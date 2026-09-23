import 'dart:async';

import 'package:flutter/material.dart';

import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'book_source_service.dart';
import 'html_source_browser.dart';
import 'http_source_transport.dart';
import 'java_regex.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// Inline online section of the existing bookshelf; the parent owns scrolling.
///
/// The list comes from the space's store: a book is on the shelf because
/// `books.shelved` says so, and removing one keeps its chapters and its
/// position. A book whose source was deleted (#53) stays in the list marked as
/// unopenable — its row, its chapters and its position are what the shelf has to
/// keep — and only its removal is offered for it.
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
  final _bookUrl = TextEditingController();
  bool matchingUrl = false;
  String? urlResult;

  @override
  void dispose() {
    _bookUrl.dispose();
    super.dispose();
  }

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

  /// A pipeline for one analysis of [source], built the way the source's rules
  /// need: a JSON source gets the JSON adapter (ticket #29).
  BookSourcePipeline _openPipeline(
    Map<String, dynamic> source,
    BookSourceTransport transport,
  ) => openBookSourcePipeline(
    source,
    transport,
    hostState: widget.service.hostState,
    androidId: widget.service.androidId,
    onHostMessage: _showHostNotice,
  );

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
              : _openPipeline(entry.sourceJson, widget.transport!),
        ),
      ),
    );
    if (mounted) await reload();
  }

  Future<void> openUrl() async {
    if (matchingUrl) return;
    final text = _bookUrl.text.trim();
    final url = Uri.tryParse(text);
    if (url == null ||
        !url.hasAuthority ||
        (url.scheme != 'http' && url.scheme != 'https')) {
      setState(() => urlResult = '请输入有效的 http(s) 书籍链接');
      return;
    }
    setState(() {
      matchingUrl = true;
      urlResult = null;
    });
    try {
      final matches = <ImportedBookSource>[];
      final failures = <String>[];
      for (final source in await widget.service.sources()) {
        final pattern = '${source.data['bookUrlPattern'] ?? ''}';
        if (pattern.isEmpty) continue;
        try {
          if (javaMatchesWhole(pattern, text, label: 'bookUrlPattern')) {
            matches.add(source);
          }
        } on UnsupportedError catch (e) {
          failures.add('${source.data['bookSourceName'] ?? source.id}：$e');
        }
      }
      if (!mounted) return;
      setState(() {
        matchingUrl = false;
        urlResult = [if (matches.isEmpty) '没有匹配此链接的书源', ...failures].join('\n');
      });
      if (matches.isEmpty) return;
      final ImportedBookSource? chosen;
      if (matches.length == 1) {
        chosen = matches.single;
      } else {
        chosen = await showDialog<ImportedBookSource>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('选择书源'),
            content: SizedBox(
              width: (MediaQuery.sizeOf(dialogContext).width - 80).clamp(
                0.0,
                360.0,
              ),
              height: (80.0 * matches.length +
                      (failures.isEmpty ? 0.0 : 120.0))
                  .clamp(0.0, MediaQuery.sizeOf(dialogContext).height * 0.6),
              child: ListView(
                children: [
                  for (final source in matches)
                    ListTile(
                      title: Text(
                        '${source.data['bookSourceName'] ?? source.id}',
                      ),
                      subtitle: Text(source.id),
                      onTap: () => Navigator.pop(dialogContext, source),
                    ),
                  if (failures.isNotEmpty) Text(failures.join('\n')),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消'),
              ),
            ],
          ),
        );
      }
      if (!mounted || chosen == null) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => HtmlSourceBrowser(
            source: chosen!.data,
            keyword: '',
            directBook: HtmlBook(url: url, title: ''),
            service: widget.service,
            transport: widget.transport,
          ),
        ),
      );
      if (mounted) await reload();
    } catch (e) {
      if (mounted) setState(() => urlResult = '打开链接失败：$e');
    } finally {
      if (mounted) setState(() => matchingUrl = false);
    }
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
        final pipeline = _openPipeline(
          source,
          widget.transport ?? HttpSourceTransport(),
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
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _bookUrl,
                decoration: const InputDecoration(
                  labelText: '书籍链接',
                  prefixIcon: Icon(Icons.link),
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
                onSubmitted: (_) => openUrl(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton.filled(
              tooltip: '打开书籍链接',
              onPressed: matchingUrl ? null : openUrl,
              icon: matchingUrl
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.arrow_forward),
            ),
          ],
        ),
      ),
      if (urlResult != null && urlResult!.isNotEmpty)
        Text(urlResult!, style: Theme.of(context).textTheme.bodySmall),
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
            entry.sourceMissing
                ? '书源已删除 · 保留书目与进度'
                : entry.chapterKey.isEmpty
                ? '尚未阅读'
                : entry.chapterName ?? '继续上次章节',
          ),
          leading: Icon(
            entry.sourceMissing ? Icons.link_off : Icons.menu_book_outlined,
          ),
          enabled: busyId == null,
          // Nothing can open a book whose source is gone: the only action that
          // makes sense for it is taking it off the shelf.
          onTap: entry.sourceMissing ? null : () => open(entry),
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
                  itemBuilder: (_) => [
                    if (!entry.sourceMissing)
                      const PopupMenuItem(
                        value: 'refresh',
                        child: Text('更新目录'),
                      ),
                    const PopupMenuItem(
                      value: 'remove',
                      child: Text('移出书架（保留进度）'),
                    ),
                  ],
                ),
        ),
      const SizedBox(height: 16),
    ],
  );
}
