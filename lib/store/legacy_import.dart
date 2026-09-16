import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;

import '../domain/contracts.dart';
import '../source/html_source_pipeline.dart';
import 'database.dart';
import 'ids.dart';
import 'space_store.dart';
import 'workspace.dart';

/// What the one-time import of the JSON stores carried over, kept in the space
/// so a second run can tell what the first one already did.
class LegacyImportReport {
  const LegacyImportReport({
    required this.imported,
    required this.importedAt,
    this.sources = 0,
    this.books = 0,
    this.chapters = 0,
    this.progress = 0,
    this.localFiles = 0,
    this.losses = const <String>[],
    this.retired = const <String>[],
  });

  /// A run that did nothing because a previous run already imported.
  factory LegacyImportReport.alreadyImported(LegacyImportReport previous) =>
      previous.copyWith(imported: false, retired: const <String>[]);

  LegacyImportReport copyWith({
    bool? imported,
    List<String>? losses,
    List<String>? retired,
  }) => LegacyImportReport(
    imported: imported ?? this.imported,
    importedAt: importedAt,
    sources: sources,
    books: books,
    chapters: chapters,
    progress: progress,
    localFiles: localFiles,
    losses: losses ?? this.losses,
    retired: retired ?? this.retired,
  );

  static const markerKey = 'legacy_import.v1';

  /// Whether this run imported; `false` means the marker was already there.
  final bool imported;
  final String importedAt;
  final int sources;
  final int books;
  final int chapters;
  final int progress;
  final int localFiles;

  /// Data the three files held that this store has no place for. Reported
  /// rather than silently dropped (`docs/user-data-contract.md` D6).
  final List<String> losses;

  /// The name each original now has under `legacy/`; a delta imported after a
  /// retirement gets a name of its own rather than overwriting the copy that
  /// was already there.
  final List<String> retired;

  Map<String, Object?> toJson() => {
    'imported': true,
    'importedAt': importedAt,
    'sources': sources,
    'books': books,
    'chapters': chapters,
    'progress': progress,
    'localFiles': localFiles,
    'losses': losses,
  };

  factory LegacyImportReport.fromJson(Map<String, Object?> json) =>
      LegacyImportReport(
        imported: json['imported'] == true,
        importedAt: json['importedAt'] as String? ?? '',
        sources: (json['sources'] as num?)?.toInt() ?? 0,
        books: (json['books'] as num?)?.toInt() ?? 0,
        chapters: (json['chapters'] as num?)?.toInt() ?? 0,
        progress: (json['progress'] as num?)?.toInt() ?? 0,
        localFiles: (json['localFiles'] as num?)?.toInt() ?? 0,
        losses: (json['losses'] as List? ?? const <Object?>[])
            .map((loss) => '$loss')
            .toList(),
      );

  String summary() => [
    '书源 $sources',
    '书籍 $books',
    '目录 $chapters',
    '进度 $progress',
    '本地文件 $localFiles',
  ].join(' · ');
}

/// Imports the three JSON stores this product wrote before the space store:
/// `online_reading.json`, `local_books.json`, `migration_state.json`.
///
/// This is the only reader of those formats now: the shelf, the local library
/// and the migration page run entirely from the space, and the originals are
/// renamed aside rather than deleted once the import has committed.
///
/// The work happens in one transaction, and the merge is non-destructive: a
/// second (forced) run only adds. Sources are keyed by URL, network books by
/// `(sourceRef, sourceBookUrl)`, local books by their root and relative path,
/// membership unions (the import never unshelves a book the store already has),
/// progress goes through `SpaceStore.saveProgress` and only advances, and the
/// retired file's own record order supplies the shelf order, which no JSON file
/// ever stored as a field.
class LegacyImport {
  LegacyImport({Directory? home}) : home = home ?? Workspace.defaultRoot();

  /// Where the three stores live: `%APPDATA%\Liber`.
  final Directory home;

  /// Where retired originals go once the store is the writer.
  static const legacyFolderName = 'legacy';

  File get onlineReadingFile =>
      File('${home.path}${Platform.pathSeparator}online_reading.json');

  File get localBooksFile =>
      File('${home.path}${Platform.pathSeparator}local_books.json');

  File get migrationStateFile =>
      File('${home.path}${Platform.pathSeparator}migration_state.json');

  /// Whether any of the three stores is still there to import.
  Future<bool> hasLegacyStores() async =>
      await onlineReadingFile.exists() ||
      await localBooksFile.exists() ||
      await migrationStateFile.exists();

