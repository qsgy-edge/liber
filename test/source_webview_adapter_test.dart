import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_state.dart';

import 'native_library.dart';

/// One recorded adapter operation, answering with [responseFor] or — when
/// [blocking] is set — never completing until the test answers or destroys it.
class _FakeAdapter implements BookSourceWebViewAdapter {
  _FakeAdapter(this.responseFor, {this.blocking = false});

  final Future<SourceWebViewResponse> Function(SourceWebViewRequest request)
  responseFor;
  final bool blocking;
  final requests = <SourceWebViewRequest>[];
  int destroys = 0;
  Completer<SourceWebViewResponse>? _pending;

  @override
  Future<SourceWebViewResponse> load(SourceWebViewRequest request) {
    requests.add(request);
    if (!blocking) return responseFor(request);
    final completer = Completer<SourceWebViewResponse>();
    _pending = completer;
    return completer.future;
  }

  @override
  void destroy() {
    destroys++;
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const SourceWebViewCancelled());
    }
  }

  @override
  bool get isDisposed => destroys > 0;

  @override
  bool get hasWebView => destroys == 0;
}

class _FakeFactory extends BookSourceWebViewAdapterFactory {
  _FakeFactory(this.adapter, {super.sourceRef = 'http://source.test'});
  final _FakeAdapter adapter;
  @override
  BookSourceWebViewAdapter create() => adapter;
}

/// A transport whose pages the WebView path must not be asked for.
class _Pages implements BookSourceTransport {
  final requests = <String>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    return '<div class="item"><h3><a href="/book/">transport book</a></h3></div>';
  }
}

Map<String, dynamic> _source({String searchUrl = '/search?key={{key}}'}) => {
  'bookSourceUrl': 'https://a.test',
  'bookSourceName': 'webview source',
  'searchUrl': searchUrl,
  'ruleSearch': {
    'bookList': 'class.item',
    'name': 'tag.h3@tag.a@text',
    'bookUrl': 'tag.a@href',
  },
};

const _renderedBook =
    '<div class="item"><h3><a href="/book/">rendered book</a></h3></div>';

