# Where this restore differs from the archived prototype

`README.md` is the archived prototype's own README, byte for byte, and stays as
provenance. It describes `liber-archive`,
`.scratch/flutter-legado-reader/prototypes/ticket_13_native_webview_contract/`
(pre-split history), which is immutable. This file records what the restored
harness does differently, and why. Nothing here changes a fixture, a golden, an
observation or a comparison rule that the contract fixes.

## The adapter under test is the product's

The archived prototype carried its own `adapter/lib/legado_webview.dart`. This
restore removes it (not a fork, not a copy) and drives the product's
`BookSourceWebViewAdapter` through a path dependency on this repository:

- `adapter/pubspec.yaml` declares `liber: path: ../../..`.
- `adapter/lib/product_webview.dart` is the fixtures' call shape over the product
  adapter. It maps the frozen constructor onto
  `SourceWebViewRequest`/`SourceWebViewResponse` and implements no adapter
  behaviour; every engine decision — the Windows interception seam, the base-URL
  `loadData` workaround, the redirect fallback, the main-frame HTTP-error
  completion, the deferred destroy, the Android session-cookie reset — lives in
  `liber/lib/source/inappwebview_book_source_adapter.dart`, and the source scope
  (jar sink, TLS exception, user agent) in
  `liber/lib/source/book_source_webview_adapter.dart`.
- The fixtures call the product types through aliases
  (`StrResponse`, `JsTimeoutException`, `OuterTimeoutException`,
  `CancelledException`, `UntrustedCertificateException`) so the fixture bodies
  stay the archived ones rather than a hand-rewritten copy of them. The alias
  target is the product exception, so `errorJson` records the product name.
- `tools/write_destination_manifest.js` therefore hashes the two product adapter
  files into `adapterSourceSha256` (under `liber:` keys) and refuses a manifest
  when either was edited after the sweep, exactly as it already did for the
  harness's own `adapter/lib/*.dart`.

## Comparison rules this restore extends

`tools/compare_to_golden.js` maps an exception type name to a stable category.
The product adapter's names are its own, so six mappings were added
(`SourceWebViewJsTimeout`, `SourceWebViewTimeout`, `SourceWebViewCancelled`,
`SourceWebViewUnavailable`, and the two names of the certificate failure,
`SourceWebViewUntrustedCertificate` for the rows collected before #75 and
`SourceTlsCertificateFailure` for the rows after it) onto the same
categories their prototype counterparts map to. No category, no comparison rule,
and no tolerance was widened: an unmapped type is still reported as
`unknown:<type>` and still fails the row.

## The build no longer uses a short-path copy

The archived Windows sweep copied the adapter to `D:/t13` because the committed
prototype path plus the CMake plugin symlink path exceeded `MAX_PATH`. The
restored path (`tool/webview_oracle/adapter`) is short enough that MSVC builds it
in place, so `tools/sync_windows_build_copy.sh` is replaced by
`tools/build_windows_harness.sh`, which hashes the sources the binary is built
from and then builds it once. The sweep still samples the executable's hash
around every fixture and still requires all samples to be equal.

## Dependencies

`device_info_plus` moved from `^12.1.0` to `^13.2.0`: the product's own
dependency tree pins `win32 ^6.3.0`, which `device_info_plus` 12 cannot accept,
so the path dependency does not resolve otherwise. The harness reads only
`androidInfo`/`windowsInfo` from it.

## The harness is its own package, outside the root analysis

`adapter/` is a standalone Flutter package (`ticket13_adapter`) with its own
`pubspec.yaml` and lockfile, and the root package does not depend on it. Its
dependency context therefore comes from `flutter pub get` inside `adapter/`
before a sweep, which a fresh checkout — CI included — does not have, so the
root `analysis_options.yaml` excludes `tool/webview_oracle/adapter/**` the way it
already excludes `packages/fjs/**`. Nothing about the product's analysis changed.
When you change the harness, analyze it in place:

```text
cd tool/webview_oracle/adapter && flutter pub get && flutter analyze
```

The product files the fixtures drive (`lib/source/book_source_webview_adapter.dart`,
`lib/source/inappwebview_book_source_adapter.dart`) stay inside the root
analysis and inside the manifest writer's `adapterSourceSha256` guard.

## Evidence directories

- `evidence/android` and `evidence/android-17` are the frozen goldens, copied
  unchanged; a destination row is still compared against the golden matching its
  own device fingerprint (Android) or against `evidence/android` (every other
  destination).
- `evidence/windows/summary.json` is the archived native WebView2 probe's own
  result, kept as provenance.
- `evidence/windows-destination` holds the Windows rows this restore executed
  through the product adapter; they replace the archived prototype's rows.
- `evidence/android-destination` still holds the archived prototype's Android
  rows. They describe the prototype adapter, not the product one, and are
  superseded: the Android destination rows must be re-run through the product
  adapter on the handset (see the ticket's Android runbook). Until then the
  Android destination and the five-platform aggregate stay `not-run`.
