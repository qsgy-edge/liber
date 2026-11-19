import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

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

  test(
    'reader follow-through corpus records three cases and fourteen GETs',
    () async {
      final result = await runBookUrlMarkersCorpus(
        fixture: loadResultFieldFixture(
          'tool/result_field_oracle/reader-followthrough-fixtures-selected.json',
        ),
      );

      expect(result.caseFailures, isEmpty);
      expect(result.unmatched, isEmpty);
      expect(result.serverErrors, isEmpty);
      expect(result.caseRecords.map((record) => record['id']), [
        'html-body-replace-title-order',
        'json-body-title-order',
        'html-order-control',
      ]);
      expect(result.requests, hasLength(14));
      expect(result.scenarioPassed, isTrue);
      expect(
        result.invariants
            .singleWhere(
              (invariant) => invariant.id == 'declared-request-sequence',
            )
            .detail,
        contains('14 declared requests observed in order'),
      );

      for (final record in result.caseRecords) {
        final search = ((record['search'] as Map)['results'] as List).single;
        final bookInfo = record['bookInfo'] as Map;
        expect(search['intro'], isA<String>());
        expect(bookInfo['intro'], isA<String>());
      }

      final html = result.caseRecords[0];
      final htmlSearch = ((html['search'] as Map)['results'] as List).single;
      final htmlInfo = html['bookInfo'] as Map;
      expect(htmlInfo['intro'], htmlSearch['intro']);
      expect(html['chapter'], isA<Map>());
      expect((html['chapter'] as Map)['title'], contains('第一页标题'));
      expect((html['chapter'] as Map)['title'], isNot(contains('第二页标题')));
      expect((html['chapter'] as Map)['text'], contains('HTML BODY'));
      expect((html['chapter'] as Map)['text'], contains('HTML PAGE2'));
      expect(html['requests'], hasLength(5));

      final json = result.caseRecords[1];
      final jsonSearch = ((json['search'] as Map)['results'] as List).single;
      final jsonInfo = json['bookInfo'] as Map;
      expect(jsonInfo['intro'], jsonSearch['intro']);
      expect((json['chapter'] as Map)['title'], contains('第一页标题'));
      expect((json['chapter'] as Map)['title'], isNot(contains('第二页标题')));
      expect((json['chapter'] as Map)['text'], contains('JSON BODY'));
      expect((json['chapter'] as Map)['text'], contains('JSON PAGE2'));
      expect(json['requests'], hasLength(5));

      final control = result.caseRecords[2];
      expect((control['chapter'] as Map)['title'], '控制标题');
      expect((control['chapter'] as Map)['text'], contains('CONTROL BODY'));
      expect((control['chapter'] as Map)['text'], contains('SECOND'));
      expect(control['requests'], hasLength(4));
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
}
