# HTTP-BOUNDARY-01 — ordinary HTTP/helper/rate/terminal corpus (#137 / Spec A #133)

One controlled corpus for the frozen `io.legado.app.debug` ordinary HTTP boundary that
AUTH-SESSION-01 and REQUEST-01 deliberately left to #137: `JsExtensions.ajax` /
`ajaxAll` / `connect`, the three source-script `getHeaderMap` arities (with the Kotlin
default call kept as provenance), the real source-keyed `ConcurrentRateLimiter` record,
non-2xx retry, declared multi-URL pagination, empty required results, a task-owned
connection failure, real gated cancellation and later same-source use.

`fixtures.json` is data, not a golden. Every compared value in a produced report is
read from a real frozen API, a real `StrResponse.body()`, or the requests the frozen
HTTP stack actually sent. No expected value is transcribed from this corpus.

**Status: the collector is implemented, host-compiled, dexed, packaged, signed and
structurally checked. No handset execution has happened in this producer lane.** A
report produced by the controller is a capture candidate; only the controller's
hash-bound handoff (`E/controller/a2-http-session-handoff.json`) can make it evidence.

## Measurement and cleanup contract

- The header-map rows execute one fixture-authored projection per arity through
  `AnalyzeUrl.evalJS`/`source`. A thrown arity keeps its measured `returned:false`; the
  Kotlin default call is explicit provenance only.
- `stepCancel` derives `cancelled`/`cancellation` from the measured cancellation and
  validated receipts; the follow-up is bound before invocation to its own
  created-parent Job/context and the same source object/key, with freshness measured by
  object identity.
- `probeState` keeps null distinct from `"null"` and makes an unresolved getter/query
  incomplete; `dbCounts` is strict. The rate record's Java class and the native DB table
  snapshot are provenance, not compared fields.
- The final request trace is validated as a whole against the actual emitted raw
  record: declared total, every owner, typed `listener`/`stage` and all other required
  fields, required headers, coherent method/path/rawQuery/target/query/headerLines, owner
  family and the actually selected declaration, honest terminals, and exactly the one
  declared negative omission. A singleton's `cohort` must be present as explicit null
  while a batch member's is a declared string; `declaredResponse` is a string except for
  the native omission. A pending or extra ownerless shutdown request fails.
- Cohort value keeps capability facts; the gate's planned release and the measured
  server send order are separated in evidence. In-flight peak is measured through each
  request's terminal.
- A held response distinguishes a peer abort from local teardown and expiry by the
  release/abort timestamps; only a peer abort yields `client-aborted`.
- Cleanup signals cancellation, releases gates, then awaits owned worker/job completion.
  An unproved handle stops all database, limiter, preference and root work; the owned
  residue and ownership metadata are preserved for controller force-stop cleanup.
- Actual `AppConfig.threadCount` is required; a failed read is incomplete, not a guessed
  default.

## Corpus shape

| Item | Value |
|---|---|
| fixture id | `HTTP-BOUNDARY-01`, corpus version 1, schema 1 |
| baseline | `14dd24945b2914ce2708b8abaa4ee67ceef892af` |
| target pin | `io.legado.app.debug`, APK SHA-256 `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6` (the AUTH pin) |
| origin | exactly `http://127.0.0.1:18771`; one loopback listener, no wildcard, no alternate port |
| sources | 6: `H1` static header, `H2` `@js:` header, `H3` `<js>` header, `S` HTML stages, `R` `concurrentRate 1/2000`, `F` task-owned failure endpoint |
| observations | 22 ids |
| ordinary HTTP requests | 31 |
| response declarations | 29 unique selectors |
| helper | 12 selectors: 4 singleton (`/h1/single`, `/h1/first`, `/h1/connect`, `/h1/connect-source`), batch 3 (`/h1/order/1..3`), batch 5 (`/h1/width/1..5`) |
| rate | 3 selectors `/r/1../r/3`, sequential |
| stages | 14 selectors, 16 requests (`s2.retry-non2xx` repeats one selector three times) |
| cohorts | `helper.order` 3, `helper.width` 5, `stage.toc-tail` 2, `stage.content-tail` 2 |
| harness entry | `io.liber.oracle.nested.HttpBoundaryOracle` |

