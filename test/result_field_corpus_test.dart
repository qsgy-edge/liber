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
