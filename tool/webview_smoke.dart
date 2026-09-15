import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/windows_webview_transport.dart';

// Native Windows smoke test: launch through Flutter, never widget-test HTTP.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final status = ValueNotifier<String>('Running WebView2 checks');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: ValueListenableBuilder(
            valueListenable: status,
            builder: (_, value, _) => Text(value),
          ),
        ),
      ),
    ),
  );
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final observed = <String>[];
  server.listen((request) async {
    observed.add(request.uri.path);
    if (request.uri.path == '/slow') {
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    if (request.uri.path == '/hang') {
      await Future<void>.delayed(const Duration(seconds: 4));
    }
    request.response.headers.contentType = ContentType.html;
    if (request.uri.path == '/error') request.response.statusCode = 503;
    request.response.write(
      '<html><body>observed-${request.uri.path}</body></html>',
    );
    try {
      await request.response.close();
    } on IOException {
      /* cancellation */
    }
  });
  final transport = WindowsWebViewTransport(
    baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
    timeout: const Duration(seconds: 10),
  );
  try {
    for (final path in ['/slow', '/error']) {
      final html = await transport.request(
        stage: BookSourceStage.content,
        path: path,
      );
      if (!html.contains('observed-$path') ||
          !observed.contains(path) ||
          !transport.resources.any((url) => Uri.parse(url).path == path)) {
        throw StateError(
          'Missing document/server/interception evidence: $path',
        );
      }
    }
    final timed = WindowsWebViewTransport(
      baseUrl: Uri.parse('http://127.0.0.1:${server.port}'),
      timeout: const Duration(seconds: 2),
    );
    try {
      await timed.request(stage: BookSourceStage.content, path: '/hang');
      throw StateError('Deadline did not stop navigation');
    } on TimeoutException {
      if (!observed.contains('/hang')) {
        throw StateError('Deadline ran before HTTP');
      }
    } finally {
      await timed.dispose();
    }
    final cancelling = transport.request(
      stage: BookSourceStage.content,
      path: '/slow',
    );
    final cancellationCheck = cancelling.then<void>(
      (_) => throw StateError('Cancelled navigation succeeded'),
      onError: (Object error) {
        if (!error.toString().contains('Navigation cancelled')) throw error;
      },
    );
    transport.cancel();
    await cancellationCheck;
    status.value =
        'PASS: delayed DOM, HTTP 503, interception, timeout and cancellation';
    debugPrint(status.value);
  } catch (error, stack) {
    status.value = 'FAIL: $error';
    debugPrint('$error\n$stack');
  } finally {
    await transport.dispose();
    await server.close(force: true);
  }
}
