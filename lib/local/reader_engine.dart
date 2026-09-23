import 'package:fjs/fjs.dart';

import 'text_engine.dart';

/// One sparse line-start anchor: the byte offset, the code-unit offset and the
/// line index of the same position. These are `text_index`'s rows
/// (`SpaceStore.TextIndexAnchor` is the same record type).
typedef ReaderAnchor = ({int byteOffset, int codeUnitOffset, int lineIndex});

/// One chapter boundary the TOC rules found.
class ReaderChapter {
  const ReaderChapter({
    required this.title,
    required this.codeUnitOffset,
    required this.lineIndex,
  });

  final String title;
  final int codeUnitOffset;
  final int lineIndex;
}

/// One bounded read: the text, the code-unit offset it starts at, the line it
/// starts in, and whether it ends at the end of the file.
///
/// [text] is at most the window the caller asked for — never a document (D4).
class ReaderWindow {
  const ReaderWindow({
    required this.text,
    required this.textOffset,
    required this.lineIndex,
    required this.atEnd,
  });

  final String text;
  final int textOffset;
  final int lineIndex;
  final bool atEnd;
}

/// One pass over a local file, as the reader needs it: the encoding windows are
/// read with, the length in code units progress is written against, the sparse
/// line-start anchors, and the chapter boundaries.
class ReaderIndex {
  const ReaderIndex({
    required this.encoding,
    required this.codeUnitLength,
    required this.anchors,
    this.chapters = const <ReaderChapter>[],
    this.ignoredRules = const <String>[],
  });

  final String encoding;
  final int codeUnitLength;
  final List<ReaderAnchor> anchors;
  final List<ReaderChapter> chapters;

  /// Rules the index pass could not compile; the frozen reader opens the book
  /// without them, and so does this one.
  final List<String> ignoredRules;
}

/// The engine operations the reader, its paging and its restore tiers are
/// written against.
///
/// The seam exists so a widget test can drive the page with a fake: this test
/// binding never settles `flutter_rust_bridge`'s pending work, so a widget test
/// cannot load the native library. [NativeReaderEngine] is the one real
/// implementation, and only a plain test or a `tool/` harness measures it.
abstract interface class ReaderEngine {
  /// Indexes a local file in one streaming pass.
  Future<ReaderIndex> index(String path);

  /// Reads at most [maxCodeUnits] starting exactly at [textOffset], seeking to
  /// [anchor] first. Pass the nearest stored anchor, or null to start at the
  /// head of the file.
  Future<ReaderWindow> readWindow({
    required String path,
    required String encoding,
    required int textOffset,
    required int maxCodeUnits,
    ReaderAnchor? anchor,
  });

  /// Renders [text] in the script the page was asked for; null leaves it as the
  /// file has it.
  ///
  /// The target is `fjs`'s own `ConvertTarget` (`liber_text::ConvertTarget`
  /// behind the bridge), the same type `ContentProcessing.script` carries and
  /// the same engine call the Book Source host surface converts with — only the
  /// character-only direction differs (ADR 0010).
  String render(String text, ConvertTarget? script);
}

/// [TextEngine] behind [ReaderEngine].
class NativeReaderEngine implements ReaderEngine {
  const NativeReaderEngine();

  /// The frozen reader's own anchor-to-target scan limit (`TextIndexOptions`'
  /// default). The anchors are one per 32 KiB, so this is 128 strides of slack
  /// before a read reports its anchor stale instead of reading the book.
  static const int maxScanBytes = 4 * 1024 * 1024;

  @override
  Future<ReaderIndex> index(String path) async {
    final index = await TextEngine.index(path);
    return ReaderIndex(
      encoding: index.encoding,
      codeUnitLength: index.codeUnitLength,
      anchors: [
        for (final anchor in index.anchors)
          (
            byteOffset: anchor.byteOffset,
            codeUnitOffset: anchor.codeUnitOffset,
            lineIndex: anchor.lineIndex,
          ),
      ],
      chapters: [
        for (final chapter in index.chapters)
          ReaderChapter(
            title: chapter.title,
            codeUnitOffset: chapter.codeUnitOffset,
            lineIndex: chapter.lineIndex,
          ),
      ],
      ignoredRules: index.ignoredRules,
    );
  }

  @override
  Future<ReaderWindow> readWindow({
    required String path,
    required String encoding,
    required int textOffset,
    required int maxCodeUnits,
    ReaderAnchor? anchor,
  }) async {
    final window = await TextEngine.readWindow(
      path: path,
      encoding: encoding,
      anchor: anchor == null
          ? null
          : TextAnchor(
              byteOffset: anchor.byteOffset,
              codeUnitOffset: anchor.codeUnitOffset,
              lineIndex: anchor.lineIndex,
            ),
      codeUnitOffset: textOffset,
      maxCodeUnits: maxCodeUnits,
      maxScanBytes: maxScanBytes,
    );
    return ReaderWindow(
      text: window.text,
      textOffset: window.codeUnitOffset,
      lineIndex: window.lineIndex,
      atEnd: window.atEnd,
    );
  }

  @override
  String render(String text, ConvertTarget? script) => switch (script) {
    null => text,
    final target => TextEngine.convertTo(text, target),
  };
}
