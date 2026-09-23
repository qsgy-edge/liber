import 'dart:async';

import 'package:flutter/material.dart';

import '../domain/contracts.dart' show SourceCancellation;
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'chapter_list_tile.dart';
import 'content_processing.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'source_notice.dart';
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
  final BookSourcePipeline pipeline;
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
  final _processingCancellation = SourceCancellation();
  List<String> paragraphs = [];
  List<int> offsets = [];
  List<GlobalKey> keys = [];
  int index = 0, offset = 0;
  bool busy = true, tracking = false;
  String? error;

  /// The user's replace rules for this book, applied to the title and the body
  /// the way the frozen reader applies them. Null while the space is read;
  /// a book opens with no rules until then.
  ContentProcessing? processing;

  /// The current chapter's display title, replaced by the title rules.
  String chapterTitle = '';

  @override
  void initState() {
    super.initState();
    // A chapter fetch can toast too; this page owns the pipeline while it is
    // open, so its notices belong on this page's messenger.
    widget.pipeline.onHostMessage = _showHostNotice;
    index = widget.chapterIndex;
    scroll.addListener(track);
    unawaited(_open());
  }

  /// Reads this book's replace rules once, then loads the chapter.
  ///
  /// The frozen reader keeps one `ContentProcessor` per (name, origin) and
  /// rebuilds it when the rules change; this page reads the space's ruleset on
  /// open, which is the same set for as long as the page is. `origin` is the
  /// source's own URL, which is what a rule's `scope` is matched against.
  Future<void> _open() async {
    ContentProcessing? built;
    try {
      final rules = await widget.service.store.replaceRules();
      built = ContentProcessing(
        rules: ReplaceRuleSet.forBook(
          rules,
          bookName: widget.book.title,
          bookOrigin: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
        ),
        bookName: widget.book.title,
        cancellation: _processingCancellation,
        // The frozen `Book.getUseReplaceRule()` for a text book: the per-book
        // switch, falling back to a default that is on. The settings field set
        // is not decided yet (the map's fog), so the frozen default stands.
        useReplaceRule: true,
        // The frozen `Book.getReSegment()`: the per-book switch for the
        // `ContentHelp.reSegment` stage, which defaults off (21 of the
        // operator's 1419 books have it on). The product has no per-book
        // reading-flag storage yet, so the frozen default is what a book opens
        // with; nothing here guesses a book's flag.
        useReSegment: false,
        onNotice: _showRuleNotice,
        onRuleDisabled: (rule) => widget.service.store.putReplaceRule(
          rule.copyWith(isEnabled: false).toCompanion(true),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = '替换规则读取失败：$e');
    }
    if (!mounted) return;
    processing = built;
    await load(
      widget.chapterIndex,
      widget.textOffset,
      clearError: built != null,
    );
  }

  /// Shows a skipped replace rule (a timeout, an unusable pattern, or a
  /// JavaScript failure) on the page's own notice surface.
  void _showRuleNotice(String message) {
    if (!mounted) return;
    showSourceNotice(context, SourceHostMessage('replace', message));
  }

  /// Shows a source's rate-limited `toast`/`longToast` notice on this page; a
  /// disposed page drops it silently.
  void _showHostNotice(SourceHostMessage message) {
    if (!mounted) return;
    showSourceNotice(context, message);
  }

  Future<void> save() async {
    try {
      if (index < 0 || index >= widget.chapters.length) return;
      await widget.service.saveProgress(
        widget.bookId,
        chapterKey: widget.chapters[index].progressKey,
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

  Future<void> load(int next, int resume, {bool clearError = true}) async {
    if (next < 0 || next >= widget.chapters.length) return;
    tracking = false;
    setState(() {
      busy = true;
      if (clearError) error = null;
    });
    try {
      final result = await withTlsExceptionConfirmation(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
        sourceName: '${widget.pipeline.source['bookSourceName'] ?? ''}',
        run: () =>
            widget.pipeline.chapter(widget.chapters[next], book: widget.book),
      );
      if (!mounted) return;
      // The frozen reader replaces the text before it reaches the screen: the
      // chapter's display title (titles) and the body (content rules) — the title
      // is what `ReadBook.kt:694` computes, the body is what
      // `ContentProcessor.getContent(..., includeTitle = false)` returns.
      final chapterName = widget.chapters[next].name;
      final current = processing;
      final sourceTitle = result.title ?? chapterName;
      final title = current == null
          ? sourceTitle
          : await current.displayTitle(sourceTitle);
      final body = current == null
          ? result.text
          // The one text entry returns the text and the run's edit script; the
          // online reader consumes the text alone — it pages the chapter it just
          // read, and its stored position is the source's own offset.
          : (await current.content(
              result.text,
              chapterTitle: sourceTitle,
            )).text;
      if (!mounted) return;
      final lines = body.split('\n');
      var cursor = 0;
      final starts = <int>[];
      for (final line in lines) {
        starts.add(cursor);
        cursor += line.length + 1;
      }
      final anchor = resume.clamp(0, body.length);
      final target = starts.lastIndexWhere((start) => start <= anchor);
      setState(() {
        index = next;
        chapterTitle = title;
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
                itemBuilder: (_, i) => ChapterListTile(
                  chapter: widget.chapters[i],
                  selected: i == index,
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
    _processingCancellation.cancel();
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
            busy ? '' : chapterTitle,
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
