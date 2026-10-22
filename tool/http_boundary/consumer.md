# HTTP-BOUNDARY-01 — the product side of the frozen ordinary-HTTP corpus

`tool/http_boundary/fixtures.json`, `tool/nested_oracle/HttpBoundaryOracle.java` and
the controller's captures are the producer lane's shared boundary. This file and the
two Dart entry points beside it are the product lane: they run the corpus through
the product's own ordinary HTTP surface, compare every portable value and wire fact
with both frozen captures of the controller's hash-bound handoff, and report what
still differs. Nothing here is a compatibility claim, and nothing here can turn a
difference into a pass.

Status: **measured, not accepted.** The product run reaches all 22 declared
observations and all 31 ordinary requests with no unmatched request, and both
captures compare identically; the remaining differences are listed below as strict
failures. Integration, review, the Windows driven run and #137/#133 acceptance stay
with the controller.

## What runs

```bash
dart run tool/http_boundary/runner.dart <fjs.dll> <root> <report.json> \
  [--expected-corpus-sha256=<LF sha256>]

dart run tool/http_boundary/compare.dart --handoff=<controller handoff.json> \
  --product=<report.json> --evidence=<directory>
```

`runner` is one fresh process per run: `<root>` must not exist, the run owns it,
writes `owner.json` before removing it, and exits with its own status
(0 completed, 1 failed, 2 refused, 3 finished-but-its-own-checks-did-not-pass).
`dart run` is the canonical entry so the native asset hooks for SQLite resolve; a
direct VM launch of the same file does not.

`compare` validates the handoff, both pinned captures and the product record, then
compares the product record with each capture and runs its controls. Its exit code
is 0 only when both comparisons and every applied control pass, 3 when there are
differences, 4 when a control does not produce its own new difference, 2 when an
input is refused.

## What each row measures, through which product API

| Corpus row | Product path |
|---|---|
| `helper.ajax` / `helper.ajax-list-first` | `java.ajax(url or [first, …])` through `InProcessSourceScriptRuntime`, so the frozen "first element only" rule is the product's own binding |
| `helper.ajaxAll-order` / `-width` | `java.ajaxAll([...])` through the same binding and `SourceHostDispatcher.ajaxAll`, whose configured batch width is its `concurrency` default |
| `helper.connect-header-string` | `java.connect(url, headerJson)`: the explicit map replaces the source's own header rule, including the user agent, and `x-declared` is absent |
| `helper.connect-source-header` | `java.connect(url)`: the source's declared `x-declared` and user agent |
| `helper.header-map-js` / `-ltjs` | the corpus' three fixture-authored scripts through the product's `source.getHeaderMap()` binding, one typed `returned` record per arity |
| `rate.record.1..3` | `java.ajax` on the `concurrentRate: "1/2000"` source, with `SourceRateLimiter.recordOf` read before and after each call |
| `s1.*`, `s2`, `s3.*`, `s6` | `openBookSourcePipeline(...).search/bookInfo/tableOfContents/chapter` over `HttpSourceTransport`, one pipeline per source |
| `s4.search-connection-failure` | the same search against the task-owned `127.0.0.1:0` listener, which accepts and closes each connection without a response; `SourceStageDiagnostic(kind: connection)` is the measured failure |
| `s5.search-cancelled` | the same search held in flight by the replay listener, then `BookSourcePipeline.cancel()` after the hold is confirmed entered |

The held response detaches its socket so the peer's own close is observable while
nothing has been written: the abort receipt is that close (or a failing write), never
an assumption. The follow-up row opens a new pipeline (its own cancellation and
transport) over the same source object and key before invoking it.

`SourceRateLimiter` is a dedicated instance over the real clock, injected into the
rate source's dispatcher, so the corpus' "initial snapshot empty" precondition is
exact and the product's process-global instance is not used. Its semantics are the
shipped class; no rate policy is changed.

## What is compared

- The ordered observation set, each row's `outcome`, `category` and its whole
  `value` tree with presence: an absent field and an explicit null are different
  observations, an added field is a difference, and array order is compared.
- The causal request trace: every row keyed by owner + selector + attempt, with
  exact method, path, raw query bytes, decoded query, target, body bytes, body
  length and body hash, status, terminal, declared response, cohort and the two
  batch facts, attempt kind, and the source-controlled headers.
