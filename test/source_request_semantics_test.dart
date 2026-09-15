import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';

/// One recorded request: the request line and lowercased headers.
class _WireRequest {
  const _WireRequest(this.line, this.headers);

  final String line;
  final String headers;

  bool has(String needle) => headers.contains(needle);
}

String ok(String body) =>
    'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n'
    'Connection: close\r\n\r\n$body';

String redirect(int status, String location) =>
    'HTTP/1.1 $status Redirect\r\nLocation: $location\r\n'
    'Content-Length: 0\r\nConnection: close\r\n\r\n';

/// A socket server that answers with [reply] and records the raw requests.
class _WireServer {
  _WireServer(this.reply);

  final String Function(String requestLine) reply;
  final List<_WireRequest> requests = [];
  final List<Socket> _sockets = [];
  late final ServerSocket _server;

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      _sockets.add(socket);
      var buffer = '';
      var sent = false;
      socket.listen(
        (bytes) {
          if (sent) return;
          buffer += utf8.decode(bytes, allowMalformed: true);
          final end = buffer.indexOf('\r\n\r\n');
          if (end < 0) return;
          sent = true;
          final head = buffer.substring(0, end);
          final lines = head.split('\r\n');
          final line = lines.first;
          requests.add(_WireRequest(line, head.toLowerCase()));
          socket.add(utf8.encode(reply(line)));
          unawaited(socket.flush().then((_) => socket.close()));
        },
        onDone: () => _sockets.remove(socket),
      );
    });
  }

  Future<void> stop() async {
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }
}

