import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

import '../tool/result_field_compare.dart';
import '../tool/result_field_runner.dart';
import 'native_library.dart';

const _fixturePath = 'tool/result_field_oracle/book-url-markers-fixtures.json';
const _origin = 'http://127.0.0.1:18733';

Map<String, dynamic> _fixture() => loadResultFieldFixture(_fixturePath);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'FIELDS-02 records the actual product and its declared-request failure',
    () async {
      final result = await runBookUrlMarkersCorpus(fixture: _fixture());

      expect(result.caseFailures, isEmpty);
      expect(result.unmatched, isEmpty);
      expect(result.serverErrors, isEmpty);
      expect(result.caseRecords.map((record) => record['id']), [
        'html-pattern-redirect-markers',
        'json-pattern-nonmatch-list',
        'json-no-pattern-empty-fallback',
        'json-pattern-empty-terminal',
      ]);
      expect(result.requests, hasLength(14));
      expect(result.scenarioPassed, isFalse);
      final requestInvariant = result.invariants.singleWhere(
        (invariant) => invariant.id == 'declared-request-sequence',
      );
      expect(requestInvariant.ok, isFalse);
      expect(requestInvariant.detail, contains('declared 12, observed 14'));

      final a = result.caseRecords[0];
      final aSearch = (a['search'] as Map)['results'] as List;
      expect((aSearch.single as Map)['bookUrl'], '$_origin/a/detail/73');
      expect((aSearch.single as Map).containsKey('infoHtml'), isFalse);
      expect((a['bookInfo'] as Map)['bookUrl'], '$_origin/a/detail/73');
      final aChapters = (a['tableOfContents'] as Map)['chapters'] as List;
      expect(aChapters, hasLength(3));
      expect((aChapters[0] as Map)['address'], '/a/c/1');
      expect((aChapters[0] as Map)['url'], '$_origin/a/c/1');
      expect((aChapters[0] as Map)['tag'], '2026-01-01');
      expect((aChapters[0] as Map)['isVolume'], isFalse);
      expect((aChapters[0] as Map)['isVip'], isTrue);
      expect((aChapters[0] as Map)['isPay'], isFalse);
      expect((aChapters[1] as Map)['address'], '第一卷1');
      expect((aChapters[1] as Map)['url'], '$_origin/a/toc/1');
      expect((aChapters[1] as Map)['isVolume'], isTrue);
      expect((aChapters[2] as Map)['address'], '/a/toc/1');
      expect((aChapters[2] as Map)['url'], '$_origin/a/toc/1');
      expect((aChapters[2] as Map)['isVip'], isTrue);
      expect((aChapters[2] as Map)['isPay'], isTrue);
      expect(a['sourceProbes'], {'vipProbe': null, 'payProbe': null});
      expect(a['requests'], hasLength(5));

      final b = result.caseRecords[1];
      expect(
        ((b['search'] as Map)['results'] as List).single['bookUrl'],
        '$_origin/b/book/1',
      );
      expect((b['bookInfo'] as Map)['name'], '列表书');
      expect((b['tableOfContents'] as Map)['chapters'], hasLength(3));
      expect(b['requests'], hasLength(4));
      expect(b['sourceProbes'], {'vipProbe': null, 'payProbe': null});

      final c = result.caseRecords[2];
      expect(
        ((c['search'] as Map)['results'] as List).single['bookUrl'],
        '$_origin/c/search?keyword=%E5%9B%9E%E6%94%BE&page=1',
      );
      expect(
        (c['bookInfo'] as Map)['bookUrl'],
        '$_origin/c/search?keyword=%E5%9B%9E%E6%94%BE&page=1',
      );
      expect((c['tableOfContents'] as Map)['chapters'], hasLength(1));
      expect(
        ((c['tableOfContents'] as Map)['chapters'] as List).single['tag'],
        isNull,
      );
      expect(c['requests'], hasLength(4));
      expect(c['sourceProbes'], {'vipProbe': null, 'payProbe': null});

      final d = result.caseRecords[3];
      expect(((d['search'] as Map)['results'] as List), isEmpty);
      expect(d['bookInfo'], isNull);
      expect(d['tableOfContents'], isNull);
      expect(d['chapter'], isNull);
      expect(d['requests'], hasLength(1));
      expect(d['sourceProbes'], {'vipProbe': null, 'payProbe': null});

      final receipt = (result.requests.first as Map)['receipt'] as Map;
      expect(receipt['status'], 302);
      expect(receipt['send'], 'completed');
      expect(receipt['redirect'], '/a/detail/73');
    },
  );

  test('a failed awaited operation retains its partial error facts', () async {
    final fixture = jsonDecode(jsonEncode(_fixture())) as Map<String, dynamic>;
    final first = ((fixture['cases'] as List).first as Map)
        .cast<String, dynamic>();
    (first['source'] as Map)['searchUrl'] =
        "@js: throw new Error('FAILED_SEARCH_MARKER')";
    fixture['cases'] = [first];
    final result = await runBookUrlMarkersCorpus(fixture: fixture);
    final id = first['id'] as String;
    expect(result.caseFailures.keys, contains(id));
    expect(result.caseFailures[id], contains('FAILED_SEARCH_MARKER'));
    final failed = result.caseRecords.singleWhere(
      (record) => record['id'] == id,
    );
    expect(failed['failure'], contains('FAILED_SEARCH_MARKER'));
    final operations = (failed['operations'] as List).cast<Map>();
    expect(operations, hasLength(1));
    expect(operations.single['name'], 'search');
    expect(operations.single['outcome'], 'error');
    expect(operations.single['error'], contains('FAILED_SEARCH_MARKER'));
    expect(operations.single['requestStart'], 0);
    expect(operations.single['requestEnd'], 0);
    expect(operations.single['traceStart'], 0);
    expect(operations.single['traceEnd'], 0);
    expect(failed['requests'], isEmpty);
    expect(result.requests, isEmpty);
  });

  test('the FIELDS-02 comparator admits a valid complete baseline', () {
    final corpus = _syntheticCorpus();
    final golden = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);
    final report = _compare(golden, product, corpus);
    expect(report['status'], 'pass');
    expect(report['notCompared'], isEmpty);
  });

  test('the comparator changes only its targeted C1 field', () {
    final corpus = _syntheticCorpus();
    final base = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);
    expect(_compare(base, product, corpus)['status'], 'pass');

    final controls = <String, String>{
      'isVip': 'chapters[0].isVip',
      'tag': 'chapters[0].tag',
      'raw address': 'chapters[0].url(raw vs address)',
      'absolute target': 'chapters[0].absoluteUrl(vs url)',
      'vip probe': 'sourceProbes.vipProbe',
      'raw query bytes': 'golden.requests[0].rawQuery',
    };
    for (final entry in controls.entries) {
      final changed = _clone(base);
      final chapter = _chapters(changed)[0];
      switch (entry.key) {
        case 'isVip':
          chapter['isVip'] = true;
        case 'tag':
          chapter['tag'] = 'wrong';
        case 'raw address':
          chapter['url'] = '/wrong';
        case 'absolute target':
          chapter['absoluteUrl'] = 'http://wrong.test/c';
        case 'vip probe':
          (_record(changed)['sourceProbes'] as Map)['vipProbe'] = 'read';
        case 'raw query bytes':
          ((changed['requests'] as List).first as Map)['rawQuery'] =
              'different=bytes';
          _request(changed)['rawQuery'] = 'different=bytes';
      }
      final report = _compare(changed, product, corpus);
      expect(report['status'], 'fail', reason: entry.key);
      expect(
        (report['differences'] as List).map((item) => item['field']),
        contains(entry.value),
        reason: entry.key,
      );
    }
  });

  test('the comparator refuses malformed/incomplete observations', () {
    final corpus = _syntheticCorpus();
    final base = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);

    final structural = <String, void Function(Map<String, dynamic>)>{
      'missing case id': (g) => g['cases'] = <Object?>[],
      'duplicate case id': (g) => (g['cases'] as List).add(_case()),
      'extra case id': (g) =>
          (g['cases'] as List).add({..._case(), 'id': 'extra'}),
      'wrong case terminal': (g) => _record(g)['terminal'] = 'search-empty',
      'missing information stage': (g) => _record(g)['bookInfo'] = null,
      'missing toc stage': (g) => _record(g)['tableOfContents'] = null,
      'missing tag key': (g) => _chapters(g)[0].remove('tag'),
      'wrong marker type': (g) => _chapters(g)[0]['isVip'] = 'true',
      'empty title': (g) => _chapters(g)[0]['title'] = '',
      'missing request receipt': (g) => _request(g).remove('receipt'),
      'truncated stage trace': (g) => g['stageTrace'] = <Object?>[],
      'request assigned to wrong case': (g) =>
          _record(g)['requests'] = [_requestJson('/wrong')],
      'legal wrong operation trace stage': (g) =>
          ((g['stageTrace'] as List).first as Map)['stage'] = 'bookInfo',
      'operation outcome error': (g) =>
          (((_record(g)['operations'] as List).first) as Map)['outcome'] =
              'error',
      'operation span outside producer': (g) =>
          (((_record(g)['operations'] as List).first) as Map)['requestEnd'] =
              99,
      'missing operation facts': (g) => _record(g).remove('operations'),
    };
    for (final entry in structural.entries) {
      final changed = _clone(base);
      entry.value(changed);
      expect(
        () => _compare(changed, product, corpus),
        throwsA(isA<StateError>()),
        reason: entry.key,
      );
    }

    final binding = _clone(base);
    (binding['corpus'] as Map)['sha256'] = 'b' * 64;
    expect(
      () => _compare(binding, product, corpus),
      throwsA(isA<StateError>()),
    );

    final cleanup = _clone(base);
    (cleanup['cleanup'] as Map)['serverClosed'] = false;
    expect(
      () => _compare(cleanup, product, corpus),
      throwsA(isA<StateError>()),
    );

    final unexpected = _clone(base);
    (unexpected['requests'] as List).add(_requestJson('/extra'));
    expect(
      () => _compare(unexpected, product, corpus),
      throwsA(isA<StateError>()),
    );
  });

  test('the legacy FIELDS-01 corpus and golden remain present', () {
    expect(File('tool/result_field_oracle/fixtures.json').existsSync(), isTrue);
    expect(
      File(
        'tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json',
      ).existsSync(),
      isTrue,
    );
  });
}

