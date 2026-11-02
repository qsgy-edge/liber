# HTTP-BOUNDARY-01 — the product side of the frozen ordinary-HTTP corpus

`tool/http_boundary/fixtures.json`, `tool/nested_oracle/HttpBoundaryOracle.java` and
the controller's captures are the producer lane's shared boundary. This file and the
two Dart entry points beside it are the product lane: they run the corpus through
the product's own ordinary HTTP surface, compare every portable value and wire fact
with both frozen captures of the controller's hash-bound handoff, and report what
still differs. Nothing here is a compatibility claim, and nothing here can turn a
difference into a pass.

The historical corpus is **version 3**: 16 sources, 44 observations, 51 ordinary
requests and five declared cohorts. It covers native-return string probes, Java-Map
member collisions and URL-option execution through the actual four-stage product
path. The same/fresh details pair consumes the identical retained hit and publishes
its retained identity; request-option scripts run at each actual request.

The CLI accepts the controller's hash-bound v3 handoff at reviewed native-source
anchor `276a625e4aef0104240beac1908e597c6023ef93`. That handoff keeps the actual
producer/build commit, corpus asset, signed harness and original positive/negative
run identities. The destination checkout, runner and native library have their own
execution binding. Earlier v2 captures retain their v2 identity.

## Selected-reference commands

The historical v3 captures retain their identity. Use the separate selected v4
corpus explicitly for a fresh selected product run and its comparison:

```bash
dart run tool/http_boundary/runner.dart <fjs.dll> <fresh-root> <report.json> \
  --corpus=tool/http_boundary/fixtures-selected.json

dart run tool/http_boundary/compare.dart --handoff=<selected-handoff.json> \
  --product=<report.json> --evidence=<fresh-evidence-dir> \
  --corpus=tool/http_boundary/fixtures-selected.json
```

`io.liber.oracle.nested.SelectedHttpBoundaryOracle` is the selected native
instrumentation entry. Capture remains controller-owned and is not established
by these commands or by selecting a corpus.

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
  differential contract's five approved groups also appear once each in
  `notCompared` with their exact `surface`/`row`/`field`, `expected`, `observed`
  and reason. They cover configured `ajaxAll` width and measured cohort facts,
  declared TOC/content page-list scheduling, zero-argument `getHeaderMap` while its
  value equals the product's explicit false/default form, the two cancellation-owner
  labels, and the 14 measured Java-return-string type/strict-equality fields.
  `unattributedCount` is `mismatchCount - notComparedCount`; an unknown width, peak,
  result, label, text or other changed behavioral fact remains unattributed.

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

Thirty-one controls run on deep copies of the immutable captures and of the product
record; each is checked against **its own** baseline, so an existing difference
cannot satisfy a control. A portable-value control must introduce a new strict
mismatch whose new keys all remain unattributed. A measured-relation control must
start from a valid relation and make its own mutation fail the shared admission
rule; its precise failure is recorded in `relationFailure`. The controls are:
product value, golden value, product raw query,
product retry attempt, product identity, product presence, product receipt, golden
receipt (native provenance), an undeclared extra request, a product header, a
product body, a product attempt kind, a real cohort peak
(`helper.ajaxAll-order.value.batch.inFlightPeak`, a fact that genuinely matches at
baseline), the retry row order, the sequential step order, the held row's terminal,
and three wrong-behaviour probes added with the carrier projection: a changed search
result `origin`, a changed search result `type`, and a broken cancellation
`workerTerminated` receipt; twelve v3 row controls then cover a changed script-probe
projection member, a removed native-return `latestChapterTitle`, a wrong retained
`bookUrl` on the same row, and measured-relation failures for a substituted retained
hit, a reused fresh pipeline, a reused fresh transport, a wrong source object, a wrong
stored hit and a golden retained-book identity, plus a genuine extra execution on the
same row (counter 1 -> 2), a genuine missing execution on the fresh row (counter 2 -> 1),
and a changed counter-backed TOC chapter title. Relation controls mutate the actual
identity and run the same pure admission rule; an invalid baseline is refused. Every
control is checked against its own otherwise-identical baseline, including baselines
that already carry unrelated strict differences. The aggregate result keeps every
capture's rows, so
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

## Named differences

The strict difference list and exit semantics retain every measured value. The
existing classifier names only these contract-approved boundaries:

| Group | Exact scope |
|---|---|
| `ajaxall-configured-width` | The configured helper width and the declared five-member cohort's measured release/peak/request consequences |
| `page-list-scheduling` | The declared TOC/content page-list widths and their measured cohort/request consequences; collected values and order remain strict |
| `header-map-zero-arity` | The frozen zero-argument refusal versus the supported product result, only while that result equals its explicit false/default form |
| `cancellation-owner-provenance` | `created-parent` versus `pipeline-cancellation`; all behavioral cancellation and fresh-follow-up receipts remain strict |
| `java-return-string-identity` | Twelve enumerated helper leaves on `helper.script-probe-hg0`–`hg3` plus `v1.details.value.latestChapterTitle` and `v1.content.value.text`; exact type/strict value directions, own source/step tags and complete envelope shapes are required |

The Java-return disposition retains primitive JS strings. Text, coercions, loose
equality, booleans, injected bindings and all unenumerated fields keep their strict
comparison. The two stringified probe envelopes require their complete 23/20-key
shape and the measured 10/8-axis changes, with every other key/value equal. A full
cross-segment Java-object carrier remains a separate #128 decision.

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
