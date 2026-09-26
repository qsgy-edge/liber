import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';

import 'package:sqlite3/common.dart' show CommonDatabase;

import 'migrations.dart';
import 'schema_versions.dart';

part 'database.g.dart';

/// The space database: one SQLite file per space
/// (`%APPDATA%\Liber\spaces\<spaceId>\data.db`).
///
/// The tables are the shape `docs/user-data-contract.md` (D3–D9) fixes, and
/// this class is that schema's single source of truth. Three rules follow from
/// the contract and are visible throughout:
///
/// * imported objects keep the fields this build does not read in `raw` JSON
///   columns, so a round trip loses nothing;
/// * unknown shapes are relational rather than bitmasks (groups, memberships,
///   progress), so the shelf's queries are SQL;
/// * an id is minted once and never derived from a mutable fact, while the
///   natural keys (`sources.bookSourceUrl`, `books.sourceRef` +
///   `books.sourceBookUrl`, `local_roots.id` + `local_files.relativePath`) are
///   what import and re-search match on.
///
/// Column names avoid SQL reserved words (`book_order`, `group_order`,
/// `rule_order`, `group_name`); the field names are the documents' names.
@DataClassName('BookSource')
class Sources extends Table {
  /// Legado's own primary key, and the space-local key a book's `sourceRef`
  /// resolves against (`docs/user-data-contract.md` D7).
  TextColumn get bookSourceUrl => text()();

  TextColumn get name => text()();

  /// Legado keeps this as a comma-joined `HashSet`, so order is not meaningful
  /// and this is a JSON array of names.
  TextColumn get groupNames => text().withDefault(const Constant('[]'))();

  IntColumn get type => integer().withDefault(const Constant(0))();

  IntColumn get customOrder => integer().withDefault(const Constant(0))();

  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  BoolColumn get enabledExplore =>
      boolean().withDefault(const Constant(true))();

  IntColumn get lastUpdateTime => integer().withDefault(const Constant(0))();

  /// The imported object as it arrived, unknown fields included.
  TextColumn get raw => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookSourceUrl};
}

