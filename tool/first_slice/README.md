# First-slice controlled corpus (SLICE-01)

One fixture for the first end-to-end compatibility slice: a synthetic Book
Source, the replay responses a local server answers it with, the scenario, and
the request sequence the scenario declares. The definition it serves is
`docs/compatibility/first-slice.md`; the contract its rows must satisfy is
`docs/compatibility/book-source-differential-contract.md`.

Files:

- `fixtures.json` — the corpus. Its `source` object is a complete Book Source,
  its `responses` are the only bytes the fixture may receive, and its
  `expectedRequests` are the scenario's declared request sequence.
- `runner.dart` — the replay server plus the four-stage run through the product
  pipeline (`HtmlSourcePipeline` over `HttpSourceTransport`).
- `../first_slice_replay.dart` — the command-line entry: record observations,
  or serve the corpus for a driven product run.
- `evidence/` — recorded observations, one file per platform.

## Destination side

```
dart run tool/first_slice_replay.dart packages/fjs/libfjs/target/debug/fjs.dll
```

The run binds `127.0.0.1:18731` (the corpus' own `origin`, because the source
object is a compared input), drives search → book information → table of
contents → content, and writes
`tool/first_slice/evidence/<platform>-slice-01.liber.json`. It fails when the
scenario shape is broken: an undeclared request, a request sequence other than
the declared one, a missing stage, the session cookie not reaching the wire, or
a page-chained stage that did not follow its next link.

`test/first_slice_fixture_test.dart` runs the same corpus through
`flutter test test`, so every desktop platform whose CI job builds the native
library executes it.

To hand the page the running corpus instead:

```
dart run tool/first_slice_replay.dart - --serve --source-out build/slice-01.source.json
```

then drive the app (`README.md` → Verification and evidence → Driving the UI)
with 书源试读 → 选择书源 JSON → `build/slice-01.source.json` and keyword `回放`.

## What a green destination run does *not* say

A pass means the corpus is healthy and the product reached the stages the slice
names. It is not a compatibility result: no frozen observation has been compared
yet, so every differential row of this fixture is `not-run` in the capability
matrix sense.

## Frozen side (not-run)

The golden must be produced by running the hash-pinned frozen APK against the
same corpus, the way `tool/nested_oracle` does: no Legado class is rebuilt, the
harness is an instrumentation APK that targets the installed
`io.legado.app.debug` package and reaches its classes through
`getTargetContext().getClassLoader()`.

1. Extend the oracle instrumentation (or add a second entry beside
   `NestedOracle`/`StateOracle`) with a four-stage entry that:
   - constructs the corpus' `BookSource` through
     `io.legado.app.data.entities.BookSource` reflection, and a `Book` for the
     first search result (`SearchBook` → `Book`, as the frozen app does);
   - calls `io.legado.app.model.webBook.WebBook.searchBookAwait(bookSource, key, page)`,
     `getBookInfoAwait(bookSource, book)`,
     `getChapterListAwait(bookSource, book)` and
     `getContentAwait(bookSource, book, chapter)` — all `suspend`, so the entry
     needs a `Continuation` (the state oracle already builds
     `kotlin.coroutines.EmptyCoroutineContext.INSTANCE` and `JobKt.Job`);
   - serves `responses` from the corpus with the same matching rule as
     `runner.dart` (decoded query exact where declared, otherwise path+method),
     on `127.0.0.1:18731` inside the device process, or with the address
     rewritten if the corpus runs outside it;
   - records the request trace (method, resolved URL, source-controlled
     headers, outbound cookies, body), the stage outputs, the state each stage
     left, and cleanup — the surfaces the differential contract requires.
2. Run it against the installed frozen APK, pull the report, and commit it as
   `evidence/android-<fingerprint>/golden.json` with the APK hash, the corpus
   hash, the device fingerprint and the run log, the way
   `tool/nested_oracle/evidence/android-17-os4.0.0.25/` records its own.
3. Compare with the contract's matching rules. `tool/state_oracle_compare.dart`
   and `tool/html_adapter_gate.dart` are the two existing comparators to model
   it on; neither compares this fixture.

Until step 2 has run, this fixture's rows are `not-run`, and no platform,
source or capability claim may be promoted by a green destination run.

## Corpus rules

- The port is fixed at 18731 and is part of the compared inputs: a busy port
  fails the fixture instead of silently moving it.
- Raw query bytes are recorded as observed; the declared `expectedRequests`
  compare the *decoded* query parameters, because the query's byte spelling is
  what the differential contract compares, not what the corpus declares.
- The corpus is versioned: changing the source, the responses, the scenario or
  the declared requests is a new corpus version, and the frozen golden must be
  regenerated with it.
