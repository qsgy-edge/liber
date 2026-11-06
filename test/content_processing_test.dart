import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart' show SourceCancellation;
import 'package:liber/domain/store_message.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime, SourceScriptError, SourceScriptRuntime;
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
    SourceScriptRuntime? scriptRuntime,
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
    scriptRuntime: scriptRuntime,
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
      expect(content, '　　共20字:20 20和30字:30 30');
    });

    test(
      'regex JS expands named, numeric and nonparticipating groups on title and body',
      () async {
        final processor = processing([
          rule(
            pattern: r'(?<word>a)(b)?',
            replacement: r'@js:"$0|$12|${word}|$2|\\$1"',
            scopeTitle: true,
          ),
        ]);
        expect(await processor.displayTitle('a'), r'a|a2|a||\a');
        expect(
          (await processor.content('a', chapterTitle: 'other')).text,
          r'　　a|a2|a||\a',
        );
      },
    );

    test('JS groups come from the original lookbehind match', () async {
      final processor = processing([
        rule(
          pattern: r'(?<=x)(?<word>a)',
          replacement: r'@js:"${word}-$0-$12"',
        ),
      ]);
      expect(
        (await processor.content('xaz', chapterTitle: 'other')).text,
        '　　xa-a-a2z',
      );
    });

    test(
      'JS numeric references take the longest existing group prefix',
      () async {
        final processor = processing([
          rule(
            pattern: r'(a)(b)(c)(d)(e)(f)(g)(h)(i)(j)(k)(l)',
            replacement: r'@js:"$12|$123|$00"',
          ),
        ]);
        expect(
          (await processor.content('abcdefghijkl', chapterTitle: 'other')).text,
          '　　l|l3|abcdefghijkl',
        );
      },
    );

    test(
      'invalid JS group on a later match rejects the whole rule once and continues',
      () async {
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              id: 'bad',
              ruleName: 'bad',
              pattern: r'(a|b)',
              replacement: r'@js:result == "a" ? "X" : "$2"',
              scopeTitle: true,
            ),
            rule(
              id: 'next',
              pattern: 'b',
              replacement: 'B',
              isRegex: false,
              ruleOrder: 1,
            ),
          ],
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        expect(await processor.displayTitle('ab'), 'ab');
        expect(
          (await processor.content('ab', chapterTitle: 'other')).text,
          '　　aB',
        );
        expect(disabled, isEmpty);
        expect(notices, hasLength(1));
        expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
        expect(notices.single.arguments.first, 'bad');
      },
    );

    test(
      'JS expanded lengths and failed atomic pass preserve raw edit mapping',
      () async {
        final expanded = await processing([
          rule(pattern: r'(a)', replacement: r'@js:"$1$1$1"'),
        ]).content('xabz', chapterTitle: 'other');
        expect(expanded.text, '　　xaaabz');
        expect(
          expanded.edits.map((e) => '${e.start}:${e.end}:${e.length}'),
          contains('1:2:3'),
        );
        final failed = await processing([
          rule(
            pattern: r'(a|b)',
            replacement: r'@js:result == "a" ? "long" : "$2"',
          ),
        ]).content('xabz', chapterTitle: 'other');
        final unchanged = await processing(
          [],
        ).content('xabz', chapterTitle: 'other');
        expect(failed.text, unchanged.text);
        expect(
          failed.edits.map((e) => '${e.start}:${e.end}:${e.length}'),
          unchanged.edits.map((e) => '${e.start}:${e.end}:${e.length}'),
        );
      },
    );

    test(
      'malformed JS group references preserve body without disabling',
      () async {
        for (final template in [
          r'$',
          r'$x',
          r'${1}',
          r'${missing}',
          r'${name',
          r'$2',
        ]) {
          final notices = <StoreMessage>[];
          final disabled = <String>[];
          final processor = processing(
            [rule(pattern: r'(a)', replacement: '@js:${jsonEncode(template)}')],
            onNotice: notices.add,
            onRuleDisabled: (rule) async => disabled.add(rule.id),
          );
          expect(
            (await processor.content('a', chapterTitle: 'other')).text,
            '　　a',
            reason: template,
          );
          expect(
            notices.single.code,
            StoreMessageCode.replaceRuleFailed,
            reason: template,
          );
          expect(disabled, isEmpty);
        }
      },
    );

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
        // The error argument carries the script's own message, where the rule
        // path kept only the bare category before #89; the engine's stack frames
        // stay part of the engine's message, as they already are on the login
        // paths.
        expect(notices.single.arguments[1], startsWith('js: Error: boom'));
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

    test(
      'a JavaScript replacement timeout can be reported without disabling',
      () async {
        final notices = <StoreMessage>[];
        final content = (await processing([
          rule(
            id: 'js-slow-no-disable',
            pattern: '广告',
            replacement: '@js:while (true) {}',
            ruleName: '超时 JS 规则',
            timeoutMillisecond: 100,
          ),
        ], onNotice: notices.add).content('广告', chapterTitle: '第一章')).text;

        expect(content, '　　广告');
        expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
        expect(notices.single.arguments, ['超时 JS 规则', 100]);
      },
    );

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

  group('the capture-expansion resource boundary', () {
    // These cases move megabytes through one rule. The product deadline is not
    // what they exercise, so they carry enough of it that a loaded test host
    // cannot turn a resource case into a timeout case.
    const resourceTimeout = 30000;

    test(
      'a bounded capture expansion past the limit fails the rule atomically',
      () async {
        // The bounded repro: a 3072-character capture repeated 4096 times asks
        // for 12,582,912 bytes, past the approved 8 MiB policy.
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              id: 'bounded-expansion',
              ruleName: 'bounded-expansion',
              pattern: r'^(a+)$',
              replacement: r'@js:"$1".repeat(4096)',
              scopeTitle: true,
            ),
          ],
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        final capture = 'a' * 3072;
        expect(await processor.displayTitle(capture), capture);
        expect(disabled, isEmpty);
        expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
        expect(notices.single.arguments.first, 'bounded-expansion');
      },
    );

    test('the exact limit succeeds and one byte more fails', () async {
      // A 32 KiB match keeps the script and its `result` binding under the
      // runtime's existing 64 KiB input cap; 256 references of it are exactly
      // 8 MiB.
      const capture = 32 * 1024;
      final exact = await processing([
        rule(
          pattern: r'(a{32768})',
          replacement: r'@js:"$1".repeat(256)',
          timeoutMillisecond: resourceTimeout,
        ),
      ]).content('a' * capture, chapterTitle: 'other');
      expect(exact.text.length, 2 + 8 * 1024 * 1024);

      final notices = <StoreMessage>[];
      final over = await processing(
        [
          rule(
            pattern: r'(a{32768})(b)',
            replacement: r'@js:"$1".repeat(256) + "$2"',
            timeoutMillisecond: resourceTimeout,
          ),
        ],
        onNotice: notices.add,
      ).content('${'a' * capture}b', chapterTitle: 'other');
      expect(over.text, '　　${'a' * capture}b');
      expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
    });

    test('capture bytes are UTF-8, not UTF-16', () async {
      // 16,384 U+00E9 are 32 KiB of UTF-8 bytes: 256 references are exactly
      // the limit, 257 pass it. A UTF-16 count would let 257 through.
      const capture = 16 * 1024;
      final exact = await processing([
        rule(
          pattern: r'(é+)',
          replacement: r'@js:"$1".repeat(256)',
          timeoutMillisecond: resourceTimeout,
        ),
      ]).content('é' * capture, chapterTitle: 'other');
      // The output is 4 Mi UTF-16 units; the 8 MiB budget counts their UTF-8
      // bytes.
      expect(exact.text.length, 2 + 256 * capture);

      final notices = <StoreMessage>[];
      final over = await processing([
        rule(
          pattern: r'(é+)',
          replacement: r'@js:"$1".repeat(257)',
          timeoutMillisecond: resourceTimeout,
        ),
      ], onNotice: notices.add).content('é' * capture, chapterTitle: 'other');
      expect(over.text, '　　${'é' * capture}');
      expect(notices.single.code, StoreMessageCode.replaceRuleFailed);

      // A supplementary character is two UTF-16 code units and four UTF-8
      // bytes: 8,192 of them are 32 KiB of UTF-8, so 256 references are
      // exactly the limit and 257 pass it. The run is captured with `.`
      // because the engine's literal supplementary pattern is code-unit based.
      const supplementary = 8 * 1024;
      final pair = await processing([
        rule(
          pattern: r'(.+)',
          replacement: r'@js:"$1".repeat(256)',
          timeoutMillisecond: resourceTimeout,
        ),
      ]).content('𝄞' * supplementary, chapterTitle: 'other');
      expect(pair.text.length, 2 + 2 * supplementary * 256);

      final pairNotices = <StoreMessage>[];
      final pairOver = await processing(
        [
          rule(
            pattern: r'(.+)',
            replacement: r'@js:"$1".repeat(257)',
            timeoutMillisecond: resourceTimeout,
          ),
        ],
        onNotice: pairNotices.add,
      ).content('𝄞' * supplementary, chapterTitle: 'other');
      expect(pairOver.text, '　　${'𝄞' * supplementary}');
      expect(pairNotices.single.code, StoreMessageCode.replaceRuleFailed);
    });

    test('the capture budget is cumulative across matches', () async {
      // 16 KiB of capture per match, 128 references each: four matches are
      // exactly 8 MiB and the fifth passes it.
      const perMatch = 16 * 1024;
      final text = 'a' * (perMatch * 5);
      final exact = await processing([
        rule(
          pattern: r'(a{16384})',
          replacement: r'@js:"$1".repeat(128)',
          timeoutMillisecond: resourceTimeout,
        ),
      ]).content(text.substring(0, perMatch * 4), chapterTitle: 'other');
      expect(exact.text.length, 2 + 8 * 1024 * 1024);

      final notices = <StoreMessage>[];
      final over = await processing([
        rule(
          pattern: r'(a{16384})',
          replacement: r'@js:"$1".repeat(128)',
          timeoutMillisecond: resourceTimeout,
        ),
      ], onNotice: notices.add).content(text, chapterTitle: 'other');
      expect(over.text, '　　$text');
      expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
    });

    test(
      'named, whole-match and nonparticipating references count only their text',
      () async {
        const capture = 32 * 1024;
        final named = await processing([
          rule(
            pattern: r'(?<word>a{32768})',
            replacement: r'@js:"${word}".repeat(256)',
            timeoutMillisecond: resourceTimeout,
          ),
        ]).content('a' * capture, chapterTitle: 'other');
        expect(named.text.length, 2 + 8 * 1024 * 1024);

        final whole = await processing([
          rule(
            pattern: r'(a{32768})',
            replacement: r'@js:"$0".repeat(256)',
            timeoutMillisecond: resourceTimeout,
          ),
        ]).content('a' * capture, chapterTitle: 'other');
        expect(whole.text.length, 2 + 8 * 1024 * 1024);

        // $2 never participates, so its thousand references insert nothing
        // and the 256 named ones still sit exactly at the limit.
        final nullable = await processing([
          rule(
            pattern: r'(?<word>a{32768})(b)?',
            replacement: r'@js:"${word}".repeat(256) + "$2".repeat(1000)',
            timeoutMillisecond: resourceTimeout,
          ),
        ]).content('a' * capture, chapterTitle: 'other');
        expect(nullable.text.length, 2 + 8 * 1024 * 1024);
      },
    );

    test('a later match past the limit leaves the whole rule out', () async {
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'cap',
            ruleName: 'cap',
            pattern: r'(a+)',
            replacement:
                r'@js:result.length > 1000 ? "$1".repeat(5000) : "$1".repeat(2)',
          ),
          rule(
            id: 'next',
            pattern: 'b',
            replacement: 'B',
            isRegex: false,
            ruleOrder: 1,
          ),
        ],
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      final text = '${'a' * 100}b${'a' * 2000}';
      final failed = await processor.content(text, chapterTitle: 'other');
      final baseline = await processing([
        rule(id: 'next', pattern: 'b', replacement: 'B', isRegex: false),
      ]).content(text, chapterTitle: 'other');
      // The first match's expansion is discarded with the whole rule: the text
      // and the public edit script are exactly what the later rule alone
      // produces, and the cap rule stays enabled.
      expect(failed.text, baseline.text);
      expect(
        failed.edits.map((edit) => '${edit.start}:${edit.end}:${edit.length}'),
        baseline.edits.map(
          (edit) => '${edit.start}:${edit.end}:${edit.length}',
        ),
      );
      expect(disabled, isEmpty);
      expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
      expect(notices.single.arguments.first, 'cap');
    });

    test('the budget is per title and content execution', () async {
      // 5 MiB per execution: either one fits the 8 MiB policy, but a budget
      // shared between the two invocations would fail the second.
      const capture = 32 * 1024;
      const perExecution = 5 * 1024 * 1024;
      final processor = processing([
        rule(
          pattern: r'(a{32768})',
          replacement: r'@js:"$1".repeat(160)',
          scopeTitle: true,
          timeoutMillisecond: resourceTimeout,
        ),
      ]);
      expect(
        (await processor.displayTitle('a' * capture)).length,
        perExecution,
      );
      expect(
        (await processor.content(
          'a' * capture,
          chapterTitle: 'other',
        )).text.length,
        2 + perExecution,
      );
    });

    test('literal template text is not part of the capture budget', () async {
      final runtime = _ScriptDouble((_) => 'x' * (1024 * 1024));
      final notices = <StoreMessage>[];
      final result = await processing(
        [
          rule(
            pattern: r'(a)',
            replacement: '@js:"x".repeat(1048576)',
            timeoutMillisecond: resourceTimeout,
          ),
        ],
        scriptRuntime: runtime,
        onNotice: notices.add,
      ).content('a' * 12, chapterTitle: 'other');
      expect(result.text.length, 2 + 12 * 1024 * 1024);
      expect(notices, isEmpty);
    });

    test('the unchanged input is not part of the capture budget', () async {
      final input = 'a${'b' * 9000000}';
      final notices = <StoreMessage>[];
      final result = await processing([
        rule(
          pattern: r'(a)',
          replacement: r'@js:"$1"',
          timeoutMillisecond: resourceTimeout,
        ),
      ], onNotice: notices.add).content(input, chapterTitle: 'other');
      expect(result.text.length, 2 + input.length);
      expect(notices, isEmpty);
    });

    test('capture expansion runs off the reading isolate', () async {
      var ticks = 0;
      final ticksAtCall = <int>[];
      final runtime = _ScriptDouble(
        (_) => 'x' * (1024 * 1024),
        onCall: (call, input) => ticksAtCall.add(ticks),
      );
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        final result = await processing([
          rule(
            pattern: r'(a)',
            replacement: '@js:"x".repeat(1048576)',
            timeoutMillisecond: resourceTimeout,
          ),
        ], scriptRuntime: runtime).content('a' * 12, chapterTitle: 'other');
        expect(result.text.length, 2 + 12 * 1024 * 1024);
      } finally {
        timer.cancel();
      }
      // Ticks before the first script call are startup and port wait and prove
      // nothing; the active worker phase must service the event loop between
      // the first and the last evaluation.
      expect(ticksAtCall, hasLength(12));
      expect(ticksAtCall.last, greaterThan(ticksAtCall.first));
    });

    test('a capture no template references is never collected', () async {
      final runtime = _ScriptDouble((_) => 'X');
      final result = await processing([
        rule(
          pattern: r'(?=(.*))',
          replacement: r'@js:"X"',
          timeoutMillisecond: resourceTimeout,
        ),
      ], scriptRuntime: runtime).content('a' * 3000, chapterTitle: 'other');
      // 3001 zero-width matches, each replaced by one X with the original text
      // kept between them; collecting every (.*) suffix would retain about 4.5
      // million characters for a template that reads none of them.
      expect(result.text.length, 2 + 3001 + 3000);
      expect(result.text, startsWith('　　XaXaX'));
    });

    test('a lookahead capture is read at the original match', () async {
      final result = await processing([
        rule(pattern: r'(?=(a+))', replacement: r'@js:"$1"'),
      ]).content('aaa', chapterTitle: 'other');
      // The matches are zero-width, so the capture can only come from the
      // original match context, never from a rematch of group 0: each match
      // inserts its own capture and the text after the last match start is
      // still appended.
      expect(result.text, '　　aaaaaaaaa');
    });

    test(
      'cancellation during capture expansion leaves the text unchanged',
      () async {
        final cancellation = SourceCancellation();
        final notices = <StoreMessage>[];
        final processor = processing(
          [rule(pattern: r'(a)', replacement: r'@js:"$1".repeat(3)')],
          scriptRuntime: _ScriptDouble(
            (_) => 'X',
            onCall: (call, _) {
              if (call == 2) cancellation.cancel();
            },
          ),
          cancellation: cancellation,
          onNotice: notices.add,
        );
        final result = await processor.content('aaaa', chapterTitle: 'other');
        expect(result.text, '　　aaaa');
        expect(notices, isEmpty);
      },
    );

    test('a slow match enumeration is still the rule timeout', () async {
      final disabled = <String>[];
      final notices = <StoreMessage>[];
      final content = (await processing(
        [
          rule(
            id: 'js-slow-match',
            ruleName: '慢匹配 JS 规则',
            pattern: r'(a+)+$',
            replacement: r'@js:"X"',
            timeoutMillisecond: 200,
          ),
        ],
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      ).content('${'a' * 32}b', chapterTitle: '第一章')).text;
      expect(content, '　　${'a' * 32}b');
      expect(disabled, ['js-slow-match']);
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['慢匹配 JS 规则', 200]);
    });

    test('one byte below the limit succeeds', () async {
      // 511 references of a 16,384-character capture plus one 16,383-character
      // capture is 8,388,607 bytes, one below the policy.
      const first = 16 * 1024;
      const second = 16 * 1024 - 1;
      final result = await processing([
        rule(
          pattern: r'(a{16384})(b{16383})',
          replacement: r'@js:"$1".repeat(511) + "$2"',
          timeoutMillisecond: resourceTimeout,
        ),
      ]).content('${'a' * first}${'b' * second}', chapterTitle: 'other');
      expect(result.text.length, 2 + 8 * 1024 * 1024 - 1);
    });

    test(
      'an over-budget template fails promptly as an ordinary cap error',
      () async {
        // The controller's actual counterexample: a 32,768-character capture
        // referenced 262,144 times (524,288-byte template). Reference 257 is
        // already over 8 MiB, so the count must stop there instead of scanning
        // the whole template until the 1000 ms rule deadline.
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              id: 'bounded-counting',
              ruleName: 'bounded-counting',
              pattern: r'^(a+)$',
              replacement: r'@js:"$1".repeat(262144)',
              scopeTitle: true,
              timeoutMillisecond: 1000,
            ),
          ],
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        final input = 'a' * 32768;
        expect(await processor.displayTitle(input), input);
        expect(disabled, isEmpty);
        expect(notices.single.code, StoreMessageCode.replaceRuleFailed);
        expect(notices.single.arguments.first, 'bounded-counting');
      },
    );

    test('a cancelled queued worker error is not reported', () async {
      // The controller's actual counterexample: the evaluator lets the worker
      // queue its invalid-reference reply, then cancels before that reply can
      // be consumed. Cancellation must win with no ordinary error notice.
      final cancellation = SourceCancellation();
      var cancellationFired = false;
      final runtime = _ScriptDouble(
        (_) => r'$2',
        onCall: (call, input) {
          if (call != 1) return;
          Timer.run(() {
            // Hold the caller while the actual worker enqueues its response;
            // cancelling before the queued response is consumed must win.
            final pause = Stopwatch()..start();
            while (pause.elapsedMilliseconds < 100) {}
            cancellationFired = true;
            cancellation.cancel();
          });
        },
      );
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'queued-worker-cancellation',
            ruleName: 'queued-worker-cancellation',
            pattern: r'^(a)$',
            replacement: r'@js:"$2"',
            scopeTitle: true,
          ),
        ],
        scriptRuntime: runtime,
        cancellation: cancellation,
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(cancellationFired, isTrue);
      expect(cancellation.isCancelled, isTrue);
      expect(notices, isEmpty);
      expect(disabled, isEmpty);
    });

    test(
      'cancellation while the worker is expanding leaves the text unchanged',
      () async {
        final cancellation = SourceCancellation();
        final runtime = _ScriptDouble(
          (_) => 'x' * (4 * 1024 * 1024),
          onCall: (call, input) {
            if (call == 1) {
              Timer(const Duration(milliseconds: 1), cancellation.cancel);
            }
          },
        );
        final notices = <StoreMessage>[];
        final processor = processing(
          [
            rule(
              pattern: r'(a)',
              replacement: '@js:"x".repeat(4194304)',
              timeoutMillisecond: resourceTimeout,
            ),
          ],
          scriptRuntime: runtime,
          cancellation: cancellation,
          onNotice: notices.add,
        );
        final result = await processor.content('aaaa', chapterTitle: 'other');
        expect(result.text, '　　aaaa');
        expect(notices, isEmpty);
        expect(runtime.calls, greaterThan(0));
      },
    );

    test('a script return after the rule deadline is not adopted', () async {
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'late-return',
            ruleName: 'late-return',
            pattern: r'(a)',
            replacement: r'@js:"X"',
            scopeTitle: true,
            timeoutMillisecond: 50,
          ),
        ],
        scriptRuntime: _ScriptDouble((_) {
          final pause = Stopwatch()..start();
          while (pause.elapsedMilliseconds < 80) {}
          return 'X';
        }),
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(disabled, ['late-return']);
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['late-return', 50]);
    });

    test('cancellation wins over a typed timeout failure', () async {
      // The controller's actual counterexample: the evaluator cancels the
      // operation and then throws the runtime's timeout category. Cancellation
      // must win with no notice or disable.
      final cancellation = SourceCancellation();
      final runtime = _ScriptDouble(
        (_) => throw const SourceScriptError('timeout'),
        onCall: (call, input) => cancellation.cancel(),
      );
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'cancel-timeout',
            ruleName: 'cancel-timeout',
            pattern: r'^(a)$',
            replacement: r'@js:"$2"',
            scopeTitle: true,
          ),
        ],
        scriptRuntime: runtime,
        cancellation: cancellation,
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(runtime.calls, 1);
      expect(cancellation.isCancelled, isTrue);
      expect(notices, isEmpty);
      expect(disabled, isEmpty);
    });

    test('cancellation wins over an ordinary script failure', () async {
      // The controller's actual counterexample: the evaluator cancels the
      // operation and then throws an ordinary script failure. Cancellation must
      // win with no notice or disable.
      final cancellation = SourceCancellation();
      final runtime = _ScriptDouble(
        (_) => throw const SourceScriptError('js', 'controlled script error'),
        onCall: (call, input) => cancellation.cancel(),
      );
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'cancel-js',
            ruleName: 'cancel-js',
            pattern: r'^(a)$',
            replacement: r'@js:"$2"',
            scopeTitle: true,
          ),
        ],
        scriptRuntime: runtime,
        cancellation: cancellation,
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(runtime.calls, 1);
      expect(cancellation.isCancelled, isTrue);
      expect(notices, isEmpty);
      expect(disabled, isEmpty);
    });

    test('a typed script failure after the deadline times out', () async {
      // The controller's actual counterexample: the evaluator runs past the
      // rule deadline and then throws an ordinary script failure. The elapsed
      // deadline must win over the failure's own category.
      final runtime = _ScriptDouble((_) {
        final pause = Stopwatch()..start();
        while (pause.elapsedMilliseconds < 800) {}
        throw const SourceScriptError('js', 'late controlled script error');
      });
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'late-js',
            ruleName: 'late-js',
            pattern: r'^(a)$',
            replacement: r'@js:"$2"',
            scopeTitle: true,
            timeoutMillisecond: 500,
          ),
        ],
        scriptRuntime: runtime,
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(runtime.calls, 1);
      expect(disabled, ['late-js']);
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['late-js', 500]);
    });

    test('a host failure after the deadline times out', () async {
      // The controller's actual counterexample: the evaluator runs past the
      // rule deadline and then throws a generic host failure. The elapsed
      // deadline must win over the ordinary error path.
      final runtime = _ScriptDouble((_) {
        final pause = Stopwatch()..start();
        while (pause.elapsedMilliseconds < 800) {}
        throw StateError('late controlled host error');
      });
      final notices = <StoreMessage>[];
      final disabled = <String>[];
      final processor = processing(
        [
          rule(
            id: 'late-host',
            ruleName: 'late-host',
            pattern: r'^(a)$',
            replacement: r'@js:"$2"',
            scopeTitle: true,
            timeoutMillisecond: 500,
          ),
        ],
        scriptRuntime: runtime,
        onNotice: notices.add,
        onRuleDisabled: (rule) async => disabled.add(rule.id),
      );
      expect(await processor.displayTitle('a'), 'a');
      expect(runtime.calls, 1);
      expect(disabled, ['late-host']);
      expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      expect(notices.single.arguments, ['late-host', 500]);
    });

    test(
      'a queued worker reply after the rule deadline is not adopted',
      () async {
        // The controller's scheduling control: a successful evaluation returns
        // a missing group and holds the caller past the rule deadline while the
        // actual expansion worker queues its invalid-reference reply.
        var queuedPauseRan = false;
        final runtime = _ScriptDouble(
          (_) => r'$2',
          onCall: (call, input) {
            Timer.run(() {
              queuedPauseRan = true;
              final pause = Stopwatch()..start();
              while (pause.elapsedMilliseconds < 800) {}
            });
          },
        );
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              id: 'queued-deadline',
              ruleName: 'queued-deadline',
              pattern: r'^(a)$',
              replacement: r'@js:"$2"',
              scopeTitle: true,
              timeoutMillisecond: 500,
            ),
          ],
          scriptRuntime: runtime,
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        expect(await processor.displayTitle('a'), 'a');
        expect(runtime.calls, 1);
        expect(queuedPauseRan, isTrue);
        expect(disabled, ['queued-deadline']);
        expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
        expect(notices.single.arguments, ['queued-deadline', 500]);
      },
    );

    test(
      'the first match is evaluated before a later match is enumerated',
      () async {
        // The first match is cheap; enumerating the second one backtracks
        // catastrophically. The evaluator must see the first match before that
        // enumeration starts, which an eager all-match collection cannot do.
        final inputs = <String>[];
        final runtime = _ScriptDouble(
          (_) => 'X',
          onCall: (call, input) => inputs.add(input['result'] as String),
        );
        final notices = <StoreMessage>[];
        final disabled = <String>[];
        final processor = processing(
          [
            rule(
              id: 'lazy-enumeration',
              ruleName: 'lazy-enumeration',
              pattern: r'(x)|((a+)+$)',
              replacement: r'@js:"X"',
              scopeTitle: true,
              timeoutMillisecond: 200,
            ),
          ],
          scriptRuntime: runtime,
          onNotice: notices.add,
          onRuleDisabled: (rule) async => disabled.add(rule.id),
        );
        final input = 'x${'a' * 32}b';
        expect(await processor.displayTitle(input), input);
        expect(inputs, ['x']);
        expect(disabled, ['lazy-enumeration']);
        expect(notices.single.code, StoreMessageCode.replaceRuleTimedOut);
      },
    );
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

/// A boundary double for the resource and scheduling cases: [answer] returns the
/// script result for one call and [onCall] runs first with that call's input, so
/// a case can be sized or phased without the JavaScript engine's own cost.
class _ScriptDouble extends InProcessSourceScriptRuntime {
  _ScriptDouble(this.answer, {this.onCall});

  final Object? Function(int call) answer;
  final void Function(int call, Map<String, Object?> input)? onCall;
  var calls = 0;

  @override
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async {
    final call = ++calls;
    onCall?.call(call, input);
    return answer(call);
  }
}
