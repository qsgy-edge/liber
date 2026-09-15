import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'domain/contracts.dart';
import 'local/local_library_service.dart';
import 'migration/migration_service.dart';
import 'source/book_source_service.dart';
import 'source/source_trial_page.dart';
import 'source/online_bookshelf.dart';

void main() {
  runApp(const LiberApp());
}

class LiberApp extends StatelessWidget {
  const LiberApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liber',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315c72)),
        useMaterial3: true,
      ),
      home: const LiberHomePage(),
    );
  }
}

class LiberHomePage extends StatefulWidget {
  const LiberHomePage({super.key});

  @override
  State<LiberHomePage> createState() => _LiberHomePageState();
}

class _LiberHomePageState extends State<LiberHomePage> {
  int _selectedIndex = 0;
  int _onlineRevision = 0;
  BookSourceRunState _run = const BookSourceRunState(
    stage: BookSourceStage.idle,
  );
  final LocalLibraryService _libraryService = LocalLibraryService();
  final MigrationService _migrationService = MigrationService();
  final BookSourceService _bookSourceService = BookSourceService();
  List<FileSystemEntity> _folderEntries = const <FileSystemEntity>[];
  List<LocalBook> _addedBooks = const <LocalBook>[];
  MigrationImportRecord? _migrationResult;
  String? _libraryMessage;
  String? _migrationMessage;
  List<BookSourceTraceEntry> _trace = const <BookSourceTraceEntry>[];

  @override
  void initState() {
    super.initState();
    _loadLibrary();
  }

  Future<void> _loadLibrary() async {
    await _libraryService.load();
    await _migrationService.load();
    final entries = await _libraryService.listCurrentFolder();
    if (mounted) setState(() => _folderEntries = entries);
  }

