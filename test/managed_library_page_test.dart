import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/platform_library_access.dart';
import 'package:liber/main.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';
import 'package:drift/drift.dart' show Value;

import 'managed_library_test.dart' show MemoryLibraryAccess;
import 'temp_directory.dart';

/// Picker choices and document IO are injected; the page and SQLite publication
/// are real. These tests do not establish native picker/provider execution.
class PickerAccess extends PlatformLibraryAccess {
  PickerAccess(this.memory);
  final MemoryLibraryAccess memory;
  LibraryLocation? selectedDirectory;
  List<LibraryFileReference>? selectedFiles;
  final directoryEntries = <String, List<LibraryFileReference>>{};

  @override
  Future<LibraryLocation?> pickDirectory() async => selectedDirectory;
  @override
  Future<List<LibraryFileReference>?> pickFiles() async => selectedFiles;
  @override
  Future<LibraryLocation> inspectRoot(
    LibraryLocation root, {
    bool writable = false,
  }) => memory.inspectRoot(root, writable: writable);
  @override
  Future<List<LibraryFileReference>> list(
    LibraryLocation root, {
    LibraryFileReference? directory,
  }) async =>
      directory != null && directoryEntries.containsKey(directory.locator)
      ? List.of(directoryEntries[directory.locator]!)
      : await memory.list(root, directory: directory);
  @override
  Future<LibraryFileReference?> stat(LibraryFileReference file) =>
      memory.stat(file);
  @override
  Future<LibraryFileReference?> fileInRoot(
    LibraryLocation root,
    LibraryFileReference file,
  ) => memory.fileInRoot(root, file);
  @override
  Future<LibraryFingerprint> fingerprint(LibraryFileReference file) =>
      memory.fingerprint(file);
  @override
  Future<LibraryCopyReceipt> copyFile(
    LibraryFileReference source,
    LibraryLocation destination,
    String name, {
    required LibraryTransfer transfer,
  }) => memory.copyFile(source, destination, name, transfer: transfer);
  @override
  Future<void> deleteFile(LibraryFileReference file) => memory.deleteFile(file);
  @override
  Future<LibraryReadLease> acquireRead(LibraryFileReference file) =>
      memory.acquireRead(file);
}

Future<void> waitFor(WidgetTester tester, bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (!condition() && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
    await tester.pump();
  }
  expect(
    condition(),
    isTrue,
    reason: 'The driven library page did not reach its expected state',
  );
}

Finder get importButton =>
    find.widgetWithText(FilledButton, 'Import local books');
bool idle(WidgetTester tester) =>
    importButton.evaluate().isNotEmpty &&
    tester.widget<FilledButton>(importButton).onPressed != null;

Future<SpaceStore> openPage(
  WidgetTester tester,
  Directory scratch,
  PickerAccess access,
) async {
  await tester.pumpWidget(
    LiberApp(
      workspaceRoot: scratch,
      interfaceLanguage: const Locale('en'),
      libraryAccess: access,
    ),
  );
  await tester.pump();
  await tester.tap(find.text('Local library'));
  await tester.pump();
  await waitFor(tester, () => idle(tester));
  return (await Workspace.open(root: scratch)).openSpace();
}

Future<void> importCurrentSelection(WidgetTester tester) async {
  await tester.tap(importButton);
  await tester.pump();
  await waitFor(tester, () => idle(tester));
}

