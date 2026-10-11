import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'domain/contracts.dart';
import 'l10n/app_localizations.dart';
import 'l10n/store_message_text.dart';
import 'local/library_access.dart';
import 'local/platform_library_access.dart';
import 'local/local_reader.dart';
import 'local/local_reader_page.dart';
import 'local/reader_engine.dart';
import 'settings/auto_change_source_page.dart';
import 'settings/interface_language.dart';
import 'settings/interface_language_page.dart';
import 'settings/reader_script_page.dart';
import 'settings/system_proxy_page.dart';
import 'source/book_source_service.dart';
import 'source/content_processing.dart';
import 'source/http_source_transport.dart';
import 'source/inappwebview_book_source_adapter.dart';
import 'source/inappwebview_source_hatch.dart';
import 'source/source_login.dart';
import 'source/source_login_dialog.dart';
import 'source/source_trial_page.dart';
import 'source/online_bookshelf.dart';
import 'source/precise_search_page.dart';
import 'source/shelf_filter.dart';
import 'store/ids.dart';
import 'store/legacy_import.dart';
import 'store/local_library.dart';
import 'store/shelf.dart';
import 'store/space_store.dart';
import 'store/workspace.dart';

void main() {
  installApplicationBindings();
  // `--dart-define=LIBER_WORKSPACE_ROOT=<path>` opens a different installation
  // directory instead of the platform's application-data directory: a review
  // run drives the real app without the operator's own library underneath it.
  const workspace = String.fromEnvironment('LIBER_WORKSPACE_ROOT');
  runApp(
    LiberApp(workspaceRoot: workspace.isEmpty ? null : Directory(workspace)),
  );
}

/// The process-wide bindings the application's composition root owns.
///
/// Both entry points call this: `main()` above and the debug-only driver entry
/// point (`tool/driver_main.dart`), so the driven run exercises the application
/// the build ships. The platform WebView is the rendered-document engine behind
/// `BookSourceWebViewAdapter` (ADR 0003, ticket #55); installing it here rather
/// than inside [LiberApp] keeps the plugin — which reaches `dart:ui` — out of
/// the model layer that the gates, the tools and the unit tests run on a plain
/// Dart VM, and keeps the install single-sourced instead of copied per
/// entry point.
void installApplicationBindings() {
  installInAppWebViewBookSourceAdapter();
  installInAppWebViewSourceHatch();
}

class LiberApp extends StatefulWidget {
  const LiberApp({
    super.key,
    this.workspaceRoot,
    this.interfaceLanguage,
    this.libraryAccess,
  });

  /// The installation directory (`manifest.json` and `spaces/`). When null,
  /// Windows keeps `%APPDATA%\Liber`; other platforms use path_provider's
  /// application support directory. An explicit root bypasses platform lookup.
  final Directory? workspaceRoot;

  /// Pins the interface language instead of resolving it from the space store.
  ///
  /// A widget test — and a driven run — says which language it expects rather
  /// than inheriting the machine's locale; null leaves the resolution to the
  /// `interface.language` row and the system locale (#28).
  final Locale? interfaceLanguage;

  /// The native picker/IO boundary; injected only for scoped UI verification.
  final PlatformLibraryAccess? libraryAccess;

  @override
  State<LiberApp> createState() => _LiberAppState();
}

class _LiberAppState extends State<LiberApp> {
  /// What the open space's store resolved the interface language to, reported
  /// by [LiberHomePage]; null until the space is open.
  Locale? _resolved;

  /// The locale the widgets read: the pinned language first, else the stored
  /// choice, else what the system locale asks for — the state for the frames
  /// before the space opens.
  Locale get _locale =>
      widget.interfaceLanguage ??
      _resolved ??
      InterfaceLanguageSetting.followSystem(
        InterfaceLanguageSetting.systemLocale(),
      );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liber',
      // The confirmed pages a hatch shows are pushed on this navigator, so the
      // source runtime can reach a navigator from inside an execution.
      navigatorKey: sourceHatchNavigatorKey,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315c72)),
        useMaterial3: true,
        // The Linux directory font manager lacks automatic CJK glyph fallback.
        fontFamilyFallback: defaultTargetPlatform == TargetPlatform.linux
            ? const ['Noto Sans CJK SC']
            : null,
      ),
      // The interface's own words (#28): the four locales `lib/l10n/` carries,
      // resolved by `InterfaceLanguageSetting` rather than by Flutter's own
      // matching. Rebuilding this widget with another locale is what applies a
      // language change — there is no restart.
      locale: _locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: InterfaceLanguageSetting.supportedLocales,
      home: LiberHomePage(
        workspaceRoot: widget.workspaceRoot,
        libraryAccess: widget.libraryAccess,
        onInterfaceLocale: (locale) => setState(() => _resolved = locale),
      ),
    );
  }
}

class LiberHomePage extends StatefulWidget {
  const LiberHomePage({
    super.key,
    this.workspaceRoot,
    this.libraryAccess,
    this.onInterfaceLocale,
  });

  final Directory? workspaceRoot;
  final PlatformLibraryAccess? libraryAccess;

  /// Reports the interface language the space store resolved (#28), so the
  /// application above rebuilds its `MaterialApp` in it. Null when nothing owns
  /// the application's locale.
  final ValueChanged<Locale>? onInterfaceLocale;

  @override
  State<LiberHomePage> createState() => _LiberHomePageState();
}

class _LiberHomePageState extends State<LiberHomePage> {
  int _selectedIndex = 0;
  int _onlineRevision = 0;
  BookSourceRunState _run = const BookSourceRunState(
    stage: BookSourceStage.idle,
  );
  final BookSourceService _bookSourceService = BookSourceService();
  SpaceStore? _store;
  ShelfService? _shelf;
  LocalLibrary? _library;
  late final PlatformLibraryAccess _libraryAccess =
      widget.libraryAccess ?? PlatformLibraryAccess();
  bool _libraryBusy = false;
  List<ShelfEntry> _importedBooks = const <ShelfEntry>[];
  List<ImportedBookSource> _sources = const <ImportedBookSource>[];
  MigrationImportRecord? _migrationResult;
  String? _migrationMessage;
  LegacyImportReport? _spaceImport;
  String? _spaceStorePath;
  String? _spaceMessage;
  List<BookSourceTraceEntry> _trace = const <BookSourceTraceEntry>[];

