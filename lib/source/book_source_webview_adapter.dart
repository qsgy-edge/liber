import '../domain/contracts.dart';
import 'http_source_transport.dart' show sourceDefaultUserAgent;
import 'source_host_state.dart';
import 'source_url_rules.dart';

/// One rendered-document operation's inputs: what the frozen `BackstageWebView`
/// constructor takes (`BackstageWebView.kt:36-46`), as `AnalyzeUrl` and the
/// `java.webView*` helpers build them.
///
/// An operation with [html] and no [url] is the frozen inline-HTML load; with
/// [html] and a [url] it is the POST-bootstrap load whose [url] is the base URL;
/// with only a [url] it is a direct GET through the engine. [sourceRegex] and
/// [overrideUrlRegex] select the sniffing operation instead of the DOM one.
class SourceWebViewRequest {
  const SourceWebViewRequest({
    this.url,
    this.html,
    this.encoding = 'utf-8',
    this.headers = const {},
    this.javaScript,
    this.delayTime = 0,
    this.sourceRegex,
    this.overrideUrlRegex,
  });

  final String? url;
  final String? html;

  /// The encoding of an inline load, as the frozen `getEncoding()` reads it.
  final String encoding;

  /// The headers the operation's first request carries — the source's own
  /// header map, as `getSource()?.getHeaderMap(true)` produces it. A `Cookie`
  /// entry is dropped: the platform engine ignores one on a load's extra
  /// headers and the frozen baseline therefore never sends an app-supplied
  /// cookie on the first request.
  final Map<String, String> headers;

  /// The page JavaScript, or null for the frozen default
  /// (`document.documentElement.outerHTML`).
  final String? javaScript;

  /// Milliseconds added to the frozen 1000 ms delay before the page script runs.
  final int delayTime;

  /// The resource-sniffer pattern: the first matching resource URL is the
  /// operation's result.
  final String? sourceRegex;

  /// The navigation-override pattern: the first matching navigation URL is the
  /// operation's result and the navigation does not proceed.
  final String? overrideUrlRegex;
}

/// The rendered document's observable outcome: the frozen `StrResponse`.
///
/// The frozen constructor synthesizes `200 OK` and falls back to
/// `http://localhost/` when the page URL is not a valid OkHttp URL
/// (`StrResponse.kt`), and a redirected load is wrapped as a `302` prior
/// response in front of a `200`.
class SourceWebViewResponse {
  SourceWebViewResponse.page(String pageUrl, this.body)
    : url = _validUrlOrPlaceholder(pageUrl),
      code = 200,
      message = 'OK',
      priorCode = null,
      priorUrl = null;

  SourceWebViewResponse.redirected({
    required String pageUrl,
    required String originUrl,
    required this.body,
  }) : url = _validUrlOrPlaceholder(pageUrl),
       code = 200,
       message = 'OK',
       priorCode = 302,
       priorUrl = _validUrlOrPlaceholder(originUrl);

  /// The final page URL, or the frozen `http://localhost/` placeholder when the
  /// platform reported a URL the baseline could not represent.
  final String url;
  final String? body;
  final int code;
  final String message;

  /// The synthetic redirect metadata: `302` when the document was reached
  /// through a redirect, never the real hop chain (`BackstageWebView.kt:222-240`).
  final int? priorCode;
  final String? priorUrl;

  static String _validUrlOrPlaceholder(String candidate) {
    final parsed = Uri.tryParse(candidate);
    if (parsed == null || (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return 'http://localhost/';
    }
    return candidate;
  }
}

/// Raised where the frozen baseline raises
/// `NoStackTraceException("js执行超时")` after its retry budget is spent.
class SourceWebViewJsTimeout implements Exception {
  const SourceWebViewJsTimeout();

  @override
  String toString() => 'js执行超时';
}

/// Raised where the frozen baseline's outer `withTimeout(60000L)` expires.
class SourceWebViewTimeout implements Exception {
  const SourceWebViewTimeout();

  @override
  String toString() => 'BackstageWebView outer timeout';
}

/// Raised when the operation is cancelled, where the frozen baseline's coroutine
/// is cancelled.
class SourceWebViewCancelled implements Exception {
  const SourceWebViewCancelled();

