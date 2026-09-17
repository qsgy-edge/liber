import 'dart:async';

import 'package:flutter/material.dart';

import '../store/shelf.dart';
import 'html_source_pipeline.dart';
import 'http_source_transport.dart';
import 'json_source_pipeline.dart' show SourceChapter;
import 'js_source_runtime.dart' show SourceHostMessage;
import 'online_reader_page.dart';
import 'source_http_uri.dart';
import 'source_notice.dart';

class HtmlSourceBrowser extends StatefulWidget {
  const HtmlSourceBrowser({
    super.key,
    required this.source,
    required this.keyword,
    required this.service,
    this.resume,
    this.pipeline,
  });
  final Map<String, dynamic> source;
  final String keyword;

  /// The space's shelf: membership, the TOC and the position all live there.
  final ShelfService service;

  /// The shelf book this browser was opened from, when it was.
  final ShelfEntry? resume;

  final HtmlSourcePipeline? pipeline;
  @override
  State<HtmlSourceBrowser> createState() => _HtmlSourceBrowserState();
}

class _HtmlSourceBrowserState extends State<HtmlSourceBrowser> {
  /// The pipeline this page runs its analyses on.
  ///
  /// One pipeline carries one analysis, so this is not `final`: when the reader
  /// takes the pipeline over for its chapter fetch, this page opens a fresh one
  /// for whatever it runs next.
  late HtmlSourcePipeline pipeline;

  bool inShelf = false;
  List<HtmlBook> hits = [];
  HtmlBook? selected;
  List<SourceChapter> chapters = [];
  bool busy = true;
  String status = '正在搜索';
  String? error;

  String get sourceUrl => '${widget.source['bookSourceUrl'] ?? ''}';

