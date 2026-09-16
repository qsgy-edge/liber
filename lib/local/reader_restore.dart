import 'dart:math' as math;

import '../store/progress.dart';
import 'reader_engine.dart';

/// One line start: where it begins in code units, and its zero-based index.
class ReaderLine {
  const ReaderLine({required this.start, required this.lineIndex});

  final int start;
  final int lineIndex;
}

/// One line start together with the window text it was found in, so a caller
/// can read the line without a second window read.
class WindowedLine {
  const WindowedLine({required this.line, required this.window});

  final ReaderLine line;
  final ReaderWindow window;

  /// The line's text as far as this window carries it: a line that began before
  /// the window contributes nothing here, because its start was found in the
  /// window that held it.
  String get text {
    final from = line.start - window.textOffset;
    if (from < 0 || from > window.text.length) return '';
    final end = window.text.indexOf('\n', from);
    return end < 0
        ? window.text.substring(from)
        : window.text.substring(from, end);
  }
}

/// The lines inside one window, in order: where each starts, its line index, and
/// its text as far as the window holds it.
///
/// A caller that reads the window at a line start gets text that starts at a
/// line start; a window read from a mid-line offset still splits the same way,
/// and the first entry is then the tail of a line whose start is elsewhere.
Iterable<({int start, int lineIndex, String text})> windowLines(
  ReaderWindow window,
) sync* {
  var start = 0;
  var lineIndex = window.lineIndex;
  while (start <= window.text.length) {
    final newline = window.text.indexOf('\n', start);
    final end = newline < 0 ? window.text.length : newline;
    yield (
      start: window.textOffset + start,
      lineIndex: lineIndex,
      text: window.text.substring(start, end),
    );
    if (newline < 0) return;
    start = newline + 1;
    lineIndex += 1;
  }
}

/// Whether what a window holds of a line confirms [anchor].
///
/// The line whose first code units the anchor names has to start with it, and
/// the window has to have shown at least as much of the line as the anchor
/// names: a prefix a window cut short cannot confirm a longer anchor.
bool anchorMatches(String linePrefix, String anchor) =>
    linePrefix.length >= anchor.length && linePrefix.startsWith(anchor);

/// The bounded line lookups the restore's line tiers and the reader's paging
/// need.
///
/// Every read seeks to the nearest stored anchor first — never to the head of
/// the file — and returns at most one window, so a lookup costs a few reads
/// whatever the file's size and nothing here materializes a document.
class ReaderLines {
  const ReaderLines({
    required this.engine,
    required this.path,
    required this.index,
    this.windowCodeUnits = 4096,
  });

  final ReaderEngine engine;
  final String path;
  final ReaderIndex index;

  /// How many code units one window holds when a caller does not say.
  final int windowCodeUnits;

