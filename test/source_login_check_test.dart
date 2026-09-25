import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_http_uri.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/workspace.dart';

import 'native_library.dart';

import 'temp_directory.dart';

/// One answer of a fixture path: the status it is sent with and its body.
class _Page {
  const _Page(this.body, {this.status = 200});
  final String body;
  final int status;
}

/// One request the fixture site saw, so a test asserts the wire — the method,
/// the target, the headers and the body bytes — and not only the extracted
/// text.
class _Seen {
  _Seen(this.method, this.target, this.headers, this.body);
  final String method;
  final String target;
  final Map<String, String> headers;
  final List<int> body;

  String get path => Uri.parse(target).path;
  String get query => Uri.parse(target).query;
}

/// A fixture site: each path answers with the next page of its queue and
/// repeats the last one, so a page can be gated, and every request is recorded.
class _Site {
  _Site._(this._server, this.pages);

  static Future<_Site> start(Map<String, List<_Page>> pages) async {
    final site = _Site._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      pages,
    );
    site._server.listen(site._handle);
    return site;
  }

  final HttpServer _server;
  final Map<String, List<_Page>> pages;
  final seen = <_Seen>[];

  /// Response headers every answer carries.
  final headers = <String, String>{};

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    final recorded = <String, String>{};
    request.headers.forEach(
      (name, values) => recorded[name] = values.join(', '),
    );
    seen.add(_Seen(request.method, request.uri.toString(), recorded, bytes));
    for (final header in headers.entries) {
      request.response.headers.add(header.key, header.value);
    }
    final queue = pages[request.uri.path];
    if (queue == null || queue.isEmpty) {
      request.response.statusCode = 404;
      request.response.write('not found');
    } else {
      final page = queue.length > 1 ? queue.removeAt(0) : queue.first;
      request.response.statusCode = page.status;
      request.response.write(page.body);
    }
    await request.response.close();
  }
}

/// The 第一版主 226 shape, against the fixture's own origin: the gate page names
/// the 1234 verification, the check POSTs the verification address with its
/// `,{…}` option tail, and re-requests the stage URL.
String _gateCheck(String origin, {String body = 'action=1&v=1234'}) => '''
var body = result.body();
if (body.indexOf('1234') > -1) {
  java.ajax('$origin/verify,' + JSON.stringify({charset: 'gbk', method: 'POST', body: '$body'}));
  result = java.getStrResponse();
}
result;
''';

/// The same gate without the verification POST: the check only re-requests the
/// stage it is running on, so a boundary test asserts the replacement alone.
const _reRequestOnGate = '''
if (result.body().indexOf('1234') > -1) { result = java.getStrResponse(); }
result;
''';

const _gatePage = '<div class="gate">请完成验证 1234</div>';
const _gateJson = '{"gate":"请完成验证 1234"}';

Map<String, dynamic> _htmlSource(
  String origin, {
  String checkJs = '',
  String loginUrl = '',
  String searchUrl = '/search?key={{key}}',
}) => {
  'bookSourceUrl': origin,
  'bookSourceName': '登录检查源',
  if (loginUrl.isNotEmpty) 'loginUrl': loginUrl,
  if (checkJs.isNotEmpty) 'loginCheckJs': checkJs,
  'searchUrl': searchUrl,
  'ruleSearch': {
    'bookList': 'div.item',
    'name': 'h3 a@text',
    'bookUrl': 'h3 a@href',
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'tocUrl': 'a.toc@href',
    'canReName': 'true',
  },
  'ruleToc': {'chapterList': 'li', 'chapterName': 'a@text', 'chapterUrl': 'a@href'},
  'ruleContent': {'content': '#content@text'},
};

