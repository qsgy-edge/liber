// THROWAWAY: the ticket-#19 text-engine benchmark.
//
// Usage: dart run tool/text_engine_prototype/text_engine_bench.dart \
//          <fjs library> <phase> <parameters.json> <result.json>
//
// One phase per process, because peak RSS is a per-process number: a later
// phase in the same process could never report a peak below an earlier one's.
// `verify.py` runs every phase the ticket asks for, collects the JSON records,
// and writes the evidence and its manifest.
//
// Phases (parameters in brackets):
//   dart-index        [path, stride] pure-Dart streaming index: line starts and
//                     code units in one pass — the comparison row the contract
//                     asks for
//   dart-read-string  [path] File.readAsString(): what the reader does today
//                     (D4 measured 2.9 s and ≈ 1 GB for the 500 MB file)
//   dart-decode       [path] decode a whole file with `dart:convert` and count
//                     replacement characters — the encoding argument, measured
//   dart-bytes        [path, stride] byte-level line pass, no decoding: the
//                     strongest pure-Dart row a GBK file admits
//   rust-index        [path, stride, toc_rules?, max_scan_bytes?] the engine's
//                     one-pass index through the bridge; writes the anchors it
//                     produced to `anchors_out` for the window phases
//   rust-window       [path, anchors_in, offset, max_code_units] one window read
//                     through the bridge, timed on its own
//   rust-convert      [traditional, simplified] t2s and s2t over two
//                     chapter-sized strings through the bridge
//
// Resident set size comes from the Dart VM (`ProcessInfo.currentRss` at the
// start of the phase and `ProcessInfo.maxRss` at the end), which reads the
// operating system's own counters — on Windows the same
// `GetProcessMemoryInfo(...).PeakWorkingSetSize` the process reports. The phase
// floor is therefore the Dart VM itself, and the record keeps both numbers so
// the engine's own footprint is the difference.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart';
import 'package:liber/local/text_engine.dart';
import 'package:liber/source/native_library.dart';

/// The pure-Dart streaming index: read fixed chunks, split them on `\n`, decode
/// every line, count UTF-16 code units, line starts, and every `stride` bytes
/// one anchor. This is the row the Rust engine has to beat, written the way a
/// Dart-only reader would have to.
Map<String, Object?> dartStreamIndex(String path, int stride) {
  final reader = File(path).openSync();
  final chunk = Uint8List(256 * 1024);
  final pending = <int>[];
  var consumed = 0;
  var unitCount = 0;
  var lineCount = 0;
  // The first line is an anchor too, exactly as the engine's index starts with
  // one; the count is comparable only if both sides count it.
  var anchorCount = 1;
  var lastAnchorByte = 0;
  try {
    while (true) {
      final read = reader.readIntoSync(chunk);
      if (read == 0) {
        break;
      }
      consumed += read;
      pending.addAll(Uint8List.sublistView(chunk, 0, read));
      var start = 0;
      while (true) {
        final newline = pending.indexOf(0x0a, start);
        if (newline < 0) {
          break;
        }
        final lineStartByte = consumed - pending.length + start;
        if (lineStartByte - lastAnchorByte >= stride) {
          anchorCount++;
          lastAnchorByte = lineStartByte;
        }
        unitCount += utf8.decode(pending.sublist(start, newline), allowMalformed: true).length + 1;
        lineCount++;
        start = newline + 1;
      }
      if (start > 0) {
        pending.removeRange(0, start);
      }
    }
    if (pending.isNotEmpty) {
      unitCount += utf8.decode(pending, allowMalformed: true).length;
      lineCount++;
    }
  } finally {
    reader.closeSync();
  }
  return {
    'bytes': consumed,
    'code_units': unitCount,
    'lines': lineCount,
    'anchors': anchorCount,
  };
}

/// Byte-level line pass with no decoding at all.
Map<String, Object?> dartBytePass(String path, int stride) {
  final reader = File(path).openSync();
  final chunk = Uint8List(256 * 1024);
  var consumed = 0;
  var lineCount = 0;
  var anchorCount = 1;
  var lastAnchorByte = 0;
  try {
    while (true) {
      final read = reader.readIntoSync(chunk);
      if (read == 0) {
        break;
      }
      final from = consumed;
      consumed += read;
      for (var index = 0; index < read; index++) {
        if (chunk[index] != 0x0a) {
          continue;
        }
        if (from + index - lastAnchorByte >= stride) {
          anchorCount++;
          lastAnchorByte = from + index;
        }
        lineCount++;
      }
    }
  } finally {
    reader.closeSync();
  }
  return {'bytes': consumed, 'lines': lineCount, 'anchors': anchorCount};
}

TextIndexOptions optionsFrom(Map<String, dynamic> parameters) {
  final defaults = textDefaultOptions();
  return TextIndexOptions(
    anchorStrideBytes: parameters['stride'] as int? ?? defaults.anchorStrideBytes,
    tocRules: (parameters['toc_rules'] as List<dynamic>?)?.cast<String>() ?? defaults.tocRules,
    maxScanBytes: parameters['max_scan_bytes'] as int? ?? defaults.maxScanBytes,
  );
}

