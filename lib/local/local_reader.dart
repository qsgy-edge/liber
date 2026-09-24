import 'dart:io';
import 'dart:math' as math;

import 'package:fjs/fjs.dart' show ConvertTarget;

import '../domain/contracts.dart';
import '../source/content_processing.dart';
import '../store/local_library.dart';
import '../store/progress.dart';
import 'reader_engine.dart';
import 'reader_offset_map.dart';
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

/// One thing the local reader has to say about the position it opened at, as a
/// code the page renders (#73).
///
/// The engine has no `AppLocalizations` and does not reach the widget layer, so
/// it reports *what* it noticed rather than the interface's words: each value's
/// name is also the ARB key its copy lives under
/// (`LocalReaderNotice.readerRestoreRelocated` ↔
/// `AppLocalizations.readerRestoreRelocated`), so one concept has one spelling
/// across the boundary — the split #72 established for the store layer.
///
/// The reader keeps its own code set rather than reusing #72's `StoreMessage`: a
/// notice here takes no arguments, is reported fresh at every open instead of
/// being read back from a stored report, and `StoreMessageCode` is the store's
/// and the source layer's vocabulary — sharing it would put the reader's words in
/// the store's enum and carry argument, JSON and literal-fallback machinery that
/// nothing on this path uses.
enum LocalReaderNotice {
  /// The stored anchor was near the record but not on it, and the position was
  /// relocated by the anchor it did find (`RestoreTier.relocated`).
  readerRestoreRelocated,

  /// The stored anchor was gone from the file and the position was searched for
  /// (`RestoreTier.searched`).
  readerRestoreSearched,

  /// The file was replaced and only the line number still identified the
  /// position (`RestoreTier.lineIndex`).
  readerRestoreLineIndex,

  /// The file was replaced and only the percentage still identified the position
  /// (`RestoreTier.percentage`).
  readerRestorePercentage,

  /// The replace rules rewrote or deleted the line the position was on: the
  /// deleted-offset policy (`reader_offset_map.dart`) put the reader on the
  /// run's own text instead. The position itself is not lost — it is still the
  /// raw file's offset — but what it shows has moved, and D4 reports that
  /// instead of moving silently.
  readerDeletedPosition,
}

/// What the reader has to say about the position it restored, or null when the
/// stored position still held.
///
/// D4: the fallback tiers report the change instead of jumping silently, and so
/// do the tolerant ones — a relocated position is worth saying out loud.
LocalReaderNotice? restoreNotice(RestoreTier tier) => switch (tier) {
  RestoreTier.exact => null,
  RestoreTier.relocated => LocalReaderNotice.readerRestoreRelocated,
  RestoreTier.searched => LocalReaderNotice.readerRestoreSearched,
  RestoreTier.lineIndex => LocalReaderNotice.readerRestoreLineIndex,
  RestoreTier.percentage => LocalReaderNotice.readerRestorePercentage,
};

/// The local reader's one open book: the file's index, the position the reader
/// is at, and the one bounded window on screen (D4/D10).
///
/// Nothing here reads the file as a document. The index is one streaming pass
/// the store keeps in `text_index` and `local_files`, the position is the
/// five-field `progress` row, and every page is a window of [pageCodeUnits] code
/// units that seeks to the nearest stored anchor.
///
/// When a [processing] instance is set, the page is not the file's own text: the
/// reader materialises the bounded **unit** the position falls in (a chapter, or
/// a capped slice of one), runs it through the one text entry
/// [ContentProcessing.content], and shows a window of the processed text. The
/// position is still the raw file's, translated to and from the processed text
/// through the unit's [ReaderOffsetMap] — so a record written before the rules
/// ran stays valid, and a rule set that changes later does not invalidate it.
/// That translation is exact: it reads the edit script the entry returns for the
/// unit, so a rule that inserts or deletes lines moves the lines after it by
/// exactly what it changed. A position inside a line the rules rewrote or
/// deleted has no image of its own; the map's deleted-offset policy puts the
/// reader on the rewritten run's own boundary and the reader reports it with
/// [LocalReaderNotice.readerDeletedPosition].
/// With [processing] null the reader is the plain window reader it was, the way
/// the online page falls back to the source's own text while its rules load.
class LocalReader {
  LocalReader({
    required this.engine,
    required this.library,
    required this.book,
    this.processing,
    this.script,
    this.pageCodeUnits = 4096,
    this.relocateLines = 200,
    this.unitCodeUnits = 102400,
    this.readChunkCodeUnits = 64 * 1024,
  });