Map<String, dynamic> _jsonSource(String origin, String checkJs) => {
  'bookSourceUrl': origin,
  'bookSourceName': 'JSON 登录检查源',
  'loginCheckJs': checkJs,
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {'bookList': r'$.items', 'name': r'$.name', 'bookUrl': r'$.url'},
  'ruleBookInfo': {
    'name': r'$.name',
    'tocUrl': r'$.toc',
    'canReName': 'true',
  },
  'ruleToc': {
    'chapterList': r'$.items',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
  'ruleContent': {'content': r'$.text'},
};

/// The fixture pages of one HTML source: every stage is gated first and answers
/// the page its rules read on the request the check makes.
Map<String, List<_Page>> _htmlPages() => {
  '/search': [
    const _Page(_gatePage),
    const _Page('<div class="item"><h3><a href="/book/">书</a></h3></div>'),
  ],
  '/book/': [
    const _Page(_gatePage),
    const _Page('<h1>书名</h1><a class="toc" href="/toc">目录</a>'),
  ],
  '/toc': [
    const _Page(_gatePage),
    const _Page('<ul><li><a href="/chapter/1">第一章</a></li></ul>'),
  ],
  '/chapter/1': [
    const _Page(_gatePage),
    const _Page('<div id="content">正文</div>'),
  ],
  '/verify': [const _Page('ok')],
};

/// The same pages without any gate: the fixture a source with no hook reads.
Map<String, List<_Page>> _ungatedPages() => {
  for (final entry in _htmlPages().entries)
    entry.key: [entry.value.last],
};

Map<String, List<_Page>> _jsonPages() => {
  '/search': [
    const _Page(_gateJson),
    const _Page('{"items":[{"name":"书","url":"/book"}]}'),
  ],
  '/book': [
    const _Page(_gateJson),
    const _Page('{"name":"书名","toc":"/toc"}'),
  ],
  '/toc': [
    const _Page(_gateJson),
    const _Page('{"items":[{"name":"第一章","url":"/chapter/1"}]}'),
  ],
  '/chapter/1': [
    const _Page(_gateJson),
    const _Page('{"text":"正文"}'),
  ],
  '/verify': [const _Page('ok')],
};

BookSourcePipeline _pipeline(
  Map<String, dynamic> source, {
  SourceHostState? state,
  void Function(SourceHostMessage message)? onHostMessage,
}) => openBookSourcePipeline(
  source,
  HttpSourceTransport(),
  hostState: state ?? SourceHostState(),
  onHostMessage: onHostMessage,
);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('loginCheckJs runs at each stage boundary', () {
    test('the search rules read the response the check returned', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: _reRequestOnGate),
      );
      final hits = await pipeline.search('书');
      // The gate page carries no `div.item`; the book only exists in the
      // response the check returned, so the rules ran on the replacement.
      expect(hits.single.title, '书');
      expect(site.seen.map((request) => '${request.method} ${request.path}'), [
        'GET /search',
        'GET /search',
      ]);
      expect(site.seen.first.query, 'key=%E4%B9%A6');
      // The check's re-request is a request this stage made, and the trace says
      // so.
      expect(pipeline.trace.map((entry) => entry.stage), [
        BookSourceStage.search,
        BookSourceStage.search,
      ]);
    });

    test('the book information rules read the response the check returned', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final source = _htmlSource(site.origin, checkJs: _reRequestOnGate);
      final pipeline = _pipeline(source);
      final hits = await pipeline.search('书');
      final (book, _) = await pipeline.details(hits.single);
      // `/book/` answered the gate first; only its second response carries the
      // title the rule reads.
      expect(book.title, '书名');
      expect(
        site.seen.map((request) => '${request.method} ${request.path}').take(4),
        ['GET /search', 'GET /search', 'GET /book/', 'GET /book/'],
      );
    });

    test('the table-of-contents rules read the response the check returned', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: _reRequestOnGate),
      );
      final hits = await pipeline.search('书');
      final (_, chapters) = await pipeline.details(hits.single);
      // The gate page carries no `li`: an empty list would fail the stage, so
      // the chapter list is the replacement's.
      expect(chapters.single.name, '第一章');
      expect(
        site.seen.map((request) => '${request.method} ${request.path}'),
        [
          'GET /search',
          'GET /search',
          'GET /book/',
          'GET /book/',
          'GET /toc',
          'GET /toc',
        ],
      );
    });

    test('the content rules read the response the check returned', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: _reRequestOnGate),
      );
      final hits = await pipeline.search('书');
      final (_, chapters) = await pipeline.details(hits.single);
      final body = await pipeline.chapter(chapters.single);
      // The gate page has no `#content`, so the text is the replacement's.
      expect(body.text, '正文');
      expect(site.seen.last.method, 'GET');
      expect(site.seen.last.path, '/chapter/1');
      expect(
        site.seen.where((request) => request.path == '/chapter/1'),
        hasLength(2),
      );
    });

    test('the JSON pipeline reads the replacement at all four boundaries', () async {
      final site = await _Site.start(_jsonPages());
      addTearDown(site.close);
      final pipeline = _pipeline(_jsonSource(site.origin, _reRequestOnGate));
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      final (book, chapters) = await pipeline.details(hits.single);
      expect(book.title, '书名');
      expect(chapters.single.name, '第一章');
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '正文');
      // Every stage answered its gate first and the response the check made
      // second, so each pair of requests is the hook's own work.
      expect(site.seen.map((request) => request.path), [
        '/search',
        '/search',
        '/book',
        '/book',
        '/toc',
        '/toc',
        '/chapter/1',
        '/chapter/1',
      ]);
    });
  });

  group('the response surface a check script uses', () {
    test(
      'the 第一版主 226 shape POSTs the verification address and re-requests the stage',
      () async {
        final site = await _Site.start(_htmlPages());
        addTearDown(site.close);
        final pipeline = _pipeline(
          _htmlSource(site.origin, checkJs: _gateCheck(site.origin)),
        );
        final hits = await pipeline.search('书');
        expect(hits.single.title, '书');
        // The POST and the re-request are what the server saw, in order.
        expect(site.seen.map((request) => '${request.method} ${request.path}'), [
          'GET /search',
          'POST /verify',
          'GET /search',
        ]);
        final post = site.seen[1];
        expect(post.body, utf8.encode('action=1&v=1234'));
        expect(
          post.headers['content-type'],
          'application/x-www-form-urlencoded; charset=utf-8',
        );
        // The stage URL is re-requested with its own method, so the second
        // request is the search address again and not the verification one.
        expect(site.seen.last.target, site.seen.first.target);
      },
    );

    test(
      'java.ajax honours a URL option tail: method, body, charset and headers',
      () async {
        final site = await _Site.start({
          ..._htmlPages(),
          // The retry option's answer: a non-2xx attempt and then the page.
          '/retry': [const _Page('busy', status: 500), const _Page('ok')],
        });
        addTearDown(site.close);
        final check = '''
var body = result.body();
if (body.indexOf('1234') > -1) {
  java.ajax('${site.origin}/charset,' + JSON.stringify({
    charset: 'gbk', method: 'POST', body: 'v=书', headers: {'X-Option': 'yes'}
  }));
  java.ajax('${site.origin}/retry,' + JSON.stringify({retry: 1, method: 'POST', body: 'r=1'}));
  result = java.getStrResponse();
}
result;
''';
        final pipeline = _pipeline(
          _htmlSource(site.origin, checkJs: check),
        );
        final hits = await pipeline.search('书');
        expect(hits.single.title, '书');
        final charset = site.seen[1];
        expect(charset.method, 'POST');
        expect(charset.path, '/charset');
        // `v=书` with the declared GBK charset: 书 is CA E9 in GBK, where UTF-8
        // would write E4 B9 A6.
        expect(utf8.decode(charset.body), 'v=%CA%E9');
        expect(charset.headers['x-option'], 'yes');
        // The retry option allowed the second attempt the 500 needed.
        expect(
          site.seen.where((request) => request.path == '/retry'),
          hasLength(2),
        );
      },
    );

    test('java.ajaxAll applies each URL its own option tail', () async {
      final site = await _Site.start({
        ..._htmlPages(),
        '/verify2': [const _Page('ok')],
      });
      addTearDown(site.close);
      final check = '''
var body = result.body();
if (body.indexOf('1234') > -1) {
  java.ajaxAll([
    '${site.origin}/verify,' + JSON.stringify({method: 'POST', body: 'a=1'}),
    '${site.origin}/verify2,' + JSON.stringify({method: 'POST', body: 'b=2'})
  ]);
  result = java.getStrResponse();
}
result;
''';
      final pipeline = _pipeline(_htmlSource(site.origin, checkJs: check));
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      // One `AnalyzeUrl` per URL (`JsExtensions.kt:111-125`): each entry keeps
      // its own method and body. `ajaxAll` issues the URLs together, so the
      // order the server *sees* them in is not a guarantee and is not asserted
      // here (it has been observed reversed on CI): what the frozen fixes is the
      // returned array's order, pinned by the host-surface gate's
      // `ajaxAllReturnsOrderedResponses` row, and the per-URL option tail, which
      // is asserted by path below.
      final posts = site.seen.where((request) => request.method == 'POST');
      expect(posts, hasLength(2));
      expect({
        for (final request in posts) request.path: utf8.decode(request.body),
      }, {'/verify': 'a=1', '/verify2': 'b=2'});
    });

    test('the hook sees a rendered document and may re-render it', () async {
      final adapter = _RenderedAdapter(
        '<div class="item"><h3><a href="/book/">书</a></h3></div>',
      );
      final state = SourceHostState();
      final source = _htmlSource(
        'http://source.test',
        checkJs: '''
cache.put('wv-code', result.code());
cache.put('wv-headers', JSON.stringify(result.headers()));
cache.put('wv-url', result.url());
result = java.getStrResponse();
result;
''',
      );
      source['searchUrl'] = '/search,{"webView":true}';
      final pipeline = HtmlSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
        webViewFactory: _RenderedFactory(adapter),
      );
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      // The frozen WebView response is the synthetic `StrResponse(url, body)`:
      // status 200 with no headers of its own.
      expect(await state.entry('http://source.test', 'wv-code'), 200);
      expect(await state.entry('http://source.test', 'wv-headers'), '{}');
      expect(
        await state.entry('http://source.test', 'wv-url'),
        'http://source.test/search',
      );
      // The stage rendered once, the check's re-request rendered again, and the
      // rules read the second document.
      expect(adapter.requests, hasLength(2));
    });

    test(
      'the pixiv shape reads a response header and re-requests with getStrResponse(null, null)',
      () async {
        final site = await _Site.start(_htmlPages());
        addTearDown(site.close);
        site.headers['x-userid'] = '12345';
        final state = SourceHostState();
        final check = '''
var uid = java.getResponse().headers().get('x-userid');
cache.put('pixiv-user', uid);
cache.put('pixiv-code', java.getResponse().code());
result = java.getStrResponse(null, null);
result;
''';
        final pipeline = _pipeline(
          _htmlSource(site.origin, checkJs: check),
          state: state,
        );
        final hits = await pipeline.search('书');
        expect(hits.single.title, '书');
        expect(
          await state.entry(site.origin, 'pixiv-user'),
          '12345',
          reason: 'headers().get(name) is case-insensitive, like OkHttp Headers',
        );
        expect(await state.entry(site.origin, 'pixiv-code'), 200);
        // Each member repeats the stage URL: getResponse() twice and
        // getStrResponse(null, null) once, on top of the stage's own request,
        // and only the last response replaces the stage's.
        expect(
          site.seen.where((request) => request.path == '/search'),
          hasLength(4),
        );
      },
    );

    test('the 笔趣阁 shape clears the jar and returns the response unchanged', () async {
      final site = await _Site.start({
        '/search': [
          const _Page(
            '<div class="item"><h3><a href="/book/">书</a></h3></div>',
          ),
        ],
      });
      addTearDown(site.close);
      site.headers['set-cookie'] = 'qbi=1; Path=/';
      final state = SourceHostState();
      final check = '''
cache.put('qbi-before', cookie.getCookie(source.getKey()));
cookie.removeCookie(source.getKey());
cache.put('qbi-after', cookie.getCookie(source.getKey()));
result;
''';
      final source = _htmlSource(site.origin, checkJs: check)
        ..['enabledCookieJar'] = true;
      final pipeline = _pipeline(source, state: state);
      final hits = await pipeline.search('书');
      // The check returned the response it was handed: the first page's own
      // rules read it, and no second request was made.
      expect(hits.single.title, '书');
      expect(site.seen, hasLength(1));
      expect(await state.entry(site.origin, 'qbi-before'), 'qbi=1');
      expect(await state.entry(site.origin, 'qbi-after'), '');
    });

    for (final json in [false, true]) {
      test('reopened relative ${json ? 'JSON' : 'HTML'} chapter reanalysis keeps its book base', () async {
        final site = await _Site.start({
          '/book/chapter/2': [
            _Page(json ? _gateJson : _gatePage),
            _Page(json ? '{"text":"正文"}' : '<div id="content">正文</div>'),
          ],
        });
        addTearDown(site.close);
        const check = '''
if (result.body().indexOf('1234') > -1) {
  java.initUrl();
  result = java.getStrResponse();
}
result;
''';
        final source = json
            ? _jsonSource(site.origin, check)
            : _htmlSource(site.origin, checkJs: check);
        final pipeline = _pipeline(source);
        final book = HtmlBook(url: Uri.parse('${site.origin}/book/1'), title: '书');
        final chapter = SourceChapter.fromAddress(
          '第二章',
          'chapter/2,{"webView":false}',
          bookUrl: book.url,
          chapterKey: 'chapter/2,{"webView":false}',
        );
        expect((await pipeline.chapter(chapter, book: book)).text, '正文');
        expect(site.seen.map((request) => request.path), [
          '/book/chapter/2',
          '/book/chapter/2',
        ]);
        expect(chapter.progressKey, 'chapter/2,{"webView":false}');
      });
    }

    test('the 🔞🔲第一版主 shape re-runs the address analysis with initUrl', () async {
      final site = await _Site.start({
        '/search': [
          const _Page('<div class="gate">请完成验证 1234</div>'),
          const _Page('<div class="item"><h3><a href="/book/">书</a></h3></div>'),
        ],
      });
      addTearDown(site.close);
      final check = '''
var vars = JSON.parse(source.getVariable() || '{}');
if (!vars.token) {
  vars.token = 'T1';
  vars.url = result.url();
  source.setVariable(JSON.stringify(vars));
  java.initUrl();
  result = java.getStrResponse();
}
result;
''';
      final pipeline = _pipeline(
        _htmlSource(
          site.origin,
          checkJs: check,
          searchUrl: '/search?key={{key}}&token={{JSON.parse(source.getVariable() || "{}").token || ""}}',
        ),
      );
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      // The first request ran on the address before the check, the second on
      // the address the re-analysis produced from the variable it wrote.
      expect(
        site.seen.map((request) => request.query),
        ['key=%E4%B9%A6&token=', 'key=%E4%B9%A6&token=T1'],
      );
      expect(
        await SourceHostState().entry(site.origin, 'sourceVariable_${site.origin}'),
        isNull,
        reason: 'a fresh state reads nothing the check wrote through the pipeline',
      );
    });
  });

  group('a loginCheckJs source opens like any other', () {
    test('a bare-URL loginUrl is carried and the stages work unchanged', () async {
      final site = await _Site.start(_ungatedPages());
      addTearDown(site.close);
      final pipeline = _pipeline(
        _htmlSource(site.origin, loginUrl: '${site.origin}/user/login'),
      );
      // No hook: every request is the stage's own.
      final hits = await pipeline.search('书');
      final (book, chapters) = await pipeline.details(hits.single);
      final body = await pipeline.chapter(chapters.single);
      expect(hits.single.title, '书');
      expect(book.title, '书名');
      expect(chapters.single.name, '第一章');
      expect(body.text, '正文');
      expect(site.seen, hasLength(4));
    });

    test('a check script that throws fails the stage and is visible in the log', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final notices = <SourceHostMessage>[];
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: 'throw new Error("gate failed");'),
        onHostMessage: notices.add,
      );
      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'js')
              .having((error) => error.message, 'message', contains('gate failed')),
        ),
      );
      // The failure is what the source log and the source's notices carry.
      expect(notices, hasLength(1));
      expect(notices.single.kind, 'loginCheckJs');
      expect(notices.single.message, contains('gate failed'));
    });

    test('a value that is not a response fails the stage like the frozen cast', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: 'result.body()'),
      );
      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            contains('must return a response object'),
          ),
        ),
      );
    });

    test('a webView tail on java.ajax refuses by name', () async {
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final check = '''
var body = result.body();
if (body.indexOf('1234') > -1) {
  java.ajax('${site.origin}/verify,' + JSON.stringify({webView: true}));
}
result;
''';
      final pipeline = _pipeline(
        _htmlSource(site.origin, checkJs: check),
      );
      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having(
                (error) => error.message,
                'member',
                contains('java.ajax(url, {…})'),
              )
              .having((error) => error.message, 'policy', contains('webView')),
        ),
      );
    });
  });

  group('source.setVariable / getVariable', () {
    test('lands in the source\'s own cache entry and a null deletes it', () async {
      final runtime = InProcessSourceScriptRuntime();
      await runtime.evaluate(
        source: '''
source.setVariable(JSON.stringify({token: 'T1'}));
var first = source.getVariable();
source.setVariable('plain');
var second = source.getVariable();
source.setVariable(null);
JSON.stringify([first, second, source.getVariable()]);
''',
        input: {
          'sourceKey': 'https://a.test/source',
          'source': {'bookSourceUrl': 'https://a.test/source'},
        },
        timeout: const Duration(seconds: 15),
      );
      expect(
        await runtime.hostState.entry(
          'https://a.test/source',
          'sourceVariable_https://a.test/source',
        ),
        isNull,
        reason: 'setVariable(null) deletes the entry, as frozen does',
      );
    });

    test('round-trips across two analyses and a restart', () async {
      final root = await Directory.systemTemp.createTemp('liber-59-login-');
      addTearDown(() => deleteTempDirectory(root));
      final site = await _Site.start(_htmlPages());
      addTearDown(site.close);
      final source = _htmlSource(
        site.origin,
        checkJs: '''
var vars = JSON.parse(source.getVariable() || '{}');
vars.visits = (vars.visits || 0) + 1;
source.setVariable(JSON.stringify(vars));
result;
''',
      );

      final workspace = await Workspace.open(root: root);
      final store = await workspace.openSpace();
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      await _pipeline(source, state: state).search('书');
      await _pipeline(source, state: state).search('书');
      await workspace.close();

      // The process ends here; the same space file is opened again, and a fresh
      // pipeline reads what the check wrote.
      final reopened = await Workspace.open(root: root);
      final store2 = await reopened.openSpace();
      final restarted = SourceHostState(
        persistence: SpaceHostStatePersistence(store2),
      );
      expect(
        jsonDecode(
          '${await restarted.entry(site.origin, 'sourceVariable_${site.origin}')}',
        ),
        {'visits': 2},
      );
      await reopened.close();
    });
  });

  group('the stage request surface belongs to the hook', () {
    late _Transport transport;
    late InProcessSourceScriptRuntime runtime;

    setUp(() {
      transport = _Transport();
      runtime = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(transport: transport),
      );
    });

    test('a check failure is recorded in the source log with the script error', () async {
      final runtime = InProcessSourceScriptRuntime();
      await expectLater(
        _check(
          runtime,
          'throw new Error("gate failed")',
          response: {
            'statusCode': 200,
            'headers': const <String, List<String>>{},
            'body': 'gate 1234',
            'url': 'http://a.test/search',
          },
        ),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            contains('gate failed'),
          ),
        ),
      );
      expect(runtime.messages, hasLength(1));
      expect(runtime.messages.single.kind, 'loginCheckJs');
      expect(runtime.messages.single.message, contains('gate failed'));
    });

    test('the stage response is result and only a response may replace it', () async {
      final response = {
        'statusCode': 200,
        'headers': {
          'X-User': ['uid-1'],
        },
        'body': 'gate 1234',
        'url': 'http://a.test/search',
      };
      await expectLater(
        _check(
          runtime,
          'JSON.stringify([result.body(), result.url(), result.code(), result.headers().get("x-user")])',
          response: response,
        ),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            contains('must return a response object'),
          ),
        ),
        reason: 'a string is not a StrResponse and the frozen cast rejects it',
      );
      final replaced = await _check(runtime, 'result', response: response);
      expect(replaced.body, 'gate 1234');
      expect(replaced.url, SourceHttpUri.parse('http://a.test/search'));
      expect(replaced.statusCode, 200);
      expect(replaced.headers['X-User'], ['uid-1']);
    });

    test('getResponse and getStrResponse repeat the stage request, initUrl re-analyzes it', () async {
      var resent = 0;
      final stage = SourceStageRequest(
        resend: () async {
          resent++;
          return SourceStageResponse(
            body: 'second page',
            url: SourceHttpUri.parse('http://a.test/search?token=T1'),
          );
        },
        reanalyze: () async {},
      );
      final replaced = await _check(
        runtime,
        'result = java.getStrResponse(); java.getResponse()',
        response: {
          'statusCode': 200,
          'headers': const <String, List<String>>{},
          'body': 'gate 1234',
          'url': 'http://a.test/search',
        },
        stage: stage,
      );
      expect(resent, 2);
      expect(replaced.body, 'second page');
      expect('${replaced.url}', 'http://a.test/search?token=T1');
    });

    test('a rule script has no stage request: each member refuses by name', () async {
      for (final member in [
        'java.getResponse()',
        'java.getStrResponse()',
        'java.getStrResponse(null, null)',
        'java.initUrl()',
      ]) {
        await expectLater(
          runtime.evaluate(
            source: member,
            input: {
              'sourceKey': 'https://a.test/source',
              'source': {'bookSourceUrl': 'https://a.test/source'},
            },
            timeout: const Duration(seconds: 15),
          ),
          throwsA(
            isA<SourceScriptError>()
                .having((error) => error.category, 'category', 'policy')
                .having(
                  (error) => error.message,
                  'member',
                  contains(member.split('(').first),
                ),
          ),
          reason: member,
        );
      }
    });

    test('the getStrResponse(jsStr, …) form refuses by name', () async {
      await expectLater(
        _check(
          runtime,
          'java.getStrResponse("page.js")',
          response: {
            'statusCode': 200,
            'headers': const <String, List<String>>{},
            'body': 'gate 1234',
            'url': 'http://a.test/search',
          },
        ),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having(
                (error) => error.message,
                'member',
                contains('java.getStrResponse(jsStr, …)'),
              ),
        ),
      );
    });
  });
}

