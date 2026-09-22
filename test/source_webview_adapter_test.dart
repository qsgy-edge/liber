import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart' show SourceChapter;
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/shelf.dart';

import 'native_library.dart';
import 'space_test_support.dart';

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
  _Pages([this.pages]);

  /// Per-path pages; a path that is not listed answers the search page the
  /// single-stage tests use.
  final Map<String, String>? pages;
  final requests = <String>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    return pages?[Uri.parse(path).path] ??
        '<div class="item"><h3><a href="/book/">transport book</a></h3></div>';
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

/// A source whose TOC rule appends `,{…}` options to each chapter address — the
/// idiom imported sources use (`href##$##,{…}`) and the carrier #58 made work.
Map<String, dynamic> _chapterSource(
  String chapterUrlRule, {
  String? nextContentUrl,
}) => {
  'bookSourceUrl': 'https://a.test',
  'bookSourceName': 'chapter webview source',
  'ruleBookInfo': {'name': 'class.title@text', 'tocUrl': 'tag.a@href'},
  'ruleToc': {
    'chapterList': 'class.chapter',
    'chapterName': 'tag.a@text',
    'chapterUrl': chapterUrlRule,
  },
  'ruleContent': {
    'content': 'class.body@text',
    'nextContentUrl': ?nextContentUrl,
  },
};

const _bookPage = '<div class="title">书</div><a href="/toc/1">目录</a>';
const _tocPage = '<div class="chapter"><a href="/chapter/1">第一章</a></div>';
const _renderedChapter = '<div class="body">渲染正文</div>';
const _httpChapter = '<div class="body">纯正文</div>';
const _chapterOptions =
    ',{"webView":true,"webJs":"document.body.innerText","webViewDelayTime":25}';