  final ReaderEngine engine;
  final LocalLibrary library;
  final LocalBook book;

  /// The user's replace rules for this book, applied through #17's one text
  /// entry. Null shows the file's own text; a book opens with none until the
  /// space's rules are read, the way the online page does.
  ///
  /// [applyScript] sets the conversion on this instance and on [processing], so
  /// the processed and the unprocessed paths always render one target.
  final ContentProcessing? processing;

  /// The script the page renders, or null for the file's own characters. Which
  /// target a reader wants is `lib/settings/reader_script.dart`'s resolution.
  /// In processed mode the conversion is [processing]'s (it converts its own
  /// output); [applyScript] keeps this field and that instance in step.
  ConvertTarget? script;

  /// A page: a few thousand code units, not a document.
  final int pageCodeUnits;

  /// D4's "±N lines" for the near restore tier.
  final int relocateLines;

  /// The materialisation cap: a unit is at most this many code units, snapped
  /// down to a line start. It matches the frozen reader's `maxLengthWithToc`
  /// (102400) whose unit is measured in bytes, so a code-unit cap this size
  /// never splits a chapter the frozen reader keeps whole.
  final int unitCodeUnits;

  /// How much raw text one materialisation read asks the engine for. A unit is
  /// assembled from bounded reads of this size, never one document read.
  final int readChunkCodeUnits;

  ReaderIndex? _index;
  ReaderLines? _lines;
  ReaderWindow? _window;
  ProgressRecord? _position;
  List<LocalReaderNotice> _notices = const <LocalReaderNotice>[];
  String? _error;
  bool _busy = true;

  /// True from [open]'s first line until it settles, so [applyScript] never
  /// starts a second materialisation under an open that is still running.
  ///
  /// It is its own flag rather than a guard on [_busy]: that field starts `true`,
  /// and the page's legitimate call *before* [open] (it resolves the script and
  /// hands it over first) has to get through.
  bool _opening = false;

  _ReaderUnit? _unit;
  int _pageStart = 0;
  String _page = '';
  final Map<int, List<int>> _unitBoundaries = {};

  bool get _processed => processing != null;

  /// The bounded window on screen. In processed mode its text is the processed
  /// text and its offsets are processed offsets; otherwise both are the file's.
  ReaderWindow? get window => _window;

  /// The page as it is rendered.
  String get text => _window == null
      ? ''
      : (_processed ? _window!.text : engine.render(_window!.text, script));

  /// Where the reader is, as the five-field record. Always the raw file's space.
  ProgressRecord? get position => _position;

  /// What the reader had to change about the stored position: the restore
  /// tier's code and, when the replace rules rewrote the line the position was
  /// on, [LocalReaderNotice.readerDeletedPosition] after it. Empty when the
  /// stored position still held.
  List<LocalReaderNotice> get notices => _notices;

  /// Why the book could not be opened, or null.
  String? get error => _error;

  bool get busy => _busy;

  bool get hasPrevious {
    if (_processed) {
      final unit = _unit;
      if (unit == null) return false;
      return !(unit.rawStart == 0 && _pageStart == 0);
    }
    return (_position?.lineStart ?? 0) > 0;
  }

