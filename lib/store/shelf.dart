import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../source/html_source_pipeline.dart';
import '../source/json_source_pipeline.dart' show SourceChapter;
import '../source/source_host_state.dart';
import 'database.dart';
import 'host_state.dart';
import 'ids.dart';
import 'space_store.dart';

/// A Book Source as the pages read it: the space row plus the object it was
/// imported from, because the rule pipeline takes the original JSON, not the
/// columns this build reads (D7).
class ImportedBookSource {
  const ImportedBookSource({required this.id, required this.data});
  final String id;
  final Map<String, dynamic> data;
}

/// The imported object a source row came from; the typed columns are the
/// fallback for a row whose `raw` is empty.
Map<String, dynamic> bookSourceJson(BookSource source) {
  final raw = source.raw;
  if (raw != null) {
    final decoded = jsonDecode(raw);
    if (decoded is Map<String, dynamic>) return decoded;
  }
  return {'bookSourceUrl': source.bookSourceUrl, 'bookSourceName': source.name};
}

/// One shelf book with everything opening it needs: the row, its source, its
/// TOC and its position.
///
/// This replaces the record `online_reading.json` handed out — the same facts,
/// read from the tables instead of trusted from a document.
class ShelfEntry {
  const ShelfEntry({
    required this.book,
    this.source,
    this.chapters = const <BookChapter>[],
    this.progress,
  });

  final ShelfBook book;

  /// Null for a book nothing can open: a legacy import left it behind without
  /// a source, and the shelf shows it as the record it is.
  final BookSource? source;

  final List<BookChapter> chapters;
  final ReadingProgress? progress;

  String get id => book.id;
  String get title => book.title;
  bool get shelved => book.shelved;

  /// The space-local Book Source key; empty for a book no source resolves.
  String get sourceRef => book.sourceRef ?? '';

  /// The source object the rule pipeline takes.
  Map<String, dynamic> get sourceJson =>
      source == null ? const <String, dynamic>{} : bookSourceJson(source!);

  /// The chapter the stored position points at, when the TOC still holds it.
  String? get chapterName {
    final key = progress?.chapterKey;
    if (key == null) return null;
    for (final chapter in chapters) {
      if (chapter.chapterKey == key) return chapter.name;
    }
    return null;
  }

  String get chapterKey => progress?.chapterKey ?? '';

  int get chapterIndex => progress?.chapterIndex ?? 0;

  int get textOffset => progress?.textOffset ?? 0;

  /// The book as the pipeline hands it around: a row is not an `HtmlBook`.
  HtmlBook get htmlBook => HtmlBook(
    url: Uri.parse(book.sourceBookUrl ?? ''),
    title: book.title,
    author: book.author,
    intro: book.intro,
    cover: book.coverUrl,
    lastChapter: book.latestChapterTitle,
  );
}

/// The shelf, over one space's store.
///
/// Everything the shelf reads and writes goes through the space: membership is
/// `books.shelved`, a book's identity is its natural key, the TOC is the
/// `chapters` table, and the position is the `progress` row. The JSON store's
/// rewrite-the-whole-file writes became the store's intent-level ones, so a
/// removal keeps the chapters and the progress instead of editing a document.
class ShelfService {
  ShelfService(this.store, {this.androidId = ''});

  final SpaceStore store;

  /// The installation's opaque `androidId` (ADR 0011 §6) the pages hand to a
  /// source pipeline, read once from the installation manifest.
  final String androidId;

  /// The space's host surface (ADR 0011 §3), which the pages that run a source
  /// hand to their pipeline: one state per space, so a source's cookies, cache
  /// entries and variables are the same across analyses and survive a restart.
  /// It lives here because this is the one handle on a space the pages already
  /// hold.
  late final SourceHostState hostState = SourceHostState(
    persistence: SpaceHostStatePersistence(store),
  );

  Future<void> close() => store.close();

  // --- Reading -------------------------------------------------------------

  /// Every source in the space, as the trial and migration pages list them.
  Future<List<ImportedBookSource>> sources() async => [
    for (final source in await store.allSources())
      ImportedBookSource(
        id: source.bookSourceUrl,
        data: bookSourceJson(source),
      ),
  ];

  /// The online shelf: the shelved books a source can open, in shelf order.
  Future<List<ShelfEntry>> onlineShelf() async =>
      _entries(await store.shelf(kind: 'network', hasSource: true));

  /// The shelf rows nothing can open: no source resolves them, and the local
  /// library does not own them either. They carry a title and a position and
  /// nothing else, so the shelf lists them as the records they are.
  Future<List<ShelfEntry>> migratedBooks() async {
    final local = {for (final book in await store.localBooks()) book.id};
    final rows = (await store.shelf(
      hasSource: false,
    )).where((book) => !local.contains(book.id)).toList();
    return _entries(rows);
  }

  /// The book a source URL and book URL resolve to (D2's natural key), or null
  /// when the space does not have it.
  Future<ShelfEntry?> find(String bookSourceUrl, String bookUrl) async {
    final book = await store.bookByNaturalKey(bookSourceUrl, bookUrl);
    return book == null ? null : _entry(book);
  }

  /// What "continue reading" resumes: the position written last. The JSON
  /// store's single `last` pointer has no column of its own — #18's import
  /// reports that as a loss — but the timestamp the reader writes answers the
  /// same question.
  Future<ShelfEntry?> lastRead() async {
    final progress = await store.latestProgress();
    if (progress == null) return null;
    final book = await store.bookById(progress.bookId);
    if (book == null || book.sourceRef == null) return null;
    return _entry(book);
  }

  // --- Writing -------------------------------------------------------------