void main() {
  test('default headers follow the frozen interceptor rules', () async {
    final server = _WireServer((_) => ok('ok'));
    await server.start();
    final transport = HttpSourceTransport();
    try {
      await transport.send(
        SourceHttpRequest(method: 'GET', url: Uri.parse('${server.origin}/a')),
      );
      final injected = server.requests.single;
      expect(injected.has('user-agent: mozilla/5.0 (windows nt 10.0; win64;'), isTrue);
      expect(injected.headers, contains('chrome/128.0.0.0'));
      expect(injected.headers, contains('keep-alive: 300'));
      expect(injected.headers, contains('connection: keep-alive'));
      expect(injected.headers, contains('cache-control: no-cache'));

      await transport.send(
        SourceHttpRequest(
          method: 'GET',
          url: Uri.parse('${server.origin}/declared'),
          headers: {
            'User-Agent': 'Source/1.0',
            'Keep-Alive': '600',
            'cache-control': 'max-age=0',
          },
        ),
      );
      final declared = server.requests[1];
      expect(declared.headers, contains('user-agent: source/1.0'));
      expect(declared.headers, isNot(contains('chrome/128.0.0.0')));
      // The frozen client appends, so a declared value keeps its slot and the
      // injected value follows it.
      expect(declared.headers, contains('keep-alive: 600, 300'));
      expect(declared.headers, contains('cache-control: max-age=0, no-cache'));
      expect(declared.headers, contains('connection: keep-alive'));

      // A source that declares the literal `null` opts out of the frozen user
      // agent; the platform default then stands.
      await transport.send(
        SourceHttpRequest(
          method: 'GET',
          url: Uri.parse('${server.origin}/null'),
          headers: {'User-Agent': 'null'},
        ),
      );
      final optedOut = server.requests[2];
      expect(optedOut.headers, isNot(contains('source/1.0')));
      expect(optedOut.headers, isNot(contains('chrome/128.0.0.0')));
    } finally {
      await server.stop();
    }
  });

  test('redirects follow the frozen method and body rules', () async {
    final server = _WireServer((line) {
      if (line.contains('/after')) return ok('ok');
      final path = line.split(' ')[1].split('?').first;
      return redirect(int.parse(path.substring(1)), '/after');
    });
    await server.start();
    final transport = HttpSourceTransport();
    Future<_WireRequest> post(String path) async {
      final before = server.requests.length;
      await transport.send(
        SourceHttpRequest(
          method: 'POST',
          url: Uri.parse('${server.origin}$path'),
          headers: {'Content-Type': 'application/x-www-form-urlencoded'},
          body: 'a=1',
          followRedirects: true,
        ),
      );
      return server.requests[before + 1];
    }

    try {
      final after302 = await post('/302');
      expect(server.requests[0].line, 'POST /302 HTTP/1.1');
      expect(after302.line, 'GET /after HTTP/1.1');
      expect(after302.headers, isNot(contains('content-type:')));
      expect(after302.headers, isNot(contains('content-length:')));

      final after303 = await post('/303');
      expect(server.requests[2].line, 'POST /303 HTTP/1.1');
      expect(after303.line, 'GET /after HTTP/1.1');

      final after307 = await post('/307');
      expect(server.requests[4].line, 'POST /307 HTTP/1.1');
      expect(after307.line, 'POST /after HTTP/1.1');
      expect(after307.headers, contains('content-type:'));

      final after308 = await post('/308');
      expect(server.requests[6].line, 'POST /308 HTTP/1.1');
      expect(after308.line, 'POST /after HTTP/1.1');
      expect(after308.headers, contains('content-type:'));
    } finally {
      await server.stop();
    }
  });

  test('a redirect to another origin drops credentials and keeps the rest',
      () async {
    final target = _WireServer((_) => ok('ok'));
    await target.start();
    final redirecting = _WireServer((_) => redirect(302, '${target.origin}/after'));
    await redirecting.start();
    try {
      await HttpSourceTransport().send(
        SourceHttpRequest(
          method: 'POST',
          url: Uri.parse('${redirecting.origin}/cross'),
          headers: {
            'Authorization': 'test-value',
            'Cookie': 'test=value',
            'X-Source': 'kept',
          },
          body: 'a=1',
          followRedirects: true,
        ),
      );
      final hop = target.requests.single;
      expect(hop.line, 'GET /after HTTP/1.1');
      expect(hop.headers, isNot(contains('authorization:')));
      // The frozen client forwards a declared cookie here; this transport does
      // not, a recorded policy divergence.
      expect(hop.headers, isNot(contains('cookie:')));
      expect(hop.headers, contains('x-source: kept'));
    } finally {
      await redirecting.stop();
      await target.stop();
    }
  });

  test('the chain stops at the frozen follow-up limit', () async {
    late final _WireServer server;
    server = _WireServer((_) => redirect(302, '${server.origin}/loop'));
    await server.start();
    try {
      await expectLater(
        HttpSourceTransport().send(
          SourceHttpRequest(
            method: 'GET',
            url: Uri.parse('${server.origin}/loop'),
            followRedirects: true,
          ),
        ),
        throwsA(isA<SourceRedirectLimitExceeded>()),
      );
      expect(server.requests, hasLength(21));
    } finally {
      await server.stop();
    }
  });

  test('search URLs substitute the raw keyword and encode the query once',
      () async {
    final server = _WireServer((_) => ok('<div></div>'));
    await server.start();
    final source = <String, dynamic>{
      'bookSourceUrl': server.origin,
      'searchUrl': '/search?q={{key}}&p={{page}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    try {
      await HtmlSourcePipeline(source, HttpSourceTransport()).search('我的 书');
      expect(
        server.requests[0].line,
        'GET /search?q=%E6%88%91%E7%9A%84%20%E4%B9%A6&p=1 HTTP/1.1',
      );

      // A query that already looks encoded is sent as it is.
      await HtmlSourcePipeline(
        <String, dynamic>{
          ...source,
          'searchUrl': '/search?q=%E4%B9%A6&p={{page}}',
        },
        HttpSourceTransport(),
      ).search('书');
      expect(server.requests[1].line, 'GET /search?q=%E4%B9%A6&p=1 HTTP/1.1');

      // A page list picks the entry for the requested page, and repeats the
      // last entry past the end.
      final paged = HtmlSourcePipeline(
        <String, dynamic>{
          ...source,
          'searchUrl': '/search?page=<1,2,3>&q={{key}}',
        },
        HttpSourceTransport(),
      );
      await paged.search('书', page: 2);
      expect(server.requests[2].line, 'GET /search?page=2&q=%E4%B9%A6 HTTP/1.1');
      await paged.search('书', page: 7);
      expect(server.requests[3].line, 'GET /search?page=3&q=%E4%B9%A6 HTTP/1.1');
    } finally {
      await server.stop();
    }
  });
}
