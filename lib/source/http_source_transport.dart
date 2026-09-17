import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'source_http_uri.dart';

/// The frozen `HttpHelper.okHttpClient` interceptor appends these to every
/// request, after whatever the source declared.
const sourceInjectedHeaders = <String, String>{
  'Keep-Alive': '300',
  'Connection': 'Keep-Alive',
  'Cache-Control': 'no-cache',
};

/// `AppConfig.userAgent` at the frozen baseline (`gradle.properties`
/// `CronetMainVersion=128.0.0.0`): the user agent used whenever a source does
/// not declare one.
const sourceDefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

/// Frozen interceptor header rules: fill in the user agent, then append the
/// three connection headers. A source value keeps its slot and the injected
/// value is appended, like OkHttp's `addHeader`. A source that declares the
/// literal `null` opts out; the frozen client then falls back to its platform
/// default, which this transport cannot reproduce (Dart's own default stands).
Map<String, String> withSourceRequestDefaults(Map<String, String> headers) {
  final result = <String, String>{...headers};
  String? declaredUserAgent;
  for (final key in result.keys) {
    if (key.toLowerCase() == 'user-agent') {
      declaredUserAgent = key;
      break;
    }
  }
  if (declaredUserAgent == null) {
    result['User-Agent'] = sourceDefaultUserAgent;
  } else if (result[declaredUserAgent] == 'null') {
    result.remove(declaredUserAgent);
  }
  for (final entry in sourceInjectedHeaders.entries) {
    String? declared;
    for (final key in result.keys) {
      if (key.toLowerCase() == entry.key.toLowerCase()) {
        declared = key;
        break;
      }
    }
    if (declared == null) {
      result[entry.key] = entry.value;
    } else {
      result[declared] = '${result[declared]}, ${entry.value}';
    }
  }
  return result;
}

/// Statuses the frozen client follows (OkHttp `followRedirects`).
const _sourceRedirectStatuses = {300, 301, 302, 303, 307, 308};

/// OkHttp's `MAX_FOLLOW_UPS`: the 21st redirect throws.
const _maxSourceFollowUps = 20;

class HttpSourceTransport implements BookSourceTransport, SourceHttpTransport {
  HttpSourceTransport({this.timeout = const Duration(seconds: 30)});

