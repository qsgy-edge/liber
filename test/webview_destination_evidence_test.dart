import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

/// The destination comparison refuses a row whose recorded sources this tree no
/// longer holds (#75).
///
/// `tool/webview_oracle/tools/compare_to_golden.js` reads the manifest beside a
/// destination row, which pins the hashes of the adapter library, the product
/// files the harness drives and the harness itself. A row those hashes no longer
/// describe was produced by a different tree, so comparing it would report a
/// verdict about code this checkout does not contain. These rows drive the real
/// comparator against a scratch copy of a committed row: a matching manifest is
/// compared, a mismatching one is refused, and a row newer than its manifest (the
/// sweep in progress) is compared as before.
const _oracleRoot = 'tool/webview_oracle';
const _windowsRow = '$_oracleRoot/evidence/windows-destination/WV-01.json';
const _goldenRow = '$_oracleRoot/evidence/android/WV-01.json';

void main() {
  final node = _nodeExecutable();
  final skipReason = node == null
      ? 'node is not installed, so the destination comparator cannot run'
      : null;

  /// The manifest's recorded maps, keyed the way
  /// `tools/write_destination_manifest.js` keys them: the adapter's library by
  /// its bare file name, the product files it drives under `liber:`, and the
  /// harness's own files oracle-relative (the adapter's two in-adapter trees
  /// adapter-relative).
  Map<String, dynamic> recordedSources() => {
    'adapterSourceSha256': {
      'product_webview.dart': _sha256File(
        '$_oracleRoot/adapter/lib/product_webview.dart',
      ),
      'liber:lib/source/book_source_webview_adapter.dart': _sha256File(
        'lib/source/book_source_webview_adapter.dart',
      ),
      'liber:lib/source/inappwebview_book_source_adapter.dart': _sha256File(
        'lib/source/inappwebview_book_source_adapter.dart',
      ),
    },
    'harnessSha256': {
      'integration_test/destination_test.dart': _sha256File(
        '$_oracleRoot/adapter/integration_test/destination_test.dart',
      ),
      'tools/compare_to_golden.js': _sha256File(
        '$_oracleRoot/tools/compare_to_golden.js',
      ),
    },
  };

  /// The manifest's recorded instant, a minute either side of the row's own, so
  /// the manifest either describes the row or predates it.
  Map<String, dynamic> manifestFor(
    Map<String, dynamic> sources, {
    required bool describesRow,
  }) {
    final row = jsonDecode(File(_windowsRow).readAsStringSync()) as Map;
    final end = DateTime.parse(row['completedAtUtc'] as String);
    return {
      'schemaVersion': 1,
      'run': {
        'completedAtUtc': end
            .add(Duration(minutes: describesRow ? 1 : -1))
            .toIso8601String(),
      },
      ...sources,
    };
  }

  /// A scratch directory holding a copy of a committed destination row and, when
  /// [manifest] is given, the manifest beside it.
  Directory scratch(Map<String, dynamic>? manifest) {
    final directory = Directory.systemTemp.createTempSync(
      'liber-75-destination-',
    );
    addTearDown(() {
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    File(_windowsRow).copySync('${directory.path}/WV-01.json');
    if (manifest != null) {
      File(
        '${directory.path}/manifest.json',
      ).writeAsStringSync(jsonEncode(manifest));
    }
    return directory;
  }

  ({int exitCode, String stdout, String stderr}) compare(Directory directory) {
    final result = Process.runSync(node!, [
      '$_oracleRoot/tools/compare_to_golden.js',
      _goldenRow,
      '${directory.path}/WV-01.json',
    ]);
    return (
      exitCode: result.exitCode,
      stdout: '${result.stdout}',
      stderr: '${result.stderr}',
    );
  }

  test(
    'a manifest that records this tree\'s sources is compared',
    () {
      final result = compare(
        scratch(manifestFor(recordedSources(), describesRow: true)),
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('"comparisonVerdict": "match"'));
    },
    skip: skipReason,
  );

  test(
    'a row whose recorded source changed is refused, not compared',
    () {
      final sources = recordedSources();
      final adapter = sources['adapterSourceSha256']! as Map<String, dynamic>;
      adapter['liber:lib/source/inappwebview_book_source_adapter.dart'] =
          '0' * 64;
      final result = compare(
        scratch(manifestFor(sources, describesRow: true)),
      );

      expect(result.exitCode, 2);
      expect(result.stderr, contains('stale destination evidence'));
      expect(
        result.stderr,
        contains(
          'liber:lib/source/inappwebview_book_source_adapter.dart: recorded ',
        ),
      );
      // Nothing was compared: no verdict about this tree can be read from it.
      expect(result.stdout, isEmpty);
    },
    skip: skipReason,
  );

  test(
    'a row newer than its manifest is the sweep in progress and is compared',
    () {
      // The manifest predates the row, so it says nothing about it: a sweep
      // producing rows right now must not refuse its own output, even though the
      // old manifest's hashes are not this tree's.
      final sources = recordedSources();
      final adapter = sources['adapterSourceSha256']! as Map<String, dynamic>;
      adapter['liber:lib/source/inappwebview_book_source_adapter.dart'] =
          '0' * 64;
      final result = compare(
        scratch(manifestFor(sources, describesRow: false)),
      );

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('"comparisonVerdict": "match"'));
    },
    skip: skipReason,
  );

  test(
    'a manifest that records nothing to check is refused',
    () {
      final result = compare(
        scratch(
          manifestFor(const {
            'adapterSourceSha256': <String, String>{},
            'harnessSha256': <String, String>{},
          }, describesRow: true),
        ),
      );

      expect(result.exitCode, 2);
      expect(result.stderr, contains('records no adapter sources'));
    },
    skip: skipReason,
  );

  test(
    'a row with no manifest beside it is compared',
    () {
      final result = compare(scratch(null));

      expect(result.exitCode, 0, reason: result.stderr);
      expect(result.stdout, contains('"comparisonVerdict": "match"'));
    },
    skip: skipReason,
  );
}

/// The `node` the comparator runs under, or null when this machine has none.
/// The oracle's own scripts need it too (`tools/run_fixture*.sh`), so its absence
/// is a not-run rather than a failure of the comparator.
String? _nodeExecutable() {
  try {
    final probe = Process.runSync('node', ['--version']);
    return probe.exitCode == 0 ? 'node' : null;
  } on ProcessException {
    return null;
  }
}

String _sha256File(String path) => _sha256(File(path).readAsBytesSync());

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  return digest
      .process(Uint8List.fromList(bytes))
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();
}
