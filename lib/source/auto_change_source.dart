import '../settings/auto_change_source.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'precise_search.dart';

/// The frozen reader's automatic switch-source
/// (`ReadBookViewModel.autoChangeSource`, `:280-325`): a book whose Book Source
/// is gone is moved onto the first enabled source that proves it carries the
/// same book, keeping the reading position.
///
/// The trigger this mirrors is the frozen reader's own (`:139-142`): after a
/// book's chapter list is loaded,
/// `if (!book.isLocal && ReadBook.bookSource == null) autoChangeSource(...)` —
/// the reader opens the book and switches it instead of showing a dead record.
/// The product has no reader for a book with no source to open, so its entry is
/// the shelf row a deleted source left behind ([ShelfEntry.sourceMissing], #53):
/// opening that row runs this.
///
/// One source at a time, in the frozen's own candidate order
/// (`appDb.bookSourceDao.allTextEnabledPart` — enabled text sources by
/// `customOrder`), the frozen runs the whole chain and swallows that source's
/// failure (`mapParallelSafe`). A source that answers nothing — or answers the
/// search and then cannot produce a chapter list or its own content — is simply
/// not a candidate:
///
/// 1. `WebBook.preciseSearchAwait(source, name, author)` (`:378-395`): the
///    page's first hit whose formatted name **and** author equal the book's,
///    with `formatSearchBookName`/`formatSearchBookAuthor` and the
///    `shouldBreak = { it > 0 }` early stop. [PreciseSearch.searchSource]
///    carries exactly that, and its `hit.exact` is that filter.
/// 2. `getBookInfoAwait` when the hit carried no `tocUrl`, then
///    `getChapterListAwait` (`:294-297`): the candidate's own page and a
///    non-empty table of contents. The product runs the book-information and
///    table-of-contents stages together ([BookSourcePipeline.details]), which is
///    what the manual 换源 flow already runs — a recorded composition, not a new
///    stage order.
/// 3. `WebBook.getContentAwait` for the chapter at the *fresh* search book's
///    `durChapterIndex` (`:298-306`). The frozen reads
///    `toc.getOrElse(book.durChapterIndex) { toc.last() }` on the book its own
///    search produced — a fresh row, so index 0, the table of contents' first
///    chapter — and a candidate is accepted only when **that content request
///    answers**. This is the check a search hit alone cannot make: a source that
///    lists the book but serves no chapter is not a candidate.
/// 4. `take(1)` then `changeTo(book, toc)` (`:313-314`, `:259-277`): the first
///    candidate that got this far wins, and the switch is written with
///    [ShelfService.switchSource] — the position mapping (`Book.migrateTo`) the
///    manual flow writes, the book's row and id kept.
///
/// Divergences, all recorded for #69's evidence:
///
/// * The frozen walks its sources through a thread pool (`mapParallelSafe`) and
///   takes whichever candidate finishes first; this walks them one at a time and
///   takes the first *accepting* source. The walk is the store's own order,
///   `customOrder` then `bookSourceUrl` (`SpaceStore.allSources`,
///   `lib/store/space_store.dart:119-124`), and a source that carries no
///   `customOrder` — what the importers here write, and the common case — sits
///   at 0, so equal orders are broken by URL where the frozen keeps its own scan
///   order.
/// * Per-source failures are swallowed (`mapParallelSafe`) and the toast names
///   only `没有合适书源`, which is what this reports too.
/// * A source with an empty or missing `ruleContent.content` is accepted there
///   and refused here. The frozen returns the chapter's own URL **without a
///   request** (`WebBook.kt:303-306`); both product adapters refuse the stage by
///   name (`html_source_pipeline.dart:1208` → `:580`,
///   `json_source_pipeline.dart:923` → `:554`) and this flow swallows that, so
///   the source is skipped. Kept as it stands — the product's reader refuses
///   such a source too (the recorded #40 choice), so switching onto it would
///   produce a book nothing can read. Measured on the operator's library: **0 of
///   the 150 used sources** have an empty or missing `ruleContent.content`,
///   while **120 of the full 8787-source collection** do (the used set is
///   `bookshelf.json`'s origins resolved against `bookSource.json`), so the
///   divergence is unobservable in the used set.
/// * A write that fails is reported here as `自动换源失败\n…`; the frozen
///   `changeTo`'s own `onError` only logs `换源失败` (`:271-276`) and shows no
///   toast.
/// * The frozen `changeTo` reloads the reader's content in place, where the
///   caller here opens the switched book (the shelf pushes its reader for it).
/// * The trigger covers a shelf row whose source row was deleted
///   ([ShelfEntry.sourceMissing], `sourceRef` present). A book with no origin at
///   all — the non-openable migrated records (`lib/main.dart:807-826`) — has no
///   reader and no switch entry, where the frozen's `ReadBook.bookSource == null`
///   check would fire for it were it open.
///
/// The identity the switch keeps is D2's and lives in
/// [ShelfService.switchSource] (`lib/store/shelf.dart:240-274`); this flow does
/// not restate it.
///
/// The one value the frozen passes that is easy to misread: its "next chapter"
/// for the content check is `toc.getOrElse(chapter.index) { toc.first() }` — the
/// chapter's own index in the list, which is 0 for the chapter it just took — so
/// the URL handed to the content stage is that same chapter's. It is passed on
/// as it stands.
///
/// The result is `(switched, ran)`: the switched entry when a candidate was
/// accepted, and whether the switch ran to its own end. `ran` is false when
/// `source.auto_change` is off — the frozen `if (!AppConfig.autoChangeSource)
/// return`, read before any source is asked — and when [isCancelled] stopped the
/// run (its owner is gone, so the caller has nothing to report). A run that
/// finished without accepting a source has no `switched` and `ran` true: the
/// caller reports the frozen `没有合适书源`.
Future<({ShelfEntry? switched, bool ran})> autoChangeSource({
  required ShelfService service,

  /// The book the reader would have opened: its name and author are what the
  /// sources are searched for, and its row is what a switch rewrites.
  required ShelfEntry book,
  required BookSourcePipeline Function(Map<String, dynamic> source) openPipeline,

  /// Wraps one source's stage, so the page that owns the switch can put its
  /// per-source TLS-exception confirmation around that source's own requests
  /// (ADR 0011 §5), the way the manual search and switch do. Null runs the
  /// stages bare, which is what the tests do.
  Future<T> Function<T>(
    Map<String, dynamic> source,
    Future<T> Function() run,
  )?
  confirm,

  /// Whether the caller has gone away, the way
  /// [PreciseSearch.searchSource]'s own hook works: a cancelled run stops at its
  /// next check instead of walking the rest of the sources — and never writes.
  /// Null never cancels, which is what the tools do.
  bool Function()? isCancelled,
}) async {
  if (!await AutoChangeSourceSetting.resolve(service.store)) {
    return (switched: null, ran: false);
  }
  final search = PreciseSearch(
    name: book.title,
    author: book.book.author,
    openPipeline: openPipeline,
    confirm: confirm,
  );
  for (final candidate in await service.sources()) {
    if (isCancelled?.call() == true) return (switched: null, ran: false);
    if (!_isAutomaticCandidate(candidate.data)) continue;
    final outcome = await search.searchSource(
      candidate.data,
      isCancelled: isCancelled,
    );
    if (isCancelled?.call() == true) return (switched: null, ran: false);
    // `preciseSearchAwait`'s filter: the formatted name **and** author equal the
    // book's. A near hit the manual dialog would admit is not a candidate here.
    final exact = outcome.hits.where((admitted) => admitted.exact);
    if (exact.isEmpty) continue;
    final verified = await _verifiedCandidate(
      source: candidate.data,
      hit: exact.first,
      openPipeline: openPipeline,
      confirm: confirm,
    );
    if (verified == null) continue;
    if (isCancelled?.call() == true) return (switched: null, ran: false);
    // The write is outside the per-source swallow: the frozen's `changeTo` runs
    // after `take(1)`, so a switch that cannot be written (the candidate's book
    // is already on the shelf as another row) fails the flow instead of
    // silently walking on to the next source.
    final (details, chapters) = verified;
    return (
      switched: await service.switchSource(
        book.id,
        candidate.data,
        details,
        chapters,
      ),
      ran: true,
    );
  }
  return (switched: null, ran: true);
}