  @override
  void initState() {
    super.initState();
    _openSpace();
  }

  /// Opens the installation's space and imports the JSON stores this product
  /// wrote before it, once the store is the writer.
  ///
  /// The import is forced and retiring: a file that is still there is a delta
  /// to merge by natural key, and renaming it aside is what proves nothing
  /// reads it any more. The import targets the default space — those files
  /// belong to the installation's original space, not to whichever space is
  /// active now.
  Future<void> _openSpace() async {
    try {
      // Await synchronous Windows failures too: the error UI reads localized
      // strings, which are available after this first frame's initialization.
      final root =
          widget.workspaceRoot ??
          await Future<Directory>.sync(
            () => defaultTargetPlatform == TargetPlatform.windows
                ? Workspace.defaultRoot()
                : getApplicationSupportDirectory(),
          );
      final workspace = await Workspace.open(root: root);
      final store = await workspace.openSpace(Workspace.defaultSpaceId);
      final shelf = ShelfService(store, androidId: await workspace.androidId());
      final library = LocalLibrary(store, access: _libraryAccess);
      // Importing is best effort: the space is open whether or not the retired
      // files could be merged, and a failure there must not cost the reader the
      // library that is already in the store.
      LegacyImportReport? report;
      String? importError;
      try {
        report = await LegacyImport(
          home: workspace.root,
        ).run(store, force: true, retireOriginals: true);
      } on Object catch (error) {
        if (mounted) {
          importError = AppLocalizations.of(
            context,
          ).legacyImportFailed('$error');
        }
      }
      await library.load();
      final imported = await shelf.migratedBooks();
      final sources = await shelf.sources();
      final path = workspace.databaseFile(store.spaceId).path;
      if (!mounted) return;
      setState(() {
        _store = store;
        _shelf = shelf;
        _library = library;
        _spaceImport = report;
        _spaceStorePath = path;
        _importedBooks = imported;
        _sources = sources;
        if (importError != null) _spaceMessage = importError;
      });
      await _resolveInterfaceLanguage(store);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _spaceMessage = AppLocalizations.of(
            context,
          ).spaceStoreUnavailable('$error'),
        );
      }
    }
  }

  /// Reads the interface language once the space is open and hands it to the
  /// application (#28).
  ///
  /// A row that cannot be read leaves the interface on the system locale: the
  /// space's own message already reports a store that does not work, and the
  /// language must not be the second thing to fail.
  Future<void> _resolveInterfaceLanguage(SpaceStore store) async {
    try {
      final locale = await InterfaceLanguageSetting.resolve(store);
      if (mounted) widget.onInterfaceLocale?.call(locale);
    } on Object {
      // The system locale stands.
    }
  }

  /// Applies a language chosen on the settings screen (#28): the application
  /// rebuilds its `MaterialApp` with it, and every widget below re-resolves its
  /// copy on the next frame.
  void _applyInterfaceLocale(Locale locale) =>
      widget.onInterfaceLocale?.call(locale);

  Future<void> _refreshLibraryViews() async {
    await _library?.load();
    await _refreshShelfViews();
    if (mounted) setState(() {});
  }

  /// Opens a local book in the paged reader.
  ///
  /// The reader writes the five-field progress record through the library, so
  /// the shelf's cached offset is re-read when the page comes back. The space's
  /// replace rules are read once and applied through #17's one text entry, the
  /// way the online reader applies them; a book whose rules cannot be read opens
  /// on the file's own text.
  Future<void> _openLocalBook(LocalBook book) async {
    final library = _library;
    if (library == null) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    final processing = await _contentProcessing(
      book,
      library,
      messenger,
      AppLocalizations.of(context),
    );
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LocalReaderPage(
          reader: LocalReader(
            engine: NativeReaderEngine(
              acquireRead: () async {
                final file = await library.fileReferenceOf(book);
                if (file == null) {
                  throw const LibraryAccessFailure(
                    LibraryAccessError.missing,
                    'Local file needs relinking',
                  );
                }
                return library.access.acquireRead(file);
              },
            ),
            library: library,
            book: book,
            processing: processing,
          ),
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  /// This book's replace rules, or null when they cannot be read (the reader
  /// then shows the file's own text).
  Future<ContentProcessing?> _contentProcessing(
    LocalBook book,
    LocalLibrary library,
    ScaffoldMessengerState? messenger,
    AppLocalizations l10n,
  ) async {
    try {
      final rules = await library.store.replaceRules();
      return ContentProcessing(
        rules: ReplaceRuleSet.forBook(
          rules,
          bookName: book.title,
          // The frozen reader's local-book origin is `BookType.localTag`
          // (`BookType.kt:66`); this product stores `kind` instead (D2), and a
          // rule's `scope` is still matched against the origin text.
          bookOrigin: 'loc_book',
        ),
        bookName: book.title,
        // The frozen `Book.getUseReplaceRule()` for a text book: on by default.
        useReplaceRule: true,
        // The frozen `Book.getReSegment()`, which defaults off (21 of the
        // operator's 1419 books carry it on).
        useReSegment: false,
        onNotice: (message) => messenger?.showSnackBar(
          SnackBar(content: Text(message.text(l10n))),
        ),
        // The frozen reader disables a rule that exceeded its deadline.
        onRuleDisabled: (rule) => library.store.putReplaceRule(
          rule.copyWith(isEnabled: false).toCompanion(true),
        ),
      );
    } on Object {
      return null;
    }
  }

  /// Re-reads what the shelf and the migration page list: a source trial, a
  /// backup import or a newly admitted file can all have added rows.
  Future<void> _refreshShelfViews() async {
    final shelf = _shelf;
    if (shelf == null) return;
    final sources = await shelf.sources();
    final imported = await shelf.migratedBooks();
    if (!mounted) return;
    setState(() {
      _sources = sources;
      _importedBooks = imported;
      _onlineRevision++;
    });
  }

  Future<void> _runControlledSource() async {
    final result = await _bookSourceService.run((state) {
      if (mounted) setState(() => _run = state);
    });
    if (mounted) setState(() => _trace = result.trace);
  }

  /// Deletes a Book Source: the host surface it owned, the TLS exceptions the
  /// user confirmed for it and its row, in one store step (#53).
  ///
  /// The confirmation states what the delete does and what it does not: the
  /// books that resolved this URL stay on the shelf, marked, because their rows,
  /// their chapters and their positions are not the source's to take.
  Future<void> _deleteSource(String sourceRef, String sourceName) async {
    final shelf = _shelf;
    if (shelf == null) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.deleteSource),
        content: Text(l10n.deleteSourceQuestion(sourceName, sourceRef)),
        actions: [
          TextButton(
            autofocus: true,
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await shelf.deleteSource(sourceRef);
      if (!mounted) return;
      setState(
        () => _migrationMessage = AppLocalizations.of(
          context,
        ).sourceDeleted(sourceName),
      );
      await _refreshShelfViews();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _migrationMessage = AppLocalizations.of(
            context,
          ).deleteSourceFailed('$error'),
        );
      }
    }
  }

  /// Edits a Book Source's `bookSourceUrl` (#53): the old URL's host surface and
  /// its TLS exceptions go, and the source is written under the new URL, in one
  /// store step. The books that resolved the old URL stay on the shelf, marked.
  Future<void> _editSourceUrl(String sourceRef, String sourceName) async {
    final shelf = _shelf;
    if (shelf == null) return;
    var draft = sourceRef;
    final l10n = AppLocalizations.of(context);
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.editSourceUrlTitle(sourceName)),
        content: TextFormField(
          initialValue: sourceRef,
          autofocus: true,
          onChanged: (value) => draft = value,
          decoration: const InputDecoration(labelText: 'bookSourceUrl'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(draft),
            child: Text(l10n.save),
          ),
        ],
      ),
    );
    if (entered == null || !mounted) return;
    final newUrl = entered.trim();
    if (newUrl.isEmpty) {
      setState(() => _migrationMessage = l10n.sourceUrlEmpty);
      return;
    }
    if (newUrl == sourceRef) return;
    if (_sources.any((source) => source.id == newUrl)) {
      setState(() => _migrationMessage = l10n.sourceUrlTaken(newUrl));
      return;
    }
    try {
      await shelf.repointSource(sourceRef, newUrl);
      if (!mounted) return;
      setState(
        () => _migrationMessage = AppLocalizations.of(
          context,
        ).sourceUrlChanged(sourceRef, newUrl),
      );
      await _refreshShelfViews();
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _migrationMessage = AppLocalizations.of(
            context,
          ).editSourceUrlFailed('$error'),
        );
      }
    }
  }

  @override
  void dispose() {
    // The page owns the space for its lifetime; letting go of it here is what
    // lets the database file be moved or deleted while the process lives.
    unawaited(_shelf?.close() ?? Future<void>.value());
    super.dispose();
  }

  /// Opens one source's login surface (#60): the frozen `SourceLoginDialog` over
  /// the space's host state, so a login header the source's own login script
  /// stores is the one the next stage's requests carry (ADR 0011 §3).
  ///
  /// The session is built per opening, because a login is one user action and
  /// not an analysis; the transport and the host state are the ones the pages
  /// run this source's stages with.
  Future<void> _loginSource(String sourceRef, String sourceName) async {
    final shelf = _shelf;
    if (shelf == null) return;
    Map<String, dynamic>? source;
    for (final item in _sources) {
      if (item.id == sourceRef) source = item.data;
    }
    final data = source;
    if (data == null) {
      setState(
        () => _migrationMessage = AppLocalizations.of(
          context,
        ).sourceNotFound(sourceRef),
      );
      return;
    }
    final loggedIn = await showDialog<bool>(
      context: context,
      builder: (_) => SourceLoginDialog(
        session: SourceLoginSession(
          source: data,
          hostState: shelf.hostState,
          androidId: shelf.androidId,
          transport: HttpSourceTransport(store: shelf.store),
        ),
      ),
    );
    if (!mounted || loggedIn != true) return;
    setState(
      () => _migrationMessage = AppLocalizations.of(
        context,
      ).sourceLoggedIn(sourceName),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shelf = _shelf;
    final library = _library;
    final store = _store;
    final pages = <Widget>[
      _BookshelfPage(
        run: _run,
        localBooks: library?.books ?? const <LocalBook>[],
        importedBooks: _importedBooks,
        onlineRevision: _onlineRevision,
        shelf: shelf,
        spaceMessage: _spaceMessage,
        onRunSource: _runControlledSource,
        trace: _trace,
        onOpenBook: _openLocalBook,
      ),
      _LocalLibraryPage(
        service: library,
        access: _libraryAccess,
        onOpenBook: _openLocalBook,
        onChanged: _refreshLibraryViews,
        onBusyChanged: (busy) {
          if (mounted) setState(() => _libraryBusy = busy);
        },
      ),
      _MigrationPage(
        result: _migrationResult,
        sources: _sources,
        message: _migrationMessage,
        spaceImport: _spaceImport,
        spaceStorePath: _spaceStorePath,
        spaceMessage: _spaceMessage,
        onDeleteSource: _deleteSource,
        onEditSourceUrl: _editSourceUrl,
        onLogin: _loginSource,
        onImportFile: (path) async {
          if (store == null) return;
          try {
            final result = await importLegadoBackupFile(store, path);
            if (!mounted) return;
            setState(() {
              _migrationResult = result;
              _migrationMessage = AppLocalizations.of(
                context,
              ).importPreviewDone;
            });
            await _refreshShelfViews();
          } on FormatException catch (error) {
            if (mounted) {
              setState(
                () => _migrationMessage = AppLocalizations.of(
                  context,
                ).importFileFailed(error.message),
              );
            }
          }
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        // #40 entry region: the app bar's actions. `精确搜索` is the
        // multi-source search entry (`PreciseSearchPage`); the page reads the
        // space's sources itself, so this hunk needs nothing but the shelf.
        // #28's own entry is `界面语言`, beside #27's `中文转换` and #69's
        // `自动换源`.
        actions: [
          IconButton(
            onPressed: shelf == null
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => InterfaceLanguagePage(
                        store: shelf.store,
                        onLocaleChanged: _applyInterfaceLocale,
                      ),
                    ),
                  ),
            tooltip: l10n.actionInterfaceLanguage,
            icon: const Icon(Icons.language),
          ),
          IconButton(
            onPressed: shelf == null
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => ReaderScriptPage(store: shelf.store),
                    ),
                  ),
            tooltip: l10n.readerScriptTitle,
            icon: const Icon(Icons.translate),
          ),
          // #69's own entry: the frozen `AppConfig.autoChangeSource`, one row
          // the shelf reads when it opens a book whose source is deleted.
          IconButton(
            onPressed: shelf == null
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => AutoChangeSourcePage(store: shelf.store),
                    ),
                  ),
            tooltip: l10n.actionAutoChangeSource,
            icon: const Icon(Icons.swap_horiz),
          ),
          // #87's own entry: whether the requests this product sends through
          // `dart:io`'s `HttpClient` follow the machine's proxy configuration.
          IconButton(
            onPressed: shelf == null
                ? null
                : () => Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => SystemProxyPage(store: shelf.store),
                    ),
                  ),
            tooltip: l10n.actionSystemProxy,
            icon: const Icon(Icons.route),
          ),
          TextButton.icon(
            onPressed: shelf == null
                ? null
                : () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => PreciseSearchPage(service: shelf),
                      ),
                    );
                    if (mounted) setState(() => _onlineRevision++);
                  },
            icon: const Icon(Icons.manage_search),
            label: Text(l10n.actionPreciseSearch),
          ),
          TextButton.icon(
            onPressed: shelf == null
                ? null
                : () async {
                    await Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) =>
                            SourceTrialPage(sources: _sources, service: shelf),
                      ),
                    );
                    if (mounted) setState(() => _onlineRevision++);
                    await _refreshShelfViews();
                  },
            icon: const Icon(Icons.travel_explore),
            label: Text(l10n.actionSourceTrial),
          ),
        ],
      ),
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: _libraryBusy
                ? null
                : (index) {
                    setState(() => _selectedIndex = index);
                  },
            labelType: NavigationRailLabelType.all,
            destinations: [
              NavigationRailDestination(
                icon: const Icon(Icons.menu_book_outlined),
                selectedIcon: const Icon(Icons.menu_book),
                label: Text(l10n.shelfTitle),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.folder_outlined),
                selectedIcon: const Icon(Icons.folder),
                label: Text(l10n.navLocalLibrary),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.import_export_outlined),
                selectedIcon: const Icon(Icons.import_export),
                label: Text(l10n.navMigration),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(child: pages[_selectedIndex]),
        ],
      ),
    );
  }
}

