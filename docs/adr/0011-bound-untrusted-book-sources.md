# Untrusted Book Sources stay in process, keep their state inside the space, and are deferred rather than refused

**Status:** accepted (2026-09-16). Settles what ADR 0004 and ADR 0009 left to this ticket: whether the hard
execution bound is built, where host-surface state lives and who may read it, what the file, WebView and
identity escape hatches do, what the network path may reach, and which baseline behavior this product refuses
outright.

**Boundary.** The boundary starts with an already accepted Book Source: import validation, unknown-field round
trips and migration are separate contracts (`docs/compatibility/book-source-differential-contract.md`, section
"Boundary"). Inside it, a source is untrusted input that reaches the network, the local file system, the user's
attention and the space's data. Everything below is a policy decision taken once for all five platforms;
per-platform code stays what ADR 0009 fixed — native build glue, the engine binding, the WebView transport.

**The principle the decisions use.** A capability this slice does not ship is **deferred**: it is recorded with
an owner and it is not a compatibility result either way. `policy-rejected` — the differential contract's term
for behavior this product will not reproduce at any price — is reserved for behavior that conflicts with the
security or data-integrity policy below. Nothing is refused merely because it is out of scope today.

## 1. The hard bound is not built; the in-process limits are the enforcement

A *hard* bound on one execution — kill it at the deadline whatever it is doing — needs a process with an
OS-level kill. In process, `JS_SetInterruptHandler` is polled, so a single C-level call has no poll point
inside it and a loop dominated by native work overshoots by the poll quantum's worth of native work per poll
(ADR 0004 "Measured limits"; `tool/runtime_limits_prototype/`). `Isolate.kill(priority: beforeNextEvent)` is
documented as scheduled for the next event-loop turn, which bounds nothing for an isolate busy in synchronous
computation, so isolation means a process.

**Not built, and not to be built as a platform-conditional feature.** A per-source helper process is possible
on Windows, macOS and Linux (a second executable in the bundle plus an IPC protocol); on Android the binary
cannot live in the app's data directory — API 29's W^X rules forbid executing a file written there — so it
would have to ship as a packaged native library and be executed out of the extracted library directory, a path
Android does not document as a supported contract; and on iOS the app sandbox does not permit spawning a child
process at all. The mechanism is therefore unavailable where its cost is highest, while it would cost a helper
implementation, an IPC protocol and a state-sharing decision on the platforms that can host it:

- the isolated process cannot share the session cookie jar, the shared `jsLib` scope, or the process-global
  request and rate-limiter state that the differential contract compares — a source's observable behavior
  would differ between an isolated and a non-isolated platform, and ADR 0004 rejected default isolation for
  exactly that reason;
- the user-visible price is a process spawn and a second engine's memory per isolated source.

**What stands instead**, with #25's settlement applied (a Rust-side deadline clock, the interrupt poll quantum
down from QuickJS's 10 000/10 000 to 1 000/1 000):

- interpreter-bound and regexp-bound work stops at the deadline: 0.1 ms and 0.2 ms past deadlines of 1–500 ms
  in the pinned engine, 6.9–15.3 ms through the product;
- native-heavy work overshoots by the poll quantum times the native cost of one iteration: 12.7 ms for the
  measured heavy loop and 407 ms for the catch-and-retry loop at the heap limit, down from 897 ms and 3 366 ms
  at 10 000;
- a single C-level call has no poll inside it and is bounded only by the input caps: script and library 64 KiB,
  a host-call payload 8 MiB (`lib/source/js_source_runtime.dart:52-53`), an HTTP response body 8 MiB and a
  request 1 MiB (`lib/source/source_host_dispatcher.dart:10-11`), and the heap 64 MiB
  (`lib/source/js_source_runtime.dart:55`). The measured worst case inside those caps is 1.77 s for one 8 MB
  `JSON.parse` under a 200 ms deadline, through the product.

The interrupt error stays uncatchable, so a source cannot swallow the deadline, and the heap limit stays
enforced at the allocator. The residual accepted here is: **a hostile source can hold the engine's own thread
for seconds per execution — it cannot exceed the heap cap, cannot escape, and the user can still cancel or
close the analysis.** Reopen condition, recorded rather than implied: if a source in the wild
is observed exploiting the residual, or if sources ever run unattended or in batches instead of one analysis
at a user's request, isolation returns as its own decision with the child-process and state-sharing costs
above. The rejected alternative is a design document with no implementation behind it.

## 2. The file and download family is deferred, and fails with a name, not a `TypeError`

