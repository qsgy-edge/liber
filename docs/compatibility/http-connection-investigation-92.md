# Details connection investigation (#92)

Branch-scoped investigation on base `8e0cca4bfa3ffe32b62822258e14fcae1ad66069`.
The five tests in the evidence directory's
`attribution-tests/source_http_connection_test.dart` are product-side
attribution fixtures, not frozen goldens or a compatibility claim. They are
not committed as product guards because they assert a known recovery gap.
Follow-up [#131](https://github.com/qsgy-edge/liber/issues/131) owns that gap.

The measured direct source sequence **did not reproduce the reported
exception**. On 2026-10-17 the product fetched the book information and first
TOC successfully: HTTP 200, 9083 raw bytes each. A separate same-origin
redirect fixture reproduces a real pooled-connection failure. That fixture does
not explain the historical exception, which names the original URL. In the
current tree that URL starts on a fresh first connection. The historical
message is consistent with an end-of-stream before complete response headers;
the evidence cannot assign a more specific cause, establish historical server
culpability or exclude every possible product contribution. The current
transport can emit that exception: the fresh-original-peer fixture does so.

## Source and execution path

The source is `4020电子书触屏版`, identity `http://m.xwurexs.com#qin`. The
historical backup is `legado-backup-2026-09-17.zip`, SHA-256
`e46452c9b824d41c1333bb58965a7709041c0b46b3fa2ff11372d7b3e4c1abb8`;
its `bookSource.json` has 8787 records. The selected record, saved as UTF-8
JSON with `ensure_ascii=False, indent=2`, has SHA-256
`75bf9d4d0578f9d01a2681cc90231a9205d04c4bb7125a2e60ba0cd264dc5dd3`.
Raw rules remain private and are not reproduced here.

Inspection of that record establishes HTML rules, no `loginCheckJs`, no `jsLib`,
no WebView option and no request-option retry on this book address. Its details
stage fetches the extracted book address with its declared User-Agent and
Referer. Its empty TOC-address rule fetches that same address again, followed
by the next TOC page. `HtmlSourcePipeline.details` → `_fetch` →
`SourceHostDispatcher.request` → `HttpSourceTransport.send` is the executed
path; it is not a WebView, `java.ajax`, login-check or JSON-pipeline fetch.
The measurement starts directly at details, the subset reaching the failure;
it does not need the search response to rediscover the already known book URL.

The operator installation's `network.system_proxy` setting is **unknown** here.
No live scratch installation store was available. The harness sets an in-memory
space's row explicitly to `false` and then `true`, and observes the value passed
to `sourceHttpClient`. `false` is DIRECT. The on measurement follows this
machine's configured proxy without recording its address or credentials.

## Raw product observations

Evidence directory on the measurement host:
`C:/Users/17945/AppData/Local/liber-evidence/batch27/92/`.
`live_probe.dart` and `live-probe-product.jsonl` contain the instrument and raw
results. It subclasses the real transport only to log send/response metadata
and observe TCP connection creation. It does not replace responses or change
request headers, proxy policy, redirects or timeouts.

Run from the ticket worktree after `flutter pub get` and supplying the native
library used by the product:

```sh
cp C:/Users/17945/AppData/Local/liber-evidence/batch27/92/live_probe.dart .dart_tool/issue92_live_probe.dart
dart run .dart_tool/issue92_live_probe.dart D:/GithubRepositories/Flutter/liber-92/build/windows/x64/runner/Debug/fjs.dll C:/Users/17945/AppData/Local/liber-evidence/batch27/92/private-source.json
```

The native artifact is the batch-26 product library, SHA-256
`f09695d5c6794f7d7ed3bc9c306c0131523b339e5a2e7979168646ac59f63ef0`.
Dart 3.12.2 / Flutter 3.44.6, Windows x64. The recorded run begins
`2026-10-17T09:23:15.757810Z`.

| Setting / request | Product result | TCP observation |
| --- | --- | --- |
| Off / book info at `http://m.xwurexs.com/Txt/XiaoShuo-375656.html` | Final URL `http://m.4020xs.com/Txt/XiaoShuo-375656.html`, HTTP 200, 9083 raw bytes | New client; separate connects to original and redirected host |
| Off / first TOC at original book address | Same final URL, HTTP 200, 9083 raw bytes | New client; two separate connects again |
| Off / next TOC at `http://m.4020xs.com/read/375656/index_1.html` | HTTP 200, 9073 raw bytes | New client and connect |
| On / book info and first TOC | Each redirect target answered HTTP 502, 0 raw bytes | New client per send, proxy used for both hosts |

No row produced `Connection closed before full header was received`. The direct
site is reachable; the live transport row was run. Full details/TOC completion
is not claimed: the direct pipeline stopped later on a duplicate chapter,
while the proxy-on pipeline stopped on the empty HTTP 502 TOC response. Those
are separate observations and no changes to their handling belong to this
investigation.

## Controlled attribution

```sh
flutter test --no-pub C:/Users/17945/AppData/Local/liber-evidence/batch27/92/attribution-tests/source_http_connection_test.dart --reporter expanded
```

The raw socket fixture preserves HTTP/1.0 and deliberate incomplete headers.
Only TCP destinations are mapped to loopback; the real product transport still
pools by the original URL origin and writes the source's headers and Host.

| Shape | Current transport observation | Implication |
| --- | --- | --- |
| Recorded HTTP/1.0 301, `Keep-Alive: timeout=4`, `Connection: keep-alive`, then peer close; cross-host target answers 200; repeat for TOC | HTTP 200 / 2 fixture bytes each; four requests on connections `[1, 2, 3, 4]` | Measured sends used distinct connections for each origin and send |
| Same-origin 301 on a persistent socket; peer closes when the next GET reaches that socket; fresh connections would answer 200 | Exact exception at `/after`; requests `/start`, `/after` on connection `[1, 1]`; no fresh attempt | A within-send pooled connection failure exists, independent of rule `retry: 0` |
| Original host accepts a fresh GET then closes without any response bytes | Exact exception naming `http://m.xwurexs.com/Txt/XiaoShuo-375656.html`; one connection / one request, even with rule `retry: 2` | The reported message does not prove idle reuse; rule retries apply to HTTP statuses, not transport exceptions |
| Original host redirects; a fresh target socket closes without headers | Exact exception naming `http://m.4020xs.com/Txt/XiaoShuo-375656.html`; connections `[1, 2]` | Dart names the failing hop, not always the initial request URL |
| Fresh peer writes a partial HTTP response header then closes | Same exact exception as the zero-byte response | Exception text cannot safely distinguish the two recovery conditions |

The first experiment asserted success for the pooled case and went red:
`connection-baseline.log` records 3 passed / 1 failed and the exact exception,
with one connection and two GETs. The self-contained
`attribution-tests/red/` directory retains that original red instrument.
The five passing evidence tests instead assert the explicitly documented
current behavior. They remain outside `test/` so a known recovery gap is not
committed as expected product behavior.

The hypotheses tested were: cross-send stale reuse (ruled out by per-send
client lifetime and distinct observed connects); within-send stale reuse
(reproduced only on a same-origin fixture, not the reported source path);
fresh-peer pre-header close (reproduces the original URI and exact message);
and proxy involvement (the separate on measurement yielded a complete HTTP 502
response, not this exception). Source-path inspection and execution rule out
WebView, JSON and source JavaScript hooks for the reported details fetch.

## Frozen recovery and the rejected idle-timeout experiment

The frozen checkout HEAD is `14dd24945b2914ce2708b8abaa4ee67ceef892af`.
At that commit:

- `app/src/main/java/io/legado/app/help/http/HttpHelper.kt:64` explicitly sets
  `.retryOnConnectionFailure(true)` on its OkHttp builder.
- `gradle/libs.versions.toml:34` pins OkHttp 4.12.0.
- `app/src/main/java/io/legado/app/help/http/OkHttpUtils.kt:29-42` separately
  implements the source's `retry` loop over non-successful HTTP responses.

This is source inspection, not an executed frozen recovery golden. The
product has no corresponding automatic connection-failure recovery. A catch
on the observed Dart exception would also catch partial headers:
Dart SDK `lib/_http/http_parser.dart:960,977` uses the same exception text for
both shapes. No such retry was added.

The original `connection-fixed-first.log` records the pooled failure but does
not identify its timeout setting, so it alone cannot verify that experiment's
configuration. The original session's recorded edit was used to reconstruct
`idle-timeout-replay/zero-idle-timeout.patch` against the exact base. A separate
`observe-effective-setting.patch` adds logging and a check of the effective
setting. Both patches apply only to an isolated base-source snapshot outside
the worktree; the replay retains source, fixture and patch hashes.

Run from this worktree:

```sh
python C:/Users/17945/AppData/Local/liber-evidence/batch27/92/idle-timeout-replay/replay.py
```

The new `idle-timeout-replay/replay.log` records
`IDLE92 effectiveIdleTimeoutMicroseconds=0` immediately before the same-origin
case, followed by the exact exception, one connection and two GETs. The
original success-expecting fixture is still red: three passed / one failed.
The runner returns zero only after checking those outcomes and that worktree
`lib/` and `test/` still match base. Its `manifest.json` records all checks.

The scheduling explanation remains **source-derived inference**, not a timing
trace: SDK `_http_impl.dart:2548-2553` schedules a Timer for idle closure,
returns idle connections at line 2613, and takes one while cancelling its timer
at line 2594; `async/schedule_microtask.dart:123` documents microtask ordering
before timer events. This supports the explanation that the next redirect
acquires the socket before its zero-duration timer fires. The replay measures
continued reuse with an effective zero timeout; it does not directly capture
that internal ordering. No idle-timeout setting, connection-failure retry,
header change or fresh-client-per-hop mechanism is in the worktree product.

The known within-send recovery gap remains explicit and belongs to
[#131](https://github.com/qsgy-edge/liber/issues/131). The controller selected
an evidence-only delivery for #92; this commit changes only this findings
document. It does not establish a cause for the historical #92 observation;
assigning a more specific cause would require the failing run's wire evidence.
Windows app build/driven verification, other platform execution and any
aggregate compatibility claim remain outside this lane.

## Validation and evidence layout

The external attribution command above passed all five tests after the fixture
was moved out of the worktree. A combined run of attribution, request
semantics, cancellation, TLS exceptions, stage diagnostics/provenance and the
system-proxy tests passed **155 tests** (`transport-controls.log`).
`dart analyze lib test integration_test tool` completed with **No issues found**
(`analyze-complete.log`, exit 0). The extra full-suite attempt was stopped at
the controller's direction after the evidence-only scope decision; it is not a
passing full-suite claim.

The evidence root retains:

- `attribution-tests/`: passing attribution fixtures, native-library path
  helper, original red fixture under `red/`, and exact replay instructions.
- `live_probe.dart`, `live-probe-product.jsonl`: product pipeline instrument and
  raw live observations. `private-source.json` is the private selected record;
  it must not be copied into a ticket or public artifact.
- `connection-baseline.log`: original red result. `connection-fixed-first.log`
  also records a red result but does not identify the experimental setting.
- `idle-timeout-replay/`: exact reconstructed experimental patch, separate
  effective-setting instrumentation, isolated source snapshot, replay runner,
  checked manifest and new log identifying zero timeout and the pooled failure.
- `connection-attribution.log`, `attribution-external.log`,
  `transport-controls.log`, `analyze-complete.log`: completed verification.
- `progress.md`, `validation-state.json`: durable checkpoint and command state.

Initial harness-launch failures included: a compile-time misuse of a
void dispose call, a direct VM invocation without sqlite native assets, and an
external `dart run` without package resolution. The successful command copies
the script into `.dart_tool` before `dart run`, resolving both package imports
and build hooks. These launch failures are not transport observations.
