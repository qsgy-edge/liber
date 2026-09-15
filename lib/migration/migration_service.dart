import 'dart:convert';
import 'dart:io';

import '../domain/contracts.dart';

class ImportedBookSource {
  const ImportedBookSource({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'id': id, 'data': data};
  factory ImportedBookSource.fromJson(Map<String, dynamic> json) =>
      ImportedBookSource(
        id: json['id'] as String,
        data: Map<String, dynamic>.from(json['data'] as Map),
      );
}

class ImportedBook {
  const ImportedBook({
    required this.id,
    required this.title,
    required this.progressOffset,
    this.needsRelink = false,
  });
  final String id;
  final String title;
  final int progressOffset;
  final bool needsRelink;

  ImportedBook copyWith({int? progressOffset}) => ImportedBook(
    id: id,
    title: title,
    progressOffset: progressOffset ?? this.progressOffset,
    needsRelink: needsRelink,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'progressOffset': progressOffset,
    'needsRelink': needsRelink,
  };

  factory ImportedBook.fromJson(Map<String, dynamic> json) => ImportedBook(
    id: json['id'] as String,
    title: json['title'] as String,
    progressOffset: (json['progressOffset'] as num?)?.toInt() ?? 0,
    needsRelink: json['needsRelink'] as bool? ?? false,
  );
}

class MigrationService {
  MigrationService({File? stateFile}) : _testFile = stateFile;
  final File? _testFile;
  final List<ImportedBookSource> _sources = <ImportedBookSource>[];
  final List<ImportedBook> _books = <ImportedBook>[];

  File get _stateFile {
    if (_testFile != null) return _testFile;
    final appData = Platform.environment['APPDATA'] ?? Directory.current.path;
    return File(
      '$appData${Platform.pathSeparator}Liber${Platform.pathSeparator}migration_state.json',
    );
  }

  List<ImportedBookSource> get sources => List.unmodifiable(_sources);
  List<ImportedBook> get books => List.unmodifiable(_books);

  Future<void> load() async {
    if (!await _stateFile.exists()) return;
    final decoded = jsonDecode(await _stateFile.readAsString());
    if (decoded is! Map<String, dynamic>) return;
    _sources
      ..clear()
      ..addAll(
        (decoded['sources'] as List? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ImportedBookSource.fromJson),
      );
    _books
      ..clear()
      ..addAll(
        (decoded['books'] as List? ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ImportedBook.fromJson),
      );
  }

  Future<MigrationImportRecord> importJson(String jsonText) async {
    final decoded = jsonDecode(jsonText);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('迁移文件必须是 JSON object');
    }
    final sources = _list(decoded, const ['bookSources', 'bookSource']);
    final books = _list(decoded, const ['books', 'bookshelf']);
    final progress = _list(decoded, const ['progress', 'bookProgress']);
    final losses = <String>['本地文件字节、Cookie、缓存和下载内容不会从备份中导入'];
    if (sources.isEmpty) losses.add('未发现 Book Source 数据');
    if (books.isEmpty) losses.add('未发现书架数据');
    if (progress.isEmpty) losses.add('未发现阅读进度数据');

    for (final raw in sources.whereType<Map>()) {
      final data = Map<String, dynamic>.from(raw);
      final id =
          '${data['bookSourceUrl'] ?? data['bookSourceName'] ?? data.hashCode}';
      final index = _sources.indexWhere((item) => item.id == id);
      final value = ImportedBookSource(id: id, data: data);
      if (index < 0) {
        _sources.add(value);
      } else {
        _sources[index] = value;
      }
    }
    for (final raw in books.whereType<Map>()) {
      final data = Map<String, dynamic>.from(raw);
      final id =
          '${data['bookUrl'] ?? data['bookId'] ?? data['name'] ?? data.hashCode}';
      final title = '${data['name'] ?? data['bookName'] ?? '未命名书籍'}';
      final incoming = _progressFor(progress, id);
      final index = _books.indexWhere((item) => item.id == id);
      if (index < 0) {
        _books.add(
          ImportedBook(
            id: id,
            title: title,
            progressOffset: incoming,
            needsRelink: _isLocalPath(data),
          ),
        );
      } else if (incoming > _books[index].progressOffset) {
        _books[index] = _books[index].copyWith(progressOffset: incoming);
      }
    }
    await _save();
    return MigrationImportRecord(
      sourceCount: sources.length,
      bookCount: books.length,
      progressCount: progress.length,
      losses: losses,
    );
  }

  Future<void> _save() async {
    await _stateFile.parent.create(recursive: true);
    await _stateFile.writeAsString(
      jsonEncode({
        'sources': _sources.map((item) => item.toJson()).toList(),
        'books': _books.map((item) => item.toJson()).toList(),
      }),
    );
  }

  int _progressFor(List<dynamic> progress, String bookId) {
    for (final raw in progress.whereType<Map>()) {
      final data = Map<String, dynamic>.from(raw);
      if ('${data['bookId'] ?? data['bookUrl'] ?? ''}' != bookId) continue;
      return (data['textOffset'] ?? data['durChapterIndex'] ?? 0) is num
          ? ((data['textOffset'] ?? data['durChapterIndex'] ?? 0) as num)
                .toInt()
          : 0;
    }
    return 0;
  }

  bool _isLocalPath(Map<String, dynamic> data) =>
      '${data['bookUrl'] ?? ''}'.startsWith('file:') ||
      '${data['bookPath'] ?? ''}'.isNotEmpty;

  List<dynamic> _list(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is List) return value;
      if (value is Map) return value.values.toList();
    }
    return const <dynamic>[];
  }
}