Map<String, dynamic> _compare(
  Map<String, dynamic> golden,
  Map<String, dynamic> product,
  Map<String, dynamic> corpus,
) => compareBookUrlMarkers(
  golden: golden,
  liber: product,
  goldenPath: 'synthetic-golden.json',
  liberPath: 'synthetic-liber.json',
  corpus: corpus,
  corpusSha256: 'a' * 64,
  corpusSha256Lf: 'a' * 64,
  corpusByteCount: 123,
  expectedHarnessApkSha256: 'harness',
  expectedHarnessAssetSha256: 'a' * 64,
  expectedProvenanceSha256: 'b' * 64,
  expectedProvenance: _syntheticProvenance(),
  expectedLibrarySha256: 'library',
  externalManifest: _syntheticManifest(corpus),
  expectedProductSources: const {'lib/source/test.dart': 'source-hash'},
);

Map<String, dynamic> _syntheticCorpus() => {
  'fixtureId': 'FIELDS-02',
  'corpusVersion': 1,
  'baselineCommit': 'synthetic-baseline',
  'entryPoint': 'synthetic-entry',
  'origin': 'http://127.0.0.1:18733',
  'target': {
    'package': 'io.legado.app.debug',
    'apkSha256': 'target-apk',
    'deviceFingerprint': 'synthetic-fingerprint',
  },
  'cases': [
    {
      'id': 'synthetic-case',
      'terminal': 'four-stage',
      'keyword': 'k',
      'source': <String, Object?>{},
    },
  ],
  'expectedRequests': [
    {'method': 'GET', 'path': '/s', 'query': <String, String>{}},
  ],
  'responses': [
    {
      'id': 'r1',
      'method': 'GET',
      'path': '/s',
      'status': 200,
      'headers': <String, Object?>{},
      'body': '',
    },
  ],
};

