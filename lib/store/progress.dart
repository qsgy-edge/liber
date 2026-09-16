/// The five-field progress record (`docs/user-data-contract.md` D4) as a reader
/// reads it back and writes it: the authoritative absolute code-unit offset,
/// the line index and the offset inside that line, the length the position was
/// written against, the chapter, and the anchor.
///
/// Nothing here touches the database: the record is the shape, and the store is
/// what maps it to a row (`LocalLibrary.saveProgressRecord`, `SpaceStore`).
class ProgressRecord {
  const ProgressRecord({
    required this.textOffset,
    required this.lineIndex,
    required this.offsetInLine,
    required this.textLength,
    this.chapterKey,
    this.chapterIndex,
    this.anchor,
    this.updatedAt = 0,
  });

  /// The authoritative absolute code-unit offset.
  final int textOffset;

  /// The line the offset sits in, and how far into it — display and the
  /// restore's tolerant tiers.
  final int lineIndex;
  final int offsetInLine;

  /// The file's length in code units when the record was written: the
  /// percentage fallback, and the fact that says whether the file changed.
  final int textLength;

  /// The chapter's stable key and its index, when the book is chaptered (D4:
  /// a local chapter's key is its own start offset).
  final String? chapterKey;
  final int? chapterIndex;

  /// The current line's first code units, verbatim, so the tolerant restore
  /// tiers can compare, relocate and search for them (D4).
  final String? anchor;

  final int updatedAt;

  /// Where the reader is, as a line start: the offset minus the intra-line
  /// offset. A line alone is not a position, which is why both are kept.
  int get lineStart => textOffset - offsetInLine;

  /// The same position with the anchor taken from the window that shows it: the
  /// anchor is the reader's own fact about the line it just read.
  ProgressRecord withAnchor(String? anchor) => ProgressRecord(
    textOffset: textOffset,
    lineIndex: lineIndex,
    offsetInLine: offsetInLine,
    textLength: textLength,
    chapterKey: chapterKey,
    chapterIndex: chapterIndex,
    anchor: anchor,
    updatedAt: updatedAt,
  );
}

/// The ordering rule of the five-field progress record
/// (`docs/user-data-contract.md` D4): `(chapterIndex, textOffset)` decides
/// whether a position advances, and the timestamp breaks ties.
///
/// One rule, two callers: a reader writing progress, and a migration folding
/// two rows for the same book into one.
class ProgressPosition {
  const ProgressPosition({
    this.chapterIndex,
    this.textOffset = 0,
    this.updatedAt = 0,
  });

  final int? chapterIndex;
  final int textOffset;
  final int updatedAt;

  bool advancesFrom(ProgressPosition other) {
    final chapter = (chapterIndex ?? 0).compareTo(other.chapterIndex ?? 0);
    if (chapter != 0) return chapter > 0;
    if (textOffset != other.textOffset) return textOffset > other.textOffset;
    return updatedAt > other.updatedAt;
  }
}
