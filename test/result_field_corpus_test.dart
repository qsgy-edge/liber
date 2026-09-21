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
