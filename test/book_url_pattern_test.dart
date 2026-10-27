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
import 'package:liber/source/source_host_state.dart';

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
  String bookUrlRule = 'h3 a@href',
  String tocRule = 'a.toc@href',
}) => {
  'bookSourceUrl': origin,
  'searchUrl': searchUrl,
  'bookUrlPattern': ?bookUrlPattern,
  'ruleSearch': {
    'bookList': bookList,
    'name': 'h3 a@text',
    'bookUrl': bookUrlRule,
  },
  'ruleBookInfo': {
    'name': 'h1@text',
    'author': 'p.author@text',
    'intro': 'div.intro@text',
    'coverUrl': 'img.cover@src',
    'kind': 'span.kind@text',
    'lastChapter': 'a.last@text',
    'wordCount': 'span.count@text',
    'tocUrl': tocRule,
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
  String bookUrlRule = r'$.url',
  String tocRule = r'$.toc',
}) => {
  'bookSourceUrl': origin,
  'searchUrl': searchUrl,
  'bookUrlPattern': ?bookUrlPattern,
  'ruleSearch': {
    'bookList': bookList,
    'name': r'$.name',
    'bookUrl': bookUrlRule,
  },
  'ruleBookInfo': {
    'name': r'$.title',
    'author': r'$.author',
    'intro': r'$.intro',
    'coverUrl': r'$.cover',
    'kind': r'$.kind',
    'lastChapter': r'$.lastChapter',
    'wordCount': r'$.wordCount',
    'tocUrl': tocRule,
  },
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.label',
    'chapterUrl': r'$.href',
  },
  'ruleContent': {'content': r'$.text'},
};

const _continuationOrigin = 'http://same-page.test';
String _continuationBody(bool json, {String toc = '/book', String next = ''}) =>
    json
    ? jsonEncode({
        'title': 'Book',
        'toc': toc,
        'next': next,
        'chapters': [
          {'name': 'One', 'url': '/c/1'},
        ],
      })
    : '<h1>Book</h1>'
          '<a class="toc" href="${HtmlEscape().convert(toc)}">目录</a>'
          '<div class="chapters"><a href="/c/1">One</a></div>';
Map<String, dynamic> _continuationSource(bool json, {String? tocRule}) => {
  'bookSourceUrl': _continuationOrigin,
  'searchUrl': '/book,{"headers":{"X-Probe":"keep"}}',
  'bookUrlPattern': r'.*/book',
  'ruleSearch': {
    'bookList': json ? r'$.missing[*]' : '.missing',
    'name': json ? r'$.title' : 'h1@text',
    'bookUrl': json ? r'$.url' : 'a@href',
  },
  'ruleBookInfo': {
    'name': json ? r'$.title' : 'h1@text',
    'tocUrl': tocRule ?? (json ? r'$.toc' : 'a.toc@href'),
  },
  'ruleToc': {
    'chapterList': json ? r'$.chapters[*]' : '.chapters a',
    'chapterName': json ? r'$.name' : 'a@text',
    'chapterUrl': json ? r'$.url' : 'a@href',
  },
};

/// The repair06 page shape [_htmlSource]/[_jsonSource] read: one search hit, a
/// detail name, a cover, the TOC rule's own value and one chapter address.
String _repair06Page(
  bool json, {
  String book = '/book/1',
  String toc = '',
  String cover = '',
  String chapter = '/c/1',
  bool hit = true,
}) => json
    ? jsonEncode({
        'title': 'Book',
        'toc': toc,
        'cover': cover,
        if (hit)
          'listing': [
            {'name': 'Book', 'url': book},
          ],
        'list': [
          {'label': 'Chapter', 'href': chapter},
        ],
      })
    : '<h1>Book</h1>'
          '${hit ? '<div class="item"><h3><a href="${HtmlEscape().convert(book)}">Book</a></h3></div>' : ''}'
          '<img class="cover" src="${HtmlEscape().convert(cover)}">'
          '<a class="toc" href="${HtmlEscape().convert(toc)}">TOC</a>'
          '<ul id="list"><li><a href="${HtmlEscape().convert(chapter)}">Chapter</a></li></ul>';

class _ContinuationPages implements BookSourceTransport, SourceHttpTransport {
  _ContinuationPages(
    this.document, {
    this.allowedPaths = const ['/book', '/else'],
  });
  final String document;
  final List<String> allowedPaths;
  final requests = <SourceHttpRequest>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('Real send required');
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    if (!allowedPaths.contains(request.url.path)) {
      throw StateError('Unexpected ${request.url}');
    }
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: document,
      url: request.url,
    );
  }
}

BookSourcePipeline _openContinuation(
  bool json,
  Map<String, dynamic> data,
  _ContinuationPages transport, {
  SourceHostState? state,
}) => json
    ? JsonSourcePipeline(data, transport, hostState: state)
    : HtmlSourcePipeline(data, transport, hostState: state);

