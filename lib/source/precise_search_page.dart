import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'chapter_position.dart';
import 'html_source_browser.dart';
import 'http_source_transport.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'precise_search.dart';
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// The space-global setting the frozen `AppConfig.changeSourceLoadWordCount` is
/// kept in: `''` off, `'1'` on — the frozen preference's own two states
/// (`AppConfig.kt:373-377`), in the existing settings table (D2's key/value
/// row), so no schema change carries the switch.
const String _loadWordCountSettingKey = 'changeSourceLoadWordCount';
const String _loadWordCountSettingOn = '1';

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
/// * **The candidate row.** `ChangeBookSourceAdapter.convert` (`:56-131`) prints
///   the hit's source name, its author, its latest chapter through
///   `SearchBook.getDisplayLastChapterTitle` (`SearchBook.kt:89-96`, which
///   answers `无最新章节信息` for an empty field), ticks the current source's row
///   (`oldBookUrl == bookUrl`, `:63-67` — both sides the resolved target, which
///   is what the frozen resolves the rule's `bookUrl` into at
///   `BookList.kt:272`), and — with
///   `AppConfig.changeSourceLoadWordCount` — shows the computed
///   `chapterWordCountText` and `R.string.respondTime` lines (`:120-131`).
///   This row shows those fields too: the title stays the row's identity, the
///   line under it carries the source, the author and the exact-match marker,
///   the latest chapter is its own line, and the two optional lines appear only
///   while the switch is on.
/// * **The word-count switch.** The dialog's `menu_load_word_count` toggles
///   `AppConfig.changeSourceLoadWordCount` (`ChangeBookSourceDialog.kt:171-176`)
///   and, turned on, loads the word count of every candidate that has none yet
///   (`ChangeBookSourceViewModel.onLoadWordCountChecked` → `startRefreshList`,
///   `:346-370`). This page carries the same switch as a space-global setting
///   (`changeSourceLoadWordCount`, off by default, the frozen
///   `AppConfig.changeSourceLoadWordCount`): off, no candidate costs a request
///   beyond its search; on, each candidate's own information, its table of
///   contents and the chosen chapter are fetched — the frozen
///   `loadBookInfo`/`loadBookToc`/`loadBookWordCount` chain (`:262-343`) — and
///   the chapter is the one the reading position maps onto
///   (the frozen `fromReadBookActivity` through `BookHelp.getDurChapter`,
///   [mapChapterIndex]) when the page was opened on a book, and the last one
///   otherwise.
///
/// Named gaps against that dialog, recorded rather than fixed:
///
/// * **The row's two existing placeholders.** The frozen row prints the hit's
///   author and source name exactly as the hit carries them, so an empty one
///   leaves a blank; this row keeps the product's own answers for those two —
///   `（无作者）` and the source URL — and uses the frozen `无最新章节信息` for the
///   new latest-chapter line alone.
/// * **What the word-count line measures, and why the existing port is not
///   reused here.** The frozen measures the *processed* content,
///   `contentProcessor.getContent(oldBook, chapter, content, false)`
///   (`ChangeBookSourceViewModel.kt:330`), so its length carries the reading
///   page's replace rules, Chinese conversion and re-segmentation;
///   `content_processing.dart` is that port (`ContentProcessing.content` with
///   `includeTitle: false`), and this page measures the body the content stage
///   returned instead. A source whose rules rewrite the chapter therefore shows
///   a different number. The bounded check run for #115's stage-1 gate found
///   three of the port's inputs have no entry point here, which is why it is a
///   follow-up rather than this ticket:
///   * the **rules** and the **chapter** do have one — `store.replaceRules()`
///     plus `ReplaceRuleSet.forBook` are the reader's own two calls
///     (`online_reader_page.dart`, `main.dart`) and the chapter is this
///     candidate's own;
///   * the **book** has one only in switch mode ([switchBook]): the frozen takes
///     the rule scope (and the duplicated-title match's book name) from
///     `oldBook`, while the search entry has no book at all — the frozen's own
///     `oldBook!!` has no counterpart there and throws, which is how the frozen
///     reaches its failure line. Which rules reach a candidate in the search
///     entry is therefore a decision the frozen does not make, and the same row
///     would mean two different things in the two modes;
///   * the **conversion** has none: the frozen reads the app-global
///     `AppConfig.chineseConverterType` (default 0, no conversion,
///     `ContentProcessor.kt:135-143`), where the product's equivalent is
///     `ReaderScriptSetting.resolve`, whose default resolves to a target on a
///     zh system — so the page would call the native `TextEngine.convertTo`, and
///     the reader carries its `convert` parameter for exactly that reason;
///   * the port's rule-timeout path disables the rule in the store through
///     `onRuleDisabled`, state the reader owns.
///   Proposed follow-up (a decision ticket, not a lane): fix the search entry's
///   rule scope, the conversion input and the `convert` seam, then reuse the
///   port for both modes.
/// * **The tick's two address texts.** Both sides are the *resolved* target, as
///   the frozen's are. A row whose stored `sourceBookUrl` is a verbatim address
///   text rather than a resolved one — the Legado backup import keeps the
///   backup's `bookUrl` as it stands, option tail and all
///   (`legado_full_backup.dart:466`), and `Uri.parse(text).toString()` is not
///   the text again — can therefore miss the tick where the frozen's comparison
///   of two stored texts would have matched. Recorded, not converted.
/// * **A candidate whose details or table of contents do not answer.** The
///   frozen chain throws out of its source's `forEach` (`:251-260`), so with the
///   switch on that candidate never reaches the list at all; this page keeps it
///   — admission stays #113/#114's — with no optional line until the word count
///   can be computed.
/// * **What the switch leaves behind for the pick.** The frozen's `loadBookToc`
///   keeps the candidate's book and chapter list in `bookMap`/`tocMap`
///   (`:301-309`) and `changeSource` reads them back
///   (`ChangeBookSourceDialog.kt:301-306`), so a pick after a word-count load
///   fetches nothing; this page's pick always runs the details and
///   table-of-contents stages, so it reads them again.
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

  /// The frozen `AppConfig.changeSourceLoadWordCount`, as this space's
  /// `changeSourceLoadWordCount` setting: off by default, and the frozen
  /// default too (`AppConfig.kt:373-377`).
  bool loadWordCount = false;

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
      // Read on every load, like the search group: the setting is the space's,
      // not this page instance's.
      final wordCount =
          await store.setting(_loadWordCountSettingKey) ==
          _loadWordCountSettingOn;
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
        loadWordCount = wordCount;
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
      // The frozen chain loads each candidate's word count before it is
      // admitted; this page admits as the answers arrive (#108) and loads what
      // the optional lines need once the walk is done.
      if (loadWordCount) await _loadWordCounts(generation);
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

  /// The frozen `menu_load_word_count` (`ChangeBookSourceDialog.kt:171-176`):
  /// the switch is written to the space's `changeSourceLoadWordCount` setting,
  /// and turning it on loads the word count of the candidates that have none
  /// yet, exactly the set `ChangeBookSourceViewModel.startRefreshList(true)`
  /// visits (`:355-363`). Turning it off only hides the lines: the frozen loads
  /// nothing and drops nothing.
  Future<void> setLoadWordCount(bool value) async {
    setState(() => loadWordCount = value);
    await widget.service.store.putSetting(
      _loadWordCountSettingKey,
      value ? _loadWordCountSettingOn : '',
    );
    // A run already in flight reaches the fill at the end of its own walk; an
    // idle page starts it here, which is the frozen `startRefreshList(true)`.
    if (value && !running && hits.isNotEmpty) {
      unawaited(_loadWordCounts(_generation));
    }
  }

  /// Loads the word count of every candidate that has none yet, in list order
  /// and one candidate at a time.
  ///
  /// The frozen `startRefreshList(true)` refreshes exactly the candidates whose
  /// `chapterWordCountText` is still null (`:355-363`); a candidate whose count
  /// is already there is not asked for again. The fill stops when the page's
  /// run is superseded or the switch is turned off, and `running` holds the
  /// page's own busy state around it, the way the frozen's refresh holds its
  /// list.
  Future<void> _loadWordCounts(int generation) async {
    final pending = [
      for (final hit in hits)
        if (hit.chapterWordCountText == null) hit,
    ];
    if (pending.isEmpty) return;
    if (mounted) setState(() => running = true);
    try {
      for (final hit in pending) {
        if (!_isCurrent(generation) || !loadWordCount) return;
        await _loadWordCount(hit, generation);
        if (mounted) setState(() {});
      }
    } finally {
      if (mounted) setState(() => running = false);
    }
  }

  /// One candidate's word-count stage: the frozen
  /// `loadBookInfo` → `loadBookToc` → `loadBookWordCount` chain
  /// (`ChangeBookSourceViewModel.kt:262-343`), which is what the switch buys.
  ///
  /// The chapter is the one the reading position maps onto when the page was
  /// opened on a book — the frozen `fromReadBookActivity` through
  /// `BookHelp.getDurChapter` ([mapChapterIndex]) — and the last one otherwise
  /// (the frozen `chapters.lastIndex`). The frozen measures the content stage's
  /// own failure into `获取字数失败` and `-1` rather than failing the search, and
  /// this does the same; its `startTime` starts after the table of contents, so
  /// [PreciseSearchHit.respondTime] covers the content stage alone. A details or
  /// TOC stage that does not answer leaves all three fields at their defaults,
  /// and the candidate keeps its place in the list.
  Future<void> _loadWordCount(PreciseSearchHit hit, int generation) async {
    final book = widget.switchBook;
    final pipeline = _openPipeline(hit.source);
    Future<T> run<T>(Future<T> Function() analysis) =>
        withTlsExceptionConfirmation<T>(
          context: context,
          hostState: widget.service.hostState,
          sourceRef: hit.sourceRef,
          sourceName: hit.sourceName,
          run: analysis,
        );
    try {
      final (_, chapters) = await run(() => pipeline.details(hit.book));
      if (!_isCurrent(generation) || chapters.isEmpty) return;
      final index = book == null
          ? chapters.length - 1
          : mapChapterIndex(
              oldIndex: book.chapterIndex,
              oldTitle: book.chapterName,
              newTitles: [for (final chapter in chapters) chapter.name],
              oldChapterCount: book.chapters.length,
            );
      final chapter = chapters[index];
      final nextChapterUrl = index + 1 < chapters.length
          ? '${chapters[index + 1].url}'
          : null;
      final title = chapter.name.trim();
      final started = DateTime.now();
      try {
        final body = await run(
          () => pipeline.chapter(
            chapter,
            book: hit.book,
            nextChapterUrl: nextChapterUrl,
          ),
        );
        hit.chapterWordCount = body.text.length;
        hit.chapterWordCountText =
            '[${index + 1}] $title\n字数：${body.text.length}';
      } on Object catch (failure) {
        hit.chapterWordCount = -1;
        hit.chapterWordCountText = '[${index + 1}] $title\n获取字数失败：$failure';
      }
      hit.respondTime = DateTime.now().difference(started).inMilliseconds;
    } on Object {
      // The frozen chain throws out of its source's own loop here, so nothing
      // of this candidate's word count is recorded: `chapterWordCountText`
      // stays null and the row shows neither optional line.
    } finally {
      pipeline.cancel();
      _pipelines.remove(pipeline);
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
                  Row(
                    children: [
                      Checkbox(
                        value: loadWordCount,
                        key: const ValueKey('precise-load-word-count'),
                        onChanged: loadingSources || picking
                            ? null
                            : (value) =>
                                  unawaited(setLoadWordCount(value ?? false)),
                      ),
                      Expanded(child: Text(l10n.loadWordCount)),
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

  /// One candidate of the candidate list, in the frozen row's fields
  /// (`ChangeBookSourceAdapter.convert`, `:56-131`).
  ///
  /// The product's own identity and affordances stay: the title is the row's
  /// identity, the exact-match marker stays in the line under it, and the row
  /// is still picked by tapping it. What the frozen row shows and this one did
  /// not is the hit's own latest chapter — its placeholder included — the tick
  /// on the book's own current source, and, with the word-count switch on, the
  /// computed word-count and respond-time lines.
  Widget _candidate(PreciseSearchHit hit, AppLocalizations l10n, bool running) {
    final book = widget.switchBook;
    // The frozen `callBack.oldBookUrl == item.bookUrl` (`:63-67`), both sides the
    // *resolved* target: the frozen resolves the rule's own `bookUrl` before the
    // dialog ever compares it (`BookList.kt:272`, `getString(ruleBookUrl, isUrl
    // = true)`), and the shelf stores that same resolved target
    // (`ShelfService._ensureBook`/`switchSource` write `'${book.url}'`).
    // Comparing the rule's raw text (`HtmlBook.address`) instead would decline
    // the tick for every source whose search rule answers a relative href.
    final current =
        book != null && book.book.sourceBookUrl == '${hit.book.url}';
    final wordCountText = hit.chapterWordCountText;
    return Card(
      child: ListTile(
        key: ValueKey('precise-hit-${hit.sourceRef}-${hit.book.url}'),
        leading: Icon(hit.exact ? Icons.check_circle : Icons.circle_outlined),
        title: Text(hit.book.title),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              [
                hit.book.author.isEmpty ? l10n.noAuthor : hit.book.author,
                hit.sourceName,
                if (hit.exact) l10n.exactMatch,
              ].join(' · '),
            ),
            // `SearchBook.getDisplayLastChapterTitle`.
            Text(
              hit.book.lastChapter.isEmpty
                  ? l10n.noLatestChapter
                  : hit.book.lastChapter,
            ),
            // The frozen `AppConfig.changeSourceLoadWordCount &&
            // !chapterWordCountText.isNullOrBlank()` and its `respondTime >= 0`
            // (`:120-131`).
            if (loadWordCount && (wordCountText ?? '').isNotEmpty)
              Text(wordCountText!),
            if (loadWordCount && hit.respondTime >= 0)
              Text(l10n.respondTime(hit.respondTime)),
          ],
        ),
        trailing: current
            ? Icon(
                Icons.check,
                key: ValueKey(
                  'precise-current-source-${hit.sourceRef}-${hit.book.url}',
                ),
              )
            : const Icon(Icons.arrow_forward),
        onTap: running ? null : () => pick(hit),
      ),
    );
  }
}
