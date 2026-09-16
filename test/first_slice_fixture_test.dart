import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

import '../tool/first_slice/runner.dart';
import 'native_library.dart';

/// The first slice's controlled corpus, run through the product pipeline on
/// every desktop platform `flutter test test` reaches.
///
/// What this test asserts is the corpus' *scenario shape*: the four stages
/// return, the request sequence is the one the corpus declares, the session
/// cookie reaches the wire, and both page-chained stages follow their next
/// link. The stage outputs themselves are recorded, never asserted here — the
/// compatibility rows stay `not-run` until a frozen oracle golden exists
/// (`tool/first_slice/README.md`, `docs/compatibility/first-slice.md`).
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));

  test('controlled corpus SLICE-01: four stages, declared requests, session', () async {
    final result = await runSliceFixture(fixture: loadSliceFixture());
    expect(result.failure, isNull);
    expect(
      [
        for (final invariant in result.invariants)
          if (!invariant.ok) '${invariant.id}: ${invariant.detail}',
      ],
      isEmpty,
      reason: 'the corpus must run as declared before it can carry any row',
    );
    expect(result.unmatched, isEmpty);
  });
}
