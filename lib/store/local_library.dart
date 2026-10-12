import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:path/path.dart' as p;

import '../domain/contracts.dart';
import '../local/filesystem_library_access.dart';
import '../local/library_access.dart';
import 'database.dart';
import 'ids.dart';
import 'progress.dart';
import 'space_store.dart';

/// One local file's stored index: the encoding its windows are read with, the
/// sparse line-start anchors, and the decoded length and modification time the
/// change detection compares against (D4/D10).
///
/// A file that was never indexed is the empty index: no encoding, no anchors,
/// no length. Nothing here opens the file.
class LocalFileIndex {
  const LocalFileIndex({
    required this.encoding,
    required this.anchors,
    this.textLength,
    this.modifiedAt,
  });

  final String encoding;
  final List<TextIndexAnchor> anchors;

  /// The file's length in code units — cached, so nothing reads a whole file to
  /// clamp an offset (D4).
  final int? textLength;

  /// The modification time the index was written against.
  final int? modifiedAt;

  /// Whether this index still describes the file as [currentModifiedAt] left
  /// it. The modification time is the cheap check that decides whether the
  /// anchors, the length and the encoding may be trusted at all; the anchor
  /// itself is what the reader's first restore tier verifies.
  bool describes(int? currentModifiedAt) =>
      currentModifiedAt != null &&
      encoding.isNotEmpty &&
      anchors.isNotEmpty &&
      textLength != null &&
      modifiedAt == currentModifiedAt;
}

enum LibraryConflictChoice { update, keepBoth, cancel }

class LibraryImportConflict {
  const LibraryImportConflict({
    required this.source,
    required this.existing,
    required this.name,
    this.existingBookId,
    this.incomingBookId,
  });
  final LibraryFileReference source;
  final LibraryFileReference existing;
  final String name;
  final String? existingBookId;
  final String? incomingBookId;
  bool get canUpdate =>
      incomingBookId == null ||
      existingBookId == null ||
      existingBookId == incomingBookId;
}

class LibraryPreviousFile {
  const LibraryPreviousFile({required this.file, required this.fingerprint});
  final LibraryFileReference file;
  final LibraryFingerprint fingerprint;
}

final class LibraryMigrationResult {
  LibraryMigrationResult._(
    this._owner, {
    required this.root,
    required List<LibraryPreviousFile> previousFiles,
  }) : previousFiles = List.unmodifiable(previousFiles);
  final LocalRoot root;
  final List<LibraryPreviousFile> previousFiles;
  final LocalLibrary _owner;
}

typedef LibraryConflictResolver =
    Future<LibraryConflictChoice> Function(LibraryImportConflict);

/// One space's managed library and its older external references. Bytes are
/// verified before a single store publication; old bytes survive publication.
class LocalLibrary {
  LocalLibrary(this.store, {LibraryAccess? access})
    : access = access ?? const FileSystemLibraryAccess();
  final SpaceStore store;
  final LibraryAccess access;
  static const activeRootKey = 'local.active_root';
  static const managedRootKey = 'local.managed_root';
  LocalRoot? _root;
  LocalRoot? _managedRoot;
  String? _currentPath;
  List<LocalBook> _books = const [];
  Future<void> _mutations = Future.value();
  LocalRoot? get root => _root;
  LocalRoot? get managedRoot => _managedRoot;
  LibraryLocation? get managedLocation => _location(_managedRoot);
  String? get currentPath => _currentPath;
  List<LocalBook> get books => List.unmodifiable(_books);

  Future<T> _serialize<T>(Future<T> Function() action) {
    final result = _mutations.then((_) => action());
    _mutations = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return result;
  }

  Future<void> load() => _serialize(_load);

  Future<void> _load() async {
    final managedId = await store.setting(managedRootKey);
    for (final row in await store.allLocalRoots()) {
      final location = _location(row);
      LibraryLocation? actual;
      if (location != null) {
        try {
          actual = await access.inspectRoot(
            location,
            writable: row.id == managedId,
          );
        } on LibraryAccessFailure catch (error) {
          if (!_unreachable(error)) rethrow;
        }
      }
      final refreshed = actual == null
          ? await store.putLocalRoot(
              LocalRootsCompanion(
                id: Value(row.id),
                displayName: Value(row.displayName),
                needsRelink: const Value(true),
              ),
            )
          : await _saveRoot(row.id, actual);
      for (final file in await store.localFilesOf(row.id)) {
        final reference = _reference(refreshed, file.relativePath, file);
        LibraryFileReference? stat;
        if (actual != null && reference != null) {
          try {
            stat = await access.stat(reference);
          } on LibraryAccessFailure catch (error) {
            if (!_unreachable(error)) rethrow;
          }
        }
        await store.transaction(() async {
          await store.putLocalFile(
            LocalFilesCompanion(
              rootId: Value(row.id),
              relativePath: Value(file.relativePath),
              needsRelink: Value(stat == null || stat.directory),
            ),
          );
          if (file.bookId != null) {
            await store.setBookRelink(
              file.bookId!,
              stat == null || stat.directory,
            );
          }
        });
      }
    }
    final roots = await _rootsById();
    for (final book in await store.localBooks()) {
      if (await store.localFile(book.rootId!, book.relativePath!) != null) {
        continue;
      }
      final reference = _reference(
        roots[book.rootId],
        book.relativePath!,
        null,
      );
      LibraryFileReference? stat;
      if (reference != null) {
        try {
          stat = await access.stat(reference);
        } on LibraryAccessFailure catch (error) {
          if (!_unreachable(error)) rethrow;
        }
      }
      await store.setBookRelink(book.id, stat == null || stat.directory);
    }
    await _refresh();
  }

  Future<void> _refresh() async {
    final roots = await _rootsById();
    _managedRoot = roots[await store.setting(managedRootKey)];
    _root =
        roots[await store.setting(activeRootKey)] ??
        _managedRoot ??
        roots.values.firstOrNull;
    final location = _location(_root);
    _currentPath = location?.kind == LibraryLocationKind.filesystem
        ? location!.locator
        : null;
    _books = await _readBooks(roots);
  }

