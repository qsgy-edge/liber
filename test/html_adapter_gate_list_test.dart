import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../tool/html_adapter_gate.dart' as gate;
import 'native_library.dart';

/// The public boundary of the HTML capture: the committed `HTML-LIST-01` corpus
/// through `tool/html_adapter_gate.dart`, plus synthetic admission controls.
/// Every control lives only in the system temp directory and is explicitly
/// synthetic: no record here is a device or frozen golden.
late Directory _scratch;
int _serial = 0;

void main() {
  setUpAll(() async {
    await NativeLibrary.initialize(libraryPath: nativeLibraryPath());
    _scratch = Directory.systemTemp.createTempSync('liber-html-list-gate-');
  });
  tearDownAll(() {
    if (_scratch.existsSync()) _scratch.deleteSync(recursive: true);
    NativeLibrary.dispose();
  });

  test(
    'the committed HTML-LIST-01 corpus measures typed list values',
    () async {
      final report = await gate.runHtmlAdapterGate(
        libraryPath: nativeLibraryPath(),
        corpusPath: gate.htmlListCorpusPath,
      );

      expect(report['status'], 'pass');
      expect(report['corpusPath'], gate.htmlListCorpusPath);
      expect(report['corpusFixtureId'], gate.htmlListFixtureId);
      expect(report['corpusVersion'], gate.htmlListCorpusVersion);
      expect(
        report['corpusSha256'],
        _sha256File(File(gate.htmlListCorpusPath)),
      );
      expect(report['fixturesSha256'], report['corpusSha256']);
      expect(report['frozenGolden'], 'not-run');
      expect(report['cases'], 11);
      expect(report['expectationMismatches'], isEmpty);

      final observed = _observedById(report);
      expect(observed['html-list-ordered-hrefs'], ['/1', '/2', '/3']);
      expect(observed['html-scalar-twin-ordered-hrefs'], '/1\n/2\n/3');
      expect(observed['html-list-declared-order'], ['/3', '/1', '/2']);
      expect(observed['html-list-per-item-replacement'], [
        '/page/1',
        '/page/2',
        '/page/3',
      ]);
      expect(
        observed['html-scalar-joined-replacement-twin'],
        '/page/1\n/2\n/3',
      );
      expect(observed['html-list-empty'], <String>[]);
      expect(observed['html-list-url-empty'], <String>[]);
      expect(observed['html-list-entity-no-unescape'], ['A&amp;B']);
      expect(observed['html-scalar-entity-twin'], 'A&B');
      expect(observed['json-list-string-names'], ['甲', '乙']);
      expect(observed['json-scalar-string-twin'], '甲\n乙');

      // The same rule's list and scalar reads are different typed observations,
      // so a nonempty list cannot be hidden as its scalar rendering and vice
      // versa.
      for (final (listId, scalarId) in [
        ('html-list-ordered-hrefs', 'html-scalar-twin-ordered-hrefs'),
        (
          'html-list-per-item-replacement',
          'html-scalar-joined-replacement-twin',
        ),
        ('json-list-string-names', 'json-scalar-string-twin'),
      ]) {
        expect(observed[listId], isA<List<String>>());
        expect(observed[scalarId], isA<String>());
        expect(
          jsonEncode(observed[listId]),
          isNot(jsonEncode(observed[scalarId])),
        );
      }
    },
  );

  test('the unchanged default corpus keeps its 45-case identity', () async {
    final report = await gate.runHtmlAdapterGate(
      libraryPath: nativeLibraryPath(),
    );

    expect(report['status'], 'pass');
    expect(report['corpusPath'], gate.legacyHtmlCorpusPath);
    expect(report['corpusFixtureId'], isNull);
    expect(report['corpusVersion'], isNull);
    expect(
      report['corpusSha256'],
      _sha256File(File(gate.legacyHtmlCorpusPath)),
    );
    expect(report['cases'], 45);
    expect(report['expectationMismatches'], isEmpty);
  });

  test('the committed legacy golden still compares 45 cases', () async {
    final report = await _run(
      corpusPath: gate.legacyHtmlCorpusPath,
      goldenPath: 'tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json',
    );

    expect(report['status'], 'pass');
    expect(report['cases'], 45);
    expect(report['frozenMismatches'], isEmpty);
  });

  test(
    'a nonempty list cannot be compared as empty or another order',
    () async {
      for (final replacement in <Object?>[
        <String>[],
        ['/2', '/1', '/3'],
        null,
      ]) {
        final corpus = _listCorpus();
        _case(corpus, 'html-list-ordered-hrefs')['expected'] = replacement;
        final report = await _run(corpusPath: _writeJson('value', corpus));

        expect(report['status'], 'fail');
        expect(_observedById(report)['html-list-ordered-hrefs'], [
          '/1',
          '/2',
          '/3',
        ]);
        expect(
          (report['expectationMismatches'] as List).join('\n'),
          contains('html-list-ordered-hrefs'),
        );
      }
    },
  );

  test(
    'a scalar expected value for a list row is refused as row damage',
    () async {
      final corpus = _listCorpus();
      _case(corpus, 'html-list-ordered-hrefs')['expected'] = '/1\n/2\n/3';
      await expectLater(
        _run(corpusPath: _writeJson('scalar-row', corpus)),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('must be a list of strings or null'),
          ),
        ),
      );
    },
  );

  test('a referenced document body must be a string or empty string', () async {
    final base = _listCorpus();
    final single = _clone(base)..['cases'] = [_case(base, 'html-list-empty')];

    final stringReport = await _run(
      corpusPath: _writeJson('document-string', single),
    );
    expect(stringReport['status'], 'pass');
    expect(stringReport['cases'], 1);

    final empty = _clone(single);
    (empty['documents'] as Map<String, dynamic>)['toc'] = '';
    final emptyReport = await _run(
      corpusPath: _writeJson('document-empty', empty),
    );
    expect(emptyReport['status'], 'pass');
    expect(emptyReport['cases'], 1);

    for (final (name, value) in [
      ('null', null),
      ('number', 7),
      ('object', <String, Object?>{'body': '<html></html>'}),
      ('array', <String>['<html></html>']),
    ]) {
      final corpus = _clone(single);
      (corpus['documents'] as Map<String, dynamic>)['toc'] = value;
      await expectLater(
        _run(corpusPath: _writeJson('document-$name', corpus)),
        throwsA(isA<FormatException>()),
        reason: name,
      );
    }
  });

  test('metadata and row damage are refused before a rule runs', () async {
    final controls = <String, Map<String, dynamic> Function()>{
      'unknown family': () {
        final corpus = _listCorpus();
        corpus['fixtureId'] = 'HTML-LIST-99';
        return corpus;
      },
      'wrong version': () {
        final corpus = _listCorpus();
        corpus['corpusVersion'] = 2;
        return corpus;
      },
      'fractional version': () {
        final corpus = _listCorpus();
        corpus['corpusVersion'] = 1.0;
        return corpus;
      },
      'wrong schema': () {
        final corpus = _listCorpus();
        corpus['schemaVersion'] = 2;
        return corpus;
      },
      'fractional schema': () {
        final corpus = _listCorpus();
        corpus['schemaVersion'] = 1.0;
        return corpus;
      },
      'duplicate id': () {
        final corpus = _listCorpus();
        final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();
        cases.add(Map<String, dynamic>.of(cases.first));
        return corpus;
      },
      'missing expected': () {
        final corpus = _listCorpus();
        _case(corpus, 'html-list-empty').remove('expected');
        return corpus;
      },
      'unsupported path': () {
        final corpus = _listCorpus();
        _case(corpus, 'html-list-ordered-hrefs')['path'] = 'rule';
        return corpus;
      },
    };
    for (final control in controls.entries) {
      await expectLater(
        _run(
          corpusPath: _writeJson('metadata-${control.key}', control.value()),
        ),
        throwsA(isA<FormatException>()),
        reason: control.key,
      );
    }
  });

  test('empty, downgraded and unknown corpora are refused', () async {
    final empty = _clone(_listCorpus())..['cases'] = <Object?>[];
    await expectLater(
      _run(corpusPath: _writeJson('empty-corpus', empty)),
      throwsA(isA<FormatException>()),
    );

    final downgraded = _clone(_listCorpus())
      ..remove('fixtureId')
      ..remove('corpusVersion');
    await expectLater(
      _run(corpusPath: _writeJson('downgraded-corpus', downgraded)),
      throwsA(isA<FormatException>()),
    );

    final legacyBytes = File(gate.legacyHtmlCorpusPath).readAsBytesSync();
    await expectLater(
      _run(corpusPath: _writeBytes('modified-legacy', [...legacyBytes, 10])),
      throwsA(isA<FormatException>()),
    );

    final copy = await _run(
      corpusPath: _writeBytes('legacy-copy', legacyBytes),
    );
    expect(copy['status'], 'pass');
    expect(copy['cases'], 45);
  });

  test('the actual producer envelope is admitted and compared', () async {
    final report = await _run(
      goldenPath: _writeJson('producer-envelope', _producerGolden()),
    );

    expect(report['status'], 'pass');
    expect(report['cases'], 11);
    expect(report['frozenMismatches'], isEmpty);
  });

  test('the retained hybrid producer shape is admitted', () async {
    final report = await _run(
      goldenPath: _writeJson('producer-hybrid', _hybridGolden()),
    );

    expect(report['status'], 'pass');
    expect(report['cases'], 11);
    expect(report['frozenMismatches'], isEmpty);
  });

  test('the nested measured binding and provenance are required', () async {
    final mutations = <String, void Function(Map<String, dynamic>)>{
      'wrong hash': (golden) {
        _corpusBlock(golden)['sha256'] = List.filled(64, '0').join();
      },
      'wrong length': (golden) {
        _corpusBlock(golden)['bytes'] =
            (_corpusBlock(golden)['bytes'] as int) + 1;
      },
      'fractional length': (golden) {
        _corpusBlock(golden)['bytes'] = (_corpusBlock(golden)['bytes'] as int)
            .toDouble();
      },
      'wrong fixture': (golden) {
        _corpusBlock(golden)['fixtureId'] = 'HTML-LIST-99';
      },
      'wrong version': (golden) {
        _corpusBlock(golden)['corpusVersion'] = 2;
      },
      'fractional version': (golden) {
        _corpusBlock(golden)['corpusVersion'] = 1.0;
      },
      'wrong schema': (golden) {
        _corpusBlock(golden)['schemaVersion'] = 2;
      },
      'fractional schema': (golden) {
        _corpusBlock(golden)['schemaVersion'] = 1.0;
      },
      'wrong asset': (golden) {
        _corpusBlock(golden)['asset'] = 'other-fixtures.json';
      },
      'missing corpus metadata': (golden) {
        golden.remove('corpus');
      },
      'missing observations': (golden) {
        golden.remove('observations');
      },
      'missing fingerprint': (golden) {
        golden.remove('fingerprint');
      },
      'empty fingerprint': (golden) {
        golden['fingerprint'] = '   ';
      },
      'non-string fingerprint': (golden) {
        golden['fingerprint'] = 7;
      },
    };
    for (final control in mutations.entries) {
      final golden = _hybridGolden();
      control.value(golden);
      await expectLater(
        _run(goldenPath: _writeJson('binding-${control.key}', golden)),
        throwsA(isA<StateError>()),
        reason: control.key,
      );
    }
  });

  test(
    'frozen observations require one typed outcome per declared id',
    () async {
      final mutations = <String, void Function(Map<String, dynamic>)>{
        'contradictory value and error': (golden) {
          _observations(golden).first['error'] = 'synthetic-contradictory';
        },
        'missing outcome': (golden) {
          _observations(golden).first.remove('value');
        },
        'non-string error': (golden) {
          _observations(golden).first
            ..remove('value')
            ..['error'] = 7;
        },
        'empty error': (golden) {
          _observations(golden).first
            ..remove('value')
            ..['error'] = '';
        },
        'scalar value on list row': (golden) {
          _row(golden, 'html-list-ordered-hrefs')['value'] = '/1\n/2\n/3';
        },
        'list value on scalar row': (golden) {
          _row(golden, 'html-scalar-twin-ordered-hrefs')['value'] = [
            '/1',
            '/2',
            '/3',
          ];
        },
        'non-string list element': (golden) {
          _row(golden, 'html-list-ordered-hrefs')['value'] = ['/1', 2];
        },
        'scalar numeric value': (golden) {
          _row(golden, 'html-scalar-twin-ordered-hrefs')['value'] = 42;
        },
      };
      for (final control in mutations.entries) {
        final golden = _hybridGolden();
        control.value(golden);
        await expectLater(
          _run(goldenPath: _writeJson('outcome-${control.key}', golden)),
          throwsA(isA<StateError>()),
          reason: control.key,
        );
      }
    },
  );

  test('declared observation ids are exactly once in any row order', () async {
    final base = _hybridGolden();
    final rows = _observations(base);
    final controls = <String, List<Map<String, dynamic>>>{
      'missing': rows.sublist(0, rows.length - 1),
      'duplicate': [...rows.sublist(0, rows.length - 1), rows.first],
      'extra': [
        ...rows,
        {'id': 'synthetic-extra', 'value': ''},
      ],
    };
    for (final control in controls.entries) {
      final golden = _clone(base)..['observations'] = control.value;
      await expectLater(
        _run(goldenPath: _writeJson('ids-${control.key}', golden)),
        throwsA(isA<StateError>()),
        reason: control.key,
      );
    }
  });

  test('row order, explicit null values and outcome kinds remain real', () async {
    final reordered = _hybridGolden();
    _observations(
      reordered,
    ).setAll(0, _observations(reordered).reversed.toList());
    final reorderedReport = await _run(
      goldenPath: _writeJson('reordered', reordered),
    );
    expect(reorderedReport['status'], 'pass');

    final nullValue = _hybridGolden();
    _row(nullValue, 'html-list-ordered-hrefs')['value'] = null;
    final nullReport = await _run(
      goldenPath: _writeJson('null-value', nullValue),
    );
    expect(nullReport['status'], 'fail');
    expect(
      (nullReport['frozenMismatches'] as List).join('\n'),
      contains('html-list-ordered-hrefs'),
    );

    // A value must not equal an error merely because its string renders the same.
    final kind = _hybridGolden();
    _row(kind, 'html-scalar-twin-ordered-hrefs')
      ..remove('value')
      ..['error'] = '/1\n/2\n/3';
    final kindReport = await _run(goldenPath: _writeJson('outcome-kind', kind));
    expect(kindReport['status'], 'fail');
    expect(
      (kindReport['frozenMismatches'] as List).join('\n'),
      contains('html-scalar-twin-ordered-hrefs'),
    );

    final error = _hybridGolden();
    _row(error, 'html-list-empty')
      ..remove('value')
      ..['error'] = 'java.lang.NullPointerException';
    final errorReport = await _run(goldenPath: _writeJson('real-error', error));
    expect(errorReport['status'], 'fail');
    expect(
      (errorReport['frozenMismatches'] as List).join('\n'),
      contains('html-list-empty'),
    );

    final order = _hybridGolden();
    _row(order, 'html-list-ordered-hrefs')['value'] = ['/2', '/1', '/3'];
    final orderReport = await _run(goldenPath: _writeJson('list-order', order));
    expect(orderReport['status'], 'fail');
    expect(
      (orderReport['frozenMismatches'] as List).join('\n'),
      contains('html-list-ordered-hrefs'),
    );
  });

  test('the legacy golden keeps its values and requires one outcome', () async {
    const goldenPath =
        'tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json';
    final reported = await _run(
      corpusPath: gate.legacyHtmlCorpusPath,
      goldenPath: goldenPath,
    );
    expect(reported['status'], 'pass');
    expect(reported['cases'], 45);

    final damaged =
        jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
    _observations(damaged).first['error'] = 'synthetic-contradictory';
    await expectLater(
      _run(
        corpusPath: gate.legacyHtmlCorpusPath,
        goldenPath: _writeJson('legacy-contradiction', damaged),
      ),
      throwsA(isA<StateError>()),
    );
  });

  test('the legacy golden is refused by the list family identity', () async {
    await expectLater(
      _run(
        goldenPath:
            'tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json',
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Oracle corpus identity mismatch',
        ),
      ),
    );
  });

  test('a nonempty URL list stays the named product refusal', () async {
    final corpus = _listCorpus();
    _case(corpus, 'html-list-url-empty')['rule'] = '#list li@a@href';
    final report = await _run(corpusPath: _writeJson('url-nonempty', corpus));

    expect(report['status'], 'fail');
    final row = (report['observations'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['id'] == 'html-list-url-empty');
    expect(row['error'], contains('named product refusal'));
    expect(row.containsKey('value'), isFalse);
  });
}