/// The shelf as one lazy scroll view.
///
/// Every section is a sliver and every kind of book row is a `SliverList`
/// builder, because a real shelf holds more than a thousand rows. The rows used
/// to hang under one `OnlineBookshelf` that was a single ~90k-pixel `Column`
/// child among a handful of small ones, so the scroll view's `maxScrollExtent`
/// was an extrapolation between wildly unequal children that the next layout
/// corrected: the position and the scrollbar thumb snapped to the corrected
/// extent while the reader scrolled (#86).
///
/// The filter field (#88) is this page's own: all three sections — the online
/// shelf, the migrated rows and the local books — narrow to the rows whose
/// title or author carries what was typed, the count line says how many of the
/// shelf's rows are left, and a filter that matches nothing says so. Nothing
/// reaches the network or the store: the rows are the ones the page already
/// has.
class _BookshelfPage extends StatefulWidget {
  const _BookshelfPage({
    required this.run,
    required this.localBooks,
    required this.importedBooks,
    required this.onlineRevision,
    required this.shelf,
    required this.spaceMessage,
    required this.onRunSource,
    required this.trace,
    required this.onOpenBook,
  });

  final BookSourceRunState run;
  final List<LocalBook> localBooks;

  /// The rows a legacy import left behind: they have no source, so the shelf
  /// lists what they are instead of pretending they can be opened.
  final List<ShelfEntry> importedBooks;
  final int onlineRevision;

