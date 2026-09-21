# Liber User Data Contract

**Status:** settled in ticket #16 (2026-09-15) and recorded as ADR 0007. Each decision below
carries the alternatives it rejected; implementation follows separately.

Inputs: ADR 0006 (principles), ADR 0007 (this contract's decision record),
`docs/compatibility/legado-data-migration-contract.md` (import envelope), and the three
stores the product writes today.

## 1. Fixed constraints

These are not open, they come from ADR 0006 and from decisions already taken:

1. The product owns its user data as a versioned contract — never Legado's Room tables,
   backup ZIP layout, or Android paths.
2. Stable IDs for a library root and for each book.
3. Reading progress is a code-unit text offset, not a layout-dependent position.
4. Import is idempotent; progress only advances; local files are flagged for relinking;
   bytes, cookies, caches, and downloaded content are never imported, and the losses are
   reported.
5. No bitmask groups. Legado's `Long` mask caps at 64 groups, its membership queries are
   unindexable, and bit 63 is unreachable through its own shelf queries.
6. **One store per space** (decided 2026-09-15, ticket #16): a space's identity *is* the
   store's identity, so no query spans spaces and a whole space can later be encrypted as
   a unit. The private-shelf feature is out of scope; this seam is what makes it additive.

## 2. What the contract owns, and where it lives today

| Entity | Today | Shape |
|---|---|---|
| Imported Book Sources | not persisted (repo fixtures) | — |
| Replace rules | absent | — |
| Shelf book (network) | `%APPDATA%\Liber\online_reading.json` v2 | `{version, last, records[]}` |
| Shelf book (imported) | `%APPDATA%\Liber\migration_state.json` | `{sources[], books[]}` |
| Local library root/book | `%APPDATA%\Liber\local_books.json` | `{root, books[]}` |
| Groups, ordering | absent | — |
| TOC / chapters | inline in the online record | `chapters: [{name, url}]` |
| Chapter content cache | absent | — |

Three stores, three identity schemes (`jsonEncode([bookSourceUrl, bookUrl])`, a lowercased
absolute path, and `bookUrl ?? bookId ?? name ?? hashCode`), and only one of them carries a
version field.

**Storage note (2026-09-16).** The three files above stopped being the live store in ticket
#24: the shelf, the local library and the migration page read and write the space's database,
the three files were imported into the default space once and renamed aside under `legacy\`,
and their readers are gone. This table and the code citations below record what the contract
was written against; D1–D9 describe the store that replaced it.

## 3. Decisions

### D1 — One store or three, and one space owning everything *decided: the space owns everything, sources included*

Everything user-generated lives **inside the space**: Book Sources, replace rules, shelf
books, groups, ordering, TOC, progress, local library roots and files, and reading
settings. Installation level holds only the space registry and UI-level preferences
(theme, language).

*Why:* a space has to open as an isolated unit — that is what makes a private space, and
its later encryption, meaningful. A shared source list leaks which sites a private space
reads (source URLs are themselves sensitive), and a book's `sourceRef` must resolve inside
its own space.

*Consequence:* importing sources and rules is a per-space action, a new space starts
empty, and a later "copy sources and rules from another space" helper is an explicit user
action rather than a hidden link.

*Rejected:* the two-tier split (shared sources and rules) considered in the first draft of
this document; and the current three files kept as three independent formats.

### D2 — Book identity and persisted field set *decided: minted id, natural-key match, explicit kind*

**Identity.** A minted, space-local `id` is the primary key; the natural key
`(sourceRef, sourceBookUrl)` is what import and re-search match on; `(name, author)` is a
secondary hint that is only ever *proposed* to the user, never merged silently.

*Rejected:* `(sourceRef, sourceBookUrl)` as the primary key (replacing a book's source
would rewrite its identity and cascade into every reference), and a content hash (the same
book legitimately exists per source).

**Field set.** Keep, per book: `title`, `author`, `sourceRef`, `originName`, `kind` (`network`
or `local`), `type` flags, `customTag`, `coverUrl`, `customCoverUrl`, `intro`, `customIntro`,
`charset`, `latestChapterTitle`, `latestChapterTime`, `totalChapterNum`, `canUpdate`,
`lastCheckTime`, `lastCheckCount`, `order`, `variable` (opaque), and for local books
`rootId`, `relativePath`, `format`, `needsRelink`. `sourceRef` is the space-local Book Source
key (`bookSourceUrl`) — the frozen baseline's `Book.origin`, which overloads that field with
`loc_book` for local books, hence an explicit `kind` instead. `originName` stays denormalized
so a deleted or renamed source does not blank the shelf, exactly as the baseline keeps it.

*Dropped, with reasons:* `syncTime` (only WebDAV sync reads it — `AppWebDav.kt:250,313,326` —
and cloud sync is out of scope); `originOrder` (a cached copy of the source's `customOrder`,
set at `BookList.kt:163`; with SQL a join replaces it); `downloadUrls`, `infoHtml`, and
`tocHtml` (the baseline does not persist them either — `@Ignore`).

*Relocated, not dropped:* the per-book reading config (the baseline's `Book.ReadConfig`:
`reverseToc`, `pageAnim`, `reSegment`, `imageStyle`, `useReplaceRule`, `delTag`, `ttsEngine`,
`splitLongChapter`, `readSimulating`, `startDate`, `startChapter`, `dailyChapters`) is not a
column on the book. It becomes the reading-settings shape — global file plus per-book
override, as the baseline does — and stays in the map's fog. Its behavioral flags are
load-bearing for compatibility: `useReplaceRule` (#17), `reSegment`, `splitLongChapter`
(D4's cap), `delTag` and `imageStyle` in content processing.

### D3 — Groups and ordering *decided: relational, synthetic views as queries*

Relational, never a mask:

- `groups: [{id, name, cover, order, enableRefresh, show, bookSort}]` — identity is the
  minted `id`, so rename is free; names are trimmed, non-empty, and unique per space.
- Membership is a list of group ids on the book.
- Synthetic views are queries, not rows: **all**, **local**, **ungrouped**,
  **update-error**. Legado stores the last four as rows with magic negative ids
  (`BookGroup.kt`), which is why its shelf SQL is a tree of `groupId = -N` branches.
- Ordering: one `order` int per book per space; per-group `bookSort` is a sort mode with
  `-1` meaning "use the space default".
- Import merge is by name (the migration contract already fixes this): a name that matches
  joins, a new name creates, membership unions.

### D4 — Progress, chapters, and local chaptering *decided: paging, five-field progress, tiered restore*

- **Progress is a five-field record, not a bare offset.** Per book: `text_offset` (the
  authoritative absolute code-unit offset, ADR 0006's semantics), `line_index` +
  `offset_in_line` (display and tolerant restore), `text_length` (percentage fallback),
  `chapter_key`/`chapter_index` (TOC navigation and migration alignment, when chaptered),
  and `anchor` (the first ≤32 code units of the current line, stored verbatim so the tolerant
  tiers can compare it as a prefix — corrected 2026-09-16, see below). `(chapterIndex,
  textOffset)` comparison decides "advances only" and the timestamp breaks ties. The line
  fields cost nothing extra: the sparse index used for window lookup is already anchored at
  line starts.
- **Ownership of the offset (ADR 0012).** The reading module treats `text_offset` as opaque: it
  stores the value and hands it back to whoever produced the text space — a format for a
  file-backed book, a source for a network chapter — and `chapter_key` names the reading unit,
  with a chapterless file being one implicit chapter. No later format may fork this record:
  a format that needs a different *field set* takes its own ADR and a generated migration test
  with it, while which text space the values live in stays the format's own business.
- **Restore is tiered**, because a local file can be edited, re-encoded, or replaced:
  1. exact — `text_length` matches and `anchor` matches at `text_offset`;
  2. near — relocate the anchor within ±N lines using the line index;
  3. search — one streaming, index-assisted pass to find the anchor in the file;
  4. fallback — the stored `line_index`, then the percentage, reporting the change to the
     reader instead of silently jumping. Restore additionally snaps to the start of a line or
     paragraph for display.
- **A line alone is not a position.** Chinese web novels routinely contain paragraphs of
  thousands of code units with no line break, so the intra-line offset stays.
- **File change detection feeds `needsRelink`.** `text_length` + modification time + the
  anchor decide whether a local file is unchanged, edited in place, or replaced; a missing
  path is only the loudest case.
- *Compared with the frozen baseline:* it stores `durChapterIndex` + `durChapterPos`
  (`Book.kt:96,99`) — coarse anchor plus fine offset — but its chapter index drifts when the
  TOC changes, which the migration contract works around by only ever advancing progress.
  This record keeps the coarse anchor as a stable `chapter_key` and adds the line's own
  prefix as the fine anchor.
- *Progress stays in the raw file's space when replace rules render the page (#47).* The
  frozen reader applies the user's replace rules per materialised chapter and stores
  `durChapterPos` as an index into the **processed** chapter (`ReadBook.kt:416,426`;
  `ChapterProvider.kt:628-630`), so a rule change moves what a stored position means. This
  record stays in the file's raw code-unit space: `text_offset`, `line_index`,
  `offset_in_line`, `text_length` and `anchor` all describe the file, and the reader
  translates to and from the unit's processed text through the unit's offset map
  (`lib/local/reader_offset_map.dart`). That keeps `text_length` the file's length, so D4's
  file-change tiers still work, and it keeps a record written before the rules ran valid
  after they run or after the rule set changes. The named divergence is
  `local-progress-raw-space` in `docs/compatibility/book-source-differential-contract.md`.
- *Correction (2026-09-16).* The anchor is the line's first ≤32 code units **verbatim**, not a
  hash: the near tier relocates it within ±N lines and the search tier finds it in the file,
  and neither can compare a digest. `docs/user-data-contract.md` D4 and ADR 0007 carried the
  word "hashed"; the implementation (`LocalReader.anchorOf`, `anchorMatches`) is the
  behaviour the tiers need and the text above is what they implement. Recorded here because
  a spec that says "hash" would justify a future format breaking the anchor comparison.
- Chapters are always a list, never "no chapters": a local TXT/Markdown file without a
  chaptering rule is one implicit chapter spanning the file. This is the seam that lets
  regex chaptering (`txtTocRule`'s job) arrive later without changing progress or the
  reader's model.
- Chapter variables are stored per chapter; book variables per book.
- **The reader renders one bounded window, never a whole document.** Measured on the
  development machine (Dart JIT, test engine and font, 800 px):
  - loading a 500 MB TXT (524 290 200 bytes, 176 232 000 code units) with
    `File.readAsString()` takes **2.9 s** and **≈ 1.0 GB RSS**;
  - `TextPainter` layout: 10 k → 7 ms, 100 k → 71 ms, 500 k → 364 ms, 1 M → 676 ms,
    5 M → 4.6 s, 20 M → 22.9 s, with a peak **≈ 250 bytes per code unit** (5 M → 2.2 GB,
    20 M → 5.0 GB);
  - so a whole-document run stops being usable above a few million code units (~5–15 MB of
    TXT) whatever the file size, and 500 MB cannot be opened at all (≈ 44 GB of paragraph
    memory, extrapolated).
  A window of a few thousand code units keeps layout sub-millisecond, and because the offset
  is a code-unit index it stays independent of window size, font, and layout.
- **Chaptering never replaces paging:** a chapter can itself be huge, a TXT with no markers is
  a single implicit chapter, and the frozen reader needs `splitLongChapter` for exactly that
  reason.
- **A local file's length is cached, not re-read.** Nothing should read a whole file to clamp
  an offset — today both `LocalLibraryService._readLength`
  (`lib/local/local_library_service.dart:82-89`) and the local reader
  (`lib/main.dart:376-384`) do.
- **Decoding happens off the UI thread** (`Isolate.run`/`compute`), and only the open book's
  window stays in memory.
- **Executed (2026-09-16, ADR 0010 and `tool/text_engine_prototype/`):** the Rust engine
  indexes the same 500 MB file in **609 ms** with a **5.7 MB** peak RSS and a 2.5 MB
  footprint, against **11.6 s / 20 MB** for a pure-Dart streaming index over it and the
  2.8 s / 817 MB `File.readAsString()` row above (reproduced). A window of 20 000 code units
  at offset 100 000 000 comes back in **1.9 ms** without reading the file. The 20 MB GBK file
  indexes in 384 ms; `dart:convert` cannot decode it at all. Windows only, page-cache-warm;
  the other four platforms are built but unmeasured.
- **Not decided here:** content-cache retention, prefetch depth (both stay in the map's fog).

### D5 — Storage engine and layout *decided: SQLite, one database per space*

```
%APPDATA%\Liber\
  manifest.json             # installation level: space registry, format/version, UI prefs
  spaces\<spaceId>\data.db  # everything the space owns
```

One database per space makes the D9 boundary literal: a space *is* a file, so a private
space can later be encrypted as a unit.

Relational tables, no bitmasks: `sources`, `books`, `groups`, `book_groups`, `chapters`,
`text_index` (the sparse byte↔code-unit anchors per local file), `progress`,
`replace_rules`, `local_roots`, `local_files`, `settings`. The synthetic shelf
views (all / local / ungrouped / update-error) are queries, not rows, so counts, filters,
and ordering are indexed instead of scanned in memory. Imported objects keep their unknown
fields in a `raw` JSON column, so the round-trip rule in D6 holds without hand-written
merge logic.

*Why not JSON documents (the first draft of this document):* the queries the shelf needs are
exactly SQL; a progress write becomes one row instead of rewriting a document; import merges
become transactions; a content cache later becomes a table with partial reads. Legado
(Room), Calibre, and KOReader all use SQLite for these reasons.

*Cost, stated plainly:* one native dependency and a migration discipline (D6). Native SQLite
arrives through `package:sqlite3` v3 **hooks** — `sqlite3_flutter_libs` is end-of-life and
must not be added — which downloads a pre-compiled, sha256-verified binary during the build,
so the first build and CI need network. Encryption, when a private space arrives, is a
three-line pubspec user-define (`sqlite3mc` or `sqlcipher`).

### D6 — Versioning and upgrade *decided: drift owns the schema*

- `drift` table classes are the single source of truth for the schema; queries are typed and
  checked at compile time, which matters because no automated test can click a Windows GUI.
- The version is drift's `schemaVersion`; upgrades are explicit, forward-only steps, one per
  released version.
- Each step gets a generated verification test: `drift_dev schema dump` snapshots every
  version and `drift_dev schema steps` + `generate` produce a test that migrates the real old
  schema to the new one. That makes "each step has its own fixture" mechanical instead of
  hopeful.
- Unknown imported fields live in `raw` JSON columns (D5) and round-trip untouched. A
  database written by a newer build is refused, not partially read.
- The three existing files are imported once into the default space inside a transaction; the
  originals are renamed aside rather than deleted, and the import reports like a migration.
- Working rule: after any schema change run
  `dart run build_runner build --delete-conflicting-outputs`, never hand-edit generated
  files, and let CI fail when the generated tree is stale.

### D7 — Imported Book Sources *decided: inside the space, keyed by `bookSourceUrl`*

Stored inside the space, keyed by `bookSourceUrl` (Legado's own primary key), as the
imported object plus typed accessors the product reads; unknown fields retained.
`bookSourceGroup` is stored as a name list (Legado keeps a comma-joined `HashSet`, so order
is not meaningful). Product-side flags (`customOrder`, `enabled`, `enabledExplore`,
`lastUpdateTime`) are preserved. Runtime state (cookies, caches, rule state) stays #10's,
and it lives in the space that owns the source.

### D8 — Replace rules *decided: inside the space, baseline fields and defaults*

Inside the space, one list, fields as in Legado (`name`, `group`, `pattern`, `replacement`,
`scope`, `excludeScope`, `scopeTitle`, `scopeContent`, `isEnabled`, `isRegex`,
`timeoutMillisecond`, `order`), defaults preserved (`scopeTitle=false`,
`scopeContent=true`, `isEnabled=true`, `isRegex=true`). Import merge is by
`(name, pattern, replacement)`; ordering is the `order` field with a stable tiebreak on
insertion. Behaviour is #17.

### D9 — Partitioning, fixed, and its consequences

Fixed: one store per space; space identity is store identity. Consequences recorded here:
ids are space-local; there is **no cross-space reference at all** — a book's `sourceRef`
resolves inside its own space, because sources live there too; import targets exactly one
space; counts, badges, and refresh scopes never aggregate across spaces; entering another
space means opening (and possibly decrypting) its store.

### D10 — The text engine is a Rust crate *decided*

A small Rust crate behind `flutter_rust_bridge` owns, for local files: encoding detection,
the one-pass index build (chapter boundaries plus the sparse byte↔code-unit anchors), and
window decoding. Dart asks for a window and receives text; the index lands in `text_index`
(D5).

*Why Rust, in order of weight:*

1. **Encodings.** `dart:convert` offers only UTF-8, Latin-1, and ASCII, while GBK/GB18030
   TXT files are common; the frozen baseline detects a charset per file (`TextFile.kt:84`)
   and this product currently assumes UTF-8. Rust's `encoding_rs` is the Encoding Standard
   implementation Firefox uses, identical on all five platforms, whereas the Dart options
   are platform-codec packages (for example `charset_converter`, which lists
   Android/iOS/Windows/Linux but not macOS) with a channel round trip per decode.
2. **mmap and zero copy.** A window can be decoded out of a mapped file without ever
   materializing the book as a Dart string — the measured 1 GB and 250 bytes per code unit
   are exactly what D4 forbids.
3. **Scan throughput.** One-time index passes over hundreds of megabytes. Dart measured
   2.9 s and 1 GB for 500 MB *when materializing*; a streaming Rust path should be a
   different order of magnitude — to be measured, not assumed.

*Cost:* one more build artifact in a repository that already builds one — the `fjs` crate,
through `cargokit`, for all five platforms — plus the codegen step for a new API surface.

*First evidence, executed (2026-09-16):* the bounded benchmark on the 20 MB GBK file and on
the 500 MB file, comparing the Rust engine against a pure-Dart streaming index on pass time
and peak RSS. The engine met both targets — 609 ms and 5.7 MB for 500 MB, one pass, with a
15 964-entry sparse index — and the pure-Dart row came in 19× slower with an 8× larger
footprint, so Dart-side indexing is not needed for a book to open. The GBK file is the row
that cannot exist on the Dart side at all: `dart:convert` refuses it, and its lossy path
produces 13.1 M replacement characters. Numbers, hashes and re-run steps:
`tool/text_engine_prototype/`.

## 4. Out of this contract

- Host-surface state (cookies, cache, rule state): shape and lifecycle were #10's; **where it persists
  is settled in ADR 0011 §3** — inside this space's `data.db`, cookies keyed by the registrable domain
  and visible per source site group, cache entries and `java.put`/`java.get` values owned by the source
  that wrote them, implementation in #21. As of commit `ddf55ce` both the cookie jar and the cache are
  in-memory only.
- Chapter content cache and prefetch policy, settings shape — the map's fog.
- Everything the map lists as out of scope, including the private-shelf feature itself.

## 5. Status

All ten decisions are settled and recorded in ADR 0007; this document is the shape they
describe. Implementation is not part of this ticket: the schema, the Rust text-engine
benchmark, and the import path are follow-up work, and #17 consumes the replace-rule
decision.