Every source declares `User-Agent: HTTP-BOUNDARY-01/1.0`, including the two script
header forms, so header arity/replacement is tested without a default-UA exemption.
Every source is `enabledCookieJar:false`, has no login script and no `jsLib`.

The counts above are **structural**, not observations. `HttpBoundaryOracle.indexCorpus`
and `validateCorpus` derive them from the step declarations and refuse the corpus when
the declared `structural` block differs; the host check (`structural_check.py`, see
Verification) re-derives the same numbers from the committed bytes.

`$FAILPORT` in source `F` is the only declared fixture binding: the collector binds a
task-owned ephemeral `127.0.0.1` listener, substitutes its assigned port, and refuses
any other token. It is not a general URL rewrite.

## What each row exercises

Helper (8 observations, no stage involved):

| id | real entry | control |
|---|---|---|
| `helper.ajax` | `java.ajax('…/h1/single')` | one body |
| `helper.ajax-list-first` | `java.ajax([first, second])` | only `first` may be requested; `/h1/second` is undeclared, so a second-URL request is an unmatched request |
| `helper.ajaxAll-order` | `java.ajaxAll([3 urls])` through the real loop `r[i].body()` | ordered joined bodies, cohort 3, exact peak |
| `helper.ajaxAll-width` | `java.ajaxAll([5 urls])` | ordered joined bodies, cohort 5, exact peak |
| `helper.connect-header-string` | `java.connect(url, headerJson)` | `x-from-header`/`user-agent` replaced, `x-declared` forbidden |
| `helper.connect-source-header` | `java.connect(url)` | source `x-declared`/`user-agent` |
| `helper.header-map-js` | three fixture-authored scripts through `AnalyzeUrl.evalJS` calling `source.getHeaderMap()`, `(false)`, `(true)` on `@js:` | one typed `returned` record per arity plus the actual primitive map; a thrown arity keeps its real outcome; the Kotlin `$default` call is provenance only |
| `helper.header-map-ltjs` | same on `<js>` spelling | same shape |

Rate (3 observations). The corpus value `1/2000` is a **synthetic fixture input**; the
frozen `ConcurrentRateLimiter` semantics are preserved. Each row reads
`AnalyzeUrl$ConcurrentRecord` from the real source-keyed
`concurrentRecordMap` before and after the call:

| id | expected real relation |
|---|---|
| `rate.record.1` | map entry absent before; after `{isConcurrent:true, frequency:1, time:t1}` |
| `rate.record.2` | after `frequency:2`, `time == t1` (same window), call inside `t1+2000` |
| `rate.record.3` | after the configured wait `time >= t1 + 2000`, `frequency` reset to 1 |

The third admission must respect the window. Explicit `sameWindowAsPrevious`,
`scheduleComplete` and `scheduleReason` record whether the harness met its own
scheduling precondition; a missed precondition is `incomplete-schedule`, never a false
implementation verdict. Epoch values are compared only through these relations, never
across hosts. The map field is resolved on its actual declaring class (outer class
first, then the Companion); unrelated records are never erased.

Stages (11 observations):

