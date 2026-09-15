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
  }) : _cookies = {};

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
  final Map<String, Map<String, String>> _cookies;

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
    _acceptCookies(uri.host, response.headers['set-cookie'] ?? const []);
    return response;
  }

  String _cookieHeader(String domain) => (_cookies[domain] ?? const {}).entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');

  void _acceptCookies(String domain, Iterable<String> values) {
    final jar = _cookies.putIfAbsent(domain, () => {});
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
    if (jar.isEmpty) _cookies.remove(domain);
  }

  void clearSessionCookies() => _cookies.clear();
}
