import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/local/reader_restore.dart';
import 'package:liber/store/progress.dart';

import 'local_reader_support.dart';

/// D4's tiered restore and the bounded line lookups it is built on. Everything
/// here is logic over a fake engine's index, so these rows run without a file and
/// without the native library.
void main() {
  /// The store-side half of an open index, over one fake file.
  ({ReaderLines lines, FakeEngine engine}) linesOf(String text) {
    final engine = FakeEngine(text, anchorStrideCodeUnits: 512);
    return (
      lines: ReaderLines(
        engine: engine,
        path: 'book.txt',
        index: ReaderIndex(
          encoding: engine.encoding,
          codeUnitLength: text.length,
          anchors: anchorsOf(text, strideCodeUnits: 512),
        ),
      ),
      engine: engine,
    );
  }

  /// The offset of the line [lineIndex] lines after [from], for building a file
  /// that moved a position.
  int offsetAfterLines(String text, int from, int lineCount) {
    var offset = from;
    var seen = 0;
    while (offset < text.length && seen < lineCount) {
      if (text.codeUnitAt(offset) == 0x0a) seen += 1;
      offset += 1;
    }
    return offset;
  }

  test('窗口里的每一行都给出起点、行号与文字', () {
    const text = 'one\ntwo\nthree';
    final rows = windowLines(
      const ReaderWindow(
        text: text,
        textOffset: 100,
        lineIndex: 7,
        atEnd: true,
      ),
    ).toList();

    expect(rows.map((row) => row.start), [100, 104, 108]);
    expect(rows.map((row) => row.lineIndex), [7, 8, 9]);
    expect(rows.map((row) => row.text), ['one', 'two', 'three']);
  });

  test('窗口从行中间开始时，第一行只算它窗口里的那截', () {
    final rows = windowLines(
      const ReaderWindow(
        text: 'wo\nthree',
        textOffset: 201,
        lineIndex: 3,
        atEnd: true,
      ),
    ).toList();

    expect(rows.first.text, 'wo', reason: '锚点比对不会把半行当成整行');
    expect(rows.last.start, 204);
  });

  test('锚点是行首的 32 个码元，空行没有锚点', () {
    expect(anchorOf('第一章 起点\n正文'), '第一章 起点');
    expect(anchorOf('x' * 40), 'x' * 32);
    expect(anchorOf('\n正文'), isNull);
    expect(anchorOf(''), isNull);
  });

  test('章节按最后一个不晚于位置的边界取，键是它自己的起点', () {
    final chapters = [
      const ReaderChapter(title: '一', codeUnitOffset: 0, lineIndex: 0),
      const ReaderChapter(title: '二', codeUnitOffset: 100, lineIndex: 4),
      const ReaderChapter(title: '三', codeUnitOffset: 250, lineIndex: 9),
    ];

    expect(chapterAt(chapters, 0), (key: '0', index: 0));
    expect(chapterAt(chapters, 100), (key: '100', index: 1));
    expect(chapterAt(chapters, 249), (key: '100', index: 1));
    expect(chapterAt(chapters, 900), (key: '250', index: 2));
    expect(chapterAt(const <ReaderChapter>[], 900), isNull);
  });

  test('恢复结果只有 exact 才是没有改动，其余都要报给读者', () {
    expect(restoreNotice(RestoreTier.exact), isNull);
    expect(restoreNotice(RestoreTier.relocated), contains('已改动'));
    expect(restoreNotice(RestoreTier.searched), contains('已改动'));
    expect(restoreNotice(RestoreTier.lineIndex), contains('已替换'));
    expect(restoreNotice(RestoreTier.percentage), contains('已替换'));
  });

  test('锚点查找给出不晚于位置的最近锚点，行号查找同理', () {
    final fixture = linesOf(novelText(chapters: 6));
    final anchors = fixture.lines.index.anchors;
    expect(anchors.length, greaterThanOrEqualTo(3));

    final third = anchors[2];
    expect(
      fixture.lines.anchorBefore(third.codeUnitOffset)!.codeUnitOffset,
      third.codeUnitOffset,
    );
    expect(
      fixture.lines.anchorBefore(third.codeUnitOffset + 1)!.codeUnitOffset,
      third.codeUnitOffset,
    );
    expect(fixture.lines.anchorBefore(0)!.codeUnitOffset, 0);
    expect(
      fixture.lines.anchorAtLine(third.lineIndex + 1)!.lineIndex,
      third.lineIndex,
    );
  });

  test('第一档：长度与锚点都还对上，位置不动', () async {
    final text = novelText();
    final fixture = linesOf(text);
    final target = text.indexOf('这是第3章的第2段。');
    final stored = recordAt(text, target);

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
    ).resolve();

    expect(restored.tier, RestoreTier.exact);
    expect(restored.changed, isFalse);
    expect(restored.textOffset, target);
  });

  test('第二档：锚点在 ±N 行内移动，就按行号把它找回来', () async {
    final stored = recordAt(novelText(), novelText().indexOf('这是第3章的第2段。'));
    // The file gained 30 lines before the position.
    final edited = '新插入的一行\n' * 30 + novelText();
    final fixture = linesOf(edited);

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
    ).resolve();

    expect(restored.tier, RestoreTier.relocated);
    expect(restored.changed, isTrue);
    expect(restored.textOffset, edited.indexOf('这是第3章的第2段。'));
  });

  test('第三档：锚点移出了 ±N 行，就用稀疏锚点扫一遍找它', () async {
    final stored = recordAt(novelText(), novelText().indexOf('这是第3章的第2段。'));
    // Far enough that only a search finds it, and not a close line number.
    final edited = '无关的内容\n' * 900 + novelText();
    final fixture = linesOf(edited);

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
      relocateLines: 20,
    ).resolve();

    expect(restored.tier, RestoreTier.searched);
    expect(restored.textOffset, edited.indexOf('这是第3章的第2段。'));
  });

  test('第四档：锚点已经不在文件里，就退回行号并报告', () async {
    final stored = recordAt(novelText(), novelText().indexOf('这是第3章的第2段。'));
    final replaced = List.generate(600, (line) => '完全不同的第 $line 行').join('\n');
    final fixture = linesOf(replaced);

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
    ).resolve();

    expect(restored.tier, RestoreTier.lineIndex);
    expect(restored.line.lineIndex, stored.lineIndex);
    expect(restoreNotice(restored.tier), contains('已替换'));
  });

  test('第四档：连行号都没有了，就按百分比恢复', () async {
    final stored = recordAt(novelText(chapters: 40), 9000);
    final replaced = '短文件\n只有两行\n';
    final fixture = linesOf(replaced);

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
    ).resolve();

    expect(restored.tier, RestoreTier.percentage);
    expect(
      restored.line.start,
      lessThanOrEqualTo(replaced.length),
      reason: '百分比落在文件里，不在它之外',
    );
  });

  test('没有长度也没有锚点的旧记录，保留它自己的偏移', () async {
    final text = novelText();
    final fixture = linesOf(text);
    // What the coarse offset writer used to leave behind: no facts to verify
    // the offset with, so the offset itself is the whole position.
    const stored = ProgressRecord(
      textOffset: 900,
      lineIndex: 0,
      offsetInLine: 0,
      textLength: 0,
    );

    final restored = await PositionRestore(
      lines: fixture.lines,
      stored: stored,
    ).resolve();

    expect(restored.tier, RestoreTier.exact);
    expect(restored.textOffset, 900);
  });

  test('行号查找走有界窗口，跨过量一页的窗口也对', () async {
    final text = novelText(chapters: 40);
    final fixture = linesOf(text);

    final offset = offsetAfterLines(text, 0, 200);
    final line = await fixture.lines.offsetOfLine(200);

    expect(line, isNotNull);
    expect(line!.start, offset);
    expect(await fixture.lines.offsetOfLine(100000), isNull);
    expect(fixture.engine.largestRead, lessThanOrEqualTo(4096));
  });
}
