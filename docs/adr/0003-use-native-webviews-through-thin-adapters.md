# Browser-backed fetching uses each platform's native WebView through a thin adapter

**Status:** accepted (2026-09-15)

Sources that need a rendered document are fetched through each platform's native
WebView (WebView2, Android WebView, WKWebView, WebKitGTK) behind the thinnest
adapter that can reproduce the frozen baseline's observable behavior: hidden
loading, page JavaScript, final DOM and URL, cookie synchronization, redirects,
timeouts, cancellation, concurrency, and cleanup. No browser engine is bundled,
and the application is not a pixel-level clone of the baseline's interface.

## Considered options

- **Bundle a headless engine (for example Chromium).** Rejected: size,
  licensing, and per-platform build cost for behavior the system engine already
  provides.
- **Fetch over HTTP and parse locally.** Rejected: the baseline's
  rendered-document path runs page JavaScript and reacts to navigation and
  cookie changes that a plain GET cannot reproduce.
- **Reimplement the baseline's WebView wrapper classes.** Rejected: only
  observable behavior is in scope, not the wrappers' internals.

## Consequences

Each adapter carries engine-specific seams that are bridged explicitly and
evidenced rather than papered over — for example on Windows: no `isRedirect` on
a navigation action, a dropped `loadData` base URL, no `onLoadResource`, and a
main-frame HTTP error that arrives without a load-stop; and on Android: the
plugin flushes session cookies to disk where the baseline never does. Adapter
evidence is platform-scoped, so a shared adapter change re-runs the affected
rows. The options that drive the WebView path are rejected with an explicit
error until the rendered-document path is wired to sources.

See `docs/compatibility/five-platform-runtime-components.md` and the WebView
rows of `docs/compatibility/book-source-capability-matrix.md`. Provenance:
`liber-archive`, `.scratch/flutter-legado-reader/prototypes/ticket_13_native_webview_contract/`
(Windows row and two Android goldens executed; iOS, macOS, and Linux rows never
run).
