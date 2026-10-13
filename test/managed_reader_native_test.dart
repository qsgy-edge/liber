import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/filesystem_library_access.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/local_library.dart';

import 'local_reader_support.dart' show novelText;
import 'native_library.dart';
import 'space_test_support.dart';

LibraryLocation location(Directory directory) => LibraryLocation(
  kind: LibraryLocationKind.filesystem,
  locator: directory.path,
  identity: directory.path,
  displayName: directory.path,
);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'retained native copies keep independent reading and backup identities',
    () async {
      final space = await TestSpace.create();
      try {
        const access = FileSystemLibraryAccess();
        final firstFolder = await Directory(
          '${space.directory.path}/library',
        ).create();
        final secondFolder = await Directory(
          '${space.directory.path}/moved',
        ).create();
        final download = await Directory(
          '${space.directory.path}/download',
        ).create();
        final source = File('${download.path}/book.txt');
        final oldText = novelText(chapters: 12, paragraphs: 8, repeats: 4);
        final aText = 'A 新版前言\n' * 20 + oldText;
        await source.writeAsString(oldText);
        var library = LocalLibrary(space.store, access: access);
        await library.load();
        await library.selectLocation(
          location(firstFolder),
          transfer: LibraryTransfer(id: 'retained-root'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        );
        final firstA = (await library.importFiles(
          [await access.source(source.path)],
          transfer: LibraryTransfer(id: 'retained-first-a'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        )).single;
        final originalKey = firstA.relativePath!;
        await source.writeAsString(aText);
        final a = (await library.importFiles(
          [await access.source(source.path)],
          transfer: LibraryTransfer(id: 'retained-update-a'),
          resolveConflict: (_) async => LibraryConflictChoice.update,
        )).single;
        expect(a.id, firstA.id);
        expect(await File(firstA.path).readAsString(), oldText);
        final b = (await library.importFiles(
          [await access.source(firstA.path)],
          transfer: LibraryTransfer(id: 'retained-keep-b'),
          resolveConflict: (conflict) async {
            expect(conflict.historicalAssociation, isTrue);
            expect(conflict.existingBookId, a.id);
            return LibraryConflictChoice.keepBoth;
          },
        )).single;
        expect(b.id, isNot(a.id));
        expect(b.path, isNot(firstA.path));
        expect(b.path, isNot(a.path));
        expect(await File(b.path).readAsString(), oldText);

        LocalReader readerFor(LocalBook book) => LocalReader(
          library: library,
          book: book,
          engine: NativeReaderEngine(
            acquireRead: () async =>
                access.acquireRead((await library.statBook(book))!),
          ),
        );
        final aReader = readerFor(a);
        await aReader.open();
        await aReader.next();
        expect(aReader.error, isNull);
        final aProgress = await space.store.progressOf(a.id);
        final bReader = readerFor(b);
        await bReader.open();
        await bReader.next();
        await bReader.next();
        expect(bReader.error, isNull);
        final bProgress = (await space.store.progressOf(b.id))!;
        expect(bProgress.textOffset, greaterThan(0));

        // A differently named independent copy can be addressed by its actual
        // filename, without changing A's logical source name or old alias.
        final bDownload = File(
          '${download.path}/${File(b.path).uri.pathSegments.last}',
        );
        final bPrefix = 'B 修订前言\n' * 30;
        await bDownload.writeAsString(bPrefix + oldText);
        final updatedB = (await library.importFiles(
          [await access.source(bDownload.path)],
          transfer: LibraryTransfer(id: 'retained-update-b'),
          resolveConflict: (conflict) async {
            expect(conflict.existingBookId, b.id);
            return LibraryConflictChoice.update;
          },
        )).single;
        expect(updatedB.id, b.id);
        expect(await space.store.progressOf(a.id), aProgress);
        expect(await space.store.progressOf(b.id), bProgress);
        final bRestored = readerFor(updatedB);
        await bRestored.open();
        expect(bRestored.error, isNull);
        expect(
          bRestored.position!.textOffset,
          bProgress.textOffset + bPrefix.length,
        );
        expect(bRestored.position!.textLength, oldText.length + bPrefix.length);

        final migration = await library.selectLocation(
          location(secondFolder),
          transfer: LibraryTransfer(id: 'retained-move'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        );
        expect(migration.previousFiles, hasLength(2));
        await library.deletePreviousCopies(migration);
        expect(await File(firstA.path).readAsString(), oldText);
        expect(await File(b.path).readAsString(), oldText);
        expect(await File(a.path).exists(), isFalse);
        expect(await File(updatedB.path).exists(), isFalse);
        expect(
          (await space.store.localBookByOriginalKey(a.rootId, originalKey))!.id,
          a.id,
        );
        await space.reopen();
        library = LocalLibrary(space.store, access: access);
        await library.load();
        expect(library.books, hasLength(2));
        final afterA = library.books.singleWhere((book) => book.id == a.id);
        final afterB = library.books.singleWhere((book) => book.id == b.id);
        final restartedB = readerFor(afterB);
        await restartedB.open();
        expect(restartedB.error, isNull);
        expect(restartedB.position!.textOffset, bRestored.position!.textOffset);
        expect(restartedB.text, bRestored.text);
        expect(await space.store.progressOf(a.id), aProgress);
        await library.deleteBookFile(b.id);
        expect(await File(afterB.path).exists(), isFalse);
        expect(await File(afterA.path).readAsString(), aText);
        expect(await File(firstA.path).readAsString(), oldText);
        expect(await bDownload.readAsString(), bPrefix + oldText);
        expect(
          (await space.store.localBookByOriginalKey(a.rootId, originalKey))!.id,
          a.id,
        );
      } finally {
        await space.delete();
      }
    },
  );

  test(
    'managed copy update and relocation restore the real reader after restart',
    () async {
      final space = await TestSpace.create();
      try {
        const access = FileSystemLibraryAccess();
        final firstFolder = await Directory(
          '${space.directory.path}/library',
        ).create();
        final secondFolder = await Directory(
          '${space.directory.path}/relocated',
        ).create();
        final download = await Directory(
          '${space.directory.path}/download',
        ).create();
        final source = File('${download.path}/book.txt');
        final text = novelText(chapters: 48, paragraphs: 9, repeats: 5);
        await source.writeAsString(text);
        var library = LocalLibrary(space.store, access: access);
        await library.load();
        await library.selectLocation(
          location(firstFolder),
          transfer: LibraryTransfer(id: 'native-first-location'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        );
        final first = (await library.importFiles(
          [await access.source(source.path)],
          transfer: LibraryTransfer(id: 'native-first-import'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        )).single;
        await source.delete();
        LocalReader readerFor(LocalBook book) => LocalReader(
          library: library,
          book: book,
          engine: NativeReaderEngine(
            acquireRead: () async =>
                access.acquireRead((await library.statBook(book))!),
          ),
        );
        final reader = readerFor(first);
        await reader.open();
        expect(reader.error, isNull);
        expect(reader.text, text.substring(0, reader.pageCodeUnits));
        await reader.next();
        final saved = (await library.progressRecordOf(first.id))!;
        expect(saved.textOffset, greaterThan(0));
        final prefix = '新版增加的前言\n' * 40;
        await source.writeAsString(prefix + text);
        final updated = (await library.importFiles(
          [await access.source(source.path)],
          transfer: LibraryTransfer(id: 'native-update'),
          resolveConflict: (_) async => LibraryConflictChoice.update,
        )).single;
        expect(updated.id, first.id);
        expect(updated.path, isNot(first.path));
        expect(await File(first.path).readAsString(), text);
        expect(await source.readAsString(), prefix + text);
        final reopened = readerFor(updated);
        await reopened.open();
        expect(reopened.error, isNull);
        expect(
          reopened.notices,
          contains(LocalReaderNotice.readerRestoreRelocated),
        );
        expect(reopened.position!.textOffset, saved.textOffset + prefix.length);
        expect(reopened.position!.textLength, prefix.length + text.length);
        final migration = await library.selectLocation(
          location(secondFolder),
          transfer: LibraryTransfer(id: 'native-relocation'),
          resolveConflict: (_) async => LibraryConflictChoice.cancel,
        );
        expect(migration.previousFiles, hasLength(1));
        final moved = library.books.single;
        expect(moved.id, first.id);
        expect(moved.rootId, first.rootId);
        expect(await File(updated.path).readAsString(), prefix + text);
        await library.deletePreviousCopies(migration);
        expect(await File(updated.path).exists(), isFalse);
        expect(await File(moved.path).readAsString(), prefix + text);
        // Only the migration's exact superseded copy is removed. The retained
        // earlier version and independently downloaded source are untouched.
        expect(await File(first.path).readAsString(), text);
        expect(await source.readAsString(), prefix + text);
        await space.reopen();
        library = LocalLibrary(space.store, access: access);
        await library.load();
        final afterRestart = readerFor(library.books.single);
        await afterRestart.open();
        expect(afterRestart.error, isNull);
        expect(afterRestart.notices, isEmpty);
        expect(
          afterRestart.position!.textOffset,
          reopened.position!.textOffset,
        );
        expect(afterRestart.text, reopened.text);
        expect(library.books.single.id, first.id);
        expect(await source.readAsString(), prefix + text);
      } finally {
        await space.delete();
      }
    },
  );
}
