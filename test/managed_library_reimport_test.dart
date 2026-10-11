import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:liber/store/legacy_import.dart';

import 'legado_full_backup_test.dart' show backupZip, localBook;
import 'legacy_import_test.dart' show LegacyHome;
import 'space_test_support.dart';

void main() {
  late TestSpace space;
  setUp(() async => space = await TestSpace.create());
  tearDown(() => space.delete());

  for (final reclaimed in [false, true]) {
    test(
      'backup reimport preserves adopted current locator (reclaimed=$reclaimed)',
      () async {
        final archive = LegadoBackupArchive.decode(
          backupZip(
            books: [
              localBook(
                'content://provider/document/old-book',
                originName: 'book.txt',
              ),
            ],
          ),
        );
        final importer = LegadoFullBackupImport(space.store);
        await importer.importArchive(archive);
        final original = (await space.store.localBooks()).single;
        final root = await space.store.putLocalRoot(
          LocalRootsCompanion(
            id: const Value('managed'),
            displayName: const Value('Managed books'),
            locator: Value(space.directory.path),
          ),
        );
        const key = 'book (2).md';
        final file = space.file(key);
        await file.writeAsString('第一章 新版\n已经迁入的正文');
        await space.store.putBook(
          original
              .toCompanion(false)
              .copyWith(
                rootId: Value(root.id),
                relativePath: const Value(key),
                originalRootId: Value(original.rootId),
                originalRelativePath: Value(original.relativePath),
                needsRelink: const Value(false),
                format: const Value('md'),
                charset: const Value('UTF-8'),
                title: const Value('用户的书名'),
              ),
        );
        await space.store.putLocalFile(
          LocalFilesCompanion(
            rootId: Value(root.id),
            relativePath: const Value(key),
            bookId: Value(original.id),
            locator: Value(file.path),
            name: const Value(key),
            importName: const Value('book.txt'),
            format: const Value('md'),
            textLength: const Value(900),
            modifiedAt: const Value(42),
          ),
        );
        await space.store.putProgress(
          ProgressCompanion(
            bookId: Value(original.id),
            textOffset: const Value(800),
            updatedAt: const Value(999999),
          ),
        );
        if (reclaimed) {
          await space.store.putBook(
            BooksCompanion(
              id: const Value('other-book'),
              kind: const Value('local'),
              title: const Value('另一部书'),
              rootId: Value(original.rootId),
              relativePath: Value(original.relativePath),
            ),
          );
        }
        await importer.importArchive(archive);
        final current = (await space.store.bookById(original.id))!;
        expect(await space.store.localBooks(), hasLength(reclaimed ? 2 : 1));
        expect(current.rootId, root.id);
        expect(current.relativePath, key);
        expect(current.format, 'md');
        expect(current.charset, 'UTF-8');
        expect(current.needsRelink, isFalse);
        expect(current.originalRootId, original.rootId);
        expect(current.originalRelativePath, original.relativePath);
        expect(current.title, '用户的书名');
        expect((await space.store.progressOf(original.id))!.textOffset, 800);
        expect((await space.store.localFile(root.id, key))!.textLength, 900);
        expect(await file.readAsString(), contains('已经迁入'));
        if (reclaimed) {
          final other = (await space.store.bookById('other-book'))!;
          expect(other.title, '另一部书');
          expect(
            other.raw,
            isNull,
            reason: 'The original import alias owns the backup association',
          );
          expect(other.type, 0);
        }
      },
    );
  }

  for (final reusedRootId in [false, true]) {
    test(
      'legacy reimport preserves moved book and root metadata (reuse=$reusedRootId)',
      () async {
        final oldFolder = Directory('${space.directory.path}/old-books');
        await oldFolder.create();
        final originalFile = File('${oldFolder.path}/kept.txt');
        await originalFile.writeAsString('旧的正文');
        final home = await LegacyHome.create(
          Directory('${space.directory.path}/legacy'),
        );
        final legacyJson = await home.writeLocalBooks(rootPath: oldFolder.path);
        final legacyData =
            jsonDecode(await legacyJson.readAsString()) as Map<String, dynamic>;
        legacyData['books'] = (legacyData['books'] as List)
            .where((entry) => (entry as Map)['relativePath'] == 'kept.txt')
            .toList();
        await legacyJson.writeAsString(jsonEncode(legacyData));
        final legacy = LegacyImport(home: home.directory);
        await legacy.run(space.store);
        final original = (await space.store.localBook(
          oldFolder.path.toLowerCase(),
          'kept.txt',
        ))!;
        final newFolder = Directory('${space.directory.path}/managed');
        await newFolder.create();
        const key = 'kept (2).md';
        final newFile = File('${newFolder.path}/$key');
        await newFile.writeAsString('新版和用户进度');
        final root = await space.store.putLocalRoot(
          LocalRootsCompanion(
            id: Value(reusedRootId ? original.rootId! : 'managed'),
            displayName: const Value('Managed books'),
            locator: Value(newFolder.path),
            identity: const Value('verified-new-location'),
            needsRelink: const Value(false),
          ),
        );
        await space.store.putBook(
          original
              .toCompanion(false)
              .copyWith(
                rootId: Value(root.id),
                relativePath: const Value(key),
                originalRootId: Value(original.rootId),
                originalRelativePath: Value(original.relativePath),
                needsRelink: const Value(false),
                title: const Value('用户的书名'),
                format: const Value('md'),
                charset: const Value('UTF-8'),
              ),
        );
        await space.store.putLocalFile(
          LocalFilesCompanion(
            rootId: Value(root.id),
            relativePath: const Value(key),
            bookId: Value(original.id),
            locator: Value(newFile.path),
            name: const Value(key),
            importName: const Value('kept.txt'),
            format: const Value('md'),
            textLength: const Value(900),
            modifiedAt: const Value(42),
          ),
        );
        await space.store.putProgress(
          ProgressCompanion(
            bookId: Value(original.id),
            textOffset: const Value(800),
            updatedAt: const Value(999999),
          ),
        );
        await (space.store.db.delete(space.store.db.localFiles)..where(
              (file) =>
                  file.rootId.equals(original.rootId!) &
                  file.relativePath.equals(original.relativePath!),
            ))
            .go();
        await originalFile.delete();
        final before = await space.store.localBooks();
        await legacy.run(space.store, force: true);
        final current = (await space.store.bookById(original.id))!;
        expect(await space.store.localBooks(), hasLength(before.length));
        expect(current.rootId, root.id);
        expect(current.relativePath, key);
        expect(current.format, 'md');
        expect(current.title, '用户的书名');
        expect(current.needsRelink, isFalse);
        expect(current.originalRootId, original.rootId);
        expect(current.originalRelativePath, original.relativePath);
        expect((await space.store.progressOf(original.id))!.textOffset, 800);
        final roots = await space.store.allLocalRoots();
        final currentRoot = roots.singleWhere((r) => r.id == root.id);
        expect(currentRoot.displayName, 'Managed books');
        expect(currentRoot.locator, newFolder.path);
        expect(currentRoot.identity, 'verified-new-location');
        expect(currentRoot.needsRelink, isFalse);
        final storedFile = (await space.store.localFile(root.id, key))!;
        expect(storedFile.textLength, 900);
        expect(storedFile.needsRelink, isFalse);
        expect(
          (await space.store.localFile(original.rootId!, 'kept.txt'))?.bookId,
          isNot(original.id),
          reason: 'Reimport cannot create a second current file association',
        );
        expect(await newFile.readAsString(), '新版和用户进度');
        expect(jsonDecode(current.raw!)['title'], 'kept.txt');
      },
    );
  }
}
