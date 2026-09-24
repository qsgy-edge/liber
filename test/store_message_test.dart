import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/domain/store_message.dart';
import 'package:liber/l10n/app_localizations.dart';
import 'package:liber/l10n/store_message_text.dart';
import 'package:liber/settings/interface_language.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/store/legacy_import.dart';

import 'space_test_support.dart';

/// The store layer's own messages (#72): a code plus the arguments its copy's
/// placeholders take, rendered by the page through `AppLocalizations`.
///
/// The store has no `BuildContext`, so nothing here reads a widget; what it
/// proves is the two halves of the seam — the store reports codes and
/// arguments, and the interface carries copy for every one of them in all four
/// languages — plus the tolerance a marker written before the seam needs.
void main() {
  test('消息经 JSON 往返后仍是同一个代码与同一组实参', () {
    final messages = <StoreMessage>[
      StoreMessage(StoreMessageCode.legacyOnlineReadingLastReadPointer),
      StoreMessage(StoreMessageCode.legacyLocalFilesMissing, <Object?>[3]),
      StoreMessage(StoreMessageCode.backupUnreadMembers, <Object?>[
        2,
        'replaceRule.json、bookmark.json',
      ]),
      StoreMessage.literal('一条旧界面写下的损失行'),
    ];
    final decoded = [
      for (final message in messages)
        StoreMessage.fromJson(jsonDecode(jsonEncode(message.toJson()))),
    ];
    expect(decoded, messages);
    // An argument that is a number stays a number: the ARB placeholder is an
    // int, and the rendered line prints the count, not a quoted string.
    expect(decoded[1].arguments, <Object?>[3]);
  });

  test('#72 之前写入的标记：纯字符串的损失行照原文渲染，不被丢掉', () {
    // The shape an already-migrated space holds: `losses` as bare strings.
    final stored = <String, Object?>{
      'imported': true,
      'importedAt': '2026-09-01T00:00:00.000Z',
      'sources': 2,
      'books': 1,
      'chapters': 1,
      'progress': 0,
      'localFiles': 0,
      'losses': [
        '在线阅读记录的“上次阅读”指针没有等价字段，改由最近保存的进度回答',
        '本地文件字节不导入；文件缺失的书已标记 needsRelink',
      ],
    };
    final report = LegacyImportReport.fromJson(stored);

    expect(report.losses, hasLength(2));
    expect(
      report.losses.first.code,
      StoreMessageCode.literalCopy,
      reason: '读不懂的旧行是它自己的文案，而不是丢掉',
    );
    expect(report.losses.first.literalText, (stored['losses']! as List).first);
    // Writing it back is the new shape, so the next read is a code.
    expect((report.toJson()['losses']! as List).first, <String, Object?>{
      'code': 'literalCopy',
      'arguments': <Object?>[(stored['losses']! as List).first],
    });
  });

  test('旧标记的损失行在界面上照原样显示，不会变成空的一行', () async {
    final zh = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.simplified,
    );
    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );
    const oldLine = '本地文件字节不导入；文件缺失的书已标记 needsRelink';
    final report = LegacyImportReport.fromJson(<String, Object?>{
      'imported': true,
      'importedAt': '2026-09-01T00:00:00.000Z',
      'sources': 0,
      'books': 0,
      'chapters': 0,
      'progress': 0,
      'localFiles': 0,
      'losses': <Object?>[oldLine],
    });

    expect(report.losses.single.code, StoreMessageCode.literalCopy);
    expect(report.losses.single.text(zh), oldLine);
    expect(
      report.losses.single.text(en),
      oldLine,
      reason: '旧行是它自己的文案：英文界面下也不翻译，但绝不能变空',
    );
  });

  test('存储层报告代码与实参：只读得了那半个文件的导入', () async {
    final space = await TestSpace.create();
    addTearDown(space.delete);
    // A version this build does not know: the file is refused by name and the
    // rest of the import still runs.
    await space
        .file('online_reading.json')
        .writeAsString(jsonEncode({'version': 3, 'records': <Object?>[]}));

    final report = await LegacyImport(home: space.directory).run(space.store);

    expect(report.imported, isTrue);
    expect(report.losses, hasLength(1));
    expect(
      report.losses.single.code,
      StoreMessageCode.legacyOnlineReadingNotImported,
    );
    // The refusal's own words are a diagnostic, passed through as the
    // argument of the interface's line (the `chapterLoadFailed('$e')` shape).
    expect(report.losses.single.arguments, <Object?>['在线阅读文件版本不受支持']);
    expect(report.summary().code, StoreMessageCode.legacyImportSummary);
    expect(report.summary().arguments, <Object?>[0, 0, 0, 0, 0]);
  });

  test('同一组消息在四个界面里各自成文', () async {
    Future<AppLocalizations> load(Locale locale) =>
        AppLocalizations.delegate.load(locale);

    final zh = await load(InterfaceLanguageSetting.simplified);
    final en = await load(InterfaceLanguageSetting.english);
    final tw = await load(InterfaceLanguageSetting.traditionalTaiwan);
    final hk = await load(InterfaceLanguageSetting.traditionalHongKong);

    const lastReadPointer = StoreMessage(
      StoreMessageCode.legacyOnlineReadingLastReadPointer,
    );
    expect(lastReadPointer.text(zh), contains('上次阅读'));
    expect(lastReadPointer.text(en), contains('no equivalent field'));
    // Both Traditional interfaces convert the line; the word tables' choices are
    // #28's to review, so this asserts the line was converted, not how.
    expect(lastReadPointer.text(tw), contains('進度回答'));
    expect(lastReadPointer.text(hk), contains('進度回答'));
    expect(lastReadPointer.text(tw), isNot(lastReadPointer.text(zh)));

    // An English interface never falls back to the template's Chinese.
    const missingFiles = StoreMessage(
      StoreMessageCode.legacyLocalFilesMissing,
      <Object?>[2],
    );
    expect(
      missingFiles.text(en),
      '2 local files are no longer at their original path',
    );
    expect(
      missingFiles.text(en),
      isNot(matches(RegExp(r'[\u4e00-\u9fff]'))),
      reason: '英文界面里不该留下中文',
    );

    final summary = const LegacyImportReport(
      imported: true,
      importedAt: '',
      sources: 3,
      books: 6,
      chapters: 9,
      progress: 1,
      localFiles: 2,
    ).summary();
    expect(summary.text(zh), '书源 3 · 书籍 6 · 目录 9 · 进度 1 · 本地文件 2');
    expect(
      summary.text(en),
      'Book Sources 3 · Books 6 · Chapters 9 · Progress 1 · Local files 2',
    );
    expect(summary.text(tw), contains('本地檔案'));
    expect(summary.text(hk), contains('本地文件'));
  });

  test('失败行的阶段是界面自己的词，不是枚举标识符', () async {
    final zh = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.simplified,
    );
    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );
    final failed = StoreMessage(StoreMessageCode.runFailed, <Object?>[
      BookSourceStage.tableOfContents.name,
      'boom',
    ]);

    expect(failed.text(en), 'Table of contents: boom');
    expect(failed.text(zh), '目录：boom');
    expect(
      failed.text(en),
      isNot(contains(BookSourceStage.tableOfContents.name)),
      reason: '界面已经有阶段自己的词，不该把标识符给读者看',
    );
    // A stage this build does not know keeps its identifier rather than going
    // blank: it can only come from a build with a stage this one lacks.
    expect(
      StoreMessage(StoreMessageCode.runFailed, <Object?>[
        'searchAudio',
        'boom',
      ]).text(en),
      'searchAudio: boom',
    );
  });

  test('实参短了或类型不对的标记照常渲染，不抛异常（评审第 1 条）', () async {
    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );

    // A known code whose stored arguments are short: the counts it lacks read
    // 0, the text it lacks reads empty, and the page still builds.
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'code': 'legacyImportSummary',
        'arguments': <Object?>[],
      }).text(en),
      'Book Sources 0 · Books 0 · Chapters 0 · Progress 0 · Local files 0',
    );
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'code': 'runFailed',
        'arguments': <Object?>['content'],
      }).text(en),
      'Content: ',
    );
    // A count stored as text is read as the number it spells.
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'code': 'legacyLocalFilesMissing',
        'arguments': <Object?>['3'],
      }).text(en),
      '3 local files are no longer at their original path',
    );
    // A number where the copy declares a string is stringified.
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'code': 'backupAbsentMember',
        'arguments': <Object?>[7],
      }).text(en),
      'The backup has no 7: that data was empty',
    );
  });

  test('命名不了的条目显示自己的文字，不是空行（评审第 2 条）', () async {
    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );

    // A slug this build does not know: a report a newer build wrote. Its
    // diagnostic form keeps both the code and what it carried.
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'code': 'aNewerCodesName',
        'arguments': <Object?>[1, 'x'],
      }).text(en),
      'aNewerCodesName(1, x)',
    );
    // A damaged entry with no code at all: the JSON it holds is the whole of
    // what it says, and an empty bullet is not.
    expect(
      StoreMessage.fromJson(<String, Object?>{
        'arguments': <Object?>['x'],
      }).text(en),
      '{"arguments":["x"]}',
    );
  });

  test('受控书源的状态行是代码加实参，界面文字在渲染时才出现', () async {
    final states = <BookSourceRunState>[];
    final result = await BookSourceService().run(states.add);

    expect(states.map((state) => state.message!.code), <StoreMessageCode>[
      StoreMessageCode.runControlledSearch,
      StoreMessageCode.runControlledBookInfo,
      StoreMessageCode.runControlledToc,
      StoreMessageCode.runControlledContent,
      StoreMessageCode.runControlledCompleted,
    ], reason: '运行状态带的是代码，不是某一种界面的文字');
    expect(result.state.stage, BookSourceStage.completed);

    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );
    expect(states.first.message!.text(en), 'The search returned 1 book');
    expect(
      result.state.message!.text(en),
      'The Windows controlled Book Source chain completed; all 4 stages have a trace',
    );
  });

  test('每个带占位符的代码在测试里都有正好那份实参（模板是准绳）', () {
    final template =
        jsonDecode(File('lib/l10n/app_zh.arb').readAsStringSync())
            as Map<String, Object?>;
    for (final code in StoreMessageCode.values) {
      final metadata = template['@${code.slug}'];
      final placeholders = metadata is Map
          ? (metadata['placeholders'] as Map?)?.length ?? 0
          : 0;
      expect(
        (_representativeArguments[code] ?? const <Object?>[]).length,
        placeholders,
        reason:
            '${code.slug} 的文案有 $placeholders 个占位符，测试却给了另一份实参：'
            '漏掉的那份会让上面的循环渲染出一句没有内容的英文',
      );
    }
  });

  test('每个代码在英文界面里都渲染出非空、没有中文的文案', () async {
    final en = await AppLocalizations.delegate.load(
      InterfaceLanguageSetting.english,
    );

    for (final code in StoreMessageCode.values) {
      final text = StoreMessage(
        code,
        _representativeArguments[code] ?? const <Object?>[],
      ).text(en);
      expect(text.trim(), isNotEmpty, reason: '${code.slug} 渲染成了空行');
      expect(
        text,
        isNot(matches(_cjk)),
        reason: '${code.slug} 的英文文案里还有中文：$text',
      );
    }
  });
}

