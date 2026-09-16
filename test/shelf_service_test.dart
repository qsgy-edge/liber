import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

/// The shelf reads and writes one space's store: membership is `books.shelved`,
/// a book is its natural key, the TOC is `chapters` and the position is the
/// `progress` row. These are the behaviours the JSON store used to have, plus
/// the ones only rows can express.
void main() {
  late TestSpace space;
  late SpaceStore store;
  late ShelfService shelf;

  const sourceUrl = 'https://example.test';
  final source = <String, dynamic>{
    'bookSourceUrl': sourceUrl,
    'bookSourceName': 'Example',
    'unknownSourceField': {
      'nested': [1, 2],
    },
  };
  String bookUrl(String id) => '$sourceUrl/$id';
  HtmlBook book(String id, {String? title}) => HtmlBook(
    url: Uri.parse(bookUrl(id)),
    title: title ?? id,
    author: '作者',
    intro: '简介',
    cover: '$sourceUrl/$id/cover.png',
  );
  List<SourceChapter> chapters(String id) => [
    SourceChapter('第一章', Uri.parse('$sourceUrl/$id/1')),
    SourceChapter('第二章', Uri.parse('$sourceUrl/$id/2')),
  ];
  Future<ShelfEntry> entryOf(String id) async =>
      (await shelf.find(sourceUrl, bookUrl(id)))!;

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    shelf = ShelfService(store);
  });

  tearDown(() => space.delete());

  /// A restart: the same database file, a new service.
  Future<ShelfService> restart() async {
    store = await space.reopen();
    shelf = ShelfService(store);
    return shelf;
  }

  test('加入的书、目录与各自的位置来自存储，重启后仍在', () async {
    await shelf.add(source, book('A', title: '甲'), chapters('A'));
    await shelf.add(source, book('B', title: '乙'), chapters('B'));
    await shelf.saveProgress(
      (await entryOf('A')).id,
      chapterKey: '$sourceUrl/A/2',
      chapterIndex: 1,
      textOffset: 48,
    );
    await shelf.saveProgress(
      (await entryOf('B')).id,
      chapterKey: '$sourceUrl/B/2',
      chapterIndex: 1,
      textOffset: 92,
    );

    final reopened = await restart();
    final entries = await reopened.onlineShelf();
    expect(entries.map((entry) => entry.title), ['甲', '乙']);
    expect(entries.first.chapters.map((chapter) => chapter.name), [
      '第一章',
      '第二章',
    ]);
    expect(entries.first.chapterName, '第二章', reason: '章节名来自目录行');
    expect(entries.first.textOffset, 48);
    expect(entries.last.textOffset, 92);
    expect(entries.first.book.sourceRef, sourceUrl);
    expect(
      entries.first.sourceJson['unknownSourceField'],
      {
        'nested': [1, 2],
      },
      reason: '书源对象原样保留在 raw 里（D7）',
    );
    expect((await reopened.sources()).single.id, sourceUrl);
  });

  test('重复加入不新建书籍，刷新目录保留进度与书架位置', () async {
    await shelf.add(source, book('A', title: '甲'), chapters('A'));
    final before = await entryOf('A');
    await shelf.saveProgress(
      before.id,
      chapterKey: '$sourceUrl/A/2',
      chapterIndex: 1,
      textOffset: 77,
    );

    await shelf.add(source, book('A', title: '甲'), chapters('A'));
    expect(await store.shelf(), hasLength(1), reason: '自然键相同就是同一本书');

    await shelf.updateCatalog(sourceUrl, book('A', title: '甲改名'), [
      SourceChapter('新章', Uri.parse('$sourceUrl/A/new')),
    ]);
    final after = await entryOf('A');
    expect(after.id, before.id, reason: '身份不因目录刷新而改变');
    expect(after.title, '甲改名');
    expect(after.chapters.map((chapter) => chapter.name), ['新章']);
    expect(after.textOffset, 77, reason: '刷新目录不动进度');
    expect(after.book.bookOrder, before.book.bookOrder, reason: '刷新目录不动排序');
    expect(after.shelved, isTrue);
  });

  test('移出书架保留进度，重新加入恢复进度，重启后仍然移出', () async {
    await shelf.add(source, book('A'), chapters('A'));
    final entry = await entryOf('A');
    await shelf.remove(entry.id);
    expect(await shelf.onlineShelf(), isEmpty);
    expect(
      (await store.bookById(entry.id))!.shelved,
      isFalse,
      reason: '移出是 shelved=false，不是删行',
    );

    // A reader save that lands after the removal writes progress and nothing
    // else: the book stays off the shelf.
    await shelf.saveProgress(
      entry.id,
      chapterKey: '$sourceUrl/A/2',
      chapterIndex: 1,
      textOffset: 45,
    );

    final reopened = await restart();
    expect(await reopened.onlineShelf(), isEmpty, reason: '移出在重启后仍然有效');
    expect((await store.progressOf(entry.id))!.textOffset, 45);
    await reopened.add(source, book('A'));
    expect((await reopened.onlineShelf()).single.textOffset, 45);
  });

  test('阅读器的写入是覆盖，上一章也留得住', () async {
    await shelf.add(source, book('A'), chapters('A'));
    final id = (await entryOf('A')).id;
    await shelf.saveProgress(
      id,
      chapterKey: '$sourceUrl/A/1',
      chapterIndex: 0,
      textOffset: 100,
    );
    await shelf.saveProgress(
      id,
      chapterKey: '$sourceUrl/A/2',
      chapterIndex: 1,
      textOffset: 10,
    );
    expect((await store.progressOf(id))!.chapterIndex, 1);

    await shelf.saveProgress(
      id,
      chapterKey: '$sourceUrl/A/1',
      chapterIndex: 0,
      textOffset: 50,
    );
    final progress = (await store.progressOf(id))!;
    expect(progress.chapterIndex, 0, reason: '读者回到上一章就该从上一章恢复');
    expect(progress.textOffset, 50);
  });

  test('阅读器的写入不动 #20 的行内字段', () async {
    await shelf.add(source, book('A'), chapters('A'));
    final id = (await entryOf('A')).id;
    await store.putProgress(
      ProgressCompanion(
        bookId: Value(id),
        textOffset: const Value(20),
        lineIndex: const Value(3),
        offsetInLine: const Value(7),
        textLength: const Value(5000),
        anchor: const Value('第一章'),
        updatedAt: const Value(1000),
      ),
    );

    await shelf.saveProgress(
      id,
      chapterKey: '$sourceUrl/A/1',
      chapterIndex: 0,
      textOffset: 20,
    );
    final progress = (await store.progressOf(id))!;
    expect(progress.lineIndex, 3);
    expect(progress.offsetInLine, 7);
    expect(progress.textLength, 5000);
    expect(progress.anchor, '第一章');
    expect(progress.updatedAt, greaterThan(1000));
  });

  test('加入顺序就是书架顺序，重启后不变，新书排在最后', () async {
    for (final id in ['B', 'A', 'C']) {
      await shelf.add(source, book(id, title: id), chapters(id));
    }
    expect((await shelf.onlineShelf()).map((entry) => entry.title), [
      'B',
      'A',
      'C',
    ]);

    final reopened = await restart();
    expect((await reopened.onlineShelf()).map((entry) => entry.title), [
      'B',
      'A',
      'C',
    ]);
    await reopened.add(source, book('D', title: 'D'));
    expect((await reopened.onlineShelf()).map((entry) => entry.title), [
      'B',
      'A',
      'C',
      'D',
    ]);
  });

  test('继续上次阅读取最近写下的位置', () async {
    await shelf.add(source, book('A', title: '甲'), chapters('A'));
    await shelf.add(source, book('B', title: '乙'), chapters('B'));
    final a = (await entryOf('A')).id;
    final b = (await entryOf('B')).id;

    await shelf.saveProgress(
      a,
      chapterKey: '$sourceUrl/A/1',
      chapterIndex: 0,
      textOffset: 10,
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await shelf.saveProgress(
      b,
      chapterKey: '$sourceUrl/B/1',
      chapterIndex: 0,
      textOffset: 10,
    );
    expect((await shelf.lastRead())!.title, '乙');

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await shelf.saveProgress(
      a,
      chapterKey: '$sourceUrl/A/2',
      chapterIndex: 1,
      textOffset: 30,
    );
    expect((await shelf.lastRead())!.title, '甲');
  });

  test('读过但没有加入书架的书不进书架，位置仍然记下', () async {
    final id = await shelf.ensureBook(source, book('A'));
    await shelf.saveProgress(
      id,
      chapterKey: '$sourceUrl/A/1',
      chapterIndex: 0,
      textOffset: 12,
    );
    expect(await shelf.onlineShelf(), isEmpty);
    expect((await store.bookById(id))!.shelved, isFalse);
    expect((await shelf.lastRead())!.id, id, reason: '“继续上次阅读”仍然找得到它');
  });

  test('迁移留下的没有书源的书只出现在已迁移书籍里', () async {
    await store.putBook(BooksCompanion.insert(id: 'legacy-x', title: '迁移书'));
    await store.putBook(
      BooksCompanion.insert(
        id: 'local-x',
        kind: const Value('local'),
        title: '本地书',
        rootId: const Value(r'c:\library'),
        relativePath: const Value('book.txt'),
      ),
    );
    await shelf.add(source, book('A', title: '甲'), chapters('A'));

    expect(
      (await shelf.migratedBooks()).map((entry) => entry.title),
      ['迁移书'],
      reason: '本地库的书有自己的列表，不是迁移留下的孤儿',
    );
    expect((await shelf.onlineShelf()).map((entry) => entry.title), ['甲']);
    expect(await shelf.find(sourceUrl, bookUrl('A')), isNotNull);
    expect(await shelf.find(sourceUrl, bookUrl('没有的书')), isNull);
  });

  test('加入书架不覆盖空间里已有的书源', () async {
    await store.putSourceJson({
      'bookSourceUrl': sourceUrl,
      'bookSourceName': 'Example',
      'enabled': false,
      'customOrder': 7,
      'bookSourceGroup': '精选',
    });

    // A source object that arrived from a file carries no `enabled`, and the
    // shelf's job is the book, not the source row.
    await shelf.add(
      {'bookSourceUrl': sourceUrl, 'bookSourceName': 'Example'},
      book('A'),
      chapters('A'),
    );
    final stored = (await store.sourceByUrl(sourceUrl))!;
    expect(stored.enabled, isFalse, reason: '用户停用的书源不被重新启用');
    expect(stored.customOrder, 7);
    expect(stored.groupNames, '["精选"]');
    expect((await entryOf('A')).sourceJson['bookSourceName'], 'Example');
  });
}