  /// Null until the space opens; the online section waits for it.
  final ShelfService? shelf;

  /// Why the space is not open, when it is not.
  final String? spaceMessage;
  final VoidCallback onRunSource;
  final List<BookSourceTraceEntry> trace;
  final ValueChanged<LocalBook> onOpenBook;

  @override
  State<_BookshelfPage> createState() => _BookshelfPageState();
}

class _BookshelfPageState extends State<_BookshelfPage> {
  /// What the operator typed into the filter field; its text is the query, and
  /// the clear button is what empties it again.
  final _filter = TextEditingController();

  /// The online section's rows as it last loaded them (#88).
  ///
  /// The count line spans every section and the page counts the migrated and
  /// local rows itself; the online section owns its own load, reload and rows,
  /// so it reports what it read and the page counts from that. Nothing here
  /// renders a row.
  List<ShelfEntry> _onlineBooks = const <ShelfEntry>[];

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  /// The query the sections filter on: the field's own words without the
  /// surrounding spaces, so a field holding only spaces shows the whole shelf.
  String get _query => _filter.text.trim();

  /// Whether the row is one the filter shows.
  bool _matches(String title, {String? author}) =>
      shelfRowMatches(_query, title: title, author: author);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final filtering = _query.isNotEmpty;
    // Each section shows the rows that match, in the order the page already
    // had them; the filtering is over words in memory, and every section below
    // is still a `SliverList.builder` over the matches, so narrowing builds the
    // rows the viewport reaches and no others.
    final importedBooks = [
      for (final entry in widget.importedBooks)
        if (_matches(entry.title, author: entry.book.author)) entry,
    ];
    final localBooks = [
      for (final book in widget.localBooks)
        if (_matches(book.title)) book,
    ];
    final onlineShown = _onlineBooks
        .where((entry) => _matches(entry.title, author: entry.book.author))
        .length;
    final shown = onlineShown + importedBooks.length + localBooks.length;
    final total =
        _onlineBooks.length +
        widget.importedBooks.length +
        widget.localBooks.length;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.shelfTitle, style: theme.textTheme.headlineMedium),
                const SizedBox(height: 8),
                Text(l10n.shelfSubtitle, style: theme.textTheme.bodyLarge),
                const SizedBox(height: 28),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Icon(Icons.auto_stories, size: 48),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.controlledSourceTitle,
                                style: theme.textTheme.titleLarge,
                              ),
                              const SizedBox(height: 6),
                              Text(l10n.controlledSourceDescription),
                              const SizedBox(height: 18),
                              Text(
                                widget.run.message?.text(l10n) ??
                                    l10n.notRunYet,
                                key: const ValueKey('run-status'),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed:
                                    widget.run.stage ==
                                        BookSourceStage.completed
                                    ? null
                                    : widget.onRunSource,
                                icon: const Icon(Icons.play_arrow),
                                label: Text(l10n.runControlledSource),
                              ),
                            ],
                          ),
                        ),
                        _StageList(current: widget.run.stage),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 20),
                // The filter (#88) sits with the section titles it narrows,
                // above the online shelf's own header. Its words are the
                // field's own: every keystroke rebuilds this page, and the
                // sections below filter on what it holds.
                TextField(
                  key: const ValueKey('shelf-filter'),
                  controller: _filter,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: l10n.shelfFilterHint,
                    prefixIcon: const Icon(Icons.filter_alt_outlined),
                    border: const OutlineInputBorder(),
                    suffixIcon: filtering
                        ? IconButton(
                            key: const ValueKey('shelf-filter-clear'),
                            tooltip: l10n.shelfFilterClear,
                            onPressed: () => setState(_filter.clear),
                            icon: const Icon(Icons.clear),
                          )
                        : null,
                  ),
                ),
                if (filtering) ...[
                  const SizedBox(height: 8),
                  Text(
                    l10n.shelfFilterShown(shown, total),
                    key: const ValueKey('shelf-filter-count'),
                    style: theme.textTheme.bodyMedium,
                  ),
                  if (shown == 0) ...[
                    const SizedBox(height: 4),
                    Text(
                      l10n.shelfFilterNoMatch,
                      key: const ValueKey('shelf-filter-empty'),
                      style: theme.textTheme.bodyMedium,
                    ),
                  ],
                ],
              ],
            ),
          ),
          if (widget.shelf case final service?)
            OnlineBookshelf(
              service: service,
              revision: widget.onlineRevision,
              filter: _query,
              onLoaded: (books) => setState(() => _onlineBooks = books),
            )
          else
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(widget.spaceMessage ?? l10n.openingSpaceStore),
              ),
            ),
          if (importedBooks.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Text(
                l10n.migratedBooksTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverList.builder(
              itemCount: importedBooks.length,
              itemBuilder: (context, index) {
                final entry = importedBooks[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.cloud_download_outlined),
                    title: Text(entry.title),
                    subtitle: Text(
                      entry.book.needsRelink
                          ? l10n.needsRelinkOffset(entry.textOffset)
                          : l10n.migratedProgressOffset(entry.textOffset),
                    ),
                    trailing: const Icon(Icons.info_outline),
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
          if (localBooks.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Text(
                l10n.localBooksTitle,
                style: theme.textTheme.titleLarge,
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            SliverList.builder(
              itemCount: localBooks.length,
              itemBuilder: (context, index) {
                final book = localBooks[index];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.description),
                    title: Text(book.title),
                    subtitle: Text(l10n.progressOffset(book.textOffset)),
                    onTap: () => widget.onOpenBook(book),
                  ),
                );
              },
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
          if (widget.trace.isNotEmpty) ...[
            SliverToBoxAdapter(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.requestTraceTitle,
                        style: theme.textTheme.titleMedium,
                      ),
                      for (final entry in widget.trace)
                        Text('${entry.stage.name}: ${entry.path}'),
                    ],
                  ),
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 16)),
          ],
          const SliverToBoxAdapter(child: _ContractNotice()),
        ],
      ),
    );
  }
}

