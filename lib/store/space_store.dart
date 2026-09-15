import 'package:drift/drift.dart';

import 'database.dart';
import 'ids.dart';
import 'progress.dart';

/// Intent-level access to one space's store.
///
/// The drift tables are the schema; this class is where the contract's rules
/// that SQL alone cannot express live — a minted id, a natural-key match, a
/// name-keyed group merge, a forward-only progress record — so that neither a
/// widget nor the importer has to re-implement them. Writes take drift's
/// companions, reads return the rows.
class SpaceStore {
  SpaceStore(this.db, {this.spaceId = ''});

  final SpaceDatabase db;
  final String spaceId;

  Future<void> close() => db.close();

  // --- Book Sources (D7) ---------------------------------------------------

  /// Stores a source keyed by `bookSourceUrl`. The imported object stays in
  /// `raw`, so fields this build does not read survive a round trip.
  Future<BookSource> putSource(SourcesCompanion source) async {
    await db.into(db.sources).insertOnConflictUpdate(source);
    return (await sourceByUrl(source.bookSourceUrl.value))!;
  }

  Future<BookSource?> sourceByUrl(String bookSourceUrl) => (db.select(
    db.sources,
  )..where((s) => s.bookSourceUrl.equals(bookSourceUrl))).getSingleOrNull();

  Future<List<BookSource>> allSources() =>
      (db.select(db.sources)..orderBy([
            (s) => OrderingTerm(expression: s.customOrder),
            (s) => OrderingTerm(expression: s.bookSourceUrl),
          ]))
          .get();

  // --- Shelf books (D2) ----------------------------------------------------

  /// Inserts or replaces a book by its minted id and returns that id. A book
  /// that already exists is found by [bookByNaturalKey] first, so its identity
  /// is not rewritten.
  Future<String> putBook(BooksCompanion book) async {
    await db.into(db.books).insertOnConflictUpdate(book);
    return book.id.value;
  }

  Future<ShelfBook?> bookById(String id) =>
      (db.select(db.books)..where((b) => b.id.equals(id))).getSingleOrNull();

  /// The natural key import and re-search match on: `(sourceRef,
  /// sourceBookUrl)`. `(name, author)` is only ever a hint.
  Future<ShelfBook?> bookByNaturalKey(String sourceRef, String sourceBookUrl) =>
      (db.select(db.books)..where(
            (b) =>
                b.sourceRef.equals(sourceRef) &
                b.sourceBookUrl.equals(sourceBookUrl),
          ))
          .getSingleOrNull();

  /// A local book's natural key: the root it was admitted under plus its path
  /// inside that root.
  Future<ShelfBook?> localBook(String rootId, String relativePath) =>
      (db.select(db.books)..where(
            (b) =>
                b.kind.equals('local') &
                b.rootId.equals(rootId) &
                b.relativePath.equals(relativePath),
          ))
          .getSingleOrNull();

  /// The shelf view: shelved books in space order. The synthetic views
  /// (all / local / ungrouped / update-error) are queries, not rows (D3).
  Future<List<ShelfBook>> shelf({String? kind, bool ungrouped = false}) {
    final query = db.select(db.books)..where((b) => b.shelved.equals(true));
    if (kind != null) query.where((b) => b.kind.equals(kind));
    if (ungrouped) {
      query.where(
        (b) => b.id.isNotInQuery(
          db.selectOnly(db.bookGroups)..addColumns([db.bookGroups.bookId]),
        ),
      );
    }
    query.orderBy([
      (b) => OrderingTerm(expression: b.bookOrder),
      (b) => OrderingTerm(expression: b.id),
    ]);
    return query.get();
  }

  // --- Groups (D3) ---------------------------------------------------------

