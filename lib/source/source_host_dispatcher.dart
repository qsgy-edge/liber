import 'dart:async';
import 'dart:convert';

import '../domain/contracts.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_login.dart';
import 'source_rate_limiter.dart';

/// One request of a batch ([SourceHostDispatcher.ajaxAll]): the shape one
/// batch entry sends, so each URL `java.ajaxAll` is handed carries its own
/// `,{…}` options the way the frozen per-URL `AnalyzeUrl` does
/// (`help/JsExtensions.kt:111-125`).
typedef SourceBatchRequest = ({
  String method,
  String url,
  Map<String, String> headers,
  String? body,
  int retry,
});

class SourceHostDispatcher {
  factory SourceHostDispatcher({
    required SourceHttpTransport transport,
    int maxResponseBytes = 8 * 1024 * 1024,
    int maxRequestBytes = 1024 * 1024,
    SourceCancellation? cancellation,
    SourceHostState? hostState,
    String sourceRef = '',
    String concurrentRate = '',
    bool enabledCookieJar = true,
    SourceRateLimiter? rateLimiter,
  }) {
    final state = hostState ?? SourceHostState();
    return SourceHostDispatcher._(
      transport,
      maxResponseBytes,
      maxRequestBytes,
      cancellation,
      state,
      sourceRef,
      state.cookiesFor(sourceRef),
      concurrentRate,
      enabledCookieJar,
      rateLimiter ?? SourceRateLimiter.shared,
    );
  }

  SourceHostDispatcher._(
    this.transport,
    this.maxResponseBytes,
    this.maxRequestBytes,
    this.cancellation,
    this._hostState,
    this._sourceRef,
    this._cookies,
    this._concurrentRate,
    this._enabledCookieJar,
    this._rateLimiter,
  );

  SourceHostDispatcher._execution(
    SourceHostDispatcher session,
    this.cancellation,
  ) : transport = session.transport,
      maxResponseBytes = session.maxResponseBytes,
      maxRequestBytes = session.maxRequestBytes,
      _hostState = session._hostState,
      _sourceRef = session._sourceRef,
      _cookies = session._cookies,
      _concurrentRate = session._concurrentRate,
      _enabledCookieJar = session._enabledCookieJar,
      _rateLimiter = session._rateLimiter;

  /// Share source state, but never reuse another execution's one-shot token.
  SourceHostDispatcher forExecution(SourceCancellation cancellation) =>
      SourceHostDispatcher._execution(this, cancellation);

  final SourceHttpTransport transport;
  final SourceCancellation? cancellation;
  final int maxResponseBytes;
  final int maxRequestBytes;
  final SourceHostState _hostState;
  final String _sourceRef;
  final SourceCookieJar _cookies;

  /// The source's `concurrentRate`, read by [SourceRateLimiter] before every
  /// request (frozen `AnalyzeUrl.concurrentRateLimiter`).
  final String _concurrentRate;

  /// The source's `enabledCookieJar`. True by default for a caller that speaks
  /// for no source (a gate, a tool); the pipelines pass the source's own flag,
  /// whose frozen default is false.
  final bool _enabledCookieJar;

  /// Where the source-keyed rate records live. Process-global by default, as
  /// the frozen companion object is; a test injects one with a fake clock.
  final SourceRateLimiter _rateLimiter;

  /// The space's host surface this dispatcher speaks for (ADR 0011 §3): the
  /// script runtime reads its cache and variables through the same object.
  SourceHostState get hostState => _hostState;

  /// The source the requests and their cookies belong to.
  String get sourceRef => _sourceRef;

  /// The session jar, seen by this source — shared with a script runtime that
  /// has no transport.
  SourceCookieJar get cookies => _cookies;

