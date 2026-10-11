import 'package:drift/drift.dart' show Value;
import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/database.dart';

import 'generated_migrations/schema.dart';
import 'generated_migrations/schema_v6.dart' as v6;

void main() {
  test(
    'v6 library references retain IDs, indexes and progress without automatic adoption',
    () async {
      final verifier = SchemaVerifier(GeneratedHelper());
      final schema = await verifier.schemaAt(6);
      final old = v6.DatabaseAtV6(schema.newConnection());
      await old
          .into(old.localRoots)
          .insert(
            v6.LocalRootsCompanion.insert(
              id: 'legacy-root',
              displayName: '/old/Books',
            ),
          );
      await old
          .into(old.books)
          .insert(
            v6.BooksCompanion.insert(
              id: 'same-book',
              title: 'Existing book',
              kind: const Value('local'),
              rootId: const Value('legacy-root'),
              relativePath: const Value('nested/book.txt'),
              charset: const Value('UTF-8'),
              raw: const Value('{"unknown":42}'),
            ),
          );
      await old
          .into(old.localFiles)
          .insert(
            v6.LocalFilesCompanion.insert(
              rootId: 'legacy-root',
              relativePath: 'nested/book.txt',
              bookId: const Value('same-book'),
              modifiedAt: const Value(1200),
              textLength: const Value(12345),
            ),
          );
      await old
          .into(old.textIndex)
          .insert(
            v6.TextIndexCompanion.insert(
              rootId: 'legacy-root',
              relativePath: 'nested/book.txt',
              byteOffset: 800,
              codeUnitOffset: 400,
              lineIndex: 9,
            ),
          );
      await old
          .into(old.progress)
          .insert(
            v6.ProgressCompanion.insert(
              bookId: 'same-book',
              textOffset: const Value(410),
              lineIndex: const Value(9),
              offsetInLine: const Value(10),
              textLength: const Value(12345),
              anchor: const Value('原有阅读位置'),
              updatedAt: const Value(1300),
            ),
          );
      await old
          .into(old.groups)
          .insert(
            v6.GroupsCompanion.insert(id: 'same-group', name: 'Existing group'),
          );
      await old
          .into(old.bookGroups)
          .insert(
            v6.BookGroupsCompanion.insert(
              bookId: 'same-book',
              groupId: 'same-group',
            ),
          );
      await old
          .into(old.settings)
          .insert(
            v6.SettingsCompanion.insert(
              key: 'reader.script',
              value: 'traditionalTaiwan',
              bookId: const Value('same-book'),
            ),
          );
      await old
          .into(old.settings)
          .insert(
            v6.SettingsCompanion.insert(
              key: 'local.active_root',
              value: 'legacy-root',
            ),
          );
      await old.close();

      final current = SpaceDatabase(schema.newConnection());
      try {
        await verifier.migrateAndValidate(current, 7);
        final root = await current.select(current.localRoots).getSingle();
        expect(root.id, 'legacy-root');
        expect(root.displayName, '/old/Books');
        expect(root.kind, 'filesystem');
        expect(root.locator, isNull);
        expect(root.authorization, isNull);
        expect(root.identity, isNull);
        final book = await current.select(current.books).getSingle();
        expect(book.id, 'same-book');
        expect(book.rootId, 'legacy-root');
        expect(book.relativePath, 'nested/book.txt');
        expect(book.raw, '{"unknown":42}');
        expect(book.originalRootId, isNull);
        expect(book.originalRelativePath, isNull);
        final file = await current.select(current.localFiles).getSingle();
        expect(file.bookId, 'same-book');
        expect(file.modifiedAt, 1200);
        expect(file.textLength, 12345);
        expect(file.locator, isNull);
        expect(file.importName, isNull);
        expect(file.sha256, isNull);
        final index = await current.select(current.textIndex).getSingle();
        expect(index.codeUnitOffset, 400);
        expect(index.lineIndex, 9);
        final progress = await current.select(current.progress).getSingle();
        expect(progress.textOffset, 410);
        expect(progress.anchor, '原有阅读位置');
        expect(progress.updatedAt, 1300);
        final membership = await current.select(current.bookGroups).getSingle();
        expect(membership.groupId, 'same-group');
        expect(membership.bookId, 'same-book');
        final settings = await current.select(current.settings).get();
        expect(
          settings.where((row) => row.bookId == 'same-book').single.value,
          'traditionalTaiwan',
        );
        expect(
          settings.where((row) => row.key == 'local.active_root').single.value,
          'legacy-root',
        );
        expect(settings.any((row) => row.key == 'local.managed_root'), isFalse);
      } finally {
        await current.close();
        schema.close();
      }
    },
  );
}
