import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/inappwebview_book_source_adapter.dart';

// Native Windows smoke test for the rendered-document path: launch through
// Flutter and drive `BookSourceWebViewAdapter`, never widget-test HTTP. The
// contract-level evidence lives in `tool/webview_oracle/`; this is the quick
// "does the engine work on this machine" check beside it.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  installInAppWebViewBookSourceAdapter();
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
  final base = 'http://127.0.0.1:${server.port}';
  final factory = BookSourceWebViewAdapterFactory(sourceRef: base);
  final adapter = factory.create();
  try {
    for (final path in ['/slow', '/error']) {
      final response = await adapter.load(
        SourceWebViewRequest(url: '$base$path'),
      );
      if (!(response.body ?? '').contains('observed-$path') ||
          !observed.contains(path)) {
        throw StateError('Missing document/server evidence: $path');
      }
    }
    final timed = factory.create();
    try {
      await timed
          .load(SourceWebViewRequest(url: '$base/hang'))
          .timeout(const Duration(seconds: 2));
      throw StateError('Deadline did not stop navigation');
    } on TimeoutException {
      if (!observed.contains('/hang')) {
        throw StateError('Deadline ran before HTTP');
      }
    } finally {
      timed.destroy();
    }
    final cancelling = adapter.load(
      SourceWebViewRequest(url: '$base/slow'),
    );
    adapter.destroy();
    await cancelling.then<void>(
      (_) => throw StateError('Cancelled navigation succeeded'),
      onError: (Object error) {
        if (error is! SourceWebViewCancelled) throw error;
      },
    );
    status.value = 'PASS: rendered DOM, HTTP 503, timeout and cancellation';
    debugPrint(status.value);
  } catch (error, stack) {
    status.value = 'FAIL: $error';
    debugPrint('$error\n$stack');
  } finally {
    adapter.destroy();
    await server.close(force: true);
  }
}
