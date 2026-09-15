import 'dart:async';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import '../domain/contracts.dart';
import 'book_source_service.dart';

/// Returns the rendered document, not an HTTP response.
class WindowsWebViewTransport implements BookSourceTransport {
  WindowsWebViewTransport({
    required this.baseUrl,
    this.timeout = const Duration(seconds: 60),
  });
  final Uri baseUrl;
  final Duration timeout;
  final resources = <String>[];
  HeadlessInAppWebView? _webView;
  Completer<String>? _pending;
  bool _reading = false;
  bool _disposed = false;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    if (_disposed) throw StateError('WebView transport is disposed');
    if (_pending != null) throw StateError('A navigation is already running');
    final target = baseUrl.resolve(path);
    if (!['http', 'https'].contains(target.scheme) || target.host.isEmpty) {
      throw ArgumentError.value(target, 'path', 'HTTP(S) URL required');
    }
    final pending = Completer<String>();
    _pending = pending;
    _reading = false;
    final deadline = Timer(timeout, () {
      if (!pending.isCompleted) {
        pending.completeError(
          TimeoutException('WebView navigation timed out', timeout),
        );
      }
    });
    final result = pending.future;
    final webView = HeadlessInAppWebView(
      initialSettings: InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        useShouldInterceptRequest: true,
      ),
      shouldInterceptRequest: (_, request) async {
        resources.add(request.url.toString());
        return null;
      },
      onLoadStop: (controller, url) {
        if (url?.scheme == 'http' || url?.scheme == 'https') {
          unawaited(_readDocument(controller, pending));
        }
      },
      onReceivedHttpError: (controller, request, response) {
        if (request.isForMainFrame != false) {
          unawaited(_readDocument(controller, pending));
        }
      },
      onReceivedError: (_, request, error) {
        if (request.isForMainFrame != false && !pending.isCompleted) {
          pending.completeError(StateError(error.description));
        }
      },
      onReceivedServerTrustAuthRequest: (_, challenge) async {
        if (!pending.isCompleted) {
          pending.completeError(StateError('Untrusted TLS certificate'));
        }
        return ServerTrustAuthResponse(
          action: ServerTrustAuthResponseAction.CANCEL,
        );
      },
    );
    _webView = webView;
    unawaited(_navigate(webView, target, pending));
    try {
      return await result;
    } finally {
      deadline.cancel();
      await Future<void>.delayed(Duration.zero);
      try {
        await webView.dispose();
      } finally {
        _webView = null;
        _pending = null;
      }
    }
  }

  Future<void> _navigate(
    HeadlessInAppWebView webView,
    Uri target,
    Completer<String> pending,
  ) async {
    try {
      await webView.run();
      if (pending.isCompleted || _disposed) return;
      await webView.webViewController!.loadUrl(
        urlRequest: URLRequest(url: WebUri(target.toString())),
      );
    } catch (error, stack) {
      if (!pending.isCompleted) pending.completeError(error, stack);
    }
  }

  Future<void> _readDocument(
    InAppWebViewController controller,
    Completer<String> pending,
  ) async {
    if (pending.isCompleted || _reading || _disposed) return;
    _reading = true;
    try {
      final value = await controller.evaluateJavascript(
        source: 'document.documentElement.outerHTML',
      );
      if (!pending.isCompleted) {
        if (value is String) {
          pending.complete(value);
        } else {
          pending.completeError(StateError('WebView returned no document'));
        }
      }
    } catch (error, stack) {
      if (!pending.isCompleted) pending.completeError(error, stack);
    }
  }

  void cancel() {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(StateError('Navigation cancelled'));
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    cancel();
    if (_pending == null) await _webView?.dispose();
  }
}
