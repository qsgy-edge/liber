import 'dart:async';
import 'dart:convert';

import '../domain/contracts.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';

class SourceHostDispatcher {
  factory SourceHostDispatcher({
    required SourceHttpTransport transport,
    int maxResponseBytes = 8 * 1024 * 1024,
    int maxRequestBytes = 1024 * 1024,
    SourceCancellation? cancellation,
    SourceHostState? hostState,
    String sourceRef = '',
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
  );

  SourceHostDispatcher._execution(
    SourceHostDispatcher session,
    this.cancellation,
  ) : transport = session.transport,
      maxResponseBytes = session.maxResponseBytes,
      maxRequestBytes = session.maxRequestBytes,
      _hostState = session._hostState,
      _sourceRef = session._sourceRef,
      _cookies = session._cookies;

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
  }) => _send('GET', url, headers: headers);

  Future<SourceHttpResponse> head(
    String url, {
    Map<String, String> headers = const {},
  }) => _send('HEAD', url, headers: headers);

  Future<SourceHttpResponse> post(
    String url,
    String body, {
    Map<String, String> headers = const {},
  }) => _send('POST', url, headers: headers, body: body);

  Future<List<SourceHttpResponse>> ajaxAll(
    Iterable<String> urls, {
    int concurrency = 4,
  }) async {
    if (concurrency < 1) throw ArgumentError.value(concurrency, 'concurrency');
    final values = urls.toList(growable: false);
    if (values.isEmpty) return const [];
    final output = List<SourceHttpResponse?>.filled(values.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final index = next++;
        if (index >= values.length) return;
        output[index] = await connect(values[index]);
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
    final merged = <String, String>{...headers};
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
    final response = await transport.send(
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
      ),
    );
    cancellation?.throwIfCancelled();
    if (utf8
            .encode(
              jsonEncode({
                'headers': response.headers,
                'body': response.body,
                'url': '${response.url}',
              }),
            )
            .length >
        maxResponseBytes) {
      throw const SourceIoLimitExceeded('response');
    }
    await _cookies.accept(uri.host, response.headers['set-cookie'] ?? const []);
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
