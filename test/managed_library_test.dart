import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

void main() {
  late TestSpace space;
  late SpaceStore store;
  late MemoryLibraryAccess access;
  late LocalLibrary library;
  late LibraryLocation first;
  late LibraryLocation second;
  var operation = 0;
  LibraryTransfer transfer() => LibraryTransfer(id: 'test-${operation++}');
  Future<LibraryConflictChoice> unexpected(
    LibraryImportConflict conflict,
  ) async => throw StateError('Unexpected conflict: ${conflict.name}');
  Future<LibraryConflictChoice> update(LibraryImportConflict _) async =>
      LibraryConflictChoice.update;
  Future<LibraryConflictChoice> keepBoth(LibraryImportConflict _) async =>
      LibraryConflictChoice.keepBoth;
  Future<LocalBook> import(
    LibraryFileReference file, {
    Future<LibraryConflictChoice> Function(LibraryImportConflict)? resolve,
  }) async => (await library.importFiles(
    [file],
    transfer: transfer(),
    resolveConflict: resolve ?? unexpected,
  )).single;
  Future<LibraryMigrationResult> select(LibraryLocation root) => library
      .selectLocation(root, transfer: transfer(), resolveConflict: unexpected);

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    access = MemoryLibraryAccess();
    first = access.addRoot('First');
    second = access.addRoot('Second');
    library = LocalLibrary(store, access: access);
    await select(first);
  });
  tearDown(() => space.delete());

  Future<LocalBook> external(String id, LibraryFileReference file) async {
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
        id: id,
        title: 'Preserved title',
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
        bookId: Value(id),
      ),
    );
    await library.load();
    return library.books.singleWhere((book) => book.id == id);
  }

  test(
    'verified copy publishes provider key/name and preserves external original',
    () async {
      access.renameCopies = true;
      final source = access.addFile('source', 'novel.txt', 'original');
      access.beforeCopyReturn = () async {
        expect(await store.localBooks(), isEmpty);
        expect(access.bytes[source.locator], 'original');
      };
      final book = await import(source);
      final file = (await store.localFile(book.rootId, book.relativePath!))!;
      expect(file.relativePath, startsWith('Opaque:'));
      expect(file.name, 'provider-1.txt');
      expect(file.importName, 'novel.txt');
      expect(
        (await library.fileReferenceOf(book))!.root!.locator,
        first.locator,
      );
      access.bytes[source.locator] = 'changed external';
      expect(access.bytes[file.locator], 'original');
      access.bytes.remove(source.locator);
      expect(await library.statBook(book), isNotNull);
    },
  );

  test('canonical member admission and repeat admission do not copy', () async {
    final source = access.addFile(
      'Case:ABC',
      'member.md',
      '# member',
      root: first,
    );
    final firstBook = await import(source);
    await store.setShelved(firstBook.id, false);
    expect((await import(source)).id, firstBook.id);
    expect(access.copyCount, 0);
    await expectLater(
      library.listCurrentFolder(),
      throwsA(accessError(LibraryAccessError.unsupported)),
    );
    expect((await store.bookById(firstBook.id))!.shelved, isTrue);
  });

  test(
    'admitting a canonical legacy book fills its missing native file facts',
    () async {
      final member = access.addFile(
        'Legacy:KEY',
        'legacy.txt',
        'bytes',
        root: first,
      );
      await store.putBook(
        BooksCompanion.insert(
          id: 'legacy-member',
          title: 'Preserved',
          kind: const Value('local'),
          rootId: Value(library.managedRoot!.id),
          relativePath: Value(member.key),
        ),
      );
      await library.load();
      final old = library.books.single;
      expect(await library.fileReferenceOf(old), isNull);
      final admitted = await import(member);
      expect(admitted.id, old.id);
      expect(access.copyCount, 0);
      expect(
        (await library.fileReferenceOf(admitted))!.locator,
        member.locator,
      );
      expect(
        (await store.localFile(admitted.rootId, member.key))!.bookId,
        old.id,
      );
      expect((await store.bookById(old.id))!.needsRelink, isFalse);
    },
  );

  test(
    'equal logical name and bytes reuse ID and progress after provider rename',
    () async {
      access.renameCopies = true;
      final book = await import(access.addFile('one', 'book.txt', 'same'));
      await library.updateOffset(book.id, 81);
      await store.setShelved(book.id, false);
      final reused = await import(access.addFile('two', 'book.txt', 'same'));
      expect(reused.id, book.id);
      expect(reused.textOffset, 81);
      expect(access.copyCount, 1);
      expect((await store.bookById(book.id))!.shelved, isTrue);
    },
  );

  test(
    'update switches locator atomically and invalidates index without losing metadata',
    () async {
      final original = access.addFile('original', 'book.txt', 'old bytes');
      final book = await import(original);
      final oldReference = (await library.fileReferenceOf(book))!;
      await library.putFileIndex(
        book,
        encoding: 'UTF-8',
        codeUnitLength: 9,
        modifiedAt: 42,
        anchors: [(byteOffset: 0, codeUnitOffset: 0, lineIndex: 0)],
      );
      await library.updateOffset(book.id, 7);
      final group = await store.ensureGroup('group');
      await store.setBookGroups(book.id, [group.id]);
      await store.putSetting('font', '18', bookId: book.id);
      await store.putBook(
        BooksCompanion(
          id: Value(book.id),
          title: const Value('Custom title'),
          author: const Value('Author'),
        ),
      );
      final source = access.addFile(
        'replacement',
        'book.txt',
        'replacement bytes',
      );
      final updated = await import(source, resolve: update);
      expect(updated.id, book.id);
      expect(updated.path, isNot(oldReference.locator));
      expect(access.bytes[oldReference.locator], 'old bytes');
      expect(access.bytes[original.locator], 'old bytes');
      expect((await store.bookById(book.id))!.title, 'Custom title');
      expect((await store.bookById(book.id))!.author, 'Author');
      expect((await store.progressOf(book.id))!.textOffset, 7);
      expect((await store.groupsOf(book.id)).single.id, group.id);
      expect(await store.setting('font', bookId: book.id), '18');
      final index = await library.fileIndex(updated);
      expect(index.encoding, isEmpty);
      expect(index.anchors, isEmpty);
      expect(index.textLength, isNull);
      expect(await store.textIndexOf(book.rootId, book.relativePath!), isEmpty);
      // The retained old physical filename must not take precedence over importName.
      expect((await import(source)).id, book.id);
      expect(access.copyCount, 2);
    },
  );

  test(
    'keep both makes another book and explicit cancellation leaves old bytes',
    () async {
      final firstBook = await import(access.addFile('one', 'book.txt', 'one'));
      final source = access.addFile('two', 'book.txt', 'two');
      await expectLater(
        library.importFiles(
          [source],
          transfer: transfer(),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        ),
        throwsA(accessError(LibraryAccessError.cancelled)),
      );
      expect(access.copyCount, 1);
      final other = await import(source, resolve: keepBoth);
      expect(other.id, isNot(firstBook.id));
      expect(other.path, isNot(firstBook.path));
      expect(await store.localBooks(), hasLength(2));
      expect((await import(source)).id, other.id);
      expect(access.copyCount, 2);
    },
  );

  test(
    'late transfer cancellation cleans only the unpublished successful receipt',
    () async {
      final source = access.addFile('source', 'book.txt', 'bytes');
      final operation = transfer();
      access.beforeCopyReturn = operation.cancel;
      await expectLater(
        library.importFiles(
          [source],
          transfer: operation,
          resolveConflict: unexpected,
        ),
        throwsA(accessError(LibraryAccessError.cancelled)),
      );
      expect(await store.localBooks(), isEmpty);
      expect(access.bytes.keys, [source.locator]);
      expect(access.deleted, hasLength(1));
    },
  );

  test(
    'DB publication failure rolls back update and cleans the new receipt',
    () async {
      final book = await import(access.addFile('one', 'book.txt', 'old'));
      final oldFile = (await library.fileReferenceOf(book))!;
      await store.db.customStatement(
        "CREATE TRIGGER fail_file BEFORE INSERT ON local_files BEGIN SELECT RAISE(ABORT, 'injected publication'); END",
      );
      await expectLater(
        import(access.addFile('two', 'book.txt', 'new'), resolve: update),
        throwsA(anything),
      );
      expect((await library.fileReferenceOf(book))!.locator, oldFile.locator);
      expect(access.bytes[oldFile.locator], 'old');
      expect(access.deleted, hasLength(1));
      expect(await store.localFilesOf(book.rootId), hasLength(1));
      await store.db.customStatement('DROP TRIGGER fail_file');
    },
  );

  test(
    'verification failure is not published and cleanup failure is exposed',
    () async {
      access.corruptReceipt = true;
      final source = access.addFile('source', 'book.txt', 'bytes');
      await expectLater(
        import(source),
        throwsA(
          isA<LibraryAccessFailure>().having(
            (error) => error.details,
            'cleanup details',
            isA<Map>(),
          ),
        ),
      );
      expect(await store.localBooks(), isEmpty);
      expect(access.bytes[source.locator], 'bytes');
      expect(
        access.deleted,
        isEmpty,
        reason: 'changed or unknown copy must not be deleted',
      );
    },
  );

  test('failed cleanup reports operation and exact owned receipt', () async {
    final operation = transfer();
    access.beforeCopyReturn = operation.cancel;
    access.failDelete = true;
    await expectLater(
      library.importFiles(
        [access.addFile('source', 'book.txt', 'bytes')],
        transfer: operation,
        resolveConflict: unexpected,
      ),
      throwsA(
        isA<LibraryAccessFailure>().having(
          (error) => (error.details as Map)['files'],
          'owned files',
          hasLength(1),
        ),
      ),
    );
    expect(await store.localBooks(), isEmpty);
  });

  test('load marks revoked access but surfaces unexpected IO errors', () async {
    final book = await import(access.addFile('source', 'book.txt', 'bytes'));
    access.rootFailure = LibraryAccessError.permission;
    await library.load();
    expect(library.managedRoot!.needsRelink, isTrue);
    expect((await store.bookById(book.id))!.needsRelink, isTrue);
    access.rootFailure = LibraryAccessError.io;
    await expectLater(
      library.load(),
      throwsA(accessError(LibraryAccessError.io)),
    );
    access.rootFailure = null;
    await library.load();
    expect((await store.bookById(book.id))!.needsRelink, isFalse);
  });

  test(
    'listing errors and unsupported membership do not trigger a copy fallback',
    () async {
      final source = access.addFile('source', 'book.txt', 'bytes');
      access.listFailure = LibraryAccessError.permission;
      await expectLater(
        import(source),
        throwsA(accessError(LibraryAccessError.permission)),
      );
      access.listFailure = null;
      access.membershipFailure = LibraryAccessError.unsupported;
      await expectLater(
        import(source),
        throwsA(accessError(LibraryAccessError.unsupported)),
      );
      expect(access.copyCount, 0);
      expect(await store.localBooks(), isEmpty);
    },
  );

  test(
    'opaque case-sensitive keys resolve against their own persisted grant',
    () async {
      final upper = await import(
        access.addFile('Doc:ABC', 'A.txt', 'upper', root: first),
      );
      final lower = await import(
        access.addFile('Doc:abc', 'a.txt', 'lower', root: first),
      );
      expect(upper.id, isNot(lower.id));
      expect((await library.fileReferenceOf(upper))!.key, 'Doc:ABC');
      final third = access.addRoot('External');
      final old = await external(
        'external',
        access.addFile('Doc:ABC', 'other.txt', 'external', root: third),
      );
      expect((await library.statBook(old))!.root!.identity, third.identity);
      expect((await library.statBook(upper))!.root!.identity, first.identity);
    },
  );

  test(
    'unknown timestamp persists null and never validates cached index',
    () async {
      final book = await import(access.addFile('source', 'book.txt', 'bytes'));
      await library.putFileIndex(
        book,
        encoding: 'UTF-8',
        codeUnitLength: 5,
        modifiedAt: null,
        anchors: [(byteOffset: 0, codeUnitOffset: 0, lineIndex: 0)],
      );
      final index = await library.fileIndex(book);
      expect(index.modifiedAt, isNull);
      expect(index.describes(null), isFalse);
      expect(index.describes(0), isFalse);
    },
  );

  test(
    'relocation keeps root/book identity and deletes only exact old copies on consent',
    () async {
      final a = await import(access.addFile('a', 'a.txt', 'a'));
      final b = await import(access.addFile('b', 'b.txt', 'b'));
      await library.updateOffset(a.id, 17);
      await store.setShelved(b.id, false);
      final group = await store.ensureGroup('group');
      await store.setBookGroups(a.id, [group.id]);
      await store.putSetting('font', '19', bookId: a.id);
      final unrelated = access.addFile(
        'unrelated',
        'leave.txt',
        'leave',
        root: first,
      );
      final externalRoot = access.addRoot('External');
      final externalBook = await external(
        'external',
        access.addFile('ext', 'ext.txt', 'ext', root: externalRoot),
      );
      final oldRootId = library.managedRoot!.id;
      final migration = await select(second);
      expect(migration.root.id, oldRootId);
      expect(migration.previousFiles, hasLength(2));
      expect(
        migration.previousFiles.every(
          (old) => old.file.root!.locator == first.locator,
        ),
        isTrue,
      );
      expect((await library.fileReferenceOf(a))!.root!.locator, second.locator);
      expect((await library.fileReferenceOf(b))!.root!.locator, second.locator);
      expect(
        (await library.fileReferenceOf(externalBook))!.root!.locator,
        externalRoot.locator,
      );
      expect((await store.progressOf(a.id))!.textOffset, 17);
      expect((await store.bookById(b.id))!.shelved, isFalse);
      expect((await store.groupsOf(a.id)).single.id, group.id);
      expect(await store.setting('font', bookId: a.id), '19');
      expect(access.deleted, isEmpty);
      await library.deletePreviousCopies(migration);
      expect(
        access.deleted.map((file) => file.locator),
        unorderedEquals(migration.previousFiles.map((old) => old.file.locator)),
      );
      expect(access.bytes[unrelated.locator], 'leave');
      expect(await library.statBook(a), isNotNull);
    },
  );

  test(
    'partial migration copy failure preserves old root, keys, and bytes',
    () async {
      final a = await import(access.addFile('a', 'a.txt', 'a'));
      final b = await import(access.addFile('b', 'b.txt', 'b'));
      final before = [
        await library.fileReferenceOf(a),
        await library.fileReferenceOf(b),
      ];
      access.failCopyNumber = access.copyCount + 2;
      await expectLater(
        select(second),
        throwsA(accessError(LibraryAccessError.io)),
      );
      expect(library.managedLocation!.locator, first.locator);
      expect((await library.fileReferenceOf(a))!.locator, before[0]!.locator);
      expect((await library.fileReferenceOf(b))!.locator, before[1]!.locator);
      expect(await access.list(second), isEmpty);
      expect(access.bytes[before[0]!.locator], 'a');
      expect(access.bytes[before[1]!.locator], 'b');
    },
  );

  test(
    'migration publication rollback preserves root grant and all books',
    () async {
      final a = await import(access.addFile('a', 'a.txt', 'a'));
      final b = await import(access.addFile('b', 'b.txt', 'b'));
      final oldRows = await store.localFilesOf(a.rootId);
      await store.db.customStatement(
        "CREATE TRIGGER fail_root_setting BEFORE INSERT ON settings WHEN NEW.key = 'local.managed_root' BEGIN SELECT RAISE(ABORT, 'injected migration'); END",
      );
      await expectLater(select(second), throwsA(anything));
      expect((await store.allLocalRoots()).single.locator, first.locator);
      expect(await store.localFilesOf(a.rootId), oldRows);
      expect(
        (await library.fileReferenceOf(b))!.root!.authorization,
        first.authorization,
      );
      expect(await access.list(second), isEmpty);
      await store.db.customStatement('DROP TRIGGER fail_root_setting');
    },
  );

  test('migration cancellation rolls back all successful copies', () async {
    final book = await import(access.addFile('a', 'a.txt', 'a'));
    final operation = transfer();
    access.beforeCopyReturn = operation.cancel;
    await expectLater(
      library.selectLocation(
        second,
        transfer: operation,
        resolveConflict: unexpected,
      ),
      throwsA(accessError(LibraryAccessError.cancelled)),
    );
    expect((await library.fileReferenceOf(book))!.root!.locator, first.locator);
    expect(await access.list(second), isEmpty);
  });

  test(
    'same-root renewal uses inspected identity and persists refreshed authorization',
    () async {
      final book = await import(access.addFile('a', 'a.txt', 'a'));
      await library.setNeedsRelink(book, true);
      final id = library.managedRoot!.id;
      final renewed = access.addRoot('First', authorization: 'renewed');
      final claimed = LibraryLocation(
        kind: first.kind,
        locator: first.locator,
        identity: 'untrusted claim',
        displayName: 'untrusted display',
        authorization: 'stale',
      );
      final migration = await select(claimed);
      expect(migration.previousFiles, isEmpty);
      expect(migration.root.id, id);
      expect((await store.bookById(book.id))!.needsRelink, isFalse);
      expect(migration.root.authorization, 'renewed');
      expect(migration.root.identity, renewed.identity);
      expect(
        (await library.fileReferenceOf(book))!.root!.authorization,
        'renewed',
      );
      expect(access.copyCount, 1);
    },
  );

  test('claimed same identity for another directory still migrates', () async {
    final book = await import(access.addFile('a', 'a.txt', 'a'));
    final claimed = LibraryLocation(
      kind: second.kind,
      locator: second.locator,
      identity: first.identity,
      displayName: first.displayName,
    );
    final migration = await select(claimed);
    expect(migration.previousFiles, hasLength(1));
    expect(
      (await library.fileReferenceOf(book))!.root!.identity,
      second.identity,
    );
    expect(access.copyCount, 2);
  });

  test(
    'changed previous copy prevents all cleanup and current files are guarded',
    () async {
      await import(access.addFile('a', 'a.txt', 'a'));
      final migration = await select(second);
      final previous = migration.previousFiles.single;
      access.bytes[previous.file.locator] = 'changed';
      await expectLater(
        library.deletePreviousCopies(migration),
        throwsA(accessError(LibraryAccessError.verification)),
      );
      expect(access.deleted, isEmpty);
      final otherInstance = LocalLibrary(store, access: access);
      await expectLater(
        otherInstance.deletePreviousCopies(migration),
        throwsA(accessError(LibraryAccessError.permission)),
      );
      expect(access.deleted, isEmpty);
    },
  );

  test(
    'A to B to A rejects an earlier cleanup result targeting a current file',
    () async {
      final book = await import(access.addFile('a', 'a.txt', 'a'));
      final firstMigration = await select(second);
      await select(first);
      expect((await library.fileReferenceOf(book))!.locator, book.path);
      await expectLater(
        library.deletePreviousCopies(firstMigration),
        throwsA(accessError(LibraryAccessError.permission)),
      );
      expect(access.deleted, isEmpty);
    },
  );

  test(
    'shelf removal is IO-free and explicit deletion is limited to managed canonical file',
    () async {
      final source = access.addFile('a', 'a.txt', 'a');
      final book = await import(source);
      final externalRoot = access.addRoot('External');
      final old = await external(
        'external',
        access.addFile('ext', 'ext.txt', 'ext', root: externalRoot),
      );
      await store.setShelved(book.id, false);
      expect(access.deleted, isEmpty);
      await expectLater(
        library.deleteBookFile(old.id),
        throwsA(accessError(LibraryAccessError.permission)),
      );
      await library.deleteBookFile(book.id);
      expect(access.deleted.single.locator, book.path);
      expect(access.bytes[source.locator], 'a');
      expect((await store.bookById(book.id))!.needsRelink, isTrue);
      expect(
        (await store.localFile(book.rootId, book.relativePath!))!.needsRelink,
        isTrue,
      );
    },
  );

  test(
    'adoption preserves ID metadata progress and original correlation through relocation/update',
    () async {
      final externalRoot = access.addRoot('External');
      final source = access.addFile(
        'Ext:BOOK',
        'book.txt',
        'old',
        root: externalRoot,
      );
      final book = await external('adopt-me', source);
      await library.updateOffset(book.id, 72);
      final group = await store.ensureGroup('adopted');
      await store.setBookGroups(book.id, [group.id]);
      await store.putSetting('font', '20', bookId: book.id);
      final adopted = (await library.adoptBooks(
        [book.id],
        transfer: transfer(),
        resolveConflict: unexpected,
      )).single;
      expect(adopted.id, book.id);
      expect(adopted.title, 'Preserved title');
      expect(
        (await store.localBookByOriginalKey(
          externalRoot.identity,
          source.key,
        ))!.id,
        book.id,
      );
      expect(await store.localBook(externalRoot.identity, source.key), isNull);
      await select(second);
      final updated = await import(
        access.addFile('new', 'book.txt', 'new'),
        resolve: update,
      );
      expect(updated.id, book.id);
      expect(
        (await store.localBookByOriginalKey(
          externalRoot.identity,
          source.key,
        ))!.id,
        book.id,
      );
      expect((await store.progressOf(book.id))!.textOffset, 72);
      expect((await store.groupsOf(book.id)).single.id, group.id);
      expect(await store.setting('font', bookId: book.id), '20');
      expect(access.bytes[source.locator], 'old');
    },
  );

  for (final content in ['same', 'different']) {
    test(
      'adoption of $content bytes cannot merge another book identity',
      () async {
        final destinationBook = await import(
          access.addFile('managed', 'book.txt', 'same'),
        );
        final externalRoot = access.addRoot('External');
        final source = access.addFile(
          'ext',
          'book.txt',
          content,
          root: externalRoot,
        );
        final old = await external('adopt-me', source);
        final copiesBefore = access.copyCount;
        await expectLater(
          library.adoptBooks(
            [old.id],
            transfer: transfer(),
            resolveConflict: (conflict) async {
              expect(conflict.canUpdate, isFalse);
              expect(conflict.incomingBookId, old.id);
              expect(conflict.existingBookId, destinationBook.id);
              return LibraryConflictChoice.update;
            },
          ),
          throwsA(accessError(LibraryAccessError.collision)),
        );
        expect(access.copyCount, copiesBefore);
        final adopted = (await library.adoptBooks(
          [old.id],
          transfer: transfer(),
          resolveConflict: keepBoth,
        )).single;
        expect(adopted.id, old.id);
        expect(adopted.path, isNot(destinationBook.path));
        expect(
          (await store.bookById(destinationBook.id))!.relativePath,
          destinationBook.relativePath,
        );
        expect(await store.localBooks(), hasLength(2));
        expect(access.bytes[source.locator], content);
      },
    );
  }

  test(
    'unresolved empty/relative legacy roots never reach IO or automatic adoption',
    () async {
      for (final display in ['', 'relative-folder']) {
        final id = 'legacy-$display';
        await store.putLocalRoot(
          LocalRootsCompanion.insert(id: id, displayName: display),
        );
        await store.putBook(
          BooksCompanion.insert(
            id: id,
            title: id,
            kind: const Value('local'),
            rootId: Value(id),
            relativePath: const Value('book.txt'),
          ),
        );
      }
      await library.load();
      for (final book in library.books) {
        expect(book.path, isEmpty);
        expect(await library.fileReferenceOf(book), isNull);
        expect(await library.statBook(book), isNull);
        expect((await store.bookById(book.id))!.needsRelink, isTrue);
      }
      expect(
        await library.adoptBooks(
          library.books.map((book) => book.id),
          transfer: transfer(),
          resolveConflict: unexpected,
        ),
        isEmpty,
      );
      expect(access.copyCount, 0);
    },
  );

  test(
    'original association collision fails before copy without merging identities',
    () async {
      access.renameCopies = true;
      final a = await import(access.addFile('a', 'book.txt', 'old'));
      final retained = (await library.fileReferenceOf(a))!;
      await import(access.addFile('new-a', 'book.txt', 'new'), resolve: update);
      final b = await import(retained);
      expect(b.id, isNot(a.id));
      await library.updateOffset(b.id, 7);
      final copies = access.copyCount;
      final source = access.addFile('new-b', retained.name, 'replacement');
      await expectLater(
        import(source, resolve: update),
        throwsA(
          isA<LibraryAccessFailure>()
              .having(
                (error) => error.code,
                'code',
                LibraryAccessError.collision,
              )
              .having(
                (error) => error.message,
                'association explanation',
                contains('Original import association'),
              ),
        ),
      );
      expect(access.copyCount, copies);
      expect(
        (await store.localBookByOriginalKey(a.rootId, a.relativePath!))!.id,
        a.id,
      );
      expect((await library.fileReferenceOf(b))!.locator, retained.locator);
      expect((await store.progressOf(b.id))!.textOffset, 7);
      expect(access.bytes[retained.locator], 'old');
      expect(access.bytes[source.locator], 'replacement');
      expect(access.deleted, isEmpty);
    },
  );

  test(
    'v6 same-root first selection retains original backup key across renamed moves',
    () async {
      await store.putSetting(LocalLibrary.managedRootKey, '');
      final path = p.join(space.directory.path, 'legacy-library');
      final legacyRoot = LibraryLocation(
        kind: LibraryLocationKind.filesystem,
        locator: path,
        identity: path,
        displayName: path,
      );
      access.roots[path] = legacyRoot;
      final source = access.addFile(
        'legacy.txt',
        'legacy.txt',
        'old',
        root: legacyRoot,
      );
      await store.putLocalRoot(
        LocalRootsCompanion.insert(id: 'v6-root', displayName: path),
      );
      await store.putBook(
        BooksCompanion.insert(
          id: 'v6-book',
          title: 'Legacy title',
          kind: const Value('local'),
          rootId: const Value('v6-root'),
          relativePath: const Value('legacy.txt'),
        ),
      );
      await store.putLocalFile(
        LocalFilesCompanion.insert(
          rootId: 'v6-root',
          relativePath: 'legacy.txt',
          bookId: const Value('v6-book'),
        ),
      );
      await library.load();
      expect(
        library.managedRoot,
        isNull,
        reason: 'startup does not adopt a v6 reference',
      );
      final firstSelection = await select(legacyRoot);
      expect(firstSelection.root.id, 'v6-root');
      expect(firstSelection.previousFiles, isEmpty);
      expect(access.copyCount, 0);
      access.renameCopies = true;
      await select(second);
      final moved = (await store.localBookByOriginalKey(
        'v6-root',
        'legacy.txt',
      ))!;
      expect(moved.id, 'v6-book');
      expect(moved.relativePath, startsWith('Opaque:'));
      expect(moved.title, 'Legacy title');
      await select(first);
      final updated = await import(
        access.addFile('updated', 'legacy.txt', 'new'),
        resolve: update,
      );
      expect(updated.id, 'v6-book');
      expect(
        (await store.localBookByOriginalKey('v6-root', 'legacy.txt'))!.id,
        'v6-book',
      );
      expect(access.bytes[source.locator], 'old');
    },
  );

  test(
    'relocation handles a provider permutation of old DB keys atomically',
    () async {
      final a = await import(access.addFile('a', 'a.txt', 'a'));
      final b = await import(access.addFile('b', 'b.txt', 'b'));
      access.copyKeys.addAll([b.relativePath!, a.relativePath!]);
      await select(second);
      final newA = (await library.fileReferenceOf(a))!;
      final newB = (await library.fileReferenceOf(b))!;
      expect(newA.key, b.relativePath);
      expect(newB.key, a.relativePath);
      expect(access.bytes[newA.locator], 'a');
      expect(access.bytes[newB.locator], 'b');
      expect((await store.localBook(a.rootId, newA.key))!.id, a.id);
      expect((await store.localBook(b.rootId, newB.key))!.id, b.id);
    },
  );

  test(
    'destination external book identity is also protected during relocation',
    () async {
      final managed = await import(
        access.addFile('source', 'book.txt', 'same'),
      );
      final other = await external(
        'destination-book',
        access.addFile('other', 'book.txt', 'same', root: second),
      );
      await expectLater(
        library.selectLocation(
          second,
          transfer: transfer(),
          resolveConflict: (conflict) async {
            expect(conflict.incomingBookId, managed.id);
            expect(conflict.existingBookId, other.id);
            expect(conflict.canUpdate, isFalse);
            return LibraryConflictChoice.update;
          },
        ),
        throwsA(accessError(LibraryAccessError.collision)),
      );
      expect(
        (await library.fileReferenceOf(managed))!.root!.locator,
        first.locator,
      );
      final migration = await library.selectLocation(
        second,
        transfer: transfer(),
        resolveConflict: keepBoth,
      );
      expect(migration.previousFiles, hasLength(1));
      expect(
        (await library.fileReferenceOf(managed))!.locator,
        isNot(other.path),
      );
      expect((await library.fileReferenceOf(other))!.locator, other.path);
    },
  );

  test(
    'verification failure at copy boundary leaves no published facts',
    () async {
      access.copyFailure = LibraryAccessError.verification;
      final source = access.addFile('source', 'book.txt', 'bytes');
      await expectLater(
        import(source),
        throwsA(accessError(LibraryAccessError.verification)),
      );
      expect(await store.localBooks(), isEmpty);
      expect(await access.list(first), isEmpty);
      expect(access.bytes[source.locator], 'bytes');
    },
  );

  test('reader cannot publish a stale index after an update', () async {
    final book = await import(access.addFile('source', 'book.txt', 'old'));
    final updated = await import(
      access.addFile('new', 'book.txt', 'new'),
      resolve: update,
    );
    await expectLater(
      library.putFileIndex(
        book,
        encoding: 'UTF-8',
        codeUnitLength: 3,
        modifiedAt: 42,
        anchors: [(byteOffset: 0, codeUnitOffset: 0, lineIndex: 0)],
      ),
      throwsA(accessError(LibraryAccessError.verification)),
    );
    expect((await library.fileIndex(updated)).anchors, isEmpty);
  });

  test(
    'mutations serialize while awaiting IO and recover after a rejected operation',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      access.beforeCopyReturn = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final one = import(access.addFile('one', 'book.txt', 'same'));
      await entered.future;
      final two = import(access.addFile('two', 'book.txt', 'same'));
      await Future<void>.delayed(Duration.zero);
      expect(access.copyCount, 1);
      release.complete();
      expect((await one).id, (await two).id);
      expect(access.copyCount, 1);
      access.beforeCopyReturn = null;
      access.listFailure = LibraryAccessError.io;
      await expectLater(
        import(access.addFile('bad', 'bad.txt', 'bad')),
        throwsA(accessError(LibraryAccessError.io)),
      );
      access.listFailure = null;
      expect(
        await import(access.addFile('good', 'good.txt', 'good')),
        isA<LocalBook>(),
      );
    },
  );
}

