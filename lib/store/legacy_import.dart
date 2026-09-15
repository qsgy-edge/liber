import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;

import '../local/local_library_service.dart';
import '../migration/migration_service.dart';
import '../source/html_source_pipeline.dart';
import '../source/online_reading_store.dart';
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
      LegacyImportReport(
        imported: false,
        importedAt: previous.importedAt,
        sources: previous.sources,
        books: previous.books,
        chapters: previous.chapters,
        progress: previous.progress,
        localFiles: previous.localFiles,
        losses: previous.losses,
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

  /// Originals renamed aside instead of deleted.
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
/// The work happens in one transaction, the originals are renamed aside rather
/// than deleted, and the merge is non-destructive, so a second (forced) run
/// only advances: sources are keyed by URL, network books by
/// `(sourceRef, sourceBookUrl)`, local books by their root and relative path,
/// groups merge by name, and progress only moves forward.
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
  /// recorded in the space. [retireOriginals] renames the files aside once the
  /// import has been committed; it is off by default so a caller that has not
  /// switched its writers over yet keeps reading what it always read.
  Future<LegacyImportReport> run(
    SpaceStore store, {
    bool force = false,
    bool retireOriginals = false,
  }) async {
    if (!force) {
      final marker = await store.setting(LegacyImportReport.markerKey);
      if (marker != null) {
        return LegacyImportReport.alreadyImported(
          LegacyImportReport.fromJson(
            Map<String, Object?>.from(jsonDecode(marker) as Map),
          ),
        );
      }
    }
    // Nothing to record when there is nothing to import: a later installation of
    // the files still has to be imported.
    if (!await hasLegacyStores()) {
      return const LegacyImportReport(imported: false, importedAt: '');
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
    final retired = await _retire();
    return LegacyImportReport(
      imported: report.imported,
      importedAt: report.importedAt,
      sources: report.sources,
      books: report.books,
      chapters: report.chapters,
      progress: report.progress,
      localFiles: report.localFiles,
      losses: report.losses,
      retired: retired,
    );
  }

  /// `online_reading.json` v2: `{version, last, records[]}`, one record per book
  /// carrying the whole source object, the book, the chapters and the position.
  Future<_Counts> _importOnlineReading(
    SpaceStore store,
    int now,
    List<String> losses,
  ) async {
    if (!await onlineReadingFile.exists()) return const _Counts();
    if (!await _parses(onlineReadingFile, losses)) return const _Counts();

    final legacy = OnlineReadingStore(file: onlineReadingFile);
    final List<Map<String, dynamic>> records;
    try {
      // Every record, shelved or not: a record that was taken off the shelf
      // still holds a book, its chapters and its position.
      records = await legacy.loadRecords();
    } on FormatException catch (error) {
      losses.add('online_reading.json 未导入：${error.message}');
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
      await store.putSource(_sourceCompanion(source));

      final book = HtmlBook.fromJson(
        Map<String, dynamic>.from(record['book'] as Map),
      );
      final bookUrl = '${book.url}';
      final existing = await store.bookByNaturalKey(sourceRef, bookUrl);
      final id = existing?.id ?? mintId('book');
      await store.putBook(
        BooksCompanion.insert(
          id: id,
          title: book.title,
          author: Value(book.author),
          intro: Value(book.intro),
          coverUrl: Value(book.cover),
          sourceRef: Value(sourceRef),
          sourceBookUrl: Value(bookUrl),
          originName: Value('${source['bookSourceName'] ?? sourceRef}'),
          latestChapterTitle: Value(book.lastChapter),
          shelved: Value(record['shelved'] == true),
          raw: Value(jsonEncode(record['book'])),
        ),
      );
      books++;

      final rows = <BookChapter>[];
      final indexes = <String, int>{};
      for (final chapter in (record['chapters'] as List? ?? const <Object?>[])) {
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
          chapterIndex: Value(
            chapterUrl.isEmpty ? null : indexes[chapterUrl],
          ),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    losses.add('在线阅读记录的“上次阅读”指针没有等价字段，未导入');
    return _Counts(
      sources: sources,
      books: books,
      chapters: chapters,
      progress: progress,
    );
  }

  /// `local_books.json`: one root plus the files the user admitted from it.
  Future<_Counts> _importLocalLibrary(
    SpaceStore store,
    int now,
    List<String> losses,
  ) async {
    if (!await localBooksFile.exists()) return const _Counts();
    if (!await _parses(localBooksFile, losses)) return const _Counts();

    final legacy = LocalLibraryService(stateFile: localBooksFile);
    await legacy.load();
    final root = legacy.root;
    if (root == null) {
      losses.add('local_books.json 没有根目录，未导入');
      return const _Counts();
    }
    await store.putLocalRoot(
      LocalRootsCompanion.insert(
        id: root.id,
        displayName: root.displayName,
        needsRelink: Value(root.needsRelink),
      ),
    );

    var books = 0, localFiles = 0, progress = 0, missing = 0;
    for (final book in legacy.books) {
      final relative =
          book.relativePath ??
          book.path.substring(root.displayName.length + 1);
      final exists = await File(book.path).exists();
      if (!exists) missing++;
      // The legacy id is the root plus the path inside it, so the same file
      // keeps the same id without trusting a stale absolute path.
      final id = '${root.id}::$relative'.toLowerCase();
      final existing = await store.localBook(root.id, relative);
      await store.putBook(
        BooksCompanion.insert(
          id: existing?.id ?? id,
          kind: const Value('local'),
          title: book.title,
          rootId: Value(root.id),
          relativePath: Value(relative),
          format: Value(book.format),
          needsRelink: Value(!exists),
          raw: Value(jsonEncode(book.toJson())),
        ),
      );
      books++;

      final stat = exists ? await File(book.path).stat() : null;
      await store.putLocalFile(
        LocalFilesCompanion.insert(
          rootId: root.id,
          relativePath: relative,
          format: Value(book.format),
          modifiedAt: Value(stat?.modified.millisecondsSinceEpoch),
          needsRelink: Value(!exists),
          bookId: Value(existing?.id ?? id),
        ),
      );
      localFiles++;

      final advanced = await store.saveProgress(
        ProgressCompanion.insert(
          bookId: existing?.id ?? id,
          textOffset: Value(book.textOffset),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    losses.add('本地文件字节不导入；文件缺失的书已标记 needsRelink');
    if (missing > 0) losses.add('$missing 个本地文件已不在原路径');
    return _Counts(
      books: books,
      localFiles: localFiles,
      progress: progress,
    );
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
    if (!await _parses(migrationStateFile, losses)) return const _Counts();

    final legacy = MigrationService(stateFile: migrationStateFile);
    await legacy.load();
    var sources = 0, books = 0, progress = 0;
    for (final source in legacy.sources) {
      final url = '${source.data['bookSourceUrl'] ?? source.id}';
      if (url.isEmpty) continue;
      if (await store.sourceByUrl(url) == null) sources++;
      await store.putSource(
        _sourceCompanion(source.data, fallbackId: source.id),
      );
    }
    for (final book in legacy.books) {
      final id = 'legacy-${book.id}';
      await store.putBook(
        BooksCompanion.insert(
          id: id,
          kind: Value(book.needsRelink ? 'local' : 'network'),
          title: book.title,
          needsRelink: Value(book.needsRelink),
          raw: Value(jsonEncode(book.toJson())),
        ),
      );
      books++;
      final advanced = await store.saveProgress(
        ProgressCompanion.insert(
          bookId: id,
          textOffset: Value(book.progressOffset),
          updatedAt: Value(now),
        ),
      );
      if (advanced) progress++;
    }
    if (legacy.books.any((book) => !book.needsRelink)) {
      losses.add('迁移记录里的网络书籍没有 bookSourceUrl，只保留标题与进度');
    }
    return _Counts(sources: sources, books: books, progress: progress);
  }

  /// The legacy services swallow an unparseable file, so the import checks
  /// first and reports the loss instead of quietly importing nothing.
  Future<bool> _parses(File file, List<String> losses) async {
    try {
      jsonDecode(await file.readAsString());
      return true;
    } on FormatException {
      losses.add('${_fileName(file)} 无法解析，已跳过（原文件保留）');
      return false;
    }
  }

  /// Renames the originals aside rather than deleting them.
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
      await file.rename('${folder.path}${Platform.pathSeparator}${_fileName(file)}');
      retired.add(_fileName(file));
    }
    return retired;
  }

  static String _fileName(File file) => file.uri.pathSegments.last;

  /// A source as the store keeps it: the typed fields the product reads, plus
  /// the whole imported object in `raw`.
  static SourcesCompanion _sourceCompanion(
    Map<String, dynamic> source, {
    String? fallbackId,
  }) {
    final url = '${source['bookSourceUrl'] ?? fallbackId ?? ''}';
    return SourcesCompanion.insert(
      bookSourceUrl: url,
      name: '${source['bookSourceName'] ?? url}',
      groupNames: Value(jsonEncode(_groupNames(source['bookSourceGroup']))),
      type: Value(_int(source['bookSourceType'])),
      customOrder: Value(_int(source['customOrder'])),
      enabled: Value(source['enabled'] as bool? ?? true),
      enabledExplore: Value(source['enabledExplore'] as bool? ?? true),
      lastUpdateTime: Value(_int(source['lastUpdateTime'])),
      raw: Value(jsonEncode(source)),
    );
  }

  /// Legado joins groups into a `HashSet` and serializes that comma-joined, so
  /// the order is not meaningful and duplicates are not either.
  static List<String> _groupNames(Object? value) {
    final names = switch (value) {
      String joined => joined.split(','),
      List<Object?> list => list.map((entry) => '$entry'),
      _ => const <String>[],
    };
    return names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  static int _int(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;
}

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