class _StageList extends StatelessWidget {
  const _StageList({required this.current});

  final BookSourceStage current;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final stages = <(BookSourceStage, String)>[
      (BookSourceStage.search, l10n.stageSearch),
      (BookSourceStage.bookInfo, l10n.stageBookInfo),
      (BookSourceStage.tableOfContents, l10n.stageTableOfContents),
      (BookSourceStage.content, l10n.stageContent),
    ];
    final currentIndex = stages.indexWhere((item) => item.$1 == current);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < stages.length; i++)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                i <= currentIndex ? Icons.check_circle : Icons.circle_outlined,
                size: 18,
                color: i <= currentIndex
                    ? Theme.of(context).colorScheme.primary
                    : null,
              ),
              const SizedBox(width: 8),
              Text(stages[i].$2),
            ],
          ),
      ],
    );
  }
}

class _ContractNotice extends StatelessWidget {
  const _ContractNotice();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Text(AppLocalizations.of(context).contractNotice),
      ),
    );
  }
}

class _LocalLibraryPage extends StatefulWidget {
  const _LocalLibraryPage({
    required this.service,
    required this.access,
    required this.onOpenBook,
    required this.onChanged,
    required this.onBusyChanged,
  });

  final LocalLibrary? service;
  final PlatformLibraryAccess access;
  final ValueChanged<LocalBook> onOpenBook;
  final Future<void> Function() onChanged;
  final ValueChanged<bool> onBusyChanged;

  @override
  State<_LocalLibraryPage> createState() => _LocalLibraryPageState();
}

