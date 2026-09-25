import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The script element family (#100): the two #11 refusal classes the operator
/// ruled in scope — an element-list rule (`ruleSearch.bookList` /
/// `ruleToc.chapterList`) that carries a script, and a per-element field rule
/// that is a script only.
///
/// The frozen binding is the contract: a list script's `result` is the response
/// body string (`BookList.kt:50` `setContent(body)`), and a per-element field
/// script's `result` is the element-list rule's own result (`BookList.kt:208`
/// `setContent(item)`). The node façade the scripts reach is exactly the surface
/// #98 measured — `Jsoup.parse`, `select`, `selectFirst`, `attr`, `text` — over
/// this product's own Rust HTML adapter; anything else refuses by name.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const bookPage =
      '<div class="book" data-name="甲"><h3 class="name">书名甲</h3>'
      '<a href="/book/1">甲</a><span class="kind">玄幻</span></div>';
  const secondBookPage =
      '<div class="book" data-name="乙"><h3 class="name">书名乙</h3>'
      '<a href="/book/2">乙</a><span class="kind">仙侠</span></div>';

  Map<String, dynamic> source({
    required String bookList,
    String name = '@js: result.attr("data-name")',
    String bookUrl = '@js: result.selectFirst("a").attr("href")',
    String kind = '@js: result.select(".kind").text()',
    String chapterName = 'a@text',
    String isVip = '',
  }) => <String, dynamic>{
    'bookSourceUrl': 'http://script-family.test',
    'searchUrl': '/search',
    'ruleSearch': <String, dynamic>{
      'bookList': bookList,
      'name': name,
      'bookUrl': bookUrl,
      'kind': kind,
    },
    'ruleBookInfo': <String, dynamic>{'name': 'h1@text', 'tocUrl': '.toc@href'},
    'ruleToc': <String, dynamic>{
      'chapterList': '#list .ch',
      'chapterName': chapterName,
      'chapterUrl': 'a@href',
      if (isVip.isNotEmpty) 'isVip': isVip,
    },
    'ruleContent': <String, dynamic>{'content': '.content@text'},
  };

  test('an element-list script receives the response body string', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: r"@js: typeof result === 'string' ? ['甲', '乙'].join('\n') : 'BAD'",
        name: '@js: result',
        bookUrl: '@js: "/book/" + result',
        kind: '@js: ""',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
      }),
    );
    final hits = await pipeline.search('关键字');
    expect(hits.map((book) => book.title), <String>['甲', '乙']);
    pipeline.cancel();
  });

  test('an element-list script that transforms the matched elements', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: '<js>let out = [];'
            'let books = Jsoup.parse(result).select(".book");'
            'for (let i = 0; i < books.length; i++) out.push(books[i]);'
            'out</js>',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
      }),
    );
    final hits = await pipeline.search('关键字');
    expect(hits.map((book) => book.title), <String>['甲', '乙']);
    expect(hits.map((book) => book.author), <String>['', '']);
    pipeline.cancel();
  });

  test(
    'an element-list script that returns elements feeds per-element fields',
    () async {
      final pipeline = openBookSourcePipeline(
        source(
          bookList: '<js>Jsoup.parse(result).select(".book")</js>',
          name: '@js: result.select(".name").text()',
        ),
        PipelinePages({
          '/search': '$bookPage$secondBookPage',
        }),
      );
      final hits = await pipeline.search('关键字');
      // `select`/`selectFirst`/`attr`/`text` each answered off the item element
      // the list script produced: the per-element `result` is that element
      // (`BookList.kt:208`), not the page.
      expect(hits.map((book) => book.title), <String>['书名甲', '书名乙']);
      expect(hits.map((book) => book.kind), <String>['玄幻', '仙侠']);
      expect('${hits.first.url}', 'http://script-family.test/book/1');
      pipeline.cancel();
    },
  );

  test('a <js> block whose extraction follows it runs on the script value',
      () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: '<js>JSON.parse(result).html</js>.book',
        name: '@js: result.attr("data-name")',
        bookUrl: '@js: result.selectFirst("a").attr("href")',
        kind: '@js: ""',
      ),
      PipelinePages({
        '/search': '{"html": "<div class=book data-name=甲><h3 class=name>书名甲</h3>'
            '<a href=/book/1>甲</a><span class=kind>玄幻</span></div>"}',
      }),
    );
    final hits = await pipeline.search('关键字');
    expect(hits.single.title, '甲');
    pipeline.cancel();
  });

  test('a per-element script-only field on a selector list rule', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: '.book',
        name: '@js: result.attr("data-name")',
        bookUrl: '@js: result.selectFirst("a").attr("href")',
        kind: '@js: result.select(".kind").text()',
        isVip: '@js: result.select("span").text().indexOf("U币") >= 0',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
        '/book/1': '<h1>书名甲</h1><a class="toc" href="/toc/1">目录</a>',
        '/book/2': '<h1>书名乙</h1><a class="toc" href="/toc/2">目录</a>',
        '/toc/1':
            '<div id="list"><div class="ch"><a href="/c/1">第一章</a>'
                '<span class="vip">U币</span></div></div>',
        '/toc/2':
            '<div id="list"><div class="ch"><a href="/c/2">第一章</a>'
                '<span>免费</span></div></div>',
        '/c/1': '<div class="content">正文一</div>',
        '/c/2': '<div class="content">正文二</div>',
      }),
    );
    final hits = await pipeline.search('关键字');
    expect(hits.map((book) => book.title), <String>['甲', '乙']);
    final (_, chapters) = await pipeline.details(hits.first);
    expect(chapters.single.name, '第一章');
    expect(chapters.single.isVip, isTrue);
    expect(
      (await pipeline.chapter(chapters.single)).text,
      '正文一',
    );
    pipeline.cancel();
  });

  test('a per-element script-only field on a scripted list rule', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: '@js: Jsoup.parse(result).select(".book")',
        isVip: '@js: result.select("span").text().indexOf("U币") >= 0',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
        '/book/1': '<h1>书名甲</h1><a class="toc" href="/toc/1">目录</a>',
        '/toc/1':
            '<div id="list"><div class="ch"><a href="/c/1">第一章</a>'
                '<span class="vip">U币</span></div></div>',
        '/c/1': '<div class="content">正文一</div>',
      }),
    );
    final hits = await pipeline.search('关键字');
    final (_, chapters) = await pipeline.details(hits.first);
    expect(chapters.single.isVip, isTrue);
    pipeline.cancel();
  });

  test('a string item is the per-element script result', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: r"@js: ['甲', '乙'].join('\n')",
        name: '@js: result',
        bookUrl: '@js: "/book/" + result',
        kind: '@js: ""',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
      }),
    );
    final hits = await pipeline.search('关键字');
    expect(hits.map((book) => book.title), <String>['甲', '乙']);
    pipeline.cancel();
  });

  test('an unlisted node method refuses by name', () async {
    final pipeline = openBookSourcePipeline(
      source(
        bookList: '@js: Jsoup.parse(result).html()',
        name: '@js: result',
        bookUrl: '@js: "/book/" + result',
        kind: '@js: ""',
      ),
      PipelinePages({
        '/search': '$bookPage$secondBookPage',
      }),
    );
    await expectLater(
      pipeline.search('关键字'),
      throwsA(
        isA<SourceScriptError>()
            .having((error) => error.category, 'category', 'policy')
            .having(
              (error) => error.message,
              'member',
              contains('Jsoup.html'),
            ),
      ),
    );
    pipeline.cancel();
  });

  test('the façade member list is the measured surface', () async {
    // Every member of the list `sourceDomMembers` names answers, and one name
    // outside it refuses by name (the row above). The gate reads the same list.
    expect(sourceDomMembers, <String>[
      'parse',
      'select',
      'selectFirst',
      'attr',
      'text',
    ]);
  });
}

/// The pages one row's pipeline reads, keyed by path.
class PipelinePages implements BookSourceTransport {
  PipelinePages(this.pages);

  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    final page = pages[target];
    if (page == null) throw StateError('Unexpected URL: $target');
    return page;
  }
}