The baseline's file family is a real sandbox: `getFile` resolves a relative path against the app's external
cache directory, then rejects anything whose canonical path does not sit under the cache directory's parent
(`JsExtensions.kt:555-568`); `downloadFile` writes `MD5(url) + suffix` under the cache path and returns a
path relative to it (`:311-344`); `cacheFile(url, saveTime)` downloads once and caches the text with a TTL
(`:267-292`); `unzipFile`/`un7zFile`/`unrarFile` unpack under a temporary folder (`:608-647`); `importScript`
reads a URL or a relative local path (`:253-265`).

Replicating it means defining, in one place: the sandbox root (per space), the traversal rule (a canonical-path
comparison plus a component check, not a prefix), archive-entry traversal and decompression bombs, a per-file,
total-size and file-count cap, a TTL and cleanup policy, a streaming download path because a real book file is
larger than the 8 MiB response cap, and the `File`-like object the JavaScript sees. Its consumers are
file-type sources (`bookSourceType: 3`, `downloadUrls`), remote `jsLib`, and sources that ship a table of
contents as an archive — the first two are ticket #14 and ticket #13.

So: the members stay unimplemented, the host surface gives each of them an explicit refusal naming the policy (#31)
(so a failing source's log says why instead of `TypeError: java.downloadFile is not a function`), and the shape
above is this boundary's constraint on whoever implements them. `cache.getFile`/`putFile` and `getQueryTTF`
belong to the same family of file-touching members. Cost of the deferral, stated plainly: those sources do not
run yet, and the capability matrix records them as deferred gaps rather than as policy rejections.

## 3. Host-surface state persists inside the space's store, and cookies are scoped to a source's own site

`cookie.*`, `cache.*`, rule state and the source variables exist in the space's database (`data.db`, ADR 0007
D5) — the same file the shelf and the sources live in, so a private space's later encryption covers them as a
unit and no state file sits beside the store. Nothing about the shape changes for that: an encrypted space is
an encrypted file, not a second store for runtime state. Implementation is #21.

**Cookie keys become the registrable domain** (eTLD+1 through a public-suffix list; an IP literal stays itself),
which is the baseline's own key — `CookieStore.kt:27` stores under `NetworkUtils.getSubDomain(url)`, and
`NetworkUtils.kt:211-222` is Guava's `PublicSuffixDatabase.getEffectiveTldPlusOne`. This closes the recorded
divergence that this product keys cookies by the exact host (`lib/source/source_host_dispatcher.dart:186-249`).
The 4096-character trim stays a recorded divergence.

**A source may read, send and delete a cookie when the cookie's site group is its own `bookSourceUrl`'s site
group, or when the source itself wrote it** (through `cookie.setCookie`/`replaceCookie`, or a `Set-Cookie` on a
response it received). Two sources for one site therefore share a session exactly as the baseline shares it,
and a source belonging to another site can neither read that session's cookie values nor send them to that
site. The runtime is already per source and the pipeline already holds `source['bookSourceUrl']`
(`lib/source/html_source_pipeline.dart:56,135`), so this is a plumbed site group, not new architecture.
Stated costs: the differential corpus is single-source, so no fixture observes the filter, and a source that
relies on a *pre-existing* cookie another source wrote to a foreign domain stops working; the filter cannot
stop a source that claims the other site's URL as its own `bookSourceUrl` — that claim is visible to the user
at import, and this ADR does not pretend the filter is stronger than that.

**Cache entries and `java.put`/`java.get` values are owned by the source that wrote them.** A source reads its
own entries; internal keys (login headers, verification results) are written on the owning source's behalf.
`cache.put(key, value, saveTime)` honors the deadline and `saveTime = 0` means permanent, as `CacheManager`
does (`CacheManager.kt:32-40`). `java.put`/`java.get` become the baseline's persistent per-source variables —
`v_<sourceKey>_<key>` in `BaseSource.kt:220-233` — instead of one analysis's rule state, which is what makes
them isolable by construction. Cost: a source that deliberately shares a cache key with another source breaks,
and the baseline's global key space is not reproduced. What is *not* decided here: the encryption library (see
§8).

## 4. WebView and verification: headless where a page is the answer, user-confirmed where a person is

The `webView` request option (with `webJs` and `webViewDelayTime`) is allowed: it is how a source reaches a
page whose content only exists after scripts run, and it is executed headlessly through the platform adapter
#2 owns, sharing the session cookie jar with the HTTP path, with a fixed timeout and http(s) only.

`java.startBrowser`, `startBrowserAwait`, `getVerificationCode` and `openUrl` require the user's confirmation,
naming the source and the URL, and the source waits with a timeout and a cancel path. These members exist to
hand a person a page or an input box and take the answer back — `SourceVerificationHelp.kt:29-58` parks the
source's thread on the user's answer, with `startBrowser` showing the page (`:72-92`) and
`getVerificationCode` an image dialog. Without a confirmation a source can phish: a page that looks like a
site's login, or a "verification code" box that asks for a password, with the answer returned to the source.
The baseline is the opposite on `startBrowser` (no confirmation) and already confirms `openUrl`
(`OpenUrlConfirmActivity`), so this is a deliberate divergence, recorded in the capability matrix. Cost: the
confirmation UI, the parked-source wait, its timeout and its cancellation, in #2's lane plus a follow-up
ticket.

