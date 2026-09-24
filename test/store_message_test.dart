import 'dart:convert';

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
}
