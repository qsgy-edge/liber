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
/// [PreciseSearch.searchAll] is the dialog's shape and
/// [PreciseSearch.firstExact] the frozen `preciseSearch`'s. `searchAll` walks
/// several sources at once, the way the dialog does — its
/// `mapParallel(threadCount)` on a pool of `min(threadCount, MAX_THREAD)`
/// threads, which is nine by default — and hands each source's answer on as it
/// arrives (#108). `firstExact` stays one source at a time and in the given
/// order, because the frozen `preciseSearch`'s loop is. The requests one source
/// does make are serialized per source by the existing rate limiter
/// (`SourceHostDispatcher` → `SourceRateLimiter`, #42) — a per-source rule,
/// not the walk's concurrency.
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

import 'dart:async';

import '../store/shelf.dart';
import 'book_source_pipeline.dart';

/// Raised where the frozen `ChangeBookSourceViewModel.search`'s per-source
/// `withTimeout(60000L)` runs out (`:237-243`), the shape
/// `SourceWebViewTimeout` already has.
///
/// The frozen swallows it and the walk goes on to the next source; this product
/// records the source as one that did not answer
/// ([PreciseSearchOutcome.failure]) so a hanging site is visible on the page.
class SourceSearchTimeout implements Exception {
  const SourceSearchTimeout(this.timeout);

  /// The budget that ran out.
  final Duration timeout;

  @override
  String toString() => '书源搜索超时（${timeout.inSeconds} 秒）';
}

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

