# User data is owned by versioned contracts: a local library with stable IDs, and an idempotent Legado import

**Status:** accepted (2026-09-15)

**Local library.** The shelf, the local library, and reading progress are stored
in this product's own versioned contract — stable IDs for a root and for each
book, and progress as a code-unit text offset that survives re-layout — rather
than as Legado's Room entities or file layout. One route owns local reading.
The #121 amendment below changes new imports from external references to a
user-selected managed library. Existing external references remain until
explicitly adopted. Discovery never imports, and Markdown remains plain text.
Losing access keeps the shelf and progress and requires renewed authorization.

## Managed-library amendment (#121, 2026-10-11)

Application data stays in the platform's private application-data directory
(#120). At the first local-book import the user selects a library folder;
subsequent imports copy and verify the chosen TXT/Markdown files there, preserve
the originals, and read the managed copies. A canonical existing library member
is admitted without another copy. Previously referenced external books move only
through explicit selected-book adoption, preserving their book IDs, groups,
settings and progress; missing or unresolved references stay visible.

Same-name, equal-byte imports reuse their managed book. Different content offers
**Update this book (replace)**, **Keep both**, or **Cancel**. Update publishes a
verified new file reference under the existing book identity, invalidates its
cached text index, and preserves the old bytes until publication succeeds. This
avoids relying on provider-specific in-place replacement. Reading positions use
the existing bounded restore and report approximate/fallback results. Old update
copies may remain; retaining them does not attach them to the new current file.

Selecting a different library folder automatically prepares verified copies of
all managed books, then publishes the new access metadata and current file keys
in one transaction. The managed root ID, book IDs and progress do not change.
Failure or cancellation leaves the old library active. After success, cleanup
requires a separate choice and is limited to the exact transferred old files,
their verified bytes and the absence of current references. It never recursively
clears the old folder. Removing a book from the shelf keeps its file; deleting a
managed file is a separate explicit action.

File access is authorized independently of book identity. Android document keys
and URIs remain opaque; Apple roots retain scoped bookmarks. Original import
aliases associate old snapshots with the same book after relocation and never
resolve readable files. Multiple verified current owners of one physical file
are refused before publication or deletion. The current unique original-alias
constraint can also refuse an update or whole relocation when another book owns
that alias; this bounded refusal is a recorded limitation, not a completed
identity-repair feature. Platform execution remains scoped to its actual
verification evidence.

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
