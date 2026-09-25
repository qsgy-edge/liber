import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'html_source_browser.dart';
import 'http_source_transport.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'precise_search.dart';
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// The product's one multi-source search entry: the frozen precise search over
/// the selected Book Sources, with the candidates a reader can pick from.
///
/// Two frozen flows come through here (`lib/source/precise_search.dart` carries
/// the mapping):
///
/// * opened with no book, it is the search entry: type a name and an author,
///   search the selected sources, and picking a candidate opens it
///   (`HtmlSourceBrowser`'s detail and table-of-contents stages), the way a
///   source trial's search result does;
/// * opened from a shelf book ([switchBook]), it is switch-source: the same
///   search runs on the book's own name and author, and picking a candidate
///   re-points that book at it — `ShelfService.switchSource` moves the reading
///   position onto the candidate's table of contents, the way the frozen
///   `ChangeBookSourceDialog` plus `Book.migrateTo` do.
///
/// Every source is searched in turn and the sources are not searched
/// concurrently (the frozen dialog runs them under a thread pool); each
/// source's own requests are serialized per source by the rate limiter the
/// transport already applies (#42).
///
/// Verified against that dialog for #103, frozen checkout `14dd24945`:
///
/// * **Which sources.** `ChangeBookSourceViewModel.startSearch` fills
///   `bookSourceParts` from `appDb.bookSourceDao.allEnabledPart`
///   (`select ... where enabled = 1 order by customOrder asc`), falling back to
///   it when the selected `AppConfig.searchGroup` is blank (its default). This
///   page reads `ShelfService.sources()` — every source in the space,
///   `customOrder` then `bookSourceUrl` — and pre-selects the enabled ones, so
///   the default set and its order are the frozen ones.
/// * **What admits a hit.** The dialog's filter is `fName == name &&
///   (!checkAuthor || fAuthor.contains(author))` with
///   `AppConfig.changeSourceCheckAuthor` defaulting to false;
///   [PreciseSearchHit.exact] is the same comparison and the `checkAuthor`
///   checkbox the same default.
/// * **The pick.** The dialog's `changeSource` reads the candidate's own
///   information when its `tocUrl` is empty and then its table of contents
///   before it calls `changeTo`; [pick] runs the same two stages as one
///   `pipeline.details` call and writes through `ShelfService.switchSource`.
/// * **The position.** `changeTo` (`ReadBookViewModel.kt:259-277`) copies the
///   old position through `Book.migrateTo` → `BookHelp.getDurChapter`
///   (`Book.kt:341-358`, `BookHelp.kt:495-542`); `ShelfService.switchSource`
///   applies the ported `mapChapterIndex`, pinned in `chapter_position_test.dart`.
///
/// Named gaps against that dialog, recorded rather than fixed:
///
/// * **No source-group filter.** The frozen reads `AppConfig.searchGroup` and
///   searches only that group's enabled sources, with a group menu; this page
///   has no group picker, so a group selected there has no counterpart here.
///   The default (no group) is the same set.
/// * **A disabled source can be searched.** The frozen's `allEnabledPart` is
///   `enabled = 1`; this page lists a chip for every source and only
///   *pre*-selects the enabled ones, so a user may search a disabled source.
/// * **Per-candidate fields.** The frozen card shows the hit's own latest
///   chapter title (`SearchBook.getDisplayLastChapterTitle`), ticks the current
///   source's row (`oldBookUrl == bookUrl`) and, with
///   `AppConfig.changeSourceLoadWordCount`, a word-count line and respond time;
///   this card shows title/author/source and the exact-match marker, and states
///   the current source once above the list.
/// * **Scoring and ordering.** `getBookScore`/`SourceConfig` scores and the
///   comparator they drive (`defaultComparator`, the word-count comparator) are
///   absent — a #69 non-goal.
/// * **A failed pick.** The frozen logs `换源获取目录出错` and keeps the dialog;
///   this page shows `switchSourceFailed`.
/// * **Sequential search.** `mapParallel` across sources is the product's
///   one-at-a-time walk (`lib/source/precise_search.dart`, #40's divergence).
///
/// The one divergence the operator met is the flow's *shape*, not a field: the
/// frozen has no user-invoked first-that-answers walk — its only such walk is
/// `ReadBookViewModel.autoChangeSource`, internal and keyed to
/// `ReadBook.bookSource == null` (`:139-142`) — and this product's only such
/// walk is the #69 automatic entry on a `sourceMissing` shelf row. The operator
/// was asked whether to expose that walk as a manual 换源 action and declined
/// (不做, 2026-09-25); this page's entry stays the candidate list, and no later
/// session re-opens it without a new decision.
class PreciseSearchPage extends StatefulWidget {
  const PreciseSearchPage({
    super.key,
    required this.service,
    this.switchBook,
    this.initialName,
    this.initialAuthor,
    this.transport,
    this.openPipeline,
  });