Matcher accessError(LibraryAccessError code) =>
    isA<LibraryAccessFailure>().having((error) => error.code, 'code', code);

/// Contract fake: real SQLite publication with injectable IO failures. This is
/// not provider/descriptor or native streaming-byte execution evidence.
class MemoryLibraryAccess implements LibraryAccess {
  final roots = <String, LibraryLocation>{};
  final files = <String, LibraryFileReference>{};
  final bytes = <String, String>{};
  final deleted = <LibraryFileReference>[];
  var copyCount = 0;
  var renameCopies = false;
  var corruptReceipt = false;
  var failDelete = false;
  int? failCopyNumber;
  LibraryAccessError? copyFailure;
  final copyKeys = <String>[];
  LibraryAccessError? rootFailure;
  LibraryAccessError? listFailure;
  LibraryAccessError? membershipFailure;
  Future<void> Function()? beforeCopyReturn;

  LibraryLocation addRoot(String id, {String? authorization}) {
    final root = LibraryLocation(
      kind: LibraryLocationKind.android,
      locator: 'tree:$id',
      identity: id,
      displayName: 'Display $id',
      authorization: authorization ?? 'grant:$id',
    );
    roots[root.locator] = root;
    return root;
  }

  LibraryFileReference addFile(
    String key,
    String name,
    String content, {
    LibraryLocation? root,
  }) {
    final file = LibraryFileReference(
      kind: root?.kind ?? LibraryLocationKind.android,
      locator: root?.kind == LibraryLocationKind.filesystem
          ? p.join(root!.locator, key)
          : '${root?.locator ?? 'external'}/$key',
      key: key,
      name: name,
      root: root,
      size: utf8.encode(content).length,
    );
    files[file.locator] = file;
    bytes[file.locator] = content;
    return file;
  }

