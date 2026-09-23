import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/chapter_position.dart';

/// The frozen reader's chapter-position mapping, ported for switch-source
/// (`BookHelp.getDurChapter`, frozen baseline `14dd24945`, `BookHelp.kt:493-540`
/// and the helpers it reads).
///
/// What these tests can assert is the port's behaviour on the frozen source's
/// own terms: each case below was worked through the frozen code by hand, the
/// expectations are those hand computations, and no frozen oracle row is
/// claimed (`docs/compatibility/delivery-phases.md`: P6 is product work over
/// search/information/TOC).
void main() {
  group('chapterNumberOf', () {
    test('reads a chapter number through either frozen pattern', () {
      // Pattern 1, `第([num]+)[章节篇回集话]`: digits and Chinese numerals alike.
      expect(chapterNumberOf('第一章'), 1);
      expect(chapterNumberOf('第3章 空'), 3);
      expect(chapterNumberOf('第１２章'), 12, reason: 'fullToHalf before matching');
      expect(chapterNumberOf('第三章 初入宗门'), 3);
      // Pattern 2, the number-then-punctuation form.
      expect(chapterNumberOf('三、入门'), 3);
      expect(chapterNumberOf('12,启程'), 12);
      // `StringUtils.chineseNumToInt`'s trailing shorthand (`一千二` → 1200),
      // the same reading `java.toNumChapter` answers
      // (`docs/compatibility/host-surface-43.md`).
      expect(chapterNumberOf('第一千二章'), 1200);
      // No number anywhere: the frozen `stringToInt("-1")`.
      expect(chapterNumberOf('序章'), -1);
      expect(chapterNumberOf(null), -1);
    });
  });

  group('pureChapterName', () {
    test('keeps the words and drops the numbering, blanks and punctuation', () {
      expect(pureChapterName('第三章 初入宗门'), '初入宗门');
      expect(pureChapterName('第3章、初入宗门'), '初入宗门');
      expect(pureChapterName('第10章 试炼（上）'), '试炼');
      expect(pureChapterName('　第三章　初入宗门　'), '初入宗门');
      expect(pureChapterName('楔子'), '楔子');
      // `regexB`'s negative look-ahead: a title that is nothing but its number
      // keeps the number instead of emptying.
      expect(pureChapterName('第一章'), '第一章');
      expect(pureChapterName('第１２章'), '第12章');
      expect(pureChapterName(null), '');
    });
  });

  group('chapterNameSimilarity', () {
    test(
      'is the character-set Jaccard similarity the frozen threshold reads',
      () {
        expect(chapterNameSimilarity('初入宗门', '初入宗门'), 1.0);
        expect(chapterNameSimilarity('启程', '试炼'), 0.0);
        expect(chapterNameSimilarity('初入宗门', '初入宗门上'), 4 / 5);
      },
    );
  });

  group('mapChapterIndex', () {
    test('finds the same chapter name in a reordered table of contents', () {
      // The window is ±10 around the old ordinal (5 and 5 chapters project to
      // the same index), and the name matches exactly, so the name decides.
      expect(
        mapChapterIndex(
          oldIndex: 2,
          oldTitle: '第三章 初入宗门',
          newTitles: const ['楔子', '第一章 离家', '第二章 拜师', '第三章 初入宗门', '第四章 试炼'],
          oldChapterCount: 5,
        ),
        3,
      );
    });

    test('falls back to the chapter number when the names differ', () {
      // Names share nothing (similarity 0), so the number rule decides: the
      // third position carries 三, the old number.
      expect(
        mapChapterIndex(
          oldIndex: 2,
          oldTitle: '第三章',
          newTitles: const ['一、启程', '二、拜师', '三、入门', '四、试炼'],
          oldChapterCount: 4,
        ),
        2,
      );
      // A table of contents that numbers its chapters differently: the nearest
      // number inside the window wins.
      expect(
        mapChapterIndex(
          oldIndex: 5,
          oldTitle: '第5章',
          newTitles: [for (var i = 1; i <= 20; i++) '第$i章'],
          oldChapterCount: 10,
        ),
        4,
        reason: '目录里第5章在下标 4',
      );
    });

    test('clamps to the old ordinal when neither name nor number matches', () {
      expect(
        mapChapterIndex(
          oldIndex: 2,
          oldTitle: '第三章',
          newTitles: const ['启程', '拜师', '入门', '试炼'],
          oldChapterCount: 4,
        ),
        2,
      );
      // No title and no recorded chapter count: the old ordinal, clamped to the
      // new list.
      expect(
        mapChapterIndex(
          oldIndex: 7,
          oldTitle: '',
          newTitles: const ['启程', '拜师', '入门', '试炼'],
          oldChapterCount: 0,
        ),
        3,
      );
    });

    test(
      'the first chapter stays first and an empty list answers the ordinal',
      () {
        // The frozen returns before touching the lists in either case.
        expect(
          mapChapterIndex(
            oldIndex: 0,
            oldTitle: '第一章',
            newTitles: const ['完全不同的一章'],
            oldChapterCount: 5,
          ),
          0,
        );
        expect(
          mapChapterIndex(
            oldIndex: 9,
            oldTitle: '第十章',
            newTitles: const [],
            oldChapterCount: 10,
          ),
          9,
        );
      },
    );
  });
}
