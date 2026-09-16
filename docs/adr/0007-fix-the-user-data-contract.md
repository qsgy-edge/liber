# The user data contract: one SQLite store per space, owning its sources, groups, progress and rules

**Status:** accepted (2026-09-15)

**One store per space.** Everything user-generated lives inside a space — Book Sources,
replace rules, shelf books, groups, ordering, table of contents, reading progress, local
library roots and files, and reading settings. Installation level keeps only the space
registry and UI-level preferences. A space's identity *is* its store's identity, so no query
spans spaces and a whole space can later be encrypted as a unit; the private-shelf feature
stays out of scope while this seam makes it additive. There is no cross-space reference at
all — a book's `sourceRef` resolves inside its own space, because sources live there too.

**SQLite through `drift`, one database per space.** Relational tables rather than JSON
documents or bitmasks: the shelf's queries (sort, filter by group, counts, ungrouped,
update-error) are SQL's work, a progress write becomes one row, and an import merge becomes
a transaction. `drift` owns the schema as its source of truth, and `drift_dev schema
dump`/`schema steps` generate the migration verification tests — which matters because no
automated test can click a Windows GUI, so a wrong migration must fail in CI rather than in
a user's library. Native SQLite arrives through `package:sqlite3` v3 hooks;
`sqlite3_flutter_libs` is end-of-life and must not be added.

**Identity.** A minted, space-local `id` is the primary key; `(sourceRef, sourceBookUrl)` is
what import and re-search match on; `(name, author)` is only ever a hint, never a silent
merge. `kind` (`network` or `local`) is explicit instead of overloading the source field the
way the baseline's `Book.origin` does with `loc_book`.

**Groups are relational.** Membership is a list of group ids; the synthetic views (all,
local, ungrouped, update-error) are queries, not rows with magic negative ids. Import merges
groups by name.

**Progress is a five-field record and the reader pages.** The authoritative value stays the
absolute code-unit offset (ADR 0006), joined by a line index, an offset in line, the text
length, the chapter key, and the line's own prefix as the anchor *(corrected 2026-09-16: earlier
revisions of this ADR and D4 called that field a hash, which no tier can compare — it is the
line's first ≤32 code units stored verbatim; `docs/user-data-contract.md` D4 carries the same
correction)*; restore is tiered (exact, near, search,
fallback) because a local file can be edited, re-encoded, or replaced, and the same facts
feed `needsRelink`. The reader renders a bounded window: measured layout cost is linear in
code units (0.7 µs each at 1 M) but memory is not (≈250 bytes per code unit — 20 M code
units peaked at 5.0 GB), so a whole-document text run stops being usable above a few
megabytes and a 500 MB file cannot be opened at all (2.9 s and 1 GB merely to decode it).

**Chaptering is a boundary source, not the fix.** A TXT without chapter markers is one
implicit chapter, so paging is what bounds the reader; the baseline itself caps segments at
10 KB without a TOC and 100 KB with one, which is the same conclusion reached from the other
side.

**Sources and replace rules follow the baseline's shapes.** Sources are keyed by
`bookSourceUrl` with unknown fields retained and `bookSourceGroup` stored as a name list;
replace rules keep the baseline's fields and defaults, merging on
`(name, pattern, replacement)`. Host-surface state (cookies, cache, rule state) keeps its own
shape from #10 but lives in the space that owns the source.

**The text engine is a Rust crate.** Encoding coverage is the primary reason: `dart:convert`
offers only UTF-8, Latin-1, and ASCII while the baseline detects a charset per file, and
Rust's `encoding_rs` behaves identically on all five platforms whereas the Dart options are
platform-codec packages with a channel round trip per decode and no macOS row. Secondary
reasons are mmap window decoding without materializing the book, and one-pass index builds
over hundreds of megabytes. The build machinery already exists: `fjs` is a Rust crate built
through `cargokit` for every platform.

## Considered options

- **Versioned JSON documents, one directory per space.** Rejected: the shelf's queries become
  hand-written scans and joins, every progress write rewrites a document, and import merges
  need hand-maintained deduplication — the cost lands exactly where mistakes corrupt user
  data.
- **Bitmask groups, as the frozen baseline stores them.** Rejected: a 64-group ceiling,
  membership queries that cannot use an index, and bit 63 unreachable through the baseline's
  own shelf queries.
- **Two tiers, with sources and rules shared across spaces.** Rejected: a private space would
  leak which sites it reads, and a book's `sourceRef` would have to cross a space boundary.
- **Chaptering alone, without paging.** Rejected: a chapter can be arbitrarily large and an
  unchaptered file is a single chapter.
- **A pure-Dart text engine.** Rejected for encodings (no GB18030; platform-codec packages add
  a channel round trip and miss macOS). Its performance comparison is still measured by the
  benchmark #16 leaves behind.
- **`(sourceRef, sourceBookUrl)` as the primary key.** Rejected: replacing a book's source
  would rewrite its identity and cascade into every reference.
- **A content hash as identity.** Rejected: the same book legitimately exists once per source.
- **Keeping `syncTime`, `originOrder`, and `Book.ReadConfig` as book columns.** Rejected:
  `syncTime` serves WebDAV sync only, `originOrder` is a cache a join replaces, and the
  per-book reading config belongs to the reading-settings shape (its behavioral flags —
  `useReplaceRule`, `reSegment`, `splitLongChapter`, `delTag`, `imageStyle` — are still
  required).

## Consequences

The three stores the product writes today (`local_books.json`, `online_reading.json`,
`migration_state.json`) are imported once into the default space inside a transaction, with
the originals renamed aside rather than deleted, and the import reports its losses like a
migration. Every later schema change carries a generated migration test, and unknown imported
fields survive in `raw` columns. The line index, the anchor, and the tiered restore are
contract rather than reader details, so a reader rewrite cannot silently drop them. Reading
configuration (global plus per-book override) and content-cache retention remain open in the
map's fog, and the Rust engine's throughput claim is still to be measured.

See `docs/user-data-contract.md`, `docs/adr/0006-own-user-data-through-versioned-contracts.md`,
and `docs/compatibility/legado-data-migration-contract.md`. Provenance: ticket #16, with the
text-cost probes run on 2026-09-15.
