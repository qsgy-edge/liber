import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart' show SourceCancellation;
import 'package:liber/local/reader_engine.dart' show ReaderScript;
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart';

import 'native_library.dart';

/// The user's replace rules on the two paths the frozen reader applies them to:
/// the chapter title (`BookChapter.getDisplayTitle`) and the chapter body
/// (`ContentProcessor.getContent`).
///
/// A plain (non-widget) test: the conversion cases go through the text engine in
/// the native library, which only this binding lets settle.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));

  const name = '不科学御兽';
  const origin = 'http://www.beqege.cc';

  ReplaceRule rule({
    String id = 'r1',
    String ruleName = '净化',
    String pattern = '',
    String replacement = '',
    String? scope,
    String? excludeScope,
    bool scopeTitle = false,
    bool scopeContent = true,
    bool isEnabled = true,
    bool isRegex = true,
    int timeoutMillisecond = 0,
    int ruleOrder = 0,
  }) => ReplaceRule(
    id: id,
    name: ruleName,
    groupName: '',
    pattern: pattern,
    replacement: replacement,
    scope: scope,
    excludeScope: excludeScope,
    scopeTitle: scopeTitle,
    scopeContent: scopeContent,
    isEnabled: isEnabled,
    isRegex: isRegex,
    timeoutMillisecond: timeoutMillisecond,
    ruleOrder: ruleOrder,
  );

  ContentProcessing processing(
    List<ReplaceRule> rules, {
    ReaderScript? script,
    String bookName = name,
    String bookOrigin = origin,
    void Function(String)? onNotice,
    Future<void> Function(ReplaceRule)? onRuleDisabled,
    SourceCancellation? cancellation,
    bool useReplaceRule = true,
    bool useReSegment = false,
  }) => ContentProcessing(
    rules: ReplaceRuleSet.forBook(
      rules,
      bookName: bookName,
      bookOrigin: bookOrigin,
    ),
    bookName: bookName,
    script: script,
    onNotice: onNotice,
    onRuleDisabled: onRuleDisabled,
    cancellation: cancellation,
    useReplaceRule: useReplaceRule,
    useReSegment: useReSegment,
  );

  group('selection (the frozen ReplaceRuleDao statement)', () {
    test('a disabled rule never runs', () async {
      final content = await processing([
        rule(pattern: '广告', replacement: '', isEnabled: false, isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(content, '本章有广告内容');
    });

    test('scope is a substring of the book name or the origin', () async {
      final byName = await processing([
        rule(pattern: '广告', scope: '不科学御兽;http://other.test', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(byName, '本章有内容');

      final byOrigin = await processing([
        rule(pattern: '广告', scope: '某书;http://www.beqege.cc', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(byOrigin, '本章有内容');

      // The name is the needle: a scope the name merely contains does not match.
      final neither = await processing([
        rule(pattern: '广告', scope: '御兽', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(neither, '本章有广告内容');

      final otherBook = await processing([
        rule(pattern: '广告', scope: '别的书;http://other.test', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(otherBook, '本章有广告内容');
    });

    test('a null or empty scope reaches every book', () async {
      for (final scope in [null, '']) {
        final content = await processing([
          rule(pattern: '广告', scope: scope, isRegex: false),
        ]).content('本章有广告内容', chapterTitle: '第一章');
        expect(content, '本章有内容', reason: 'scope=$scope');
      }
    });

    test('scope folding is ASCII, as SQLite LIKE is', () async {
      final content = await processing([
        rule(
          pattern: '广告',
          scope: '不科学御兽;HTTP://WWW.BEQEGE.CC',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(content, '本章有内容');
    });

    test('excludeScope removes the book, an empty one does not', () async {
      final excluded = await processing([
        rule(
          pattern: '广告',
          excludeScope: '不科学御兽;http://other.test',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(excluded, '本章有广告内容');

      final empty = await processing([
        rule(pattern: '广告', excludeScope: '', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(empty, '本章有内容');
    });

    test('excludeScope removes the book by origin too', () async {
      final content = await processing([
        rule(
          pattern: '广告',
          excludeScope: 'book@http://www.beqege.cc',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章');
      expect(content, '本章有广告内容');
    });

    test('the two scope columns gate their own path', () async {
      final titleOnly = processing([
        rule(
          pattern: '第',
          replacement: '一',
          scopeTitle: true,
          scopeContent: false,
          isRegex: false,
        ),
      ]);
      expect(await titleOnly.displayTitle('第1章'), '一1章');
      expect(await titleOnly.content('正文第1章', chapterTitle: '别的标题'), '正文第1章');

      final contentOnly = processing([
        rule(
          pattern: '正文',
          replacement: '内容',
          scopeTitle: false,
          scopeContent: true,
          isRegex: false,
        ),
      ]);
      expect(await contentOnly.displayTitle('第1章'), '第1章');
      expect(await contentOnly.content('正文第1章', chapterTitle: '别的标题'), '内容第1章');
    });

    test('rules run in order, and one order keeps the store order', () async {
      final ordered = await processing([
        rule(
          id: 'b',
          pattern: 'x',
          replacement: '2',
          ruleOrder: 5,
          isRegex: false,
        ),
        rule(
          id: 'a',
          pattern: '1',
          replacement: 'x',
          ruleOrder: 1,
          isRegex: false,
        ),
      ]).content('1', chapterTitle: '别的标题');
      expect(ordered, '2');

      // Two rules with the same order: the store's own order decides, so the
      // ('1' -> 'x') rule runs after ('x' -> '2') and '1' stays.
      final stable = await processing([
        rule(
          id: 'b',
          pattern: 'x',
          replacement: '2',
          ruleOrder: 5,
          isRegex: false,
        ),
        rule(
          id: 'a',
          pattern: '1',
          replacement: 'x',
          ruleOrder: 5,
          isRegex: false,
        ),
      ]).content('1', chapterTitle: '别的标题');
      expect(stable, 'x');
    });
  });

  group('the chapter title (BookChapter.getDisplayTitle)', () {
    test('rules apply, line breaks are stripped first', () async {
      final title = await processing([
        rule(pattern: r'^\d+', replacement: '', scopeTitle: true),
      ]).displayTitle('12\n第一章');
      expect(title, '第一章');
    });

    test('a blank result is rejected and the title stays', () async {
      final title = await processing([
        rule(pattern: '.*', replacement: '   ', scopeTitle: true),
      ]).displayTitle('第一章');
      expect(title, '第一章');
    });

    test('a literal title rule replaces every occurrence', () async {
      final title = await processing([
        rule(pattern: '网', replacement: '', scopeTitle: true, isRegex: false),
      ]).displayTitle('第一网章网');
      expect(title, '第一章');
    });

    test('the per-book switch turns the rules off', () async {
      final title = await processing([
        rule(pattern: '第', replacement: '一', scopeTitle: true, isRegex: false),
      ], useReplaceRule: false).displayTitle('第1章');
      expect(title, '第1章');
    });
  });

  group('the chapter body (ContentProcessor.getContent)', () {
    test('a literal rule, a regex rule with a capture group', () async {
      final content = await processing([
        rule(pattern: '广告', replacement: '', isRegex: false),
        rule(pattern: r'(\d+)字', replacement: r'$1 字', ruleOrder: 1),
      ]).content('本章有广告，共20字', chapterTitle: '第一章');
      expect(content, '本章有，共20 字');
    });

    test(
      'the replace stage trims every line before the rules see it',
      () async {
        final withoutTrim = await processing([
          rule(pattern: r'^开始', replacement: '起', ruleOrder: 1),
        ]).content('  开始', chapterTitle: '别的标题');
        expect(
          withoutTrim,
          '起',
          reason: 'the leading spaces are gone before ^开始',
        );

        final everyLine = await processing([
          rule(pattern: r'(?m)^开始', replacement: '起', ruleOrder: 1),
        ]).content('  开始\n   开始', chapterTitle: '别的标题');
        expect(everyLine, '起\n起');
      },
    );

    test('a duplicated leading title is removed', () async {
      final content = await processing(
        const [],
      ).content('第一章 开始\n正文开始。', chapterTitle: '第一章 开始');
      expect(content, '正文开始。');
    });

    test(
      'the title pattern tolerates whitespace runs and the book name',
      () async {
        final content = await processing(
          const [],
        ).content('不科学御兽 第一章\n正文。', chapterTitle: '第一章');
        expect(content, '正文。');
      },
    );

    test(
      'the title pattern preserves Java ASCII whitespace semantics',
      () async {
        final content = await processing(
          const [],
        ).content('第一章　标题\n正文。', chapterTitle: '第一章　标题');
        expect(content, '正文。');
      },
    );

    test('the retry uses the content rules to find the title', () async {
      final content = await processing([
        rule(pattern: '第1章', replacement: '第一章', id: 'retitle'),
      ]).content('第一章 正文。', chapterTitle: '第1章');
      expect(content, '正文。');
    });

    test('includeTitle prepends the display title as its own line', () async {
      final content = await processing([
        rule(pattern: '网', replacement: '', scopeTitle: true),
      ]).content('正文。', chapterTitle: '第一网章', includeTitle: true);
      expect(content, '第一章\n正文。');
    });

    test('a body that is the literal null is not processed', () async {
      final content = await processing([
        rule(pattern: 'null', replacement: 'x'),
      ]).content('null', chapterTitle: '第一章');
      expect(content, 'null');
    });
  });

  group('the re-segmentation stage (ContentProcessor.kt:131-133)', () {
    test('the per-book flag is off by default', () async {
      final content = await processing(
        const [],
      ).content('第一段没有句号\n第二段也没有标点。', chapterTitle: '别的标题');
      expect(content, '第一段没有句号\n第二段也没有标点。');
    });

    test('the flag runs it after the duplicated title is removed', () async {
      final content = await processing(
        const [],
        useReSegment: true,
      ).content('第一章 标题\n\n第一段没有句号\n第二段也没有标点。', chapterTitle: '第一章 标题');
      expect(content, '第一段没有句号第二段也没有标点。');
    });

    test('the content rules see the re-segmented body', () async {
      final body = '第一段没有句号\n第二段也没有标点。';
      // `句号第二段` only exists once the two paragraphs are glued, so a rule
      // that matches it proves the stage ran before the rules.
      final on = await processing([
        rule(pattern: '句号第二段', replacement: 'X', isRegex: false),
      ], useReSegment: true).content(body, chapterTitle: '别的标题');
      expect(on, '第一段没有X也没有标点。');

      final off = await processing([
        rule(pattern: '句号第二段', replacement: 'X', isRegex: false),
      ]).content(body, chapterTitle: '别的标题');
      expect(off, body);
    });

    test('the display title is still prepended last', () async {
      final content = await processing(
        const [],
        useReSegment: true,
      ).content('第一段没有句号\n第二段也没有标点。', chapterTitle: '第一章', includeTitle: true);
      expect(content, '第一章\n第一段没有句号第二段也没有标点。');
    });
  });

  group('replacement JavaScript and named skips', () {
    test('an enabled @js: replacement sees the complete match', () async {
      final content = await processing([
        rule(
          pattern: r'(\d+)字',
          replacement: r'@js:result + ":" + result.match(/(\d+)字/)[1] + " $1"',
          ruleName: 'JS 规则',
        ),
      ]).content('共20字和30字', chapterTitle: '第一章');
      expect(content, '共20字:20 \$1和30字:30 \$1');
    });

    test('a disabled @js: replacement remains inactive', () async {
      final notices = <String>[];
      final content = await processing([
        rule(
          pattern: '广告',
          replacement: '@js:result + "!"',
          ruleName: '停用 JS 规则',
          isEnabled: false,
        ),
      ], onNotice: notices.add).content('广告', chapterTitle: '第一章');
      expect(content, '广告');
      expect(notices, isEmpty);
    });

    test(
      'a JavaScript replacement error keeps the text and is reported',
      () async {
        final notices = <String>[];
        final content = await processing([
          rule(
            pattern: '广告',
            replacement: '@js:throw new Error("boom")',
            ruleName: '出错 JS 规则',
          ),
        ], onNotice: notices.add).content('广告', chapterTitle: '第一章');
        expect(content, '广告');
        expect(notices, hasLength(1));
        expect(notices.single, contains('出错 JS 规则'));
      },
    );

    test('cancellation keeps the text without reporting an error', () async {
      final cancellation = SourceCancellation()..cancel();
      final notices = <String>[];
      final content = await processing(
        [
          rule(
            pattern: '广告',
            replacement: '@js:result + "!"',
            ruleName: '取消 JS 规则',
          ),
        ],
        cancellation: cancellation,
        onNotice: notices.add,
      ).content('广告', chapterTitle: '第一章');
      expect(content, '广告');
      expect(notices, isEmpty);
    });

    test('a JavaScript replacement timeout disables the rule', () async {
      final disabled = <String>[];
      final notices = <String>[];
      final content = await processing(
        [
          rule(
            id: 'js-slow',
            pattern: '广告',
            replacement: '@js:while (true) {}',
            ruleName: '超时 JS 规则',
            timeoutMillisecond: 100,
          ),
        ],
        onNotice: notices.add,
        onRuleDisabled: (rule) async {
          disabled.add(rule.id);
        },
      ).content('广告', chapterTitle: '第一章');
      expect(content, '广告');
      expect(disabled, ['js-slow']);
      expect(notices, hasLength(1));
      expect(notices.single, contains('超时 JS 规则'));
      expect(notices.single, contains('超时'));
    });

    test('an ordinary regex replacement remains unchanged', () async {
      final content = await processing([
        rule(pattern: r'(\d+)字', replacement: r'$1 字'),
      ]).content('共20字', chapterTitle: '第一章');
      expect(content, '共20 字');
    });

    test('a pattern the engine cannot express is refused by name', () async {
      final notices = <String>[];
      final content = await processing([
        rule(pattern: r'a*+', replacement: 'x', ruleName: '占有量词'),
      ], onNotice: notices.add).content('aaab', chapterTitle: '第一章');
      expect(content, 'aaab');
      expect(notices.single, contains('占有量词'));
      expect(notices.single, contains('不可用'));
    });
  });

  group('the timeout', () {
    test('a rule past its own deadline is disabled and its text kept', () async {
      final disabled = <String>[];
      final notices = <String>[];
      final content = await processing(
        [
          rule(id: 'fast', pattern: 'b', replacement: 'c', ruleOrder: 1),
          rule(
            id: 'slow',
            ruleName: '灾难回溯',
            pattern: r'(a+)+$',
            replacement: '',
            timeoutMillisecond: 200,
            ruleOrder: 2,
          ),
          rule(
            id: 'after',
            pattern: 'c',
            replacement: 'd',
            ruleOrder: 3,
            isRegex: false,
          ),
        ],
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      ).content('${'a' * 32}b', chapterTitle: '第一章');
      // The fast rule ran, the slow one was killed at its own deadline and left
      // the text as it was, and the rule after it still ran.
      expect(content, '${'a' * 32}d');
      expect(disabled, ['slow']);
      expect(notices.single, contains('灾难回溯'));
      expect(notices.single, contains('超时'));
    });

    test('a fast rule under its deadline is never reported', () async {
      var disableCalls = 0;
      final content = await processing(
        [
          rule(
            pattern: r'第(\d+)章',
            replacement: r'第$1章（改）',
            timeoutMillisecond: 2000,
          ),
        ],
        onRuleDisabled: (rule) async => disableCalls++,
      ).content('正文第1章', chapterTitle: '别的标题');
      expect(content, '正文第1章（改）');
      expect(disableCalls, 0);
    });
  });

  group('conversion, in the frozen position', () {
    test('the rules see converted content', () async {
      final content = await processing([
        rule(pattern: '龙', replacement: '龙（已转换）', isRegex: false),
      ], script: ReaderScript.simplified).content('龍與鳳', chapterTitle: '第一章');
      expect(content, contains('龙（已转换）'));
    });

    test('a converted title is what the title rules match', () async {
      final title = await processing([
        rule(pattern: r'^龙', replacement: '龙首', scopeTitle: true),
      ], script: ReaderScript.simplified).displayTitle('龍鳳');
      expect(title, '龙首凤');
    });
  });
}
