import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/progress.dart';
import 'package:liber/store/space_store.dart';

import 'legado_full_backup_test.dart' show backupZip, localBook;
import 'managed_library_test.dart' show MemoryLibraryAccess, accessError;
import 'space_test_support.dart';

/// #142's explicit reconnect of a migrated local book.
///
/// The fixture is the importer's own row: a synthetic Legado backup whose local
/// book keeps metadata, a group and a position but carries no bytes and no
/// readable root. A reconnect is the user's file selection for that exact book;
/// these tests do not establish a native picker or provider receipt.
void main() {
  late TestSpace space;
  late SpaceStore store;
  late MemoryLibraryAccess access;
  late LocalLibrary library;
  late LibraryLocation managed;
  late LibraryLocation other;
  var operation = 0;
  LibraryTransfer transfer() => LibraryTransfer(id: 'relink-${operation++}');
  Future<LibraryConflictChoice> unexpected(
    LibraryImportConflict conflict,
  ) async => throw StateError('Unexpected conflict: ${conflict.name}');

  /// The importer's row for one migrated local book, before any reconnect.
  Future<ShelfBook> importMigrated() async {
    await LegadoFullBackupImport(store).importArchive(
      LegadoBackupArchive.decode(
        backupZip(
          groups: [
            {'groupId': 1, 'groupName': '历史', 'order': 0},
          ],
          books: [
            {
              ...localBook(
                'content://provider/document/migrated',
                originName: 'migrated.txt',
                group: 1,
              ),
              'author': '迁移作者',
              'intro': '迁移简介',
              'customTag': '迁移标签',
              'durChapterIndex': 4,
              'durChapterPos': 240,
              'durChapterTime': 42,
            },
          ],
        ),
      ),
    );
    await library.load();
    // The migrated row is the one whose current root is still the backup's
    // correlation key; the library may already hold other local books.
    return (await store.localBooks()).singleWhere(
      (book) => book.rootId!.startsWith('sha256:'),
    );
  }

  Future<void> selectManagedRoot() async {
    await library.selectLocation(
      managed,
      transfer: transfer(),
      resolveConflict: unexpected,
    );
  }

  /// A local book another root already owns — the independent book a reconnect
  /// must never take a file from.
  Future<LibraryFileReference> otherBookFile(
    LibraryFileReference file,
    String bookId, {
    String title = '另一部书',
  }) async {
    final root = file.root!;
    await store.putLocalRoot(
      LocalRootsCompanion.insert(
        id: root.identity,
        displayName: root.displayName,
        kind: Value(root.kind.name),
        locator: Value(root.locator),
        identity: Value(root.identity),
        authorization: Value(root.authorization),
      ),
    );
    await store.putBook(
      BooksCompanion.insert(
        id: bookId,
        title: title,
        kind: const Value('local'),
        rootId: Value(root.identity),
        relativePath: Value(file.key),
      ),
    );
    await store.putLocalFile(
      LocalFilesCompanion.insert(
        rootId: root.identity,
        relativePath: file.key,
        locator: Value(file.locator),
        name: Value(file.name),
        bookId: Value(bookId),
      ),
    );
    await library.load();
    return file;
  }

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    access = MemoryLibraryAccess();
    managed = access.addRoot('managed');
    other = access.addRoot('other');
    library = LocalLibrary(store, access: access);
  });
  tearDown(() => space.delete());

  test(
    'an explicit reconnect keeps the id, metadata, group, settings, progress and correlation',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      final progress = (await store.progressOf(migrated.id))!;
      final group = (await store.groupsOf(migrated.id)).single;
      await store.putSetting('font', '18', bookId: migrated.id);
      expect(progress.textOffset, 240);
      expect(progress.chapterIndex, 4);
      expect(library.books.single.path, isEmpty);
      await selectManagedRoot();

      final selected = access.addFile('picked', 'novel.txt', '第一章 重新关联的正文');
      final relinked = await library.relinkBook(
        migrated.id,
        selected,
        transfer: transfer(),
        resolveConflict: unexpected,
      );

      final row = (await store.bookById(migrated.id))!;
      expect(relinked.id, migrated.id);
      expect(row.rootId, library.managedRoot!.id);
      expect(row.needsRelink, isFalse);
      expect(row.title, migrated.title);
      expect(row.author, '迁移作者');
      expect(row.intro, '迁移简介');
      expect(row.customTag, '迁移标签');
      expect(row.originalRootId, correlation);
      expect(row.originalRelativePath, migrated.relativePath);
      expect(await store.localBooks(), hasLength(1));
      expect(await store.progressOf(migrated.id), progress);
      expect((await store.groupsOf(migrated.id)).single.id, group.id);
      expect(await store.setting('font', bookId: migrated.id), '18');
      final stored = (await store.localFile(row.rootId!, row.relativePath!))!;
      expect(access.bytes[stored.locator], '第一章 重新关联的正文');
      expect(
        access.bytes[selected.locator],
        '第一章 重新关联的正文',
        reason: 'The selected original file is retained',
      );
      expect(access.copyCount, 1);
      expect(access.deleted, isEmpty);
      expect(
        (await library.fileReferenceOf(relinked))!.locator,
        stored.locator,
      );
    },
  );

  test('a reconnect survives a restart and a repeated backup import', () async {
    final migrated = await importMigrated();
    final correlation = migrated.rootId!;
    await selectManagedRoot();
    final relinked = await library.relinkBook(
      migrated.id,
      access.addFile('picked', 'novel.txt', '第一章 正文'),
      transfer: transfer(),
      resolveConflict: unexpected,
    );
    final row = (await store.bookById(migrated.id))!;
    final file = (await store.localFile(row.rootId!, row.relativePath!))!;

    // The reader's own five-field write, then a restart of the application.
    await library.saveProgressRecord(
      migrated.id,
      const ProgressRecord(
        textOffset: 12,
        lineIndex: 0,
        offsetInLine: 12,
        textLength: 40,
        chapterKey: 'native-chapter',
        chapterIndex: 0,
        anchor: '第一章',
        updatedAt: 777,
      ),
    );
    final nativeProgress = (await store.progressOf(migrated.id))!;
    await space.reopen();
    store = space.store;
    library = LocalLibrary(store, access: access);
    await library.load();
    final reopened = library.books.singleWhere(
      (book) => book.id == migrated.id,
    );
    expect((await store.bookById(migrated.id))!.needsRelink, isFalse);
    expect(
      (await library.fileReferenceOf(reopened))!.locator,
      file.locator,
      reason: 'A restart keeps the reconnected file readable',
    );
    expect(await store.progressOf(migrated.id), nativeProgress);

    // The same backup again: one book, the recovered one, and no backward
    // progress.
    await LegadoFullBackupImport(store).importArchive(
      LegadoBackupArchive.decode(
        backupZip(
          groups: [
            {'groupId': 1, 'groupName': '历史', 'order': 0},
          ],
          books: [
            {
              ...localBook(
                'content://provider/document/migrated',
                originName: 'migrated.txt',
                group: 1,
              ),
              'durChapterIndex': 4,
              'durChapterPos': 240,
              'durChapterTime': 42,
            },
          ],
        ),
      ),
    );
    final afterImport = (await store.bookById(migrated.id))!;
    expect(await store.localBooks(), hasLength(1));
    expect(await store.bookById(relinked.id), afterImport);
    expect(afterImport.rootId, row.rootId);
    expect(afterImport.relativePath, row.relativePath);
    expect(afterImport.needsRelink, isFalse);
    expect(afterImport.originalRootId, correlation);
    expect(afterImport.originalRelativePath, migrated.relativePath);
    expect(await store.progressOf(migrated.id), nativeProgress);
  });

  test(
    'a cancelled, failed or unpublished reconnect keeps the book and the selected file',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      await selectManagedRoot();
      final selected = access.addFile('picked', 'novel.txt', '正文');
      Future<void> unchanged() async {
        final row = (await store.bookById(migrated.id))!;
        expect(row.needsRelink, isTrue);
        expect(row.rootId, correlation);
        expect(await store.localBooks(), hasLength(1));
        expect(access.bytes.keys, [selected.locator]);
      }

      final cancelled = transfer();
      await cancelled.cancel();
      await expectLater(
        library.relinkBook(
          migrated.id,
          selected,
          transfer: cancelled,
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.cancelled)),
      );
      await unchanged();
      expect(access.copyCount, 0);

      access.copyFailure = LibraryAccessError.io;
      await expectLater(
        library.relinkBook(
          migrated.id,
          selected,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.io)),
      );
      await unchanged();
      access.copyFailure = null;

      // A cancellation after the copy is owned: only that copy is removed.
      final late = transfer();
      access.beforeCopyReturn = late.cancel;
      await expectLater(
        library.relinkBook(
          migrated.id,
          selected,
          transfer: late,
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.cancelled)),
      );
      access.beforeCopyReturn = null;
      await unchanged();
      expect(access.deleted, hasLength(1));

      // A publication failure rolls the store back and cleans the same copy.
      access.deleted.clear();
      await store.db.customStatement(
        "CREATE TRIGGER fail_relink_file BEFORE INSERT ON local_files BEGIN SELECT RAISE(ABORT, 'injected publication'); END",
      );
      await expectLater(
        library.relinkBook(
          migrated.id,
          selected,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(anything),
      );
      await store.db.customStatement('DROP TRIGGER fail_relink_file');
      await unchanged();
      expect(access.deleted, hasLength(1));
      expect(await store.localFilesOf(correlation), isEmpty);
    },
  );

  test(
    'a file another book currently reads is refused without changing either book',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      await selectManagedRoot();
      final shared = access.addFile(
        'shared',
        'shared.txt',
        'B 的正文',
        root: other,
      );
      await otherBookFile(shared, 'book-b');

      await expectLater(
        library.relinkBook(
          migrated.id,
          shared,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(
          isA<LibraryAccessFailure>()
              .having(
                (error) => error.code,
                'code',
                LibraryAccessError.collision,
              )
              .having(
                (error) => (error.details as Map)['bookIds'],
                'both identities',
                [migrated.id, 'book-b'],
              ),
        ),
      );

      final row = (await store.bookById(migrated.id))!;
      expect(row.needsRelink, isTrue);
      expect(row.rootId, correlation);
      final owner = (await store.bookById('book-b'))!;
      expect(owner.rootId, other.identity);
      expect(owner.relativePath, shared.key);
      expect(access.copyCount, 0);
      expect(access.bytes[shared.locator], 'B 的正文');
      expect(await store.localBooks(), hasLength(2));
    },
  );

  test(
    'an owned destination candidate is refused instead of kept as a second copy',
    () async {
      await selectManagedRoot();
      final owned = access.addFile('owner-source', 'novel.txt', 'B 的书库正文');
      final otherBook = (await library.importFiles(
        [owned],
        transfer: transfer(),
        resolveConflict: unexpected,
      )).single;
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      final selected = access.addFile('picked', 'novel.txt', 'A 的正文');

      await expectLater(
        library.relinkBook(
          migrated.id,
          selected,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.collision)),
      );

      final row = (await store.bookById(migrated.id))!;
      expect(row.needsRelink, isTrue);
      expect(row.rootId, correlation);
      final unchanged = (await store.bookById(otherBook.id))!;
      expect(unchanged.rootId, library.managedRoot!.id);
      expect(await store.localBooks(), hasLength(2));
      expect(
        access.copyCount,
        1,
        reason: 'Only the other book imported a copy',
      );
      final stored = (await store.localFile(
        unchanged.rootId!,
        unchanged.relativePath!,
      ))!;
      expect(access.bytes[stored.locator], 'B 的书库正文');
      expect(access.bytes[selected.locator], 'A 的正文');
    },
  );

  test(
    'an unowned same-name file still follows the existing conflict choices',
    () async {
      await selectManagedRoot();
      final unowned = access.addFile(
        'loose',
        'novel.txt',
        '库里的散装文件',
        root: access.roots[managed.locator],
      );
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      final selected = access.addFile('picked', 'novel.txt', 'A 的正文');
      final asked = <LibraryImportConflict>[];
      final relinked = await library.relinkBook(
        migrated.id,
        selected,
        transfer: transfer(),
        resolveConflict: (conflict) async {
          asked.add(conflict);
          return LibraryConflictChoice.keepBoth;
        },
      );

      expect(asked.single.existingBookId, isNull);
      expect(asked.single.incomingBookId, migrated.id);
      final row = (await store.bookById(migrated.id))!;
      expect(row.rootId, library.managedRoot!.id);
      expect(row.needsRelink, isFalse);
      expect(row.originalRootId, correlation);
      expect(relinked.id, migrated.id);
      final stored = (await store.localFile(row.rootId!, row.relativePath!))!;
      expect(stored.relativePath, isNot(unowned.key));
      expect(stored.name, 'novel (2).txt');
      expect(stored.importName, 'novel.txt');
      expect(access.bytes[stored.locator], 'A 的正文');
      expect(
        access.bytes[unowned.locator],
        '库里的散装文件',
        reason: 'An unowned library file is kept as it is',
      );
      expect(access.copyCount, 1);
    },
  );

  test('a book whose file is readable is not reconnected', () async {
    await selectManagedRoot();
    final imported = (await library.importFiles(
      [access.addFile('one', 'book.txt', '正文')],
      transfer: transfer(),
      resolveConflict: unexpected,
    )).single;
    final replacement = access.addFile('two', 'other.txt', '另一份正文');
    await expectLater(
      library.relinkBook(
        imported.id,
        replacement,
        transfer: transfer(),
        resolveConflict: unexpected,
      ),
      throwsA(accessError(LibraryAccessError.permission)),
    );
    final row = (await store.bookById(imported.id))!;
    expect(row.rootId, library.managedRoot!.id);
    expect(row.needsRelink, isFalse);
    expect(access.copyCount, 1);
  });

  test(
    'a retained grant of the same provider that owns no book does not block a reconnect',
    () async {
      final migrated = await importMigrated();
      await selectManagedRoot();
      final selected = access.addFile(
        'picked-document',
        'selected.txt',
        '第一章 所选文件的正文',
        root: access.addRoot(
          'picked',
          locator: 'content://example.documents/tree/picked',
        ),
      );
      final unrelated = access.addRoot(
        'retired-unrelated',
        locator: 'content://example.documents/tree/retired-unrelated',
      );
      await store.putLocalRoot(
        LocalRootsCompanion.insert(
          id: unrelated.identity,
          displayName: unrelated.displayName,
          kind: Value(unrelated.kind.name),
          locator: Value(unrelated.locator),
          identity: Value(unrelated.identity),
          authorization: Value(unrelated.authorization),
        ),
      );
      // No current book and no original pair refers to this retained grant.
      access.rootFailures[unrelated.locator] = LibraryAccessError.verification;
      access.inspectedRoots.clear();

      final relinked = await library.relinkBook(
        migrated.id,
        selected,
        transfer: transfer(),
        resolveConflict: unexpected,
      );

      expect(relinked.id, migrated.id);
      expect((await store.bookById(migrated.id))!.needsRelink, isFalse);
      expect(
        access.inspectedRoots,
        isNot(contains(unrelated.locator)),
        reason:
            'A shared provider authority is not a grant to inspect another root',
      );
      expect(access.bytes[selected.locator], '第一章 所选文件的正文');
      expect(access.copyCount, 1);
    },
  );

  test(
    'a same-provider root whose book records another file does not block a reconnect',
    () async {
      final migrated = await importMigrated();
      await selectManagedRoot();
      final provider = access.addRoot(
        'provider',
        locator: 'content://example.documents/tree/provider',
      );
      final otherFile = access.addFile(
        'other-document',
        'other.txt',
        '另一部书的正文',
        root: provider,
        identity: 'other-id',
      );
      await otherBookFile(otherFile, 'book-c');
      access.rootFailures[provider.locator] = LibraryAccessError.verification;
      access.inspectedRoots.clear();
      final selected = access.addFile(
        'picked-document',
        'selected.txt',
        '第一章 所选文件的正文',
        root: access.addRoot(
          'picked',
          locator: 'content://example.documents/tree/picked',
        ),
      );

      final relinked = await library.relinkBook(
        migrated.id,
        selected,
        transfer: transfer(),
        resolveConflict: unexpected,
      );

      expect(relinked.id, migrated.id);
      expect((await store.bookById(migrated.id))!.needsRelink, isFalse);
      expect(
        access.inspectedRoots,
        isNot(contains(provider.locator)),
        reason:
            "Another book's recorded key cannot nominate this root for the "
            'selected document',
      );
      final other = (await store.bookById('book-c'))!;
      expect(other.rootId, provider.identity);
      expect(other.relativePath, otherFile.key);
      expect(access.bytes[otherFile.locator], '另一部书的正文');
      expect(access.bytes[selected.locator], '第一章 所选文件的正文');
      expect(access.copyCount, 1);
    },
  );

  test(
    'a selected document another book owns is refused through a detached grant',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      await selectManagedRoot();
      final provider = access.addRoot(
        'provider',
        locator: 'content://example.documents/tree/books',
      );
      final owned = access.addFile(
        'owned-document',
        'owned.txt',
        'B 的正文',
        root: provider,
        identity: 'owned-id',
      );
      await otherBookFile(owned, 'book-b');
      // A fresh pick of the same document: the provider key stays its identity
      // while the grant that opened it is new.
      final fresh = LibraryFileReference(
        kind: owned.kind,
        locator: owned.locator,
        key: owned.key,
        name: owned.name,
        identity: owned.identity,
        authorization: 'grant:fresh-pick',
        size: owned.size,
      );

      await expectLater(
        library.relinkBook(
          migrated.id,
          fresh,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(
          isA<LibraryAccessFailure>()
              .having(
                (error) => error.code,
                'code',
                LibraryAccessError.collision,
              )
              .having(
                (error) => (error.details as Map)['bookIds'],
                'both identities',
                [migrated.id, 'book-b'],
              ),
        ),
      );
      final row = (await store.bookById(migrated.id))!;
      expect(row.needsRelink, isTrue);
      expect(row.rootId, correlation);
      expect((await store.bookById('book-b'))!.relativePath, owned.key);
      expect(access.bytes[owned.locator], 'B 的正文');
      expect(access.copyCount, 0);
    },
  );

  test(
    'a selected apple document another book owns is refused when its key changed',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      await selectManagedRoot();
      final shelf = access.addRoot(
        'shelf',
        kind: LibraryLocationKind.apple,
        locator: 'file:///shelf',
      );
      final owned = access.addFile(
        'apple.txt',
        'apple.txt',
        'B 的正文',
        root: shelf,
        identity: 'apple-id',
      );
      await otherBookFile(owned, 'book-b');
      // An Apple key is scoped to the root that opened it, so a fresh grant of
      // the same file need not repeat the recorded key.
      final fresh = LibraryFileReference(
        kind: LibraryLocationKind.apple,
        locator: owned.locator,
        key: 'fresh-scope-key',
        name: owned.name,
        identity: owned.identity,
        authorization: 'bookmark:fresh',
        size: owned.size,
      );

      await expectLater(
        library.relinkBook(
          migrated.id,
          fresh,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.collision)),
      );
      final row = (await store.bookById(migrated.id))!;
      expect(row.needsRelink, isTrue);
      expect(row.rootId, correlation);
      expect(access.bytes[owned.locator], 'B 的正文');
      expect(access.copyCount, 0);
    },
  );

  test(
    'a picked file inside another book\'s filesystem root is refused',
    () async {
      final migrated = await importMigrated();
      final correlation = migrated.rootId!;
      await selectManagedRoot();
      final shelf = access.addRoot(
        'shelf',
        kind: LibraryLocationKind.filesystem,
        locator: '${space.directory.path}/shelf',
      );
      final owned = access.addFile(
        'nested.txt',
        'nested.txt',
        'B 的正文',
        root: shelf,
      );
      await otherBookFile(owned, 'book-b');
      // The picker's own reference: the containing root is the nomination, not
      // a grant the selected file carries.
      final picked = LibraryFileReference(
        kind: LibraryLocationKind.filesystem,
        locator: owned.locator,
        key: owned.key,
        name: owned.name,
        size: owned.size,
      );

      await expectLater(
        library.relinkBook(
          migrated.id,
          picked,
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.collision)),
      );
      final row = (await store.bookById(migrated.id))!;
      expect(row.needsRelink, isTrue);
      expect(row.rootId, correlation);
      expect(access.bytes[owned.locator], 'B 的正文');
      expect(access.copyCount, 0);
    },
  );
}
