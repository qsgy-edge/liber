/// The frozen reader's precise search (`WebBook.preciseSearchAwait`,
/// `WebBook.kt:371-390`) and the entry the product builds on it: search a name
/// and an author across Book Sources, keep the exact match, and offer the
/// candidates a reader can switch a book onto.
///
/// The frozen flow this mirrors, read from baseline `14dd24945`:
///
/// * `WebBook.preciseSearchAwait` calls `searchBookAwait(
///   bookSource, name, filter = { fName, fAuthor -> fName == name && fAuthor ==
///   author }, shouldBreak = { it > 0 })` and takes `.firstOrNull()`: the filter
///   admits only a hit whose *formatted* name and author equal the searched
///   ones, and the break stops the page's item loop as soon as one hit passed
///   it. Nothing on the page matching throws
///   `NoStackTraceException("未搜索到 $name($author) 书籍")`.
/// * `WebBook.preciseSearch` walks the sources in order and stops at the first
///   one that produced a book (`:358-370`); nothing anywhere throws
///   `NoStackTraceException("没有搜索到<$name>$author")`. `ReadBookViewModel`'s
///   `autoChangeSource` (`:282-318`) is its reader.
/// * `ChangeBookSourceDialog` is the same search without the cross-source stop:
///   every source is searched, and its own filter is `fName == name &&
///   (!checkAuthor || fAuthor.contains(author))` — by default `checkAuthor` is
///   false (`AppConfig.changeSourceCheckAuthor`,
///   `AppConfig.kt:360-364`; `getPrefBoolean`'s default is false,
///   `utils/ContextExtensions.kt:162`), so a same-name hit by another author is
///   a candidate too.
///
/// [PreciseSearch.searchAll] is the entry's shape and [PreciseSearch.firstExact]
/// the frozen `preciseSearch`'s. Both read one source at a time, in the order
/// they were given: the frozen runs sources concurrently under a thread pool
/// (`mapParallel`/`mapParallelSafe` with `AppConfig.threadCount`), which this
/// product does not, and the requests a source does make are serialized per
/// source by the existing rate limiter (`SourceHostDispatcher` →
/// `SourceRateLimiter`, #42) instead.
///
/// Two divergences from the frozen code, both recorded for #40's evidence:
///
/// * The early stop is applied to the *results*, not to the page parse. The
///   frozen `shouldBreak` stops `BookList.analyzeBookList`'s item loop, so the
///   rules of the items after the first admitted one never run; this product's
///   [BookSourcePipeline.search] returns the whole page, and the loop below
///   stops scanning it at the first exact hit. The list of admitted hits is
///   identical either way.
/// * Both sides of the comparison are formatted. `BookHelp.formatBookName`/
///   `formatBookAuthor` (`BookHelp.kt:466-482`) are applied to the hit in the
///   frozen flow, against a target that was formatted when it entered the shelf;
///   this product's search stage stores the rule's raw text, so the target is
///   formatted here too rather than compared raw against formatted.
library;

import '../store/shelf.dart';
import 'book_source_pipeline.dart';

/// The frozen `AppPattern.nameRegex` (`constant/AppPattern.kt:18`).
final RegExp _nameSuffix = RegExp(r'\s+作\s*者.*|\s+\S+\s+著');

/// The frozen `AppPattern.authorRegex` (`constant/AppPattern.kt:19`).
final RegExp _authorPrefix = RegExp(r'^\s*作\s*者[:：\s]+|\s+著');

/// The frozen `BookHelp.formatBookName` (`BookHelp.kt:466-473`): the author a
/// search page left inside the name field is dropped, then Kotlin's
/// `trim { it <= ' ' }`.
String formatSearchBookName(String name) =>
    _trimSpacesBelow(name.replaceAll(_nameSuffix, ''));

/// The frozen `BookHelp.formatBookAuthor` (`BookHelp.kt:478-483`).
String formatSearchBookAuthor(String author) =>
    _trimSpacesBelow(author.replaceAll(_authorPrefix, ''));

/// Kotlin's `trim { it <= ' ' }`: leading and trailing code units at or below
/// `0x20`, which is neither Dart's `trim()` (it also strips `0x85` and U+00A0)
/// nor Java's `String.trim()` (it stops at `0x20` too, but reads only one
/// argument).
String _trimSpacesBelow(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && value.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && value.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  return value.substring(start, end);
}

/// One book a source's search returned for the searched name, with whether it
/// is the exact name-and-author match the frozen `preciseSearchAwait` filters
/// for.
class PreciseSearchHit {
  const PreciseSearchHit({
    required this.source,
    required this.book,
    required this.exact,
  });

  /// The source object the hit came from, as the pipeline was handed it.
  final Map<String, dynamic> source;

  /// The book the source's search rule produced.
  final HtmlBook book;

  /// Whether the formatted name and author equal the searched ones — the
  /// frozen filter `{ fName, fAuthor -> fName == name && fAuthor == author }`.
  final bool exact;

  String get sourceRef => '${source['bookSourceUrl'] ?? ''}';

  String get sourceName => '${source['bookSourceName'] ?? sourceRef}';
}

/// What one source's search produced: the candidates it admitted, in page
/// order, or why it produced none.
class PreciseSearchOutcome {
  const PreciseSearchOutcome({
    required this.source,
    required this.hits,
    this.failure,
  });

  final Map<String, dynamic> source;
  final List<PreciseSearchHit> hits;

  /// The error the source's search raised, or null when it answered. A source
  /// that fails does not stop the search across the others.
  final String? failure;

  String get sourceRef => '${source['bookSourceUrl'] ?? ''}';

  String get sourceName => '${source['bookSourceName'] ?? sourceRef}';
}