  /// Resolves current DB facts, never the active root or a stale UI path.
  Future<LibraryFileReference?> fileReferenceOf(LocalBook book) async {
    final row = await store.bookById(book.id);
    if (row == null ||
        row.kind != 'local' ||
        row.rootId == null ||
        row.relativePath == null) {
      return null;
    }
    return _reference(
      (await _rootsById())[row.rootId],
      row.relativePath!,
      await store.localFile(row.rootId!, row.relativePath!),
    );
  }

  Future<LibraryFileReference?> statBook(LocalBook book) =>
      _serialize(() async {
        final reference = await fileReferenceOf(book);
        LibraryFileReference? actual;
        if (reference != null) {
          try {
            actual = await access.stat(reference);
          } on LibraryAccessFailure catch (error) {
            if (!_unreachable(error)) rethrow;
          }
        }
        if (actual?.directory == true) actual = null;
        final row = await store.bookById(book.id);
        if (row != null) await _markRelink(row, actual == null);
        return actual;
      });

  Future<LocalRoot> selectRoot(String path) => _serialize(() async {
    if (!p.isAbsolute(path)) {
      throw ArgumentError.value(path, 'path', 'Expected an absolute directory');
    }
    final actual = await access.inspectRoot(
      LibraryLocation(
        kind: LibraryLocationKind.filesystem,
        locator: path,
        identity: path,
        displayName: path,
      ),
    );
    final existing = await _matchingRoot(actual);
    final selected = await _saveRoot(existing?.id ?? mintId('root'), actual);
    await store.putSetting(activeRootKey, selected.id);
    await _load();
    return _root!;
  });

  Future<List<FileSystemEntity>> listCurrentFolder() async {
    final location = _location(_root);
    final path = _currentPath;
    if (location == null) return const [];
    _filesystemLocation(location);
    if (path == null) return const [];
    final entries = await access.list(
      location,
      directory: path == location.locator
          ? null
          : LibraryFileReference(
              kind: location.kind,
              locator: path,
              key: p.relative(path, from: location.locator),
              name: p.basename(path),
              directory: true,
              root: location,
            ),
    );
    return [
      for (final file in entries)
        if (file.directory)
          Directory(file.locator)
        else if (_isSupported(file.name))
          File(file.locator),
    ];
  }

  Future<List<FileSystemEntity>> enterFolder(String path) =>
      _serialize(() async {
        final location = _location(_root);
        if (location == null) return const <FileSystemEntity>[];
        _filesystemLocation(location);
        if (!p.isAbsolute(path) ||
            (path != location.locator && !p.isWithin(location.locator, path))) {
          throw const LibraryAccessFailure(
            LibraryAccessError.permission,
            'Directory is outside the selected root',
          );
        }
        final previous = _currentPath;
        _currentPath = path;
        try {
          return await listCurrentFolder();
        } catch (_) {
          _currentPath = previous;
          rethrow;
        }
      });

  Future<List<FileSystemEntity>> goUp() async {
    final location = _location(_root);
    final current = _currentPath;
    if (location == null || current == null || current == location.locator) {
      return listCurrentFolder();
    }
    return enterFolder(p.dirname(current));
  }

  Future<List<FileSystemEntity>> scanRecursively() async {
    final location = _location(_root);
    if (location == null) return const [];
    _filesystemLocation(location);
    if (_currentPath == null) return const [];
    final files = <FileSystemEntity>[];
    Future<void> walk(LibraryFileReference? directory) async {
      for (final file in await access.list(location, directory: directory)) {
        if (file.directory) {
          await walk(file);
        } else if (_isSupported(file.name)) {
          files.add(File(file.locator));
        }
      }
    }

    await walk(
      _currentPath == location.locator
          ? null
          : LibraryFileReference(
              kind: location.kind,
              locator: _currentPath!,
              key: p.relative(_currentPath!, from: location.locator),
              name: p.basename(_currentPath!),
              directory: true,
              root: location,
            ),
    );
    return files;
  }

  /// Compatibility admission of ordinary files under the browsed root.
  /// Native selections enter through importFiles with their grant intact.
  Future<List<LocalBook>> addFiles(Iterable<FileSystemEntity> entries) =>
      _serialize(() async {
        final root = _root;
        final location = _location(root);
        if (root == null || location == null) return const <LocalBook>[];
        _filesystemLocation(location);
        final ids = <String>[];
        for (final entry in entries) {
          if (entry is! File ||
              !_isSupported(entry.path) ||
              !p.isAbsolute(entry.path)) {
            continue;
          }
          final file = await access.fileInRoot(
            location,
            LibraryFileReference(
              kind: location.kind,
              locator: entry.path,
              key: p.basename(entry.path),
              name: p.basename(entry.path),
            ),
          );
          if (file == null || file.directory) continue;
          final existing = (await _ownersOf(location, [file]))[file.key];
          if (existing?.rootId == root.id &&
              existing?.relativePath == file.key) {
            continue;
          }
          await _checkOriginalAssociation(existing);
          final stored = existing == null
              ? null
              : await store.localFile(existing.rootId!, existing.relativePath!);
          final pending = _PreparedBook(
            file: file,
            name: stored?.importName ?? file.name,
            id: existing?.id ?? mintId('book'),
            existing: existing,
          );
          await store.transaction(() => _publish(root.id, [pending]));
          ids.add(pending.id);
        }
        await _refresh();
        return _books.where((book) => ids.contains(book.id)).toList();
      });

  Future<List<LocalBook>> importFiles(
    Iterable<LibraryFileReference> files, {
    required LibraryTransfer transfer,
    required LibraryConflictResolver resolveConflict,
  }) => _serialize(() async {
    final ids = <String>{};
    for (final file in files) {
      if (file.directory || !_isSupported(file.name)) continue;
      ids.add(await _importOne(file, transfer, resolveConflict));
    }
    await _refresh();
    return _books.where((book) => ids.contains(book.id)).toList();
  });

