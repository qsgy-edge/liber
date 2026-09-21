import 'dart:io';
import 'dart:math' as math;

import 'package:drift/native.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/local/local_reader.dart';
import 'package:liber/local/reader_engine.dart';
import 'package:liber/source/content_processing.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/local_library.dart';
import 'package:liber/store/progress.dart';
import 'package:liber/store/space_store.dart';

/// A text engine that serves windows out of a String.
///
/// The reader, its paging, its restore tiers and its page are all written
/// against [ReaderEngine], so a test drives them with this fake and never loads
/// the native library — which is exactly what a widget test cannot do. It
/// reproduces the real engine's contract: a window starts exactly at the offset
/// asked for, names the line that offset is in, and says when it reached the end
/// of the file.
class FakeEngine implements ReaderEngine {
  FakeEngine(
    this.text, {
    this.encoding = 'UTF-8',
    this.chapters = const <ReaderChapter>[],
    this.anchorStrideCodeUnits = 1024,
  });

  /// The file, as this fake serves it: a test edits this to change the book
  /// behind the reader's back.
  String text;

  final String encoding;
  final List<ReaderChapter> chapters;

  /// One anchor per this many code units of line starts — the stand-in for the
  /// engine's 32 KiB byte stride.
  final int anchorStrideCodeUnits;

  /// Every window the reader asked for, in order: what it asked and how much.
  final List<({int textOffset, int maxCodeUnits, bool anchored})> reads = [];

  /// How many times the reader made the engine do an index pass.
  int indexPasses = 0;

  /// The largest window the reader asked for: a page, never a document.
  int get largestRead => reads.isEmpty
      ? 0
      : reads.map((read) => read.maxCodeUnits).reduce(math.max);

  @override
  Future<ReaderIndex> index(String path) async {
    indexPasses += 1;
    return ReaderIndex(
      encoding: encoding,
      codeUnitLength: text.length,
      anchors: anchorsOf(text, strideCodeUnits: anchorStrideCodeUnits),
      chapters: chapters,
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
    reads.add((
      textOffset: textOffset,
      maxCodeUnits: maxCodeUnits,
      anchored: anchor != null,
    ));
    if (textOffset >= text.length) {
      throw StateError('offset $textOffset is past the end of ${text.length}');
    }
    final stop = math.min(text.length, textOffset + maxCodeUnits);
    return ReaderWindow(
      text: text.substring(textOffset, stop),
      textOffset: textOffset,
      lineIndex: _lineIndexAt(textOffset),
      atEnd: stop >= text.length,
    );
  }

  @override
  String render(String text, ReaderScript? script) =>
      script == null ? text : '«${script.name}»$text';

  int _lineIndexAt(int textOffset) {
    var lineIndex = 0;
    for (var unit = 0; unit < textOffset; unit++) {
      if (text.codeUnitAt(unit) == 0x0a) lineIndex += 1;
    }
    return lineIndex;
  }
}

/// An engine that records what a reader asked a real engine for: the assertion
/// that no path hands the engine a whole document.
class RecordingEngine implements ReaderEngine {
  RecordingEngine(this.engine);

  final ReaderEngine engine;

  /// Every window the reader asked for, in order.
  final List<({int textOffset, int maxCodeUnits, bool anchored})> reads = [];

  /// How many index passes the reader asked for.
  int indexPasses = 0;

  int get largestRead => reads.isEmpty
      ? 0
      : reads.map((read) => read.maxCodeUnits).reduce(math.max);

  @override
  Future<ReaderIndex> index(String path) {
    indexPasses += 1;
    return engine.index(path);
  }

  @override
  Future<ReaderWindow> readWindow({
    required String path,
    required String encoding,
    required int textOffset,
    required int maxCodeUnits,
    ReaderAnchor? anchor,
  }) {
    reads.add((
      textOffset: textOffset,
      maxCodeUnits: maxCodeUnits,
      anchored: anchor != null,
    ));
    return engine.readWindow(
      path: path,
      encoding: encoding,
      textOffset: textOffset,
      maxCodeUnits: maxCodeUnits,
      anchor: anchor,
    );
  }