Future<void> main(List<String> args) async {
  if (args.length != 4) {
    stderr.writeln(
      'usage: text_engine_bench <fjs library> <phase> <parameters.json> <result.json>',
    );
    exit(2);
  }
  final [library, phase, parametersPath, resultPath] = args;
  final parameters =
      jsonDecode(File(parametersPath).readAsStringSync()) as Map<String, dynamic>;
  final baselineRss = ProcessInfo.currentRss;
  var measuredMicros = 0;
  final record = <String, Object?>{'phase': phase};
  // The bridge has to be initialized before the first engine call and disposed
  // after the last one: an undisposed bridge keeps pending work alive and the
  // process then never settles.
  final usesEngine = phase.startsWith('rust-');
  if (usesEngine) {
    await NativeLibrary.initialize(libraryPath: library);
  }

  Future<void> run(Future<Map<String, Object?>> Function() body) async {
    final watch = Stopwatch()..start();
    record.addAll(await body());
    watch.stop();
    measuredMicros = watch.elapsedMicroseconds;
  }

  switch (phase) {
    case 'dart-index':
      final path = parameters['path'] as String;
      final stride = parameters['stride'] as int;
      await run(() async => dartStreamIndex(path, stride));
    case 'dart-read-string':
      final path = parameters['path'] as String;
      try {
        await run(() async {
          final text = File(path).readAsStringSync();
          return {
            'code_units': text.length,
            'lines': '\n'.allMatches(text).length,
          };
        });
      } catch (error) {
        // Decoding is where a file the reader can open today ends: UTF-8 is all
        // `dart:convert` has, so a GBK file fails here (FileSystemException:
        // "Failed to decode data using encoding 'utf-8'") or, with
        // `allowMalformed`, comes back as replacement characters.
        record['error'] = '$error';
      }
    case 'dart-decode':
      final path = parameters['path'] as String;
      await run(() async {
        final text = utf8.decode(
          File(path).readAsBytesSync(),
          allowMalformed: true,
        );
        return {
          'code_units': text.length,
          'replacement_characters': '\uFFFD'.allMatches(text).length,
        };
      });
    case 'dart-bytes':
      final path = parameters['path'] as String;
      final stride = parameters['stride'] as int;
      await run(() async => dartBytePass(path, stride));
    case 'rust-index':
      final path = parameters['path'] as String;
      await run(() async {
        final index = await TextEngine.index(path, options: optionsFrom(parameters));
        final anchorsOut = parameters['anchors_out'] as String?;
        if (anchorsOut != null) {
          File(anchorsOut).writeAsStringSync(
            jsonEncode([
              for (final anchor in index.anchors)
                [anchor.byteOffset, anchor.codeUnitOffset, anchor.lineIndex],
            ]),
          );
        }
        return {
          'encoding': index.encoding,
          'bytes': index.byteLength,
          'code_units': index.codeUnitLength,
          'anchors': index.anchors.length,
          'chapters': index.chapters.length,
          'ignored_rules': index.ignoredRules.length,
        };
      });
    case 'rust-window':
      final path = parameters['path'] as String;
      final offset = parameters['offset'] as int;
      final anchors = (jsonDecode(
        File(parameters['anchors_in'] as String).readAsStringSync(),
      ) as List<dynamic>)
          .map((row) => (row as List<dynamic>).cast<int>())
          .toList();
      final encoding = parameters['encoding'] as String;
      final anchorRow = anchors.lastWhere((row) => row[1] <= offset);
      await run(() async {
        final window = await TextEngine.readWindow(
          path: path,
          encoding: encoding,
          anchor: TextAnchor(
            byteOffset: anchorRow[0],
            codeUnitOffset: anchorRow[1],
            lineIndex: anchorRow[2],
          ),
          codeUnitOffset: offset,
          maxCodeUnits: parameters['max_code_units'] as int,
          maxScanBytes: parameters['max_scan_bytes'] as int? ?? 4 * 1024 * 1024,
        );
        return {
          'code_units': window.text.length,
          'at_end': window.atEnd,
          'sample': window.text.substring(
            0,
            window.text.length < 32 ? window.text.length : 32,
          ),
        };
      });
    case 'rust-convert':
      final traditional = File(parameters['traditional'] as String).readAsStringSync();
      final simplified = File(parameters['simplified'] as String).readAsStringSync();
      await run(() async {
        final watch = Stopwatch()..start();
        final t2s = TextEngine.t2s(traditional);
        final t2sMicros = watch.elapsedMicroseconds;
        watch.reset();
        final s2t = TextEngine.s2t(simplified);
        final s2tMicros = watch.elapsedMicroseconds;
        return {
          't2s_code_units': traditional.length,
          's2t_code_units': simplified.length,
          't2s_micros': t2sMicros,
          's2t_micros': s2tMicros,
          't2s_changed': t2s == traditional ? 0 : 1,
          's2t_changed': s2t == simplified ? 0 : 1,
        };
      });
    default:
      stderr.writeln('unknown phase $phase');
      exit(2);
  }

  record.addAll({
    'elapsed_micros': measuredMicros,
    'baseline_rss_bytes': baselineRss,
    'peak_rss_bytes': ProcessInfo.maxRss,
    'platform': Platform.operatingSystem,
  });
  if (usesEngine) {
    NativeLibrary.dispose();
  }
  File(resultPath).writeAsStringSync(jsonEncode(record));
  stdout.writeln(jsonEncode(record));
}
