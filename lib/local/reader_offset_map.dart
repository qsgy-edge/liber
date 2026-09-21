/// The raw-file ↔ processed-text offset mapping of one materialised unit.
///
/// A replace rule inserts, deletes or rewrites text, so the byte-for-byte
/// offsets a progress anchor was written against no longer describe the text
/// on screen. This map keeps the two spaces in step: it records the raw line
/// starts whose line a rule left unchanged — the **sync points** — and resolves
/// any other position to the nearest preceding sync point. Between two sync
/// points ([ContentProcessing.content] rewrote, inserted or deleted lines
/// there) the map therefore carries the preceding point instead of inventing
/// an offset, which is the resolution this ticket pins: a position inside a
/// rewritten line lands on the nearest preceding sync point's line. The
/// mappings are monotonic, so paging forward never walks the raw offset
/// backwards.
///
/// The map is built from the unit's raw body and the text
/// [ContentProcessing.content] returned for it and lives with the unit in
/// memory — it is never persisted, so `text_index`'s shape does not change.
library;

/// The paragraph indent [ContentProcessing.content] prefixes every processed
/// line with — `ReadBookConfig.paragraphIndent`'s frozen default, the same
/// constant the shaping stage uses.
const String _paragraphIndent = '　　';

String _expected(String rawLine) => '$_paragraphIndent$rawLine';

/// The frozen `str.trim { it.code <= 0x20 || it == '　' }` cutset: Java's
/// control/space range plus the ideographic space. The shaping stage trims
/// every processed paragraph with it, so a raw line is compared the same way.
bool _cut(int codeUnit) => codeUnit <= 0x20 || codeUnit == 0x3000;

String _trimFrozen(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _cut(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _cut(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/// One synchronisation point: a raw line start and the processed line start it
/// became.
typedef OffsetSync = ({int raw, int processed});

/// The raw ↔ processed offset map of one materialised unit (B1).
///
/// A sync point is a raw line start the alignment placed a processed line at.
/// An unchanged line is found by matching the two texts; a line a rule rewrote
/// in place still gets its sync point from the alignment's positional
/// correspondence, so a page on it round-trips exactly. Only a position the
/// alignment could not place — an inserted line, or a run of rewritten lines
/// longer than [_resyncLookahead] — resolves to the nearest preceding sync
/// point, which is the documented resolution for it.
class ReaderOffsetMap {
  ReaderOffsetMap(List<OffsetSync> points)
    : _points = List.unmodifiable(_normalise(points));

  final List<OffsetSync> _points;

  /// A raw offset maps to a processed offset, exact at a sync point and the
  /// nearest preceding one otherwise.
  int processedForRaw(int raw) => _at(raw, (point) => point.raw).processed;

  /// A processed offset maps to a raw offset, exact at a sync point and the
  /// nearest preceding one otherwise.
  int rawForProcessed(int processed) =>
      _at(processed, (point) => point.processed).raw;

  OffsetSync _at(int value, int Function(OffsetSync) key) {
    var low = 0;
    var high = _points.length - 1;
    OffsetSync? found;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (key(_points[middle]) <= value) {
        found = _points[middle];
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found ?? _points.first;
  }

  /// Orders by raw offset (the alignment emits the two keys in step, so this is
  /// also processed order) and drops a point that repeats its predecessor.
  static List<OffsetSync> _normalise(List<OffsetSync> points) {
    final sorted = [...points]..sort((a, b) => a.raw.compareTo(b.raw));
    final out = <OffsetSync>[];
    for (final point in sorted) {
      if (out.isNotEmpty && out.last == point) continue;
      out.add(point);
    }
    return out;
  }
}

/// Builds the sync-point map for one unit.
///
/// [rawText] is the unit's raw body (the chapter's heading line already
/// removed) and [rawBase] its absolute code-unit start, so the sync points
/// carry absolute raw offsets while the processed offsets stay relative to the
/// unit's processed text. [processedText] is exactly what
/// `ContentProcessing.content` returned for that body, so the shaping stage's
/// indent, trim and dropped-empty-lines behaviour is compared, not
/// reimplemented.
ReaderOffsetMap buildOffsetMap({
  required String rawText,
  required int rawBase,
  required String processedText,
}) {
  final rawLines = <({int start, String text})>[];
  var cursor = 0;
  for (final line in rawText.split('\n')) {
    final trimmed = _trimFrozen(line.trim());
    if (trimmed.isNotEmpty) {
      rawLines.add((start: rawBase + cursor, text: trimmed));
    }
    cursor += line.length + 1;
  }

  final processedLines = <({int start, String text})>[];
  cursor = 0;
  for (final line in processedText.split('\n')) {
    processedLines.add((start: cursor, text: line));
    cursor += line.length + 1;
  }

  final points = <OffsetSync>[(raw: rawBase, processed: 0)];
  var raw = 0;
  var processed = 0;
  while (raw < rawLines.length && processed < processedLines.length) {
    if (processedLines[processed].text == _expected(rawLines[raw].text)) {
      points.add((
        raw: rawLines[raw].start,
        processed: processedLines[processed].start,
      ));
      raw += 1;
      processed += 1;
      continue;
    }
    // The texts disagree. Find the nearest line either side still carries the
    // other's text: that tells a dropped raw line from an inserted processed
    // one. When neither side finds one, the line was rewritten in place and the
    // two positions still correspond.
    final dropRaw = _lookahead(
      rawLines,
      processedLines,
      raw,
      processed,
      rawSide: true,
    );
    final insertProcessed = _lookahead(
      rawLines,
      processedLines,
      raw,
      processed,
      rawSide: false,
    );
    if (dropRaw != null &&
        (insertProcessed == null || dropRaw <= insertProcessed)) {
      raw += dropRaw;
      continue;
    }
    if (insertProcessed != null) {
      processed += insertProcessed;
      continue;
    }
    points.add((
      raw: rawLines[raw].start,
      processed: processedLines[processed].start,
    ));
    raw += 1;
    processed += 1;
  }
  points.add((raw: rawBase + rawText.length, processed: processedText.length));
  return ReaderOffsetMap(points);
}

/// How far the alignment looks for the next line either side still carries
/// before it treats the run as rewritten lines and keeps the positional
/// correspondence. A rule that rewrites a longer run therefore still maps each
/// of its lines instead of hunting through the whole unit.
const int _resyncLookahead = 64;

/// The smallest step along one side that reaches a line the other side still
/// carries, or null when no line within [_resyncLookahead] matches.
int? _lookahead(
  List<({int start, String text})> rawLines,
  List<({int start, String text})> processedLines,
  int raw,
  int processed, {
  required bool rawSide,
}) {
  for (var step = 1; step <= _resyncLookahead; step++) {
    if (rawSide) {
      // A rule dropped or merged raw lines: skip to the next raw line the
      // processed side still carries.
      if (raw + step < rawLines.length &&
          processedLines[processed].text ==
              _expected(rawLines[raw + step].text)) {
        return step;
      }
    } else {
      // A rule inserted or split lines: skip to the next processed line the raw
      // side still carries.
      if (processed + step < processedLines.length &&
          processedLines[processed + step].text ==
              _expected(rawLines[raw].text)) {
        return step;
      }
    }
  }
  return null;
}
