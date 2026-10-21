# AUTH-SESSION-01 — the product side of the frozen login/header/Cookie corpus

The frozen corpus (`fixtures.json`) and the device harness are the producer lane's
shared boundary; this file and the two Dart entry points beside it are the
product lane. Nothing here is a compatibility claim: it runs the corpus through
the product as two real OS processes, compares every portable value and wire
value with the controller's raw captures, and reports what still differs.

Status: **measured, not accepted**. Both phases run to completion and every
structural check passes; the comparison fails only on the Cookie rows listed
under [What still fails](#what-still-fails). Those rows are open work, not
accepted differences.

## What runs

```bash
dart run tool/auth_session/compare.dart \
  --capture=<controller/auth-capture-01> \
  --evidence=<a2-auth-product/attempt-N> \
  --library=<this worktree's fjs.dll> \
  [--handoff=<controller/a2-auth-session-handoff.json>]
```

Two replay forms compare reports that already exist, without touching the
device or starting a product process:

```bash
dart run tool/auth_session/compare.dart --compare-only <seed.json> <restart.json>   --golden-seed=<capture>/seed-report.json   --golden-restart=<capture>/restart-report.json [--out=<report.json>]

dart run tool/auth_session/compare.dart --controls-only   --capture=<capture>   --seed-product=<seed.json>   --restart-product=<restart.json>   --evidence=<dir> [--handoff=<json>] [--library=<fjs.dll>]
```

`--compare-only` is what the controls invoke for each copy; `--controls-only`
runs the whole control set against a pair of already-completed product reports,
so a comparator-only change can be replayed on bound reports without repeating
the HTTP phases.

The comparator first validates the frozen captures (identity, corpus LF pin,
target, harness, provider containment, request trace against the corpus, ordered
observation set, listener/terminal/ownership receipts, and the controller handoff
when given), then starts the two product phases as two terminated Dart processes:

```bash
dart run tool/auth_session/runner.dart seed    <fjs.dll> <root> <report.json>
dart run tool/auth_session/runner.dart restart <fjs.dll> <root> <report.json>
```

`seed` requires a root that does not exist, writes `owner.json` and retains it;
`restart` is a second process that validates that owner before opening the
space, reads the cookie/login state **before any request**, and removes the
root. Each report carries `phase`, `pid`, `runId`, the measured corpus/target/
library/runner hashes, the actual request trace with its stage, the ordered
observation set, the isolation and cleanup receipts, and the product's own
single-tier cookie receipt (`sessionTier`).

## What each step measures, and through which product API

| Corpus step | Product path |
|---|---|
| `login` | `SourceLoginSession.submit` — `putSourceLoginInfo` + the real `loginUrl` script through `InProcessSourceScriptRuntime`, with `java.connect`, `cookie.setCookie` and `source.putLoginHeader`; then `loginInfo()`/`loginHeader()`/`loginHeaderMap()` and the script's `source.put` probe |
| `headerMap` | the `source.getHeaderMap(false|true)` binding over the real `_headers` path (there is no Dart-level member for the map) |
| `stage` | `openBookSourcePipeline(...).search`, `.bookInfo`, `.tableOfContents`, `.chapter` over `HttpSourceTransport`, one pipeline per source, with the space's `SourceHostState` and the installation `androidId`. A details step runs the frozen `getBookInfoAwait` stage alone and a TOC step runs `getChapterListAwait` alone; a details-only book (A3, A9) therefore stops after its information response |
| `cookieState` | `SourceHostState.cookiesFor(...)` after `ready()`: `effective`, sorted `keys`, `loginHeader`, `loginHeaderMap` |
| `cookieKeyRemoval` | a declared fixture action: read the jar's live header, drop the declared keys, `SourceCookieJar.set` the remaining pairs in the same order (the product exposes no per-key removal member; the frozen `CookieManager.removeCookie(url, key)` removes one key of the same site's jar and rewrites the persistent remainder through `CookieStore.setCookie`) |
| `removeLoginHeader` / `loginHeaderPut` | `SourceLoginSession.removeLoginHeader` / `putSourceLoginHeader` over the same jar |
| `state` | the login header, login info map and cookie probe per source |