@TableIndex(
  name: 'books_natural_key',
  columns: {#sourceRef, #sourceBookUrl},
  unique: true,
)
@TableIndex(
  name: 'books_local_key',
  columns: {#rootId, #relativePath},
  unique: true,
)
@TableIndex(name: 'books_shelf_order', columns: {#shelved, #kind, #bookOrder})
@DataClassName('ShelfBook')
class Books extends Table {
  /// Minted space-local id: the primary key, so a source change does not
  /// rewrite a book's identity (D2).
  TextColumn get id => text()();

  /// `network` or `local`. The frozen baseline overloads `Book.origin` with
  /// `loc_book`; this is explicit instead (D2).
  TextColumn get kind => text().withDefault(const Constant('network'))();

  /// The space-local Book Source key; null for a book whose source is unknown.
  TextColumn get sourceRef => text().nullable()();

  /// With `sourceRef`, the natural key import and re-search match on. Null for
  /// local books, whose natural key is `rootId` + `relativePath`.
  TextColumn get sourceBookUrl => text().nullable()();

  TextColumn get title => text()();

  TextColumn get author => text().withDefault(const Constant(''))();

  /// Denormalized so a deleted or renamed source does not blank the shelf.
  TextColumn get originName => text().withDefault(const Constant(''))();

  /// Legado's book type flags.
  IntColumn get type => integer().withDefault(const Constant(0))();

  TextColumn get customTag => text().withDefault(const Constant(''))();

  TextColumn get coverUrl => text().withDefault(const Constant(''))();

  TextColumn get customCoverUrl => text().withDefault(const Constant(''))();

  TextColumn get intro => text().withDefault(const Constant(''))();

  TextColumn get customIntro => text().withDefault(const Constant(''))();

  TextColumn get charset => text().withDefault(const Constant(''))();

  TextColumn get latestChapterTitle => text().withDefault(const Constant(''))();

  IntColumn get latestChapterTime => integer().withDefault(const Constant(0))();

  IntColumn get totalChapterNum => integer().withDefault(const Constant(0))();

  BoolColumn get canUpdate => boolean().withDefault(const Constant(true))();

  IntColumn get lastCheckTime => integer().withDefault(const Constant(0))();

  IntColumn get lastCheckCount => integer().withDefault(const Constant(0))();

  /// One int per book per space; the shelf's order (D3).
  IntColumn get bookOrder => integer().withDefault(const Constant(0))();

  /// Opaque per-book variables.
  TextColumn get variable => text().nullable()();

  /// Shelf membership. Removing a book keeps its row, its chapters and its
  /// progress — the product's behavior today — so membership has to be a flag
  /// rather than a deletion.
  BoolColumn get shelved => boolean().withDefault(const Constant(true))();

  // Local books (D2/D4).
  TextColumn get rootId => text().nullable()();

  TextColumn get relativePath => text().nullable()();

  TextColumn get format => text().nullable()();

  BoolColumn get needsRelink => boolean().withDefault(const Constant(false))();

  /// The imported object as it arrived, unknown fields included.
  TextColumn get raw => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'groups_name', columns: {#name}, unique: true)
@DataClassName('ShelfGroup')
class Groups extends Table {
  TextColumn get id => text()();

  /// Trimmed, non-empty, and unique per space (D3).
  TextColumn get name => text()();

  TextColumn get cover => text().withDefault(const Constant(''))();

  IntColumn get groupOrder => integer().withDefault(const Constant(0))();

  BoolColumn get enableRefresh => boolean().withDefault(const Constant(true))();

  BoolColumn get show => boolean().withDefault(const Constant(true))();

  /// Sort mode; `-1` means "use the space default".
  IntColumn get bookSort => integer().withDefault(const Constant(-1))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'book_groups_group', columns: {#groupId, #bookId})
class BookGroups extends Table {
  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  TextColumn get groupId =>
      text().references(Groups, #id, onDelete: KeyAction.cascade)();

  @override
  Set<Column> get primaryKey => {bookId, groupId};
}

@TableIndex(name: 'chapters_toc_order', columns: {#bookId, #chapterIndex})
@DataClassName('BookChapter')
class Chapters extends Table {
  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  /// Stable per book: a network chapter's URL, or a local chapter's start
  /// offset. Progress refers to this rather than to a position in the TOC,
  /// which drifts when the TOC changes (D4).
  TextColumn get chapterKey => text()();

  TextColumn get name => text()();

  TextColumn get url => text().nullable()();

  IntColumn get chapterIndex => integer()();

  /// The frozen `ruleToc.updateTime` value: the chapter's own extra information
  /// (`BookChapter.tag`), null when the source declares no such rule or the rule
  /// matched nothing.
  TextColumn get tag => text().nullable()();

  /// A volume heading rather than a readable chapter (`ruleToc.isVolume`).
  BoolColumn get isVolume => boolean().withDefault(const Constant(false))();

  /// A chapter the source marks as VIP (`ruleToc.isVip`).
  BoolColumn get isVip => boolean().withDefault(const Constant(false))();

  /// A chapter the source marks as already paid for (`ruleToc.isPay`).
  BoolColumn get isPay => boolean().withDefault(const Constant(false))();

  /// Opaque per-chapter variables.
  TextColumn get variable => text().nullable()();

  @override
  Set<Column> get primaryKey => {bookId, chapterKey};
}

/// Sparse byte ↔ code-unit anchors at line starts, per local file (D4/D10).
///
/// The key is the file, not the shelf book: the index describes a file, and a
/// library file that is not admitted to the shelf has nowhere else to live.
@DataClassName('TextIndexEntry')
class TextIndex extends Table {
  TextColumn get rootId =>
      text().references(LocalRoots, #id, onDelete: KeyAction.cascade)();

  TextColumn get relativePath => text()();

  IntColumn get byteOffset => integer()();

  IntColumn get codeUnitOffset => integer()();

  IntColumn get lineIndex => integer()();

  @override
  Set<Column> get primaryKey => {rootId, relativePath, byteOffset};

  @override
  List<String> get customConstraints => [
    'FOREIGN KEY (root_id, relative_path) '
        'REFERENCES local_files(root_id, relative_path) ON DELETE CASCADE',
  ];
}

/// The five-field progress record (D4) plus the timestamp that breaks ties when
/// two records describe the same position.
/// The anchor keeps the line's first code units verbatim rather than a hash of
/// them (D4's wording): the tolerant restore tiers have to relocate and search
/// for that text, and a hash cannot be searched for. The 32-unit cap is the
/// writer's.
@DataClassName('ReadingProgress')
class Progress extends Table {
  TextColumn get bookId =>
      text().references(Books, #id, onDelete: KeyAction.cascade)();

  /// The authoritative absolute code-unit offset.
  IntColumn get textOffset => integer().withDefault(const Constant(0))();

  /// Display and tolerant restore; the sparse index is anchored at line starts
  /// already, so these cost nothing extra.
  IntColumn get lineIndex => integer().withDefault(const Constant(0))();

  IntColumn get offsetInLine => integer().withDefault(const Constant(0))();

  /// The file length the offset was written against; the percentage fallback.
  IntColumn get textLength => integer().withDefault(const Constant(0))();

  /// TOC navigation and migration alignment, when the book is chaptered.
  TextColumn get chapterKey => text().nullable()();

  IntColumn get chapterIndex => integer().nullable()();

  /// The first code units of the current line, kept verbatim so the tolerant
  /// restore tiers can compare, relocate and search for it.
  TextColumn get anchor => text().nullable()();

  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bookId};
}

@TableIndex(
  name: 'replace_rules_merge_key',
  columns: {#name, #pattern, #replacement},
  unique: true,
)
@TableIndex(name: 'replace_rules_order', columns: {#ruleOrder})
class ReplaceRules extends Table {
  TextColumn get id => text()();

  TextColumn get name => text()();

  /// Legado's `group` field: the single group name a rule belongs to.
  TextColumn get groupName => text().withDefault(const Constant(''))();

  TextColumn get pattern => text()();

  TextColumn get replacement => text().withDefault(const Constant(''))();

  TextColumn get scope => text().nullable()();

  TextColumn get excludeScope => text().nullable()();

  BoolColumn get scopeTitle => boolean().withDefault(const Constant(false))();

  BoolColumn get scopeContent => boolean().withDefault(const Constant(true))();

  BoolColumn get isEnabled => boolean().withDefault(const Constant(true))();

  BoolColumn get isRegex => boolean().withDefault(const Constant(true))();

  IntColumn get timeoutMillisecond =>
      integer().withDefault(const Constant(0))();

  IntColumn get ruleOrder => integer().withDefault(const Constant(0))();

  /// The imported object as it arrived, unknown fields included.
  TextColumn get raw => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('LocalRoot')
class LocalRoots extends Table {
  /// Stable: the lowercased absolute path, so re-authorizing the same root
  /// keeps the shelf and the progress (ADR 0006).
  TextColumn get id => text()();

  TextColumn get displayName => text()();

  BoolColumn get needsRelink => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {id};
}

@TableIndex(name: 'local_files_book', columns: {#bookId})
@DataClassName('LocalFile')
class LocalFiles extends Table {
  TextColumn get rootId =>
      text().references(LocalRoots, #id, onDelete: KeyAction.cascade)();

  TextColumn get relativePath => text()();

  TextColumn get format => text().withDefault(const Constant('txt'))();

  /// Cached decoded length: nothing reads a whole file to clamp an offset (D4).
  IntColumn get textLength => integer().nullable()();

  /// Cached modification time; with `textLength` it decides whether the file is
  /// unchanged, edited in place, or replaced.
  IntColumn get modifiedAt => integer().nullable()();

  BoolColumn get needsRelink => boolean().withDefault(const Constant(false))();

  /// The shelf book this file is admitted as, when it is on the shelf.
  TextColumn get bookId =>
      text().nullable().references(Books, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column> get primaryKey => {rootId, relativePath};
}

/// Reading settings: one value per key, space-global when `bookId` is empty and
/// a per-book override otherwise (D2's reading-settings shape).
@DataClassName('SpaceSetting')
class Settings extends Table {
  TextColumn get bookId => text().withDefault(const Constant(''))();

  TextColumn get key => text()();

  TextColumn get value => text()();

  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {bookId, key};
}

/// The cookies one space's sources hold, keyed the way the frozen baseline keys
/// them: the registrable domain (eTLD+1) of the site a cookie was set for, or
/// the IP literal itself (ADR 0011 §3).
///
/// `writerRef` names the source that wrote a pair when a source wrote it — that
/// is how a source may still read and send a pair under another site's key —
/// while a pair no source wrote belongs to the site itself and every source of
/// that site sees it.
@DataClassName('StoredCookie')
class SourceCookies extends Table {
  TextColumn get domain => text()();

  TextColumn get name => text()();

  TextColumn get value => text()();

  TextColumn get writerRef => text().nullable()();

  @override
  Set<Column> get primaryKey => {domain, name};
}

/// What one source's scripts wrote for themselves: `cache.*` entries and the
/// per-source variables `java.put`/`java.get` share with `source.put`/
/// `source.get` (ADR 0011 §3).
///
/// `sourceRef` is the owning source, so another source neither reads nor
/// overwrites the row; `value` is JSON text because a cache value is any JSON
/// value; `expiresAt` is the deadline a `saveTime` produces, and 0 means the
/// entry does not expire, which is how the frozen `CacheManager` reads a
/// `saveTime` of 0.
///
/// One source's rows are bounded (#37, ADR 0011 §3): `SpaceHostStatePersistence`
/// caps each of its two buckets — the `cache.*` entries and the
/// `java.put`/`java.get` variables — and a write past a bucket's cap evicts
/// that bucket's least recently written rows. [writtenAt] is the order that
/// eviction reads; it is not a read-recency stamp, because a read must not
/// write (a `cache.get` on the request path stays a read).
@DataClassName('StoredSourceEntry')
class SourceEntries extends Table {
  TextColumn get sourceRef => text()();

  TextColumn get key => text()();

  TextColumn get value => text().nullable()();

  IntColumn get expiresAt => integer().withDefault(const Constant(0))();

  /// The instant this row was last written (milliseconds since the epoch).
  /// A v4 row has no instant and defaults to 0, which sorts before any v5
  /// write, so it is the first evicted.
  IntColumn get writtenAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sourceRef, key};
}

/// The per-source, per-host TLS exceptions a user has confirmed (ADR 0011 §5).
///
/// A row exists only because a person answered the confirmation for that one
/// source and host; the transport reads it before it decides whether a
/// certificate-verification failure may be continued past. Keyed by both, so an
/// exception never applies to another source or another host.
@DataClassName('StoredTlsException')
class SourceTlsExceptions extends Table {
  TextColumn get sourceRef => text()();

  TextColumn get host => text()();

  @override
  Set<Column> get primaryKey => {sourceRef, host};
}

@DriftDatabase(
  tables: [
    Sources,
    Books,
    Groups,
    BookGroups,
    Chapters,
    TextIndex,
    Progress,
    ReplaceRules,
    LocalRoots,
    LocalFiles,
    Settings,
    SourceCookies,
    SourceEntries,
    SourceTlsExceptions,
  ],
)
class SpaceDatabase extends _$SpaceDatabase {
  /// A database over an existing executor (an in-memory one in tests).
  SpaceDatabase(super.executor);

  /// The space's SQLite file, opened in a background isolate.
  SpaceDatabase.file(File file)
    : super(NativeDatabase.createInBackground(file, setup: _waitOutLocks));

  @override
  int get schemaVersion => latestVersion;

  /// The schema version this build writes. Each released version has a snapshot
  /// in `drift_schemas/` and a step in `schema_versions.dart`.
  static const latestVersion = 6;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      await m.createAll();
    },
    onUpgrade: (m, from, to) async {
      if (from > to) {
        throw StateError('space 数据库版本 v$from 高于本构建支持的 v$to，拒绝降级读取');
      }
      // Forward-only steps, one per released version, generated from the
      // snapshots in `drift_schemas/` by `drift_dev schema steps`. Data work a
      // step needs runs before it, while the old shape is still in place.
      if (from < 2) await mergeDuplicateNaturalKeys(m);
      // v2 → v3 only creates the host-surface tables (ADR 0011 §3): there is no
      // old shape to migrate data out of, so the step is the generated one.
      // v3 → v4 only creates the TLS-exception table (ADR 0011 §5), likewise.
      // v4 → v5 adds `source_entries.written_at`, the per-source eviction order
      // (#37).
      // v5 → v6 adds the table-of-contents markers (`chapters.tag`,
      // `is_volume`, `is_vip`, `is_pay`, #13).
      await stepByStep(
        from1To2: migrateToV2,
        from2To3: migrateToV3,
        from3To4: migrateToV4,
        from4To5: migrateToV5,
        from5To6: migrateToV6,
      )(m, from, to);
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
      if (details.wasCreated) {
        await customStatement('PRAGMA journal_mode = WAL');
      }
    },
  );
}

/// Waits out a transient lock instead of failing the open: every connection to
/// a space's file sets a busy timeout before its first statement.
///
/// Two connections to one space exist in practice — a second app instance, or an
/// in-process restart whose previous store is still closing — and without a busy
/// timeout SQLite answers SQLITE_BUSY (`SqliteException(5): database is locked`)
/// the moment a lock is held. The statement that meets it is drift's own
/// `PRAGMA user_version` read, which runs at connection setup, *before*
/// `beforeOpen`: the failure is then the whole open, the space reads as
/// unavailable, and the reader gets a dead screen. #109 measured that as 4 of 15
/// red CI runs (and reproduced it under load); five seconds outlasts any lock our
/// own close or a second instance holds and still fails on a stuck file.
void _waitOutLocks(CommonDatabase database) {
  database.execute('PRAGMA busy_timeout = 5000');
}
