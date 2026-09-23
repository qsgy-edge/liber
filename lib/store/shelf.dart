import 'dart:convert';

import 'package:drift/drift.dart' show Value;

import '../source/chapter_position.dart';
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

  /// Whether the Book Source this book resolved is gone from the space (#53):
  /// the book stays on the shelf with everything it had — its chapters, its
  /// position, its denormalized origin name, which D2 keeps for exactly this —
  /// and nothing opens it until a source is imported under the same URL again,
  /// when the natural key resolves it once more.
  bool get sourceMissing => sourceRef.isNotEmpty && source == null;

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

  /// The online shelf: the shelved network books in shelf order, each with
  /// whether a source still resolves it. A book whose source row was deleted
  /// (#53) stays in this list, marked by [ShelfEntry.sourceMissing]: the shelf
  /// keeps showing the record it has instead of dropping the row, which is what
  /// lets the same URL resolve it again.
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

  /// Moves a shelved network book onto another source's copy of the same book,
  /// keeping the row the reader already has.
  ///
  /// [source] is the new Book Source as the space holds it (or as it arrived,
  /// when the space does not hold it yet); [book] and [chapters] are what that
  /// source's book-information and table-of-contents stages produced. The row
  /// keeps its minted id — D2 mints one exactly so a source change does not
  /// rewrite a book's identity, `docs/user-data-contract.md` D2 and the
  /// migration contract's rule 3 — and its `bookOrder`, its `shelved` flag, its
  /// custom title/cover/intro/tag, its group memberships, its per-book settings
  /// and its `raw` all stay where they are. What changes is the source it
  /// resolves, its denormalized origin name, the metadata the new source
  /// answered with, the `chapters` rows, and the position.
  ///
  /// The position moves the way the frozen `Book.migrateTo` moves it
  /// (`data/entities/Book.kt:341-358`, from `ReadBookViewModel.changeTo` and
  /// `BookInfoViewModel.changeTo`): the old chapter's ordinal and title and the
  /// old table of contents' size decide the new ordinal through
  /// [mapChapterIndex], the text offset is carried verbatim (the frozen
  /// `durChapterPos`), and the row's timestamp is left alone (the frozen carries
  /// `durChapterTime` and writes nothing of its own). A book that was never read
  /// has no position row and gets none: merely switching a source does not
  /// invent a position (D4).
  ///
  /// The frozen flow instead *deletes* the old row and inserts a new one, because
  /// its primary key is the book URL; what it carries by hand — group, order,
  /// custom cover/intro/tag, `canUpdate`, the reading config — survives here by
  /// construction. Its `Book.durChapterTitle` still has no column (the migration
  /// contract's family 10 records that gap): the shelf shows the new table of
  /// contents' own chapter name, which is what [ShelfEntry.chapterName] reads.
  ///
  /// A switch to a source that already holds this book as another row is refused
  /// rather than merged: `(name, author)` is only ever a hint in this product
  /// (D2), and the frozen's answer to the same situation is a `REPLACE` that
  /// silently drops one of the two rows (the migration contract's rule 3 records
  /// that the baseline "can overwrite a shelf entry and its progress").
  Future<ShelfEntry> switchSource(
    String bookId,
    Map<String, dynamic> source,
    HtmlBook book,
    List<SourceChapter> chapters,
  ) async {
    final existing = await store.bookById(bookId);
    if (existing == null) throw StateError('书籍不存在：$bookId');
    if (existing.kind != 'network') {
      throw StateError('只有网络书籍可以换源：${existing.title}');
    }
    final sourceUrl = '${source['bookSourceUrl'] ?? ''}';
    if (sourceUrl.isEmpty) throw StateError('书源 URL 不能为空');
    if (chapters.isEmpty) throw StateError('新书源的目录为空，不能换源');
    final bookUrl = '${book.url}';
    final oldChapters = await store.chaptersOf(bookId);
    final progress = await store.progressOf(bookId);
    final oldIndex = progress?.chapterIndex ?? 0;
    final oldTitle = oldIndex >= 0 && oldIndex < oldChapters.length
        ? oldChapters[oldIndex].name
        : null;
    final newIndex = mapChapterIndex(
      oldIndex: oldIndex,
      oldTitle: oldTitle,
      newTitles: [for (final chapter in chapters) chapter.name],
      oldChapterCount: oldChapters.length,
    );
    await store.transaction(() async {
      final existingSource = await store.sourceByUrl(sourceUrl);
      final sourceRow = existingSource ?? await store.putSourceJson(source);
      final clash = await store.bookByNaturalKey(sourceUrl, bookUrl);
      if (clash != null && clash.id != bookId) {
        throw StateError(
          '该书籍已在书源“${sourceRow.name}”下：${clash.title}（$bookUrl）',
        );
      }
      await store.putBook(
        BooksCompanion(
          id: Value(bookId),
          sourceRef: Value(sourceRow.bookSourceUrl),
          sourceBookUrl: Value(bookUrl),
          originName: Value(sourceRow.name),
          title: Value(book.title),
          author: Value(book.author),
          intro: Value(book.intro),
          coverUrl: Value(book.cover),
          latestChapterTitle: Value(book.lastChapter),
        ),
      );
      await store.putChapters(bookId, _chapterRows(bookId, chapters));
      if (progress != null) {
        await store.putProgress(
          ProgressCompanion(
            bookId: Value(bookId),
            chapterKey: Value(chapters[newIndex].storeKey),
            chapterIndex: Value(newIndex),
            textOffset: Value(progress.textOffset),
            // The line fields describe a position inside the *old* source's
            // chapter text, which the switch has just replaced: a companion
            // that left them out would leave the record describing two texts
            // at once. Their zero values are "not derived yet" — the reader
            // re-derives the line index and the anchor when it opens the
            // chapter (D4's five-field record, `LocalLibrary` being the only
            // writer that reads them today).
            lineIndex: const Value(0),
            offsetInLine: const Value(0),
            textLength: const Value(0),
            anchor: const Value(null),
          ),
        );
      }
    });
    return _entry((await store.bookById(bookId))!);
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

  // --- Sources -------------------------------------------------------------

  /// Deletes a Book Source and every row this space keeps for it: its host
  /// surface — cache entries, variables, the cookies it wrote and the TLS
  /// exceptions the user confirmed for it (#36, #53) — and then the `sources`
  /// row itself, in one store transaction.
  ///
  /// The two writes are one user-visible step: the action either completes with
  /// both done or fails with neither, so the half-deleted state (the host rows
  /// reclaimed while the source row is still there) is not something a
  /// completed delete can leave behind.
  ///
  /// The books that resolved this URL stay on the shelf and their progress
  /// stays with them (D2), and [ShelfEntry.sourceMissing] marks them until a
  /// source with that URL exists again. Removing them instead would cost the
  /// user those positions, and the baseline keeps them too.
  Future<void> deleteSource(String sourceRef) async {
    if (await store.sourceByUrl(sourceRef) == null) {
      throw StateError('书源不存在：$sourceRef');
    }
    await store.transaction(() async {
      await hostState.deleteSource(sourceRef);
      await store.deleteSource(sourceRef);
    });
  }

  /// Writes a Book Source under [newUrl], reclaiming what its old URL owned.
  ///
  /// A source's row identity *is* its `bookSourceUrl` (D7), so an edit is the old
  /// URL's host surface going (#36's seam, TLS exceptions included) and the
  /// source written under the new URL through the existing write path — the
  /// imported object's own `bookSourceUrl` field included, because that object
  /// is what the pipeline is handed (D7). One store transaction, like
  /// [deleteSource].
  ///
  /// The books that resolved the old URL are not rewritten to the new one: they
  /// stay on the shelf marked by [ShelfEntry.sourceMissing]. Rewriting them
  /// would rebind a book to a source that never served it and could collide with
  /// the natural key `(sourceRef, sourceBookUrl)` of a book the new URL's source
  /// already has.
  ///
  /// A URL is a key here, not a fetch target: an empty one is refused, a URL
  /// another source already holds is refused instead of overwriting that source,
  /// and an edit that does not change the URL writes nothing.
  Future<void> repointSource(String sourceRef, String newUrl) async {
    final target = newUrl.trim();
    if (target.isEmpty) {
      throw ArgumentError.value(newUrl, 'newUrl', '书源 URL 不能为空');
    }
    if (target == sourceRef) return;
    final source = await store.sourceByUrl(sourceRef);
    if (source == null) throw StateError('书源不存在：$sourceRef');
    if (await store.sourceByUrl(target) != null) {
      throw StateError('已存在同一 URL 的书源：$target');
    }
    final data = {...bookSourceJson(source), 'bookSourceUrl': target};
    await store.transaction(() async {
      await hostState.deleteSource(sourceRef);
      // `fallbackId` keeps a source that arrived without a URL of its own keyed
      // by the URL the user just gave it. `putSourceJson` derives the typed
      // columns from [data], so the row under the new URL keeps the name, the
      // groups and the flags the old row had.
      await store.putSourceJson(data, fallbackId: target);
      await store.deleteSource(sourceRef);
    });
  }

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
  ///
  /// The key stays the bare request target, while `url` keeps the address text
  /// with that target resolved and the TOC rule's option tail kept — the frozen
  /// `BookChapter.url` shape — because the content request parses its options
  /// from it (#58). A row written before this holds a bare target there, which
  /// is address text with no options and parses to itself, so no migration is
  /// needed and no progress key drifts.
  ///
  /// A volume the rules left without a URL has no target: its key and its
  /// address text are both the frozen identity text `title + index`
  /// ([SourceChapter.storeKey]), and the content stage never fetches it.
  static List<BookChapter> _chapterRows(
    String bookId,
    List<SourceChapter> chapters,
  ) => [
    for (var index = 0; index < chapters.length; index++)
      BookChapter(
        bookId: bookId,
        chapterKey: chapters[index].storeKey,
        name: chapters[index].name,
        url: chapters[index].persistedAddress,
        chapterIndex: index,
        tag: chapters[index].tag,
        isVolume: chapters[index].isVolume,
        isVip: chapters[index].isVip,
        isPay: chapters[index].isPay,
      ),
  ];
}
