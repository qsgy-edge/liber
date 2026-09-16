import 'dart:io';

import 'package:drift/drift.dart' show Value;

import '../domain/contracts.dart';
import 'database.dart';
import 'ids.dart';
import 'space_store.dart';

/// The local library: the authorized roots and the files the user admitted
/// from them, over the space's store.
///
/// `local_roots` holds the roots, `local_files` the files, and a file admitted
/// to the shelf is a `books` row of kind `local` carrying its root and its
/// relative path (D2/D4). Nothing here reads a book: walking folders is the
/// file system's job, and the reading position is the `progress` row.
class LocalLibrary {
  LocalLibrary(this.store);

  final SpaceStore store;

  /// The space-global setting that remembers which root the library shows.
  static const activeRootKey = 'local.active_root';

  LocalRoot? _root;
  String? _currentPath;
  List<LocalBook> _books = const <LocalBook>[];

  LocalRoot? get root => _root;

  /// The folder the page is browsing; a session fact, not persisted state.
  String? get currentPath => _currentPath;

  /// The files admitted to the shelf, in the order they were added.
  List<LocalBook> get books => List.unmodifiable(_books);

  /// Loads the roots and the admitted books.
  ///
  /// A root whose directory is gone is flagged rather than forgotten: that flag
  /// is how a library survives its volume being unplugged (D4).
  Future<void> load() async {
    final roots = <String, LocalRoot>{};
    for (final row in await store.allLocalRoots()) {
      final missing = !await Directory(row.displayName).exists();
      roots[row.id] = missing == row.needsRelink
          ? row
          : await store.putLocalRoot(
              LocalRootsCompanion(
                id: Value(row.id),
                displayName: Value(row.displayName),
                needsRelink: Value(missing),
              ),
            );
    }
    final active = await store.setting(activeRootKey);
    _root = roots[active] ?? roots.values.firstOrNull;
    _currentPath = _root?.displayName;
    _books = await _readBooks(roots);
  }

  /// Authorizes a root, or re-authorizes one whose directory came back, and
  /// makes it the root the library shows.
  ///
  /// Re-authorizing is the relink: a file that is back where it was is usable
  /// again, a file that is still gone stays flagged, and both facts are in the
  /// store rather than in this session.
  Future<LocalRoot> selectRoot(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) throw FileSystemException('目录不存在', path);
    final absolute = directory.absolute.path;
    final id = absolute.toLowerCase();
    final root = await store.putLocalRoot(
      LocalRootsCompanion.insert(
        id: id,
        displayName: absolute,
        needsRelink: const Value(false),
      ),
    );
    await store.putSetting(activeRootKey, id);
    // The relink is per file, and both the file's flag and the book's are facts
    // of the store rather than of this session.
    for (final file in await store.localFilesOf(id)) {
      final restored = File(_absolute(root, file.relativePath));
      final stat = await restored.exists() ? await restored.stat() : null;
      final missing = stat == null;
      if (missing == file.needsRelink) continue;
      await store.putLocalFile(
        LocalFilesCompanion(
          rootId: Value(id),
          relativePath: Value(file.relativePath),
          needsRelink: Value(missing),
          modifiedAt: Value(stat?.modified.millisecondsSinceEpoch),
          bookId: Value(file.bookId),
        ),
      );
      final bookId = file.bookId;
      if (bookId != null) await store.setBookRelink(bookId, missing);
    }
    _root = root;
    _currentPath = root.displayName;
    _books = await _readBooks(await _rootsById());
    return root;
  }

  Future<List<FileSystemEntity>> listCurrentFolder() async {
    final path = _currentPath;
    if (path == null) return const <FileSystemEntity>[];
    try {
      final entries = await Directory(path).list(followLinks: false).toList();
      entries.sort((a, b) {
        final aDir = a is Directory ? 0 : 1;
        final bDir = b is Directory ? 0 : 1;
        return aDir == bDir ? a.path.compareTo(b.path) : aDir - bDir;
      });
      return entries
          .where((entry) => entry is Directory || _isSupported(entry.path))
          .toList();
    } on FileSystemException {
      return const <FileSystemEntity>[];
    }
  }

  Future<List<FileSystemEntity>> enterFolder(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) throw FileSystemException('目录不存在', path);
    _currentPath = directory.absolute.path;
    return listCurrentFolder();
  }

  Future<List<FileSystemEntity>> goUp() async {
    final root = _root;
    final current = _currentPath;
    if (root == null ||
        current == null ||
        current.toLowerCase() == root.displayName.toLowerCase()) {
      return listCurrentFolder();
    }
    return enterFolder(Directory(current).parent.path);
  }

  Future<List<FileSystemEntity>> scanRecursively() async {
    final path = _currentPath;
    if (path == null) return const <FileSystemEntity>[];
    final entries = <FileSystemEntity>[];
    await for (final entry in Directory(
      path,
    ).list(recursive: true, followLinks: false)) {
      if (entry is File && _isSupported(entry.path)) entries.add(entry);
    }
    return entries;
  }

  /// Admits files to the shelf: the `books` row the shelf lists, plus the
  /// `local_files` row the reader resolves the path from.
  ///
  /// The natural key — the root and the path inside it — is what a re-add and
  /// the import match on, and it is the only thing they match on: the id is
  /// minted (D2), so a file that is only different in case is a different book
  /// rather than the same row rewritten.
  Future<List<LocalBook>> addFiles(Iterable<FileSystemEntity> entries) async {
    final root = _root;
    if (root == null) return const <LocalBook>[];
    final addedIds = <String>{};
    for (final entry in entries) {
      if (entry is! File || !_isSupported(entry.path)) continue;
      final path = entry.absolute.path;
      final relative = _relativeTo(root, path);
      if (relative == null) continue;
      if (await store.localBook(root.id, relative) != null) continue;
      final format = path.toLowerCase().endsWith('.md') ? 'markdown' : 'txt';
      final title = path.split(Platform.pathSeparator).last;
      final id = mintId('book');
      await store.putBook(
        BooksCompanion.insert(
          id: id,
          kind: const Value('local'),
          title: title,
          rootId: Value(root.id),
          relativePath: Value(relative),
          format: Value(format),
          bookOrder: Value(await store.nextBookOrder()),
        ),
      );
      await store.putLocalFile(
        LocalFilesCompanion.insert(
          rootId: root.id,
          relativePath: relative,
          format: Value(format),
          modifiedAt: Value(
            (await entry.stat()).modified.millisecondsSinceEpoch,
          ),
          bookId: Value(id),
        ),
      );
      addedIds.add(id);
    }
    if (addedIds.isEmpty) return const <LocalBook>[];
    _books = await _readBooks(await _rootsById());
    return [
      for (final book in _books)
        if (addedIds.contains(book.id)) book,
    ];
  }

  /// Saves a local book's reading position as its progress row.
  Future<void> updateOffset(String bookId, int offset) async {
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
      path: _absolute(root, relative),
      title: row.title,
      textOffset: progress?.textOffset ?? 0,
      relativePath: relative,
      format: row.format ?? 'txt',
    );
  }

  /// The path a book resolves to: its own root's folder plus its relative path,
  /// so a book admitted under another root still points at its own file.
  static String _absolute(LocalRoot? root, String relative) {
    final display = root?.displayName;
    if (display == null || display.isEmpty) return relative;
    return '$display${Platform.pathSeparator}$relative';
  }

  static String? _relativeTo(LocalRoot root, String path) {
    final prefix = '${root.displayName}${Platform.pathSeparator}';
    if (!path.toLowerCase().startsWith(prefix.toLowerCase())) return null;
    return path.substring(prefix.length);
  }
}
