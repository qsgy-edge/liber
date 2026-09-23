import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'domain/contracts.dart';
import 'l10n/app_localizations.dart';
import 'local/local_reader.dart';
import 'local/local_reader_page.dart';
import 'local/reader_engine.dart';
import 'settings/interface_language.dart';
import 'settings/interface_language_page.dart';
import 'settings/reader_script_page.dart';
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
import 'store/legacy_import.dart';
import 'store/local_library.dart';
import 'store/shelf.dart';
import 'store/space_store.dart';
import 'store/workspace.dart';

void main() {
  installApplicationBindings();
  // `--dart-define=LIBER_WORKSPACE_ROOT=<path>` opens a different installation
  // directory instead of `%APPDATA%\Liber`: a review run drives the real app
  // without the operator's own library underneath it.
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
  const LiberApp({super.key, this.workspaceRoot, this.interfaceLanguage});

  /// The installation directory (`manifest.json` and `spaces\`), the default
  /// `%APPDATA%\Liber` when null. Tests point it at a directory of their own so
  /// a test run never touches the user's library.
  final Directory? workspaceRoot;

  /// Pins the interface language instead of resolving it from the space store.
  ///
  /// A widget test — and a driven run — says which language it expects rather
  /// than inheriting the machine's locale; null leaves the resolution to the
  /// `interface.language` row and the system locale (#28).
  final Locale? interfaceLanguage;

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
        onInterfaceLocale: (locale) => setState(() => _resolved = locale),
      ),
    );
  }
}

class LiberHomePage extends StatefulWidget {
  const LiberHomePage({super.key, this.workspaceRoot, this.onInterfaceLocale});

  final Directory? workspaceRoot;

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
  List<FileSystemEntity> _folderEntries = const <FileSystemEntity>[];
  List<ShelfEntry> _importedBooks = const <ShelfEntry>[];
  List<ImportedBookSource> _sources = const <ImportedBookSource>[];
  MigrationImportRecord? _migrationResult;
  String? _libraryMessage;
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
      final workspace = await Workspace.open(root: widget.workspaceRoot);
      final store = await workspace.openSpace(Workspace.defaultSpaceId);
      final shelf = ShelfService(store, androidId: await workspace.androidId());
      final library = LocalLibrary(store);
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
      await _refreshFolder();
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

  Future<void> _refreshFolder() async {
    final library = _library;
    if (library == null) return;
    final entries = await library.listCurrentFolder();
    if (mounted) setState(() => _folderEntries = entries);
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
    final processing = await _contentProcessing(book, library, messenger);
    if (!mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => LocalReaderPage(
          reader: LocalReader(
            engine: const NativeReaderEngine(),
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
        onNotice: (message) =>
            messenger?.showSnackBar(SnackBar(content: Text(message))),
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
          transport: HttpSourceTransport(),
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
        entries: _folderEntries,
        books: library?.books ?? const <LocalBook>[],
        message: _libraryMessage,
        onOpenBook: _openLocalBook,
        onEnterFolder: (path) async {
          final entries = await library?.enterFolder(path);
          if (mounted) {
            setState(() {
              if (entries != null) _folderEntries = entries;
            });
          }
        },
        onGoUp: () async {
          final entries = await library?.goUp();
          if (mounted) {
            setState(() {
              if (entries != null) _folderEntries = entries;
            });
          }
        },
        onRootSelected: (path) async {
          final root = await library?.selectRoot(path);
          final entries = await library?.listCurrentFolder();
          if (!mounted) return;
          setState(() {
            if (entries != null) _folderEntries = entries;
            if (root != null) {
              _libraryMessage = AppLocalizations.of(
                context,
              ).rootSelected(root.displayName);
            }
          });
        },
        onScan: () async {
          final entries = await library?.scanRecursively();
          if (!mounted) return;
          setState(() {
            if (entries != null) _folderEntries = entries;
            _libraryMessage = AppLocalizations.of(
              context,
            ).scanFinished(entries?.length ?? 0);
          });
        },
        onAdd: () async {
          final books = await library?.addFiles(_folderEntries);
          if (!mounted) return;
          setState(() {
            _libraryMessage = books == null || books.isEmpty
                ? l10n.noNewFiles
                : l10n.filesAdded(books.length);
          });
        },

        onAddEntry: (entry) async {
          final books = await library?.addFiles([entry]);
          if (!mounted) return;
          setState(() {
            _libraryMessage = books == null || books.isEmpty
                ? l10n.fileAlreadyOnShelf
                : l10n.fileAdded(books.first.title);
          });
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
            if (mounted) setState(() => _migrationMessage = error.message);
          }
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        // #40 entry region: the app bar's actions. `精确搜索` is the
        // multi-source search entry (`PreciseSearchPage`); the page reads the
        // space's sources itself, so this hunk needs nothing but the shelf.
        // #28's own entry is `界面语言`, beside #27's `中文转换`.
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
            onDestinationSelected: (index) {
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

class _BookshelfPage extends StatelessWidget {
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
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
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
                          run.message.isEmpty ? l10n.notRunYet : run.message,
                          key: const ValueKey('run-status'),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: run.stage == BookSourceStage.completed
                              ? null
                              : onRunSource,
                          icon: const Icon(Icons.play_arrow),
                          label: Text(l10n.runControlledSource),
                        ),
                      ],
                    ),
                  ),
                  _StageList(current: run.stage),
                ],
              ),
            ),
          ),
          Expanded(
            child: ListView(
              children: [
                if (shelf case final service?)
                  OnlineBookshelf(service: service, revision: onlineRevision)
                else
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(spaceMessage ?? l10n.openingSpaceStore),
                  ),
                if (importedBooks.isNotEmpty) ...[
                  Text(
                    l10n.migratedBooksTitle,
                    style: theme.textTheme.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  for (final entry in importedBooks)
                    Card(
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
                    ),
                  const SizedBox(height: 16),
                ],
                if (localBooks.isNotEmpty) ...[
                  Text(l10n.localBooksTitle, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final book in localBooks)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.description),
                        title: Text(book.title),
                        subtitle: Text(l10n.progressOffset(book.textOffset)),
                        onTap: () => onOpenBook(book),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (trace.isNotEmpty) ...[
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            l10n.requestTraceTitle,
                            style: theme.textTheme.titleMedium,
                          ),
                          for (final entry in trace)
                            Text('${entry.stage.name}: ${entry.path}'),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
                const _ContractNotice(),
              ],
            ),
          ),
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

