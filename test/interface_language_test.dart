import 'dart:io';

import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/main.dart';
import 'package:liber/settings/interface_language.dart';
import 'package:liber/settings/reader_script.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';
import 'space_test_support.dart';

import 'temp_directory.dart';

/// The interface language (#28) and its independence from the content's script
/// (#27).
///
/// The two settings read one locale — [InterfaceLanguageSetting.systemLocale],
/// which [ReaderScriptSetting.systemLocale] answers with — and each then
/// resolves on its own: a fresh install on a `zh-TW` machine opens with the
/// Taiwan interface and Taiwan wording for its books, and either half can be
/// overridden without moving the other (an English interface with Simplified
/// books is a state the product allows).
void main() {
  const zhTW = Locale.fromSubtags(
    languageCode: 'zh',
    scriptCode: 'Hant',
    countryCode: 'TW',
  );
  const zhHK = Locale.fromSubtags(
    languageCode: 'zh',
    scriptCode: 'Hant',
    countryCode: 'HK',
  );
  const zhCN = Locale.fromSubtags(languageCode: 'zh', countryCode: 'CN');

  test('系统语言把四种界面选出来，其余语言落到 English', () {
    expect(InterfaceLanguageSetting.followSystem(zhCN), Locale('zh'));
    expect(
      InterfaceLanguageSetting.followSystem(const Locale('zh')),
      Locale('zh'),
    );
    expect(
      InterfaceLanguageSetting.followSystem(zhTW),
      InterfaceLanguageSetting.traditionalTaiwan,
    );
    expect(
      InterfaceLanguageSetting.followSystem(zhHK),
      InterfaceLanguageSetting.traditionalHongKong,
    );
    expect(
      InterfaceLanguageSetting.followSystem(const Locale('en', 'US')),
      Locale('en'),
    );
    // The frozen reader's unmatched locale falls back to its default `values`,
    // which are English.
    expect(
      InterfaceLanguageSetting.followSystem(const Locale('de')),
      Locale('en'),
    );
  });

  test('存的 slug 决定界面语言，读不懂的行回到跟随系统', () async {
    final space = await TestSpace.create();
    addTearDown(space.delete);

    Future<Locale> resolved() =>
        InterfaceLanguageSetting.resolve(space.store, systemLocale: zhTW);

    expect(await resolved(), InterfaceLanguageSetting.traditionalTaiwan);

    await InterfaceLanguageSetting.putGlobal(
      space.store,
      InterfaceLanguageChoice.english,
    );
    expect(await resolved(), Locale('en'));

    // A hand-edited or older row is not a language.
    await space.store.putSetting(InterfaceLanguageSetting.key, 'klingon');
    expect(await resolved(), InterfaceLanguageSetting.traditionalTaiwan);
  });

  test('zh-TW 机器：繁体界面 + 台湾用词，两边各自可覆盖', () async {
    final space = await TestSpace.create();
    addTearDown(space.delete);

    Future<Locale> ui() =>
        InterfaceLanguageSetting.resolve(space.store, systemLocale: zhTW);
    Future<ConvertTarget?> content() =>
        ReaderScriptSetting.resolve(space.store, locale: zhTW);

    // A fresh install: both halves follow the machine.
    expect(await ui(), InterfaceLanguageSetting.traditionalTaiwan);
    expect(await content(), ConvertTarget.traditionalTaiwan);

    // English interface, books still following the machine's locale.
    await InterfaceLanguageSetting.putGlobal(
      space.store,
      InterfaceLanguageChoice.english,
    );
    expect(await ui(), Locale('en'));
    expect(await content(), ConvertTarget.traditionalTaiwan);

    // Simplified books under that English interface: the two are independent in
    // both directions.
    await ReaderScriptSetting.putGlobal(
      space.store,
      ReaderScriptChoice.simplified,
    );
    expect(await ui(), Locale('en'));
    expect(await content(), ConvertTarget.simplifiedMainland);

    // Back to following the machine: the interface moves, the books do not.
    await InterfaceLanguageSetting.putGlobal(
      space.store,
      InterfaceLanguageChoice.followLocale,
    );
    expect(await ui(), InterfaceLanguageSetting.traditionalTaiwan);
    expect(await content(), ConvertTarget.simplifiedMainland);

    // And the choice is a row, not process state: reopening the same space
    // reads the same two answers (this is the restart).
    await space.reopen();
    expect(await ui(), InterfaceLanguageSetting.traditionalTaiwan);
    expect(await content(), ConvertTarget.simplifiedMainland);
  });

  testWidgets('一个读出平台语言的入口：两个设置共用它', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = zhTW;
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);

    expect(InterfaceLanguageSetting.systemLocale(), zhTW);
    expect(ReaderScriptSetting.systemLocale(), zhTW);
  });

  testWidgets('同一页在四个界面里读四种文字', (tester) async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final page = SourceTrialPage(
      sources: const [],
      service: ShelfService(store),
    );

    Future<void> pump(Locale locale) async {
      await tester.pumpWidget(localizedApp(home: page, locale: locale));
      await tester.pumpAndSettle();
    }

    await pump(const Locale('zh'));
    expect(find.text('搜索关键词'), findsOneWidget);
    expect(find.text('选择书源并输入关键词。'), findsOneWidget);

    await pump(const Locale('en'));
    expect(find.text('Search keyword'), findsOneWidget);
    expect(
      find.text('Choose a book source and enter a keyword.'),
      findsOneWidget,
    );

    await pump(InterfaceLanguageSetting.traditionalTaiwan);
    expect(find.text('搜尋關鍵詞'), findsOneWidget);
    expect(find.text('選擇書源並輸入關鍵詞。'), findsOneWidget);

    await pump(InterfaceLanguageSetting.traditionalHongKong);
    expect(find.text('搜尋關鍵詞'), findsOneWidget);
  });

  group('在设置里换语言', () {
    // The installation directory is made in `setUp`: the test body runs in a
    // fake async zone, where a real `Directory.createTemp` future never
    // completes.
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('liber-language-');
    });

    tearDown(() => _delete(root));

    testWidgets('主界面立刻跟着换，重启后还是它', (tester) async {
      tester.binding.platformDispatcher.localeTestValue = zhCN;
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      // The desktop window the product ships is 1280×720 (`windows/runner`); the
      // default 800×600 test surface makes the shelf page's fixed card overflow
      // once the copy is English, which is a surface size and not the copy.
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Unmounting releases the space; doing it here as well means a test that
      // fails half way still lets `_delete` remove the directory.
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      });

      await tester.runAsync(() async {
        await tester.pumpWidget(LiberApp(workspaceRoot: root));
        await tester.pump();
        // The shelf section appears with the space; the app bar's language entry
        // is disabled until then.
        await _waitFor(tester, find.text('书架'));
        await _waitFor(tester, find.text('在线书架'));
        expect(find.text('Bookshelf'), findsNothing);

        // The settings screen opens from the app bar; its own copy is the
        // interface's too. The choices appear once the row has been read.
        await tester.tap(find.byIcon(Icons.language));
        await _pumpFrames(tester);
        await _waitFor(tester, find.text('界面语言'));
        await _waitFor(
          tester,
          find.byKey(const ValueKey('interface-language-follow_locale')),
        );

        await tester.tap(
          find.byKey(const ValueKey('interface-language-english')),
        );
        // No restart: the frame after the choice is already English, on the
        // settings screen and on the main screen behind it.
        await _waitFor(tester, find.text('Interface language'));
        expect(find.text('界面语言'), findsNothing);

        await tester.tap(find.byType(BackButton));
        await _pumpFrames(tester);
        await _waitFor(tester, find.text('Bookshelf'));
        expect(find.text('书架'), findsNothing);

        // The choice is the space store's row, so a second launch reads it back.
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await tester.pumpWidget(LiberApp(workspaceRoot: root));
        await _waitFor(tester, find.text('Bookshelf'));
        expect(find.text('书架'), findsNothing);
      });
    });
  });
}

/// Pumps the frames an animated route needs. `runAsync` has no `pumpAndSettle`:
/// it would wait for frames that only the animation itself produces.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Real work finishes on real time, so wait for the text instead of guessing a
/// duration; a finder that never appears fails here rather than at the
/// assertion that follows it.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
  throw StateError('$finder never appeared');
}

/// The scratch directory goes through the shared helper: the space's database
/// file is released asynchronously, and Windows held it past this file's own
/// first retry window once (one red run). See `temp_directory.dart`.
Future<void> _delete(Directory root) => deleteTempDirectory(root);
