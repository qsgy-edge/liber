# The first end-to-end compatibility slice

Ticket: #6. Contract: [book-source-differential-contract.md](book-source-differential-contract.md).
Capability inventory: [book-source-capability-matrix.md](book-source-capability-matrix.md).
Baseline: `14dd24945b2914ce2708b8abaa4ee67ceef892af`.

## Answer

One controlled fixture, one real source as a supplement, one page, and one
frozen-oracle entry that produces a golden for all four stages at once:

- **fixture** — `tool/first_slice/fixtures.json` (`SLICE-01`): one synthetic Book
  Source, six declared replay responses, a four-stage scenario, and the request
  sequence the scenario declares. It answers with a session cookie, chains both
  `nextTocUrl` and `nextContentUrl`, resolves relative URLs, declares a source
  header, and applies `replaceRegex` — the cheapest set that touches every stage
  the slice names and the session state between them.
- **real compatibility case** — 就爱文学 (the `jiuai` source), used only as a
  supplement: it is the one sample source whose four stages pass in the
  2026-09-15 triage recorded in the capability matrix, and its existing harness
  (`tool/jiuai_replay.dart`, `test/fixtures/jiuai_replay.json`) keeps that
  observation alive. It never defines the corpus and is never the oracle.
- **page** — the existing 书源试读 flow: `SourceTrialPage` → `HtmlSourceBrowser`
  → `OnlineReaderPage`, entered from the shelf. `HtmlSourceBrowser` is the page
  that carries search results, book information, the full table of contents, the
  shelf write and the reader entry in one place.
- **frozen side** — one instrumentation entry beside `tool/nested_oracle` that
  reflectively drives `WebBook.searchBookAwait` / `getBookInfoAwait` /
  `getChapterListAwait` / `getContentAwait` against the same corpus and records
  the request trace, stage outputs and state
  (`tool/nested_oracle/SliceOracle.java`, entry
  `io.liber.oracle.nested.SliceOracle`). **Executed 2026-09-18** on the
  operator's handset (`5615f742`, Android 17 / OS4.0.0.31): the golden is
  `tool/first_slice/evidence/android-17-os4.0.0.31/golden.json`, its provenance
  is the `manifest.json` beside it, and the row-by-row comparison against the
  Liber-side observation is `comparison.json` in the same directory. Six of the
  eight compared rows pass; R3 and R8 carry recorded divergences (below).

Why this is the cheapest credible set: the four stages, the session state and
the page chain are exercised by **one** fixture whose frozen side is **one**
oracle entry, and the rows that would need more corpus (request semantics, rule
families, WebView, JSON, failures) already have owners and do not have to be
solved before the slice can be measured. A capability corpus is what the
baseline-complete claim needs, not what the first slice needs.

## The fixture

`tool/first_slice/fixtures.json` — see `tool/first_slice/README.md` for the
mechanism and the frozen-side recipe. Executed here:

```
dart run tool/first_slice_replay.dart packages/fjs/libfjs/target/debug/fjs.dll
flutter test test/first_slice_fixture_test.dart
```

Recorded: `tool/first_slice/evidence/windows-slice-01.liber.json`
(corpus `03b013304efa90be2328014bdde0b9081957aac634a9c01b86bb1bd3bfade419`,
library `aa9586df2551ef4499d08a5bf54d9a9ce1ebb1de58b0314f5456da1b9348b49e`,
`oracle: "not-run"` — the field records that no frozen golden existed when this
observation was recorded; the golden and the comparison against it were added on
2026-09-18 under `evidence/android-17-os4.0.0.31/`, and this file is the input to
that comparison rather than rewritten by it). The run observed:

- six requests in the declared order — `GET /search?keyword=回放&page=1`,
  `GET /book/1`, `GET /book/1/toc`, `GET /book/1/toc?page=2`,
  `GET /book/1/chapter/1`, `GET /book/1/chapter/1-2` — every one answered from
  the corpus, none undeclared;
- the source header and the frozen default user agent on every request;
- the session cookie `sid=slice01` set by the search response and carried by all
  five later requests;
- search: two ordered results with name, author, kind and absolute book URL;
- book information: name, author, kind, last chapter, relative cover URL
  resolved, introduction;
- table of contents: two pages, three ordered chapters, `nextTocUrl` followed;
- content: chapter one over two pages, `nextContentUrl` followed, `replaceRegex`
  applied (the recorded text keeps an empty line where the replaced sentence
  was — an observation for the golden to compare, not a verdict).

**Frozen side, executed 2026-09-18** (`dart run tool/first_slice_compare.dart
 tool/first_slice/evidence/android-17-os4.0.0.31/golden.json
 tool/first_slice/evidence/windows-slice-01.liber.json
 tool/first_slice/evidence/android-17-os4.0.0.31/comparison.json`, exit 1):
