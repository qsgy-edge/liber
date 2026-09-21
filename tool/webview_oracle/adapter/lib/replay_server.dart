import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// One observed request, recorded before the route's own delay is applied so
/// arrival order matches the frozen harness.
class RequestObservation {
  RequestObservation({
    required this.method,
    required this.target,
    required this.headers,
    required this.body,
    required this.startedAtElapsedMs,
  });

  final String method;
  final String target;
  final Map<String, String> headers;
  final String body;
  final int startedAtElapsedMs;

  Map<String, Object?> toJson() => {
        'method': method,
        'target': target,
        'headers': headers,
        'body': body,
        'startedAtElapsedMs': startedAtElapsedMs,
      };
}

/// Dart port of the frozen oracle's replay server. It writes raw HTTP bytes so
/// route behavior (`abort`, `delayMs`, exact status/reason/headers) matches the
/// Kotlin harness the golden was produced with.
class ReplayServer {
  ReplayServer._(
    this._fixture,
    this._connections,
    this.port,
    this._closeSocket,
    this._elapsed,
    this.isTls,
  );

  static Future<ReplayServer> bind(
    Map<String, Object?> fixture, {
    int port = 0,
  }) async {
    final elapsed = Stopwatch()..start();
    final tls = fixture['tls'] == true;
    final Stream<Socket> socket;
    final int boundPort;
    final Future<void> Function() closeSocket;
    // Assigned once the instance exists; a raw TLS connection is counted before
    // its handshake decides anything.
    void Function()? onRawConnection;
    if (!tls) {
      final plain = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      socket = plain;
      boundPort = plain.port;
      closeSocket = () async => plain.close();
    } else {
      final context = SecurityContext(withTrustedRoots: false)
        ..useCertificateChainBytes(
          utf8.encode(_pem('CERTIFICATE', fixture['certificateDerBase64']! as String)),
        )
        ..usePrivateKeyBytes(
          utf8.encode(_pem('PRIVATE KEY', fixture['privateKeyPkcs8Base64']! as String)),
        );
      // A plain listener upgraded per connection, rather than
      // `SecureServerSocket`, which only surfaces a connection once its
      // handshake succeeds. A client that refuses the fixture's certificate
      // aborts the handshake, so the fixture would otherwise observe nothing at
      // all and could not distinguish a refusal from a client that never
      // connected.
      final raw = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        shared: false,
      );
      socket = raw
          .asyncMap<Socket>((connection) async {
            onRawConnection?.call();
            return SecureSocket.secureServer(connection, context);
          })
          .transform(
            StreamTransformer<Socket, Socket>.fromHandlers(
              handleError: (error, stackTrace, sink) {
                // A refused handshake is an observation, not a server fault.
                if (error is HandshakeException || error is TlsException) return;
                sink.addError(error, stackTrace);
              },
            ),
          );
      boundPort = raw.port;
      closeSocket = () async => raw.close();
    }
    final server = ReplayServer._(
      fixture,
      socket,
      boundPort,
      closeSocket,
      elapsed,
      tls,
    );
    onRawConnection = server._countRawConnection;
    server._accept();
    return server;
  }

  final Map<String, Object?> _fixture;
  final Stream<Socket> _connections;
  final int port;
  final Future<void> Function() _closeSocket;
  final Stopwatch _elapsed;
  final bool isTls;
  final List<RequestObservation> _requests = [];
  final List<Future<void>> _inFlight = [];
  final Set<Socket> _open = {};
  Object? failure;
  bool _closed = false;

  /// Connections accepted, whether or not they produced a request. A TLS
  /// handshake that the client refuses still lands here, which distinguishes
  /// "the client reached the fixture and rejected its certificate" from "the
  /// client never connected".
  int connectionsAccepted = 0;

  void _countRawConnection() => connectionsAccepted += 1;

  String url(String path) =>
      '${isTls ? 'https' : 'http'}://127.0.0.1:$port$path';

  List<RequestObservation> snapshotRequests() =>
      List<RequestObservation>.unmodifiable(_requests);

  void _accept() {
    _connections.listen(
      (connection) {
        if (!isTls) connectionsAccepted += 1;
        _open.add(connection);
        final handled = _handle(connection).catchError((Object error) {
          if (!_closed) failure ??= error;
        }).whenComplete(() => _open.remove(connection));
        _inFlight.add(handled);
      },
      onError: (Object error) {
        if (!_closed) failure ??= error;
      },
      cancelOnError: false,
    );
  }

  Future<void> _handle(Socket connection) async {
    final buffer = <int>[];
    var headerEnd = -1;
    late StreamSubscription<List<int>> subscription;
    final complete = Completer<void>();
    var responded = false;

    subscription = connection.listen(
      (chunk) async {
        buffer.addAll(chunk);
        if (headerEnd < 0) {
          headerEnd = _findHeaderEnd(buffer);
          if (headerEnd < 0) return;
        }
        final head = latin1.decode(buffer.sublist(0, headerEnd));
        final lines = head.split('\r\n');
        final parts = lines.first.split(' ');
        if (parts.length < 3) {
          if (!complete.isCompleted) complete.complete();
          return;
        }
        final headers = <String, String>{};
        for (final line in lines.skip(1)) {
          if (line.isEmpty) continue;
          final separator = line.indexOf(':');
          if (separator <= 0) continue;
          headers[line.substring(0, separator).toLowerCase()] =
              line.substring(separator + 1).trim();
        }
        final expected = int.tryParse(headers['content-length'] ?? '') ?? 0;
        final available = buffer.length - (headerEnd + 4);
        if (available < expected) return;
        if (responded) return;
        responded = true;
        await subscription.cancel();
        final body = latin1.decode(
          buffer.sublist(headerEnd + 4, headerEnd + 4 + expected),
        );
        _requests.add(
          RequestObservation(
            method: parts[0],
            target: parts[1],
            headers: headers,
            body: body,
            startedAtElapsedMs: _elapsed.elapsedMilliseconds,
          ),
        );
        await _respond(connection, parts[0], parts[1]);
        if (!complete.isCompleted) complete.complete();
      },
      onError: (Object error) {
        if (!complete.isCompleted) complete.complete();
      },
      onDone: () {
        if (!complete.isCompleted) complete.complete();
      },
      cancelOnError: false,
    );

    await complete.future;
  }

  Future<void> _respond(Socket connection, String method, String target) async {
    final route = _routeFor(method, target);
    if (route != null && route['abort'] == true) {
      await _destroy(connection);
      return;
    }
    final status = (route?['status'] as int?) ?? 404;
    final reason = (route?['reason'] as String?) ??
        (status == 404 ? 'Not Found' : 'OK');
    final bodyText = route == null ? 'not found' : (route['body'] as String? ?? '');
    final bodyBytes = utf8.encode(bodyText);
    final delayMs = (route?['delayMs'] as int?) ?? 0;
    if (delayMs > 0) {
      await Future<void>.delayed(Duration(milliseconds: delayMs));
    }
    final headers = <String, String>{};
    final configured = route?['headers'] as Map<String, Object?>?;
    if (configured != null) {
      configured.forEach((name, value) => headers[name] = value as String);
    }
    if (!headers.keys.any((name) => name.toLowerCase() == 'content-type')) {
      headers['Content-Type'] = 'text/plain; charset=utf-8';
    }
    headers['Content-Length'] = bodyBytes.length.toString();
    headers['Connection'] = 'close';
    final head = StringBuffer('HTTP/1.1 $status $reason\r\n');
    headers.forEach((name, value) => head.write('$name: $value\r\n'));
    head.write('\r\n');
    try {
      connection.add(latin1.encode(head.toString()));
      connection.add(bodyBytes);
      await connection.flush();
      await connection.close();
    } on SocketException {
      // The client can disconnect while a delayed response is being written;
      // that is an expected observation, not a server failure.
    }
  }

  Map<String, Object?>? _routeFor(String method, String target) {
    final routes = _fixture['routes'] as List<Object?>?;
    if (routes != null) {
      for (final entry in routes) {
        final route = entry! as Map<String, Object?>;
        if ((route['method'] as String? ?? 'GET') == method &&
            route['path'] == target) {
          return route;
        }
      }
      return null;
    }
    if (_fixture['path'] == target && method == 'GET') {
      return _fixture['response']! as Map<String, Object?>;
    }
    return null;
  }

  Future<void> _destroy(Socket connection) async {
    try {
      await connection.close();
    } on SocketException {
      // Already gone.
    }
    connection.destroy();
  }

  /// Closes the listening socket and drops any still-open connection.
  ///
  /// A WebView keeps idle keep-alive and preconnected sockets open, and a
  /// handler for such a socket never finishes on its own because no request ever
  /// arrives on it. Awaiting those handlers would hang, so remaining sockets are
  /// destroyed first and the wait is bounded. Observations are already recorded
  /// when a request completes, so dropping idle sockets does not lose evidence.
  Future<void> close() async {
    _closed = true;
    await _closeSocket();
    for (final connection in _open.toList()) {
      connection.destroy();
    }
    await Future.wait(_inFlight)
        .timeout(const Duration(seconds: 2), onTimeout: () => <void>[])
        .catchError((Object _) => <void>[]);
  }

  static int _findHeaderEnd(List<int> buffer) {
    for (var index = 0; index + 3 < buffer.length; index++) {
      if (buffer[index] == 13 &&
          buffer[index + 1] == 10 &&
          buffer[index + 2] == 13 &&
          buffer[index + 3] == 10) {
        return index;
      }
    }
    return -1;
  }

  static String _pem(String label, String base64Body) {
    final lines = <String>['-----BEGIN $label-----'];
    for (var offset = 0; offset < base64Body.length; offset += 64) {
      lines.add(
        base64Body.substring(
          offset,
          offset + 64 > base64Body.length ? base64Body.length : offset + 64,
        ),
      );
    }
    lines.add('-----END $label-----');
    return '${lines.join('\n')}\n';
  }
}
