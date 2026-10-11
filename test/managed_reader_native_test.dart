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