class _LocalLibraryPageState extends State<_LocalLibraryPage> {
  List<LibraryFileReference> _entries = const [];
  final Set<String> _selected = {};
  final List<LibraryFileReference?> _parents = [];
  LibraryFileReference? _directory;
  LibraryTransfer? _transfer;
  String? _message;
  bool _busy = false;
  int _bytes = 0;
  int? _total;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshEntries());
  }

  @override
  void didUpdateWidget(covariant _LocalLibraryPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.service != widget.service) unawaited(_refreshEntries());
  }

  Future<void> _refreshEntries() async {
    final library = widget.service;
    final location = library?.managedLocation;
    try {
      final entries = location == null
          ? <LibraryFileReference>[]
          : await library!.access.list(location, directory: _directory);
      entries.removeWhere(
        (entry) =>
            !entry.directory &&
            !entry.name.toLowerCase().endsWith('.txt') &&
            !entry.name.toLowerCase().endsWith('.md'),
      );
      entries.sort(
        (a, b) => a.directory == b.directory
            ? a.name.compareTo(b.name)
            : a.directory
            ? -1
            : 1,
      );
      if (mounted) setState(() => _entries = entries);
    } on Object catch (error) {
      if (mounted) {
        setState(() {
          _entries = const [];
          _message = _failureText(error);
        });
      }
    }
  }

  String _failureText(Object error) {
    final l10n = AppLocalizations.of(context);
    if (error is! LibraryAccessFailure) {
      return l10n.libraryOperationFailed('$error');
    }
    return switch (error.code) {
      LibraryAccessError.cancelled => l10n.libraryCancelled,
      LibraryAccessError.permission => l10n.libraryPermissionLost,
      LibraryAccessError.missing => l10n.libraryFileMissing,
      LibraryAccessError.unsupported => l10n.libraryUnsupported,
      LibraryAccessError.verification => l10n.libraryVerificationFailed,
      LibraryAccessError.collision ||
      LibraryAccessError.io => l10n.libraryOperationFailed(error.message),
    };
  }

  Future<void> _run(
    Future<void> Function(LibraryTransfer) operation, {
    bool refreshEntries = true,
  }) async {
    if (_busy || widget.service == null) return;
    final transfer = LibraryTransfer(
      id: mintId('library-transfer'),
      onProgress: (bytes, total) {
        if (mounted) {
          setState(() {
            _bytes = bytes;
            _total = total;
          });
        }
      },
    );
    setState(() {
      _busy = true;
      _transfer = transfer;
      _message = null;
      _bytes = 0;
      _total = null;
    });
    widget.onBusyChanged(true);
    try {
      await operation(transfer);
    } on Object catch (error) {
      if (mounted) setState(() => _message = _failureText(error));
    } finally {
      // A batch import can publish earlier books before a later file fails.
      // Always refresh the actual store, including that partial-success case.
      try {
        await widget.onChanged();
        if (refreshEntries) await _refreshEntries();
      } on Object catch (error) {
        if (mounted) setState(() => _message = _failureText(error));
      }
      widget.onBusyChanged(false);
      if (mounted) {
        setState(() {
          _busy = false;
          _transfer = null;
        });
      }
    }
  }

  Future<void> _scanRecursively() => _run((transfer) async {
    final library = widget.service!;
    final location = library.managedLocation;
    if (location == null) return;
    final files = <LibraryFileReference>[];
    final visited = <String>{};
    Future<void> walk(LibraryFileReference? directory) async {
      transfer.checkCancelled();
      if (!visited.add(directory?.locator ?? location.locator)) return;
      for (final entry in await library.access.list(
        location,
        directory: directory,
      )) {
        transfer.checkCancelled();
        if (entry.directory) {
          await walk(entry);
        } else if (entry.name.toLowerCase().endsWith('.txt') ||
            entry.name.toLowerCase().endsWith('.md')) {
          files.add(entry);
        }
      }
    }

    await walk(_directory);
    transfer.checkCancelled();
    if (mounted) {
      setState(() {
        _entries = files;
        _message = AppLocalizations.of(context).scanFinished(files.length);
      });
    }
  }, refreshEntries: false);

  Future<LibraryConflictChoice> _resolveConflict(
    LibraryImportConflict conflict,
  ) async {
    if (!mounted) return LibraryConflictChoice.cancel;
    final l10n = AppLocalizations.of(context);
    return await showDialog<LibraryConflictChoice>(
          context: context,
          builder: (context) => AlertDialog(
            scrollable: true,
            title: Text(l10n.libraryNameConflict),
            content: Text(
              conflict.canUpdate
                  ? l10n.libraryConflictDescription(conflict.name)
                  : l10n.libraryConflictOtherBook(conflict.name),
            ),
            actions: [
              TextButton(
                onPressed: () =>
                    Navigator.pop(context, LibraryConflictChoice.cancel),
                child: Text(l10n.cancel),
              ),
              OutlinedButton(
                onPressed: () =>
                    Navigator.pop(context, LibraryConflictChoice.keepBoth),
                child: Text(l10n.libraryKeepBoth),
              ),
              if (conflict.canUpdate)
                FilledButton(
                  onPressed: () =>
                      Navigator.pop(context, LibraryConflictChoice.update),
                  child: Text(l10n.libraryUpdate),
                ),
            ],
          ),
        ) ??
        LibraryConflictChoice.cancel;
  }

  Future<bool> _ensureLocation(LibraryTransfer transfer) async {
    if (widget.service!.managedRoot != null) return true;
    final selected = await widget.access.pickDirectory();
    if (selected == null) return false;
    await widget.service!.selectLocation(
      selected,
      transfer: transfer,
      resolveConflict: _resolveConflict,
    );
    _directory = null;
    _parents.clear();
    return true;
  }

  Future<void> _importSelected() => _run((transfer) async {
    if (!await _ensureLocation(transfer)) return;
    final files = await widget.access.pickFiles();
    if (files == null) return;
    final books = await widget.service!.importFiles(
      files,
      transfer: transfer,
      resolveConflict: _resolveConflict,
    );
    if (mounted) {
      setState(
        () => _message = AppLocalizations.of(context).filesAdded(books.length),
      );
    }
  });

  Future<void> _changeLocation() => _run((transfer) async {
    final selected = await widget.access.pickDirectory();
    if (selected == null) return;
    final migration = await widget.service!.selectLocation(
      selected,
      transfer: transfer,
      resolveConflict: _resolveConflict,
    );
    _directory = null;
    _parents.clear();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    setState(() => _message = l10n.libraryDirectoryChanged);
    if (migration.previousFiles.isEmpty) return;
    final cleanup = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(l10n.libraryCleanupTitle),
        content: Text(
          l10n.libraryCleanupDescription(migration.previousFiles.length),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.libraryKeepOld),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l10n.libraryDeleteOld),
          ),
        ],
      ),
    );
    if (cleanup != true) return;
    try {
      await widget.service!.deletePreviousCopies(migration);
      if (mounted) setState(() => _message = l10n.libraryCleanupDone);
    } on Object catch (error) {
      if (mounted) {
        setState(
          () => _message = l10n.libraryCleanupFailed(_failureText(error)),
        );
      }
    }
  });

  Future<void> _adoptSelected() => _run((transfer) async {
    if (!await _ensureLocation(transfer)) return;
    final books = await widget.service!.adoptBooks(
      _selected.toList(),
      transfer: transfer,
      resolveConflict: _resolveConflict,
    );
    _selected.removeAll(books.map((book) => book.id));
    if (mounted) {
      setState(
        () => _message = AppLocalizations.of(
          context,
        ).libraryAdopted(books.length),
      );
    }
  });

  Future<void> _bookAction(LocalBook book, String action) async {
    if (action == 'remove') {
      await _run((_) => widget.service!.store.setShelved(book.id, false));
    } else if (action == 'delete') {
      final l10n = AppLocalizations.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          scrollable: true,
          title: Text(l10n.libraryDeleteFile),
          content: Text(l10n.libraryDeleteDescription(book.title)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l10n.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l10n.libraryDeleteFile),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await _run((_) => widget.service!.deleteBookFile(book.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final library = widget.service;
    final root = library?.managedRoot;
    final books = library?.books ?? const <LocalBook>[];
    final legacy = books.where((book) => book.rootId != root?.id).toList();
    final managed = books.where((book) => book.rootId == root?.id).toList();
    final enabled = library != null && !_busy;
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 32, 32, 20),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.navLocalLibrary,
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
                const SizedBox(height: 8),
                SelectableText(
                  root == null
                      ? l10n.libraryNoFolder
                      : root.needsRelink
                      ? l10n.currentFolderRelink(root.displayName)
                      : l10n.currentFolder(root.displayName),
                ),
                const SizedBox(height: 8),
                Text(l10n.libraryCopyHint),
                const SizedBox(height: 20),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: enabled ? _importSelected : null,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Text(l10n.libraryImport),
                    ),
                    OutlinedButton.icon(
                      onPressed: enabled ? _changeLocation : null,
                      icon: const Icon(Icons.folder_open),
                      label: Text(
                        root == null
                            ? l10n.libraryChooseFolder
                            : l10n.libraryChangeFolder,
                      ),
                    ),
                    if (root != null)
                      OutlinedButton.icon(
                        onPressed: enabled ? _scanRecursively : null,
                        icon: const Icon(Icons.manage_search),
                        label: Text(l10n.scanRecursively),
                      ),
                    if (_directory != null)
                      OutlinedButton.icon(
                        onPressed: enabled
                            ? () => _run((_) async {
                                _directory = _parents.removeLast();
                                await _refreshEntries();
                              })
                            : null,
                        icon: const Icon(Icons.arrow_upward),
                        label: Text(l10n.goUp),
                      ),
                    if (_selected.isNotEmpty)
                      OutlinedButton.icon(
                        onPressed: enabled ? _adoptSelected : null,
                        icon: const Icon(Icons.drive_file_move_outline),
                        label: Text(l10n.libraryAdopt),
                      ),
                  ],
                ),
                if (_busy) ...[
                  const SizedBox(height: 20),
                  LinearProgressIndicator(
                    value: _total != null && _total! > 0
                        ? (_bytes / _total!).clamp(0.0, 1.0)
                        : null,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        _bytes == 0
                            ? l10n.libraryWorking
                            : l10n.libraryProgress(_bytes),
                      ),
                      TextButton(
                        onPressed: _transfer?.cancelled == true
                            ? null
                            : () async {
                                try {
                                  await _transfer?.cancel();
                                } on Object catch (error) {
                                  if (mounted) {
                                    setState(
                                      () => _message = _failureText(error),
                                    );
                                  }
                                }
                                if (mounted) setState(() {});
                              },
                        child: Text(l10n.cancel),
                      ),
                    ],
                  ),
                ],
                if (_message != null) ...[
                  const SizedBox(height: 16),
                  Text(_message!, key: const ValueKey('library-status')),
                ],
                if (_directory != null) ...[
                  const SizedBox(height: 20),
                  Text(
                    _directory!.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          sliver: SliverList.builder(
            itemCount: _entries.length,
            itemBuilder: (context, index) {
              final entry = _entries[index];
              return ListTile(
                key: ValueKey('library-entry-${entry.key}'),
                leading: Icon(
                  entry.directory
                      ? Icons.folder_outlined
                      : Icons.description_outlined,
                ),
                title: Text(entry.name),
                onTap: entry.directory && enabled
                    ? () => _run((_) async {
                        _parents.add(_directory);
                        _directory = entry;
                        await _refreshEntries();
                      })
                    : null,
                trailing: entry.directory
                    ? const Icon(Icons.chevron_right)
                    : TextButton(
                        onPressed: enabled
                            ? () => _run((transfer) async {
                                final added = await library.importFiles(
                                  [entry],
                                  transfer: transfer,
                                  resolveConflict: _resolveConflict,
                                );
                                if (mounted) {
                                  setState(
                                    () => _message = l10n.filesAdded(
                                      added.length,
                                    ),
                                  );
                                }
                              })
                            : null,
                        child: Text(l10n.addEntryToShelf),
                      ),
              );
            },
          ),
        ),
        if (root != null && _entries.isEmpty)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            sliver: SliverToBoxAdapter(child: Text(l10n.libraryEmpty)),
          ),
        if (legacy.isNotEmpty) ...[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
            sliver: SliverToBoxAdapter(
              child: Text(
                l10n.libraryLegacyBooks,
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: SliverList.builder(
              itemCount: legacy.length,
              itemBuilder: (context, index) {
                final book = legacy[index];
                return CheckboxListTile(
                  key: ValueKey('library-adopt-${book.id}'),
                  secondary: IconButton(
                    onPressed: enabled ? () => widget.onOpenBook(book) : null,
                    tooltip: l10n.libraryRead,
                    icon: const Icon(Icons.menu_book_outlined),
                  ),
                  title: Text(book.title),
                  subtitle: Text(l10n.progressOffset(book.textOffset)),
                  value: _selected.contains(book.id),
                  onChanged: enabled
                      ? (selected) => setState(() {
                          if (selected == true) {
                            _selected.add(book.id);
                          } else {
                            _selected.remove(book.id);
                          }
                        })
                      : null,
                );
              },
            ),
          ),
        ],
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(32, 24, 32, 8),
          sliver: SliverToBoxAdapter(
            child: Text(
              l10n.shelfLocalBookCount(managed.length),
              style: Theme.of(context).textTheme.titleLarge,
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
          sliver: SliverList.builder(
            itemCount: managed.length,
            itemBuilder: (context, index) {
              final book = managed[index];
              return ListTile(
                leading: const Icon(Icons.menu_book_outlined),
                title: Text(book.title),
                subtitle: Text(l10n.progressOffset(book.textOffset)),
                onTap: enabled ? () => widget.onOpenBook(book) : null,
                trailing: PopupMenuButton<String>(
                  enabled: enabled,
                  tooltip: l10n.bookActions,
                  onSelected: (action) => _bookAction(book, action),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'remove',
                      child: Text(l10n.removeFromShelf),
                    ),
                    PopupMenuItem(
                      value: 'delete',
                      child: Text(l10n.libraryDeleteFile),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _MigrationPage extends StatelessWidget {
  const _MigrationPage({
    required this.result,
    required this.sources,
    required this.message,
    required this.spaceImport,
    required this.spaceStorePath,
    required this.spaceMessage,
    required this.onImportFile,
    required this.onDeleteSource,
    required this.onEditSourceUrl,
    required this.onLogin,
  });

  final MigrationImportRecord? result;
  final List<ImportedBookSource> sources;
  final String? message;
  final LegacyImportReport? spaceImport;
  final String? spaceStorePath;
  final String? spaceMessage;

  /// Called with the picked file's path: the importer reads it, because the two
  /// accepted containers need different readers (a Legado full backup is a ZIP).
  final ValueChanged<String> onImportFile;

  /// The source-management actions of one listed source (#53), called with its
  /// `bookSourceUrl` and the name the user sees it under; the page owns the
  /// confirmation its delete asks for, because the row and what it owned go
  /// together.
  final Future<void> Function(String ref, String name) onDeleteSource;
  final Future<void> Function(String ref, String name) onEditSourceUrl;

  /// Opens one source's login surface (#60), called with the same two values.
  final Future<void> Function(String ref, String name) onLogin;

  /// What the one-time import of this installation's own JSON stores did. It
  /// runs by itself on the first launch, so it reports here instead of behind a
  /// button.
  Widget _spaceCard(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    final report = spaceImport;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.spaceStoreTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              spaceStorePath ?? l10n.notCreatedYet,
              key: const ValueKey('space-store-path'),
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            if (spaceMessage != null)
              Text(spaceMessage!, key: const ValueKey('space-store-status'))
            else if (report == null)
              Text(l10n.opening)
            else if (report.imported)
              Text(
                l10n.importedNow(
                  report.importedAt,
                  report.summary().text(l10n),
                ),
                key: const ValueKey('space-store-status'),
              )
            else if (report.importedAt.isEmpty)
              Text(
                l10n.nothingToImport,
                key: const ValueKey('space-store-status'),
              )
            else
              Text(
                l10n.alreadyImported(
                  report.importedAt,
                  report.summary().text(l10n),
                ),
                key: const ValueKey('space-store-status'),
              ),
            if (report != null && report.losses.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final loss in report.losses) Text('• ${loss.text(l10n)}'),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // The source list grows with the space, so the page scrolls rather than
    // clipping what does not fit.
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Text(
          l10n.navMigration,
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: 8),
        Text(l10n.migrationIntro),
        const SizedBox(height: 20),
        _spaceCard(context),
        const SizedBox(height: 20),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () async {
              final picked = await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['zip', 'json'],
              );
              final path = picked?.path;
              if (path == null) return;
              onImportFile(path);
            },
            icon: const Icon(Icons.file_open),
            label: Text(l10n.chooseLegadoBackup),
          ),
        ),
        if (message != null) ...[
          const SizedBox(height: 16),
          Text(message!, key: const ValueKey('migration-status')),
        ],
        if (sources.isNotEmpty) ...[
          const SizedBox(height: 20),
          Text(
            l10n.importedSourcesTitle,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          for (final source in sources)
            ListTile(
              leading: const Icon(Icons.public),
              title: Text('${source.data['bookSourceName'] ?? source.id}'),
              subtitle: Text(
                '${source.data['bookSourceUrl'] ?? l10n.urlMissing}',
              ),
              // A source's row identity is its URL, so the two actions a source
              // has are deleting it and moving it to another URL (#53).
              trailing: PopupMenuButton<String>(
                key: ValueKey('source-actions-${source.id}'),
                tooltip: l10n.sourceActions,
                onSelected: (action) {
                  final name = '${source.data['bookSourceName'] ?? source.id}';
                  if (action == 'login') {
                    onLogin(source.id, name);
                  } else if (action == 'edit') {
                    onEditSourceUrl(source.id, name);
                  } else {
                    onDeleteSource(source.id, name);
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'login', child: Text(l10n.loginAction)),
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(l10n.editSourceUrlAction),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(l10n.deleteSource),
                  ),
                ],
              ),
            ),
        ],
        if (result != null) ...[
          const SizedBox(height: 20),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.importPreviewTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(l10n.previewSources(result!.sourceCount)),
                  Text(l10n.previewBooks(result!.bookCount)),
                  Text(l10n.previewProgress(result!.progressCount)),
                  const SizedBox(height: 12),
                  for (final loss in result!.losses)
                    Text('• ${loss.text(l10n)}'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