| id | stage | requests | checked |
|---|---|---|---|
| `s1.search` | search `b1` | 1 | ordered search result fields |
| `s1.details` | details book 1 | 1 | book fields and `tocUrl` |
| `s1.toc` | toc book 1 | ordered prefix `toc1` + tail batch `{toc2,toc3}` | ordered chapters `c1,c2,c3`; peak 2 |
| `s1.content` | content chapter c1 | ordered prefix `ch1` + tail batch `{ch1-2,ch1-3}` | exact `P1\nP2\nP3`; peak 2 |
| `s2.retry-non2xx` | search `b4` (`retry:2`) | 3 attempts of one selector, 502 body | parsed results; `attemptKind` 1 `initial` then 2 `source-status-retry` |
| `s3.toc-empty.search/details/toc` | search/details/toc book 2 | 1 + 1 + 1 | toc outcome `failure`, category `empty-required-result` |
| `s4.search-connection-failure` | search `fail` on source `F` | 0 ordinary requests | row `failure`/`network-failure`; fail-endpoint connections recorded separately |
| `s5.search-cancelled` | search `hold`, then real `Job.cancel` | 1 held request | `cancelled` + abort/termination/no-late/state receipts |
| `s6.search-after-cancel` | search `after` on the same source | 1 | results + fresh execution token |

`s1.search` is also the `retry:2`-on-2xx proof (exactly 1 attempt). `s2` is the
`retry+1` proof, and the last 502 body is parsed, not raised.

## Matching and request ownership

- A request is matched by exact `method` + `path` + the **raw query bytes** the client
  sent. Each declared selector is unique and each selector belongs to exactly one
  causal step, resolved from the corpus at load time. A late request keeps its declared
  owner even when the mutable `stage` has moved on; a request with no declaration is an
  `unmatchedRequests` entry and fails the capture.
- Each record carries `attempt` (1-based) and `attemptKind`: `initial`,
  `source-status-retry` (the previous attempt for that selector received a response) or
  `transport-reconnect` (the previous attempt received none). The two retry kinds are
  never folded into one count.
- Sequential prefixes are ordered; declared concurrent tails are compared as
  multisets, while the returned chapter/content order is the frozen `mapAsync` emission
  order (declared order) and is compared exactly.
- `requestCheck` is the collector's own structural gate over the whole final trace: the
  declared total (31), every causal owner (no ownerless or unknown-owner record), per
  step count, ordered prefix, batch multiset, required raw fields/types, required
  source-controlled header values (a missing header object is a failure, not a skip) and
  per-step/global forbidden headers (`cookie` globally; `x-declared` on the
  header-string row).
- Every request carries an explicit honest terminal: `responded` (successful server
  flush with `sentAtNanos`/`sendSequence`/status), `client-aborted` (only the held
  cancel request, no response fact), `omitted-unmatched` (only the one declared negative
  omission) or `rejected-after-shutdown`. `received`, `held`,
  `hold-released-at-teardown`, `hold-window-expired` and any shutdown rejection are
  non-success terminals; an extra ownerless shutdown request fails the total and owner
  accounting.

## Cohorts, holds and the failure endpoint

- A cohort member is held until every declared member is in flight or the 5 s cohort
  window expires. The compared batch block records `cohortSize`, `cohortTimeoutMs`,
  `cohortComplete`, `releaseReason` (`complete` or `cohort-window`), the exact
  `inFlightPeak` (requests fully read but unanswered until their own response flush, not
  sockets), the sorted `membership`, and the real `threadCount` read from the scratch
  `AppCtx`. A window release is a measurement outcome, not an infrastructure timeout.
  `evidence.batch` separately records the gate's `plannedReleaseOrder` (a decision made
  before any send), the measured `actualSendOrder` from response flush completions, the
  arrival order and `clientCompletionUnobserved: true`. A planned reverse index is never
  named the actual send order.
- The connection-failure row uses a task-owned listener bound to `127.0.0.1:0`. It is
  bound before sources load and armed for the failure step; every accepted connection is
  read, recorded and closed without a response. Only that listener may be reached, and
  unexpected activity fails closed. Because no response is ever written, the frozen
  source-status retry (`OkHttpUtils.kt:29-43`) cannot occur; later connections are
  classified `transport-reconnect`. `$FAILPORT` connections are a separate trace and are
  **not** part of the 31 ordinary HTTP requests.
