import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_http_uri.dart';

import 'package:liber/source/native_library.dart';

import 'native_library.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  test(
    'wire targets preserve literal brackets and redirect header isolation',
    () async {
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final seen = <String>[];
      final headersSeen = <String>[];
      final sockets = <Socket>{};
      server.listen((socket) {
        sockets.add(socket);
        var header = '';
        var sent = false;
        socket.listen(
          (bytes) {
            if (sent) return;
            header += ascii.decode(bytes);
            if (!header.contains('\r\n\r\n')) return;
            sent = true;
            seen.add(header.split('\r\n').first);
            headersSeen.add(header.toLowerCase());
            final path = header.split(' ')[1];
            final redirect = path == '/redirect' || path == '/cross';
            final location = path == '/cross'
                ? 'http://localhost:${server.port}/next[]'
                : '/next[]';
            socket.add(
              ascii.encode(
                redirect
                    ? 'HTTP/1.1 303 See Other\r\nLocation: $location\r\nContent-Length: 0\r\nConnection: close\r\n\r\n'
                    : 'HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok',
              ),
            );
            unawaited(socket.close());
          },
          onDone: () {
            sockets.remove(socket);
          },
        );
      });
      try {
        final host = SourceHostDispatcher(transport: HttpSourceTransport());
        await host.ajax('$origin/a[]/%5B%5D?q=[]&escaped=%5B%5D#ignored');
        expect(seen.last, 'GET /a[]/%5B%5D?q=[]&escaped=%5B%5D HTTP/1.1');
        await host.ajax('$origin/redirect');
        expect(seen.sublist(1), [
          'GET /redirect HTTP/1.1',
          'GET /next[] HTTP/1.1',
        ]);
        await host.request(
          'POST',
          '$origin/cross',
          body: 'body',
          headers: {
            'Authorization': 'test-value',
            'Cookie': 'test=value',
            'X-Source': 'kept',
          },
        );
        expect(seen.sublist(3), [
          'POST /cross HTTP/1.1',
          'GET /next[] HTTP/1.1',
        ]);
        expect(headersSeen.last, isNot(contains('authorization:')));
        expect(headersSeen.last, isNot(contains('cookie:')));
        expect(headersSeen.last, contains('x-source: kept'));
        await host.ajax('$origin/%0D%0Ainjected:value[]');
        expect(seen.last, 'GET /%0D%0Ainjected:value[] HTTP/1.1');
      } finally {
        await server.close();
        for (final socket in sockets.toList()) {
          socket.destroy();
        }
      }
    },
  );

  test('resolution retains escaped/literal distinction and IPv6 authority', () {
    final base = SourceHttpUri.parse('http://[::1]:8080/a[]/start?old=[]#gone');
    expect(base.host, '::1');
    expect(
      base.resolve('../%5Bkeep%5D/next[]?q=[]').toString(),
      'http://[::1]:8080/%5Bkeep%5D/next[]?q=[]',
    );
    expect(base.removeFragment().path, '/a[]/start');
    expect(base.pathSegments, ['a[]', 'start']);
    expect(base.queryParameters['old'], '[]');
    final collision = SourceHttpUri.parse(
      'http://localhost/%6CiberBracket0L/[]',
    );
    expect(collision.path, '/liberBracket0L/[]');
    expect(
      SourceHttpUri.parse(
        'relative[]',
      ).replace(scheme: 'http', host: 'example.com').toString(),
      'http://example.com/relative[]',
    );
  });
}
