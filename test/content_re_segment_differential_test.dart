import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/content_re_segment.dart';

/// The frozen comparison for the re-segmentation stage.
///
/// The golden is executed evidence from the frozen `ContentHelp.kt` at
/// `14dd2494` on a host JVM (`tool/re_segment_oracle/`), produced by running the
/// frozen source bytes over `fixtures.json`. This test runs the product's ported
/// transform over the same fixtures and compares byte for byte. The frozen
/// stage runs only when the book's own `reSegment` flag is on, so the golden of
/// a disabled book is the body it was handed.
///
/// The `forceSplit` `Math.random()` branch is deliberately absent from the
/// corpus: the harness refuses a case whose two frozen runs differ, and those
/// inputs are covered by the seeded tests in `content_re_segment_test.dart`.
void main() {
  const fixturesPath = 'tool/re_segment_oracle/fixtures.json';
  const goldenPath = 'tool/re_segment_oracle/evidence/jvm-host/golden.json';

  final fixtures = (jsonDecode(File(fixturesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final cases = (fixtures['cases'] as List).cast<Map>();
  final golden = (jsonDecode(File(goldenPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();

  test('every fixture has a golden row', () {
    expect(golden.keys.toSet(), {for (final c in cases) c['name'] as String});
  });

  test('the ported transform matches the frozen stage for every case', () {
    for (final c in cases) {
      final name = c['name'] as String;
      final content = c['content'] as String;
      final title = c['chapterTitle'] as String;
      final enabled = c['reSegment'] as bool;
      final staged = enabled ? reSegment(content, title) : content;
      expect(
        staged,
        golden[name],
        reason: '$name (reSegment=$enabled): ${c['note']}',
      );
    }
  });

  test('the enabled and disabled books are the same body, two flags', () {
    final enabled = cases.singleWhere(
      (c) => c['name'] == 'enabled-observed-shape',
    );
    final disabled = cases.singleWhere(
      (c) => c['name'] == 'disabled-observed-shape',
    );
    expect(enabled['content'], disabled['content']);
    expect(enabled['chapterTitle'], disabled['chapterTitle']);
    expect(enabled['reSegment'], isTrue);
    expect(disabled['reSegment'], isFalse);
    // The disabled book's frozen stage output is the body it was handed, while
    // the enabled book's is re-segmented, so the two really are different
    // observations of the same body.
    expect(golden['disabled-observed-shape'], disabled['content']);
    expect(golden['enabled-observed-shape'], isNot(enabled['content']));
  });
}
