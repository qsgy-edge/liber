import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/local/reader_offset_map.dart';
import 'package:liber/source/content_processing.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/space_store.dart';

import 'local_reader_support.dart';

/// The reader's processed path: the bounded unit materialised and run through
/// #17's one text entry, and the raw-space position translated through the
/// unit's raw ↔ processed map.
///
/// A plain (non-widget) test. The rules are literal, so no rule needs the
/// isolate a regex rule runs in.
void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-reader-processing-');
    file = File('${root.path}${Platform.pathSeparator}book.txt');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Only the fixture is on disk; the space's database is in memory.
    }
  });

  Future<OpenProcessedBook> openBook({
    required String text,
    ContentProcessing? processing,
    int pageCodeUnits = 256,
    int unitCodeUnits = 102400,
    int readChunkCodeUnits = 64 * 1024,
    ReaderScript? script,
  }) async {
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
      processing: processing,
      pageCodeUnits: pageCodeUnits,
      unitCodeUnits: unitCodeUnits,
      readChunkCodeUnits: readChunkCodeUnits,
      script: script,
    );
    await reader.open();
    return OpenProcessedBook(
      store: space.store,
      library: space.library,
      book: space.book,
      engine: engine,
      reader: reader,
      text: text,
    );
  }

  test('同一模块处理两条路径：本地章节与同一段在线正文得到同样的文本', () async {
    final processing = literalProcessing([(pattern: '广告', replacement: '')]);
    const heading = '第1章 起点';
    // No body line starts with a heading marker (the test indexer's rule), so
    // the only boundaries are the two headings.
    const body = '广告正文第一行\n另一行 广告\n   \n收尾这一段';
    final online = await processing.content(body, chapterTitle: heading);

    final opened = await openBook(
      text: '$heading\n$body\n第2章 终点\n第二章的正文\n',
      processing: processing,
      // One page holds the whole unit, so the displayed text is the unit's.
      pageCodeUnits: 4096,
    );

    expect(opened.reader.error, isNull);
    expect(opened.reader.text, online, reason: '本地路径把章节正文交给同一个入口，结果与在线路径一致');
  });

  test('规则启用下跨重启的进度往返落在同一可见行', () async {
    final text = novelText(chapters: 6, paragraphs: 5, repeats: 2);
    final rules = <({String pattern, String replacement})>[
      (pattern: '这是', replacement: '那是'),
    ];
    final opened = await openBook(
      text: text,
      processing: literalProcessing(rules),
      pageCodeUnits: 128,
    );
    final reader = opened.reader;
    await reader.open();
    await reader.next();
    await reader.next();
    final visible = reader.text;
    final record = (await opened.library.progressRecordOf(opened.book.id))!;

    // A restart: the same store and rules, a new session.
    final reopened = LocalReader(
      engine: opened.engine,
      library: opened.library,
      book: opened.book,
      processing: literalProcessing(rules),
      pageCodeUnits: 128,
    );
    await reopened.open();

    expect(reopened.notice, isNull, reason: '文件没变，恢复就是精确的那一档');
    expect(reopened.position!.textOffset, record.textOffset);
    expect(reopened.position!.textLength, text.length);
    expect(reopened.text, visible, reason: '规则改写了行，逐行的对应仍让页面落在同一可见行');
    expect(reopened.text, startsWith('　　'), reason: '显示的是处理后的文本');
  });

  test('规则启用前写下的 raw 记录仍然落在同一条正文行上', () async {
    final text = novelText(chapters: 4, paragraphs: 4, repeats: 2);
    await file.writeAsString(text);
    final space = await admittedBook(file);
    // A record the plain window reader wrote before the rules existed: the raw
    // offset of a body line's start and that raw line's anchor.
    final offset = text.indexOf('这是第2章的第3段');
    final facts = positionFacts(text, offset);
    final lineStart = offset - facts.offsetInLine;
    await space.library.saveProgressRecord(
      space.book.id,
      recordAt(text, lineStart),
    );

    final processing = literalProcessing([(pattern: '这是', replacement: '那是')]);
    final engine = FakeEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: processing,
      pageCodeUnits: 4096,
    );
    await reader.open();

    expect(reader.error, isNull);
    expect(reader.notice, isNull, reason: '文件没变，精确恢复，规则不改变恢复结果');
    expect(reader.position!.textOffset, lineStart, reason: '位置仍在 raw 空间');
    expect(
      reader.text.split('\n').first,
      '　　${anchorOf(text.substring(lineStart))!.replaceAll('这是', '那是')}',
      reason: '页面落在 raw 行对应的处理后行',
    );
  });

  test('规则变化不作废 raw 位置', () async {
    final text = novelText(chapters: 3, paragraphs: 4, repeats: 2);
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    final first = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing([(pattern: '这是', replacement: '那是')]),
      pageCodeUnits: 128,
    );
    await first.open();
    await first.next();
    final stored = (await space.library.progressRecordOf(space.book.id))!;

    // The rule set changes: the same store, a reader with different rules.
    final second = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing([(pattern: '第', replacement: '篇')]),
      pageCodeUnits: 128,
    );
    await second.open();

    expect(second.notice, isNull, reason: '文件没变，规则变化不是文件变化');
    expect(second.position!.textOffset, stored.textOffset);
    expect(second.error, isNull);
  });

  test('没有 TOC 标记的文件：一个隐式章节，按上限单元分块应用规则', () async {
    final text = List.generate(
      400,
      (line) => '这是第 $line 行的一些普通正文内容',
    ).join('\n');
    final opened = await openBook(
      text: text,
      processing: literalProcessing([(pattern: '这是', replacement: '那是')]),
      pageCodeUnits: 128,
      unitCodeUnits: 512,
    );

    expect(opened.reader.error, isNull);
    expect(opened.reader.position!.chapterKey, isNull, reason: '没有章节标记');
    expect(opened.reader.text, startsWith('　　'), reason: '隐式章节也走同一个入口');
    expect(
      opened.engine.largestRead,
      lessThanOrEqualTo(512),
      reason: '单元有上限，引擎拿到的是一段而不是整份文件',
    );
    expect(opened.engine.largestRead * 4, lessThan(text.length));

    // Paging walks across the unit boundaries without error.
    for (var step = 0; step < 20 && opened.reader.hasNext; step++) {
      await opened.reader.next();
    }
    expect(opened.reader.error, isNull);
    expect(opened.reader.text, isNotEmpty);
  });

  test('超长章节切成连续单元，读到的永远是一段', () async {
    final text = novelText(chapters: 2, paragraphs: 60, repeats: 8);
    final opened = await openBook(
      text: text,
      processing: literalProcessing([(pattern: '这是', replacement: '那是')]),
      pageCodeUnits: 256,
      unitCodeUnits: 1024,
      readChunkCodeUnits: 1024,
    );

    expect(opened.reader.error, isNull);
    expect(
      opened.engine.largestRead,
      lessThanOrEqualTo(1024),
      reason: '一个单元不超过上限，一次读不超过一个单元',
    );
    expect(opened.engine.largestRead * 4, lessThan(text.length));

    for (var step = 0; step < 10 && opened.reader.hasNext; step++) {
      await opened.reader.next();
    }
    await opened.reader.previous();
    expect(opened.reader.error, isNull);
  });

  test('无 TOC 的大文件深处打开只走位置之前的边界，不枚举整个 region', () async {
    // Far more cap-units than the position walks, and one implicit chapter, so
    // the region spans the whole file. Opening must stop at the position's
    // boundary, not walk to the region's end (D4: no whole-document scan).
    final text = List.generate(600, (line) => '普通正文第$line行').join('\n');
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      text,
      chapters: const <ReaderChapter>[],
      anchorStrideCodeUnits: 4096,
    );
    final target = text.indexOf('普通正文第150行');
    await space.library.saveProgressRecord(
      space.book.id,
      recordAt(text, target),
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing(
        const <({String pattern, String replacement})>[],
      ),
      pageCodeUnits: 4096,
      unitCodeUnits: 64,
      readChunkCodeUnits: 64,
    );

    final before = engine.reads.length;
    await reader.open();
    final openedReads = engine.reads.length - before;

    final unitsBefore = target ~/ 64;
    final unitsWhole = text.length ~/ 64;
    expect(unitsWhole, greaterThan(unitsBefore * 2), reason: '文件远大于位置之前的单元');
    expect(
      openedReads,
      lessThanOrEqualTo(unitsBefore * 2 + 16),
      reason: '只走到位置之前的边界，没有枚举整个 region',
    );

    // The cache holds only the prefix: paging back and forward still works.
    await reader.previous();
    expect(reader.error, isNull);
    await reader.next();
    expect(reader.error, isNull);
    expect(reader.text, isNotEmpty);
  });

  test('规则插入一行：页面仍落在可见行上', () async {
    const text = '第1章 起点\n甲行\n乙行\n丙行\n第2章 终点\n丁行';
    final processing = literalProcessing([
      (pattern: '乙行', replacement: '乙行\n插入行'),
    ]);
    final opened = await openBook(
      text: text,
      processing: processing,
      pageCodeUnits: 4096,
    );

    final expected = await processing.content(
      '甲行\n乙行\n丙行\n',
      chapterTitle: '第1章 起点',
    );
    expect(opened.reader.text, expected);

    await opened.reader.next();
    expect(opened.reader.error, isNull);
    expect(opened.reader.text, isNotEmpty);
  });

  group('ReaderOffsetMap', () {
    test('未改写行精确映射，改写行也保持逐行的对应', () {
      const raw = '第一行\n第二行\n第三行';
      const processed = '　　第一行\n　　第二行改\n　　第三行';
      final map = buildOffsetMap(
        rawText: raw,
        rawBase: 0,
        processedText: processed,
      );

      expect(map.processedForRaw(0), 0);
      expect(map.processedForRaw(4), '　　第一行\n'.length, reason: '改写行仍有对应');
      expect(map.processedForRaw(8), '　　第一行\n　　第二行改\n'.length);
      expect(map.rawForProcessed(0), 0);
      expect(map.rawForProcessed('　　第一行\n'.length), 4);
      expect(map.rawForProcessed('　　第一行\n　　第二行改\n'.length), 8);
    });

    test('规则插入一行：插入行解析到最近同步点', () {
      const raw = '第一行\n第二行\n第三行';
      const processed = '　　第一行\n　　插入行\n　　第二行\n　　第三行';
      final map = buildOffsetMap(
        rawText: raw,
        rawBase: 0,
        processedText: processed,
      );

      expect(map.processedForRaw(0), 0);
      expect(map.processedForRaw(4), '　　第一行\n　　插入行\n'.length);
      expect(
        map.rawForProcessed('　　第一行\n'.length),
        0,
        reason: '插入行没有对应的 raw 行，落在前一个同步点',
      );
      expect(map.rawForProcessed('　　第一行\n　　插入行\n'.length), 4);
    });

    test('规则删掉一行：被删的 raw 行解析到最近同步点', () {
      const raw = '第一行\n第二行\n第三行';
      const processed = '　　第一行\n　　第三行';
      final map = buildOffsetMap(
        rawText: raw,
        rawBase: 0,
        processedText: processed,
      );

      // The dropped line has no processed counterpart, so it carries the
      // previous sync point; the line after it keeps its own.
      expect(map.processedForRaw(4), 0);
      expect(map.processedForRaw(8), '　　第一行\n'.length);
      expect(map.rawForProcessed('　　第一行\n'.length), 8);
    });
  });
}

/// One book under test, assembled once per test.
class OpenProcessedBook {
  const OpenProcessedBook({
    required this.store,
    required this.library,
    required this.book,
    required this.engine,
    required this.reader,
    required this.text,
  });

  final SpaceStore store;
  final LocalLibrary library;
  final LocalBook book;
  final FakeEngine engine;
  final LocalReader reader;
  final String text;
}
