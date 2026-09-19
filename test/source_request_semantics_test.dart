import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

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

/// The same envelope carrying raw bytes, so a non-UTF-8 body can be served.
List<int> okBytes(List<int> body, {String contentType = 'text/html'}) => [
  ...utf8.encode(
    'HTTP/1.1 200 OK\r\nContent-Type: $contentType\r\n'
    'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n',
  ),
  ...body,
];

String redirect(int status, String location) =>
    'HTTP/1.1 $status Redirect\r\nLocation: $location\r\n'
    'Content-Length: 0\r\nConnection: close\r\n\r\n';

/// A socket server that answers with [reply] (text or raw bytes) and records
/// the raw requests.
class _WireServer {
  _WireServer(this.reply);

  final Object Function(String requestLine) reply;
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
          final answer = reply(line);
          socket.add(answer is List<int> ? answer : utf8.encode(answer as String));
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
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

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
      // The frozen client knows the body it built: the wire carries its
      // length, not a chunked stream (okhttp-4.12.0 RequestBody$Companion).
      expect(server.requests[0].headers, contains('content-length: 3'));
      expect(server.requests[0].headers, isNot(contains('transfer-encoding')));
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

  test('a body media type gains the frozen charset only when none is declared',
      () async {
    final server = _WireServer((_) => ok('ok'));
    await server.start();
    final transport = HttpSourceTransport();
    Future<_WireRequest> post(Map<String, String> headers) async {
      final before = server.requests.length;
      await transport.send(
        SourceHttpRequest(
          method: 'POST',
          url: Uri.parse('${server.origin}/post'),
          headers: headers,
          body: 'a=1',
        ),
      );
      return server.requests[before];
    }

    try {
      // okhttp-4.12.0 `RequestBody$Companion.create(String, MediaType)` parses
      // "<declared>; charset=utf-8" and writes the resolved charset's bytes,
      // so a declared media type without a charset reaches the wire with one.
      final appended = await post({
        'Content-Type': 'application/x-www-form-urlencoded',
      });
      expect(
        appended.headers,
        contains('content-type: application/x-www-form-urlencoded; charset=utf-8'),
      );
      expect(appended.headers, contains('content-length: 3'));
      expect(appended.headers, isNot(contains('transfer-encoding')));

      // A media type that names a charset is kept as the source wrote it. The
      // frozen call would also write the body's bytes with that charset; this
      // transport keeps UTF-8, which no fixture in this slice reaches.
      final declared = await post({'Content-Type': 'text/plain; charset=GBK'});
      expect(declared.headers, contains('content-type: text/plain; charset=gbk'));
      expect(declared.headers, contains('content-length: 3'));
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

  test('the charset option reaches the wire in both encoder shapes', () async {
    final server = _WireServer(
      (_) => ok('<div class="item"><h3><a href="/book/">书</a></h3></div>'),
    );
    await server.start();
    try {
      // `charset: "escape"` is the frozen `EncoderUtils.escape` on the query:
      // a space is `%20`, and everything outside letters and digits is escaped.
      await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': server.origin,
        'searchUrl': '/search?q={{key}},{"charset":"escape"}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('a b');
      expect(server.requests[0].line, 'GET /search?q=a%20b HTTP/1.1');

      // A residual divergence the differential contract records: Dart's `Uri`
      // canonicalizes an escape of an unreserved character while it resolves,
      // so `EncoderUtils.escape`'s `%7e` reaches the wire as the bare `~` (and
      // its `%uXXXX` form as `%25uXXXX`). The frozen client sends the escape.
      await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': server.origin,
        'searchUrl': '/search?q={{key}},{"charset":"escape"}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('a~b');
      expect(server.requests[1].line, 'GET /search?q=a~b HTTP/1.1');

      // A named charset writes that charset's bytes: GBK 书 is CA E9.
      await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': server.origin,
        'searchUrl': '/search?q={{key}},{"charset":"gbk"}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('书');
      expect(server.requests[2].line, 'GET /search?q=%CA%E9 HTTP/1.1');
    } finally {
      await server.stop();
    }
  });

  test('a named charset reaches the POST form body on the wire', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final bodies = <String>[];
    final contentTypes = <String>[];
    final subscription = server.listen((request) async {
      final bytes = <int>[];
      await for (final chunk in request) {
        bytes.addAll(chunk);
      }
      bodies.add(utf8.decode(bytes, allowMalformed: true));
      contentTypes.add(request.headers.value('content-type') ?? '');
      request.response.write(
        '<div class="item"><h3><a href="/book/">书</a></h3></div>',
      );
      await request.response.close();
    });
    try {
      final origin = 'http://127.0.0.1:${server.port}';
      await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/search,{"method":"POST","body":"k={{key}}",'
            '"charset":"gbk"}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('书');
      // `URLEncoder.encode(value, GBK)`: the charset's bytes as upper-case
      // `%XX` (AnalyzeUrl.kt:318-328).
      expect(bodies.single, 'k=%CA%E9');
      // Frozen `String.toRequestBody(formContentType)`: the form media type has
      // no charset parameter, so the body it writes gains `; charset=utf-8`
      // (okhttp-4.12.0 `RequestBody$Companion.create`). The frozen client's
      // header therefore names UTF-8 while the bytes above are GBK: the same
      // resolved charset also selects those bytes, and only the header half is
      // reproduced here (recorded as a coverage gap).
      expect(contentTypes.single, 'application/x-www-form-urlencoded; charset=utf-8');
    } finally {
      await subscription.cancel();
      await server.close(force: true);
    }
  });

  test('a response is decoded with the charset its Content-Type declares',
      () async {
    // GBK 书 is CA E9; the header names the charset the body is in.
    final page = <int>[
      ...utf8.encode('<html><body><div class="item"><h3><a href="/book/">'),
      0xCA,
      0xE9,
      ...utf8.encode('</a></h3></div></body></html>'),
    ];
    final server = _WireServer(
      (_) => okBytes(page, contentType: 'text/html; charset=GBK'),
    );
    await server.start();
    try {
      final hits = await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': server.origin,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('书');
      expect(hits.single.title, '书');
    } finally {
      await server.stop();
    }
  });

  test('a response is decoded with the charset its own meta declares',
      () async {
    final page = <int>[
      ...utf8.encode(
        '<html><head><meta charset="gbk"></head><body>'
        '<div class="item"><h3><a href="/book/">',
      ),
      0xCA,
      0xE9,
      ...utf8.encode('</a></h3></div></body></html>'),
    ];
    // No Content-Type charset: the frozen path reads the document's meta.
    final server = _WireServer((_) => okBytes(page));
    await server.start();
    try {
      final hits = await HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': server.origin,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      }, HttpSourceTransport()).search('书');
      expect(hits.single.title, '书');
    } finally {
      await server.stop();
    }
  });
}