- Cancellation is triggered only after the replay confirms the hold was entered. It uses
  the real `JobKt.Job(null)` + `CoroutineContext.plus` + two-argument `runBlocking` +
  `Job.cancel` entry and derives the row outcome/category from the measured cancellation
  and validated receipts (`clientAborted`, `workerTerminated`, `jobInactive`, empty
  `lateRequests`, unchanged portable state probes, unchanged raw database snapshot). An
  expiry or a teardown-only release is never accepted as an abort. The created parent
  job/context/source identities are recorded; an unresolvable entry or a missing receipt
  makes the row `incomplete`, never an `ok` row and never a fake success.
- The post-cancellation search is bound **before invocation** to its own created-parent
  `Job`/context, and to the same source object/key. `value.followUp` compares measured
  `jobIdentityFresh`, `contextIdentityFresh`, `sameSourceObject`, `sameSourceKey` and
  `jobClosed`; the UUIDs and identity hashes are provenance only. A parent Job is
  compared with a parent Job, never with its child coroutine.

## Containment, startup and cleanup

- `Instrumentation.newApplication` returns a storage-only `android.app.Application`
  over the existing package-visible
  `StateSessionOracle.ScratchContext(base, "liber-http-boundary-01",
  "liber_http_boundary_01_")`. Frozen `App.onCreate` never runs; no WebView API and no
  data-directory suffix is touched anywhere in the collector.
- `scratch.bind("seed", identity)` runs before the database or any preference read. The
  seed probe and the scoped preference namespace prove the storage belongs to the task.
  `threadCount` (and therefore `ajaxAll` / pagination concurrency) is read from the real
  `AppConfig.getThreadCount()` on the isolated scratch `AppCtx`, never from operator
  preferences; an unavailable actual configuration makes the capture incomplete and is
  never replaced with a guessed default. The database is opened because `BookContent`
  queries chapter rows even with save disabled.
- One cleanup order, on success or failure: stop admission → cancel unfinished owned
  jobs → release/abort every hold and cohort → close listeners and await owned
  worker/executor termination → close the database → final terminal snapshot → fence
  every owned preference so a background `apply()` write cannot outlive the run →
  remove only the proven owned preference union → remove the root → assemble the report.
  Gates are freed before workers are joined. A worker/job handle whose termination is
  not proved keeps its handle; when any owned resource is uncertain the collector
  preserves the owned root and preferences (`cleanup.preservedForController: true`) for
  controller force-stop cleanup instead of deleting beneath it. The owner manifest,
  owned preference names and pre/post XML+BAK residue metadata are copied into the
  report **before** any removal, so the controller can check late residue after
  force-stop.
- The report leaves the device only on the instrumentation stream
  (`HTTP_BOUNDARY_ORACLE_BASE64=<base64 JSON>`). A watchdog expiry emits an explicitly
  `incomplete` diagnostic, never a golden.

## Report shape (for the consumer lane)

Top level: `fixtureId`, `schemaVersion`, `corpusVersion`, `baselineCommit`, `entryPoint`,
`platform`, `fingerprint`, `recordedAt`, `runId`, `pid`, `captureKind`, `status`
(`ok`/`incomplete`), `promotable`, `negativeMode`, `negative`, `identity`, `structural`,
`isolation`, `runtimeConfiguration`, `rateLimiter`, `failEndpoint`, `stageTrace`,
`requests`, `unmatchedRequests`, `serverErrors`, `requestCheck`, `observations`,
`observationCheck`, `inventory`, `cleanup`, `sourceDerivedNotes`, `coverageGaps`,
`nondeterministic`, `analysisFailure`.

- `observations[]` = one row per declared step: `id`, `outcome`
  (`ok`/`failure`/`cancelled`/`incomplete`), `category` (`null`,
  `empty-required-result`, `network-failure`, `cancellation`, `unresolved-entry`),
  `value` (the compared surface), `evidence` (provenance only) and the step's request
  slice.
- `requests[]` = the exact arrival trace: `index`, `owner`, `family`, `cohort`,
  `attempt`, `attemptKind`, `selector`, `method`, `target`, `path`, `rawQuery`, `query`,
  `headers`, `headerLines`, `body`, `bodyLength`, `bodySha256`, `receivedAtNanos`,
  `sentAtNanos`, `sendSequence`, `respondedAtNanos`, `status`, `terminal`,
  `declaredResponse`, `outcome`, `stage`.
