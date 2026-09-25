import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart' show SourceHostMessage;
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// A book's address text beside its URL (#97).
///
/// A shelf row keeps a book's `source_book_url` as the address the import
/// wrote — option tail included, exactly as the frozen keeps `book.bookUrl` —
/// and the frozen splits that text at every fetch (`AnalyzeUrl.kt:214-222`).
/// A `Uri` cannot carry it: `Uri.toString()` percent-encodes a raw `,{…}` tail,
/// so a pipeline that only had the URL sent the encoded tail as query text —
/// the site answered a 95-byte error envelope, `ruleBookInfo.init: $.data` found
/// nothing, the `{{$.novelId}}` in the TOC address came out empty and the site
/// answered 403 (the operator's 万生痴魔).
///
/// One row per pipeline opens the stored shape, and one per pipeline carries a
/// *search hit's* rule text into a fresh analysis, which is the browser's
/// 更新目录 and 换源 shape.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const origin = 'http://source.test';

  /// The operator's own stored address text: multi-line, with a `js` tail, so
  /// an unsplit tail reaches the query as `%7B` and `%0A` rather than being
  /// dropped.
  const tail =
      '?isSearch=1,{\n'
      '  "js": "java.toast(\'正在加载详情页，请稍等！\')"\n'
      '}';
  const toasted = '正在加载详情页，请稍等！';

  test(
    'the HTML pipeline fetches the stored address text, not its Uri',
    () async {
      for (final (label, stored) in <(String, String)>[
        ('option tail', '$origin/book/b29$tail'),
        ('no tail', '$origin/book/b29'),
      ]) {
        final notices = <SourceHostMessage>[];
        final pages = _Pages({
          '/book/b29':
              '<h2>万生痴魔</h2><div id="toc"><a href="/toc/b29">目录</a></div>',
          '/toc/b29': '<ul id="list"><li><a href="/c/1">第一章</a></li></ul>',
        });
        final pipeline = HtmlSourcePipeline(
          _htmlSource(origin),
          pages,
          onHostMessage: notices.add,
        );

        // The hit as the shelf builds it: the row's own URL column beside the
        // stored text the column holds.
        final (book, chapters) = await pipeline.details(
          HtmlBook(url: Uri.parse(stored), rawAddress: stored, title: '万生痴魔'),
        );

        expect(book.title, '万生痴魔', reason: label);
        expect(chapters.single.name, '第一章', reason: label);
        expect(
          pages.requests.map((request) => request.url.toString()),
          [
            '$origin/book/b29${label == 'no tail' ? '' : '?isSearch=1'}',
            '$origin/toc/b29',
          ],
          reason: label,
        );
        expect(
          pages.requests.first.url.toString(),
          isNot(contains('%7B')),
          reason: '$label: 选项尾巴没有作为查询文本到达站点',
        );
        expect(
          notices.map((notice) => notice.message),
          label == 'no tail' ? isEmpty : [toasted],
          reason: '$label: 尾部的 js 选项',
        );
      }
    },
  );

  test(
    'the JSON pipeline fetches the stored address text, not its Uri',
    () async {
      for (final (label, stored) in <(String, String)>[
        ('option tail', '$origin/book/b29$tail'),
        ('no tail', '$origin/book/b29'),
      ]) {
        final notices = <SourceHostMessage>[];
        final pages = _Pages({
          '/book/b29': '{"title":"万生痴魔","toc":"/toc/b29"}',
          '/toc/b29': '{"list":[{"name":"第一章","url":"/c/1"}]}',
        });
        final pipeline = JsonSourcePipeline(
          _jsonSource(origin),
          pages,
          onHostMessage: notices.add,
        );

        final (book, chapters) = await pipeline.details(
          HtmlBook(url: Uri.parse(stored), rawAddress: stored, title: '万生痴魔'),
        );

        expect(book.title, '万生痴魔', reason: label);
        expect(chapters.single.name, '第一章', reason: label);
        expect(
          pages.requests.map((request) => request.url.toString()),
          [
            '$origin/book/b29${label == 'no tail' ? '' : '?isSearch=1'}',
            '$origin/toc/b29',
          ],
          reason: label,
        );
        expect(
          notices.map((notice) => notice.message),
          label == 'no tail' ? isEmpty : [toasted],
          reason: '$label: 尾部的 js 选项',
        );
      }
    },
  );

  test('a search hit carries its rule text into a fresh analysis', () async {
    // The browser's 更新目录 and the precise search run a second analysis over
    // the book the first one answered. The hit keeps the address text its
    // `ruleSearch.bookUrl` rule produced — the same text a shelf row would
    // store — so the second analysis splits it exactly as the first did.
    final htmlPages = _Pages({
      '/search':
          '<div class="item"><h3><a href="/book/b29">万生痴魔</a></h3></div>',
      '/book/b29':
          '<h2>万生痴魔</h2><div id="toc"><a href="/toc/b29">目录</a></div>',
      '/toc/b29': '<ul id="list"><li><a href="/c/1">第一章</a></li></ul>',
    });
    final html = HtmlSourcePipeline(_htmlSource(origin, tail: tail), htmlPages);
    final htmlHit = (await html.search('b29')).single;
    expect(htmlHit.rawAddress, '/book/b29$tail');
    expect('${htmlHit.url}', '$origin/book/b29?isSearch=1');

    final htmlSecond = HtmlSourcePipeline(
      _htmlSource(origin, tail: tail),
      htmlPages,
    );
    final (htmlBook, htmlChapters) = await htmlSecond.details(htmlHit);
    expect(htmlBook.title, '万生痴魔');
    expect(htmlChapters.single.name, '第一章');
    expect(
      htmlPages.requests.map((request) => request.url.toString()),
      [
        '$origin/search?key=b29',
        '$origin/book/b29?isSearch=1',
        '$origin/toc/b29',
      ],
    );

    final jsonPages = _Pages({
      '/search':
          '{"items":[{"title":"万生痴魔",'
          '"url":"/book/b29?isSearch=1,{\\"js\\":\\"java.toast(1)\\"}"}]}',
      '/book/b29': '{"title":"万生痴魔","toc":"/toc/b29"}',
      '/toc/b29': '{"list":[{"name":"第一章","url":"/c/1"}]}',
    });
    final json = JsonSourcePipeline(_jsonSource(origin), jsonPages);
    final jsonHit = (await json.search('b29')).single;
    expect(
      jsonHit.rawAddress,
      '/book/b29?isSearch=1,{"js":"java.toast(1)"}',
    );
    expect('${jsonHit.url}', '$origin/book/b29?isSearch=1');

    final jsonSecond = JsonSourcePipeline(_jsonSource(origin), jsonPages);
    final (jsonBook, jsonChapters) = await jsonSecond.details(jsonHit);
    expect(jsonBook.title, '万生痴魔');
    expect(jsonChapters.single.name, '第一章');
    expect(
      jsonPages.requests.map((request) => request.url.toString()),
      [
        '$origin/search?key=b29',
        '$origin/book/b29?isSearch=1',
        '$origin/toc/b29',
      ],
    );
  });
}