`tocUrl` on a details observation is the value the information stage itself
carried: `SourceBookInfo.tocUrl`, the declared `ruleBookInfo.tocUrl` text with
the frozen `BookInfo.kt:150-152` empty-rule fallback to the book's own address.
It is read before any TOC request exists — no request of a later stage stands in
for it, and no trace scan is involved.

The product's isolation surface is the workspace root (`manifest.json` and
`spaces/default/data.db`); unlike the frozen capture it has no task-prefixed
SharedPreferences outside that root, and the report says so instead of implying
one. The native WebView provider receipt, profile paths and cookie/cache row
inventories stay provenance: they are validated as the *capture's* receipts,
never as a portable compared schema.

## What is compared

- Requests: the causal order, method, resolved path and the **exact raw query
  bytes** against the corpus declaration; source-controlled headers with
  header-name case and the contract's platform-generated names
  (`Host`, `Content-Length`, `Accept-Encoding`, `Connection`) ignored; body
  bytes; no internal `CookieJar` marker on the wire.
- Observations: every declared field, type and order — the login UI rows,
  `putLoginInfo`, the login info map, the login outcome probe, the header maps,
  search results, book info, chapters, content text, the `loginCheckJs` probe,
  and each cookie probe's `url`, `domain`, `keys`, `loginHeader` and
  `loginHeaderMap`.
- Receipts: the product's own process/phase identity, root ownership chain
  (seed owner hash read by the restart), retained/removed root, listener and
  database closure, and the frozen capture's own terminal/ownership/provider
  receipts before any value is compared.

The effective cookie **pair map** (`keys`) is compared strictly, and the raw
**effective string** — on a probe and on the wire — is compared strictly too.
When the strings differ only in pair order both strings and the pair-map
equality are recorded in `cookieOrderDifferences`, and the comparison still
fails: an unexplained raw difference is never a `notCompared` row, a
`policy-rejected` row or a pass.

## Approved differences carried with evidence

Only the previously approved field-specific rows are carried, each with the
actual expected and observed values and the row it belongs to:

- `session-tier` — the frozen capture's `persistent`/`session` split and its
  `sessions` map (process-memory session cookies, `CookieManager.kt:42-53`)
  against the product's one storage shape (ADR 0011 §3,
  `book-source-differential-contract.md` known divergences). The product's own
  claim is gated: `persistent` must equal `effective` and `session` must be
  null.
- `login-header-precedence` — a key the source's static `header` rule also
  declares keeps the static value in the product, where the frozen login header
  wins (capability matrix, login flow and login headers). The entry pins both
  values: the observed value must be the corpus' static header value and the
  expected value must differ from it; anything else is a mismatch.

## The Cookie result and what the existing contract already covers

The comparison passes with **no unapproved mismatch**: the eight raw Cookie-order
rows that used to fail are gone because the product jar now serializes the way
the frozen `CookieStore.getCookie` does.