  /// The nearest stored anchor at or before [textOffset]; null when the index
  /// has no anchors at all.
  ReaderAnchor? anchorBefore(int textOffset) {
    var low = 0;
    var high = index.anchors.length - 1;
    ReaderAnchor? found;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (index.anchors[middle].codeUnitOffset <= textOffset) {
        found = index.anchors[middle];
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  /// The last anchor whose line index is at or before [lineIndex].
  ReaderAnchor? anchorAtLine(int lineIndex) {
    var low = 0;
    var high = index.anchors.length - 1;
    ReaderAnchor? found;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (index.anchors[middle].lineIndex <= lineIndex) {
        found = index.anchors[middle];
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  /// One bounded window starting exactly at [textOffset].
  ///
  /// [textOffset] has to be inside the file: the last position a window can
  /// start at is `codeUnitLength - 1`, which is the caller's clamp, not this
  /// method's silent one.
  Future<ReaderWindow> read(int textOffset, {int? maxCodeUnits}) =>
      engine.readWindow(
        path: path,
        encoding: index.encoding,
        textOffset: textOffset,
        maxCodeUnits: maxCodeUnits ?? windowCodeUnits,
        anchor: anchorBefore(textOffset),
      );

  /// Line starts from [from], in order, each with the window that holds it. The
  /// walk reads one bounded window at a time and stops at the end of the file,
  /// so it never materializes more than a window.
  ///
  /// [from] must itself be a line start (an anchor, or a line this walk already
  /// returned).
  Stream<WindowedLine> linesFrom(ReaderLine from) async* {
    var line = from;
    var offset = from.start;
    while (true) {
      final window = await read(offset);
      // The walk's line belongs to this window only when its start is inside
      // it; after a window that ended inside a line, the same line comes back
      // with its start behind the window and is skipped — it was already
      // yielded where it began.
      if (line.start >= window.textOffset) {
        yield WindowedLine(line: line, window: window);
      }
      var count = 0;
      for (var unit = 0; unit < window.text.length; unit++) {
        if (window.text.codeUnitAt(unit) != 0x0a) continue;
        count += 1;
        line = ReaderLine(
          start: window.textOffset + unit + 1,
          lineIndex: window.lineIndex + count,
        );
        yield WindowedLine(line: line, window: window);
      }
      if (window.atEnd) return;
      final end = window.textOffset + window.text.length;
      if (end <= offset || end >= index.codeUnitLength) return;
      offset = end;
    }
  }

  /// The line containing [textOffset], with the window its start was found in.
  Future<WindowedLine> lineAt(int textOffset) async {
    final anchor = anchorBefore(textOffset);
    WindowedLine? found;
    await for (final line in linesFrom(
      ReaderLine(
        start: anchor?.codeUnitOffset ?? 0,
        lineIndex: anchor?.lineIndex ?? 0,
      ),
    )) {
      if (line.line.start > textOffset) break;
      found = line;
    }
    return found!;
  }

  /// The start of line [lineIndex], or null when the file has fewer lines than
  /// that.
  Future<ReaderLine?> offsetOfLine(int lineIndex) async {
    final anchor = anchorAtLine(lineIndex);
    if (anchor == null) return null;
    await for (final line in linesFrom(
      ReaderLine(start: anchor.codeUnitOffset, lineIndex: anchor.lineIndex),
    )) {
      if (line.line.lineIndex >= lineIndex) {
        return line.line.lineIndex == lineIndex ? line.line : null;
      }
    }
    return null;
  }
}

/// The tier D4's restore settled on. Each tier runs only when the previous one
/// failed, and the reader reports every tier but [exact] rather than jumping
/// silently.
enum RestoreTier { exact, relocated, searched, lineIndex, percentage }

/// Where a stored position ended up: the line to display from, the intra-line
/// offset the record keeps (D4: a line alone is not a position), and the tier
/// that put it there.
class RestoredPosition {
  const RestoredPosition({
    required this.line,
    required this.tier,
    this.offsetInLine = 0,
  });

  final ReaderLine line;
  final int offsetInLine;
  final RestoreTier tier;

  /// The absolute code-unit offset the record is written with.
  int get textOffset => line.start + offsetInLine;

  bool get changed => tier != RestoreTier.exact;
}

/// D4's tiered restore: an exact anchor, a ±N-line relocation, an
/// index-assisted search, then the line index or the percentage with the change
/// reported instead of a silent jump.
///
/// Every input comes in from a caller — the stored record and the index as the
/// file is now — and every read goes through [ReaderLines], so this is the part
/// of the reader that can be tested without a file or a native library.
class PositionRestore {
  const PositionRestore({
    required this.lines,
    required this.stored,
    this.relocateLines = 200,
    this.relocateCodeUnits = 64 * 1024,
    this.searchCodeUnits = 16 * 1024 * 1024,
    this.searchWindowCodeUnits = 64 * 1024,
  });

  final ReaderLines lines;
  final ProgressRecord stored;

  /// D4's "±N lines": how far the anchor may have moved for the near tier.
  final int relocateLines;

  /// How much text the near tier reads around the stored line once.
  final int relocateCodeUnits;

  /// How much text the search tier may examine before it gives up and lets the
  /// fallback tier report the change. 16 M code units is one twenty-megabyte
  /// novel's worth; a larger file reports the fallback rather than blocking the
  /// reader on a full pass.
  final int searchCodeUnits;

  /// One search step, read from a stored anchor so it starts at a line start.
  final int searchWindowCodeUnits;

  Future<RestoredPosition> resolve() async {
    final exact = await _exact();
    if (exact != null) return exact;
    final near = await _relocate();
    if (near != null) {
      return RestoredPosition(
        line: near,
        offsetInLine: stored.offsetInLine,
        tier: RestoreTier.relocated,
      );
    }
    final searched = await _search();
    if (searched != null) {
      return RestoredPosition(
        line: searched,
        offsetInLine: stored.offsetInLine,
        tier: RestoreTier.searched,
      );
    }
    final byLine = await lines.offsetOfLine(stored.lineIndex);
    if (byLine != null) {
      return RestoredPosition(
        line: byLine,
        offsetInLine: stored.offsetInLine,
        tier: RestoreTier.lineIndex,
      );
    }
    return RestoredPosition(
      line: await _byPercentage(),
      tier: RestoreTier.percentage,
    );
  }

  /// D4's first tier: the length still matches and the anchor still sits at the
  /// stored offset.
  ///
  /// A record that carries no length and no anchor — one written before a
  /// reader filled them — keeps its offset: the offset is the authoritative
  /// field, and nothing here contradicts it.
  Future<RestoredPosition?> _exact() async {
    final length = lines.index.codeUnitLength;
    if (stored.textOffset >= length) return null;
    if (stored.textLength != 0 && stored.textLength != length) return null;
    final line = await lines.lineAt(stored.textOffset);
    final anchor = stored.anchor;
    if (anchor != null && anchor.isNotEmpty) {
      // Exactly the units the anchor names: a verification read asks for what it
      // compares, so a page-sized window that ended inside the line cannot make
      // the comparison answer the wrong way.
      final prefix = await lines.read(
        line.line.start,
        maxCodeUnits: anchor.length,
      );
      if (!anchorMatches(prefix.text, anchor)) return null;
    }
    return RestoredPosition(
      line: line.line,
      // The record's offset is the position, and the line it falls in is known:
      // the intra-line offset is derived from both instead of being taken on
      // trust, so a record written before the line fields existed keeps its own
      // offset.
      offsetInLine: stored.textOffset - line.line.start,
      tier: RestoreTier.exact,
    );
  }

  /// D4's second tier: one bounded window around the stored line index, looking
  /// for the line the anchor names within ±[relocateLines] of it.
  Future<ReaderLine?> _relocate() async {
    final anchor = stored.anchor;
    if (anchor == null || anchor.isEmpty) return null;
    final from = await lines.offsetOfLine(
      math.max(0, stored.lineIndex - relocateLines),
    );
    if (from == null) return null;
    final window = await lines.read(
      from.start,
      maxCodeUnits: relocateCodeUnits,
    );
    for (final line in windowLines(window)) {
      if ((line.lineIndex - stored.lineIndex).abs() > relocateLines) continue;
      if (anchorMatches(line.text, anchor)) {
        return ReaderLine(start: line.start, lineIndex: line.lineIndex);
      }
    }
    return null;
  }

  /// D4's third tier: one pass of bounded windows, each read from a stored
  /// anchor so it starts at a line start, looking for the anchor's text.
  Future<ReaderLine?> _search() async {
    final anchor = stored.anchor;
    if (anchor == null || anchor.isEmpty) return null;
    var examined = 0;
    for (final step in lines.index.anchors) {
      if (examined >= searchCodeUnits) return null;
      final window = await lines.read(
        step.codeUnitOffset,
        maxCodeUnits: searchWindowCodeUnits,
      );
      for (final line in windowLines(window)) {
        if (anchorMatches(line.text, anchor)) {
          return ReaderLine(start: line.start, lineIndex: line.lineIndex);
        }
      }
      examined += window.text.length;
    }
    return null;
  }

  /// D4's last tier: the stored offset as a share of the length it was written
  /// against, snapped to a line start for display.
  Future<ReaderLine> _byPercentage() async {
    final length = lines.index.codeUnitLength;
    if (stored.textLength <= 0 || length <= 0) {
      return (await lines.lineAt(0)).line;
    }
    final scaled = stored.textOffset * length ~/ stored.textLength;
    final offset = scaled.clamp(0, length - 1);
    return (await lines.lineAt(offset)).line;
  }
}
