import 'dart:convert';
import 'dart:io';

/// Minimal HTTP leg shaped to the frozen baseline's OkHttp client, used only
/// where the frozen `AnalyzeUrl` performs a real HTTP request before handing the
/// result to the WebView (the POST bootstrap path).
///
/// The frozen client adds `Keep-Alive`, `Connection`, and `Cache-Control` in an
/// interceptor, and `postJson` posts with a fixed
/// `application/json; charset=UTF-8` media type that replaces any
/// `Content-Type` a source declared. Both are observable by the server, so both
/// are reproduced here rather than left to the platform's defaults.
///
/// The client itself is a process-wide singleton, matching the frozen
/// `val okHttpClient by lazy` in `HttpHelper.kt:50`. That is not an
/// optimization: a per-request client pays connection setup per request, and
/// when a rule issues several requests at once the setup cost lands unevenly and
/// shifts request arrival times the server can observe.
class LegadoHttpResponse {
  LegadoHttpResponse(this.url, this.body, this.code);

  final String url;
  final String body;
  final int code;
}

class LegadoHttpClient {
  LegadoHttpClient({required this.userAgent});

  static const String jsonContentType = 'application/json; charset=UTF-8';

  final String userAgent;

  /// The shared client. `badCertificateCallback` refuses an untrusted
  /// certificate, which the security policy requires and which the frozen
  /// baseline does not do.
  static final HttpClient _client = HttpClient()
    ..badCertificateCallback = ((_, _, _) => false);

  /// Plain GET with the frozen client's interceptor headers. A non-2xx response
  /// is returned like any other response, matching the frozen baseline; only a
  /// connection failure throws.
  Future<LegadoHttpResponse> get({
    required String url,
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = _client..connectionTimeout = timeout;
    final request = await client.getUrl(Uri.parse(url));
    request.followRedirects = true;
    headers?.forEach(request.headers.set);
    if (headers?.keys.any((name) => name.toLowerCase() == 'user-agent') !=
        true) {
      request.headers.set('User-Agent', userAgent);
    }
    request.headers.set('Keep-Alive', '300');
    request.headers.set('Connection', 'Keep-Alive');
    request.headers.set('Cache-Control', 'no-cache');
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    return LegadoHttpResponse(
      response.redirects.isEmpty
          ? url
          : response.redirects.last.location.toString(),
      text,
      response.statusCode,
    );
  }

  Future<LegadoHttpResponse> postJson({
    required String url,
    required String body,
    Map<String, String>? headers,
  }) async {
    final client = _client;
    final request = await client.postUrl(Uri.parse(url));
    request.followRedirects = true;
    headers?.forEach((name, value) {
      if (name.toLowerCase() == 'content-type') return;
      request.headers.set(name, value);
    });
    if (headers?.keys.any((name) => name.toLowerCase() == 'user-agent') !=
        true) {
      request.headers.set('User-Agent', userAgent);
    }
    request.headers.set('Keep-Alive', '300');
    request.headers.set('Connection', 'Keep-Alive');
    request.headers.set('Cache-Control', 'no-cache');
    request.headers.set('Content-Type', jsonContentType);
    final bytes = utf8.encode(body);
    request.headers.contentLength = bytes.length;
    request.add(bytes);
    final response = await request.close();
    final text = await response.transform(utf8.decoder).join();
    return LegadoHttpResponse(
      response.redirects.isEmpty
          ? url
          : response.redirects.last.location.toString(),
      text,
      response.statusCode,
    );
  }
}
