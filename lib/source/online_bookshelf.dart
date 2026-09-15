import 'dart:async';

import 'package:flutter/material.dart';

import 'html_source_browser.dart';
import 'book_source_service.dart';
import 'html_source_pipeline.dart';
import 'http_source_transport.dart';
import 'online_reading_store.dart';

/// Inline online section of the existing bookshelf; the parent owns scrolling.
class OnlineBookshelf extends StatefulWidget {
  const OnlineBookshelf({
    super.key,
    this.revision = 0,
    this.store,
    this.transport,
  });
  final BookSourceTransport? transport;
  final int revision;
  final OnlineReadingStore? store;
  @override
  State<OnlineBookshelf> createState() => _OnlineBookshelfState();
}

class _OnlineBookshelfState extends State<OnlineBookshelf> {
  late final store = widget.store ?? OnlineReadingStore();
  List<Map<String, dynamic>> books = [];
  bool loading = true;
  String? busyId, error;

  @override
  void initState() {
    super.initState();
    unawaited(reload());
  }

  @override
  void didUpdateWidget(OnlineBookshelf oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.revision != widget.revision) unawaited(reload());
  }

  Future<void> reload() async {
    try {
      final saved = await store.loadBooks();
      if (mounted) {
        setState(() {
          books = saved;
          loading = false;
          error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          loading = false;
          error = '读取在线书架失败：$e';
        });
      }
    }
  }

  Future<void> open(Map<String, dynamic> entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HtmlSourceBrowser(
          source: Map<String, dynamic>.from(entry['source'] as Map),
          keyword: '',
          resume: entry,
          store: store,
          pipeline: widget.transport == null
              ? null
              : HtmlSourcePipeline(
                  Map<String, dynamic>.from(entry['source'] as Map),
                  widget.transport!,
                ),
        ),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> action(String action, Map<String, dynamic> entry) async {
    final id = OnlineReadingStore.recordKey(entry);
    setState(() {
      busyId = id;
      error = null;
    });
    try {
      if (action == 'remove') {
        await store.removeBook(entry);
      } else {
        final source = Map<String, dynamic>.from(entry['source'] as Map);
        final pipeline = HtmlSourcePipeline(
          source,
          widget.transport ?? HttpSourceTransport(),
        );
        try {
          final (book, chapters) = await pipeline.details(
            HtmlBook.fromJson(Map<String, dynamic>.from(entry['book'] as Map)),
          );
          await store.updateCatalog(source, book, chapters);
        } finally {
          pipeline.cancel();
        }
      }
      if (mounted) await reload();
    } catch (e) {
      if (mounted) setState(() => error = '操作失败，书架和进度仍保留：$e');
    } finally {
      if (mounted) setState(() => busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text('在线书架', style: Theme.of(context).textTheme.titleLarge),
      if (loading) const LinearProgressIndicator(),
      if (error != null)
        Row(
          children: [
            Expanded(child: Text(error!)),
            TextButton(onPressed: reload, child: const Text('重试')),
          ],
        ),
      if (!loading && books.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: Text('从书源搜索结果或详情页加入书架。'),
        ),
      for (final entry in books)
        ListTile(
          title: Text('${(entry['book'] as Map)['title']}'),
          subtitle: Text(
            entry['chapterUrl'] == ''
                ? '尚未阅读'
                : '${entry['chapterName'] ?? '继续上次章节'}',
          ),
          leading: const Icon(Icons.menu_book_outlined),
          enabled: busyId == null,
          onTap: () => open(entry),
          trailing: busyId == OnlineReadingStore.recordKey(entry)
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(),
                )
              : PopupMenuButton<String>(
                  enabled: busyId == null,
                  tooltip: '书籍操作',
                  onSelected: (value) => action(value, entry),
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: 'refresh', child: Text('更新目录')),
                    PopupMenuItem(value: 'remove', child: Text('移出书架（保留进度）')),
                  ],
                ),
        ),
      const SizedBox(height: 16),
    ],
  );
}
