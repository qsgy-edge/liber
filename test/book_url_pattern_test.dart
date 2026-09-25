import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The search-stage `bookUrlPattern` rule (`BookList.kt:53-70` and its
/// `:88-99` fallback) in both pipelines.
///
/// The frozen stage matches the pattern against the response's final URL — the
/// request URL when nothing redirected — and a match makes the page a book
/// detail page: the `ruleBookInfo` rules read *that* response and
/// `ruleSearch.bookList` is never consulted.

/// A fixture site that answers each path with one page and records the exact
/// request it saw, so a test asserts the wire as well as the parsed book.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);

  final Map<String, String> pages;
  final List<String> requests = [];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    final page = pages[Uri.parse(path).path];
    if (page == null) throw StateError('Unexpected URL: $path');
    return page;
  }
}

/// One detail page: every `ruleBookInfo` field the fixture sources declare.
const _detailPage =
    '<h1>真实标题</h1>'
    '<p class="author">作者甲</p>'
    '<div class="intro">简介</div>'
    '<img class="cover" src="/img/cover.jpg">'
    '<span class="kind">玄幻</span>'
    '<a class="last" href="/chapter/9">第九章</a>'
    '<span class="count">120000</span>'
    '<a class="toc" href="/toc/73">目录</a>';

/// The same page as the JSON adapter reads it.
const _detailDocument = {
  'title': '真实标题',
  'author': '作者甲',
  'intro': '简介',
  'cover': '/img/cover.jpg',
  'kind': '玄幻',
  'lastChapter': '第九章',
  'wordCount': '120000',
  'toc': '/toc/73',
};

/// One search-list page: a single `div.item` hit.
const _listPage = '<div class="item"><h3><a href="/book/1">列表标题</a></h3></div>';

Map<String, dynamic> _htmlSource(
  String origin, {
  String searchUrl = '/search?key={{key}}',
  String? bookUrlPattern,
  String bookList = 'div.item',
}) => {
  'bookSourceUrl': origin,
  'searchUrl': searchUrl,
  'bookUrlPattern': ?bookUrlPattern,
  'ruleSearch': {
    'bookList': bookList,
    'name': 'h3 a@text',
    'bookUrl': 'h3 a@href',
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'author': 'p.author@text',
    'intro': 'div.intro@text',
    'coverUrl': 'img.cover@src',
    'kind': 'span.kind@text',
    'lastChapter': 'a.last@text',
    'wordCount': 'span.count@text',
    'tocUrl': 'a.toc@href',
  },
  'ruleToc': {
    'chapterList': 'li',
    'chapterName': 'a@text',
    'chapterUrl': 'a@href',
  },
  'ruleContent': {'content': '#content@text'},
};

