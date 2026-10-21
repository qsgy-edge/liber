# AUTH-SESSION-01 — frozen login, loginCheckJs, header and CookieStore corpus (#137 / Spec A #133)

One controlled corpus that drives the frozen `io.legado.app.debug` application's
ordinary-source login, login-check, header and CookieStore/CookieManager
lifecycle through its four real `WebBook` stage entry points. It is served by
`tool/nested_oracle/AuthSessionOracle.java` on the handset; the product side is
the companion lane. This file and `fixtures.json` are the shared boundary;
everything else here is producer evidence.

`fixtures.json` is data, not a golden. Every compared value is read from a real
frozen API or from the requests the frozen HTTP stack actually sent: no expected
value is echoed as an observation.

## Corpus shape

| Item | Value |
|---|---|
| fixture id | `AUTH-SESSION-01`, corpus version 1 |
| target pin | `io.legado.app.debug`, APK SHA-256 `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6` |
| baseline | `14dd24945b2914ce2708b8abaa4ee67ceef892af` |
| sources | A: HTML, `enabledCookieJar=true`; B: JSON, `enabledCookieJar=false` |
| listeners | exactly `127.0.0.1:18751` and `127.0.0.2:18751`; no wildcard, no alternate port |
| seed | 20 observation ids, 13 requests, retains its owned scratch root |
| restart | 9 observation ids, 4 requests, removes its owned preferences and root |
| provider pin | `com.google.android.webview` `157.0.8103.5` (the controller's `dumpsys webviewupdate` identity) |

Every response is matched by method, path and the exact raw query bytes the
client sent. An undeclared request is recorded and fails the phase. A response
selector may appear only once in a phase.

## What the phases exercise

Seed:

- `seed.login.A` / `seed.login.B` reproduce `SourceLoginDialog`'s sequence
  (`loginUi()`, `putLoginInfo()`, `login()`) with synthetic login info. The
  login script runs through real `BaseSource.login()` and `java.connect`
  (`AnalyzeUrl`/OkHttp), writes a script cookie through the `cookie` binding and
  stores a real login header through `putLoginHeader()`.
- `seed.headers.*` read `getHeaderMap(false)` and `getHeaderMap(true)` through
  the real API, so declared/default/login precedence is observable without
  echoing the corpus declaration.
- `seed.search.A` makes the source's own `loginCheckJs` inspect the first
  response (`AUTH-STALE`), record what it saw, discard it and return a second
  `java.connect` response (`AUTH-SELECTED`). The rules consume only the selected
  body; both actual requests and both response markers stay in the report.
- A's response cookies are persistent (`sidA`, `extraA`) and session (`ssA`,
  `ss2`); same-key overwrites, a two-key removal and a whole-domain
  `removeLoginHeader()` are observed through `CookieStore`/`CookieManager` and
  the next actual requests.
- B's `enabledCookieJar=false` still sends the script-written cookie and sends
  the database cookie on ordinary requests, while response `Set-Cookie: bresp`
  is not persisted. A later `putLoginHeader` carries a `Cookie` key; the
  effective request shows the login-header key merged over the jar value.
- `seed.state.seed` records the portable cookie/header/login-info state. Raw
  cookie DAO rows and cache-key inventories are provenance/isolation receipts,
  never compared native schema.

Restart, in a genuinely fresh process over the retained root:

- `restart.cookies.before` reads every cookie map and login state **before any
  HTTP request**, so persistent versus session survival is separated from a
  reseeding request.
- The first A and B requests show the effective cookie header after restart;
  A's persistent cookies survive, the session cookies do not, B's jar-off
  database cookie and login header survive.
- `restart.headers.A` proves the removed A login header stays removed; B's
  `removeLoginHeader()` then removes its own database cookie, session memory and
  login header, and the following request has no Cookie and no login header.

## Real entry points

- `BaseSource.login/putLoginInfo/getLoginInfoMap/putLoginHeader/removeLoginHeader/getHeaderMap`
  (`BaseSource.kt:85-101,103-131,134-158,175-191`).
- `CookieStore.setCookie/replaceCookie/getCookie/removeCookie`
  (`CookieStore.kt:25-85`) and `CookieManager.saveResponse/loadRequest/getSessionCookie/removeCookie/getCookieNoSession`
  (`CookieManager.kt:29-74,81,112-131`).
- `AnalyzeUrl`'s declared-header, option-header and Cookie merge paths
  (`AnalyzeUrl.kt:119-131,212-246,597-620`); `HttpHelper.kt:85-99` strips the
  internal `CookieJar` marker and loads/saves on the OkHttp path.
- `WebBook.searchBookAwait/getBookInfoAwait/getChapterListAwait/getContentAwait`
  and their `loginCheckJs` application points (`WebBook.kt:48-88,152-198,224-270,296-355`).
- `SourceLoginDialog.kt:58-70,149-184` is the UI caller whose sequence is
  reproduced without Android views.

