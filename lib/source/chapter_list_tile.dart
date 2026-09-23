import 'package:flutter/material.dart';

import 'book_source_pipeline.dart' show SourceChapter;

/// One table-of-contents row, shaped the way the frozen `ChapterListAdapter`
/// renders a chapter (`ChapterListAdapter.kt:119-168`).
///
/// A volume is a heading: the frozen tints the row's background and keeps its
/// `tag` hidden (`ChapterListAdapter.kt:138-150`). Every other chapter shows its
/// `tag` — the `ruleToc.updateTime` value — as the secondary line, and a chapter
/// the source marks VIP and not paid shows a lock (`ChapterListAdapter.kt:162-165`).
/// The frozen row is `singleLine="true"` for the name and the tag
/// (`res/layout/item_chapter_list.xml`), so both stay on one line instead of
/// growing the row, and a volume row differs only in its background.
///
/// The title is the chapter's own name: the frozen list replaces a title only
/// when `AppConfig.tocUiUseReplace` is on (`ChapterListAdapter.kt:78`), which
/// defaults to false.
///
/// The frozen's own 购买 action (`ReadMenu.kt:372-375`) has no counterpart in
/// this product: the lock is where its state is surfaced.
class ChapterListTile extends StatelessWidget {
  const ChapterListTile({
    super.key,
    required this.chapter,
    required this.onTap,
    this.selected = false,
  });

  final SourceChapter chapter;
  final VoidCallback onTap;

  /// Whether this is the chapter the reader is on.
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final tag = chapter.tag;
    return ListTile(
      selected: selected,
      tileColor: chapter.isVolume ? colors.surfaceContainerHighest : null,
      title: Text(chapter.name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: chapter.isVolume || tag == null || tag.isEmpty
          ? null
          : Text(tag, maxLines: 1, overflow: TextOverflow.ellipsis),
      // The frozen lock follows the chapter's own markers, a volume included:
      // `isVip && !isPay` (`ChapterListAdapter.kt:162-165`).
      trailing: chapter.isVip && !chapter.isPay
          ? const Icon(Icons.lock_outline, size: 18)
          : null,
      onTap: onTap,
    );
  }
}