  @override
  String toString() => 'BackstageWebView cancelled';
}

/// The WebView path's certificate failure (ADR 0011 §5).
///
/// The engine's server-trust callback is the only thing that produces it, so it
/// is evidence that the server presented a certificate the adapter rejected; the
/// per-source, per-host exception is the one case where the adapter proceeds
/// through the certificate instead. It is the same failure the `dart:io` path
/// raises — [SourceTlsCertificateFailure] — carrying the host the challenge
/// named and the plain-words reason the engine cannot supply, so one
/// confirmation serves whichever transport failed.
SourceTlsCertificateFailure sourceWebViewUntrustedCertificateFailure({
  required String sourceRef,
  required String host,
}) => SourceTlsCertificateFailure(
  sourceRef: sourceRef,
  host: host,
  reason: SourceTlsCertificateFailure.unspecifiedReason,
);

/// What the headless adapter does with the engine's server-trust challenge for
/// one host (ADR 0011 §5).
///
/// It is the callback's own decision, named here rather than inline in the
/// platform callback so it can be driven without an engine: the callback is only
/// the mapping onto the engine's response actions.
enum SourceWebViewTrustDecision {
  /// A stored per-source, per-host exception lets the page load through the
  /// certificate.
  proceed,

  /// Nothing is stored: the operation fails with the WebView path's certificate
  /// failure and the WebView is destroyed instead of loading the page.
  refuse,
}

/// The headless adapter's decision for the engine's server-trust challenge
/// (ADR 0011 §5).
///
/// [scope] answers with the stored exception for this source and [host]; [fail]
/// and [destroy] are the adapter's own effects (`_fail` and `destroy()`), so the
/// decision reads the real store, reports the real failure and performs the real
/// teardown. The failure [fail] receives is
/// [sourceWebViewUntrustedCertificateFailure] for the host the challenge named —
/// not for the source's own host — because that is the pair the confirmation
/// asks about and the pair the retried operation then finds stored.
SourceWebViewTrustDecision sourceWebViewTrustDecision({
  required BookSourceWebViewAdapterFactory scope,
  required String host,
  required void Function(Object failure) fail,
  required void Function() destroy,
}) {
  if (scope.allowsInvalidCertificate(host)) {
    return SourceWebViewTrustDecision.proceed;
  }
  fail(
    sourceWebViewUntrustedCertificateFailure(
      sourceRef: scope.sourceRef,
      host: host,
    ),
  );
  destroy();
  return SourceWebViewTrustDecision.refuse;
}

/// Raised when the WebView path is reached in a process with no platform engine
/// binding, which is every process that is not the application or the WebView
/// evidence harness: the gates, the tools and the unit tests run without a
/// Flutter engine ([BookSourceWebViewAdapterFactory.engineBinding]).
class SourceWebViewUnavailable implements Exception {
  const SourceWebViewUnavailable();

  @override
  String toString() => 'WebView 适配器未安装：此进程没有平台 WebView 引擎';
}

/// One hidden engine WebView for one source operation (ADR 0003).
///
/// The operation owns its WebView from creation to [destroy]; it is never
/// attached to a view hierarchy and never shown. Independent instances may run
/// concurrently, and [destroy] is idempotent on success, failure, timeout,
/// cancellation and setup errors.
abstract interface class BookSourceWebViewAdapter {
  /// Runs the operation and answers the rendered document, the matched resource
  /// URL or the matched navigation URL, depending on the request.
  Future<SourceWebViewResponse> load(SourceWebViewRequest request);

  /// Destroys the WebView and fails a pending operation with
  /// [SourceWebViewCancelled], as cancelling the frozen baseline's coroutine
  /// does.
  void destroy();

  /// Whether this operation's WebView has been destroyed.
  bool get isDisposed;

