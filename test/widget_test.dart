import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liber/main.dart';
import 'package:liber/settings/interface_language.dart';

import 'l10n_support.dart';

void defaultAppTest(Directory Function() root) {
  testWidgets('Windows MVP shows the controlled source workbench', (
    tester,
  ) async {
    await tester.pumpWidget(
      LiberApp(workspaceRoot: root(), interfaceLanguage: testLocale),
    );

    expect(find.text('书架'), findsNWidgets(2));
    expect(find.text('Wayfinder 受控书源'), findsOneWidget);
    expect(find.text('尚未运行'), findsOneWidget);
    // The settings screens have an entry point in the app bar (#27, #28, #69);
    // the space is not open yet, so each is disabled until it is.
    final script = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.translate),
        matching: find.byType(IconButton),
      ),
    );
    expect(script.tooltip, '中文转换');
    expect(script.onPressed, isNull);
    final language = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.language),
        matching: find.byType(IconButton),
      ),
    );
    expect(language.tooltip, '界面语言');
    expect(language.onPressed, isNull);
    final autoSwitch = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.swap_horiz),
        matching: find.byType(IconButton),
      ),
    );
    expect(autoSwitch.tooltip, '自动换源');
    expect(autoSwitch.onPressed, isNull);
  });
}

/// The startup path does real work — opening the space database runs in a
/// background isolate — so it needs `runAsync`; `pumpAndSettle` in the fake
/// zone would wait for frames that never come.
void spaceStoreTest(Directory Function() root) {
  testWidgets('迁移页报告旧数据导入结果，原文件退休后书架仍从空间读取', (tester) async {
    _pinShelfSurface(tester);
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      await tester.tap(find.text('迁移'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('本次导入旧数据'));

      expect(
        find.byKey(const ValueKey('space-store-path')),
        findsOneWidget,
        reason: '空间数据库的位置要能看见',
      );
      expect(find.textContaining('书源 2'), findsOneWidget);
      expect(find.textContaining('上次阅读'), findsOneWidget, reason: '损失要写出来');

      // The old files are renamed aside rather than deleted, and the shelf that
      // no longer reads them shows what the import carried over.
      final home = workspaceRoot;
      expect(
        File(
          '${home.path}${Platform.pathSeparator}online_reading.json',
        ).existsSync(),
        isFalse,
        reason: '原文件不再留在安装目录',
      );
      expect(
        File(
          '${home.path}${Platform.pathSeparator}legacy'
          '${Platform.pathSeparator}online_reading.json',
        ).existsSync(),
        isTrue,
      );
      await tester.tap(find.text('书架'));
      await tester.pump();
      await _waitFor(tester, find.text('斗破苍穹'));
      expect(find.text('斗破苍穹'), findsOneWidget);

      // Nothing reads the JSON files any more: the second launch opens the same
      // space with them already gone and the shelf is still there.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      await tester.tap(find.text('迁移'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('本次未重复导入'));

      expect(find.textContaining('本次未重复导入'), findsOneWidget);
      expect(find.textContaining('本次导入旧数据'), findsNothing);
      await tester.tap(find.text('书架'));
      await tester.pump();
      await _waitFor(tester, find.text('斗破苍穹'));
      expect(find.text('斗破苍穹'), findsOneWidget);

      // Unmounting the app is what releases the space, and the directory can
      // only be deleted once that happened.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// The settings screens' app-bar entries as the user reaches them (#27, #28,
/// #69): the space has to be open for them, so this drives the real app the way
/// `spaceStoreTest` does.
void settingsEntryTest(Directory Function() root) {
  testWidgets('自动换源的入口打开设置页，开关读的是已存的行', (tester) async {
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      // The shelf section appears with the space; the app bar's entries are
      // disabled until then.
      await _waitFor(tester, find.text('在线书架'));

      await tester.tap(find.byIcon(Icons.swap_horiz));
      await _waitFor(
        tester,
        find.byKey(const ValueKey('auto-change-source-switch')),
      );

      expect(find.text('自动换源'), findsOneWidget, reason: '设置页的标题');
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('auto-change-source-switch')),
            )
            .value,
        isTrue,
        reason: '没有行时是冻结的默认值 true',
      );

      // Unmounting the app is what releases the space, and the directory can
      // only be deleted once that happened.

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}


/// The loss report under a non-Chinese interface (#72): the store's own report
/// is codes with arguments, so the page renders it in the interface's language
/// instead of the Chinese the store used to write.
void lossReportLanguageTest(Directory Function() root) {
  testWidgets('英文界面下导入摘要与损失报告都是英文', (tester) async {
    // The interface language is part of this row, and English copy is taller
    // than Simplified copy: without this override the row fails with
    // `A RenderFlex overflowed by 184 pixels on the bottom` on the *shelf*
    // page's own vertical Column (`Padding(EdgeInsets.all(32))`, 556.5×480
    // available at the default 800×600 test surface) — the same fixture and the
    // same surface pass in 简体 (`spaceStoreTest`). The Windows desktop window
    // the product ships is 1280×720 (`windows/runner`), and the surface size is
    // not the copy.
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(
          workspaceRoot: root(),
          interfaceLanguage: InterfaceLanguageSetting.english,
        ),
      );
      await tester.pump();
      await tester.tap(find.text('Migration'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('imported this run'));

      // The summary's counts, and the one loss the fixture produces
      // (`online_reading.json`'s last-read pointer has no equivalent field).
      expect(find.textContaining('Book Sources 2'), findsOneWidget);
      expect(find.textContaining('no equivalent field'), findsOneWidget);
      expect(
        find.textContaining('上次阅读'),
        findsNothing,
        reason: '英文界面里不该留下这条中文损失行',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// The source-management surface (#53) as the user reaches it: the migration
/// page's source list deletes a source and edits its URL, and the book that
/// resolved the old URL stays on the shelf, marked.
void sourceManagementTest(Directory Function() root) {
  testWidgets('迁移页删除书源：书源行消失，书架上的书保留并标记', (tester) async {
    _pinShelfSurface(tester);
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      await tester.tap(find.text('迁移'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('本次导入旧数据'));
      await _waitFor(tester, find.text('已导入书源'));
      expect(
        find.textContaining('https://example.test'),
        findsOneWidget,
        reason: '导入进来的书源列在这里',
      );

      final actions = find.byKey(
        const ValueKey('source-actions-https://example.test'),
      );
      await tester.ensureVisible(actions);
      // The overlay routes animate, and a finder that already matches is not yet
      // hit-testable mid-animation: `pumpAndSettle` cannot run inside
      // `runAsync`, so the frames are pumped by hand.
      await _pumpFrames(tester);
      await tester.tap(actions);
      await _waitFor(tester, find.text('删除书源'));
      await _pumpFrames(tester);
      await tester.tap(find.text('删除书源'));
      await _waitFor(tester, find.text('删除'));
      await _pumpFrames(tester);
      await tester.tap(find.text('删除'));
      await _waitFor(tester, find.textContaining('已删除书源'));
      // The page re-reads its source list after the delete, which is a store
      // read the message above does not wait for; the list is the evidence.
      await _waitForGone(
        tester,
        find.byKey(const ValueKey('source-actions-https://example.test')),
      );
      // The confirmation route is still animating out.
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('source-actions-https://example.test')),
        findsNothing,
        reason: '已导入书源里不再有它',
      );
      expect(find.textContaining('已删除书源'), findsOneWidget);

      // The book that resolved the deleted URL is still there, marked: its row,
      // its chapters and its position were never the source's to take.
      await tester.tap(find.text('书架'));
      await tester.pump();
      await _waitFor(tester, find.text('斗破苍穹'));
      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.textContaining('书源已删除'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });

  testWidgets('迁移页修改书源 URL：旧 URL 消失，书架上的书保留并标记', (tester) async {
    _pinShelfSurface(tester);
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      await tester.tap(find.text('迁移'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('本次导入旧数据'));

      final actions = find.byKey(
        const ValueKey('source-actions-https://example.test'),
      );
      await tester.ensureVisible(actions);
      await _pumpFrames(tester);
      await tester.tap(actions);
      await _waitFor(tester, find.text('修改书源 URL'));
      await _pumpFrames(tester);
      await tester.tap(find.text('修改书源 URL'));
      await _waitFor(tester, find.text('保存'));
      await _pumpFrames(tester);
      await tester.enterText(find.byType(TextFormField), 'https://moved.test');
      await tester.tap(find.text('保存'));
      await _waitFor(tester, find.textContaining('已修改书源 URL'));
      // The page re-reads its source list after the re-point, which is a store
      // read the message above does not wait for; the list is the evidence.
      await _waitFor(
        tester,
        find.byKey(const ValueKey('source-actions-https://moved.test')),
      );
      await _pumpFrames(tester);

      expect(
        find.byKey(const ValueKey('source-actions-https://moved.test')),
        findsOneWidget,
        reason: '列表里是书源的新 URL',
      );
      expect(
        find.byKey(const ValueKey('source-actions-https://example.test')),
        findsNothing,
      );

      // The book that came from the old URL keeps its place on the shelf, and
      // the source it points at is the one that no longer exists.
      await tester.tap(find.text('书架'));
      await tester.pump();
      await _waitFor(tester, find.text('斗破苍穹'));
      expect(find.text('斗破苍穹'), findsOneWidget);
      expect(find.textContaining('书源已删除'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
  testWidgets('迁移页登录书源：书源行的登录项打开登录界面（#60）', (tester) async {
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      await tester.tap(find.text('迁移'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('本次导入旧数据'));

      final actions = find.byKey(
        const ValueKey('source-actions-https://example.test'),
      );
      await tester.ensureVisible(actions);
      await _pumpFrames(tester);
      await tester.tap(actions);
      await _waitFor(tester, find.text('登录'));
      await _pumpFrames(tester);
      await tester.tap(find.text('登录'));
      // The migrated source declares no `loginUi`: the surface says so instead
      // of showing an empty form, and nothing of the login runs.
      await _waitFor(tester, find.textContaining('没有可显示的登录界面'));
      expect(find.text('登录书源：Example'), findsOneWidget);

      await tester.tap(find.text('取消'));
      await _waitForGone(tester, find.textContaining('没有可显示的登录界面'));
      await _pumpFrames(tester);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// The shelf page's own scrolling (#86).
///
/// The operator's shelf holds 1424 rows and, while scrolling, the page's position
/// and scrollbar thumb jumped: the rows hung under one `OnlineBookshelf` that was
/// a single child the size of the whole shelf, so the page's `maxScrollExtent` was
/// an extrapolation over a few wildly unequal children that the next layout
/// corrected. This fixture shelves 300 rows through the same legacy import the
/// other rows use, so both halves of the fix are observable: only the rows on
/// screen are built, and the extent does not move under a scroll.
void shelfScrollTest(Directory Function() root) {
  testWidgets('书架 300 行：只构建可见的行，滚动范围不在滚动中改变', (tester) async {
    _pinShelfSurface(tester);
    final workspaceRoot = root();
    File(
      '${workspaceRoot.path}${Platform.pathSeparator}online_reading.json',
    ).writeAsStringSync(
      jsonEncode({
        'version': 2,
        'last': '',
        'records': [
          for (var index = 0; index < 300; index++)
            _legacyRecord(
              url: 'https://example.test/book/$index',
              title: '书籍${index.toString().padLeft(3, '0')}',
            ),
        ],
      }),
    );
    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      // A 300-record import takes seconds on a shared runner; the default
      // five-second budget is not enough for it.
      await _waitFor(tester, find.text('书籍000'), attempts: 400);
      expect(find.text('书籍000'), findsOneWidget, reason: '第一行是第一本书');

      // Only the rows the viewport reaches are built; the rest of the 300 are
      // not in the tree at all.
      expect(
        find.byType(ListTile).evaluate().length,
        lessThan(40),
        reason: '300 行里只有可见的几十行被构建',
      );
      expect(find.text('书籍299'), findsNothing, reason: '视口之外的行没有建');
      expect(
        tester.getTopLeft(find.text('书籍001')).dy,
        greaterThan(tester.getTopLeft(find.text('书籍000')).dy),
      );

      // The page's own scrollable: a drag moves the position by what was
      // dragged, and the scroll range never moves under the reader. The rows
      // used to be one child the size of the whole shelf, which made this page
      // report a range of 43256 for a page whose real range is 21628 and snap
      // to the real one at step 56 of this scroll — the operator's jump,
      // scrollbar thumb included. On the sliver tree the range is right from
      // the start and stays put.
      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      final extent = position.maxScrollExtent;
      expect(extent, greaterThan(600), reason: '300 行是长清单');
      var step = 0;
      while (position.pixels < extent - 600) {
        expect(step, lessThan(100), reason: '一直拖不到末尾：这个范围不是这一页的');
        final before = position.pixels;
        await tester.drag(scrollable, const Offset(0, -400));
        await tester.pump();
        expect(
          position.maxScrollExtent,
          extent,
          reason: '滚动范围不在滚动中校正（第 $step 步）',
        );
        if (position.pixels < extent - 600) {
          expect(
            position.pixels,
            // `tester.drag` spends its first 20 pixels on the drag's own touch
            // slop, so the position moves by the drag distance less that.
            closeTo(before + 400, 40),
            reason: '拖多少就走多少（第 $step 步）',
          );
        }
        step++;
      }
      // One more drag puts the page at its end, still on the same range.
      await tester.drag(scrollable, const Offset(0, -400));
      await tester.pump();
      expect(position.maxScrollExtent, extent, reason: '滚到末尾，范围还是那一个');
      expect(position.pixels, closeTo(extent, 0.5), reason: '末尾就是末尾');

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// The shelf's own filter (#88).
///
/// The operator's shelf holds 1424 rows, and the precise search (`#23`) runs the
/// sources over the network, which is not what "find a book I already have"
/// means. This fixture is the #86 one grown by the two other sections — 301
/// online rows, one migrated row, one local book — so all three narrow together
/// and "the rows on screen" stays unmistakable from "all of them".
void shelfFilterTest(Directory Function() root) {
  testWidgets('筛选：输入就窄，清除就回来，没匹配就说出这一行', (tester) async {
    _pinShelfSurface(tester);
    final workspaceRoot = root();
    final separator = Platform.pathSeparator;
    // `Dune` carries an ASCII title and an author: the case-insensitive half and
    // the author half of the filter are both about it.
    File(
      '${workspaceRoot.path}${separator}online_reading.json',
    ).writeAsStringSync(
      jsonEncode({
        'version': 2,
        'last': '',
        'records': [
          _legacyRecord(
            url: 'https://example.test/book/dune',
            title: 'Dune',
            author: 'Frank Herbert',
          ),
          for (var index = 0; index < 300; index++)
            _legacyRecord(
              url: 'https://example.test/book/$index',
              title: '书籍${index.toString().padLeft(3, '0')}',
            ),
        ],
      }),
    );
    final localRoot = Directory('${workspaceRoot.path}${separator}local')
      ..createSync();
    final localFile = File('${localRoot.path}${separator}note.txt')
      ..writeAsStringSync('本地文件的一行');
    File(
      '${workspaceRoot.path}${separator}local_books.json',
    ).writeAsStringSync(
      jsonEncode({
        'root': {
          'id': localRoot.absolute.path.toLowerCase(),
          'displayName': localRoot.absolute.path,
        },
        'books': [
          {
            'path': localFile.path,
            'relativePath': 'note.txt',
            'title': '本地笔记',
            'format': 'txt',
            'textOffset': 0,
          },
        ],
      }),
    );
    // A book with no source and no local file: the shelf lists it as the record
    // it is, which is the migrated section.
    File(
      '${workspaceRoot.path}${separator}migration_state.json',
    ).writeAsStringSync(
      jsonEncode({
        'sources': <Object>[],
        'books': [
          {
            'id': 'legacy-1',
            'title': '旧记录甲',
            'progressOffset': 3,
            'needsRelink': true,
          },
        ],
      }),
    );

    await tester.runAsync(() async {
      await tester.pumpWidget(
        LiberApp(workspaceRoot: workspaceRoot, interfaceLanguage: testLocale),
      );
      await tester.pump();
      // A 301-record import takes seconds on a shared runner.
      await _waitFor(tester, find.text('Dune'), attempts: 400);

      final field = find.byKey(const ValueKey('shelf-filter'));
      final countLine = find.byKey(const ValueKey('shelf-filter-count'));
      String? count() => countLine.evaluate().isEmpty
          ? null
          : tester.widget<Text>(countLine).data;
      Future<void> type(String query) async {
        await tester.enterText(field, query);
        await tester.pump();
      }

      // The whole shelf, and no count line: an empty field shows everything, the
      // way the shelf has always been.
      expect(find.text('按书名或作者筛选'), findsOneWidget, reason: '占位文字说出筛的是什么');
      expect(count(), isNull, reason: '没有筛选就没有计数行');
      expect(find.text('Dune'), findsOneWidget);
      expect(find.text('书籍000'), findsOneWidget);

      // Typing narrows: `书籍1` is carried by 100 of the 301 online rows, and
      // the row that does not carry it is gone while the first match takes the
      // first row. The built rows stay the viewport's few — a filter over 100
      // matches is not 100 rows of widgets.
      await type('书籍1');
      expect(count(), '显示 100 / 303');
      expect(find.text('书籍100'), findsOneWidget, reason: '第一条匹配排在筛出来的第一行');
      expect(find.text('Dune'), findsNothing, reason: '不匹配的行不在了');
      expect(find.text('书籍099'), findsNothing, reason: '不匹配的行不在了');
      expect(
        find.byType(ListTile, skipOffstage: false).evaluate().length,
        lessThan(40),
        reason: '100 条匹配里，只为视口建行的还是那几十条以内',
      );
      expect(
        find.text('书籍199', skipOffstage: false),
        findsNothing,
        reason: '视口之外的行根本没有建',
      );

      // Clearing brings the whole shelf back, and the count line goes with the
      // filter that asked for it.
      await tester.tap(find.byKey(const ValueKey('shelf-filter-clear')));
      await tester.pump();
      expect(count(), isNull);
      expect(find.text('Dune'), findsOneWidget, reason: '清除后整张书架回来');
      expect(
        find.byType(ListTile, skipOffstage: false).evaluate().length,
        lessThan(40),
        reason: '清除不等于把 301 行都建出来',
      );

      // Case-insensitively, by title and by author — what the placeholder says
      // the field searches.
      await type('dune');
      expect(count(), '显示 1 / 303');
      expect(find.text('Dune'), findsOneWidget);
      await type('frank herbert');
      expect(count(), '显示 1 / 303');
      expect(find.text('Dune'), findsOneWidget);

      // Every section narrows: a migrated row, then a local book, each counted
      // against the whole shelf.
      await type('旧记录');
      expect(count(), '显示 1 / 303');
      expect(find.text('旧记录甲'), findsOneWidget);
      await type('本地笔记');
      expect(count(), '显示 1 / 303');
      // The field holds those very words, so the row is named by its tile.
      expect(find.widgetWithText(ListTile, '本地笔记'), findsOneWidget);

      // A filter that matches nothing says so in its own line, and the count
      // says the shelf is still there.
      await type('没有这样的书');
      expect(count(), '显示 0 / 303');
      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('shelf-filter-empty')))
            .data,
        '没有匹配的书',
      );

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// Pins the surface the shelf page's rows need.
///
/// Since #88 the page's header carries the filter field, so the first shelf row
/// sits ~76px lower than the default 800x600 test surface shows — and that
/// surface leaves the shelf exactly one row of room to begin with. The surface
/// is not the copy: the product's window is 1280x720 (`windows/runner`), which
/// `lossReportLanguageTest` pins for its own header-height reason. Only the
/// surface changes; what these tests assert about the rows does not.
void _pinShelfSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Pumps the frames an animated route needs. `runAsync` has no `pumpAndSettle`:
/// it would wait for frames that only the animation itself produces.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Real work finishes on real time, so wait for the text instead of guessing a
/// duration.
Future<void> _waitFor(
  WidgetTester tester,
  Finder finder, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

/// The other half of [_waitFor]: wait for a widget the page is supposed to drop.
Future<void> _waitForGone(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump();
  }
}

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-app-');
    await _writeLegacyStores(root);
  });

  // The app lets go of the space when its page is disposed, which is
  // asynchronous: the directory can only go once the database file is closed.
  tearDown(() async {
    for (var attempt = 0; attempt < 40; attempt++) {
      try {
        await root.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    await root.delete(recursive: true);
  });

  defaultAppTest(() => root);
  spaceStoreTest(() => root);
  settingsEntryTest(() => root);
  lossReportLanguageTest(() => root);
  sourceManagementTest(() => root);
  shelfScrollTest(() => root);
  shelfFilterTest(() => root);
}

/// One `online_reading.json` v2 record, the shape the retired JSON store wrote:
/// a book under the `Example` source, shelved, with one chapter and a position.
Map<String, dynamic> _legacyRecord({
  required String url,
  required String title,
  String author = '天蚕土豆',
}) => {
  'source': {
    'bookSourceUrl': 'https://example.test',
    'bookSourceName': 'Example',
  },
  'book': {
    'url': url,
    'title': title,
    'author': author,
    'intro': '',
    'cover': '',
  },
  'chapterUrl': '',
  'chapterName': '',
  'textOffset': 12,
  'chapters': [
    {'name': '第一章', 'url': '$url/1'},
  ],
  'shelved': true,
};

/// The three JSON stores live in the installation directory itself, next to the
/// manifest and the space database.
Future<void> _writeLegacyStores(Directory home) async {
  await File(
    '${home.path}${Platform.pathSeparator}online_reading.json',
  ).writeAsString(
    jsonEncode({
      'version': 2,
      'last': '',
      'records': [
        _legacyRecord(url: 'https://example.test/book/1', title: '斗破苍穹'),
      ],
    }),
  );
  await File(
    '${home.path}${Platform.pathSeparator}migration_state.json',
  ).writeAsString(
    jsonEncode({
      'sources': [
        {
          'id': 'fixture',
          'data': {'bookSourceUrl': 'fixture', 'bookSourceName': 'Fixture'},
        },
      ],
      'books': [],
    }),
  );
}
