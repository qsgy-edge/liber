/// The shelf's own filter (#88): whether a row's words contain what was typed.
///
/// A plain case-insensitive substring of the title or the author — not a
/// search. Nothing here reaches the network or the store, because the rows are
/// already in memory; nothing ranks, nothing remembers what was typed before,
/// and nothing matches approximately. The operator asked for a book they
/// already have, so the only question is whether a row carries the query.
///
/// A local book (`LocalBook`) carries a title and no author, so its rows match
/// on the title alone; an empty or whitespace-only query matches every row.
bool shelfRowMatches(String filter, {required String title, String? author}) {
  final needle = filter.trim().toLowerCase();
  if (needle.isEmpty) return true;
  return title.toLowerCase().contains(needle) ||
      (author ?? '').toLowerCase().contains(needle);
}
