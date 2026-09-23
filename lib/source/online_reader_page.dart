import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';

import '../domain/contracts.dart' show SourceCancellation;
import '../local/reader_offset_map.dart' show ReaderOffsetMap;
import '../local/text_engine.dart' show TextEngine;
import '../l10n/app_localizations.dart';
import '../settings/reader_script.dart';
import '../settings/reader_script_page.dart';
import '../store/shelf.dart';
import 'book_source_pipeline.dart';
import 'chapter_list_tile.dart';
import 'content_processing.dart';
import 'js_source_runtime.dart' show SourceHostMessage;
import 'source_notice.dart';
import 'source_tls_confirmation.dart';

/// The reader's reading column: the body's own text style, the widest column it
/// is set in, and the padding around it. The image shapes below are expressed
/// in this column's terms.
const TextStyle _bodyTextStyle = TextStyle(fontSize: 20, height: 1.8);
const double _columnMaxWidth = 760;
const EdgeInsets _contentPadding = EdgeInsets.fromLTRB(24, 8, 24, 40);

/// One row of the reader's flow: one line of the chapter body, in as many pieces
/// as the chapter's content images cut it into.
///
/// The frozen layout splits the content string at every `<img …>` element and
/// lays the text before it out, draws the image, then continues with the text
/// after it (`ChapterProvider.kt:229-278`, `TextChapterLayout.kt:255-315`). A row
/// is that split in this reader's own terms: one line, one row, with the images
/// that stood in it in their own place.
class _ReaderRow {
  const _ReaderRow(this.offset, this.pieces);

  /// The offset in the chapter body this line starts at — the value the
  /// progress record stores for it, exactly as it did before images existed.
  final int offset;

  /// The line's content in body order: a [String] is text to draw, a
  /// [SourceChapterImage] is one of the chapter's images, drawn where its
  /// element stood.
  final List<Object> pieces;
}

/// The rows one chapter body reads as, with the images it carries placed in
/// them.
///
/// [images] are the pipeline's own extraction, translated into [body]'s offsets
/// (`_render`); an image whose `<img …>` element an edit script rewrote has no
/// place in this text any more and is left out.
List<_ReaderRow> _readerRows(String body, List<SourceChapterImage> images) {
  final rows = <_ReaderRow>[];
  var lineStart = 0;
  var next = 0;
  for (final line in body.split('\n')) {
    final lineEnd = lineStart + line.length;
    final pieces = <Object>[];
    var at = lineStart;
    while (next < images.length && images[next].offset < lineEnd) {
      final image = images[next++];
      final start = image.offset;
      // The frozen pattern's `[^>]*` can match a line break, so an element can
      // reach over one; this reader's rows cannot, and the element is cut at the
      // line it starts in (recorded as a gap rather than guessed at).
      final end = math.min(start + image.length, lineEnd);
      if (start > at) pieces.add(body.substring(at, start));
      pieces.add(image);
      at = end;
    }
    if (at < lineEnd) pieces.add(body.substring(at, lineEnd));
    rows.add(_ReaderRow(lineStart, pieces));
    lineStart = lineEnd + 1;
  }
  return rows;
}

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
    this.convert,
  });
  final BookSourcePipeline pipeline;
  final HtmlBook book;

  /// The space's book row this reader reports progress for.
  final String bookId;
  final List<SourceChapter> chapters;
  final ShelfService service;
  final int chapterIndex, textOffset;

  /// The conversion `ContentProcessing` runs, or null for the engine's own
  /// (`TextEngine.convertTo`). A widget test injects a pure-Dart double, because
  /// its binding cannot load the native library — the same seam reason
  /// `ContentProcessing.scriptRuntime` exists.
  final String Function(String text, ConvertTarget target)? convert;
  @override
  State<OnlineReaderPage> createState() => _OnlineReaderPageState();
}

class _OnlineReaderPageState extends State<OnlineReaderPage> {
  final scroll = ScrollController();