  /// Names are trimmed, non-empty and unique per space; a name that already
  /// exists joins instead of creating a second group.
  Future<ShelfGroup> ensureGroup(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) throw ArgumentError.value(name, 'name', '分组名不能为空');
    final existing = await groupByName(trimmed);
    if (existing != null) return existing;
    final id = mintId('group');
    await db
        .into(db.groups)
        .insert(GroupsCompanion.insert(id: id, name: trimmed));
    return (await groupByName(trimmed))!;
  }

  Future<ShelfGroup?> groupByName(String name) => (db.select(
    db.groups,
  )..where((g) => g.name.equals(name))).getSingleOrNull();

  Future<List<ShelfGroup>> allGroups() =>
      (db.select(db.groups)..orderBy([
            (g) => OrderingTerm(expression: g.groupOrder),
            (g) => OrderingTerm(expression: g.id),
          ]))
          .get();

  /// Membership is the whole list of group ids for a book; importing unions.
  Future<void> setBookGroups(String bookId, Iterable<String> groupIds) async {
    await db.transaction(() async {
      await (db.delete(
        db.bookGroups,
      )..where((m) => m.bookId.equals(bookId))).go();
      for (final groupId in groupIds.toSet()) {
        await db
            .into(db.bookGroups)
            .insert(
              BookGroup(bookId: bookId, groupId: groupId),
              mode: InsertMode.insertOrIgnore,
            );
      }
    });
  }

  Future<List<ShelfGroup>> groupsOf(String bookId) {
    final query = db.select(db.groups).join([
      innerJoin(db.bookGroups, db.bookGroups.groupId.equalsExp(db.groups.id)),
    ])..where(db.bookGroups.bookId.equals(bookId));
    return query.map((row) => row.readTable(db.groups)).get();
  }

  // --- Chapters (D4) -------------------------------------------------------

  /// A book's chapters are its TOC: replacing the list replaces the rows.
  Future<void> putChapters(String bookId, List<BookChapter> chapters) async {
    await db.transaction(() async {
      await (db.delete(
        db.chapters,
      )..where((c) => c.bookId.equals(bookId))).go();
      await db.batch((b) => b.insertAll(db.chapters, chapters));
    });
  }

  Future<List<BookChapter>> chaptersOf(String bookId) =>
      (db.select(db.chapters)
            ..where((c) => c.bookId.equals(bookId))
            ..orderBy([(c) => OrderingTerm(expression: c.chapterIndex)]))
          .get();

  // --- Progress (D4) -------------------------------------------------------

  Future<ReadingProgress?> progressOf(String bookId) => (db.select(
    db.progress,
  )..where((p) => p.bookId.equals(bookId))).getSingleOrNull();

  /// Forward-only: `(chapterIndex, textOffset)` decides whether the incoming
  /// record advances, and the timestamp breaks ties. Returns whether it was
  /// written, so a caller can tell "saved" from "older than what was there".
  Future<bool> saveProgress(ProgressCompanion incoming) async {
    final bookId = incoming.bookId.value;
    final existing = await progressOf(bookId);
    if (existing == null) {
      await db.into(db.progress).insert(incoming);
      return true;
    }
    if (!_advances(incoming, existing)) return false;
    await db.into(db.progress).insertOnConflictUpdate(incoming);
    return true;
  }

  static bool _advances(ProgressCompanion incoming, ReadingProgress existing) =>
      ProgressPosition(
        chapterIndex: incoming.chapterIndex.present
            ? incoming.chapterIndex.value
            : null,
        textOffset: incoming.textOffset.present ? incoming.textOffset.value : 0,
        updatedAt: incoming.updatedAt.present ? incoming.updatedAt.value : 0,
      ).advancesFrom(
        ProgressPosition(
          chapterIndex: existing.chapterIndex,
          textOffset: existing.textOffset,
          updatedAt: existing.updatedAt,
        ),
      );

  // --- Replace rules (D8) --------------------------------------------------

  /// Merges on `(name, pattern, replacement)` and keeps the existing id.
  Future<ReplaceRule> putReplaceRule(ReplaceRulesCompanion rule) async {
    final existing =
        await (db.select(db.replaceRules)..where(
              (r) =>
                  r.name.equals(rule.name.value) &
                  r.pattern.equals(rule.pattern.value) &
                  r.replacement.equals(
                    rule.replacement.present ? rule.replacement.value : '',
                  ),
            ))
            .getSingleOrNull();
    final row = existing == null ? rule : rule.copyWith(id: Value(existing.id));
    await db.into(db.replaceRules).insertOnConflictUpdate(row);
    final stored = db.select(db.replaceRules)
      ..where((r) => r.id.equals(row.id.value));
    return stored.getSingle();
  }

  Future<List<ReplaceRule>> replaceRules() =>
      (db.select(db.replaceRules)..orderBy([
            (r) => OrderingTerm(expression: r.ruleOrder),
            (r) => OrderingTerm(expression: r.id),
          ]))
          .get();

  // --- Local library -------------------------------------------------------

  Future<LocalRoot> putLocalRoot(LocalRootsCompanion root) async {
    await db.into(db.localRoots).insertOnConflictUpdate(root);
    final stored = db.select(db.localRoots)
      ..where((r) => r.id.equals(root.id.value));
    return stored.getSingle();
  }

  Future<List<LocalRoot>> allLocalRoots() => db.select(db.localRoots).get();

  Future<LocalFile> putLocalFile(LocalFilesCompanion file) async {
    await db.into(db.localFiles).insertOnConflictUpdate(file);
    final stored = db.select(db.localFiles)
      ..where(
        (f) =>
            f.rootId.equals(file.rootId.value) &
            f.relativePath.equals(file.relativePath.value),
      );
    return stored.getSingle();
  }

  Future<List<LocalFile>> localFilesOf(String rootId) =>
      (db.select(db.localFiles)..where((f) => f.rootId.equals(rootId))).get();

  // --- Settings ------------------------------------------------------------

  /// Space-global when [bookId] is empty, a per-book override otherwise.
  Future<void> putSetting(
    String key,
    String value, {
    String bookId = '',
  }) async {
    await db
        .into(db.settings)
        .insertOnConflictUpdate(
          SettingsCompanion.insert(
            bookId: Value(bookId),
            key: key,
            value: value,
            updatedAt: Value(DateTime.now().toUtc().millisecondsSinceEpoch),
          ),
        );
  }

  Future<String?> setting(String key, {String bookId = ''}) async {
    final row =
        await (db.select(db.settings)
              ..where((s) => s.bookId.equals(bookId) & s.key.equals(key)))
            .getSingleOrNull();
    return row?.value;
  }
}
