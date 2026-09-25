import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_url_rules.dart';

import 'native_library.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test('URL options follow the frozen split and validation rules', () {
    final plain = splitSourceUrlOptions('/search?key=x');
    expect(plain.path, '/search?key=x');
    expect(plain.options.method, 'GET');
    expect(plain.options.body, isNull);
    expect(plain.options.retry, 0);

    final post = splitSourceUrlOptions(
      '/s , {"method":"post","body":"a=1","headers":{"X-A":"1"},"retry":2}',
    );
    expect(post.path, '/s');
    expect(post.options.method, 'POST');
    expect(post.options.body, 'a=1');
    expect(post.options.headers, {'X-A': '1'});
    expect(post.options.retry, 2);

    final json = splitSourceUrlOptions(
      '/s,{"body":{"a":1},"headers":"{\\"X-B\\":\\"2\\"}","origin":"https://x"}',
    );
    expect(json.path, '/s');
    expect(json.options.body, '{"a":1}');
    expect(json.options.jsonBody, isTrue);
    expect(json.options.headers, {'X-B': '2'});
    expect(json.options.method, 'GET');

    // `type` and `serverID` stay named refusals; the WebView options are wired
    // to the WebView path instead.
    expect(
      () => splitSourceUrlOptions('/s,{"type":"audio"}'),
      throwsUnsupportedError,
    );
    expect(
      () => splitSourceUrlOptions('/s,{"serverID":1}'),
      throwsUnsupportedError,
    );
    expect(
      () => splitSourceUrlOptions('/s,{"unknown":1}'),
      throwsUnsupportedError,
    );
    expect(
      () => splitSourceUrlOptions('/s,{"retry":-1}'),
      throwsFormatException,
    );
    // A tail the reader cannot read is not an error: the frozen
    // `AnalyzeUrl.kt:222` applies a `UrlOption` only when Gson returned one, so
    // the URL stays bare and nothing is applied (#58).
    final unreadable = splitSourceUrlOptions('/s,{"method":');
    expect(unreadable.path, '/s');
    expect(unreadable.options.method, 'GET');
    expect(unreadable.options.body, isNull);
    final notAnObject = splitSourceUrlOptions('/s,{"body":{');
    expect(notAnObject.path, '/s');
    expect(notAnObject.options.webView, isFalse);
  });

  test('the option tail is read the way the frozen Gson reader reads it', () {
    // Gson is lenient: unquoted names and single-quoted strings are both
    // accepted, and imported sources use both (255 of the operator's 8787 write
    // single-quoted option text). Strict JSON rejects every one of these.
    final unquotedName = splitSourceUrlOptions('/s,{webView:true}');
    expect(unquotedName.path, '/s');
    expect(unquotedName.options.webView, isTrue);

    final singleQuoted = splitSourceUrlOptions("/s,{'webView': true}");
    expect(singleQuoted.path, '/s');
    expect(singleQuoted.options.webView, isTrue);

    final mixed = splitSourceUrlOptions(
      "/s,{method:'POST',body:'a=1',headers:{'X-A':1},"
      'webJs:"document.title",webViewDelayTime:"250",retry:2,}',
    );
    expect(mixed.options.method, 'POST');
    expect(mixed.options.body, 'a=1');
    expect(mixed.options.headers, {'X-A': '1'});
    expect(mixed.options.webJs, 'document.title');
    expect(mixed.options.webViewDelayTime, 250);
    expect(mixed.options.retry, 2);

    // A structured body keeps being re-serialized as JSON, leniently read or
    // not, because the frozen `UrlOption.body` is written as JSON on the wire.
    final structured = splitSourceUrlOptions('/s,{body:{a:1}}');
    expect(structured.options.body, '{"a":1}');
    expect(structured.options.jsonBody, isTrue);

    // A value holding an unbalanced brace does not cost the options after it.
    // Strict JSON reads the object the brace scan frames, and when that frame
    // lands inside the value instead (`'a}b'`), the lenient reader takes the
    // whole remainder and stops after the object itself — so `webView` survives.
    final braceInValue = splitSourceUrlOptions("/s,{'body': 'a}b', webView:true}");
    expect(braceInValue.path, '/s');
    expect(braceInValue.options.body, 'a}b');
    expect(braceInValue.options.webView, isTrue);

    // The strict reading still decides first, and its own typed refusals stay:
    // a value the option cannot use is an error, not a silent fallback.
    expect(
      () => splitSourceUrlOptions('/s,{unknown:1}'),
      throwsUnsupportedError,
    );
    expect(
      () => splitSourceUrlOptions('/s,{webJs:1}'),
      throwsFormatException,
    );
  });

  test('an address text splits into its request target', () {
    expect(
      sourceUrlTargetOf('https://a.test/c/1,{webView:true}'),
      'https://a.test/c/1',
    );
    expect(sourceUrlTargetOf('https://a.test/c/1'), 'https://a.test/c/1');
    expect(sourceUrlTargetOf('/c/1,{"method":'), '/c/1');
    expect(
      sourceUrlOptionTailOf('/c/1,{"webView":true}'),
      ',{"webView":true}',
    );
    expect(sourceUrlOptionTailOf('/c/1'), '');
  });

  test('the WebView options are parsed the way the frozen UrlOption reads them', () {
    // Frozen `useWebView()`: null, "", false and "false" are false, everything
    // else is true.
    expect(splitSourceUrlOptions('/s').options.webView, isFalse);
    expect(splitSourceUrlOptions('/s,{}').options.webView, isFalse);
    for (final value in ['null', '""', 'false', '"false"']) {
      expect(
        splitSourceUrlOptions('/s,{"webView":$value}').options.webView,
        isFalse,
        reason: 'webView:$value',
      );
    }
    for (final value in ['true', '"true"', '1']) {
      expect(
        splitSourceUrlOptions('/s,{"webView":$value}').options.webView,
        isTrue,
        reason: 'webView:$value',
      );
    }
    // Frozen `setWebJs()`: blank is null, anything else is kept verbatim.
    expect(splitSourceUrlOptions('/s').options.webJs, isNull);
    expect(splitSourceUrlOptions('/s,{"webJs":""}').options.webJs, isNull);
    expect(
      splitSourceUrlOptions('/s,{"webJs":"  "}').options.webJs,
      isNull,
    );
    expect(
      splitSourceUrlOptions('/s,{"webJs":"document.title"}').options.webJs,
      'document.title',
    );
    expect(
      () => splitSourceUrlOptions('/s,{"webJs":1}'),
      throwsFormatException,
    );
    // Frozen `max(0, getWebViewDelayTime() ?: 0)`: a malformed value disables the
    // delay instead of failing the request.
    expect(splitSourceUrlOptions('/s').options.webViewDelayTime, 0);
    expect(
      splitSourceUrlOptions('/s,{"webViewDelayTime":250}').options.webViewDelayTime,
      250,
    );
    expect(
      splitSourceUrlOptions('/s,{"webViewDelayTime":"250"}').options.webViewDelayTime,
      250,
    );
    expect(
      splitSourceUrlOptions('/s,{"webViewDelayTime":-5}').options.webViewDelayTime,
      0,
    );
    expect(
      splitSourceUrlOptions('/s,{"webViewDelayTime":"nope"}').options.webViewDelayTime,
      0,
    );
  });

  test('the charset option is parsed the way the frozen UrlOption reads it', () {
    expect(splitSourceUrlOptions('/s,{"charset":"gbk"}').options.charset, 'gbk');
    expect(
      splitSourceUrlOptions('/s,{"charset":"escape"}').options.charset,
      'escape',
    );
    // Frozen `setCharset`: null and blank are the default branch.
    expect(splitSourceUrlOptions('/s,{"charset":""}').options.charset, isNull);
    expect(
      splitSourceUrlOptions('/s,{"charset":"   "}').options.charset,
      isNull,
    );
    expect(splitSourceUrlOptions('/s').options.charset, isNull);
    expect(
      () => splitSourceUrlOptions('/s,{"charset":1}'),
      throwsFormatException,
    );
  });

  test('the escape charset uses the frozen EncoderUtils.escape', () async {
    // `EncoderUtils.kt:11-28`: letters and digits stay, everything else is `%`
    // plus the UTF-16 code unit's lower-case hex, `%0` under 16 and `%u` over
    // 255 — the JS `escape` shape the frozen option named.
    expect(sourceEscape('a b'), 'a%20b');
    expect(sourceEscape('中'), '%u4e2d');
    expect(sourceEscape('~!'), '%7e%21');
    expect(sourceEscape('\n'), '%0a');

    // A query under `escape` drops to the same field loop a form body uses, so
    // `=` and `&` keep their meaning and each side is escaped (`AnalyzeUrl.kt:294-334`).
    expect(
      await encodeSourceQuery(
        'http://a/b?q=中 文&n=1',
        charset: 'escape',
      ),
      'http://a/b?q=%u4e2d%20%u6587&n=1',
    );
    // An already-escaped value is re-escaped, because `escape` disables the
    // already-encoded check.
    expect(
      await encodeSourceQuery('http://a/b?q=%E4%B9%A6', charset: 'escape'),
      'http://a/b?q=%25E4%25B9%25A6',
    );
  });

  test('a named charset encodes the request the way the frozen encoder does', () async {
    // `URLEncoder.encode(value, charset)` for a form body: the charset's bytes
    // as uppercase `%XX`, spaces as `+`, `*-._` kept (`AnalyzeUrl.kt:318-328`).
    final form = await sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: 'k=中', charset: 'gbk'),
      const {},
    );
    expect(form.body, 'k=%D6%D0');

    // The query path uses the frozen `queryEncoder`, which keeps the mask
    // characters and writes the charset's bytes as uppercase `%XX`.
    expect(
      await encodeSourceQuery('http://a/b?q=中 文', charset: 'gbk'),
      'http://a/b?q=%D6%D0%20%CE%C4',
    );
    // The already-encoded check stays on for a named charset.
    expect(
      await encodeSourceQuery('http://a/b?q=%D6%D0', charset: 'gbk'),
      'http://a/b?q=%D6%D0',
    );
    expect(
      () => encodeSourceQuery('http://a/b?q=x', charset: 'no-such-charset'),
      throwsUnsupportedError,
    );
  });

  test('POST request shapes mirror the frozen body selection', () async {
    final plain = await sourceRequestShape(const SourceUrlOptions(), const {});
    expect(plain.method, 'GET');
    expect(plain.body, isNull);
    expect(plain.headers, isEmpty);
    final empty = await sourceRequestShape(
      const SourceUrlOptions(method: 'POST'),
      const {},
    );
    expect(empty.method, 'POST');
    expect(empty.body, '');
    expect(empty.headers, {
      'Content-Type': 'application/x-www-form-urlencoded',
    });
    final form = await sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: 'a=1&b=中文'),
      const {},
    );
    expect(form.method, 'POST');
    expect(form.body, 'a=1&b=%E4%B8%AD%E6%96%87');
    expect(form.headers, {'Content-Type': 'application/x-www-form-urlencoded'});
    final json = await sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: '{"a":1}'),
      const {},
    );
    expect(json.method, 'POST');
    expect(json.body, '{"a":1}');
    expect(json.headers, {'Content-Type': 'application/json; charset=UTF-8'});
    final declared = await sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: '<x/>'),
      const {'Content-Type': 'application/xml'},
    );
    expect(declared.method, 'POST');
    expect(declared.body, '<x/>');
    expect(declared.headers, isEmpty);
  });

  test('HTML pipeline applies URL options to the search request', () async {
    final transport = RecordingHttpTransport({
      '/search':
          '<div class="container"><div class="item"><div class="itemtxt">'
          '<h3><a href="/book/">书</a></h3></div></div></div>',
    });
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': '{"X-Source":"1"}',
      'searchUrl':
          '/search,{"method":"POST","body":"key={{key}}&n=1",'
          '"headers":{"X-Option":"2"},"retry":1}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    final hits = await HtmlSourcePipeline(source, transport).search('书 & A');
    expect(hits.single.title, '书');
    expect(transport.requests, hasLength(1));
    final request = transport.requests.single;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'http://source.test/search');
    expect(request.retry, 1);
    // Frozen `analyzeFields`: `{{key}}` substitutes the raw keyword, so the
    // `&` inside it splits the form and spaces become `+`.
    expect(request.body, 'key=%E4%B9%A6+&+A&n=1');
    expect(request.headers, {
      'X-Source': '1',
      'X-Option': '2',
      'Content-Type': 'application/x-www-form-urlencoded',
    });
  });

  test(
    'a js option whose script answers nothing keeps the URL (#94)',
    () async {
      // The frozen `AnalyzeUrl.kt:238-242` assigns the option script's result to
      // the URL only when the result is not null. A real source's search, detail
      // and TOC addresses carry `,{"js":"java.toast('…')"}` — a script that only
      // shows a notice — and stringifying that nothing into `'null'` sent the
      // request to `/null` (a 404), which is what the operator's search hit.
      final transport = RecordingHttpTransport({
        '/search':
            '<div class="container"><div class="item"><div class="itemtxt">'
            '<h3><a href="/book/1">书</a></h3></div></div></div>',
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://source.test',
        'searchUrl':
            r'/search?keyword={{key}}&page={{page}},'
            r'''{"js":"java.toast('正在搜索中，请稍等！');"}''',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      };
      final hits = await HtmlSourcePipeline(source, transport).search('书');
      expect(hits.single.title, '书');
      expect(transport.requests, hasLength(1));
      expect(
        transport.requests.single.url.toString(),
        isNot(contains('/null')),
        reason: 'the toast-only script must not replace the URL',
      );
      expect(
        transport.requests.single.url.path,
        '/search',
        reason: 'the address the rule wrote stands',
      );
    },
  );

  test('JSON options carry a structured body on the search stage', () async {
    final transport = RecordingHttpTransport({
      '/search': '{"items":[{"name":"标题","url":"/details"}]}',
      '/details': '{"title":"标题","toc":"/chapters"}',
      '/chapters': '{"list":[{"label":"首章","href":"/text"}]}',
      '/text': '{"body":"正文"}',
    });
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': '{"X-Token":"42"}',
      'searchUrl': '/search,{"method":"POST","body":{"key":"{{key}}"}}',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
      'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
      'ruleToc': {
        'chapterList': r'$.list',
        'chapterName': r'$.label',
        'chapterUrl': r'$.href',
      },
      'ruleContent': {'content': r'$.body'},
    };
    final output = await JsonSourcePipeline(source, transport).run('书', (_) {});
    expect(output.title, '标题');
    expect(output.content, '正文');
    final request = transport.requests.first;
    expect(request.method, 'POST');
    expect(request.url.toString(), 'http://source.test/search');
    expect(request.headers, {
      'X-Token': '42',
      'Content-Type': 'application/json; charset=UTF-8',
    });
    // A structured body is not form-encoded: the frozen baseline substitutes
    // the raw key and keeps the JSON text as it is.
    expect(request.body, '{"key":"书"}');
  });

  test('a lenient header rule reaches the request (#83)', () async {
    // The frozen `BaseSource.getHeaderMap` reads the rule with lenient Gson, so
    // a single-quoted or unquoted map parses on both pipelines; a scalar value
    // becomes its text.
    final html = RecordingHttpTransport({
      '/search': '<div class="item"><h3><a href="/book/">书</a></h3></div>',
    });
    await HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': "{'User-Agent':'x','X-Token':'1'}",
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    }, html).search('书');
    expect(html.requests.single.headers['X-Token'], '1');

    final json = RecordingHttpTransport({
      '/search': '{"items":[{"name":"标题","url":"/d"}]}',
    });
    await JsonSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': '{User-Agent:x, X-Token: 2, flag: true}',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
    }, json).search('书');
    expect(json.requests.single.headers['X-Token'], '2');
    expect(json.requests.single.headers['flag'], 'true');
  });

  test('a header rule that is not a JSON map sends no source headers (#83)',
      () async {
    // The frozen answers no headers for a rule it cannot read (lenient Gson,
    // every failure caught), so the source runs with the request carrying none
    // of the rule's headers instead of being refused before the request.
    final html = RecordingHttpTransport({
      '/search': '<div class="item"><h3><a href="/book/">书</a></h3></div>',
    });
    final hits = await HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': 'User-Agent: x',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    }, html).search('书');
    expect(hits.single.title, '书');
    expect(html.requests.single.headers, isEmpty);

    final json = RecordingHttpTransport({
      '/search': '{"items":[{"name":"标题","url":"/d"}]}',
    });
    final jsonHits = await JsonSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'header': 'not json',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
    }, json).search('书');
    expect(jsonHits.single.title, '标题');
    expect(json.requests.single.headers, isEmpty);
  });

  test('directory page options reach the following request', () async {
    final transport = RecordingHttpTransport({
      '/search': '<div class="item"><h3><a href="/book/">书</a></h3></div>',
      '/book/':
          '<h2 id="dir"><a href="/toc,{&quot;headers&quot;:{&quot;X-Page&quot;:&quot;1&quot;}}">目录</a></h2>',
      '/toc': '<div id="list"><li><a href="/chapter/1">第一章</a></li></div>',
    });
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://source.test',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
      'ruleBookInfo': {'name': '@CSS:a@text', 'tocUrl': '@CSS:#dir a@href'},
      'ruleToc': {
        'chapterList': '@CSS:#list li a',
        'chapterName': '@CSS:a@text',
        'chapterUrl': '@CSS:a@href',
      },
    };
    final pipeline = HtmlSourcePipeline(source, transport);
    final hits = await pipeline.search('书');
    final (_, chapters) = await pipeline.details(hits.single);
    expect(chapters.single.url.toString(), 'http://source.test/chapter/1');
    final toc = transport.requests.last;
    expect(toc.url.toString(), 'http://source.test/toc');
    expect(toc.headers, {'X-Page': '1'});
  });
}

/// Records the requests the pipelines hand to the HTTP transport.
class RecordingHttpTransport
    implements BookSourceTransport, SourceHttpTransport {
  RecordingHttpTransport(this.pages);
  final Map<String, String> pages;
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final body = pages[request.url.path];
    if (body == null) throw StateError('Unexpected path: ${request.url.path}');
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: body,
      url: request.url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';
}