both runs issued the same six requests in the same order with the same raw query
bytes (`keyword=%E5%9B%9E%E6%94%BE&page=1`), the same decoded queries, the same
source header, the same session cookie carriage and the same search, book
information and table-of-contents output; two rows did not pass and are recorded
as divergences, and four observations are named in the comparison's
`notCompared` list rather than dropped. A second device run reproduced the golden
byte for byte once `recordedAt` is dropped.

The corpus' own port (`127.0.0.1:18731`) is fixed and is part of the compared
inputs; a busy port fails the fixture.

## The real compatibility case

就爱文学 is the supplement, not the definition:

- it is the only sample source whose four stages pass in the 2026-09-15 triage
  recorded in `book-source-capability-matrix.md` (Sample weighting), across
  legacy selectors, a POST search with the frozen form encoding, a 302 to the
  result page, page chaining and `replaceRegex`;
- its replay fixture is synthetic — `tool/jiuai_replay.dart` says so in its own
  header ("Synthetic local responses; this is a regression fixture, not an
  oracle golden") — which is exactly its role: it keeps a real source's rule
  shapes running, and its live check (`tool/source_live_check.dart`, a
  supplemental run that produces no golden) is an observation, never a gate;
- consequences: a live success of this source promotes nothing; a failure of its
  replay fixture is a regression signal for the product, not a compatibility
  result; and the differential rows of the slice are those of `SLICE-01`.

Alternatives considered, with their costs:

| Candidate | Why not | Cost if chosen |
|---|---|---|
| 速读谷 (`book_sources/shudugu.json`, bundled) | its live path needs the network, and every rule family it uses is already exercised by `SLICE-01` | a second corpus to keep stable, and a live dependency in the slice |
| 无限小说网 | search passes but content extraction is blocked by an unimplemented rule family | the slice would inherit a capability gap |
| 猫眼看书 | JSON pipeline, not the HTML four-stage path | it would drag #29 (unify the pipelines) into the slice |
| A preserved real response corpus | this repository stores no source responses (one sample carries an authorization header) | provenance and mutation-risk work that the controlled corpus avoids |

## The page

The slice's page is `HtmlSourceBrowser`, reached from the shelf through
书源试读 (`SourceTrialPage`), with `OnlineReaderPage` as its chapter view. The
flow it must carry, in order:

1. **import** — 书源试读 → 选择书源 JSON loads `SLICE-01`'s source; the source
   is persisted with the shelf row when the book is added. The differential
   boundary starts *after* this step (the contract compares an already-parsed
   source object); the import itself is evidenced by the store and migration
   tests (#16, #24), not by the corpus.
2. **search** — the keyword `回放` returns the two recorded results.
3. **book information and table of contents** — selecting a result shows the
   information fields and the three chapters of the two TOC pages.
4. **shelf and reader** — 加入书架 writes the `books` row and the chapters, and
   tapping a chapter opens the reader on the content the corpus served.
5. **session state** — the reader's chapter request carries the cookie the search
   response set; a fresh process rebuilds it from the corpus (persistence across
   restarts is #21's row, not this slice's).

Driven recipe (Dart MCP, per `README.md` → Verification and evidence → Driving
the UI):

```
dart run tool/first_slice_replay.dart - --serve --source-out build/slice-01.source.json
```

then launch the driver against a scratch installation, load
`build/slice-01.source.json` in 书源试读, and assert the five steps; the store
side is asserted on `<scratch>/spaces/default/data.db` (`books`, `chapters`,
`progress`).

**Status: `run`, with the qualification below (amended 2026-09-18).** The batch
controller drove the flow on 2026-09-17 from a scratch installation, per #6's
resolution comment; the run was **store-seeded** (the controller seeded the
`sources` row), so the 选择书源 JSON dialog step of the recipe above was not
driven. The page and the recipe stay fixed so a later run has one thing to prove.

## Row set

Rows follow the contract's required observations, restricted to what `SLICE-01`
reaches. `run` means an observation exists on this branch. The frozen column is
the `tool/first_slice_compare.dart` verdict against
`android-17-os4.0.0.31/golden.json`; `fail` rows carry a recorded divergence, and
an observation one side does not carry is named in the comparison's
`notCompared` list instead of being counted as a pass.

| # | Row | Surface | Evidence source | Liber | Frozen |
|---|---|---|---|---|---|
| R1 | corpus inputs (source object, responses, keyword) | Input | `fixtures.json` + its hash | run | — |
| R2 | request trace: method, resolved URL, raw query bytes, order | Request | evidence `requests` | run | pass |
| R3 | source-controlled headers and injected request defaults | Request | evidence `requests[].headers` | run | fail (`accept-encoding`) |
| R4 | session cookie: `Set-Cookie` on search, `Cookie` on the five later requests | State (cookies) | evidence `requests[].headers.cookie` | run | pass |
| R5 | search output: ordered results, name/author/kind/book URL | Search | evidence `stages.search` | run | pass |
| R6 | book information output: name/author/kind/last chapter/cover/intro | Book info | evidence `stages.bookInfo` | run | pass |
| R7 | table of contents: order, chapter URLs, `nextTocUrl` pages | TOC | evidence `stages.toc`, `stageTrace` | run | pass |
| R8 | content: page chain, `replaceRegex`, final text | Content | evidence `stages.content` | run | fail (paragraph indent) |
| R9 | the scenario's declared request sequence, and no undeclared request | Failure/cleanup | evidence `scenario.invariants`, `unmatchedRequests` | run | — |
| R10 | the page shows import → search → info → TOC → content | Product | driven run | run (store-seeded, #6) | — |
| R11 | the shelf row, its chapters and the reader's progress row | Product/store | driven run + `data.db` | run (store-seeded, #6) | — |
| R12 | the same six observations on Linux and macOS | Platform | the corpus runs inside `flutter test test` on each desktop job | not-run on this branch | not-run |
| R13 | frozen golden and the Android destination row | Platform | the oracle entry | not-run (no Android app) | run (golden committed; the Android destination row is not-run) |
| R14 | iOS destination row | Platform | device/simulator run (`flutter test` is not an iOS row) | not-run | not-run |

Rows owned elsewhere and deliberately not in this set: request-semantics rows
(#15), the HTML extraction corpus on a device (#23), WebView rows (#2), rule-level
JavaScript (#11), login/explore/variables (#13), replace rules (#17), host-state
persistence (#21), XPath (#22), JSON pipeline unification (#29), and every
capability row the matrix already tracks.

## The frozen comparison, and its divergences

`tool/first_slice_compare.dart` compares the golden against the committed
Liber-side observation row by row and writes a report; it exits non-zero because
two rows did not pass. Both are recorded, neither is normalized away:

- **R3 — `accept-encoding`.** Every request carries the same injected default on
  both sides except this value: the frozen client sends `gzip, deflate`, the
  product's transport sends `gzip`. The source-controlled header
  (`X-Slice-Corpus: SLICE-01`), the frozen default user agent and the rest of
  the header set are identical on all six requests.
- **R8 — the content text.** The frozen content stage runs `ContentProcessor`,
  which prepends `ReadBookConfig.paragraphIndent` (default `"　　"`,
  `ReadBookConfig.kt:532`) to every paragraph (`ContentProcessor.kt:199`). The
  two texts are identical once that two-character prefix is removed per line —
  including the empty line the corpus' `replaceRegex` leaves behind — and the
  product's content stage has no counterpart to that post-processing yet.

Named `notCompared` observations (each with its reason in `comparison.json`):
`stages.bookInfo.tocUrl` (the Liber evidence shape does not record the resolved
TOC URL), `stages.toc.chapters[].url` as stored (the frozen entity keeps the rule
output and resolves it when used; R7 compares the resolved values),
`state.*`/`cleanup.*`/`serverErrors` (frozen-side observations with no
counterpart), and the two runs' provenance fields.

Promotion follows the contract: a row promotes only where the comparison passes,
so R3 and R8 do not, and the Android half of R13 stays `not-run`.

## Not-run, and what promotion needs

- **The frozen golden** — produced and committed 2026-09-18
  (`android-17-os4.0.0.31/`), with its `manifest.json`, `run.log`, corpus hash and
  APK hash; a repeat run reproduced it byte for byte.
- **The comparison** — `tool/first_slice_compare.dart` exists and ran; its report
  is committed beside the golden. Re-running it against a re-recorded Liber-side
  observation is the check the batch loop repeats.
- **The driven page row (R10, R11)** — driven by the batch controller on
  2026-09-17; the record is #6's resolution comment (store-seeded: the source row
  was seeded, and the 选择书源 JSON dialog step is not driven).
- **Linux/macOS (R12)** — `flutter test test` executes the corpus on every
  desktop job, so the row becomes `run` when the batch's CI run is green; that
  promotion is the controller's, after the batch lands.
- **Android/iOS destination rows (R13's other half, R14)** — the product has no
  Android or iOS application yet (P4); the golden is the frozen half of R13 only.

Promotion ladder, per the contract: fixture/platform `pass` only after the
golden comparison; capability `pass` only with no coverage gap; a source claim
only for the capabilities that source reaches; an all-platform claim only after
every desktop and device row exists. A green destination run promotes nothing.

## Coverage gaps the slice leaves open

Named here so no later claim treats the slice as complete:
the per-site cookie visibility rule (single-source corpus, ADR 0011 §3 / #21);
redirects, non-2xx retries and POST bodies (#15); rule-level JavaScript and
templates (#11); login, explore, variables, remote `jsLib`, TOC formatting (#13);
volume/VIP markers, cover decoding, `sourceRegex` (#14); WebView request paths
(#2); XPath and `@Json:` element rules (#22/#29); concurrency and rate limiting
(the product issues one request at a time); failure paths, cancellation and
timeouts (the scenario stops before any failure); and a second book, so the
retained-body and cache-reuse paths between books are unobserved.