  /// The space's shelf: the sources that can be searched, the host surface the
  /// analyses run over, and the book row a switch writes.
  final ShelfService service;

  /// The shelf book this page re-points when a candidate is picked. Null for
  /// the plain search entry.
  final ShelfEntry? switchBook;

  /// The name and author to search with; the switch flow takes them from the
  /// book it was opened on.
  final String? initialName;
  final String? initialAuthor;

  /// The transport a pipeline this page builds sends through; null takes a real
  /// HTTP transport, and a test hands a scripted one, the way the browser and
  /// the shelf already take one.
  final BookSourceTransport? transport;

  /// How this page builds the pipeline for one source's search.
  ///
  /// Null builds it the way every other page does — `openBookSourcePipeline`
  /// over the source's rules, the space's host state and [transport] — and a
  /// test substitutes a scripted pipeline, because a widget test cannot load the
  /// native rule adapter (the binding never settles flutter_rust_bridge's
  /// pending work).
  final BookSourcePipeline Function(Map<String, dynamic> source)? openPipeline;

  @override
  State<PreciseSearchPage> createState() => _PreciseSearchPageState();
}

class _PreciseSearchPageState extends State<PreciseSearchPage> {
  final _name = TextEditingController();
  final _author = TextEditingController();

  /// The pipelines this page's running search owns; disposing the page cancels
  /// them, the way the browser cancels the analysis it owns. A finished run's
  /// pipelines have already been cancelled by the runner and are dropped from
  /// here when the run ends.
  final _pipelines = <BookSourcePipeline>[];

  List<ImportedBookSource> sources = const <ImportedBookSource>[];
  final Set<String> selected = <String>{};
  bool loadingSources = true;
  bool running = false;
  bool checkAuthor = false;

  /// What the page last did, or null before it has read the sources: the
  /// initial line is the build's, because it is copy (`lib/l10n/`).
  String? status;
  String? error;
  List<PreciseSearchOutcome> outcomes = const <PreciseSearchOutcome>[];

  /// Every candidate the last search admitted, in source order.
  List<PreciseSearchHit> get hits => [
    for (final outcome in outcomes) ...outcome.hits,
  ];

  List<PreciseSearchOutcome> get failures => [
    for (final outcome in outcomes)
      if (outcome.failure != null) outcome,
  ];

