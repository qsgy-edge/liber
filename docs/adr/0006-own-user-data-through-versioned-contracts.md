# User data is owned by versioned contracts: a local library with stable IDs, and an idempotent Legado import

**Status:** accepted (2026-09-15)

**Local library.** The shelf, the local library, and reading progress are stored
in this product's own versioned contract — stable IDs for a root and for each
book, and progress as a code-unit text offset that survives re-layout — rather
than as Legado's Room entities or file layout. One route owns local reading: the
user selects a root, may browse it or scan the current folder recursively, and
explicitly adds TXT or Markdown files; scanning never imports. Markdown is read
as plain text in the first version. Losing access to a root keeps the shelf and
the progress, and only requires re-authorizing the same root ID.

**Legado migration.** Book Sources, backup books and groups, and reading
progress are imported through a baseline adapter into that same contract: Book
Sources merge by stable key, shelf entries merge by stable book key, progress
only moves forward, books backed by local files are marked for relinking, and
file bytes, cookies, caches, and downloaded content are never imported — the
losses are reported instead.

## Considered options

- **Store Legado's shapes directly (Room tables, backup ZIP layout).** Rejected:
  it would make the frozen baseline's private storage layout this product's
  persistence model, and the backup format carries no manifest or version to
  migrate against.
- **Auto-import everything found under a scanned root.** Rejected: it matches
  neither the baseline's explicit-add behavior nor the expectation of a curated
  shelf.
- **Use Legado's UI `books.json` export as the migration surface.** Rejected: it
  carries only name, author, and intro, and its import path re-searches sources
  instead of restoring state.

## Consequences

Progress is persisted as code-unit offsets, so changing the reader's text model
needs a migration rather than a reinterpretation. Import is idempotent and
reports its losses, and nothing about the baseline's storage layout is promised.

See `docs/compatibility/legado-data-migration-contract.md` and `CONTEXT.md`.
Provenance: `liber-archive`, issues 06 and 07.
