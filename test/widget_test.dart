import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:liber/main.dart';

void defaultAppTest(Directory Function() root) {
  testWidgets('Windows MVP shows the controlled source workbench', (
    tester,
  ) async {
    await tester.pumpWidget(LiberApp(workspaceRoot: root()));

    expect(find.text('书架'), findsNWidgets(2));
    expect(find.text('Wayfinder 受控书源'), findsOneWidget);
    expect(find.text('尚未运行'), findsOneWidget);
    // The conversion screen has an entry point in the app bar (#27); the space
    // is not open yet, so it is disabled until it is.
    final settings = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.translate),
        matching: find.byType(IconButton),
      ),
    );
    expect(settings.tooltip, '中文转换');
    expect(settings.onPressed, isNull);
  });
}

/// The startup path does real work — opening the space database runs in a
/// background isolate — so it needs `runAsync`; `pumpAndSettle` in the fake
/// zone would wait for frames that never come.
void spaceStoreTest(Directory Function() root) {
  testWidgets('迁移页报告旧数据导入结果，原文件退休后书架仍从空间读取', (tester) async {
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(LiberApp(workspaceRoot: workspaceRoot));
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
      await tester.pumpWidget(LiberApp(workspaceRoot: workspaceRoot));
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

/// The source-management surface (#53) as the user reaches it: the migration
/// page's source list deletes a source and edits its URL, and the book that
/// resolved the old URL stays on the shelf, marked.
void sourceManagementTest(Directory Function() root) {
  testWidgets('迁移页删除书源：书源行消失，书架上的书保留并标记', (tester) async {
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(LiberApp(workspaceRoot: workspaceRoot));
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
    final workspaceRoot = root();
    await tester.runAsync(() async {
      await tester.pumpWidget(LiberApp(workspaceRoot: workspaceRoot));
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
      await tester.pumpWidget(LiberApp(workspaceRoot: workspaceRoot));
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

/// Pumps the frames an animated route needs. `runAsync` has no `pumpAndSettle`:
/// it would wait for frames that only the animation itself produces.
Future<void> _pumpFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Real work finishes on real time, so wait for the text instead of guessing a
/// duration.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
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
  sourceManagementTest(() => root);
}

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
        {
          'source': {
            'bookSourceUrl': 'https://example.test',
            'bookSourceName': 'Example',
          },
          'book': {
            'url': 'https://example.test/book/1',
            'title': '斗破苍穹',
            'author': '天蚕土豆',
            'intro': '',
            'cover': '',
          },
          'chapterUrl': '',
          'chapterName': '',
          'textOffset': 12,
          'chapters': [
            {'name': '第一章', 'url': 'https://example.test/book/1/1'},
          ],
          'shelved': true,
        },
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