  @override
  void initState() {
    super.initState();
    _name.text = widget.switchBook?.title ?? widget.initialName ?? '';
    _author.text = widget.switchBook?.book.author ?? widget.initialAuthor ?? '';
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    for (final pipeline in _pipelines) {
      pipeline.cancel();
    }
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  /// Reads the space's sources and starts on those the space has enabled — the
  /// frozen flow's `allEnabledPart` — with every one of them selected.
  Future<void> _loadSources() async {
    try {
      final loaded = await widget.service.sources();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        sources = loaded;
        selected
          ..clear()
          ..addAll([
            for (final source in loaded)
              if (source.data['enabled'] != false) source.id,
          ]);
        loadingSources = false;
        status = loaded.isEmpty
            ? l10n.noSourcesInSpace
            : l10n.chooseSourcesToSearch;
      });
      // The frozen dialog searches as soon as it opens when it has a name.
      if (_name.text.trim().isNotEmpty) await search();
    } on Object catch (failure) {
      if (mounted) {
        setState(() {
          loadingSources = false;
          error = AppLocalizations.of(context).loadSourcesFailed('$failure');
        });
      }
    }
  }

  /// A pipeline for one analysis of [source], built the way the source's rules
  /// need — a JSON source gets the JSON adapter — and tracked so this page can
  /// cancel what it owns.
  ///
  /// A page that is gone does not start one: the analysis could no longer be
  /// cancelled, its notices would have nowhere to go, and its confirmation
  /// could not be shown. [search]'s `isCancelled` stops a run at its next
  /// source, and this refuses the call even if some path reaches it.
  BookSourcePipeline _openPipeline(Map<String, dynamic> source) {
    if (!mounted) {
      throw StateError('页面已销毁，不能再开始书源分析');
    }
    final pipeline =
        widget.openPipeline?.call(source) ??
        openBookSourcePipeline(
          source,
          widget.transport ?? HttpSourceTransport(store: widget.service.store),
          hostState: widget.service.hostState,
          androidId: widget.service.androidId,
          onHostMessage: _showHostNotice,
        );
    _pipelines.add(pipeline);
    return pipeline;
  }

  /// Shows a source's rate-limited `toast`/`longToast` notice on this page; a
  /// disposed page drops it silently.
  void _showHostNotice(SourceHostMessage message) {
    if (!mounted) return;
    showSourceNotice(context, message);
  }

  Future<void> search() async {
    // A page a run has outlived must not start another one; [running] keeps
    // one run at a time.
    if (!mounted || running) return;
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    final author = _author.text.trim();
    if (name.isEmpty) {
      setState(() => status = l10n.enterBookName);
      return;
    }
    final chosen = [
      for (final source in sources)
        if (selected.contains(source.id)) source,
    ];
    if (chosen.isEmpty) {
      setState(() => status = l10n.chooseSourcesToSearchStatus);
      return;
    }
    setState(() {
      running = true;
      error = null;
      outcomes = const <PreciseSearchOutcome>[];
      status = l10n.searchingSources(chosen.length);
    });
    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: _openPipeline,
      checkAuthor: checkAuthor,
      // ADR 0011 §5: one certificate confirmation per source, around that
      // source's own search.
      confirm: <T>(source, run) => withTlsExceptionConfirmation<T>(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: '${source['bookSourceUrl'] ?? ''}',
        sourceName: '${source['bookSourceName'] ?? ''}',
        run: run,
      ),
    );
    try {
      final result = await search.searchAll(
        chosen,
        // The page's lifetime is the run's lifetime: a disposed page stops the
        // run at the next source instead of walking the rest of the list under
        // a State that no longer exists.
        isCancelled: () => !mounted,
        onProgress: (progress) {
          if (mounted) {
            setState(
              () => status = l10n.searchingSource(
                progress.sourceName,
                progress.index,
                progress.total,
              ),
            );
          }
        },
      );
      if (!mounted) return;
      setState(() {
        outcomes = result;
        running = false;
        status = _summary(l10n, name, author);
      });
    } on Object catch (failure) {
      if (mounted) {
        setState(() {
          running = false;
          error = AppLocalizations.of(context).searchFailed('$failure');
        });
      }
    } finally {
      // The run's own pipelines cancel themselves when their source finishes
      // (`PreciseSearch._readSource`), so this usually cancels nothing; a
      // cancelled pipeline is inert, so cancelling again is safe and keeps the
      // list from dropping anything that could still be in flight.
      for (final pipeline in _pipelines) {
        pipeline.cancel();
      }
      _pipelines.clear();
    }
  }

  /// What the search found, in the frozen flow's words: the exact match is the
  /// hit `preciseSearchAwait` filters for, and a search that admitted nothing
  /// anywhere is the frozen `没有搜索到<$name>$author`.
  String _summary(AppLocalizations l10n, String name, String author) {
    final admitted = hits;
    if (admitted.isEmpty) {
      return failures.isEmpty
          ? l10n.noResults(name, author)
          : l10n.noResultsWithFailures(name, author, failures.length);
    }
    final exact = admitted.where((hit) => hit.exact).length;
    return l10n.candidatesFound(admitted.length, exact);
  }

  /// Picks a candidate: switches the book onto it in the switch flow, and opens
  /// it in the plain search flow.
  Future<void> pick(PreciseSearchHit hit) async {
    final l10n = AppLocalizations.of(context);
    final book = widget.switchBook;
    if (book == null) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HtmlSourceBrowser(
            source: hit.source,
            keyword: '',
            directBook: hit.book,
            service: widget.service,
            transport: widget.transport,
          ),
        ),
      );
      // The candidates do not change by opening one, so the list stays as it
      // is; adding the book wrote to the shelf, which the shelf page re-reads
      // when this page is popped.
      return;
    }
    setState(() {
      running = true;
      error = null;
      status = l10n.readingSourceToc(hit.sourceName);
    });
    final pipeline = _openPipeline(hit.source);
    try {
      final (details, chapters) = await withTlsExceptionConfirmation(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: hit.sourceRef,
        sourceName: hit.sourceName,
        run: () => pipeline.details(hit.book),
      );
      final switched = await widget.service.switchSource(
        book.id,
        hit.source,
        details,
        chapters,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l10n.switchedSource(
              hit.sourceName,
              switched.title,
              switched.chapterName ?? l10n.notReadYet,
              switched.textOffset,
            ),
          ),
        ),
      );
    } on Object catch (failure) {
      if (mounted) {
        setState(() {
          running = false;
          error = AppLocalizations.of(context).switchSourceFailed('$failure');
        });
      }
    } finally {
      pipeline.cancel();
      _pipelines.remove(pipeline);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final status = this.status ?? l10n.readingSources;
    final book = widget.switchBook;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          book == null
              ? l10n.preciseSearchTitle
              : l10n.switchSourceTitle(book.title),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          if (book != null)
            Text(
              l10n.currentSourceLine(
                book.source?.name ?? book.sourceRef,
                book.textOffset,
              ),
              key: const ValueKey('switch-source-current'),
            ),
          if (loadingSources)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: LinearProgressIndicator(),
            )
          else ...[
            Text(l10n.searchedSources, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final source in sources)
                  FilterChip(
                    key: ValueKey('precise-source-${source.id}'),
                    label: Text(
                      '${source.data['bookSourceName'] ?? source.id}',
                    ),
                    selected: selected.contains(source.id),
                    onSelected: running
                        ? null
                        : (value) => setState(() {
                            if (value) {
                              selected.add(source.id);
                            } else {
                              selected.remove(source.id);
                            }
                          }),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _name,
            key: const ValueKey('precise-name'),
            decoration: InputDecoration(labelText: l10n.bookName),
            onSubmitted: (_) => search(),
          ),
          TextField(
            controller: _author,
            key: const ValueKey('precise-author'),
            decoration: InputDecoration(labelText: l10n.authorName),
            onSubmitted: (_) => search(),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Checkbox(
                value: checkAuthor,
                key: const ValueKey('precise-check-author'),
                onChanged: running
                    ? null
                    : (value) => setState(() => checkAuthor = value ?? false),
              ),
              Expanded(child: Text(l10n.mustMatchAuthor)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              FilledButton.icon(
                key: const ValueKey('precise-search'),
                onPressed: running ? null : search,
                icon: const Icon(Icons.search),
                label: Text(l10n.search),
              ),
              const SizedBox(width: 12),
              if (running)
                const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Text(status, key: const ValueKey('precise-status')),
          if (error != null) Text(error!, key: const ValueKey('precise-error')),
          for (final outcome in failures)
            Text(
              l10n.sourceErrorLine(outcome.sourceName, '${outcome.failure}'),
              style: theme.textTheme.bodySmall,
            ),
          const SizedBox(height: 8),
          for (final hit in hits)
            Card(
              child: ListTile(
                key: ValueKey('precise-hit-${hit.sourceRef}-${hit.book.url}'),
                leading: Icon(
                  hit.exact ? Icons.check_circle : Icons.circle_outlined,
                ),
                title: Text(hit.book.title),
                subtitle: Text(
                  [
                    hit.book.author.isEmpty ? l10n.noAuthor : hit.book.author,
                    hit.sourceName,
                    if (hit.exact) l10n.exactMatch,
                  ].join(' · '),
                ),
                trailing: const Icon(Icons.arrow_forward),
                onTap: running ? null : () => pick(hit),
              ),
            ),
        ],
      ),
    );
  }
}
