# Book Source Capability Matrix (Frozen Baseline vs Current Implementation)

Frozen baseline: `14dd24945b2914ce2708b8abaa4ee67ceef892af` (local `gedoor/legado` snapshot)
Frozen WebView/HTTP contract: [book-source-differential-contract.md](book-source-differential-contract.md)
Product revision at survey: `ee8f235` (`master`)
Survey date: 2026-09-15 UTC

## Verdict

- **CONFIRMED** — The frozen Book Source execution surface has six axes: source fields, rule grammar, JavaScript host surface, request/URL semantics, pipeline features, and product-side reading features. This document inventories the first five; the sixth is listed only as declared non-goals.
- **CONFIRMED** — The current product implements a bounded slice of all five axes: the Rust HTML rule adapter (jsoup selectors, the Legado rule layer, and the extraction operations), a `$.`/`$..`-style JSON adapter, the `java.*` request methods plus the rule-state, cookie, cache, logging and encoding members, the frozen request defaults and redirect rules, and four pipeline stages with page-chaining.
- **CONFIRMED** — Several current behaviors are *divergent* rather than absent: the query characters Dart's client escapes that the frozen one sends raw, cookie keys that are the exact host instead of the effective domain, a declared `Cookie` that is not forwarded across origins, a source debug console that records instead of showing messages, `t2s`/`s2t` and Chinese-numeral `toNumChapter` gaps, and JSON rules that silently drop a ` @js:` suffix instead of executing or rejecting it.
- **UNVERIFIED** — Every status below is a source-level comparison against the frozen commit above. Only the five-source live triage in [Sample weighting](#sample-weighting) is runtime evidence, and it is an observation, not a golden. No per-capability runtime row exists: the extraction and selector rows added by #12 are source-derived values checked by `tool/html_adapter_gate.dart` in CI, and their frozen-device rows are `not-run` (`tool/html_oracle/README.md`).
- **UNVERIFIED** — The sample sources hit 18 of the sampled capability tokens and hit none of `@CSS:`-style rules, `@XPath:`, `@Json:` element rules, `&&`/`%%` merges, `@get:`, cache bindings, or the login fields. Priority in [Proposed slice order](#proposed-slice-order) is ordered by blocking impact, then by sample frequency; it is not a compatibility claim.

## Boundary

In scope: everything reachable while executing an already-parsed Book Source through search, book information, table of contents, and chapter content, plus the request semantics those stages use.

Out of scope: UI reproduction, bookshelf/sync semantics, migration format, differential-fixture design, the frozen WebView row set, and store distribution. Data migration and local-library contracts have their own documents.

## Status vocabulary

| Mark | Meaning |
|---|---|
| ✅ | Implemented and covered by an automated test or gate on Windows |
| 🟡 | Implemented partially, or implemented with a known behavioral divergence from the frozen baseline |
| ❌ | Not implemented; the capability is currently unreachable |
| ⛔ | Deliberately rejected with an explicit error, or reserved for a security decision |

## Method

Frozen side (read-only, no execution): `data/entities/BookSource.kt`, `data/entities/BaseSource.kt`, `data/entities/rule/{SearchRule,ExploreRule,BookInfoRule,TocRule,ContentRule,ReviewRule}.kt`, `model/analyzeRule/{AnalyzeRule,RuleAnalyzer,AnalyzeByJSoup,AnalyzeByXPath,AnalyzeByJSonPath,AnalyzeUrl}.kt`, `help/JsExtensions.kt`, `help/http/{HttpHelper,OkHttpUtils,CookieStore,CookieManager}.kt`, `model/webBook/{WebBook,BookChapterList,BookContent}.kt`.

Product side: `lib/source/{html_rule_adapter,native_library,json_source_rules,html_source_pipeline,json_source_pipeline,source_url_rules,js_source_runtime,source_host_dispatcher,http_source_transport,online_reader_page,online_reading_store}.dart`, plus the gates in `tool/`.

Runtime observation: `tool/source_triage.dart` runs each source of one exported file through the four stages and reports stage outcomes only. It never logs headers, tokens, URLs, or response bodies.

## Sample weighting

Five user-exported Book Sources were used to weight the gaps. The export itself is **not** stored in this repository (one source carries an authorization header); only names and feature hits are recorded here. Rule bodies, headers, and tokens are not reproduced. The last column is the state after the request-semantics slice (issue #9, re-measured 2026-09-15 with `tool/source_triage.dart`).

| Source | Pipeline | Four-stage triage | First failure |
|---|---|---|---|
| 书趣阁 | HTML | ❌ | `@CSS` extension `:nth-child(n+1)` rejected before any request (selector family, slice 4) |
| 沧元图小说 | HTML | ❌ | rule JavaScript: `searchUrl` uses `{{cookie.removeCookie(source.key)}}`; no `cookie` binding (host surface, slice 2) |
| 猫眼看书 | JSON | ❌ | rule JavaScript: `,{"js":"java.toast(...)"}`; no `java.toast` (host surface, slice 2) |
| 就爱文学 | HTML | ✅ (search, info, toc, content) | — |
| 无限小说网 | HTML | ⏳ search now passes | its search previously parsed to zero results; the request-semantics slice fixed that stage, and `content` extraction is the next blocker (slice 4) |

Feature hits across the sample (counts of sources containing the token):

| Capability | Hits | Capability | Hits |
|---|---|---|---|
| `{{ }}` templates, `{{key}}`, `,{...}` options | 5/5 | `source.*` | 3/5 |
| `##` replacement | 4/5 | `\|\|` merge | 2/5 |
| `java.*` | 4/5 | `@textNodes`, `@ownText`, `class.`, `@tag.`, `:nth-child`, `cookie.*`, login fields | 1/5 each |
| `@js:`/`<js>`, `@html`, `{{page}}` | 3/5 | `@CSS:`, `@XPath:`, `@Json:`, `&&`, `%%`, `@get:`, `:eq(`, `cache.*` | 0/5 |

The sample is therefore evidence for *legacy* rule syntax and rule-level JavaScript, and no evidence at all for the CSS-mode and XPath families.

## Capability matrix

### A. Book Source fields (`BookSource.kt:41-97`, `rule/*.kt`)

| Capability | Frozen | Status |
|---|---|---|
| `searchUrl` + `,{...}` options | `AnalyzeUrl.kt:208-248`, `671-716` | 🟡 `method`/`headers`/`body`/`js`/`retry` ✅; ⛔ `charset`, `type`, `webView`, `webJs`, `webViewDelayTime`, `serverID` |
| `ruleSearch` | `SearchRule.kt:14-24` | ✅ `bookList`/`name`/`bookUrl`/`author`/`kind`/`coverUrl`; ❌ `intro`/`lastChapter`/`wordCount`/`updateTime`/`checkKeyWord` |
| `ruleBookInfo` | `BookInfoRule.kt:13-24` | ✅ `name`/`author`/`intro`/`kind`/`coverUrl`/`lastChapter`/`tocUrl`; 🟡 `init` (JSON pipeline only), `canReName` (accepted, unused); ❌ `downloadUrls` |
| `ruleToc` | `TocRule.kt:10-19` | ✅ `chapterList`/`chapterName`/`chapterUrl`/`nextTocUrl`; ❌ `preUpdateJs`/`formatJs`/`isVolume`/`isVip`/`isPay`/`updateTime` |
| `ruleContent` | `ContentRule.kt:13-21` | ✅ `content`/`nextContentUrl`; 🟡 `replaceRegex` (`##regex##replacement` and `{{chapter.title}}` only; a source that also writes an inline `##` replacement in `content` is ⛔ rejected with an explicit error instead of being applied twice — the frozen content-stage replacement belongs to #17); ❌ `title`/`webJs`/`sourceRegex`/`imageStyle`/`imageDecode`/`payAction` |
| `ruleExplore`, `ruleReview` | `ExploreRule.kt`, `ReviewRule.kt` | ❌ |
| `header` | `BaseSource.kt:103-123` | ✅ static JSON, `@js:`, `<js>` |
| `loginUrl`, `loginUi`, `loginCheckJs` | `BaseSource.kt:134-182`, `WebBook.kt:211` | ❌ rejected with an explicit error |
| `jsLib` | `BaseSource.kt:245-252`, `JsExtensions.kt:253` | 🟡 local shared library ✅; remote URL and `importScript` ❌ |
| `enabledCookieJar` | `AnalyzeUrl.kt:597-615` | 🟡 session retention only; no domain store or persistence parity |
| `bookSourceType` | `BookSource.kt:41` | 🟡 text (`0`) only; audio/image/file sources ❌ |
| `bookUrlPattern`, `coverDecodeJs`, `variable`, `variableComment`, `concurrentRate` | `BookSource.kt:43-97`, `BaseSource.kt:202-228` | ❌ |

### B. Rule grammar and selectors

The rows below include the #12 adapter rows. `✅` there means implemented and covered by the
crate's tests plus the gate corpus (`tool/html_adapter_gate.dart`, run for every destination platform in CI); their frozen-device
rows are `not-run` (`tool/html_oracle/README.md`), so nothing in this section is a
device-confirmed compatibility claim.

| Capability | Frozen | Status |
|---|---|---|
| Mode prefixes | `AnalyzeRule.kt:526-560` | ✅ `@CSS:` and legacy bare, `@@` literal; ⛔ `@Json:` element rules, `@XPath:` and a leading `/` rejected with an explicit error |
| Merge operators `&&`, `\|\|`, `%%` | `RuleAnalyzer.kt:165`, `AnalyzeByJSoup.kt:131-192` | ✅ ported, including the frozen quirk that the first separator found is the only one that splits |
| `@` chain, `.N`, `!N`, `N:M` | `AnalyzeByJSoup.kt:159-190`, `303-460` | ✅ also the `[i, a:b:c]` list form with negative indices and steps |
| `$1` regex captures in rules | `AnalyzeRule.kt:600-616` | ⛔ rejected by the adapter; the rule-JavaScript family is #3 |
| Extraction `text`, `textNodes` | `AnalyzeByJSoup.kt:232-252` | ✅ (`textNodes` keeps the frozen raw-trim, not a whitespace-collapsed value) |
| Extraction by attribute name (`@content`, `@data-*`) | `AnalyzeByJSoup.kt:272` | ✅ every attribute name; the baseline has no `attr(x)` form, so that row was a plan error |
| Extraction `ownText`, `html`, `all` | `AnalyzeByJSoup.kt:253-272` | ✅ jsoup serialization with its pretty printing; `html` drops `script`/`style` and `all` keeps them, as frozen. The frozen `AnalyzeRule.getString` entity unescape runs over the result; the table used is HTML5's, a superset of Java's HTML 4 one |
| Replacement `##regex` and `##regex##replacement` | `AnalyzeRule.kt:421-430`, `650-665` | ✅ |
| Replacement fourth field (`replaceFirst`) | `AnalyzeRule.kt:663-665` | ✅ |
| Rule-level templates `{{js}}`, `@get:key`, inline `{json}` put parameters | `AnalyzeRule.kt:404-416`, `575-620` | ⛔ rejected by the adapter; templates are #3 |
| `{{baseUrl}}`, `{{book.*}}`, `{{title}}` inside rule fields | `AnalyzeRule.kt:538-620` | ❌ (URL rules only) |
| JSONPath adapter | `AnalyzeByJSonPath.kt` | 🟡 `$.`, `$..`, `[*]`, numeric index; ❌ filters/slices |
| Legacy sub-syntax `text.x@href` | `AnalyzeByJSoup.kt:319` | ✅ |
| Legacy sub-syntax `class.x`, `@tag.x` | `AnalyzeByJSoup.kt:434+` | ✅ `class.x`, `tag.x`, `id.x`, `children.x`, `text.x` |
| Jsoup CSS extensions (`:nth-child`, `:eq`, `:contains`, `:has`, …) | `AnalyzeByJSoup.kt:144` (real Jsoup `select`) | ✅ ported from jsoup 1.16.2 (`:lt`/`:gt`/`:eq`, the `nth-*` family, `:contains`/`:matches` variants, `:has`/`:not`, attribute operators, `:empty`/`:root`, `*|tag`); ⛔ `:matchText` rejected because it rewrites the tree |

### C. JavaScript host surface

Frozen bindings: `AnalyzeUrl.kt:338-352` — `java`, `baseUrl`, `cookie`, `cache`, `page`, `key`, `speakText`, `speakSpeed`, `book`, `source`, `result`. Frozen `java` surface: `help/JsExtensions.kt`.

| Capability | Status |
|---|---|
| Bindings `baseUrl`, `key`, `page`, `result` | ✅ |
| Binding `java` | 🟡 `connect`/`ajax`/`get`/`head`/`post` and the one-argument `get` rule-state overload; ❌ multi-URL `ajax`, `ajaxAll`, the header-string `connect` overload |
| Binding `source` | 🟡 `getKey`, `getName`, `getTag`, `getVariable`, `put`/`get` and the common fields; ❌ `getHeaderMap`, `enabledCookieJar` handling, login helpers |
| Binding `book` | 🟡 present but always `null`, so `java.get('bookName')` has no book to read |
| Binding `cookie` (`CookieStore`) | 🟡 `setCookie`, `replaceCookie`, `getCookie`, `getKey`, `removeCookie` over the session jar; ❌ persistence, and two recorded divergences: keys are the exact host instead of the effective domain, and the frozen 4096-character random-pair trim is not reproduced |
| Binding `cache` (`CacheManager`) | 🟡 the whole accessor set (`get`, `put`, `getInt`/`getLong`/`getDouble`, `delete`, `putMemory`, `getFromMemory`, `deleteMemory`) over a process-lifetime store; ❌ persistence, `getFile`/`putFile`/`getQueryTTF` |
| `java.get`/`put` rule state | ✅ scoped to one source analysis; ❌ chapter/book variables, which this product has no objects for |
| `java.toast`, `longToast`, `log`, `logType` | 🟡 recorded instead of shown: this product has no source debug console yet |
| `java` encoding/utility family | 🟡 `base64*` (Android flags), `hex*`, `encodeURI`, `htmlFormat`, `timeFormat*` (pattern subset, local time), `strToBytes`/`bytesToStr` (UTF-8 only, other charsets throw), `toNumChapter` (fullwidth digits only), `toURL`; ❌ `t2s`/`s2t` (needs a conversion table), `toNumChapter` for Chinese numerals, `androidId` |
| `java` file/cache family (`downloadFile`, `cacheFile`, `getFile`, `readFile`, `deleteFile`, `unzip*`) | ⛔ deferred on purpose: writing files an untrusted source names is a data-integrity decision that belongs to the untrusted-source boundary, and the WebView/verification members wait for the WebView adapter lane |
| `java` WebView family (`webView*`, `startBrowser*`, `getVerificationCode`, `getWebViewUA`) | ⛔ options rejected; the Windows WebView adapter exists but is not wired to sources |
| `java.importScript` (remote `jsLib`) | ❌ remote `jsLib` still loads nothing; local `jsLib` shares one scope across a source's rules |
| Synchronous return contract | ✅ native in-process broker, cancellable host I/O |

### D. Request and URL semantics

| Capability | Frozen | Status |
|---|---|---|
| URL options (`method`, `headers`, `body`, `js`, `retry`, `origin`) | `AnalyzeUrl.kt:208-248` | ✅ (`origin` parsed and ignored, as frozen does on the HTTP path) |
| Parameter encoding (`charset`, `escape`, already-encoded detection) | `AnalyzeUrl.kt:279-334` | 🟡 the default path (already-encoded skip plus the frozen query encoder) is implemented; `charset`/`escape` options are still rejected, and response decoding is UTF-8 only |
| Query re-encoding (nothing else) | `NetworkUtils.encodedQuery`, `AnalyzeUrl.kt:265-278` | 🟡 reproduced, with one platform seam: Dart's HTTP client percent-encodes `{`, `}`, `\|`, `^`, `` ` ``, `\` inside a query where the frozen client sends them raw, and keeps `'` raw where the frozen encoder escapes it |
| `{{key}}` substitution | `AnalyzeUrl.kt:184-200` | ✅ raw substitution as a JavaScript binding; escaping happens once in the query or body encoder |
| `{{page}}` substitution, page lists (`<1,2,3>`) and multi-page search | same | 🟡 the pipeline substitutes the requested page and repeats the last list entry; the reader UI still requests page 1 only |
| Default request headers (`User-Agent`, `Keep-Alive`, `Connection`, `Cache-Control`) | `HttpHelper.kt:72-82` | ✅ injected with the frozen append rule; a source that declares `User-Agent: null` keeps a platform default instead of the baseline's Dalvik agent |
| Redirect semantics (300/301/302/303 → GET without body; 307/308 keep method and body; 20 follow-ups) | OkHttp 4.12 `RetryAndFollowUpInterceptor` | ✅ including the cross-origin `Authorization` drop; a declared `Cookie` is *not* forwarded to another origin here, a deliberate divergence: the frozen client forwards it |
| Non-2xx retry from the `retry` option | `OkHttpUtils.kt:29-43` | ✅ |
| Connection retry, 60 s read/call budgets | `HttpHelper.kt:56-62` | 🟡 30 s request budget, no separate connection-retry parity |
| Per-source concurrency limit (`ConcurrentRateLimiter`, `concurrentRate`) | `AnalyzeUrl.kt:479`, `JsExtensions.kt:371` | ❌ |
| Cookie priority and persistence (`setCookie`, `enabledCookieJar`) | `AnalyzeUrl.kt:597-615` | 🟡 session-scoped only |
| TLS policy | `HttpHelper.kt:63-65` (unsafe trust) | ⛔ rejected by policy; a divergence recorded in the differential contract |
| WebView request path | `BackstageWebView`, `webView*` options | ⛔ options rejected; the Windows WebView adapter exists but is not wired to sources |

### E. Pipeline features

| Capability | Frozen | Status |
|---|---|---|
| Search → information → table of contents → content | `WebBook.kt:34-358` | ✅ |
| Page chaining (`nextTocUrl`, `nextContentUrl`) | `WebBook.kt:224-356` | ✅ single URL per page; ❌ list results |
| `ruleBookInfo.init` | `WebBook.kt:152-198` | 🟡 JSON pipeline only |
| Old-style HTML selectors | `AnalyzeByJSoup.kt` | ✅ subset |
| Explore (categories) | `WebBook.kt:93-140` | ❌ |
| Reviews (paragraph comments) | `ReviewRule.kt` | ❌ |
| Login flow and login headers | `BaseSource.kt:134-182` | ❌ |
| Source variables (`variable`, `getVariable`, `setVariable`) | `BaseSource.kt:202-228` | ❌ |
| Table-of-contents pre-processing and formatting (`preUpdateJs`, `formatJs`) | `WebBook.kt:211`, `BookChapterList.kt` | ❌ |
| Volume/VIP/paid markers (`isVolume`, `isVip`, `isPay`) | `TocRule.kt`, `BookChapterList.kt` | ❌ |
| `bookUrlPattern` matching | `BookSource.kt:43` | ❌ |
| Cover decoding (`coverDecodeJs`) | `BookCover.kt` | ❌ |
| Content source validation (`sourceRegex`) | `ContentRule.kt`, `WebBook.kt` | ❌ |
| Image style/decoding/pay actions | `ContentRule.kt` | ❌ |
| Download (`downloadUrls`, file sources) | `BookInfo.kt` | ❌ |
| Auto source switching, precise search | `WebBook.kt:358` | ❌ |

### F. Declared non-goals

TTS/reading aloud, image and audio Book Sources, review UI, cloud synchronization, pixel-level UI reproduction, bundled browser engine, required backend. These stay out of the compatibility path and are not gaps to close for the current target.

## What the sample does not exercise

`@CSS:`-mode rules (the sample's 0/5 means the only CSS-mode evidence in this repository is `book_sources/shudugu.json`), `@XPath:`, `@Json:` element rules, `&&`/`%%` merges, `$1` captures, `@get:`/inline put parameters, `cache` binding, `replaceFirst`, `ownText`, filters in JSONPath, explore, reviews, source variables, remote `jsLib`, table-of-contents formatting, volume/VIP markers, cover decoding, `sourceRegex`, image handling, downloads, and non-text source types. Those rows must be re-checked against the frozen source rather than assumed from this sample.

## Proposed slice order

Ordered by blocking impact on running real sources, then by sample frequency. Each slice is independently verifiable and should keep its own evidence.

1. ~~**Request defaults and redirect semantics.**~~ *Implemented (issue #9, 2026-09-15): the rows above are closed except the platform encoding seam and the reader's page-1-only UI.* Default `User-Agent`/connection headers, OkHttp-style 301/302/303 → GET without body and 307/308 preserving method and body, `{{page}}` substitution, and keyword substitution matching the frozen rule. Blocks every source whose search depends on a browser-like request or a redirected POST result page.
2. ~~**JavaScript host surface.**~~ *Implemented (issue #10, 2026-09-15): `cookie.*`, `java.get`/`put`, `java.toast`/`longToast`/`log`/`logType`, `cache.*`, the `source.*` accessors, and the encoding family except `t2s`/`s2t` and `androidId`; the file and WebView members are deferred to the untrusted-source boundary and the WebView lane. Both sample sources that previously failed before any request now reach the network.* The slice covered `cookie.*`, `java.get`/`put`, `java.toast`/`log`, `cache.*`, the common utility family (`base64*`, `hex*`, `encodeURI`, `t2s`), and the `source.*` accessors.
3. **Rule-level JavaScript and templates.** `@js:`/`<js>`/`{{js}}` inside rule fields, `@get:`, inline put parameters, `{{baseUrl}}`/`{{book.*}}`/`{{title}}`, and `###` replaceFirst. Also removes the JSON adapter's silent ` @js:` truncation.
4. ~~**Extraction and selector family.**~~ *Implemented (issue #12, 2026-09-15): extraction by attribute name, `html`/`ownText`/`all`, `&&`/`||`/`%%`, `class.`/`tag.`/`text.`, the index list form and the Jsoup CSS extensions now run through the Rust adapter (`packages/fjs/liber_html`), behind one whole-document bridge call per stage. The 35 corpus rows in `tool/html_oracle/fixtures.json` are checked in CI against values read from the frozen source; the frozen-device golden is `not-run`.*
5. **Pipeline features.** Login, explore, source variables, remote `jsLib`, table-of-contents formatting, volume/VIP markers, cover decoding.
6. **Peripheral.** Multi-URL page results, `sourceRegex`, downloads, reviews, image/audio sources, reading aloud.

## Open questions

- Which JSONPath subset the frozen `AnalyzeByJSonPath` actually accepts for the corpus, and how much of it must be emulated rather than approximated.
- ~~How the ticket 12 adapter should reproduce Jsoup-specific CSS and XPath behavior without vendoring Jsoup semantics.~~ *Answered for HTML/CSS by #12: the adapter is a Rust port of jsoup 1.16.2's selector engine and Legado's rule layer (ADR 0008). The XPath row is still open and needs its own decision.*
- Whether the login flow is needed for the Windows target or stays deferred with the security boundary (ticket 05).
- What the per-source concurrency limit should be, since the frozen contract compares concurrent batches and the product currently issues one request at a time.
- Whether `{{key}}` encoding parity is a compatibility requirement or an accepted divergence; the frozen rule changes the wire bytes for non-ASCII keywords.

## Provenance and re-verification

- Frozen evidence: local snapshot at `14dd24945b2914ce2708b8abaa4ee67ceef892af`; line references above are from that revision.
- Product evidence: `master` at the survey date; statuses must be re-derived after the slices in [Proposed slice order](#proposed-slice-order) land.
- Runtime observation: `tool/source_triage.dart`; re-running it needs the private export file, which stays outside the repository.
- Re-verification rule: this matrix is a planning index, not a compatibility result. Any promoted status needs a per-capability test or gate row, and the frozen-oracle rows remain `not-run` until the differential corpus covers them.
