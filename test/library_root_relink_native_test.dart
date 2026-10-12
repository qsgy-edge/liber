import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/filesystem_library_access.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/local_library.dart';
import 'package:path/path.dart' as p;

import 'local_reader_support.dart' show novelText;
import 'native_library.dart';
import 'space_test_support.dart';

LibraryLocation _location(Directory directory) => LibraryLocation(
  kind: LibraryLocationKind.filesystem,
  locator: directory.path,
  identity: directory.path,
  displayName: directory.path,
);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  for (final alreadyInLibrary in [false, true]) {
    test(
      'reselecting an externally renamed ${alreadyInLibrary ? 'admitted' : 'copied'} library restores reader and metadata after restart',
      () async {
        final space = await TestSpace.create();
        try {
          const access = FileSystemLibraryAccess();
          var library = LocalLibrary(space.store, access: access);
          final oldDirectory = await Directory(
            p.join(space.directory.path, 'books'),
          ).create();
          await library.selectLocation(
            _location(oldDirectory),
            transfer: LibraryTransfer(id: 'select-before-rename'),
            resolveConflict: (_) async => LibraryConflictChoice.cancel,
          );
          final sourceDirectory = await Directory(
            p.join(
              alreadyInLibrary ? oldDirectory.path : space.directory.path,
              'nested',
            ),
          ).create();
          final source = await File(
            p.join(sourceDirectory.path, 'book.txt'),
          ).writeAsString(novelText(chapters: 12, paragraphs: 9, repeats: 3));
          final first = (await library.importFiles(
            [await access.source(source.path)],
            transfer: LibraryTransfer(id: 'import-before-rename'),
            resolveConflict: (_) async => LibraryConflictChoice.cancel,
          )).single;
          if (!alreadyInLibrary) await source.delete();
          await space.store.putSetting(
            'reader.script',
            'traditionalTaiwan',
            bookId: first.id,
          );
          await space.store.db
              .into(space.store.db.groups)
              .insert(
                GroupsCompanion.insert(id: 'kept-group', name: 'Kept group'),
              );
          await space.store.db
              .into(space.store.db.bookGroups)
              .insert(
                BookGroupsCompanion.insert(
                  bookId: first.id,
                  groupId: 'kept-group',
                ),
              );
          LocalReader readerFor(LocalBook book) => LocalReader(
            library: library,
            book: book,
            pageCodeUnits: 512,
            engine: NativeReaderEngine(
              acquireRead: () async =>
                  access.acquireRead((await library.statBook(book))!),
            ),
          );
          final reader = readerFor(first);
          await reader.open();
          await reader.next();
          expect(reader.error, isNull);
          final progress = await space.store.progressOf(first.id);
          expect(progress!.textOffset, greaterThan(0));
          final bookBefore = await space.store.bookById(first.id);
          final fileBefore = await space.store.localFile(
            first.rootId,
            first.relativePath!,
          );
          final indexBefore = await space.store.textIndexOf(
            first.rootId,
            first.relativePath!,
          );
          final bytesBefore = await File(first.path).readAsBytes();
          await space.store.setShelved(first.id, false);
          final renamed = await oldDirectory.rename(
            p.join(space.directory.path, 'renamed'),
          );
          await library.load();
          expect(await library.statBook(library.books.single), isNull);
          final migration = await library.selectLocation(
            _location(renamed),
            transfer: LibraryTransfer(id: 'reselect-renamed'),
            resolveConflict: (_) async =>
                throw StateError('Relink must not ask to overwrite'),
          );
          expect(migration.previousFiles, isEmpty);
          expect(migration.root.id, first.rootId);
          expect(migration.root.locator, await renamed.resolveSymbolicLinks());
          final restored = library.books.single;
          expect(restored.id, first.id);
          expect(restored.relativePath, first.relativePath);
          expect(await File(restored.path).readAsBytes(), bytesBefore);
          expect(await space.store.progressOf(first.id), progress);
          final after = (await space.store.bookById(first.id))!;
          expect(after.charset, bookBefore!.charset);
          expect(after.originalRootId, bookBefore.originalRootId);
          expect(after.originalRelativePath, bookBefore.originalRelativePath);
          expect(after.shelved, isFalse);
          expect(after.needsRelink, isFalse);
          final fileAfter = (await space.store.localFile(
            first.rootId,
            first.relativePath!,
          ))!;
          expect(fileAfter.sha256, fileBefore!.sha256);
          expect(fileAfter.textLength, fileBefore.textLength);
          expect(
            await space.store.textIndexOf(first.rootId, first.relativePath!),
            indexBefore,
          );
          expect(
            await space.store.setting('reader.script', bookId: first.id),
            'traditionalTaiwan',
          );
          expect(
            (await space.store.db.select(space.store.db.bookGroups).getSingle())
                .groupId,
            'kept-group',
          );
          await space.reopen();
          library = LocalLibrary(space.store, access: access);
          await library.load();
          final afterRestart = readerFor(library.books.single);
          await afterRestart.open();
          expect(afterRestart.error, isNull);
          expect(
            afterRestart.position!.textOffset,
            reader.position!.textOffset,
          );
          expect(afterRestart.text, reader.text);
          expect(await space.store.progressOf(first.id), progress);
        } finally {
          await space.delete();
        }
      },
    );
  }

  for (final problem in ['different bytes', 'missing file', 'unknown hash']) {
    test(
      'renamed library with $problem does not publish guessed file associations',
      () async {
        final space = await TestSpace.create();
        try {
          const access = FileSystemLibraryAccess();
          final library = LocalLibrary(space.store, access: access);
          final oldDirectory = await Directory(
            p.join(space.directory.path, 'books'),
          ).create();
          await library.selectLocation(
            _location(oldDirectory),
            transfer: LibraryTransfer(id: 'select-negative'),
            resolveConflict: (_) async => LibraryConflictChoice.cancel,
          );
          final originals = await Directory(
            p.join(space.directory.path, 'originals'),
          ).create();
          for (final name in ['one.txt', 'two.md']) {
            final source = await File(
              p.join(originals.path, name),
            ).writeAsString('original $name');
            await library.importFiles(
              [await access.source(source.path)],
              transfer: LibraryTransfer(id: 'import-$name'),
              resolveConflict: (_) async => LibraryConflictChoice.cancel,
            );
          }
          if (problem == 'unknown hash') {
            final first = library.books.first;
            await space.store.putLocalFile(
              LocalFilesCompanion(
                rootId: Value(first.rootId),
                relativePath: Value(first.relativePath!),
                sha256: const Value(null),
              ),
            );
          }
          final rootsBefore = await space.store.allLocalRoots();
          final booksBefore = await space.store.localBooks();
          final filesBefore = await space.store.localFilesOf(
            library.managedRoot!.id,
          );
          final renamed = await oldDirectory.rename(
            p.join(space.directory.path, 'renamed'),
          );
          final changed = File(p.join(renamed.path, 'two.md'));
          if (problem == 'different bytes')
            await changed.writeAsString('unrelated same-name book');
          if (problem == 'missing file') await changed.delete();
          final selectedFilesBefore = await renamed.list().toList();
          await expectLater(
            library.selectLocation(
              _location(renamed),
              transfer: LibraryTransfer(id: 'negative-reselect'),
              resolveConflict: (_) async =>
                  throw StateError('Relink is not an overwrite decision'),
            ),
            throwsA(isA<LibraryAccessFailure>()),
          );
          expect(await space.store.allLocalRoots(), rootsBefore);
          expect(await space.store.localBooks(), booksBefore);
          expect(
            await space.store.localFilesOf(library.managedRoot!.id),
            filesBefore,
          );
          expect(
            (await renamed.list().toList()).map((file) => file.path).toSet(),
            selectedFilesBefore.map((file) => file.path).toSet(),
          );
          for (final file in await originals.list().toList()) {
            expect(
              await File(file.path).readAsString(),
              'original ${p.basename(file.path)}',
            );
          }
        } finally {
          await space.delete();
        }
      },
    );
  }
  for (final problem in ['other owner', 'cancelled', 'database rollback']) {
    test(
      'reselecting an unavailable root refuses $problem without publication',
      () async {
        final space = await TestSpace.create();
        try {
          final access = _ControlledAccess();
          final library = LocalLibrary(space.store, access: access);
          final old = await Directory(
            p.join(space.directory.path, 'books'),
          ).create();
          await library.selectLocation(
            _location(old),
            transfer: LibraryTransfer(id: 'select-controlled'),
            resolveConflict: (_) async => LibraryConflictChoice.cancel,
          );
          final source = await File(
            p.join(space.directory.path, 'original.txt'),
          ).writeAsString('verified original contents');
          final first = (await library.importFiles(
            [await access.source(source.path)],
            transfer: LibraryTransfer(id: 'import-controlled'),
            resolveConflict: (_) async => LibraryConflictChoice.cancel,
          )).single;
          final renamed = await old.rename(
            p.join(space.directory.path, 'renamed'),
          );
          if (problem == 'other owner') {
            final actual = await access.inspectRoot(_location(renamed));
            await space.store.putLocalRoot(
              LocalRootsCompanion.insert(
                id: 'other-root',
                displayName: actual.displayName,
                locator: Value(actual.locator),
                identity: Value(actual.identity),
              ),
            );
            await space.store.putBook(
              BooksCompanion.insert(
                id: 'other-book',
                title: 'Independent identity',
                kind: const Value('local'),
                rootId: const Value('other-root'),
                relativePath: Value(first.relativePath!),
              ),
            );
            await space.store.putLocalFile(
              LocalFilesCompanion.insert(
                rootId: 'other-root',
                relativePath: first.relativePath!,
                locator: Value(p.join(actual.locator, first.relativePath!)),
                bookId: const Value('other-book'),
              ),
            );
          }
          final rootsBefore = await space.store.allLocalRoots();
          final booksBefore = await space.store.localBooks();
          final filesBefore = await space.store.localFilesOf(first.rootId);
          final transfer = LibraryTransfer(id: 'controlled-reselect');
          if (problem == 'cancelled') access.afterFingerprint = transfer.cancel;
          if (problem == 'database rollback') {
            await space.store.db.customStatement(
              "CREATE TRIGGER deny_relink BEFORE UPDATE ON local_files "
              "BEGIN SELECT RAISE(ABORT, 'forced relink rollback'); END",
            );
          }
          final expected = problem == 'database rollback'
              ? throwsA(isA<Exception>())
              : throwsA(
                  isA<LibraryAccessFailure>().having(
                    (error) => error.code,
                    'code',
                    problem == 'cancelled'
                        ? LibraryAccessError.cancelled
                        : LibraryAccessError.collision,
                  ),
                );
          await expectLater(
            library.selectLocation(
              _location(renamed),
              transfer: transfer,
              resolveConflict: (_) async => LibraryConflictChoice.cancel,
            ),
            expected,
          );
          expect(await space.store.allLocalRoots(), rootsBefore);
          expect(await space.store.localBooks(), booksBefore);
          expect(await space.store.localFilesOf(first.rootId), filesBefore);
          expect(
            await space.store.setting(LocalLibrary.managedRootKey),
            first.rootId,
          );
          expect(
            await File(
              p.join(renamed.path, first.relativePath!),
            ).readAsString(),
            'verified original contents',
          );
          expect(await source.readAsString(), 'verified original contents');
        } finally {
          await space.delete();
        }
      },
    );
  }
}

class _ControlledAccess extends FileSystemLibraryAccess {
  Future<void> Function()? afterFingerprint;

  @override
  Future<LibraryFingerprint> fingerprint(LibraryFileReference file) async {
    final result = await super.fingerprint(file);
    await afterFingerprint?.call();
    return result;
  }
}