/// Which source of how many is being searched, for a page's progress line.
class PreciseSearchProgress {
  const PreciseSearchProgress({
    required this.sourceName,
    required this.index,
    required this.total,
  });

  final String sourceName;
  final int index;
  final int total;
}

/// One precise search: a name, an author, and how to open a pipeline per
/// source.
///
/// One instance runs one search. [openPipeline] is the page's own pipeline
/// builder — `openBookSourcePipeline` over the space's transport and host
/// state — so a page that already knows how to build one for a source (the
/// browser's `_openPipeline`) builds the same one here, and a test substitutes
/// a scripted pipeline.
class PreciseSearch {
  PreciseSearch({
    required this.name,
    required this.author,
    required this.openPipeline,
    this.checkAuthor = false,
    this.confirm,
  });

  /// The searched name, as the shelf holds the book's title.
  final String name;

  /// The searched author, as the shelf holds it.
  final String author;

  final BookSourcePipeline Function(Map<String, dynamic> source) openPipeline;

  /// The frozen `AppConfig.changeSourceCheckAuthor`: when true a candidate must
  /// also carry [author] inside its author field; false admits any hit whose
  /// name matches. The frozen default is false.
  final bool checkAuthor;

  /// Wraps one source's search, so the page that owns the search can put its
  /// per-source TLS-exception confirmation around that source's own request
  /// (ADR 0011 §5) — the same wrapper every other page that runs a source
  /// applies. Null runs the search bare, which is what the tests do.
  final Future<T> Function<T>(
    Map<String, dynamic> source,
    Future<T> Function() run,
  )?
  confirm;

  /// Searches every source in [sources], in order, and returns what each
  /// produced.
  ///
  /// A source is searched through [openPipeline] and its hits are read in page
  /// order: a hit is admitted when its formatted name equals the searched name
  /// (and, with [checkAuthor], when its formatted author contains the searched
  /// one), and the scan stops at the first *exact* hit — the frozen
  /// `shouldBreak = { it > 0 }`, which the precise filter reaches only on an
  /// exact one. A source that fails is reported as one and the search goes on;
  /// a page that produces only inexact hits contributes those, with
  /// [PreciseSearchHit.exact] false.
  Future<List<PreciseSearchOutcome>> searchAll(
    List<ImportedBookSource> sources, {
    void Function(PreciseSearchProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final outcomes = <PreciseSearchOutcome>[];
    for (var index = 0; index < sources.length; index++) {
      if (isCancelled?.call() == true) break;
      final source = sources[index].data;
      onProgress?.call(
        PreciseSearchProgress(
          sourceName: '${source['bookSourceName'] ?? sources[index].id}',
          index: index + 1,
          total: sources.length,
        ),
      );
      outcomes.add(await searchSource(source, isCancelled: isCancelled));
    }
    return outcomes;
  }

  /// The frozen `WebBook.preciseSearch` (`:358-370`): the first source, in
  /// order, that has an exact hit — or null, which the frozen caller reports as
  /// `没有搜索到<$name>$author`.
  ///
  /// The sources after that one are not searched at all: the frozen returns
  /// from its loop, and `searchSource` is not called for them.
  Future<PreciseSearchHit?> firstExact(
    List<ImportedBookSource> sources, {
    void Function(PreciseSearchProgress progress)? onProgress,
  }) async {
    for (var index = 0; index < sources.length; index++) {
      final source = sources[index].data;
      onProgress?.call(
        PreciseSearchProgress(
          sourceName: '${source['bookSourceName'] ?? sources[index].id}',
          index: index + 1,
          total: sources.length,
        ),
      );
      final outcome = await searchSource(source);
      for (final hit in outcome.hits) {
        if (hit.exact) return hit;
      }
    }
    return null;
  }

  /// One source's search: the frozen `preciseSearchAwait`'s page read, with the
  /// candidate filter the frozen change-source dialog uses around it.
  ///
  /// The source's own failure — an unreadable page, a refused certificate — is
  /// reported as [PreciseSearchOutcome.failure] and does not stop the other
  /// sources.
  Future<PreciseSearchOutcome> searchSource(
    Map<String, dynamic> source, {
    bool Function()? isCancelled,
  }) async {
    try {
      final confirm = this.confirm;
      return await (confirm == null
          ? _readSource(source, isCancelled: isCancelled)
          : confirm(
              source,
              () => _readSource(source, isCancelled: isCancelled),
            ));
    } on Object catch (error) {
      return PreciseSearchOutcome(
        source: source,
        hits: const <PreciseSearchHit>[],
        failure: '$error',
      );
    }
  }

  Future<PreciseSearchOutcome> _readSource(
    Map<String, dynamic> source, {
    bool Function()? isCancelled,
  }) async {
    final pipeline = openPipeline(source);
    try {
      final books = await pipeline.search(name);
      final hits = <PreciseSearchHit>[];
      for (final book in books) {
        if (isCancelled?.call() == true) break;
        final formattedName = formatSearchBookName(book.title);
        if (formattedName != formatSearchBookName(name)) continue;
        final formattedAuthor = formatSearchBookAuthor(book.author);
        final exact = formattedAuthor == formatSearchBookAuthor(author);
        if (!exact && checkAuthor && !formattedAuthor.contains(author)) {
          continue;
        }
        hits.add(PreciseSearchHit(source: source, book: book, exact: exact));
        // The frozen `shouldBreak = { it > 0 }`: the page's item loop ends as
        // soon as one hit passed the precise filter.
        if (exact) break;
      }
      return PreciseSearchOutcome(source: source, hits: hits);
    } finally {
      pipeline.cancel();
    }
  }
}