void main() {
  late Directory scratch;
  setUp(
    () async =>
        scratch = await Directory.systemTemp.createTemp('liber-library-ui-'),
  );
  tearDown(() => deleteTempDirectory(scratch));

  testWidgets(
    'shelf removal hides the book while retaining its file and progress',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final io = MemoryLibraryAccess();
        final access = PickerAccess(io)..selectedDirectory = io.addRoot('one');
        access.selectedFiles = [
          io.addFile('source-one', 'book.txt', 'first version'),
        ];
        final store = await openPage(tester, scratch, access);
        try {
          await importCurrentSelection(tester);
          final book = (await store.localBooks()).single;
          await store.putProgress(
            ProgressCompanion(
              bookId: Value(book.id),
              textOffset: const Value(8),
            ),
          );
          final managedFile = (await store.localFile(
            book.rootId!,
            book.relativePath!,
          ))!;
          final menu = find.byType(PopupMenuButton<String>);
          await tester.ensureVisible(menu.last);
          await tester.pump();
          await tester.tap(menu.last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('Remove from the shelf (progress kept)'));
          await tester.pump();
          await waitFor(tester, () => idle(tester));
          expect((await store.bookById(book.id))!.shelved, isFalse);
          await tester.tap(find.text('Bookshelf'));
          await tester.pump(const Duration(milliseconds: 350));
          await Future<void>.delayed(const Duration(milliseconds: 60));
          await tester.pump();
          expect(
            find.text(book.title),
            findsNothing,
            reason: 'Removed books cannot still be listed on the bookshelf',
          );
          expect(await store.bookById(book.id), isNotNull);
          expect((await store.progressOf(book.id))!.textOffset, 8);
          expect(io.bytes[managedFile.locator], 'first version');
          expect(io.deleted, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await store.close();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      });
    },
  );

  testWidgets('recursive discovery finds nested books without importing them', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final io = MemoryLibraryAccess();
      final root = io.addRoot('one');
      final folder = LibraryFileReference(
        kind: root.kind,
        locator: '${root.locator}/nested',
        key: 'nested',
        name: 'nested',
        directory: true,
        root: root,
      );
      io.files[folder.locator] = folder;
      io.bytes[folder.locator] = '';
      final book = io.addFile(
        'nested/book.txt',
        'nested-book.txt',
        'nested book',
        root: root,
      );
      io.nestedFiles.add(book.locator);
      final access = PickerAccess(io)..selectedDirectory = root;
      access.directoryEntries[folder.locator] = [book];
      final store = await openPage(tester, scratch, access);
      try {
        await tester.tap(find.text('Choose library folder'));
        await tester.pump();
        await waitFor(
          tester,
          () => idle(tester) && find.text('nested').evaluate().isNotEmpty,
        );
        expect(find.text('nested-book.txt'), findsNothing);
        await tester.tap(find.text('Scan this folder recursively'));
        await tester.pump();
        await waitFor(
          tester,
          () =>
              idle(tester) &&
              find.text('nested-book.txt').evaluate().isNotEmpty,
        );
        expect(await store.localBooks(), isEmpty);
        expect(io.copyCount, 0);
        expect(io.bytes[book.locator], 'nested book');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await store.close();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    });
  });

  for (final choice in ['Cancel', 'Keep both', 'Update this book (replace)']) {
    testWidgets('historical file dialog handles $choice explicitly', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final io = MemoryLibraryAccess();
        final access = PickerAccess(io)..selectedDirectory = io.addRoot('one');
        final source = io.addFile('source-one', 'book.txt', 'first version');
        access.selectedFiles = [source];
        final store = await openPage(tester, scratch, access);
        try {
          await importCurrentSelection(tester);
          final first = (await store.localBooks()).single;
          final retained = (await store.localFile(
            first.rootId!,
            first.relativePath!,
          ))!;
          await store.putProgress(
            ProgressCompanion(
              bookId: Value(first.id),
              textOffset: const Value(240),
              updatedAt: const Value(99),
            ),
          );
          final savedProgress = await store.progressOf(first.id);
          final newer = io.addFile(
            'source-two',
            'book.txt',
            'different content',
          );
          access.selectedFiles = [newer];
          await tester.tap(importButton);
          await tester.pump();
          await waitFor(
            tester,
            () => find.byType(AlertDialog).evaluate().isNotEmpty,
          );
          expect(
            find.text('Different content with the same name'),
            findsOneWidget,
          );
          await tester.tap(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.text('Update this book (replace)'),
            ),
          );
          await tester.pump();
          await waitFor(tester, () => idle(tester));
          final currentA = (await store.bookById(first.id))!;
          final currentFile = (await store.localFile(
            currentA.rootId!,
            currentA.relativePath!,
          ))!;
          final copiesBefore = io.copyCount;

          access.selectedFiles = [io.files[retained.locator]!];
          await tester.tap(importButton);
          await tester.pump();
          await waitFor(
            tester,
            () => find.byType(AlertDialog).evaluate().isNotEmpty,
          );
          expect(
            find.text('File from a previous book location'),
            findsOneWidget,
          );
          expect(find.textContaining('save a separate copy'), findsOneWidget);
          expect(find.textContaining('old version'), findsNothing);
          expect(
            io.copyCount,
            copiesBefore,
            reason: 'History needs a choice before copying',
          );
          final dialog = find.byType(AlertDialog);
          for (final label in [
            'Cancel',
            'Keep both',
            'Update this book (replace)',
          ]) {
            expect(
              find.descendant(of: dialog, matching: find.text(label)),
              findsOneWidget,
            );
          }
          await tester.tap(
            find.descendant(of: dialog, matching: find.text(choice)),
          );
          await tester.pump();
          await waitFor(tester, () => idle(tester));

          final books = await store.localBooks();
          final afterA = (await store.bookById(first.id))!;
          if (choice == 'Keep both') {
            expect(books, hasLength(2));
            expect(afterA, currentA);
            final b = books.singleWhere((book) => book.id != first.id);
            final bFile = (await store.localFile(b.rootId!, b.relativePath!))!;
            expect(bFile.locator, isNot(retained.locator));
            expect(bFile.locator, isNot(currentFile.locator));
            expect(io.bytes[bFile.locator], 'first version');
          } else if (choice == 'Update this book (replace)') {
            expect(books.single.id, first.id);
            final updatedFile = (await store.localFile(
              afterA.rootId!,
              afterA.relativePath!,
            ))!;
            expect(updatedFile.locator, isNot(retained.locator));
            expect(io.bytes[updatedFile.locator], 'first version');
          } else {
            expect(books.single, currentA);
          }
          expect(io.copyCount, copiesBefore + (choice == 'Cancel' ? 0 : 1));
          expect(await store.progressOf(first.id), savedProgress);
          expect(
            (await store.localBookByOriginalKey(
              first.rootId!,
              first.relativePath!,
            ))!.id,
            first.id,
          );
          expect(io.bytes[retained.locator], 'first version');
          expect(io.bytes[currentFile.locator], 'different content');
          expect(io.bytes[source.locator], 'first version');
          expect(io.bytes[newer.locator], 'different content');
          expect(io.deleted, isEmpty);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await store.close();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      });
    });
  }

  testWidgets(
    'update conflict preserves the existing book and reading progress',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        final io = MemoryLibraryAccess();
        final access = PickerAccess(io)..selectedDirectory = io.addRoot('one');
        final original = io.addFile('source-one', 'book.txt', 'first version');
        access.selectedFiles = [original];
        final store = await openPage(tester, scratch, access);
        try {
          await importCurrentSelection(tester);
          final first = (await store.localBooks()).single;
          await store.putProgress(
            ProgressCompanion(
              bookId: Value(first.id),
              textOffset: const Value(240),
              updatedAt: const Value(99),
            ),
          );
          final updated = io.addFile(
            'source-two',
            'book.txt',
            'a newer version',
          );
          access.selectedFiles = [updated];
          await tester.tap(importButton);
          await tester.pump();
          await waitFor(
            tester,
            () => find
                .text('Different content with the same name')
                .evaluate()
                .isNotEmpty,
          );
          expect(find.text('Keep both'), findsOneWidget);
          expect(find.text('Cancel'), findsWidgets);
          await tester.tap(find.text('Update this book (replace)'));
          await tester.pump();
          await waitFor(tester, () => idle(tester));
          final books = await store.localBooks();
          expect(books, hasLength(1));
          expect(books.single.id, first.id);
          expect((await store.progressOf(first.id))!.textOffset, 240);
          expect(books.single.relativePath, isNot(first.relativePath));
          expect(io.bytes[original.locator], 'first version');
          expect(io.bytes[updated.locator], 'a newer version');
          expect(io.copyCount, 2);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
          await store.close();
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }
      });
    },
  );

  testWidgets('directory migration offers separate exact old-copy cleanup', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      final io = MemoryLibraryAccess();
      final access = PickerAccess(io)..selectedDirectory = io.addRoot('one');
      final original = io.addFile('source', 'book.txt', 'retained original');
      access.selectedFiles = [original];
      final store = await openPage(tester, scratch, access);
      try {
        await importCurrentSelection(tester);
        final first = (await store.localBooks()).single;
        final firstFile = (await store.localFile(
          first.rootId!,
          first.relativePath!,
        ))!;
        final two = io.addRoot('two');
        access.selectedDirectory = two;
        await tester.tap(find.text('Change library folder'));
        await tester.pump();
        await waitFor(
          tester,
          () => find.text('Delete the old copies?').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Keep old copies'));
        await tester.pump();
        await waitFor(tester, () => idle(tester));
        final second = (await store.localBooks()).single;
        expect(second.id, first.id);
        expect(second.rootId, first.rootId);
        expect(io.bytes.containsKey(firstFile.locator), isTrue);
        expect(io.deleted, isEmpty);
        final secondFile = (await store.localFile(
          second.rootId!,
          second.relativePath!,
        ))!;
        final unrelated = io.addFile(
          'unrelated',
          'unrelated.txt',
          'unrelated bytes',
          root: two,
        );
        access.selectedDirectory = io.addRoot('three');
        await tester.tap(find.text('Change library folder'));
        await tester.pump();
        await waitFor(
          tester,
          () => find.text('Delete the old copies?').evaluate().isNotEmpty,
        );
        await tester.tap(find.text('Delete old copies'));
        await tester.pump();
        await waitFor(tester, () => idle(tester));
        final third = (await store.localBooks()).single;
        expect(third.id, first.id);
        expect(third.rootId, first.rootId);
        expect(
          (await store.allLocalRoots())
              .singleWhere((r) => r.id == third.rootId)
              .locator,
          'tree:three',
        );
        expect(io.deleted.map((file) => file.locator), [secondFile.locator]);
        expect(io.bytes.containsKey(firstFile.locator), isTrue);
        expect(io.bytes[unrelated.locator], 'unrelated bytes');
        expect(io.bytes[original.locator], 'retained original');
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await store.close();
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    });
  });
}
