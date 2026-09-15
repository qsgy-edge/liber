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

    expect(
      () => splitSourceUrlOptions('/s,{"charset":"gbk"}'),
      throwsUnsupportedError,
    );
    expect(
      () => splitSourceUrlOptions('/s,{"webView":true}'),
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
    expect(() => splitSourceUrlOptions('/s,{"method":'), throwsFormatException);
  });

  test('POST request shapes mirror the frozen body selection', () {
    final plain = sourceRequestShape(const SourceUrlOptions(), const {});
    expect(plain.method, 'GET');
    expect(plain.body, isNull);
    expect(plain.headers, isEmpty);
    final empty = sourceRequestShape(
      const SourceUrlOptions(method: 'POST'),
      const {},
    );
    expect(empty.method, 'POST');
    expect(empty.body, '');
    expect(empty.headers, {
      'Content-Type': 'application/x-www-form-urlencoded',
    });
    final form = sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: 'a=1&b=中文'),
      const {},
    );
    expect(form.method, 'POST');
    expect(form.body, 'a=1&b=%E4%B8%AD%E6%96%87');
    expect(form.headers, {'Content-Type': 'application/x-www-form-urlencoded'});
    final json = sourceRequestShape(
      const SourceUrlOptions(method: 'POST', body: '{"a":1}'),
      const {},
    );
    expect(json.method, 'POST');
    expect(json.body, '{"a":1}');
    expect(json.headers, {'Content-Type': 'application/json; charset=UTF-8'});
    final declared = sourceRequestShape(
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
    final output = await JsonSourcePipeline(transport).run(source, '书', (_) {});
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