/// Every CJK the interface must not carry in an English render: the ideographs,
/// the CJK punctuation the store used to join a list with (`、`), and the
/// fullwidth forms.
final RegExp _cjk = RegExp(r'[　-〿一-鿿＀-￯]');

/// The arguments one code needs to render, for the codes that carry any: the
/// loop above renders every code in [StoreMessageCode], so a code this map omits
/// is one whose copy has no placeholder. The values are ASCII on purpose — the
/// row is about the copy the interface writes, not about the data a message
/// carries.
const Map<StoreMessageCode, List<Object?>> _representativeArguments = {
  StoreMessageCode.literalCopy: <Object?>['a stored line'],
  StoreMessageCode.legacyOnlineReadingNotImported: <Object?>['a reason'],
  StoreMessageCode.legacyLocalFilesMissing: <Object?>[1],
  StoreMessageCode.legacyImportSummary: <Object?>[1, 2, 3, 4, 5],
  StoreMessageCode.backupAndroidPreferences: <Object?>[1],
  StoreMessageCode.backupAbsentMember: <Object?>['bookmark.json'],
  StoreMessageCode.backupUnreadMembers: <Object?>[1, 'a.json, b.json'],
  StoreMessageCode.backupInvalidSources: <Object?>[1],
  StoreMessageCode.backupInvalidGroups: <Object?>[1],
  StoreMessageCode.backupInvalidBooks: <Object?>[1],
  StoreMessageCode.backupConflictingSources: <Object?>[1],
  StoreMessageCode.backupDuplicateBooks: <Object?>[1],
  StoreMessageCode.backupSystemGroups: <Object?>[1],
  StoreMessageCode.backupUnmatchedMasks: <Object?>[1],
  StoreMessageCode.backupUnreadBooks: <Object?>[1],
  StoreMessageCode.backupNonTextSources: <Object?>[1],
  StoreMessageCode.backupDroppedCovers: <Object?>[1],
  StoreMessageCode.backupDroppedEntries: <Object?>[1],
  StoreMessageCode.replaceRuleUnusable: <Object?>['rule', 'a reason'],
  StoreMessageCode.replaceRuleTimedOut: <Object?>['rule', 3000],
  StoreMessageCode.replaceRuleFailed: <Object?>['rule', 'boom'],
  StoreMessageCode.runReading: <Object?>['a chapter'],
  StoreMessageCode.runFailed: <Object?>['tableOfContents', 'boom'],
};