/// The frozen `allTextEnabledPart`'s own two filters: the source is enabled and
/// its `bookSourceType` is text (0), which the imported object's field carries
/// the way the store's `type` column was derived from it.
bool _isAutomaticCandidate(Map<String, dynamic> source) =>
    source['enabled'] != false && '${source['bookSourceType'] ?? 0}' == '0';

/// One candidate's proof, or null when this source cannot carry the book.
///
/// This is the frozen's per-source chain (`:294-306`), whose own failure
/// `mapParallelSafe` swallows: an unreadable page, an empty table of contents
/// (`getChapterListAwait` throws `TocEmptyException`) or a content request that
/// does not answer all leave the source out and the next one is asked.
Future<(HtmlBook, List<SourceChapter>)?> _verifiedCandidate({
  required Map<String, dynamic> source,
  required PreciseSearchHit hit,
  required BookSourcePipeline Function(Map<String, dynamic> source) openPipeline,
  Future<T> Function<T>(
    Map<String, dynamic> source,
    Future<T> Function() run,
  )?
  confirm,
}) async {
  final pipeline = openPipeline(source);
  Future<T> run<T>(Future<T> Function() analysis) =>
      confirm == null ? analysis() : confirm<T>(source, analysis);
  try {
    final (details, chapters) = await run(() => pipeline.details(hit.book));
    if (chapters.isEmpty) return null;
    // `toc.getOrElse(book.durChapterIndex) { toc.last() }` on the fresh search
    // book: index 0. `chapter.index` is 0 too, so the frozen's "next chapter"
    // URL is this same chapter's.
    final chapter = chapters.first;
    await run(
      () => pipeline.chapter(
        chapter,
        book: details,
        nextChapterUrl: '${chapters.first.url}',
      ),
    );
    return (details, chapters);
  } on Object {
    return null;
  } finally {
    pipeline.cancel();
  }
}
