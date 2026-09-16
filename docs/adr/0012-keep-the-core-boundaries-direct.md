# The core boundaries stay direct: a format supplies text, a source supplies stages, the reading module owns the position

**Status:** accepted (2026-09-16). Answers ticket #7 — the extension boundary the map's "Not yet
specified" list left open for later local formats and later Legado capability families. It
changes no compatibility row and starts no abstraction: every seam below either already exists
in the code or is recorded here as the sentence a later implementation must fit, with the
evidence that would justify a real one.

**A format joins reading by supplying text and chapter boundaries, and nothing else.** The two
formats in scope now are TXT and Markdown, both read as plain text (ADR 0006: "Markdown is read
as plain text in the first version"). Their difference today is a `local_files`/`books` label
and the file filter (`lib/store/local_library.dart:170,220`); no code branches on it, and both
reach the same byte → code-unit engine. What a format must supply to the reading module is
already an argument in the engine's API rather than a constant: chapter boundaries and the
bounded window, i.e. `TextEngine.index(path, IndexOptions{toc_rules, anchor_stride_bytes,
max_scan_bytes})` and `TextEngine.readWindow(...)` (`lib/local/text_engine.dart`), where
`toc_rules: Vec<String>` is the caller's own list — the frozen reader's two default TXT rules
are only the default (`packages/fjs/liber_text/src/scan.rs:88,138`). Chapterization therefore
stays *one mechanism* (a regex rule list) that a format may choose defaults for; a
heading-based Markdown default belongs to the reading-settings field set, which is still in the
map's fog, not to this decision.

**What a rich format does to the progress record, and what waits for its implementation.** The
record's *field set* is D4's and does not change per format: a chapter key, a code-unit offset,
the line fields, a length, an anchor. What changes is the *space* those values live in — which
document a `chapter_key` names, what `text_offset` is an offset into, what `text_length`
measures — and that space belongs to the format (see the ownership rule below), not to the
reader. Two things inside
a rich format are therefore genuinely open until it is implemented: whether `text_length` (the
percentage fallback and the relink signal) measures the current document or the whole book, and
whether a position inside one document needs a stronger anchor than a code-unit offset once the
document carries images or reflow. Both are decided by the format's implementation with its own
evidence; a change to the *field set* would be a new ADR plus a `drift` migration with a
generated test, not an implementation detail. A PDF is the boundary case and does not use this
record at all — it has no code-unit space, its position is a page and a rectangle, and it is a
document-viewer module rather than a variant of the reading one.

**Rendering is the format's own business, and arrives with the format that needs it.** Markdown
stays plain text; the first format that renders itself (EPUB, or an HTML file) brings its own
rendering path when it is built. There is no general "the reader renders a format" seam to
design now, because the two rendering needs that are actually visible diverge: EPUB reflows
text and images, a PDF is page-rendered and will not reuse either path. This is the same
answer the ticket's anti-speculation clause asks for, applied to the one axis where it is
tempting to build ahead.

**The formats that arrive later, and what they break.** EPUB, PDF, HTML, MOBI/AZW3, comics and
audio are not in the destination sentence, and image and audio Book Sources are already the
map's declared out of scope. Their arrival is not free: `text_index` — the sparse byte ↔
code-unit anchor table — is keyed `(rootId, relativePath, byteOffset)`
(`lib/store/database.dart:212`), i.e. one byte stream per book, and a container's spine has no
such stream; a PDF has no code-unit space at all. That refactor lands with the format that
forces it, not before, and the position model that must survive it is fixed below.

**A new Book Source capability family joins by three edits and a matrix row.** The mechanism is
already there and stays: a host member is the facade string
(`lib/source/js_source_runtime.dart:590`) plus `SourceHostDispatcher` plus the
`tool/host_surface_gate.dart:12` whitelist (49 members, 37 checks); a new stage is a pipeline
method (`search`/`details`/`chapter`, `lib/source/html_source_pipeline.dart:280,337,465`) plus
its own entry point; and the compatibility claim is a row of
`docs/compatibility/book-source-capability-matrix.md` re-measured per slice, never a structural
promise. This ADR therefore introduces no `BookSourcePipeline` interface, no stage abstraction
and no per-source capability record: a capability record would have no consumer, and
permission *policy* is the security boundary's (#5). One case is a dated exception rather than a
seam decision: the two pipelines are not interchangeable —
`JsonSourcePipeline.run()` (`lib/source/json_source_pipeline.dart:18`) is a single call
returning `SourceReadingResult(title, chapters, content, trace)` (`:322`) and the JSON path
reaches only the trial page (`lib/source/source_trial_page.dart:113`) — so a JSON Book Source
cannot be shelved or read today. **That unification is due inside v1**, at the slice that puts a
JSON source on the shelf; it is a refactor of two existing pipelines, not a new layer, and it is
not started here (ticket #29).

**Reading never learns a non-text source.** `bookSourceType` is read and stored as `books.type`
(`lib/store/space_store.dart:56`) and nothing branches on it; audio, image and file sources are
unreachable (capability matrix, `bookSourceType` and `downloadUrls` rows). The rule this ADR
fixes: `bookSourceType` is a property of the *source*, the reading module's unit is *text*, and
a non-text source is a separate module with its own contract and its own progress — planned
after v1. Until then the "open a book" boundary must fail loudly for a book whose source is
non-text instead of degrading into empty text, and no multimedia shape may enter the reading
module or the five-field progress record. Refusing such sources at import was rejected: a
Legado export mixes source types, and a whole-file refusal turns a partial gap into an import
that loses the user's other sources.

**One reading module, and the position is opaque to it.** The reading module owns the chapter
list, the current position, bounded window reads, the progress write with its tiered restore,
and navigation; a format owns the byte ↔ code-unit mapping, the chapter boundaries and the
bounded decode; a source owns the network path that yields a chapter list and chapter text (the
pipeline's `details()`/`chapter()`). There is one such module for local and for network books,
even though two differently shaped readers exist today (`lib/source/online_reader_page.dart`
writes a per-chapter position; `lib/main.dart:490` reads a whole file — #20 replaces the
latter). The progress record is not re-decided here: it is D4's five-field record, and the
ownership rule this ADR adds is that the reading module treats `text_offset` as **opaque** — it
stores the offset and hands it back to whoever produced the text space (a format for a file, a
source for a network chapter), and `chapter_key` names the reading unit, with a chapterless file
being one implicit chapter. That sentence is what keeps a later format from forking the record.

**Conversion attaches once, at the reading module's text entry.** #27's content-script choice
(system locale, with a manual override) is applied where text enters the reader — to chapter
text *and* to TOC titles, for local and source content alike, which is what the frozen
`ContentProcessor` does — through ADR 0010's `liber_text` implementation. Per-format conversion
is a red line: it is the one way TXT and a later format could disagree about the same
characters. #28's interface language is the other half and is not the same setting: it is
installation level (ADR 0007, D1 keeps only the space registry and UI preferences there) and
must not be merged with the content script.

## What stays stable, and what stays direct

| Stable (a later change is an ADR, not an implementation detail) | Direct (no abstraction on purpose) |
|---|---|
| The five-field progress record, with `chapter_key` naming the reading unit and `text_offset` opaque to the reader | How a format stores its anchors (`text_index` is TXT/Markdown's answer, not the reader's) |
| `TextEngine`'s three calls — `detectEncoding`, `index`, `readWindow` — with `toc_rules` as the caller's parameter | Which default rule list a format hands in |
| The capability matrix row as the per-family compatibility claim, and the host-surface gate as its structural assertion | The three edits a new host member needs |
| The differential contract's four stages and its matching rules | The pipeline class shape behind each source type |

## Considered options

- **A format registry or plugin interface now.** Rejected: it would be designed from
  imagination — one implementation exists, and the only real inputs (a container, a spine, a
  position that is not a file offset) arrive with EPUB. The registry's cost is paid today for a
  shape that EPUB would then re-shape.
- **A generic rendering path for formats.** Rejected: Markdown does not need one now, and the
  two visible needs (reflow, page rendering) do not share a shape. Building it would add a
  rendering dependency and a rich-text reader path with one hypothetical user.
- **A `BookSourcePipeline` interface now.** Rejected *as now*, not as a shape: with one consumer
  it would force splitting `JsonSourcePipeline.run()` and unifying `HtmlBook` with
  `SourceReadingResult` for a call site that does not exist yet. The v1 slice that shelves a JSON
  source is where that cost is real (#29), and it is smaller there because a consumer exists to
  check the interface against.
- **A per-source capability record with permission.** Rejected: the record has no reader, and the
  policy that would consume it belongs to #5. If #5 defines a permission that must be enforced at
  a dispatch point, the carrier for it is that ADR's to name.
- **Per-format content conversion.** Rejected: the frozen reader converts content and TOC titles
  once, in the content processor; per-format conversion would let two formats disagree about the
  same chapter, and would put the conversion tables behind every future format's implementation.
- **Keeping the local and network readers separate.** Rejected: one progress record with two
  position models is the fork this ticket exists to prevent, and #20 is already replacing the
  local reader with the paged one.
- **Supporting non-text sources now, or refusing them at import.** Rejected for the reasons in
  the paragraphs above: the first forces a second shape into the reader and the record, the
  second fails an import that is otherwise fine.

## Deliberately not built, and the trigger that reopens each

| Not built | Trigger |
|---|---|
| Format registry / plugin interface | A second format implementation exists (EPUB) and it actually needs something different from the reader (container, its own TOC document, a position that is not a file offset) |
| Format rendering path (rich text, images, Markdown rendering) | The first format that must render itself is built; PDF will not reuse it |
| `BookSourcePipeline` interface | The slice that shelves a JSON source (#29, inside v1), or the second stage entry point (explore, reviews) |
| Per-source capability record, permissions | #5 defines a permission that has to be read at a dispatch point |
| Multimedia shape in the reader or the progress record | After v1, when a non-text source is actually scheduled — as a new module |
| `text_index` with multiple text streams per book | The first non-single-stream text format (EPUB) |
| Conversion performed per format | Never — one attachment point (red line) |
| Content cache, prefetch depth, the reading-settings field set | Still the map's fog; not decided here |

## Consequences

- No code changes and no new files beyond this record and one clarifying sentence in
  `docs/user-data-contract.md` (D4: the reading module treats `text_offset` as opaque). The
  map's "extension boundary for later local formats and later Legado capability families" line
  is retired by this ADR; the controller updates the map when it merges.
- A v1 obligation is created: unify the HTML and JSON pipelines so a JSON Book Source reaches
  the shelf and the reader. It is carried by ticket #29 and is not started here.
- New capability families reference the matrix row and the gate instead of restating a claim,
  so the incremental cost of the next family is what it is today: a facade member, a dispatcher
  method, a whitelist line, a matrix row, a ticket.
- #20 implements the position as the reading module's; the rule that the reader never
  interprets `text_offset` is what it must preserve, and a format that misstates its own offset
  space will show up as a restore bug rather than as a compile error.
- Residual risk this decision accepts: "the offset is opaque to the reader" is a convention, not
  a type, and nothing in the gate set asserts it. The first implementation to violate it will be
  the EPUB-class format, which is also the point where the convention is cheapest to check.

Provenance: ticket #7; ticket #1 (the map's destination, "Not yet specified" and out-of-scope
lists); ADR 0006, ADR 0007 (`docs/user-data-contract.md` D4), ADR 0009, ADR 0010;
`docs/compatibility/book-source-capability-matrix.md`, `docs/compatibility/book-source-differential-contract.md`;
`lib/store/local_library.dart`, `lib/store/database.dart`, `lib/source/`, `lib/local/text_engine.dart`,
`packages/fjs/liber_text/src/scan.rs`.
