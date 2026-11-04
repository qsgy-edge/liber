import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import '../tool/result_field_compare.dart';

/// The FIELDS-01 row comparator's own rules: the corpus-hash pin, the seven
/// field rows, the named `notCompared` observations, and — most importantly —
/// the one divergence the executed frozen golden actually shows. The committed
/// golden and Liber observation are the inputs, so a rule that stops holding
/// against real evidence fails here too.
void main() {
  late Map<String, dynamic> golden;
  late Map<String, dynamic> liber;
  late Map<String, dynamic> corpus;
  late String corpusSha256;
  late String manifestCorpusSha256;

  setUpAll(() {
    golden = _read(
      'tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json',
    );
    liber = _read(
      'tool/result_field_oracle/evidence/windows-fields-01.liber.json',
    );
    corpus = _read('tool/result_field_oracle/fixtures.json');
    corpusSha256 = _sha256(
      File('tool/result_field_oracle/fixtures.json').readAsBytesSync(),
    );
    manifestCorpusSha256 =
        (_read(
                  'tool/result_field_oracle/evidence/android-17-os4.0.0.31/'
                  'manifest.json',
                )['corpus']
                as Map)['sha256']
            as String;
  });

  Map<String, Object?> compareWith({
    Map<String, dynamic>? goldenOverride,
    Map<String, dynamic>? liberOverride,
    String? shaOverride,
    String? manifestShaOverride,
  }) => compareResultFields(
    golden: goldenOverride ?? golden,
    liber: liberOverride ?? liber,
    goldenPath: 'golden.json',
    liberPath: 'liber.json',
    corpus: corpus,
    corpusSha256: shaOverride ?? corpusSha256,
    manifestCorpusSha256: manifestShaOverride ?? manifestCorpusSha256,
  );

  test(
    'selected APK accepts exactly historical five or current seven sources',
    () {
      final asset = File(
        'tool/result_field_oracle/book-url-markers-fixtures.json',
      ).readAsBytesSync();
      final historical = <String, String>{
        for (final name in [
          'FieldOracle.java',
          'StateSessionOracle.java',
          'AndroidManifest.xml',
          'build.ps1',
          'capture.py',
        ])
          name: 'a' * 64,
      };
      final current = {
        ...historical,
        'HostRuntimeInit.java': 'b' * 64,
        'ShortcutStartupGuard.java': 'c' * 64,
      };
      final directory = Directory.systemTemp.createTempSync(
        'fields-provenance-',
      );
      addTearDown(() => directory.deleteSync(recursive: true));
      Map<String, dynamic> inspect(Map<String, String> sources) {
        final provenance = {
          'schemaVersion': 1,
          'fixtureId': 'FIELDS-02',
          'corpus': {
            'asset': 'field-fixtures.json',
            'fixtureId': 'FIELDS-02',
            'corpusVersion': 1,
            'bytes': asset.length,
            'sha256': _sha256(asset),
            'sha256Lf': _sha256(
              utf8.encode(utf8.decode(asset).replaceAll('\r\n', '\n')),
            ),
          },
          'sources': sources,
        };
        final encoded = utf8.encode(jsonEncode(provenance));
        final archive = Archive()
          ..addFile(
            ArchiveFile('assets/field-fixtures.json', asset.length, asset),
          )
          ..addFile(
            ArchiveFile(
              'assets/field-provenance.json',
              encoded.length,
              encoded,
            ),
          );
        final apk = File('${directory.path}/fields.apk')
          ..writeAsBytesSync(ZipEncoder().encode(archive));
        return inspectSelectedHarnessApk(apk.path);
      }

      expect((inspect(historical)['provenance'] as Map)['sources'], historical);
      expect((inspect(current)['provenance'] as Map)['sources'], current);
      for (final bad in [
        {...current}..remove('HostRuntimeInit.java'),
        {...current, 'ShortcutStartupGuard.java': 'bad'},
        {...current, 'unrelated.java': 'd' * 64},
      ]) {
        expect(() => inspect(bad), throwsA(isA<StateError>()));
      }
    },
  );

  test('selected-reference APK requires its exact ten-source provenance', () {
    final asset = File(
      'tool/result_field_oracle/book-url-markers-fixtures-selected.json',
    ).readAsBytesSync();
    final sources = <String, String>{
      for (final name in [
        'FieldOracle.java',
        'StateSessionOracle.java',
        'AndroidManifest.xml',
        'build.ps1',
        'capture.py',
        'HostRuntimeInit.java',
        'ShortcutStartupGuard.java',
        'GuardedReaderApplication.java',
        'SelectedFieldHostBridge.java',
        'AndroidManifest-selected.xml',
      ])
        name: 'a' * 64,
    };
    final directory = Directory.systemTemp.createTempSync('fields-selected-');
    addTearDown(() => directory.deleteSync(recursive: true));
    Map<String, dynamic> inspect(
      Map<String, String> input, {
      List<int>? corpusBytes,
    }) {
      final selectedAsset = corpusBytes ?? asset;
      final provenance = utf8.encode(
        jsonEncode({
          'schemaVersion': 1,
          'fixtureId': 'FIELDS-02',
          'corpus': {
            'asset': 'field-fixtures.json',
            'fixtureId': 'FIELDS-02',
            'corpusVersion': 1,
            'bytes': selectedAsset.length,
            'sha256': _sha256(selectedAsset),
            'sha256Lf': _sha256(selectedAsset),
          },
          'sources': input,
        }),
      );
      final archive = Archive()
        ..addFile(
          ArchiveFile(
            'assets/field-fixtures.json',
            selectedAsset.length,
            selectedAsset,
          ),
        )
        ..addFile(
          ArchiveFile(
            'assets/field-provenance.json',
            provenance.length,
            provenance,
          ),
        );
      final apk = File('${directory.path}/fields.apk')
        ..writeAsBytesSync(ZipEncoder().encode(archive));
      return inspectSelectedHarnessApk(apk.path);
    }

    expect((inspect(sources)['provenance'] as Map)['sources'], sources);
    expect(
      () => inspect({...sources}..remove('SelectedFieldHostBridge.java')),
      throwsA(isA<StateError>()),
    );
    final relabelled = (jsonDecode(utf8.decode(asset)) as Map<String, dynamic>);
    (relabelled['target'] as Map)['apkSha256'] = '0' * 64;
    expect(
      () => inspect(sources, corpusBytes: utf8.encode(jsonEncode(relabelled))),
      throwsA(isA<StateError>()),
    );
  });

  test('the corpus row and six of the seven field rows pass', () {
    final report = compareWith();
    for (final id in ['C1', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7']) {
      expect(_row(report, id)['status'], 'pass', reason: id);
      expect(_row(report, id)['differences'], isEmpty, reason: id);
    }
    expect(_row(report, 'C1')['detail'], contains('20 declared requests'));
  });

  test('F4 passes on the frozen parse-layer scalar coercion', () {
    // The executed frozen reader reads `checkKeyWord: 42` as the string "42"
    // (Gson's String adapter on a NUMBER token) and `BookSource.getCheckKeyword`
    // returns it; the product reproduces that at `sourceCheckKeyword`. This test
    // fails if either side stops coercing, which is the point of the row. The
    // residual spelling difference for a non-canonical literal (`1e3`, `1.50`)
    // is recorded in the capability matrix, not compared here.
    expect((golden['checkKeyword'] as Map)['number'], {
      'outcome': 'value',
      'value': '42',
    });
    expect((liber['checkKeyword'] as Map)['number'], {
      'outcome': 'value',
      'value': '42',
    });
    final row = _row(compareWith(), 'F4');
    expect(row['status'], 'pass');
    expect(row['differences'], isEmpty);
  });

  test('F4 treats the malformed object as refused on both sides', () {
    final detail = _row(compareWith(), 'F4')['detail'] as String;
    expect(
      detail,
      contains('object (frozen: com.google.gson.JsonSyntaxException'),
    );
    expect(detail, contains('product: FormatException'));
  });

  test('F4 fails when one side refuses and the other answers', () {
    final changed = _deepCopy(golden);
    (changed['checkKeyword'] as Map)['declared'] = {
      'outcome': 'refused',
      'reason': 'a refusal the frozen side did not record',
    };
    expect(_row(compareWith(goldenOverride: changed), 'F4')['status'], 'fail');
  });

  test('a changed frozen field value fails its row', () {
    final changed = _deepCopy(golden);
    final results =
        (((changed['cases'] as Map)['html-rename-permitted'] as Map)['search']
                as Map)['results']
            as List;
    ((results.first as Map))['intro'] = 'not the frozen intro';
    expect(_row(compareWith(goldenOverride: changed), 'F1')['status'], 'fail');
    // The same mutation leaves the other rows alone.
    expect(_row(compareWith(goldenOverride: changed), 'F2')['status'], 'pass');
  });

  test(
    'a case the frozen side did not reach is named, not silently passed',
    () {
      final changed = _deepCopy(golden);
      (changed['cases'] as Map).remove('json-fields');
      (changed['caseFailures'] as Map)['json-fields'] =
          'a streamed stage error';
      final report = compareWith(goldenOverride: changed);
      // Only the case both sides reached is compared, so the row has no
      // divergence to report; the missing case is named with its reason.
      expect(_row(report, 'F1')['status'], 'pass');
      expect(_row(report, 'F1')['detail'], '4 of 5 cases compared on intro');
      expect(
        (report['notCompared'] as List).cast<Map>().map(
          (e) => e['observation'],
        ),
        contains('cases.json-fields.search.results'),
      );
      expect(
        (report['notCompared'] as List).cast<Map>().firstWhere(
          (e) => e['observation'] == 'cases.json-fields.search.results',
        )['reason'],
        contains('a streamed stage error'),
      );
    },
  );

  test('the corpus bytes are pinned to the manifest and the observation', () {
    expect(() => compareWith(shaOverride: 'not-the-corpus'), throwsStateError);
    expect(
      () => compareWith(manifestShaOverride: 'not-the-pinned-corpus'),
      throwsStateError,
    );
  });

  test('a golden with an analysis failure is refused outright', () {
    final changed = _deepCopy(golden);
    changed['analysisFailure'] = 'searchBookAwait threw';
    expect(() => compareWith(goldenOverride: changed), throwsStateError);
  });

  test('notCompared names the content text, the headers and the teardown', () {
    final observations = _observations(compareWith());
    expect(observations, contains('cases.<id>.chapter.text'));
    expect(observations, contains('requests[].headers.*, requests[].body'));
    expect(observations, contains('state.*, cleanup.*, serverErrors'));
  });
}

Map<String, dynamic> _read(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

Map _row(Map<String, Object?> report, String id) =>
    (report['rows'] as List).cast<Map>().firstWhere((row) => row['id'] == id);

Set<Object?> _observations(Map<String, Object?> report) => {
  for (final entry in (report['notCompared'] as List).cast<Map>())
    entry['observation'],
};

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
