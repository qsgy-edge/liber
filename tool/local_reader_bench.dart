// THROWAWAY: the ticket-#20 paged-reader benchmark.
//
// Usage: dart run tool/local_reader_bench.dart <fjs library> <phase> <args…> <result.json>
//
//   gen  <path> <megabytes>  write a plausible Chinese novel TXT of that size.
//                             The fixture is generated, never committed.
//   open <path> <fraction>   admit that file to an in-memory space, open it once
//                             (the index pass) and page once, write the stored
//                             position where <fraction> of the file is, and then
//                             time the open the acceptance row asks for — open
//                             to the stored position — on its own.
//
// One phase per process, because peak RSS is a per-process number: a later phase
// in the same process could never report a peak below an earlier one's. Resident
// set size comes from the Dart VM (`ProcessInfo.maxRss`), the same
// operating-system counter the text engine's own rows use.

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/local/reader_restore.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/progress.dart';
import 'package:liber/store/space_store.dart';

/// Writes a Chinese novel TXT of at least [megabytes] to [path].
///
/// The shape is a plausible one: a chapter heading every thirty-odd paragraphs,
/// so a twenty-megabyte book has a few thousand chapters rather than ten
/// thousand.
void generate(String path, int megabytes) {
  final target = megabytes * 1024 * 1024;
  final sink = File(path).openSync(mode: FileMode.write);
  final buffer = StringBuffer();
  var written = 0;
  var chapter = 1;
  try {
    while (written < target) {
      buffer.clear();
      for (var index = 0; index < 200; index++) {
        buffer.writeln('第${chapter + index}章 起点');
        for (var paragraph = 1; paragraph <= 30; paragraph++) {
          buffer.writeln('这是第${chapter + index}章的第$paragraph段。' * 6);
        }
      }
      final bytes = utf8.encode(buffer.toString());
      sink.writeFromSync(bytes);
      written += bytes.length;
      chapter += 200;
    }
  } finally {
    sink.closeSync();
  }
}

/// A book over an in-memory space with [file] admitted, as the app admits one.
Future<({SpaceStore store, LocalLibrary library, LocalBook book})> admit(
  File file,
) async {
  final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
  final library = LocalLibrary(store);
  // `LocalLibrary` matches a file inside a root by the platform's own
  // separators, and a path handed in from outside may spell them the other way.
  final root = file.parent.path.replaceAll('/', Platform.pathSeparator);
  await library.selectRoot(root);
  final books = await library.addFiles([
    File(
      '$root${Platform.pathSeparator}'
      '${file.path.split(RegExp(r'[/\\]')).last}',
    ),
  ]);
  return (store: store, library: library, book: books.single);
}

/// The engine under measurement, counting what the reader asked it for: the
/// proof that no open hands it a whole document.
class CountingEngine implements ReaderEngine {
  CountingEngine(this.engine);

  final ReaderEngine engine;
  final List<({int textOffset, int maxCodeUnits})> reads = [];
  int indexPasses = 0;

  /// What the engine's own index call took, inside the open that asked for it.
  int indexMicros = 0;

  int get largestRead => reads.isEmpty
      ? 0
      : reads.map((read) => read.maxCodeUnits).reduce(math.max);

  @override
  Future<ReaderIndex> index(String path) async {
    indexPasses += 1;
    final watch = Stopwatch()..start();
    try {
      return await engine.index(path);
    } finally {
      indexMicros = watch.elapsedMicroseconds;
    }
  }

  @override
  Future<ReaderWindow> readWindow({
    required String path,
    required String encoding,
    required int textOffset,
    required int maxCodeUnits,
    ReaderAnchor? anchor,
  }) {
    reads.add((textOffset: textOffset, maxCodeUnits: maxCodeUnits));
    return engine.readWindow(
      path: path,
      encoding: encoding,
      textOffset: textOffset,
      maxCodeUnits: maxCodeUnits,
      anchor: anchor,
    );
  }

  @override
  String render(String text, ConvertTarget? script) =>
      engine.render(text, script);
}