  /// Adds a book to the shelf, or re-shelves and refreshes one already there.
  ///
  /// The natural key decides identity, so a re-add keeps the row it had — its
  /// chapters and its progress included — and only a new book is appended to
  /// the shelf order.
  Future<void> add(
    Map<String, dynamic> source,
    HtmlBook book, [
    List<SourceChapter> chapters = const <SourceChapter>[],
  ]) async {
    final row = await _ensureBook(source, book, shelved: true);
    // An existing row keeps its position, its `raw` and its source reference:
    // the fields a Legado import carried must survive an update (D2).
    await store.putBook(
      BooksCompanion(
        id: Value(row.id),
        title: Value(book.title),
        author: Value(book.author),
        intro: Value(book.intro),
        coverUrl: Value(book.cover),
        latestChapterTitle: Value(book.lastChapter),
        shelved: const Value(true),
      ),
    );
    if (chapters.isNotEmpty) {
      await store.putChapters(row.id, _chapterRows(row.id, chapters));
    }
  }

  /// The book a source URL and book URL resolve to, created *off* the shelf
  /// when the space does not have it yet.
  ///
  /// Reading a book nobody added still has to track a position, and a position
  /// belongs to a book row (D4) — the JSON store's positional write did the same
  /// when it appended a record. Merely opening a book's details writes nothing.
  Future<String> ensureBook(Map<String, dynamic> source, HtmlBook book) async =>
      (await _ensureBook(source, book, shelved: false)).id;

  /// Refreshes a book's metadata and replaces its TOC. Membership, position and
  /// progress stay where they are: a refresh is not a re-add.
  Future<void> updateCatalog(
    String bookSourceUrl,
    HtmlBook book,
    List<SourceChapter> chapters,
  ) async {
    final existing = await store.bookByNaturalKey(bookSourceUrl, '${book.url}');
    if (existing == null) return;
    await store.putBook(
      BooksCompanion(
        id: Value(existing.id),
        title: Value(book.title),
        author: Value(book.author),
        intro: Value(book.intro),
        coverUrl: Value(book.cover),
        latestChapterTitle: Value(book.lastChapter),
      ),
    );
    await store.putChapters(existing.id, _chapterRows(existing.id, chapters));
  }

  /// Takes a book off the shelf. Its chapters and its progress stay, so adding
  /// it again puts it back where it was.
  Future<void> remove(String bookId) => store.setShelved(bookId, false);

  /// Writes the position the reader reports, a chapter switch included.
  ///
  /// The line-derived fields of the five-field record keep their values (#20's
  /// writer); what the reader knows — the offset, the chapter it is in and the
  /// timestamp — is what this writes.
  Future<void> saveProgress(
    String bookId, {
    String? chapterKey,
    int? chapterIndex,
    required int textOffset,
  }) => store.putProgress(
    ProgressCompanion(
      bookId: Value(bookId),
      textOffset: Value(textOffset),
      chapterKey: Value(chapterKey),
      chapterIndex: Value(chapterIndex),
      updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
    ),
  );

  // --- Assembly ------------------------------------------------------------

  /// The row a source URL and book URL stand for: the one the natural key
  /// names, or a new one, which is appended to the shelf order and keeps the
  /// object it arrived as.
  Future<ShelfBook> _ensureBook(
    Map<String, dynamic> source,
    HtmlBook book, {
    required bool shelved,
  }) async {
    // A source the space already knows stays as it is: the shelf's job is the
    // book, and an object that arrived from a file must not re-enable a source
    // the user turned off (D7's flags are the product's).
    final sourceUrl = '${source['bookSourceUrl'] ?? ''}';
    final existingSource = sourceUrl.isEmpty
        ? null
        : await store.sourceByUrl(sourceUrl);
    final sourceRow = existingSource ?? await store.putSourceJson(source);
    final bookUrl = '${book.url}';
    final existing = await store.bookByNaturalKey(
      sourceRow.bookSourceUrl,
      bookUrl,
    );
    if (existing != null) return existing;
    final id = mintId('book');
    await store.putBook(
      BooksCompanion.insert(
        id: id,
        kind: const Value('network'),
        sourceRef: Value(sourceRow.bookSourceUrl),
        sourceBookUrl: Value(bookUrl),
        title: book.title,
        author: Value(book.author),
        intro: Value(book.intro),
        coverUrl: Value(book.cover),
        latestChapterTitle: Value(book.lastChapter),
        originName: Value(sourceRow.name),
        shelved: Value(shelved),
        bookOrder: Value(await store.nextBookOrder()),
        raw: Value(jsonEncode(book.toJson())),
      ),
    );
    return (await store.bookById(id))!;
  }

  Future<List<ShelfEntry>> _entries(List<ShelfBook> books) async {
    final entries = <ShelfEntry>[];
    for (final book in books) {
      entries.add(await _entry(book));
    }
    return entries;
  }

  Future<ShelfEntry> _entry(ShelfBook book) async {
    final sourceRef = book.sourceRef;
    return ShelfEntry(
      book: book,
      source: sourceRef == null ? null : await store.sourceByUrl(sourceRef),
      chapters: await store.chaptersOf(book.id),
      progress: await store.progressOf(book.id),
    );
  }

  /// A network chapter's key is its URL (D4): progress refers to the chapter,
  /// not to a position in the TOC, which drifts when the TOC changes.
  static List<BookChapter> _chapterRows(
    String bookId,
    List<SourceChapter> chapters,
  ) => [
    for (var index = 0; index < chapters.length; index++)
      BookChapter(
        bookId: bookId,
        chapterKey: '${chapters[index].url}',
        name: chapters[index].name,
        url: '${chapters[index].url}',
        chapterIndex: index,
      ),
  ];
}