Map<String, dynamic> _syntheticProvenance() => {
  'schemaVersion': 1,
  'fixtureId': 'FIELDS-02',
  'corpus': {
    'asset': 'field-fixtures.json',
    'bytes': 123,
    'sha256': 'a' * 64,
    'sha256Lf': 'a' * 64,
    'fixtureId': 'FIELDS-02',
    'corpusVersion': 1,
  },
  'sources': {
    'FieldOracle.java': 'c' * 64,
    'StateSessionOracle.java': 'c' * 64,
    'AndroidManifest.xml': 'c' * 64,
    'build.ps1': 'c' * 64,
    'capture.py': 'c' * 64,
  },
};

Map<String, dynamic> _syntheticManifest(Map<String, dynamic> corpus) {
  final provenance = _syntheticProvenance();
  return {
    'status': 'observed',
    'existingDataHashesUnchanged': true,
    'frozenAppDataUnchanged': true,
    'privateFileChanges': <String, Object?>{},
    'targetPrivateRoot': '/data/data/io.legado.app.debug',
    'corpus': {'bytes': 123, 'sha256': 'a' * 64, 'sha256Lf': 'a' * 64},
    'artifact': {
      'apkSha256': 'harness',
      'selectedAssetSha256': 'a' * 64,
      'selectedAssetSha256Lf': 'a' * 64,
      'selectedAssetBytes': 123,
      'provenanceSha256': 'b' * 64,
      'provenance': provenance,
    },
    'scratchCleanup': {
      'postStop': true,
      'rootAbsent': true,
      'ownedPreferencesAbsent': true,
      'root': '/data/data/io.legado.app.debug/cache/liber-fields-02',
      'ownerRunId': 'synthetic-run',
      'reportedOwnedPreferences': ['liber_fields_02_probe'],
    },
    'harnessSources': _syntheticProvenance()['sources'],
    'scratchOwner': {
      'fixtureId': 'FIELDS-02',
      'corpusVersion': 1,
      'targetPackage': 'io.legado.app.debug',
      'harnessPackage': 'io.liber.oracle.fields',
      'targetApkSha256': 'target-apk',
      'harnessApkSha256': 'harness',
      'corpusSha256Lf': 'a' * 64,
      'complete': true,
      'seedRunId': 'synthetic-run',
      'seedPid': 4242,
      'preferences': ['liber_fields_02_probe'],
    },
  };
}

