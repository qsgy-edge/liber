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
  }) => memory.list(root, directory: directory);
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
