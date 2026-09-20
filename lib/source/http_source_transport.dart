import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'source_encoding.dart';
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

/// Frozen `String.toRequestBody(contentType)` (okhttp-4.12.0
/// `RequestBody$Companion.create(String, MediaType)`): a media type that names
/// no charset gains `; charset=utf-8` on the body it writes, and a declared
/// charset is kept as it is. Mutates [headers] in place, so the follow-up of a
/// 307/308 sees the same map, and is idempotent for the same reason.
///
/// Guarded by the body's own content type, so it applies to every branch the
/// frozen `AnalyzeUrl` builds a body for: the form branch
/// (`postForm(encodedForm)`, `OkHttpUtils.kt:141-142`), a declared
/// `Content-Type` (`body.toRequestBody(contentType.toMediaType())`,
/// `AnalyzeUrl.kt:435-446`) and `postJson` (whose media type already names
/// `UTF-8`). It is idempotent, so the follow-up of a 307/308 keeps one charset.
///
/// The body's bytes use that media type's charset through [SourceEncoding].
/// The URL option's `charset` has already been applied to form/query escapes;
/// it does not override a declared body media type (frozen AnalyzeUrl.kt:257-260,
/// 435-446).
Map<String, String> withSourceBodyContentType(Map<String, String> headers) {
  String? name;
  for (final key in headers.keys) {
    if (key.toLowerCase() == 'content-type') {
      name = key;
      break;
    }
  }
  if (name == null) return headers;
  final value = headers[name]!;
  if (sourceMediaTypeCharset([value]) != null) return headers;
  headers[name] = '$value; charset=utf-8';
  return headers;
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
      final requestHeaders = body == null
          ? headers
          : withSourceBodyContentType(headers);
      for (final header in requestHeaders.entries) {
        request.headers.set(header.key, header.value);
      }
      if (body != null) {
        final charset = sourceMediaTypeCharset([
          for (final header in requestHeaders.entries)
            if (header.key.toLowerCase() == 'content-type') header.value,
        ]);
        List<int> bytes;
        try {
          bytes = await SourceEncoding.encode(body, charset ?? 'UTF-8');
        } catch (error) {
          if (!SourceEncoding.isUnknownEncoding(error)) rethrow;
          // OkHttp MediaType.charset returns its default for unknown labels.
          // Preserve the explicitly declared header and the UTF-8 body fallback.
          bytes = utf8.encode(body);
        }
        // The frozen client knows the body it built, so its request carries
        // `Content-Length` rather than a chunked stream; Dart's `HttpClient`
        // frames an unknown length chunked unless the length is set first.
        request.contentLength = bytes.length;
        request.add(bytes);
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
        final keepsBody =
            response.statusCode == 307 || response.statusCode == 308;
        if (!keepsBody &&
            (response.statusCode == 300 ||
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
      body: await decodeSourceResponseBody(Uint8List.fromList(bytes), headers),
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
  String toString() => 'Too many follow-up requests: $followUps ($url)';
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

/// The response body decoded the way the frozen client decodes it.
///
/// `ResponseBody.text()` (`OkHttpUtils.kt:78-96`) removes a UTF-8 byte order
/// mark and then decodes with the media type's charset; when the response
/// declares none, `EncodingDetect.getHtmlEncode` (`EncodingDetect.kt:18-50`)
/// reads the document's own `<meta>` charset and only then falls back to the
/// engine's detection. One engine decodes every branch (`packages/fjs/liber_text`,
/// the same `encoding_rs` the local-file decode uses). The body's
/// `charset` request option plays no part here: the frozen option only feeds
/// request encoding.
Future<String> decodeSourceResponseBody(
  Uint8List bytes,
  Map<String, List<String>> headers,
) async {
  final body = removeSourceUtf8Bom(bytes);
  final declared = sourceMediaTypeCharset(headers['content-type']);
  if (declared != null) {
    try {
      return await SourceEncoding.decode(body, encoding: declared);
    } catch (error) {
      // OkHttp's `MediaType.charset()` answers null for a label it cannot
      // resolve, and the frozen path then reads the document's own meta. A
      // decoding failure that is not a missing label still propagates.
      if (!SourceEncoding.isUnknownEncoding(error)) rethrow;
    }
  }
  final meta = sourceHtmlMetaCharset(body);
  if (meta != null) {
    // The frozen `String(bytes, Charset.forName(meta))` is left to throw on a
    // name no charset provider knows, so this branch does not fall back.
    return SourceEncoding.decode(body, encoding: meta);
  }
  return SourceEncoding.decode(body);
}

/// Frozen `Utf8BomUtils.removeUTF8BOM` (`Utf8BomUtils.kt:12-18`), the strict
/// `size > 3` test included: a body of exactly the three BOM bytes is kept.
Uint8List removeSourceUtf8Bom(Uint8List bytes) =>
    bytes.length > 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF
    ? Uint8List.sublistView(bytes, 3)
    : bytes;

/// OkHttp's `MediaType.charset()` over the response's `Content-Type` values.
///
/// OkHttp reads the last `Content-Type` header, matches `charset` as a
/// case-insensitive parameter name and unquotes its value; a parameter that is
/// empty or absent answers null, and the caller then reads the document.
String? sourceMediaTypeCharset(List<String>? values) {
  if (values == null || values.isEmpty) return null;
  final match = RegExp(
    r'charset\s*=\s*("([^"]*)"|([^;,\s]*))',
    caseSensitive: false,
  ).firstMatch(values.last);
  if (match == null) return null;
  final value = (match[2] ?? match[3] ?? '').trim();
  return value.isEmpty ? null : value;
}

/// Frozen `EncodingDetect.getHtmlEncode` (`EncodingDetect.kt:18-50`): the
/// document's `<head>` meta tags in order, then an `http-equiv` content-type.
///
/// The head is the literal `<head>`…`</head>` byte range when the document has
/// one — that byte search is case-sensitive in the frozen code — and otherwise
/// the same tags matched case-insensitively over the whole body. Both read the
/// bytes as UTF-8, as the frozen `String(bytes)` does, so a legacy-encoded
/// page's non-ASCII text is mojibake while the meta tags, ASCII in every
/// encoding the engine decodes, survive. No tag answers null, which is the
/// frozen path's fall-through to detection.
String? sourceHtmlMetaCharset(Uint8List bytes) {
  final head = _sourceHeadSlice(bytes) ?? _sourceHeadByPattern(bytes);
  if (head == null) return null;
  for (final tag in RegExp(
    '<meta\\b[^>]*>',
    caseSensitive: false,
  ).allMatches(head)) {
    final text = tag.group(0)!;
    final charset = _sourceAttributeValue(text, 'charset');
    if (charset != null && charset.isNotEmpty) return charset;
    final httpEquiv = _sourceAttributeValue(text, 'http-equiv');
    if (httpEquiv == null || httpEquiv.toLowerCase() != 'content-type') {
      continue;
    }
    final content = _sourceAttributeValue(text, 'content') ?? '';
    final index = content.toLowerCase().indexOf('charset=');
    final value = index > -1
        ? content.substring(index + 'charset='.length)
        : _substringAfterSemicolon(content);
    if (value.isNotEmpty) return value;
  }
  return null;
}

/// Frozen `content.substringAfter(";")`: everything after the first `;`, or the
/// whole string when there is none.
String _substringAfterSemicolon(String content) {
  final index = content.indexOf(';');
  return index < 0 ? content : content.substring(index + 1);
}

/// The `<head>`…`</head>` bytes as the frozen `String(bytes)` reads them.
String? _sourceHeadSlice(Uint8List bytes) {
  const open = [0x3C, 0x68, 0x65, 0x61, 0x64, 0x3E]; // `<head>`
  const close = [0x3C, 0x2F, 0x68, 0x65, 0x61, 0x64, 0x3E]; // `</head>`
  final start = _indexOfBytes(bytes, open, 0);
  if (start < 0) return null;
  final end = _indexOfBytes(bytes, close, start);
  if (end < 0) return null;
  return _utf8Lenient(bytes, start, end + close.length);
}

/// The frozen regex fallback: `<head>`…`</head>` ignoring case over the whole
/// body decoded as UTF-8.
String? _sourceHeadByPattern(Uint8List bytes) => RegExp(
  r'<head>[\s\S]*?</head>',
  caseSensitive: false,
).firstMatch(_utf8Lenient(bytes, 0, bytes.length))?.group(0);

/// One HTML attribute's value, as Jsoup's `Element.attr` reads it: double- or
/// single-quoted, or the bare token up to whitespace or the tag's end.
String? _sourceAttributeValue(String tag, String name) {
  final match = RegExp(
    '$name\\s*=\\s*("([^"]*)"|\'([^\']*)\'|([^\\s"\'>]+))',
    caseSensitive: false,
  ).firstMatch(tag);
  if (match == null) return null;
  return match[2] ?? match[3] ?? match[4] ?? '';
}

int _indexOfBytes(Uint8List bytes, List<int> pattern, int from) {
  outer:
  for (var at = from; at + pattern.length <= bytes.length; at++) {
    for (var offset = 0; offset < pattern.length; offset++) {
      if (bytes[at + offset] != pattern[offset]) continue outer;
    }
    return at;
  }
  return -1;
}

String _utf8Lenient(Uint8List bytes, int start, int end) =>
    utf8.decode(Uint8List.sublistView(bytes, start, end), allowMalformed: true);
