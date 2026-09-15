import 'dart:async';

import 'package:flutter/material.dart';

import 'html_source_pipeline.dart';
import 'http_source_transport.dart';
import 'json_source_pipeline.dart' show SourceChapter;
import 'online_reader_page.dart';
import 'online_reading_store.dart';
import 'source_http_uri.dart';

class HtmlSourceBrowser extends StatefulWidget {
  const HtmlSourceBrowser({
    super.key,
    required this.source,
    required this.keyword,
    this.resume,
    this.store,
    this.pipeline,
  });
  final Map<String, dynamic> source;
  final String keyword;
  final Map<String, dynamic>? resume;
  final OnlineReadingStore? store;
  final HtmlSourcePipeline? pipeline;
  @override
  State<HtmlSourceBrowser> createState() => _HtmlSourceBrowserState();
}

class _HtmlSourceBrowserState extends State<HtmlSourceBrowser> {
  late final pipeline =
      widget.pipeline ??
      HtmlSourcePipeline(widget.source, HttpSourceTransport());
  late final store = widget.store ?? OnlineReadingStore();
  bool inShelf = false;
  List<HtmlBook> hits = [];
  HtmlBook? selected;
  List<SourceChapter> chapters = [];
  bool busy = true;
  String status = '正在搜索';
  String? error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(start());
    });
  }

  Future<void> start() async {
    try {
      if (widget.resume case final saved?) {
        final hit = HtmlBook.fromJson(
          Map<String, dynamic>.from(saved['book'] as Map),
        );
        final cached = saved['chapters'];
        if (cached is List && cached.isNotEmpty) {
          setState(() {
            selected = hit;
            inShelf = saved['shelved'] == true;
            chapters = cached
                .map(
                  (c) => SourceChapter(
                    c['name'] as String,
                    SourceHttpUri.parse(c['url'] as String),
                  ),
                )
                .toList();
            busy = false;
          });
        } else {
          await details(hit);
        }
        if (!mounted || error != null) return;
        final savedUrl = saved['chapterUrl'] as String;
        final index = savedUrl.isEmpty
            ? 0
            : chapters.indexWhere((c) => '${c.url}' == savedUrl);
        if (index < 0) throw StateError('原章节已不在目录中，进度仍保留，请选择章节');
        await read(index, saved['textOffset'] as int);
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

  Future<void> details(HtmlBook hit) async {
    setState(() {
      busy = true;
      error = null;
      status = '正在读取详情和完整目录';
    });
    try {
      final (book, items) = await pipeline.details(hit);
      final existing = await store.find(widget.source, '${book.url}');
      if (existing != null) {
        await store.updateCatalog(widget.source, book, items);
      }
      if (mounted) {
        setState(() {
          selected = book;
          inShelf = existing?['shelved'] == true;
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
      await store.addBook(widget.source, book, items);
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
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OnlineReaderPage(
          pipeline: pipeline,
          book: selected!,
          chapters: chapters,
          store: store,
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