/// A source whose search page names the address text a hit keeps: [tail] is
/// appended by the `ruleSearch.bookUrl` rule the way an imported source writes
/// its options (`href##$##,{…}`).
Map<String, dynamic> _htmlSource(String origin, {String tail = ''}) => {
  'bookSourceUrl': origin,
  'bookSourceName': '地址源',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': '@CSS:.item',
    'name': '@CSS:h3 a@text',
    'bookUrl':
        '@CSS:h3 a@href${tail.isEmpty ? '' : '##\$##$tail'}',
  },
  'ruleBookInfo': {'name': '@CSS:h2@text', 'tocUrl': '@CSS:#toc a@href'},
  'ruleToc': {
    'chapterList': '@CSS:#list li',
    'chapterName': '@CSS:a@text',
    'chapterUrl': '@CSS:a@href',
  },
};

Map<String, dynamic> _jsonSource(String origin) => {
  'bookSourceUrl': origin,
  'bookSourceName': '地址源',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.title',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
};

/// Answers one page per path and records every request, so a row can read the
/// URL text that actually reached the site.
class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: _body(request.url),
      url: request.url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path);
    requests.add(SourceHttpRequest(method: 'GET', url: url));
    return _body(url);
  }

  String _body(Uri url) {
    final body = pages[url.path];
    if (body == null) throw StateError('不应请求：$url');
    return body;
  }
}