  Never fail(LibraryAccessError code) =>
      throw LibraryAccessFailure(code, 'Injected $code');
  @override
  Future<LibraryLocation> inspectRoot(
    LibraryLocation root, {
    bool writable = false,
  }) async {
    if (rootFailure != null) fail(rootFailure!);
    return roots[root.locator] ?? fail(LibraryAccessError.missing);
  }

  @override
  Future<List<LibraryFileReference>> list(
    LibraryLocation root, {
    LibraryFileReference? directory,
  }) async {
    if (listFailure != null) fail(listFailure!);
    await inspectRoot(root);
    return files.values
        .where(
          (file) =>
              file.root?.locator == root.locator &&
              bytes.containsKey(file.locator),
        )
        .toList();
  }

  @override
  Future<LibraryFileReference?> stat(LibraryFileReference file) async {
    if (file.root != null) await inspectRoot(file.root!);
    return bytes.containsKey(file.locator) ? files[file.locator] : null;
  }

  @override
  Future<LibraryFileReference?> fileInRoot(
    LibraryLocation root,
    LibraryFileReference file,
  ) async {
    if (membershipFailure != null) fail(membershipFailure!);
    await inspectRoot(root);
    final actual = await stat(file);
    return actual?.root?.locator == root.locator ? actual : null;
  }

