import 'dart:async';
import 'dart:io';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/local_reader_page.dart';
import 'package:liber/local/reader_engine.dart' show ReaderIndex;
import 'package:liber/settings/reader_script.dart';
import 'package:liber/settings/reader_script_page.dart';

import 'local_reader_support.dart';

/// The local reader's conversion (#27): the page resolves the setting before it
/// opens the book, and changing it re-renders what is on screen without opening
/// the book again.
///
/// A widget test with a fake engine, so the raw path renders the target the fake
/// is asked for instead of loading the native library; the processed path gets a
/// pure-Dart conversion double for the same reason, with a conversion that keeps
/// the text's length so the reader's offset map stays exact. Opening a book
/// touches the file system, so the drive runs inside `runAsync` and waits for
/// what it looks for instead of guessing a duration.
String fakeConvert(String text, ConvertTarget target) => switch (target) {
  ConvertTarget.simplifiedMainland =>
    text.replaceAll('龍', '龙').replaceAll('鳳', '凤'),
  _ => text,
};

/// An engine whose index pass waits on a gate, so a test can hold a book in the
/// middle of opening and call into the reader from that window.
class GatedIndexEngine extends FakeEngine {
  GatedIndexEngine(super.text, {super.chapters, super.anchorStrideCodeUnits});

  final Completer<void> gate = Completer<void>();

  @override
  Future<ReaderIndex> index(String path) async {
    await gate.future;
    return super.index(path);
  }
}

void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-reader-script-');
    file = File('${root.path}${Platform.pathSeparator}book.txt');
  });

  tearDown(() async {
    final directory = root;
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        await directory.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  void systemLocale(WidgetTester tester, Locale locale) {
    tester.binding.platformDispatcher.localeTestValue = locale;
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
  }

  Future<void> openPage(WidgetTester tester, LocalReader reader) async {
    await tester.pumpWidget(MaterialApp(home: LocalReaderPage(reader: reader)));
    await _waitFor(tester, find.byKey(const ValueKey('reader-window')));
  }

  /// Opens the conversion screen from the reader, picks one choice and comes
  /// back; the reader re-resolves and re-renders on the way back. The screen
  /// scrolls, so a row below the fold is brought into the viewport first.
  Future<void> chooseScript(
    WidgetTester tester,
    String key,
    bool Function() applied,
  ) async {
    await tester.tap(find.byTooltip('中文转换'));
    await _waitFor(
      tester,
      find.byKey(const ValueKey('reader-script-effective')),
    );
    await tester.scrollUntilVisible(
      find.byKey(ValueKey(key)),
      300,
      scrollable: find.descendant(
        of: find.byType(ReaderScriptPage),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pump();
    await tester.pageBack();
    await _waitUntil(tester, applied);
  }

  testWidgets('zh-TW 不开设置就渲染繁體（台灣），改设置后重新渲染而不重新打开', (tester) async {
    await tester.runAsync(() async {
      systemLocale(tester, const Locale('zh', 'TW'));
      const text = '第一章 起点\n龍與鳳就在這裡。\n';
      await file.writeAsString(text);
      final space = await admittedBook(file);
      final engine = FakeEngine(
        text,
        chapters: chaptersOf(text),
        anchorStrideCodeUnits: 512,
      );
      final reader = LocalReader(
        engine: engine,
        library: space.library,
        book: space.book,
        pageCodeUnits: 64,
      );

      await openPage(tester, reader);
      expect(reader.error, isNull);
      expect(reader.script, ConvertTarget.traditionalTaiwan);
      expect(reader.text, startsWith('«traditionalTaiwan»'));

      final indexPasses = engine.indexPasses;
      final reads = engine.reads.length;
      await chooseScript(
        tester,
        'reader-script-global-simplified',
        () => reader.script == ConvertTarget.simplifiedMainland,
      );

      expect(reader.text, startsWith('«simplifiedMainland»'));
      expect(engine.indexPasses, indexPasses, reason: '改脚本不重新打开书');
      expect(engine.reads.length, reads, reason: '窗口还在手里，不用重读');
      expect(await space.store.setting(ReaderScriptSetting.key), 'simplified');
    });
  });

  testWidgets('规则处理路径按同一个解析重新渲染，位置不动', (tester) async {
    await tester.runAsync(() async {
      systemLocale(tester, const Locale('zh', 'CN'));
      const text = '第一章 起点\n龍與鳳就在這裡。\n';
      await file.writeAsString(text);
      final space = await admittedBook(file);
      final engine = FakeEngine(
        text,
        chapters: chaptersOf(text),
        anchorStrideCodeUnits: 512,
      );
      final reader = LocalReader(
        engine: engine,
        library: space.library,
        book: space.book,
        processing: literalProcessing(const [], convert: fakeConvert),
        pageCodeUnits: 4096,
      );

      await openPage(tester, reader);
      expect(reader.error, isNull);
      expect(reader.script, ConvertTarget.simplifiedMainland);
      expect(reader.text, contains('龙'));
      final position = reader.position!.textOffset;
      final indexPasses = engine.indexPasses;

      await chooseScript(
        tester,
        'reader-script-book-traditional_taiwan',
        // The re-render is what the reader shows, not the field the resolution
        // sets on the way there.
        () => reader.text.contains('龍'),
      );

      expect(reader.text, contains('龍'));
      expect(reader.text, isNot(contains('龙')));
      expect(reader.position!.textOffset, position, reason: '转换只改显示');
      expect(engine.indexPasses, indexPasses);
      expect(
        await space.store.setting(
          ReaderScriptSetting.key,
          bookId: space.book.id,
        ),
        'traditional_taiwan',
      );
    });
  });

  test('打开还没结束时收到脚本请求：不打断这次打开', () async {
    const text = '第一章 起点\n龍與鳳就在這裡。\n';
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = GatedIndexEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing(const [], convert: fakeConvert),
      pageCodeUnits: 4096,
    );

    // What the page does before opening: it hands the resolved script over.
    await reader.applyScript(ConvertTarget.simplifiedMainland);
    final opened = reader.open();
    // The index pass is held on the gate, so the open is in flight here.
    await Future<void>.delayed(Duration.zero);
    await reader.applyScript(ConvertTarget.traditionalTaiwan);
    expect(
      reader.script,
      ConvertTarget.simplifiedMainland,
      reason: '打开过程中的请求不能落在半开的会话上',
    );

    engine.gate.complete();
    await opened;

    expect(reader.error, isNull);
    expect(reader.text, contains('龙'));
    expect(reader.text, isNot(contains('龍')), reason: '这本书用它拿到脚本时的目标开');
    expect(
      reader.position!.textOffset,
      text.indexOf('龍與鳳'),
      reason: '正文第一行，没有被两次物质化搬动',
    );
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

/// Waits for a condition the drive cannot see on screen (a reader's resolved
/// target), pumping frames so whatever the page rebuilds is built.
Future<void> _waitUntil(WidgetTester tester, bool Function() done) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (done()) {
      await tester.pump();
      return;
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await tester.pump();
  }
}