  /// Imports everything the three files hold into [store].
  ///
  /// A previous run is a no-op unless [force] is set, because the import is
  /// recorded in the space. The app runs it forced and retiring: the store is
  /// the writer, so a file that is still there is a delta to merge, and the
  /// files themselves are renamed aside instead of deleted.
  ///
  /// With nothing left on disk the report is whatever the space recorded, which
  /// is how a later launch can still say when the import ran.
  Future<LegacyImportReport> run(
    SpaceStore store, {
    bool force = false,
    bool retireOriginals = false,
  }) async {
    final marker = await _marker(store);
    if (!await hasLegacyStores()) {
      return marker == null
          ? const LegacyImportReport(imported: false, importedAt: '')
          : LegacyImportReport.alreadyImported(marker);
    }
    if (!force && marker != null) {
      return LegacyImportReport.alreadyImported(marker);
    }

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    final losses = <String>[];
    late LegacyImportReport report;
    await store.db.transaction(() async {
      final online = await _importOnlineReading(store, now, losses);
      final local = await _importLocalLibrary(store, now, losses);
      final migrated = await _importMigrationState(store, now, losses);
      report = LegacyImportReport(
        imported: true,
        importedAt: DateTime.fromMillisecondsSinceEpoch(
          now,
          isUtc: true,
        ).toIso8601String(),
        sources: online.sources + local.sources + migrated.sources,
        books: online.books + local.books + migrated.books,
        chapters: online.chapters + local.chapters + migrated.chapters,
        progress: online.progress + local.progress + migrated.progress,
        localFiles: local.localFiles,
        losses: losses,
      );
      await store.putSetting(
        LegacyImportReport.markerKey,
        jsonEncode(report.toJson()),
      );
    });

    if (!retireOriginals) return report;
    return report.copyWith(retired: await _retire());
  }

  Future<LegacyImportReport?> _marker(SpaceStore store) async {
    final marker = await store.setting(LegacyImportReport.markerKey);
    if (marker == null) return null;
    return LegacyImportReport.fromJson(
      Map<String, Object?>.from(jsonDecode(marker) as Map),
    );
  }