  @override
  Future<LibraryFingerprint> fingerprint(LibraryFileReference file) async {
    if (await stat(file) == null) fail(LibraryAccessError.missing);
    final content = utf8.encode(bytes[file.locator]!);
    return LibraryFingerprint(content.length, 'fake:${base64Encode(content)}');
  }

  @override
  Future<LibraryCopyReceipt> copyFile(
    LibraryFileReference source,
    LibraryLocation destination,
    String name, {
    required LibraryTransfer transfer,
  }) async {
    transfer.checkCancelled();
    copyCount++;
    if (copyFailure != null) fail(copyFailure!);
    if (copyCount == failCopyNumber) fail(LibraryAccessError.io);
    final content = bytes[source.locator] ?? fail(LibraryAccessError.missing);
    final actualName = renameCopies ? 'provider-$copyCount.txt' : name;
    if ((await list(destination)).any((file) => file.name == actualName)) {
      fail(LibraryAccessError.collision);
    }
    final file = addFile(
      copyKeys.isEmpty ? 'Opaque:$copyCount' : copyKeys.removeAt(0),
      actualName,
      content,
      root: destination,
    );
    final fingerprint = await this.fingerprint(file);
    await beforeCopyReturn?.call();
    return LibraryCopyReceipt(
      file: file,
      fingerprint: corruptReceipt
          ? const LibraryFingerprint(0, 'bad')
          : fingerprint,
    );
  }

  @override
  Future<void> deleteFile(LibraryFileReference file) async {
    if (failDelete) fail(LibraryAccessError.io);
    if (file.root == null || file.directory) {
      fail(LibraryAccessError.permission);
    }
    deleted.add(file);
    bytes.remove(file.locator);
    files.remove(file.locator);
  }

  @override
  Future<LibraryReadLease> acquireRead(LibraryFileReference file) =>
      throw UnimplementedError('No fake reader evidence');
}
