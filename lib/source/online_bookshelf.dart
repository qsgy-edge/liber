import 'dart:async';

import 'package:flutter/material.dart';

import '../store/shelf.dart';
import 'book_source_service.dart';
import 'html_source_browser.dart';
import 'html_source_pipeline.dart';
import 'http_source_transport.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// Inline online section of the existing bookshelf; the parent owns scrolling.
///
/// The list comes from the space's store: a book is on the shelf because
/// `books.shelved` says so, and removing one keeps its chapters and its
/// position.
class OnlineBookshelf extends StatefulWidget {
  const OnlineBookshelf({
    super.key,
    required this.service,
    this.revision = 0,
    this.transport,
  });
  final ShelfService service;
  final BookSourceTransport? transport;

  /// Bumped by the parent when something outside this widget changed the shelf.
  final int revision;

  @override
  State<OnlineBookshelf> createState() => _OnlineBookshelfState();
}

class _OnlineBookshelfState extends State<OnlineBookshelf> {
  List<ShelfEntry> books = const <ShelfEntry>[];
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
      final saved = await widget.service.onlineShelf();
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

  Future<void> open(ShelfEntry entry) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HtmlSourceBrowser(
          source: entry.sourceJson,
          keyword: '',
          resume: entry,
          service: widget.service,
          pipeline: widget.transport == null
              ? null
              : HtmlSourcePipeline(
                  entry.sourceJson,
                  widget.transport!,
                  hostState: widget.service.hostState,
                  androidId: widget.service.androidId,
                  onHostMessage: _showHostNotice,
                ),
        ),
      ),
    );
    if (mounted) await reload();
  }

  /// Shows a source's rate-limited `toast`/`longToast` notice on this widget's
  /// messenger; a disposed widget drops it silently.
  void _showHostNotice(SourceHostMessage message) {
    if (!mounted) return;
    showSourceNotice(context, message);
  }

  Future<void> action(String action, ShelfEntry entry) async {
    setState(() {
      busyId = entry.id;
      error = null;
    });
    try {
      if (action == 'remove') {
        await widget.service.remove(entry.id);
      } else {
        final source = entry.sourceJson;
        final pipeline = HtmlSourcePipeline(
          source,
          widget.transport ?? HttpSourceTransport(),
          hostState: widget.service.hostState,
          androidId: widget.service.androidId,
          onHostMessage: _showHostNotice,
        );
        try {
          final (book, chapters) = await withTlsExceptionConfirmation(
            context: context,
            hostState: widget.service.hostState,
            sourceRef: entry.sourceRef,
            sourceName: '${source['bookSourceName'] ?? ''}',
            run: () => pipeline.details(entry.htmlBook),
          );
          await widget.service.updateCatalog(entry.sourceRef, book, chapters);
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
          title: Text(entry.title),
          subtitle: Text(
            entry.chapterKey.isEmpty ? '尚未阅读' : entry.chapterName ?? '继续上次章节',
          ),
          leading: const Icon(Icons.menu_book_outlined),
          enabled: busyId == null,
          onTap: () => open(entry),
          trailing: busyId == entry.id
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
