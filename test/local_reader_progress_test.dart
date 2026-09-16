import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/space_store.dart';

import 'local_reader_support.dart';

/// The reader's open path over the store: the five-field record it writes and
/// reads back, the restore it does when the file behind a book changed, the
/// relink flag that change feeds, and the window bound that keeps a whole
/// document away from the engine.
void main() {
  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-reader-');
    file = File('${root.path}${Platform.pathSeparator}book.txt');
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Only the fixture is on disk; the space's database is in memory.
    }
  });

  /// One book under test: the space it was admitted to, the engine that serves
  /// its file, and the reader over both.
  Future<OpenBook> openReader({
    String? text,
    int pageCodeUnits = 256,
    ReaderScript? script,
  }) async {
    final content = text ?? novelText(chapters: 8);
    await file.writeAsString(content);
    final space = await admittedBook(file);
    final engine = FakeEngine(
      content,
      chapters: chaptersOf(content),
      anchorStrideCodeUnits: 512,
    );
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
      pageCodeUnits: pageCodeUnits,
      script: script,
    );
    await reader.open();
    return OpenBook(
      space: space,
      engine: engine,
      reader: reader,
      text: content,
    );
  }

  test('打开一本书只交出一页，读到的就是那一页', () async {
    final opened = await openReader();
    final reader = opened.reader;

    expect(reader.error, isNull);
    expect(reader.notice, isNull, reason: '位置没有动，就没有要报告的东西');
    expect(reader.window!.text.length, 256);
    expect(reader.text, opened.text.substring(0, 256));
    expect(reader.position!.textOffset, 0);
    expect(reader.hasPrevious, isFalse);
    expect(reader.hasNext, isTrue);
  });

  test('翻页把整条五字段记录写回，重启后按锚点原地恢复', () async {
    final opened = await openReader();
    final reader = opened.reader;
    final first = reader.window!;

    await reader.next();

    final record = await opened.space.library.progressRecordOf(
      opened.space.book.id,
    );
    expect(record, isNotNull);
    expect(record!.textOffset, first.textOffset + first.text.length);
    expect(record.lineIndex, greaterThan(0));
    expect(record.offsetInLine, record.textOffset - record.lineStart);
    expect(record.textLength, opened.text.length);
    expect(record.anchor, isNotNull, reason: '锚点是行首那几十个码元');
    expect(record.chapterKey, isNotNull);
    expect(record.chapterIndex, isNotNull);
    expect(
      reader.window!.textOffset,
      record.lineStart,
      reason: '页面按行首显示，位置里仍然留着行内偏移',
    );
    expect(reader.position!.textOffset, record.textOffset);

    // A restart: the same store, a new session, the stored index reused.
    final reopened = LocalReader(
      engine: opened.engine,
      library: opened.space.library,
      book: opened.space.book,
      pageCodeUnits: 256,
    );
    await reopened.open();

    expect(reopened.notice, isNull, reason: '文件没有变，恢复就是精确的那一档');
    expect(reopened.position!.textOffset, record.textOffset);
    expect(reopened.position!.textLength, record.textLength);
    expect(opened.engine.indexPasses, 1, reason: '第二次打开不再重新索引');

    await reopened.previous();
    expect(reopened.position!.textOffset, lessThan(record.textOffset));
    expect(reopened.position!.lineStart, 0, reason: '退回到文件开头');
  });

  test('文件被改过：位置按锚点重新定位，并写下 relink', () async {
    final opened = await openReader();
    await opened.reader.next();
    final stored = (await opened.space.library.progressRecordOf(
      opened.space.book.id,
    ))!;

    // Forty lines appear before the position, so its line number moves with it.
    final edited = '新插入的一行\n' * 40 + opened.text;
    opened.engine.text = edited;
    await file.writeAsString(edited);

    final reopened = LocalReader(
      engine: opened.engine,
      library: opened.space.library,
      book: opened.space.book,
      pageCodeUnits: 256,
    );
    await reopened.open();

    final position = reopened.position!;
    expect(reopened.notice, contains('已改动'));
    expect(position.textLength, edited.length);
    expect(
      edited.substring(position.lineStart).startsWith(stored.anchor!),
      isTrue,
      reason: '恢复到的行就是锚点说的那一行',
    );
    expect(position.textOffset, greaterThan(stored.textOffset));
    expect(position.chapterKey, isNotNull, reason: '章节事实跟着新文件更新');

    expect(
      (await opened.space.store.bookById(opened.space.book.id))!.needsRelink,
      isTrue,
    );
    expect(
      (await fileRow(opened.space.store, opened.space.book)).needsRelink,
      isTrue,
    );
  });

  test('文件被替换：位置按行号恢复，读者看得到报告', () async {
    final opened = await openReader();
    await opened.reader.next();
    await opened.reader.next();

    final replaced = List.generate(400, (line) => '完全不同的第 $line 行').join('\n');
    opened.engine.text = replaced;
    await file.writeAsString(replaced);

    final reopened = LocalReader(
      engine: opened.engine,
      library: opened.space.library,
      book: opened.space.book,
      pageCodeUnits: 256,
    );
    await reopened.open();

    expect(reopened.notice, contains('已替换'));
    expect(reopened.error, isNull);
    expect(reopened.position!.lineStart, lessThan(replaced.length));
    expect(reopened.text, isNotEmpty);
    expect(
      (await opened.space.store.bookById(opened.space.book.id))!.needsRelink,
      isTrue,
    );
  });

  test('文件不见了：标记 relink 并说清楚', () async {
    final opened = await openReader();

    await file.delete();
    final reopened = LocalReader(
      engine: opened.engine,
      library: opened.space.library,
      book: opened.space.book,
      pageCodeUnits: 256,
    );
    await reopened.open();

    expect(reopened.error, contains('文件不存在'));
    expect(reopened.window, isNull);
    expect(
      (await opened.space.store.bookById(opened.space.book.id))!.needsRelink,
      isTrue,
    );
    expect(
      (await fileRow(opened.space.store, opened.space.book)).needsRelink,
      isTrue,
    );
  });

  test('引擎拿到的永远是一页，不是整份文件', () async {
    final opened = await openReader(
      text: novelText(chapters: 40),
      pageCodeUnits: 256,
    );
    await opened.reader.next();
    await opened.reader.next();

    expect(
      opened.engine.largestRead,
      lessThanOrEqualTo(256),
      reason: '文件不变时，恢复的校验读也不过一页',
    );
    expect(
      opened.engine.largestRead * 8,
      lessThan(opened.text.length),
      reason: '一次读走的远小于整份文件',
    );
    expect(opened.reader.window!.text.length, lessThanOrEqualTo(256));
  });

  test('要什么文字就渲染什么文字，位置仍然是码元偏移', () async {
    final opened = await openReader(
      pageCodeUnits: 256,
      script: ReaderScript.simplified,
    );

    expect(opened.reader.text, startsWith('«simplified»'));
    expect(
      opened.reader.position!.textOffset,
      0,
      reason: '转换只改显示，偏移量不受它和窗口大小影响',
    );

    final first = opened.reader.window!;
    await opened.reader.next();
    expect(
      opened.reader.position!.textOffset,
      first.textOffset + first.text.length,
      reason: '翻页按原始码元走，不按转换后的文字',
    );
    expect(opened.reader.text, startsWith('«simplified»'));
  });

  test('章节键是这一章自己在文件里的起点', () async {
    final text = novelText(chapters: 8);
    final opened = await openReader(text: text);
    final chapters = chaptersOf(text);

    await opened.reader.next();
    final record = (await opened.space.library.progressRecordOf(
      opened.space.book.id,
    ))!;
    final containing = chapters.lastWhere(
      (chapter) => chapter.codeUnitOffset <= record.textOffset,
    );
    expect(record.chapterKey, '${containing.codeUnitOffset}');
    expect(record.chapterIndex, chapters.indexOf(containing));
  });

  test('没有读过的书从第一行开始，记录由保存或翻页写下', () async {
    final opened = await openReader();
    expect(
      await opened.space.library.progressRecordOf(opened.space.book.id),
      isNull,
      reason: '只是打开一本书不写进度',
    );

    await opened.reader.save();
    final record = await opened.space.library.progressRecordOf(
      opened.space.book.id,
    );
    expect(record, isNotNull);
    expect(record!.textOffset, 0);
    expect(record.anchor, isNotNull);
    expect(record.textLength, opened.text.length);
  });
}

/// One book under test, assembled once per test.
class OpenBook {
  const OpenBook({
    required this.space,
    required this.engine,
    required this.reader,
    required this.text,
  });

  final ({SpaceStore store, LocalLibrary library, LocalBook book}) space;
  final FakeEngine engine;
  final LocalReader reader;
  final String text;
}
