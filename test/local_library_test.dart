import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

/// The local library over the space: roots in `local_roots`, files in
/// `local_files`, admitted books in `books` of kind `local`, positions in
/// `progress`. Walking folders stays the file system's job.
void main() {
  late TestSpace space;
  late SpaceStore store;
  late LocalLibrary library;
  late Directory root;

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    library = LocalLibrary(store);
    root = await Directory(
      '${space.directory.path}${Platform.pathSeparator}library',
    ).create();
    await File(
      '${root.path}${Platform.pathSeparator}book.txt',
    ).writeAsString('text');
    await File(
      '${root.path}${Platform.pathSeparator}cover.jpg',
    ).writeAsBytes(<int>[1]);
    final nested = await Directory(
      '${root.path}${Platform.pathSeparator}nested',
    ).create();
    await File(
      '${nested.path}${Platform.pathSeparator}chapter.md',
    ).writeAsString('# chapter');
  });

  tearDown(() => space.delete());

  /// A restart: the same database file, a new library.
  Future<LocalLibrary> restart() async {
    store = await space.reopen();
    library = LocalLibrary(store);
    await library.load();
    return library;
  }

  /// The relative path as the platform spells it: a path inside a root keeps
  /// the separator the file system gave it.
  String relative(String value) =>
      value.replaceAll('/', Platform.pathSeparator);

  test('本地库只收 TXT/Markdown，显式加入后重启仍在', () async {
    final selected = await library.selectRoot(root.path);
    expect(selected.needsRelink, isFalse);
    final entries = await library.scanRecursively();
    expect(entries, hasLength(2), reason: 'jpg 不进本地库');

    final books = await library.addFiles(entries);
    expect(
      books.map((book) => book.title),
      containsAll(<String>['book.txt', 'chapter.md']),
    );
    expect(books.every((book) => book.textOffset == 0), isTrue);
    expect(await library.addFiles(entries), isEmpty, reason: '自然键相同就不再加入');

    final files = await store.localFilesOf(selected.id);
    expect(
      files.map((file) => file.relativePath),
      containsAll(<String>['book.txt', relative('nested/chapter.md')]),
    );
    expect(files.every((file) => file.bookId != null), isTrue);

    final reopened = await restart();
    expect(reopened.root!.id, selected.id, reason: '重启后还是那个根目录');
    expect(reopened.root!.needsRelink, isFalse);
    expect(
      reopened.books.map((book) => book.title),
      containsAll(<String>['book.txt', 'chapter.md']),
    );
    expect(
      reopened.books.every((book) => File(book.path).existsSync()),
      isTrue,
      reason: '路径由根目录与相对路径解析出来',
    );
  });

  test('根目录不见了就标记 relink，重新选择后恢复，重启后仍然有效', () async {
    final selected = await library.selectRoot(root.path);
    await library.addFiles(await library.scanRecursively());
    final bookId = library.books
        .singleWhere((book) => book.title == 'book.txt')
        .id;

    // The volume goes away; only the file that comes back is usable again.
    await root.rename('${root.path}-away');
    await restart();
    expect(library.root!.needsRelink, isTrue, reason: '目录不在的事实写进存储');

    await Directory(root.path).create(recursive: true);
    await File(
      '${root.path}${Platform.pathSeparator}book.txt',
    ).writeAsString('回来了');
    await library.selectRoot(root.path);
    expect(library.root!.needsRelink, isFalse);
    final files = await store.localFilesOf(selected.id);
    expect(
      files.singleWhere((file) => file.relativePath == 'book.txt').needsRelink,
      isFalse,
    );
    expect(
      files
          .singleWhere(
            (file) => file.relativePath == relative('nested/chapter.md'),
          )
          .needsRelink,
      isTrue,
      reason: '没有回来的文件仍然需要重新关联',
    );
    expect((await store.bookById(bookId))!.needsRelink, isFalse);

    await restart();
    expect(library.root!.needsRelink, isFalse, reason: 'relink 的结果在重启后仍在');
    expect(
      (await store.localFilesOf(
        selected.id,
      )).singleWhere((file) => file.relativePath == 'book.txt').needsRelink,
      isFalse,
    );
  });

  test('本地书的阅读位置写进 progress，重启后读到', () async {
    await library.selectRoot(root.path);
    await library.addFiles(await library.scanRecursively());
    final book = library.books.singleWhere((item) => item.title == 'book.txt');

    await library.updateOffset(book.id, 120);
    expect((await store.progressOf(book.id))!.textOffset, 120);

    final reopened = await restart();
    expect(
      reopened.books.singleWhere((item) => item.id == book.id).textOffset,
      120,
    );
    // The reader's last write wins: going back in the file is a position too.
    await reopened.updateOffset(book.id, 40);
    expect((await store.progressOf(book.id))!.textOffset, 40);
    expect(
      reopened.books.singleWhere((item) => item.id == book.id).textOffset,
      40,
    );
  });
}