  @override
  void initState() {
    super.initState();
    pipeline =
        widget.pipeline ??
        HtmlSourcePipeline(
          widget.source,
          HttpSourceTransport(),
          hostState: widget.service.hostState,
          androidId: widget.service.androidId,
          onHostMessage: _showHostNotice,
        );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(start());
    });
  }

  /// Shows a source's rate-limited `toast`/`longToast` notice on this page; a
  /// disposed page drops it silently.
  void _showHostNotice(SourceHostMessage message) {
    if (!mounted) return;
    showSourceNotice(context, message);
  }

  Future<void> start() async {
    try {
      if (widget.resume case final entry?) {
        final hit = entry.htmlBook;
        if (entry.chapters.isNotEmpty) {
          setState(() {
            selected = hit;
            inShelf = entry.shelved;
            chapters = [
              for (final chapter in entry.chapters)
                SourceChapter(
                  chapter.name,
                  SourceHttpUri.parse(chapter.url ?? chapter.chapterKey),
                ),
            ];
            busy = false;
          });
        } else {
          await _details(hit);
        }
        if (!mounted || error != null) return;
        final savedUrl = entry.chapterKey;
        final index = savedUrl.isEmpty
            ? 0
            : chapters.indexWhere((c) => '${c.url}' == savedUrl);
        if (index < 0) throw StateError('原章节已不在目录中，进度仍保留，请选择章节');
        await read(index, entry.textOffset);
      } else {
        final output = await pipeline.search(widget.keyword);
        if (mounted) {
          setState(() {
            hits = output;
            busy = false;
            status = '找到 ${hits.length} 本书';
          });
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  /// Starts one book analysis, unless one already owns the pipeline.
  ///
  /// One pipeline carries one analysis — `_page`, `_ruleState`, `_bookOptions`
  /// and the cancellation token are fields, not per-call arguments — so a
  /// second `details()` while one is in flight would overwrite them under the
  /// first. The call is ignored instead of disabled at each entry: a search
  /// row and 更新目录 both come through here, and `busy` already replaces the
  /// whole body with the spinner while an analysis runs, so an ignored call is
  /// the only thing an entry could offer at that moment.
  Future<void> details(HtmlBook hit) async {
    if (busy) return;
    await _details(hit);
  }

  Future<void> _details(HtmlBook hit) async {
    setState(() {
      busy = true;
      error = null;
      status = '正在读取详情和完整目录';
    });
    try {
      final (book, items) = await pipeline.details(hit);
      final existing = await widget.service.find(sourceUrl, '${book.url}');
      if (existing != null) {
        await widget.service.updateCatalog(sourceUrl, book, items);
      }
      if (mounted) {
        setState(() {
          selected = book;
          inShelf = existing?.shelved == true;
          chapters = items;
          busy = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '$e';
        });
      }
    }
  }

  Future<void> add(
    HtmlBook book, [
    List<SourceChapter> items = const [],
  ]) async {
    try {
      await widget.service.add(widget.source, book, items);
      if (!mounted) return;
      setState(() {
        if (selected?.url == book.url) inShelf = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('已加入书架：${book.title}')));
    } catch (e) {
      if (mounted) setState(() => error = '加入书架失败：$e');
    }
  }

  Future<void> read(int index, [int offset = 0]) async {
    final book = selected!;
    // Reading a book nobody added still tracks a position, and a position
    // belongs to a book row; the row stays off the shelf.
    final bookId =
        (await widget.service.find(sourceUrl, '${book.url}'))?.id ??
        await widget.service.ensureBook(widget.source, book);
    if (!mounted) return;
    // Ownership rule: whoever runs an analysis owns its pipeline. The reader
    // runs the chapter fetch through this one, so it takes it over and cancels
    // it in its own dispose; this page opens a fresh pipeline for whatever it
    // runs next. Disposing this page must never cancel work the reader still
    // holds.
    final readerPipeline = pipeline;
    pipeline = HtmlSourcePipeline(
      widget.source,
      readerPipeline.transport,
      hostState: widget.service.hostState,
      androidId: widget.service.androidId,
      onHostMessage: _showHostNotice,
    );
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineReaderPage(
          pipeline: readerPipeline,
          book: book,
          bookId: bookId,
          chapters: chapters,
          service: widget.service,
          chapterIndex: index,
          textOffset: offset,
        ),
      ),
    );
  }

  @override
  void dispose() {
    pipeline.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text(selected?.title ?? '搜索结果')),
    body: busy
        ? Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(status),
              ],
            ),
          )
        : CustomScrollView(
            slivers: [
              if (error != null)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('读取失败：$error'),
                  ),
                ),
              if (selected case final book?) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(book.author),
                        const SizedBox(height: 12),
                        Text(book.intro),
                        const SizedBox(height: 16),
                        Text('目录 · ${chapters.length} 章'),
                        Wrap(
                          spacing: 12,
                          children: [
                            FilledButton.icon(
                              onPressed: inShelf
                                  ? null
                                  : () => add(book, chapters),
                              icon: const Icon(Icons.playlist_add),
                              label: Text(inShelf ? '已在书架' : '加入书架'),
                            ),
                            OutlinedButton.icon(
                              onPressed: () => details(book),
                              icon: const Icon(Icons.refresh),
                              label: const Text('更新目录'),
                            ),
                          ],
                        ),
                        if (hits.isNotEmpty)
                          TextButton(
                            onPressed: () => setState(() => selected = null),
                            child: const Text('返回搜索结果'),
                          ),
                      ],
                    ),
                  ),
                ),
                SliverList.builder(
                  itemCount: chapters.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(chapters[i].name),
                    onTap: () => read(i),
                  ),
                ),
              ] else ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(status),
                  ),
                ),
                SliverList.builder(
                  itemCount: hits.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(hits[i].title),
                    subtitle: Text(hits[i].author),
                    trailing: IconButton(
                      tooltip: '加入书架',
                      icon: const Icon(Icons.playlist_add),
                      onPressed: () => add(hits[i]),
                    ),
                    onTap: () => details(hits[i]),
                  ),
                ),
              ],
            ],
          ),
  );
}
