import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';

import 'native_library.dart';

/// A transport that answers from a script and records the outbound `Cookie`
/// header, which is what the flag's two outcomes are observable through.
class ScriptedCookieTransport
    implements SourceHttpTransport, BookSourceTransport {
  final requests = <SourceHttpRequest>[];
  final pages = <String, String>{};
  final setCookies = <String, List<String>>{};

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: {
        if (setCookies[request.url.path] != null)
          'set-cookie': setCookies[request.url.path]!,
      },
      body: pages[request.url.path] ?? '',
      url: request.url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';

  String? cookieOfLastRequest() => requests.last.headers['Cookie'];

  SourceHttpRequest requestFor(String path) =>
      requests.firstWhere((request) => request.url.path == path);
}

/// The flag's behavior on top of the per-space jar (ADR 0011 §3 owns the
/// storage; the flag decides whether a response may write to it at all).
///
/// Frozen `AnalyzeUrl.setCookie` (AnalyzeUrl.kt:597-615) sets the `CookieJar`
/// header only when `source.enabledCookieJar == true`, and the frozen network
/// interceptor (HttpHelper.kt:86-98) loads and saves the jar only when that
/// header is present. A source whose flag is false therefore still *sends* what
/// the jar already holds, but its responses never add to it.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  late SourceHostState state;
  late ScriptedCookieTransport transport;

  setUp(() {
    state = SourceHostState();
    transport = ScriptedCookieTransport();
  });

  SourceHostDispatcher source(String url, {required bool jar}) =>
      SourceHostDispatcher(
        transport: transport,
        hostState: state,
        sourceRef: url,
        enabledCookieJar: jar,
      );

  test('the flag on keeps a response cookie for the next request', () async {
    final dispatcher = source('http://a.test/book', jar: true);
    transport.setCookies['/login'] = ['sid=abc; Path=/'];
    await dispatcher.get('http://a.test/login');
    expect(state.cookiesFor('http://a.test').header('a.test'), 'sid=abc');

    await dispatcher.get('http://a.test/next');
    expect(transport.cookieOfLastRequest(), 'sid=abc');
  });

  test('the flag off drops the response cookie and sends none after', () async {
    final dispatcher = source('http://a.test/book', jar: false);
    transport.setCookies['/login'] = ['sid=abc; Path=/'];
    await dispatcher.get('http://a.test/login');
    expect(state.cookiesFor('http://a.test').header('a.test'), '');

    await dispatcher.get('http://a.test/next');
    expect(transport.cookieOfLastRequest(), isNull);
  });

  test('the flag off still sends a cookie the source script wrote', () async {
    final dispatcher = source('http://a.test/book', jar: false);
    // `cookie.setCookie` is the frozen `CookieStore.setCookie`, which writes to
    // the store directly and does not consult the flag.
    await dispatcher.setCookies('http://a.test/', 'sid=1');
    await dispatcher.get('http://a.test/next');
    expect(transport.cookieOfLastRequest(), 'sid=1');
  });

  test('the flag off still sends what the jar already holds', () async {
    // Another run of the same site (here: the same source with the flag on)
    // stored a pair; the disabled source is not blind to it, because the frozen
    // `setCookie` merges `CookieStore.getCookie` before the interceptor runs.
    final enabled = source('http://a.test/book', jar: true);
    transport.setCookies['/login'] = ['sid=abc; Path=/'];
    await enabled.get('http://a.test/login');

    final disabled = source('http://a.test/book', jar: false);
    await disabled.get('http://a.test/next');
    expect(transport.cookieOfLastRequest(), 'sid=abc');
  });

  test('a source without the flag leaves response cookies out of the jar',
      () async {
    // The pipelines pass `source['enabledCookieJar'] == true`, so the frozen
    // null default is false and a search response's cookie does not reach the
    // book page.
    transport.pages['/search'] =
        '<div class="item"><h3><a href="/book/">书</a></h3></div>';
    transport.pages['/book/'] =
        '<h2 id="dir"><a href="/toc">目录</a></h2><p>标题</p>';
    transport.pages['/toc'] =
        '<div class="chapter"><a href="/c/1">第一章</a></div>';
    transport.setCookies['/search'] = ['sid=abc; Path=/'];
    final pipeline = HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://a.test',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
      'ruleBookInfo': {'name': '@CSS:p@text', 'tocUrl': '@CSS:#dir a@href'},
      'ruleToc': {
        'chapterList': '@CSS:.chapter',
        'chapterName': '@CSS:a@text',
        'chapterUrl': '@CSS:a@href',
      },
    }, transport, hostState: state);
    final hits = await pipeline.search('书');
    await pipeline.details(hits.single);
    expect(transport.requestFor('/book/').headers['Cookie'], isNull);
  });

  test('a source that declares the flag carries the cookie into the next stage',
      () async {
    transport.pages['/search'] =
        '<div class="item"><h3><a href="/book/">书</a></h3></div>';
    transport.pages['/book/'] =
        '<h2 id="dir"><a href="/toc">目录</a></h2><p>标题</p>';
    transport.pages['/toc'] =
        '<div class="chapter"><a href="/c/1">第一章</a></div>';
    transport.setCookies['/search'] = ['sid=abc; Path=/'];
    final pipeline = HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://a.test',
      'enabledCookieJar': true,
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
      'ruleBookInfo': {'name': '@CSS:p@text', 'tocUrl': '@CSS:#dir a@href'},
      'ruleToc': {
        'chapterList': '@CSS:.chapter',
        'chapterName': '@CSS:a@text',
        'chapterUrl': '@CSS:a@href',
      },
    }, transport, hostState: state);
    final hits = await pipeline.search('书');
    await pipeline.details(hits.single);
    expect(transport.requestFor('/book/').headers['Cookie'], 'sid=abc');
  });
}
