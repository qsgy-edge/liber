import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

import '../tool/result_field_runner.dart';
import 'native_library.dart';

/// The remaining-result-field corpus (FIELDS-01), run through the product
/// pipeline on every desktop platform `flutter test test` reaches.
///
/// What this test asserts is the corpus' *scenario shape*: every case reaches
/// all four stages, the request sequence is the one the corpus declares, and no
/// undeclared request is issued. The stage outputs themselves are recorded by
/// `tool/result_field_replay.dart`, never asserted here — the compatibility
/// verdicts belong to `tool/result_field_compare.dart`, which reads the executed
/// frozen golden in `tool/result_field_oracle/evidence/`.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));

  test(
    'reader follow-through corpus: three cases and fourteen declared GETs',
    () {
      final corpus = loadResultFieldFixture(
        'tool/result_field_oracle/reader-followthrough-fixtures-selected.json',
      );
      expect(corpus['fixtureId'], 'FIELDS-02');
      expect(corpus['corpusVersion'], 1);
      expect(
        corpus['baselineCommit'],
        'a7d37f1707a70a459ad708f4fe79341d1e42d716',
      );
      expect((corpus['target'] as Map)['package'], 'com.legado.app.debug');
      expect(
        (corpus['target'] as Map)['apkSha256'],
        '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
      );
      expect(
        (corpus['target'] as Map)['deviceFingerprint'],
        'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys',
      );
      expect(
        [
          for (final entry in (corpus['cases'] as List).cast<Map>())
            entry['id'],
        ],
        [
          'html-body-replace-title-order',
          'json-body-title-order',
          'html-order-control',
        ],
      );
      expect(corpus['expectedRequests'], hasLength(14));
      expect(corpus['responses'], hasLength(14));
      expect(
        [
          for (final source in (corpus['frozenSources'] as List).cast<Map>())
            source['path'],
        ],
        containsAll(<String>[
          'app/src/main/java/io/legado/app/model/webBook/BookList.kt',
          'app/src/main/java/io/legado/app/model/webBook/BookInfo.kt',
          'app/src/main/java/io/legado/app/model/webBook/BookContent.kt',
          'app/src/main/java/io/legado/app/utils/HtmlFormatter.kt',
        ]),
      );
      for (final entry in (corpus['cases'] as List).cast<Map>()) {
        final source = (entry['source'] as Map).cast<String, dynamic>();
        expect((source['ruleSearch'] as Map).containsKey('intro'), isTrue);
        expect((source['ruleBookInfo'] as Map).containsKey('intro'), isTrue);
      }
    },
  );

  test(
    'JSON replace corpus: one replacement case, one control, ten declared GETs',
    () {
      // The pair is the whole point: the replacement case declares the ordinary
      // `##regex##replacement` field and the control declares none, over the same
      // two pages and the same bodies. A corpus edit that changed either side
      // would stop isolating the whole-content replacement pass.
      final corpus = loadResultFieldFixture(
        'tool/result_field_oracle/reader-json-replace-fixtures-selected.json',
      );
      expect(corpus['fixtureId'], 'FIELDS-02');
      expect(corpus['corpusVersion'], 1);
      expect(
        corpus['baselineCommit'],
        'a7d37f1707a70a459ad708f4fe79341d1e42d716',
      );
      expect((corpus['target'] as Map)['package'], 'com.legado.app.debug');
      expect(
        (corpus['target'] as Map)['apkSha256'],
        '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
      );
      expect(
        (corpus['target'] as Map)['deviceFingerprint'],
        'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys',
      );
      final cases = (corpus['cases'] as List).cast<Map>();
      expect(
        [for (final entry in cases) entry['id']],
        ['json-replace-whole-content', 'json-no-replace-control'],
      );
      expect(
        [for (final entry in cases) entry['terminal']],
        ['four-stage', 'four-stage'],
      );
      final contents = [
        for (final entry in cases)
          ((entry['source'] as Map)['ruleContent'] as Map)
              .cast<String, Object?>(),
      ];
      expect(contents[0]['replaceRegex'], '##@@AD@@');
      expect(contents[1].containsKey('replaceRegex'), isFalse);
      expect(contents[0]['content'], contents[1]['content']);
      expect(contents[0]['nextContentUrl'], contents[1]['nextContentUrl']);
      expect(contents[0]['title'], contents[1]['title']);
      expect(corpus['expectedRequests'], hasLength(10));
      expect(corpus['responses'], hasLength(10));
      expect(
        [
          for (final request
              in (corpus['expectedRequests'] as List).cast<Map>())
            '${request['method']} ${request['path']}',
        ],
        [
          'GET /json-replace/search',
          'GET /json-replace/book/1',
          'GET /json-replace/toc/1',
          'GET /json-replace/c/1',
          'GET /json-replace/c/2',
          'GET /json-control/search',
          'GET /json-control/book/1',
          'GET /json-control/toc/1',
          'GET /json-control/c/1',
          'GET /json-control/c/2',
        ],
      );
      // The two content pages carry the same bodies in both cases; only the
      // route the page declares differs, so the pair isolates the replacement.
      final bodies = [
        for (final response in (corpus['responses'] as List).cast<Map>())
          if ('${response['path']}'.endsWith('/c/1') ||
              '${response['path']}'.endsWith('/c/2'))
            ((jsonDecode(response['body'] as String) as Map)['body'] as String),
      ];
      expect(bodies, hasLength(4));
      expect(bodies[0], bodies[2]);
      expect(bodies[1], bodies[3]);
      expect(bodies[0], contains('@@AD@@'));
      expect(
        [
          for (final source in (corpus['frozenSources'] as List).cast<Map>())
            source['path'],
        ],
        containsAll(<String>[
          'app/src/main/java/io/legado/app/model/webBook/BookContent.kt',
          'app/src/main/java/io/legado/app/model/webBook/WebBook.kt',
          'app/src/main/java/io/legado/app/utils/HtmlFormatter.kt',
        ]),
      );
    },
  );

  test('title lifecycle corpus: four cases, eighteen declared GETs', () {
    // Two ordinary title-error cases and two saved-name/refresh cases. The
    // saved pair re-reads its table of contents, so the same path appears
    // twice in the declared sequence and the replay serves the declared
    // responses in order.
    final corpus = loadResultFieldFixture(
      'tool/result_field_oracle/reader-title-lifecycle-fixtures-selected.json',
    );
    expect(corpus['fixtureId'], 'FIELDS-02');
    expect(corpus['corpusVersion'], 1);
    expect(
      corpus['baselineCommit'],
      'a7d37f1707a70a459ad708f4fe79341d1e42d716',
    );
    expect((corpus['target'] as Map)['package'], 'com.legado.app.debug');
    expect(
      (corpus['target'] as Map)['apkSha256'],
      '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
    );
    final cases = (corpus['cases'] as List).cast<Map>();
    expect(
      [for (final entry in cases) entry['id']],
      [
        'html-title-error-body-retained',
        'json-title-error-body-retained',
        'html-title-saved-refresh',
        'json-title-saved-refresh',
      ],
    );
    expect(
      [for (final entry in cases) entry['terminal']],
      ['four-stage', 'four-stage', 'four-stage-refresh', 'four-stage-refresh'],
    );
    final titles = [
      for (final entry in cases)
        ((entry['source'] as Map)['ruleContent'] as Map)['title'],
    ];
    expect(titles[0], '@js: throw new Error("title-probe")');
    expect(titles[1], '@js: throw new Error("title-probe")');
    expect(titles[2], '.chapter-title@text');
    expect(titles[3], r'$.title');
    expect(corpus['expectedRequests'], hasLength(18));
    expect(corpus['responses'], hasLength(18));
    expect(
      [
        for (final request in (corpus['expectedRequests'] as List).cast<Map>())
          '${request['method']} ${request['path']}',
      ],
      [
        'GET /html-title-error/search',
        'GET /html-title-error/book/1',
        'GET /html-title-error/toc/1',
        'GET /html-title-error/c/1',
        'GET /json-title-error/search',
        'GET /json-title-error/book/1',
        'GET /json-title-error/toc/1',
        'GET /json-title-error/c/1',
        'GET /html-title-saved/search',
        'GET /html-title-saved/book/1',
        'GET /html-title-saved/toc/1',
        'GET /html-title-saved/c/1',
        'GET /html-title-saved/toc/1',
        'GET /json-title-saved/search',
        'GET /json-title-saved/book/1',
        'GET /json-title-saved/toc/1',
        'GET /json-title-saved/c/1',
        'GET /json-title-saved/toc/1',
      ],
    );
    final lifecycle = corpus['titleLifecycle'] as Map;
    expect(lifecycle['observingTerminal'], 'four-stage-refresh');
    expect(lifecycle['seedVariables'], ['toc-a', 'toc-b']);
    expect(lifecycle['phases'], [
      'beforeContent',
      'storedAfterContent',
      'refreshedChapters',
      'storedAfterRefresh',
    ]);
    expect(lifecycle['tocCountWordsPreference'], 'tocCountWords');
    final pins = [
      for (final source in (corpus['frozenSources'] as List).cast<Map>())
        source['path'],
    ];
    expect(pins, hasLength(20));
    expect(
      pins,
      containsAll(<String>[
        'app/src/main/java/io/legado/app/help/book/BookHelp.kt',
        'app/src/main/java/io/legado/app/data/dao/BookChapterDao.kt',
        'app/src/main/java/io/legado/app/help/config/AppConfig.kt',
        'app/src/main/java/io/legado/app/utils/ContextExtensions.kt',
        'app/src/main/java/io/legado/app/data/dao/BookDao.kt',
        'app/src/main/java/io/legado/app/data/AppDatabase.kt',
        'app/src/main/java/io/legado/app/utils/EventBusExtensions.kt',
        'app/src/main/java/io/legado/app/constant/EventBus.kt',
      ]),
    );
  });

  test('controlled corpus FIELDS-01: five cases, declared requests', () async {
    final result = await runResultFieldCorpus(
      fixture: loadResultFieldFixture(),
    );
    expect(
      [
        for (final invariant in result.invariants)
          if (!invariant.ok) '${invariant.id}: ${invariant.detail}',
      ],
      isEmpty,
      reason: 'the corpus must run as declared before it can carry any row',
    );
    expect(result.unmatched, isEmpty);
    expect(result.caseFailures, isEmpty);
    expect(result.cases.keys, [
      'html-rename-permitted',
      'html-rename-absent',
      'html-blank-rename-empty-author',
      'html-content-title-blank',
      'json-fields',
    ]);
    expect(result.checkKeyword.keys, [
      'declared',
      'blank',
      'absent',
      'number',
      'object',
    ]);
    expect(result.requests, hasLength(20));
  });
}
