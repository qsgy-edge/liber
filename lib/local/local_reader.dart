import 'dart:io';
import 'dart:math' as math;

import '../domain/contracts.dart';
import '../store/local_library.dart';
import '../store/progress.dart';
import 'reader_engine.dart';
import 'reader_restore.dart';

/// The chapter a position falls in: the last boundary at or before it, keyed by
/// its own start offset — D4's stable local chapter key — with its index in the
/// TOC. Null when the file has no chaptering at all.
({String key, int index})? chapterAt(
  List<ReaderChapter> chapters,
  int textOffset,
) {
  ({String key, int index})? found;
  for (var index = 0; index < chapters.length; index++) {
    if (chapters[index].codeUnitOffset > textOffset) break;
    found = (key: '${chapters[index].codeUnitOffset}', index: index);
  }
  return found;
}

/// The anchor a record keeps: the line's first code units, verbatim, capped at
/// the 32 the schema documents. A line with no text has no anchor to find, and
/// null says so.
String? anchorOf(String lineText) {
  final newline = lineText.indexOf('\n');
  final line = newline < 0 ? lineText : lineText.substring(0, newline);
  if (line.isEmpty) return null;
  return line.substring(0, math.min(32, line.length));
}

/// What the reader has to say about the position it restored, or null when the
/// stored position still held.
///
/// D4: the fallback tiers report the change instead of jumping silently, and so
/// do the tolerant ones — a relocated position is worth saying out loud.
String? restoreNotice(RestoreTier tier) => switch (tier) {
  RestoreTier.exact => null,
  RestoreTier.relocated => '文件已改动：阅读位置按锚点重新定位',
  RestoreTier.searched => '文件已改动：阅读位置在文件中重新找到',
  RestoreTier.lineIndex => '文件已替换：阅读位置按行号恢复，请检查',
  RestoreTier.percentage => '文件已替换：阅读位置按百分比恢复，请检查',
};

/// The local reader's one open book: the file's index, the position the reader
/// is at, and the one bounded window on screen (D4/D10).
///
/// Nothing here reads the file as a document. The index is one streaming pass
/// the store keeps in `text_index` and `local_files`, the position is the
/// five-field `progress` row, and every page is a window of [pageCodeUnits] code
/// units that seeks to the nearest stored anchor.
class LocalReader {
  LocalReader({
    required this.engine,
    required this.library,
    required this.book,
    this.script,
    this.pageCodeUnits = 4096,
    this.relocateLines = 200,
  });

  final ReaderEngine engine;
  final LocalLibrary library;
  final LocalBook book;

  /// The script the page was asked to render, or null for the file's own
  /// characters. Which one a reader wants is #27's choice.
  final ReaderScript? script;

  /// A page: a few thousand code units, not a document.
  final int pageCodeUnits;

  /// D4's "±N lines" for the near restore tier.
  final int relocateLines;

  ReaderIndex? _index;
  ReaderLines? _lines;
  ReaderWindow? _window;
  ProgressRecord? _position;
  String? _notice;
  String? _error;
  bool _busy = true;

  /// The bounded window on screen, as the engine returned it.
  ReaderWindow? get window => _window;

  /// The page as it is rendered: the window, in the script the page was asked
  /// for.
  String get text =>
      _window == null ? '' : engine.render(_window!.text, script);

  /// Where the reader is, as the five-field record.
  ProgressRecord? get position => _position;

  /// What the reader had to change about the stored position, or null.
  String? get notice => _notice;

  /// Why the book could not be opened, or null.
  String? get error => _error;

  bool get busy => _busy;

  bool get hasPrevious => (_position?.lineStart ?? 0) > 0;

  bool get hasNext {
    final window = _window;
    final index = _index;
    if (window == null || index == null) return false;
    return !window.atEnd &&
        window.textOffset + window.text.length < index.codeUnitLength;
  }

