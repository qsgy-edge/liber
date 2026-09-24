import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'book_source_webview_adapter.dart';

/// The cookies the platform's cookie store holds for [pageUrl], joined the way
/// the frozen `CookieStore.setCookie` receives them.
///
/// Both the headless adapter's page-finished write and the visible confirmed
/// page's use it: one spelling for what a finished page contributes to the
/// source's own jar.
Future<String> inAppWebViewPageCookies(String pageUrl) async {
  final cookies = await CookieManager.instance().getCookies(
    url: WebUri(pageUrl),
  );
  return cookies
      .map((cookie) => '${cookie.name}=${cookie.value}')
      .join('; ');
}

/// Installs the native adapter as the model layer's WebView binding.
///
/// Called once by the application entry point (`lib/main.dart`) and by the
/// WebView evidence harness; every other process reaches the WebView path
/// without an engine and refuses it by name
/// ([SourceWebViewUnavailable]).
void installInAppWebViewBookSourceAdapter() {
  BookSourceWebViewAdapterFactory.engineBinding =
      InAppWebViewBookSourceAdapter.new;
}

/// The headers one WebView load carries.
///
/// Android's WebView silently ignores a `Cookie` entry in a load's additional
/// headers, so the frozen baseline never sends an app-supplied cookie on the
/// first request even though it passes the header map straight through; only
/// cookies the page itself sets appear later. The Windows engine honours the
/// entry instead, so passing it through there would make the destination send a
/// cookie the contract says is not sent. The visible confirmed page applies the
/// same rule, because it is the same load.
Map<String, String> inAppWebViewLoadHeaders(Map<String, String> headers) {
  final load = <String, String>{};
  for (final entry in headers.entries) {
    if (entry.key.toLowerCase() == 'cookie') continue;
    load[entry.key] = entry.value;
  }
  return load;
}

/// The platform-native adapter: `flutter_inappwebview`'s engine driven to the
/// frozen `BackstageWebView` contract rather than to that plugin's defaults.
///
/// The plugin differs from the baseline engine in ways the observable contract
/// covers, and each difference is bridged here rather than papered over: the
/// Windows engine reports no redirect flag, cannot carry a base URL through
/// `loadData`, has no `onLoadResource`, reports a main-frame HTTP error without a
/// load-stop event, and blocks on the navigation-decision callback; Android
/// flushes native session cookies to disk where the baseline never does. See
/// `docs/adr/0003-use-native-webviews-through-thin-adapters.md`.
class InAppWebViewBookSourceAdapter implements BookSourceWebViewAdapter {
  InAppWebViewBookSourceAdapter(this._scope);

  static const String defaultJs = 'document.documentElement.outerHTML';
  static const String _userAgentHeaderName = 'User-Agent';

  final BookSourceWebViewAdapterFactory _scope;

  HeadlessInAppWebView? _webView;
  Completer<SourceWebViewResponse>? _completer;
  Timer? _evalTimer;
  int _retry = 0;
  bool _redirected = false;
  bool _disposed = false;
  String? _pendingBaseUrlDocument;

  /// The request this operation is running, which the page-finished and
  /// evaluate callbacks need for the script, the delay and the base URL.
  SourceWebViewRequest? _request;

  @override
  bool get isDisposed => _disposed;

  @override
  bool get hasWebView => _webView != null;

  /// The frozen `HtmlWebViewClient.onPageFinished` also stores the native
  /// cookies for the page under the source's key; the adapter hands them to the
  /// scope's sink, which is the source's jar.
  Future<void> _storePageCookies(String pageUrl) async {
    final sink = _scope.onPageCookies;
    if (sink == null || pageUrl.isEmpty) return;
    await sink(pageUrl, await inAppWebViewPageCookies(pageUrl));
  }

  Map<String, String> _webViewHeaders(SourceWebViewRequest request) =>
      inAppWebViewLoadHeaders(request.headers);

