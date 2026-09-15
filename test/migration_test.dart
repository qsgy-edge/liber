import 'package:drift/drift.dart' show Value;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/database.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v1.dart' as v1;

/// The generated migration tests: the schemas in `drift_schemas/` are the
/// released versions, `drift_dev schema steps` turns them into the upgrade
/// path `SpaceDatabase.migration` runs, and these tests drive that path over
/// the real old schema. A step that produces the wrong shape, or a schema
/// change that never got a version and a snapshot, fails here instead of in a
/// user's library.
void main() {
  final verifier = SchemaVerifier(GeneratedHelper());

  test('每个已发布版本都能升级到当前版本', () async {
    for (var version = 1; version <= SpaceDatabase.latestVersion; version++) {
      final schema = await verifier.schemaAt(version);
      final database = SpaceDatabase(schema.newConnection());
      await verifier.migrateAndValidate(database, SpaceDatabase.latestVersion);
      await database.close();
      schema.close();
    }
  });

  test('v1 → v2 合并重复的自然键，然后才允许唯一索引', () async {
    final schema = await verifier.schemaAt(1);
    final old = v1.DatabaseAtV1(schema.newConnection());
    await _seedV1(old);
    await old.close();

    final database = SpaceDatabase(schema.newConnection());
    await verifier.migrateAndValidate(database, 2);

    // One row per natural key survived, and it is the earlier one.
    final books = await database.select(database.books).get();
    expect(books.map((book) => book.id), ['book-1', 'local-1']);

    // Memberships union, and the more advanced position wins.
    final groups =
        await (database.select(database.bookGroups)
              ..where((m) => m.bookId.equals('book-1')))
            .get();
    expect(groups.map((m) => m.groupId), unorderedEquals(['g1', 'g2']));
    final progress =
        await (database.select(database.progress)
              ..where((p) => p.bookId.equals('book-1')))
            .getSingle();
    expect(progress.textOffset, 300);
    expect(progress.chapterKey, 'https://s/1/2');
    expect(progress.anchor, '第二章的那一行');

    // The TOC of the row that had one moved to the survivor.
    final chapters =
        await (database.select(database.chapters)
              ..where((c) => c.bookId.equals('book-1')))
            .get();
    expect(chapters.map((c) => c.chapterKey), ['https://s/1/1', 'https://s/1/2']);

    // The local file row followed the surviving book.
    final file = await database.select(database.localFiles).getSingle();
    expect(file.bookId, 'local-1');

    // The constraint is real now: a second row for the same book is refused.
    await expectLater(
      database
          .into(database.books)
          .insert(
            BooksCompanion.insert(
              id: 'book-3',
              sourceRef: const Value('https://s'),
              sourceBookUrl: const Value('https://s/1'),
              title: '重复',
            ),
          ),
      throwsA(isA<Exception>()),
    );
    await database.close();
    schema.close();
  });

  test('没有重复行的 v1 数据库原样升级，数据不丢', () async {
    final schema = await verifier.schemaAt(1);
    final old = v1.DatabaseAtV1(schema.newConnection());
    await old
        .into(old.books)
        .insert(
          v1.BooksCompanion.insert(
            id: 'book-1',
            sourceRef: const Value('https://s'),
            sourceBookUrl: const Value('https://s/1'),
            title: '斗破苍穹',
            raw: const Value('{"unknownBookField":42}'),
          ),
        );
    await old
        .into(old.progress)
        .insert(
          v1.ProgressCompanion.insert(
            bookId: 'book-1',
            textOffset: const Value(120),
            lineIndex: const Value(3),
            offsetInLine: const Value(4),
            textLength: const Value(500),
            chapterKey: const Value('https://s/1/2'),
            chapterIndex: const Value(1),
            anchor: const Value('正文开头'),
            updatedAt: const Value(1000),
          ),
        );
    await old.close();

    final database = SpaceDatabase(schema.newConnection());
    await verifier.migrateAndValidate(database, 2);
    final book = await database.select(database.books).getSingle();
    expect(book.id, 'book-1');
    expect(book.title, '斗破苍穹');
    expect(book.raw, '{"unknownBookField":42}');
    final progress = await database.select(database.progress).getSingle();
    expect(progress.textOffset, 120);
    expect(progress.lineIndex, 3);
    expect(progress.offsetInLine, 4);
    expect(progress.textLength, 500);
    expect(progress.anchor, '正文开头');
    await database.close();
    schema.close();
  });
}

/// A v1 database holding what v1 could hold: two rows for one network book
/// (with their own groups, chapters and progress) and two for one local file.
Future<void> _seedV1(v1.DatabaseAtV1 old) async {
  for (final id in ['g1', 'g2']) {
    await old.into(old.groups).insert(v1.GroupsCompanion.insert(id: id, name: id));
  }
  await old
      .into(old.books)
      .insert(
        v1.BooksCompanion.insert(
          id: 'book-1',
          sourceRef: const Value('https://s'),
          sourceBookUrl: const Value('https://s/1'),
          title: '斗破苍穹',
        ),
      );
  await old
      .into(old.books)
      .insert(
        v1.BooksCompanion.insert(
          id: 'book-2',
          sourceRef: const Value('https://s'),
          sourceBookUrl: const Value('https://s/1'),
          title: '斗破苍穹',
          author: const Value('天蚕土豆'),
        ),
      );
  await old
      .into(old.bookGroups)
      .insert(v1.BookGroupsData(bookId: 'book-1', groupId: 'g1'));
  await old
      .into(old.bookGroups)
      .insert(v1.BookGroupsData(bookId: 'book-2', groupId: 'g2'));
  await old.batch(
    (batch) => batch.insertAll(old.chapters, [
      v1.ChaptersData(
        bookId: 'book-2',
        chapterKey: 'https://s/1/1',
        name: '第一章',
        chapterIndex: 0,
      ),
      v1.ChaptersData(
        bookId: 'book-2',
        chapterKey: 'https://s/1/2',
        name: '第二章',
        chapterIndex: 1,
      ),
    ]),
  );
  await old
      .into(old.progress)
      .insert(
        v1.ProgressCompanion.insert(
          bookId: 'book-1',
          textOffset: const Value(100),
          chapterIndex: const Value(1),
          updatedAt: const Value(1000),
        ),
      );
  await old
      .into(old.progress)
      .insert(
        v1.ProgressCompanion.insert(
          bookId: 'book-2',
          textOffset: const Value(300),
          chapterKey: const Value('https://s/1/2'),
          chapterIndex: const Value(1),
          anchor: const Value('第二章的那一行'),
          updatedAt: const Value(2000),
        ),
      );

  await old
      .into(old.localRoots)
      .insert(
        v1.LocalRootsCompanion.insert(id: 'root-1', displayName: r'C:\Books'),
      );
  for (final id in ['local-1', 'local-2']) {
    await old
        .into(old.books)
        .insert(
          v1.BooksCompanion.insert(
            id: id,
            kind: const Value('local'),
            title: 'kept.txt',
            rootId: const Value('root-1'),
            relativePath: const Value('kept.txt'),
          ),
        );
  }
  // v1's local file row may point at either duplicate.
  await old
      .into(old.localFiles)
      .insert(
        v1.LocalFilesCompanion.insert(
          rootId: 'root-1',
          relativePath: 'kept.txt',
          bookId: const Value('local-2'),
        ),
      );
}
