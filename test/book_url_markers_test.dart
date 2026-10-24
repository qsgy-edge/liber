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

  test('FIELDS-02 reaches its four real paths and empty terminal', () async {
    final result = await runBookUrlMarkersCorpus(fixture: _fixture());

    expect(result.scenarioPassed, isTrue);
    expect(result.caseFailures, isEmpty);
    expect(result.unmatched, isEmpty);
    expect(result.caseRecords.map((record) => record['id']), [
      'html-pattern-redirect-markers',
      'json-pattern-nonmatch-list',
      'json-no-pattern-empty-fallback',
      'json-pattern-empty-terminal',
    ]);
    expect(result.requests, hasLength(14));

    final a = result.caseRecords[0];
    final aSearch = (a['search'] as Map)['results'] as List;
    expect((aSearch.single as Map)['bookUrl'], '$_origin/a/detail/73');
    expect((aSearch.single as Map)['infoHtml'], isFalse);
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
    expect(receipt['redirect'], '/a/detail/73');
  });

  test('the FIELDS-02 comparator admits an equal synthetic record', () {
    final caseRecord = _syntheticCase();
    final corpus = _syntheticCorpus();
    final corpusSha = 'a' * 64;
    final golden = _syntheticEnvelope(corpus, caseRecord, corpusSha);
    final liber = _syntheticProduct(corpus, caseRecord, corpusSha);
    final report = compareBookUrlMarkers(
      golden: golden,
      liber: liber,
      goldenPath: 'synthetic-golden.json',
      liberPath: 'synthetic-liber.json',
      corpus: corpus,
      corpusSha256: corpusSha,
    );
    expect(report['status'], 'pass');
    expect(report['notCompared'], isEmpty);
  });

  test('the FIELDS-02 comparator refuses damaged input and observations', () {
    final corpus = _syntheticCorpus();
    final corpusSha = 'a' * 64;
    final positive = _syntheticCase();
    _syntheticChapters({
      'cases': [positive],
    });
    final base = _syntheticEnvelope(corpus, positive, corpusSha);
    final product = _syntheticProduct(corpus, positive, corpusSha);

    final controls = <String, void Function(Map<String, dynamic>)>{
      'wrong marker': (g) => _syntheticChapters(g)[0]['isVip'] = true,
      'wrong tag': (g) => _syntheticChapters(g)[0]['tag'] = 'wrong',
      'wrong raw address': (g) => _syntheticChapters(g)[0]['url'] = '/wrong',
      'wrong absolute target': (g) =>
          _syntheticChapters(g)[0]['absoluteUrl'] = 'http://wrong.test/c',
      'wrong stage': (g) => _syntheticRecord(g)['bookInfo'] = null,
      'wrong terminal': (g) => g['terminal'] = 'search-empty',
      'wrong probe': (g) =>
          (_syntheticRecord(g)['sourceProbes'] as Map)['vipProbe'] = 'read',
    };
    for (final control in controls.entries) {
      final golden = _deepClone(base);
      control.value(golden);
      final report = compareBookUrlMarkers(
        golden: golden,
        liber: product,
        goldenPath: 'synthetic-golden.json',
        liberPath: 'synthetic-liber.json',
        corpus: corpus,
        corpusSha256: corpusSha,
      );
      expect(report['status'], 'fail', reason: control.key);
      expect(report['differences'], isNotEmpty, reason: control.key);
    }

    final malformed = <String, void Function(Map<String, dynamic>)>{
      'missing id': (g) => g['cases'] = <Object?>[],
      'duplicate id': (g) => g['cases'] = [_syntheticCase(), _syntheticCase()],
      'extra id': (g) => (g['cases'] as List).add({
        ..._syntheticCase(),
        'id': 'synthetic-extra',
      }),
      'wrong type': (g) => _syntheticChapters(g)[0]['isVip'] = 'true',
      'empty title': (g) => _syntheticChapters(g)[0]['title'] = '',
    };
    for (final control in malformed.entries) {
      final golden = _deepClone(base);
      control.value(golden);
      expect(
        () => compareBookUrlMarkers(
          golden: golden,
          liber: product,
          goldenPath: 'synthetic-golden.json',
          liberPath: 'synthetic-liber.json',
          corpus: corpus,
          corpusSha256: corpusSha,
        ),
        throwsA(isA<StateError>()),
        reason: control.key,
      );
    }

    final binding = _deepClone(base);
    (binding['corpus'] as Map)['sha256'] = 'b' * 64;
    expect(
      () => compareBookUrlMarkers(
        golden: binding,
        liber: product,
        goldenPath: 'synthetic-golden.json',
        liberPath: 'synthetic-liber.json',
        corpus: corpus,
        corpusSha256: corpusSha,
      ),
      throwsA(isA<StateError>()),
    );

    final cleanup = _deepClone(base);
    (cleanup['cleanup'] as Map)['serverClosed'] = false;
    expect(
      () => compareBookUrlMarkers(
        golden: cleanup,
        liber: product,
        goldenPath: 'synthetic-golden.json',
        liberPath: 'synthetic-liber.json',
        corpus: corpus,
        corpusSha256: corpusSha,
      ),
      throwsA(isA<StateError>()),
    );

    final unexpected = _deepClone(base);
    (unexpected['requests'] as List).add(_syntheticRequest('extra'));
    final report = compareBookUrlMarkers(
      golden: unexpected,
      liber: product,
      goldenPath: 'synthetic-golden.json',
      liberPath: 'synthetic-liber.json',
      corpus: corpus,
      corpusSha256: corpusSha,
    );
    expect(report['status'], 'fail');
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

Map<String, dynamic> _syntheticCorpus() => {
  'fixtureId': 'FIELDS-02',
  'corpusVersion': 1,
  'baselineCommit': 'synthetic-baseline',
  'entryPoint': 'synthetic-entry',
  'cases': [
    {'id': 'synthetic-case'},
  ],
};

Map<String, dynamic> _syntheticCase() => {
  'id': 'synthetic-case',
  'terminal': 'search-empty',
  'search': {'results': <Object?>[]},
  'bookInfo': null,
  'tableOfContents': null,
  'chapter': null,
  'sourceProbes': {'vipProbe': null, 'payProbe': null},
  'requests': <Object?>[],
};

Map<String, dynamic> _syntheticEnvelope(
  Map<String, dynamic> corpus,
  Map<String, dynamic> caseRecord,
  String corpusSha,
) => {
  'fixtureId': corpus['fixtureId'],
  'corpusVersion': corpus['corpusVersion'],
  'baselineCommit': corpus['baselineCommit'],
  'entryPoint': corpus['entryPoint'],
  'fingerprint': 'synthetic-test-only-not-device-evidence',
  'corpus': {
    'asset': 'field-fixtures.json',
    'bytes': 1,
    'sha256': corpusSha,
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
  },
  'isolation': {'bound': true, 'filesRouted': true, 'databaseRouted': true},
  'cleanup': {'serverClosed': true},
  'caseFailures': <String, Object?>{},
  'cases': [caseRecord],
  'requests': <Object?>[],
  'stageTrace': <Object?>[],
};

Map<String, dynamic> _syntheticProduct(
  Map<String, dynamic> corpus,
  Map<String, dynamic> caseRecord,
  String corpusSha,
) {
  final product = _syntheticEnvelope(corpus, caseRecord, corpusSha)
    ..remove('corpus')
    ..remove('fingerprint')
    ..remove('isolation')
    ..remove('cases');
  product['fixturesSha256'] = corpusSha;
  product['librarySha256'] = 'library';
  product['caseRecords'] = <Object?>[caseRecord];
  return product;
}

List<Map<String, dynamic>> _syntheticChapters(Map<String, dynamic> golden) {
  final record = (golden['cases'] as List).first as Map<String, dynamic>;
  if (record['terminal'] == 'four-stage') {
    return _chaptersOf(record);
  }
  record['terminal'] = 'four-stage';
  record['bookInfo'] = {
    'name': 'synthetic',
    'author': 'synthetic',
    'bookUrl': 'http://synthetic.test/book',
    'tocUrl': '/toc',
  };
  record['tableOfContents'] = {
    'tocUrl': '/toc',
    'chapters': [
      {
        'title': 'chapter',
        'url': '/c/1',
        'absoluteUrl': 'http://synthetic.test/c/1',
        'tag': 'tag',
        'isVolume': false,
        'isVip': false,
        'isPay': false,
        'address': '/c/1',
        'rawAddress': '/c/1',
        'storeKey': 'http://synthetic.test/c/1',
        'persistedAddress': 'http://synthetic.test/c/1',
      },
    ],
  };
  record['chapter'] = {'title': 'chapter', 'text': 'body'};
  return _chaptersOf(record);
}

Map<String, dynamic> _syntheticRecord(Map<String, dynamic> golden) =>
    (golden['cases'] as List).first as Map<String, dynamic>;

List<Map<String, dynamic>> _chaptersOf(Map<String, dynamic> record) =>
    ((record['tableOfContents'] as Map)['chapters'] as List)
        .cast<Map<String, dynamic>>();

Map<String, dynamic> _syntheticRequest(String path) => {
  'method': 'GET',
  'path': path,
  'rawQuery': '',
  'query': <String, String>{},
  'receipt': {'terminal': 'responded', 'status': 200, 'responseId': path},
};

Map<String, dynamic> _deepClone(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