/// Which source of how many is being searched, for [PreciseSearch.firstExact]'s
/// progress hook. The parallel walk reports its own progress instead: each
/// source's answer is the event the page's line is made of.
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
    this.concurrency = defaultConcurrency,
    this.sourceTimeout = defaultSourceTimeout,
  });

  /// The frozen dialog's effective default bound on its walk: `threadCount`
  /// (`AppConfig.threadCount`, `AppConfig.kt:232-235`) defaults to **16**, the
  /// pool the dialog walks on is
  /// `Executors.newFixedThreadPool(min(threadCount, AppConst.MAX_THREAD))`
  /// (`ChangeBookSourceViewModel.kt:165-168`) and `AppConst.MAX_THREAD` is
  /// **9** (`AppConst.kt:25`), so nine sources are in flight by default. The
  /// product has no thread-count preference, so the walk takes that effective
  /// default.
  static const int defaultConcurrency = 9;

  /// The frozen `withTimeout(60000L)` around one source of the dialog's
  /// candidate search (`ChangeBookSourceViewModel.kt:237-243`) — the walk
  /// [searchAll] implements. The frozen's other walks have their own numbers and
  /// are not this one: its search *page* bounds a source's search at 30 s
  /// (`SearchModel.kt:86-87`) and the dialog's candidate *refresh*, which loads
  /// each candidate's book information rather than searching, at 60 s
  /// (`ChangeBookSourceViewModel.kt:382-384`); the auto walk this product's
  /// [firstExact] feeds has no coroutine timeout at all (`ReadBookViewModel.kt:294`),
  /// only the transport's own OkHttp bounds (`HttpHelper.kt:57-61`).
  static const Duration defaultSourceTimeout = Duration(seconds: 60);

  /// How many of the walk's sources [searchAll] searches at once. The frozen's
  /// effective default is [defaultConcurrency]; a test sets 2 or 3 to prove the
  /// bound without nine scripted sources.
  final int concurrency;

  /// How long one source's search may take before [searchAll] records that
  /// source as failed and gives its slot to the next one —
  /// [defaultSourceTimeout], the frozen's own number for this walk.
  final Duration sourceTimeout;

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

  /// The pipelines this search's sources have open right now, by the source map
  /// they were opened for — the identity the walk handed in — so a walk that
  /// stops, or one source that runs out of its time, can cancel the request in
  /// flight: [BookSourcePipeline.cancel] is what closes a request's client
  /// (`http_source_transport.dart`), the same call a page's dispose makes. A
  /// pipeline leaves the map when its source's read returns.
  ///
  /// One instance runs one search, so this map is exactly the running walk's.
  final Map<Map<String, dynamic>, BookSourcePipeline> _openPipelines = {};

  /// Searches every source in [sources] and yields what each one produced, as
  /// soon as that source answers.
  ///
  /// This is the frozen change-source dialog's walk
  /// (`ChangeBookSourceViewModel.search`, `:226-256`): at most [concurrency]
  /// sources are searched at a time — the frozen's `mapParallel(threadCount)`
  /// (`:236`) on its pool of `min(threadCount, MAX_THREAD)` threads — and the
  /// outcomes are emitted in completion order, exactly as the frozen's
  /// `flatMapMerge` emits them. A source that does not answer within
  /// [sourceTimeout] is reported as a failure, **its request is cancelled**, and
  /// its slot goes to the next source: the frozen's own `withTimeout(60000L)`
  /// around the same stage, whose `Call.await` cancels the call with the
  /// coroutine (`help/http/OkHttpUtils.kt:63-77`), so one hanging site cannot
  /// hold a slot or a connection.
  ///
  /// One source's own read is [searchSource]: its hits are read in page order, a
  /// hit is admitted when its formatted name equals the searched name (and, with
  /// [checkAuthor], when its formatted author contains the searched one), and
  /// the scan stops at the first *exact* hit — the frozen
  /// `shouldBreak = { it > 0 }`. A source that fails is reported as one and the
  /// walk goes on; a page that produces only inexact hits contributes those,
  /// with [PreciseSearchHit.exact] false.
  ///
  /// A caller that wants the sources' own order re-orders by the list it
  /// handed in; `precise_search_page.dart` does, so its candidate list keeps
  /// the source order however the answers arrive. No "first" decision is made
  /// here: the frozen's first-that-answers walk is [firstExact], which stays
  /// sequential and in order.
  ///
  /// The walk ends when every source has answered. Cancelling the subscription
  /// — or [isCancelled] turning true — stops it: no source after the ones
  /// already in flight is searched, the pipelines those sources have open are
  /// cancelled (the same [BookSourcePipeline.cancel] a page's dispose calls),
  /// and the cancellation completes only once those searches have settled.
  Stream<PreciseSearchOutcome> searchAll(
    List<ImportedBookSource> sources, {
    bool Function()? isCancelled,
  }) {
    final controller = StreamController<PreciseSearchOutcome>();

    /// The searches that have not settled yet: as many as [concurrency] while
    /// there are sources left, plus whatever a stop leaves in flight.
    final inFlight = <Future<void>>{};
    var next = 0;
    var stopped = false;
    var done = false;

    bool shouldStop() => stopped || (isCancelled?.call() ?? false);

    /// Closes the walk, and closes the pipelines of the sources still in flight
    /// so a stopped run leaves nothing running behind its closed stream.
    void end() {
      if (done) return;
      done = true;
      for (final pipeline in _openPipelines.values.toList()) {
        pipeline.cancel();
      }
      unawaited(controller.close());
    }

    /// Starts one source's search; its slot is freed when its future settles.
    void launch() {
      final source = sources[next++].data;
      late final Future<void> running;
      running = searchSource(source, isCancelled: shouldStop)
          .timeout(
            sourceTimeout,
            // The frozen's `withTimeout` cancels the coroutine and its
            // `Call.await` cancels the call with it; this product stops the same
            // request through the pipeline's own cancel, so a timed-out source
            // is not left holding a connection while the walk goes on. The
            // outcome is the failure this product reports, not the frozen's
            // silence.
            onTimeout: () {
              _openPipelines[source]?.cancel();
              return PreciseSearchOutcome(
                source: source,
                hits: const <PreciseSearchHit>[],
                failure: '${SourceSearchTimeout(sourceTimeout)}',
              );
            },
          )
          .then((outcome) {
            inFlight.remove(running);
            if (!done && !shouldStop()) controller.add(outcome);
          });
      inFlight.add(running);
    }

    controller
      ..onListen = () async {
        while (!done) {
          while (!shouldStop() &&
              next < sources.length &&
              inFlight.length < concurrency) {
            launch();
          }
          if (inFlight.isEmpty) break;
          await Future.any(inFlight);
        }
        end();
      }
      ..onCancel = () async {
        stopped = true;
        end();
        // The run is over once the sources already in flight are: a caller that
        // cancels the subscription (the page's dispose) can rely on no search of
        // this run still running when the cancellation completes.
        await Future.wait(inFlight.toList());
      };
    return controller.stream;
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
    _openPipelines[source] = pipeline;
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
      _openPipelines.remove(source);
    }
  }
}
