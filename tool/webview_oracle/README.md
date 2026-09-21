# Ticket 13 native WebView contract probe

Bounded Windows probe for the native WebView2 engine plus the frozen-source
contract derived for Wayfinder ticket 13. It tests the engine boundary directly;
it does not pretend that an uncached Flutter plugin or another platform ran.

## Verdict

- `candidateSelfCheckVerdict`: `pass` on the recorded Windows run.
- Frozen Android oracle execution: complete on two device images; WV-01 through
  WV-13 are `pass`, and WV-14 is `policy-rejected` because frozen Legado accepts
  invalid TLS. `evidence/android` is pinned to Android 16 and `evidence/android-17`
  to Android 17, both produced from the same frozen APKs.
- Windows destination adapter: executed against the golden; WV-01 through WV-13
  are `match`, and WV-14 is `policy-rejected` because the adapter refuses the
  invalid certificate the frozen baseline accepts.
- Android destination adapter: executed against the golden matching its own
  device image; twelve `match`, WV-05 `match-race-alternative`, and WV-14
  `policy-rejected`.
- iOS, macOS, and Linux destination verdicts: `not-run`.
- Five-platform aggregate: `not-run`.

The frozen oracle ran on Android 16 with System WebView `152.0.7977.42`.
The accepted evidence is pinned to device fingerprint
`Redmi/myron/myron:16/BP2A.250605.031.A3/OS3.0.309.0.WPMCNXM:user/release-keys`.
`evidence/android/manifest.json` pins the device fingerprint, locale/timezone,
installed app/test APK hashes, final harness hash, every fixture/evidence hash,
the instrumentation log hash, and the exact accepted-evidence window. The
installed APK hashes match the local artifacts built from frozen commit
`14dd24945b2914ce2708b8abaa4ee67ceef892af`; the frozen production source has
no diff.

`evidence/windows/summary.json` separately records the bounded Windows result,
request trace, WebView2 Runtime `152.0.4191.35`, SDK `1.0.3179.45`, fixture hash,
loader hash, measured capability rows, and explicit coverage gaps.

## What the Windows self-check measures

The loopback-only replay fixture exercises:

- off-screen, non-taskbar WebView2 loading through a redirect;
- delayed page JavaScript, final URL/outer HTML, and a subresource URL;
- explicit HTTP-cookie import into WebView and WebView-cookie export to HTTP;
- response and JavaScript cookies plus local/session storage in one instance;
- two simultaneous WebViews with observed request overlap;
- disposal of an infinite-script navigation;
- `Stop` plus disposal of a hanging request, including socket disconnect;
- a successful navigation after both disposal paths;
- rejection of undeclared replay requests.

The Windows self-check does not cover the frozen POST/inline load modes, exact
sniffer termination, cross-instance/restart state, baseline timeout retry loop,
early-cancel race, complete error/TLS branches, Flutter plugin behavior, or any
non-Windows destination adapter. Those branches now have frozen Android golden
observations, but no destination result may be copied from the oracle.

## Fixture TLS material

