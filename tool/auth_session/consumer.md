# AUTH-SESSION-01 — the product side of the frozen login/header/Cookie corpus

The frozen corpus (`fixtures.json`) and the device harness are the producer lane's
shared boundary; this file and the two Dart entry points beside it are the
product lane. Nothing here is a compatibility claim: it runs the corpus through
the product as two real OS processes, compares every portable value and wire
value with the controller's raw captures, and reports what still differs.

Status: **partial**. The measurement runs as far as the corpus allows and the
comparison fails on the rows listed under [What still fails](#what-still-fails).
Those rows are open work, not accepted differences.

## What runs

```bash
dart run tool/auth_session/compare.dart \
  --capture=<controller/auth-capture-01> \
  --evidence=<a2-auth-product/attempt-N> \
  --library=<this worktree's fjs.dll> \
  [--handoff=<controller/a2-auth-session-handoff.json>]
```

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
| `stage` | `openBookSourcePipeline(...).search/details/chapter` over `HttpSourceTransport`, one pipeline per source, with the space's `SourceHostState` and the installation `androidId` |
| `cookieState` | `SourceHostState.cookiesFor(...)` after `ready()`: `effective`, sorted `keys`, `loginHeader`, `loginHeaderMap` |
| `cookieKeyRemoval` | a declared fixture action: read the jar's live header, drop the declared keys, `SourceCookieJar.set` the remaining pairs in the same order (the product exposes no per-key removal member; the frozen `CookieManager.removeCookie(url, key)` removes one key of the same site's jar and rewrites the persistent remainder through `CookieStore.setCookie`) |
| `removeLoginHeader` / `loginHeaderPut` | `SourceLoginSession.removeLoginHeader` / `putSourceLoginHeader` over the same jar |
| `state` | the login header, login info map and cookie probe per source |

`tocUrl` on a details observation is a **labelled projection**: the product's
`details` call runs the frozen `getBookInfoAwait` and `getChapterListAwait`
together and exposes no stored `getTocUrl` member, so the value is the TOC
request that current call emitted. The projection snapshots the pipeline trace
length before the call and accepts exactly one newly emitted TOC request for
that book; a missing or ambiguous one fails. It is a request provenance, not a
stored-getter, retained-body, redirect or final-model claim.

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

## What still fails

The comparison is **red** and stays red until the open items are resolved:

1. A details step with no following toc step. The product's `details` call
   always runs the TOC stage, so `seed.details.A.afterRemoval` (A3) and
   `restart.details.A` (A9) emit a TOC request the corpus declares no response
   for. The phase fails on that request.
2. The `loginCheckJs` probe of a details step. The product's one call runs both
   frozen stages before the probe is read, so `seed.details.*.check` carries the
   TOC-stage response body where the frozen capture carries the info-stage body.
3. The raw effective cookie order. The product jar keeps one insertion-ordered
   map, so a session pair written before a persistent pair keeps that position
   where the frozen `CookieStore.getCookie` merges the persistent map first.
   The pairs are identical; the raw strings are not, and the decision keeps the
   raw string strict.

Items 1 and 2 are the same product-stage-boundary question (one composite
`details` call against two frozen stages); they are with the controller and are
not repaired or normalized here.

## Negative controls

The comparator runs thirteen controls on copies of the immutable captures and of
the product reports: a changed golden value, swapped golden requests, swapped
golden observation ids, a changed golden target, a changed product value, an
added product request, a changed product identity, a reordered, a re-encoded and
an absent raw query, a changed cookie value, a reordered cookie header, and a
false restart-cleanup receipt. Each must fail with its intended exit code and,
where declared, at its intended comparison surface; the originals are re-hashed
afterwards and must be byte-identical.

A control whose intended surface is a request header can only reach that surface
once a phase completes its declared request trace, so while item 1 keeps the
seed phase short the two cookie-header controls fail their surface requirement
instead of passing silently.

## Limits

One product session is compared with both independently captured native pairs;
compare-only replay is never called another product run. No phone, ADB, corpus
or capture mutation, golden edit, runtime/persistence redesign or public-API
addition is part of this lane. `coverageGaps` from the corpus stay listed as
coverage gaps; nothing here closes a capability row, #137 or Spec A #133.
