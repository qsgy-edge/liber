import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

const _startAddress = 'http://fixture.test/start';
const _afterAddress = 'http://fixture.test/after';
const _sourceHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/127.0.0.0 Safari/537.36',
  'referer': 'http://fixture.test',
};

/// One request as the fixture's raw socket saw it: the 1-based id of the
/// accepted socket that carried it, and the request head it wrote.
typedef _Request = ({int connection, String line, String headers});

/// What the fixture writes back, and whether it then closes the socket.
typedef _Reply = ({String text, bool close});

/// A raw loopback server that keeps the HTTP/1.0 envelope and the deliberate
/// incomplete responses `HttpServer` would repair for us.
///
/// [reply] sees the accepted socket's id, so a fixture can answer a reuse of
/// the first socket differently from a request on a socket opened later. Only
/// TCP destinations are mapped onto loopback; the real transport still writes
/// its own Host and header values, and each client still pools by the original
/// URL origin.
class _ConnectionServer {
  _ConnectionServer(this.reply);

  final _Reply Function(_Request request) reply;
  final requests = <_Request>[];
  final connections = <String>[];
  final _sockets = <Socket>[];
  final _closed = <int, Completer<void>>{};
  late final ServerSocket _server;

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _sockets.add(socket);
      final id = _sockets.length;
      final closed = _closed[id] = Completer<void>();
      var buffer = '';
      socket.listen(
        (bytes) {
          buffer += latin1.decode(bytes);
          while (true) {
            final end = buffer.indexOf('\r\n\r\n');
            if (end < 0) return;
            final head = buffer.substring(0, end);
            final rest = buffer.substring(end + 4);
            final length = RegExp(
              r'content-length:\s*(\d+)',
            ).firstMatch(head.toLowerCase());
            final bodyLength = length == null ? 0 : int.parse(length.group(1)!);
            // Answer only a whole request: a reply written while the body is
            // still arriving would race the peer's close against the write.
            if (rest.length < bodyLength) return;
            buffer = rest.substring(bodyLength);
            final request = (
              connection: id,
              line: head.split('\r\n').first,
              headers: head.toLowerCase(),
            );
            requests.add(request);
            final answer = reply(request);
            socket.add(latin1.encode(answer.text));
            if (answer.close) {
              unawaited(socket.flush().then((_) => socket.close()));
              return;
            }
          }
        },
        // The transport closes the client that served a finished hop; a reset
        // from that close is the policy under test, not a fixture error.
        onError: (Object _) {
          if (!closed.isCompleted) closed.complete();
        },
        onDone: () {
          if (!closed.isCompleted) closed.complete();
        },
      );
    });
  }

  /// Resolves once the socket with [connection] id is closed by either side,
  /// so a test can assert the transport dropped the connection it had in
  /// flight instead of leaving it open.
  Future<void> whenClosed(int connection) =>
      (_closed[connection] ??= Completer<void>()).future;

  HttpClient client({bool useSystemProxy = false}) {
    final client = sourceHttpClient(useSystemProxy: useSystemProxy);
    client.connectionFactory = (url, proxyHost, proxyPort) {
      // Map only the fixture's TCP destination. HttpClient still pools by the
      // original URL origin and writes its real Host/header values.
      expect(proxyHost, isNull);
      connections.add('$url');
      return Socket.startConnect(InternetAddress.loopbackIPv4, _server.port);
    };
    return client;
  }

  Future<void> stop() async {
    await _server.close();
    for (final socket in _sockets) {
      socket.destroy();
    }
  }
}

_Reply _ok() => (
  text:
      'HTTP/1.1 200 OK\r\nContent-Length: 2\r\n'
      'Content-Type: text/plain; charset=utf-8\r\n'
      'Connection: keep-alive\r\n\r\nok',
  close: false,
);

_Reply _status(int code) => (
  text:
      'HTTP/1.1 $code Status\r\nContent-Length: 0\r\n'
      'Connection: keep-alive\r\n\r\n',
  close: false,
);