Future<Object?> _errorOrNull(Future<dynamic> future) async {
  try {
    await future;
    return null;
  } catch (error) {
    return error;
  }
}

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
    test(
      'a JSON source with a non-rule downloadUrls still reads details',
      () async {
        final document = jsonEncode({
          'author': '作者甲',
          'chapters': [
            {'name': '第一章', 'url': '/c/1'},
          ],
        });
        final (
          book,
          chapters,
        ) = await JsonSourcePipeline({
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
      },
    );

    // A chapter whose URL rule carries an option tail keeps it: the raw address
    // is what the store holds and what the chapter's own fetch parses
    // (`SourceChapter.options`). The TOC builder used to refuse such a tail by
    // name (零点看书's `ruleToc.chapterUrl` ends in `##$##,{"headers": …}`).
    test(
      'a chapter address with a header tail reaches the chapter list',
      () async {
        final transport = _Pages({
          '/book/7':
              '<ul class="chapters">'
              '<li><a href="/c/1##\$##,{&quot;headers&quot;:{&quot;X-Test&quot;:&quot;1&quot;}}">第一章</a></li>'
              '</ul>',
        });
        final (
          _,
          chapters,
        ) = await HtmlSourcePipeline({
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
      },
    );
  });

  group('the frozen shapes the product refused (#83)', () {
    // 5. The identity address is a plain string in the frozen (`BookSource.kt:34`
    // is an index key and a `baseUrl`), so a label identity with absolute rules
    // must read its stages; a fetchable target is required only where a request
    // is built.
    test(
      'a label identity with absolute rules reads its details and chapters',
      () async {
        final pages = _Pages({
          '/search':
              '<div class="item"><h3><a href="http://example.test/book/7">'
              '书</a></h3></div>',
          '/book/7':
              '<ul class="chapters"><li>'
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
      },
    );

    // 4. A blank `ruleToc.chapterUrl` is not a refusal: the frozen reads the
    // empty rule list as `""` and takes the empty-URL fallback
    // (`BookChapterList.kt:229-243`), which this TOC builder already applies.
    test('a blank chapterUrl takes the TOC page address', () async {
      final pages = _Pages({
        '/book/7':
            '<ul class="chapters">'
            '<li><a>第一章</a></li>'
            '</ul>',
      });
      final (
        _,
        chapters,
      ) = await HtmlSourcePipeline({
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
    test(
      'a JSON source declaring imageStyle and replaceRegex reads its stages',
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
      },
    );

    // 3. A field whose text has nothing left to parse is read by this tree's
    // own runtime; only the product's `validate` refused it.
    test(
      'a JSON content rule that is an @get: token reads its content',
      () async {
        final transport = _Pages({'/c/1': jsonEncode({})});
        final source = <String, dynamic>{
          'bookSourceUrl': 'http://example.test',
          'ruleContent': {'content': '@get:title'},
        };
        final body = await JsonSourcePipeline(
          source,
          transport,
        ).chapter(SourceChapter('第一章', Uri.parse('http://example.test/c/1')));
        expect(body.text, '第一章');
      },
    );
  });

  group('retained search and same-page information responses', () {
    test(
      'HTML detail and deferred handoff reuse nonempty search text',
      () async {
        final origin = 'http://example.test';
        final transport = _Pages({'/detail/73': _detailPage});
        final source = _htmlSource(
          origin,
          searchUrl: '/detail/73?key={{key}}',
          bookUrlPattern: r'.*/detail/\d+.*',
        );
        final pipeline = HtmlSourcePipeline(source, transport);
        final hit = (await pipeline.search('书')).single;
        expect(transport.requests, ['$origin/detail/73?key=%E4%B9%A6']);
        final info = await pipeline.bookInfo(hit);
        expect(info.book.title, '真实标题');
        expect(transport.requests, ['$origin/detail/73?key=%E4%B9%A6']);
        final deferred = HtmlSourcePipeline(source, transport);
        try {
          final deferredInfo = await deferred.bookInfo(
            hit.withVariable('{"k":1}'),
          );
          expect(deferredInfo.book.title, '真实标题');
          expect(transport.requests, ['$origin/detail/73?key=%E4%B9%A6']);
        } finally {
          deferred.cancel();
        }
        pipeline.cancel();
      },
    );

    test('JSON empty-list fallback reuses nonempty search text', () async {
      final origin = 'http://example.test';
      final transport = _Pages({'/detail/73': jsonEncode(_detailDocument)});
      final pipeline = JsonSourcePipeline(
        _jsonSource(origin, searchUrl: '/detail/73?key={{key}}'),
        transport,
      );
      final hit = (await pipeline.search('书')).single;
      final info = await pipeline.bookInfo(hit);
      expect(info.book.title, '真实标题');
      expect(transport.requests, ['$origin/detail/73?key=%E4%B9%A6']);
      pipeline.cancel();
    });

    test(
      'unrelated ordinary list hit still fetches its information page',
      () async {
        final origin = 'http://example.test';
        final transport = _Pages({
          '/search': _listPage,
          '/book/1': _detailPage,
        });
        final pipeline = HtmlSourcePipeline(_htmlSource(origin), transport);
        final hit = (await pipeline.search('书')).single;
        expect(transport.requests, ['$origin/search?key=%E4%B9%A6']);
        await pipeline.bookInfo(hit);
        expect(transport.requests, [
          '$origin/search?key=%E4%B9%A6',
          '$origin/book/1',
        ]);
        pipeline.cancel();
      },
    );

    test('cached information skips a second login check', () async {
      final origin = 'http://example.test';
      final transport = _Pages({'/detail/73': _detailPage});
      final state = SourceHostState();
      final source =
          _htmlSource(
              origin,
              searchUrl: '/detail/73?key={{key}}',
              bookUrlPattern: r'.*/detail/\d+.*',
            )
            ..['loginCheckJs'] =
                "source.put('loginChecks', String(Number(source.get('loginChecks')||'0')+1)); result";
      final pipeline = HtmlSourcePipeline(source, transport, hostState: state);
      final hit = (await pipeline.search('书')).single;
      final key = sourceRuleVariableKey(origin, 'loginChecks');
      expect(await state.entry(origin, key), '1');
      await pipeline.bookInfo(hit);
      expect(await state.entry(origin, key), '1');
      final deferred = HtmlSourcePipeline(source, transport, hostState: state);
      try {
        await deferred.bookInfo(hit);
        expect(await state.entry(origin, key), '1');
      } finally {
        deferred.cancel();
      }
      pipeline.cancel();
    });

    test('HTML same-page TOC reuses only the first response', () async {
      final origin = 'http://example.test';
      final transport = _Pages({
        '/search': '<div class="item"><a href="/book/7">书</a></div>',
        '/book/7': '<h1>书</h1><div id="list"><a href="/c/1">章</a></div>',
      });
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': 'div.item',
          'name': 'a@text',
          'bookUrl': 'a@href',
        },
        'ruleBookInfo': {'name': 'h1@text'},
        'ruleToc': {
          'chapterList': '#list@a',
          'chapterName': '@text',
          'chapterUrl': '@href',
        },
      };
      final pipeline = HtmlSourcePipeline(source, transport);
      final hit = (await pipeline.search('书')).single;
      expect(transport.requests, ['$origin/search?key=%E4%B9%A6']);
      final info = await pipeline.bookInfo(hit);
      expect(transport.requests, [
        '$origin/search?key=%E4%B9%A6',
        '$origin/book/7',
      ]);
      final (_, chapters) = await pipeline.tableOfContents(info);
      expect(chapters.single.name, '章');
      expect(transport.requests, [
        '$origin/search?key=%E4%B9%A6',
        '$origin/book/7',
      ]);
      pipeline.cancel();
    });
  });

  group('actual fallback and retained TOC identity', () {
    for (final json in [false, true]) {
      test(
        'unredirected identity retains no-query options json=$json',
        () async {
          final transport = _ContinuationPages(_continuationBody(json));
          final pipeline = _openContinuation(
            json,
            _continuationSource(json),
            transport,
          );
          try {
            final hit = (await pipeline.search('Book')).single;
            expect(transport.requests.single.headers['X-Probe'], 'keep');
            expect(
              hit.identityAddress,
              '$_continuationOrigin/book,{"headers":{"X-Probe":"keep"}}',
            );
          } finally {
            pipeline.cancel();
          }
        },
      );
      test(
        'explicit relative same-page TOC reuses one response json=$json',
        () async {
          final transport = _ContinuationPages(_continuationBody(json));
          final pipeline = _openContinuation(
            json,
            _continuationSource(json, tocRule: json ? r'$.toc' : 'a.toc@href'),
            transport,
          );
          try {
            final info = await pipeline.bookInfo(
              HtmlBook(
                url: Uri.parse('$_continuationOrigin/book'),
                title: 'Book',
              ),
            );
            expect(info.tocUrl, '$_continuationOrigin/book');
            expect(transport.requests, hasLength(1));
            await pipeline.tableOfContents(info);
            expect(transport.requests, hasLength(1));
          } finally {
            pipeline.cancel();
          }
        },
      );
    }
    test('JSON retained same-page TOC bypasses URL option JS', () async {
      final state = SourceHostState();
      final identity =
          '$_continuationOrigin/book,{"js":"source.put(\'tocOption\',\'ran\'); \'$_continuationOrigin/book\'"}';
      final transport = _ContinuationPages(_continuationBody(true));
      final pipeline = _openContinuation(
        true,
        _continuationSource(true, tocRule: '@js:${jsonEncode(identity)}'),
        transport,
        state: state,
      );
      final key = sourceRuleVariableKey(_continuationOrigin, 'tocOption');
      try {
        final info = await pipeline.bookInfo(
          HtmlBook(
            url: Uri.parse('$_continuationOrigin/book'),
            rawAddress: identity,
            title: 'Book',
            infoHtml: _continuationBody(true),
          ),
        );
        expect(info.tocUrl, identity);
        expect(await state.entry(_continuationOrigin, key), isNull);
        await pipeline.tableOfContents(info);
        expect(await state.entry(_continuationOrigin, key), isNull);
        expect(transport.requests, isEmpty);
      } finally {
        pipeline.cancel();
      }
    });
  });

  group('different TOC option tails remain ordinary work', () {
    for (final json in [false, true]) {
      test(
        'different header options force a real TOC request json=$json',
        () async {
          final origin = _continuationOrigin;
          final identity =
              '$origin/book,${jsonEncode({
                'headers': {'X-TOC': 'new'},
              })}';
          final transport = _ContinuationPages(_continuationBody(json));
          final pipeline = _openContinuation(
            json,
            _continuationSource(json, tocRule: '@js:${jsonEncode(identity)}'),
            transport,
          );
          try {
            final info = await pipeline.bookInfo(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'Book'),
            );
            expect(info.tocUrl, identity);
            expect(transport.requests, hasLength(1));
            final (_, chapters) = await pipeline.tableOfContents(info);
            expect(chapters.single.name, 'One');
            expect(transport.requests, hasLength(2));
            expect(transport.requests.last.headers['X-TOC'], 'new');
          } finally {
            pipeline.cancel();
          }
        },
      );
      test(
        'different URL script runs its ordinary side effect json=$json',
        () async {
          final origin = _continuationOrigin;
          final state = SourceHostState();
          final script = "source.put('ordinaryToc','ran'); '$origin/else'";
          final identity = '$origin/book,${jsonEncode({'js': script})}';
          final transport = _ContinuationPages(_continuationBody(json));
          final pipeline = _openContinuation(
            json,
            _continuationSource(json, tocRule: '@js:${jsonEncode(identity)}'),
            transport,
            state: state,
          );
          final key = sourceRuleVariableKey(origin, 'ordinaryToc');
          try {
            final info = await pipeline.bookInfo(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'Book'),
            );
            expect(info.tocUrl, identity);
            await pipeline.tableOfContents(info);
            expect(await state.entry(origin, key), 'ran');
            expect(transport.requests.last.url.path, '/else');
          } finally {
            pipeline.cancel();
          }
        },
      );
    }
  });

  group('review repair controls', () {
    for (final json in [false, true]) {
      test(
        'cancelled retained information and TOC refuse before effects json=$json',
        () async {
          final pages = _ContinuationPages(_continuationBody(json));
          final pipeline = _openContinuation(
            json,
            _continuationSource(json),
            pages,
          );
          pipeline.cancel();
          final info = await _errorOrNull(
            pipeline.bookInfo(
              HtmlBook(
                url: Uri.parse('$_continuationOrigin/book'),
                title: 'Book',
                infoHtml: _continuationBody(json),
              ),
            ),
          );
          expect(info, isA<SourceRequestCancelled>());
          expect(pages.requests, isEmpty);
          final tocPages = _ContinuationPages(_continuationBody(json));
          final tocPipeline = _openContinuation(
            json,
            _continuationSource(json),
            tocPages,
          );
          final retained = await tocPipeline.bookInfo(
            HtmlBook(
              url: Uri.parse('$_continuationOrigin/book'),
              title: 'Book',
            ),
          );
          tocPipeline.cancel();
          final tocError = await _errorOrNull(
            tocPipeline.tableOfContents(retained),
          );
          expect(tocError, isA<SourceRequestCancelled>());
          expect(tocPages.requests, hasLength(1));
          tocPipeline.cancel();
          pipeline.cancel();
        },
      );
    }

    for (final retainedFirst in [false, true]) {
      test(
        'actual JSON header precedes first uncached TOC URL script retainedFirst=$retainedFirst',
        () async {
          final state = SourceHostState();
          const optionScript =
              "var seen=String(source.get('observedHeader')||''); if(seen==='') source.put('observedHeader','seen:'+String(source.get('headerRuns'))); result";
          final next =
              '$_continuationOrigin/else,${jsonEncode({'js': optionScript})}';
          final data = _continuationSource(
            true,
            tocRule:
                '@js:${jsonEncode(retainedFirst ? '$_continuationOrigin/book' : next)}',
          );
          data['header'] =
              '@js:source.put("headerRuns","ready"); JSON.stringify({"X-Source":"keep"})';
          if (retainedFirst) {
            (data['ruleToc'] as Map<String, dynamic>)['nextTocUrl'] = r'$.next';
          }
          final body = _continuationBody(true, next: retainedFirst ? next : '');
          final pages = _ContinuationPages(body);
          final pipeline = JsonSourcePipeline(data, pages, hostState: state);
          try {
            final info = await pipeline.bookInfo(
              HtmlBook(
                url: Uri.parse('$_continuationOrigin/book'),
                title: 'Book',
                infoHtml: body,
              ),
            );
            expect(info.book.title, 'Book');
            expect(pages.requests, isEmpty);
            expect(
              await state.entry(
                _continuationOrigin,
                sourceRuleVariableKey(_continuationOrigin, 'headerRuns'),
              ),
              isNull,
              reason: 'Retained information must not eagerly evaluate headers',
            );
            final (_, chapters) = await pipeline.tableOfContents(info);
            expect(chapters, isNotEmpty);
            expect(pages.requests.single.url.path, '/else');
            expect(pages.requests.single.headers['X-Source'], 'keep');
            expect(
              await state.entry(
                _continuationOrigin,
                sourceRuleVariableKey(_continuationOrigin, 'headerRuns'),
              ),
              'ready',
            );
            expect(
              await state.entry(
                _continuationOrigin,
                sourceRuleVariableKey(_continuationOrigin, 'observedHeader'),
              ),
              'seen:ready',
              reason: 'The URL script must observe the completed header run',
            );
          } finally {
            pipeline.cancel();
          }
        },
      );
    }

    for (final json in [false, true]) {
      test('absolute published TOC keeps native text json=$json', () async {
        const address =
            'http://UPPER.test/目录?q=书,{"headers":{"X-Value":"keep"}}';
        final body = _continuationBody(json, toc: address);
        final pages = _ContinuationPages(body);
        final pipeline = _openContinuation(
          json,
          _continuationSource(json),
          pages,
        );
        try {
          final info = await pipeline.bookInfo(
            HtmlBook(
              url: Uri.parse('$_continuationOrigin/book'),
              title: 'Book',
              infoHtml: body,
            ),
          );
          expect(info.book.title, 'Book');
          expect(pages.requests, isEmpty);
          expect(info.tocAddress, address);
          expect(info.tocUrl, address);
        } finally {
          pipeline.cancel();
        }
      });
    }

    test(
      'ordinary same-path different full identity performs information work',
      () async {
        final pages = _ContinuationPages(
          '<h1>Book</h1><div class="item"><a href="book,{&quot;method&quot;:&quot;POST&quot;,&quot;body&quot;:&quot;x=1&quot;,&quot;headers&quot;:{&quot;X-Detail&quot;:&quot;new&quot;}}">Book</a></div>'
          '<div class="chapters"><a href="/c/1">One</a></div>',
        );
        final source = <String, dynamic>{
          'bookSourceUrl': _continuationOrigin,
          'searchUrl': '/book',
          'ruleSearch': {
            'bookList': '.item',
            'name': 'a@text',
            'bookUrl': 'a@href',
          },
          'ruleBookInfo': {'name': 'h1@text'},
          'ruleToc': {
            'chapterList': '.chapters a',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          },
        };
        final pipeline = HtmlSourcePipeline(source, pages);
        final hit = (await pipeline.search('Book')).single;
        expect(pages.requests, hasLength(1));
        final info = await pipeline.bookInfo(hit);
        expect(info.book.title, 'Book');
        expect(pages.requests, hasLength(2));
        expect(pages.requests.last.method, 'POST');
        expect(pages.requests.last.body, 'x=1');
        expect(pages.requests.last.headers['X-Detail'], 'new');
        pipeline.cancel();
      },
    );

    test(
      'ordinary same-path different full identity performs JSON information work',
      () async {
        final pages = _ContinuationPages(
          jsonEncode({
            'items': [
              {
                'name': 'Book',
                'url':
                    'book,{"method":"POST","body":"x=1","headers":{"X-Detail":"new"}}',
              },
            ],
            'title': 'Book',
            'toc': '/book',
            'chapters': [
              {'name': 'One', 'url': '/c/1'},
            ],
          }),
        );
        final source = <String, dynamic>{
          'bookSourceUrl': _continuationOrigin,
          'searchUrl': '/book',
          'ruleSearch': {
            'bookList': r'$.items[*]',
            'name': r'$.name',
            'bookUrl': r'$.url',
          },
          'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
          'ruleToc': {
            'chapterList': r'$.chapters[*]',
            'chapterName': r'$.name',
            'chapterUrl': r'$.url',
          },
        };
        final pipeline = JsonSourcePipeline(source, pages);
        final hit = (await pipeline.search('Book')).single;
        expect(pages.requests, hasLength(1));
        final info = await pipeline.bookInfo(hit);
        expect(info.book.title, 'Book');
        expect(pages.requests, hasLength(2));
        expect(pages.requests.last.method, 'POST');
        expect(pages.requests.last.body, 'x=1');
        expect(pages.requests.last.headers['X-Detail'], 'new');
        pipeline.cancel();
      },
    );

    test(
      'fresh JSON retained information initializes headers for real TOC',
      () async {
        final body = _continuationBody(true);
        final pages = _ContinuationPages(body);
        final source = _continuationSource(
          true,
          tocRule: '@js:${jsonEncode('$_continuationOrigin/else')}',
        );
        source['header'] = '{"X-Source":"keep"}';
        final pipeline = JsonSourcePipeline(source, pages);
        final info = await pipeline.bookInfo(
          HtmlBook(
            url: Uri.parse('$_continuationOrigin/book'),
            title: 'Book',
            infoHtml: body,
          ),
        );
        expect(pages.requests, isEmpty);
        await pipeline.tableOfContents(info);
        expect(pages.requests.single.url.path, '/else');
        expect(pages.requests.single.headers['X-Source'], 'keep');
        pipeline.cancel();
      },
    );
  });

  group('native textual identity and ordinary retention', () {
    for (final template in [false, true]) {
      test(
        'address context preserves native comparison across fresh handoff template=$template',
        () async {
          const origin = 'http://source.test';
          final raw = template ? '/book/{{key}}' : '/book/1';
          final body = jsonEncode({
            'title': 'Book',
            'toc': '/book/1',
            'items': [
              {'title': 'Book', 'url': raw},
            ],
            'list': [
              {'name': 'Chapter', 'url': '/c/1'},
            ],
          });
          final pages = _Pages({'/search': body, '/book/1': body});
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'searchUrl': '/search',
            'bookUrlPattern': r'$^',
            'ruleSearch': {
              'bookList': r'$.items[*]',
              'name': r'$.title',
              'bookUrl': r'$.url',
            },
            'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
            'ruleToc': {
              'chapterList': r'$.list[*]',
              'chapterName': r'$.name',
              'chapterUrl': r'$.url',
            },
          };
          final same = JsonSourcePipeline(source, pages);
          final fresh = JsonSourcePipeline(source, pages);
          try {
            final hit = (await same.search('1')).single;
            expect(hit.addressContext, isNotNull);
            expect(
              hit.addressContext!.comparisonAddress,
              template ? '$origin/book/{{key}}' : '$origin/book/1',
            );
            expect(hit.addressContext!.publicationAddress, '$origin/book/1');
            expect(hit.toJson().containsKey('addressContext'), isFalse);
            expect(
              hit.withVariable('{"seed":"x"}').addressContext,
              hit.addressContext,
            );
            final sameInfo = await same.bookInfo(hit);
            final freshInfo = await fresh.bookInfo(hit);
            expect(sameInfo.tocHtml, template ? isNull : isNotNull);
            expect(freshInfo.tocHtml, sameInfo.tocHtml);
          } finally {
            same.cancel();
            fresh.cancel();
          }
        },
      );
    }

    for (final fallback in [false, true]) {
      for (final rooted in [false, true]) {
        test(
          'HTML relative special publication fallback=$fallback rooted=$rooted',
          () async {
            const origin = 'http://source.test';
            const targetOrigin = 'http://other.test';
            final raw = '${rooted ? '/' : ''}目录?q=书';
            final tail =
                ',${jsonEncode({'js': "source.put('specialRuns', String(Number(source.get('specialRuns')||'0')+1)); '$targetOrigin/wire'"})}';
            final body =
                '<h2>Book</h2><a id="toc" href="/toc">TOC</a>'
                '<ul id="list"><li><a href="/c/1">Chapter</a></li></ul>';
            final pages = _Pages({'/wire': body});
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': raw + tail,
              'bookUrlPattern': fallback ? '' : '.*',
              'ruleSearch': {
                'bookList': '.missing',
                'name': 'h2@text',
                'bookUrl': 'a@href',
              },
              'ruleBookInfo': {'name': 'h2@text', 'tocUrl': '#toc@href'},
              'ruleToc': {
                'chapterList': '#list li',
                'chapterName': 'a@text',
                'chapterUrl': 'a@href',
              },
            };
            final pipeline = HtmlSourcePipeline(source, pages);
            try {
              final hit = (await pipeline.search('x')).single;
              expect(hit.title, 'Book');
              expect(hit.url.toString(), '$targetOrigin/wire');
              expect(hit.identityAddress, '$targetOrigin/目录?q=书$tail');
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    for (final raw in ['/book/1', "@js: '/book/1'", "<js>'/book/1'</js>"]) {
      test('JSON literal native admission scalar=$raw', () async {
        const origin = 'http://source.test';
        final body = jsonEncode({
          'title': 'Book',
          'toc': '/toc',
          'items': [
            {'title': 'Book', 'url': raw},
          ],
          'list': [
            {'name': 'Chapter', 'url': '/c/1'},
          ],
        });
        final pages = _Pages({'/book/1': body});
        final state = SourceHostState();
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'searchUrl': '/book/1',
          'bookUrlPattern': r'$^',
          'loginCheckJs':
              "source.put('checks', String(Number(source.get('checks')||'0')+1)); result",
          'ruleSearch': {
            'bookList': r'$.items[*]',
            'name': r'$.title',
            'bookUrl': r'$.url',
          },
          'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
          'ruleToc': {
            'chapterList': r'$.list[*]',
            'chapterName': r'$.name',
            'chapterUrl': r'$.url',
          },
        };
        final pipeline = JsonSourcePipeline(source, pages, hostState: state);
        try {
          final hit = (await pipeline.search('1')).single;
          expect(hit.title, 'Book');
          expect(hit.identityAddress, '$origin/book/1');
          final info = await pipeline.bookInfo(hit);
          expect(info.book.title, 'Book');
          final literal = raw == '/book/1';
          expect(hit.infoHtml != null, literal);
          expect(pages.requests, hasLength(literal ? 1 : 2));
          expect(
            await state.entry(origin, sourceRuleVariableKey(origin, 'checks')),
            literal ? '1' : '2',
          );
        } finally {
          pipeline.cancel();
        }
      });
    }

    for (final seed in ['/book/1', '/seed']) {
      test('HTML finished field scalar seed=$seed', () async {
        const origin = 'http://source.test';
        final body =
            '<h2>Book</h2><ul id="list"><li><a href="/c/1">Chapter</a></li></ul>';
        final pages = _Pages({'/book/1': body});
        final state = SourceHostState();
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'searchUrl': '/book/1',
          'loginCheckJs':
              "source.put('checks', String(Number(source.get('checks')||'0')+1)); result",
          'ruleSearch': {
            'bookList': '@js:${jsonEncode([seed])}',
            'name': "@js:'Book'",
            'bookUrl':
                "@js:source.put('urlReads', String(Number(source.get('urlReads')||'0')+1)); '/book/1'",
          },
          'ruleBookInfo': {'name': 'h2@text', 'tocUrl': '#toc@href'},
          'ruleToc': {
            'chapterList': '#list li',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          },
        };
        final pipeline = HtmlSourcePipeline(source, pages, hostState: state);
        try {
          final hit = (await pipeline.search('x')).single;
          expect(hit.title, 'Book');
          expect(hit.identityAddress, '$origin/book/1');
          final info = await pipeline.bookInfo(hit);
          expect(info.book.title, 'Book');
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'urlReads'),
            ),
            '1',
          );
          expect(hit.infoHtml, isNotNull);
          expect(pages.requests, hasLength(1));
        } finally {
          pipeline.cancel();
        }
      });
    }

    for (final fresh in [false, true]) {
      for (final template in [false, true]) {
        test(
          'encoded query fetched base sameFresh=$fresh template=$template',
          () async {
            const origin = 'http://source.test';
            final raw = '/book/${template ? '{{key}}' : '1'}?keep=a%23tail&x=1';
            final body = jsonEncode({
              'title': 'Book',
              'toc': '#next',
              'items': [
                {'title': 'Book', 'url': raw},
              ],
              'list': [
                {'name': 'Chapter', 'url': '/c/1'},
              ],
            });
            final pages = _Pages({'/search': body, '/book/1': body});
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': '/search',
              'bookUrlPattern': r'$^',
              'ruleSearch': {
                'bookList': r'$.items[*]',
                'name': r'$.title',
                'bookUrl': r'$.url',
              },
              'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
              'ruleToc': {
                'chapterList': r'$.list[*]',
                'chapterName': r'$.name',
                'chapterUrl': r'$.url',
              },
            };
            final pipeline = JsonSourcePipeline(source, pages);
            final next = fresh ? JsonSourcePipeline(source, pages) : pipeline;
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.identityAddress, '$origin/book/1?keep=a%23tail&x=1');
              expect(hit.infoHtml, isNull);
              final info = await next.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(info.tocAddress, '#next');
              expect(pages.requests, hasLength(2));
              expect(pages.requests.last, '$origin/book/1?keep=a%23tail&x=1');
              expect(info.tocUrl, '$origin/book/1?keep=a%23tail&x=1#next');
            } finally {
              if (fresh) next.cancel();
              pipeline.cancel();
            }
          },
        );
      }
    }

    for (final crossOrigin in [false, true]) {
      test(
        'ordinary JSON ${crossOrigin ? 'other-origin' : 'same-origin'} script keeps pre-option identity',
        () async {
          const origin = 'http://source.test';
          final target = crossOrigin
              ? 'http://other.test/wire'
              : '$origin/wire';
          final tail = ',${jsonEncode({'js': jsonEncode(target)})}';
          final raw = 'detail?q=书$tail';
          final body = jsonEncode({
            'items': [
              {'title': 'Book', 'url': raw},
            ],
          });
          final pages = _Pages({'/catalog/search': body});
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'searchUrl': '/catalog/search',
            'ruleSearch': {
              'bookList': r'$.items[*]',
              'name': r'$.title',
              'bookUrl': r'$.url',
            },
          };
          final pipeline = JsonSourcePipeline(source, pages);
          try {
            final hit = (await pipeline.search('x')).single;
            expect(hit.title, 'Book');
            expect(hit.url.toString(), target);
            expect(
              hit.preOptionUrl.toString(),
              '$origin/catalog/detail?q=%E4%B9%A6',
            );
            expect(
              hit.identityAddress,
              '$origin/catalog/detail?q=%E4%B9%A6$tail',
            );
            expect(pages.requests.single, '$origin/catalog/search');
          } finally {
            pipeline.cancel();
          }
        },
      );
    }

    for (final json in [false, true]) {
      for (final rawQuery in [false, true]) {
        test(
          'ordinary native textual equality gates retention json=$json raw=$rawQuery',
          () async {
            final raw = rawQuery ? '/book?q=书' : '/book?q=%E4%B9%A6';
            const origin = 'http://source.test';
            final body = json
                ? jsonEncode({
                    'title': 'Book',
                    'toc': '',
                    'items': [
                      {'title': 'Book', 'url': raw},
                    ],
                  })
                : '<h2>Book</h2><div class="item"><a href="$raw">Book</a></div>';
            final pages = _Pages({'/book': body});
            final state = SourceHostState();
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': '/book?q=%E4%B9%A6',
              'bookUrlPattern': r'$^',
              'loginCheckJs':
                  "source.put('loginChecks', String(Number(source.get('loginChecks')||'0')+1)); result",
              'ruleSearch': json
                  ? {
                      'bookList': r'$.items[*]',
                      'name': r'$.title',
                      'bookUrl': r'$.url',
                    }
                  : {
                      'bookList': '.item',
                      'name': 'a@text',
                      'bookUrl': 'a@href',
                    },
              'ruleBookInfo': json
                  ? {'name': r'$.title', 'tocUrl': r'$.toc'}
                  : {'name': 'h2@text', 'tocUrl': '#toc@href'},
            };
            final pipeline = json
                ? JsonSourcePipeline(source, pages, hostState: state)
                : HtmlSourcePipeline(source, pages, hostState: state);
            try {
              final hit = (await pipeline.search('x')).single;
              expect(hit.title, 'Book');
              expect(hit.identityAddress, '$origin/book?q=%E4%B9%A6');
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(pages.requests, hasLength(rawQuery ? 2 : 1));
              expect(
                await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, 'loginChecks'),
                ),
                rawQuery ? '2' : '1',
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }
  });

  group('repair05 JSON fetched response URL base', () {
    for (final scenario in ['plain', 'redirect', 'retain', 'empty']) {
      test('real loopback scenario=$scenario', () async {
        final redirected = scenario != 'plain';
        final toc = scenario == 'retain'
            ? '../../book/1'
            : scenario == 'empty'
            ? ''
            : 'toc';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final base = 'http://127.0.0.1:${server.port}';
        final seen = <String>[];
        final body = jsonEncode({
          'title': 'Book',
          'toc': toc,
          'items': [
            {'title': 'Book', 'url': '/book/1'},
          ],
        });
        server.listen((request) async {
          seen.add(request.uri.path);
          if (redirected && request.uri.path == '/book/1') {
            request.response.statusCode = 302;
            request.response.headers.set('Location', '/alt/deep/info');
          } else {
            request.response.headers.contentType = ContentType.json;
            request.response.write(body);
          }
          await request.response.close();
        });
        final source = <String, dynamic>{
          'bookSourceUrl': base,
          'searchUrl': '/search',
          'bookUrlPattern': r'$^',
          'ruleSearch': {
            'bookList': r'$.items[*]',
            'name': r'$.title',
            'bookUrl': r'$.url',
          },
          'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
        };
        final pipeline = JsonSourcePipeline(source, HttpSourceTransport());
        try {
          final hit = (await pipeline.search('1')).single;
          expect(hit.title, 'Book');
          expect(hit.url.toString(), '$base/book/1');
          final info = await pipeline.bookInfo(hit);
          expect(info.book.title, 'Book');
          expect(info.tocAddress, toc);
          expect(
            seen,
            redirected
                ? ['/search', '/book/1', '/alt/deep/info']
                : ['/search', '/book/1'],
          );
          if (toc.isNotEmpty) {
            final expectedBase =
                '$base/${redirected ? 'alt/deep/info' : 'book/1'}';
            expect(info.tocBase.toString(), expectedBase);
            expect(
              info.tocUrl,
              scenario == 'retain'
                  ? '$base/book/1'
                  : '$base/${redirected ? 'alt/deep' : 'book'}/toc',
            );
          } else {
            expect(info.tocUrl, '$base/book/1');
          }
          expect(
            info.tocHtml != null,
            scenario == 'retain' || scenario == 'empty',
          );
        } finally {
          pipeline.cancel();
          await server.close(force: true);
        }
      });
    }
  });

  group('repair05 finished scalar and resolved publication', () {
    test(
      'HTML ordinary publication resolves against the search page',
      () async {
        const origin = 'http://source.test';
        final body =
            '<div class="item"><a href="book/1">Book</a></div>'
            '<h2>Book</h2><ul id="list"><li><a href="">Chapter</a></li></ul>';
        final pages = _Pages({
          '/catalog/search': body,
          '/catalog/book/1': body,
        });
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'searchUrl': '/catalog/search',
          'ruleSearch': {
            'bookList': '.item',
            'name': 'a@text',
            'bookUrl': 'a@href',
          },
          'ruleBookInfo': {'name': 'h2@text', 'tocUrl': ''},
          'ruleToc': {
            'chapterList': '#list li',
            'chapterName': 'a@text',
            'chapterUrl': 'a@href',
          },
        };
        final pipeline = HtmlSourcePipeline(source, pages);
        try {
          final hit = (await pipeline.search('1')).single;
          expect(hit.title, 'Book');
          expect(
            hit.addressContext?.publicationAddress,
            '$origin/catalog/book/1',
          );
          final info = await pipeline.bookInfo(hit);
          final (_, chapters) = await pipeline.tableOfContents(info);
          expect(info.tocUrl, '$origin/catalog/book/1');
          expect(chapters.single.address, '$origin/catalog/book/1');
        } finally {
          pipeline.cancel();
        }
      },
    );

    test('HTML interpolation admission uses the finished scalar once', () async {
      const origin = 'http://source.test';
      final body =
          '<h2>Book</h2><ul id="list"><li><a href="/c/1">Chapter</a></li></ul>';
      final pages = _Pages({'/book/1': body});
      final state = SourceHostState();
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/book/1',
        'loginCheckJs':
            "source.put('checks', String(Number(source.get('checks')||'0')+1)); result",
        'ruleSearch': {
          'bookList': '@js:${jsonEncode(['/seed'])}',
          'name': "@js:'Book'",
          'bookUrl': '{{"/book/1"}}',
        },
        'ruleBookInfo': {'name': 'h2@text', 'tocUrl': ''},
      };
      final pipeline = HtmlSourcePipeline(source, pages, hostState: state);
      try {
        final hit = (await pipeline.search('1')).single;
        expect(hit.title, 'Book');
        expect(hit.identityAddress, '$origin/book/1');
        expect(hit.addressContext?.comparisonAddress, '$origin/book/1');
        final info = await pipeline.bookInfo(hit);
        expect(info.book.title, 'Book');
        expect(hit.infoHtml, isNotNull);
        expect(
          await state.entry(origin, sourceRuleVariableKey(origin, 'checks')),
          '1',
        );
      } finally {
        pipeline.cancel();
      }
    });
  });

  group('repair05 retained native bases and captured-key order', () {
    test('retained raw uppercase authority survives publication', () async {
      const origin = 'http://UPPER.test/catalog/book?keep=word';
      final body = '<h2>Book</h2><a id="toc" href="#next">TOC</a>';
      final pages = _Pages({'/catalog/book': body});
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': origin,
        'bookUrlPattern': '.*',
        'ruleBookInfo': {'name': 'h2@text', 'tocUrl': '#toc@href'},
      };
      final pipeline = HtmlSourcePipeline(source, pages);
      try {
        final hit = (await pipeline.search('1')).single;
        final info = await pipeline.bookInfo(hit);
        expect(info.tocUrl, '$origin#next');
      } finally {
        pipeline.cancel();
      }
    });

    test('captured key refusal precedes option effects', () async {
      const origin = 'http://source.test';
      final body = jsonEncode({
        'title': 'Book',
        'items': [
          {'title': 'Book', 'url': '/book/1'},
        ],
      });
      final pages = _Pages({'/book': body});
      final state = SourceHostState();
      final tail =
          ',${jsonEncode({'charset': 'x-no-such-charset', 'js': "source.put('marker','ran'); '$origin/queryless'"})}';
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/book?q=x$tail',
        'ruleSearch': {
          'bookList': r'$.items[*]',
          'name': r'$.title',
          'bookUrl': r'$.url',
        },
      };
      final pipeline = JsonSourcePipeline(source, pages, hostState: state);
      try {
        await expectLater(
          pipeline.search('1'),
          throwsA(isA<UnsupportedError>()),
        );
        expect(
          await state.entry(origin, sourceRuleVariableKey(origin, 'marker')),
          isNull,
        );
        expect(pages.requests, isEmpty);
      } finally {
        pipeline.cancel();
      }
    });

    test('valid captured key executes its option once', () async {
      const origin = 'http://source.test';
      final searchBody = jsonEncode({
        'title': 'Book',
        'toc': '/toc',
        'items': [
          {'title': 'Book', 'url': '/book/1'},
        ],
        'list': [
          {'name': 'Chapter', 'url': '/c/1'},
        ],
      });
      final detailBody = jsonEncode({
        'title': 'Book',
        'toc': '/toc',
        'list': [
          {'name': 'Chapter', 'url': '/c/1'},
        ],
      });
      final pages = _Pages({
        '/queryless': searchBody,
        '/book/1': detailBody,
        '/toc': detailBody,
      });
      final state = SourceHostState();
      final tail =
          ',${jsonEncode({'charset': 'utf-8', 'js': "source.put('capturedEffect', String(Number(source.get('capturedEffect')||'0')+1)); '$origin/queryless'"})}';
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/book?q=x$tail',
        'ruleSearch': {
          'bookList': r'$.items[*]',
          'name': r'$.title',
          'bookUrl': r'$.url',
        },
        'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
      };
      final pipeline = JsonSourcePipeline(source, pages, hostState: state);
      try {
        final hit = (await pipeline.search('1')).single;
        expect(hit.title, 'Book');
        expect(hit.url.toString(), '$origin/book/1');
        expect(hit.identityAddress, '$origin/book/1');
        expect(hit.addressContext?.publicationAddress, '$origin/book/1');
        expect(pages.requests, ['$origin/queryless']);
        expect(
          await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'capturedEffect'),
          ),
          '1',
        );
      } finally {
        pipeline.cancel();
      }
    });

    for (final unknown in [false, true]) {
      test(
        'no-capture information option removes the unusable query unknownCharset=$unknown',
        () async {
          const origin = 'http://source.test';
          final tail =
              ',${jsonEncode({'charset': unknown ? 'x-no-such-charset' : 'utf-8', 'js': "source.put('tocOption','ran'); '$origin/toc'"})}';
          final toc = 'toc?q=x$tail';
          final body = jsonEncode({
            'title': 'Book',
            'toc': toc,
            'items': [
              {'title': 'Book', 'url': '/book'},
            ],
            'list': [
              {'name': 'Chapter', 'url': '/c/1'},
            ],
          });
          final pages = _Pages({'/book': body, '/toc': body});
          final state = SourceHostState();
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'searchUrl': '/book',
            'bookUrlPattern': '.*',
            'ruleSearch': {
              'bookList': r'$.items[*]',
              'name': r'$.title',
              'bookUrl': r'$.url',
            },
            'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
            'ruleToc': {
              'chapterList': r'$.list[*]',
              'chapterName': r'$.name',
              'chapterUrl': r'$.url',
            },
          };
          final pipeline = JsonSourcePipeline(source, pages, hostState: state);
          try {
            final hit = (await pipeline.search('x')).single;
            expect(hit.title, 'Book');
            expect(hit.identityAddress, '$origin/book');
            expect(pages.requests, ['$origin/book']);
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.tocAddress, toc);
            expect(info.tocHtml, isNull);
            expect(pages.requests, ['$origin/book']);
            final (_, chapters) = await pipeline.tableOfContents(info);
            expect(chapters.single.name, 'Chapter');
            expect(pages.requests, ['$origin/book', '$origin/toc']);
            expect(
              await state.entry(
                origin,
                sourceRuleVariableKey(origin, 'tocOption'),
              ),
              'ran',
            );
          } finally {
            pipeline.cancel();
          }
        },
      );
    }
  });

  group('repair05 same-path response provenance', () {
    for (final json in [false, true]) {
      for (final scenario in ['plain', 'query', 'authority']) {
        test('real same-path $scenario json=$json', () async {
          final first = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final second = scenario == 'authority'
              ? await HttpServer.bind(InternetAddress.loopbackIPv4, 0)
              : null;
          final origin = 'http://127.0.0.1:${first.port}';
          final finalOrigin = second == null
              ? origin
              : 'http://127.0.0.1:${second.port}';
          final toc = scenario == 'authority' ? 'toc' : '#next';
          final seen = <Map<String, String>>[];
          final body = json
              ? jsonEncode({
                  'title': 'Book',
                  'toc': toc,
                  'items': [
                    {'title': 'Book', 'url': '/book/1?q=word'},
                  ],
                })
              : '<h2>Book</h2><div class="item"><a href="/book/1?q=word">Book</a></div>'
                    '<a id="toc" href="$toc">TOC</a>';
          Future<void> respond(HttpRequest request, String server) async {
            seen.add({'server': server, 'target': '${request.uri}'});
            // Only the initial `q=word` request redirects: the query
            // scenario's final `q=final` target is answered, not redirected
            // again, and the authority scenario redirects once to the second
            // listener.
            final redirect =
                server == 'first' &&
                request.uri.path == '/book/1' &&
                (scenario == 'authority' ||
                    (scenario == 'query' &&
                        request.uri.queryParameters['q'] == 'word'));
            if (redirect) {
              request.response.statusCode = 302;
              request.response.headers.set(
                'Location',
                scenario == 'authority'
                    ? '$finalOrigin/book/1?q=word'
                    : '/book/1?q=final',
              );
            } else {
              request.response.headers.contentType = ContentType(
                json ? 'application' : 'text',
                json ? 'json' : 'html',
              );
              request.response.write(body);
            }
            await request.response.close();
          }

          first.listen((request) => respond(request, 'first'));
          second?.listen((request) => respond(request, 'second'));
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'searchUrl': '/search',
            'bookUrlPattern': r'$^',
            'ruleSearch': json
                ? {
                    'bookList': r'$.items[*]',
                    'name': r'$.title',
                    'bookUrl': r'$.url',
                  }
                : {'bookList': '.item', 'name': 'a@text', 'bookUrl': 'a@href'},
            'ruleBookInfo': json
                ? {'name': r'$.title', 'tocUrl': r'$.toc'}
                : {'name': 'h2@text', 'tocUrl': '#toc@href'},
          };
          final pipeline = json
              ? JsonSourcePipeline(source, HttpSourceTransport())
              : HtmlSourcePipeline(source, HttpSourceTransport());
          try {
            final hit = (await pipeline.search('1')).single;
            expect(hit.title, 'Book');
            expect(hit.identityAddress, '$origin/book/1?q=word');
            expect(hit.url.toString(), '$origin/book/1?q=word');
            expect(hit.infoHtml, isNull);
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.tocAddress, toc);
            final finalAddress =
                '$finalOrigin/book/1?q=${scenario == 'query' ? 'final' : 'word'}';
            expect(info.tocBase.toString(), finalAddress);
            expect(
              info.tocUrl,
              scenario == 'authority'
                  ? '$finalOrigin/book/toc'
                  : '$finalAddress#next',
            );
            expect(seen, <Map<String, String>>[
              {'server': 'first', 'target': '/search'},
              {'server': 'first', 'target': '/book/1?q=word'},
              if (scenario == 'query')
                {'server': 'first', 'target': '/book/1?q=final'},
              if (scenario == 'authority')
                {'server': 'second', 'target': '/book/1?q=word'},
            ]);
          } finally {
            pipeline.cancel();
            await first.close(force: true);
            if (second != null) await second.close(force: true);
          }
        });
      }
    }
  });

  group('repair05 JSON expanded wrapper and finished scalar', () {
    for (final wrapper in ['object', 'plain']) {
      test('expanded once without request options wrapper=$wrapper', () async {
        const origin = 'http://source.test';
        final returned = wrapper == 'object'
            ? '@js: [0,${jsonEncode({'futureRequestOption': true})}]; ${jsonEncode('/book/{{key}}')}'
            : "@js: '/book/1'";
        final searchBody = jsonEncode({
          'title': 'Book',
          'toc': '/toc',
          'items': [
            {'title': 'Book', 'url': returned},
          ],
        });
        final detailBody = jsonEncode({
          'title': 'Book',
          'toc': '/toc',
          'list': [
            {'name': 'Chapter', 'url': '/c/1'},
          ],
        });
        final pages = _Pages({'/search': searchBody, '/book/1': detailBody});
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'searchUrl': '/search',
          'bookUrlPattern': r'$^',
          'ruleSearch': {
            'bookList': r'$.items[*]',
            'name': r'$.title',
            'bookUrl': r'$.url',
          },
          'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
        };
        final pipeline = JsonSourcePipeline(source, pages);
        try {
          List<HtmlBook>? hits;
          final failure = await _errorOrNull(
            pipeline.search('1').then((value) => hits = value),
          );
          expect(failure, isNull);
          final hit = hits!.single;
          expect(hit.title, 'Book');
          expect(hit.rawAddress, '/book/1');
          expect(hit.identityAddress, '$origin/book/1');
          expect(hit.addressContext?.comparisonAddress, '$origin/$returned');
          expect(hit.addressContext?.publicationAddress, '$origin/book/1');
          expect(hit.infoHtml, isNull);
          expect(pages.requests, ['$origin/search']);
          final info = await pipeline.bookInfo(hit);
          expect(info.book.title, 'Book');
          expect(info.tocUrl, '$origin/toc');
          expect(pages.requests, ['$origin/search', '$origin/book/1']);
        } finally {
          pipeline.cancel();
        }
      });
    }

    for (final json in [false, true]) {
      for (final embeddedDot in [false, true]) {
        test(
          'complete scalar comparison json=$json embeddedDot=$embeddedDot',
          () async {
            const origin = 'http://source.test';
            final tail =
                ',${jsonEncode({
                  'headers': {'X-Text': embeddedDot ? 'a/../b' : 'ab'},
                })}';
            final raw = 'book$tail';
            final toc = '$origin/catalog/book$tail';
            final body = json
                ? jsonEncode({
                    'title': 'Book',
                    'toc': toc,
                    'items': [
                      {'title': 'Book', 'url': raw},
                    ],
                    'list': [
                      {'name': 'Chapter', 'url': '/c/1'},
                    ],
                  })
                : '<h2>Book</h2>'
                      '<div class="item"><a href="${HtmlEscape().convert(raw)}">Book</a></div>'
                      '<a class="toc" href="${HtmlEscape().convert(toc)}">TOC</a>'
                      '<ul id="list"><li><a href="/c/1">Chapter</a></li></ul>';
            final pages = _ContinuationPages(
              body,
              allowedPaths: const ['/catalog/search', '/catalog/book'],
            );
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': '/catalog/search',
              'bookUrlPattern': r'$^',
              'ruleSearch': json
                  ? {
                      'bookList': r'$.items[*]',
                      'name': r'$.title',
                      'bookUrl': r'$.url',
                    }
                  : {
                      'bookList': '.item',
                      'name': 'a@text',
                      'bookUrl': 'a@href',
                    },
              'ruleBookInfo': json
                  ? {'name': r'$.title', 'tocUrl': r'$.toc'}
                  : {'name': 'h2@text', 'tocUrl': 'a.toc@href'},
              'ruleToc': json
                  ? {
                      'chapterList': r'$.list[*]',
                      'chapterName': r'$.name',
                      'chapterUrl': r'$.url',
                    }
                  : {
                      'chapterList': '#list li',
                      'chapterName': 'a@text',
                      'chapterUrl': 'a@href',
                    },
            };
            final pipeline = json
                ? JsonSourcePipeline(source, pages)
                : HtmlSourcePipeline(source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.identityAddress, '$origin/catalog/book$tail');
              expect(
                hit.addressContext?.comparisonAddress,
                embeddedDot
                    ? '$origin/catalog/b"}}'
                    : '$origin/catalog/book$tail',
              );
              expect(
                hit.addressContext?.publicationAddress,
                '$origin/catalog/book$tail',
              );
              expect(hit.infoHtml, isNull);
              final info = await pipeline.bookInfo(hit);
              final detailHeaders = {
                for (final entry in pages.requests.last.headers.entries)
                  entry.key.toLowerCase(): entry.value,
              };
              expect(detailHeaders['x-text'], embeddedDot ? 'a/../b' : 'ab');
              expect(info.book.title, 'Book');
              expect(info.tocUrl, '$origin/catalog/book$tail');
              final (_, chapters) = await pipeline.tableOfContents(info);
              expect(chapters.single.name, 'Chapter');
              expect(info.tocHtml != null, !embeddedDot);
              expect(pages.requests.length, embeddedDot ? 3 : 2);
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }
  });

  group('repair05 retained logical information bases', () {
    for (final json in [false, true]) {
      for (final transformed in [false, true]) {
        test(
          'cover, same-page TOC and chapters json=$json transformed=$transformed',
          () async {
            const origin = 'http://source.test';
            final tail = transformed
                ? ',${jsonEncode({'js': "source.put('logicalRuns', String(Number(source.get('logicalRuns')||'0')+1)); result.replace('logical','wire').replace('book','deep')"})}'
                : '';
            final logical = '$origin/logical/book$tail';
            final wire =
                '$origin/${transformed ? 'wire/deep' : 'logical/book'}';
            final body = json
                ? jsonEncode({
                    'title': 'Book',
                    'toc': 'book$tail',
                    'cover': 'cover.jpg',
                    'list': [
                      {'name': 'Chapter', 'url': 'child'},
                    ],
                  })
                : '<h2>Book</h2>'
                      '<img class="cover" src="cover.jpg">'
                      '<a class="toc" href="book${HtmlEscape().convert(tail)}">TOC</a>'
                      '<ul id="list"><li><a href="child">Chapter</a></li></ul>';
            final pages = _Pages({Uri.parse(wire).path: body});
            final state = SourceHostState();
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': logical,
              'bookUrlPattern': '.*',
              'ruleSearch': json
                  ? {
                      'bookList': r'$.items[*]',
                      'name': r'$.title',
                      'bookUrl': r'$.url',
                    }
                  : {
                      'bookList': '.item',
                      'name': 'a@text',
                      'bookUrl': 'a@href',
                    },
              'ruleBookInfo': json
                  ? {
                      'name': r'$.title',
                      'coverUrl': r'$.cover',
                      'tocUrl': r'$.toc',
                    }
                  : {
                      'name': 'h2@text',
                      'coverUrl': 'img.cover@src',
                      'tocUrl': 'a.toc@href',
                    },
              'ruleToc': json
                  ? {
                      'chapterList': r'$.list[*]',
                      'chapterName': r'$.name',
                      'chapterUrl': r'$.url',
                    }
                  : {
                      'chapterList': '#list li',
                      'chapterName': 'a@text',
                      'chapterUrl': 'a@href',
                    },
            };
            final pipeline = json
                ? JsonSourcePipeline(source, pages, hostState: state)
                : HtmlSourcePipeline(source, pages, hostState: state);
            final fresh = json
                ? JsonSourcePipeline(source, pages, hostState: state)
                : HtmlSourcePipeline(source, pages, hostState: state);
            try {
              final hit = (await pipeline.search('x')).single;
              expect(hit.title, 'Book');
              expect(hit.url.toString(), wire);
              expect(hit.identityAddress, logical);
              expect(hit.infoHtml, isNotEmpty);
              expect(hit.addressContext?.comparisonAddress, logical);
              expect(hit.addressContext?.publicationAddress, logical);
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(info.tocAddress, 'book$tail');
              expect(info.tocHtml, isNotNull);
              expect(info.tocUrl, logical);
              expect(info.book.cover, '$origin/logical/cover.jpg');
              final (_, chapters) = await pipeline.tableOfContents(info);
              expect(chapters.single.name, 'Chapter');
              expect(chapters.single.url.toString(), '$origin/logical/child');
              expect(pages.requests, [wire]);
              expect(
                await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, 'logicalRuns'),
                ),
                transformed ? '1' : isNull,
              );

              final freshInfo = await fresh.bookInfo(hit);
              expect(freshInfo.tocUrl, logical);
              expect(freshInfo.tocHtml, isNotNull);
              expect(freshInfo.book.cover, '$origin/logical/cover.jpg');
              final (_, freshChapters) = await fresh.tableOfContents(freshInfo);
              expect(freshChapters.single.name, 'Chapter');
              expect(
                freshChapters.single.url.toString(),
                '$origin/logical/child',
              );
              expect(pages.requests, [wire]);
              expect(
                await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, 'logicalRuns'),
                ),
                transformed ? '1' : isNull,
              );
            } finally {
              pipeline.cancel();
              fresh.cancel();
            }
          },
        );
      }
    }
  });

  group('repair05 blank URL fallback', () {
    for (final json in [false, true]) {
      for (final blank in [false, true]) {
        test('real information redirect json=$json blank=$blank', () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final base = 'http://127.0.0.1:${server.port}';
          final seen = <String>[];
          final toc = blank ? '   ' : '';
          final body = json
              ? jsonEncode({
                  'title': 'Book',
                  'toc': toc,
                  'items': [
                    {'title': 'Book', 'url': '/book/1'},
                  ],
                  'list': [
                    {'name': 'Chapter', 'url': '/c/1'},
                  ],
                })
              : '<h2>Book</h2>'
                    '<div class="item"><a href="/book/1">Book</a></div>'
                    '<a class="toc" href="">TOC</a>'
                    '<ul id="list"><li><a href="/c/1">Chapter</a></li></ul>';
          server.listen((request) async {
            seen.add(request.uri.path);
            if (request.uri.path == '/book/1') {
              request.response.statusCode = 302;
              request.response.headers.set('Location', '/alt/deep/info');
            } else {
              request.response.headers.contentType = ContentType(
                json ? 'application' : 'text',
                json ? 'json' : 'html',
                charset: 'utf-8',
              );
              request.response.write(body);
            }
            await request.response.close();
          });
          final source = <String, dynamic>{
            'bookSourceUrl': base,
            'searchUrl': '/search',
            'ruleSearch': json
                ? {
                    'bookList': r'$.items[*]',
                    'name': r'$.title',
                    'bookUrl': r'$.url',
                  }
                : {'bookList': '.item', 'name': 'a@text', 'bookUrl': 'a@href'},
            'ruleBookInfo': json
                ? {'name': r'$.title', 'tocUrl': r'$.toc'}
                : {
                    'name': 'h2@text',
                    'tocUrl': blank ? "@js:'   '" : 'a.toc@href',
                  },
            'ruleToc': json
                ? {
                    'chapterList': r'$.list[*]',
                    'chapterName': r'$.name',
                    'chapterUrl': r'$.url',
                  }
                : {
                    'chapterList': '#list li',
                    'chapterName': 'a@text',
                    'chapterUrl': 'a@href',
                  },
          };
          final pipeline = json
              ? JsonSourcePipeline(source, HttpSourceTransport())
              : HtmlSourcePipeline(source, HttpSourceTransport());
          try {
            final hit = (await pipeline.search('1')).single;
            expect(hit.title, 'Book');
            expect(hit.url.toString(), '$base/book/1');
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.tocAddress.trim(), '');
            expect(info.tocBase.toString(), '$base/alt/deep/info');
            expect(info.tocUrl, '$base/book/1');
            expect(info.tocHtml, isNotEmpty);
            expect(seen, ['/search', '/book/1', '/alt/deep/info']);
            final (_, chapters) = await pipeline.tableOfContents(info);
            expect(chapters.single.name, 'Chapter');
            expect(chapters.single.url.toString(), '$base/c/1');
            expect(seen, ['/search', '/book/1', '/alt/deep/info']);
          } finally {
            pipeline.cancel();
            await server.close(force: true);
          }
        });
      }
    }
  });

  group('repair05 inherited empty query and query presence', () {
    for (final json in [false, true]) {
      for (final removeQuery in [false, true]) {
        test(
          'real empty-query redirect json=$json removed=$removeQuery',
          () async {
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            final origin = 'http://127.0.0.1:${server.port}';
            final seen = <String>[];
            final body = json
                ? jsonEncode({
                    'title': 'Book',
                    'toc': '#next',
                    'items': [
                      {'title': 'Book', 'url': '/book/1?'},
                    ],
                  })
                : '<h2>Book</h2>'
                      '<div class="item"><a href="/book/1?">Book</a></div>'
                      '<a class="toc" href="#next">TOC</a>';
            server.listen((request) async {
              seen.add('${request.uri}');
              if (removeQuery &&
                  request.uri.path == '/book/1' &&
                  request.uri.hasQuery) {
                request.response.statusCode = 302;
                request.response.headers.set('Location', '/book/1');
              } else {
                request.response.headers.contentType = ContentType(
                  json ? 'application' : 'text',
                  json ? 'json' : 'html',
                  charset: 'utf-8',
                );
                request.response.write(body);
              }
              await request.response.close();
            });
            final source = <String, dynamic>{
              'bookSourceUrl': origin,
              'searchUrl': '/search',
              'bookUrlPattern': r'$^',
              'ruleSearch': json
                  ? {
                      'bookList': r'$.items[*]',
                      'name': r'$.title',
                      'bookUrl': r'$.url',
                    }
                  : {
                      'bookList': '.item',
                      'name': 'a@text',
                      'bookUrl': 'a@href',
                    },
              'ruleBookInfo': json
                  ? {'name': r'$.title', 'tocUrl': r'$.toc'}
                  : {'name': 'h2@text', 'tocUrl': 'a.toc@href'},
            };
            final pipeline = json
                ? JsonSourcePipeline(source, HttpSourceTransport())
                : HtmlSourcePipeline(source, HttpSourceTransport());
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.identityAddress, '$origin/book/1?');
              expect(hit.url.hasQuery, isTrue);
              expect(hit.infoHtml, isNull);
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(info.tocAddress, '#next');
              expect(info.tocBase.hasQuery, !removeQuery);
              expect(
                info.tocBase.toString(),
                '$origin/book/1${removeQuery ? '' : '?'}',
              );
              expect(seen, ['/search', '/book/1?', if (removeQuery) '/book/1']);
              expect(
                info.tocUrl,
                '$origin/book/1${removeQuery ? '' : '?'}#next',
              );
            } finally {
              pipeline.cancel();
              await server.close(force: true);
            }
          },
        );
      }
    }
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

    test(
      'the HTML pipeline reads details and takes the TOC from the book URL',
      () async {
        final pages = _Pages({'/book/7': page});
        final (
          book,
          chapters,
        ) = await HtmlSourcePipeline({
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
        expect(
          book.title,
          '书架标题',
          reason: 'an empty name rule keeps the title',
        );
        expect(book.author, '作者甲');
        expect(chapters.map((chapter) => chapter.name), ['第一章', '第二章']);
        expect(
          pages.requests,
          contains('http://example.test/book/7'),
          reason: 'the TOC is read from the book URL when tocUrl is empty',
        );
      },
    );

    test(
      'the JSON pipeline reads details with neither field declared',
      () async {
        final document = jsonEncode({
          'author': '作者甲',
          'chapters': [
            {'name': '第一章', 'url': '/c/1'},
          ],
        });
        final (
          book,
          chapters,
        ) = await JsonSourcePipeline({
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
      },
    );
  });

  group('repair06 native consumers', () {
    // The information stage's own TOC admission compares the finished scalar
    // the way the frozen `BookInfo.kt:150-157` compares `book.tocUrl` against
    // `book.bookUrl`: one native URL operation over the whole rule result, so an
    // option tail that holds a dot segment takes part in it. A relative book and
    // an absolute one must both retire the response exactly when the two
    // finished texts agree.
    for (final json in [false, true]) {
      for (final absoluteBook in [false, true]) {
        for (final embeddedDot in [false, true]) {
          test(
            'repair06 whole-scalar information retention json=$json absoluteBook=$absoluteBook embeddedDot=$embeddedDot',
            () async {
              const origin = 'http://source.test';
              final tail =
                  ',${jsonEncode({
                    'headers': {'X-Text': embeddedDot ? 'a/../b' : 'ab'},
                  })}';
              final raw = '${absoluteBook ? '$origin/catalog/' : ''}book$tail';
              final toc = 'book$tail';
              final body = _repair06Page(json, book: raw, toc: toc);
              final pages = _ContinuationPages(
                body,
                allowedPaths: const ['/catalog/search', '/catalog/book'],
              );
              final state = SourceHostState();
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['searchUrl'] = '/catalog/search'
                ..['bookUrlPattern'] = r'$^'
                ..['loginCheckJs'] =
                    "source.put('r06Checks', String(Number(source.get('r06Checks')||'0')+1)); result";
              final pipeline = _openContinuation(
                json,
                source,
                pages,
                state: state,
              );
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNull);
                expect(
                  hit.addressContext?.comparisonAddress,
                  absoluteBook || !embeddedDot
                      ? '$origin/catalog/book$tail'
                      : '$origin/catalog/b"}}',
                );
                expect(
                  hit.addressContext?.publicationAddress,
                  '$origin/catalog/book$tail',
                );
                final info = await pipeline.bookInfo(hit);
                expect(info.book.title, 'Book');
                expect(
                  pages.requests.map((request) => request.url.path).toList(),
                  ['/catalog/search', '/catalog/book'],
                );
                final headers = {
                  for (final entry in pages.requests.last.headers.entries)
                    entry.key.toLowerCase(): entry.value,
                };
                expect(headers['x-text'], embeddedDot ? 'a/../b' : 'ab');
                expect(
                  await state.entry(
                    origin,
                    sourceRuleVariableKey(origin, 'r06Checks'),
                  ),
                  '2',
                );
                expect(
                  info.tocHtml != null,
                  !(absoluteBook && embeddedDot),
                  reason: 'the whole finished scalar decides retention',
                );
                await pipeline.tableOfContents(info);
                expect(
                  pages.requests.length,
                  absoluteBook && embeddedDot ? 3 : 2,
                );
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // A retained TOC page is read against its own native base, which is the
    // book's address text the frozen passes as `baseUrl` (`WebBook.kt:239-262`),
    // not the response URL a redirect landed on. The information stage still
    // reports the actual response URL it fetched.
    for (final json in [false, true]) {
      for (final redirect in [false, true]) {
        for (final relativeToc in [false, true]) {
          test(
            'repair06 retained TOC logical base json=$json redirect=$redirect relativeToc=$relativeToc',
            () async {
              final server = await HttpServer.bind(
                InternetAddress.loopbackIPv4,
                0,
              );
              addTearDown(() => server.close(force: true));
              final origin = 'http://127.0.0.1:${server.port}';
              final seen = <String>[];
              final toc = relativeToc ? (redirect ? '../../book/1' : '1') : '';
              final body = _repair06Page(json, toc: toc, chapter: 'child');
              server.listen((request) async {
                seen.add(request.uri.toString());
                if (redirect && request.uri.path == '/book/1') {
                  request.response.statusCode = 302;
                  request.response.headers.set('Location', '/alt/deep/info');
                } else {
                  request.response.headers.contentType = ContentType(
                    json ? 'application' : 'text',
                    json ? 'json' : 'html',
                    charset: 'utf-8',
                  );
                  request.response.write(body);
                }
                await request.response.close();
              });
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['searchUrl'] = '/search'
                ..['bookUrlPattern'] = r'$^';
              final pipeline = json
                  ? JsonSourcePipeline(source, HttpSourceTransport())
                  : HtmlSourcePipeline(source, HttpSourceTransport());
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNull);
                expect(hit.url.toString(), '$origin/book/1');
                final info = await pipeline.bookInfo(hit);
                expect(info.book.title, 'Book');
                expect(
                  info.tocBase.toString(),
                  redirect ? '$origin/alt/deep/info' : '$origin/book/1',
                );
                expect(info.tocHtml, isNotEmpty);
                expect(info.tocUrl, '$origin/book/1');
                expect(seen, [
                  '/search',
                  '/book/1',
                  if (redirect) '/alt/deep/info',
                ]);
                final (_, chapters) = await pipeline.tableOfContents(info);
                expect(chapters.single.name, 'Chapter');
                expect(
                  chapters.single.url.toString(),
                  '$origin/book/child',
                  reason: 'the retained page keeps its own logical base',
                );
                expect(seen, [
                  '/search',
                  '/book/1',
                  if (redirect) '/alt/deep/info',
                ]);
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // A fetched information response is the only fact that owns the response
    // URL text: the Unicode query it actually sent stays percent-encoded in the
    // published TOC text, and the old raw book text cannot be restored for it.
    for (final json in [false, true]) {
      for (final unicode in [false, true]) {
        test(
          'repair06 fetched response text json=$json unicode=$unicode',
          () async {
            final server = await HttpServer.bind(
              InternetAddress.loopbackIPv4,
              0,
            );
            addTearDown(() => server.close(force: true));
            final origin = 'http://127.0.0.1:${server.port}';
            final raw = '/book/1?q=${unicode ? '书' : 'word'}';
            final wire = '$origin/book/1?q=${unicode ? '%E4%B9%A6' : 'word'}';
            final body = _repair06Page(json, book: raw, toc: '#next');
            final seen = <String>[];
            server.listen((request) async {
              seen.add(request.uri.toString());
              request.response.headers.contentType = ContentType(
                json ? 'application' : 'text',
                json ? 'json' : 'html',
                charset: 'utf-8',
              );
              request.response.write(body);
              await request.response.close();
            });
            final source = (json ? _jsonSource(origin) : _htmlSource(origin))
              ..['searchUrl'] = '/search'
              ..['bookUrlPattern'] = r'$^';
            final pipeline = json
                ? JsonSourcePipeline(source, HttpSourceTransport())
                : HtmlSourcePipeline(source, HttpSourceTransport());
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.infoHtml, isNull);
              expect(hit.addressContext?.publicationAddress, '$origin$raw');
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(info.tocBase.toString(), wire);
              expect(seen, [
                '/search',
                '/book/1?q=${unicode ? '%E4%B9%A6' : 'word'}',
              ]);
              expect(
                info.tocUrl,
                '$wire#next',
                reason: 'the actual response text is the published base',
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    // A retained detail page publishes its own raw logical text: the cover
    // through the frozen String-base overload and an empty chapter URL through
    // the finished TOC text (`BookChapterList.kt:229-243`).
    for (final json in [false, true]) {
      for (final rawCase in [false, true]) {
        for (final feature in ['cover', 'emptyChapter']) {
          test(
            'repair06 retained raw consumer json=$json raw=$rawCase feature=$feature',
            () async {
              final logical = rawCase
                  ? 'http://UPPER.test/目录/book?keep=书'
                  : 'http://source.test/catalog/book?keep=word';
              final toc = rawCase ? 'book?keep=书' : 'book?keep=word';
              final body = _repair06Page(
                json,
                toc: toc,
                cover: 'cover.jpg',
                chapter: '',
              );
              final pages = _Pages({Uri.parse(logical).path: body});
              final source =
                  (json ? _jsonSource(logical) : _htmlSource(logical))
                    ..['searchUrl'] = logical
                    ..['bookUrlPattern'] = '.*';
              final pipeline = json
                  ? JsonSourcePipeline(source, pages)
                  : HtmlSourcePipeline(source, pages);
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNotEmpty);
                expect(hit.addressContext?.comparisonAddress, logical);
                expect(hit.addressContext?.publicationAddress, logical);
                expect(pages.requests.length, 1);
                final info = await pipeline.bookInfo(hit);
                expect(info.book.title, 'Book');
                expect(info.tocHtml, isNotEmpty);
                expect(info.tocUrl, logical);
                if (feature == 'cover') {
                  expect(
                    info.book.cover,
                    rawCase
                        ? 'http://UPPER.test/目录/cover.jpg'
                        : 'http://source.test/catalog/cover.jpg',
                    reason: 'the retained cover base is the raw book text',
                  );
                } else {
                  final (_, chapters) = await pipeline.tableOfContents(info);
                  expect(chapters.single.name, 'Chapter');
                  expect(
                    chapters.single.address,
                    logical,
                    reason: 'an empty chapter URL publishes the TOC text',
                  );
                }
                expect(pages.requests.length, 1);
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // The search stage's blank `ruleSearch.bookUrl` keeps the base text the
    // frozen answers for a blank finished scalar (`BookList.kt:265-269`,
    // `AnalyzeRule.kt:315-323`), query included.
    for (final spaces in [false, true]) {
      test('repair06 blank search scalar spaces=$spaces', () async {
        const origin = 'http://source.test';
        const full = '$origin/book/1?q=x';
        final body = _repair06Page(false, book: '/book/1?q=x');
        final pages = _Pages({'/book/1': body});
        final source = _htmlSource(
          origin,
          searchUrl: '/book/1?q=x',
          bookUrlRule: '@js: ${jsonEncode(spaces ? '   ' : '')}',
        );
        final pipeline = HtmlSourcePipeline(source, pages);
        try {
          final hit = (await pipeline.search('1')).single;
          expect(hit.title, 'Book');
          expect(hit.identityAddress, full);
          expect(pages.requests, [full]);
          expect(
            hit.addressContext?.publicationAddress,
            full,
            reason: 'a blank scalar keeps the whole search response text',
          );
          expect(hit.infoHtml, isNotEmpty);
        } finally {
          pipeline.cancel();
        }
      });
    }

    // Reading a published TOC address is boundary-only: it never parses or
    // validates the book program it came from. A legacy rule whose expansion
    // already fetched keys its option object out of the request path.
    for (final future in [false, true]) {
      test('repair06 legacy wrapper publication future=$future', () async {
        const origin = 'http://source.test';
        final wrapper = future
            ? '@js: [0,{"futureRequestOption":true}]; "/book/1"'
            : '@js: "/book/1"';
        final pages = _Pages({
          '/book/1': jsonEncode({'title': 'Book', 'toc': '/toc'}),
        });
        final pipeline = JsonSourcePipeline(_jsonSource(origin), pages);
        try {
          final info = await pipeline.bookInfo(
            HtmlBook(
              url: Uri.parse('$origin/book/1'),
              rawAddress: wrapper,
              title: 'Book',
            ),
          );
          expect(info.book.title, 'Book');
          expect(info.tocAddress, '/toc');
          expect(pages.requests, ['$origin/book/1']);
          String? value;
          Object? error;
          try {
            value = info.tocUrl;
          } catch (exception) {
            error = exception;
          }
          expect(error, isNull, reason: 'publication reads no request options');
          expect(value, '$origin/toc');
        } finally {
          pipeline.cancel();
        }
      });
    }

    // A relative special detail rule resolves once against the target the
    // search request actually reached; the frozen `getInfoItem` keeps that
    // double directory as its identity (`BookList.kt:159-163`).
    for (final json in [false, true]) {
      for (final rooted in [false, true]) {
        for (final fallback in [false, true]) {
          test(
            'repair06 special relative identity json=$json rooted=$rooted fallback=$fallback',
            () async {
              const origin = 'http://source.test';
              final raw = rooted ? '/catalog/book/1' : 'book/1';
              final pages = _Pages({'/catalog/book/1': _repair06Page(json)});
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['bookSourceUrl'] = '$origin/catalog/search'
                ..['searchUrl'] = raw
                ..['bookUrlPattern'] = fallback ? null : '.*'
                ..['ruleSearch'] = <String, dynamic>{
                  'bookList': fallback
                      ? (json ? r'$.missing[*]' : '.missing')
                      : (json ? r'$.listing[*]' : 'div.item'),
                  'name': json ? r'$.name' : 'h3 a@text',
                  'bookUrl': json ? r'$.url' : 'h3 a@href',
                };
              final pipeline = json
                  ? JsonSourcePipeline(source, pages)
                  : HtmlSourcePipeline(source, pages);
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNotEmpty);
                expect(pages.requests, ['$origin/catalog/book/1']);
                expect(
                  hit.identityAddress,
                  rooted
                      ? '$origin/catalog/book/1'
                      : '$origin/catalog/book/book/1',
                  reason: 'one native resolution after the actual target',
                );
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // A relative field inherits the native URL object's lower-case protocol
    // while the authority, path and query keep their raw spelling.
    for (final json in [false, true]) {
      for (final upperScheme in [false, true]) {
        test(
          'repair06 raw base protocol json=$json upperScheme=$upperScheme',
          () async {
            final logical =
                '${upperScheme ? 'HTTP' : 'http'}://UPPER.test/catalog/book';
            final pages = _Pages({
              '/catalog/book': _repair06Page(json, toc: 'toc'),
            });
            final source = (json ? _jsonSource(logical) : _htmlSource(logical))
              ..['searchUrl'] = logical
              ..['bookUrlPattern'] = '.*';
            final pipeline = json
                ? JsonSourcePipeline(source, pages)
                : HtmlSourcePipeline(source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.addressContext?.publicationAddress, logical);
              expect(hit.infoHtml, isNotEmpty);
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(pages.requests.length, 1);
              expect(
                info.tocUrl,
                'http://UPPER.test/catalog/toc',
                reason: 'the native protocol is lower case',
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    // The frozen URL getter's blank test is Kotlin's `isBlank`
    // (`AnalyzeRule.kt:315-323`): `0x1C` is blank and `0x85` is not, and no
    // later Dart trim may turn the nonblank value back into the book address.
    for (final json in [false, true]) {
      for (final unit in [0x20, 0x1c, 0x85]) {
        test(
          'repair06 Kotlin blank membership json=$json unit=$unit',
          () async {
            const origin = 'http://source.test';
            final logical = '$origin/book/1?keep=x';
            final value = String.fromCharCode(unit);
            final pages = _Pages({'/book/1': _repair06Page(json)});
            final source = (json ? _jsonSource(origin) : _htmlSource(origin))
              ..['searchUrl'] = logical
              ..['bookUrlPattern'] = '.*';
            final infoRule = Map<String, dynamic>.from(
              source['ruleBookInfo'] as Map,
            );
            infoRule['tocUrl'] = '@js: String.fromCharCode($unit)';
            source['ruleBookInfo'] = infoRule;
            final pipeline = json
                ? JsonSourcePipeline(source, pages)
                : HtmlSourcePipeline(source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.infoHtml, isNotEmpty);
              expect(hit.addressContext?.comparisonAddress, logical);
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(pages.requests.length, 1);
              expect(
                info.tocAddress,
                unit == 0x85 ? value : '',
                reason: 'Kotlin isBlank decides the finished scalar',
              );
              if (unit == 0x85) {
                expect(info.tocHtml, isNull);
                expect(
                  info.tocUrl,
                  '$origin/book/$value',
                  reason:
                      'a nonblank control character stays a relative address',
                );
              } else {
                expect(info.tocUrl, logical);
                expect(info.tocHtml, isNotEmpty);
              }
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }
  });
}