  Future<List<LocalBook>> adoptBooks(
    Iterable<String> bookIds, {
    required LibraryTransfer transfer,
    required LibraryConflictResolver resolveConflict,
  }) => _serialize(() async {
    final ids = <String>{};
    for (final id in bookIds.toSet()) {
      transfer.checkCancelled();
      final row = await store.bookById(id);
      if (row == null || row.kind != 'local') continue;
      final managedId = await store.setting(managedRootKey);
      if (row.rootId == managedId) {
        ids.add(id);
        continue;
      }
      final book = await _localBook(row, (await _rootsById())[row.rootId]);
      final reference = await fileReferenceOf(book);
      LibraryFileReference? actual;
      if (reference != null) {
        try {
          actual = await access.stat(reference);
        } on LibraryAccessFailure catch (error) {
          if (!_unreachable(error)) rethrow;
        }
      }
      if (actual == null || actual.directory) {
        await _markRelink(row, true);
        continue;
      }
      ids.add(
        await _importOne(actual, transfer, resolveConflict, incoming: row),
      );
    }
    await _refresh();
    return _books.where((book) => ids.contains(book.id)).toList();
  });

  Future<String> _importOne(
    LibraryFileReference source,
    LibraryTransfer transfer,
    LibraryConflictResolver resolver, {
    ShelfBook? incoming,
  }) async {
    transfer.checkCancelled();
    final rootId = await store.setting(managedRootKey);
    final root = (await _rootsById())[rootId];
    final location = _location(root);
    if (root == null || location == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.missing,
        'Select a managed library first',
      );
    }
    final actual = await access.inspectRoot(location, writable: true);
    final candidates = await _candidates(root.id, actual);
    final owned = <LibraryCopyReceipt>[];
    try {
      final pending = await _prepare(
        source,
        actual,
        candidates,
        owned,
        transfer,
        resolver,
        rootId: root.id,
        incoming: incoming,
      );
      transfer.checkCancelled();
      await store.transaction(() async {
        await _saveRoot(root.id, actual);
        await _publish(root.id, [pending]);
        transfer.checkCancelled();
      });
      owned.clear();
      await _refresh();
      return pending.id;
    } catch (error, stack) {
      return _cleanupAndRethrow(owned, error, stack);
    }
  }

  Future<LibraryMigrationResult> selectLocation(
    LibraryLocation location, {
    required LibraryTransfer transfer,
    required LibraryConflictResolver resolveConflict,
  }) => _serialize(() async {
    transfer.checkCancelled();
    final actual = await access.inspectRoot(location, writable: true);
    final roots = await _rootsById();
    final old = roots[await store.setting(managedRootKey)];
    final oldLocation = _location(old);
    LibraryLocation? inspectedOld;
    if (oldLocation != null) {
      try {
        inspectedOld = await access.inspectRoot(oldLocation);
      } on LibraryAccessFailure catch (error) {
        if (!_unreachable(error)) rethrow;
      }
    }
    final same =
        inspectedOld?.sameLocation(actual) == true ||
        (inspectedOld == null &&
            old?.identity != null &&
            oldLocation!.sameLocation(actual));
    final reselectingFilesystem =
        old != null &&
        inspectedOld == null &&
        !same &&
        oldLocation?.kind == LibraryLocationKind.filesystem &&
        actual.kind == LibraryLocationKind.filesystem;
    final id = old?.id ?? (await _matchingRoot(actual))?.id ?? mintId('root');
    final owned = <LibraryCopyReceipt>[];
    final previous = <LibraryPreviousFile>[];
    final pending = <_PreparedBook>[];
    final relinks = <(ShelfBook, bool)>[];
    final reselected = <(ShelfBook, LibraryFileReference)>[];
    try {
      if (old == null || same) {
        final refreshed = LocalRoot(
          id: id,
          displayName: actual.displayName,
          kind: actual.kind.name,
          locator: actual.locator,
          identity: actual.identity,
          authorization: actual.authorization,
          needsRelink: false,
        );
        for (final book in await store.localBooks()) {
          if (book.rootId != id) continue;
          final reference = _reference(
            refreshed,
            book.relativePath!,
            await store.localFile(id, book.relativePath!),
          );
          LibraryFileReference? file;
          if (reference != null) {
            try {
              file = await access.stat(reference);
            } on LibraryAccessFailure catch (error) {
              if (!_unreachable(error)) rethrow;
            }
          }
          relinks.add((book, file == null || file.directory));
        }
      }
      if (reselectingFilesystem) {
        reselected.addAll(await _reselectFilesystem(old, actual, transfer));
      }
      if (old != null && !same && !reselectingFilesystem) {
        final candidates = await _candidates(
          (await _matchingRoot(actual))?.id,
          actual,
        );
        for (final row in await store.localBooks()) {
          if (row.rootId != old.id) continue;
          transfer.checkCancelled();
          final oldFile = await store.localFile(old.id, row.relativePath!);
          final reference = _reference(old, row.relativePath!, oldFile);
          if (reference == null) {
            throw const LibraryAccessFailure(
              LibraryAccessError.missing,
              'Managed book needs relinking',
            );
          }
          final source = await access.stat(reference);
          if (source == null || source.directory) {
            throw const LibraryAccessFailure(
              LibraryAccessError.missing,
              'Managed book is missing',
            );
          }
          final fingerprint = await access.fingerprint(source);
          final prepared = await _prepare(
            source,
            actual,
            candidates,
            owned,
            transfer,
            resolveConflict,
            rootId: id,
            incoming: row,
            name: oldFile?.importName ?? source.name,
          );
          // A nested selected root can already contain a canonical old file.
          if (!_sameFile(source, prepared.file)) {
            previous.add(
              LibraryPreviousFile(file: source, fingerprint: fingerprint),
            );
          }
          pending.add(prepared);
          candidates.removeWhere((candidate) => candidate.book?.id == row.id);
          candidates.add(_LibraryCandidate(prepared.file, prepared.name, row));
        }
      }
      transfer.checkCancelled();
      late LocalRoot selected;
      await store.transaction(() async {
        selected = await _saveRoot(id, actual);
        await _publish(id, pending, shelve: false);
        for (final (book, file) in reselected) {
          // The hash proved unchanged bytes. Keep charset, sparse index,
          // original association and shelf membership; only access facts move.
          await store.putLocalFile(
            LocalFilesCompanion(
              rootId: Value(id),
              relativePath: Value(file.key),
              locator: Value(file.locator),
              name: Value(file.name),
            ),
          );
          await _markRelink(book, false);
        }
        for (final (book, missing) in relinks) {
          await _markRelink(book, missing);
        }
        await store.putSetting(managedRootKey, id);
        await store.putSetting(activeRootKey, id);
        transfer.checkCancelled();
      });
      owned.clear();
      await _refresh();
      return LibraryMigrationResult._(
        this,
        root: selected,
        previousFiles: previous,
      );
    } catch (error, stack) {
      return _cleanupAndRethrow(owned, error, stack);
    }
  });

  /// Explicitly reselects an unavailable filesystem library. A relative key
  /// only locates a candidate: recorded bytes and actual membership must match
  /// before any of the old root/file facts can be published at the new path.
  Future<List<(ShelfBook, LibraryFileReference)>> _reselectFilesystem(
    LocalRoot old,
    LibraryLocation selected,
    LibraryTransfer transfer,
  ) async {
    final refreshed = old.copyWith(
      displayName: selected.displayName,
      kind: selected.kind.name,
      locator: Value(selected.locator),
      identity: Value(selected.identity),
      authorization: Value(selected.authorization),
    );
    final verified = <(ShelfBook, LibraryFileReference)>[];
    for (final book in await store.localBooks()) {
      if (book.rootId != old.id) continue;
      transfer.checkCancelled();
      final key = book.relativePath!;
      final stored = await store.localFile(old.id, key);
      if (stored?.bookId != book.id || stored?.sha256 == null) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Restore the original library: book bytes were not recorded',
        );
      }
      final reference = _reference(
        refreshed,
        key,
        stored!.copyWith(
          locator: Value(p.normalize(p.join(selected.locator, key))),
        ),
      );
      final file = reference == null ? null : await access.stat(reference);
      if (file == null || file.directory) {
        throw const LibraryAccessFailure(
          LibraryAccessError.missing,
          'Selected library is missing a recorded book',
        );
      }
      final member = await access.fileInRoot(selected, file);
      if (member == null || member.key != key || !_sameFile(member, file)) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Selected book membership could not be verified',
        );
      }
      if ((await access.fingerprint(member)).sha256 != stored.sha256) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Selected book differs from the recorded library file',
        );
      }
      transfer.checkCancelled();
      verified.add((book, member));
    }
    final owners = await _ownersOf(selected, [
      for (final (_, file) in verified) file,
    ]);
    for (final (book, file) in verified) {
      final owner = owners[file.key];
      if (owner != null && owner.id != book.id) {
        throw LibraryAccessFailure(
          LibraryAccessError.collision,
          'Selected library file belongs to another book',
          details: {
            'bookIds': [book.id, owner.id],
            'locator': file.locator,
          },
        );
      }
    }
    return verified;
  }

  Future<void> deletePreviousCopies(LibraryMigrationResult migration) =>
      _serialize(() async {
        if (!identical(migration._owner, this)) {
          throw const LibraryAccessFailure(
            LibraryAccessError.permission,
            'Unknown migration cleanup result',
          );
        }
        for (final previous in migration.previousFiles) {
          await _guardPrevious(previous);
        }
        for (final previous in migration.previousFiles) {
          final actual = await _guardPrevious(previous);
          await access.deleteFile(actual);
        }
      });

  Future<LibraryFileReference> _guardPrevious(
    LibraryPreviousFile previous,
  ) async {
    if (previous.file.root == null || previous.file.directory) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'Cleanup requires an exact rooted file',
      );
    }
    final actual = await access.stat(previous.file);
    if (actual == null ||
        actual.directory ||
        actual.key != previous.file.key ||
        !_sameFile(actual, previous.file) ||
        previous.fingerprint.bytes < 0 ||
        previous.fingerprint.sha256.isEmpty) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Previous file identity is unverifiable',
      );
    }
    final roots = await _rootsById();
    for (final row in await store.localBooks()) {
      final file = _reference(
        roots[row.rootId],
        row.relativePath!,
        await store.localFile(row.rootId!, row.relativePath!),
      );
      final current = file == null ? null : await access.stat(file);
      if (current != null && _sameFile(current, actual)) {
        throw const LibraryAccessFailure(
          LibraryAccessError.permission,
          'Cannot delete a current book file',
        );
      }
    }
    for (final root in roots.values) {
      for (final stored in await store.localFilesOf(root.id)) {
        final reference = _reference(root, stored.relativePath, stored);
        final current = reference == null ? null : await access.stat(reference);
        if (current != null && _sameFile(current, actual)) {
          throw const LibraryAccessFailure(
            LibraryAccessError.permission,
            'Cannot delete a current library file',
          );
        }
      }
    }
    if (!(await access.fingerprint(actual)).sameBytes(previous.fingerprint)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Previous file changed; cleanup refused',
      );
    }
    return actual;
  }

  Future<void> deleteBookFile(String bookId) => _serialize(() async {
    final row = await store.bookById(bookId);
    final managedId = await store.setting(managedRootKey);
    if (row == null ||
        managedId == null ||
        row.rootId != managedId ||
        row.relativePath == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'Only managed book files can be deleted',
      );
    }
    final root = (await _rootsById())[managedId];
    final file = await store.localFile(managedId, row.relativePath!);
    final reference = _reference(root, row.relativePath!, file);
    if (file?.bookId != bookId || reference == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'No canonical managed book file',
      );
    }
    final actual = await access.stat(reference);
    if (actual != null) {
      if (actual.directory || !_sameFile(actual, reference)) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Managed file identity changed',
        );
      }
      await _ownersOf(await access.inspectRoot(reference.root!), [actual]);
      await access.deleteFile(actual);
    }
    await _markRelink(row, true);
    await _refresh();
  });

  /// Saves a local book's reading position as its progress row.
  ///
  /// The coarse writer: what a caller that knows only an offset writes. The
  /// reader writes the settled five-field record through [saveProgressRecord],
  /// whose line facts and anchor are what a restore needs.
  Future<void> updateOffset(String bookId, int offset) => _serialize(() async {
    await store.putProgress(
      ProgressCompanion(
        bookId: Value(bookId),
        textOffset: Value(offset),
        updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
      ),
    );
    _books = [
      for (final book in _books)
        book.id == bookId ? book.copyWith(textOffset: offset) : book,
    ];
  });

  // --- The reader's facts (D4/D10) -----------------------------------------

  /// The five-field record the reader settled on, or null when the book was
  /// never read. The same row the reader writes, read back on open.
  Future<ProgressRecord?> progressRecordOf(String bookId) async {
    final row = await store.progressOf(bookId);
    if (row == null) return null;
    return ProgressRecord(
      textOffset: row.textOffset,
      lineIndex: row.lineIndex,
      offsetInLine: row.offsetInLine,
      textLength: row.textLength,
      chapterKey: row.chapterKey,
      chapterIndex: row.chapterIndex,
      anchor: row.anchor,
      updatedAt: row.updatedAt,
    );
  }

  /// Writes the record the reader settled on — every field of it, so a later
  /// open has the length it was written against and the anchor to restore by —
  /// and keeps the shelf's cached offset in step.
  Future<void> saveProgressRecord(String bookId, ProgressRecord record) =>
      _serialize(() async {
        await store.putProgress(
          ProgressCompanion(
            bookId: Value(bookId),
            textOffset: Value(record.textOffset),
            lineIndex: Value(record.lineIndex),
            offsetInLine: Value(record.offsetInLine),
            textLength: Value(record.textLength),
            chapterKey: Value(record.chapterKey),
            chapterIndex: Value(record.chapterIndex),
            anchor: Value(record.anchor),
            updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
          ),
        );
        _books = [
          for (final book in _books)
            book.id == bookId
                ? book.copyWith(textOffset: record.textOffset)
                : book,
        ];
      });

  /// What the store already knows about a local book's file: the index the last
  /// pass stored. Nothing here opens the file.
  Future<LocalFileIndex> fileIndex(LocalBook book) async {
    final row = await store.bookById(book.id);
    if (row?.rootId == null || row?.relativePath == null) {
      return const LocalFileIndex(encoding: '', anchors: []);
    }
    final rootId = row!.rootId!;
    final relative = row.relativePath!;
    final file = await store.localFile(rootId, relative);
    return LocalFileIndex(
      encoding: row.charset,
      anchors: await store.textIndexOf(rootId, relative),
      textLength: file?.textLength,
      modifiedAt: file?.modifiedAt,
    );
  }

  /// Stores what one index pass found: the sparse anchors, the decoded length
  /// and the modification time the change detection compares against, and the
  /// encoding the windows are read with. This is what makes the next open one
  /// window read instead of a pass.
  Future<void> putFileIndex(
    LocalBook book, {
    required String encoding,
    required int codeUnitLength,
    required int? modifiedAt,
    required List<TextIndexAnchor> anchors,
  }) => _serialize(() async {
    final current = await fileReferenceOf(book);
    final row = await store.bookById(book.id);
    if (current == null ||
        row?.rootId != book.rootId ||
        current.key != book.relativePath ||
        current.locator != book.path) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Book changed while indexing',
      );
    }
    final relative = book.relativePath ?? '';
    // The file row first: the anchors reference it (D4's per-file key), and a
    // failure between the two leaves an index that `describes` rejects rather
    // than anchors nothing can attribute to a file.
    await store.putLocalFile(
      LocalFilesCompanion(
        rootId: Value(book.rootId),
        relativePath: Value(relative),
        textLength: Value(codeUnitLength),
        modifiedAt: Value(modifiedAt),
      ),
    );
    await store.putTextIndex(book.rootId, relative, anchors);
    // A local book's detected charset is the encoding its windows are decoded
    // with, and `books.charset` is that field (D2's field set).
    await store.setBookCharset(book.id, encoding);
  });

  /// Flags or clears the relink state of a local book and its file together:
  /// the flag describes the file behind the book, and D4's change detection —
  /// the length, the modification time and the anchor — is what sets it here.
  Future<void> setNeedsRelink(LocalBook book, bool needsRelink) =>
      _serialize(() async {
        final row = await store.bookById(book.id);
        if (row != null) await _markRelink(row, needsRelink);
      });

  static LibraryLocation? _location(LocalRoot? root) {
    if (root == null) return null;
    final kind = LibraryLocationKind.values
        .where((kind) => kind.name == root.kind)
        .firstOrNull;
    final locator = root.locator ?? root.displayName;
    if (kind == null ||
        locator.isEmpty ||
        (kind == LibraryLocationKind.filesystem && !p.isAbsolute(locator))) {
      return null;
    }
    return LibraryLocation(
      kind: kind,
      locator: locator,
      identity: root.identity ?? locator,
      displayName: root.displayName,
      authorization: root.authorization,
    );
  }

  static LibraryFileReference? _reference(
    LocalRoot? root,
    String key,
    LocalFile? file,
  ) {
    final location = _location(root);
    if (location == null || key.isEmpty) return null;
    String? locator = file?.locator;
    if (location.kind == LibraryLocationKind.filesystem) {
      if (p.isAbsolute(key)) return null;
      locator ??= p.normalize(p.join(location.locator, key));
      if (!p.isAbsolute(locator) || !p.isWithin(location.locator, locator)) {
        return null;
      }
    }
    if (locator == null || locator.isEmpty) return null;
    return LibraryFileReference(
      kind: location.kind,
      locator: locator,
      key: key,
      name:
          file?.name ??
          (location.kind == LibraryLocationKind.filesystem
              ? p.basename(locator)
              : key),
      modifiedAt: file?.modifiedAt,
      root: location,
    );
  }

  static void _filesystemLocation(LibraryLocation location) {
    if (location.kind != LibraryLocationKind.filesystem) {
      throw const LibraryAccessFailure(
        LibraryAccessError.unsupported,
        'Native documents require library file references',
      );
    }
  }

  static bool _unreachable(LibraryAccessFailure error) =>
      error.code == LibraryAccessError.missing ||
      error.code == LibraryAccessError.permission;

  static bool _sameFile(LibraryFileReference a, LibraryFileReference b) =>
      a.kind == b.kind &&
      (a.locator == b.locator ||
          (a.identity != null &&
              b.identity != null &&
              a.identity == b.identity));

  Future<LocalRoot> _saveRoot(String id, LibraryLocation location) =>
      store.putLocalRoot(
        LocalRootsCompanion.insert(
          id: id,
          displayName: location.displayName,
          kind: Value(location.kind.name),
          locator: Value(location.locator),
          identity: Value(location.identity),
          authorization: Value(location.authorization),
          needsRelink: const Value(false),
        ),
      );

  Future<LocalRoot?> _matchingRoot(LibraryLocation actual) async {
    for (final root in await store.allLocalRoots()) {
      final location = _location(root);
      if (location == null || location.kind != actual.kind) continue;
      try {
        if ((await access.inspectRoot(location)).sameLocation(actual)) {
          return root;
        }
      } on LibraryAccessFailure catch (error) {
        if (!_unreachable(error)) rethrow;
      }
    }
    return null;
  }

  Future<void> _markRelink(ShelfBook row, bool missing) =>
      store.transaction(() async {
        await store.setBookRelink(row.id, missing);
        if (row.rootId != null &&
            row.relativePath != null &&
            await store.localFile(row.rootId!, row.relativePath!) != null) {
          await store.putLocalFile(
            LocalFilesCompanion(
              rootId: Value(row.rootId!),
              relativePath: Value(row.relativePath!),
              needsRelink: Value(missing),
            ),
          );
        }
      });

  /// Root IDs can alias one directory after relocation. Stored locators only
  /// narrow the lookup; inspected access and canonical membership prove which
  /// current book owns a listed file. Unrelated roots are never probed.
  Future<Map<String, ShelfBook>> _ownersOf(
    LibraryLocation destination,
    List<LibraryFileReference> files,
  ) async {
    final owners = <String, ShelfBook>{};
    final roots = await _rootsById();
    final inspectedRoots = <String, LibraryLocation>{};
    final byKey = {for (final file in files) file.key: file};
    for (final book in await store.localBooks()) {
      final root = roots[book.rootId];
      final location = _location(root);
      if (root == null ||
          location == null ||
          location.kind != destination.kind) {
        continue;
      }
      final stored = await store.localFile(root.id, book.relativePath!);
      final reference = _reference(root, book.relativePath!, stored);
      final sameDirectory = _sameLocator(
        location.kind,
        location.locator,
        destination.locator,
      );
      final sameKey = sameDirectory ? byKey[book.relativePath] : null;
      final sameLocator = reference == null
          ? null
          : files
                .where(
                  (file) =>
                      _sameLocator(file.kind, file.locator, reference.locator),
                )
                .firstOrNull;
      if (sameKey == null && sameLocator == null) continue;
      final actualRoot = inspectedRoots[root.id] ??= await access.inspectRoot(
        location,
      );
      final refreshedRoot = root.copyWith(
        displayName: actualRoot.displayName,
        kind: actualRoot.kind.name,
        locator: Value(actualRoot.locator),
        identity: Value(actualRoot.identity),
        authorization: Value(actualRoot.authorization),
      );
      final refreshedReference = _reference(
        refreshedRoot,
        book.relativePath!,
        stored,
      );
      // Legacy native book rows can lack file facts. Their exact opaque key
      // can name a listed member only after the directory itself is verified.
      final known =
          refreshedReference ??
          (stored?.locator == null &&
                  actualRoot.kind != LibraryLocationKind.filesystem &&
                  actualRoot.sameLocation(destination)
              ? sameKey
              : null);
      if (known == null) continue;
      final current = await access.stat(known);
      if (current == null) continue;
      final actual = await access.fileInRoot(destination, current);
      if (actual == null) continue;
      final listed = byKey[actual.key];
      if (listed == null || !_sameFile(actual, listed)) continue;
      final previous = owners[actual.key];
      if (previous != null && previous.id != book.id) {
        throw LibraryAccessFailure(
          LibraryAccessError.collision,
          'Multiple books own the same library file',
          details: {
            'bookIds': [previous.id, book.id],
            'locator': actual.locator,
          },
        );
      }
      owners[actual.key] = book;
    }
    return owners;
  }

  static bool _sameLocator(LibraryLocationKind kind, String a, String b) =>
      kind == LibraryLocationKind.filesystem ? p.equals(a, b) : a == b;

  Future<List<_LibraryCandidate>> _candidates(
    String? rootId,
    LibraryLocation location,
  ) async {
    final listed = await access.list(location);
    final owners = await _ownersOf(location, listed);
    final candidates = <_LibraryCandidate>[];
    for (final file in listed) {
      final row = owners[file.key];
      final stored = row == null
          ? null
          : await store.localFile(row.rootId!, row.relativePath!);
      candidates.add(
        _LibraryCandidate(file, stored?.importName ?? file.name, row),
      );
    }
    if (rootId != null) {
      final root = (await _rootsById())[rootId];
      for (final file in await store.localFilesOf(rootId)) {
        if (file.bookId == null ||
            candidates.any(
              (candidate) => candidate.file.key == file.relativePath,
            )) {
          continue;
        }
        final reference = _reference(root, file.relativePath, file);
        if (reference == null) {
          throw const LibraryAccessFailure(
            LibraryAccessError.missing,
            'Managed file needs relinking',
          );
        }
        LibraryFileReference? present;
        try {
          present = await access.stat(reference);
        } on LibraryAccessFailure catch (error) {
          if (error.code != LibraryAccessError.missing) rethrow;
        }
        if (present == null) {
          // Absence cannot prove ownership, but the stored book identity must
          // remain available to the explicit update/conflict decision.
          candidates.add(
            _LibraryCandidate(
              reference,
              file.importName ?? reference.name,
              await store.bookById(file.bookId!),
            ),
          );
          continue;
        }
        final member = await access.fileInRoot(location, present);
        if (member == null) {
          throw const LibraryAccessFailure(
            LibraryAccessError.verification,
            'Stored candidate membership could not be verified',
          );
        }
        final owner = (await _ownersOf(location, [member]))[member.key];
        candidates.add(
          _LibraryCandidate(member, file.importName ?? reference.name, owner),
        );
      }
    }
    return candidates;
  }

  Future<_PreparedBook> _prepare(
    LibraryFileReference source,
    LibraryLocation destination,
    List<_LibraryCandidate> candidates,
    List<LibraryCopyReceipt> owned,
    LibraryTransfer transfer,
    LibraryConflictResolver resolver, {
    required String rootId,
    ShelfBook? incoming,
    String? name,
  }) async {
    transfer.checkCancelled();
    final logicalName = name ?? source.name;
    final member = await access.fileInRoot(destination, source);
    _LibraryCandidate? canonical;
    if (member != null) {
      // Membership can be below the listed directory. Resolve its ownership
      // directly as well, rather than treating an unlisted child as unowned.
      final owner = (await _ownersOf(destination, [member]))[member.key];
      final stored = owner == null
          ? null
          : await store.localFile(owner.rootId!, owner.relativePath!);
      canonical = _LibraryCandidate(
        member,
        stored?.importName ?? member.name,
        owner,
      );
    }
    if (member != null &&
        !member.directory &&
        (incoming == null ||
            canonical?.book == null ||
            canonical!.book!.id == incoming.id)) {
      final existing = incoming ?? canonical?.book;
      final unchanged =
          incoming == null &&
          existing?.rootId == rootId &&
          existing?.relativePath == member.key;
      await _checkOriginalAssociation(unchanged ? null : existing);
      return _PreparedBook(
        file: member,
        name: incoming == null && existing != null
            ? canonical!.name
            : logicalName,
        id: existing?.id ?? mintId('book'),
        existing: existing,
        unchanged: unchanged,
        fingerprint: await access.fingerprint(member),
      );
    }
    final logicalMatches =
        candidates
            .where(
              (candidate) =>
                  candidate.book != null && candidate.name == logicalName,
            )
            .toList()
          ..sort((a, b) => a.book!.bookOrder.compareTo(b.book!.bookOrder));
    // Keep-both can leave several managed books with one logical import name.
    // Repeating either source reuses its own equal-byte book, not whichever
    // provider entry happened to be listed first.
    if (incoming == null && logicalMatches.length > 1) {
      final fingerprint = await access.fingerprint(source);
      for (final candidate in logicalMatches) {
        if (!candidate.file.directory &&
            await _matchesFingerprint(fingerprint, candidate.file)) {
          final unchanged =
              candidate.book!.rootId == rootId &&
              candidate.book!.relativePath == candidate.file.key;
          await _checkOriginalAssociation(unchanged ? null : candidate.book);
          return _PreparedBook(
            file: candidate.file,
            name: logicalName,
            id: candidate.book!.id,
            existing: candidate.book,
            unchanged: unchanged,
            fingerprint: fingerprint,
          );
        }
      }
    }
    final collision =
        canonical ??
        logicalMatches.firstOrNull ??
        candidates
            .where((candidate) => candidate.file.name == logicalName)
            .firstOrNull;
    ShelfBook? existing = incoming;
    var copyName = logicalName;
    if (collision != null) {
      final conflict = LibraryImportConflict(
        source: source,
        existing: collision.file,
        name: logicalName,
        existingBookId: collision.book?.id,
        incomingBookId: incoming?.id,
      );
      final fingerprint = !collision.file.directory && conflict.canUpdate
          ? await access.fingerprint(source)
          : null;
      if (fingerprint != null &&
          await _matchesFingerprint(fingerprint, collision.file)) {
        final reused = incoming ?? collision.book;
        final unchanged =
            incoming == null &&
            reused?.rootId == rootId &&
            reused?.relativePath == collision.file.key;
        await _checkOriginalAssociation(unchanged ? null : reused);
        return _PreparedBook(
          file: collision.file,
          name: incoming == null && reused != null
              ? collision.name
              : logicalName,
          id: reused?.id ?? mintId('book'),
          existing: reused,
          unchanged: unchanged,
          fingerprint: fingerprint,
        );
      }
      final choice = await resolver(conflict);
      transfer.checkCancelled();
      if (choice == LibraryConflictChoice.cancel) {
        throw const LibraryAccessFailure(
          LibraryAccessError.cancelled,
          'Library conflict cancelled',
        );
      }
      if (choice == LibraryConflictChoice.update && !conflict.canUpdate) {
        throw const LibraryAccessFailure(
          LibraryAccessError.collision,
          'Updating would discard a different book identity',
        );
      }
      if (choice == LibraryConflictChoice.update) existing ??= collision.book;
      copyName = _availableName(logicalName, candidates);
    }
    await _checkOriginalAssociation(existing);
    final receipt = await access.copyFile(
      source,
      destination,
      copyName,
      transfer: transfer,
    );
    if (_sameFile(source, receipt.file) ||
        candidates.any(
          (candidate) => _sameFile(candidate.file, receipt.file),
        )) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Copy did not create a fresh owned file',
      );
    }
    owned.add(receipt);
    transfer.checkCancelled();
    final actual = await access.fileInRoot(destination, receipt.file);
    if (actual == null ||
        actual.directory ||
        actual.key != receipt.file.key ||
        !_sameFile(actual, receipt.file) ||
        candidates.any(
          (candidate) =>
              _sameFile(candidate.file, actual) ||
              candidate.file.key == actual.key,
        ) ||
        !(await access.fingerprint(actual)).sameBytes(receipt.fingerprint)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Copy receipt does not identify verified fresh bytes',
      );
    }
    return _PreparedBook(
      file: actual,
      name: logicalName,
      id: existing?.id ?? mintId('book'),
      existing: existing,
      fingerprint: receipt.fingerprint,
    );
  }

  Future<bool> _matchesFingerprint(
    LibraryFingerprint source,
    LibraryFileReference candidate,
  ) async {
    try {
      return source.sameBytes(await access.fingerprint(candidate));
    } on LibraryAccessFailure catch (error) {
      if (error.code == LibraryAccessError.missing) return false;
      rethrow;
    }
  }

  Future<void> _checkOriginalAssociation(ShelfBook? book) async {
    if (book == null ||
        book.originalRootId != null ||
        book.originalRelativePath != null ||
        book.rootId == null ||
        book.relativePath == null) {
      return;
    }
    final owner = await store.localBookByOriginalKey(
      book.rootId!,
      book.relativePath!,
    );
    if (owner != null && owner.id != book.id) {
      throw LibraryAccessFailure(
        LibraryAccessError.collision,
        'Original import association belongs to another book',
        details: {
          'bookId': book.id,
          'existingBookId': owner.id,
          'originalRootId': book.rootId,
          'originalRelativePath': book.relativePath,
        },
      );
    }
  }

  static String _availableName(
    String name,
    List<_LibraryCandidate> candidates,
  ) {
    final extension = p.extension(name);
    final stem = p.basenameWithoutExtension(name);
    for (var number = 2; ; number++) {
      final candidate = '$stem ($number)$extension';
      if (!candidates.any(
        (entry) => entry.file.name == candidate || entry.name == candidate,
      )) {
        return candidate;
      }
    }
  }

  Future<void> _publish(
    String rootId,
    List<_PreparedBook> pending, {
    bool shelve = true,
  }) async {
    // Vacate old keys first: a provider can reuse them at the new location,
    // including a permutation of two books' previous keys.
    for (final book in pending) {
      final old = book.existing;
      if (old == null || book.unchanged) continue;
      if (old.rootId != null && old.relativePath != null) {
        await store.removeLocalFile(old.rootId!, old.relativePath!);
      }
      await store.putBook(
        BooksCompanion(
          id: Value(book.id),
          title: Value(old.title),
          rootId: const Value(null),
          relativePath: const Value(null),
        ),
      );
    }
    for (final book in pending) {
      final old = book.existing;
      if (book.unchanged) {
        final stored = await store.localFile(rootId, book.file.key);
        await store.putLocalFile(
          LocalFilesCompanion(
            rootId: Value(rootId),
            relativePath: Value(book.file.key),
            locator: Value(book.file.locator),
            name: Value(book.file.name),
            importName: Value(stored?.importName ?? book.name),
            sha256: Value(book.fingerprint?.sha256 ?? stored?.sha256),
            format: Value(
              old!.format ??
                  (book.name.toLowerCase().endsWith('.md')
                      ? 'markdown'
                      : 'txt'),
            ),
            bookId: Value(book.id),
            needsRelink: const Value(false),
          ),
        );
        await store.setShelved(book.id, true);
        await _markRelink(old, false);
        continue;
      }
      final format = book.name.toLowerCase().endsWith('.md')
          ? 'markdown'
          : 'txt';
      if (old == null) {
        await store.putBook(
          BooksCompanion.insert(
            id: book.id,
            title: book.name,
            kind: const Value('local'),
            rootId: Value(rootId),
            relativePath: Value(book.file.key),
            format: Value(format),
            bookOrder: Value(await store.nextBookOrder()),
          ),
        );
      } else {
        final captureOriginal =
            old.originalRootId == null && old.originalRelativePath == null;
        await store.putBook(
          BooksCompanion(
            id: Value(old.id),
            title: Value(old.title),
            rootId: Value(rootId),
            relativePath: Value(book.file.key),
            originalRootId: Value(
              captureOriginal ? old.rootId : old.originalRootId,
            ),
            originalRelativePath: Value(
              captureOriginal ? old.relativePath : old.originalRelativePath,
            ),
            charset: const Value(''),
            needsRelink: const Value(false),
            shelved: Value(shelve || old.shelved),
            format: Value(format),
          ),
        );
      }
      await store.putLocalFile(
        LocalFilesCompanion.insert(
          rootId: rootId,
          relativePath: book.file.key,
          locator: Value(book.file.locator),
          name: Value(book.file.name),
          importName: Value(book.name),
          sha256: Value(book.fingerprint?.sha256),
          format: Value(format),
          textLength: const Value(null),
          modifiedAt: Value(book.file.modifiedAt),
          bookId: Value(book.id),
          needsRelink: const Value(false),
        ),
      );
      await store.putTextIndex(rootId, book.file.key, const []);
    }
  }

  Future<Never> _cleanupAndRethrow(
    List<LibraryCopyReceipt> owned,
    Object error,
    StackTrace stack,
  ) async {
    final failures = <Object>[];
    for (final receipt in owned.reversed) {
      try {
        if (!(await access.fingerprint(
          receipt.file,
        )).sameBytes(receipt.fingerprint)) {
          throw const LibraryAccessFailure(
            LibraryAccessError.verification,
            'Unpublished copy changed; cleanup refused',
          );
        }
        await access.deleteFile(receipt.file);
      } catch (cleanupError) {
        failures.add(cleanupError);
      }
    }
    if (failures.isNotEmpty) {
      throw LibraryAccessFailure(
        LibraryAccessError.io,
        'Library operation failed and unpublished copies could not be cleaned',
        details: {
          'operation': error,
          'cleanup': failures,
          'files': owned.map((receipt) => receipt.file.toJson()).toList(),
        },
      );
    }
    Error.throwWithStackTrace(error, stack);
  }

  bool _isSupported(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.txt') || lower.endsWith('.md');
  }

  Future<Map<String, LocalRoot>> _rootsById() async => {
    for (final row in await store.allLocalRoots()) row.id: row,
  };

  Future<List<LocalBook>> _readBooks(Map<String, LocalRoot> roots) async {
    final books = <LocalBook>[];
    for (final row in await store.localBooks()) {
      books.add(await _localBook(row, roots[row.rootId]));
    }
    return books;
  }

  Future<LocalBook> _localBook(ShelfBook row, LocalRoot? root) async {
    final progress = await store.progressOf(row.id);
    final relative = row.relativePath ?? '';
    return LocalBook(
      id: row.id,
      rootId: row.rootId ?? '',
      path:
          _reference(
            root,
            relative,
            await store.localFile(row.rootId ?? '', relative),
          )?.locator ??
          '',
      title: row.title,
      textOffset: progress?.textOffset ?? 0,
      relativePath: relative,
      format: row.format ?? 'txt',
    );
  }
}

class _LibraryCandidate {
  const _LibraryCandidate(this.file, this.name, this.book);
  final LibraryFileReference file;
  final String name;
  final ShelfBook? book;
}

class _PreparedBook {
  const _PreparedBook({
    required this.file,
    required this.name,
    required this.id,
    this.existing,
    this.fingerprint,
    this.unchanged = false,
  });
  final LibraryFileReference file;
  final String name;
  final String id;
  final ShelfBook? existing;
  final LibraryFingerprint? fingerprint;
  final bool unchanged;
}
