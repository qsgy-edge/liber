# HTTP-BOUNDARY-01 — the product side of the frozen ordinary-HTTP corpus

`tool/http_boundary/fixtures.json`, `tool/nested_oracle/HttpBoundaryOracle.java` and
the controller's captures are the producer lane's shared boundary. This file and the
two Dart entry points beside it are the product lane: they run the corpus through
the product's own ordinary HTTP surface, compare every portable value and wire fact
with both frozen captures of the controller's hash-bound handoff, and report what
still differs. Nothing here is a compatibility claim, and nothing here can turn a
difference into a pass.

Status: **measured, not accepted.** At candidate `b7fc3cf`, the product run reached
all 22 v2 observations and all 31 v2 ordinary requests with no unmatched request,
and both v2 captures compared identically with 56 strict differences. That retained
pre-repair measurement keeps its original identity; new runtime or observer bytes
require a new execution and comparison.

The active corpus is now **version 3**: 16 sources, 44 observations, 51 ordinary
requests and a fifth declared cohort. The v2 rows and captures keep their original
identities and are not relabelled as v3. The v3 product run on this preparation branch
reaches 50/51 declared requests and 44 observations with three unmatched requests.
`t1.toc`, `p1.toc` and `n1.toc` are the incomplete rows: the first two request the
pre-option TOC addresses, and the null-return counter read leaves the TOC chapter title
empty. The O pair consumes the identical retained hit; both details publish the
retained `identityAddress` (the analyzed targets stay in the request trace). The
product's cached first call skips the source-authored option `js`, so the fresh call's
counter is 1 and it sends `/o/book/1` (not the declared `/o/book/2`), while the frozen
runs the script twice. That `/1` request lands on the same row's declared selector, so
the actual ownership/count mismatch is retained rather than repaired
(`o1.details-fresh` owns no request and `/o/book/2` is missing; `GET /o/book` is
unmatched). That report is retained as the actual current-product measurement: it is
not a pass, and the comparator refuses an incomplete product record by design. The v3
installed-app capture and comparison remain with the controller and are **not-run**
here.

At the historical v2 observer candidate, built on integration/133 `a175a67`, the Map
repair and the source-context carrier projection were in place. That product session
reached 22 observations and 31 requests, every cleanup receipt was true, and both v2
captures compared with **38 strict differences each**. All 38 are named in
`notCompared` under the four approved dispositions below and **0 are unattributed**;
the strict verdict remains a difference (exit 3), never a pass. Nineteen own-baseline
controls per v2 capture applied and passed, and every control's own new mismatch stayed
unattributed; the eight v3 row controls are not-applicable on a v2 record. Integration,
review, the Windows driven run and #137/#133 acceptance stay with the controller.

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

The replay listener reads each request itself on one owned `ServerSocket`. Published
rows retain the method, literal request target and original header lines. A
`Content-Length` body is read for every method; responses are matched by literal
method + raw path + raw query, and unsupported or ambiguous framing is a named refusal. The held response keeps its
connection open so the peer's own close is observable while nothing has been written,
and only the connection that entered the hold can report that abort: an unrelated idle
connection's close is not the held request's abort. The abort receipt is that close (or
the failing write on the held request), never an assumption, and a locally closed
listener never invents one. Cleanup is ordered and truthful: the listener stops admitting and releases its gates,
the owned cancellation worker is joined, and only then are the database snapshot, the
database close and the native disposal attempted, each independently, so one failing
step cannot skip the rest or lose the collected trace; the run's `ownedTeardown`
receipt records what was attempted, what completed and each error, and an unresolved
worker performs none of those steps and keeps its owned residue. The cancelled
execution is the HTML pipeline the search actually ran on, so `jobInactive`/`jobDone` read that pipeline's own `cancelled` state (before the
request, at the cancel request and after the worker settled) together with the
worker termination, the quiet window and the late-request count; no unrelated
cancellation token stands in for it. The follow-up row opens a new pipeline (its own
cancellation and transport) over the same source object and key before invoking it.

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
- The causal chronology: every row's complete `(selector, attempt)` identity, its
  declared dependency, the run's step order (a sequential step cannot be entered
  twice or reached after a later one) and each selector's attempt kinds. Declared
  ordered prefixes are ordered; only a declared cohort is a multiset, and arrival
  or completion order is never compared inside one.
- Both sides' identity pins (corpus LF hash, target package/APK/baseline) and the
  frozen capture's own receipts (`terminalIntegrityOk`, `promotable`,
  `requestCheck.match`, `observationCheck.match`, cleanup integrity), so a mutated
  copy is a visible difference rather than an unchecked assumption.
