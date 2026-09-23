import 'dart:io';

import 'package:fjs/fjs.dart' show ConvertTarget;
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
    ConvertTarget? script,
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
    final online = (await processing.content(body, chapterTitle: heading)).text;

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

  test('规则删掉位置所在的行：显示删除处之后的正文并报告', () async {
    const heading = '第1章 起点';
    const body = '甲行\n乙行\n丙行\n';
    final text = '$heading\n$body';
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    // A record written before the rules ran: the start of the line the rules
    // delete, with that line's own anchor.
    final offset = text.indexOf('乙行');
    await space.library.saveProgressRecord(
      space.book.id,
      recordAt(text, offset),
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing([(pattern: '乙行\n', replacement: '')]),
      pageCodeUnits: 4096,
    );
    await reader.open();

    expect(reader.error, isNull);
    expect(reader.notice, deletedPositionNotice, reason: '删掉的位置不静默跳走，读者把它报告出来');
    expect(reader.text.split('\n').first, '　　丙行', reason: '显示的是删除处之后的那一行');
    expect(
      reader.position!.textOffset,
      offset,
      reason: '记录仍是 raw 空间里被删的那一行，位置没有丢',
    );

    await reader.save();
    final stored = (await space.library.progressRecordOf(space.book.id))!;
    expect(stored.textLength, text.length, reason: '记录长度仍是整份文件');
  });

  test('规则删掉末尾：读者落在最后一行上，不显示空白', () async {
    const heading = '第1章 起点';
    const body = '甲行\n乙行\n';
    final text = '$heading\n$body';
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    final offset = text.indexOf('乙行');
    await space.library.saveProgressRecord(
      space.book.id,
      recordAt(text, offset),
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      processing: literalProcessing([(pattern: '乙行\n', replacement: '')]),
      pageCodeUnits: 4096,
    );
    await reader.open();

    expect(reader.error, isNull);
    expect(reader.notice, deletedPositionNotice);
    expect(reader.text, '　　甲行', reason: '删到末尾时落在最后一行上');
    expect(reader.position!.textOffset, text.indexOf('甲行'));
  });

  test('超过旧前瞻的改写：重复行上的位置仍落在自己那一行', () async {
    const heading = '第1章 起点';
    const repeated = '同样的正文行';
    // One distinct line, then hundreds of identical ones, so a map that hunts for
    // a matching line has nothing to tell them apart, and the rewritten first
    // line shifts every line after it.
    final body = [
      '抬头的独有行',
      for (var line = 0; line < 200; line++) repeated,
    ].join('\n');
    final text = '$heading\n$body\n';
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      text,
      chapters: chaptersOf(text),
      anchorStrideCodeUnits: 512,
    );
    final processing = literalProcessing([
      (pattern: '抬头的独有行', replacement: '抬头的独有行，加长了一段插入文字'),
    ]);
    final expectedLines = (await processing.content(
      body,
      chapterTitle: heading,
    )).text.split('\n');
    // The 151st line: a repeated one, far past the 64-line lookahead the old map
    // fell back at, and past the length the first line's rewrite added.
    const lineIndex = 150;
    final rawOffset =
        text.indexOf(repeated) + lineIndex * (repeated.length + 1);
    await space.library.saveProgressRecord(
      space.book.id,
      recordAt(text, rawOffset),
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
    expect(reader.notice, isNull, reason: '位置没有被改写，不需要报告');
    expect(
      reader.text.split('\n').first,
      expectedLines[lineIndex + 1],
      reason: '第 $lineIndex 行的位置仍落在同一行上',
    );
    expect(reader.position!.textOffset, rawOffset);
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

    final expected = (await processing.content(
      '甲行\n乙行\n丙行\n',
      chapterTitle: '第1章 起点',
    )).text;
    expect(opened.reader.text, expected);

    await opened.reader.next();
    expect(opened.reader.error, isNull);
    expect(opened.reader.text, isNotEmpty);
  });

  group('规则形状：每个 raw 偏移都映射到入口产出的精确 processed 偏移', () {
    // The shapes #47's heuristic got wrong: a rewrite in place, an insertion and
    // a deletion inside a line, a line the rules remove, a rule that adds a line,
    // duplicated lines, and a rewritten run far longer than the old 64-line
    // lookahead. Every fixture declares the *image of every raw line*, so the map
    // is checked against the shape that was asked for, not against its own
    // answer.
    final longBlock = List.generate(70, (line) => '第${line + 10}行正文');
    final corpus = <_RuleShape>[
      _RuleShape(
        name: '就地改写：逐位置精确',
        raw: '甲行\n乙行\n丙行\n',
        rules: [(pattern: '乙行', replacement: '丁行')],
        images: ['甲行', '丁行', '丙行'],
      ),
      _RuleShape(
        name: '行内插入',
        raw: '甲行\n乙行\n丙行\n',
        rules: [(pattern: '乙行', replacement: '乙行ABC')],
        images: ['甲行', '乙行ABC', '丙行'],
      ),
      _RuleShape(
        name: '行首删除',
        raw: '甲行\n广告乙行\n丙行\n',
        rules: [(pattern: '广告', replacement: '')],
        images: ['甲行', '乙行', '丙行'],
      ),
      _RuleShape(
        name: '行中插入',
        raw: '甲行\n乙丙行\n丁行\n',
        rules: [(pattern: '丙', replacement: '丙X')],
        images: ['甲行', '乙丙X行', '丁行'],
      ),
      _RuleShape(
        name: '整行连同换行被删：带位置的行',
        raw: '甲行\n乙行\n丙行\n丁行\n',
        rules: [(pattern: '乙行\n', replacement: '')],
        images: ['甲行', null, '丙行', '丁行'],
      ),
      _RuleShape(
        name: '整行内容被删：空行被形变丢掉',
        raw: '甲行\n乙行\n丙行\n',
        rules: [(pattern: '乙行', replacement: '')],
        images: ['甲行', null, '丙行'],
      ),
      _RuleShape(
        name: '规则插入一行',
        raw: '甲行\n乙行\n丙行\n',
        rules: [(pattern: '乙行', replacement: '乙行\n插入行')],
        images: ['甲行', '乙行\n插入行', '丙行'],
      ),
      _RuleShape(
        name: '重复行也逐行对应',
        raw: '甲行\n重复行\n重复行\n乙行\n',
        rules: [(pattern: '重复行', replacement: '改动行')],
        images: ['甲行', '改动行', '改动行', '乙行'],
      ),
      _RuleShape(
        name: '超过旧前瞻的连续改写',
        raw: '${List.generate(100, (line) => '第${line + 1}行正文').join('\n')}\n',
        rules: [(pattern: '正文', replacement: '文字')],
        images: List.generate(100, (line) => '第${line + 1}行文字'),
      ),
      _RuleShape(
        name: '超过旧前瞻的连续删除',
        raw: '开头\n${longBlock.join('\n')}\n结尾\n',
        rules: [(pattern: longBlock.join('\n'), replacement: '')],
        images: ['开头', ...List<String?>.filled(70, null), '结尾'],
      ),
    ];

    for (final shape in corpus) {
      test(shape.name, () async {
        final processing = literalProcessing(shape.rules);
        final script = await processing.content(
          shape.raw,
          chapterTitle: '第1章 起点',
        );
        expect(script.text, shape.processed, reason: '入口的产出与声明的形一致');

        final map = ReaderOffsetMap.fromEdits(script.edits, rawBase: 0);
        var previous = 0;
        // Every offset a stored position can name: the content of every raw
        // line. The separators and the trimmed whitespace between them are the
        // paragraph shape's business (covered by #17's own tests), and the
        // reader only ever stores a line start.
        for (var offset = 0; offset < shape.raw.length; offset++) {
          if (!shape.isLineContent(offset)) continue;
          final expected = shape.expectationFor(offset);
          if (expected != null) {
            expect(map.imageOf(offset), expected, reason: 'raw $offset 的精确像');
            expect(
              map.rawForProcessed(expected),
              offset,
              reason: 'processed $expected 反查回 raw $offset',
            );
          } else {
            expect(
              map.imageOf(offset),
              isNull,
              reason: 'raw $offset 被改写，没有自己的像',
            );
            expect(
              map.processedForRaw(offset),
              shape.boundaryFor(offset),
              reason: 'raw $offset 落在改写处的边界',
            );
          }
          expect(
            map.processedForRaw(offset),
            greaterThanOrEqualTo(previous),
            reason: '映射单调',
          );
          previous = map.processedForRaw(offset);
        }

        // The reverse direction. A processed line start is either the image of
        // the raw line whose content begins there, or a line the rules generated
        // inside a run — and the map answers with the run that put it there.
        // Either way the two directions agree at that offset.
        for (final lineStart in shape.processedLineStarts) {
          final raw = map.rawForProcessed(lineStart);
          final first = shape.firstSurvivingContent(lineStart);
          expect(
            raw == first || shape.isInsideRun(raw),
            isTrue,
            reason: 'processed 行首 $lineStart 反查到该行第一个存活偏移或改写处',
          );
          if (raw == first) {
            expect(
              map.processedForRaw(raw),
              greaterThan(lineStart),
              reason: '该行第一个存活偏移 $raw 的正文紧随行首之后',
            );
          }
        }
      });
    }
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

/// One corpus fixture of the rule shapes: the unit body, the literal rules, and
/// the **image of every raw line** — the line's content as the one entry leaves
/// it, or null when the line's content is gone from the processed text. A
/// content carrying a `\n` is a line the rules split into several.
///
/// The fixture works out what the map has to answer from itself, never from the
/// map: the raw ranges the run rewrote (the rules' literal occurrences, the
/// whitespace the line trim cuts, the separators the paragraph shape drops),
/// where each surviving offset lands, and where a rewritten range's replacement
/// begins. Its patterns must sit inside a line with no leading whitespace, so an
/// occurrence in the body is the range the rule rewrote.
class _RuleShape {
  _RuleShape({
    required this.name,
    required this.raw,
    required this.rules,
    required this.images,
  }) {
    final lines = raw.split('\n');
    var cursor = 0;
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      lineStarts.add(cursor);
      final trimmed = line.trim();
      final coreStart = cursor + (trimmed.isEmpty ? 0 : line.indexOf(trimmed));
      coreStarts.add(coreStart);
      coreEnds.add(coreStart + trimmed.length);
      lineEnds.add(cursor + line.length);
      if (trimmed.isEmpty) {
        // The shape drops the empty paragraph with its whole line.
        layoutRuns.add((start: cursor, end: cursor + line.length));
      } else {
        if (coreStart > cursor) layoutRuns.add((start: cursor, end: coreStart));
        if (coreStart + trimmed.length < cursor + line.length) {
          layoutRuns.add((
            start: coreStart + trimmed.length,
            end: cursor + line.length,
          ));
        }
      }
      cursor += line.length + 1;
    }
    for (final rule in rules) {
      var from = 0;
      while (true) {
        final at = raw.indexOf(rule.pattern, from);
        if (at < 0) break;
        ruleRuns.add((
          start: at,
          end: at + rule.pattern.length,
          replacement: rule.replacement,
        ));
        from = at + rule.pattern.length;
      }
    }
    ruleRuns.sort((a, b) => a.start.compareTo(b.start));

    // The separators the shape keeps: before every processed paragraph but the
    // first, the last newline that stands before it and that no rule rewrote.
    // Every other newline is cut.
    final rendered = <int>{};
    for (var index = 0; index < images.length; index++) {
      if (index == 0 || images[index] == null) continue;
      if (images.take(index).every((image) => image == null)) continue;
      for (var before = index - 1; before >= 0; before--) {
        final newline = lineEnds[before];
        if (ruleRuns.any((run) => newline >= run.start && newline < run.end)) {
          continue;
        }
        rendered.add(newline);
        break;
      }
    }
    for (var index = 0; index + 1 < lines.length; index++) {
      final newline = lineEnds[index];
      if (rendered.contains(newline)) continue;
      if (ruleRuns.any((run) => newline >= run.start && newline < run.end)) {
        continue;
      }
      layoutRuns.add((start: newline, end: newline + 1));
    }

    final parts = <String>[];
    for (var index = 0; index < images.length; index++) {
      final image = images[index];
      if (image == null) {
        imageStarts.add(null);
        continue;
      }
      imageStarts.add(parts.isEmpty ? 0 : parts.join('\n').length + 1);
      parts.add(image.split('\n').map((line) => '　　$line').join('\n'));
    }
    processed = parts.join('\n');

    var at = 0;
    while (at <= processed.length) {
      processedLineStarts.add(at);
      final next = processed.indexOf('\n', at);
      if (next < 0) break;
      at = next + 1;
    }
  }

  final String name;
  final String raw;
  final List<({String pattern, String replacement})> rules;
  final List<String?> images;

  final List<int> lineStarts = [];
  final List<int> lineEnds = [];
  final List<int> coreStarts = [];
  final List<int> coreEnds = [];
  final List<({int start, int end, String replacement})> ruleRuns = [];

  /// The rule runs that changed the length of what they rewrote: only those
  /// ranges have offsets with no image of their own. A rule that rewrote a range
  /// in place (same length) leaves every offset of it where it was.
  Iterable<({int start, int end})> get writtenRuns => [
    for (final run in ruleRuns)
      if (run.replacement.length != run.end - run.start)
        (start: run.start, end: run.end),
  ];
  final List<({int start, int end})> layoutRuns = [];
  final List<int?> imageStarts = [];
  final List<int> processedLineStarts = [];
  late final String processed;

  Iterable<({int start, int end})> get runs => [...writtenRuns, ...layoutRuns];

  /// The indent the paragraph shape puts before every line.
  static const String _indent = '　　';

  bool survives(int offset) =>
      !runs.any((run) => offset >= run.start && offset < run.end);

  int _lineOf(int offset) {
    for (var index = lineStarts.length - 1; index >= 0; index--) {
      if (lineStarts[index] <= offset) return index;
    }
    return 0;
  }

  /// The processed offset a surviving offset's own text became.
  int image(int offset) {
    final index = _lineOf(offset);
    var shift = 0;
    for (final run in ruleRuns) {
      if (run.start >= coreStarts[index] && run.end <= offset) {
        shift += run.replacement.length - (run.end - run.start);
      }
    }
    return imageStarts[index]! + 2 + (offset - coreStarts[index]) + shift;
  }

  /// The processed offset this raw offset maps to, or null when a run rewrote
  /// the text it was in and it therefore has no image of its own.
  int? expectationFor(int offset) => survives(offset) ? image(offset) : null;

  /// The boundary the map's deleted-offset policy answers with for an offset a
  /// run rewrote: the offset where that run's replacement begins, which is the
  /// position right after the last text that survived before it.
  /// Whether [offset] is inside a raw line's trimmed content: the offsets a
  /// stored position can name.
  bool isLineContent(int offset) {
    final index = _lineOf(offset);
    return offset >= coreStarts[index] && offset < coreEnds[index];
  }

  bool isInsideRun(int offset) =>
      runs.any((run) => offset >= run.start && offset < run.end);

  /// The first surviving content offset of the line whose processed block starts
  /// at [lineStart], or null when no line's block starts there.
  int? firstSurvivingContent(int lineStart) {
    for (var index = 0; index < images.length; index++) {
      if (imageStarts[index] != lineStart) continue;
      for (
        var offset = coreStarts[index];
        offset <= coreEnds[index];
        offset++
      ) {
        if (survives(offset)) return offset;
      }
      return null;
    }
    return null;
  }

  /// The processed offset the map's deleted-offset policy answers with for an
  /// offset a run rewrote: where that run's replacement begins. Adjacent ranges
  /// the entry reported separately — the rule's rewrite, the whitespace the trim
  /// cut, the separator the shape dropped — are one range to the map, so the
  /// answer is the start of that whole chain.
  int boundaryFor(int offset) {
    final run = runs.firstWhere(
      (candidate) => offset >= candidate.start && offset < candidate.end,
    );
    var start = run.start;
    var end = run.end;
    var changed = true;
    while (changed) {
      changed = false;
      for (final other in runs) {
        if (other.end == start) {
          start = other.start;
          changed = true;
        } else if (other.start == end) {
          end = other.end;
          changed = true;
        }
      }
    }
    final index = _lineOf(start);
    if (imageStarts[index] == null) return _nextBlockStart(index);
    if (start < coreStarts[index] || start >= coreEnds[index]) {
      return image(start);
    }
    return image(start) - (start == coreStarts[index] ? _indent.length : 0);
  }

  /// The block start of the first line after [index] whose content survived.
  int _nextBlockStart(int index) {
    for (var next = index + 1; next < images.length; next++) {
      if (imageStarts[next] != null) return imageStarts[next]!;
    }
    return 0;
  }
}