  Future<SourceHttpResponse> request(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
    int retry = 0,
  }) {
    if (!{'GET', 'HEAD', 'POST'}.contains(method)) {
      throw ArgumentError.value(method, 'method', 'Unsupported HTTP method');
    }
    return _send(
      method,
      url,
      headers: headers,
      body: body,
      followRedirects: true,
      retry: retry,
    );
  }

  /// Runs one rendered-document operation under this source's `concurrentRate`.
  ///
  /// The frozen `AnalyzeUrl.getStrResponseAwait` wraps its whole body — the HTTP
  /// bootstrap and the WebView load alike — in `concurrentRateLimiter.withLimit`
  /// (`AnalyzeUrl.kt:397-461`), while the direct `java.webView*` helpers never
  /// touch that limiter (`JsExtensions.kt:161-213`). A source with no rate runs
  /// [run] without waiting.
  Future<T> withSourceRateLimit<T>(Future<T> Function() run) async {
    final rate = _rateLimiter.applies(_sourceRef, _concurrentRate)
        ? await _rateLimiter.acquire(
            _sourceRef,
            _concurrentRate,
            cancellation: cancellation,
          )
        : null;
    try {
      return await run();
    } finally {
      _rateLimiter.release(rate);
    }
  }

  Future<String> ajax(String url) async {
    final response = await _send('GET', url, followRedirects: true);
    return response.body;
  }

  Future<SourceHttpResponse> connect(
    String url, {
    Map<String, String> headers = const {},
  }) => _send('GET', url, headers: headers, followRedirects: true);

  Future<SourceHttpResponse> get(
    String url, {
    Map<String, String> headers = const {},
    bool readBytes = false,
  }) => _send('GET', url, headers: headers, readBytes: readBytes);

  Future<SourceHttpResponse> head(
    String url, {
    Map<String, String> headers = const {},
  }) => _send('HEAD', url, headers: headers);

  Future<SourceHttpResponse> post(
    String url,
    String body, {
    Map<String, String> headers = const {},
  }) => _send('POST', url, headers: headers, body: body);

  /// Sends one batch of already-shaped requests, at most [concurrency] at a
  /// time, in the order it was handed to the frozen `ajaxAll`
  /// (`JsExtensions.kt:111-125`): each request keeps its own method, body and
  /// headers, and a batch's responses are returned in input order.
  Future<List<SourceHttpResponse>> ajaxAll(
    Iterable<SourceBatchRequest> requests, {
    int concurrency = 4,
  }) async {
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
    final values = requests.toList(growable: false);
    if (values.isEmpty) return const [];
    final output = List<SourceHttpResponse?>.filled(values.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= values.length) return;
        final request = values[index];
        output[index] = await _send(
          request.method,
          request.url,
          headers: request.headers,
          body: request.body,
          followRedirects: true,
          retry: request.retry,
        );
      }
    }

    await Future.wait(
      List.generate(concurrency.clamp(1, values.length), (_) => worker()),
    );
    return output.cast<SourceHttpResponse>();
  }

  Future<SourceHttpResponse> _send(
    String method,
    String url, {
    Map<String, String> headers = const {},
    String? body,
    bool followRedirects = false,
    int retry = 0,
    bool readBytes = false,
  }) async {
    cancellation?.throwIfCancelled();
    final uri = SourceHttpUri.parse(url);
    // A cookie another run of this source wrote is on disk until it is read
    // back, and the outbound header below reads the in-memory jar. Reading the
    // space's state first is what makes a cookie survive a restart (ADR 0011
    // §3); a state with nothing to load skips the wait, so an in-process run
    // starts its first request synchronously.
    if (!_hostState.isLoaded) await _hostState.ready();
    final allowInvalidCertificate = _hostState.allowsInvalidCertificate(
      _sourceRef,
      uri.host,
    );
    // Frozen `BaseSource.getHeaderMap(hasLoginHeader = true)` (`:103-130`), which
    // every `AnalyzeUrl` reads with the login header on (`AnalyzeUrl.kt:89,124`):
    // the header a source stored through `source.putLoginHeader` is part of its
    // header map, so every request of that source carries it. It goes under the
    // caller's own headers, which is the frozen order against a request's `,{…}`
    // options and against a script's own header map; the one divergence is a key
    // the source's static `header` rule declares too, where the frozen login
    // header would win (recorded in the capability matrix).
    //
    // Read from the loaded state without an `await`: the wait above only happens
    // when there is something to load, so a request whose state is already in
    // memory still starts in the same turn it was asked for.
    final merged = <String, String>{
      ...?loadedSourceLoginHeaderMap(_hostState, _sourceRef),
      ...headers,
    };
    final cookie = _cookieHeader(uri.host);
    if (cookie.isNotEmpty &&
        !merged.keys.any((key) => key.toLowerCase() == 'cookie')) {
      merged['Cookie'] = cookie;
    }
    if (utf8
            .encode(
              jsonEncode({
                'method': method,
                'url': url,
                'headers': merged,
                'body': body,
              }),
            )
            .length >
        maxRequestBytes) {
      throw const SourceIoLimitExceeded('request');
    }
    // Frozen `concurrentRateLimiter.withLimit`: the source's declared rate is
    // read before the request, and a plain-millisecond record is released when
    // the request is finished. A source with no rate keeps its request
    // synchronous, as it was before this seam existed.
    final rate = _rateLimiter.applies(_sourceRef, _concurrentRate)
        ? await _rateLimiter.acquire(
            _sourceRef,
            _concurrentRate,
            cancellation: cancellation,
          )
        : null;
    final SourceHttpResponse response;
    try {
      response = await transport.send(
        SourceHttpRequest(
          method: method,
          url: uri,
          headers: merged,
          body: body,
          followRedirects: followRedirects,
          cancellation: cancellation,
          retry: retry,
          maxResponseBytes: maxResponseBytes,
          sourceRef: _sourceRef,
          allowInvalidCertificate: allowInvalidCertificate,
          readBytes: readBytes,
        ),
      );
      cancellation?.throwIfCancelled();
      // The 8 MiB response cap is measured on what this response actually is. A
      // caller that asked for bytes gets the bytes that arrived (the transport
      // already refuses a longer one at the same number): measuring the JSON
      // escaping of a decoded body cannot carry them back and would reject an
      // image the transport read inside the cap.
      final bytes = response.bodyBytes;
      final oversized = readBytes
          ? (bytes?.length ?? 0) > maxResponseBytes
          : utf8
                    .encode(
                      jsonEncode({
                        'headers': response.headers,
                        'body': response.body,
                        'url': '${response.url}',
                      }),
                    )
                    .length >
                maxResponseBytes;
      if (oversized) {
        throw const SourceIoLimitExceeded('response');
      }
      if (_enabledCookieJar) {
        // Frozen `enabledCookieJar` (AnalyzeUrl.kt:604-615, HttpHelper.kt:86-98):
        // a response's `Set-Cookie` is stored only when the source declares the
        // flag. A source without it still sends what the jar already holds,
        // which is what `setCookie()` does before the interceptor runs.
        await _cookies.accept(
          uri.host,
          response.headers['set-cookie'] ?? const [],
        );
      }
    } finally {
      _rateLimiter.release(rate);
    }
    return response;
  }

  String _cookieHeader(String host) => _cookies.header(host);

  /// Frozen `CookieStore.getCookie` for this session's jar.
  String cookiesFor(String url) => _cookies.cookiesFor(url);

  /// Frozen `CookieStore.getKey`.
  String cookieValue(String url, String key) => _cookies.value(url, key);

  /// Frozen `CookieStore.setCookie`: replace what this site holds.
  Future<void> setCookies(String url, String cookie) =>
      _cookies.set(url, cookie);

  /// Frozen `CookieStore.replaceCookie`: merge instead of replace.
  Future<void> replaceCookies(String url, String cookie) =>
      _cookies.replace(url, cookie);

  /// Frozen `CookieStore.removeCookie`.
  Future<void> removeCookies(String url) => _cookies.remove(url);

  /// Forgets what this source may forget; the writes are durable, so awaiting
  /// this means the next run does not see them either.
  Future<void> clearSessionCookies() => _cookies.clear();
}
