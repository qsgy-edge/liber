import 'dart:async';

import 'package:flutter/material.dart';

import '../store/shelf.dart';
import 'html_source_pipeline.dart';
import 'json_source_pipeline.dart' show SourceChapter;
import 'source_tls_confirmation.dart';

class OnlineReaderPage extends StatefulWidget {
  const OnlineReaderPage({
    super.key,
    required this.pipeline,
    required this.book,
    required this.bookId,
    required this.chapters,
    required this.service,
    this.chapterIndex = 0,
    this.textOffset = 0,
  });
  final HtmlSourcePipeline pipeline;
  final HtmlBook book;

  /// The space's book row this reader reports progress for.
  final String bookId;
  final List<SourceChapter> chapters;
  final ShelfService service;
  final int chapterIndex, textOffset;
  @override
  State<OnlineReaderPage> createState() => _OnlineReaderPageState();
}

class _OnlineReaderPageState extends State<OnlineReaderPage> {
  final scroll = ScrollController();
  final viewport = GlobalKey();
  List<String> paragraphs = [];
  List<int> offsets = [];
  List<GlobalKey> keys = [];
  int index = 0, offset = 0;
  bool busy = true, tracking = false;
  String? error;

  @override
  void initState() {
    super.initState();
    index = widget.chapterIndex;
    scroll.addListener(track);
    unawaited(load(index, widget.textOffset));
  }

  Future<void> save() async {
    try {
      if (index < 0 || index >= widget.chapters.length) return;
      await widget.service.saveProgress(
        widget.bookId,
        chapterKey: '${widget.chapters[index].url}',
        chapterIndex: index,
        textOffset: offset,
      );
    } catch (e) {
      if (mounted) setState(() => error = '进度保存失败：$e');
    }
  }

  void track() {
    if (!tracking || busy || !mounted) return;
    final box = viewport.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final top = box.localToGlobal(Offset.zero).dy;
    for (var i = 0; i < keys.length; i++) {
      final paragraph =
          keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (paragraph != null &&
          paragraph.localToGlobal(Offset.zero).dy + paragraph.size.height >
              top + 1) {
        if (offset != offsets[i]) {
          offset = offsets[i];
          unawaited(save());
        }
        break;
      }
    }
  }

  Future<void> load(int next, int resume) async {
    if (next < 0 || next >= widget.chapters.length) return;
    tracking = false;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final result = await withTlsExceptionConfirmation(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
        sourceName: '${widget.pipeline.source['bookSourceName'] ?? ''}',
        run: () => widget.pipeline.chapter(widget.chapters[next]),
      );
      if (!mounted) return;
      final lines = result.text.split('\n');
      var cursor = 0;
      final starts = <int>[];
      for (final line in lines) {
        starts.add(cursor);
        cursor += line.length + 1;
      }
      final anchor = resume.clamp(0, result.text.length);
      final target = starts.lastIndexWhere((start) => start <= anchor);
      setState(() {
        index = next;
        paragraphs = lines;
        offsets = starts;
        keys = List.generate(lines.length, (_) => GlobalKey());
        offset = starts[target < 0 ? 0 : target];
        busy = false;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        final context = keys[target < 0 ? 0 : target].currentContext;
        if (context != null) {
          await Scrollable.ensureVisible(context, alignment: 0);
        }
        if (!mounted) return;
        tracking = true;
        await save();
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '章节读取失败：$e';
        });
      }
    }
  }

  Future<void> chooseChapter() async {
    final choice = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          children: [
            ListTile(
              title: Text('目录 · ${widget.chapters.length} 章'),
              trailing: IconButton(
                tooltip: '关闭目录',
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.chapters.length,
                itemBuilder: (_, i) => ListTile(
                  selected: i == index,
                  title: Text(widget.chapters[i].name),
                  onTap: () => Navigator.pop(context, i),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    if (choice != null && mounted) await load(choice, 0);
  }

  @override
  void dispose() {
    // The reader owns the pipeline it fetches through: it is the analysis whose
    // cancellation token this page must end when it leaves, and the page that
    // handed the pipeline over has already replaced its own.
    widget.pipeline.cancel();
    scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.book.title),
      actions: [
        TextButton.icon(
          onPressed: busy ? null : chooseChapter,
          icon: const Icon(Icons.list),
          label: const Text('目录'),
        ),
      ],
    ),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Text(
            // The chapter name is blank while a chapter loads: the previous
            // name would contradict the incoming chapter, and the target name
            // would read as if it were already displayed. The line keeps its
            // height so the content area does not jump.
            busy ? '' : widget.chapters[index].name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (error != null)
          Padding(padding: const EdgeInsets.all(12), child: Text(error!)),
        Expanded(
          child: busy
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                  key: viewport,
                  controller: scroll,
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 760),
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 8, 24, 40),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (var i = 0; i < paragraphs.length; i++)
                              Padding(
                                key: keys[i],
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  paragraphs[i],
                                  style: const TextStyle(
                                    fontSize: 20,
                                    height: 1.8,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 16,
              children: [
                OutlinedButton(
                  onPressed: busy || index == 0
                      ? null
                      : () => load(index - 1, 0),
                  child: const Text('上一章'),
                ),
                TextButton(
                  onPressed: busy ? null : () => load(index, offset),
                  child: const Text('重新加载'),
                ),
                FilledButton(
                  onPressed: busy || index + 1 == widget.chapters.length
                      ? null
                      : () => load(index + 1, 0),
                  child: const Text('下一章'),
                ),
              ],
            ),
          ),
        ),
      ],
    ),
  );
}
