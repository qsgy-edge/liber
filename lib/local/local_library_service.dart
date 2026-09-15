import 'dart:convert';
import 'dart:io';

import '../domain/contracts.dart';

class LocalLibraryService {
  LocalLibraryService({File? stateFile}) : _testFile = stateFile;
  final File? _testFile;
  LocalRoot? _root;
  String? _currentPath;
  final Set<String> _addedIds = <String>{};
  final List<LocalBook> _books = <LocalBook>[];

  LocalRoot? get root => _root;
  String? get currentPath => _currentPath;
  List<LocalBook> get books => List.unmodifiable(_books);

  File get _stateFile {
    if (_testFile != null) return _testFile;
    final appData = Platform.environment['APPDATA'] ?? Directory.current.path;
    return File(
      '$appData${Platform.pathSeparator}Liber${Platform.pathSeparator}local_books.json',
    );
  }

  Future<void> load() async {
    if (!await _stateFile.exists()) return;
    try {
      final decoded = jsonDecode(await _stateFile.readAsString());
      if (decoded is List) {
        _books
          ..clear()
          ..addAll(
            decoded.whereType<Map<String, dynamic>>().map(LocalBook.fromJson),
          );
      } else if (decoded is Map<String, dynamic>) {
        final root = decoded['root'];
        if (root is Map<String, dynamic>) {
          _root = LocalRoot.fromJson(root);
          _currentPath = _root!.displayName;
        }
        final books = decoded['books'];
        if (books is List) {
          _books
            ..clear()
            ..addAll(
              books.whereType<Map<String, dynamic>>().map(LocalBook.fromJson),
            );
        }
      }
      if (_root != null && !await Directory(_root!.displayName).exists()) {
        _root = _root!.copyWith(needsRelink: true);
      }

      _addedIds.addAll(_books.map((book) => book.id));
    } on FormatException {
      // A damaged state file does not prevent the application from starting.
    }
  }

  Future<void> _save() async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      jsonEncode({
        'root': _root?.toJson(),
        'books': _books.map((book) => book.toJson()).toList(),
      }),
    );
  }

  Future<void> updateOffset(String bookId, int offset) async {
    final index = _books.indexWhere((book) => book.id == bookId);
    if (index < 0) return;
    final clamped = offset.clamp(0, await _readLength(_books[index].path));
    _books[index] = _books[index].copyWith(
      textOffset: clamped,
      updatedAt: DateTime.now(),
    );
    await _save();
  }

  Future<int> _readLength(String path) async {
    try {
      return (await File(path).readAsString()).length;
    } on IOException {
      return 0;
    }
  }

  Future<LocalRoot> selectRoot(String path) async {
    final directory = Directory(path);
    if (!await directory.exists()) throw FileSystemException('目录不存在', path);
    final normalized = directory.absolute.path.toLowerCase();
    final previousRoot = _root;
    _root = LocalRoot(id: normalized, displayName: directory.absolute.path);
    _currentPath = _root!.displayName;
    if (previousRoot?.id == normalized) {
      for (var i = 0; i < _books.length; i++) {
        final book = _books[i];
        final relative = book.relativePath;
        if (relative != null) {
          final path =
              '${directory.absolute.path}${Platform.pathSeparator}$relative';
          _books[i] = LocalBook(
            id: book.id,
            rootId: book.rootId,
            path: path,
            title: book.title,
            textOffset: book.textOffset,
            relativePath: relative,
            format: book.format,
            updatedAt: book.updatedAt,
          );
        }
      }
    }
    await _save();
    return _root!;
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

  Future<List<LocalBook>> addFiles(Iterable<FileSystemEntity> entries) async {
    final root = _root;
    if (root == null) return const <LocalBook>[];
    final added = <LocalBook>[];
    for (final entry in entries) {
      if (entry is! File || !_isSupported(entry.path)) continue;
      final path = entry.absolute.path;
      final id = path.toLowerCase();
      if (!_addedIds.add(id)) continue;
      final relative = path.substring(root.displayName.length + 1);
      final format = path.toLowerCase().endsWith('.md') ? 'markdown' : 'txt';
      added.add(
        LocalBook(
          id: '${root.id}::$relative'.toLowerCase(),
          rootId: root.id,
          path: path,
          title: path.split(Platform.pathSeparator).last,
          textOffset: 0,
          relativePath: relative,
          format: format,
          updatedAt: DateTime.now(),
        ),
      );
    }
    _books.addAll(added);
    if (added.isNotEmpty) await _save();
    return added;
  }

  bool _isSupported(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.txt') || lower.endsWith('.md');
  }
}