HtmlBook _chapterHit() =>
    HtmlBook(url: Uri.parse('https://a.test/book/1'), title: '书');

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

  test(
    'a chapter address carrying ,{webView:true} renders the content stage',
    () async {
      final adapter = _FakeAdapter(
        (request) async =>
            SourceWebViewResponse.page(request.url!, _renderedChapter),
      );
      final transport = _Pages({'/book/1': _bookPage, '/toc/1': _tocPage});
      final pipeline = HtmlSourcePipeline(
        _chapterSource('tag.a@href##\$##$_chapterOptions'),
        transport,
        webViewFactory: _FakeFactory(adapter),
      );
      final (_, chapters) = await pipeline.details(_chapterHit());

      // The TOC's own address text is what the chapter carries, options included,
      // and the request target is the resolved URL beside it.
      expect(chapters.single.address, '/chapter/1$_chapterOptions');
      expect('${chapters.single.url}', 'https://a.test/chapter/1');
      expect(chapters.single.options.webView, isTrue);

      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '渲染正文');
      // The content stage is the stage that used the chapter's options, and the
      // request targets the bare URL.
      expect(adapter.requests, hasLength(1));
      expect(adapter.requests.single.url, 'https://a.test/chapter/1');
      expect(adapter.requests.single.javaScript, 'document.body.innerText');
      expect(adapter.requests.single.delayTime, 25);
      expect(transport.requests, isNot(contains('https://a.test/chapter/1')));
    },
  );

  test('a leniently written chapter option tail is applied', () async {
    // `webView:true` and `{'webJs': …}` are what imported sources write; strict
    // JSON rejects both, Gson (and now this reader) accept both.
    final adapter = _FakeAdapter(
      (request) async =>
          SourceWebViewResponse.page(request.url!, _renderedChapter),
    );
    final transport = _Pages({'/book/1': _bookPage, '/toc/1': _tocPage});
    final pipeline = HtmlSourcePipeline(
      _chapterSource("tag.a@href##\$##,{webView:true,webJs:'document.title'}"),
      transport,
      webViewFactory: _FakeFactory(adapter),
    );
    final (_, chapters) = await pipeline.details(_chapterHit());
    await pipeline.chapter(chapters.single);

    expect(adapter.requests.single.javaScript, 'document.title');
  });

  test('an unreadable chapter option tail fetches the bare URL', () async {
    // A tail the reader cannot read applies no option instead of failing the
    // chapter, the frozen `AnalyzeUrl.kt:222` behaviour.
    final adapter = _FakeAdapter(
      (request) async => throw StateError('the WebView path must not run'),
    );
    final transport = _Pages({
      '/book/1': _bookPage,
      '/toc/1': _tocPage,
      '/chapter/1': _httpChapter,
    });
    final pipeline = HtmlSourcePipeline(
      _chapterSource('tag.a@href##\$##,{webView:'),
      transport,
      webViewFactory: _FakeFactory(adapter),
    );
    final (_, chapters) = await pipeline.details(_chapterHit());
    final body = await pipeline.chapter(chapters.single);

    expect(body.text, '纯正文');
    expect(transport.requests, contains('https://a.test/chapter/1'));
    expect(adapter.requests, isEmpty);
  });

  test(
    'a chapter address without options keeps the HTTP content request',
    () async {
      final adapter = _FakeAdapter(
        (request) async => throw StateError('the WebView path must not run'),
      );
      final transport = _Pages({
        '/book/1': _bookPage,
        '/toc/1': _tocPage,
        '/chapter/1': _httpChapter,
      });
      final pipeline = HtmlSourcePipeline(
        _chapterSource('tag.a@href'),
        transport,
        webViewFactory: _FakeFactory(adapter),
      );
      final (_, chapters) = await pipeline.details(_chapterHit());
      expect(chapters.single.address, '/chapter/1');
      expect(chapters.single.options.webView, isFalse);
      // No option at all: the request is the one this stage has always made
      // (`SourceUrlOptions(retry: 0)` was every field's default).
      final options = chapters.single.options;
      expect(options.method, 'GET');
      expect(options.headers, isEmpty);
      expect(options.body, isNull);
      expect(options.retry, 0);
      expect(options.charset, isNull);
      expect(options.webJs, isNull);
      expect(options.webViewDelayTime, 0);

      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '纯正文');
      expect(transport.requests, contains('https://a.test/chapter/1'));
      expect(adapter.requests, isEmpty);
    },
  );


  test('a chapter address option family this product lacks is refused by name', () async {
    // Nothing is silently dropped: the families the TOC guard cannot express
    // keep their named refusal, at the same place (#58).
    final pipeline = HtmlSourcePipeline(
      _chapterSource('tag.a@href##\$##,{"body":"a=1"}'),
      _Pages({'/book/1': _bookPage, '/toc/1': _tocPage}),
    );
    await expectLater(
      pipeline.details(_chapterHit()),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('章节地址的 URL 选项'),
        ),
      ),
    );
  });
  test(
    'a chapter address survives the shelf and comes back with its options',
    () async {
      final space = await TestSpace.create();
      try {
        final shelf = ShelfService(space.store);
        final adapter = _FakeAdapter(
          (request) async =>
              SourceWebViewResponse.page(request.url!, _renderedChapter),
        );
        final source = _chapterSource('tag.a@href##\$##$_chapterOptions');

        // The TOC's chapters are what the shelf writes; after that the rows are
        // the only carrier left.
        final first = HtmlSourcePipeline(
          source,
          _Pages({'/book/1': _bookPage, '/toc/1': _tocPage}),
          webViewFactory: _FakeFactory(adapter),
        );
        final (detail, chapters) = await first.details(_chapterHit());
        await shelf.add(source, detail, chapters);

        // A restart: a new store handle, a fresh pipeline, the stored rows only.
        final store = await space.reopen();
        final entry = (await ShelfService(
          store,
        ).find('https://a.test', '${detail.url}'))!;
        final row = entry.chapters.single;
        expect(row.chapterKey, 'https://a.test/chapter/1');
        expect(row.url, 'https://a.test/chapter/1$_chapterOptions');

        // The chapter the row describes keeps its options, and the content stage
        // of a fresh pipeline renders through the adapter because of them.
        final rebuilt = SourceChapter.fromAddress(
          row.name,
          row.url ?? row.chapterKey,
        );
        expect(rebuilt.options.webView, isTrue);
        final second = HtmlSourcePipeline(
          source,
          _Pages({'/chapter/1': _httpChapter}),
          webViewFactory: _FakeFactory(adapter),
        );
        final body = await second.chapter(rebuilt);
        expect(body.text, '渲染正文');
        expect(adapter.requests, hasLength(1));
        expect(adapter.requests.single.url, 'https://a.test/chapter/1');
        expect(adapter.requests.single.javaScript, 'document.body.innerText');
        expect(adapter.requests.single.delayTime, 25);
      } finally {
        await space.delete();
      }
    },
  );

  test('a next content page applies its own address options', () async {
    final adapter = _FakeAdapter(
      (request) async => SourceWebViewResponse.page(
        request.url!,
        '<div class="body">第二页渲染</div>',
      ),
    );
    final transport = _Pages({
      '/book/1': _bookPage,
      '/toc/1': _tocPage,
      '/chapter/1':
          '<div class="body">第一页</div>'
          '<a class="next" href="/chapter/2,{&quot;webView&quot;:true}">下一页</a>',
      '/chapter/2': '<div class="body">第二页纯 HTTP</div>',
    });
    final pipeline = HtmlSourcePipeline(
      _chapterSource('tag.a@href', nextContentUrl: 'class.next@href'),
      transport,
      webViewFactory: _FakeFactory(adapter),
    );
    final (_, chapters) = await pipeline.details(_chapterHit());
    final body = await pipeline.chapter(chapters.single);

    expect(body.pages, 2);
    expect(body.text, '第一页\n第二页渲染');
    expect(adapter.requests.single.url, 'https://a.test/chapter/2');
    expect(transport.requests, isNot(contains('https://a.test/chapter/2')));
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
        return SourceWebViewResponse.page(
          request.url!,
          'https://a.test/res.js',
        );
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
          (Object? error) => '$error'.contains(
            'webView is unavailable without a source session',
          ),
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
              .having((error) => error.message, 'message', contains(member)),
        ),
      );
    }
    expect(
      runtime.messages.where((message) => message.kind == 'refused'),
      hasLength(members.length),
    );
  });
}