void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);
  tearDown(() => BookSourceWebViewAdapterFactory.engineBinding = null);

  test('the WebView path refuses by name where no engine is installed', () {
    final factory = BookSourceWebViewAdapterFactory(sourceRef: 'x');
    // A gate, a tool and a unit test run the model layer on a plain Dart VM,
    // which cannot link the platform plugin; the refusal names that, rather than
    // failing as a null dereference.
    expect(() => factory.create(), throwsA(isA<SourceWebViewUnavailable>()));
    // The per-source, per-host TLS exception is only honoured for the pair it
    // was confirmed for (ADR 0011 §5), and never for an empty host.
    expect(factory.allowsInvalidCertificate('a.test'), isFalse);
    expect(
      BookSourceWebViewAdapterFactory(
        sourceRef: 'http://source.test',
        hostState: SourceHostState(),
      ).allowsInvalidCertificate(''),
      isFalse,
    );
  });

  test('the response keeps the frozen placeholder and synthetic redirect', () {
    expect(
      SourceWebViewResponse.page('not a url', 'body').url,
      'http://localhost/',
    );
    expect(
      SourceWebViewResponse.page('https://a.test/x', 'b').priorCode,
      isNull,
    );
    final redirected = SourceWebViewResponse.redirected(
      pageUrl: 'https://a.test/final',
      originUrl: 'https://a.test/start',
      body: 'b',
    );
    expect(redirected.code, 200);
    expect(redirected.priorCode, 302);
    expect(redirected.priorUrl, 'https://a.test/start');
  });

  test('a stage without the option goes over the transport', () async {
    final adapter = _FakeAdapter(
      (request) async =>
          SourceWebViewResponse.page(request.url!, _renderedBook),
    );
    final transport = _Pages();
    final pipeline = HtmlSourcePipeline(
      _source(),
      transport,
      webViewFactory: _FakeFactory(adapter),
    );
    final hits = await pipeline.search('keyword');
    expect(hits.single.title, 'transport book');
    expect(adapter.requests, isEmpty);
  });

  test('webView:true renders the stage through the adapter', () async {
    final adapter = _FakeAdapter(
      (request) async =>
          SourceWebViewResponse.page(request.url!, _renderedBook),
    );
    final transport = _Pages();
    final pipeline = HtmlSourcePipeline(
      _source(
        searchUrl:
            '/search?key={{key}},{"webView":true,"webJs":"document.title","webViewDelayTime":10}',
      ),
      transport,
      webViewFactory: _FakeFactory(adapter),
    );
    final hits = await pipeline.search('keyword');
    expect(hits.single.title, 'rendered book');
    expect(adapter.requests, hasLength(1));
    final request = adapter.requests.single;
    expect(request.url, 'https://a.test/search?key=keyword');
    expect(request.javaScript, 'document.title');
    expect(request.delayTime, 10);
    // The WebView path replaces the HTTP fetch for that stage, so the transport
    // saw nothing.
    expect(transport.requests, isEmpty);
  });

  test('cancelling a rendered stage destroys the adapter', () async {
    final adapter = _FakeAdapter(
      (request) async =>
          SourceWebViewResponse.page(request.url!, _renderedBook),
      blocking: true,
    );
    final pipeline = HtmlSourcePipeline(
      _source(searchUrl: '/search?key={{key}},{"webView":true}'),
      _Pages(),
      webViewFactory: _FakeFactory(adapter),
    );
    final pending = pipeline.search('keyword');
    await Future<void>.delayed(Duration.zero);
    expect(adapter.requests, hasLength(1));
    pipeline.cancel();
    await expectLater(pending, throwsA(isA<SourceRequestCancelled>()));
    expect(adapter.destroys, greaterThan(0));
  });

  test('java.webView* run through the source-scoped factory', () async {
    final adapter = _FakeAdapter((request) async {
      if (request.sourceRegex != null) {
        return SourceWebViewResponse.page(request.url!, 'https://a.test/res.js');
      }
      if (request.overrideUrlRegex != null) {
        return SourceWebViewResponse.page(request.url!, 'https://a.test/next');
      }
      return SourceWebViewResponse.page(
        request.url ?? 'http://localhost/',
        'rendered:${request.javaScript}',
      );
    });
    final runtime = InProcessSourceScriptRuntime(
      webViewFactory: _FakeFactory(adapter),
    );
    Future<Object?> run(String script) => runtime.evaluate(
      source: script,
      input: {'sourceKey': 'http://source.test'},
      timeout: const Duration(seconds: 5),
    );
    expect(
      await run('java.webView("<html></html>", "https://a.test/page", "1+1")'),
      'rendered:1+1',
    );
    expect(
      await run(
        'java.webViewGetSource(null, "https://a.test/page", null, "res[.]js")',
      ),
      'https://a.test/res.js',
    );
    expect(
      await run(
        'java.webViewGetOverrideUrl(null, "https://a.test/page", null, "next")',
      ),
      'https://a.test/next',
    );
    expect(adapter.requests.first.html, '<html></html>');
    expect(adapter.requests.first.url, 'https://a.test/page');
    expect(adapter.requests[1].sourceRegex, 'res[.]js');
    expect(adapter.requests[2].overrideUrlRegex, 'next');
  });

  test('java.webView refuses by name without a source session', () async {
    final runtime = InProcessSourceScriptRuntime();
    await expectLater(
      runtime.evaluate(
        source: 'java.webView("<html></html>", "https://a.test/page", null)',
        input: {'sourceKey': 'http://source.test'},
        timeout: const Duration(seconds: 5),
      ),
      throwsA(
        predicate(
          (Object? error) =>
              '$error'.contains('webView is unavailable without a source session'),
        ),
      ),
    );
  });

  test('the user-confirmed hatches refuse with the policy category', () async {
    final runtime = InProcessSourceScriptRuntime();
    Future<Object?> run(String script) => runtime.evaluate(
      source: script,
      input: {'sourceKey': 'http://source.test'},
      timeout: const Duration(seconds: 5),
    );
    const members = <String>[
      'java.startBrowser',
      'java.startBrowserAwait',
      'java.getVerificationCode',
      'java.openUrl',
    ];
    for (final member in members) {
      await expectLater(
        run('$member("https://a.test/verify")'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having(
                (error) => error.message,
                'message',
                contains(member),
              ),
        ),
      );
    }
    expect(
      runtime.messages.where((message) => message.kind == 'refused'),
      hasLength(members.length),
    );
  });
}