- The product record itself is validated as one bounded schema before any value is
  compared: every compared field must be present with its declared type (an
  integer is an `int`, so a widened `200.0` is refused), explicit nulls stay
  distinct from absence, and object key order is never a fact (arrays, duplicate
  values and raw bytes keep their order). The headline booleans must agree with
  the rows they summarise: each observation's `requests` recomputed from the
  trace, `headerLines` re-derived from `headers` (header names case-insensitive,
  values exact), `bodyLength`/`bodySha256` from the body, every
  `requestCheck.steps` count/order/batch flag re-derived from the rows and
  `requestCheck.match` from those, `observationCheck` from the observation set,
  `structural.declared` against the corpus' own declared model and
  `structural.derived` recomputed, the cleanup flags against the nested `terminal`
  block, `lateErrorCount` against `serverErrors`, the failure endpoint's counts
  against its own connection list (each armed, observed, terminated after
  acceptance), and the inventory against the four tables this observer actually
  reads (`books`, `chapters`, `source_entries`, `source_cookies`). Each request's
  send cannot precede its own arrival and its stage must name a measured step. The
  stage trace must be the measured rows' own four-field **multiset**: a duplicated
  entry can never stand in for a distinct request, while a reversed trace and the
  identical retry rows keep exactly their counted multiplicities. The cancellation
  row's measured `cancellationState`, the follow-up's fresh execution identities
  (same run only) and every rate operation's own interval, duration, source key,
  record chain and window relation are checked, so a claim and its evidence cannot
  disagree. An abort is proven by exactly one of the runner's two measured
  branches: a present nullable `peerClosed` holding a non-empty string, or a
  non-empty `abortError` on the bound held request whose terminal is
  `client-aborted`; an unrelated request or a bare observation key is not a
  receipt. Both `dbProvenance` snapshots must be actual measurements over the same
  four tables with non-negative integer counts before they are compared. Two
  captures must be two independently captured runs (distinct id, report path,
  report hash and run id).
