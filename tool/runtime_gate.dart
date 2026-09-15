import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/js_source_runtime.dart';

Future<void> main(List<String> args) async {
  await InProcessSourceScriptRuntime.initialize(
    libraryPath: args.isEmpty ? null : args.single,
  );
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final reached = Completer<void>();
  final disconnected = Completer<void>();
  final token = SourceCancellation();
  final sinkDone = <Future<void>>[];
  void disconnectedWithError(Object error) {
    if (!token.isCancelled ||
        error is! SocketException ||
        ![104, 54, 10054].contains(error.osError?.errorCode)) {
      throw error;
    }
    if (!disconnected.isCompleted) disconnected.complete();
  }

  final sockets = <Socket>[];
  final subscription = server.listen((socket) {
    sockets.add(socket);
    sinkDone.add(
      socket.done.then<void>((_) {}, onError: disconnectedWithError),
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
      onError: disconnectedWithError,
    );
  });
  final runtime = InProcessSourceScriptRuntime(
    dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
  );
  final checks = <String, bool>{};
  Future<String> category(
    String source, {
    InProcessSourceScriptRuntime? using,
    Map<String, Object?> input = const {},
    Duration timeout = const Duration(seconds: 2),
  }) async {
    try {
      await (using ?? runtime).evaluate(
        source: source,
        input: input,
        timeout: timeout,
      );
      return 'success';
    } on SourceScriptError catch (e) {
      return e.category;
    }
  }

  try {
    checks['syncEcho'] =
        await runtime.evaluate(
          source:
              'JSON.parse(fjs.bridge_call(JSON.stringify({method:"echo",payload:"abc"}))).value.substring(0,2)',
          input: {},
          timeout: const Duration(seconds: 2),
        ) ==
        'ab';
    checks['unknownMethodRefused'] =
        await category(
          'fjs.bridge_call(JSON.stringify({method:"request",payload:{method:"DELETE",url:"http://127.0.0.1:${server.port}/"}}))',
        ) ==
        'host-method';
    checks['unknownMethodNoIo'] = sockets.isEmpty;
    checks['hostErrorSettles'] =
        await category('fjs.bridge_call("invalid-json")') == 'host-input';
    checks['forgedCancellationIsJs'] =
        await category('throw new TypeError("bridge request closed")') == 'js';
    checks['completeInputCapped'] =
        await category('1', input: {'large': 'x' * 70000}) == 'input-cap';
    checks['hostInputCapped'] =
        await category(
          'fjs.bridge_call(JSON.stringify({method:"echo",payload:"x".repeat(200)}))',
          using: InProcessSourceScriptRuntime(maxHostBytes: 100),
        ) ==
        'host-input-cap';
    checks['hostOutputCapped'] =
        await category(
          'fjs.bridge_call(JSON.stringify({method:"echo",payload:1}))',
          using: InProcessSourceScriptRuntime(
            maxHostBytes: 100,
            hostCall: (_, _, _) async => 'x' * 200,
          ),
        ) ==
        'host-output-cap';
    checks['outputCapped'] =
        await category(
          '"x".repeat(200)',
          using: InProcessSourceScriptRuntime(maxOutputBytes: 100),
        ) ==
        'output-cap';
    checks['infiniteLoopTimeout'] =
        await category(
          'while(true) {}',
          timeout: const Duration(milliseconds: 100),
        ) ==
        'timeout';
    final executing = runtime
        .evaluate(
          source: 'java.connect(source.getKey()).body()',
          input: {'sourceKey': 'http://127.0.0.1:${server.port}/slow'},
          timeout: const Duration(seconds: 5),
          cancellation: token,
        )
        .then<Object?>((v) => v, onError: (Object e, StackTrace s) => e);
    await reached.future.timeout(const Duration(seconds: 3));
    token.cancel();
    final result = await executing;
    await disconnected.future.timeout(const Duration(seconds: 3));
    checks['realHttpCancelled'] =
        result is SourceScriptError && result.category == 'cancelled';
    checks['serverDisconnected'] = disconnected.isCompleted;
    checks['nextExecutionWorks'] =
        await runtime.evaluate(
          source: '2+3',
          input: {},
          timeout: const Duration(seconds: 2),
        ) ==
        5;
    final pass = checks.values.every((value) => value);
    stdout.writeln(
      jsonEncode({'status': pass ? 'pass' : 'fail', 'checks': checks}),
    );
    if (!pass) exitCode = 1;
  } finally {
    for (final socket in sockets) {
      socket.destroy();
    }
    await subscription.cancel();
    await server.close();
    await Future.wait(sinkDone).timeout(const Duration(seconds: 3));
    await InProcessSourceScriptRuntime.dispose();
  }
}
