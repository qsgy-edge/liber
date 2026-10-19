import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
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

    // The line-derived fields describe a position inside the *old* source's
    // chapter text (the local reader is their only reader today).
    await store.putProgress(
      ProgressCompanion(
        bookId: Value(before.id),
        textOffset: const Value(42),
        lineIndex: const Value(7),
        offsetInLine: const Value(9),
        textLength: const Value(5000),
        anchor: const Value('初入宗门'),
        chapterKey: const Value('https://a.test/chapter/2'),
        chapterIndex: const Value(2),
      ),
    );

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
    // The record must not describe two texts at once: the position columns move
    // to the new chapter, the line-derived ones are cleared.
    expect(progressAfter.lineIndex, 0);
    expect(progressAfter.offsetInLine, 0);
    expect(progressAfter.textLength, 0);
    expect(progressAfter.anchor, isNull);

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

  // --- #132 cancellation -----------------------------------------------------
  //
  // The publication re-reads the caller's liveness inside its own transaction,
  // so the two windows the manual page and the automatic walk can be cancelled
  // in — a transaction still queued, and one already writing — both refuse the
  // switch instead of committing a late result.

  /// A book on 甲源 with a group, a per-book setting and a position, read at the
  /// second of three chapters — the row a cancelled switch must leave alone.
  Future<ShelfEntry> cancelWindowBook(SpaceStore gated) async {
    final gatedShelf = ShelfService(gated);
    await gatedShelf.add(
      sourceA,
      book('https://a.test'),
      chapters('https://a.test', const ['第一章', '第二章', '第三章']),
    );
    final entry = (await gatedShelf.find(
      'https://a.test',
      bookUrl('https://a.test'),
    ))!;
    final group = await gated.ensureGroup('在追');
    await gated.setBookGroups(entry.id, [group.id]);
    await gated.putSetting('convert', 't2s', bookId: entry.id);
    await gatedShelf.saveProgress(
      entry.id,
      chapterKey: 'https://a.test/chapter/1',
      chapterIndex: 1,
      textOffset: 42,
    );
    return (await gatedShelf.find(
      'https://a.test',
      bookUrl('https://a.test'),
    ))!;
  }

  Future<void> expectUntouched(SpaceStore gated, ShelfEntry before) async {
    final row = (await gated.bookById(before.id))!;
    expect(row.toJson(), before.book.toJson(), reason: '书行原封不动');
    expect(
      (await gated.chaptersOf(before.id)).map((chapter) => chapter.chapterKey),
      before.chapters.map((chapter) => chapter.chapterKey),
      reason: '目录还是旧书源的',
    );
    final progress = (await gated.progressOf(before.id))!;
    expect(progress.chapterKey, before.progress!.chapterKey);
    expect(progress.textOffset, 42);
    expect((await gated.groupsOf(before.id)).map((row) => row.name), ['在追']);
    expect(await gated.setting('convert', bookId: before.id), 't2s');
  }

  test('换源的事务还在排队时被取消：取消信号抛出，旧行不动', () async {
    // The gate wraps this space's own database, so `space.delete()` in the
    // tear-down is what closes it and only one database is ever open.
    final gated = GateableSpaceStore(database: space.store.db);
    final before = await cancelWindowBook(gated);
    var cancelled = false;
    gated.holdNextTransaction = true;
    final pending = ShelfService(gated).switchSource(
      before.id,
      sourceB,
      book('https://b.test'),
      chapters('https://b.test', const ['第一章', '第二章']),
      isCancelled: () => cancelled,
    );
    await gated.entered.future.timeout(const Duration(seconds: 5));
    // The owner goes away while the write is queued.
    cancelled = true;
    gated.release.complete();

    await expectLater(pending, throwsA(isA<SourceRequestCancelled>()));
    await expectUntouched(gated, before);
  }, timeout: const Timeout(Duration(seconds: 20)));

  test(
    '换源的事务已经写下一行后被取消：整个事务回滚，旧行、目录与进度都在',
    () async {
      final gated = GateableSpaceStore(database: space.store.db);
      final before = await cancelWindowBook(gated);
      var cancelled = false;
      // The cancellation lands after the transaction has already written the
      // book row: the publication's last check aborts it, and the transaction
      // rolls that write back.
      gated.afterBookWrite = () => cancelled = true;
      await expectLater(
        () => ShelfService(gated).switchSource(
          before.id,
          sourceB,
          book('https://b.test'),
          chapters('https://b.test', const ['第一章', '第二章']),
          isCancelled: () => cancelled,
        ),
        throwsA(isA<SourceRequestCancelled>()),
      );
      gated.afterBookWrite = null;

      await expectUntouched(gated, before);
      expect(
        (await ShelfService(gated).onlineShelf()).length,
        1,
        reason: '还是一条书架行',
      );
    },
    timeout: const Timeout(Duration(seconds: 20)),
  );
}