class _LocalLibraryPage extends StatelessWidget {
  const _LocalLibraryPage({
    required this.service,
    required this.entries,
    required this.books,
    required this.message,
    required this.onEnterFolder,
    required this.onGoUp,
    required this.onRootSelected,
    required this.onScan,
    required this.onAdd,
    required this.onAddEntry,
    required this.onOpenBook,
  });

  /// Null until the space opens; every action below needs it.
  final LocalLibrary? service;
  final List<FileSystemEntity> entries;
  final List<LocalBook> books;
  final String? message;
  final Future<void> Function(String path) onEnterFolder;
  final Future<void> Function() onGoUp;
  final Future<void> Function(String path) onRootSelected;
  final VoidCallback onScan;
  final VoidCallback onAdd;
  final Future<void> Function(FileSystemEntity entry) onAddEntry;

  /// Opens a book already admitted to the shelf, from this page as well as from
  /// the shelf itself.
  final ValueChanged<LocalBook> onOpenBook;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final root = service?.root;
    final current = service?.currentPath;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.navLocalLibrary,
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: 8),
          Text(
            root == null
                ? l10n.noRootFolder
                : root.needsRelink
                ? l10n.currentFolderRelink(current ?? root.displayName)
                : l10n.currentFolder(current ?? root.displayName),
          ),
          const SizedBox(height: 20),
          Wrap(
            spacing: 12,
            children: [
              FilledButton.icon(
                onPressed: () async {
                  final path = await FilePicker.getDirectoryPath();
                  if (path != null) await onRootSelected(path);
                },
                icon: const Icon(Icons.folder_open),
                label: Text(l10n.chooseRootFolder),
              ),
              OutlinedButton.icon(
                onPressed: root == null ? null : onGoUp,
                icon: const Icon(Icons.arrow_upward),
                label: Text(l10n.goUp),
              ),
              OutlinedButton.icon(
                onPressed: root == null ? null : onScan,
                icon: const Icon(Icons.search),
                label: Text(l10n.scanRecursively),
              ),
              OutlinedButton.icon(
                onPressed: entries.isEmpty ? null : onAdd,
                icon: const Icon(Icons.playlist_add),
                label: Text(l10n.addToShelf),
              ),
            ],
          ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, key: const ValueKey('library-status')),
          ],
          const SizedBox(height: 20),
          Expanded(
            child: Card(
              child: ListView(
                padding: const EdgeInsets.all(12),
                children: [
                  for (final entry in entries)
                    ListTile(
                      leading: Icon(
                        entry is Directory ? Icons.folder : Icons.description,
                      ),
                      title: Text(entry.path),
                      subtitle: Text(
                        entry is Directory ? l10n.folder : l10n.textFile,
                      ),
                      trailing: PopupMenuButton<String>(
                        onSelected: (action) {
                          if (entry is Directory && action == 'open') {
                            onEnterFolder(entry.path);
                          } else if (entry is File && action == 'add') {
                            onAddEntry(entry);
                          }
                        },
                        itemBuilder: (_) => [
                          if (entry is Directory)
                            PopupMenuItem(
                              value: 'open',
                              child: Text(l10n.openFolder),
                            ),
                          if (entry is File)
                            PopupMenuItem(
                              value: 'add',
                              child: Text(l10n.addEntryToShelf),
                            ),
                        ],
                      ),
                      onTap: entry is Directory
                          ? () => onEnterFolder(entry.path)
                          : null,
                    ),
                  if (entries.isEmpty) ListTile(title: Text(l10n.scanEmpty)),
                ],
              ),
            ),
          ),
          Text(l10n.shelfLocalBookCount(books.length)),
          for (final book in books)
            ListTile(
              dense: true,
              leading: const Icon(Icons.menu_book_outlined),
              title: Text(book.title),
              subtitle: Text(l10n.progressOffset(book.textOffset)),
              onTap: () => onOpenBook(book),
            ),
        ],
      ),
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
                l10n.importedNow(report.importedAt, report.summary()),
                key: const ValueKey('space-store-status'),
              )
            else if (report.importedAt.isEmpty)
              Text(
                l10n.nothingToImport,
                key: const ValueKey('space-store-status'),
              )
            else
              Text(
                l10n.alreadyImported(report.importedAt, report.summary()),
                key: const ValueKey('space-store-status'),
              ),
            if (report != null && report.losses.isNotEmpty) ...[
              const SizedBox(height: 12),
              for (final loss in report.losses) Text('• $loss'),
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
                  for (final loss in result!.losses) Text('• $loss'),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }
}
