import 'dart:async';
import 'dart:convert';

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
/// Every source is searched, several at a time, and each source's answer
/// appears on the page as it arrives (#108): the walk is the frozen dialog's
/// `mapParallel(threadCount)` — nine sources in flight by default, its pool
/// being `min(threadCount, MAX_THREAD)` — and a source that does not answer
/// within the frozen's own 60 s is reported as one that failed. Each source's
/// own requests are serialized per source by the rate limiter the transport
/// already applies (#42).
///
/// Verified against that dialog for #103, frozen checkout `14dd24945`:
///
/// * **Which sources.** `ChangeBookSourceViewModel.startSearch` fills
///   `bookSourceParts` from `appDb.bookSourceDao.allEnabledPart`
///   (`select ... where enabled = 1 order by customOrder asc`), falling back to
///   it when the selected `AppConfig.searchGroup` is blank (its default). This
///   page reads the same store rows and `bookSourceJson` as
///   `ShelfService.sources()` — every source in the space,
///   `customOrder` then `bookSourceUrl` — and keeps only the enabled ones, all
///   of them selected, so the default set and its order are the frozen ones.
/// * **A disabled source is not searched (#114).** `allEnabledPart` is
///   `enabled = 1` and the dialog has no way to add a disabled source to the
///   run; this page lists no chip for a disabled source, so no selection can
///   reach it. The set is read from the store each time the page loads, so a
///   source whose stored `enabled` has become true is searched the next time.
///   Like `allEnabledPart`, the filter is the enabled flag alone — no
///   `bookSourceType` filter; that one is `allTextEnabledPart`'s, which the
///   automatic switch (`auto_change_source.dart`) follows.
/// * **Source groups (#113).** `ChangeBookSourceViewModel.startSearch`
///   (`:195-208`) uses `getEnabledPartByGroup` for a nonblank `searchGroup`,
///   and clears an empty eligible group before searching all enabled sources.
///   The space-global `searchGroup` setting serves both page modes here. The
///   menu follows `ChangeBookSourceDialog.initLiveData` (`:260-265`), whose
///   `flowEnabledGroups` includes only enabled sources' groups. Membership
///   uses the store's split/trimmed `groupNames`, not SQL LIKE: whitespace and
///   wildcard/case behavior can differ. Menu order is Dart string order, not
///   the frozen `cnCompare`'s Chinese ICU collation (no equivalent is shipped).
///   A populated group with no hits asks before searching all groups, as the
///   dialog's `searchFinishCallback` (`:79-93`) does; cancel keeps that group.
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
  bool picking = false;
  bool checkAuthor = false;
  String searchGroup = '';
  List<String> sourceGroups = const [];

  // A group change cancels the old walk and waits for its in-flight work to
  // settle before starting another. Rapid changes coalesce to the latest
  // generation; they cannot multiply the walk's concurrency bound.
  int _generation = 0;
  Future<void> _sourceLoad = Future<void>.value();
  Future<void> _searchTask = Future<void>.value();

  /// What the page last did, or null before it has read the sources: the
  /// initial line is the build's, because it is copy (`lib/l10n/`).
  String? status;
  String? error;

  /// The running search's outcomes, one slot per searched source, filled as the
  /// walk streams them in. The slots keep the page in **source order** however
  /// the answers arrive, which is the order the candidate list has always had.
  List<PreciseSearchOutcome?> placed = const <PreciseSearchOutcome?>[];

  /// Where each mid-flight answer's source sits in [placed]: the walk streams a
  /// source's ref, and a run of thousands of answers must not search a list of
  /// thousands of sources for each one.
  Map<String, int> slotOf = const <String, int>{};

  /// Every candidate the run has admitted so far, in source order.
  List<PreciseSearchHit> hits = const <PreciseSearchHit>[];

  /// Every source that has failed to answer, in source order.
  List<PreciseSearchOutcome> failures = const <PreciseSearchOutcome>[];

  /// How many of the run's sources have answered, for the progress line.
  int answered = 0;

  @override
  void initState() {
    super.initState();
    _name.text = widget.switchBook?.title ?? widget.initialName ?? '';
    _author.text = widget.switchBook?.book.author ?? widget.initialAuthor ?? '';
    unawaited(_loadSources());
  }

  @override
  void dispose() {
    _generation++;
    for (final pipeline in _pipelines) {
      pipeline.cancel();
    }
    _name.dispose();
    _author.dispose();
    super.dispose();
  }

  /// Re-reads eligibility on every load. Serializing the store work also keeps
  /// a superseded preference write from overwriting the latest group choice.
  Future<void> _loadSources({String? group}) {
    if (!mounted || picking) return Future<void>.value();
    final generation = ++_generation;
    for (final pipeline in _pipelines) {
      pipeline.cancel();
    }
    final previousSearch = _searchTask;
    setState(() {
      loadingSources = true;
      running = false;
      error = null;
      hits = const [];
      failures = const [];
    });
    return _sourceLoad = _sourceLoad.then((_) async {
      await previousSearch;
      if (!_isCurrent(generation)) return;
      await _readSources(generation, group);
    });
  }

  bool _isCurrent(int generation) => mounted && generation == _generation;

  Future<void> _readSources(int generation, String? group) async {
    try {
      final store = widget.service.store;
      final stored = await store.allSources();
      // Keep #114's raw-vs-typed authority exactly as ShelfService.sources
      // does, and use the store's already normalized group membership.
      final loaded = [
        for (final source in stored)
          ImportedBookSource(
            id: source.bookSourceUrl,
            data: bookSourceJson(source),
          ),
      ];
      final enabled = [
        for (final source in loaded)
          if (source.data['enabled'] != false) source,
      ];
      final groupsBySource = {
        for (final source in stored)
          source.bookSourceUrl: (jsonDecode(source.groupNames) as List)
              .cast<String>(),
      };
      final groups =
          enabled
              .expand((source) => groupsBySource[source.id]!)
              .toSet()
              .toList()
            ..sort();
      final requested = group ?? await store.setting('searchGroup') ?? '';
      var chosenGroup = requested.trim().isEmpty ? '' : requested;
      var eligible = [
        for (final source in enabled)
          if (chosenGroup.isEmpty ||
              groupsBySource[source.id]!.contains(chosenGroup))
            source,
      ];
      // Frozen startSearch: an absent/disabled-only group resets to all. The
      // control shows the reset before the replacement search begins.
      if (eligible.isEmpty && chosenGroup.isNotEmpty) {
        chosenGroup = '';
        eligible = enabled;
      }
      if (!_isCurrent(generation)) return;
      if (group != null || requested != chosenGroup) {
        await store.putSetting('searchGroup', chosenGroup);
      }
      if (!_isCurrent(generation)) return;
      final l10n = AppLocalizations.of(context);
      setState(() {
        searchGroup = chosenGroup;
        sourceGroups = groups;
        sources = eligible;
        selected
          ..clear()
          ..addAll([for (final source in eligible) source.id]);
        loadingSources = false;
        status = loaded.isEmpty
            ? l10n.noSourcesInSpace
            : enabled.isEmpty
            ? l10n.noEnabledSourcesInSpace
            : l10n.chooseSourcesToSearch;
      });
      if (_name.text.trim().isNotEmpty && eligible.isNotEmpty)
        unawaited(search());
    } on Object catch (failure) {
      if (_isCurrent(generation)) {
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
    if (!mounted || running || loadingSources) return;
    final generation = _generation;
    final task = _runSearch(generation);
    _searchTask = task.then((_) {});
    final completed = await task;
    if (!completed ||
        !_isCurrent(generation) ||
        hits.isNotEmpty ||
        failures.isNotEmpty ||
        searchGroup.isEmpty)
      return;
    final group = searchGroup;
    final l10n = AppLocalizations.of(context);
    final allGroups = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.sourceGroupNoResultsTitle),
        content: Text(l10n.sourceGroupNoResults(group)),
        actions: [
          TextButton(
            key: const ValueKey('precise-group-cancel'),
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.cancel),
          ),
          FilledButton(
            key: const ValueKey('precise-group-confirm'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(l10n.confirm),
          ),
        ],
      ),
    );
    if (allGroups == true && _isCurrent(generation))
      await _loadSources(group: '');
  }

  Future<bool> _runSearch(int generation) async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    final author = _author.text.trim();
    if (name.isEmpty) {
      setState(() => status = l10n.enterBookName);
      return false;
    }
    final chosen = [
      for (final source in sources)
        if (selected.contains(source.id)) source,
    ];
    if (chosen.isEmpty) {
      setState(() => status = l10n.chooseSourcesToSearchStatus);
      return false;
    }
    setState(() {
      running = true;
      error = null;
      placed = List<PreciseSearchOutcome?>.filled(chosen.length, null);
      slotOf = {
        for (var index = 0; index < chosen.length; index++)
          chosen[index].id: index,
      };
      hits = const <PreciseSearchHit>[];
      failures = const <PreciseSearchOutcome>[];
      answered = 0;
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
      // The page's lifetime is the run's lifetime: a disposed page stops the
      // walk — no source behind the ones already in flight is started, and those
      // sources' pipelines are cancelled — instead of walking the rest of the
      // list under a State that no longer exists.
      final answers = search.searchAll(
        chosen,
        isCancelled: () => !_isCurrent(generation),
      );
      await for (final outcome in answers) {
        if (!_isCurrent(generation)) break;
        setState(() {
          _place(outcome);
          // The frozen dialog's own progress line: what this run has found so
          // far, how many of the sources have answered, and the one that just
          // did.
          status = l10n.searchProgress(
            hits.length,
            answered,
            chosen.length,
            outcome.sourceName,
          );
        });
      }
      if (!_isCurrent(generation)) return false;
      setState(() {
        running = false;
        status = _summary(l10n, name, author);
      });
      return true;
    } on Object catch (failure) {
      if (_isCurrent(generation)) {
        setState(() {
          running = false;
          error = AppLocalizations.of(context).searchFailed('$failure');
        });
      }
      return false;
    } finally {
      // The run's own pipelines cancel themselves when their source finishes
      // (`PreciseSearch._readSource`), and the walk cancels the ones left in
      // flight when it stops; a cancelled pipeline is inert, so cancelling
      // again is safe and keeps the list from dropping anything that could
      // still be open.
      for (final pipeline in _pipelines) {
        pipeline.cancel();
      }
      _pipelines.clear();
    }
  }

  /// Puts one streamed answer in its own source's slot and refreshes the two
  /// ordered lists the page's slivers read.
  ///
  /// The walk streams in completion order; the slots are what keep the page in
  /// source order. The lists are rebuilt only when an answer adds a row, so the
  /// thousands of sources that find nothing do not each rescan the run.
  void _place(PreciseSearchOutcome outcome) {
    final slot = slotOf[outcome.sourceRef];
    if (slot != null) placed[slot] = outcome;
    answered++;
    if (outcome.hits.isNotEmpty) {
      hits = [for (final slot in placed) ...?slot?.hits];
    }
    if (outcome.failure != null) {
      failures = [
        for (final slot in placed)
          if (slot?.failure != null) slot!,
      ];
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
      picking = true;
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
      if (mounted) setState(() => picking = false);
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
        actions: [
          PopupMenuButton<String>(
            key: const ValueKey('precise-source-group'),
            tooltip: l10n.sourceGroup,
            enabled: !picking,
            initialValue: searchGroup,
            onSelected: (group) => unawaited(_loadSources(group: group)),
            itemBuilder: (_) => [
              for (final group in ['', ...sourceGroups])
                CheckedPopupMenuItem<String>(
                  key: ValueKey('precise-group-$group'),
                  value: group,
                  checked: group == searchGroup,
                  child: Text(group.isEmpty ? l10n.allSources : group),
                ),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.sizeOf(context).width * 0.4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        searchGroup.isEmpty ? l10n.allSources : searchGroup,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
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
                    Text(
                      l10n.searchedSources,
                      style: theme.textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                  ],
                ],
              ),
            ),
          ),
          if (!loadingSources)
            SliverPadding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              sliver: SliverGrid.builder(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 240,
                  mainAxisExtent: 48,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: sources.length,
                itemBuilder: (_, index) {
                  final source = sources[index];
                  return Align(
                    alignment: Alignment.centerLeft,
                    child: FilterChip(
                      key: ValueKey('precise-source-${source.id}'),
                      label: Text(
                        '${source.data['bookSourceName'] ?? source.id}',
                      ),
                      selected: selected.contains(source.id),
                      onSelected: running || loadingSources
                          ? null
                          : (value) => setState(() {
                              if (value) {
                                selected.add(source.id);
                              } else {
                                selected.remove(source.id);
                              }
                            }),
                    ),
                  );
                },
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
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
                        onChanged: running || loadingSources
                            ? null
                            : (value) =>
                                  setState(() => checkAuthor = value ?? false),
                      ),
                      Expanded(child: Text(l10n.mustMatchAuthor)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton.icon(
                        key: const ValueKey('precise-search'),
                        onPressed: running || loadingSources ? null : search,
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
                  if (error != null)
                    Text(error!, key: const ValueKey('precise-error')),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          // A walk over thousands of sources admits its candidates as they
          // arrive; each row below is built when the viewport reaches it and no
          // sooner (#86's lesson: 8 716 rows are not built one per frame), and
          // an answer that adds a row rebuilds the rows on screen only.
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            sliver: SliverList.builder(
              itemCount: failures.length,
              itemBuilder: (_, index) => Text(
                l10n.sourceErrorLine(
                  failures[index].sourceName,
                  '${failures[index].failure}',
                ),
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            sliver: SliverList.builder(
              itemCount: hits.length,
              itemBuilder: (_, index) => _candidate(hits[index], l10n, running),
            ),
          ),
        ],
      ),
    );
  }

  /// One candidate of the candidate list.
  Widget _candidate(
    PreciseSearchHit hit,
    AppLocalizations l10n,
    bool running,
  ) => Card(
    child: ListTile(
      key: ValueKey('precise-hit-${hit.sourceRef}-${hit.book.url}'),
      leading: Icon(hit.exact ? Icons.check_circle : Icons.circle_outlined),
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
  );
}