- The declared ordered prefixes in order and each declared batch as a multiset.
- Both sides' identity pins (corpus LF hash, target package/APK/baseline) and the
  frozen capture's own receipts (`terminalIntegrityOk`, `promotable`,
  `requestCheck.match`, `observationCheck.match`, cleanup integrity), so a mutated
  copy is a visible difference rather than an unchecked assumption.
- The product's own gates and cleanup receipts (listeners, bridge, database,
  scratch removal), its inventory ("opened and empty before and after" — the table
  names are each runtime's own schema) and the failure endpoint's measured
  `acceptedConnections` / `transportReconnects`.

### Documented exclusions

Only these, each named and each one the corpus or the differential contract already
declares:

- `recordedAt`, `runId`, `pid`, `startedAt`/`completedAt`, `stageTrace`,
  `requests[].stage`;
- `observations[].evidence` (the corpus' own provenance channel: script errors,
  class names, planned/actual release order, database snapshots, identity hashes);
- request `receivedAtNanos` / `sentAtNanos` / `respondedAtNanos` / `sendSequence`,
  and `requests[].index` as row position rather than a value;
- a rate record's `time` epoch, compared only through `sameWindowAsPrevious`,
  `scheduleComplete` and the window advance; its `isConcurrent`/`frequency` are
  compared exactly;
- the failure endpoint's assigned port, its nanosecond stamps and its host header,
  and the owner manifest's timestamp;
- header **name case and order** and the differential contract's platform-generated
  `Host`, `Content-Length`, `Accept-Encoding` and `Connection` (a name the corpus
  declares required or forbidden is never filtered);
- `headerLines`, which is the same facts as `headers` with wire case and order.

No wildcard, no fuzzy text, no lower-bound proxy and no `notCompared` row exists in
this comparer.

## Controls

Fourteen controls run on deep copies of the immutable captures and of the product
record; each is compared against **its own** baseline, so a row the baseline already
reports can never satisfy a control: product value, golden value, product raw query,
product retry order, product identity, product presence, product receipt, golden
receipt (native provenance), an undeclared extra request, a product header, a
product body, a product attempt kind, a product batch fact and the held row's
terminal. Originals are re-hashed after the run and stay byte-identical.

## The measured differences (all strict failures, kept as they are)

Both captures produce the same 56 differences, grouped by cause:

1. **Configured batch width** — `runtimeConfiguration.threadCount` 16 vs 4, and every
   batch row's `value.batch.threadCount`. The frozen reads `AppConfig.threadCount`
   (default 16); the product's `SourceHostDispatcher.ajaxAll` default is 4.
2. **Declared 5-member batch** — the width cohort records
   `inFlightPeak` 4, `cohortComplete: false` and `releaseReason: "cohort-window"`,
   and the same two facts on each of its five request rows. This is the recorded
   5-vs-4 difference; the product's own peak is what the replay listener measured,
   not a lower bound.
3. **TOC and content tails** — the frozen batches the declared next pages
   (`BookChapterList.kt:89-113`, `BookContent.kt:110-135`); the product's
   `walkSourcePages` walks them sequentially, so each tail cohort records peak 1,
   `cohortComplete: false` and `releaseReason: "cohort-window"` with the same facts on
   its request rows.
4. **`source.getHeaderMap` arities** — the corpus' scripts iterate the returned map
   with `keySet()`/`iterator()`, which the product's map binding does not answer, so
   the `falseArity` and `trueArity` rows record `returned: false` where the frozen
   records the two pairs. The zero-argument row is `returned: false` on both sides.
5. **Book carrier fields** — the frozen `SearchBook`/`Book` rows carry `origin`,
   `originName` and `type` (and the details row its `origin`), which the product's
   `HtmlBook` carrier does not; those fields are absent, and absence is a failure.
6. **Cancellation bookkeeping wording** — the product has no Kotlin `Job`, so its
   `execution.jobLevel` and `followUp.jobLevel` read `pipeline-cancellation` where the
   frozen records `created-parent`. Every measured cancellation receipt itself
   (`holdEntered`, `clientAborted`, `workerTerminated`, `jobDone`, `lateRequests`,
   unchanged state probes and database, fresh follow-up execution) passes.

No exemption, normalization or policy change was introduced for any of these; they
await the controller's decision.

## Limits

One product session is compared with both independently captured positives; nothing
is fabricated from a capture or a raw script rerun. No phone, ADB, corpus, capture,
native producer or product `lib/`/Rust/persistence/public API change is part of this
lane, and this document closes no capability row, #137 or #133.