`getWebViewUA` is emulated (the platform WebView's user agent), and the automatic WebView fallback that the
baseline applies to some request shapes is a #2 row, not a policy question.

## 5. The network path reaches any host a source names, over http(s)

The private-address filter was rejected: LAN and self-hosted sources are a real use (a NAS, Calibre-Web, a
local server), and a source that can name a private host can already send what it reads anywhere, so the
filter would remove a capability without removing the leak — and to mean anything it would have to check every
redirect hop against the resolved IP, not the requested one. What stands: only `http` and `https` are accepted
(`lib/source/http_source_transport.dart:79`).

TLS is the one permanent policy conflict, and it is narrowed rather than accepted as incompatibility. The
baseline trusts every certificate and every hostname for every source request
(`HttpHelper.kt:63,65` — `unsafeSSLSocketFactory` plus `unsafeHostnameVerifier`); this product validates. A
source that needs an exception gets it **from the user, per source, once**: on a certificate failure the
confirmation says the certificate is invalid and asks whether to continue anyway for this source, and a stored
per-source flag is what the transport reads afterwards. Default stays validation, so the divergence is not
silent, and a source whose site has a broken certificate stops being permanently incompatible. This is the
browser's "continue (unsafe)" contract; it is the only place this boundary lowers a security property on the
user's explicit say-so, and it must be implemented for whichever transport the request uses, HTTP or WebView.
Implementation is #30.

## 6. Escape hatches, member by member

| Member | Decision | Reason and consequence |
|---|---|---|
| `java.androidId` (`JsExtensions.kt:970`) | Emulated (#31): a per-install opaque random id, stable across restarts | Sources bind sessions and signatures to a device id; a random id keeps them working without exposing the platform's real identifier. It changes on reinstall, as the baseline's does on a device change. |
| `java.toast`, `longToast` (`:927-941`) | Emulated (#31): recorded, and shown rate-limited | Sources use them to tell the user to finish a verification; hiding them leaves the user with a dead source. |
| `java.log`, `logType` (`:943-964`) | Emulated (#31): bounded per-source log | The source debug console is the only way a failing source is diagnosable. |
| `startBrowser*`, `getVerificationCode`, `openUrl` (`:222-252`, `:974`) | Permission, user-confirmed (#32) | §4. |
| `getWebViewUA` (`:544`) | Emulated (#31) | No security cost. |
| File family, `downloadFile`, `cacheFile`, `unzip*`, `cache.getFile`/`putFile` | Deferred, refused by name (#31); the family itself is #13's and #14's | §2. |
| `importScript` (`:253`) | Deferred: the local-path half with §2, the URL half with #13; the refusal is #31's | Remote `jsLib` is a pipeline feature (#13). |
| `getQueryTTF`, `replaceFont` (`:791-903`) | Deferred (#33) | Not a reader font: it is content de-obfuscation — the source hands in a font and the glyph outlines are compared to map substituted characters back (`QueryTTF.java`). Cost is a TTF parser and glyph comparison in Rust, no UI; without it those sources render mojibake. |
| `speakText`, `speakSpeed` | Deferred | Reading aloud is deferred beyond the first slice (§7), not a policy question. |

## 7. Deferred is not refused

The following are deferred to work after the first slice, recorded here so that no row in the capability
matrix reads as a permanent exclusion: the file and download family and archive handling (§2); font
de-obfuscation (§6); the WebView request path and the user-confirmed verification members (§4); TTS/reading
aloud; image, audio and file-type Book Sources; the review UI; cloud synchronization; bookmarks, reading
history, search history and Book Source subscriptions; pixel-level UI reproduction, a bundled browser engine
and store distribution. Capabilities already owned by a ticket stay with it (#13 pipeline features, #14
peripheral capabilities, #2 WebView, #21 persistence); the ones with a concrete shape became tickets with this
decision — #30 the per-source TLS exception, #31 the named refusals and emulated members, #32 the
user-confirmed verification hatches, #33 font de-obfuscation — and the remaining product features are
registered in the map rather than turned into tickets with no shape.

## 8. Encryption at rest is not chosen here

Both candidates for a private space's database — SQLite3 Multiple Ciphers and SQLCipher — are a three-line
pubspec user-define on the `sqlite3` v3 hook, and neither can be validated before the private-shelf feature
exists; ADR 0007 and `docs/user-data-contract.md` already record the trade-off (SQLCipher links OpenSSL on
Windows, Linux and Android and carries its own license; sqlite3mc stays closer to the public-domain SQLite).
What this boundary fixes is the constraint that keeps the choice cheap: **all host-surface state lives in the
space's `data.db`**, so encryption stays a property of one file.

## Considered options

- **Build per-source process isolation now.** Rejected: unavailable on iOS, outside Android's documented
  contracts, and it breaks the shared state the differential contract compares (§1).
- **Design isolation and defer it as a ticket.** Rejected: the shape is recorded in §1 instead; a design with
  no implementation ticket behind it is a decision, not a feature.
- **Accept the in-process residual as a hard guarantee.** Rejected as a claim, accepted as a cost: §1 states
  what the limits do bound and what they do not.
- **Emulate the file family now, inside a per-space sandbox.** Rejected for this slice: the sandbox, its caps
  and its archive handling are a subsystem whose consumers arrive with #13 and #14.
- **Refuse the file family permanently.** Rejected by the operator's rule: a capability this slice does not
  ship is deferred with an owner, not rejected.
- **A shared cookie jar with unrestricted reads (baseline behavior).** Rejected: any source could read and
  send another site's session, which is the one leak a browser-like jar does not require.
- **A cookie jar per source.** Rejected: it would break the same-site sharing the baseline provides, which
  users rely on when two sources cover one site.
- **A cache key space shared across sources (baseline behavior).** Rejected: a source can guess another
  source's keys (`v_<sourceKey>_<key>`), and nothing in the corpus depends on cross-source cache reads.
- **Keep `java.put`/`get` scoped to one analysis.** Rejected: the baseline persists them per source
  (`BaseSource.kt:220-233`), and the differential contract compares reachable cache keys.
- **Keep the file members undefined.** Rejected: an undefined member fails as a JavaScript `TypeError`, which
  names neither the policy nor the member, in exactly the failure a user would report.
- **Copy the baseline's TLS trust.** Rejected: accepting every certificate and hostname makes every source
  request interceptable; a per-source user exception keeps the capability without the default.
- **Block private and loopback addresses.** Rejected: it removes LAN sources without removing the leak, and
  its correctness needs resolved-IP checks on every hop.
- **Let a source open a browser or an input box without asking.** Rejected: that is a phishing surface and it
  is the one thing the user confirmation exists for.
- **Decide the encryption library now.** Rejected: unverifiable before the feature exists, and cheap to add
  later (§8).

## Per-platform consequences

- No platform gains an isolation mode, so no per-platform capability difference is introduced by §1, and each
  platform's limits rows stay each platform's own as ADR 0009 requires.
- The TLS exception is a property of the transport, so it must be implemented for the Dart HTTP client and for
  each WebView adapter as #2 lands, with the same stored per-source flag.
- The registrable-domain cookie key needs a public-suffix list on all five platforms; the implementation
  ticket picks it and verifies its license, as this repository's rule requires before a dependency is added.
- The deferred families (§2, §4, §6) are cross-platform work with no platform-specific policy: when they land,
  each platform's rows are still its own per ADR 0009.

## Not established

- Only the Windows limits rows are executed; the quantum change and the Rust clock (#25) are not in the tree
  yet, so the numbers in §1 are the ones ADR 0004 measured plus the quantum probe's rows, not a re-measurement
  of the shipped product.
- No fixture exercises the cross-source cookie filter, the per-source TLS exception, or any deferred member:
  the differential corpus is single-source today, and every file, WebView and verification row remains `not-run`
  until it has a golden. `policy-rejected` applies to the baseline's TLS behavior only until the per-source
  exception exists; the capability matrix row says so.
- The Android and iOS readings in §1 are platform rules (API 29's W^X behavior, the iOS sandbox's ban on
  spawning a process), not measurements made by this repository on a device.

## Provenance

Ticket #5; ADR 0004 and ADR 0009 (the execution model and what the limits do); ADR 0007 and
`docs/user-data-contract.md` (where state lives); `tool/runtime_limits_prototype/` (the measured limits); the
frozen tree at `14dd24945b2914ce2708b8abaa4ee67ceef892af` (local `gedoor/legado` snapshot) for every
`JsExtensions.kt`, `BaseSource.kt`, `CacheManager.kt`, `CookieStore.kt`, `NetworkUtils.kt`, `HttpHelper.kt` and
`SourceVerificationHelp.kt` citation above; `docs/compatibility/book-source-capability-matrix.md` for the rows
this decision changes. The follow-up tickets this decision creates are #30 (the per-source TLS exception), #31
(named refusals for the deferred members, the emulated identity, UA and log surfaces), #32 (the user-confirmed
browser and captcha hatches) and #33 (font de-obfuscation).
