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
    'FIELDS-02 records the actual product and completes declared requests',
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
      expect(result.requests, hasLength(12));
      expect(result.scenarioPassed, isTrue);
      final requestInvariant = result.invariants.singleWhere(
        (invariant) => invariant.id == 'declared-request-sequence',
      );
      expect(requestInvariant.ok, isTrue);
      expect(
        requestInvariant.detail,
        contains('12 declared requests observed in order'),
      );

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
      expect((aChapters[2] as Map)['address'], '$_origin/a/toc/1');
      expect((aChapters[2] as Map)['url'], '$_origin/a/toc/1');
      expect((aChapters[2] as Map)['isVip'], isTrue);
      expect((aChapters[2] as Map)['isPay'], isTrue);
      expect(a['sourceProbes'], {'vipProbe': null, 'payProbe': null});
      expect(a['requests'], hasLength(4));

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
        '$_origin/c/search?keyword=回放&page=1',
      );
      expect(
        (c['bookInfo'] as Map)['bookUrl'],
        '$_origin/c/search?keyword=回放&page=1',
      );
      expect((c['tableOfContents'] as Map)['chapters'], hasLength(1));
      expect(
        ((c['tableOfContents'] as Map)['chapters'] as List).single['tag'],
        '',
      );
      expect(c['requests'], hasLength(3));
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

  test('an absent terminal is materialized as four-stage', () {
    final corpus = _syntheticCorpus();
    ((corpus['cases'] as List).first as Map).remove('terminal');
    final report = _compare(
      _syntheticEnvelope(corpus),
      _syntheticProduct(corpus),
      corpus,
    );
    expect(report['status'], 'pass');
  });

  test('chronological case ids cannot be swapped under a coherent set', () {
    final corpus = _twoCaseCorpus();
    final golden = _twoCaseGolden(corpus);
    final product = _twoCaseProduct(corpus);
    expect(_compare(golden, product, corpus)['status'], 'pass');
    final swappedGolden = _twoCaseGolden(corpus);
    final swappedProduct = _twoCaseProduct(corpus);
    final gCases = swappedGolden['cases'] as List;
    final pCases = swappedProduct['caseRecords'] as List;
    final firstG = (gCases[0] as Map)['id'];
    final firstP = (pCases[0] as Map)['id'];
    (gCases[0] as Map)['id'] = (gCases[1] as Map)['id'];
    (gCases[1] as Map)['id'] = firstG;
    (pCases[0] as Map)['id'] = (pCases[1] as Map)['id'];
    (pCases[1] as Map)['id'] = firstP;
    expect(
      () => _compare(swappedGolden, swappedProduct, corpus),
      throwsA(isA<StateError>()),
    );
  });

  test('repeated product URIs are matched forward within operations', () {
    final corpus = _repeatedUriCorpus();
    final golden = _repeatedUriEnvelope(corpus, product: false);
    final product = _repeatedUriEnvelope(corpus, product: true);
    final positive = _compare(golden, product, corpus);
    expect(
      positive['status'],
      'pass',
      reason: jsonEncode(positive['differences']),
    );
    final damaged = _repeatedUriEnvelope(corpus, product: true);
    ((damaged['stageTrace'] as List)[2] as Map)['path'] =
        'http://127.0.0.1:18733/wrong';
    final report = _compare(golden, damaged, corpus);
    expect(report['status'], 'fail');
    expect(
      (report['differences'] as List).cast<Map>().any(
        (row) =>
            row['field'] == 'liber.trace[2].path' &&
            row['frozen'] == 'forward request context',
      ),
      isTrue,
    );
  });

  test('selected native admission refuses missing guarded runtime proof', () {
    final corpus = _syntheticCorpus()
      ..['baselineCommit'] = 'a7d37f1707a70a459ad708f4fe79341d1e42d716';
    final golden = _syntheticEnvelope(corpus);
    expect(
      () => _compare(golden, _syntheticProduct(corpus), corpus),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('selected native runtime'),
        ),
      ),
    );
  });

  test('selected native admission refuses missing raw device evidence', () {
    final corpus = _syntheticCorpus()
      ..['baselineCommit'] = 'a7d37f1707a70a459ad708f4fe79341d1e42d716'
      ..['hostInitialization'] = {
        'method': 'test-init',
        'registrations': <Object>[],
      };
    final golden = _syntheticEnvelope(corpus);
    golden['startupContainment'] = {
      'service': 'shortcut',
      'provider': 'io.legado.app.api.ReaderProvider',
      'intercepted': 1,
      'handled': 1,
      'beforeBinding': true,
    };
    (golden['isolation'] as Map)['appClass'] =
        'io.liber.oracle.nested.GuardedReaderApplication';
    golden['hostInitialization'] = {
      'verified': true,
      'applicationAttached': false,
      'invokedOn': 'unattached-instance',
      'notRun': ['io.legado.app.App.onCreate'],
      'method': 'test-init',
      'registeredWrappers': <String, String>{},
    };
    golden['terminalOwner'] = {
      'scope': 'Coroutine.DEFAULT',
      'rootActive': true,
      'rootCompleted': false,
      'baselineChildren': 0,
      'childrenMethod': 'kotlinx.coroutines.Job.getChildren()',
      'completionMethod': 'kotlinx.coroutines.Job.isCompleted()',
    };
    const prefix =
        'public final java.lang.Object io.legado.app.model.webBook.WebBook.';
    golden['entryPoints'] = {
      'searchBookAwait':
          '${prefix}searchBookAwait(io.legado.app.data.entities.BookSource,java.lang.String,java.lang.Integer,kotlin.jvm.functions.Function3,kotlin.jvm.functions.Function1,kotlin.coroutines.Continuation)',
      'getBookInfoAwait':
          '${prefix}getBookInfoAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,kotlin.coroutines.Continuation)',
      'getChapterListAwait':
          '${prefix}getChapterListAwait-yxL6bBk(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,boolean,kotlin.coroutines.Continuation)',
      'getContentAwait':
          '${prefix}getContentAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,kotlin.coroutines.Continuation)',
    };
    for (final value in golden['cases'] as List) {
      (value as Map)['terminalOwner'] = {
        'owner': 'Coroutine.DEFAULT Job',
        'observedChildren': 0,
        'allCompleted': true,
        'rootEmpty': true,
        'launchAttempts': 0,
      };
    }
    golden['cleanup'] = {
      ...(golden['cleanup'] as Map<String, dynamic>),
      'openConnectionsAfterClose': 0,
      'databaseClosed': true,
      'activityLaunchAttempts': 0,
    };
    final manifest = _syntheticManifest(corpus)..['serial'] = '5615f742';
    expect(
      () => _compare(
        golden,
        _syntheticProduct(corpus),
        corpus,
        externalManifest: manifest,
      ),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          contains('selected native evidence missing'),
        ),
      ),
    );
  });

  test('the FIELDS-02 comparator admits a valid complete baseline', () {
    final corpus = _syntheticCorpus();
    final golden = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);
    final report = _compare(golden, product, corpus);
    expect(report['status'], 'pass');
    expect(report['notCompared'], isEmpty);
  });

  test(
    'FIELDS-02 compares complete seven-source provenance with the manifest',
    () {
      final corpus = _syntheticCorpus();
      final provenance = _syntheticProvenance();
      (provenance['sources'] as Map<String, String>).addAll(<String, String>{
        'HostRuntimeInit.java': 'd' * 64,
        'ShortcutStartupGuard.java': 'e' * 64,
      });
      final manifest = _syntheticManifest(corpus);
      (manifest['artifact'] as Map)['provenance'] = _clone(provenance);
      manifest['harnessSources'] = _clone(
        provenance['sources'] as Map<String, dynamic>,
      );
      expect(
        _compare(
          _syntheticEnvelope(corpus),
          _syntheticProduct(corpus),
          corpus,
          externalManifest: manifest,
          expectedProvenance: provenance,
        )['status'],
        'pass',
      );
      for (final name in [
        'HostRuntimeInit.java',
        'ShortcutStartupGuard.java',
      ]) {
        final changed = _clone(manifest);
        (changed['harnessSources'] as Map)[name] = 'f' * 64;
        expect(
          () => _compare(
            _syntheticEnvelope(corpus),
            _syntheticProduct(corpus),
            corpus,
            externalManifest: changed,
            expectedProvenance: provenance,
          ),
          throwsA(isA<StateError>()),
        );
        final changedArtifact = _clone(manifest);
        (((changedArtifact['artifact'] as Map)['provenance'] as Map)['sources']
                as Map)[name] =
            'f' * 64;
        expect(
          () => _compare(
            _syntheticEnvelope(corpus),
            _syntheticProduct(corpus),
            corpus,
            externalManifest: changedArtifact,
            expectedProvenance: provenance,
          ),
          throwsA(isA<StateError>()),
        );
      }
    },
  );

  test('actual Android preference punctuation is admitted coherently', () {
    const names = [
      'liber_fields_02_FirebasePerfSharedPrefs',
      'liber_fields_02_probe',
      'liber_fields_02_FirebaseHeartBeatW0RFRkFVTFRd+MTo0NTMzOTIyNzQ3OTA6YW5kcm9pZDpjNGVhYzE0YjE0MTBlZWM1ZjYyNGE3',
      'liber_fields_02_frc_1:453392274790:android:c4eac14b1410eec5f624a7_firebase_settings',
      'liber_fields_02_com.google.android.gms.measurement.prefs',
      'liber_fields_02_io.legado.app.debug_preferences',
      'liber_fields_02_com.google.android.gms.appid',
    ];
    final corpus = _syntheticCorpus();
    final golden = _syntheticEnvelope(corpus);
    final manifest = _syntheticManifest(corpus);
    (golden['cleanup'] as Map)['ownedPreferences'] = names;
    (manifest['scratchOwner'] as Map)['preferences'] = names;
    (manifest['scratchCleanup'] as Map)['reportedOwnedPreferences'] = names;
    final report = _compare(
      golden,
      _syntheticProduct(corpus),
      corpus,
      externalManifest: manifest,
    );
    expect(report['status'], 'pass');

    final invalid = [...names]
      ..[2] = 'liber_fields_02_FirebaseHeartBeat+/bad/name';
    final badGolden = _clone(golden);
    final badManifest = _clone(manifest);
    (badGolden['cleanup'] as Map)['ownedPreferences'] = invalid;
    (badManifest['scratchOwner'] as Map)['preferences'] = invalid;
    (badManifest['scratchCleanup'] as Map)['reportedOwnedPreferences'] =
        invalid;
    expect(
      () => _compare(
        badGolden,
        _syntheticProduct(corpus),
        corpus,
        externalManifest: badManifest,
      ),
      throwsA(isA<StateError>()),
    );
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
          ((changed['stageTrace'] as List).first as Map)['path'] =
              'http://127.0.0.1:18733/s?different=bytes';
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
  Map<String, dynamic> corpus, {
  Map<String, dynamic>? externalManifest,
  Map<String, dynamic>? expectedProvenance,
}) => compareBookUrlMarkers(
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
  expectedProvenance: expectedProvenance ?? _syntheticProvenance(),
  expectedLibrarySha256: 'library',
  externalManifest: externalManifest ?? _syntheticManifest(corpus),
  expectedProductSources: const {'lib/source/test.dart': 'source-hash'},
);

Map<String, dynamic> _requestFooter(
  String path, {
  String responseId = 'r1',
  String method = 'GET',
}) => {
  'method': method,
  'path': path,
  'query': <String, String>{},
  'rawQuery': '',
  'stage': 'search',
  'headers': <String, Object?>{},
  'body': '',
  'receipt': {
    'terminal': 'responded',
    'status': 200,
    'responseId': responseId,
    'redirect': null,
    'send': 'completed',
  },
};

Map<String, dynamic> _twoCaseCorpus() {
  final corpus = _syntheticCorpus();
  final first = (corpus['cases'] as List).first as Map;
  corpus['cases'] = [
    first,
    {...first, 'id': 'synthetic-other'},
  ];
  corpus['expectedRequests'] = [
    {'method': 'GET', 'path': '/s', 'query': <String, String>{}},
    {'method': 'GET', 'path': '/s2', 'query': <String, String>{}},
  ];
  corpus['responses'] = [
    {'id': 'r1', 'method': 'GET', 'path': '/s', 'status': 200},
    {'id': 'r2', 'method': 'GET', 'path': '/s2', 'status': 200},
  ];
  return corpus;
}

Map<String, dynamic> _twoCaseExpansion(
  Map<String, dynamic> envelope, {
  required bool product,
}) {
  final first = _clone(
    product ? _record({'cases': envelope['caseRecords']}) : _record(envelope),
  );
  final second = _clone(first);
  second['id'] = 'synthetic-other';
  final ops = (second['operations'] as List).cast<Map<String, dynamic>>();
  for (final op in ops) {
    op['requestStart'] = (op['requestStart'] as int) + 1;
    op['requestEnd'] = (op['requestEnd'] as int) + 1;
    op['traceStart'] = (op['traceStart'] as int) + 1;
    op['traceEnd'] = (op['traceEnd'] as int) + 1;
  }
  second['requests'] = [_requestFooter('/s2', responseId: 'r2')];
  if (product) {
    envelope['caseRecords'] = [first, second];
  } else {
    envelope['cases'] = [first, second];
  }
  envelope['requests'] = [
    _requestFooter('/s'),
    _requestFooter('/s2', responseId: 'r2'),
  ];
  envelope['stageTrace'] = [
    {'stage': 'search', 'path': 'http://127.0.0.1:18733/s'},
    {'stage': 'search', 'path': 'http://127.0.0.1:18733/s2'},
  ];
  first['requests'] = [envelope['requests'][0]];
  second['requests'] = [envelope['requests'][1]];
  return envelope;
}

Map<String, dynamic> _twoCaseGolden(Map<String, dynamic> corpus) =>
    _twoCaseExpansion(_syntheticEnvelope(corpus), product: false);

Map<String, dynamic> _twoCaseProduct(Map<String, dynamic> corpus) =>
    _twoCaseExpansion(_syntheticProduct(corpus), product: true);

Map<String, dynamic> _repeatedUriCorpus() {
  final corpus = _syntheticCorpus();
  corpus['expectedRequests'] = [
    {'method': 'POST', 'path': '/a', 'query': <String, String>{}},
    {'method': 'GET', 'path': '/b', 'query': <String, String>{}},
    {'method': 'GET', 'path': '/a', 'query': <String, String>{}},
    {'method': 'GET', 'path': '/c', 'query': <String, String>{}},
  ];
  corpus['responses'] = [
    {'id': 'r1', 'method': 'POST', 'path': '/a', 'status': 200},
    {'id': 'r2', 'method': 'GET', 'path': '/b', 'status': 200},
    {'id': 'r3', 'method': 'GET', 'path': '/a', 'status': 200},
    {'id': 'r4', 'method': 'GET', 'path': '/c', 'status': 200},
  ];
  return corpus;
}

Map<String, dynamic> _repeatedUriEnvelope(
  Map<String, dynamic> corpus, {
  required bool product,
}) {
  final envelope = product
      ? _syntheticProduct(corpus)
      : _syntheticEnvelope(corpus);
  final record = _clone(
    _record(product ? {'cases': envelope['caseRecords']} : envelope),
  );
  record['requests'] = [
    _requestFooter('/a', responseId: 'r1', method: 'POST'),
    _requestFooter('/b', responseId: 'r2'),
    _requestFooter('/a', responseId: 'r3'),
    _requestFooter('/c', responseId: 'r4'),
  ];
  record['operations'] = [
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
      'requestEnd': 2,
      'traceStart': 1,
      'traceEnd': 2,
    },
    {
      'name': 'tableOfContents',
      'outcome': 'completed',
      'requestStart': 2,
      'requestEnd': 3,
      'traceStart': 2,
      'traceEnd': 3,
    },
    {
      'name': 'content',
      'outcome': 'completed',
      'requestStart': 3,
      'requestEnd': 4,
      'traceStart': 3,
      'traceEnd': 4,
    },
  ];
  final requests = record['requests'] as List;
  for (var index = 0; index < requests.length; index++) {
    (requests[index] as Map)['stage'] = [
      'search',
      'bookInfo',
      'tableOfContents',
      'content',
    ][index];
  }
  final trace = [
    for (var index = 0; index < requests.length; index++)
      {
        'stage': ['search', 'bookInfo', 'tableOfContents', 'content'][index],
        'path': 'http://127.0.0.1:18733${(requests[index] as Map)['path']}',
      },
  ];
  if (product) {
    envelope['caseRecords'] = [record];
  } else {
    envelope['cases'] = [record];
  }
  envelope['requests'] = requests;
  envelope['stageTrace'] = trace;
  return envelope;
}

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
