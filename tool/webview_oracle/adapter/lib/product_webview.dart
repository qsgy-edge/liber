import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/inappwebview_book_source_adapter.dart';

/// The fixtures' call shape over the product's WebView adapter.
///
/// Every engine-observable decision belongs to
/// `package:liber/source/inappwebview_book_source_adapter.dart`, which this
/// harness drives through [BookSourceWebViewAdapterFactory]; this class maps the
/// fixtures' frozen-shape constructor onto that factory's request and response
/// and implements no adapter behaviour of its own.
///
/// The fixtures were written against the frozen baseline's own call shape
/// (`BackstageWebView(url, html, tag, headerMap, javaScript, delayTime,
/// sourceRegex, overrideUrlRegex)` plus `getStrResponse()` and `destroy()`), so
/// keeping that shape keeps the fixture bodies the archived ones instead of a
/// hand-rewritten copy of them.
class FixtureWebView {
  FixtureWebView({
    this.url,
    this.html,
    this.encode,
    this.tag,
    this.headerMap,
    this.javaScript,
    this.delayTime = 0,
    this.userAgent,
    this.sourceRegex,
    this.overrideUrlRegex,
    this.onPageCookies,
  }) {
    installInAppWebViewBookSourceAdapter();
    _adapter = BookSourceWebViewAdapterFactory(
      sourceRef: tag ?? '',
      userAgent: userAgent ?? '',
      onPageCookies: onPageCookies,
    ).create();
  }

  final String? url;
  final String? html;
  final String? encode;

  /// The source key the operation belongs to; the fixtures pass the page URL,
  /// as the frozen `tag: source?.getKey()` slot receives one.
  final String? tag;
  final Map<String, String>? headerMap;
  final String? javaScript;
  final int delayTime;
  final String? userAgent;
  final String? sourceRegex;
  final String? overrideUrlRegex;

  /// Receives the native cookies a finished page left for the page URL.
  final Future<void> Function(String pageUrl, String cookies)? onPageCookies;

  late final BookSourceWebViewAdapter _adapter;

  Future<SourceWebViewResponse> getStrResponse() => _adapter.load(
    SourceWebViewRequest(
      url: url,
      html: html,
      encoding: encode ?? 'utf-8',
      headers: headerMap ?? const {},
      javaScript: javaScript,
      delayTime: delayTime,
      sourceRegex: sourceRegex,
      overrideUrlRegex: overrideUrlRegex,
    ),
  );

  void cancel() => _adapter.destroy();

  void destroy() => _adapter.destroy();

  bool get isDisposed => _adapter.isDisposed;

  bool get hasWebView => _adapter.hasWebView;
}

/// The frozen exception names the fixtures and the comparator use, mapped onto
/// the product's own names. `errorJson` records `runtimeType`, and
/// `tools/compare_to_golden.js` maps that name to a stable category, so these
/// aliases are what makes a destination row comparable to the golden without a
/// second exception vocabulary.
typedef StrResponse = SourceWebViewResponse;
typedef JsTimeoutException = SourceWebViewJsTimeout;
typedef OuterTimeoutException = SourceWebViewTimeout;
typedef CancelledException = SourceWebViewCancelled;
typedef UntrustedCertificateException = SourceTlsCertificateFailure;