- **Ordering.** The jar keeps one value map and one private, process-only set of
  the names that have a persistent position, ordered by each name's first
  persistent or script write. A serialized header is those names in that order,
  then the never-persistent names in their own arrival order — the frozen
  persistent map followed by the session map. A later session write to a name
  already persistent keeps its position; a session-first name written
  persistently joins the persistent block then. A response cookie is persistent
  when its `Expires` or `Max-Age` attribute is valid to the frozen okhttp 4.12.0
  parser — the same token-date scan and two-digit-year mapping, the same
  `Long.parseLong` integer rules (any Unicode decimal digit that fits a signed
  64-bit value, and the source's ASCII `-?\d+` overflow retry), and the same
  five-code-unit whitespace trim (tab, line feed, form feed, carriage return and
  space; every other control character is data) — and a script
  `setCookie`/`replaceCookie` is persistent. An invalid attribute is ignored
  and never resets an earlier valid one. Nothing here enforces an
  expiry, rejects an input or stores a second value: the durable row is still
  the one row per pair, and every deletion path (`removeCookie`, a source
  delete, a clear) drops the ordering metadata with the value.
- **Two restart session-cookie wire rows, under the contract's existing
  divergence.** Restart request indexes 0 and 1: the frozen header is
  `sidA=after; extraA=e2`, the product's also carries `ssA=after; ss2=sx2` - the
  session pairs the same source's validated seed capture recorded, kept across
  the restart in the product's one tier.
  `book-source-differential-contract.md:132` already names session-cookie
  survival across a restart as a divergence and requires a fixture that observes
  it to report expected and observed values in `notCompared`. Those two rows are
  reported that way (`row: session-tier`, `kind: restart-session-cookie-wire`,
  the attributed pairs, the raw attributed segments and both full raw strings).
  The attribution is bounded to the raw wire text: restart phase only, the
  seeded source only, and a whole `;`-separated segment whose text is exactly one
  recorded session `name=value`. Removing only those segments must leave the
  native expected header byte for byte; nothing is trimmed, re-rendered or
  skipped, so a wrong value, a missing or duplicated pair, an unknown cookie, an
  empty segment, a changed separator or spacing, a reordered frozen pair or a
  seed-phase use stays a strict failure.

The approved `session-tier` and `login-header-precedence` rows carry their exact
expected and observed values, and every compared map keeps presence: an absent
field and an explicit null are different observations, so a dropped nullable
field fails. A completed phase must also carry a present, empty `serverErrors`
list and a present, null `analysisFailure`, and each ordered `stageTrace` entry
must be the captured causal entry for its own request.

The product's stage API and JSON reader are implemented as follows:
`BookSourcePipeline.bookInfo` returns the `SourceBookInfo` carrier (book,
declared TOC address, TOC base, book request, and the information analysis's own
`key`/`page` bindings), `tableOfContents` continues from it with that context,
`details` is their composition and keeps its pre-request setup order; the JSON
reader reads a simple bare property name as its canonical `$.name`, evaluates an
accepted merge branch with the whitespace around its operator, keeps the
dot-leading recursive form and every documented refusal, and treats an explicit
interpolation or script as the literal value it resolved to.

## Negative controls

The comparator runs fifteen controls on copies of the immutable captures and of
the product reports: a changed golden value, swapped golden requests, swapped
golden observation ids, a changed golden target, a broken golden replay receipt,
a changed product value, swapped product requests, a changed product identity, a
reordered, a re-encoded and an absent raw query, a false product start time, a
changed non-cookie request header, a changed cookie value and a reordered cookie
header.

Each control is compared with **its own baseline**, the real comparison of the
unmutated inputs: the difference it introduces must appear as a mismatch key
(surface + phase + request index/header or observation id/field) that the
baseline does not already report. A row the run already fails — the Cookie order
rows today — therefore cannot satisfy a control, and a control whose
otherwise-matching target does not exist in the reached trace is reported as
`not-applicable` with its reason instead of passing. The originals are re-hashed
afterwards and must be byte-identical.

## Limits

One product session is compared with both independently captured native pairs;
compare-only replay is never called another product run. No phone, ADB, corpus or
capture mutation, golden edit or runtime/persistence change is part of this lane.
The stage entries and the JSON bare-property reading are product API/behaviour
that earlier decisions approved and that this lane implements; `@@`-prefixed
rules are still refused by the JSON pipeline's rule validation, so the literal
form here is an interpolation or a script, never `@@`. `coverageGaps` from the
corpus stay listed as coverage gaps; nothing here closes a capability row, #137
or Spec A #133.