  String _configuredUserAgent(SourceWebViewRequest request) {
    for (final entry in request.headers.entries) {
      if (entry.key.toLowerCase() == _userAgentHeaderName.toLowerCase()) {
        return entry.value;
      }
    }
    return _scope.userAgent;
  }

  String _javaScript(SourceWebViewRequest request) {
    final configured = request.javaScript;
    if (configured != null && configured.isNotEmpty) return configured;
    return defaultJs;
  }

  bool _isSniffer(SourceWebViewRequest request) =>
      (request.sourceRegex != null && request.sourceRegex!.trim().isNotEmpty) ||
      (request.overrideUrlRegex != null &&
          request.overrideUrlRegex!.trim().isNotEmpty);

  /// Whether URL-matching decisions run in the resource-interception hook.
  ///
  /// Windows has no `onLoadResource`, and it issues a navigation's request
  /// before asking for the navigation decision, so both the resource sniffer and
  /// the override matcher run at interception there.
  bool get _decidesAtInterception => Platform.isWindows;

  /// Inline HTML with a base URL has to be served through the interception hook
  /// on Windows, because that platform's `loadData` cannot carry a base URL.
  bool _needsInterceptedBaseUrl(SourceWebViewRequest request) =>
      Platform.isWindows &&
      request.html != null &&
      request.html!.isNotEmpty &&
      request.url != null &&
      request.url!.isNotEmpty;

  /// Whether the platform reports a main-frame HTTP error status instead of a
  /// load-stop event. Android delivers both; the Windows engine delivers only the
  /// error, so the adapter has to treat it as completion to reach the same
  /// observable outcome.
  bool get _treatsHttpErrorAsCompletion => Platform.isWindows;

  /// Whether this platform reports a redirect flag on a navigation action.
  /// Android does; the Windows implementation does not populate it.
  bool get _reportsRedirectFlag => !Platform.isWindows;

  /// Whether the platform both persists native session cookies and offers the
  /// operation that drops them.
  ///
  /// Android's plugin flushes the native cookie store when a page finishes
  /// (`InAppWebViewClient.java:235`), which writes session cookies to the WebView
  /// cookie database and makes them survive a process restart. The frozen
  /// baseline never flushes, so its session cookies live only in memory and are
  /// gone after a restart. Dropping them once per process restores that semantics
  /// while leaving genuinely persistent cookies intact. The Windows
  /// implementation has no `removeSessionCookies`, so no correction is applied
  /// there.
  bool get _canResetNativeSessionCookies => !Platform.isWindows;

  /// Process-wide, not per adapter instance: the frozen semantics this restores
  /// are "the session cookies live as long as the process does", so the native
  /// store is cleaned once when the process first needs a WebView. A per-instance
  /// latch also ran before a second operation in the same process, which deleted
  /// the cookies a live page had just set — the next request must still send them,
  /// and the source's durable jar must keep them (WV-07).
  static Future<void>? _processSessionCookieReset;

  Future<void> _dropNativeSessionCookiesOnce() {
    if (!_canResetNativeSessionCookies) return Future<void>.value();
    return _processSessionCookieReset ??= CookieManager.instance()
        .removeSessionCookies()
        .then((_) {});
  }

  @override
  Future<SourceWebViewResponse> load(SourceWebViewRequest request) {
    _request = request;
    final completer = Completer<SourceWebViewResponse>();
    _completer = completer;
    unawaited(_load(request));
    return completer.future.timeout(
      const Duration(seconds: 60),
      onTimeout: () {
        destroy();
        throw const SourceWebViewTimeout();
      },
    );
  }

  @override
  void destroy() {
    _evalTimer?.cancel();
    _evalTimer = null;
    final webView = _webView;
    _webView = null;
    _disposed = true;
    _fail(const SourceWebViewCancelled());
    if (webView != null) unawaited(webView.dispose());
  }