- The product's own gates and cleanup receipts (listeners, bridge, database,
  scratch removal), its inventory ("opened and empty before and after" — the table
  names are each runtime's own schema) and the failure endpoint's measured
  `acceptedConnections` / `transportReconnects`.
- The approved named differences: a strict mismatch stays in `mismatches`, and the
  amended differential contract's four approved cases also appear once each in
  `notCompared` with their exact `surface`/`row`/`field`, `expected`, `observed`
  and reason. They are the configured `ajaxAll` width and its measured 5-member
  cohort consequences, the declared TOC/content page-list scheduling and its
  measured cohort/request consequences, the zero-argument `getHeaderMap` extension
  (only while its value equals the product's explicit `getHeaderMap(false)` form),
  and the two cancellation-owner labels. `unattributedCount` is
  `mismatchCount - notComparedCount`; an unknown width, peak, result or label, a
  corrupt zero-argument map or any other changed behavioural fact remains an
  unattributed failure. Approval never turns a difference into a pass.

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
  `scheduleComplete`, the within-run call interval and the window advance; its
  type, `isConcurrent`, `frequency`, the record chain and the first record's own
  operation interval are compared exactly, so one coherent cross-host epoch
  translation stays valid while a zeroed, non-numeric or out-of-interval time is
  refused;
- the failure endpoint's assigned port, its nanosecond stamps and its host header,
  and the owner manifest's timestamp;
- header **name case and order** and the differential contract's platform-generated
  `Host`, `Content-Length`, `Accept-Encoding` and `Connection` (a name the corpus
  declares required or forbidden is never filtered);
- `headerLines`, which is the same facts as `headers` with wire case and order.

No wildcard, no fuzzy text and no lower-bound proxy exists in this comparer. A
`notCompared` entry is not an exemption: it names one strict mismatch, its actual
expected/observed values and the approved reason, and every mismatch it does not
name stays an unattributed failure.

## Controls

Twenty-seven controls run on deep copies of the immutable captures and of the product
record; each is compared against **its own** baseline, so a row the baseline already
reports can never satisfy a control. A control passes only when it introduces a new
strict mismatch and the approved disposition leaves every one of those new keys
unattributed. The controls are: product value, golden value, product raw query,
product retry attempt, product identity, product presence, product receipt, golden
receipt (native provenance), an undeclared extra request, a product header, a
product body, a product attempt kind, a real cohort peak
(`helper.ajaxAll-order.value.batch.inFlightPeak`, a fact that genuinely matches at
baseline), the retry row order, the sequential step order, the held row's terminal,
and three wrong-behaviour probes added with the carrier projection: a changed search
result `origin`, a changed search result `type`, and a broken cancellation
`workerTerminated` receipt; eight v3 row controls then cover a changed script-probe
projection member, a removed native-return `latestChapterTitle`, a wrong retained
`bookUrl` on the same row, a substituted retained address on the fresh row, the
request consequence of a reused fresh pipeline (with a counter fallback when a record
has no request row), a genuine extra execution on the same row (counter 1 -> 2), a
genuine missing execution on the fresh row (counter 2 -> 1), and a changed
counter-backed TOC chapter title. Each is compared against its own otherwise-identical
baseline, including baselines that already carry unrelated strict differences. The aggregate result keeps every capture's rows, so
neither capture's controls can hide the other's. Originals are re-hashed after the
run and stay byte-identical.

## Approved product behavior and repair acceptance

Spec A #133/#137 and the differential contract retain `ajaxAll`'s default width 4
and the current serial page-list walk. The frozen widths and actual cohort/request
facts remain visible as named scheduling differences. A replay cohort-window is an
arrival-shape probe; it provides no real-site performance comparison. Pagination
changes first need real-source waiting-time, timeout/rate-limit and cancellation
measurements; the approved later option is at most four network fetches collected
in declared order, preserving #26's serialized analyses/prefetch and serial
next-URL-discovery chains.

The Map repair already answers the Java-Map key-set/iterator access used by the
fixture's explicit false/true header-map calls, including the shared login-header
and login-information map callers. Existing zero-argument calls, property reads and
`.get()` remain supported. The resulting zero-argument script difference is
reported with both actual results, not converted into a product refusal; its value
must still equal the product's explicit false/default form.

Search `origin`/`originName` and search book `type`, plus details `origin`, are
projected from the actual source/book context with their derivation retained as
provenance. No field is filled from a golden and no database shape or value changes.
The frozen mapping is `getBookType()` at `14dd2494`: `bookSourceType` 1/2/3 answer
32/64/136 and the default or any other value answers 8.

Cancellation retains `created-parent` and `pipeline-cancellation` as each side's
own provenance label. Acceptance checks requests/scripts stopping, late side
effects, terminal state, state preservation, resource release and the fresh
follow-up operation. The label difference is recorded explicitly; it does not
remove the cancellation row or any behavioral assertion.

The comparer retains its strict difference list and exit semantics and reports the
four approved named differences in `notCompared`; a scheduling or zero-argument
divergence is not a frozen compatibility pass. The 56 historical differences below
remain the pre-repair result bound to `b7fc3cf`; the historical v2 candidate's measured
38 are listed next. No v3 capture exists on this branch, so this document makes no v3
difference list and no v3 claim; the new rows' actual frozen/product differences must
come from the controller's executed v3 comparison.

## The historical v2 named differences

The historical v2 observer candidate records 38 strict differences per capture, each
one named by the classifier above and none left unattributed:

1. **Configured `ajaxAll` width — 16 entries.** `runtimeConfiguration.threadCount`
   16 → 4, each helper batch row's `value.batch.threadCount` 16 → 4, and the declared
   5-member cohort's measured consequences: `cohortComplete` true → false,
   `releaseReason` "complete" → "cohort-window", `inFlightPeak` 5 → 4, and the same
   two cohort facts on each of its five declared request rows.
2. **Declared page-list scheduling — 16 entries.** `s1.toc` and `s1.content` record
   `threadCount` 16 → 1, their tails' `cohortComplete` true → false,
   `releaseReason` "complete" → "cohort-window", `inFlightPeak` 2 → 1, and the same
   two cohort facts on their four declared tail request rows.
3. **Zero-argument `getHeaderMap` — 4 entries.** The two header-map rows record the
   product's zero-argument result where the frozen binding refused: `returned`
   false → true and the observed value list, which equals that row's explicit
   `getHeaderMap(false)` result.
4. **Cancellation-owner provenance — 2 entries.** `s5.search-cancelled`
   `execution.jobLevel` and `s6.search-after-cancel` `followUp.jobLevel` read
   `created-parent` → `pipeline-cancellation`; every behavioural cancellation
   receipt and the fresh follow-up remain strictly compared.

The former book-carrier and explicit false/true header-map differences are gone:
those fields now match the frozen values. The 56 differences retained below are the
pre-repair measurement at `b7fc3cf` and are not this candidate's result.

## The retained pre-repair differences (all strict failures at `b7fc3cf`)

Both captures produce the same 56 differences, grouped by cause:

1. **Configured batch width** — `runtimeConfiguration.threadCount` 16 vs 4, and every
   batch row's `value.batch.threadCount`. The frozen reads `AppConfig.threadCount`
   (default 16). The product's configuration is recorded per family from the code that
   actually runs the batch: the helper `ajaxAll` batches use
   `SourceHostDispatcher.ajaxAll`'s default 4, while the TOC and content pagination
   tails run `walkSourcePages`, which fetches the declared next pages one at a time
   (`lib/source/source_page_results.dart`), so their rows record 1 against the frozen
   16. Each cohort's `evidence.batch` names which configuration it measured; a measured
   peak is never reported as a configured width.
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

These are the original measured facts. The approved dispositions above governed the
repair and this candidate's measurement; this historical result is not relabelled as
pass.

## Limits

One product session is compared with both independently captured positives, which
must be two distinct captured runs; nothing is fabricated from a capture or a raw
script rerun. The canonical LF corpus hash is the semantic identity, so an LF or a
CRLF working copy of the same corpus is equally acceptable; each capture's bundled
asset hash is checked against the asset its capture manifest pinned, never against
whatever line endings this checkout happens to have. The corpus, captures, handoff
and native producer remain immutable inputs to the product repair. This work
introduces no Rust, persistence or transport-policy change, and this document
closes no capability row, #137 or #133.