_Reply _redirect(String location) => (
  text:
      'HTTP/1.0 301 Moved Permanently\r\n'
      'Location: $location\r\nKeep-Alive: timeout=4\r\n'
      'Connection: keep-alive\r\nContent-Length: 0\r\n\r\n',
  close: false,
);

SourceHttpRequest _get(
  String address, {
  int retry = 0,
  SourceCancellation? cancellation,
}) => SourceHttpRequest(
  method: 'GET',
  url: Uri.parse(address),
  headers: _sourceHeaders,
  followRedirects: true,
  retry: retry,
  cancellation: cancellation,
);

SourceHttpRequest _post(String address, {int retry = 0}) => SourceHttpRequest(
  method: 'POST',
  url: Uri.parse(address),
  headers: {'Content-Type': 'text/plain', 'referer': 'http://fixture.test'},
  body: 'a=1',
  followRedirects: true,
  retry: retry,
);

/// The pre-header failure Dart reports for both a zero-byte response and an
/// incomplete response header.
Matcher _preHeaderFailure(String url) => throwsA(
  isA<HttpException>()
      .having(
        (e) => e.message,
        'message',
        'Connection closed before full header was received',
      )
      .having((e) => '${e.uri}', 'uri', url),
);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test('a same-origin redirect follow-up uses a fresh connection', () async {
    final server = _ConnectionServer((request) {
      if (request.line.contains('/start ')) return _redirect('/after');
      // The peer closes the socket this follow-up arrives on when it is a
      // reuse of the hop that answered 301; a later socket answers 200.
      if (request.connection == 1) return (text: '', close: true);
      return _ok();
    });
    await server.start();
    addTearDown(server.stop);
    var clients = 0;
    final proxyAnswers = <bool>[];
    final transport = HttpSourceTransport(
      clientFactory: ({bool useSystemProxy = false}) {
        clients++;
        proxyAnswers.add(useSystemProxy);
        return server.client(useSystemProxy: useSystemProxy);
      },
    );

    final response = await transport
        .send(_get(_startAddress))
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect(response.body, 'ok');
    expect('${response.url}', _afterAddress);
    // The follow-up reached a socket the first hop never used: one client and
    // one TCP connection per hop, not a reuse of the hop that answered 301.
    expect(server.requests.map((r) => r.connection), [1, 2]);
    expect(server.requests.map((r) => r.line), [
      'GET /start HTTP/1.1',
      'GET /after HTTP/1.1',
    ]);
    expect(server.connections, [_startAddress, _afterAddress]);
    expect(clients, 2);
    // The proxy answer this request resolved is what every hop's client was
    // built with; no store means the direct connection.
    expect(proxyAnswers, [false, false]);
    for (final request in server.requests) {
      expect(request.headers, contains('chrome/127.0.0.0'));
      expect(request.headers, contains('referer: http://fixture.test'));
      expect(request.headers, contains('keep-alive: 300'));
    }
  });

  test('a source status retry starts on its own connection', () async {
    final server = _ConnectionServer(
      (request) => request.connection == 1 ? _status(500) : _ok(),
    );
    await server.start();
    addTearDown(server.stop);
    var clients = 0;
    final transport = HttpSourceTransport(
      clientFactory: ({bool useSystemProxy = false}) {
        clients++;
        return server.client(useSystemProxy: useSystemProxy);
      },
    );

    final response = await transport
        .send(_get(_startAddress, retry: 1))
        .timeout(const Duration(seconds: 10));

    expect(response.statusCode, 200);
    expect(response.body, 'ok');
    expect(server.requests.map((r) => r.connection), [1, 2]);
    expect(server.connections, [_startAddress, _startAddress]);
    expect(clients, 2);
  });

  test(
    'cancellation during a redirect hop closes it and starts no later hop',
    () async {
      final reached = Completer<void>();
      final server = _ConnectionServer((request) {
        if (request.line.contains('/start ')) return _redirect('/after');
        // The follow-up is answered with nothing: the send is cancelled while
        // it waits here, so the hop's own client must close.
        if (!reached.isCompleted) reached.complete();
        return (text: '', close: false);
      });
      await server.start();
      addTearDown(server.stop);
      var clients = 0;
      final cancellation = SourceCancellation();
      final transport = HttpSourceTransport(
        clientFactory: ({bool useSystemProxy = false}) {
          clients++;
          return server.client(useSystemProxy: useSystemProxy);
        },
      );

      final cancelled = expectLater(
        transport.send(_get(_startAddress, cancellation: cancellation)),
        throwsA(isA<SourceRequestCancelled>()),
      );
      await reached.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      await cancelled;

      expect(server.requests.map((r) => r.line), [
        'GET /start HTTP/1.1',
        'GET /after HTTP/1.1',
      ]);
      expect(server.requests.map((r) => r.connection), [1, 2]);
      expect(clients, 2);
    },
  );

  test('a fresh peer close stays visible with no replay', () async {
    final server = _ConnectionServer((_) => (text: '', close: true));
    await server.start();
    addTearDown(server.stop);
    var clients = 0;
    final transport = HttpSourceTransport(
      clientFactory: ({bool useSystemProxy = false}) {
        clients++;
        return server.client(useSystemProxy: useSystemProxy);
      },
    );

    await expectLater(
      transport
          .send(_get(_startAddress, retry: 2))
          .timeout(const Duration(seconds: 10)),
      _preHeaderFailure(_startAddress),
    );
    // The rule's attempts cover non-2xx responses only: a transport failure
    // leaves exactly one request on one connection.
    expect(server.requests, hasLength(1));
    expect(server.connections, [_startAddress]);
    expect(clients, 1);
  });

  test('a partial response header is the same visible failure', () async {
    final server = _ConnectionServer(
      (_) => (text: 'HTTP/1.1 200 OK\r\nX-Test: incomplete', close: true),
    );
    await server.start();
    addTearDown(server.stop);
    var clients = 0;
    final transport = HttpSourceTransport(
      clientFactory: ({bool useSystemProxy = false}) {
        clients++;
        return server.client(useSystemProxy: useSystemProxy);
      },
    );

    await expectLater(
      transport.send(_get(_startAddress)).timeout(const Duration(seconds: 10)),
      _preHeaderFailure(_startAddress),
    );
    expect(server.requests, hasLength(1));
    expect(clients, 1);
  });

  test('a request with a body is not replayed after a peer close', () async {
    final server = _ConnectionServer((_) => (text: '', close: true));
    await server.start();
    addTearDown(server.stop);
    var clients = 0;
    final transport = HttpSourceTransport(
      clientFactory: ({bool useSystemProxy = false}) {
        clients++;
        return server.client(useSystemProxy: useSystemProxy);
      },
    );

    await expectLater(
      transport
          .send(_post(_startAddress, retry: 2))
          .timeout(const Duration(seconds: 10)),
      _preHeaderFailure(_startAddress),
    );
    expect(server.requests.map((r) => r.line), ['POST /start HTTP/1.1']);
    expect(server.requests.single.headers, contains('content-length: 3'));
    expect(server.connections, [_startAddress]);
    expect(clients, 1);
  });

  test(
    'a whole-send timeout during a redirect hop closes it and starts no later hop',
    () async {
      final server = _ConnectionServer((request) {
        if (request.line.contains('/start ')) return _redirect('/after');
        // The follow-up is answered with nothing, so the whole-send timeout is
        // what ends this request while its hop is waiting here.
        return (text: '', close: false);
      });
      await server.start();
      addTearDown(server.stop);
      var clients = 0;
      final transport = HttpSourceTransport(
        timeout: const Duration(seconds: 2),
        clientFactory: ({bool useSystemProxy = false}) {
          clients++;
          return server.client(useSystemProxy: useSystemProxy);
        },
      );

      await expectLater(
        transport.send(_get(_startAddress)),
        throwsA(isA<TimeoutException>()),
      );
      // The waiting hop is the last one: no third client and no third request
      // followed the timeout, and the hop's own connection was dropped.
      expect(server.requests.map((r) => r.line), [
        'GET /start HTTP/1.1',
        'GET /after HTTP/1.1',
      ]);
      expect(server.requests.map((r) => r.connection), [1, 2]);
      expect(clients, 2);
      await server.whenClosed(2).timeout(const Duration(seconds: 5));
    },
  );
}
