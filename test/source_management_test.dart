import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart' show SourceChapter;
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

/// The source-management surface over the store (#53): deleting a Book Source
/// and re-pointing its `bookSourceUrl`. A source's row identity *is* its URL, so
/// both actions reclaim what the old URL owned — its `source_entries` rows, the
/// cookies it wrote and the TLS exceptions the user confirmed for it (#36) —
/// before the source row goes or is written again, and both are one store
/// transaction: a completed action never leaves the half-deleted state behind.
///
/// The two decisions the ticket left open are asserted here as behaviour: the
/// confirmed TLS exceptions go with the URL, and a shelf book whose source
/// disappeared stays on the shelf, marked and unopenable, with its chapters and
/// its position intact.
void main() {
  late TestSpace space;
  late SpaceStore store;
  late ShelfService shelf;

  const sourceUrl = 'https://example.test';
  const movedUrl = 'https://moved.test';
  final source = <String, dynamic>{
    'bookSourceUrl': sourceUrl,
    'bookSourceName': 'Example',
    'bookSourceGroup': '精选',
    'enabled': false,
    'customOrder': 7,
  };

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    shelf = ShelfService(store);
  });

  tearDown(() => space.delete());

  /// The `source_entries` keys the store holds for one source.
  Future<List<String>> entryKeys(String sourceRef) async {
    final rows =
        await (store.db.select(store.db.sourceEntries)
              ..where((e) => e.sourceRef.equals(sourceRef))
              ..orderBy([(e) => OrderingTerm(expression: e.key)]))
            .get();
    return [for (final row in rows) row.key];
  }

  /// Every TLS-exception row the store holds, as `source|host`.
  Future<List<String>> tlsRows() async {
    final rows =
        await (store.db.select(store.db.sourceTlsExceptions)..orderBy([
              (e) => OrderingTerm(expression: e.sourceRef),
              (e) => OrderingTerm(expression: e.host),
            ]))
            .get();
    return [for (final row in rows) '${row.sourceRef}|${row.host}'];
  }

  Future<List<String>> cookieRows() async {
    final rows =
        await (store.db.select(store.db.sourceCookies)..orderBy([
              (c) => OrderingTerm(expression: c.domain),
              (c) => OrderingTerm(expression: c.name),
            ]))
            .get();
    return [
      for (final row in rows) '${row.writerRef}|${row.domain}|${row.name}',
    ];
  }

  /// A source with a host surface, a confirmed TLS exception and one shelved
  /// book with a TOC and a position: the state both actions act on.
  Future<String> seedShelf() async {
    await store.putSourceJson(source);
    await shelf.hostState
        .cookiesFor(sourceUrl)
        .set('https://example.test/', 'sid=1');
    await shelf.hostState.putEntry(sourceUrl, 'cache.key', 'cached');
    await shelf.hostState.allowInvalidCertificate(
      sourceUrl,
      'self-signed.test',
    );
    await shelf.add(
      source,
      HtmlBook(url: Uri.parse('$sourceUrl/book/1'), title: '保留的书'),
      [SourceChapter('第一章', Uri.parse('$sourceUrl/book/1/1'))],
    );
    final bookId = (await shelf.find(sourceUrl, '$sourceUrl/book/1'))!.id;
    await shelf.saveProgress(
      bookId,
      chapterKey: '$sourceUrl/book/1/1',
      chapterIndex: 0,
      textOffset: 42,
    );
    return bookId;
  }

  test('删除书源：书源行、宿主面与已确认的证书例外一起清理', () async {
    final bookId = await seedShelf();

    await shelf.deleteSource(sourceUrl);

    expect(await store.sourceByUrl(sourceUrl), isNull);
    expect(await store.allSources(), isEmpty);
    expect(await entryKeys(sourceUrl), isEmpty);
    expect(await cookieRows(), isEmpty);
    expect(await tlsRows(), isEmpty);
    // The in-memory copy of the space is the same answer in this process.
    expect(await shelf.hostState.entry(sourceUrl, 'cache.key'), isNull);
    expect(
      shelf.hostState.cookiesFor(sourceUrl).cookiesFor('https://example.test/'),
      '',
    );
    expect(
      shelf.hostState.allowsInvalidCertificate(sourceUrl, 'self-signed.test'),
      isFalse,
      reason: '例外是 (书源, 主机) 对，书源不在了就没有能再读到它的人',
    );

    // The book is kept: the row, its chapters and its position are untouched.
    final book = (await store.bookById(bookId))!;
    expect(book.shelved, isTrue);
    expect(book.sourceRef, sourceUrl);
    expect(book.originName, 'Example', reason: 'D2 保留 originName 就是为了这一天');
    expect((await store.progressOf(bookId))!.textOffset, 42);
    expect((await store.chaptersOf(bookId)).map((c) => c.name), ['第一章']);

    // A restart reads the same: the reclamation was durable, not just in
    // memory.
    store = await space.reopen();
    shelf = ShelfService(store);
    expect(await store.sourceByUrl(sourceUrl), isNull);
    expect(await tlsRows(), isEmpty);
    expect(await entryKeys(sourceUrl), isEmpty);
  });

  test('删除书源后，书架上的书保留并标记，同 URL 的书源重新导入即恢复', () async {
    final bookId = await seedShelf();

    await shelf.deleteSource(sourceUrl);

    final entries = await shelf.onlineShelf();
    expect(entries, hasLength(1), reason: '书还在书架上，只是打不开了');
    final entry = entries.single;
    expect(entry.id, bookId);
    expect(entry.title, '保留的书');
    expect(entry.source, isNull);
    expect(entry.sourceMissing, isTrue);
    expect(entry.sourceJson, isEmpty);
    expect(entry.chapters.map((chapter) => chapter.name), ['第一章']);
    expect(entry.textOffset, 42);
    expect(
      (await shelf.migratedBooks()).map((book) => book.title),
      isEmpty,
      reason: '它不是迁移留下的孤儿，它的 sourceRef 还在',
    );

    // The natural key is what resolves it: the same URL imported again binds the
    // book back to a source without touching the row.
    await store.putSourceJson({
      'bookSourceUrl': sourceUrl,
      'bookSourceName': 'Example again',
    });
    final again = (await shelf.onlineShelf()).single;
    expect(again.id, bookId);
    expect(again.sourceMissing, isFalse);
    expect(again.sourceJson['bookSourceName'], 'Example again');
    expect(again.textOffset, 42);
  });

  test('修改 bookSourceUrl：旧 URL 的行清理，书源在新 URL 下完整可用', () async {
    final bookId = await seedShelf();

    await shelf.repointSource(sourceUrl, '$movedUrl/book');

    // The row moved, with the object's own URL field and every typed column it
    // had (D7): the pipeline is handed `raw`, and the shelf reads the columns.
    expect(await store.sourceByUrl(sourceUrl), isNull);
    final moved = (await store.sourceByUrl('$movedUrl/book'))!;
    expect(moved.name, 'Example');
    expect(moved.groupNames, '["精选"]');
    expect(moved.enabled, isFalse, reason: '用户停用的书源不因改址而被启用');
    expect(moved.customOrder, 7);
    final listed = (await shelf.sources()).single;
    expect(listed.id, '$movedUrl/book');
    expect(listed.data['bookSourceUrl'], '$movedUrl/book');
    expect(listed.data['bookSourceName'], 'Example');

    // The old URL's host surface, cookies and TLS exception went with it, and
    // the new URL starts with nothing of its own.
    expect(await entryKeys(sourceUrl), isEmpty);
    expect(await cookieRows(), isEmpty);
    expect(await tlsRows(), isEmpty);
    expect(await shelf.hostState.entry(sourceUrl, 'cache.key'), isNull);
    expect(
      shelf.hostState.allowsInvalidCertificate(sourceUrl, 'self-signed.test'),
      isFalse,
    );
    expect(await shelf.hostState.entry('$movedUrl/book', 'cache.key'), isNull);

    // The shelf keeps the book, marked: a re-point does not silently rewrite
    // which source a book came from.
    final entry = (await shelf.onlineShelf()).single;
    expect(entry.id, bookId);
    expect(entry.book.sourceRef, sourceUrl);
    expect(entry.sourceMissing, isTrue);
    expect(entry.textOffset, 42);

    // The re-point is durable.
    store = await space.reopen();
    shelf = ShelfService(store);
    expect(await store.sourceByUrl('$movedUrl/book'), isNotNull);
    expect(await store.sourceByUrl(sourceUrl), isNull);
  });

  test('修改 bookSourceUrl 拒绝空 URL 和已被别的书源占用的 URL', () async {
    await seedShelf();
    await store.putSourceJson({
      'bookSourceUrl': movedUrl,
      'bookSourceName': 'Taken',
      'enabled': false,
    });

    await expectLater(
      shelf.repointSource(sourceUrl, '   '),
      throwsA(isA<ArgumentError>()),
    );
    await expectLater(
      shelf.repointSource(sourceUrl, movedUrl),
      throwsA(isA<StateError>()),
    );
    await expectLater(
      shelf.deleteSource('https://never-imported.test'),
      throwsA(isA<StateError>()),
    );

    // Neither refusal changed anything: the other source's row is its own, and
    // the source being edited still has its host surface and its exception.
    final taken = (await store.sourceByUrl(movedUrl))!;
    expect(taken.name, 'Taken');
    expect(taken.enabled, isFalse);
    expect(await store.sourceByUrl(sourceUrl), isNotNull);
    expect(await entryKeys(sourceUrl), ['cache.key']);
    expect(await tlsRows(), ['$sourceUrl|self-signed.test']);
  });

  test('一次删除要么全部完成，要么什么都没变', () async {
    await seedShelf();
    // A store that refuses to remove this source row after the host surface was
    // already reclaimed: the failure the transaction has to absorb.
    await store.db.customStatement(
      'CREATE TRIGGER refuse_source_delete BEFORE DELETE ON sources '
      "WHEN OLD.book_source_url = '$sourceUrl' "
      "BEGIN SELECT RAISE(ABORT, 'refused by the test'); END",
    );

    await expectLater(shelf.deleteSource(sourceUrl), throwsA(anything));

    // The action did not complete, and no half-deleted source is reachable from
    // it: the source row, its entries, its cookies and its TLS exception are all
    // still there.
    expect(await store.sourceByUrl(sourceUrl), isNotNull);
    expect(await entryKeys(sourceUrl), ['cache.key']);
    expect(await cookieRows(), ['$sourceUrl|example.test|sid']);
    expect(await tlsRows(), ['$sourceUrl|self-signed.test']);

    // With the refusal gone the same call completes and clears everything.
    await store.db.customStatement('DROP TRIGGER refuse_source_delete');
    await shelf.deleteSource(sourceUrl);
    expect(await store.sourceByUrl(sourceUrl), isNull);
    expect(await entryKeys(sourceUrl), isEmpty);
    expect(await tlsRows(), isEmpty);
  });
}
