import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';

void main() {
  test('dispatcher cancellation closes the actual HTTP connection', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final reached = Completer<void>();
    final disconnected = Completer<Object?>();
    final cancellation = SourceCancellation();
    final socketErrors = <(Object, bool)>[];
    final sinkDone = <Future<void>>[];
    final sockets = <Socket>[];
    final subscription = server.listen((socket) {
      sockets.add(socket);
      // TCP reset is reported independently by the read stream and write sink.
      sinkDone.add(
        socket.done.then<void>(
          (_) {},
          onError: (Object error) {
            socketErrors.add((error, cancellation.isCancelled));
          },
        ),
      );
      socket.listen(
        (data) {
          if (!reached.isCompleted) {
            socket.write(
              'HTTP/1.1 200 OK\r\nContent-Length: 1000\r\n\r\npartial',
            );
            reached.complete();
          }
        },
        onDone: () {
          if (!disconnected.isCompleted) disconnected.complete();
        },
        onError: (Object error) {
          socketErrors.add((error, cancellation.isCancelled));
          if (!disconnected.isCompleted) disconnected.complete(error);
        },
      );
    });
    final dispatcher = SourceHostDispatcher(
      transport: HttpSourceTransport(),
      cancellation: cancellation,
    );
    try {
      final request = dispatcher.connect(
        'http://127.0.0.1:${server.port}/slow',
      );
      // Attach error handling before causing cancellation.
      final cancelled = expectLater(
        request,
        throwsA(isA<SourceRequestCancelled>()),
      );
      await reached.future.timeout(const Duration(seconds: 5));
      cancellation.cancel();
      cancellation.cancel();
      await cancelled;
      await disconnected.future.timeout(const Duration(seconds: 5));
      await expectLater(
        dispatcher.ajax('http://127.0.0.1:${server.port}/later'),
        throwsA(isA<SourceRequestCancelled>()),
      );
      expect(sockets.length, 1);
    } finally {
      for (final socket in sockets) {
        socket.destroy();
      }
      await subscription.cancel();
      await server.close();
      await Future.wait(sinkDone).timeout(const Duration(seconds: 5));
    }
    // A reset after explicit cancellation is a real disconnection, just like
    // EOF. Reject every other socket failure rather than suppressing errors.
    for (final (error, wasCancelled) in socketErrors) {
      expect(wasCancelled, isTrue);
      expect(error, isA<SocketException>());
      expect(
        (error as SocketException).osError?.errorCode,
        isIn([104, 54, 10054]),
      ); // Linux, Darwin, Windows ECONNRESET.
    }
  });

  test('completed cancellation subscriptions can be removed', () {
    final signal = SourceCancellation();
    var calls = 0;
    final remove = signal.listen(() {
      calls++;
    });
    remove();
    signal.cancel();
    expect(calls, 0);
    signal.listen(() {
      calls++;
    });
    expect(calls, 1);
    signal.cancel();
    expect(calls, 1);
  });
}
