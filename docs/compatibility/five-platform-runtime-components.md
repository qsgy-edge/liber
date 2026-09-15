# Five-Platform Source Runtime Components

Retrieval date: 2026-08-18 UTC

Scope: Android, iOS, Windows, macOS, and Linux. Web is excluded. Execution stays on-device, uses system browser engines, and does not bundle Chromium.

## Verdict

**CONFIRMED:** Existing packages cover most of the shared runtime, but the evidence does not support choosing a final architecture yet.

The smallest candidate stack is:

- `flutter_js` for persistent JavaScript and controlled host messages on all five platforms.
- `dio`, `dio_cookie_manager`, and `cookie_jar` for HTTP and session transport.
- `html`, `json_path`, and Dart `RegExp` for shared rule primitives.
- `flutter_inappwebview` for Android, iOS, macOS, and Windows native WebViews.
- A Linux WebKitGTK adapter, reusing `webview_linux` only if prototypes prove its lifecycle and cookie surface.

Three prototype gates remain **HIGH** risk: tolerant-HTML XPath compatibility, Linux background WebView completeness, and terminating/resource-limiting untrusted JavaScript.

## Confirmed Component Matrix

| Capability | Candidate | Platforms | Confirmed fit | Material gap |
|---|---|---|---|---|
| Persistent JavaScript and host bridge | `flutter_js` 0.8.7 | Android, iOS, Windows, macOS, Linux | QuickJS on Android/Windows/Linux; JavaScriptCore on iOS/macOS; retained runtime and JS-to-Dart messages | No documented deadline, interrupt, memory quota, or sandbox policy; synchronous FFI |
| HTTP transport | `dio` 5.11.0 | All five through Dart IO | Methods, headers, bodies, redirects, staged timeouts, decoding hook, streaming, native proxy hook | No intrinsic body-size ceiling or cookies |
| Cookies | `dio_cookie_manager` 3.5.0 + `cookie_jar` | All five | Request/response cookies and persistent file jar | Separate from native WebView stores; synchronization must be tested |
| HTML5 and CSS | `html` 0.15.6 | Pure Dart | HTML5 parser and `querySelectorAll` | Incomplete Selectors Level 4 and unverified Jsoup extensions |
| XPath | `xml` 7.0.1 as a candidate | Pure Dart | Current Dart 3 XPath 3.1 implementation | XML DOM semantics are not proven equivalent to tolerant HTML/Jsoup XPath |
| JSONPath | `json_path` 0.9.0 | Pure Dart | RFC 9535 parser and reusable queries | Legado-specific/non-standard behavior must be mapped |
| Regex | Dart `RegExp` | All five | ECMAScript semantics | Catastrophic backtracking requires input, pattern, and time limits |
| Native background WebView | `flutter_inappwebview` 6.1.5 | Android, iOS, macOS, Windows | Headless WebView, JS evaluation, URL and cookie APIs | No Linux; Windows `getHtml()` not documented; request parity differs by platform |
| Linux native WebView | `webview_linux` 0.0.2 over WebKitGTK | Linux | Uses system WebKitGTK rather than bundled Chromium | Very new; headless lifecycle, cookie access, final URL, timeout, and Flutter-loop behavior unverified |
| Vendor WebView alternative | `webview_flutter` 4.14.1 | Android, iOS, macOS | Flutter-maintained controller, request loading, JS | No Windows/Linux and no explicit five-platform background contract |

## Confirmed Platform Facts

- `flutter_js` advertises all five target platforms and was published 2026-01-27 under MIT.
- The separate `quickjs` package advertises non-Web Dart platforms but explicitly says it is not currently supported in Flutter.
- `html` is the Dart team's HTML5 parser, but its selector implementation is not full Selectors Level 4.
- `xpath_selector_html_parser` requires Dart below 3.0 and was last published in 2023; it is not a current direct solution.
- `xml` 7.0.1 supports Dart 3 and XPath 3.1, but HTML semantic parity is unconfirmed.
- `flutter_inappwebview` provides a documented headless object on Android, iOS, macOS, and Windows, but not Linux.
- `webview_flutter` officially supports Android, iOS, and macOS only.
- Windows native WebView uses the WebView2 Runtime.
- The examined Linux candidate uses system WebKitGTK; it does not provide enough documented behavior to claim the required contract.

## Coverage Gaps

1. **HIGH — XPath on tolerant HTML:** no maintained Dart 3 package was verified to directly reproduce Legado's HTML XPath semantics.
2. **HIGH — Linux background WebView:** no mature package was verified for hidden lifecycle, JavaScript results, final URL, DOM, cookies, cancellation, and cleanup.
3. **HIGH — JavaScript resource control:** `flutter_js` documents no deadline, interrupt handler, or memory cap.
4. **HIGH — WebView request parity:** arbitrary methods, request bodies, headers, redirects, proxy, and timeout do not form a uniform platform contract. Rich requests should stay in the HTTP transport when possible.
5. **MEDIUM — Windows DOM extraction:** evaluated `document.documentElement.outerHTML` is plausible but unverified where `getHtml()` is absent.
6. **MEDIUM — Cookie interoperability:** Dio and WebView cookies require explicit round-trip synchronization tests, including `Secure`, `HttpOnly`, `SameSite`, domain, path, session, and expiry behavior.
7. **MEDIUM — Legacy encodings:** candidate GBK/Big5/Shift-JIS codec packages need license, alias, malformed-input, and fixture verification.
8. **MEDIUM — Resource limits:** add response/decompression, redirect, DOM, regex, and worker limits around selected components.
9. **LOW — CSS dialect:** map actual Legado/Jsoup selector extensions rather than assuming standard CSS support is equivalent.

