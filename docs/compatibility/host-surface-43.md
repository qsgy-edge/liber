# Host-surface rows implemented by #43

Introduced on `wayfinder/43` from `master` at `8d4069d`, then integrated and
corrected by the batch-9 controller. See ticket #43's resolution for the integrated
commit and platform results. Source-derived expectations do not promote a frozen-device
comparison or an unexecuted destination platform.
The frozen revision is `14dd24945b2914ce2708b8abaa4ee67ceef892af`.

## Members and shapes

| Member/family | Frozen source | Implemented shape and limit |
|---|---|---|
| `java.ajax(url)` and list argument | `help/JsExtensions.kt:91-105` | String body. A list selects its first URL, rather than fetching every URL. Existing host failure/cancellation propagation is retained; frozen exception-stack strings are not reproduced. |
| `java.ajaxAll(urls)` | `help/JsExtensions.kt:111-121`; `help/http/StrResponse.kt:49-71` | One URL-array argument; an empty array returns an empty array. Ordered response facades expose `body()`, `code()`, `url()`, `headers()` and `raw().request().url()`, as the existing single-response facade does. Non-2xx responses retain status and body. URL expressions use the existing nested bridge evaluator before bounded dispatch. |
| `java.connect(url[, headerString])` | `help/JsExtensions.kt:127-159`; `AnalyzeUrl.kt:123-130` | One/two arguments return the existing response facade. Valid JSON headers replace source headers; null, empty, malformed JSON fall back to source headers. The existing map-valued extension is retained. |
| `java.get` overload | `AnalyzeUrl.kt:371-383`; HTTP helper inherited from `JsExtensions` | One argument reads state; two arguments issue HTTP even if the second is explicitly undefined. |
| `source.getHeaderMap()` / `(false)` | `data/entities/BaseSource.kt:103-130` | A fresh header map, evaluated at the call from static JSON or `@js:`/`<js>` through the same scoped runtime. Missing case-insensitive `User-Agent` gets the product's emulated default. Invalid JSON/script results fall back to the default; number/boolean scalars are strings, null values are preserved. |
| `source.getHeaderMap(true)` | `BaseSource.kt:124-139` | Named deferral to #13. Login headers are not silently dropped or newly implemented. |
| `book` | `AnalyzeUrl.kt:350`; `data/entities/Book.kt:42-70` | Read-only snapshot of actual selected pipeline fields: `name`, `bookUrl`, `author`, `intro`, `coverUrl`, `kind`, `latestChapterTitle`, `wordCount`. Info starts with its supplied hit; TOC/content use the resulting book, including a reader reopened through a fresh pipeline. Search resets context; genuinely absent book stays null. Unknown fields and mutations fail by member name. |
| Chapter fields/variables | `BookChapter.kt:42-84`; `AnalyzeUrl.kt:365-383` | Actual chapter `title` and `url` are read-only. `book.variable`, `book.getVariable`, `book.putVariable` and the corresponding chapter members refuse by name. No mutable public result models or persistence were introduced. |
| `java.get('bookName')` / `java.get('title')` | `AnalyzeUrl.kt:371-379` | All keys retain ADR 0011 §3's source-owned persistent state, including `bookName` and `title`; a bound snapshot must not shadow values written by `java.put`. Actual stage values are exposed through the read-only snapshots and the existing pipeline rule-variable reader. Frozen chapter/book variable routing remains unimplemented. `source.get/put` continue to address the same source state. |
| `java.toNumChapter` | `help/JsExtensions.kt:905-912`; `constant/AppPattern.kt:21`; `utils/StringUtils.kt:29-53,133-218` | Nullable string result, first `第...章` match only, fullwidth normalization, Chinese and financial digits, shorthand such as `一千二` → 1200, invalid input → -1, signed 32-bit overflow. No match returns the original text. |

## Evidence grade and remaining gaps

`test/source_host_surface_test.dart` checks every family above, including actual HTML/JSON
search → details → chapter → search flows, source-state preservation, named refusals,
source header scripts, argument-count overloads and numeral edges. Dispatcher tests
check bounded admission, response order and headers. `tool/host_surface_gate.dart`
adds individually named rows to its existing checks and still disposes the bridge once.

These expected values are **source-derived**. Windows execution tests the destination;
no new frozen JVM/Android golden was executed. The archived WV-12 harness calls frozen
`ajaxAll` and observes ordering, but its WebView/concurrency evidence is not promoted by
this slice. The frozen files inspected locally match the pinned tree after CRLF
normalization. Git-blob SHA256 values (LF bytes) are:

| Frozen file, under `app/src/main/java/io/legado/app/` | SHA256 |
|---|---|
| `help/JsExtensions.kt` | `60ab74cd454ef328f9dc96befe400d998441fd38fafa6e67c02a07b5b6c5896c` |
| `help/http/StrResponse.kt` | `ae1ce2a0119cdf8561dc6ce1b28004d1fa3252cb3d6922aefc12faeccacd8da0` |
| `data/entities/BaseSource.kt` | `e8f781bdde91f6b14c49e6f797138377273343700533b8a59fa4cf828bd9d91e` |
| `data/entities/Book.kt` | `ed2362bfc65272d5583a7afb71ff75afdc0982bae25227ac4fc632df6125e99d` |
| `data/entities/BookChapter.kt` | `34557c7700f0078ebf4d0676e5c311f6155f3292b9e7e07541674bef871c6831` |
| `utils/StringUtils.kt` | `cbff908efad61e25163862e2b5ee90281a381f22afd4f3eea6adfcd48b988676` |

Deliberate limits: the response facade remains the existing subset of `StrResponse`;
header maps are JavaScript maps of header values, not the entire Java collection API.
A batch keeps the dispatcher's existing concurrency default (4), rather than Android's
user-configured thread count. It evaluates the source headers once and resolves URL
expressions before request admission, rather than doing those steps within each frozen
worker. Nested URL options still fail explicitly. No request-layer redesign, deferred
file/archive/font/WebView/verification members, UI, Rust, device operation, comparator,
or #49 content-processing change is included. Null-valued header observation is covered;
sending those values still encounters the existing string-header transport boundary.

The local native DLL was copied with controller approval from the controller checkout;
source and copy SHA256 both equal
`e5bade176f54d786d0225dbcd9c133707335d1caf0b4d661eeae3f122a6a2bf6`.
No Rust build was run. Actual final command results, source hashes, gate row names and
artifact paths are recorded in the single ticket #43 evidence comment and lane handoff.
Windows UI driving and other platform rows are not run in this lane; controller review
and integrated platform reruns are still required before promotion.
