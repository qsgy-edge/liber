import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../tool/html_adapter_gate.dart' as gate;
import 'native_library.dart';

/// The public boundary of the HTML capture: the committed `HTML-LIST-01` corpus
/// through `tool/html_adapter_gate.dart`, plus synthetic controls that mutate a
/// copy in the system temp directory. No control is a device golden.
void main() {
  late Directory scratch;

  setUpAll(() async {
    await NativeLibrary.initialize(libraryPath: nativeLibraryPath());
    scratch = Directory.systemTemp.createTempSync('liber-html-list-gate-');
  });
  tearDownAll(() {
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
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
      expect(report['corpusSha256'], _sha256(File(gate.htmlListCorpusPath)));
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
    expect(report['corpusSha256'], _sha256(File(gate.legacyHtmlCorpusPath)));
    expect(report['cases'], 45);
    expect(report['expectationMismatches'], isEmpty);
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
        final report = await gate.runHtmlAdapterGate(
          libraryPath: nativeLibraryPath(),
          corpusPath: _writeControl(scratch, 'value', corpus),
        );

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
        gate.runHtmlAdapterGate(
          libraryPath: nativeLibraryPath(),
          corpusPath: _writeControl(scratch, 'scalar-row', corpus),
        ),
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
        gate.runHtmlAdapterGate(
          libraryPath: nativeLibraryPath(),
          corpusPath: _writeControl(scratch, 'metadata', control.value()),
        ),
        throwsA(isA<FormatException>()),
        reason: control.key,
      );
    }
  });

  test(
    'a metadata-bearing golden must name exactly the declared ids',
    () async {
      final report = await gate.runHtmlAdapterGate(
        libraryPath: nativeLibraryPath(),
        corpusPath: gate.htmlListCorpusPath,
      );
      final observations = [
        for (final item in (report['observations'] as List).cast<Map>())
          {'id': item['id'], 'value': item['value']},
      ];
      Map<String, dynamic> golden(List<Map<String, Object?>> rows) => {
        'baselineCommit': gate.htmlOracleBaselineCommit,
        'entryPoint': gate.htmlOracleEntryPoint,
        'fixtureId': gate.htmlListFixtureId,
        'corpusVersion': gate.htmlListCorpusVersion,
        'observations': rows,
      };
      final controls = <String, List<Map<String, Object?>>>{
        'missing': observations.sublist(0, observations.length - 1),
        'duplicate': [
          ...observations.sublist(0, observations.length - 1),
          observations.first,
        ],
      };
      for (final control in controls.entries) {
        final file = File(
          '${scratch.path}/synthetic-control-golden-${control.key}.json',
        )..writeAsStringSync(jsonEncode(golden(control.value)));
        await expectLater(
          gate.runHtmlAdapterGate(
            libraryPath: nativeLibraryPath(),
            corpusPath: gate.htmlListCorpusPath,
            goldenPath: file.path,
          ),
          throwsA(isA<StateError>()),
          reason: control.key,
        );
      }
    },
  );

  test('the legacy golden is refused by the list family identity', () async {
    await expectLater(
      gate.runHtmlAdapterGate(
        libraryPath: nativeLibraryPath(),
        corpusPath: gate.htmlListCorpusPath,
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
    final report = await gate.runHtmlAdapterGate(
      libraryPath: nativeLibraryPath(),
      corpusPath: _writeControl(scratch, 'url-nonempty', corpus),
    );

    expect(report['status'], 'fail');
    final row = (report['observations'] as List)
        .cast<Map<String, dynamic>>()
        .firstWhere((item) => item['id'] == 'html-list-url-empty');
    expect(row['error'], contains('named product refusal'));
    expect(row.containsKey('value'), isFalse);
  });
}

Map<String, dynamic> _listCorpus() =>
    jsonDecode(File(gate.htmlListCorpusPath).readAsStringSync())
        as Map<String, dynamic>;

Map<String, dynamic> _case(Map<String, dynamic> corpus, String id) =>
    (corpus['cases'] as List).cast<Map<String, dynamic>>().firstWhere(
      (entry) => entry['id'] == id,
    );

String _writeControl(
  Directory scratch,
  String name,
  Map<String, dynamic> corpus,
) {
  final file = File(
    '${scratch.path}/synthetic-control-$name-${corpus['cases'].hashCode}.json',
  );
  file.writeAsStringSync(jsonEncode(corpus));
  return file.path;
}

Map<String, Object?> _observedById(Map<String, Object?> report) => {
  for (final item in (report['observations'] as List).cast<Map>())
    item['id'] as String: item.containsKey('value')
        ? item['value']
        : item['error'],
};

String _sha256(File file) => SHA256Digest()
    .process(file.readAsBytesSync())
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