Map<String, dynamic> _requestJson(String path) => {
  'method': 'GET',
  'path': path,
  'query': <String, String>{},
  'rawQuery': '',
  'stage': 'search',
  'receipt': {
    'terminal': 'responded',
    'status': 200,
    'responseId': 'r1',
    'redirect': null,
    'send': 'completed',
  },
};

Map<String, dynamic> _case() => {
  'id': 'synthetic-case',
  'terminal': 'four-stage',
  'search': {
    'results': [
      {
        'name': 'name',
        'author': 'author',
        'bookUrl': 'http://synthetic.test/book',
        'infoHtml': true,
      },
    ],
  },
  'bookInfo': {
    'name': 'name',
    'author': 'author',
    'bookUrl': 'http://synthetic.test/book',
    'tocUrl': '/toc',
  },
  'tableOfContents': {
    'tocUrl': '/toc',
    'chapters': [
      {
        'title': 'chapter',
        'url': '/c',
        'absoluteUrl': 'http://synthetic.test/c',
        'tag': null,
        'isVolume': false,
        'isVip': false,
        'isPay': false,
      },
    ],
  },
  'chapter': {'title': 'chapter', 'text': 'body'},
  'sourceProbes': {'vipProbe': null, 'payProbe': null},
  'operations': [
    {
      'name': 'search',
      'outcome': 'completed',
      'requestStart': 0,
      'requestEnd': 1,
      'traceStart': 0,
      'traceEnd': 1,
    },
    {
      'name': 'bookInfo',
      'outcome': 'completed',
      'requestStart': 1,
      'requestEnd': 1,
      'traceStart': 1,
      'traceEnd': 1,
    },
    {
      'name': 'tableOfContents',
      'outcome': 'completed',
      'requestStart': 1,
      'requestEnd': 1,
      'traceStart': 1,
      'traceEnd': 1,
    },
    {
      'name': 'content',
      'outcome': 'completed',
      'requestStart': 1,
      'requestEnd': 1,
      'traceStart': 1,
      'traceEnd': 1,
    },
  ],
  'requests': [_requestJson('/s')],
};