Future<Map<String, Object?>> _run({
  String corpusPath = gate.htmlListCorpusPath,
  String? goldenPath,
}) => gate.runHtmlAdapterGate(
  libraryPath: nativeLibraryPath(),
  corpusPath: corpusPath,
  goldenPath: goldenPath,
);

Map<String, dynamic> _listCorpus() =>
    jsonDecode(File(gate.htmlListCorpusPath).readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

Map<String, dynamic> _case(Map<String, dynamic> corpus, String id) =>
    (corpus['cases'] as List).cast<Map<String, dynamic>>().firstWhere(
      (entry) => entry['id'] == id,
    );

Map<String, dynamic> _corpusBlock(Map<String, dynamic> golden) =>
    golden['corpus'] as Map<String, dynamic>;

List<Map<String, dynamic>> _observations(Map<String, dynamic> golden) =>
    (golden['observations'] as List).cast<Map<String, dynamic>>();

Map<String, dynamic> _row(Map<String, dynamic> golden, String id) =>
    _observations(golden).firstWhere((row) => row['id'] == id);

/// The actual producer envelope: family metadata nested under `corpus` and a
/// measured raw asset binding, with source-derived expected values as values.
/// The fingerprint names this record as a synthetic protocol control.
Map<String, dynamic> _producerGolden() {
  final corpus = _listCorpus();
  final bytes = File(gate.htmlListCorpusPath).readAsBytesSync();
  return {
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'fingerprint': 'synthetic-protocol-control-not-device-evidence',
    'corpus': {
      'asset': 'html-fixtures.json',
      'bytes': bytes.length,
      'sha256': _sha256Bytes(bytes),
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'schemaVersion': corpus['schemaVersion'],
    },
    'observations': [
      for (final row in (corpus['cases'] as List).cast<Map>())
        {'id': row['id'], 'value': row['expected']},
    ],
  };
}

/// The actual producer envelope plus the old top-level family fields: a
/// positive control that keeps both the nested and the hybrid shapes admissible.
Map<String, dynamic> _hybridGolden() => _clone(_producerGolden())
  ..['fixtureId'] = gate.htmlListFixtureId
  ..['corpusVersion'] = gate.htmlListCorpusVersion;

String _writeJson(String name, Object value) {
  final file = File(
    '${_scratch.path}/synthetic-control-${_serial++}-$name.json',
  );
  file.writeAsStringSync(jsonEncode(value));
  return file.path;
}

String _writeBytes(String name, List<int> bytes) {
  final file = File(
    '${_scratch.path}/synthetic-control-${_serial++}-$name.json',
  );
  file.writeAsBytesSync(bytes);
  return file.path;
}

Map<String, Object?> _observedById(Map<String, Object?> report) => {
  for (final item in (report['observations'] as List).cast<Map>())
    item['id'] as String: item.containsKey('value')
        ? item['value']
        : item['error'],
};

String _sha256File(File file) => _sha256Bytes(file.readAsBytesSync());

String _sha256Bytes(List<int> bytes) => SHA256Digest()
    .process(Uint8List.fromList(bytes))
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
