import 'dart:convert';

import 'package:drift/drift.dart';

import 'database.dart';
import 'ids.dart';
import 'progress.dart';

/// One line-start anchor the text engine produced: the byte offset, the UTF-16
/// code-unit offset and the line index of the same position. Named here rather
/// than imported from the bridge so the store can describe its own rows without
/// depending on the native library.
typedef TextIndexAnchor = ({int byteOffset, int codeUnitOffset, int lineIndex});

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

  /// Stores a Book Source the way Legado hands it over: the typed fields this
  /// product reads, plus the whole object in `raw`, so fields this build does
  /// not know survive a round trip (D7).
  ///
  /// [fallbackId] keys a source that arrived without a `bookSourceUrl` — an
  /// import's own record id, as D7's key has to be the source's URL.
  Future<BookSource> putSourceJson(
    Map<String, dynamic> source, {
    String? fallbackId,
  }) {
    return putSource(_sourceCompanion(source, fallbackId: fallbackId));
  }

  /// Stores many Book Sources in one batch, with [putSourceJson]'s mapping.
  ///
  /// A migration brings thousands at once, and one statement per row is most of
  /// its runtime: measured on the operator's own backup (8 787 sources), the
  /// per-row upserts took 14.0 s of a 20.7 s import; the batch does the same rows
  /// in one statement.
  Future<void> putSourceJsons(Iterable<Map<String, dynamic>> sources) async {
    final rows = <SourcesCompanion>[
      for (final source in sources) _sourceCompanion(source),
    ];
    if (rows.isEmpty) return;
    await db.batch(
      (batch) => batch.insertAllOnConflictUpdate(db.sources, rows),
    );
  }

  static SourcesCompanion _sourceCompanion(
    Map<String, dynamic> source, {
    String? fallbackId,
  }) {
    final declared = '${source['bookSourceUrl'] ?? ''}';
    final url = declared.isEmpty ? (fallbackId ?? '') : declared;
    return SourcesCompanion.insert(
      bookSourceUrl: url,
      name: '${source['bookSourceName'] ?? url}',
      groupNames: Value(jsonEncode(_groupNames(source['bookSourceGroup']))),
      type: Value(_legacyInt(source['bookSourceType'])),
      customOrder: Value(_legacyInt(source['customOrder'])),
      enabled: Value(source['enabled'] as bool? ?? true),
      enabledExplore: Value(source['enabledExplore'] as bool? ?? true),
      lastUpdateTime: Value(_legacyInt(source['lastUpdateTime'])),
      raw: Value(jsonEncode(source)),
    );
  }

  /// Legado joins a source's groups into a `HashSet` and serializes that
  /// comma-joined, so the order is not meaningful and duplicates are not
  /// either.
  static List<String> _groupNames(Object? value) {
    final names = switch (value) {
      String joined => joined.split(','),
      List<Object?> list => list.map((entry) => '$entry'),
      _ => const <String>[],
    };
    return names
        .map((name) => name.trim())
        .where((name) => name.isNotEmpty)
        .toSet()
        .toList();
  }

  /// A Legado field read as an int: its JSON is not typed consistently.
  static int _legacyInt(Object? value) =>
      value is num ? value.toInt() : int.tryParse('${value ?? ''}') ?? 0;

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

  /// A network book whose source reference is absent. SQLite NULLs are not
  /// equal in a unique key, so the migration's empty-origin identity uses the
  /// URL explicitly to remain idempotent.
  Future<ShelfBook?> bookWithoutSource(String sourceBookUrl) =>
      (db.select(db.books)..where(
            (b) => b.sourceRef.isNull() & b.sourceBookUrl.equals(sourceBookUrl),
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
  ///
  /// [hasSource] narrows to the books a Book Source can open (`true`) or to the
  /// rows no source resolves (`false`).
  Future<List<ShelfBook>> shelf({
    String? kind,
    bool? hasSource,
    bool ungrouped = false,
  }) {
    final query = db.select(db.books)..where((b) => b.shelved.equals(true));
    if (kind != null) query.where((b) => b.kind.equals(kind));
    if (hasSource == true) query.where((b) => b.sourceRef.isNotNull());
    if (hasSource == false) query.where((b) => b.sourceRef.isNull());
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

  /// Shelf membership is a flag, not a deletion: removing a book keeps its
  /// row, its chapters and its progress (D2's `shelved`; the JSON store kept
  /// the record's position for the same reason).
  Future<void> setShelved(String bookId, bool shelved) async {
    await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(shelved: Value(shelved)),
    );
  }

  /// Flags or clears a book's relink state: the flag describes the file behind
  /// the book, so it is an update of a row that is already there (D4).
  Future<void> setBookRelink(String bookId, bool needsRelink) async {
    await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(needsRelink: Value(needsRelink)),
    );
  }

  /// Stores the charset a local book's file was detected as: the encoding its
  /// windows are decoded with (`books.charset`, D2's field set). An update like
  /// the relink flag's, because the file is indexed after the book is admitted.
  Future<void> setBookCharset(String bookId, String charset) async {
    await (db.update(db.books)..where((b) => b.id.equals(bookId))).write(
      BooksCompanion(charset: Value(charset)),
    );
  }

  /// The next free position: `bookOrder` is one int per book per space (D3),
  /// and a book added to the shelf goes to the end of it.
  Future<int> nextBookOrder() async {
    final position = db.books.bookOrder.max();
    final row = await (db.selectOnly(
      db.books,
    )..addColumns([position])).getSingle();
    return (row.read(position) ?? -1) + 1;
  }

  /// The local files admitted to the shelf, in the order they were added.
  Future<List<ShelfBook>> localBooks() =>
      (db.select(db.books)
            ..where(
              (b) =>
                  b.kind.equals('local') &
                  b.rootId.isNotNull() &
                  b.relativePath.isNotNull(),
            )
            ..orderBy([
              (b) => OrderingTerm(expression: b.bookOrder),
              (b) => OrderingTerm(expression: b.id),
            ]))
          .get();

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

  /// Stores a group a migration brings over: the name is the key (D3), so a
  /// re-import joins the group the space already has instead of making a second
  /// one, and the frozen row's own order and display flags come with it — a
  /// shelf ordered by a minted id is not the shelf the user had.
  ///
  /// [ensureGroup] stays the product's own path: a name, and nothing to say
  /// about it beyond that.
  Future<ShelfGroup> putGroup(GroupsCompanion group) async {
    final name = group.name.value.trim();
    if (name.isEmpty)
      throw ArgumentError.value(group.name.value, 'name', '分组名不能为空');
    final existing = await groupByName(name);
    final row =
        (existing == null ? group : group.copyWith(id: Value(existing.id)))
            .copyWith(name: Value(name));
    await db.into(db.groups).insertOnConflictUpdate(row);
    return (await groupByName(name))!;
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

  /// The most recently written position in the space: what "continue reading"
  /// resumes, where the JSON store kept a single `last` pointer.
  Future<ReadingProgress?> latestProgress() =>
      (db.select(db.progress)
            ..orderBy([
              (p) => OrderingTerm(
                expression: p.updatedAt,
                mode: OrderingMode.desc,
              ),
              (p) => OrderingTerm(expression: p.bookId),
            ])
            ..limit(1))
          .getSingleOrNull();

  /// The live writer's write: where the reader is, going back included.
  ///
  /// [saveProgress]'s forward-only rule is the *merge* rule (D6's import, D4's
  /// migration alignment); a reader that went back a chapter still has to find
  /// itself there when it reopens the book. A companion that leaves a column out
  /// keeps that column's value, which is how the reader's five-field writer
  /// (`LocalLibrary.saveProgressRecord`) and the coarse offset writer
  /// (`LocalLibrary.updateOffset`) can both write this row.
  Future<void> putProgress(ProgressCompanion progress) =>
      db.into(db.progress).insertOnConflictUpdate(progress);

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

  /// Replaces a file's sparse index with [anchors] in one transaction.
  ///
  /// The index describes one version of a file, so a rebuild replaces it whole:
  /// a half-written index would let the reader seek to an anchor that describes
  /// other bytes, and D4's restore tiers assume the anchors and the file agree.
  /// [textIndexOf] is the read side the reader seeks with.
  Future<void> putTextIndex(
    String rootId,
    String relativePath,
    List<TextIndexAnchor> anchors,
  ) async {
    await db.transaction(() async {
      await (db.delete(db.textIndex)..where(
            (t) =>
                t.rootId.equals(rootId) & t.relativePath.equals(relativePath),
          ))
          .go();
      await db.batch(
        (batch) => batch.insertAll(db.textIndex, [
          for (final anchor in anchors)
            TextIndexCompanion.insert(
              rootId: rootId,
              relativePath: relativePath,
              byteOffset: anchor.byteOffset,
              codeUnitOffset: anchor.codeUnitOffset,
              lineIndex: anchor.lineIndex,
            ),
        ]),
      );
    });
  }

  /// The sparse anchors of one local file, in file order — the seek the reader
  /// and the restore tiers do (D4). [putTextIndex] is the same rows' other half.
  Future<List<TextIndexAnchor>> textIndexOf(
    String rootId,
    String relativePath,
  ) async {
    final rows =
        await (db.select(db.textIndex)
              ..where(
                (t) =>
                    t.rootId.equals(rootId) &
                    t.relativePath.equals(relativePath),
              )
              ..orderBy([(t) => OrderingTerm(expression: t.byteOffset)]))
            .get();
    return [
      for (final row in rows)
        (
          byteOffset: row.byteOffset,
          codeUnitOffset: row.codeUnitOffset,
          lineIndex: row.lineIndex,
        ),
    ];
  }

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

  /// One local file by its natural key.
  Future<LocalFile?> localFile(String rootId, String relativePath) =>
      (db.select(db.localFiles)..where(
            (f) =>
                f.rootId.equals(rootId) & f.relativePath.equals(relativePath),
          ))
          .getSingleOrNull();

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