/// The record a reader would have written at [textOffset]: the line it sits in,
/// the line's anchor, and the length of the file it was written against — all
/// through the same engine the reader reads with.
Future<ProgressRecord> recordAt(
  ReaderEngine engine,
  ReaderIndex index,
  String path,
  int textOffset,
) async {
  final lines = ReaderLines(engine: engine, path: path, index: index);
  final line = (await lines.lineAt(textOffset)).line;
  final prefix = await lines.read(line.start, maxCodeUnits: 32);
  final newline = prefix.text.indexOf('\n');
  final anchor = newline < 0 ? prefix.text : prefix.text.substring(0, newline);
  return ProgressRecord(
    textOffset: line.start,
    lineIndex: line.lineIndex,
    offsetInLine: 0,
    textLength: index.codeUnitLength,
    anchor: anchor.isEmpty ? null : anchor,
  );
}

Future<void> main(List<String> arguments) async {
  if (arguments.length < 4) {
    stderr.writeln(
      'usage: local_reader_bench <fjs library> <phase> <args…> <result.json>',
    );
    exit(2);
  }
  final library = arguments[0];
  final phase = arguments[1];
  final resultPath = arguments.last;
  var baselineRss = ProcessInfo.currentRss;
  var usesEngine = false;
  final record = <String, Object?>{'phase': phase, 'library': library};

  switch (phase) {
    case 'gen':
      final path = arguments[2];
      final megabytes = int.parse(arguments[3]);
      generate(path, megabytes);
      record.addAll({'path': path, 'bytes': File(path).lengthSync()});
    case 'open':
      usesEngine = true;
      final path = arguments[2];
      final fraction = double.parse(arguments[3]);
      await NativeLibrary.initialize(libraryPath: library);
      final space = await admit(File(path));
      final engine = CountingEngine(const NativeReaderEngine());

      // Opener A: the first open indexes the file in one pass, then pages once so
      // the store holds an index and a position.
      final first = LocalReader(
        engine: engine,
        library: space.library,
        book: space.book,
      );
      final indexWatch = Stopwatch()..start();
      await first.open();
      final indexMicros = indexWatch.elapsedMicroseconds;
      await first.next();

      final facts = await space.library.fileIndex(space.book);
      final index = ReaderIndex(
        encoding: facts.encoding,
        codeUnitLength: facts.textLength!,
        anchors: facts.anchors,
      );
      final readsAfterIndex = engine.reads.length;

      // The stored position the acceptance row opens to.
      final stored = await recordAt(
        const NativeReaderEngine(),
        index,
        path,
        (index.codeUnitLength * fraction).round(),
      );
      await space.library.saveProgressRecord(space.book.id, stored);

      // Opener B: opening to the stored position, on its own.
      engine.reads.clear();
      final second = LocalReader(
        engine: engine,
        library: space.library,
        book: space.book,
      );
      final openWatch = Stopwatch()..start();
      await second.open();
      final openMicros = openWatch.elapsedMicroseconds;

      baselineRss = ProcessInfo.currentRss;
      record.addAll({
        'path': path,
        'bytes': File(path).lengthSync(),
        'code_units': index.codeUnitLength,
        'anchors': index.anchors.length,
        'index_pass_and_first_page_micros': indexMicros,
        'engine_index_micros': engine.indexMicros,
        'open_to_stored_position_micros': openMicros,
        'reads_during_index_pass_and_first_page': readsAfterIndex,
        'reads_during_open_to_stored_position': engine.reads.length,
        'largest_read_code_units': engine.largestRead,
        'window_code_units': second.window?.text.length,
        'window_text_offset': second.window?.textOffset,
        'stored_text_offset': stored.textOffset,
        'position_text_offset': second.position?.textOffset,
        'restore_notice': second.notices.map((notice) => notice.name).toList(),
        'error': second.error,
      });
    default:
      stderr.writeln('unknown phase $phase');
      exit(2);
  }

  record.addAll({
    'baseline_rss_bytes': baselineRss,
    'peak_rss_bytes': ProcessInfo.maxRss,
    'platform': Platform.operatingSystem,
  });
  if (usesEngine) NativeLibrary.dispose();
  File(resultPath).writeAsStringSync(jsonEncode(record));
  stdout.writeln(jsonEncode(record));
}
