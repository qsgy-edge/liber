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

## What still fails

The comparison is **red** and stays red until the open items are resolved:

1. The raw effective cookie order. The product jar keeps one insertion-ordered
   map, so a session pair written before a persistent pair keeps that position
   where the frozen `CookieStore.getCookie` merges the persistent map first. The
   pairs are identical; the raw strings are not, and the decision keeps the raw
   string strict. Four probe rows and four wire rows in the seed phase.
The stage-boundary items of the previous checkpoint are resolved: a details
step makes only its information request, its `loginCheckJs` probe is the
information marker, and the TOC stage makes its own request and changes it.

The JSON bare-property item is resolved too: a simple bare property name is
json-path's canonical root property (`$.name`), so source B's
`ruleSearch.kind = "json"` reads the document's `json` property and answers the
frozen empty value when the document has none. The shared reader (`validate`
and `extract`) treats that one supported form as a path — a merge whose branches
are all supported forms included — while `$` paths, the dot-leading recursive
form, mode prefixes, scripts, templates, replacements and every documented
refusal are unchanged.

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
compare-only replay is never called another product run. No phone, ADB, corpus
or capture mutation, golden edit, runtime/persistence redesign or public-API
addition is part of this lane. `coverageGaps` from the corpus stay listed as
coverage gaps; nothing here closes a capability row, #137 or Spec A #133.
