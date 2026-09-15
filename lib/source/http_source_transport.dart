import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../domain/contracts.dart';
import 'book_source_service.dart';
import 'source_http_uri.dart';

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
    // Dart fills its default User-Agent before copying redirect headers.
    // Configure the client too, so an explicit source value survives every hop.
    for (final header in sourceRequest.headers.entries) {
      if (header.key.toLowerCase() == 'user-agent') {
        client.userAgent = header.value;
      }
    }
    Future<SourceHttpResponse> read() async {
      SourceHttpResponse? response;
      for (var attempt = 0; attempt <= sourceRequest.retry; attempt++) {
        sourceRequest.cancellation?.throwIfCancelled();
        response = await _readOnce(client, uri, sourceRequest);
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
    } catch (_) {
      // Closing the client can report an I/O error before the cancellation
      // Future settles. Preserve the explicit cancellation outcome.
      sourceRequest.cancellation?.throwIfCancelled();
      rethrow;
    } finally {
      unsubscribe?.call();
      // Future.timeout alone does not stop I/O; close this request's client.
      client.close(force: true);
    }
  }

  /// One attempt: request, manual redirect chain, and body read.
  Future<SourceHttpResponse> _readOnce(
    HttpClient client,
    Uri uri,
    SourceHttpRequest sourceRequest,
  ) async {
    final request = await client.openUrl(sourceRequest.method, uri);
    // Supply raw Location ourselves; automatic redirects parse it with Uri
    // and lose literal brackets. redirect() retains Dart's method and
    // sensitive-header forwarding rules, TLS validation and cancellation.
    request.followRedirects = false;
    sourceRequest.headers.forEach(request.headers.set);
    if (sourceRequest.body != null) request.write(sourceRequest.body);
    var response = await request.close();
    while (sourceRequest.followRedirects && response.isRedirect) {
      if (response.redirects.length >= request.maxRedirects) {
        throw RedirectException('Redirect limit exceeded', response.redirects);
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) break;
      await response.drain<void>();
      sourceRequest.cancellation?.throwIfCancelled();
      response = await response.redirect(null, SourceHttpUri.parse(location));
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      if (bytes.length + chunk.length > sourceRequest.maxResponseBytes) {
        throw const SourceIoLimitExceeded('response');
      }
      bytes.addAll(chunk);
    }
    final headers = <String, List<String>>{};
    response.headers.forEach((name, values) {
      headers[name] = List<String>.unmodifiable(values);
    });
    var finalUrl = uri;
    for (final redirect in response.redirects) {
      finalUrl = finalUrl.resolveUri(redirect.location);
    }
    return SourceHttpResponse(
      statusCode: response.statusCode,
      headers: Map<String, List<String>>.unmodifiable(headers),
      body: utf8.decode(bytes),
      url: finalUrl,
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