Map<String, dynamic> _jsonSource(
  String origin, {
  String searchUrl = '/search?key={{key}}',
  String? bookUrlPattern,
  String bookList = r'$.listing[*]',
}) => {
  'bookSourceUrl': origin,
  'searchUrl': searchUrl,
  'bookUrlPattern': ?bookUrlPattern,
  'ruleSearch': {'bookList': bookList, 'name': r'$.name', 'bookUrl': r'$.url'},
  'ruleBookInfo': {
    'name': r'$.title',
    'author': r'$.author',
    'intro': r'$.intro',
    'coverUrl': r'$.cover',
    'kind': r'$.kind',
    'lastChapter': r'$.lastChapter',
    'wordCount': r'$.wordCount',
    'tocUrl': r'$.toc',
  },
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.label',
    'chapterUrl': r'$.href',
  },
  'ruleContent': {'content': r'$.text'},
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('a matched detail page (BookList.kt:53-70)', () {
    test(
      'the HTML pipeline returns its one book and reads no list rule',
      () async {
        final transport = _Pages({'/detail/73': _detailPage});
        final pipeline = HtmlSourcePipeline(
          _htmlSource(
            'http://example.test',
            searchUrl: '/detail/73?key={{key}}',
            // The list rule is the proof: a script that throws if it runs means
            // a search that returns the book never read it.
            bookList: "@js: (() => { throw new Error('列表规则被读取') })()",
            bookUrlPattern: r'.*/detail/\d+.*',
          ),
          transport,
        );

        final hits = await pipeline.search('书');

        final book = hits.single;
        // Every field is the `ruleBookInfo` rule's, not a `ruleSearch` one.
        expect(book.title, '真实标题');
        expect(book.author, '作者甲');
        expect(book.intro, '简介');
        expect(book.cover, 'http://example.test/img/cover.jpg');
        expect(book.kind, '玄幻');
        expect(book.lastChapter, '第九章');
        expect(book.wordCount, '12万字');
        expect('${book.url}', 'http://example.test/detail/73?key=%E4%B9%A6');
        // The detail parse runs on the response the search stage already has.
        expect(transport.requests, [
          'http://example.test/detail/73?key=%E4%B9%A6',
        ]);

        // The proof that the list rule above was never consulted: read at all,
        // its script throws.
        final listed = HtmlSourcePipeline(
          _htmlSource(
            'http://example.test',
            searchUrl: '/detail/73?key={{key}}',
            bookList: "@js: (() => { throw new Error('列表规则被读取') })()",
          ),
          _Pages({'/detail/73': _detailPage}),
        );
        await expectLater(
          listed.search('书'),
          throwsA(
            isA<SourceScriptError>().having(
              (error) => error.message,
              'message',
              contains('列表规则被读取'),
            ),
          ),
        );
      },
    );

    test(
      'the JSON pipeline returns its one book and reads no list rule',
      () async {
        final transport = _Pages({'/detail/73': jsonEncode(_detailDocument)});
        final pipeline = JsonSourcePipeline(
          _jsonSource(
            'http://example.test',
            searchUrl: '/detail/73?key={{key}}',
            bookUrlPattern: r'.*/detail/\d+.*',
          ),
          transport,
        );

        final hits = await pipeline.search('书');

        final book = hits.single;
        expect(book.title, '真实标题');
        expect(book.author, '作者甲');
        expect(book.intro, '简介');
        expect(book.cover, 'http://example.test/img/cover.jpg');
        expect(book.kind, '玄幻');
        expect(book.lastChapter, '第九章');
        expect(book.wordCount, '12万字');
        expect('${book.url}', 'http://example.test/detail/73?key=%E4%B9%A6');
        expect(transport.requests, [
          'http://example.test/detail/73?key=%E4%B9%A6',
        ]);
      },
    );

    test('the match is over the whole final URL, not a substring', () async {
      final transport = _Pages({'/detail/73': _detailPage});
      // Java's `String.matches` needs the entire URL; `detail/\d+` alone would
      // match a substring of `/detail/73?key=…` under a partial-match reader.
      final pipeline = HtmlSourcePipeline(
        _htmlSource(
          'http://example.test',
          searchUrl: '/detail/73?key={{key}}',
          bookList: 'div.item',
          bookUrlPattern: r'.*/detail/\d+',
        ),
        transport,
      );

      expect(await pipeline.search('书'), isEmpty);
    });

    test('a redirect to the matching detail URL answers that page', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <String>[];
      server.listen((request) async {
        seen.add(request.uri.toString());
        if (request.uri.path == '/search') {
          request.response.statusCode = 302;
          request.response.headers.set(
            HttpHeaders.locationHeader,
            '/detail/73',
          );
        } else if (request.uri.path == '/detail/73') {
          request.response.write(_detailPage);
        } else {
          request.response.statusCode = 404;
        }
        await request.response.close();
      });
      final origin = 'http://127.0.0.1:${server.port}';
      final pipeline = HtmlSourcePipeline(
        // The pattern matches the *redirect target* only, so a search that
        // matched its own request URL would fall through to the list rule and
        // fail on it.
        _htmlSource(
          origin,
          bookUrlPattern: r'.*/detail/73',
          bookList: '@js:[]',
        ),
        HttpSourceTransport(),
      );

      final hits = await pipeline.search('书');

      // The book's URL is the response's final URL — what the details stage
      // fetches afterwards.
      expect('${hits.single.url}', '$origin/detail/73');
      expect(hits.single.title, '真实标题');
      expect(seen, ['/search?key=%E4%B9%A6', '/detail/73']);
    });
  });

  group('the empty-element-list fallback (BookList.kt:88-99)', () {
    test('the HTML pipeline parses the page as a detail page', () async {
      final transport = _Pages({'/detail/73': _detailPage});
      final pipeline = HtmlSourcePipeline(
        _htmlSource(
          'http://example.test',
          searchUrl: '/detail/73?key={{key}}',
          bookList: 'div.item',
        ),
        transport,
      );

      final hits = await pipeline.search('书');

      final book = hits.single;
      expect(book.title, '真实标题');
      expect(book.intro, '简介');
      expect(book.wordCount, '12万字');
      expect('${book.url}', 'http://example.test/detail/73?key=%E4%B9%A6');
    });

    test('the JSON pipeline parses the page as a detail page', () async {
      final transport = _Pages({'/detail/73': jsonEncode(_detailDocument)});
      final pipeline = JsonSourcePipeline(
        _jsonSource('http://example.test', searchUrl: '/detail/73?key={{key}}'),
        transport,
      );

      final hits = await pipeline.search('书');

      final book = hits.single;
      expect(book.title, '真实标题');
      expect(book.author, '作者甲');
      expect(book.kind, '玄幻');
      expect('${book.url}', 'http://example.test/detail/73?key=%E4%B9%A6');
    });

    test('a declared pattern suppresses the fallback', () async {
      final transport = _Pages({'/detail/73': _detailPage});
      final pipeline = HtmlSourcePipeline(
        _htmlSource(
          'http://example.test',
          searchUrl: '/detail/73?key={{key}}',
          bookUrlPattern: 'only-on-the-detail-host',
        ),
        transport,
      );

      // The pattern is non-empty and does not match, so the frozen stage reads
      // the element list, finds none and returns no books.
      expect(await pipeline.search('书'), isEmpty);
    });
  });

  group('a source without a pattern (BookList.kt:70-88)', () {
    test(
      'the HTML pipeline keeps the element-list request and parse',
      () async {
        final transport = _Pages({'/search': _listPage});
        final pipeline = HtmlSourcePipeline(
          _htmlSource('http://example.test'),
          transport,
        );

        final hits = await pipeline.search('书');

        expect(transport.requests, [
          'http://example.test/search?key=%E4%B9%A6',
        ]);
        expect(hits.single.title, '列表标题');
        expect('${hits.single.url}', 'http://example.test/book/1');
        expect(hits.single.author, '');
      },
    );

    test(
      'the JSON pipeline keeps the element-list request and parse',
      () async {
        final transport = _Pages({
          '/search': jsonEncode({
            'listing': [
              {'name': '列表标题', 'url': '/book/1'},
            ],
          }),
        });
        final pipeline = JsonSourcePipeline(
          _jsonSource('http://example.test'),
          transport,
        );

        final hits = await pipeline.search('书');

        expect(transport.requests, [
          'http://example.test/search?key=%E4%B9%A6',
        ]);
        expect(hits.single.title, '列表标题');
        expect('${hits.single.url}', 'http://example.test/book/1');
      },
    );

    test(
      'a pattern that does not match leaves the list path in charge',
      () async {
        final transport = _Pages({'/search': _listPage});
        final pipeline = HtmlSourcePipeline(
          _htmlSource('http://example.test', bookUrlPattern: r'.*/detail/\d+'),
          transport,
        );

        final hits = await pipeline.search('书');

        expect(transport.requests, [
          'http://example.test/search?key=%E4%B9%A6',
        ]);
        expect(hits.single.title, '列表标题');
        expect('${hits.single.url}', 'http://example.test/book/1');
      },
    );
  });

  group('a page whose source declares no ruleBookInfo.name', () {
    test('the HTML pipeline answers no book instead of the field', () async {
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://example.test',
        'searchUrl': '/detail/73?key={{key}}',
        'ruleSearch': {
          'bookList': 'div.item',
          'name': 'h3 a@text',
          'bookUrl': 'h3 a@href',
        },
      };
      // Both the pattern branch and the fallback read the detail rules off the
      // response they have; the frozen `getInfoItem` finds no name and returns
      // no book, where the details stage would refuse the missing field.
      expect(
        await HtmlSourcePipeline(
          source,
          _Pages({'/detail/73': _detailPage}),
        ).search('书'),
        isEmpty,
      );
      expect(
        await HtmlSourcePipeline({
          ...source,
          'bookUrlPattern': r'.*/detail/\d+.*',
        }, _Pages({'/detail/73': _detailPage})).search('书'),
        isEmpty,
      );
    });

    test('the JSON pipeline answers no book instead of the field', () async {
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://example.test',
        'searchUrl': '/detail/73?key={{key}}',
        'ruleSearch': {
          'bookList': r'$.listing[*]',
          'name': r'$.name',
          'bookUrl': r'$.url',
        },
      };
      expect(
        await JsonSourcePipeline(
          source,
          _Pages({'/detail/73': jsonEncode(_detailDocument)}),
        ).search('书'),
        isEmpty,
      );
      expect(
        await JsonSourcePipeline({
          ...source,
          'bookUrlPattern': r'.*/detail/\d+.*',
        }, _Pages({'/detail/73': jsonEncode(_detailDocument)})).search('书'),
        isEmpty,
      );
    });
  });

  group('a pattern the Java-pattern port cannot express', () {
    test('the HTML pipeline refuses it by name', () async {
      final transport = _Pages({'/detail/73': _detailPage});
      final pipeline = HtmlSourcePipeline(
        _htmlSource(
          'http://example.test',
          searchUrl: '/detail/73?key={{key}}',
          bookUrlPattern: r'\Qbook\E/\d+',
        ),
        transport,
      );

      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<UnsupportedError>()
              .having(
                (error) => error.message,
                'message',
                contains('bookUrlPattern'),
              )
              .having((error) => error.message, 'message', contains(r'\Q')),
        ),
      );
    });

    test('the JSON pipeline refuses it by name', () async {
      final transport = _Pages({'/search': jsonEncode(_detailDocument)});
      final pipeline = JsonSourcePipeline(
        _jsonSource('http://example.test', bookUrlPattern: r'\Qbook\E/\d+'),
        transport,
      );

      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<UnsupportedError>()
              .having(
                (error) => error.message,
                'message',
                contains('bookUrlPattern'),
              )
              .having((error) => error.message, 'message', contains(r'\Q')),
        ),
      );
    });
  });

  group('fields the product declares but does not execute (#81)', () {
    // A real source declares `ruleBookInfo.downloadUrls` as a bare URL
    // (万生痴魔's source, found by the operator's run). The frozen reads it into
    // `book.downloadUrls`; this product defers downloads (ADR 0011 §4), so the
    // field must be accepted and ignored instead of failing the details stage.
    test('a JSON source with a non-rule downloadUrls still reads details',
        () async {
      final document = jsonEncode({
        'author': '作者甲',
        'chapters': [
          {'name': '第一章', 'url': '/c/1'},
        ],
      });
      final (book, chapters) = await JsonSourcePipeline({
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {
          'author': r'$.author',
          'downloadUrls': 'http://api.example.test/',
        },
        'ruleToc': {
          'chapterList': r'$.chapters[*]',
          'chapterName': r'$.name',
          'chapterUrl': r'$.url',
        },
      }, _Pages({'/book/7': document})).details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(book.author, '作者甲');
      expect(chapters.map((chapter) => chapter.name), ['第一章']);
    });

    // A chapter whose URL rule carries an option tail keeps it: the raw address
    // is what the store holds and what the chapter's own fetch parses
    // (`SourceChapter.options`). The TOC builder used to refuse such a tail by
    // name (零点看书's `ruleToc.chapterUrl` ends in `##$##,{"headers": …}`).
    test('a chapter address with a header tail reaches the chapter list',
        () async {
      final transport = _Pages({
        '/book/7': '<ul class="chapters">'
            '<li><a href="/c/1##\$##,{&quot;headers&quot;:{&quot;X-Test&quot;:&quot;1&quot;}}">第一章</a></li>'
            '</ul>',
      });
      final (_, chapters) = await HtmlSourcePipeline({
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {'intro': 'p.intro@text'},
        'ruleToc': {
          'chapterList': 'ul.chapters li',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
      }, transport).details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(chapters.single.options.headers, {'X-Test': '1'});
      expect('${chapters.single.url}', 'http://example.test/c/1');
    });
  });

  group('the frozen shapes the product refused (#83)', () {
    // 5. The identity address is a plain string in the frozen (`BookSource.kt:34`
    // is an index key and a `baseUrl`), so a label identity with absolute rules
    // must read its stages; a fetchable target is required only where a request
    // is built.
    test('a label identity with absolute rules reads its details and chapters',
        () async {
      final pages = _Pages({
        '/search': '<div class="item"><h3><a href="http://example.test/book/7">'
            '书</a></h3></div>',
        '/book/7': '<ul class="chapters"><li>'
            '<a href="http://example.test/c/1">第一章</a></li></ul>',
      });
      final source = <String, dynamic>{
        // A display label, not a URL: no scheme, no host.
        'bookSourceUrl': '书架·标签',
        'searchUrl': 'http://example.test/search?key={{key}}',
        'ruleSearch': {
          'bookList': 'div.item',
          'name': 'h3 a@text',
          'bookUrl': 'h3 a@href',
        },
        'ruleToc': {
          'chapterList': 'ul.chapters li',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
      };
      final pipeline = HtmlSourcePipeline(source, pages);
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      final (_, chapters) = await pipeline.details(hits.single);
      expect(chapters.single.name, '第一章');
      expect('${chapters.single.url}', 'http://example.test/c/1');
    });

    // 4. A blank `ruleToc.chapterUrl` is not a refusal: the frozen reads the
    // empty rule list as `""` and takes the empty-URL fallback
    // (`BookChapterList.kt:229-243`), which this TOC builder already applies.
    test('a blank chapterUrl takes the TOC page address', () async {
      final pages = _Pages({
        '/book/7': '<ul class="chapters">'
            '<li><a>第一章</a></li>'
            '</ul>',
      });
      final (_, chapters) = await HtmlSourcePipeline({
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {'intro': 'p.intro@text'},
        'ruleToc': {
          'chapterList': 'ul.chapters li',
          'chapterName': 'a@text',
          // no chapterUrl rule at all
        },
      }, pages).details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(chapters.single.name, '第一章');
      expect('${chapters.single.url}', 'http://example.test/book/7');
    });

    // 2. `ruleContent.imageStyle` and `ruleContent.replaceRegex` are declared
    // fields the JSON adapter refused as "unsupported" and validated as
    // extractions; `imageStyle` is a value this tree reads, and `replaceRegex`
    // is a frozen field the JSON path does not execute.
    test('a JSON source declaring imageStyle and replaceRegex reads its stages',
        () async {
      final transport = _Pages({
        '/book/7': jsonEncode({
          'author': '作者甲',
          'chapters': [
            {'name': '第一章', 'url': '/c/1'},
          ],
        }),
        '/c/1': jsonEncode({'body': '正文'}),
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {'author': r'$.author'},
        'ruleToc': {
          'chapterList': r'$.chapters[*]',
          'chapterName': r'$.name',
          'chapterUrl': r'$.url',
        },
        'ruleContent': {
          'content': r'$.body',
          'imageStyle': 'FULL',
          'replaceRegex': r'##a##b',
        },
      };
      final pipeline = JsonSourcePipeline(source, transport);
      final (book, chapters) = await pipeline.details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(book.author, '作者甲');
      expect(chapters.single.name, '第一章');
      // `imageStyle` is a value this product already reads off the source.
      expect(sourceImageStyle(source), SourceImageStyle.full);
      // `replaceRegex` is accepted and left unexecuted on the JSON path (a
      // recorded deferral), so the content stage reads its own rule.
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, contains('正文'));
    });

    // 3. A field whose text has nothing left to parse is read by this tree's
    // own runtime; only the product's `validate` refused it.
    test('a JSON content rule that is an @get: token reads its content',
        () async {
      final transport = _Pages({'/c/1': jsonEncode({})});
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://example.test',
        'ruleContent': {'content': '@get:title'},
      };
      final body = await JsonSourcePipeline(source, transport).chapter(
        SourceChapter('第一章', Uri.parse('http://example.test/c/1')),
      );
      expect(body.text, '第一章');
    });
  });

  group('a source whose ruleBookInfo omits name and tocUrl (#80)', () {
    // The frozen keeps the book's existing name for an empty `name` rule
    // (`BookInfo.kt:64-70`) and falls back to the book's own address for an
    // empty `tocUrl` (`BookInfo.kt:150-152`). Both were read as required, so a
    // real source was refused before any fetch (the operator's run, batch 17).
    const page =
        '<h1>真实标题</h1>'
        '<p class="author">作者甲</p>'
        '<ul class="chapters">'
        '<li><a href="/c/1">第一章</a></li>'
        '<li><a href="/c/2">第二章</a></li>'
        '</ul>';

    test('the HTML pipeline reads details and takes the TOC from the book URL',
        () async {
      final pages = _Pages({'/book/7': page});
      final (book, chapters) = await HtmlSourcePipeline({
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {'author': 'p.author@text'},
        'ruleToc': {
          'chapterList': 'ul.chapters li',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
      }, pages).details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(book.title, '书架标题', reason: 'an empty name rule keeps the title');
      expect(book.author, '作者甲');
      expect(
        chapters.map((chapter) => chapter.name),
        ['第一章', '第二章'],
      );
      expect(
        pages.requests,
        contains('http://example.test/book/7'),
        reason: 'the TOC is read from the book URL when tocUrl is empty',
      );
    });

    test('the JSON pipeline reads details with neither field declared',
        () async {
      final document = jsonEncode({
        'author': '作者甲',
        'chapters': [
          {'name': '第一章', 'url': '/c/1'},
        ],
      });
      final (book, chapters) = await JsonSourcePipeline({
        'bookSourceUrl': 'http://example.test',
        'ruleBookInfo': {'author': r'$.author'},
        'ruleToc': {
          'chapterList': r'$.chapters[*]',
          'chapterName': r'$.name',
          'chapterUrl': r'$.url',
        },
      }, _Pages({'/book/7': document})).details(
        HtmlBook(url: Uri.parse('http://example.test/book/7'), title: '书架标题'),
      );
      expect(book.title, '书架标题');
      expect(book.author, '作者甲');
      expect(chapters.map((chapter) => chapter.name), ['第一章']);
    });
  });
}