  final Duration timeout;

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest sourceRequest) async {
    final originalUri = SourceHttpUri.parse(sourceRequest.url.toString());
    // OkHttp's canonical HTTP URL includes '/' for an empty path. Source JS
    // can append a relative filename directly to raw().request().url().
    final uri = originalUri.path.isEmpty
        ? originalUri.replace(path: '/')
        : originalUri;
    if (!['http', 'https'].contains(uri.scheme) || uri.host.isEmpty) {
      throw ArgumentError.value(uri, 'url', 'HTTP(S) URL required');
    }
    sourceRequest.cancellation?.throwIfCancelled();
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..findProxy = (_) => 'DIRECT';
    if (sourceRequest.allowInvalidCertificate) {
      // ADR 0011 §5: the user's per-source, per-host exception. This client
      // serves one `send`, so the callback cannot lower validation for another
      // source or another host.
      client.badCertificateCallback = (_, _, _) => true;
    }
    // Dart fills its default User-Agent before the headers are copied, so
    // configure the client too: an explicit value must survive every hop.
    final headers = withSourceRequestDefaults(sourceRequest.headers);
    for (final header in headers.entries) {
      if (header.key.toLowerCase() == 'user-agent') {
        client.userAgent = header.value;
      }
    }
    Future<SourceHttpResponse> read() async {
      SourceHttpResponse? response;
      for (var attempt = 0; attempt <= sourceRequest.retry; attempt++) {
        sourceRequest.cancellation?.throwIfCancelled();
        response = await _readOnce(client, uri, sourceRequest, headers);
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return response;
        }
      }
      return response!;
    }

    final cancelled = Completer<SourceHttpResponse>();
    final result = Future.any([read(), cancelled.future]);
    final unsubscribe = sourceRequest.cancellation?.listen(() {
      if (!cancelled.isCompleted) {
        cancelled.completeError(const SourceRequestCancelled());
        client.close(force: true);
      }
    });
    try {
      return await result.timeout(timeout);
    } catch (error) {
      // Closing the client can report an I/O error before the cancellation
      // Future settles. Preserve the explicit cancellation outcome.
      sourceRequest.cancellation?.throwIfCancelled();
      final failure = sourceTlsFailure(
        error,
        sourceRef: sourceRequest.sourceRef,
        host: uri.host,
      );
      if (failure != null) throw failure;
      rethrow;
    } finally {
      unsubscribe?.call();
      // Future.timeout alone does not stop I/O; close this request's client.
      client.close(force: true);
    }
  }

  /// One attempt: request, manual redirect chain, and body read.
  ///
  /// The redirect rules are OkHttp's `RetryAndFollowUpInterceptor`: 300, 301,
  /// 302 and 303 turn a request that carries a body into a GET without one and
  /// drop the content headers, 307 and 308 keep method and body, a hop to
  /// another scheme, host or port drops `Authorization`, and the 21st redirect
  /// fails the call. Dart's own `HttpClientResponse.redirect` keeps the method
  /// and drops the body, so the chain is walked here.
  Future<SourceHttpResponse> _readOnce(
    HttpClient client,
    Uri uri,
    SourceHttpRequest sourceRequest,
    Map<String, String> headers,
  ) async {
    var method = sourceRequest.method;
    var target = uri.hasFragment ? uri.removeFragment() : uri;
    var body = sourceRequest.body;
    var hop = 0;
    while (true) {
      final request = await client.openUrl(method, target);
      request.followRedirects = false;
      for (final header in headers.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        // OkHttp writes a body as UTF-8 unless the media type names a charset;
        // the sink's own encoding is latin1 and not mutable here.
        request.add(utf8.encode(body));
      }
      final response = await request.close();
      if (!sourceRequest.followRedirects ||
          !_sourceRedirectStatuses.contains(response.statusCode)) {
        return _readResponse(response, target, sourceRequest.maxResponseBytes);
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        return _readResponse(response, target, sourceRequest.maxResponseBytes);
      }
      await response.drain<void>();
      if (++hop > _maxSourceFollowUps) {
        throw SourceRedirectLimitExceeded(hop, target);
      }
      final next = target.resolve(location);
      if (next.scheme != target.scheme ||
          next.host != target.host ||
          next.port != target.port) {
        // The frozen client drops `Authorization` here but forwards a declared
        // `Cookie`; this transport drops both, a recorded policy divergence:
        // credentials do not travel to another origin.
        headers.removeWhere((key, _) {
          final name = key.toLowerCase();
          return name == 'authorization' || name == 'cookie';
        });
      }
      target = next.hasFragment ? next.removeFragment() : next;
      if (method != 'GET' && method != 'HEAD') {
        final keepsBody = response.statusCode == 307 || response.statusCode == 308;
        if (!keepsBody && (response.statusCode == 300 ||
            response.statusCode == 301 ||
            response.statusCode == 302 ||
            response.statusCode == 303)) {
          method = 'GET';
          body = null;
          headers.removeWhere((key, _) {
            final name = key.toLowerCase();
            return name == 'content-type' ||
                name == 'content-length' ||
                name == 'transfer-encoding';
          });
        } else if (!keepsBody) {
          body = null;
          headers.removeWhere((key, _) {
            final name = key.toLowerCase();
            return name == 'content-type' ||
                name == 'content-length' ||
                name == 'transfer-encoding';
          });
        }
      }
      sourceRequest.cancellation?.throwIfCancelled();
    }
  }

  Future<SourceHttpResponse> _readResponse(
    HttpClientResponse response,
    Uri url,
    int maxResponseBytes,
  ) async {
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > maxResponseBytes) {
        throw const SourceIoLimitExceeded('response');
      }
      bytes.addAll(chunk);
    }
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name] = List<String>.unmodifiable(values);
    });
    return SourceHttpResponse(
      statusCode: response.statusCode,
      headers: Map<String, List<String>>.unmodifiable(headers),
      body: utf8.decode(bytes),
      url: url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => (await send(
    SourceHttpRequest(
      method: 'GET',
      url: SourceHttpUri.parse(path),
      // Preserve the existing HTML pipeline's redirect behavior.
      followRedirects: true,
    ),
  )).body;
}

/// Raised when a source redirect chain exceeds the frozen client's limit.
class SourceRedirectLimitExceeded implements Exception {
  const SourceRedirectLimitExceeded(this.followUps, this.url);

  final int followUps;
  final Uri url;

  @override
  String toString() =>
      'Too many follow-up requests: $followUps ($url)';
}

/// Names [error] as ADR 0011 §5's certificate failure, or returns null when it
/// is not one.
///
/// Dart's `HttpClient` reports a certificate or hostname failure out of
/// `openUrl`/`request.close` as a `TlsException`, whose subclasses
/// (`HandshakeException`, `CertificateException`) all satisfy this test.
SourceTlsCertificateFailure? sourceTlsFailure(
  Object error, {
  required String sourceRef,
  required String host,
}) {
  if (error is! TlsException) return null;
  return SourceTlsCertificateFailure(
    sourceRef: sourceRef,
    host: host,
    reason: _tlsReason(error.message),
    detail: error.message,
  );
}

/// The verification problem in plain words. The transport's message is the
/// platform's; only the categories a user can act on are named.
String _tlsReason(String message) {
  final upper = message.toUpperCase();
  if (upper.contains('HOSTNAME') || upper.contains('IP ADDRESS MISMATCH')) {
    return '证书与主机名不匹配';
  }
  if (upper.contains('CERTIFICATE') ||
      upper.contains('SELF-SIGNED') ||
      upper.contains('SELF SIGNED') ||
      upper.contains('EXPIRED')) {
    return '证书无效、过期或不受信任';
  }
  return '证书或主机名校验未通过';
}