  /// Opens the book at its stored position, through D4's tiers.
  ///
  /// The stored index is trusted only while the file's modification time still
  /// matches; when it does not — or when the anchor is not where the record
  /// says it is — the file is indexed again, and the record is restored against
  /// the file as it is now.
  Future<void> open() async {
    _busy = true;
    _error = null;
    try {
      final file = File(book.path);
      if (!await file.exists()) {
        // D4's loudest case: the path itself is gone. That is a relink, and the
        // reader says so instead of showing a file that is not there.
        await library.setNeedsRelink(book, true);
        _error = '文件不存在，需要重新关联本地文件';
        return;
      }
      final modifiedAt = (await file.stat()).modified.millisecondsSinceEpoch;
      final facts = await library.fileIndex(book);
      final stored = await library.progressRecordOf(book.id);
      var index = facts.describes(modifiedAt) ? _asIndex(facts) : null;
      var restored = index == null || stored == null
          ? null
          : await _resolve(index, stored);
      if (restored != null && restored.changed) {
        // The modification time said the stored index was current, but the
        // anchor is not where the record says: the file was edited without its
        // timestamp moving, and the anchors, the length and the encoding have to
        // be re-derived before the position can be trusted again.
        index = null;
      }
      if (index == null) {
        final pass = await engine.index(book.path);
        await library.putFileIndex(
          book,
          encoding: pass.encoding,
          codeUnitLength: pass.codeUnitLength,
          modifiedAt: modifiedAt,
          anchors: pass.anchors,
        );
        index = pass;
        restored = stored == null ? null : await _resolve(pass, stored);
      }
      if (index.codeUnitLength == 0) {
        _error = '文件是空的';
        return;
      }
      _index = index;
      _lines = ReaderLines(
        engine: engine,
        path: book.path,
        index: index,
        windowCodeUnits: pageCodeUnits,
      );
      _notice = restored == null ? null : restoreNotice(restored.tier);
      _position = restored == null
          ? _startPosition(index)
          : _recordAt(
              index,
              stored: stored!,
              line: restored.line,
              offsetInLine: restored.offsetInLine,
            );
      // D4's change detection feeds the relink flag: the same facts that
      // restored the position decide whether the file is still the one the
      // record describes.
      await library.setNeedsRelink(book, restored != null && restored.changed);
      await _readPage();
      if (restored != null && restored.changed) await save();
    } on Object catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
    }
  }

  /// The next page: the line the current window ends in, so the reader advances
  /// by whole lines while the offset stays a code-unit index.
  Future<void> next() async {
    final window = _window;
    final lines = _lines;
    if (window == null || lines == null || !hasNext) return;
    final raw = window.textOffset + window.text.length;
    await _move(await lines.lineAt(raw), raw: raw);
  }

  /// The previous page: the line the window's start falls in once a page's worth
  /// of text is taken off it.
  Future<void> previous() async {
    final position = _position;
    final lines = _lines;
    if (position == null || lines == null || !hasPrevious) return;
    final raw = math.max(0, position.lineStart - pageCodeUnits);
    await _move(await lines.lineAt(raw), raw: raw);
  }

  /// Writes the position the reader is at as its five-field record.
  Future<void> save() async {
    final position = _position;
    if (position == null) return;
    await library.saveProgressRecord(book.id, position);
  }

  /// Moves to the line [target] was found in, keeping how far into that line
  /// [raw] is — D4's intra-line offset, which a line alone cannot carry.
  Future<void> _move(WindowedLine target, {required int raw}) async {
    final index = _index;
    final position = _position;
    if (index == null || position == null) return;
    _position = _recordAt(
      index,
      stored: position,
      line: target.line,
      offsetInLine: raw - target.line.start,
    );
    await _readPage();
    await save();
  }

  /// Reads the window that shows the reader's line and keeps the anchor the
  /// record is written with.
  Future<void> _readPage() async {
    final position = _position;
    final lines = _lines;
    if (position == null || lines == null) return;
    final window = await lines.read(
      position.lineStart,
      maxCodeUnits: pageCodeUnits,
    );
    _window = window;
    _position = position.withAnchor(anchorOf(window.text));
  }

  /// The record a moved position produces: the line, the intra-line offset it
  /// keeps, the length of the file as it is now, and the chapter the offset
  /// falls in when the chapter list is at hand.
  ProgressRecord _recordAt(
    ReaderIndex index, {
    required ProgressRecord stored,
    required ReaderLine line,
    required int offsetInLine,
  }) {
    final textOffset = line.start + offsetInLine;
    final chapter = chapterAt(index.chapters, textOffset);
    return ProgressRecord(
      textOffset: textOffset,
      lineIndex: line.lineIndex,
      offsetInLine: offsetInLine,
      textLength: index.codeUnitLength,
      chapterKey: chapter?.key ?? stored.chapterKey,
      chapterIndex: chapter?.index ?? stored.chapterIndex,
      anchor: stored.anchor,
    );
  }

  /// Where a book that was never read starts: its first line.
  ProgressRecord _startPosition(ReaderIndex index) {
    final chapter = chapterAt(index.chapters, 0);
    return ProgressRecord(
      textOffset: 0,
      lineIndex: 0,
      offsetInLine: 0,
      textLength: index.codeUnitLength,
      chapterKey: chapter?.key,
      chapterIndex: chapter?.index,
    );
  }

  Future<RestoredPosition> _resolve(ReaderIndex index, ProgressRecord stored) =>
      PositionRestore(
        lines: ReaderLines(
          engine: engine,
          path: book.path,
          index: index,
          windowCodeUnits: pageCodeUnits,
        ),
        stored: stored,
        relocateLines: relocateLines,
      ).resolve();

  static ReaderIndex _asIndex(LocalFileIndex facts) => ReaderIndex(
    encoding: facts.encoding,
    codeUnitLength: facts.textLength!,
    anchors: facts.anchors,
  );
}