  /// The scroll view's own box: the reader measures what is on screen with it
  /// (`track`) and passes its constraints to the image shapes.
  final viewportKey = GlobalKey();
  final _processingCancellation = SourceCancellation();

  /// The chapter's rows: one per line of the body it displays, each carrying the
  /// content images that stood in that line.
  List<_ReaderRow> rows = [];
  List<GlobalKey> keys = [];
  int index = 0, offset = 0;
  bool busy = true, tracking = false;
  String? error;

  /// The image style this source's content rule asks for
  /// (`ruleContent.imageStyle`, the frozen `Book.getImageStyle()`).
  late final SourceImageStyle imageStyle = sourceImageStyle(
    widget.pipeline.source,
  );

  /// The content images this reader has already fetched, by their own address:
  /// a settings change re-renders the chapter and reuses them, and a chapter
  /// change drops them. The frozen keeps downloaded images on disk; this reader
  /// keeps them for as long as the page is open.
  final _images = <String, Future<Uint8List>>{};

  /// The URL a relative image address resolves against: the chapter's own URL,
  /// which is what the frozen download path resolves against
  /// (`BookHelp.flowImages`).
  Uri? _chapterUrl;

  /// The user's replace rules for this book, applied to the title and the body
  /// the way the frozen reader applies them. Null while the space is read;
  /// a book opens with no rules until then.
  ContentProcessing? processing;

  /// The script the reader resolved on open (`lib/settings/reader_script.dart`),
  /// or null for the source's own characters.
  ConvertTarget? script;

  /// The last fetched chapter as the source returned it: a settings change
  /// re-renders from here instead of fetching the chapter again.
  String sourceTitle = '';
  String sourceBody = '';