  /// `online_reading.json` v2: `{version, last, records[]}`, one record per book
  /// carrying the whole source object, the book, the chapters and the position.
  /// A file holding a single record without the envelope is the version this
  /// format replaced.
  Future<_Counts> _importOnlineReading(
    SpaceStore store,
    int now,
    List<String> losses,
  ) async {
    if (!await onlineReadingFile.exists()) return const _Counts();
    final List<Map<String, dynamic>> records;
    try {
      records = await _readOnline();
    } on FormatException catch (error) {
      losses.add('online_reading.json 未导入：${error.message}（原文件保留）');
      return const _Counts();
    }

    var sources = 0, books = 0, chapters = 0, progress = 0;
    for (final record in records) {
      final source = Map<String, dynamic>.from(record['source'] as Map);
      final sourceRef = '${source['bookSourceUrl'] ?? ''}';
      if (sourceRef.isEmpty) {
        losses.add('一条在线阅读记录没有 bookSourceUrl，已跳过');
        continue;
      }
      if (await store.sourceByUrl(sourceRef) == null) sources++;
      await store.putSourceJson(source);

      final book = HtmlBook.fromJson(
        Map<String, dynamic>.from(record['book'] as Map),
      );
      final bookUrl = '${book.url}';
      final existing = await store.bookByNaturalKey(sourceRef, bookUrl);
      final id = existing?.id ?? mintId('book');
      final shelved = record['shelved'] == true;
      await store.putBook(
        BooksCompanion(
          id: Value(id),
          sourceRef: Value(sourceRef),
          sourceBookUrl: Value(bookUrl),
          title: Value(book.title),
          author: Value(book.author),
          intro: Value(book.intro),
          coverUrl: Value(book.cover),
          originName: Value(
            _string(source['bookSourceName'], fallback: sourceRef),
          ),
          latestChapterTitle: Value(book.lastChapter),
          // Membership unions: a re-import never takes a book off the shelf,
          // and a book the store does not have yet takes the record's answer.
          shelved: Value(
            existing == null ? shelved : existing.shelved || shelved,
          ),
          // The retired file's own record order is the shelf order the JSON
          // store had; nothing in it stored a position as a field.
          bookOrder: Value(await _position(store, existing)),
          raw: Value(jsonEncode(record['book'])),
        ),
      );
      books++;

      final rows = <BookChapter>[];
      final indexes = <String, int>{};
      for (final chapter
          in (record['chapters'] as List? ?? const <Object?>[])) {
        if (chapter is! Map) continue;
        final url = '${chapter['url'] ?? ''}';
        if (url.isEmpty) continue;
        indexes.putIfAbsent(url, () => rows.length);
        rows.add(
          BookChapter(
            bookId: id,
            chapterKey: url,
            name: '${chapter['name'] ?? ''}',
            url: url,
            chapterIndex: rows.length,
          ),
        );
      }
      if (rows.isNotEmpty) {
        await store.putChapters(id, rows);
        chapters += rows.length;
      }

      final chapterUrl = '${record['chapterUrl'] ?? ''}';
      final advanced = await store.saveProgress(
        ProgressCompanion.insert(
          bookId: id,
          textOffset: Value(_int(record['textOffset'])),
          chapterKey: Value(chapterUrl.isEmpty ? null : chapterUrl),
          chapterIndex: Value(chapterUrl.isEmpty ? null : indexes[chapterUrl]),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    losses.add('在线阅读记录的“上次阅读”指针没有等价字段，改由最近保存的进度回答');
    return _Counts(
      sources: sources,
      books: books,
      chapters: chapters,
      progress: progress,
    );
  }

  /// The retired `online_reading.json`, read as the shelf read it.
  Future<List<Map<String, dynamic>>> _readOnline() async {
    final raw = jsonDecode(await onlineReadingFile.readAsString());
    if (raw is! Map<String, dynamic>) {
      throw const FormatException('在线阅读文件格式错误');
    }
    if (raw.containsKey('source')) {
      _validateOnlineRecord(raw);
      return [raw];
    }
    if (raw['version'] != 2 || raw['records'] is! List) {
      throw const FormatException('在线阅读文件版本不受支持');
    }
    final records = <Map<String, dynamic>>[];
    for (final value in raw['records'] as List) {
      if (value is! Map<String, dynamic>) {
        throw const FormatException('非法书架条目');
      }
      _validateOnlineRecord(value);
      records.add(value);
    }
    return records;
  }

  static void _validateOnlineRecord(Map<String, dynamic> value) {
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

  /// `local_books.json`: one root plus the files the user admitted from it.
  Future<_Counts> _importLocalLibrary(
    SpaceStore store,
    int now,
    List<String> losses,
  ) async {
    if (!await localBooksFile.exists()) return const _Counts();
    final Object? decoded;
    try {
      decoded = jsonDecode(await localBooksFile.readAsString());
    } on FormatException {
      losses.add('local_books.json 无法解析，已跳过（原文件保留）');
      return const _Counts();
    }
    if (decoded is! Map<String, dynamic>) {
      losses.add('local_books.json 没有根目录，未导入');
      return const _Counts();
    }
    final rootEntry = decoded['root'];
    if (rootEntry is! Map) {
      losses.add('local_books.json 没有根目录，未导入');
      return const _Counts();
    }
    final displayName = _string(rootEntry['displayName']);
    final rootId = _string(
      rootEntry['id'],
      fallback: displayName.toLowerCase(),
    );
    if (displayName.isEmpty || rootId.isEmpty) {
      losses.add('local_books.json 没有根目录，未导入');
      return const _Counts();
    }
    await store.putLocalRoot(
      LocalRootsCompanion(
        id: Value(rootId),
        displayName: Value(displayName),
        needsRelink: Value(!await Directory(displayName).exists()),
      ),
    );

    var books = 0, localFiles = 0, progress = 0, missing = 0;
    for (final entry
        in (decoded['books'] as List? ?? const <Object?>[]).whereType<Map>()) {
      final path = _string(entry['path']);
      var relative = _string(entry['relativePath']);
      if (relative.isEmpty &&
          path.isNotEmpty &&
          path.length > displayName.length) {
        relative = path.substring(displayName.length + 1);
      }
      if (relative.isEmpty) continue;
      final format = _string(entry['format'], fallback: 'txt');
      final title = _string(entry['title'], fallback: relative);
      final exists = path.isNotEmpty && await File(path).exists();
      if (!exists) missing++;
      // The natural key is the root plus the path inside it; a book the store
      // does not have yet gets a minted id, like every other book (D2).
      final existing = await store.localBook(rootId, relative);
      final id = existing?.id ?? mintId('book');
      await store.putBook(
        BooksCompanion(
          id: Value(id),
          kind: const Value('local'),
          title: Value(title),
          rootId: Value(rootId),
          relativePath: Value(relative),
          format: Value(format),
          needsRelink: Value(!exists),
          bookOrder: Value(await _position(store, existing)),
          raw: Value(jsonEncode(entry)),
        ),
      );
      books++;

      final stat = exists ? await File(path).stat() : null;
      await store.putLocalFile(
        LocalFilesCompanion(
          rootId: Value(rootId),
          relativePath: Value(relative),
          format: Value(format),
          modifiedAt: Value(stat?.modified.millisecondsSinceEpoch),
          needsRelink: Value(!exists),
          bookId: Value(id),
        ),
      );
      localFiles++;

      final advanced = await store.saveProgress(
        ProgressCompanion.insert(
          bookId: id,
          textOffset: Value(_int(entry['textOffset'])),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    losses.add('本地文件字节不导入；文件缺失的书已标记 needsRelink');
    if (missing > 0) losses.add('$missing 个本地文件已不在原路径');
    return _Counts(books: books, localFiles: localFiles, progress: progress);
  }

  /// `migration_state.json`: what an earlier Legado JSON import left behind.
  /// These books carry no natural key, so their deterministic id is the legacy
  /// key itself and the whole entry stays in `raw`.
  Future<_Counts> _importMigrationState(
    SpaceStore store,
    int now,
    List<String> losses,
  ) async {
    if (!await migrationStateFile.exists()) return const _Counts();
    final Object? decoded;
    try {
      decoded = jsonDecode(await migrationStateFile.readAsString());
    } on FormatException {
      losses.add('migration_state.json 无法解析，已跳过（原文件保留）');
      return const _Counts();
    }
    if (decoded is! Map<String, dynamic>) return const _Counts();

    var sources = 0, books = 0, progress = 0, network = 0;
    for (final entry
        in (decoded['sources'] as List? ?? const <Object?>[])
            .whereType<Map>()) {
      final data = entry['data'] is Map
          ? Map<String, dynamic>.from(entry['data'] as Map)
          : <String, dynamic>{};
      final url = '${data['bookSourceUrl'] ?? entry['id'] ?? ''}';
      if (url.isEmpty) continue;
      if (await store.sourceByUrl(url) == null) sources++;
      await store.putSourceJson(data, fallbackId: _string(entry['id']));
    }
    for (final entry
        in (decoded['books'] as List? ?? const <Object?>[]).whereType<Map>()) {
      final legacyId = _string(entry['id']);
      if (legacyId.isEmpty) continue;
      final id = 'legacy-$legacyId';
      final needsRelink = entry['needsRelink'] == true;
      final existing = await store.bookById(id);
      await store.putBook(
        BooksCompanion(
          id: Value(id),
          kind: Value(needsRelink ? 'local' : 'network'),
          title: Value(_string(entry['title'], fallback: legacyId)),
          needsRelink: Value(needsRelink),
          bookOrder: Value(await _position(store, existing)),
          raw: Value(jsonEncode(entry)),
        ),
      );
      books++;
      if (!needsRelink) network++;
      final advanced = await store.saveProgress(
        ProgressCompanion.insert(
          bookId: id,
          textOffset: Value(_int(entry['progressOffset'])),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    if (network > 0) {
      losses.add('迁移记录里的网络书籍没有 bookSourceUrl，只保留标题与进度');
    }
    return _Counts(sources: sources, books: books, progress: progress);
  }

  /// Renames the originals aside rather than deleting them.
  ///
  /// A copy that is already there is not overwritten: it is the older state of
  /// the same file, and both copies are worth keeping, so a delta that arrived
  /// after retirement gets a name of its own.
  Future<List<String>> _retire() async {
    final folder = Directory(
      '${home.path}${Platform.pathSeparator}$legacyFolderName',
    );
    await folder.create(recursive: true);
    final retired = <String>[];
    for (final file in [
      onlineReadingFile,
      localBooksFile,
      migrationStateFile,
    ]) {
      if (!await file.exists()) continue;
      final name = _fileName(file);
      var target = File('${folder.path}${Platform.pathSeparator}$name');
      if (await target.exists()) {
        target = File(
          '${folder.path}${Platform.pathSeparator}$name.'
          '${DateTime.now().toUtc().millisecondsSinceEpoch}',
        );
      }
      await file.rename(target.path);
      retired.add(_fileName(target));
    }
    return retired;
  }

  static String _fileName(File file) => file.uri.pathSegments.last;
}

/// Imports a Legado backup JSON — what the 迁移 page's file picker hands over —
/// into the space.
///
/// The input is a Legado export, not Liber's own interchange envelope (the
/// envelope in `docs/compatibility/legado-data-migration-contract.md` is still
/// unimplemented): sources come from `bookSources` / `bookSource`, books from
/// `books` / `bookshelf` and progress from `progress` / `bookProgress`, which is
/// what the retired `MigrationService` accepted.
///
/// Books merge on the backup's own key, because a Legado bookshelf entry carries
/// no `sourceRef` to match `(sourceRef, sourceBookUrl)` on: the deterministic
/// `legacy-<key>` id keeps a re-import from duplicating a book, and an entry
/// without any key at all is reported rather than given an unstable one. A local
/// entry keeps its Android path in `raw` and in that key, which migration
/// contract rule 4 has not replaced yet. Nothing of ours is written beside the
/// space database to hold any of it.
class LegadoBackupImport {
  LegadoBackupImport(this.store);

  final SpaceStore store;

  /// Parses [jsonText] and merges it into the space in one transaction, so a
  /// failure cannot leave half a backup behind. Throws [FormatException] when
  /// the file is not a Legado backup object.
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

    final now = DateTime.now().toUtc().millisecondsSinceEpoch;
    await store.db.transaction(() async {
      for (final raw in sources.whereType<Map>()) {
        final data = Map<String, dynamic>.from(raw);
        final url = _string(data['bookSourceUrl']);
        final name = _string(data['bookSourceName']);
        if (url.isEmpty && name.isEmpty) {
          losses.add('一条书源既没有 URL 也没有名字，已跳过');
          continue;
        }
        await store.putSourceJson(data, fallbackId: url.isEmpty ? name : null);
      }
      for (final raw in books.whereType<Map>()) {
        final data = Map<String, dynamic>.from(raw);
        final legacyId = _string(
          data['bookUrl'] ?? data['bookId'] ?? data['name'],
        );
        if (legacyId.isEmpty) {
          losses.add('一条书架记录没有 bookUrl/bookId/name，已跳过');
          continue;
        }
        final id = 'legacy-$legacyId';
        final needsRelink =
            '${data['bookUrl'] ?? ''}'.startsWith('file:') ||
            '${data['bookPath'] ?? ''}'.isNotEmpty;
        final existing = await store.bookById(id);
        await store.putBook(
          BooksCompanion(
            id: Value(id),
            kind: Value(needsRelink ? 'local' : 'network'),
            title: Value('${data['name'] ?? data['bookName'] ?? '未命名书籍'}'),
            needsRelink: Value(needsRelink),
            shelved: Value(existing?.shelved ?? true),
            bookOrder: Value(await _position(store, existing)),
            raw: Value(jsonEncode(data)),
          ),
        );
        await store.saveProgress(
          ProgressCompanion.insert(
            bookId: id,
            textOffset: Value(_backupProgress(progress, legacyId)),
            updatedAt: Value(now),
          ),
        );
      }
    });
    return MigrationImportRecord(
      sourceCount: sources.length,
      bookCount: books.length,
      progressCount: progress.length,
      losses: losses,
    );
  }

  static int _backupProgress(List<dynamic> progress, String bookId) {
    for (final raw in progress.whereType<Map>()) {
      final data = Map<String, dynamic>.from(raw);
      if ('${data['bookId'] ?? data['bookUrl'] ?? ''}' != bookId) continue;
      return _int(data['textOffset'] ?? data['durChapterIndex']);
    }
    return 0;
  }

  static List<dynamic> _list(Map<String, dynamic> data, List<String> keys) {
    for (final key in keys) {
      final value = data[key];
      if (value is List) return value;
      if (value is Map) return value.values.toList();
    }
    return const <dynamic>[];
  }
}

/// The position an imported record takes.
///
/// A book the store never positioned takes the next free one — counting from 1,
/// because 0 is what a row the store never positioned has — and a book the
/// store already placed keeps its place, so a restored backup appends what is
/// new instead of reordering the shelf.
Future<int> _position(SpaceStore store, ShelfBook? existing) async {
  if (existing != null && existing.bookOrder != 0) return existing.bookOrder;
  final next = await store.nextBookOrder();
  return next == 0 ? 1 : next;
}

/// The three files were written by this product, so a damaged one is reported
/// and skipped rather than trusted: the import works from the values it can
/// read and says what it could not.
String _string(Object? value, {String fallback = ''}) =>
    value is String && value.isNotEmpty ? value : fallback;

int _int(Object? value) =>
    value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

class _Counts {
  const _Counts({
    this.sources = 0,
    this.books = 0,
    this.chapters = 0,
    this.progress = 0,
    this.localFiles = 0,
  });

  final int sources;
  final int books;
  final int chapters;
  final int progress;
  final int localFiles;
}
