import 'dart:convert';
import 'dart:io';

import 'html_source_pipeline.dart';
import 'json_source_pipeline.dart' show SourceChapter;

/// Shared per-file queue prevents overlapping routes from losing each other's
/// updates. All changes read the latest committed state before atomic replace.
class OnlineReadingStore {
  OnlineReadingStore({File? file}) : file = file ?? _defaultFile();
  final File file;
  static final _queues = <String, Future<void>>{};
  String get _path => file.absolute.path;

  static File _defaultFile() {
    final folder = Platform.environment['APPDATA'];
    if (folder == null) throw StateError('APPDATA is unavailable');
    return File('$folder/Liber/online_reading.json');
  }

  static String key(Map<String, dynamic> source, String bookUrl) => jsonEncode([
    source['bookSourceUrl'],
    Uri.parse(bookUrl).removeFragment().toString(),
  ]);
  static String recordKey(Map<String, dynamic> value) => key(
    Map<String, dynamic>.from(value['source'] as Map),
    (value['book'] as Map)['url'] as String,
  );

  static void _validate(Map<String, dynamic> value) {
    final source = value['source'];
    final book = value['book'];
    if (source is! Map ||
        source['bookSourceUrl'] is! String ||
        book is! Map ||
        book['url'] is! String ||
        book['title'] is! String ||
        value['chapterUrl'] is! String ||
        value['textOffset'] is! int ||
        (value['textOffset'] as int) < 0 ||
        (value['shelved'] != null && value['shelved'] is! bool)) {
      throw const FormatException('在线阅读记录损坏，原文件保留');
    }
    final chapters = value['chapters'];
    if (chapters != null &&
        (chapters is! List ||
            chapters.any(
              (c) => c is! Map || c['name'] is! String || c['url'] is! String,
            ))) {
      throw const FormatException('已存目录损坏，原文件保留');
    }
  }

  Future<Map<String, dynamic>> _read() async {
    if (!await file.exists()) return {'version': 2, 'records': <dynamic>[]};
    final raw = jsonDecode(await file.readAsString());
    if (raw is! Map<String, dynamic>) throw const FormatException('在线阅读文件格式错误');
    if (raw.containsKey('source')) {
      _validate(raw);
      return {
        'version': 2,
        'last': recordKey(raw),
        'records': [raw],
      };
    }
    if (raw['version'] != 2 || raw['records'] is! List) {
      throw const FormatException('在线阅读文件版本不受支持');
    }
    for (final value in raw['records'] as List) {
      if (value is! Map<String, dynamic>) throw const FormatException('非法书架条目');
      _validate(value);
    }
    return raw;
  }

  Future<Map<String, dynamic>?> load() async {
    await _queues[_path];
    final state = await _read();
    for (final value
        in (state['records'] as List).cast<Map<String, dynamic>>()) {
      if (recordKey(value) == state['last']) return value;
    }
    return null;
  }

  Future<List<Map<String, dynamic>>> loadBooks() async {
    await _queues[_path];
    return ((await _read())['records'] as List)
        .cast<Map<String, dynamic>>()
        .where((value) => value['shelved'] == true)
        .toList();
  }

  Future<Map<String, dynamic>?> find(
    Map<String, dynamic> source,
    String url,
  ) async {
    await _queues[_path];
    final id = key(source, url);
    return ((await _read())['records'] as List)
        .cast<Map<String, dynamic>>()
        .where((value) => recordKey(value) == id)
        .firstOrNull;
  }

  Future<void> _change(void Function(Map<String, dynamic>) change) {
    final operation = (_queues[_path] ?? Future<void>.value()).then((_) async {
      final state = await _read();
      change(state);
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(state), flush: true);
      await temp.rename(file.path);
    });
    _queues[_path] = operation.catchError((Object _) {});
    return operation;
  }

  Future<void> save(Map<String, dynamic> value) {
    // Capture caller-owned data before awaiting other writes.
    final snapshot = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
    _validate(snapshot);
    return _change((state) {
      final records = state['records'] as List;
      final id = recordKey(snapshot);
      final index = records.indexWhere(
        (r) => recordKey(r as Map<String, dynamic>) == id,
      );
      final previous = index < 0
          ? <String, dynamic>{}
          : records[index] as Map<String, dynamic>;
      final merged = {
        ...previous,
        ...snapshot,
        'shelved': previous['shelved'] == true,
      };
      if (index < 0) {
        records.add(merged);
      } else {
        records[index] = merged;
      }
      state['last'] = id;
    });
  }

  Future<void> addBook(
    Map<String, dynamic> source,
    HtmlBook book, [
    List<SourceChapter> chapters = const [],
  ]) => _change((state) {
    final records = state['records'] as List;
    final id = key(source, '${book.url}');
    final index = records.indexWhere(
      (r) => recordKey(r as Map<String, dynamic>) == id,
    );
    final previous = index < 0
        ? <String, dynamic>{'chapterUrl': '', 'textOffset': 0}
        : records[index] as Map<String, dynamic>;
    final record = {
      ...previous,
      'source': source,
      'book': book.toJson(),
      'shelved': true,
    };
    if (chapters.isNotEmpty) {
      record['chapters'] = chapters
          .map((c) => {'name': c.name, 'url': '${c.url}'})
          .toList();
    }
    _validate(record);
    if (index < 0) {
      records.add(record);
    } else {
      records[index] = record;
    }
  });

  Future<void> updateCatalog(
    Map<String, dynamic> source,
    HtmlBook book,
    List<SourceChapter> chapters,
  ) => _change((state) {
    final records = state['records'] as List;
    final id = key(source, '${book.url}');
    final index = records.indexWhere(
      (r) => recordKey(r as Map<String, dynamic>) == id,
    );
    if (index < 0) return;
    records[index] = {
      ...records[index] as Map<String, dynamic>,
      'book': book.toJson(),
      'chapters': chapters
          .map((c) => {'name': c.name, 'url': '${c.url}'})
          .toList(),
    };
  });

  Future<void> removeBook(Map<String, dynamic> value) => _change((state) {
    final id = recordKey(value);
    for (final entry in state['records'] as List) {
      if (recordKey(entry as Map<String, dynamic>) == id) {
        entry['shelved'] = false;
      }
    }
  });
}
