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

/// Real work finishes on real time, so wait for the text instead of guessing a
/// duration.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
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