The storage-only `android.app.Application` over `StateSessionOracle.ScratchContext`
skips frozen `App.onCreate` (crash handler, file logging, Cronet pre-download,
DefaultData.upVersion, freeze monitor, LiveEventBus, URL factory). The splitties
`AppCtxInitProvider` still runs and is checked. Login scripts therefore use
`java.connect` through AnalyzeUrl/OkHttp instead of the Jsoup `java.get/post`
family; that is a declared coverage boundary, not a claim about Jsoup.

## Isolation

- Root: `<target cacheDir>/liber-auth-session-01`; preferences use the
  `liber_auth_session_01_` name prefix and are outside the root by name only.
- Seed requires a fresh root, records its full owned preference name set in
  `owner.json`, fences it and retains the root. Restart requires the completed
  owner manifest, validates fixture/corpus/target/harness identity, reuses only
  the recorded names, then removes the owned preference union and the root.
- A failed or rejected phase removes only what the current invocation created or
  validated; prior state is left for inspection.
- Reports leave the device only through the BASE64 instrumentation stream
  (`AUTH_SESSION_ORACLE_BASE64=<base64 JSON>`), so a final cleanup cannot delete
  its own evidence. A timeout still reports the stage and everything recorded.
- The phase's own cleanup receipt is not proof of process exit. The controller
  force-stops the target, verifies no PID, and then inspects/removes only proven
  task-owned residue and verifies root/owner-listed preference XML+BAK absence.

## CookieStore.removeCookie containment

Frozen `CookieStore.removeCookie` calls
`android.webkit.CookieManager.getInstance().removeCookie(url)`, so it initializes
the WebView provider in the target process. The harness does not rely on an
assumption about the default profile:

- `WebView.setDataDirectorySuffix("liber-auth-session-01")` is called once in
  `Instrumentation.newApplication`, before the app finishes `makeApplication` and
  before any target provider/`Application.onCreate`. A prior provider
  initialization is a fatal refusal; there is no default-profile fallback.
- Before the first remove, the harness refuses an AndroidX
  `ProcessGlobalConfig` data/cache base-path override or data-directory suffix
  key, refuses a device-protected storage-only application (which would let the
  provider replace it with a credential-protected context), and proves
  `application.getApplicationContext()` is still the storage-only application.
- It then proves the suffixed `getDir`/cache names resolve inside the already
  bound AUTH root, initializes the provider once through
  `CookieManager.getInstance()`, pins the actual provider package/version,
  reads the provider's own `org.chromium.base.PathUtils` data/cache/thumbnail
  paths through its classloader and requires them to equal the approved
  canonical paths before calling frozen `removeCookie`.
- `dir-webview_liber-auth-session-01`, `cache/webview_liber-auth-session-01` and
  `dir-textures` are the only provider paths; all are descendants of the AUTH
  root. Real target `app_webview*` existence/size/mtime is recorded as a
  secondary diagnostic only, never as proof that existing contents were
  unchanged. Any mismatch fails before removal.
- Seed retains the profile with the root; restart removes both. The controller's
  post-force-stop check owns final absence of the root and late provider residue.

The source proof for the mapping (Chromium tag `157.0.8103.5` and Android-35
framework reference sources, with hashes) is under the producer evidence root,
not this checkout.

## Capturing it

Build the harness with the repository's portable JDK 17 and build-tools 35.0.1,
install only the instrumentation APK, and run two fresh seed → force-stop →
restart pairs. Each run is one instrumentation invocation:

```bash
adb -s <serial> shell am instrument -w -r -e phase seed \
  io.liber.oracle.nested/io.liber.oracle.nested.AuthSessionOracle
adb -s <serial> shell am force-stop io.legado.app.debug
adb -s <serial> shell am instrument -w -r -e phase restart \
  io.liber.oracle.nested/io.liber.oracle.nested.AuthSessionOracle
adb -s <serial> shell am force-stop io.legado.app.debug
```

The producer does not use ADB or the handset. The controller installs/runs the
candidate and writes its own handoff with the raw captures, hashes, cleanup,
producer commit and integration head.

## Verification

A phase passes only after the terminal snapshot is taken with listeners, workers
and clients stopped: the final actual request/observation set must still
match the corpus, and `unmatchedRequests`/`serverErrors` and listener closure
errors must be empty. A late error or a listener whose measured `isClosed()` is
false fails the phase, keeps it out of seed-owner completion and remains in the
report; cleanup failures are terminal evidence, not nondeterministic equality
exemptions.

`javac -source 8 -target 8` against `android-35/android.jar`, the existing
`build.ps1` into a fresh output directory, `apksigner verify --print-certs`, the
bundled asset hash, and a host structural check of the corpus
(step/request/response/observation identities) are producer checks only. They do
not substitute for the frozen execution.

## Limits

No real credentials, private-site or cross-source cookie access; no WebView
cookie contents, browser/TLS/captcha behavior (Spec B); no ajaxAll,
header-string connect, full getHeaderMap matrix, concurrency/rate, retry,
non-2xx/empty/cancellation or multi-URL pagination (those remain #137). No
source-derived precedence difference is promoted beyond the approved
declared/login/option ordering, the login-header Cookie merge, and the session
cookie restart behavior.
