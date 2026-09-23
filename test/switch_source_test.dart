import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

/// Switch-source over one space's store (#40): a book moves onto another
/// source's copy of the same book, the reading position lands on the new table
/// of contents, and the row the reader already had stays the row it was.
///
/// The mapping itself is pinned in `chapter_position_test.dart` against the
/// frozen `BookHelp.getDurChapter`; what these tests pin is the store step
/// around it.
void main() {
  late TestSpace space;
  late SpaceStore store;
  late ShelfService shelf;

  final sourceA = <String, dynamic>{
    'bookSourceUrl': 'https://a.test',
    'bookSourceName': '甲源',
  };
  final sourceB = <String, dynamic>{
    'bookSourceUrl': 'https://b.test',
    'bookSourceName': '乙源',
  };

  String bookUrl(String sourceRef) => '$sourceRef/book';
  HtmlBook book(String sourceRef, {String title = '凡人修仙传'}) => HtmlBook(
    url: Uri.parse(bookUrl(sourceRef)),
    title: title,
    author: '忘语',
    intro: '简介',
    cover: '$sourceRef/cover.png',
  );
  List<SourceChapter> chapters(String sourceRef, List<String> names) => [
    for (var i = 0; i < names.length; i++)
      SourceChapter(names[i], Uri.parse('$sourceRef/chapter/$i')),
  ];

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    shelf = ShelfService(store);
  });

  tearDown(() => space.delete());

  Future<ShelfEntry> addBookOnA({List<String>? names}) async {
    await shelf.add(
      sourceA,
      book('https://a.test'),
      chapters(
        'https://a.test',
        names ?? const ['第一章', '第二章', '第三章', '第四章', '第五章'],
      ),
    );
    return (await shelf.find('https://a.test', bookUrl('https://a.test')))!;
  }

  test('换源后书的 id、书架位置与分组都留在同一行，目录和进度换成新书源的', () async {
    final before = await addBookOnA();
    final group = await store.ensureGroup('在追');
    await store.setBookGroups(before.id, [group.id]);
    await store.putSetting('convert', 't2s', bookId: before.id);
    await shelf.saveProgress(
      before.id,
      chapterKey: 'https://a.test/chapter/2',
      chapterIndex: 2,
      textOffset: 42,
    );
    final progressBefore = (await store.progressOf(before.id))!;

    final switched = await shelf.switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      chapters('https://b.test', const [
        '楔子',
        '第一章',
        '第二章',
        '第三章',
        '第四章',
        '第五章',
      ]),
    );

    expect(switched.id, before.id, reason: 'D2：换源不重写书的身份');
    expect(switched.sourceRef, 'https://b.test');
    expect(switched.book.sourceBookUrl, bookUrl('https://b.test'));
    expect(switched.title, '凡人修仙传');
    expect(switched.chapters.map((chapter) => chapter.name), [
      '楔子',
      '第一章',
      '第二章',
      '第三章',
      '第四章',
      '第五章',
    ]);
    expect(switched.chapterIndex, 3, reason: '第三章在新目录的下标 3');
    expect(switched.chapterName, '第三章');
    expect(switched.textOffset, 42, reason: '偏移原样带过去（冻结的 durChapterPos）');
    expect(switched.book.bookOrder, before.book.bookOrder);
    expect(switched.shelved, isTrue);
    expect((await store.groupsOf(before.id)).map((row) => row.name), ['在追']);
    expect(await store.setting('convert', bookId: before.id), 't2s');
    final progressAfter = (await store.progressOf(before.id))!;
    expect(progressAfter.chapterKey, 'https://b.test/chapter/3');
    expect(
      progressAfter.updatedAt,
      progressBefore.updatedAt,
      reason: '冻结带走 durChapterTime，换源自己不写时间',
    );

    expect(
      await shelf.find('https://a.test', bookUrl('https://a.test')),
      isNull,
      reason: '旧书源的同一本书不再单独留一行',
    );
    expect((await shelf.onlineShelf()).length, 1);
    expect((await store.allSources()).map((row) => row.bookSourceUrl), [
      'https://a.test',
      'https://b.test',
    ]);
  });

  test('章节名变了、章节号还在时按章节号落位', () async {
    final before = await addBookOnA();
    await shelf.saveProgress(
      before.id,
      chapterKey: 'https://a.test/chapter/2',
      chapterIndex: 2,
      textOffset: 9,
    );

    // The words differ (`初入宗门` against `拜入山门`), so the number decides.
    final switched = await shelf.switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      chapters('https://b.test', const [
        '第一章 启程',
        '第二章 拜师',
        '第三章 拜入山门',
        '第四章 试炼',
      ]),
    );

    expect(switched.chapterIndex, 2);
    expect(switched.chapterName, '第三章 拜入山门');
    expect(switched.textOffset, 9);
  });

  test('章节目录换了位置的书也能找到原章节', () async {
    final before = await addBookOnA();
    await shelf.saveProgress(
      before.id,
      chapterKey: 'https://a.test/chapter/4',
      chapterIndex: 4,
      textOffset: 7,
    );

    final switched = await shelf.switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      // 第五章 first, so only the name can find it.
      chapters('https://b.test', const ['第五章', '第一章', '第二章', '第三章', '第四章']),
    );

    expect(switched.chapterIndex, 0);
    expect(switched.chapterKey, 'https://b.test/chapter/0');
  });

  test('没读过的书换源不写进度行', () async {
    final before = await addBookOnA();
    await shelf.switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      chapters('https://b.test', const ['第一章', '第二章']),
    );

    expect(await store.progressOf(before.id), isNull);
    expect((await shelf.onlineShelf()).single.chapterKey, '');
  });

  test('目标书源下已有同一本书时拒绝换源，两边都不动', () async {
    final onA = await addBookOnA();
    await shelf.add(
      sourceB,
      book('https://b.test', title: '凡人修仙传（乙）'),
      chapters('https://b.test', const ['第一章']),
    );
    await shelf.saveProgress(
      onA.id,
      chapterKey: 'https://a.test/chapter/1',
      chapterIndex: 1,
      textOffset: 5,
    );

    await expectLater(
      () => shelf.switchSource(
        onA.id,
        sourceB,
        book('https://b.test'),
        chapters('https://b.test', const ['第一章', '第二章']),
      ),
      throwsA(isA<StateError>()),
    );

    final stillOnA = (await store.bookById(onA.id))!;
    expect(stillOnA.sourceRef, 'https://a.test');
    expect((await store.chaptersOf(onA.id)).length, 5);
    expect((await store.progressOf(onA.id))!.textOffset, 5);
    expect((await shelf.onlineShelf()).length, 2);
  });

  test('换源写下的行在重启后仍然是一行', () async {
    final before = await addBookOnA();
    await shelf.saveProgress(
      before.id,
      chapterKey: 'https://a.test/chapter/3',
      chapterIndex: 3,
      textOffset: 88,
    );
    await shelf.switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      chapters('https://b.test', const ['第一章', '第二章', '第三章', '第四章']),
    );

    final reopened = await space.reopen();
    shelf = ShelfService(reopened);
    final entries = await shelf.onlineShelf();
    expect(entries.length, 1);
    expect(entries.single.id, before.id);
    expect(entries.single.sourceRef, 'https://b.test');
    expect(entries.single.chapterKey, 'https://b.test/chapter/3');
    expect(entries.single.textOffset, 88);
    expect((await reopened.sourceByUrl('https://b.test'))!.name, '乙源');
  });

  test('空间里没有的书源由换源写进来，已有的书源行不被覆盖', () async {
    await store.putSourceJson({
      'bookSourceUrl': 'https://b.test',
      'bookSourceName': '乙源',
      'enabled': false,
      'customOrder': 7,
    });
    final before = await addBookOnA();

    await shelf.switchSource(
      before.id,
      // The object the search handed over carries no `enabled`.
      {'bookSourceUrl': 'https://b.test', 'bookSourceName': '乙源'},
      book('https://b.test'),
      chapters('https://b.test', const ['第一章', '第二章']),
    );

    final stored = (await store.sourceByUrl('https://b.test'))!;
    expect(stored.enabled, isFalse, reason: '用户停用的书源不被重新启用');
    expect(stored.customOrder, 7);
    expect((await store.bookById(before.id))!.originName, '乙源');
  });

  test('本地书不能换源', () async {
    await store.putBook(
      BooksCompanion.insert(
        id: 'local-x',
        kind: const Value('local'),
        title: '本地书',
        rootId: const Value(r'c:\library'),
        relativePath: const Value('book.txt'),
      ),
    );

    await expectLater(
      () => shelf.switchSource(
        'local-x',
        sourceB,
        book('https://b.test'),
        chapters('https://b.test', const ['第一章']),
      ),
      throwsA(isA<StateError>()),
    );
  });
}
