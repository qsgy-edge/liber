import 'dart:async';
import 'dart:convert';

import '../domain/contracts.dart';
import 'source_http_uri.dart';

class SourceHostDispatcher {
  SourceHostDispatcher({
    required this.transport,
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.maxRequestBytes = 1024 * 1024,
    this.cancellation,
  }) : _cookies = SourceCookieJar();

  SourceHostDispatcher._execution(
    SourceHostDispatcher session,
    this.cancellation,
  ) : transport = session.transport,
      maxResponseBytes = session.maxResponseBytes,
      maxRequestBytes = session.maxRequestBytes,
      _cookies = session._cookies;

  /// Share source state, but never reuse another execution's one-shot token.
  SourceHostDispatcher forExecution(SourceCancellation cancellation) =>
      SourceHostDispatcher._execution(this, cancellation);

  final SourceHttpTransport transport;
  final SourceCancellation? cancellation;
  final int maxResponseBytes;
  final int maxRequestBytes;
  final SourceCookieJar _cookies;

  /// The session jar, shared with a script runtime that has no transport.
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
    _cookies.accept(uri.host, response.headers['set-cookie'] ?? const []);
    return response;
  }

  String _cookieHeader(String domain) => _cookies.header(domain);

  /// Frozen `CookieStore.getCookie` for this session's jar.
  String cookiesFor(String url) => _cookies.cookiesFor(url);

  /// Frozen `CookieStore.getKey`.
  String cookieValue(String url, String key) => _cookies.value(url, key);

  /// Frozen `CookieStore.setCookie`: replace what this host holds.
  void setCookies(String url, String cookie) => _cookies.set(url, cookie);

  /// Frozen `CookieStore.replaceCookie`: merge instead of replace.
  void replaceCookies(String url, String cookie) =>
      _cookies.replace(url, cookie);

  /// Frozen `CookieStore.removeCookie`.
  void removeCookies(String url) => _cookies.remove(url);

  void clearSessionCookies() => _cookies.clear();
}

/// The session cookie store the frozen baseline keeps in `CookieStore` plus its
/// platform jar, restricted to one process and one source session.
class SourceCookieJar {
  final Map<String, Map<String, String>> _domains = {};

  String header(String domain) => (_domains[domain] ?? const {}).entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');

  /// Frozen `CookieStore.getCookie`: the pairs held for the URL's host,
  /// serialized `k=v; k2=v2`. The frozen baseline keys by effective domain
  /// through a public-suffix database and drops a random key past 4096
  /// characters; this jar keys by the exact host and never drops a pair, both
  /// recorded divergences.
  String cookiesFor(String url) => header(_hostOf(url));

  /// Frozen `CookieStore.getKey`.
  String value(String url, String key) =>
      _domains[_hostOf(url)]?[key] ?? '';

  /// Frozen `CookieStore.setCookie`: the given cookie string replaces what this
  /// host holds. Unlike a `Set-Cookie` header, the whole string is name/value
  /// pairs, not attributes.
  void set(String url, String cookie) {
    final host = _hostOf(url);
    _domains.remove(host);
    mergePairs(host, cookie);
  }

  /// Frozen `CookieStore.replaceCookie`: merge instead of replace.
  void replace(String url, String cookie) {
    mergePairs(_hostOf(url), '${cookiesFor(url)}; $cookie');
  }

  /// Stores every `name=value` pair of a cookie string.
  void mergePairs(String domain, String cookie) {
    for (final pair in cookie.split(';')) {
      final trimmed = pair.trim();
      if (trimmed.isEmpty) continue;
      accept(domain, [trimmed]);
    }
  }

  /// Frozen `CookieStore.removeCookie`.
  void remove(String url) => _domains.remove(_hostOf(url));

  void accept(String domain, Iterable<String> values) {
    final jar = _domains.putIfAbsent(domain, () => {});
    for (final raw in values) {
      final pair = raw.split(';').first.split('=');
      if (pair.length < 2) continue;
      final name = pair.first.trim();
      final value = pair.sublist(1).join('=').trim();
      if (value.isEmpty) {
        jar.remove(name);
      } else {
        jar[name] = value;
      }
    }
    if (jar.isEmpty) _domains.remove(domain);
  }

  void clear() => _domains.clear();

  static String _hostOf(String url) {
    try {
      return SourceHttpUri.parse(url).host;
    } on FormatException {
      return url;
    }
  }
}