  Future<void> _runControlledSource() async {
    final result = await _bookSourceService.run((state) {
      if (mounted) setState(() => _run = state);
    });
    if (mounted) setState(() => _trace = result.trace);
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      _BookshelfPage(
        run: _run,
        localBooks: _libraryService.books,
        importedBooks: _migrationService.books,
        onlineRevision: _onlineRevision,
        onRunSource: _runControlledSource,
        trace: _trace,
        onOpenBook: (book) async {
          await Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => _ReaderPage(
                book: book,
                onOffsetChanged: (offset) async {
                  await _libraryService.updateOffset(book.id, offset);
                  if (mounted) setState(() {});
                },
              ),
            ),
          );
          if (mounted) setState(() {});
        },
      ),
      _LocalLibraryPage(
        service: _libraryService,
        entries: _folderEntries,
        books: _libraryService.books,
        message: _libraryMessage,
        currentPath: _libraryService.currentPath,
        onEnterFolder: (path) async {
          final entries = await _libraryService.enterFolder(path);
          setState(() => _folderEntries = entries);
        },
        onGoUp: () async {
          final entries = await _libraryService.goUp();
          setState(() => _folderEntries = entries);
        },
        onRootSelected: (path) async {
          final root = await _libraryService.selectRoot(path);
          final entries = await _libraryService.listCurrentFolder();
          setState(() {
            _folderEntries = entries;
            _libraryMessage = '已选择根目录：${root.displayName}';
          });
        },
        onScan: () async {
          final entries = await _libraryService.scanRecursively();
          setState(() {
            _folderEntries = entries;
            _libraryMessage = '递归扫描完成：发现 ${entries.length} 个 TXT/Markdown 文件';
          });
        },
        onAdd: () async {
          final books = await _libraryService.addFiles(_folderEntries);
          setState(() {
            _addedBooks = [..._addedBooks, ...books];
            _libraryMessage = books.isEmpty
                ? '没有新的文件加入书架'
                : '已显式加入 ${books.length} 本书';
          });
        },

        onAddEntry: (entry) async {
          final books = await _libraryService.addFiles([entry]);
          setState(() {
            _addedBooks = [..._addedBooks, ...books];
            _libraryMessage = books.isEmpty
                ? '该文件已经在书架中'
                : '已加入 ${books.first.title}';
          });
        },
      ),
      _MigrationPage(
        result: _migrationResult,
        sources: _migrationService.sources,
        message: _migrationMessage,
        onImport: (jsonText) async {
          try {
            final result = await _migrationService.importJson(jsonText);
            setState(() {
              _migrationResult = result;
              _migrationMessage = '导入预览完成';
            });
          } on FormatException catch (error) {
            setState(() => _migrationMessage = error.message);
          }
        },
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        actions: [
          TextButton.icon(
            onPressed: () async {
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) =>
                      SourceTrialPage(sources: _migrationService.sources),
                ),
              );
              if (mounted) setState(() => _onlineRevision++);
            },
            icon: const Icon(Icons.travel_explore),
            label: const Text('书源试读'),
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
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.menu_book_outlined),
                selectedIcon: Icon(Icons.menu_book),
                label: Text('书架'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.folder_outlined),
                selectedIcon: Icon(Icons.folder),
                label: Text('本地书库'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.import_export_outlined),
                selectedIcon: Icon(Icons.import_export),
                label: Text('迁移'),
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
    required this.onRunSource,
    required this.trace,
    required this.onOpenBook,
  });

  final BookSourceRunState run;
  final List<LocalBook> localBooks;
  final List<ImportedBook> importedBooks;
  final int onlineRevision;
  final VoidCallback onRunSource;
  final List<BookSourceTraceEntry> trace;
  final ValueChanged<LocalBook> onOpenBook;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('书架', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            'Windows-first MVP · 共享书源契约验证台',
            style: theme.textTheme.bodyLarge,
          ),
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
                          'Wayfinder 受控书源',
                          style: theme.textTheme.titleLarge,
                        ),
                        const SizedBox(height: 6),
                        const Text('用于验证搜索、书籍信息、目录和正文的最小链路。'),
                        const SizedBox(height: 18),
                        Text(
                          run.message.isEmpty ? '尚未运行' : run.message,
                          key: const ValueKey('run-status'),
                        ),
                        const SizedBox(height: 12),
                        FilledButton.icon(
                          onPressed: run.stage == BookSourceStage.completed
                              ? null
                              : onRunSource,
                          icon: const Icon(Icons.play_arrow),
                          label: const Text('运行受控书源'),
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
                OnlineBookshelf(revision: onlineRevision),
                if (importedBooks.isNotEmpty) ...[
                  Text('已迁移书籍', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final book in importedBooks)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.cloud_download_outlined),
                        title: Text(book.title),
                        subtitle: Text(
                          book.needsRelink
                              ? '需要重新关联本地文件 · offset：${book.progressOffset}'
                              : '迁移进度 offset：${book.progressOffset}',
                        ),
                        trailing: const Icon(Icons.info_outline),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
                if (localBooks.isNotEmpty) ...[
                  Text('本地书', style: theme.textTheme.titleLarge),
                  const SizedBox(height: 8),
                  for (final book in localBooks)
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.description),
                        title: Text(book.title),
                        subtitle: Text('进度 offset：${book.textOffset}'),
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
                          Text('请求 trace', style: theme.textTheme.titleMedium),
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

class _ReaderPage extends StatefulWidget {
  const _ReaderPage({required this.book, required this.onOffsetChanged});

  final LocalBook book;
  final ValueChanged<int> onOffsetChanged;

  @override
  State<_ReaderPage> createState() => _ReaderPageState();
}

class _ReaderPageState extends State<_ReaderPage> {
  final TextEditingController _controller = TextEditingController();
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final text = await File(widget.book.path).readAsString();
      _controller.text = text;
      final offset = widget.book.textOffset.clamp(0, text.length);
      _controller.selection = TextSelection.collapsed(offset: offset);
    } on FileSystemException catch (error) {
      _error = error.message;
    } on IOException catch (error) {
      _error = error.toString();
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          FilledButton.icon(
            onPressed: _loading
                ? null
                : () {
                    widget.onOffsetChanged(_controller.selection.baseOffset);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('阅读位置已保存')));
                  },
            icon: const Icon(Icons.bookmark_add),
            label: const Text('保存位置'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text('无法读取：$_error'))
          : Padding(
              padding: const EdgeInsets.all(24),
              child: TextField(
                controller: _controller,
                readOnly: true,
                expands: true,
                maxLines: null,
                textAlignVertical: TextAlignVertical.top,
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            ),
    );
  }
}

class _StageList extends StatelessWidget {
  const _StageList({required this.current});

  final BookSourceStage current;