Map<String, dynamic> _syntheticEnvelope(Map<String, dynamic> corpus) => {
  'fixtureId': corpus['fixtureId'],
  'corpusVersion': corpus['corpusVersion'],
  'baselineCommit': corpus['baselineCommit'],
  'entryPoint': corpus['entryPoint'],
  'fingerprint': 'synthetic-fingerprint',
  'corpus': {
    'asset': 'field-fixtures.json',
    'bytes': 123,
    'sha256': 'a' * 64,
    'sha256Lf': 'a' * 64,
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
  },
  'isolation': {
    'bound': true,
    'filesRouted': true,
    'databaseRouted': true,
    'deviceProtected': false,
    'rootExistedAtStart': false,
    'targetPackage': 'io.legado.app.debug',
    'targetApkSha256': 'target-apk',
    'harnessPackage': 'io.liber.oracle.fields',
    'harnessApkSha256': 'harness',
    'corpusSha256Lf': 'a' * 64,
    'preferencesPrefix': 'liber_fields_02_',
    'scratchRoot': '/data/data/io.legado.app.debug/cache/liber-fields-02',
    'preferenceProbe': {
      'name': 'liber_fields_02_probe',
      'registered': true,
      'committed': true,
      'scopedFile': true,
      'installationFile': false,
    },
  },
  'cleanup': {
    'fixtureId': 'FIELDS-02',
    'corpusVersion': 1,
    'serverClosed': true,
    'ownerComplete': true,
    'rootRetained': true,
    'preferencesFenced': true,
    'ownerRunId': 'synthetic-run',
    'scratchRoot': '/data/data/io.legado.app.debug/cache/liber-fields-02',
    'reportPath':
        '/data/data/io.legado.app.debug/cache/liber-fields-02/field-oracle.json',
    'ownedPreferences': ['liber_fields_02_probe'],
  },
  'analysisFailure': null,
  'caseFailures': <String, Object?>{},
  'cases': [_case()],
  'requests': [_requestJson('/s')],
  'stageTrace': [
    {'stage': 'search', 'path': 'http://127.0.0.1:18733/s'},
  ],
  'unmatchedRequests': <Object?>[],
  'serverErrors': <Object?>[],
};

Map<String, dynamic> _syntheticProduct(Map<String, dynamic> corpus) => {
  'fixtureId': corpus['fixtureId'],
  'corpusVersion': corpus['corpusVersion'],
  'baselineCommit': corpus['baselineCommit'],
  'entryPoint': corpus['entryPoint'],
  'fixturesBytes': 123,
  'fixturesSha256': 'a' * 64,
  'fixturesSha256Lf': 'a' * 64,
  'fixturesPath': 'synthetic-fixture.json',
  'productSources': const {'lib/source/test.dart': 'source-hash'},
  'libraryPath': 'synthetic-fjs.dll',
  'librarySha256': 'library',
  'platform': 'windows',
  'oracle': 'not-run',
  'cleanup': {'serverClosed': true},
  'analysisFailure': null,
  'caseFailures': <String, Object?>{},
  'caseRecords': [
    {
      ..._case(),
      'search': {
        'results': [
          {
            'name': 'name',
            'author': 'author',
            'bookUrl': 'http://synthetic.test/book',
          },
        ],
      },
      'tableOfContents': {
        'tocUrl': '/toc',
        'chapters': [
          {
            'title': 'chapter',
            'url': 'http://synthetic.test/c',
            'address': '/c',
            'rawAddress': '/c',
            'storeKey': 'http://synthetic.test/c',
            'persistedAddress': 'http://synthetic.test/c',
            'tag': null,
            'isVolume': false,
            'isVip': false,
            'isPay': false,
          },
        ],
      },
    },
  ],
  'requests': [_requestJson('/s')],
  'stageTrace': [
    {'stage': 'search', 'path': 'http://127.0.0.1:18733/s'},
  ],
  'unmatchedRequests': <Object?>[],
  'serverErrors': <Object?>[],
};

Map<String, dynamic> _record(Map<String, dynamic> envelope) =>
    (envelope['cases'] as List).first as Map<String, dynamic>;

List<Map<String, dynamic>> _chapters(Map<String, dynamic> envelope) =>
    ((_record(envelope)['tableOfContents'] as Map)['chapters'] as List)
        .cast<Map<String, dynamic>>();

Map<String, dynamic> _request(Map<String, dynamic> envelope) =>
    (_record(envelope)['requests'] as List).first as Map<String, dynamic>;

Map<String, dynamic> _clone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
