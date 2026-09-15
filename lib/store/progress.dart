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
