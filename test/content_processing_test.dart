import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart' show SourceCancellation;
import 'package:liber/domain/store_message.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
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
    ConvertTarget? script,
    String bookName = name,
    String bookOrigin = origin,
    void Function(StoreMessage)? onNotice,
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
      final content = (await processing([
        rule(pattern: '广告', replacement: '', isEnabled: false, isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(content, '　　本章有广告内容');
    });

    test('scope is a substring of the book name or the origin', () async {
      final byName = (await processing([
        rule(pattern: '广告', scope: '不科学御兽;http://other.test', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(byName, '　　本章有内容');

      final byOrigin = (await processing([
        rule(pattern: '广告', scope: '某书;http://www.beqege.cc', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(byOrigin, '　　本章有内容');

      // The name is the needle: a scope the name merely contains does not match.
      final neither = (await processing([
        rule(pattern: '广告', scope: '御兽', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(neither, '　　本章有广告内容');

      final otherBook = (await processing([
        rule(pattern: '广告', scope: '别的书;http://other.test', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(otherBook, '　　本章有广告内容');
    });

    test('a null or empty scope reaches every book', () async {
      for (final scope in [null, '']) {
        final content = (await processing([
          rule(pattern: '广告', scope: scope, isRegex: false),
        ]).content('本章有广告内容', chapterTitle: '第一章')).text;
        expect(content, '　　本章有内容', reason: 'scope=$scope');
      }
    });

    test('scope folding is ASCII, as SQLite LIKE is', () async {
      final content = (await processing([
        rule(
          pattern: '广告',
          scope: '不科学御兽;HTTP://WWW.BEQEGE.CC',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(content, '　　本章有内容');
    });

    test('excludeScope removes the book, an empty one does not', () async {
      final excluded = (await processing([
        rule(
          pattern: '广告',
          excludeScope: '不科学御兽;http://other.test',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(excluded, '　　本章有广告内容');

      final empty = (await processing([
        rule(pattern: '广告', excludeScope: '', isRegex: false),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(empty, '　　本章有内容');
    });

    test('excludeScope removes the book by origin too', () async {
      final content = (await processing([
        rule(
          pattern: '广告',
          excludeScope: 'book@http://www.beqege.cc',
          isRegex: false,
        ),
      ]).content('本章有广告内容', chapterTitle: '第一章')).text;
      expect(content, '　　本章有广告内容');
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
      expect(
        (await titleOnly.content('正文第1章', chapterTitle: '别的标题')).text,
        '　　正文第1章',
      );

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
      expect(
        (await contentOnly.content('正文第1章', chapterTitle: '别的标题')).text,
        '　　内容第1章',
      );
    });

    test('rules run in order, and one order keeps the store order', () async {
      final ordered = (await processing([
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
      ]).content('1', chapterTitle: '别的标题')).text;
      expect(ordered, '　　2');

      // Two rules with the same order: the store's own order decides, so the
      // ('1' -> 'x') rule runs after ('x' -> '2') and '1' stays.
      final stable = (await processing([
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
      ]).content('1', chapterTitle: '别的标题')).text;
      expect(stable, '　　x');
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
      final content = (await processing([
        rule(pattern: '广告', replacement: '', isRegex: false),
        rule(pattern: r'(\d+)字', replacement: r'$1 字', ruleOrder: 1),
      ]).content('本章有广告，共20字', chapterTitle: '第一章')).text;
      expect(content, '　　本章有，共20 字');
    });

    test(
      'the replace stage trims every line before the rules see it',
      () async {
        final withoutTrim = (await processing([
          rule(pattern: r'^开始', replacement: '起', ruleOrder: 1),
        ]).content('  开始', chapterTitle: '别的标题')).text;
        expect(
          withoutTrim,
          '　　起',
          reason: 'the leading spaces are gone before ^开始',
        );

        final everyLine = (await processing([
          rule(pattern: r'(?m)^开始', replacement: '起', ruleOrder: 1),
        ]).content('  开始\n   开始', chapterTitle: '别的标题')).text;
        expect(everyLine, '　　起\n　　起');
      },
    );

    test('a duplicated leading title is removed', () async {
      final content = (await processing(
        const [],
      ).content('第一章 开始\n正文开始。', chapterTitle: '第一章 开始')).text;
      expect(content, '　　正文开始。');
    });

    test(
      'the title pattern tolerates whitespace runs and the book name',
      () async {
        final content = (await processing(
          const [],
        ).content('不科学御兽 第一章\n正文。', chapterTitle: '第一章')).text;
        expect(content, '　　正文。');
      },
    );

    test(
      'the title pattern preserves Java ASCII whitespace semantics',
      () async {
        final content = (await processing(
          const [],
        ).content('第一章　标题\n正文。', chapterTitle: '第一章　标题')).text;
        expect(content, '　　正文。');
      },
    );

    test('the retry uses the content rules to find the title', () async {
      final content = (await processing([
        rule(pattern: '第1章', replacement: '第一章', id: 'retitle'),
      ]).content('第一章 正文。', chapterTitle: '第1章')).text;
      expect(content, '　　正文。');
    });

    test('includeTitle prepends the display title as its own line', () async {
      final content = (await processing([
        rule(pattern: '网', replacement: '', scopeTitle: true),
      ]).content('正文。', chapterTitle: '第一网章', includeTitle: true)).text;
      expect(content, '第一章\n　　正文。');
    });

    test('a body that is the literal null is not processed', () async {
      final content = (await processing([
        rule(pattern: 'null', replacement: 'x'),
      ]).content('null', chapterTitle: '第一章')).text;
      expect(content, 'null');
    });
  });

  group('the final paragraph shaping (ContentProcessor.kt:185-201)', () {
    test('every paragraph is indented and blank lines are dropped', () async {
      final content = (await processing(
        const [],
      ).content('第一段。\n\n　第二段。　\n', chapterTitle: '别的标题')).text;
      expect(content, '　　第一段。\n　　第二段。');
    });

    test(
      'the frozen cutset is code <= 0x20 and the ideographic space',
      () async {
        // Dart's String.trim also removes U+00A0 and friends; the frozen
        // `trim { it.code <= 0x20 || it == '　' }` does not, so the reader text
        // the pinned oracle compares keeps them.
        final content = (await processing(
          const [],
          useReplaceRule: false,
        ).content('\u00A0正文\u00A0', chapterTitle: '别的标题')).text;
        expect(content, '　　\u00A0正文\u00A0');
      },
    );

    test('includeTitle leaves the first paragraph unindented', () async {
      final content = (await processing(
        const [],
      ).content('正文。\n续。', chapterTitle: '第一章', includeTitle: true)).text;
      expect(content, '第一章\n　　正文。\n　　续。');
    });
  });

  group('the re-segmentation stage (ContentProcessor.kt:131-133)', () {
    test('the per-book flag is off by default', () async {
      final content = (await processing(
        const [],
      ).content('第一段没有句号\n第二段也没有标点。', chapterTitle: '别的标题')).text;
      expect(content, '　　第一段没有句号\n　　第二段也没有标点。');
    });

    test('the flag runs it after the duplicated title is removed', () async {
      final content = (await processing(
        const [],
        useReSegment: true,
      ).content('第一章 标题\n\n第一段没有句号\n第二段也没有标点。', chapterTitle: '第一章 标题')).text;
      expect(content, '　　第一段没有句号第二段也没有标点。');
    });

    test('the content rules see the re-segmented body', () async {
      final body = '第一段没有句号\n第二段也没有标点。';
      // `句号第二段` only exists once the two paragraphs are glued, so a rule
      // that matches it proves the stage ran before the rules.
      final on = (await processing([
        rule(pattern: '句号第二段', replacement: 'X', isRegex: false),
      ], useReSegment: true).content(body, chapterTitle: '别的标题')).text;
      expect(on, '　　第一段没有X也没有标点。');

      final off = (await processing([
        rule(pattern: '句号第二段', replacement: 'X', isRegex: false),
      ]).content(body, chapterTitle: '别的标题')).text;
      expect(off, '　　第一段没有句号\n　　第二段也没有标点。');
    });

    test('the display title is still prepended last', () async {
      final content = (await processing(const [], useReSegment: true).content(
        '第一段没有句号\n第二段也没有标点。',
        chapterTitle: '第一章',
        includeTitle: true,
      )).text;
      expect(content, '第一章\n　　第一段没有句号第二段也没有标点。');
    });
  });

  group('replacement JavaScript and named skips', () {
    test('an enabled @js: replacement sees the complete match', () async {
      final content = (await processing([
        rule(
          pattern: r'(\d+)字',
          replacement: r'@js:result + ":" + result.match(/(\d+)字/)[1] + " $1"',
          ruleName: 'JS 规则',
        ),
      ]).content('共20字和30字', chapterTitle: '第一章')).text;
      expect(content, '　　共20字:20 \$1和30字:30 \$1');
    });

    test('a disabled @js: replacement remains inactive', () async {
      final notices = <StoreMessage>[];
      final content = (await processing([
        rule(
          pattern: '广告',
          replacement: '@js:result + "!"',
          ruleName: '停用 JS 规则',
          isEnabled: false,
        ),
      ], onNotice: notices.add).content('广告', chapterTitle: '第一章')).text;
      expect(content, '　　广告');
      expect(notices, isEmpty);
    });

    test(
      'a JavaScript replacement error keeps the text and is reported',
      () async {
        final notices = <StoreMessage>[];
        final content = (await processing([
          rule(
            pattern: '广告',
            replacement: '@js:throw new Error("boom")',
            ruleName: '出错 JS 规则',
          ),
        ], onNotice: notices.add).content('广告', chapterTitle: '第一章')).text;
        expect(content, '　　广告');
        expect(notices, hasLength(1));
        expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
        expect(notices.single.arguments.first, '出错 JS 规则');
      },
    );

    test('cancellation keeps the text without reporting an error', () async {
      final cancellation = SourceCancellation()..cancel();
      final notices = <StoreMessage>[];
      final content = (await processing(
        [
          rule(
            pattern: '广告',
            replacement: '@js:result + "!"',
            ruleName: '取消 JS 规则',
          ),
        ],
        cancellation: cancellation,
        onNotice: notices.add,
      ).content('广告', chapterTitle: '第一章')).text;
      expect(content, '　　广告');
      expect(notices, isEmpty);
    });

    test(
      'cancellation during match-worker startup leaves the title unchanged',
      () async {
        final cancellation = SourceCancellation();
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              pattern: '广告',
              replacement: '@js:result + "!"',
              scopeTitle: true,
            ),
          ],
          cancellation: cancellation,
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        final title = processor.displayTitle('广告');
        cancellation.cancel();
        expect(await title, '广告');
        expect(notices, isEmpty);
        expect(disabled, isEmpty);
      },
    );

    test('a JavaScript replacement timeout disables the rule', () async {
      final disabled = <String>[];
      final notices = <StoreMessage>[];
      final content = (await processing(
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
      ).content('广告', chapterTitle: '第一章')).text;
      expect(content, '　　广告');
      expect(disabled, ['js-slow']);
      expect(notices, hasLength(1));
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['超时 JS 规则', 100]);
    });

    test('an ordinary regex replacement remains unchanged', () async {
      final content = (await processing([
        rule(pattern: r'(\d+)字', replacement: r'$1 字'),
      ]).content('共20字', chapterTitle: '第一章')).text;
      expect(content, '　　共20 字');
    });

    test('a pattern the engine cannot express is refused by name', () async {
      final notices = <StoreMessage>[];
      final content = (await processing([
        rule(pattern: r'a*+', replacement: 'x', ruleName: '占有量词'),
      ], onNotice: notices.add).content('aaab', chapterTitle: '第一章')).text;
      expect(content, '　　aaab');
      expect(notices.single.code, StoreMessageCode.replaceRuleUnusable);
      expect(notices.single.arguments.first, '占有量词');
    });
  });

  group('the timeout', () {
    test('a rule past its own deadline is disabled and its text kept', () async {
      final disabled = <String>[];
      final notices = <StoreMessage>[];
      final content = (await processing(
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
      ).content('${'a' * 32}b', chapterTitle: '第一章')).text;
      // The fast rule ran, the slow one was killed at its own deadline and left
      // the text as it was, and the rule after it still ran.
      expect(content, '　　${'a' * 32}d');
      expect(disabled, ['slow']);
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['灾难回溯', 200]);
    });

    test('a fast rule under its deadline is never reported', () async {
      var disableCalls = 0;
      final content = (await processing(
        [
          rule(
            pattern: r'第(\d+)章',
            replacement: r'第$1章（改）',
            timeoutMillisecond: 2000,
          ),
        ],
        onRuleDisabled: (rule) async => disableCalls++,
      ).content('正文第1章', chapterTitle: '别的标题')).text;
      expect(content, '　　正文第1章（改）');
      expect(disableCalls, 0);
    });
  });

  group('conversion, in the frozen position', () {
    test('the rules see converted content', () async {
      final content = (await processing(
        [rule(pattern: '龙', replacement: '龙（已转换）', isRegex: false)],
        script: ConvertTarget.simplifiedMainland,
      ).content('龍與鳳', chapterTitle: '第一章')).text;
      expect(content, contains('龙（已转换）'));
    });

    test('a converted title is what the title rules match', () async {
      final title = await processing([
        rule(pattern: r'^龙', replacement: '龙首', scopeTitle: true),
      ], script: ConvertTarget.simplifiedMainland).displayTitle('龍鳳');
      expect(title, '龙首凤');
    });

    test('目录行只转换标题：规则留给阅读页本身', () async {
      // The frozen list applies the title rules only when
      // `AppConfig.tocUiUseReplace` is on (`ChapterListAdapter.kt:78`, default
      // false), while the reader's own title converts first and then runs them.
      final titleRules = processing([
        rule(pattern: '凤', replacement: '凤首', scopeTitle: true),
      ], script: ConvertTarget.simplifiedMainland);
      expect(titleRules.listTitle('龍鳳'), '龙凤');
      expect(await titleRules.displayTitle('龍鳳'), '龙凤首');
    });

    test('没有目标时目录行不转换，阅读页的标题规则照旧', () async {
      final none = processing([
        rule(pattern: '龍', replacement: '龙首', scopeTitle: true),
      ]);
      expect(none.listTitle('龍鳳'), '龍鳳');
      expect(await none.displayTitle('龍鳳'), '龙首鳳');
    });
  });
}