  /// The content images the last fetched chapter carries, keyed to
  /// [sourceBody]'s own offsets — the pipeline's extraction, as it returned it.
  List<SourceChapterImage> sourceImages = const [];

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
      final target = await ReaderScriptSetting.resolve(
        widget.service.store,
        bookId: widget.bookId,
      );
      script = target;
      final rules = await widget.service.store.replaceRules();
      built = ContentProcessing(
        rules: ReplaceRuleSet.forBook(
          rules,
          bookName: widget.book.title,
          bookOrigin: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
        ),
        bookName: widget.book.title,
        script: target,
        convert: widget.convert ?? TextEngine.convertTo,
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
      if (mounted) {
        setState(
          () => error = AppLocalizations.of(context).replaceRulesFailed('$e'),
        );
      }
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
      if (mounted) {
        setState(
          () => error = AppLocalizations.of(context).saveProgressFailed('$e'),
        );
      }
    }
  }

  void track() {
    if (!tracking || busy || !mounted) return;
    final box = viewportKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final top = box.localToGlobal(Offset.zero).dy;
    for (var i = 0; i < keys.length; i++) {
      final paragraph =
          keys[i].currentContext?.findRenderObject() as RenderBox?;
      if (paragraph != null &&
          paragraph.localToGlobal(Offset.zero).dy + paragraph.size.height >
              top + 1) {
        if (offset != rows[i].offset) {
          offset = rows[i].offset;
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
      // The frozen content stage's next-chapter lookup (`BookContent.kt:49-53`):
      // the chapter after this one, falling back to the chapter at index 0 — the
      // frozen `getChapter(bookUrl, index + 1)?.url ?: getChapter(bookUrl, 0)?.url`,
      // whose index-0 fallback is its own quirk and is reproduced as it stands.
      // The content stage stops its page walk before a page equal to that URL
      // (`BookContent.kt:85-88`), which is how a `nextContentUrl` rule that also
      // matches the next chapter's link does not continue into that chapter.
      final nextChapterUrl = next + 1 < widget.chapters.length
          ? '${widget.chapters[next + 1].url}'
          : '${widget.chapters.first.url}';
      final result = await withTlsExceptionConfirmation(
        context: context,
        hostState: widget.service.hostState,
        sourceRef: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
        sourceName: '${widget.pipeline.source['bookSourceName'] ?? ''}',
        run: () => widget.pipeline.chapter(
          widget.chapters[next],
          book: widget.book,
          nextChapterUrl: nextChapterUrl,
        ),
      );
      if (!mounted) return;
      sourceTitle = result.title ?? widget.chapters[next].name;
      sourceBody = result.text;
      sourceImages = result.images;
      _chapterUrl = widget.chapters[next].url;
      _images.clear();
      await _render(next, resume);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = AppLocalizations.of(context).chapterLoadFailed('$e');
        });
      }
    }
  }

  /// Renders the chapter [sourceBody]/[sourceTitle] already hold the way the
  /// frozen reader does before the text reaches the screen: the chapter's
  /// display title (titles) and the body (content rules) — the title is what
  /// `ReadBook.kt:694` computes, the body is what
  /// `ContentProcessor.getContent(..., includeTitle = false)` returns.
  ///
  /// Both the fetch and a settings change come through here, so re-rendering in
  /// another script needs no second fetch of the chapter.
  Future<void> _render(int next, int resume) async {
    final current = processing;
    final title = current == null
        ? sourceTitle
        : await current.displayTitle(sourceTitle);
    final ProcessedContent? processed = current == null
        ? null
        // The one text entry returns the text and the run's edit script; the
        // online reader consumes the text alone — it pages the chapter it just
        // read, and its stored position is the source's own offset.
        : await current.content(sourceBody, chapterTitle: sourceTitle);
    final body = processed?.text ?? sourceBody;
    if (!mounted) return;
    // The reader's rows come from the processed body, and the images the
    // pipeline extracted are keyed to the text it returned, so their offsets go
    // through the same edit script the local reader translates positions with
    // (ADR 0012: one entry, one meaning for the script).
    final built = _readerRows(body, _placedImages(processed));
    final anchor = resume.clamp(0, body.length);
    final target = built.lastIndexWhere((row) => row.offset <= anchor);
    setState(() {
      index = next;
      chapterTitle = title;
      rows = built;
      keys = List.generate(built.length, (_) => GlobalKey());
      offset = built[target < 0 ? 0 : target].offset;
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
  }

  /// The chapter's images as the body this reader displays carries them.
  ///
  /// [processed] is `ContentProcessing.content`'s run: without one the body is
  /// the pipeline's own text and the offsets are already in it. With one, an
  /// image's element is located in the processed text through the map built from
  /// the run's edit script; an element a replace rule rewrote or removed — or one
  /// a conversion re-wrote the line under — has no text of its own left, and the
  /// image is left out rather than drawn where its markup no longer is.
  List<SourceChapterImage> _placedImages(ProcessedContent? processed) {
    if (sourceImages.isEmpty) return const <SourceChapterImage>[];
    if (processed == null) return sourceImages;
    final map = ReaderOffsetMap.fromEdits(processed.edits, rawBase: 0);
    final placed = <SourceChapterImage>[];
    for (final image in sourceImages) {
      final start = map.imageOf(image.offset);
      final end = map.imageOf(image.offset + image.length);
      if (start == null || end == null || end <= start) continue;
      placed.add(
        SourceChapterImage(src: image.src, offset: start, length: end - start),
      );
    }
    return placed;
  }

  /// One content image, in the shape its source's `imageStyle` asks for.
  ///
  /// The frozen shapes scale an image into a measured page
  /// (`ChapterProvider.setTypeImage`, `TextChapterLayout.setTypeImage`); this
  /// reader scrolls instead of measuring pages, so each shape is a box of this
  /// reader's own terms:
  ///
  /// - `DEFAULT` keeps the image's own size, scaled down to the column and to
  ///   one viewport, centred — the frozen natural size, centred;
  /// - `FULL` fills the column's width and keeps the ratio, taller than the
  ///   screen included — the frozen `visibleWidth` rule;
  /// - `SINGLE` is drawn in a viewport-high box with `BoxFit.contain`, so one
  ///   image is on screen at a time — the frozen forces a page break before and
  ///   after the image and centres it on a measured page, which this reader has
  ///   no pages to reproduce;
  /// - `TEXT` is one character cell inside its line — the frozen draws the image
  ///   in the column of the placeholder character it replaced the element with.
  Widget _image(SourceChapterImage image, BoxConstraints viewport) {
    final column =
        (viewport.maxWidth < _columnMaxWidth
            ? viewport.maxWidth
            : _columnMaxWidth) -
        _contentPadding.horizontal;
    final cell = _bodyTextStyle.fontSize!;
    if (image.src.trim().isEmpty) return _imageNotice(l10n.imageEmptyAddress);
    return switch (imageStyle) {
      SourceImageStyle.full => SizedBox(
        width: column,
        child: _imageBytes(image, fit: BoxFit.fitWidth),
      ),
      SourceImageStyle.single => SizedBox(
        width: column,
        height: viewport.maxHeight,
        child: _imageBytes(image, fit: BoxFit.contain),
      ),
      SourceImageStyle.text => SizedBox(
        width: cell,
        height: cell * _bodyTextStyle.height!,
        child: _imageBytes(image, fit: BoxFit.contain),
      ),
      SourceImageStyle.natural => Align(
        alignment: Alignment.center,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: column,
            maxHeight: viewport.maxHeight,
          ),
          child: _imageBytes(image, fit: BoxFit.scaleDown),
        ),
      ),
    };
  }

  /// One image's bytes, fetched through the source's own session on first use
  /// and kept for this chapter.
  ///
  /// The request runs under the page's own TLS confirmation, the way the chapter
  /// fetch does (`load`): ADR 0011 §5's exception is per source and host, and an
  /// image can sit on a host no stage has asked for yet, so without this an image
  /// behind a certificate the user has not yet accepted could only ever show the
  /// placeholder. A refused confirmation, or a request that still fails, is that
  /// placeholder: the frozen layout draws its own error bitmap and the chapter
  /// keeps reading.
  Future<Uint8List> _loadImage(SourceChapterImage image) => _images.putIfAbsent(
    image.src,
    () => withTlsExceptionConfirmation(
      context: context,
      hostState: widget.service.hostState,
      sourceRef: '${widget.pipeline.source['bookSourceUrl'] ?? ''}',
      sourceName: '${widget.pipeline.source['bookSourceName'] ?? ''}',
      run: () => widget.pipeline.chapterImage(image.src, base: _chapterUrl),
    ),
  );

  /// One image's bytes as the shape draws them.
  Widget _imageBytes(SourceChapterImage image, {required BoxFit fit}) =>
      FutureBuilder<Uint8List>(
        future: _loadImage(image),
        builder: (context, snapshot) {
          if (snapshot.hasError) return _imageNotice(l10n.imageLoadFailed);
          final bytes = snapshot.data;
          if (bytes == null) return _imageNotice(l10n.imageLoading);
          return Image.memory(
            bytes,
            fit: fit,
            alignment: Alignment.center,
            // A response that is not an image at all (a login page, an empty
            // body) is a failed image, not a failed chapter.
            errorBuilder: (_, _, _) => _imageNotice(l10n.imageLoadFailed),
          );
        },
      );

  Widget _imageNotice(String message) => Center(
    child: Text(
      message,
      style: TextStyle(
        fontSize: 12,
        color: Theme.of(context).colorScheme.outline,
      ),
    ),
  );

  /// One row of the chapter: its text, with the images that stood in it drawn at
  /// the place their element did.
  Widget _row(_ReaderRow row, BoxConstraints viewport) {
    // The rows that carry no image are the text they always were, one `Text`
    // each.
    if (row.pieces.length == 1 && row.pieces.first is String) {
      return Text(row.pieces.first as String, style: _bodyTextStyle);
    }
    if (imageStyle == SourceImageStyle.text) {
      // The `TEXT` style keeps the image inside the line, where the frozen
      // draws the placeholder character it replaced the element with.
      return Text.rich(
        TextSpan(
          style: _bodyTextStyle,
          children: [
            for (final piece in row.pieces)
              if (piece is SourceChapterImage)
                WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: _image(piece, viewport),
                )
              else
                TextSpan(text: piece as String),
          ],
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final piece in row.pieces)
          if (piece is SourceChapterImage)
            _image(piece, viewport)
          // A segment an image cut out of the line is drawn only when it has
          // text: the frozen lays out none for a blank one
          // (`if (text.isNotBlank())`, `TextChapterLayout.kt:258`).
          else if ((piece as String).trim().isNotEmpty)
            Text(piece, style: _bodyTextStyle),
      ],
    );
  }

  /// Opens the reader's conversion screen (#27) for this book, then re-resolves
  /// and re-renders the chapter it is already showing. Nothing is fetched again
  /// and the book is not reopened: only the characters change.
  ///
  /// A conversion that fails is reported on the same error line a failed chapter
  /// fetch uses; the choice itself is already stored, so the next render (another
  /// chapter, a reload) uses it. Without the `try` the failure would leave the
  /// reader with the old text and no notice at all.
  Future<void> openScriptSettings() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ReaderScriptPage(
          store: widget.service.store,
          bookId: widget.bookId,
          bookTitle: widget.book.title,
        ),
      ),
    );
    if (!mounted) return;
    final target = await ReaderScriptSetting.resolve(
      widget.service.store,
      bookId: widget.bookId,
    );
    if (!mounted || target == script) return;
    script = target;
    processing?.script = target;
    try {
      await _render(index, offset);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = '中文转换失败：$e';
        });
      }
    }
  }

  Future<void> chooseChapter() async {
    final l10n = AppLocalizations.of(context);
    final choice = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.sizeOf(context).height * .8,
        child: Column(
          children: [
            ListTile(
              title: Text(l10n.tableOfContentsCount(widget.chapters.length)),
              trailing: IconButton(
                tooltip: l10n.closeTableOfContents,
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: widget.chapters.length,
                itemBuilder: (_, i) => ChapterListTile(
                  chapter: widget.chapters[i],
                  // The frozen list converts the title when the converter is on
                  // and applies the title rules only when
                  // `AppConfig.tocUiUseReplace` is on (`ChapterListAdapter.kt:78`,
                  // default false), which is what [ContentProcessing.listTitle]
                  // does.
                  title: processing?.listTitle(widget.chapters[i].name),
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title),
        actions: [
          IconButton(
            onPressed: busy ? null : openScriptSettings,
            tooltip: l10n.readerScriptTitle,
            icon: const Icon(Icons.translate),
          ),
          TextButton.icon(
            onPressed: busy ? null : chooseChapter,
            icon: const Icon(Icons.list),
            label: Text(l10n.tableOfContentsAction),
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
                // The viewport's own box is what the `SINGLE` shape and the image
                // widths are expressed in; the reader scrolls it instead of
                // measuring pages.
                : LayoutBuilder(
                    builder: (context, viewport) => SingleChildScrollView(
                      key: viewportKey,
                      controller: scroll,
                      child: Center(
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(
                            maxWidth: _columnMaxWidth,
                          ),
                          child: Padding(
                            padding: _contentPadding,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                for (var i = 0; i < rows.length; i++)
                                  Padding(
                                    key: keys[i],
                                    padding: const EdgeInsets.only(bottom: 12),
                                    child: _row(rows[i], viewport),
                                  ),
                              ],
                            ),
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
                    child: Text(l10n.previousChapter),
                  ),
                  TextButton(
                    onPressed: busy ? null : () => load(index, offset),
                    child: Text(l10n.reloadChapter),
                  ),
                  FilledButton(
                    onPressed: busy || index + 1 == widget.chapters.length
                        ? null
                        : () => load(index + 1, 0),
                    child: Text(l10n.nextChapter),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