  @override
  Widget build(BuildContext context) {
    const stages = <(BookSourceStage, String)>[
      (BookSourceStage.search, '搜索'),
      (BookSourceStage.bookInfo, '书籍信息'),
      (BookSourceStage.tableOfContents, '目录'),
      (BookSourceStage.content, '正文'),
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
    return const Card(
      child: Padding(
        padding: EdgeInsets.all(20),
        child: Text(
          '当前阶段只运行受控 fixture。fjs 的 host callback 生命周期和不可信书源隔离仍是明确门禁；Windows MVP 不代表五平台兼容性已完成。',
        ),
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
    required this.currentPath,
    required this.onEnterFolder,
    required this.onGoUp,
    required this.onRootSelected,
    required this.onScan,
    required this.onAdd,
    required this.onAddEntry,
  });

  final LocalLibraryService service;
  final List<FileSystemEntity> entries;
  final List<LocalBook> books;
  final String? message;
  final String? currentPath;
  final Future<void> Function(String path) onEnterFolder;
  final Future<void> Function() onGoUp;
  final Future<void> Function(String path) onRootSelected;
  final VoidCallback onScan;
  final VoidCallback onAdd;
  final Future<void> Function(FileSystemEntity entry) onAddEntry;

  @override
  Widget build(BuildContext context) {
    final root = service.root;
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('本地书库', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          Text(
            root == null ? '尚未授权目录' : '当前位置：${currentPath ?? root.displayName}',
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
                label: const Text('选择根目录'),
              ),
              OutlinedButton.icon(
                onPressed: root == null ? null : onGoUp,
                icon: const Icon(Icons.arrow_upward),
                label: const Text('返回上级'),
              ),
              OutlinedButton.icon(
                onPressed: root == null ? null : onScan,
                icon: const Icon(Icons.search),
                label: const Text('递归扫描当前目录'),
              ),
              OutlinedButton.icon(
                onPressed: entries.isEmpty ? null : onAdd,
                icon: const Icon(Icons.playlist_add),
                label: const Text('显式加入书架'),
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
                        entry is Directory ? '文件夹' : 'TXT/Markdown 文件',
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
                            const PopupMenuItem(
                              value: 'open',
                              child: Text('打开文件夹'),
                            ),
                          if (entry is File)
                            const PopupMenuItem(
                              value: 'add',
                              child: Text('加入书架'),
                            ),
                        ],
                      ),
                      onTap: entry is Directory
                          ? () => onEnterFolder(entry.path)
                          : null,
                    ),
                  if (entries.isEmpty) const ListTile(title: Text('扫描结果为空')),
                ],
              ),
            ),
          ),
          Text('书架已加入 ${books.length} 本本地书'),
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
    required this.onImport,
  });

  final MigrationImportRecord? result;
  final List<ImportedBookSource> sources;
  final String? message;
  final ValueChanged<String> onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('迁移', style: Theme.of(context).textTheme.headlineMedium),
          const SizedBox(height: 8),
          const Text('选择 JSON 备份文件，先做导入预览并报告无法迁移的数据。'),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () async {
              final picked = await FilePicker.pickFile(
                type: FileType.custom,
                allowedExtensions: ['json'],
              );
              final path = picked?.path;
              if (path == null) return;
              final jsonText = await File(path).readAsString();
              onImport(jsonText);
            },
            icon: const Icon(Icons.file_open),
            label: const Text('选择 Legado JSON'),
          ),
          if (message != null) ...[
            const SizedBox(height: 16),
            Text(message!, key: const ValueKey('migration-status')),
          ],
          if (sources.isNotEmpty) ...[
            const SizedBox(height: 20),
            Text('已导入书源', style: Theme.of(context).textTheme.titleLarge),
            for (final source in sources)
              ListTile(
                leading: const Icon(Icons.public),
                title: Text('${source.data['bookSourceName'] ?? source.id}'),
                subtitle: Text(
                  '${source.data['bookSourceUrl'] ?? '未提供 URL'} · 等待 WebView2 transport',
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
                    Text('导入预览', style: Theme.of(context).textTheme.titleLarge),
                    Text('Book Sources：${result!.sourceCount}'),
                    Text('书架：${result!.bookCount}'),
                    Text('阅读进度：${result!.progressCount}'),
                    const SizedBox(height: 12),
                    for (final loss in result!.losses) Text('• $loss'),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