Future<SourceStageResponse> _check(
  SourceScriptRuntime runtime,
  String script, {
  required Map<String, Object?> response,
  SourceStageRequest? stage,
}) => runtime.evaluateLoginCheck(
  script: script,
  input: {
    'sourceKey': 'http://source.test',
    'source': {'bookSourceUrl': 'http://source.test'},
    'result': response,
  },
  stage:
      stage ??
      SourceStageRequest(
        resend: () async => throw StateError('no stage request'),
        reanalyze: () async {},
      ),
  timeout: const Duration(seconds: 15),
);

class _Transport implements SourceHttpTransport {
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async =>
      SourceHttpResponse(
        statusCode: 200,
        headers: const {},
        body: 'ok',
        url: request.url,
      );
}

/// One rendered-document adapter the WebView path is handed in a test.
class _RenderedAdapter implements BookSourceWebViewAdapter {
  _RenderedAdapter(this.body);
  final String body;
  final requests = <SourceWebViewRequest>[];

  @override
  Future<SourceWebViewResponse> load(SourceWebViewRequest request) async {
    requests.add(request);
    return SourceWebViewResponse.page(request.url ?? '', body);
  }

  @override
  void destroy() {}

  @override
  bool get isDisposed => false;

  @override
  bool get hasWebView => true;
}

class _RenderedFactory extends BookSourceWebViewAdapterFactory {
  _RenderedFactory(this.adapter, {super.sourceRef = 'http://source.test'});
  final _RenderedAdapter adapter;

  @override
  BookSourceWebViewAdapter create() => adapter;
}