- `requestCheck` = per-step derived/actual, `totalMatch`, `ownerless`,
  `unknownOwners`, `duplicateIndices`, `fieldProblems`, `terminalProblems`,
  `intendedOmission`, `otherUnmatched`, `unmatchedPolicyOk`, server errors and the
  forbidden-header result. `match` is the full integrity predicate.
- `cleanup` = admission/jobs/gates/replay/fail-endpoint/database/terminal receipts,
  `preservedForController`, owner manifest, owned preferences, residue and removal
  result. `terminal.resources` is the final listener/worker/executor/connection/database
  snapshot; `terminal.integrityOk` is the exact success gate.
- Compare every `value`/row/request field except the list in
  `nondeterministic` (`recordedAt`, `runId`, `pid`, `stageTrace`, arrival/response
  nanoseconds, `sendSequence`, `stage`, `evidence` (including `evidence.batch` planned
  and actual send order, `evidence.dbProvenance`, `evidence.rate` class names,
  `evidence.arityProvenance` and `evidence.followUpExecution`), the rate `time` values
  used only through their relations, the fail endpoint's ephemeral port/connection
  timestamps/host header, and the owner manifest timestamp). Every capability field is
  compared; nothing is dropped silently. `not-run` or unknown is never promoted.
- On `rate.record.*`, compare `isConcurrent` and `frequency` exactly, and `time` only
  through `sameWindowAsPrevious`, `scheduleComplete` and the recorded
  `windowAdvanceMillis` relation.

## Capturing it (controller only)

Build the harness with the repository's portable JDK 17 and build-tools 35.0.1
(`pwsh tool/nested_oracle/build.ps1 -OutputDirectory <fresh> -JavaHome <jdk-17>`), pull
and verify the installed frozen APK at the pin, then, for each of two fresh runs:

```bash
adb -s 5615f742 shell am instrument -w -r \
  io.liber.oracle.nested/io.liber.oracle.nested.HttpBoundaryOracle
adb -s 5615f742 shell am force-stop io.legado.app.debug
```

and once for the executed replay-omission control:

```bash
adb -s 5615f742 shell am instrument -w -r -e negative drop=h1-single \
  io.liber.oracle.nested/io.liber.oracle.nested.HttpBoundaryOracle
adb -s 5615f742 shell am force-stop io.legado.app.debug
```

- The negative control validates the immutable corpus first and then omits
  `GET /h1/single?` from the in-memory active set, so `helper.ajax` really reaches
  replay, gets the 404 placeholder and appears as exactly one `omitted-unmatched`
  terminal in `unmatchedRequests`. Merely failing corpus validation before any request is
  **not** this control. The negative report has `negativeMode:true`,
  `status:"incomplete"`, `promotable:false` and must never become a golden. Its
  `negative.integrityOk` must still be true: the omission may not excuse another
  malformed, extra or error row.
- A positive capture is promotable only with `status:"ok"`, zero unmatched requests and
  server errors, all 22 rows matching their expected outcome/category/request counts,
  the follow-up execution proven fresh/same-source, complete resource receipts,
  `terminal.integrityOk:true` and a true cleanup. A cohort-window release or a real
  frozen/product difference is a measurement, not a harness failure; a step/watchdog
  deadline, wrong reflection, replay error or cleanup failure is.
- After each run the controller force-stops the target, verifies no `pidof` process,
  independently checks the recorded owned preference XML/BAK and root absence, hashes
  the raw capture, and writes the handoff. The two positive captures must agree after
  the documented exclusions. Root absence alone is insufficient evidence.

## Verification performed by this producer

