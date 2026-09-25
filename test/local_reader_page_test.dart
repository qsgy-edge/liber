import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/l10n/app_localizations.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/local_reader_page.dart';
import 'package:liber/store/space_store.dart';

import 'local_reader_support.dart';

import 'l10n_support.dart';

import 'temp_directory.dart';

/// The reader page with the engine faked: the test binding never settles
/// `flutter_rust_bridge`'s pending work, so the native library is out of reach
/// here — which is why the page is written against [ReaderEngine] at all.
///
/// Opening a book touches the file system, so the whole drive runs inside
/// `runAsync` and waits for what it looks for instead of guessing a duration.
void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-reader-page-');
    file = File('${root.path}${Platform.pathSeparator}book.txt');
  });

  tearDown(() async {
    final directory = root;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await deleteTempDirectory(directory);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  /// A book on disk with an in-memory space behind it, and the reader over
  /// both.
  Future<({LocalReader reader, SpaceStore store, LocalBook book, String text})>
  openBook({String? text}) async {
    final content = text ?? novelText(chapters: 12);
    await file.writeAsString(content);
    final space = await admittedBook(file);
    final book = space.book;
    return (
      reader: LocalReader(
        engine: FakeEngine(content, chapters: chaptersOf(content)),
        library: space.library,
        book: book,
        pageCodeUnits: 256,
      ),
      store: space.store,
      book: book,
      text: content,
    );
  }

  String windowText(WidgetTester tester) =>
      tester.widget<Text>(find.byKey(const ValueKey('reader-window'))).data!;

  testWidgets('阅读页只渲染一页，翻页把位置写回存储', (tester) async {
    await tester.runAsync(() async {
      final opened = await openBook();
      await tester.pumpWidget(
        localizedApp(home: LocalReaderPage(reader: opened.reader)),
      );
      await _waitFor(tester, find.byKey(const ValueKey('reader-window')));

      expect(windowText(tester), opened.text.substring(0, 256));
      expect(find.text('offset 0 / ${opened.text.length}'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '上一页'))
            .onPressed,
        isNull,
        reason: '文件开头没有上一页',
      );

      await tester.tap(find.text('下一页'));
      await tester.pump();
      await _waitFor(tester, find.text('offset 256 / ${opened.text.length}'));

      final record = await opened.reader.library.progressRecordOf(
        opened.book.id,
      );
      expect(record, isNotNull);
      expect(record!.textLength, opened.text.length);
      expect(record.anchor, isNotNull);
      expect(record.textOffset, greaterThan(0));

      await tester.tap(find.text('保存位置'));
      await tester.pump();
      expect(find.text('阅读位置已保存'), findsOneWidget);
    });
  });

  testWidgets('文件被改过：页面把恢复的改动显示出来', (tester) async {
    await tester.runAsync(() async {
      final opened = await openBook();
      await tester.pumpWidget(
        localizedApp(home: LocalReaderPage(reader: opened.reader)),
      );
      await _waitFor(tester, find.byKey(const ValueKey('reader-window')));
      await tester.tap(find.text('下一页'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('offset 256'));

      // The file changes behind the reader's back: the page that opens next
      // restores the stored position instead of jumping silently.
      final edited = '新插入的一行\n' * 40 + opened.text;
      await file.writeAsString(edited);
      final reopened = LocalReader(
        engine: FakeEngine(edited, chapters: chaptersOf(edited)),
        library: opened.reader.library,
        book: opened.book,
        pageCodeUnits: 256,
      );
      // A page of the same type keeps its state, so the old one is unmounted
      // before the reopened reader takes the screen.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        localizedApp(home: LocalReaderPage(reader: reopened)),
      );
      await _waitFor(tester, find.byKey(const ValueKey('reader-notice')));

      expect(find.text('文件已改动：阅读位置按锚点重新定位'), findsOneWidget);
      expect(windowText(tester), isNotEmpty);
    });
  });

  testWidgets('英文界面：恢复的改动用界面的英文文案显示', (tester) async {
    await tester.runAsync(() async {
      final opened = await openBook();
      await tester.pumpWidget(
        localizedApp(
          home: LocalReaderPage(reader: opened.reader),
          locale: const Locale('en'),
        ),
      );
      await _waitFor(tester, find.byKey(const ValueKey('reader-window')));
      await tester.tap(find.text('Next page'));
      await tester.pump();
      await _waitFor(tester, find.textContaining('offset 256'));

      // The file changes behind the reader's back, exactly as in the row above;
      // the notice is the same code, rendered in this interface's language.
      final edited = '新插入的一行\n' * 40 + opened.text;
      await file.writeAsString(edited);
      final reopened = LocalReader(
        engine: FakeEngine(edited, chapters: chaptersOf(edited)),
        library: opened.reader.library,
        book: opened.book,
        pageCodeUnits: 256,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await tester.pumpWidget(
        localizedApp(
          home: LocalReaderPage(reader: reopened),
          locale: const Locale('en'),
        ),
      );
      await _waitFor(tester, find.byKey(const ValueKey('reader-notice')));

      expect(
        find.text(
          'The file changed: the reading position was relocated by its anchor',
        ),
        findsOneWidget,
      );
      expect(windowText(tester), isNotEmpty);
    });
  });

  test('两个提示的每一段文案在简体与英文界面里都渲染出各自的字', () async {
    final zh = await AppLocalizations.delegate.load(const Locale('zh'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));

    expect(
      LocalReaderNotice.readerRestoreRelocated.text(zh),
      '文件已改动：阅读位置按锚点重新定位',
    );
    expect(
      LocalReaderNotice.readerRestoreSearched.text(zh),
      '文件已改动：阅读位置在文件中重新找到',
    );
    expect(
      LocalReaderNotice.readerRestoreLineIndex.text(zh),
      '文件已替换：阅读位置按行号恢复，请检查',
    );
    expect(
      LocalReaderNotice.readerRestorePercentage.text(zh),
      '文件已替换：阅读位置按百分比恢复，请检查',
    );
    expect(
      LocalReaderNotice.readerDeletedPosition.text(zh),
      '替换规则改写了这一行：阅读位置移到改动处的正文',
    );

    expect(
      LocalReaderNotice.readerRestoreRelocated.text(en),
      'The file changed: the reading position was relocated by its anchor',
    );
    expect(
      LocalReaderNotice.readerRestoreSearched.text(en),
      'The file changed: the reading position was found again in the file',
    );
    expect(
      LocalReaderNotice.readerRestoreLineIndex.text(en),
      'The file was replaced: the reading position was restored by line number; '
      'please check',
    );
    expect(
      LocalReaderNotice.readerRestorePercentage.text(en),
      'The file was replaced: the reading position was restored by percentage; '
      'please check',
    );
    expect(
      LocalReaderNotice.readerDeletedPosition.text(en),
      'A replace rule rewrote this line: the reading position moved to the text '
      'at the change',
    );
  });

  testWidgets('文件不见了：页面说清楚而不是空白', (tester) async {
    await tester.runAsync(() async {
      final opened = await openBook();
      await file.delete();
      final reopened = LocalReader(
        engine: FakeEngine(opened.text, chapters: chaptersOf(opened.text)),
        library: opened.reader.library,
        book: opened.book,
        pageCodeUnits: 256,
      );
      await tester.pumpWidget(
        localizedApp(home: LocalReaderPage(reader: reopened)),
      );
      await _waitFor(tester, find.textContaining('文件不存在'));

      expect(find.textContaining('无法读取'), findsOneWidget);
      expect(
        (await opened.store.bookById(opened.book.id))!.needsRelink,
        isTrue,
      );
    });
  });
}

/// Real work finishes on real time, so wait for the text instead of guessing a
/// duration.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}
