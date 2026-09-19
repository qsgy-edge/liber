import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/content_re_segment.dart';

/// The ported frozen `ContentHelp.reSegment` transform, on its own.
///
/// A plain (non-widget) test: the transform is pure Dart with no native-library
/// or isolate dependency. The differential comparison against the frozen source
/// is `content_re_segment_differential_test.dart`; `forceSplit`'s
/// `Math.random()` branch cannot be compared there, so the seeded cases here are
/// what pins it.
void main() {
  test('blank lines collapse, and paragraphs merge at a sentence end only', () {
    expect(reSegment('第一段。\n\n\n第二段。', '第一章'), '第一段。\n第二段。');
    // No sentence end between the two, so they are glued.
    expect(reSegment('第一段没有句号\n第二段也没有标点。', '别的标题'), '第一段没有句号第二段也没有标点。');
  });

  test('the chapter title is not repeated as the first paragraph', () {
    expect(reSegment('第一章\n正文第一段。\n第二段。', '第一章'), '正文第一段。\n第二段。');
    // A different title keeps the first paragraph.
    expect(reSegment('第一章\n正文第一段。\n第二段。', '别的标题'), '第一章正文第一段。\n第二段。');
  });

  test('the ideographic space is removed inside a paragraph', () {
    expect(reSegment('前　言。', '第一章'), '前言。');
  });

  test(
    'an ASCII quote sequence is normalized the way the frozen stage does',
    () {
      expect(reSegment('他说："你好"。', '第一章'), '他说：“你好”。');
    },
  );

  test('the frozen `(？。！?!~)` group is a sequence, not a class', () {
    // `ContentHelp.kt:60-61` writes `(？。！?!~)`, which matches the literal
    // sequence `？。!~` (with `！` optional) rather than one punctuation
    // character, so the frozen reader never breaks at a quote followed by a
    // sentence end. The port preserves that, including its unobservable effect.
    expect(reSegment('“你好”。他走了。', '第一章'), '“你好”。他走了。');
  });

  group('a long paragraph (forceSplit, under a seed)', () {
    const long = '一。二。三。四。五。六。七。八。九。十。';

    test('inserts breaks and only breaks', () {
      final split = reSegment(long, '第一章', random: Random(2));
      expect(split.split('\n').length, greaterThan(1));
      expect(split.replaceAll('\n', ''), long);
    });

    test('is deterministic for one seed and varies with the seed', () {
      expect(
        reSegment(long, '第一章', random: Random(2)),
        reSegment(long, '第一章', random: Random(2)),
      );
      final outputs = {
        for (var seed = 0; seed < 8; seed++)
          reSegment(long, '第一章', random: Random(seed)),
      };
      expect(outputs.length, greaterThan(1));
    });

    test('a run shorter than the trigger never reaches the random branch', () {
      // Fewer than two sentence ends and fewer than six mid punctuation marks
      // short-circuits forceSplit (`ContentHelp.kt:143`), so no seed can break
      // it.
      for (var seed = 0; seed < 10; seed++) {
        expect(reSegment('一句话。', '第一章', random: Random(seed)), '一句话。');
        expect(
          reSegment('两句话，中间一个逗号。', '第一章', random: Random(seed)),
          '两句话，中间一个逗号。',
        );
      }
    });
  });
}