- `javac -source 8 -target 8` against `android-35/android.jar`, `build.ps1` into a fresh
  directory, `d8` dexing, `aapt` packaging, `apksigner verify --print-certs` (v2+v3,
  existing Android debug certificate `954abf2c…b2f2ad`), and a manifest/dex check that
  the new instrumentation is registered and packaged.
- The bundled `assets/http-boundary-fixtures.json` is byte-identical to the committed
  corpus (raw hash below), and the report records the raw and LF-normalised hash.
- Host structural check re-derives selectors, owners, cohorts, the 22/31/29 model and
  both line-ending identity forms from the committed bytes; its output and the build
  receipts are under `E/a2-http-native/presence-repair-03/`.
- The host probes execute the terminal, hold, cleanup and full raw-record presence/type
  sweep on the actual compiled methods with complete positive counterparts; every
  missing/null/wrong-type control is rejected and the allowed nullable cases pass. Host
  checks are never device goldens.
- No ADB, phone, install, app/Driver, target/Rust/Flutter build, dependency or config
  change happened here.

Pinned corpus identity (this checkout):

```
raw (CRLF) sha256  63e5702878a413ad2f8e4fa760dae6e6ebcb95043d94390882e62699668a2db5
LF-normalised sha256 12e58825243434a42a0741f6a0d02d014efec48ae2334c352962ef1ed7a22d54
```

`core.autocrlf=true` materialises a fresh Windows checkout as CRLF; the LF form is
what the comparator's identity rules normalise to. Both are pinned in the report.

## Real entry points (frozen `14dd2494…`)

- `JsExtensions.ajax` (`:91-106`), `ajaxAll` (`:111-125`), `connect(String)`
  (`:127-141`), `connect(String,String)` (`:143-158`).
- `BaseSource.getHeaderMap` (`BaseSource.kt:103-130`), `getKey`/`getHeader`.
- `AnalyzeUrl` constructor, `evalJS` (`:340-360`), `getStrResponseAwait`
  (`:389-461`), rate wrapper (`:397`), `AnalyzeUrl$ConcurrentRecord` (`:825-840`).
- `ConcurrentRateLimiter` (`ConcurrentRateLimiter.kt:11-130`).
- `OkHttpUtils.newCallResponse` (`:29-43`), `Call.await` (`:62-78`).
- `WebBook.searchBookAwait/getBookInfoAwait/getChapterListAwait/getContentAwait`
  (`WebBook.kt:48-83,152-198,224-270,296-355`), `BookChapterList.kt:89-113`,
  `BookContent.kt:110-135`.

## What this corpus does not cover

- No login, cookie-jar on/off, restart or WebView row (AUTH-SESSION-01 / Spec B).
- No POST/form/redirect/body-charset row (REQUEST-01).
- No product implementation and no comparator; the product lane, the SLICE-01
  destination replay, Windows driven verification, integration, publication and ticket
  closure stay with the controller/consumer.
- The recorded #137 residuals (native-return strict equality, URL-option `js` on
  cached/extracted addresses, a `getHeaderMap` data key literally named `get`) are not
  exercised or closed here.
- The 5-vs-4 `ajaxAll` width and 2-vs-1 page-walk differences are source-derived
  findings. This corpus records the real frozen peak; whether a product difference
  becomes a FAIL waiting for a decision is the comparator's job, and no `notCompared`
  or lower-bound proxy is introduced here.

## Ownership

Producer write set: this directory, `tool/nested_oracle/HttpBoundaryOracle.java`, one
asset-copy and one `javac` argument in `tool/nested_oracle/build.ps1`, and one
`<instrumentation>` entry in `tool/nested_oracle/AndroidManifest.xml`. Every existing
oracle, `ScratchContext`, corpus, golden, product/Rust and consumer file is read-only.

The `build.ps1`/manifest edits change the harness APK for any *future* capture. No
existing oracle's code changed, so no existing family needs a re-capture now; no
existing corpus may be re-captured afterward and still claim its recorded producer
identity. A later change to a shared helper (including `ScratchContext`) would force
re-capture of the affected family instead of relabelling historical evidence.