  Future<void> _load(SourceWebViewRequest request) async {
    if (_disposed) return;
    await _dropNativeSessionCookiesOnce();
    if (_disposed) return;
    final sniffer = _isSniffer(request);
    final settings = InAppWebViewSettings(
      javaScriptEnabled: true,
      domStorageEnabled: true,
      blockNetworkImage: true,
      userAgent: _configuredUserAgent(request),
      mixedContentMode: MixedContentMode.MIXED_CONTENT_ALWAYS_ALLOW,
      useShouldOverrideUrlLoading: true,
      // `onLoadResource` is not wired on Windows, so the resource sniffer is fed
      // by `shouldInterceptRequest` there. Both fire once per resource URL; the
      // interception hook fires before the request is issued instead of after it
      // starts, which the frozen contract already treats as a race.
      useOnLoadResource: sniffer && !_decidesAtInterception,
      useShouldInterceptRequest:
          (sniffer && _decidesAtInterception) ||
          _needsInterceptedBaseUrl(request),
      clearCache: false,
    );
    final webView = HeadlessInAppWebView(
      initialSettings: settings,
      onLoadStop: (controller, pageUrl) => _onPageFinished(controller, pageUrl),
      shouldOverrideUrlLoading: (controller, action) =>
          _shouldOverrideUrlLoading(request, controller, action),
      onLoadResource: sniffer && !_decidesAtInterception
          ? (controller, resource) =>
                _onLoadResource(request, resource.url?.toString())
          : null,
      shouldInterceptRequest:
          (sniffer && _decidesAtInterception) ||
              _needsInterceptedBaseUrl(request)
          ? (controller, webRequest) =>
                _shouldInterceptRequest(request, webRequest)
          : null,
      // The frozen baseline proceeds through an untrusted certificate, which the
      // security policy forbids. The adapter cancels instead and fails the
      // operation with the transport's own certificate failure, so a source sees
      // a named refusal rather than the blank page the cancelled navigation
      // would otherwise deliver, and the caller's ADR 0011 §5 confirmation asks
      // about it. The per-source, per-host exception the user confirmed is the
      // one way past it: the retry finds it stored and proceeds.
      onReceivedServerTrustAuthRequest: (controller, challenge) async {
        final host = challenge.protectionSpace.host;
        if (_scope.allowsInvalidCertificate(host)) {
          return ServerTrustAuthResponse(
            action: ServerTrustAuthResponseAction.PROCEED,
          );
        }
        _fail(
          sourceWebViewUntrustedCertificateFailure(
            sourceRef: _scope.sourceRef,
            host: host,
          ),
        );
        destroy();
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.CANCEL,
        );
      },
      // No `onReceivedError` or `onReceivedHttpError` handling beyond this: the
      // frozen `HtmlWebViewClient` overrides neither, so a main-frame network or
      // status error still reaches page completion and is parsed as an ordinary
      // response there.
      //
      // The Windows engine reports a main-frame HTTP error status as a failed
      // navigation and fires no load-stop event at all, even though the document
      // is committed and its body is rendered. The frozen baseline reaches page
      // completion in that case, so the adapter treats a main-frame HTTP error as
      // page completion there. A navigation that genuinely failed has no document
      // to read, and the frozen baseline lets that operation run into its own
      // timeout.
      onReceivedHttpError: (controller, request2, response) {
        if (!_treatsHttpErrorAsCompletion) return;
        if (request2.isForMainFrame == false) return;
        unawaited(_onPageFinished(controller, request2.url));
      },
    );
    _webView = webView;
    try {
      await webView.run();
      if (_disposed) return;
      final controller = webView.webViewController!;
      final page = request.html;
      if (page != null && page.isNotEmpty) {
        final base = request.url;
        if (base == null || base.isEmpty) {
          await controller.loadData(
            data: page,
            mimeType: 'text/html',
            encoding: request.encoding,
          );
        } else if (_needsInterceptedBaseUrl(request)) {
          // The Windows implementation's `loadData` calls WebView2's
          // `NavigateToString`, which has no base-URL parameter and therefore
          // drops the base URL entirely: the document commits as `about:blank`,
          // so relative resources cannot resolve and the page URL is unusable.
          // The adapter instead navigates to the base URL and serves the already
          // fetched HTML from the resource-interception hook, which commits the
          // document at that URL without issuing a request for it.
          _pendingBaseUrlDocument = page;
          await controller.loadUrl(
            urlRequest: URLRequest(
              url: WebUri(base),
              headers: _webViewHeaders(request),
            ),
          );
        } else {
          await controller.loadData(
            data: page,
            mimeType: 'text/html',
            encoding: request.encoding,
            baseUrl: WebUri(base),
            historyUrl: WebUri(base),
          );
        }
      } else {
        await controller.loadUrl(
          urlRequest: URLRequest(
            url: WebUri(request.url!),
            headers: _webViewHeaders(request),
          ),
        );
      }
    } catch (error) {
      // The frozen baseline leaves its WebView behind when setup fails; an
      // internal resource leak is a fixable defect rather than source-visible
      // behavior, so the adapter cleans up instead of reproducing it.
      _fail(error);
      destroy();
    }
  }

  bool _matchesOverrideUrl(SourceWebViewRequest request, String candidate) {
    final override = request.overrideUrlRegex;
    if (override == null || override.isEmpty) return false;
    return RegExp(override).hasMatch(candidate);
  }

  Future<NavigationActionPolicy?> _shouldOverrideUrlLoading(
    SourceWebViewRequest request,
    InAppWebViewController controller,
    NavigationAction action,
  ) async {
    final target = action.request.url?.toString();
    if (target != null && !_decidesAtInterception) {
      if (_matchesOverrideUrl(request, target)) {
        _succeed(SourceWebViewResponse.page(request.url!, target));
        _destroyAfterCallback();
        return NavigationActionPolicy.CANCEL;
      }
    }
    _redirected =
        _redirected || action.isRedirect == true || await _looksRedirected(controller, target);
    return NavigationActionPolicy.ALLOW;
  }

  /// The frozen baseline's own fallback for a platform that does not report a
  /// redirect flag: a navigation whose URL differs from the document currently
  /// loaded is a redirect (`BackstageWebView.kt:157-160`). The Windows engine
  /// reports no redirect flag to this callback, and unlike Android it also
  /// invokes the callback for the initial programmatic load, so the comparison
  /// only applies once a real page is loaded.
  Future<bool> _looksRedirected(
    InAppWebViewController controller,
    String? target,
  ) async {
    if (target == null || _reportsRedirectFlag) return false;
    final current = (await controller.getUrl())?.toString();
    if (current == null) return false;
    if (!current.startsWith('http://') && !current.startsWith('https://')) {
      return false;
    }
    return current != target;
  }

  /// Destroys the WebView without doing it inside a native callback the engine
  /// is still waiting on.
  ///
  /// The frozen baseline destroys inside `shouldOverrideUrlLoading` and returns
  /// afterwards, which is safe on Android because destruction is posted to the
  /// main handler. The Windows engine blocks on this callback's reply, so
  /// disposing before returning deadlocks the navigation and the operation never
  /// completes. Deferring by one event-loop turn keeps the observable outcome
  /// (navigation cancelled, WebView destroyed) and only moves work that is not
  /// source-visible.
  void _destroyAfterCallback() {
    if (!Platform.isWindows) {
      destroy();
      return;
    }
    // The adapter's own state must reflect the destruction immediately, because a
    // caller checks it as soon as the operation completes; only the native
    // dispose is deferred.
    _evalTimer?.cancel();
    _evalTimer = null;
    final webView = _webView;
    _webView = null;
    _disposed = true;
    if (webView == null) return;
    Future<void>.delayed(Duration.zero, webView.dispose);
  }

  Future<WebResourceResponse?> _shouldInterceptRequest(
    SourceWebViewRequest request,
    WebResourceRequest webRequest,
  ) async {
    final requestUrl = webRequest.url.toString();
    _matchSniffedResource(request, requestUrl);
    // On Windows the engine issues a navigation's resource request before it
    // asks for the navigation decision, and cancelling the navigation after that
    // request has started wedges the engine. The override match therefore runs
    // here, where returning a response keeps the forbidden URL from reaching the
    // network at all, which is what the frozen contract requires.
    if (_decidesAtInterception && _matchesOverrideUrl(request, requestUrl)) {
      _succeed(SourceWebViewResponse.page(request.url!, requestUrl));
      _destroyAfterCallback();
      return WebResourceResponse(
        contentType: 'text/plain',
        data: Uint8List(0),
        statusCode: 204,
        reasonPhrase: 'No Content',
      );
    }
    final document = _pendingBaseUrlDocument;
    if (document != null && requestUrl == request.url) {
      _pendingBaseUrlDocument = null;
      return WebResourceResponse(
        contentType: 'text/html',
        contentEncoding: request.encoding,
        data: Uint8List.fromList(utf8.encode(document)),
        statusCode: 200,
        reasonPhrase: 'OK',
      );
    }
    // Returning null leaves the request to the engine, so the destroy a sniffer
    // match triggers races the request exactly as it does on a platform that
    // reports the resource after the load starts.
    return null;
  }

  void _matchSniffedResource(SourceWebViewRequest request, String resourceUrl) {
    final source = request.sourceRegex;
    if (source == null || source.isEmpty) return;
    if (RegExp(source).hasMatch(resourceUrl)) {
      _succeed(SourceWebViewResponse.page(request.url!, resourceUrl));
      _destroyAfterCallback();
    }
  }

  Future<void> _onLoadResource(
    SourceWebViewRequest request,
    String? resourceUrl,
  ) async {
    if (resourceUrl == null) return;
    _matchSniffedResource(request, resourceUrl);
  }

  Future<void> _onPageFinished(
    InAppWebViewController controller,
    WebUri? pageUri,
  ) async {
    if (_disposed) return;
    final pageUrl = pageUri?.toString() ?? '';
    unawaited(_storePageCookies(pageUrl));
    final request = _request;
    if (request == null) return;
    if (_isSniffer(request)) {
      final script = request.javaScript;
      if (script != null && script.isNotEmpty) {
        _evalTimer?.cancel();
        _evalTimer = Timer(
          Duration(milliseconds: 1000 + request.delayTime),
          () {
            if (_disposed) return;
            unawaited(controller.evaluateJavascript(source: script));
          },
        );
      }
      return;
    }
    _evalTimer?.cancel();
    _evalTimer = Timer(
      Duration(milliseconds: 1000 + request.delayTime),
      () => _evaluate(controller, pageUrl),
    );
  }

  Future<void> _evaluate(
    InAppWebViewController controller,
    String pageUrl,
  ) async {
    final request = _request;
    if (_disposed || request == null) return;
    Object? result;
    try {
      result = await controller.evaluateJavascript(source: _javaScript(request));
    } catch (error) {
      if (_disposed) return;
      result = null;
    }
    if (_disposed) return;
    if (result != null) {
      final content = result is String ? result : result.toString();
      _succeed(
        _redirected
            ? SourceWebViewResponse.redirected(
                pageUrl: pageUrl,
                originUrl: request.url ?? pageUrl,
                body: content,
              )
            : SourceWebViewResponse.page(pageUrl, content),
      );
      destroy();
      return;
    }
    if (_retry > 30) {
      _fail(const SourceWebViewJsTimeout());
      destroy();
      return;
    }
    _retry++;
    _evalTimer?.cancel();
    _evalTimer = Timer(
      const Duration(milliseconds: 1000),
      () => _evaluate(controller, pageUrl),
    );
  }

  void _succeed(SourceWebViewResponse response) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.complete(response);
    }
  }

  void _fail(Object error) {
    final completer = _completer;
    if (completer != null && !completer.isCompleted) {
      completer.completeError(error);
    }
  }
}
