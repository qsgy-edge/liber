import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/source/native_library.dart';

import 'local_reader_support.dart';
import 'native_library.dart';

/// The reader against the real engine, which is the path the app takes: a
/// generated Chinese TXT on disk, indexed once through the bridge, opened as
/// bounded windows, and opened again from the stored position without a second
/// pass.
///
/// A plain (non-widget) test, because only this binding lets
/// `flutter_rust_bridge`'s work settle.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));

  late Directory root;
  late File file;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-reader-native-');
    file = File('${root.path}${Platform.pathSeparator}book.txt');
  });

  tearDown(() async {
    await root.delete(recursive: true);
  });

  test('真引擎：一本书只按窗口读，位置与锚点写回后又按原样恢复', () async {
    final text = novelText(chapters: 400, paragraphs: 9, repeats: 8);
    await file.writeAsString(text);
    final space = await admittedBook(file);
    final engine = RecordingEngine(const NativeReaderEngine());
    final reader = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
    );

    await reader.open();

    expect(reader.error, isNull);
    expect(reader.notice, isNull);
    expect(reader.text, text.substring(0, reader.pageCodeUnits));
    expect(
      engine.largestRead,
      lessThanOrEqualTo(reader.pageCodeUnits),
      reason: '每一读都是一页',
    );
    expect(
      engine.largestRead * 8,
      lessThan(text.length),
      reason: '引擎拿到的是文件的一小段，不是整份文件',
    );
    expect(engine.indexPasses, 1);

    // A first page, then a page further in: the record the reader writes carries
    // every field of D4's five-field shape.
    await reader.next();
    final record = await space.library.progressRecordOf(space.book.id);
    expect(record, isNotNull);
    expect(record!.textOffset, greaterThan(0));
    expect(record.textLength, text.length);
    expect(record.offsetInLine, record.textOffset - record.lineStart);
    expect(record.anchor, isNotNull);
    expect(record.chapterKey, isNotNull, reason: '第N章 起点 是默认的目录规则');
    expect(record.chapterIndex, isNotNull);
    expect(reader.window!.textOffset, record.lineStart);

    // Reopening reads the stored index and the stored position: no new pass, and
    // the position is the one that was written.
    final reopened = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
    );
    await reopened.open();

    expect(reopened.notice, isNull);
    expect(reopened.position!.textOffset, record.textOffset);
    expect(reopened.text, reader.text);
    expect(engine.indexPasses, 1, reason: '存下来的锚点就够第二次打开');

    // The file changes: the reader relocates the position instead of jumping,
    // and says so.
    final edited = '新插入的一行\n' * 40 + text;
    await file.writeAsString(edited);
    final afterEdit = LocalReader(
      engine: engine,
      library: space.library,
      book: space.book,
    );
    await afterEdit.open();

    expect(afterEdit.notice, contains('已改动'));
    expect(afterEdit.position!.textLength, edited.length);
    expect(afterEdit.hasPrevious, isTrue);
    expect((await space.store.bookById(space.book.id))!.needsRelink, isTrue);
  });
}