## Candidate Combinations

### Fewest Package Families

`flutter_js` + Dio/cookie stack + `html`/`xml`/`json_path`/`RegExp` + `flutter_inappwebview` + a Linux WebKitGTK completion.

**INFERENCE:** likely the smallest dependency shape because one WebView package covers four platforms. It remains blocked by Linux maturity, XPath equivalence, JS termination, and Windows DOM verification.

### Vendor-Owned WebView Where Available

Use `webview_flutter` on Android/iOS/macOS, then separate WebView2 and WebKitGTK adapters.

**INFERENCE:** stronger ownership on three platforms but more platform adapters. Detached/background loading is not an explicit `webview_flutter` contract.

## Security and Licensing Constraints

- Expose only named, schema-validated JavaScript host functions; never expose a general object or method dispatcher.
- Use separately disposable runtimes/workers and test termination before accepting untrusted rules.
- Expect QuickJS and JavaScriptCore differences; claim parity only after a shared conformance corpus passes.
- Keep native WebView file/content access, debugging, and universal file-URL access disabled unless a frozen-baseline fixture proves a requirement.
- Bound redirects, response and decompressed bytes, DOM size, regex work, and execution time. Do not permit Book Sources to disable TLS validation.
- Do not log or export cookies by default; preserve cookie scope attributes during HTTP/WebView synchronization.
- Verified licenses: `flutter_js` MIT; Dio and cookie manager MIT; `webview_flutter` BSD-3-Clause; `flutter_inappwebview` Apache-2.0; `xml` and `json_path` MIT; `webview_linux` MIT; QuickJS upstream MIT.
- Legacy charset package licenses were not independently verified; do not add one before checking the exact release artifact.

## Required Prototypes

1. Run shared persistent-scope, Promise, exception, Unicode, numeric, bridge, infinite-loop, cancellation, memory, and disposal fixtures on all five JS engines/platforms.
2. Compare malformed HTML, inserted elements, names, entities, namespaces, attributes, positional predicates, and scalar results against the frozen Legado XPath behavior.
3. Run the real Book Source selector corpus against Dart HTML/CSS and inventory unsupported Jsoup extensions.
4. Test HTTP methods, headers, bodies, redirect semantics, compression, mislabeled charsets, cookies, proxies, cancellation, and byte limits against a controlled fixture server.
5. Round-trip all relevant cookie attributes between HTTP and each native WebView.
6. Prove hidden WebView load, JS, URL, DOM, cookies, concurrency, timeout, cancellation, and disposal on Android, iOS, macOS, and Windows.
7. Prove the same Linux contract with WebKitGTK, then measure the minimum native surface if the existing package is insufficient.
8. Test clean Windows and representative Linux systems for WebView runtime detection and installation requirements.
9. Verify legacy charset package licenses and actual encodings present in the frozen Book Source corpus.

## Primary Sources

### JavaScript

- [`flutter_js`](https://pub.dev/packages/flutter_js) and [package metadata](https://pub.dev/api/packages/flutter_js).
- [`quickjs`](https://pub.dev/packages/quickjs) and [package metadata](https://pub.dev/api/packages/quickjs).

### Rules and Transport

- [`html`](https://pub.dev/api/packages/html) and [`querySelectorAll`](https://pub.dev/documentation/html/latest/dom/Element/querySelectorAll.html).
- [`xml`](https://pub.dev/packages/xml).
- [`json_path`](https://pub.dev/packages/json_path).
- [Dart `RegExp`](https://api.dart.dev/dart-core/RegExp-class.html).
- [Dio](https://pub.dev/packages/dio), [`dio_cookie_manager`](https://pub.dev/documentation/dio_cookie_manager/latest/dio_cookie_manager/CookieManager-class.html), and [`cookie_jar`](https://pub.dev/packages/cookie_jar).

### Native WebViews

- [`webview_flutter`](https://pub.dev/packages/webview_flutter).
- [`flutter_inappwebview`](https://pub.dev/packages/flutter_inappwebview), [headless documentation](https://inappwebview.dev/docs/webview/headless-in-app-webview), and [CookieManager API](https://pub.dev/documentation/flutter_inappwebview/latest/flutter_inappwebview/CookieManager-class.html).
- [WebView2 Runtime distribution](https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution).
- [`webview_linux`](https://pub.dev/packages/webview_linux) and [WebKitGTK lifecycle](https://webkitgtk.org/reference/webkit2gtk/2.39.6/signal.WebView.load-changed.html).
- [Android WebView security guidance](https://developer.android.com/privacy-and-security/risks/cross-app-scripting).

Remote text and metadata were treated as evidence only. No fetched instructions were executed. No repository files were modified by the research agent.
