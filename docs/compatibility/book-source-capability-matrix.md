# Book Source Capability Matrix (Frozen Baseline vs Current Implementation)

Frozen baseline: `14dd24945b2914ce2708b8abaa4ee67ceef892af` (local `gedoor/legado` snapshot)
Frozen WebView/HTTP contract: [book-source-differential-contract.md](book-source-differential-contract.md)
Product revision at survey: `ee8f235` (`master`)
Survey date: 2026-09-15 UTC

## Verdict

- **CONFIRMED** — The frozen Book Source execution surface has six axes: source fields, rule grammar, JavaScript host surface, request/URL semantics, pipeline features, and product-side reading features. This document inventories the first five; the sixth is listed only as declared non-goals.
- **CONFIRMED** — The current product implements a bounded slice of all five axes: the Rust HTML rule adapter (jsoup selectors, the Legado rule layer, and the extraction operations), a `$.`/`$..`-style JSON adapter, the `java.*` request methods plus the rule-state, cookie, cache, logging and encoding members, the frozen request defaults and redirect rules, and four pipeline stages with page-chaining.
- **CONFIRMED** — Several current behaviors are *divergent* rather than absent: the query characters Dart's client escapes that the frozen one sends raw, cache entries that a per-source cap evicts by write order where the frozen `CacheManager` keeps one global access-ordered 600-row LRU (#37), a declared `Cookie` that is not forwarded across origins, a source debug console that records `log`/`logType` instead of showing them (`toast`/`longToast` are shown rate-limited since #31), and Chinese-numeral `toNumChapter` as a gap. `t2s`/`s2t` are implemented (issue #19) and *divergent*: ADR 0010 measures the difference from the frozen reader at 0.055 %–0.210 % of code units on the corpora it was decided with. The JSON adapter's silent ` @js:` truncation is gone: a rule field that carries a script now runs it or refuses it by name (#11).
- **UNVERIFIED** — Except for the device-confirmed rows named in [Rule grammar and selectors](#b-rule-grammar-and-selectors), every status below is a source-level comparison against the frozen commit above. Only the five-source live triage in [Sample weighting](#sample-weighting) and the executed `tool/html_oracle` golden are runtime evidence; the triage is an observation, not a golden. The extraction and selector rows added by #12 are source-derived values checked by `tool/html_adapter_gate.dart` in CI and now also compared against the frozen-device golden (`tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json`, all 39 cases: the 35 #12 added plus the four `path: rule` rows #11 added): every row matches the adapter, so the capability rows those cases cover are device-confirmed, including `Replacement fourth field (replaceFirst)`. Every other per-capability frozen-device row still has no executed golden.
- **UNVERIFIED** — The sample sources hit 18 of the sampled capability tokens and hit none of `@CSS:`-style rules, `@XPath:`, `@Json:` element rules, `&&`/`%%` merges, `@get:`, cache bindings, or the login fields. Priority in [Proposed slice order](#proposed-slice-order) is ordered by blocking impact, then by sample frequency; it is not a compatibility claim.

## Boundary

In scope: everything reachable while executing an already-parsed Book Source through search, book information, table of contents, and chapter content, plus the request semantics those stages use.

Out of scope: UI reproduction, bookshelf/sync semantics, migration format, differential-fixture design, the frozen WebView row set, and store distribution. Data migration and local-library contracts have their own documents.

## Status vocabulary

| Mark | Meaning |
|---|---|
| ✅ | Implemented and covered by an automated test or gate on a destination platform |
| 🟡 | Implemented partially, or implemented with a known behavioral divergence from the frozen baseline |
| ❌ | Not implemented; the capability is currently unreachable (a *deferred* row names the ADR that fixes its shape and the ticket that lands it — ADR 0011 §7) |
| ⛔ | Deliberately rejected with an explicit error, or reserved for a security decision |

## Method

Frozen side (read-only, no execution): `data/entities/BookSource.kt`, `data/entities/BaseSource.kt`, `data/entities/rule/{SearchRule,ExploreRule,BookInfoRule,TocRule,ContentRule,ReviewRule}.kt`, `model/analyzeRule/{AnalyzeRule,RuleAnalyzer,AnalyzeByJSoup,AnalyzeByXPath,AnalyzeByJSonPath,AnalyzeUrl}.kt`, `help/JsExtensions.kt`, `help/http/{HttpHelper,OkHttpUtils,CookieStore,CookieManager}.kt`, `model/webBook/{WebBook,BookChapterList,BookContent}.kt`.

Product side: `lib/source/{html_rule_adapter,native_library,json_source_rules,html_source_pipeline,json_source_pipeline,source_url_rules,js_source_runtime,source_host_dispatcher,http_source_transport,online_reader_page}.dart`, plus the space store under `lib/store/` and the gates in `tool/`.

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
| `searchUrl` + `,{...}` options | `AnalyzeUrl.kt:208-248`, `671-716` | 🟡 `method`/`headers`/`body`/`js`/`retry`/`charset` ✅; ⛔ `type`, `webView`, `webJs`, `webViewDelayTime`, `serverID` |
| `ruleSearch` | `SearchRule.kt:14-24` | ✅ `bookList`/`name`/`bookUrl`/`author`/`kind`/`coverUrl`; ❌ `intro`/`lastChapter`/`wordCount`/`updateTime`/`checkKeyWord` |
| `ruleBookInfo` | `BookInfoRule.kt:13-24` | ✅ `name`/`author`/`intro`/`kind`/`coverUrl`/`lastChapter`/`tocUrl`; 🟡 `init` (JSON pipeline only), `canReName` (accepted, unused); ❌ `downloadUrls` |
| `ruleToc` | `TocRule.kt:10-19` | ✅ `chapterList`/`chapterName`/`chapterUrl`/`nextTocUrl`; ❌ `preUpdateJs`/`formatJs`/`isVolume`/`isVip`/`isPay`/`updateTime` |
| `ruleContent` | `ContentRule.kt:13-21` | ✅ `content`/`nextContentUrl`; 🟡 `replaceRegex` (`##regex##replacement` and `{{chapter.title}}` only; a source that also writes an inline `##` replacement in `content` is ⛔ rejected with an explicit error instead of being applied twice — the frozen content-stage replacement belongs to #17); ❌ `title`/`webJs`/`sourceRegex`/`imageStyle`/`imageDecode`/`payAction` |
| `ruleExplore`, `ruleReview` | `ExploreRule.kt`, `ReviewRule.kt` | ❌ |
| `header` | `BaseSource.kt:103-123` | ✅ static JSON, `@js:`, `<js>` |
| `loginUrl`, `loginUi`, `loginCheckJs` | `BaseSource.kt:134-182`, `WebBook.kt:211` | ❌ rejected with an explicit error |
| `jsLib` | `BaseSource.kt:245-252`, `JsExtensions.kt:253` | 🟡 local shared library ✅; remote URL and `importScript` ❌ |
| `enabledCookieJar` | `AnalyzeUrl.kt:597-615` | ✅ the flag decides whether a response's `Set-Cookie` reaches the jar, which stays per space and scoped to a source's own site group (ADR 0011 §3, #21); a source whose flag is off still sends what the jar holds, as the frozen `setCookie` does. One divergence is recorded: the frozen session/persistent split does not survive a restart here |
| `bookSourceType` | `BookSource.kt:41` | 🟡 text (`0`) only; audio/image/file sources deferred beyond the first slice, not refused (ADR 0011 §7) |
| `bookUrlPattern`, `coverDecodeJs`, `variable`, `variableComment`, `concurrentRate` | `BookSource.kt:43-97`, `BaseSource.kt:202-228` | ❌ |

### B. Rule grammar and selectors

The rows below include the #12 adapter rows. `✅` there means implemented and covered by the
crate's tests plus the gate corpus (`tool/html_adapter_gate.dart`, run for the desktop destinations in CI - Windows, Linux and macOS; the Android and iOS jobs cross-build the native library only). The #23 frozen-device golden (`tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json`, refreshed in place by #51 to all 39 cases and compared against the Rust adapter on Windows) now confirms these rows by name: Mode prefixes; Merge operators `&&`/`||`/`%%`; `@` chain, `.N`, `!N`, `N:M` and the index list form; Extraction `text`/`textNodes`; Extraction by attribute name; Extraction `ownText`/`html`/`all`; Replacement `##regex` and `##regex##replacement`; Replacement fourth field (`replaceFirst`); Legacy `text.x@href`; Legacy `class.x`/`tag.x`; Jsoup CSS extensions; the `@js:`/`<js>` segments inside a rule field; and `{{baseUrl}}`/`{{title}}` interpolation inside a rule field. **Not device-confirmed:** the JSONPath adapter and `$1` captures, which the corpus does not reach (`notCompared`), and the `{{js}}`/`@get:`/`@put:` forms of the rule-level-template row, which the four `path: rule` cases do not carry (`notCompared`). No other row in this section is a device-confirmed compatibility claim.

| Capability | Frozen | Status |
|---|---|---|
| Mode prefixes | `AnalyzeRule.kt:526-560` | ✅ `@CSS:` and legacy bare, `@@` literal; ⛔ `@Json:` element rules, `@XPath:` and a leading `/` rejected with an explicit error |
| Merge operators `&&`, `\|\|`, `%%` | `RuleAnalyzer.kt:165`, `AnalyzeByJSoup.kt:131-192` | ✅ ported, including the frozen quirk that the first separator found is the only one that splits |
| `@` chain, `.N`, `!N`, `N:M` | `AnalyzeByJSoup.kt:159-190`, `303-460` | ✅ also the `[i, a:b:c]` list form with negative indices and steps |
| `$1` regex captures in rules | `AnalyzeRule.kt:600-616` | ⛔ rejected by the adapter; the rule-JavaScript family is #3 |
| Extraction `text`, `textNodes` | `AnalyzeByJSoup.kt:232-252` | ✅ (`textNodes` keeps the frozen raw-trim, not a whitespace-collapsed value) |
| Extraction by attribute name (`@content`, `@data-*`) | `AnalyzeByJSoup.kt:272` | ✅ every attribute name; the baseline has no `attr(x)` form, so that row was a plan error |
| Extraction `ownText`, `html`, `all` | `AnalyzeByJSoup.kt:253-272` | ✅ jsoup serialization with its pretty printing; `html` drops `script`/`style` and `all` keeps them, as frozen. The frozen `AnalyzeRule.getString` entity unescape runs over the result; the named table is HTML5's (a superset of Java's HTML 4 one) and a numeric reference is decoded whenever it is a valid scalar, where Java keeps its invalid-reference placeholders |
| Replacement `##regex` and `##regex##replacement` | `AnalyzeRule.kt:421-430`, `686-695` | ✅ |
| Replacement fourth field (`replaceFirst`) | `AnalyzeRule.kt:426-437`, `686-695` | ✅ |
| Rule-level templates `{{js}}`, `@get:key`, inline `@put:{json}` parameters | `AnalyzeRule.kt:404-416`, `575-620` | ✅ one rule-field path (`lib/source/rule_field.dart`, ticket #11) resolves them for both adapters: `{{js}}` and `@js:`/`<js>` segments run through the source runtime, `@get:`/`@put:` read and write the source's `v_<sourceKey>_<key>` variables (`java.get`/`put` share them), and a rule the frozen reader completes after a `<js>` block is ⛔ refused by name. The bare `@get:key` spelling beside the frozen `@get:{key}` is a deliberate extension; the frozen `$n` capture reference is ⛔ refused by name. Device-confirmed for the `@js:`/`<js>` segments by the #51 golden (`rule-js-trailing`, `rule-js-lt-js-block`); the `{{js}}`, `@get:` and `@put:` forms are `notCompared` |
| `{{baseUrl}}`, `{{book.*}}`, `{{title}}` inside rule fields | `AnalyzeRule.kt:538-620` | ✅ `{{...}}` interpolation runs inside every rule field (ticket #11): `baseUrl` and `title` (the chapter the content stage reads) are bound, and any other JavaScript expression reaches the runtime; `book` stays the always-null binding its own row records, so `{{book.*}}` evaluates and fails like the frozen null binding. A `{{@...}}`/`{{//...}}` expression is ⛔ refused by name, and `{{page}}`/`{{key}}` in request rules stay #9's. Device-confirmed for `{{baseUrl}}` and the always-null `{{title}}` by the #51 golden (`rule-interpolation-base-url`, `rule-interpolation-title-null`); `{{book.*}}` is `notCompared` |
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
| Binding `cookie` (`CookieStore`) | 🟡 `setCookie`, `replaceCookie`, `getCookie`, `getKey`, `removeCookie` over the session jar; ✅ persistence: the jar lives in the space's store, keyed by the registrable domain and visible to a source's own site group plus what it wrote (ADR 0011 §3, #21); one recorded divergence remains: the frozen 4096-character random-pair trim is not reproduced |
| Binding `cache` (`CacheManager`) | 🟡 the whole accessor set (`get`, `put`, `getInt`/`getLong`/`getDouble`, `delete`, `putMemory`, `getFromMemory`, `deleteMemory`); ✅ persistence: entries live in the space's store, owned by the source that wrote them, expiring on the `saveTime` deadline (ADR 0011 §3, #21) and capped at 600 rows per source — a write past the cap evicts that bucket's least recently written row, against a baseline cap that is a global access-order `LruCache` (a recorded divergence, #37); ❌ `getFile`/`putFile` are deferred with the file family and `getQueryTTF` with font de-obfuscation (ADR 0011 §2, §6); all three are present and, since #31, refuse by name with the policy instead of failing as a `TypeError` |
| `java.get`/`put` rule state | ✅ the baseline's persistent per-source variables (`v_<sourceKey>_<key>`) in the space's store, owned by the source that wrote them and capped in their own 600-row bucket (#21, #37, ADR 0011 §3); ❌ `source.getVariable`/`setVariable` is #13; ❌ chapter variables, which this product has no objects for |
| `java.toast`, `longToast`, `log`, `logType` | ✅ emulated (ADR 0011 §6, #31): every message goes into a bounded per-source log (newest 200, in memory) and `toast`/`longToast` are also shown as a rate-limited notice (at most one per source per 3 s), so a source that tells the user to finish a verification is not silent; the untrusted text is flattened and capped before display. There is still no source debug console, so `log`/`logType` output is recorded rather than shown |
| `java` encoding/utility family | 🟡 `base64*` (Android flags), `hex*`, `encodeURI`, `htmlFormat`, `timeFormat*` (pattern subset, local time), `strToBytes`/`bytesToStr` (UTF-8 only, other charsets throw), `toNumChapter` (fullwidth digits only), `toURL`; 🟡 `t2s`/`s2t` through the same HanLP-based tables and exclude list the reader converts with, measured against the frozen reader at 0.055 %–0.210 % of code units on the ADR 0010 corpora — the divergences are the frozen library's extra phrase tables, which are unlicensed and not shipped; ❌ `toNumChapter` for Chinese numerals; ✅ `androidId` is emulated as a per-install opaque id (16 lowercase hex characters, stable across restarts, kept in the installation manifest) rather than the platform identifier (ADR 0011 §6, #31) |
| `java` file/cache family (`downloadFile`, `cacheFile`, `getFile`, `readFile`, `deleteFile`, `unzip*`) | ❌ deferred, not refused (ADR 0011 §2): every member is present and, since #31, refuses by name with the policy instead of failing as a `TypeError`; the sandbox root, traversal rule, caps, archive handling and streaming download the family needs are fixed there as the constraint on #13 (remote `jsLib`) and #14 (`downloadUrls`, file-type sources), which land it |
| `java` WebView family (`webView*`, `startBrowser*`, `getVerificationCode`, `getWebViewUA`) | ❌ allowed by policy, not wired yet (ADR 0011 §4): `webView`/`webJs`/`webViewDelayTime` run headlessly through #2's adapter with the session cookie jar and `startBrowser*`/`getVerificationCode`/`openUrl` require the user's confirmation, both still unwired; ✅ `getWebViewUA` is emulated (#31) — it answers the product's non-empty, platform-plausible WebView user agent |
| `java.importScript` (remote `jsLib`) | ❌ still loads nothing: since #31 the member is present and refuses by name (the local-path half with the file family, ADR 0011 §2; the remote half with #13); local `jsLib` shares one scope across a source's rules |
| Synchronous return contract | ✅ native in-process broker, cancellable host I/O |

### D. Request and URL semantics

| Capability | Frozen | Status |
|---|---|---|
| URL options (`method`, `headers`, `body`, `js`, `retry`, `origin`) | `AnalyzeUrl.kt:208-248` | ✅ (`origin` parsed and ignored, as frozen does on the HTTP path) |
| Parameter encoding (`charset`, `escape`, already-encoded detection) | `AnalyzeUrl.kt:279-334` | ✅ the default path (already-encoded skip plus the frozen query encoder), `EncoderUtils.escape`, and a named charset's bytes through `liber_text`'s `encoding_rs`; the query is taken from the rule's own text so the charset encoder sees the source's characters. Response decoding resolves the Content-Type charset, then the document's `<meta>`, then detection, in one engine. One platform seam remains for `escape` and is recorded in the differential contract. The default path's upper-case `%XX`, its `%20` for a space and its already-encoded short-circuit are device-pinned by the frozen RequestOracle (`query-key-raw`, `query-key-separators`, `query-key-separators-and-space`, `query-already-encoded`, REQUEST-01 v1). #54's v2 adds a GBK form control and declared-body charset rows; their frozen device run is **blocked/not-run**. The request option only selects form/query percent-encoding; a declared raw body's media type selects its byte encoding |
| Query re-encoding (nothing else) | `NetworkUtils.encodedQuery`, `AnalyzeUrl.kt:265-278` | 🟡 device-pinned by REQUEST-01 with one platform seam: the frozen client sends `q={a}\|b^c` backtick `\d%27e%20f%20%E4%B9%A6&p=1` and the product `q=%7Ba%7D%7Cb%5Ec%60%5Cd%27e%20f%20%E4%B9%A6&p=1`, because Dart's `Uri` percent-encodes `{`, `}`, `\|`, `^`, the backtick and the backslash while the frozen `HttpUrl.encodedQuery` keeps them raw. The frozen encoder's own escapes — `%27` for `'`, `%20` for a space, upper-case UTF-8 bytes — reproduce exactly, and the already-encoded short-circuit leaves such a query alone (`query-key-separators`). The seam is a recorded divergence in the differential contract (`query-exact-bytes` is reported `notCompared`) |
| `{{key}}` substitution | `AnalyzeUrl.kt:184-200` | ✅ raw substitution as a JavaScript binding; escaping happens once in the query or body encoder. Device-pinned by REQUEST-01 (`query-key-raw`, `query-exact-bytes`): the rewritten separator row shows a keyword whose text is itself a legal query is passed through untouched |
| `{{page}}` substitution, page lists (`<1,2,3>`) and multi-page search | same | 🟡 device-pinned by REQUEST-01 (`page-list-hit`, `page-list-past-end`, `pageless-empty-bindings`, `pageless-page-list-literal`): the requested entry is substituted, a page past the end repeats the last one, a page-less stage binds `{{page}}`/`{{key}}` empty, and a list on a page-less stage stays literal text that the query encoder escapes. The reader UI still requests page 1 only |
| Default request headers (`User-Agent`, `Keep-Alive`, `Connection`, `Cache-Control`) | `HttpHelper.kt:72-82` | 🟡 device-pinned by REQUEST-01: the frozen default user agent (`AppConfig.kt:544-549`, Chrome/128.0.0.0) and the appended `Keep-Alive: 300`, `Connection: Keep-Alive`, `Cache-Control: no-cache` reach the wire, and a source that declares each keeps its slot with the injected value appended (`600, 300`; `max-age=0, no-cache`; `Keep-Alive, Keep-Alive`) — both rows compare byte for byte. A source that declares `User-Agent: null` does not: the frozen client then sends its platform default `okhttp/4.12.0` while the product keeps Dart's, a recorded divergence, so the row is not ✅ |
| Request body media type and framing | okhttp-4.12.0 `RequestBody$Companion.create(String, MediaType)`, `AnalyzeUrl.kt:435-446`, `OkHttpUtils.kt:139-142` at the frozen commit | 🟡 REQUEST-01 v1 device evidence (`redirect-300-post` … `redirect-308-post`) pins the default `; charset=utf-8` and `Content-Length` framing. #54 now encodes body bytes through `SourceEncoding.encode` with the declared media type's charset; Windows wire tests pin GBK `书` as `CA E9` (UTF-8 `E4 B9 A6`), header precedence, the default and form branches, and preservation across 307/308. REQUEST-01 v2's three new rows remain **blocked/not-run** on the unavailable handset; the unchanged v1 golden/manifest are historical evidence and the comparator rejects the v2 identity. No charset compatibility promotion. Unknown labels propagate a named error (controller-approved divergence); UTF-16 output, other legacy labels and unrepresentable characters remain outside the new device coverage. See the contract's pending #54 evidence paragraph |
| Redirect semantics (300/301/302/303 → GET without body; 307/308 keep method and body; 20 follow-ups) | OkHttp 4.12 `RetryAndFollowUpInterceptor` | 🟡 device-pinned by REQUEST-01: the six POST rows show the method rewrite with the content headers dropped, 307/308 keeping method, body and content type, the 21st follow-up failing after 21 requests (`java.net.ProtocolException: Too many follow-up requests: 21` on the device, `SourceRedirectLimitExceeded` here) and the cross-origin `Authorization` drop with `X-Source` kept — every one compares. A declared `Cookie` is *not* forwarded to another origin here, a deliberate divergence: the frozen client forwards it, so that row is reported `notCompared` and the row is not ✅ |
| Non-2xx retry from the `retry` option | `OkHttpUtils.kt:29-43` | ✅ |
| Connection retry, 60 s read/call budgets | `HttpHelper.kt:56-62` | 🟡 30 s request budget, no separate connection-retry parity |
| Per-source concurrency limit (`ConcurrentRateLimiter`, `concurrentRate`) | `AnalyzeUrl.kt:479`, `JsExtensions.kt:371` | ✅ the frozen source-keyed record, both rate forms and the wait-until-admitted loop around every source request; a declared batch keeps its input order. The product's page pagination is still issued sequentially, so the frozen multi-URL `nextTocUrl` branch's concurrent shape has no fixture |
| Cookie priority and persistence (`setCookie`, `enabledCookieJar`) | `AnalyzeUrl.kt:597-615` | ✅ the URL option's `Cookie`, then the stored jar, merged into the outbound header before the request, and a response only writes the jar when the source declares `enabledCookieJar`; storage stays per space and scoped to a source's own site group (ADR 0011 §3, #21) |
| TLS policy | `HttpHelper.kt:63-65` (unsafe trust) | 🟡 validation is the default and a certificate or hostname failure is a named outcome carrying the source and the host; the user is asked once per source and host (a browser's "continue (unsafe)"), and the exception the confirmation stores is what the transport reads afterwards (ADR 0011 §5, #30). The baseline's unconditional trust for every source stays rejected; the divergence is recorded in the differential contract |
| Host reachability | any host the source names | 🟡 any `http`/`https` host, with no private-address filter — a LAN or self-hosted source is a real use, and the filter would remove a capability without removing the leak (ADR 0011 §5) |
| WebView request path | `BackstageWebView`, `webView*` options | ❌ allowed by policy, not wired yet: executed headlessly through #2's adapter when it lands (ADR 0011 §4) |

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
| Download (`downloadUrls`, file sources) | `BookInfo.kt` | ❌ deferred with the file family (ADR 0011 §2), #14 |
| Auto source switching, precise search | `WebBook.kt:358` | ❌ |

### F. Declared non-goals

TTS/reading aloud, image and audio Book Sources, review UI, cloud synchronization, pixel-level UI reproduction, bundled browser engine, required backend. These stay out of the current compatibility path and are **deferred beyond the first slice rather than refused** (ADR 0011 §7), as are the map's bookmarks, reading history, search history and Book Source subscriptions: each arrives as its own slice with its own evidence, instead of appearing here as a gap the boundary is hiding.

## What the sample does not exercise

`@CSS:`-mode rules (the sample's 0/5 means the only CSS-mode evidence in this repository is `book_sources/shudugu.json`), `@XPath:`, `@Json:` element rules, `&&`/`%%` merges, `$1` captures, `@get:`/inline put parameters, `cache` binding, `replaceFirst`, `ownText`, filters in JSONPath, explore, reviews, source variables, remote `jsLib`, table-of-contents formatting, volume/VIP markers, cover decoding, `sourceRegex`, image handling, downloads, and non-text source types. Those rows must be re-checked against the frozen source rather than assumed from this sample.

## Proposed slice order

Ordered by blocking impact on running real sources, then by sample frequency. Each slice is independently verifiable and should keep its own evidence.

1. ~~**Request defaults and redirect semantics.**~~ *Implemented (issue #9, 2026-09-15): the rows above are closed except the platform encoding seam and the reader's page-1-only UI.* Default `User-Agent`/connection headers, OkHttp-style 301/302/303 → GET without body and 307/308 preserving method and body, `{{page}}` substitution, and keyword substitution matching the frozen rule. Blocks every source whose search depends on a browser-like request or a redirected POST result page. *Device-pinned by #15 (REQUEST-01, `tool/nested_oracle/evidence/android-17-os4.0.0.31/`): 17 of 20 rows compare byte for byte and 3 are recorded divergences; the comparison also forced two product fixes (the body media type's `; charset=utf-8` and the body's `Content-Length`).*
2. ~~**JavaScript host surface.**~~ *Implemented (issue #10, 2026-09-15): `cookie.*`, `java.get`/`put`, `java.toast`/`longToast`/`log`/`logType`, `cache.*`, the `source.*` accessors, and the encoding family except `t2s`/`s2t` and `androidId`; `t2s`/`s2t` followed in issue #19 (ADR 0010), measured rather than assumed equal; the file and WebView members are deferred to the untrusted-source boundary and the WebView lane. Both sample sources that previously failed before any request now reach the network.* The slice covered `cookie.*`, `java.get`/`put`, `java.toast`/`log`, `cache.*`, the common utility family (`base64*`, `hex*`, `encodeURI`, `t2s`), and the `source.*` accessors.
3. ~~**Rule-level JavaScript and templates.**~~ *Implemented (issue #11, 2026-09-18): `@js:`/`<js>`/`{{js}}` inside rule fields, `@get:`/`@put:`, `{{baseUrl}}`/`{{title}}` and the `###` replaceFirst field run through one rule-field path in front of both adapters, and the JSON adapter's silent ` @js:` truncation is gone. The four `path: rule` corpus rows #11 added are now device observations in the #51 golden (their `@js:`/`<js>`/`{{baseUrl}}`/`{{title}}` values match the adapter).* `@js:`/`<js>`/`{{js}}` inside rule fields, `@get:`, inline put parameters, `{{baseUrl}}`/`{{book.*}}`/`{{title}}`, and `###` replaceFirst. Also removes the JSON adapter's silent ` @js:` truncation.
4. ~~**Extraction and selector family.**~~ *Implemented (issue #12, 2026-09-15): extraction by attribute name, `html`/`ownText`/`all`, `&&`/`||`/`%%`, `class.`/`tag.`/`text.`, the index list form and the Jsoup CSS extensions now run through the Rust adapter (`packages/fjs/liber_html`), behind one whole-document bridge call per stage. The corpus rows in `tool/html_oracle/fixtures.json` are checked in CI against values read from the frozen source (the 35 #12 rows plus four rule-level rows added by #11); the frozen-device golden now exists (`tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json`) and covers all 39 rows (the 35 #12 rows plus the four #11 rule-level rows); every row matches the adapter after #51 fixed the `##` split and corrected the `replacement-trailing-field` expectation.*
5. **Pipeline features.** Login, explore, source variables, remote `jsLib`, table-of-contents formatting, volume/VIP markers, cover decoding.
6. **Peripheral.** Multi-URL page results, `sourceRegex`, downloads, reviews, image/audio sources, reading aloud.

## Open questions

- Which JSONPath subset the frozen `AnalyzeByJSonPath` actually accepts for the corpus, and how much of it must be emulated rather than approximated.
- ~~How the ticket 12 adapter should reproduce Jsoup-specific CSS and XPath behavior without vendoring Jsoup semantics.~~ *Answered for HTML/CSS by #12: the adapter is a Rust port of jsoup 1.16.2's selector engine and Legado's rule layer (ADR 0008). The XPath row is still open and needs its own decision.*
- Whether the login flow is needed for the Windows target or stays deferred with the security boundary (ticket 05).
- ~~What the per-source concurrency limit should be, since the frozen contract compares concurrent batches and the product currently issues one request at a time.~~ *Answered by #42: `concurrentRate` is applied per source request with the frozen limiter's two forms, and a declared batch preserves input order. The product's pagination is still sequential, so the frozen `nextTocUrl` multi-URL concurrent branch remains unexercised.*
- Whether `{{key}}` encoding parity is a compatibility requirement or an accepted divergence; the frozen rule changes the wire bytes for non-ASCII keywords.

## Provenance and re-verification

- Frozen evidence: local snapshot at `14dd24945b2914ce2708b8abaa4ee67ceef892af`; line references above are from that revision.
- Product evidence: `master` at the survey date; statuses must be re-derived after the slices in [Proposed slice order](#proposed-slice-order) land.
- Runtime observation: `tool/source_triage.dart`; re-running it needs the private export file, which stays outside the repository.
- Re-verification rule: this matrix is a planning index, not a compatibility result. Any promoted status needs a per-capability test or gate row, and a frozen-oracle row remains `not-run` until the differential corpus covers it (the #23/#51 extraction corpus, #38's four-stage corpus and #15's request-semantics corpus now have device rows; the WebView corpus does not).
