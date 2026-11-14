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

  test('declared raw query bytes remain distinct from decoded query', () {
    final corpus = _syntheticCorpus();
    ((corpus['expectedRequests'] as List).first as Map)
      ..['query'] = {'q': '��'}
      ..['rawQuery'] = 'q=%D6%D0';
    final golden = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);
    for (final envelope in [golden, product]) {
      final records =
          (envelope[envelope == golden ? 'cases' : 'caseRecords'] as List);
      for (final request in [
        (envelope['requests'] as List).first as Map,
        ((records.first as Map)['requests'] as List).first as Map,
      ]) {
        request['query'] = {'q': '��'};
        request['rawQuery'] = 'q=%D6%D0';
      }
      ((envelope['stageTrace'] as List).first as Map)['path'] =
          'http://127.0.0.1:18733/s?q=%D6%D0';
    }
    expect(_compare(golden, product, corpus)['status'], 'pass');
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

  group('title lifecycle public consumer', () {
    // The four phase arrays are shared with the product; the native proof is
    // producer evidence and must never be required of the product. These run
    // through the real public comparator, not a copied one.
    const book = 'http://synthetic.test/book';
    const chapter = '/c';

    List<Map<String, Object?>> rows() => [
      {'index': 0, 'title': 'CHAPTER ONE', 'variable': 'toc-a'},
      {'index': 1, 'title': 'CHAPTER TWO', 'variable': 'toc-b'},
    ];

    Map<String, Object?> terminal() => {
      'events': 1,
      'duplicates': 0,
      'foreignEvents': 0,
      'callbackErrors': 0,
      'offMainEvents': 0,
      'malformedEvents': 0,
      'lastEvent': {'bookUrl': book, 'chapterUrl': chapter, 'correlates': true},
      'removal': {
        'interface': 'com.jeremyliao.liveeventbus.core.Observable',
        'declaringClass': 'com.jeremyliao.liveeventbus.core.Observable',
        'onMain': true,
        'removed': true,
      },
    };

    Map<String, Object?> proof({
      bool previousPresent = true,
      bool previous = true,
      bool observedAfter = true,
    }) {
      final event = terminal();
      return {
        'bookParent': {'bookUrl': book, 'stored': true, 'readBack': true},
        'chapterSeed': {'rows': 2, 'inserted': true},
        'saveObserver': {
          'tag': 'saveContent',
          'interface': 'com.jeremyliao.liveeventbus.core.Observable',
          'declaringClass': 'com.jeremyliao.liveeventbus.core.Observable',
          'onMain': true,
          'registered': true,
        },
        'tocCountWordsApplied': {
          'name': 'tocCountWords',
          'applied': true,
          'committed': true,
          'observed': true,
        },
        'saveEvent': event,
        'contentFiles': ['00000-abc.nb'],
        'saveObserverClose': {
          ...(jsonDecode(jsonEncode(event)) as Map<String, Object?>),
          'alreadyClosed': true,
          'removed': true,
        },
        'tocCountWords': {
          'previousPresent': previousPresent,
          'previous': previous,
          'committed': true,
          'presentAfter': previousPresent,
          'observedAfter': observedAfter,
          'restored': true,
        },
      };
    }

    Map<String, Object?> lifecycle() => {
      'beforeContent': rows(),
      'storedAfterContent': rows(),
      'refreshedChapters': rows(),
      'storedAfterRefresh': rows(),
    };

    Map<String, dynamic> corpus({
      String terminal = 'four-stage-refresh',
      int requestCount = 5,
    }) {
      final base = _syntheticCorpus();
      base['cases'] = [
        {
          'id': 'synthetic-case',
          'terminal': terminal,
          'keyword': 'k',
          'source': <String, Object?>{},
        },
      ];
      final paths = ['/a', '/b', '/c', '/d', '/e'].take(requestCount).toList();
      base['expectedRequests'] = [
        for (final path in paths)
          {'method': 'GET', 'path': path, 'query': <String, String>{}},
      ];
      base['responses'] = [
        for (var index = 0; index < paths.length; index++)
          {
            'id': 'r${index + 1}',
            'method': 'GET',
            'path': paths[index],
            'status': 200,
            'headers': <String, Object?>{},
            'body': '',
          },
      ];
      return base;
    }

    Map<String, dynamic> envelope(
      Map<String, dynamic> corpus, {
      required bool native,
      String terminal = 'four-stage-refresh',
    }) {
      final base = native
          ? _syntheticEnvelope(corpus)
          : _syntheticProduct(corpus);
      final names = switch (terminal) {
        'search-empty' => const ['search'],
        'four-stage' => const [
          'search',
          'bookInfo',
          'tableOfContents',
          'content',
        ],
        _ => const [
          'search',
          'bookInfo',
          'tableOfContents',
          'content',
          'tableOfContents',
        ],
      };
      final record = native
          ? _clone(_case())
          : _clone(
              ((base['caseRecords'] as List).first as Map)
                  .cast<String, dynamic>(),
            );
      record['terminal'] = terminal;
      record['operations'] = [
        for (var index = 0; index < names.length; index++)
          {
            'name': names[index],
            'outcome': 'completed',
            'requestStart': index,
            'requestEnd': index + 1,
            'traceStart': index,
            'traceEnd': index + 1,
          },
      ];
      record['requests'] = [
        for (var index = 0; index < names.length; index++)
          _requestFooter(
            ['/a', '/b', '/c', '/d', '/e'][index],
            responseId: 'r${index + 1}',
            stage: names[index],
          ),
      ];
      if (terminal == 'search-empty') {
        record['search'] = {'results': <Object?>[]};
        record['bookInfo'] = null;
        record['tableOfContents'] = null;
        record['chapter'] = null;
      } else {
        record['bookInfo'] = {
          'name': 'name',
          'author': 'author',
          'bookUrl': book,
          'tocUrl': '/toc',
        };
        record['tableOfContents'] = {
          'tocUrl': '/toc',
          'chapters': [
            {
              'title': 'CHAPTER ONE',
              'url': native ? chapter : 'http://synthetic.test/c',
              'absoluteUrl': 'http://synthetic.test/c',
              'tag': null,
              'isVolume': false,
              'isVip': false,
              'isPay': false,
              if (!native) 'address': chapter,
              if (!native) 'rawAddress': chapter,
              if (!native) 'storeKey': 'http://synthetic.test/c',
              if (!native) 'persistedAddress': 'http://synthetic.test/c',
            },
            {
              'title': 'CHAPTER TWO',
              'url': native ? '/c2' : 'http://synthetic.test/c2',
              'absoluteUrl': 'http://synthetic.test/c2',
              'tag': null,
              'isVolume': false,
              'isVip': false,
              'isPay': false,
              if (!native) 'address': '/c2',
              if (!native) 'rawAddress': '/c2',
              if (!native) 'storeKey': 'http://synthetic.test/c2',
              if (!native) 'persistedAddress': 'http://synthetic.test/c2',
            },
          ],
        };
      }
      if (terminal == 'four-stage-refresh') {
        record['titleLifecycle'] = lifecycle();
        if (native) record['titleLifecycleProof'] = proof();
      }
      if (native) {
        base['cases'] = [record];
      } else {
        base['caseRecords'] = [record];
      }
      base['requests'] = [
        for (var index = 0; index < names.length; index++)
          _requestFooter(
            ['/a', '/b', '/c', '/d', '/e'][index],
            responseId: 'r${index + 1}',
            stage: names[index],
          ),
      ];
      base['stageTrace'] = [
        for (var index = 0; index < names.length; index++)
          {
            'stage': names[index],
            'path':
                'http://127.0.0.1:18733${['/a', '/b', '/c', '/d', '/e'][index]}',
          },
      ];
      return base;
    }

    Map<String, dynamic> pair({
      String terminal = 'four-stage-refresh',
      int requestCount = 5,
      void Function(Map<String, dynamic>)? damageNative,
      void Function(Map<String, dynamic>)? damageProduct,
    }) {
      final base = corpus(terminal: terminal, requestCount: requestCount);
      final golden = envelope(base, native: true, terminal: terminal);
      final product = envelope(base, native: false, terminal: terminal);
      damageNative?.call(golden);
      damageProduct?.call(product);
      return _compare(golden, product, base);
    }

    Map<String, dynamic> nativeRecord(Map<String, dynamic> envelope) =>
        ((envelope['cases'] as List).first as Map).cast<String, dynamic>();

    Map<String, dynamic> productRecord(Map<String, dynamic> envelope) =>
        ((envelope['caseRecords'] as List).first as Map)
            .cast<String, dynamic>();

    Map<String, dynamic> nativeProof(Map<String, dynamic> envelope) =>
        (nativeRecord(envelope)['titleLifecycleProof'] as Map)
            .cast<String, dynamic>();

    void expectRefused(void Function() action, {String? reason}) {
      expect(
        action,
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'message',
            reason == null ? anything : contains(reason),
          ),
        ),
      );
    }

    test('the shared phases pass and the product needs no native proof', () {
      final report = pair();
      expect(
        report['status'],
        'pass',
        reason: jsonEncode(report['differences']),
      );
    });

    test('ordinary four-stage and search-empty positives are clean', () {
      for (final terminal in ['four-stage', 'search-empty']) {
        final report = pair(
          terminal: terminal,
          requestCount: terminal == 'search-empty' ? 1 : 4,
        );
        expect(
          report['status'],
          'pass',
          reason: '$terminal ${jsonEncode(report['differences'])}',
        );
      }
    });

    test('a non-observing terminal may not carry either field', () {
      for (final terminal in ['four-stage', 'search-empty']) {
        for (final side in ['native', 'product']) {
          for (final field in ['titleLifecycle', 'titleLifecycleProof']) {
            expectRefused(
              () => pair(
                terminal: terminal,
                requestCount: terminal == 'search-empty' ? 1 : 4,
                damageNative: side == 'native'
                    ? (envelope) => nativeRecord(envelope)[field] =
                          field == 'titleLifecycle' ? lifecycle() : proof()
                    : null,
                damageProduct: side == 'product'
                    ? (envelope) => productRecord(envelope)[field] =
                          field == 'titleLifecycle' ? lifecycle() : proof()
                    : null,
              ),
              reason: 'not declared by its terminal',
            );
          }
        }
      }
    });

    test('a changed variable in any phase is a named difference', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native', 'product']) {
          final report = pair(
            damageNative: side == 'native'
                ? (envelope) {
                    final rows =
                        (nativeRecord(envelope)['titleLifecycle'] as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = 'tampered';
                  }
                : null,
            damageProduct: side == 'product'
                ? (envelope) {
                    final rows =
                        (productRecord(envelope)['titleLifecycle']
                                as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = 'tampered';
                  }
                : null,
          );
          expect(report['status'], 'fail', reason: '$phase/$side');
          expect(
            (report['differences'] as List).cast<Map>().any(
              (row) => row['field'] == 'titleLifecycle.$phase[0].variable',
            ),
            isTrue,
            reason: '$phase/$side',
          );
        }
      }
    });

    test('a changed title in any phase is a named difference', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        final report = pair(
          damageProduct: (envelope) {
            final rows =
                (productRecord(envelope)['titleLifecycle'] as Map)[phase]
                    as List;
            (rows[1] as Map)['title'] = 'OTHER';
          },
        );
        expect(report['status'], 'fail', reason: phase);
        expect(
          (report['differences'] as List).cast<Map>().any(
            (row) => row['field'] == 'titleLifecycle.$phase[1].title',
          ),
          isTrue,
          reason: phase,
        );
      }
    });

    test('the observation is required on both sides when declared', () {
      expectRefused(
        () => pair(
          damageProduct: (envelope) =>
              productRecord(envelope).remove('titleLifecycle'),
        ),
      );
      expectRefused(
        () => pair(
          damageNative: (envelope) =>
              nativeRecord(envelope).remove('titleLifecycle'),
        ),
      );
    });

    test('every phase missing, null or wrong-typed is refused', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native', 'product']) {
          for (final damage in <void Function(Map<String, dynamic>)>[
            (rows) => rows.remove(phase),
            (rows) => rows[phase] = null,
            (rows) => rows[phase] = <Object?>[],
            (rows) => rows[phase] = 'not-a-list',
          ]) {
            expectRefused(
              () => pair(
                damageNative: side == 'native'
                    ? (envelope) => damage(
                        (nativeRecord(envelope)['titleLifecycle'] as Map)
                            .cast<String, dynamic>(),
                      )
                    : null,
                damageProduct: side == 'product'
                    ? (envelope) => damage(
                        (productRecord(envelope)['titleLifecycle'] as Map)
                            .cast<String, dynamic>(),
                      )
                    : null,
              ),
              reason: 'titleLifecycle',
            );
          }
        }
      }
    });

    test('row count, order, fields and types are refused', () {
      for (final damage in <void Function(Map<String, dynamic>)>[
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          rows.removeLast();
        },
        (record) {
          final lifecycle = record['titleLifecycle'] as Map;
          final rows = lifecycle['beforeContent'] as List;
          lifecycle['beforeContent'] = <dynamic>['not-a-map', rows[1]];
        },
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          (rows[0] as Map).remove('variable');
        },
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          (rows[0] as Map)['wordCount'] = '1';
        },
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          (rows[0] as Map)['index'] = 1;
          (rows[1] as Map)['index'] = 0;
        },
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          (rows[0] as Map)['index'] = true;
        },
        (record) {
          final rows =
              (record['titleLifecycle'] as Map)['beforeContent'] as List;
          (rows[0] as Map)['title'] = '';
        },
      ]) {
        expectRefused(
          () => pair(
            damageProduct: (envelope) => damage(productRecord(envelope)),
          ),
        );
      }
    });

    test('null and missing variables stay distinct', () {
      final report = pair(
        damageNative: (envelope) {
          final rows =
              (nativeRecord(envelope)['titleLifecycle'] as Map)['beforeContent']
                  as List;
          (rows[0] as Map)['variable'] = null;
        },
        damageProduct: (envelope) {
          final rows =
              (productRecord(envelope)['titleLifecycle']
                      as Map)['beforeContent']
                  as List;
          (rows[0] as Map)['variable'] = null;
        },
      );
      expect(
        report['status'],
        'pass',
        reason: jsonEncode(report['differences']),
      );
      expectRefused(
        () => pair(
          damageProduct: (envelope) {
            final rows =
                (productRecord(envelope)['titleLifecycle']
                        as Map)['beforeContent']
                    as List;
            (rows[0] as Map).remove('variable');
          },
        ),
      );
    });

    test('the native proof is native-only and must be the actual shape', () {
      expectRefused(
        () => pair(
          damageNative: (envelope) =>
              nativeRecord(envelope).remove('titleLifecycleProof'),
        ),
        reason: 'titleLifecycleProof',
      );
      expectRefused(
        () => pair(
          damageProduct: (envelope) =>
              productRecord(envelope)['titleLifecycleProof'] = proof(),
        ),
        reason: 'native producer evidence',
      );
      final proofDamages = <void Function(Map<String, dynamic>)>[
        (proof) => proof.remove('saveObserverClose'),
        (proof) => proof['undeclared'] = true,
        (proof) => (proof['bookParent'] as Map)['bookUrl'] = 'other',
        (proof) => (proof['bookParent'] as Map)['readBack'] = false,
        (proof) => (proof['chapterSeed'] as Map)['rows'] = 1,
        (proof) => (proof['saveObserver'] as Map)['onMain'] = false,
        (proof) => (proof['saveObserver'] as Map)['tag'] = 'other',
        (proof) => (proof['tocCountWordsApplied'] as Map)['applied'] = false,
        (proof) => (proof['saveEvent'] as Map)['events'] = 2,
        (proof) => (proof['saveEvent'] as Map)['duplicates'] = 1,
        (proof) =>
            ((proof['saveEvent'] as Map)['removal'] as Map)['removed'] = false,
        (proof) =>
            ((proof['saveEvent'] as Map)['lastEvent'] as Map)['chapterUrl'] =
                '/other',
        (proof) =>
            ((proof['saveEvent'] as Map)['lastEvent'] as Map)['correlates'] =
                false,
        (proof) => (proof['saveObserverClose'] as Map)['events'] = 2,
        (proof) => (proof['saveObserverClose'] as Map)['alreadyClosed'] = false,
        (proof) => proof['contentFiles'] = ['a/b'],
        (proof) => proof['contentFiles'] = ['b', 'a'],
        (proof) => proof['contentFiles'] = ['a', 'a'],
        (proof) => (proof['tocCountWords'] as Map)['restored'] = false,
        (proof) => (proof['tocCountWords'] as Map)['previous'] = false,
        (proof) => (proof['tocCountWords'] as Map).remove('previous'),
      ];
      const proofReasons = [
        'saveObserverClose',
        'undeclared',
        'bookParent.bookUrl',
        'readBack',
        'rows',
        'onMain',
        'tag',
        'applied',
        'save event',
        'duplicates',
        'removal',
        'lastEvent',
        'lastEvent',
        'saveObserverClose',
        'alreadyClosed',
        'contentFiles',
        'contentFiles',
        'contentFiles',
        'restored',
        'observed value',
        'tocCountWords',
      ];
      for (var index = 0; index < proofDamages.length; index++) {
        final damage = proofDamages[index];
        expectRefused(
          () => pair(damageNative: (envelope) => damage(nativeProof(envelope))),
          reason: proofReasons[index],
        );
      }
      // A present false prior and an absent prior read back through the actual
      // getBoolean default are both clean positives.
      for (final prior in [
        {
          'previousPresent': true,
          'previous': false,
          'presentAfter': true,
          'observedAfter': false,
        },
        {
          'previousPresent': false,
          'previous': true,
          'presentAfter': false,
          'observedAfter': true,
        },
      ]) {
        final report = pair(
          damageNative: (envelope) {
            (nativeProof(envelope)['tocCountWords'] as Map).addAll(prior);
          },
        );
        expect(
          report['status'],
          'pass',
          reason: '$prior ${jsonEncode(report['differences'])}',
        );
      }
      // An absent key cannot read back false through getBoolean(KEY, true).
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            (nativeProof(envelope)['tocCountWords'] as Map)
                .addAll(<String, bool>{
                  'previousPresent': false,
                  'previous': false,
                  'presentAfter': false,
                  'observedAfter': false,
                });
          },
        ),
        reason: 'absent prior must read back the actual default true',
      );
    });

    test('the refresh span must cover all five requests', () {
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            final record = nativeRecord(envelope);
            (record['operations'] as List).removeLast();
          },
        ),
        reason: 'operation set differs',
      );
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            final record = nativeRecord(envelope);
            ((record['operations'] as List).last as Map)['requestStart'] = 3;
          },
        ),
        reason: 'span count differs',
      );
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            ((envelope['stageTrace'] as List).last as Map)['path'] =
                'http://127.0.0.1:18733/wrong';
          },
        ),
        reason: 'unrelated request target',
      );
    });

    test(
      'shared container missing, null and non-map combinations are refused',
      () {
        for (final side in ['native', 'product', 'both']) {
          for (final shape in ['missing', 'null', 'non-map']) {
            expectRefused(
              () => pair(
                damageNative: side == 'native' || side == 'both'
                    ? (envelope) {
                        final record = nativeRecord(envelope);
                        if (shape == 'missing') {
                          record.remove('titleLifecycle');
                        } else if (shape == 'null') {
                          record['titleLifecycle'] = null;
                        } else {
                          record['titleLifecycle'] = 'not-a-map';
                        }
                      }
                    : null,
                damageProduct: side == 'product' || side == 'both'
                    ? (envelope) {
                        final record = productRecord(envelope);
                        if (shape == 'missing') {
                          record.remove('titleLifecycle');
                        } else if (shape == 'null') {
                          record['titleLifecycle'] = null;
                        } else {
                          record['titleLifecycle'] = 'not-a-map';
                        }
                      }
                    : null,
              ),
              reason: 'titleLifecycle',
            );
          }
        }
      },
    );

    test('every phase and both sides have the complete row matrix', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native', 'product']) {
          final damages = <String, void Function(Map<String, dynamic>)>{
            'row-count': (record) {
              ((record['titleLifecycle'] as Map)[phase] as List).removeLast();
            },
            'empty': (record) {
              (record['titleLifecycle'] as Map)[phase] = <Object?>[];
            },
            'non-list': (record) {
              (record['titleLifecycle'] as Map)[phase] = 'not-a-list';
            },
            'non-map-row': (record) {
              final lifecycle = record['titleLifecycle'] as Map;
              final rows = lifecycle[phase] as List;
              lifecycle[phase] = <dynamic>['not-a-map', rows[1]];
            },
            'missing-index': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first as Map)
                  .remove('index');
            },
            'missing-title': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first as Map)
                  .remove('title');
            },
            'missing-variable': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first as Map)
                  .remove('variable');
            },
            'null-index': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['index'] =
                  null;
            },
            'null-title': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['title'] =
                  null;
            },
            'wrong-index-type': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['index'] =
                  '0';
            },
            'wrong-title-type': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['title'] =
                  1;
            },
            'wrong-variable-type': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['variable'] =
                  1;
            },
            'extra-field': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['wordCount'] =
                  '1';
            },
            'duplicate-index': (record) {
              final rows = (record['titleLifecycle'] as Map)[phase] as List;
              (rows[0] as Map)['index'] = 1;
            },
            'reordered-index': (record) {
              final rows = (record['titleLifecycle'] as Map)[phase] as List;
              (rows[0] as Map)['index'] = 1;
              (rows[1] as Map)['index'] = 0;
            },
            'empty-title': (record) {
              (((record['titleLifecycle'] as Map)[phase] as List).first
                      as Map)['title'] =
                  '';
            },
          };
          for (final entry in damages.entries) {
            expectRefused(
              () => pair(
                damageNative: side == 'native'
                    ? (envelope) => entry.value(nativeRecord(envelope))
                    : null,
                damageProduct: side == 'product'
                    ? (envelope) => entry.value(productRecord(envelope))
                    : null,
              ),
              reason: phase,
            );
          }
        }
      }
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        expectRefused(
          () => pair(
            damageNative: (envelope) =>
                (nativeRecord(envelope)['titleLifecycle'] as Map).remove(phase),
            damageProduct: (envelope) =>
                (productRecord(envelope)['titleLifecycle'] as Map).remove(
                  phase,
                ),
          ),
          reason: 'titleLifecycle',
        );
      }
    });

    test('every phase title differs on the native side too', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        final report = pair(
          damageNative: (envelope) {
            final rows =
                (nativeRecord(envelope)['titleLifecycle'] as Map)[phase]
                    as List;
            (rows[0] as Map)['title'] = 'NATIVE OTHER';
          },
        );
        expect(report['status'], 'fail', reason: phase);
        expect(
          (report['differences'] as List).cast<Map>().any(
            (row) => row['field'] == 'titleLifecycle.$phase[0].title',
          ),
          isTrue,
          reason: phase,
        );
      }
    });

    test('raw, whitespace and null variable variants stay exact', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native', 'product']) {
          for (final value in ['  raw  ', 'line\nbreak', '']) {
            final report = pair(
              damageNative: side == 'native'
                  ? (envelope) {
                      final rows =
                          (nativeRecord(envelope)['titleLifecycle']
                                  as Map)[phase]
                              as List;
                      (rows[0] as Map)['variable'] = value;
                    }
                  : null,
              damageProduct: side == 'product'
                  ? (envelope) {
                      final rows =
                          (productRecord(envelope)['titleLifecycle']
                                  as Map)[phase]
                              as List;
                      (rows[0] as Map)['variable'] = value;
                    }
                  : null,
            );
            expect(report['status'], 'fail', reason: '$phase/$side/$value');
            expect(
              (report['differences'] as List).cast<Map>().any(
                (row) => row['field'] == 'titleLifecycle.$phase[0].variable',
              ),
              isTrue,
              reason: '$phase/$side/$value',
            );
          }
        }
        final bothNull = pair(
          damageNative: (envelope) {
            final rows =
                (nativeRecord(envelope)['titleLifecycle'] as Map)[phase]
                    as List;
            (rows[0] as Map)['variable'] = null;
          },
          damageProduct: (envelope) {
            final rows =
                (productRecord(envelope)['titleLifecycle'] as Map)[phase]
                    as List;
            (rows[0] as Map)['variable'] = null;
          },
        );
        expect(bothNull['status'], 'pass', reason: '$phase null');
        final nullVersusString = pair(
          damageProduct: (envelope) {
            final rows =
                (productRecord(envelope)['titleLifecycle'] as Map)[phase]
                    as List;
            (rows[0] as Map)['variable'] = null;
          },
        );
        expect(
          nullVersusString['status'],
          'fail',
          reason: '$phase null/string',
        );
        expect(
          (nullVersusString['differences'] as List).cast<Map>().any(
            (row) => row['field'] == 'titleLifecycle.$phase[0].variable',
          ),
          isTrue,
        );
      }
    });

    test('nested proof missing, null, type and error matrix is refused', () {
      for (final root in [
        'bookParent',
        'chapterSeed',
        'saveObserver',
        'tocCountWordsApplied',
        'saveEvent',
        'contentFiles',
        'saveObserverClose',
        'tocCountWords',
      ]) {
        for (final shape in ['missing', 'null', 'non-map']) {
          expectRefused(
            () => pair(
              damageNative: (envelope) {
                final proof = nativeProof(envelope);
                if (shape == 'missing') {
                  proof.remove(root);
                } else if (shape == 'null') {
                  proof[root] = null;
                } else {
                  proof[root] = 'not-a-map';
                }
              },
            ),
            reason: root,
          );
        }
      }
      for (final entry in <String, void Function(Map<String, dynamic>)>{
        'bookParent-bookUrl': (proof) =>
            (proof['bookParent'] as Map)['bookUrl'] = 'other',
        'bookParent-stored': (proof) =>
            (proof['bookParent'] as Map)['stored'] = false,
        'bookParent-readBack': (proof) =>
            (proof['bookParent'] as Map)['readBack'] = false,
        'chapterSeed-rows': (proof) =>
            (proof['chapterSeed'] as Map)['rows'] = 1,
        'chapterSeed-inserted': (proof) =>
            (proof['chapterSeed'] as Map)['inserted'] = false,
        'saveObserver-tag': (proof) =>
            (proof['saveObserver'] as Map)['tag'] = 'other',
        'saveObserver-interface': (proof) =>
            (proof['saveObserver'] as Map)['interface'] = 'other',
        'saveObserver-onMain': (proof) =>
            (proof['saveObserver'] as Map)['onMain'] = false,
        'saveObserver-registered': (proof) =>
            (proof['saveObserver'] as Map)['registered'] = false,
        'applied-name': (proof) =>
            (proof['tocCountWordsApplied'] as Map)['name'] = 'other',
        'applied-applied': (proof) =>
            (proof['tocCountWordsApplied'] as Map)['applied'] = false,
        'applied-committed': (proof) =>
            (proof['tocCountWordsApplied'] as Map)['committed'] = false,
        'applied-observed': (proof) =>
            (proof['tocCountWordsApplied'] as Map)['observed'] = false,
        'event-events': (proof) => (proof['saveEvent'] as Map)['events'] = 2,
        'event-duplicates': (proof) =>
            (proof['saveEvent'] as Map)['duplicates'] = 1,
        'event-foreign': (proof) =>
            (proof['saveEvent'] as Map)['foreignEvents'] = 1,
        'event-callback': (proof) =>
            (proof['saveEvent'] as Map)['callbackErrors'] = 1,
        'event-offMain': (proof) =>
            (proof['saveEvent'] as Map)['offMainEvents'] = 1,
        'event-malformed': (proof) =>
            (proof['saveEvent'] as Map)['malformedEvents'] = 1,
        'event-failed': (proof) => (proof['saveEvent'] as Map)['failed'] = true,
        'event-last-book': (proof) =>
            ((proof['saveEvent'] as Map)['lastEvent'] as Map)['bookUrl'] =
                'other',
        'event-last-chapter': (proof) =>
            ((proof['saveEvent'] as Map)['lastEvent'] as Map)['chapterUrl'] =
                'other',
        'event-last-correlates': (proof) =>
            ((proof['saveEvent'] as Map)['lastEvent'] as Map)['correlates'] =
                false,
        'event-removal-interface': (proof) =>
            ((proof['saveEvent'] as Map)['removal'] as Map)['interface'] =
                'other',
        'event-removal-class': (proof) =>
            ((proof['saveEvent'] as Map)['removal'] as Map)['declaringClass'] =
                'other',
        'event-removal-onMain': (proof) =>
            ((proof['saveEvent'] as Map)['removal'] as Map)['onMain'] = false,
        'event-removal-removed': (proof) =>
            ((proof['saveEvent'] as Map)['removal'] as Map)['removed'] = false,
        'close-events': (proof) =>
            (proof['saveObserverClose'] as Map)['events'] = 2,
        'close-alreadyClosed': (proof) =>
            (proof['saveObserverClose'] as Map)['alreadyClosed'] = false,
        'close-removed': (proof) =>
            (proof['saveObserverClose'] as Map)['removed'] = false,
        'close-lastEvent': (proof) =>
            ((proof['saveObserverClose'] as Map)['lastEvent']
                    as Map)['bookUrl'] =
                'other',
        'files-empty': (proof) => proof['contentFiles'] = <Object?>[],
        'files-traversal': (proof) => proof['contentFiles'] = ['../x'],
        'files-slash': (proof) => proof['contentFiles'] = ['a/b'],
        'files-backslash': (proof) => proof['contentFiles'] = ['a\\b'],
        'files-duplicate': (proof) => proof['contentFiles'] = ['a', 'a'],
        'files-order': (proof) => proof['contentFiles'] = ['b', 'a'],
        'preference-restored': (proof) =>
            (proof['tocCountWords'] as Map)['restored'] = false,
        'preference-committed': (proof) =>
            (proof['tocCountWords'] as Map)['committed'] = false,
        'preference-present': (proof) =>
            (proof['tocCountWords'] as Map)['presentAfter'] = false,
        'preference-previous': (proof) =>
            (proof['tocCountWords'] as Map)['previous'] = false,
        'preference-observed': (proof) =>
            (proof['tocCountWords'] as Map)['observedAfter'] = false,
        'preference-absent-false': (proof) =>
            (proof['tocCountWords'] as Map).addAll(<String, bool>{
              'previousPresent': false,
              'previous': false,
              'presentAfter': false,
              'observedAfter': false,
            }),
      }.entries) {
        const reasons = {
          'bookParent-bookUrl': 'bookParent.bookUrl',
          'bookParent-stored': 'stored',
          'bookParent-readBack': 'readBack',
          'chapterSeed-rows': 'rows',
          'chapterSeed-inserted': 'inserted',
          'saveObserver-tag': 'tag',
          'saveObserver-interface': 'interface',
          'saveObserver-onMain': 'onMain',
          'saveObserver-registered': 'registered',
          'applied-name': 'name',
          'applied-applied': 'applied',
          'applied-committed': 'committed',
          'applied-observed': 'observed',
          'event-events': 'save event',
          'event-duplicates': 'duplicates',
          'event-foreign': 'foreignEvents',
          'event-callback': 'callbackErrors',
          'event-offMain': 'offMainEvents',
          'event-malformed': 'malformedEvents',
          'event-failed': 'failed',
          'event-last-book': 'lastEvent',
          'event-last-chapter': 'lastEvent',
          'event-last-correlates': 'lastEvent',
          'event-removal-interface': 'removal',
          'event-removal-class': 'removal',
          'event-removal-onMain': 'removal',
          'event-removal-removed': 'removal',
          'close-events': 'saveObserverClose',
          'close-alreadyClosed': 'alreadyClosed',
          'close-removed': 'removed',
          'close-lastEvent': 'saveObserverClose.lastEvent',
          'files-empty': 'contentFiles',
          'files-traversal': 'contentFiles',
          'files-slash': 'contentFiles',
          'files-backslash': 'contentFiles',
          'files-duplicate': 'contentFiles',
          'files-order': 'contentFiles',
          'preference-restored': 'restored',
          'preference-committed': 'commit',
          'preference-present': 'presence',
          'preference-previous': 'observed value',
          'preference-observed': 'observed value',
          'preference-absent-false': 'absent prior',
        };
        expectRefused(
          () => pair(
            damageNative: (envelope) => entry.value(nativeProof(envelope)),
          ),
          reason: reasons[entry.key],
        );
      }
    });

    test('product-side five-operation failures are refused or named', () {
      for (final entry in <String, void Function(Map<String, dynamic>)>{
        'missing-operation': (record) {
          (record['operations'] as List).removeLast();
        },
        'extra-operation': (record) {
          (record['operations'] as List).add({
            'name': 'search',
            'outcome': 'completed',
            'requestStart': 4,
            'requestEnd': 5,
            'traceStart': 4,
            'traceEnd': 5,
          });
        },
        'wrong-name': (record) {
          ((record['operations'] as List).first as Map)['name'] = 'bookInfo';
        },
        'wrong-outcome': (record) {
          ((record['operations'] as List).first as Map)['outcome'] = 'error';
        },
        'overlap': (record) {
          ((record['operations'] as List)[1] as Map)['requestStart'] = 0;
        },
        'gap': (record) {
          ((record['operations'] as List)[1] as Map)['requestStart'] = 2;
        },
        'outside': (record) {
          ((record['operations'] as List).last as Map)['requestEnd'] = 99;
        },
        'wrong-stage': (record) {
          ((record['operations'] as List).last as Map)['name'] = 'content';
        },
      }.entries) {
        const reasons = {
          'missing-operation': 'operation set differs',
          'extra-operation': 'operation set differs',
          'wrong-name': 'name is not the declared term',
          'wrong-outcome': 'did not complete',
          'overlap': 'spans are not contiguous',
          'gap': 'spans are not contiguous',
          'outside': 'outside its producer',
          'wrong-stage': 'name is not the declared term',
        };
        expectRefused(
          () => pair(
            damageProduct: (envelope) => entry.value(productRecord(envelope)),
          ),
          reason: reasons[entry.key],
        );
      }
      final wrongPath = pair(
        damageProduct: (envelope) {
          ((envelope['stageTrace'] as List).last as Map)['path'] =
              'http://127.0.0.1:18733/wrong';
        },
      );
      expect(wrongPath['status'], 'fail');
      expect(
        (wrongPath['differences'] as List).cast<Map>().any(
          (row) => row['row'] == 'C3',
        ),
        isTrue,
      );
    });

    test('native-side five-operation failures are refused or named', () {
      for (final entry in <String, void Function(Map<String, dynamic>)>{
        'missing-operation': (record) {
          (record['operations'] as List).removeLast();
        },
        'extra-operation': (record) {
          (record['operations'] as List).add({
            'name': 'search',
            'outcome': 'completed',
            'requestStart': 4,
            'requestEnd': 5,
            'traceStart': 4,
            'traceEnd': 5,
          });
        },
        'wrong-name': (record) {
          ((record['operations'] as List).first as Map)['name'] = 'bookInfo';
        },
        'wrong-outcome': (record) {
          ((record['operations'] as List).first as Map)['outcome'] = 'error';
        },
        'overlap': (record) {
          ((record['operations'] as List)[1] as Map)['requestStart'] = 0;
        },
        'gap': (record) {
          ((record['operations'] as List)[1] as Map)['requestStart'] = 2;
        },
        'outside': (record) {
          ((record['operations'] as List).last as Map)['requestEnd'] = 99;
        },
        'wrong-stage': (record) {
          ((record['operations'] as List).last as Map)['name'] = 'content';
        },
      }.entries) {
        const reasons = {
          'missing-operation': 'operation set differs',
          'extra-operation': 'operation set differs',
          'wrong-name': 'name is not the declared term',
          'wrong-outcome': 'did not complete',
          'overlap': 'span count differs',
          'gap': 'span count differs',
          'outside': 'outside its producer',
          'wrong-stage': 'name is not the declared term',
        };
        expectRefused(
          () => pair(
            damageNative: (envelope) => entry.value(nativeRecord(envelope)),
          ),
          reason: reasons[entry.key],
        );
      }
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            ((envelope['stageTrace'] as List).last as Map)['path'] =
                'http://127.0.0.1:18733/wrong';
          },
        ),
        reason: 'unrelated request target',
      );
    });

    Map<String, dynamic> multiCorpus() {
      final base = _syntheticCorpus();
      base['cases'] = [
        {
          'id': 'saved-one',
          'terminal': 'four-stage-refresh',
          'keyword': 'k',
          'source': <String, Object?>{},
        },
        {
          'id': 'saved-two',
          'terminal': 'four-stage-refresh',
          'keyword': 'k',
          'source': <String, Object?>{},
        },
      ];
      base['expectedRequests'] = [
        for (var index = 0; index < 10; index++)
          {
            'method': 'GET',
            'path': ['/a', '/b', '/c', '/d', '/e'][index % 5],
            'query': <String, String>{},
          },
      ];
      base['responses'] = [
        for (var index = 0; index < 10; index++)
          {
            'id': 'r${index + 1}',
            'method': 'GET',
            'path': ['/a', '/b', '/c', '/d', '/e'][index % 5],
            'status': 200,
            'headers': <String, Object?>{},
            'body': '',
          },
      ];
      return base;
    }

    Map<String, dynamic> multiCase({bool product = false}) {
      final base = multiCorpus();
      final envelope = product
          ? _syntheticProduct(base)
          : _syntheticEnvelope(base);
      final names = [
        'search',
        'bookInfo',
        'tableOfContents',
        'content',
        'tableOfContents',
      ];
      Map<String, dynamic> record(String id, int start) => {
        'id': id,
        'terminal': 'four-stage-refresh',
        'search': {
          'results': [
            {'name': 'name', 'author': 'author', 'bookUrl': book},
          ],
        },
        'bookInfo': {
          'name': 'name',
          'author': 'author',
          'bookUrl': book,
          'tocUrl': '/toc',
        },
        'tableOfContents': {
          'tocUrl': '/toc',
          'chapters': [
            {
              'title': 'CHAPTER ONE',
              'url': product ? 'http://synthetic.test/c' : chapter,
              'absoluteUrl': 'http://synthetic.test/c',
              'tag': null,
              'isVolume': false,
              'isVip': false,
              'isPay': false,
              if (product) 'address': chapter,
              if (product) 'rawAddress': chapter,
              if (product) 'storeKey': 'http://synthetic.test/c',
              if (product) 'persistedAddress': 'http://synthetic.test/c',
            },
            {
              'title': 'CHAPTER TWO',
              'url': product ? 'http://synthetic.test/c2' : '/c2',
              'absoluteUrl': 'http://synthetic.test/c2',
              'tag': null,
              'isVolume': false,
              'isVip': false,
              'isPay': false,
              if (product) 'address': '/c2',
              if (product) 'rawAddress': '/c2',
              if (product) 'storeKey': 'http://synthetic.test/c2',
              if (product) 'persistedAddress': 'http://synthetic.test/c2',
            },
          ],
        },
        'chapter': {'title': 'CHAPTER ONE', 'text': 'body'},
        'sourceProbes': {'vipProbe': null, 'payProbe': null},
        'operations': [
          for (var index = 0; index < names.length; index++)
            {
              'name': names[index],
              'outcome': 'completed',
              'requestStart': start + index,
              'requestEnd': start + index + 1,
              'traceStart': start + index,
              'traceEnd': start + index + 1,
            },
        ],
        'requests': [
          for (var index = start; index < start + 5; index++)
            _requestFooter(
              ['/a', '/b', '/c', '/d', '/e'][index % 5],
              responseId: 'r${index + 1}',
              stage: names[index - start],
            ),
        ],
        'titleLifecycle': lifecycle(),
        if (!product) 'titleLifecycleProof': proof(),
      };
      final records = [record('saved-one', 0), record('saved-two', 5)];
      if (product) {
        envelope['caseRecords'] = records;
      } else {
        envelope['cases'] = records;
      }
      envelope['requests'] = [
        for (var index = 0; index < 10; index++)
          _requestFooter(
            ['/a', '/b', '/c', '/d', '/e'][index % 5],
            responseId: 'r${index + 1}',
            stage: names[index % 5],
          ),
      ];
      envelope['stageTrace'] = [
        for (var index = 0; index < 10; index++)
          {
            'stage': names[index % 5],
            'path':
                'http://127.0.0.1:18733${['/a', '/b', '/c', '/d', '/e'][index % 5]}',
          },
      ];
      return envelope;
    }

    test(
      'lifecycle multi-case ownership rejects stale, overlap, gap and mixed order',
      () {
        for (final product in [false, true]) {
          final clean = _compare(
            multiCase(),
            multiCase(product: true),
            multiCorpus(),
          );
          expect(
            clean['status'],
            'pass',
            reason: 'product=$product ${jsonEncode(clean['differences'])}',
          );
          for (final damage in <String, void Function(Map<String, dynamic>)>{
            'overlap': (envelope) {
              final records =
                  (envelope[product ? 'caseRecords' : 'cases'] as List);
              (((records[1] as Map)['operations'] as List).first as Map)
                ..['requestStart'] = 4
                ..['traceStart'] = 4;
            },
            'gap': (envelope) {
              final records =
                  (envelope[product ? 'caseRecords' : 'cases'] as List);
              (((records[1] as Map)['operations'] as List).first as Map)
                ..['requestStart'] = 6
                ..['traceStart'] = 6;
            },
            'stale': (envelope) {
              final records =
                  (envelope[product ? 'caseRecords' : 'cases'] as List);
              (((records[1] as Map)['operations'] as List).first as Map)
                ..['requestStart'] = 0
                ..['traceStart'] = 0;
            },
            'mixed-order': (envelope) {
              final records =
                  (envelope[product ? 'caseRecords' : 'cases'] as List);
              final first = (records[0] as Map)['id'];
              (records[0] as Map)['id'] = (records[1] as Map)['id'];
              (records[1] as Map)['id'] = first;
            },
            'missing-case': (envelope) {
              (envelope[product ? 'caseRecords' : 'cases'] as List)
                  .removeLast();
            },
            'extra-request': (envelope) {
              (envelope['requests'] as List).add(_requestFooter('/extra'));
            },
          }.entries) {
            final damaged = multiCase(product: product);
            damage.value(damaged);
            final golden = product ? multiCase() : damaged;
            final productEnvelope = product
                ? damaged
                : multiCase(product: true);
            final reasons = product
                ? const {
                    'overlap': 'unrelated trace stage',
                    'gap': 'skip or overlap',
                    'stale': 'unrelated trace stage',
                    'mixed-order': 'chronological',
                    'missing-case': 'chronological',
                    'extra-request': 'cover',
                  }
                : const {
                    'overlap': 'unrelated request stage',
                    'gap': 'skip or overlap',
                    'stale': 'unrelated request stage',
                    'mixed-order': 'chronological',
                    'missing-case': 'chronological',
                    'extra-request': 'cover',
                  };
            expectRefused(
              () => _compare(golden, productEnvelope, multiCorpus()),
              reason: reasons[damage.key],
            );
          }
          final wrongTarget = multiCase(product: product);
          ((wrongTarget['stageTrace'] as List).last as Map)['path'] =
              'http://127.0.0.1:18733/wrong';
          if (product) {
            final report = _compare(multiCase(), wrongTarget, multiCorpus());
            expect(report['status'], 'fail');
            expect(
              (report['differences'] as List).cast<Map>().any(
                (row) => row['row'] == 'C3',
              ),
              isTrue,
            );
          } else {
            expectRefused(
              () => _compare(
                wrongTarget,
                multiCase(product: true),
                multiCorpus(),
              ),
              reason: 'target',
            );
          }
        }
      },
    );
    test(
      'nested proof leaves reject missing, null, wrong type and unknown fields',
      () {
        final leaves = <List<String>>[
          ['bookParent', 'bookUrl'],
          ['bookParent', 'stored'],
          ['bookParent', 'readBack'],
          ['chapterSeed', 'rows'],
          ['chapterSeed', 'inserted'],
          ['saveObserver', 'tag'],
          ['saveObserver', 'interface'],
          ['saveObserver', 'declaringClass'],
          ['saveObserver', 'onMain'],
          ['saveObserver', 'registered'],
          ['tocCountWordsApplied', 'name'],
          ['tocCountWordsApplied', 'applied'],
          ['tocCountWordsApplied', 'committed'],
          ['tocCountWordsApplied', 'observed'],
          ['saveEvent', 'events'],
          ['saveEvent', 'duplicates'],
          ['saveEvent', 'foreignEvents'],
          ['saveEvent', 'callbackErrors'],
          ['saveEvent', 'offMainEvents'],
          ['saveEvent', 'malformedEvents'],
          ['saveEvent', 'lastEvent', 'bookUrl'],
          ['saveEvent', 'lastEvent', 'chapterUrl'],
          ['saveEvent', 'lastEvent', 'correlates'],
          ['saveEvent', 'removal', 'interface'],
          ['saveEvent', 'removal', 'declaringClass'],
          ['saveEvent', 'removal', 'onMain'],
          ['saveEvent', 'removal', 'removed'],
          ['saveObserverClose', 'events'],
          ['saveObserverClose', 'duplicates'],
          ['saveObserverClose', 'foreignEvents'],
          ['saveObserverClose', 'callbackErrors'],
          ['saveObserverClose', 'offMainEvents'],
          ['saveObserverClose', 'malformedEvents'],
          ['saveObserverClose', 'alreadyClosed'],
          ['saveObserverClose', 'removed'],
          ['saveObserverClose', 'lastEvent', 'bookUrl'],
          ['saveObserverClose', 'lastEvent', 'chapterUrl'],
          ['saveObserverClose', 'lastEvent', 'correlates'],
          ['saveObserverClose', 'removal', 'interface'],
          ['saveObserverClose', 'removal', 'declaringClass'],
          ['saveObserverClose', 'removal', 'onMain'],
          ['saveObserverClose', 'removal', 'removed'],
          ['tocCountWords', 'previousPresent'],
          ['tocCountWords', 'previous'],
          ['tocCountWords', 'committed'],
          ['tocCountWords', 'presentAfter'],
          ['tocCountWords', 'observedAfter'],
          ['tocCountWords', 'restored'],
        ];
        (Type, Type) damagePath(
          Map<String, dynamic> proof,
          List<String> path,
          String mode,
        ) {
          Map<String, Object?> parent = proof;
          for (var index = 0; index < path.length - 1; index++) {
            final child = Map<String, Object?>.from(parent[path[index]] as Map);
            parent[path[index]] = child;
            parent = child;
          }
          final key = path.last;
          final baseline = parent[key];
          final baselineType = baseline.runtimeType;
          if (mode == 'missing') {
            parent.remove(key);
          } else if (mode == 'null') {
            parent[key] = null;
          } else {
            parent[key] = switch (baseline) {
              String() => 7,
              bool() => 'not-a-bool',
              int() => true,
              Map() => 7,
              _ => throw StateError(
                  'unexpected baseline type $baselineType at $path'),
            };
          }
          return (baselineType, parent[key].runtimeType);
        }

        void assertWrongType((Type, Type) types, List<String> path) {
          expect(types.$2, isNot(types.$1),
              reason: 'wrong-type subject for $path retained ${types.$2}');
        }

        for (final leaf in leaves) {
          for (final mode in ['missing', 'null', 'wrong-type']) {
            expectRefused(
              () => pair(
                damageNative: (envelope) {
                  final types = damagePath(nativeProof(envelope), leaf, mode);
                  if (mode == 'wrong-type') {
                    assertWrongType(types, leaf);
                  }
                },
              ),
              reason: leaf.last,
            );
          }
        }
        for (final nested in <List<String>>[
          ['saveEvent', 'lastEvent'],
          ['saveEvent', 'removal'],
          ['saveObserverClose', 'lastEvent'],
          ['saveObserverClose', 'removal'],
        ]) {
          for (final mode in ['missing', 'null', 'wrong-type']) {
            expectRefused(
              () => pair(
                damageNative: (envelope) {
                  final types = damagePath(nativeProof(envelope), nested, mode);
                  if (mode == 'wrong-type') {
                    assertWrongType(types, nested);
                  }
                },
              ),
              reason: nested.last,
            );
          }
        }
        expectRefused(
          () => pair(
            damageNative: (envelope) {
              (nativeProof(envelope)['saveEvent'] as Map)['unknown'] = true;
            },
          ),
          reason: 'saveEvent',
        );
        expectRefused(
          () => pair(
            damageNative: (envelope) {
              (nativeProof(envelope)['saveEvent'] as Map)['failed'] = true;
            },
          ),
          reason: 'failed',
        );
      },
    );

    test('cached close removal mutation does not alias the first event', () {
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            final proof = nativeProof(envelope);
            final first = jsonDecode(jsonEncode(proof['saveEvent']));
            ((proof['saveObserverClose'] as Map)['removal'] as Map)['removed'] =
                false;
            expect(proof['saveEvent'], first);
          },
        ),
        reason: 'saveObserverClose.removal',
      );
    });

    test('whitespace-only variable differences are named', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native', 'product']) {
          final report = pair(
            damageNative: side == 'native'
                ? (envelope) {
                    final rows =
                        (nativeRecord(envelope)['titleLifecycle'] as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = ' toc-a ';
                  }
                : null,
            damageProduct: side == 'product'
                ? (envelope) {
                    final rows =
                        (productRecord(envelope)['titleLifecycle']
                                as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = ' toc-a ';
                  }
                : null,
          );
          expect(report['status'], 'fail', reason: '$phase/$side');
          expect(
            (report['differences'] as List).cast<Map>().any(
              (row) => row['field'] == 'titleLifecycle.$phase[0].variable',
            ),
            isTrue,
            reason: '$phase/$side',
          );
        }
      }
    });

    test('native-null versus product-string and reverse are named', () {
      for (final phase in [
        'beforeContent',
        'storedAfterContent',
        'refreshedChapters',
        'storedAfterRefresh',
      ]) {
        for (final side in ['native-null', 'product-null']) {
          final report = pair(
            damageNative: side == 'native-null'
                ? (envelope) {
                    final rows =
                        (nativeRecord(envelope)['titleLifecycle'] as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = null;
                  }
                : null,
            damageProduct: side == 'product-null'
                ? (envelope) {
                    final rows =
                        (productRecord(envelope)['titleLifecycle']
                                as Map)[phase]
                            as List;
                    (rows[0] as Map)['variable'] = null;
                  }
                : null,
          );
          expect(report['status'], 'fail', reason: '$phase/$side');
          expect(
            (report['differences'] as List).cast<Map>().any(
              (row) => row['field'] == 'titleLifecycle.$phase[0].variable',
            ),
            isTrue,
            reason: '$phase/$side',
          );
        }
      }
    });

    test('cached close mutation does not alias the first event', () {
      expectRefused(
        () => pair(
          damageNative: (envelope) {
            final proof = nativeProof(envelope);
            final first = jsonDecode(jsonEncode(proof['saveEvent']));
            ((proof['saveObserverClose'] as Map)['lastEvent']
                    as Map)['bookUrl'] =
                'other';
            expect(proof['saveEvent'], first);
          },
        ),
        reason: 'saveObserverClose.lastEvent',
      );
    });
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
          contains('selected raw-bundle'),
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
          contains('selected raw-bundle'),
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

  test('comparator uses full ordinary request text but volume target', () {
    final corpus = _syntheticCorpus();
    final golden = _syntheticEnvelope(corpus);
    final product = _syntheticProduct(corpus);
    final productRecord = (product['caseRecords'] as List).first as Map;
    final productChapter =
        (((productRecord['tableOfContents'] as Map)['chapters'] as List).first
            as Map);
    const complete = 'http://synthetic.test/c,{"charset":"gbk"}';
    _chapters(golden).first['absoluteUrl'] = complete;
    productChapter['persistedAddress'] = complete;
    expect(_compare(golden, product, corpus)['status'], 'pass');
    for (final fields in [
      <String>['url'],
      <String>['storeKey'],
      <String>['url', 'storeKey'],
    ]) {
      final changed = _clone(product);
      final row =
          (((((changed['caseRecords'] as List).first as Map)['tableOfContents']
                          as Map)['chapters']
                      as List)
                  .first
              as Map);
      for (final field in fields) {
        row[field] = 'http://wrong.test/c';
      }
      final result = _compare(golden, changed, corpus);
      expect(result['status'], 'fail', reason: '$fields');
      final differences = (result['differences'] as List).map(
        (item) => item['field'],
      );
      for (final field in fields) {
        expect(
          differences,
          contains('chapters[0].$field(vs native pre-option target)'),
        );
      }
    }
    productChapter['persistedAddress'] = '$complete-wrong';
    expect(_compare(golden, product, corpus)['status'], 'fail');
    productChapter['persistedAddress'] = 'chapter0';
    productChapter['address'] = 'chapter0';
    productChapter['isVolume'] = true;
    _chapters(golden).first
      ..['url'] = 'chapter0'
      ..['absoluteUrl'] = 'http://synthetic.test/c'
      ..['isVolume'] = true;
    expect(_compare(golden, product, corpus)['status'], 'pass');
    productChapter['url'] = 'http://wrong.test/c';
    expect(_compare(golden, product, corpus)['status'], 'fail');
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
      'absolute target': 'chapters[0].absoluteUrl(vs persistedAddress)',
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

  group('declared intro public matrix', () {
    Map<String, dynamic> recordOf(
      Map<String, dynamic> envelope, {
      required bool native,
    }) => ((envelope[native ? 'cases' : 'caseRecords'] as List).first as Map)
        .cast<String, dynamic>();
    Map<String, dynamic> searchOf(Map<String, dynamic> record) =>
        (((record['search'] as Map)['results'] as List).first as Map)
            .cast<String, dynamic>();
    Map<String, dynamic> infoOf(Map<String, dynamic> record) =>
        (record['bookInfo'] as Map).cast<String, dynamic>();
    void setIntro(Map<String, dynamic> record, String stage, Object? value) {
      if (stage == 'search') {
        final search = Map<String, dynamic>.from(record['search'] as Map);
        final results = [
          for (final item in (search['results'] as List))
            Map<String, dynamic>.from(item as Map),
        ];
        if (value == null) {
          results.first.remove('intro');
        } else {
          results.first['intro'] = value;
        }
        search['results'] = results;
        record['search'] = search;
      } else {
        final info = Map<String, dynamic>.from(record['bookInfo'] as Map);
        if (value == null) {
          info.remove('intro');
        } else {
          info['intro'] = value;
        }
        record['bookInfo'] = info;
      }
    }

    ({
      Map<String, dynamic> corpus,
      Map<String, dynamic> golden,
      Map<String, dynamic> product,
    })
    fixture() {
      final corpus = _syntheticCorpus();
      final entry = ((corpus['cases'] as List).first as Map)
          .cast<String, dynamic>();
      final source = (entry['source'] as Map).cast<String, dynamic>();
      source['ruleSearch'] = <String, dynamic>{'intro': '.intro@text'};
      source['ruleBookInfo'] = <String, dynamic>{'intro': ''};
      final golden = _syntheticEnvelope(corpus);
      final product = _syntheticProduct(corpus);
      for (final record in [
        recordOf(golden, native: true),
        recordOf(product, native: false),
      ]) {
        searchOf(record)['intro'] = 'search intro';
        infoOf(record)['intro'] = 'search intro';
      }
      return (corpus: corpus, golden: golden, product: product);
    }

    void expectIntroRejection(void Function() action, String stage) {
      expect(
        action,
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'message',
            allOf(
              contains('intro'),
              contains(stage == 'search' ? 'search.results[0]' : 'bookInfo'),
            ),
          ),
        ),
      );
    }

    Map<String, dynamic> difference(
      Map<String, dynamic> report,
      String field,
    ) => (report['differences'] as List)
        .cast<Map>()
        .singleWhere((entry) => entry['field'] == field)
        .cast<String, dynamic>();

    for (final stage in ['search', 'info']) {
      test('$stage native omission rejects for intro', () {
        final f = fixture();
        setIntro(recordOf(f.golden, native: true), stage, null);
        expectIntroRejection(
          () => _compare(f.golden, f.product, f.corpus),
          stage,
        );
      });

      test('$stage product omission rejects for intro', () {
        final f = fixture();
        setIntro(recordOf(f.product, native: false), stage, null);
        expectIntroRejection(
          () => _compare(f.golden, f.product, f.corpus),
          stage,
        );
      });

      test('$stage both omissions reject for intro', () {
        final f = fixture();
        setIntro(recordOf(f.golden, native: true), stage, null);
        setIntro(recordOf(f.product, native: false), stage, null);
        expectIntroRejection(
          () => _compare(f.golden, f.product, f.corpus),
          stage,
        );
      });

      test('$stage native wrong type rejects for intro', () {
        final f = fixture();
        setIntro(recordOf(f.golden, native: true), stage, 42);
        expectIntroRejection(
          () => _compare(f.golden, f.product, f.corpus),
          stage,
        );
      });

      test('$stage product wrong type rejects for intro', () {
        final f = fixture();
        setIntro(recordOf(f.product, native: false), stage, 42);
        expectIntroRejection(
          () => _compare(f.golden, f.product, f.corpus),
          stage,
        );
      });

      test('$stage native changed string is an exact difference', () {
        final f = fixture();
        setIntro(
          recordOf(f.golden, native: true),
          stage,
          'native $stage changed',
        );
        final report = _compare(f.golden, f.product, f.corpus);
        expect(report['status'], 'fail');
        final field = stage == 'search'
            ? 'search.results[0].intro'
            : 'bookInfo.intro';
        final diff = difference(report, field);
        expect(diff['frozen'], 'native $stage changed');
        expect(diff['liber'], 'search intro');
      });

      test('$stage product changed string is an exact difference', () {
        final f = fixture();
        setIntro(
          recordOf(f.product, native: false),
          stage,
          'product $stage changed',
        );
        final report = _compare(f.golden, f.product, f.corpus);
        expect(report['status'], 'fail');
        final field = stage == 'search'
            ? 'search.results[0].intro'
            : 'bookInfo.intro';
        final diff = difference(report, field);
        expect(diff['frozen'], 'search intro');
        expect(diff['liber'], 'product $stage changed');
      });
    }

    test('positive declared strings pass, including the empty info rule', () {
      final f = fixture();
      final entry = ((f.corpus['cases'] as List).first as Map)
          .cast<String, dynamic>();
      final source = (entry['source'] as Map).cast<String, dynamic>();
      expect((source['ruleBookInfo'] as Map)['intro'], '');
      final report = _compare(f.golden, f.product, f.corpus);
      expect(report['status'], 'pass');
      expect(report['differences'], isEmpty);
      expect(
        searchOf(recordOf(f.golden, native: true))['intro'],
        'search intro',
      );
      expect(
        infoOf(recordOf(f.product, native: false))['intro'],
        'search intro',
      );
    });

    test('old undeclared input keeps its old shape and passes', () {
      final corpus = _syntheticCorpus();
      final golden = _syntheticEnvelope(corpus);
      final product = _syntheticProduct(corpus);
      expect(
        searchOf(recordOf(golden, native: true)).containsKey('intro'),
        isFalse,
      );
      expect(
        infoOf(recordOf(product, native: false)).containsKey('intro'),
        isFalse,
      );
      final report = _compare(golden, product, corpus);
      expect(report['status'], 'pass');
      expect(report['differences'], isEmpty);
    });

    test('old undeclared input rejects an injected intro field', () {
      final corpus = _syntheticCorpus();
      final golden = _syntheticEnvelope(corpus);
      final product = _syntheticProduct(corpus);
      setIntro(recordOf(golden, native: true), 'search', 'injected');
      expect(
        () => _compare(golden, product, corpus),
        throwsA(
          isA<StateError>().having(
            (error) => '$error',
            'message',
            allOf(contains('intro'), contains('not declared by the corpus')),
          ),
        ),
      );
    });
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
  String stage = 'search',
}) => {
  'method': method,
  'path': path,
  'query': <String, String>{},
  'rawQuery': '',
  'stage': stage,
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