  @override
  String render(String text, ReaderScript? script) =>
      engine.render(text, script);
}

/// The sparse line-start anchors an index pass produces for [text]: the first
/// line always, then one at least every [strideCodeUnits] code units, aligned to
/// a line start. A byte offset is the UTF-8 length of the text before it.
List<ReaderAnchor> anchorsOf(String text, {int strideCodeUnits = 1024}) {
  final anchors = <ReaderAnchor>[
    (byteOffset: 0, codeUnitOffset: 0, lineIndex: 0),
  ];
  var bytes = 0;
  var lineIndex = 0;
  var lastAnchor = 0;
  for (var unit = 0; unit < text.length; unit++) {
    final code = text.codeUnitAt(unit);
    bytes += code < 0x80 ? 1 : (code < 0x800 ? 2 : 3);
    if (code != 0x0a) continue;
    lineIndex += 1;
    if (unit + 1 - lastAnchor >= strideCodeUnits) {
      anchors.add((
        byteOffset: bytes,
        codeUnitOffset: unit + 1,
        lineIndex: lineIndex,
      ));
      lastAnchor = unit + 1;
    }
  }
  return anchors;
}

/// A plausible Chinese TXT: chapter headings with paragraphs under them, long
/// enough that one page holds a few of them.
String novelText({int chapters = 4, int paragraphs = 6, int repeats = 4}) {
  final buffer = StringBuffer();
  for (var chapter = 1; chapter <= chapters; chapter++) {
    buffer.writeln('第$chapter章 起点');
    for (var paragraph = 1; paragraph <= paragraphs; paragraph++) {
      buffer.writeln('这是第$chapter章的第$paragraph段。' * repeats);
    }
  }
  return buffer.toString();
}

/// The chapter boundaries a default TOC rule finds in [text]: the lines that
/// start a chapter heading, keyed by their own start offset and line index.
List<ReaderChapter> chaptersOf(String text) {
  final chapters = <ReaderChapter>[];
  var offset = 0;
  var lineIndex = 0;
  for (final line in text.split('\n')) {
    if (line.startsWith('第')) {
      chapters.add(
        ReaderChapter(
          title: line,
          codeUnitOffset: offset,
          lineIndex: lineIndex,
        ),
      );
    }
    offset += line.length + 1;
    lineIndex += 1;
  }
  return chapters;
}

/// A space over an in-memory database with [file] admitted as a local book, so
/// the reader sees the rows the app writes.
Future<({SpaceStore store, LocalLibrary library, LocalBook book})> admittedBook(
  File file,
) async {
  final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
  final library = LocalLibrary(store);
  await library.selectRoot(file.parent.path);
  final books = await library.addFiles([file]);
  return (store: store, library: library, book: books.single);
}

/// The book's file row, for the assertions about the cached length, the
/// modification time and the relink flag.
Future<LocalFile> fileRow(SpaceStore store, LocalBook book) async =>
    (await store.localFile(book.rootId, book.relativePath!))!;

/// The line facts a reader writes for [textOffset]: the line it is in, how far
/// into it, and the line's own anchor.
({int lineIndex, int offsetInLine, String? anchor}) positionFacts(
  String text,
  int textOffset,
) {
  var lineIndex = 0;
  var lineStart = 0;
  for (var unit = 0; unit < textOffset; unit++) {
    if (text.codeUnitAt(unit) == 0x0a) {
      lineIndex += 1;
      lineStart = unit + 1;
    }
  }
  return (
    lineIndex: lineIndex,
    offsetInLine: textOffset - lineStart,
    anchor: anchorOf(text.substring(lineStart)),
  );
}

/// The record a reader writes for [textOffset] of [text], as it would have been
/// written before a later open reads it back.
ProgressRecord recordAt(
  String text,
  int textOffset, {
  int? textLength,
  String? chapterKey,
  int? chapterIndex,
}) {
  final facts = positionFacts(text, textOffset);
  return ProgressRecord(
    textOffset: textOffset,
    lineIndex: facts.lineIndex,
    offsetInLine: facts.offsetInLine,
    textLength: textLength ?? text.length,
    chapterKey: chapterKey,
    chapterIndex: chapterIndex,
    anchor: facts.anchor,
  );
}

/// A [ContentProcessing] over **literal** replace rules.
///
/// A regex rule runs in its own isolate, which a widget test's binding cannot
/// settle (and which a plain test pays a spawn for), so the reader's processed
/// path is driven here with a rule the isolated path would produce the same
/// result for. The book name and origin match what the app passes a local book.
ContentProcessing literalProcessing(
  List<({String pattern, String replacement})> rules, {
  String bookName = '本地书',
  String bookOrigin = 'loc_book',
  ReaderScript? script,
  bool useReplaceRule = true,
}) {
  final replaceRules = [
    for (var index = 0; index < rules.length; index++)
      ReplaceRule(
        id: 'r$index',
        name: '规则$index',
        groupName: '',
        pattern: rules[index].pattern,
        replacement: rules[index].replacement,
        scope: null,
        excludeScope: null,
        scopeTitle: false,
        scopeContent: true,
        isEnabled: true,
        isRegex: false,
        timeoutMillisecond: 0,
        ruleOrder: index,
      ),
  ];
  return ContentProcessing(
    rules: ReplaceRuleSet.forBook(
      replaceRules,
      bookName: bookName,
      bookOrigin: bookOrigin,
    ),
    bookName: bookName,
    script: script,
    useReplaceRule: useReplaceRule,
    useReSegment: false,
  );
}