  /// Whether an engine WebView is still attached to this operation.
  bool get hasWebView;
}

/// The source-scoped factory the pipelines and the `java.webView*` helpers share
/// (ADR 0003): one adapter per operation, carrying the source's identity, its
/// user agent, its cookie jar's page-cookie sink and its TLS policy.
///
/// The adapter itself reads no store and shows no UI. [onPageCookies] is where
/// the source's `SourceCookieJar` sees the cookies a finished page left in the
/// native store, which is the frozen `BackstageWebView.setCookie` write.
class BookSourceWebViewAdapterFactory {
  BookSourceWebViewAdapterFactory({
    required this.sourceRef,
    this.userAgent = sourceDefaultUserAgent,
    this.hostState,
    this.onPageCookies,
  });

  /// The source this factory speaks for: its `bookSourceUrl`.
  final String sourceRef;

  /// The user agent a request without its own `User-Agent` header uses, the
  /// frozen `AppConfig.userAgent` slot.
  final String userAgent;

  /// The space's host state, which answers the per-source, per-host TLS
  /// exception (ADR 0011 §5). Without one, every certificate is validated.
  final SourceHostState? hostState;

  /// Receives the native cookies a finished page left for [pageUrl].
  final Future<void> Function(String pageUrl, String cookies)? onPageCookies;

  /// Whether a confirmed exception lets this operation continue past [host]'s
  /// invalid certificate.
  bool allowsInvalidCertificate(String host) =>
      host.isNotEmpty &&
      (hostState?.allowsInvalidCertificate(sourceRef, host) ?? false);

  /// The platform adapter constructor, installed once by the composition root
  /// (`installInAppWebViewBookSourceAdapter` from `lib/main.dart` and from the
  /// WebView evidence harness).
  ///
  /// It is a binding rather than an import because the platform package reaches
  /// `dart:ui`, and the gates, the tools and the unit tests compile and run this
  /// model layer with a plain Dart VM. A process that never installs one reaches
  /// [SourceWebViewUnavailable] by name instead of failing as a null
  /// dereference.
  static BookSourceWebViewAdapter Function(BookSourceWebViewAdapterFactory scope)?
  engineBinding;

  /// One adapter, bound to this source's scope.
  BookSourceWebViewAdapter create() {
    final binding = engineBinding;
    if (binding == null) throw const SourceWebViewUnavailable();
    return binding(this);
  }
}

/// The frozen `AnalyzeUrl` WebView path for one stage (`AnalyzeUrl.kt:394-432`):
/// a direct GET through the engine, or — for an explicit POST — the HTTP
/// bootstrap whose returned HTML is loaded with the *response* URL as its base
/// URL, so relative resources and the page URL come from the real response.
///
/// The caller runs this under the source's rate limit (`withSourceRateLimit`),
/// because the frozen `withLimit` encloses the complete `AnalyzeUrl` operation,
/// bootstrap and rendered load alike. The direct `java.webView*` helpers never
/// come through here; they keep the frozen independent concurrency.
Future<({String body, Uri url})> loadSourceWebView({
  required BookSourceWebViewAdapterFactory factory,
  required SourceUrlOptions options,
  required Uri url,
  required String method,
  required Map<String, String> headers,
  required SourceCancellation cancellation,
  required Future<SourceHttpResponse> Function() bootstrap,
}) async {
  var target = url;
  String? document;
  if (method == 'POST') {
    final response = await bootstrap();
    document = response.body;
    target = response.url;
  }
  final adapter = factory.create();
  final unsubscribe = cancellation.listen(adapter.destroy);
  try {
    final response = await adapter.load(
      SourceWebViewRequest(
        url: '$target',
        html: document,
        headers: headers,
        javaScript: options.webJs,
        delayTime: options.webViewDelayTime,
      ),
    );
    final parsed = Uri.tryParse(response.url);
    final finalUrl =
        parsed != null && (parsed.scheme == 'http' || parsed.scheme == 'https')
        ? parsed
        : target;
    return (body: response.body ?? '', url: finalUrl);
  } on SourceWebViewCancelled {
    // The adapter's own cancellation is the frozen coroutine cancellation, seen
    // by the pipeline as its own cancellation token.
    throw const SourceRequestCancelled();
  } finally {
    unsubscribe();
    adapter.destroy();
  }
}