  bool get hasNext {
    final index = _index;
    if (index == null) return false;
    if (_processed) {
      final unit = _unit;
      if (unit == null) return false;
      return _pageStart + _page.length < unit.processedText.length ||
          unit.rawEnd < index.codeUnitLength;
    }
    final window = _window;
    if (window == null) return false;
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
    _opening = true;
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
      final restoredNotice = restored == null
          ? null
          : restoreNotice(restored.tier);
      _notices = restoredNotice == null
          ? const <LocalReaderNotice>[]
          : <LocalReaderNotice>[restoredNotice];
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
      if (_processed) {
        final unit = await _materialise(
          await _unitStartFor(_position!.lineStart),
        );
        _unit = unit;
        if (unit.map.imageOf(_position!.lineStart) == null) {
          _notices = <LocalReaderNotice>[
            ..._notices,
            LocalReaderNotice.readerDeletedPosition,
          ];
        }
        _pageStart = _processedLineStartAt(
          unit.processedText,
          unit.map.processedForRaw(_position!.lineStart),
        );
        await _readProcessedPage();
      } else {
        await _readRawPage();
      }
      if (restored != null && restored.changed) await save();
    } on Object catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
      _opening = false;
    }
  }

  /// The next page.
  ///
  /// In the file's own text it is the line the current window ends in, so the
  /// reader advances by whole lines while the offset stays a code-unit index. In
  /// processed mode it is the next window of the unit's processed text, and past
  /// the unit it materialises the next unit.
  Future<void> next() async {
    if (!_processed) {
      final window = _window;
      final lines = _lines;
      if (window == null || lines == null || !hasNext) return;
      final raw = window.textOffset + window.text.length;
      await _move(await lines.lineAt(raw), raw: raw);
      return;
    }
    final unit = _unit;
    final index = _index;
    if (unit == null || index == null || !hasNext) return;
    final sliceEnd = _pageStart + _page.length;
    if (sliceEnd < unit.processedText.length) {
      var start = _processedLineStartAt(unit.processedText, sliceEnd);
      if (start <= _pageStart) {
        start = _nextProcessedLineStart(unit.processedText, _pageStart);
      }
      _pageStart = start;
      await _readProcessedPage();
      await save();
      return;
    }
    if (unit.rawEnd >= index.codeUnitLength) return;
    _unit = await _materialise(unit.rawEnd);
    _pageStart = 0;
    await _readProcessedPage();
    await save();
  }

  /// The previous page.
  Future<void> previous() async {
    if (!_processed) {
      final position = _position;
      final lines = _lines;
      if (position == null || lines == null || !hasPrevious) return;
      final raw = math.max(0, position.lineStart - pageCodeUnits);
      await _move(await lines.lineAt(raw), raw: raw);
      return;
    }
    final unit = _unit;
    if (unit == null || !hasPrevious) return;
    if (_pageStart > 0) {
      final target = math.max(0, _pageStart - pageCodeUnits);
      _pageStart = _processedLineStartAt(unit.processedText, target);
      await _readProcessedPage();
      await save();
      return;
    }
    final previousStart = await _unitStartFor(unit.rawStart - 1);
    final previous = await _materialise(previousStart);
    _unit = previous;
    _pageStart = _processedLineStartAt(
      previous.processedText,
      math.max(0, previous.processedText.length - pageCodeUnits),
    );
    await _readProcessedPage();
    await save();
  }

  /// Writes the position the reader is at as its five-field record.
  Future<void> save() async {
    final position = _position;
    if (position == null) return;
    await library.saveProgressRecord(book.id, position);
  }

  /// Re-renders the current page in [target] without reopening the book: the
  /// file is not indexed again and the stored position does not move, so only
  /// the characters on screen change.
  ///
  /// In the file's own text the page is re-rendered from the window the reader
  /// already holds; in processed mode the unit the position falls in is run
  /// through the one text entry again, because that entry is what converts
  /// there. A book that is still opening ignores the call ([_opening]): the two
  /// materialisations would interleave `_unit` and `_pageStart`, and this
  /// method's `finally` would clear `_busy` under the open. The book opens with
  /// the script it was already given.
  Future<void> applyScript(ConvertTarget? target) async {
    if (_opening) return;
    processing?.script = target;
    if (script == target) return;
    script = target;
    final unit = _unit;
    final position = _position;
    if (!_processed || _index == null || unit == null || position == null) {
      return;
    }
    _busy = true;
    try {
      final next = await _materialise(unit.rawStart);
      _unit = next;
      _pageStart = _processedLineStartAt(
        next.processedText,
        next.map.processedForRaw(position.lineStart),
      );
      await _readProcessedPage();
    } on Object catch (error) {
      _error = '$error';
    } finally {
      _busy = false;
    }
  }

  // --- The file's own text (processing is null) ----------------------------

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
    await _readRawPage();
    await save();
  }

  /// Reads the window that shows the reader's line and keeps the anchor the
  /// record is written with.
  Future<void> _readRawPage() async {
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

  // --- The processed text (processing is set) ------------------------------

  /// Materialises the unit [rawStart] begins and processes it through the one
  /// text entry.
  ///
  /// The unit is bounded: its raw range ends at the region's end or at the first
  /// line start not past the cap, whichever comes first, and a chapter longer
  /// than the cap becomes consecutive units. A unit that begins at a chapter
  /// boundary has that heading line removed before the body reaches the entry,
  /// the way the frozen reader's `TextFile.getContent` strips the title.
  Future<_ReaderUnit> _materialise(int rawStart) async {
    final region = _regionAt(rawStart);
    final rawEnd = await _nextBoundary(rawStart, region.end);
    var bodyStart = rawStart;
    final chapterStart = region.chapterStart;
    if (chapterStart != null && rawStart == chapterStart) {
      final heading = await _lines!.lineAt(rawStart);
      final next = await _lines!.offsetOfLine(heading.line.lineIndex + 1);
      bodyStart = math.min(next?.start ?? rawEnd, rawEnd);
    }
    final body = await _readRange(bodyStart, rawEnd);
    final processed = await processing!.content(
      body,
      chapterTitle: region.title,
    );
    // The entry's own edit script is what the map is built from: it names the
    // ranges of the body the run rewrote, so no text has to be compared.
    final map = ReaderOffsetMap.fromEdits(processed.edits, rawBase: bodyStart);
    return _ReaderUnit(
      rawStart: rawStart,
      rawEnd: rawEnd,
      processedText: processed.text,
      map: map,
    );
  }

  /// Reads the raw code units `[start, end)` from the file in bounded windows.
  /// The range is already capped, so this never reads a document.
  Future<String> _readRange(int start, int end) async {
    final buffer = StringBuffer();
    var offset = start;
    while (offset < end) {
      final window = await _lines!.read(
        offset,
        maxCodeUnits: math.min(readChunkCodeUnits, end - offset),
      );
      if (window.text.isEmpty) break;
      buffer.write(window.text);
      offset += window.text.length;
      if (window.atEnd) break;
    }
    return buffer.toString();
  }

  /// Reads the page of the unit's processed text that shows the current
  /// position, and writes the raw position that page maps to.
  Future<void> _readProcessedPage() async {
    final unit = _unit;
    final index = _index;
    if (unit == null || index == null) return;
    final length = unit.processedText.length;
    var start = _pageStart.clamp(0, length);
    if (start == length && length > 0) {
      // A run rewrote or deleted the text to the end of the unit, and the
      // deleted-offset policy put the position past the last character it kept:
      // the last line the run left is what the reader shows for it.
      start = _processedLineStartAt(unit.processedText, length);
    }
    _pageStart = start;
    final end = math.min(length, start + pageCodeUnits);
    _page = unit.processedText.substring(start, end);
    final raw = unit.map.rawForProcessed(start);
    final line = await _lines!.lineAt(raw);
    final chapter = chapterAt(index.chapters, line.line.start);
    _position = ProgressRecord(
      textOffset: line.line.start,
      lineIndex: line.line.lineIndex,
      // A processed page starts at a line start, so the intra-line offset is
      // zero; the record still carries the raw line the page maps to.
      offsetInLine: 0,
      textLength: index.codeUnitLength,
      chapterKey: chapter?.key ?? _position?.chapterKey,
      chapterIndex: chapter?.index ?? _position?.chapterIndex,
      anchor: anchorOf(line.text),
    );
    _window = ReaderWindow(
      text: _page,
      textOffset: start,
      lineIndex: _processedLineIndex(unit.processedText, start),
      atEnd: end >= length,
    );
  }

  /// The chapter region the raw offset falls in: `[start, end)` between two TOC
  /// boundaries, with the chapter that owns it, or the preface before the first
  /// boundary when no chapter starts at or before the offset.
  _Region _regionAt(int rawOffset) {
    final index = _index!;
    final chapters = index.chapters;
    var low = 0;
    var high = chapters.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (chapters[middle].codeUnitOffset <= rawOffset) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    final end = found + 1 < chapters.length
        ? chapters[found + 1].codeUnitOffset
        : index.codeUnitLength;
    if (found < 0) {
      return _Region(
        start: 0,
        end: end,
        chapterStart: null,
        chapterIndex: null,
        title: '',
      );
    }
    return _Region(
      start: chapters[found].codeUnitOffset,
      end: end,
      chapterStart: chapters[found].codeUnitOffset,
      chapterIndex: found,
      title: chapters[found].title,
    );
  }

  /// The start of the capped unit that holds [rawOffset], walking the region's
  /// boundaries from its start only as far as [rawOffset]. The boundaries are
  /// cached, so paging back and forth continues the walk instead of repeating
  /// it.
  Future<int> _unitStartFor(int rawOffset) async {
    final region = _regionAt(rawOffset);
    final boundaries = await _boundariesFor(region.start, rawOffset);
    var start = region.start;
    for (final boundary in boundaries) {
      if (boundary > rawOffset) break;
      start = boundary;
    }
    return start;
  }

  /// The region's boundaries from its start up to the first boundary past
  /// [upTo].
  ///
  /// The cached list is always a **prefix** of the region's true boundary
  /// sequence, so a later call with a larger [upTo] continues the walk from the
  /// last boundary instead of treating the prefix as the whole region. [upTo] is
  /// what keeps opening a deep position in a region that spans a whole file from
  /// enumerating every unit (D4: no whole-document scan).
  Future<List<int>> _boundariesFor(int regionStart, int upTo) async {
    final regionEnd = _regionAt(regionStart).end;
    final boundaries = _unitBoundaries.putIfAbsent(
      regionStart,
      () => <int>[regionStart],
    );
    while (boundaries.last < upTo && boundaries.last < regionEnd) {
      final next = await _nextBoundary(boundaries.last, regionEnd);
      if (next <= boundaries.last) break;
      boundaries.add(next);
    }
    return boundaries;
  }

  /// The line start a unit that begins at [start] ends before: the last line
  /// start at or before `start + unitCodeUnits`, or the region's end. A single
  /// line longer than the cap advances to the next line start so a unit always
  /// grows.
  Future<int> _nextBoundary(int start, int regionEnd) async {
    final want = start + unitCodeUnits;
    if (want >= regionEnd) return regionEnd;
    final line = await _lines!.lineAt(want);
    if (line.line.start > start) return line.line.start;
    final next = await _lines!.offsetOfLine(line.line.lineIndex + 1);
    final nextStart = next?.start ?? regionEnd;
    return nextStart > start ? nextStart : regionEnd;
  }

  /// The largest line start at or before [offset] in the processed text.
  int _processedLineStartAt(String text, int offset) {
    if (offset <= 0) return 0;
    final capped = math.min(offset, text.length);
    return text.lastIndexOf('\n', capped - 1) + 1;
  }

  /// The next line start after [start] in the processed text.
  int _nextProcessedLineStart(String text, int start) {
    final newline = text.indexOf('\n', start);
    return newline < 0 ? text.length : newline + 1;
  }

  int _processedLineIndex(String text, int offset) {
    var count = 0;
    for (var unit = 0; unit < offset && unit < text.length; unit++) {
      if (text.codeUnitAt(unit) == 0x0a) count += 1;
    }
    return count;
  }

  // --- Shared --------------------------------------------------------------

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

/// One chapter region: the file range between two TOC boundaries.
class _Region {
  const _Region({
    required this.start,
    required this.end,
    required this.chapterStart,
    required this.chapterIndex,
    required this.title,
  });

  final int start;
  final int end;
  final int? chapterStart;
  final int? chapterIndex;
  final String title;
}

/// One materialised unit: its raw range, the text the one entry returned for it,
/// and the raw ↔ processed map between them.
class _ReaderUnit {
  const _ReaderUnit({
    required this.rawStart,
    required this.rawEnd,
    required this.processedText,
    required this.map,
  });

  final int rawStart;
  final int rawEnd;
  final String processedText;
  final ReaderOffsetMap map;
}