WV-14 needs an untrusted HTTPS endpoint, so `fixtures/WV-14.json` carries a
self-signed certificate and its RSA-2048 private key (PKCS#8). They are test
material, not credentials:

- Subject and issuer are `CN=wayfinder-ticket13.invalid`, self-signed,
  SHA-256 with RSA, valid 2026-08-19 to 2026-08-21, so the certificate is
  already expired. Its only use is the loopback listener that serves the fixture
  routes for `adapter/lib/replay_server.dart` and `oracle/android`.
- No service, workflow, product path, or third party trusts or can use this key
  pair. Nothing needs rotation or revocation, and the certificate is public
  anyway.
- The material stays byte-identical on purpose: the recorded oracle and
  destination manifests pin `fixtures/WV-14.json` and
  `adapter/lib/replay_server.dart` by SHA-256. Regenerating the pair would
  invalidate those pins and require re-deriving the platform rows, which needs
  the device and adapters that are not available.
- If a secret scanner reports this key, it is a test-fixture finding: dismiss it
  with the reasoning above rather than rotating anything.

## Frozen Android oracle

Two goldens exist because the device's OS was updated mid-ticket, from Android 16
to Android 17. Both were produced from the same frozen application and
instrumentation APKs, whose hashes are recorded in each manifest, so the pair
isolates the OS as the only variable. `evidence/android` is the Android 16
golden; `evidence/android-17` is the Android 17 golden. A destination row is
compared against the golden matching its own device fingerprint, and the
comparison refuses to compare an Android destination against a mismatched golden
rather than loosening the gate.

Every observation is identical across the two OS versions except the arrival
order inside the concurrent groups WV-12 itself declares concurrent; all of that
fixture's checks and its admission shape are unchanged. That is scheduling
non-determinism, not an OS behaviour difference, and it is recorded in the
Android 17 manifest.

Each accepted fixture cleared app data, ran its test method explicitly, required
`OK (1 test)`, and pulled its JSON before the next clear. WV-07 and WV-08 add a
real process stop/restart phase without clearing state between their two phases.
Each `run.log` is the verbatim execution log of its run.

The Android 16 run took three segments (WV-01 through WV-07, then WV-08, then
WV-09 through WV-14) and its log retains 16 accepted `OK (1 test)` results plus
three environment interruptions that produced no accepted result. The Android 17
run completed in one segment with 16 accepted results and no interruption in its
log. Reaching that required a device setting, not a harness change: this OS
freezes a backgrounded app process (`cgroup.freeze=1`), which stalls the harness
timers, so the oracle app was given an unrestricted battery policy. Attempts
made before that, and a separate WV-09 timing run that confirmed the fix, were
neither pulled nor accepted, and each manifest records them.

Earlier Android 16 batches, including an `OS3.0.308.0` batch and earlier harness
revisions, are superseded in full. Both goldens retain the request-delivered side
of the WV-05 race as non-accepted diagnostic evidence under their own
`diagnostics/` directory, each declared in its manifest with its hash.

| ID | Verdict | Frozen observation |
| --- | --- | --- |
| WV-01 | `pass` | Hidden direct GET returns default outerHTML/final URL and also requests `/favicon.ico`. |
| WV-02 | `pass` | HTTP POST body/header are preserved; returned HTML uses the request URL as base and delayed custom JS sees the relative asset. |
| WV-03 | `pass` | Inline HTML without a base URL returns the legacy `http://localhost/` placeholder URL. |
| WV-04 | `pass` | Real requests follow redirect then late script navigation; result metadata is synthetic `302 -> 200`. |
| WV-05 | `pass` | Resource callback returns the full matched URL and destroys immediately; delivery of the already-starting subresource is a race whose actual outcome remains in the request trace. |
| WV-06 | `pass` | Override callback returns the matched URL and prevents the matched navigation request. |
| WV-07 | `pass` | Input app Cookie is absent from the first WebView request; page/JS cookies reach later requests and Room. After restart Room still has them, native WebView does not send them, then page completion overwrites Room with an empty native cookie. |
| WV-08 | `pass` | localStorage survives new WebViews and process restart for the same origin; sessionStorage survives neither new instance nor restart. |
| WV-09 | `pass` | Repeated null JS results fail with `NoStackTraceException("js执行超时")` after about 32 seconds and clean up. |
| WV-10 | `pass` | Outer coroutine timeout fires at about 60 seconds and destroys the WebView; the server stays open 7 seconds past termination, so the observation window extends past the 65-second delayed response and still records no post-terminal request. |
| WV-11 | `pass` | Queued and in-flight cancellation complete and clean up; the server stays open 6 seconds past cancellation, so the observation window extends past the 5-second delayed response and still records no post-terminal request. The queued request is a UI-queue race and its actual outcome remains in the golden. |
| WV-12 | `pass` | Direct helpers overlap; `1/800` admits two initial requests and delays the third about 800 ms; results retain input order; one sibling can be cancelled without killing the other. |
| WV-13 | `pass` | HTTP 500 is an ordinary response, an aborted connection throws, and a WebView main-frame 500 body is returned with synthetic status 200. |
| WV-14 | `policy-rejected` | Frozen Legado accepts invalid TLS; a deterministic setup failure also leaves a WebView requiring harness cleanup. |

The full request traces, operation values, checks, runtime provenance, and
per-file hashes are under `evidence/android/`. WV-05's accepted trace records
the request-absent side of its race; the non-accepted diagnostic preserves the
request-delivered side. The policy rejection is a frozen baseline observation,
not permission for a production adapter to accept invalid certificates.

## Reproduce the frozen Android oracle

Requirements: an Android device, Gradle 8.11.1, JDK 17, Android SDK/adb, and a
clean worktree of the frozen Legado commit. Copy
`oracle/android/Ticket13OracleTest.kt` into
`app/src/androidTest/java/io/legado/app/ticket13/` and `fixtures/WV-*.json` into
`app/src/androidTest/assets/ticket13/`; do not modify production source. Build
`:app:assembleAppDebug :app:assembleAppDebugAndroidTest`, install both APKs, and
run only one `Ticket13OracleTest#<method>` at a time. Clear app data between
independent fixtures; for WV-07/WV-08, force-stop without clearing before the
restart method. Keep the device awake and keep a light foreground app (the
launcher) in front for WV-09/WV-10; a heavy foreground app lets the device
freeze the instrumentation process and stall their timers. Compare the installed
APK, harness, fixture, pulled evidence, and instrumentation-log SHA-256 values
with `evidence/android/manifest.json`.

## Reproduce on Windows

Requirements:

- .NET 10 SDK with Windows Forms support;
- Microsoft WebView2 Runtime;
- the pinned WebView2 package already present at
  `%USERPROFILE%/.nuget/packages/microsoft.web.webview2/1.0.3179.45`.

From this directory:

```text
dotnet run --project WebViewProbe.csproj --no-restore
```

`NuGet.Config` clears package sources, and the project references only the local
package cache. A missing SDK/package/runtime produces `not-run`; it cannot
silently download dependencies. Flutter/Dart is not required for this native
engine probe.

## Reproduce the destination sweeps

Android, with the pinned device attached:

```text
bash tools/run_all_destination.sh
node tools/write_destination_manifest.js android
```

Windows:

```text
bash tools/run_all_destination_windows.sh
node tools/write_destination_manifest.js windows
```

Either sweep stops at the first fixture that is neither a match nor a declared
policy rejection, and the manifest writer refuses to record adapter sources that
were edited after the sweep it describes. Editing a shared adapter source
therefore invalidates every platform row already collected, so a change made
while working on one platform requires re-running the others.

To re-run the frozen oracle itself on the device's current OS:

```text
bash tools/run_oracle_android17.sh
```

That script reuses the recorded frozen APKs rather than rebuilding, and verifies
their hashes before installing, so a new golden cannot come from different
binaries. It is pinned to the Android 17 fingerprint; another OS needs its own
copy with that fingerprint and target directory.

## Frozen source contract

All pointers below refer to Legado commit
`14dd24945b2914ce2708b8abaa4ee67ceef892af` (tree
`5a250932cf8cc4905198a58587851b39dbc98499`).

- `BackstageWebView.kt:52-79`: each operation has a 60-second outer timeout;
  cancellation posts WebView destruction, while queued loading has no canceled
  guard.
- `AnalyzeUrl.kt:397-430` and `BackstageWebView.kt:87-102`: direct GET uses
  WebView headers; POST first uses HTTP and then loads returned HTML with a base
  URL; helper calls can also load inline HTML without a base URL.
- `BackstageWebView.kt:109-122`: the Android WebView is constructed with the
  application context, never attached to a view hierarchy, and enables
  JavaScript/DOM storage.
- `BackstageWebView.kt:130-137,165-220`: default JavaScript is
  `document.documentElement.outerHTML`; evaluation starts after
  `1000 + delayTime`; null/empty results retry and eventually fail.
- `BackstageWebView.kt:222-240`: redirect metadata is a synthetic `302 -> 200`
  response, not the real hop chain.
- `BackstageWebView.kt:246-320`: resource and navigation sniffers are separate
  clients with first-match/early-destroy behavior; observing a resource URL in
  this Windows self-check does not prove that full behavior.
- `AnalyzeUrl.kt:397-430`, `BackstageWebView.kt:139-145`, and
  `CookieStore.kt:25-30,51-69`: cookie flow is asymmetric. App cookies become
  direct request headers; page-finished WebView cookies are asynchronously
  persisted under the Book Source key and the store combines persistent and
  session maps. The background path does not call `applyToWebView`.
- `BackstageWebView.kt:125-127,196-220,266-292`: result delivery and destruction
  are not atomic; setup/load exceptions can complete without direct cleanup.
- `BackstageWebView.kt:174-180,304-310`: both clients accept TLS certificate
  errors. A destination security refusal must be `policy-rejected`, never pass.
- `AnalyzeUrl.kt:397-461` and `JsExtensions.kt:161-213`: source rate limiting
  encloses the complete AnalyzeUrl operation, while direct JavaScript helpers
  bypass that limiter. WebView instances are per-operation, but browser
  cookies/storage are shared profile state.

## Minimum production adapter contract

Each platform adapter must expose one observable operation boundary that can:

1. Create an engine-active hidden WebView with declared profile/state identity.
2. Load direct GET, HTTP-bootstrapped HTML with base URL, and inline HTML.
3. Set UA/source headers and execute delayed JavaScript, returning exact typed
   results, final DOM, evaluated URL, and stable errors.
4. Observe resource/navigation URLs and stop on the first full-regex match.
5. Import/export the Book Source cookie model while separately exposing actual
   outbound cookies, native cookies, and browser storage for comparison.
6. Report real redirect requests separately from Legado-compatible synthetic
   result metadata.
7. Enforce timeout and explicit cancellation so pending operations complete and
   post-terminal requests/scripts/side effects can be observed.
8. Permit independent concurrent instances while preserving external
   source-rate limits and input-order result collection.
9. Dispose idempotently on success, failure, timeout, cancellation, and setup
   errors without clearing shared state unless the fixture requests a reset.
10. Emit platform + adapter provenance and `pass | fail | policy-rejected |
    not-run` per fixture; missing rows block aggregate compatibility.

## Frozen-oracle fixture gate

These branches cannot be collapsed into the single Windows self-check:

| ID | Frozen oracle verdict | Logical fixture |
| --- | --- | --- |
| WV-01 | `pass` | Hidden direct GET, default outerHTML, final URL, normal cleanup |
| WV-02 | `pass` | HTTP POST bootstrap, base URL, relative resources, custom JS/delay |
| WV-03 | `pass` | Inline HTML without base URL |
| WV-04 | `pass` | Server redirect plus late script navigation and synthetic result |
| WV-05 | `pass` | Full-match resource sniffer with first-match cleanup |
| WV-06 | `pass` | Full-match override sniffer with blocked navigation |
| WV-07 | `pass` | Header/native/HTTP cookies across origin, quiescence, and restart |
| WV-08 | `pass` | local/session storage across instances, origin, and restart |
| WV-09 | `pass` | Null-result retry loop and internal JS timeout |
| WV-10 | `pass` | 60-second outer timeout with post-terminal activity observation |
| WV-11 | `pass` | Explicit cancellation before queued load and while in flight |
| WV-12 | `pass` | Direct-helper overlap, source limiter, sibling cancellation, ordering |
| WV-13 | `pass` | HTTP 500, refusal/abort, renderer/main-frame failures |
| WV-14 | `policy-rejected` | Invalid TLS policy plus deterministic setup-failure cleanup |

The frozen Android golden gate is complete on two device images, and the Android
and Windows destination rows are executed against the golden matching their own
image. Each row still needs an independent run for iOS WKWebView, macOS
WKWebView, and Linux WebKitGTK. That is 42 remaining destination executions; a
result may not be copied between platform adapters. WV-14 cannot pass on any
destination because the security contract forbids reproducing invalid-TLS
acceptance.

## Destination adapters

One thin `flutter_inappwebview` adapter shaped to the frozen `BackstageWebView`
contract, driven by a Dart port of the replay server, executed per platform
against the same golden. The comparison refuses to run at all when an Android
destination's device fingerprint or WebView version differs from the golden's.
Each platform sweep builds the application once from the integration-test
entrypoint and reuses that binary for all 14 fixtures, sampling its hash around
every fixture and requiring all 30 samples to be identical; a per-fixture
rebuild would make the evidence unattributable to one build. Each fixture clears
the app's state first and is compared against the golden immediately. The fixture
to run is selected at run time through a file rather than with `--dart-define`,
because a compile-time define would change the binary per fixture.

Android reuses the built APK with `--use-application-binary`. Windows has no
equivalent flag, so its sweep verifies the binary hash is unchanged around every
fixture instead, and it builds from a hash-verified short-path copy because MSVC
cannot build from the committed path's length.

The comparison is not a file diff. It compares request order, method, path,
body, and source-set headers, plus each fixture's operation results, extra
observations, and every assertion the frozen harness recorded in `checks`. A
duration is compared as the band the contract cares about (under the 30 second
retry budget, inside the 30-60 second budget, or at/after the 60 second outer
timeout) rather than in milliseconds, so a timeout that never fired is a
difference while platform overhead is not. A concurrent group declared by the
fixture is compared both as a multiset and by admission shape, so a destination
that applied no rate limiting differs even when its members match. A cookie
observation is compared as a set of name/value pairs, matching the frozen
baseline's own cookie model. It deliberately does not compare platform-generated
headers, exact millisecond values, the loopback port, a platform exception class
name or runtime message (mapped to a stable error category instead),
browser-initiated `/favicon.ico`, or which member of a declared concurrent group
won a racy admission slot.

Three divergences are recorded rather than reproduced:

- The plugin flushes the native cookie store when a page finishes, which made
  session cookies survive a process restart. The adapter drops native session
  cookies once per process, restoring the frozen in-memory session semantics.
  Windows exposes no such operation, so no correction is applied there and
  WV-07's restart phase observes what that platform actually does.
- The frozen baseline leaks its WebView when an operation is created with neither
  URL nor HTML. An internal resource leak is a fixable defect rather than
  source-visible behavior, so the adapter cleans up.
- The frozen baseline proceeds through an invalid TLS certificate. The adapter
  refuses it and fails the operation, so WV-14 is `policy-rejected` on both
  sides and cannot count toward compatibility.

Four platform seams are bridged so the observable outcome matches; each is a
platform capability gap, not a contract change:

- Windows reports no redirect flag on a navigation, so a redirect is detected the
  way the frozen baseline itself detects one without that flag: the navigation
  URL differs from the loaded document's.
- Windows `loadData` cannot carry a base URL, so inline HTML with a base URL is
  served from the resource-interception hook at that URL instead.
- Windows has no `onLoadResource`, so resource sniffing runs through
  `shouldInterceptRequest`; an override match is also decided there, because the
  engine issues the navigation's request before asking for the decision.
- Windows reports a main-frame HTTP error status as a failed navigation with no
  load-stop event, so a main-frame HTTP error is treated as page completion,
  which is where the frozen baseline arrives.

WV-05's matched-subresource delivery is a race. A destination trace may match the
other side of it only when the golden manifest itself declares that recording
under `diagnosticEvidence` and its bytes hash to the declared value, so dropping
a file into the diagnostics directory cannot widen the comparison. A run that
lands on the declared alternative is recorded as `match-race-alternative` rather
than `match`, and the report names the trace it matched.

WV-14 is verified as a refusal, not merely as a matching verdict string: the
destination must name the check that proves it refused the forbidden capability,
and that check must hold, otherwise the comparison reports `policy-violation`.
The refusal is observed as the fixture certificate having been presented and the
operation not having proceeded through it, so an engine that aborts the handshake
itself counts, while a destination that never reached the fixture does not.

## Platform accounting

| Platform/adapter | Verdict | Reason |
| --- | --- | --- |
| Windows/WebView2 native engine | `pass` (candidate self-check) | Bounded self-check of the native engine only. |
| Windows/Flutter adapter | `match` × 13, `policy-rejected` × 1 | Thin `flutter_inappwebview` adapter compared against the golden. |
| Android/WebView | `match` × 12, `match-race-alternative` × 1, `policy-rejected` × 1 | Same adapter, compared against the golden matching its device image. |
| iOS/WKWebView | `not-run` | No macOS/Xcode execution host. |
| macOS/WKWebView | `not-run` | No macOS/Xcode execution host. |
| Linux/WebKitGTK | `not-run` | No published plugin supports it; needs a first-party WebKitGTK adapter. |
| Frozen Legado Android oracle | WV-01 through WV-13 `pass`; WV-14 `policy-rejected` | All 14 required fixtures executed with pinned provenance and hashes, on two device images. |

The current evidence fixes the frozen Android golden contract and proves the
Android and Windows destination adapters reproduce it. It does not resolve the
five-platform destination contract.

iOS, macOS, and Linux are deliberately deferred, not blocked on discovery. iOS
and macOS have no execution host. Linux has a usable host but no plugin that
covers the contract, so it needs a first-party WebKitGTK plugin and a WV-02
workaround for the missing POST-body navigation, and a result would be pinned to
WebKitGTK `2.38.6` under WSLg. The conditions each row needs are recorded in the
ticket's destination environment survey.

A non-Android destination is compared against the Android 16 golden. That choice
is immaterial: the two goldens agree on every fixture's checks and verdict, and
differ only in the arrival order inside the concurrent groups WV-12 declares
concurrent. The fingerprint gate applies only to an Android destination, where a
mismatched device would otherwise be attributed to the wrong OS.
