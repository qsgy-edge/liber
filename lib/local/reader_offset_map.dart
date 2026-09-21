/// The raw-file ↔ processed-text offset map of one materialised unit.
///
/// A replace rule inserts, deletes or rewrites text, so the code-unit offsets a
/// progress anchor was written against no longer describe the text on screen.
/// This map keeps the two spaces in step, and it is **exact**: it is built from
/// the edit script [ContentProcessing.content] returns for the unit — the ranges
/// of the body it rewrote, as the stage that rewrote them reported them — so
/// nothing here compares the two texts or guesses a correspondence.
///
/// Outside a rewritten range the raw body's offsets line up exactly, shifted by
/// the lengths the earlier ranges add or remove, and both directions translate
/// offset for offset. Inside one there is no image to translate: the **deleted
/// (rewritten) offset policy** resolves such an offset to the processed offset
/// where that range's replacement begins — the nearest surviving boundary — and
/// the same in reverse, so a page on one lands on the run's own text. A raw
/// offset whose run replaced the text with nothing therefore lands on the text
/// that follows it, and one whose run replaced it with text lands on that text.
/// The mappings are monotonic, so paging forward never walks the raw offset
/// backwards.
///
/// The map is built from the unit's body and the script
/// [ContentProcessing.content] returned for it, and lives with the unit in
/// memory — it is never persisted, so `text_index`'s shape does not change.
library;

import '../source/content_processing.dart' show ContentEdit;

/// One rewritten range of the unit's body: the raw range `[rawStart, rawEnd)`
/// became the processed range `[processedStart, processedEnd)`, after which the
/// two spaces are [shiftAfter] apart. A zero-width raw range is inserted text; a
/// zero-width processed range is deleted text.
class _Run {
  const _Run({
    required this.rawStart,
    required this.rawEnd,
    required this.processedStart,
    required this.processedEnd,
    required this.shiftAfter,
  });

  final int rawStart;
  final int rawEnd;
  final int processedStart;
  final int processedEnd;
  final int shiftAfter;
}

/// The raw ↔ processed offset map of one materialised unit.
///
/// The raw offsets are the file's own; the processed offsets are relative to the
/// start of the unit's body, which is the text the run was given.
class ReaderOffsetMap {
  ReaderOffsetMap.fromEdits(Iterable<ContentEdit> edits, {required int rawBase})
    : _rawBase = rawBase,
      _runs = List.unmodifiable(_runsOf(edits, rawBase));

  final int _rawBase;
  final List<_Run> _runs;

  /// The processed offset the raw offset's own text became, or null when a run
  /// rewrote or deleted the text it was in — [processedForRaw] then answers with
  /// that run's boundary.
  int? imageOf(int raw) {
    final at = _rawAt(raw < _rawBase ? _rawBase : raw);
    final run = at < 0 ? null : _runs[at];
    if (run != null && raw < run.rawEnd) return null;
    return raw - _rawBase + (run?.shiftAfter ?? 0);
  }

  /// Where a raw offset lands, under the deleted-offset policy of this file's
  /// library comment.
  int processedForRaw(int raw) {
    final at = _rawAt(raw < _rawBase ? _rawBase : raw);
    final run = at < 0 ? null : _runs[at];
    if (run == null) return raw - _rawBase;
    if (raw < run.rawEnd) return run.processedStart;
    return raw - _rawBase + run.shiftAfter;
  }

  /// The raw offset the processed offset's own text came from, or null when a
  /// run generated the text at it — [rawForProcessed] then answers with that
  /// run's boundary.
  int? sourceOf(int processed) {
    final at = _processedAt(processed < 0 ? 0 : processed);
    final run = at < 0 ? null : _runs[at];
    if (run != null && processed < run.processedEnd) return null;
    return _rawBase + processed - (run?.shiftAfter ?? 0);
  }

  /// Where a processed offset lands, under the deleted-offset policy of this
  /// file's library comment.
  int rawForProcessed(int processed) {
    final at = _processedAt(processed < 0 ? 0 : processed);
    final run = at < 0 ? null : _runs[at];
    if (run == null) return _rawBase + processed;
    if (processed < run.processedEnd) return run.rawStart;
    return _rawBase + processed - run.shiftAfter;
  }

  /// The last run that starts at or before [raw], or -1.
  int _rawAt(int raw) {
    var low = 0;
    var high = _runs.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_runs[middle].rawStart <= raw) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  /// The last run whose processed range starts at or before [processed], or -1.
  int _processedAt(int processed) {
    var low = 0;
    var high = _runs.length - 1;
    var found = -1;
    while (low <= high) {
      final middle = (low + high) >> 1;
      if (_runs[middle].processedStart <= processed) {
        found = middle;
        low = middle + 1;
      } else {
        high = middle - 1;
      }
    }
    return found;
  }

  /// One run per edit, in the offsets the reader asks in: the raw offsets are
  /// the file's, the processed offsets are relative to the body's start, and the
  /// shift is the length every earlier rewrite added or removed.
  static List<_Run> _runsOf(Iterable<ContentEdit> edits, int rawBase) {
    final runs = <_Run>[];
    var shift = 0;
    for (final edit in edits) {
      assert(
        runs.isEmpty || edit.start >= runs.last.rawEnd - rawBase,
        'the script is ascending and disjoint',
      );
      final rawStart = rawBase + edit.start;
      final rawEnd = rawBase + edit.end;
      runs.add(
        _Run(
          rawStart: rawStart,
          rawEnd: rawEnd,
          processedStart: edit.start + shift,
          processedEnd: edit.start + shift + edit.length,
          shiftAfter: shift + edit.length - (edit.end - edit.start),
        ),
      );
      shift = runs.last.shiftAfter;
    }
    return runs;
  }
}
