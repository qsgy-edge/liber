import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';

import 'package:liber/source/native_library.dart';

import 'native_library.dart';

class ControlledTransport implements SourceHttpTransport {
  final requests = <SourceHttpRequest>[];
  final pending = <Completer<SourceHttpResponse>>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) {
    requests.add(request);
    final completion = Completer<SourceHttpResponse>();
    pending.add(completion);
    return completion.future;
  }

  void finish(int index) => pending[index].complete(
    SourceHttpResponse(
      statusCode: 200 + index,
      headers: {
        'x-index': ['$index'],
      },
      body: 'body-$index',
      url: requests[index].url,
    ),
  );
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  test(
    'cancelling one execution preserves source cookies for the next',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = <String>[];
      final subscription = server.listen((request) async {
        seen.add(request.headers.value('cookie') ?? '');
        request.response.headers.add('set-cookie', 'sid=kept');
        request.response.write('ok');
        await request.response.close();
      });
      try {
        final session = SourceHostDispatcher(transport: HttpSourceTransport());
        final firstToken = SourceCancellation();
        final first = session.forExecution(firstToken);
        final url = 'http://127.0.0.1:${server.port}';
        final response = await first.connect(url);
        expect(response.url.toString(), '$url/');
        expect('${response.url}s.php', '$url/s.php');
        firstToken.cancel();
        await expectLater(
          first.get(url),
          throwsA(isA<SourceRequestCancelled>()),
        );
        await session.forExecution(SourceCancellation()).get(url);
        expect(seen, ['', 'sid=kept']);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'host caps reject input before I/O and bound streamed response',
    () async {
      final transport = ControlledTransport();
      final small = SourceHostDispatcher(
        transport: transport,
        maxRequestBytes: 100,
      );
      await expectLater(
        small.post('http://localhost/', 'x' * 200),
        throwsA(isA<SourceIoLimitExceeded>()),
      );
      expect(transport.requests, isEmpty);
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final subscription = server.listen((request) async {
        request.response.write('x' * 1024);
        await request.response.close();
      });
      try {
        final dispatcher = SourceHostDispatcher(
          transport: HttpSourceTransport(),
          maxResponseBytes: 128,
        );
        await expectLater(
          dispatcher.get('http://127.0.0.1:${server.port}/'),
          throwsA(isA<SourceIoLimitExceeded>()),
        );
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test(
    'connect follows redirects while get/head/post preserve the first response',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final observed = <String>[];
      final subscription = server.listen((request) async {
        observed.add('${request.method} ${request.uri.path}');
        await request.drain<void>();
        if (request.uri.path == '/start') {
          request.response.statusCode = 302;
          request.response.headers.set('location', '/landing/');
        } else {
          request.response.write('landing');
        }
        await request.response.close();
      });
      try {
        final base = 'http://127.0.0.1:${server.port}';
        final dispatcher = SourceHostDispatcher(
          transport: HttpSourceTransport(),
        );
        final connected = await dispatcher.connect('$base/start');
        expect(connected.statusCode, 200);
        expect(connected.body, 'landing');
        expect(connected.url.toString(), '$base/landing/');
        expect(await dispatcher.ajax('$base/start'), 'landing');
        for (final response in [
          await dispatcher.get('$base/start'),
          await dispatcher.head('$base/start'),
          await dispatcher.post('$base/start', 'payload'),
        ]) {
          expect(response.statusCode, 302);
          expect(response.headers['location'], ['/landing/']);
          expect(response.url.toString(), '$base/start');
        }
        expect(observed, [
          'GET /start',
          'GET /landing/',
          'GET /start',
          'GET /landing/',
          'GET /start',
          'HEAD /start',
          'POST /start',
        ]);
      } finally {
        await subscription.cancel();
        await server.close(force: true);
      }
    },
  );

  test('ajaxAll accepts empty input without starting requests', () async {
    final transport = ControlledTransport();
    expect(
      await SourceHostDispatcher(transport: transport).ajaxAll([]),
      isEmpty,
    );
    expect(transport.requests, isEmpty);
  });

  test(
    'ajaxAll bounds admission and preserves full responses in input order',
    () async {
      final transport = ControlledTransport();
      final dispatcher = SourceHostDispatcher(transport: transport);
      final result = dispatcher.ajaxAll(
        ['http://localhost/a', 'http://localhost/b', 'http://localhost/c'],
        concurrency: 2,
        headers: {'X-Batch': 'yes'},
      );
      expect(transport.requests.length, 2);
      expect(transport.requests.first.headers['X-Batch'], 'yes');
      transport.finish(1);
      await Future<void>.delayed(Duration.zero);
      expect(transport.requests.length, 3);
      transport.finish(2);
      transport.finish(0);
      final responses = await result;
      expect(responses.map((r) => r.body), ['body-0', 'body-1', 'body-2']);
      expect(responses.map((r) => r.statusCode), [200, 201, 202]);
      expect(responses[1].headers['x-index'], ['1']);
      expect(responses.map((r) => r.url.path), ['/a', '/b', '/c']);
    },
  );
}
