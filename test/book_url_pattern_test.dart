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
import 'package:liber/source/source_url_rules.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/workspace.dart';

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

/// One retained first page and the page it declares answer different bodies, so
/// a page walk is observable by the chapter text it joins: the information
/// request's own document carries the retained first page, and every other
/// allowed target answers the declared next page. Both possible next targets a
/// complete native base can produce are answerable, so a wrong target fails its
/// own assertion instead of the fixture's path refusal.
class _RetainedPagingPages extends _ContinuationPages {
  _RetainedPagingPages(super.document)
    : super(
        allowedPaths: const [
          '/catalog/book/1',
          '/catalog/book/leaf',
          '/catalog/leaf',
        ],
      );

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    final response = await super.send(request);
    if (request.url.path == '/catalog/book/1') return response;
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: jsonEncode({'text': 'Second', 'next': ''}),
      url: request.url,
    );
  }
}

/// One TOC (or page-walk) sequence answered in order: each request gets the
/// next body and every later request repeats the last one. The TOC stage's own
/// retained first page and its fetched later page therefore carry different
/// bodies, and both next-page targets answer a valid body, so a wrong target or
/// a wrong page fails its own assertion instead of a fixture refusal.
class _RetainedSequencePages extends _ContinuationPages {
  _RetainedSequencePages(this.responses) : super('');

  final List<String> responses;

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final index = requests.length - 1;
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: responses[index < responses.length ? index : responses.length - 1],
      url: request.url,
    );
  }
}

/// The frozen O/P-shaped site: a list page whose selected hit carries a
/// `bookUrl` URL-option script, or a TOC page whose continuation addresses carry
/// their own, plus the pages those scripts select. A target the frozen never
/// requests has no page, so it answers the runner's own refusal (an unmatched
/// request and no book markup) rather than a page that could hide the divergence
/// behind a plausible body.
class _RequestOptionPages implements BookSourceTransport, SourceHttpTransport {
  _RequestOptionPages(this.pages);

  final Map<String, String> pages;
  final List<SourceHttpRequest> requests = [];

  /// The path each request reached, in send order.
  List<String> get targets => [
    for (final request in requests) request.url.path,
  ];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('Real send required');

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final page = pages[request.url.path];
    return SourceHttpResponse(
      statusCode: page == null ? 404 : 200,
      headers: const {},
      body: page ?? 'undeclared replay request',
      url: request.url,
    );
  }
}

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

  for (final json in [false, true]) {
    test(
      'information option fragment query reaches wire and retained content json=$json',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final seen = <String>[];
        final state = SourceHostState();
        final selected = '$origin/wire#frag?probe=wire';
        final address =
            '$origin/book,${jsonEncode({'js': "source.put('infoRuns',String(Number(source.get('infoRuns')||'0')+1)); '$selected'"})}';
        final source = json
            ? _jsonSource(origin, searchUrl: '/search', bookUrlPattern: r'$^')
            : _htmlSource(origin, searchUrl: '/search', bookUrlPattern: r'$^');
        final page = json
            ? jsonEncode({
                'title': 'Book',
                'toc': '',
                'list': [
                  {'label': 'Chapter', 'href': ''},
                ],
                'text': 'Body',
              })
            : '${_repair06Page(false, hit: false, chapter: '')}<div id="content">Body</div>';
        server.listen((request) async {
          seen.add(request.uri.toString());
          if (request.uri.path == '/search') {
            request.response.write(
              json
                  ? jsonEncode({
                      'listing': [
                        {'name': 'Book', 'url': address},
                      ],
                    })
                  : '<div class="item"><h3><a href="${HtmlEscape().convert(address)}">Book</a></h3></div>',
            );
          } else if (request.uri.path == '/wire' &&
              request.uri.query == 'probe=wire') {
            request.response.write(page);
          } else {
            request.response.statusCode = 404;
            request.response.write('unexpected');
          }
          await request.response.close();
        });
        final pipeline = json
            ? JsonSourcePipeline(
                source,
                HttpSourceTransport(),
                hostState: state,
              )
            : HtmlSourcePipeline(
                source,
                HttpSourceTransport(),
                hostState: state,
              );
        try {
          final hit = (await pipeline.search('book')).single;
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'infoRuns'),
            ),
            json ? '1' : isNull,
          );
          final info = await pipeline.bookInfo(hit);
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'infoRuns'),
            ),
            '1',
          );
          final (book, chapters) = await pipeline.tableOfContents(info);
          final body = await pipeline.chapter(chapters.single, book: book);
          expect(body.text, 'Body');
          expect(seen, ['/search', '/wire?probe=wire']);
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'infoRuns'),
            ),
            '1',
          );
        } finally {
          pipeline.cancel();
          await server.close(force: true);
        }
      },
    );
  }

  for (final json in [false, true]) {
    test(
      'relative Unicode-tail book text reuses retained chapter json=$json',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final origin = 'http://127.0.0.1:${server.port}';
        final seen = <String>[];
        const rule = '@js: "book?q=word\\u2000"';
        final source = json
            ? _jsonSource(
                origin,
                searchUrl: '/search',
                bookUrlPattern: r'$^',
                bookUrlRule: rule,
                tocRule: rule,
              )
            : _htmlSource(
                origin,
                searchUrl: '/search',
                bookUrlPattern: r'$^',
                bookUrlRule: rule,
                tocRule: rule,
              );
        server.listen((request) async {
          seen.add(request.uri.toString());
          if (request.uri.path == '/search') {
            request.response.write(
              json
                  ? jsonEncode({
                      'listing': [
                        {'name': 'Book', 'url': '/unused'},
                      ],
                    })
                  : '<div class="item"><h3><a href="/unused">Book</a></h3></div>',
            );
          } else if (request.uri.path == '/book' &&
              request.uri.query == 'q=word') {
            request.response.write(
              json
                  ? jsonEncode({
                      'title': 'Book',
                      'toc': '',
                      'list': [
                        {'label': 'Chapter', 'href': ''},
                      ],
                      'text': 'Body',
                    })
                  : '${_repair06Page(false, hit: false, chapter: '')}<div id="content">Body</div>',
            );
          } else {
            request.response.statusCode = 404;
            request.response.write('unexpected');
          }
          await request.response.close();
        });
        final pipeline = json
            ? JsonSourcePipeline(source, HttpSourceTransport())
            : HtmlSourcePipeline(source, HttpSourceTransport());
        try {
          final hit = (await pipeline.search('book')).single;
          expect(
            hit.addressContext?.comparisonAddress,
            '$origin/book?q=word\u2000',
          );
          final info = await pipeline.bookInfo(hit);
          expect(
            info.book.addressContext?.comparisonAddress,
            '$origin/book?q=word\u2000',
          );
          final (book, chapters) = await pipeline.tableOfContents(info);
          expect(chapters.single.address, '$origin/book?q=word\u2000');
          expect(chapters.single.fetchContext?.retainedPage, isNotNull);
          final body = await pipeline.chapter(chapters.single, book: book);
          expect(body.text, 'Body');
          expect(seen, ['/search', '/book?q=word']);
          expect(chapters.single.address, '$origin/book?q=word\u2000');
          expect(chapters.single.persistedAddress, '$origin/book?q=word');
        } finally {
          pipeline.cancel();
          await server.close(force: true);
        }
      },
    );
  }

  for (final (json, search, link, expected) in [
    (false, '/search', '/book#frag?probe=wire', 'http://source.test/book'),
    (
      true,
      '/search?seed=base',
      '#frag?probe=wire',
      'http://source.test/search?probe=wire',
    ),
  ]) {
    test(
      'relative book identity retains original fragment semantics json=$json',
      () async {
        final page = json
            ? jsonEncode({
                'listing': [
                  {'name': 'Book', 'url': link},
                ],
              })
            : '<div class="item"><h3><a href="$link">Book</a></h3></div>';
        final pages = _Pages({'/search': page});
        final source = json
            ? _jsonSource(
                'http://source.test',
                searchUrl: search,
                bookUrlPattern: r'$^',
              )
            : _htmlSource(
                'http://source.test',
                searchUrl: search,
                bookUrlPattern: r'$^',
              );
        final pipeline = json
            ? JsonSourcePipeline(source, pages)
            : HtmlSourcePipeline(source, pages);
        try {
          final hit = (await pipeline.search('book')).single;
          expect(hit.identityAddress, expected);
          expect('${hit.preOptionUrl}', expected);
          expect(pages.requests, ['http://source.test$search']);
        } finally {
          pipeline.cancel();
        }
      },
    );
  }

  test('relative JSON book fragment query keeps pre-option identity', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    final seen = <String>[];
    final tail = ',${jsonEncode({'js': "'$origin/wire#frag?probe=wire'"})}';
    server.listen((request) async {
      seen.add(request.uri.toString());
      if (request.uri.path == '/search') {
        request.response.write(
          jsonEncode({
            'listing': [
              {'name': 'Book', 'url': '/book#frag?probe=wire$tail'},
            ],
          }),
        );
      } else if (request.uri.path == '/wire' &&
          request.uri.query == 'probe=wire') {
        request.response.write(_repair06Page(true, hit: false));
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });
    final pipeline = JsonSourcePipeline(
      _jsonSource(origin, searchUrl: '/search', bookUrlPattern: r'$^'),
      HttpSourceTransport(),
    );
    try {
      final hit = (await pipeline.search('book')).single;
      expect(hit.preOptionUrl.toString(), '$origin/book');
      expect(hit.identityAddress, '$origin/book$tail');
      final info = await pipeline.bookInfo(hit);
      expect(info.book.title, 'Book');
      expect(info.book.identityAddress, '$origin/book$tail');
      expect(seen, ['/search', '/wire?probe=wire']);
    } finally {
      pipeline.cancel();
      await server.close(force: true);
    }
  });

  test(
    'JSON chapter option script keeps raw query for GBK wire encoding',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final origin = 'http://127.0.0.1:${server.port}';
      final state = SourceHostState();
      final address =
          '$origin/content?q=中,${jsonEncode({'charset': 'gbk', 'js': "source.put('contentRuns',String(Number(source.get('contentRuns')||'0')+1)); source.put('chapterSnapshot',JSON.stringify(chapter)); result"})}';
      final seen = <String>[];
      server.listen((request) async {
        seen.add(request.uri.toString());
        if (request.uri.path == '/search') {
          request.response.write(
            jsonEncode({
              'listing': [
                {'name': 'Book', 'url': '/book'},
              ],
            }),
          );
        } else if (request.uri.path == '/book') {
          request.response.write(
            _repair06Page(true, hit: false, chapter: address),
          );
        } else if (request.uri.path == '/content' &&
            request.uri.query == 'q=%D6%D0') {
          request.response.write(jsonEncode({'text': 'Body'}));
        } else {
          request.response.statusCode = 404;
          request.response.write('unexpected');
        }
        await request.response.close();
      });
      final source = _jsonSource(
        origin,
        searchUrl: '/search',
        bookUrlPattern: r'$^',
      );
      final pipeline = JsonSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
      );
      final key = sourceRuleVariableKey(origin, 'contentRuns');
      try {
        final hit = (await pipeline.search('book')).single;
        final info = await pipeline.bookInfo(hit);
        final (book, chapters) = await pipeline.tableOfContents(info);
        expect(await state.entry(origin, key), isNull);
        expect(chapters.single.persistedAddress, address);
        final stableKey = chapters.single.storeKey;
        expect(stableKey, '$origin/content?q=%E4%B8%AD');
        final body = await pipeline.chapter(chapters.single, book: book);
        expect(body.text, 'Body');
        expect(seen, ['/search', '/book', '/content?q=%D6%D0']);
        expect(await state.entry(origin, key), '1');
        final snapshot = await state.entry(
          origin,
          sourceRuleVariableKey(origin, 'chapterSnapshot'),
        );
        expect(snapshot, contains('url'));
        expect(snapshot, isNot(contains('fetchContext')));
        expect(snapshot, isNot(contains('retainedPage')));
        expect(snapshot, isNot(contains('requestAddress')));
        expect(chapters.single.storeKey, stableKey);
      } finally {
        pipeline.cancel();
        await server.close(force: true);
      }
    },
  );

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

  // The pinned URL overload reaches the base with the original relative text, so
  // a nonblank scalar that ends in a Unicode space keeps it through the public
  // information and TOC stages.
  for (final json in [false, true]) {
    for (final suffix in [false, true]) {
      test('repair06whitespace pipeline json=$json suffix=$suffix', () async {
        const origin = 'http://source.test';
        const logical = '$origin/book/1?keep=x';
        final value = 'child${suffix ? '\u2000' : ''}';
        final pages = _Pages({'/book/1': _repair06Page(json)});
        final source = (json ? _jsonSource(origin) : _htmlSource(origin))
          ..['searchUrl'] = logical
          ..['bookUrlPattern'] = '.*';
        final infoRule = Map<String, dynamic>.from(
          source['ruleBookInfo'] as Map,
        );
        infoRule['tocUrl'] = '@js: ${jsonEncode(value)}';
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
          expect(info.tocAddress, value);
          expect(info.tocBase.toString(), logical);
          expect(info.tocHtml, isNull);
          expect(pages.requests, [logical]);
          expect(
            info.tocUrl,
            '$origin/book/$value',
            reason: 'a nonblank relative scalar keeps its Unicode text',
          );
        } finally {
          pipeline.cancel();
        }
      });
    }
  }

  group('repair07 native consumers', () {
    // The retained cover and the nonempty relative chapter target both reach
    // the frozen String URL overload (`NetworkUtils.kt:160-169`), which builds
    // its URL object from the base before the first comma; the option tail of
    // the book's raw text therefore never becomes a directory. The next-page
    // stage keeps resolving against the whole logical stage.
    for (final json in [false, true]) {
      for (final slash in [false, true]) {
        for (final feature in ['cover', 'relativeChapter']) {
          test(
            'repair07 String base json=$json slash=$slash feature=$feature',
            () async {
              const origin = 'http://source.test';
              final header = slash ? 'a/b' : 'ab';
              final tail =
                  ',${jsonEncode({
                    'headers': {'X-Text': header},
                  })}';
              final raw = '$origin/catalog/book$tail';
              final document = _repair06Page(
                json,
                cover: 'cover.jpg',
                chapter: 'child',
              );
              final pages = _ContinuationPages(
                document,
                allowedPaths: const ['/catalog/book'],
              );
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['searchUrl'] = raw
                ..['bookUrlPattern'] = '.*';
              final pipeline = _openContinuation(json, source, pages);
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book', reason: 'premise: detail title');
                expect(
                  hit.infoHtml,
                  isNotEmpty,
                  reason: 'premise: retained information',
                );
                expect(
                  hit.addressContext?.publicationAddress,
                  raw,
                  reason: 'premise: exact raw fact',
                );
                expect(
                  pages.requests.single.url.toString(),
                  '$origin/catalog/book',
                  reason: 'premise: real request target',
                );
                expect(
                  {
                    for (final entry in pages.requests.single.headers.entries)
                      entry.key.toLowerCase(): entry.value,
                  }['x-text'],
                  header,
                  reason: 'premise: option header executed',
                );
                final info = await pipeline.bookInfo(hit);
                expect(info.book.title, 'Book');
                expect(
                  info.tocHtml,
                  isNotEmpty,
                  reason: 'premise: blank self TOC',
                );
                expect(
                  info.tocUrl,
                  raw,
                  reason: 'premise: whole publication retained',
                );
                expect(pages.requests.length, 1);
                if (feature == 'cover') {
                  expect(
                    info.book.cover,
                    '$origin/catalog/cover.jpg',
                    reason: 'target: cover String-base consumer',
                  );
                } else {
                  final (_, chapters) = await pipeline.tableOfContents(info);
                  final chapter = chapters.single;
                  expect(chapter.name, 'Chapter');
                  expect(
                    chapter.address,
                    'child',
                    reason: 'premise: nonempty raw chapter',
                  );
                  expect(
                    pages.requests.length,
                    1,
                    reason: 'premise: no TOC network work',
                  );
                  expect(
                    chapter.url.toString(),
                    '$origin/catalog/child',
                    reason: 'target: nonempty chapter String-base consumer',
                  );
                  expect(chapter.storeKey, '$origin/catalog/child');
                  expect(chapter.persistedAddress, '$origin/catalog/child');
                }
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // An ordinary empty chapter URL publishes the TOC page's own text
    // (`BookChapterList.kt:229-243`), so the target comes from the fact that
    // text carries: the once-expanded publication (#99, JSON only) and the
    // request's own charset encoding, never the native comparison scalar.
    for (final json in [false, true]) {
      for (final template in [false, true]) {
        // The single-expansion follow-up is JSON-only: HTML return templates are
        // untouched (`sources/policy-99/comment-01.md`).
        if (!json && template) continue;
        test('repair07 empty expanded json=$json template=$template', () async {
          const origin = 'http://source.test';
          final raw = template ? r'/book/{{key}}' : '/book/1';
          final page = _repair06Page(json, book: raw, chapter: '');
          final document = json
              ? jsonEncode({
                  ...jsonDecode(page) as Map<String, dynamic>,
                  'content': 'Body',
                })
              : '$page<div id="content">Body</div>';
          final pages = _ContinuationPages(
            document,
            allowedPaths: const ['/search', '/book/1'],
          );
          final source = (json ? _jsonSource(origin) : _htmlSource(origin))
            ..['searchUrl'] = '/search'
            ..['bookUrlPattern'] = r'$^'
            ..['ruleContent'] = {
              'content': json ? r'$.content' : '#content@text',
            };
          final pipeline = _openContinuation(json, source, pages);
          try {
            final hit = (await pipeline.search('1')).single;
            expect(hit.title, 'Book');
            expect(hit.infoHtml, isNull, reason: 'premise: ordinary list');
            expect(
              hit.addressContext?.publicationAddress,
              '$origin/book/1',
              reason: 'premise: expansion fact',
            );
            final info = await pipeline.bookInfo(hit);
            expect(info.tocHtml, isNotEmpty);
            expect(info.tocUrl, '$origin/book/1');
            expect(pages.requests.map((request) => request.url.path), [
              '/search',
              '/book/1',
            ]);
            final (_, chapters) = await pipeline.tableOfContents(info);
            final chapter = chapters.single;
            expect(
              chapter.address,
              '$origin/book/1',
              reason: 'premise: raw fallback publication',
            );
            expect(
              chapter.url.toString(),
              '$origin/book/1',
              reason: 'target: empty target uses the expanded fact',
            );
            expect(chapter.storeKey, '$origin/book/1');
            expect(
              chapter.persistedAddress,
              json ? '$origin$raw' : '$origin/book/1',
            );
            final body = await pipeline.chapter(chapter, book: info.book);
            expect(body.text, 'Body');
            expect(pages.requests.last.url.toString(), '$origin/book/1');
            expect(pages.requests.length, 2);
          } finally {
            pipeline.cancel();
          }
        });
      }
    }

    // Information applies its declared charset on the wire; the retained
    // chapter keeps the pre-option URI and the complete raw request text.
    for (final json in [false, true]) {
      for (final value in ['unicode', 'preencoded', 'ascii']) {
        test('repair07 empty charset json=$json value=$value', () async {
          const origin = 'http://source.test';
          final query = value == 'unicode'
              ? '中'
              : value == 'preencoded'
              ? '%D6%D0'
              : 'word';
          final encoded = value == 'ascii' ? 'word' : '%D6%D0';
          final tail =
              ',${jsonEncode({
                'charset': 'gbk',
                'headers': {'X-Book': 'fallback'},
              })}';
          final raw = '$origin/book?q=$query$tail';
          final wire = '$origin/book?q=$encoded';
          final preOption =
              '$origin/book?q=${value == 'unicode' ? '%E4%B8%AD' : encoded}';
          final page = _repair06Page(json, chapter: '');
          final document = json
              ? jsonEncode({
                  ...jsonDecode(page) as Map<String, dynamic>,
                  'content': 'Body',
                })
              : '$page<div id="content">Body</div>';
          final pages = _ContinuationPages(
            document,
            allowedPaths: const ['/book'],
          );
          final source = (json ? _jsonSource(origin) : _htmlSource(origin))
            ..['ruleContent'] = {
              'content': json ? r'$.content' : '#content@text',
            };
          final pipeline = _openContinuation(json, source, pages);
          try {
            final info = await pipeline.bookInfo(
              HtmlBook(
                url: Uri.parse(wire),
                preOptionUrl: Uri.parse(wire),
                rawAddress: raw,
                title: 'Book',
              ),
            );
            expect(info.book.title, 'Book');
            expect(
              info.tocHtml,
              isNotEmpty,
              reason: 'premise: information reused as TOC',
            );
            expect(info.tocUrl, raw, reason: 'premise: raw options and query');
            expect(
              pages.requests.single.url.toString(),
              wire,
              reason: 'premise: real named charset request',
            );
            expect(
              {
                for (final entry in pages.requests.single.headers.entries)
                  entry.key.toLowerCase(): entry.value,
              }['x-book'],
              'fallback',
            );
            final (_, chapters) = await pipeline.tableOfContents(info);
            final chapter = chapters.single;
            expect(chapter.address, raw);
            expect(
              chapter.options.charset,
              'gbk',
              reason: 'premise: charset option remains',
            );
            expect(
              chapter.url.toString(),
              preOption,
              reason: 'target: pre-option chapter identity',
            );
            expect(chapter.storeKey, preOption);
            expect(chapter.persistedAddress, raw);
            final body = await pipeline.chapter(chapter, book: info.book);
            expect(body.text, 'Body');
            expect(pages.requests.length, 1);
            expect(
              pages.requests.last.url.toString(),
              wire,
              reason: 'target: actual content request',
            );
          } finally {
            pipeline.cancel();
          }
        });
      }
    }

    // The native comparison keeps the finished scalar as read: the Kotlin blank
    // test decides the fallback, and a nonblank value reaches the URL operation
    // with its own Unicode text, so retention and the repeated information
    // request follow it.
    for (final json in [false, true]) {
      for (final suffix in [false, true]) {
        test('repair07 ordinary whitespace json=$json suffix=$suffix', () async {
          const origin = 'http://source.test';
          final scalar = 'book${suffix ? '\u2000' : ''}';
          final pages = _ContinuationPages(
            _repair06Page(json, book: scalar),
            allowedPaths: const ['/catalog/book'],
          );
          final source = (json ? _jsonSource(origin) : _htmlSource(origin))
            ..['searchUrl'] = '/catalog/book'
            ..['bookUrlPattern'] = r'$^'
            ..['loginCheckJs'] =
                "source.put('r07Checks',String(Number(source.get('r07Checks')||'0')+1)); result";
          final state = SourceHostState();
          final pipeline = _openContinuation(json, source, pages, state: state);
          try {
            final hit = (await pipeline.search('1')).single;
            expect(hit.title, 'Book');
            expect(
              pages.requests.single.url.toString(),
              '$origin/catalog/book',
            );
            expect(
              await state.entry(
                origin,
                sourceRuleVariableKey(origin, 'r07Checks'),
              ),
              '1',
              reason: 'premise: one search login check',
            );
            expect(
              hit.addressContext?.comparisonAddress,
              '$origin/catalog/$scalar',
              reason: 'target: native comparison keeps the nonblank scalar',
            );
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(
              hit.infoHtml != null,
              !suffix,
              reason: 'target: comparison controls information retention',
            );
            expect(pages.requests.length, suffix ? 2 : 1);
            expect(
              await state.entry(
                origin,
                sourceRuleVariableKey(origin, 'r07Checks'),
              ),
              suffix ? '2' : '1',
            );
          } finally {
            pipeline.cancel();
          }
        });
      }
    }

    // A response the search stage reads as a detail page keeps one native URL
    // operation over the whole once-expanded rule text (`BookList.kt:159-163`
    // over `AnalyzeUrl.ruleUrl`), so a dot in the option tail takes part in the
    // comparison while the published address keeps its exact tail and the
    // actual search request keeps its own options.
    for (final json in [false, true]) {
      for (final fallback in [false, true]) {
        for (final dot in [false, true]) {
          test(
            'repair07 special scalar json=$json fallback=$fallback dot=$dot',
            () async {
              const origin = 'http://source.test';
              final header = dot ? 'a/../b' : 'ab';
              final tail =
                  ',${jsonEncode({
                    'headers': {'X-Text': header},
                  })}';
              final raw = 'book/1$tail';
              final publication = '$origin/catalog/book/book/1$tail';
              final native = dot
                  ? '$origin/catalog/book/book/b"}}'
                  : publication;
              final pages = _ContinuationPages(
                _repair06Page(json, toc: native),
                allowedPaths: [
                  '/catalog/book/1',
                  '/catalog/book/book/b"}}',
                  '/catalog/book/book/1',
                ],
              );
              final state = SourceHostState();
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['bookSourceUrl'] = '$origin/catalog/search'
                ..['searchUrl'] = raw
                ..['bookUrlPattern'] = fallback ? null : '.*'
                ..['loginCheckJs'] =
                    "source.put('r07Special',String(Number(source.get('r07Special')||'0')+1)); result"
                ..['ruleSearch'] = <String, dynamic>{
                  'bookList': fallback
                      ? (json ? r'$.missing[*]' : '.missing')
                      : (json ? r'$.listing[*]' : 'div.item'),
                  'name': json ? r'$.name' : 'h3 a@text',
                  'bookUrl': json ? r'$.url' : 'h3 a@href',
                };
              final pipeline = _openContinuation(
                json,
                source,
                pages,
                state: state,
              );
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNotEmpty);
                expect(
                  hit.addressContext?.publicationAddress,
                  publication,
                  reason: 'premise: published exact tail',
                );
                expect(
                  hit.identityAddress,
                  publication,
                  reason: 'premise: approved stored identity',
                );
                expect(
                  pages.requests.single.url.toString(),
                  '$origin/catalog/book/1',
                );
                expect(
                  {
                    for (final entry in pages.requests.single.headers.entries)
                      entry.key.toLowerCase(): entry.value,
                  }['x-text'],
                  header,
                );
                final info = await pipeline.bookInfo(hit);
                expect(info.book.title, 'Book');
                expect(
                  info.tocAddress,
                  native,
                  reason: 'premise: finished TOC scalar',
                );
                expect(
                  hit.addressContext?.comparisonAddress,
                  native,
                  reason: 'target: special whole scalar comparison',
                );
                expect(
                  info.tocHtml,
                  isNotEmpty,
                  reason: 'target: native same page retained',
                );
                final (_, chapters) = await pipeline.tableOfContents(info);
                expect(chapters.single.name, 'Chapter');
                expect(chapters.single.url.path, '/c/1');
                expect(
                  pages.requests.length,
                  1,
                  reason: 'target: no extra TOC request',
                );
                expect(
                  await state.entry(
                    '$origin/catalog/search',
                    sourceRuleVariableKey(
                      '$origin/catalog/search',
                      'r07Special',
                    ),
                  ),
                  '1',
                  reason: 'target: no extra login',
                );
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }
  });

  group('repair07completion native logical bases', () {
    // A detail page the search stage keeps carries two different address facts:
    // the native logical whole-scalar text (`BookList.kt:159-163` over
    // `AnalyzeUrl.ruleUrl`) and the exact published tail. The retained cover and
    // the nonempty relative chapter reach the frozen String overload
    // (`NetworkUtils.kt:160-169`), so both resolve against the native logical
    // text before its first comma — not against the expanded publication. The
    // ordinary empty chapter keeps publishing the expanded fact.
    for (final json in [false, true]) {
      for (final deep in [false, true]) {
        for (final feature in ['cover', 'chapter']) {
          test(
            'repair07completion String consumer json=$json deep=$deep feature=$feature',
            () async {
              const origin = 'http://source.test';
              final header = deep ? 'a/../../b' : 'ab';
              final tail =
                  ',${jsonEncode({
                    'headers': {'X-Text': header},
                  })}';
              final publication = '$origin/catalog/book/book/1$tail';
              final comparison = deep
                  ? '$origin/catalog/book/b"}}'
                  : publication;
              final directory = deep
                  ? '$origin/catalog/book'
                  : '$origin/catalog/book/book';
              final page = _repair06Page(
                json,
                chapter: 'child',
                cover: 'cover.jpg',
              );
              final document = json
                  ? jsonEncode({
                      ...jsonDecode(page) as Map<String, dynamic>,
                      'content': 'Body',
                    })
                  : '$page<div id="content">Body</div>';
              final pages = _ContinuationPages(
                document,
                allowedPaths: const [
                  '/catalog/book/1',
                  '/catalog/book/child',
                  '/catalog/book/book/child',
                ],
              );
              final source = (json ? _jsonSource(origin) : _htmlSource(origin))
                ..['bookSourceUrl'] = '$origin/catalog/search'
                ..['searchUrl'] = 'book/1$tail'
                ..['bookUrlPattern'] = '.*'
                ..['ruleContent'] = {
                  'content': json ? r'$.content' : '#content@text',
                };
              final pipeline = _openContinuation(json, source, pages);
              try {
                final hit = (await pipeline.search('1')).single;
                expect(hit.title, 'Book', reason: 'premise: detail title');
                expect(
                  hit.infoHtml,
                  isNotEmpty,
                  reason: 'premise: retained detail body',
                );
                expect(
                  hit.addressContext?.comparisonAddress,
                  comparison,
                  reason: 'premise: genuine whole expanded scalar comparison',
                );
                expect(
                  hit.addressContext?.publicationAddress,
                  publication,
                  reason: 'premise: exact publication remains independent',
                );
                expect(
                  hit.identityAddress,
                  publication,
                  reason: 'premise: approved stored identity',
                );
                expect(
                  pages.requests.single.url.toString(),
                  '$origin/catalog/book/1',
                  reason: 'premise: real search target',
                );
                expect(
                  {
                    for (final entry in pages.requests.single.headers.entries)
                      entry.key.toLowerCase(): entry.value,
                  }['x-text'],
                  header,
                  reason: 'premise: option header executed',
                );
                final info = await pipeline.bookInfo(hit);
                expect(
                  info.tocHtml,
                  isNotEmpty,
                  reason: 'premise: retained TOC body',
                );
                expect(info.tocAddress, '');
                expect(
                  info.tocUrl,
                  publication,
                  reason: 'premise: publication text unchanged',
                );
                expect(pages.requests.length, 1);
                if (feature == 'cover') {
                  expect(
                    info.book.cover,
                    '$directory/cover.jpg',
                    reason: 'target: cover uses the native logical String base',
                  );
                } else {
                  final (_, chapters) = await pipeline.tableOfContents(info);
                  final chapter = chapters.single;
                  expect(chapter.name, 'Chapter');
                  expect(
                    chapter.address,
                    'child',
                    reason: 'premise: nonempty relative chapter',
                  );
                  expect(
                    pages.requests.length,
                    1,
                    reason: 'premise: no TOC network work',
                  );
                  await pipeline.chapter(chapter, book: info.book);
                  expect(pages.requests.length, 2);
                  expect(
                    chapter.url.toString(),
                    '$directory/child',
                    reason:
                        'target: relative chapter uses the native logical String base',
                  );
                  expect(
                    pages.requests.last.url.toString(),
                    '$directory/child',
                    reason:
                        'target: actual content request uses the native logical String base',
                  );
                  expect(chapter.storeKey, '$directory/child');
                }
              } finally {
                pipeline.cancel();
              }
            },
          );
        }
      }
    }

    // A typed legacy `SourceBookInfo` already carries the evaluated request
    // options of the text its retained TOC page publishes. An empty chapter's
    // target is that text analyzed as a URL, so building it must not re-read and
    // re-validate the whole raw option tail: an unsupported family still refuses
    // when the chapter's own options are explicitly consumed
    // (`SourceChapter.options`), which is the request consumer's place.
    for (final json in [false, true]) {
      for (final future in [false, true]) {
        test(
          'repair07completion legacy option admission json=$json future=$future',
          () async {
            const origin = 'http://source.test';
            const wire = '$origin/book/1';
            final tail =
                ',${jsonEncode({
                  'headers': {'X-Book': 'carry'},
                  if (future) 'serverID': 'future',
                })}';
            final raw = '$wire$tail';
            final document = _repair06Page(json, chapter: '');
            final pages = _ContinuationPages(
              document,
              allowedPaths: const ['/book/1'],
            );
            final source = json ? _jsonSource(origin) : _htmlSource(origin);
            final pipeline = _openContinuation(json, source, pages);
            final info = SourceBookInfo(
              book: HtmlBook(
                url: Uri.parse(wire),
                rawAddress: raw,
                title: 'Book',
                infoHtml: document,
                addressContext: (
                  comparisonAddress: raw,
                  publicationAddress: raw,
                ),
              ),
              tocAddress: '',
              tocBase: Uri.parse(wire),
              bookUrl: Uri.parse(wire),
              bookOptions: const SourceUrlOptions(headers: {'X-Book': 'carry'}),
              bookAddress: raw,
              keyword: '1',
              page: null,
              tocHtml: document,
            );
            try {
              expect(info.tocUrl, raw, reason: 'premise: raw text and options');
              expect(
                info.tocHtml,
                isNotEmpty,
                reason: 'premise: retained TOC body',
              );
              expect(
                pages.requests,
                isEmpty,
                reason: 'premise: no request yet',
              );
              Object? failure;
              List<SourceChapter>? values;
              try {
                final (_, chapters) = await pipeline.tableOfContents(info);
                values = chapters;
              } catch (error) {
                failure = error;
              }
              expect(
                failure,
                isNull,
                reason:
                    'target: typed legacy retained TOC does not revalidate the raw request family',
              );
              final chapter = values!.single;
              expect(
                pages.requests,
                isEmpty,
                reason: 'target: no request for the empty chapter',
              );
              expect(
                chapter.address,
                raw,
                reason: 'target: raw address text kept',
              );
              expect(
                chapter.url.toString(),
                wire,
                reason: 'target: target from the evaluated request fact',
              );
              if (future) {
                expect(
                  () => chapter.options,
                  throwsA(
                    isA<UnsupportedError>().having(
                      (error) => '${error.message}',
                      'message',
                      contains('serverID'),
                    ),
                  ),
                  reason:
                      'target: explicit option consumption keeps the named refusal',
                );
              } else {
                expect(chapter.options.headers['X-Book'], 'carry');
              }
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }
  });

  group('repair08 fallback target and comparison consumers', () {
    // The information wire consumes its charset while retained chapter
    // identity stays pre-option across pattern and fresh-pipeline handoffs.
    for (final json in [false, true]) {
      for (final flow in ['pattern', 'fallback', 'fresh-pattern']) {
        for (final valueCase in ['unicode', 'preencoded', 'ascii']) {
          test(
            'repair08 special charset json=$json flow=$flow value=$valueCase',
            () async {
              const origin = 'http://source.test';
              final value = valueCase == 'unicode'
                  ? '中'
                  : valueCase == 'preencoded'
                  ? '%D6%D0'
                  : 'word';
              final tail = ',${jsonEncode({'charset': 'gbk'})}';
              final raw = '$origin/book?q=$value$tail';
              final wire =
                  '$origin/book?q=${valueCase == 'ascii' ? 'word' : '%D6%D0'}';
              final preOption =
                  '$origin/book?q=${valueCase == 'unicode' ? '%E4%B8%AD' : value}';
              final page = _repair06Page(json, chapter: '', hit: false);
              final document = json
                  ? jsonEncode({
                      ...jsonDecode(page) as Map<String, dynamic>,
                      'text': 'Body',
                    })
                  : '$page<div id="content">Body</div>';
              final pages = _ContinuationPages(
                document,
                allowedPaths: const ['/book'],
              );
              final source = json
                  ? _jsonSource(
                      origin,
                      searchUrl: raw,
                      bookUrlPattern: flow == 'fallback' ? null : '.*',
                      bookList: flow == 'fallback'
                          ? r'$.missing[*]'
                          : r'$.listing[*]',
                    )
                  : _htmlSource(
                      origin,
                      searchUrl: raw,
                      bookUrlPattern: flow == 'fallback' ? null : '.*',
                      bookList: flow == 'fallback' ? '.missing' : 'div.item',
                    );
              final search = _openContinuation(json, source, pages);
              var pipeline = search;
              try {
                final hit = (await search.search('1')).single;
                expect(hit.title, 'Book');
                expect(hit.infoHtml, isNotEmpty);
                expect(hit.addressContext?.comparisonAddress, raw);
                expect(hit.addressContext?.publicationAddress, raw);
                expect(hit.identityAddress, raw);
                expect(
                  pages.requests.single.url.toString(),
                  wire,
                  reason:
                      'premise: the real search applied the declared GBK charset',
                );
                if (flow == 'fresh-pattern') {
                  pipeline = _openContinuation(json, source, pages);
                }
                final info = await pipeline.bookInfo(hit);
                expect(
                  info.tocHtml,
                  isNotEmpty,
                  reason: 'premise: information reused as TOC',
                );
                expect(info.tocAddress, '');
                expect(info.tocUrl, raw, reason: 'premise: raw fallback text');
                expect(
                  pages.requests.length,
                  1,
                  reason: 'premise: retained page, no TOC request',
                );
                final (_, chapters) = await pipeline.tableOfContents(info);
                final chapter = chapters.single;
                expect(chapter.address, raw);
                expect(
                  chapter.options.charset,
                  'gbk',
                  reason: 'premise: the fallback text keeps its option',
                );
                expect(
                  '${chapter.url}',
                  preOption,
                  reason:
                      'target: retained identity precedes charset processing',
                );
                expect(chapter.storeKey, preOption);
                expect(chapter.persistedAddress, raw);
                final body = await pipeline.chapter(chapter, book: info.book);
                expect(body.text, 'Body');
                expect(
                  pages.requests.map((request) => '${request.url}').toList(),
                  [wire],
                );
              } finally {
                pipeline.cancel();
                if (!identical(pipeline, search)) search.cancel();
              }
            },
          );
        }
      }
    }

    // Information and TOC option charsets remain distinct from the retained
    // chapter's pre-option identity and its complete persisted text.
    for (final json in [false, true]) {
      for (final sameCharset in [false, true]) {
        test(
          'repair08 distinct fallback charset json=$json same=$sameCharset',
          () async {
            const origin = 'http://source.test';
            final first = sameCharset ? 'gbk' : 'UTF-8';
            final book =
                'book/1,{"charset":"$first"}/../target?q=中,{"charset":"gbk"}';
            const rawToc = '$origin/catalog/book/target?q=中,{"charset":"gbk"}';
            const preOption = '$origin/catalog/book/target?q=%E4%B8%AD';
            final page = _repair06Page(
              json,
              book: book,
              toc: rawToc,
              chapter: '',
            );
            final document = json
                ? jsonEncode({
                    ...jsonDecode(page) as Map<String, dynamic>,
                    'text': 'Body',
                  })
                : '$page<div id="content">Body</div>';
            final pages = _ContinuationPages(
              document,
              allowedPaths: const [
                '/catalog/search',
                '/catalog/book/1',
                '/catalog/book/target',
              ],
            );
            final source = json
                ? _jsonSource(
                    '$origin/catalog/search',
                    searchUrl: '/catalog/search',
                  )
                : _htmlSource(
                    '$origin/catalog/search',
                    searchUrl: '/catalog/search',
                  );
            final pipeline = _openContinuation(json, source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.infoHtml, isNull, reason: 'premise: ordinary list');
              expect(
                hit.addressContext?.comparisonAddress,
                rawToc,
                reason:
                    'premise: the native whole scalar resolves to the declared TOC',
              );
              final info = await pipeline.bookInfo(hit);
              expect(info.book.title, 'Book');
              expect(
                info.bookOptions.charset,
                first,
                reason:
                    'premise: the information request keeps its own charset',
              );
              expect(info.tocAddress, rawToc);
              expect(
                info.tocHtml,
                isNotEmpty,
                reason: 'premise: information reused as TOC',
              );
              expect(info.tocUrl, rawToc);
              expect(
                pages.requests.map((request) => '${request.url}').toList(),
                ['$origin/catalog/search', '$origin/catalog/book/1'],
              );
              final (_, chapters) = await pipeline.tableOfContents(info);
              final chapter = chapters.single;
              expect(chapter.address, rawToc);
              expect(
                chapter.options.charset,
                'gbk',
                reason: 'premise: the fallback text keeps its own option',
              );
              expect(
                '${chapter.url}',
                preOption,
                reason: 'target: fallback identity precedes charset processing',
              );
              expect(chapter.storeKey, preOption);
              expect(chapter.persistedAddress, rawToc);
              final body = await pipeline.chapter(chapter, book: info.book);
              expect(body.text, 'Body');
              expect(
                pages.requests.map((request) => '${request.url}').toList(),
                ['$origin/catalog/search', '$origin/catalog/book/1'],
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    // A declared TOC's options remain pending; its empty chapter identity
    // precedes charset processing and information-request history.
    for (final json in [false, true]) {
      for (final scripted in [false, true]) {
        test(
          'repair08 declared TOC script json=$json scripted=$scripted',
          () async {
            const origin = 'http://source.test';
            final tail =
                ',${jsonEncode({'charset': 'gbk', if (scripted) 'js': 'result'})}';
            final rawToc = '$origin/catalog/book/target?q=中$tail';
            final book = 'book/1,{"charset":"gbk"}/../target?q=中$tail';
            final pages = _ContinuationPages(
              _repair06Page(json, book: book, toc: rawToc, chapter: ''),
              allowedPaths: const ['/catalog/search', '/catalog/book/1'],
            );
            final source = json
                ? _jsonSource(
                    '$origin/catalog/search',
                    searchUrl: '/catalog/search',
                  )
                : _htmlSource(
                    '$origin/catalog/search',
                    searchUrl: '/catalog/search',
                  );
            final pipeline = _openContinuation(json, source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.infoHtml, isNull, reason: 'premise: ordinary list');
              expect(hit.addressContext?.comparisonAddress, rawToc);
              final info = await pipeline.bookInfo(hit);
              expect(
                info.bookOptions.charset,
                'gbk',
                reason: 'premise: the information request keeps its charset',
              );
              expect(
                info.bookOptions.js,
                isNull,
                reason:
                    'premise: the information request carried no option script',
              );
              expect(
                info.bookUrl.hasQuery,
                isFalse,
                reason: 'premise: the information request had no query',
              );
              expect(
                info.tocAddress,
                rawToc,
                reason: 'premise: a declared TOC address, not the book address',
              );
              expect(
                info.tocHtml,
                isNotEmpty,
                reason: 'premise: information reused as TOC',
              );
              expect(info.tocUrl, rawToc);
              expect(
                pages.requests.map((request) => '${request.url}').toList(),
                ['$origin/catalog/search', '$origin/catalog/book/1'],
              );
              final (_, chapters) = await pipeline.tableOfContents(info);
              final chapter = chapters.single;
              expect(chapter.address, rawToc);
              expect(chapter.options.charset, 'gbk');
              expect(
                chapter.options.js,
                scripted ? 'result' : null,
                reason: 'premise: the declared TOC keeps its own script',
              );
              const expected = '$origin/catalog/book/target?q=%E4%B8%AD';
              expect(
                '${chapter.url}',
                expected,
                reason:
                    'control: the declared TOC query does not depend on the information request',
              );
              expect(chapter.storeKey, expected);
              expect(chapter.persistedAddress, rawToc);
              expect(
                pages.requests.length,
                2,
                reason: 'control: no extra request for the declared TOC',
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    // A POST request's charset lives in its body branch (`AnalyzeUrl.kt:248-260`),
    // so a POST fallback text never puts its query through the GET encoder: the
    // target keeps the URI's own UTF-8 representation, a structured body keeps
    // its JSON body, and a charset nothing consumes is not resolved at all.
    for (final json in [false, true]) {
      for (final scenario in [
        'known-unicode',
        'unknown-structured',
        'utf8-control',
        'ascii-control',
      ]) {
        test('repair08 POST empty json=$json scenario=$scenario', () async {
          const origin = 'http://source.test';
          final unknown = scenario == 'unknown-structured';
          final unicode =
              scenario == 'known-unicode' || scenario == 'utf8-control';
          final charset = unknown
              ? 'x-no-such-charset'
              : scenario == 'utf8-control'
              ? 'UTF-8'
              : 'gbk';
          final prefix = '$origin/book?q=${unicode ? '中' : 'x'}';
          final wire = '$origin/book?q=${unicode ? '%E4%B8%AD' : 'x'}';
          final tail =
              ',${jsonEncode({
                'method': 'POST',
                'body': {'x': 1},
                'charset': charset,
              })}';
          final raw = '$prefix$tail';
          final page = _repair06Page(json, chapter: '');
          final document = json
              ? jsonEncode({
                  ...jsonDecode(page) as Map<String, dynamic>,
                  'text': 'Body',
                })
              : '$page<div id="content">Body</div>';
          final pages = _ContinuationPages(
            document,
            allowedPaths: const ['/book'],
          );
          final source = json ? _jsonSource(origin) : _htmlSource(origin);
          final pipeline = _openContinuation(json, source, pages);
          try {
            final hit = HtmlBook(
              url: Uri.parse(prefix),
              rawAddress: raw,
              title: 'Book',
            );
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.bookOptions.isPost, isTrue);
            expect(info.bookOptions.charset, charset);
            expect(
              info.tocHtml,
              isNotEmpty,
              reason: 'premise: information reused as TOC',
            );
            expect(info.tocUrl, raw);
            expect('${pages.requests.single.url}', wire);
            expect(pages.requests.single.method, 'POST');
            expect(pages.requests.single.body, '{"x":1}');
            Object? failure;
            List<SourceChapter>? values;
            try {
              final (_, chapters) = await pipeline.tableOfContents(info);
              values = chapters;
            } catch (error) {
              failure = error;
            }
            expect(
              failure,
              isNull,
              reason:
                  'target: a POST empty target consumes no GET query charset',
            );
            final chapter = values!.single;
            expect(
              '${chapter.url}',
              wire,
              reason:
                  'target: the POST query keeps its existing URI representation',
            );
            expect(chapter.address, raw);
            expect(chapter.storeKey, wire);
            expect(chapter.persistedAddress, raw);
            final body = await pipeline.chapter(chapter, book: info.book);
            expect(body.text, 'Body');
            expect('${pages.requests.last.url}', wire);
            expect(pages.requests.last.method, 'POST');
            expect(pages.requests.last.body, '{"x":1}');
            expect(pages.requests.length, 1);
          } finally {
            pipeline.cancel();
          }
        });
      }
    }

    // An option script that replaced the request URL already dropped its query,
    // so the empty chapter's target does not resolve the discarded charset: the
    // completed request, its one script effect and the stored text are the facts
    // that remain.
    for (final json in [false, true]) {
      for (final unknown in [false, true]) {
        test(
          'repair08 no-capture discarded query json=$json unknown=$unknown',
          () async {
            const origin = 'http://source.test';
            final tail =
                ',${jsonEncode({'charset': unknown ? 'x-no-such-charset' : 'UTF-8', 'js': "source.put('once',String(Number(source.get('once')||'0')+1)); '$origin/wire'"})}';
            final raw = '$origin/book?q=x$tail';
            final state = SourceHostState();
            final pages = _ContinuationPages(
              _repair06Page(json, chapter: ''),
              allowedPaths: const ['/wire'],
            );
            final source = json ? _jsonSource(origin) : _htmlSource(origin);
            final pipeline = _openContinuation(
              json,
              source,
              pages,
              state: state,
            );
            try {
              final info = await pipeline.bookInfo(
                HtmlBook(
                  url: Uri.parse('$origin/book?q=x'),
                  rawAddress: raw,
                  title: 'Book',
                ),
              );
              expect(info.book.title, 'Book');
              expect(
                info.tocHtml,
                isNotEmpty,
                reason: 'premise: information reused as TOC',
              );
              expect(info.tocUrl, raw, reason: 'premise: raw fallback text');
              expect(
                '${pages.requests.single.url}',
                '$origin/wire',
                reason: 'premise: the option script replaced the request URL',
              );
              expect(
                await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, 'once'),
                ),
                '1',
                reason: 'premise: one script effect for the request',
              );
              Object? failure;
              List<SourceChapter>? values;
              try {
                final (_, chapters) = await pipeline.tableOfContents(info);
                values = chapters;
              } catch (error) {
                failure = error;
              }
              expect(
                failure,
                isNull,
                reason:
                    'target: the TOC does not newly validate the discarded query charset',
              );
              expect(values!.single.address, raw);
              expect('${values.single.url}', '$origin/book?q=x');
              expect(pages.requests.length, 1);
              expect(
                await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, 'once'),
                ),
                '1',
                reason: 'target: the script is not re-executed',
              );
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    // A retained same-page TOC compares its fragment-only scalar against the
    // native logical text (`WebBook.kt:157-165` over `AnalyzeRule.kt:315-323`),
    // not against the expanded publication, so the body is retained and no extra
    // TOC request or login check runs.
    for (final json in [false, true]) {
      for (final deep in [false, true]) {
        test('repair08 self fragment json=$json deep=$deep', () async {
          const origin = 'http://source.test';
          final header = deep ? 'a/../../b#anchor' : 'ab#anchor';
          final tail =
              ',${jsonEncode({
                'headers': {'X-Text': header},
              })}';
          final publication = '$origin/catalog/book/book/1$tail';
          final comparison = deep
              ? '$origin/catalog/book/b#anchor"}}'
              : publication;
          const toc = '#anchor"}}';
          final pages = _ContinuationPages(
            _repair06Page(json, toc: toc, chapter: '$origin/chapter'),
            allowedPaths: const ['/catalog/book/1'],
          );
          final state = SourceHostState();
          final source = (json ? _jsonSource(origin) : _htmlSource(origin))
            ..['bookSourceUrl'] = '$origin/catalog/search'
            ..['searchUrl'] = 'book/1$tail'
            ..['bookUrlPattern'] = '.*'
            ..['loginCheckJs'] =
                "source.put('login',String(Number(source.get('login')||'0')+1)); result";
          final pipeline = _openContinuation(json, source, pages, state: state);
          try {
            final hit = (await pipeline.search('1')).single;
            expect(hit.title, 'Book');
            expect(hit.infoHtml, isNotEmpty);
            expect(
              hit.addressContext?.comparisonAddress,
              comparison,
              reason: 'premise: the native whole scalar',
            );
            expect(
              hit.addressContext?.publicationAddress,
              publication,
              reason: 'premise: the exact published tail',
            );
            expect('${pages.requests.single.url}', '$origin/catalog/book/1');
            expect(
              {
                for (final entry in pages.requests.single.headers.entries)
                  entry.key.toLowerCase(): entry.value,
              }['x-text'],
              header,
            );
            final info = await pipeline.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.tocAddress, toc, reason: 'premise: fragment-only TOC');
            expect(info.tocUrl, publication);
            expect(pages.requests.length, 1);
            expect(
              await state.entry(
                '$origin/catalog/search',
                sourceRuleVariableKey('$origin/catalog/search', 'login'),
              ),
              '1',
            );
            expect(
              info.tocHtml,
              isNotEmpty,
              reason:
                  'target: the fragment compares against the native logical base',
            );
            final (_, chapters) = await pipeline.tableOfContents(info);
            expect(chapters.single.url.toString(), '$origin/chapter');
            expect(pages.requests.length, 1);
            expect(
              await state.entry(
                '$origin/catalog/search',
                sourceRuleVariableKey('$origin/catalog/search', 'login'),
              ),
              '1',
              reason: 'target: no extra login check',
            );
          } finally {
            pipeline.cancel();
          }
        });
      }
    }

    // The comparison text a retained page carries is a finished scalar, not a
    // request: a `,{'serverID':…}` boundary the native URL operation left in it
    // is data. Only the request parsers and `SourceChapter.options` refuse an
    // unsupported family by name.
    for (final json in [false, true]) {
      for (final future in [false, true]) {
        test(
          'repair08 comparison option-shaped data json=$json future=$future',
          () async {
            const origin = 'http://source.test';
            final header = future
                ? "a/../target,{'serverID':'future'}"
                : 'a/../target';
            final tail =
                ',${jsonEncode({
                  'headers': {'X-Text': header},
                })}';
            final publication = '$origin/catalog/book/book/1$tail';
            final comparison =
                '$origin/catalog/book/book/target${future ? ",{'serverID':'future'}" : ''}"}}';
            final pages = _ContinuationPages(
              _repair06Page(json, chapter: '$origin/chapter'),
              allowedPaths: const ['/catalog/book/1'],
            );
            final source = (json ? _jsonSource(origin) : _htmlSource(origin))
              ..['bookSourceUrl'] = '$origin/catalog/search'
              ..['searchUrl'] = 'book/1$tail'
              ..['bookUrlPattern'] = '.*';
            final pipeline = _openContinuation(json, source, pages);
            try {
              final hit = (await pipeline.search('1')).single;
              expect(hit.title, 'Book');
              expect(hit.infoHtml, isNotEmpty);
              expect(
                hit.addressContext?.comparisonAddress,
                comparison,
                reason: 'premise: the native whole scalar',
              );
              expect(hit.addressContext?.publicationAddress, publication);
              expect('${pages.requests.single.url}', '$origin/catalog/book/1');
              expect(
                {
                  for (final entry in pages.requests.single.headers.entries)
                    entry.key.toLowerCase(): entry.value,
                }['x-text'],
                header,
              );
              Object? failure;
              SourceBookInfo? info;
              try {
                info = await pipeline.bookInfo(hit);
              } catch (error) {
                failure = error;
              }
              expect(
                failure,
                isNull,
                reason:
                    'target: logical comparison data is not a request option object',
              );
              expect(info!.book.title, 'Book');
              expect(
                info.tocHtml,
                isNotEmpty,
                reason: 'target: the retained body is read',
              );
              final (_, chapters) = await pipeline.tableOfContents(info);
              expect(chapters.single.url.toString(), '$origin/chapter');
              expect(pages.requests.length, 1);
            } finally {
              pipeline.cancel();
            }
          },
        );
      }
    }

    for (final json in [false, true]) {
      test(
        'retained fallback identity ignores information wire json=$json',
        () async {
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final origin = 'http://127.0.0.1:${server.port}';
          final seen = <String>[];
          final page = json
              ? jsonEncode({
                  ...jsonDecode(_repair06Page(true, chapter: ''))
                      as Map<String, dynamic>,
                  'text': 'Body',
                })
              : '${_repair06Page(false, chapter: '')}<div id="content">Body</div>';
          server.listen((request) async {
            seen.add(request.uri.toString());
            request.response.write(page);
            await request.response.close();
          });
          final script =
              "source.put('once',String(Number(source.get('once')||'0')+1)); '$origin/wire'+source.get('choice')";
          final raw =
              '$origin/book?q=中,${jsonEncode({'charset': 'gbk', 'js': script})}';
          final source = json ? _jsonSource(origin) : _htmlSource(origin);
          final keys = <String>[];
          final saved = <String>[];
          try {
            for (final choice in ['', '#frag?probe=wire']) {
              final state = SourceHostState();
              await state.putEntry(
                origin,
                sourceRuleVariableKey(origin, 'choice'),
                choice,
              );
              final pipeline = json
                  ? JsonSourcePipeline(
                      source,
                      HttpSourceTransport(),
                      hostState: state,
                    )
                  : HtmlSourcePipeline(
                      source,
                      HttpSourceTransport(),
                      hostState: state,
                    );
              try {
                final info = await pipeline.bookInfo(
                  HtmlBook(
                    url: Uri.parse('$origin/book?q=中'),
                    rawAddress: raw,
                    title: 'Book',
                  ),
                );
                final (book, chapters) = await pipeline.tableOfContents(info);
                final chapter = chapters.single;
                keys.add(chapter.storeKey);
                saved.add(chapter.persistedAddress);
                expect(chapter.storeKey, '$origin/book?q=%E4%B8%AD');
                expect(chapter.persistedAddress, raw);
                expect(
                  (await pipeline.chapter(chapter, book: book)).text,
                  'Body',
                );
                expect(
                  await state.entry(
                    origin,
                    sourceRuleVariableKey(origin, 'once'),
                  ),
                  '1',
                );
              } finally {
                pipeline.cancel();
              }
            }
            expect(seen, ['/wire', '/wire?probe=wire']);
            expect(keys.toSet(), hasLength(1));
            expect(saved, [raw, raw]);
          } finally {
            await server.close(force: true);
          }
        },
      );
    }
  });

  // The approved chapter lifecycle separates a new chapter's identity from the
  // target its own request options produce: the TOC keeps the rule's finished
  // text, the key is the bare resolved pre-option target, the saved request text
  // appends that exact option tail once, and the option script runs for the
  // actual content request alone.
  group('chapterLifecycle', () {
    const origin = 'http://source.test';
    const bookAddress = 'http://source.test/catalog/book/1';
    const preOptionTarget = 'http://source.test/catalog/content?q=ascii';
    const selectedTarget =
        'http://source.test/catalog/content-selected?q=ascii';
    const counterScript =
        "source.put('chapterRuns',String(Number(source.get('chapterRuns')||'0')+1));result";
    const selectedScript =
        "source.put('chapterRuns',String(Number(source.get('chapterRuns')||'0')+1));'$selectedTarget'";

    final cases = <({String name, bool json, String? script, String target})>[
      (
        name: 'JSON independent chapter, option script returns its input',
        json: true,
        script: counterScript,
        target: preOptionTarget,
      ),
      (
        name:
            'JSON independent chapter, option script chooses a different explicit absolute target',
        json: true,
        script: selectedScript,
        target: selectedTarget,
      ),
      (
        name:
            'JSON independent chapter without request-option script (control)',
        json: true,
        script: null,
        target: preOptionTarget,
      ),
      (
        name:
            'HTML independent chapter without request-option script (control)',
        json: false,
        script: null,
        target: preOptionTarget,
      ),
    ];

    for (final testCase in cases) {
      test(testCase.name, () async {
        final script = testCase.script;
        final tail =
            ',${jsonEncode({
              'headers': {'X-Chapter': 'once'},
              'js': ?script,
            })}';
        final raw = '$preOptionTarget$tail';
        final page = _repair06Page(
          testCase.json,
          book: '/catalog/book/1',
          toc: '/catalog/book/1',
          chapter: raw,
        );
        final document = testCase.json
            ? jsonEncode({
                ...jsonDecode(page) as Map<String, dynamic>,
                'text': 'Body',
              })
            : '$page<div id="content">Body</div>';
        final pages = _ContinuationPages(
          document,
          // Both content candidates are answerable, so a wrong target fails its
          // own assertion instead of the fixture's path refusal.
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
            '/catalog/content-selected',
          ],
        );
        final state = SourceHostState();
        final source =
            (testCase.json ? _jsonSource(origin) : _htmlSource(origin))
              ..['searchUrl'] = '/catalog/search?q=ascii'
              ..['bookUrlPattern'] = r'$^';
        final pipeline = _openContinuation(
          testCase.json,
          source,
          pages,
          state: state,
        );
        final runsKey = sourceRuleVariableKey(origin, 'chapterRuns');
        try {
          final hit = (await pipeline.search('ascii')).single;
          expect(hit.title, 'Book', reason: 'premise: a valid search result');
          final info = await pipeline.bookInfo(hit);
          expect(
            info.book.title,
            'Book',
            reason: 'premise: a valid information page',
          );
          expect(
            info.tocUrl,
            bookAddress,
            reason: 'premise: the TOC is the information page',
          );
          final (book, chapters) = await pipeline.tableOfContents(info);
          expect(
            pages.requests.map((request) => request.url.path),
            ['/catalog/search', '/catalog/book/1'],
            reason:
                'premise: only the search and information requests are real',
          );
          final chapter = chapters.single;
          expect(chapter.name, 'Chapter', reason: 'premise: the chapter list');
          expect(
            chapter.address,
            raw,
            reason:
                'premise: the address is the rule finished text and its tail',
          );
          expect(
            chapter.options.headers['X-Chapter'],
            'once',
            reason: 'premise: the tail is this chapter request own options',
          );
          expect(
            await state.entry(origin, runsKey),
            isNull,
            reason: 'target: no request-option effect at TOC',
          );
          expect(
            '${chapter.url}',
            preOptionTarget,
            reason: 'target: the chapter URL is the pre-option target',
          );
          expect(
            chapter.storeKey,
            preOptionTarget,
            reason: 'target: the new chapter keys by its pre-option target',
          );
          expect(
            chapter.persistedAddress,
            '$preOptionTarget$tail',
            reason:
                'target: the saved text keeps that target and the exact tail once',
          );
          final body = await pipeline.chapter(chapter, book: info.book);
          expect(
            body.text,
            'Body',
            reason: 'target: the content rule reads the answered page',
          );
          expect(
            pages.requests.length,
            3,
            reason: 'target: exactly one content request',
          );
          expect(
            '${pages.requests.last.url}',
            testCase.target,
            reason: 'target: the actual content request target',
          );
          expect(
            pages.requests.last.headers['X-Chapter'],
            'once',
            reason: 'target: the option header on the actual request',
          );
          final Object expectedRuns = script == null ? isNull : '1';
          expect(
            await state.entry(origin, runsKey),
            expectedRuns,
            reason:
                'target: the option script runs once for the content request only',
          );
          expect(
            chapter.storeKey,
            preOptionTarget,
            reason: 'target: the fetch leaves the key',
          );
          expect(
            chapter.persistedAddress,
            '$preOptionTarget$tail',
            reason: 'target: the fetch leaves the saved text',
          );
          expect(
            book.identityAddress,
            bookAddress,
            reason: 'target: the fetch leaves the book identity',
          );
        } finally {
          pipeline.cancel();
        }
      });
    }
  });

  // The chapter address's own request program belongs to the actual content
  // request: the TOC keeps the rule's finished text, and the one request that
  // fetches the chapter expands that text once.
  group('chapterRequestExpansion', () {
    const origin = 'http://source.test';
    const tail = ',{"headers":{"X-Chapter":"once"}}';

    for (final fresh in [false, true]) {
      for (final scripted in [false, true]) {
        test('request template timing fresh=$fresh scripted=$scripted', () async {
          final raw = scripted
              ? "$origin/catalog/content?q={{source.put('addressRuns',String(Number(source.get('addressRuns')||'0')+1));'ascii'}}$tail"
              : '$origin/catalog/content?q=ascii$tail';
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/catalog/book/1',
            chapter: raw,
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          });
          final pages = _ContinuationPages(
            document,
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/content',
            ],
          );
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^';
          final state = SourceHostState();
          final first = _openContinuation(true, source, pages, state: state);
          BookSourcePipeline? second;
          final runsKey = sourceRuleVariableKey(origin, 'addressRuns');
          try {
            final hit = (await first.search('ascii')).single;
            final info = await first.bookInfo(hit);
            final (book, chapters) = await first.tableOfContents(info);
            expect(book.title, 'Book', reason: 'premise: valid book');
            expect(
              pages.requests.map((request) => request.url.path),
              ['/catalog/search', '/catalog/book/1'],
              reason: 'premise: no content request yet',
            );
            final chapter = chapters.single.withVariable('{"seed":"kept"}');
            expect(
              chapter.address,
              raw,
              reason: 'premise: rule scalar preserved',
            );
            expect(
              chapter.options.headers['X-Chapter'],
              'once',
              reason: 'premise: chapter options',
            );
            final key = chapter.storeKey;
            expect(
              await state.entry(origin, runsKey),
              isNull,
              reason: 'target: request template is not evaluated at TOC',
            );
            final reader = fresh
                ? (second = _openContinuation(
                    true,
                    source,
                    pages,
                    state: state,
                  ))
                : first;
            final body = await reader.chapter(chapter, book: book);
            expect(body.text, 'Body');
            expect(pages.requests.length, 3);
            expect(
              '${pages.requests.last.url}',
              '$origin/catalog/content?q=ascii',
            );
            expect(pages.requests.last.headers['X-Chapter'], 'once');
            expect(
              await state.entry(origin, runsKey),
              scripted ? '1' : isNull,
              reason: 'target: template executes once at actual request',
            );
            expect(chapter.storeKey, key);
          } finally {
            first.cancel();
            second?.cancel();
          }
        });
      }

      for (final generated in [false, true]) {
        test('generated result marker fresh=$fresh generated=$generated', () async {
          final raw = generated
              ? '$origin/catalog/content?q={{String.fromCharCode(64,114,101,115,117,108,116)}}$tail'
              : '$origin/catalog/content?q=%40result$tail';
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/catalog/book/1',
            chapter: raw,
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          });
          final pages = _ContinuationPages(
            document,
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/content',
            ],
          );
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^';
          final first = _openContinuation(true, source, pages);
          BookSourcePipeline? second;
          try {
            final hit = (await first.search('ascii')).single;
            final info = await first.bookInfo(hit);
            final (book, chapters) = await first.tableOfContents(info);
            expect(book.title, 'Book');
            expect(pages.requests.map((request) => request.url.path), [
              '/catalog/search',
              '/catalog/book/1',
            ]);
            final chapter = chapters.single.withVariable('{"seed":"kept"}');
            expect(chapter.address, raw);
            final reader = fresh
                ? (second = _openContinuation(true, source, pages))
                : first;
            final body = await reader.chapter(chapter, book: book);
            expect(
              body.text,
              'Body',
              reason: 'premise: content request succeeded',
            );
            expect(
              pages.requests.length,
              3,
              reason: 'premise: one content request',
            );
            expect(
              pages.requests.last.headers['X-Chapter'],
              'once',
              reason: 'premise: own request header',
            );
            expect(
              '${pages.requests.last.url}',
              generated
                  ? '$origin/catalog/content?q=@result'
                  : '$origin/catalog/content?q=%40result',
              reason:
                  'target: the generated result marker remains URL data, expanded once',
            );
          } finally {
            first.cancel();
            second?.cancel();
          }
        });
      }
    }
  });

  // A pending chapter address is resolved against the TOC page's own base before
  // its request program runs: the chapter names an absolute identity now, keeps
  // that resolved base in its saved request text, and the single actual request
  // executes whatever program the address still carries.
  group('chapterPendingAddress', () {
    const origin = 'http://source.test';
    const query = '{{String.fromCharCode(97,115,99,105,105)}}';
    const tail = ',{"headers":{"X-Chapter":"once"}}';

    for (final fresh in [false, true]) {
      for (final relative in [false, true]) {
        test('resolved identity fresh=$fresh relative=$relative', () async {
          final raw = relative
              ? '../content?q=$query$tail'
              : '$origin/catalog/content?q=$query$tail';
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/catalog/deep/toc',
            chapter: raw,
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          });
          final pages = _ContinuationPages(
            document,
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/deep/toc',
              '/catalog/content',
            ],
          );
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^';
          final first = _openContinuation(true, source, pages);
          BookSourcePipeline? second;
          try {
            final hit = (await first.search('ascii')).single;
            final info = await first.bookInfo(hit);
            final (book, chapters) = await first.tableOfContents(info);
            expect(book.title, 'Book');
            expect(info.tocUrl, '$origin/catalog/deep/toc');
            expect(pages.requests.map((request) => request.url.path), [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/deep/toc',
            ]);
            final chapter = chapters.single.withVariable('{"seed":"kept"}');
            expect(chapter.address, raw);
            expect(chapter.addressBase?.path, '/catalog/deep/toc');
            final keyBefore = chapter.storeKey;
            final reader = fresh
                ? (second = _openContinuation(true, source, pages))
                : first;
            final body = await reader.chapter(chapter, book: book);
            expect(
              body.text,
              'Body',
              reason: 'premise: the actual chapter request works',
            );
            expect(pages.requests.length, 4);
            expect(
              '${pages.requests.last.url}',
              '$origin/catalog/content?q=ascii',
            );
            expect(pages.requests.last.headers['X-Chapter'], 'once');
            expect(chapter.storeKey, keyBefore);
            expect(
              chapter.url.isAbsolute,
              isTrue,
              reason:
                  'target: pending relative chapter identity is resolved before request execution',
            );
            expect(chapter.url.path, '/catalog/content');
            expect(chapter.storeKey, startsWith('$origin/catalog/content?'));
            expect(
              chapter.persistedAddress,
              '$origin/catalog/content?q=$query$tail',
              reason:
                  'target: saved request text keeps its resolved base and unexecuted template',
            );
          } finally {
            first.cancel();
            second?.cancel();
          }
        });
      }
    }

    for (final relative in [false, true]) {
      test('different TOC bases remain distinct relative=$relative', () async {
        final keys = <String>[];
        for (final directory in ['catalog', 'other']) {
          final raw = relative
              ? '../content?q=$query$tail'
              : '$origin/$directory/content?q=$query$tail';
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/$directory/deep/toc',
            chapter: raw,
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          });
          final pages = _ContinuationPages(
            document,
            allowedPaths: [
              '/catalog/search',
              '/catalog/book/1',
              '/$directory/deep/toc',
              '/$directory/content',
            ],
          );
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^';
          final pipeline = _openContinuation(true, source, pages);
          try {
            final hit = (await pipeline.search('ascii')).single;
            final info = await pipeline.bookInfo(hit);
            final (book, chapters) = await pipeline.tableOfContents(info);
            expect(book.identityAddress, '$origin/catalog/book/1');
            final chapter = chapters.single;
            expect(chapter.addressBase?.path, '/$directory/deep/toc');
            final body = await pipeline.chapter(chapter, book: book);
            expect(body.text, 'Body');
            expect(pages.requests.length, 4);
            expect(
              '${pages.requests.last.url}',
              '$origin/$directory/content?q=ascii',
              reason: 'premise: distinct actual targets',
            );
            keys.add(chapter.storeKey);
          } finally {
            pipeline.cancel();
          }
        }
        expect(
          keys.toSet(),
          hasLength(2),
          reason:
              'target: different logical bases cannot collapse to one chapter key',
        );
      });
    }

    for (final fresh in [false, true]) {
      for (final programmed in [false, true]) {
        test('whole request program fresh=$fresh programmed=$programmed', () async {
          final raw = programmed
              ? "@js:source.put('programRuns',String(Number(source.get('programRuns')||'0')+1));'$origin/catalog/content?q=ascii'"
              : '$origin/catalog/content?q=ascii';
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/catalog/deep/toc',
            chapter: raw,
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          });
          final pages = _ContinuationPages(
            document,
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/deep/toc',
              '/catalog/content',
            ],
          );
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^';
          final state = SourceHostState();
          final first = _openContinuation(true, source, pages, state: state);
          BookSourcePipeline? second;
          final key = sourceRuleVariableKey(origin, 'programRuns');
          try {
            final hit = (await first.search('ascii')).single;
            final info = await first.bookInfo(hit);
            expect(info.book.title, 'Book');
            expect(info.tocUrl, '$origin/catalog/deep/toc');
            expect(pages.requests.map((request) => request.url.path), [
              '/catalog/search',
              '/catalog/book/1',
            ]);
            final directory = first.tableOfContents(info).catchError((
              Object error,
              StackTrace stack,
            ) {
              if (error is FormatException &&
                  error.message ==
                      'Scheme not starting with alphabetic character') {
                fail(
                  'target: a supported pending request program is not parsed as a URI scheme at TOC: ${error.message}',
                );
              }
              Error.throwWithStackTrace(error, stack);
            });
            final (book, chapters) = await directory;
            final chapter = chapters.single.withVariable('{"seed":"kept"}');
            expect(chapter.address, raw);
            expect(pages.requests.map((request) => request.url.path), [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/deep/toc',
            ]);
            expect(
              await state.entry(origin, key),
              isNull,
              reason: 'target: no request-program effects at TOC',
            );
            final stableKey = chapter.storeKey;
            final saved = chapter.persistedAddress;
            final reader = fresh
                ? (second = _openContinuation(
                    true,
                    source,
                    pages,
                    state: state,
                  ))
                : first;
            final body = await reader.chapter(chapter, book: book);
            expect(body.text, 'Body');
            expect(pages.requests.length, 4);
            expect(
              '${pages.requests.last.url}',
              '$origin/catalog/content?q=ascii',
            );
            expect(await state.entry(origin, key), programmed ? '1' : isNull);
            expect(chapter.storeKey, stableKey);
            expect(chapter.persistedAddress, saved);
          } finally {
            first.cancel();
            second?.cancel();
          }
        });
      }
    }
  });

  // The approved chapter lifecycle reuses the TOC page's retained body for a
  // chapter whose finished raw text is the book's own finished text
  // (`WebBook.kt:311-329`): that branch runs no request processing, so it reads
  // neither the source header nor the login check. A chapter whose *resolved*
  // address merely equals the book's — a different raw text over the same base —
  // is ordinary content work, so URI equality alone cannot admit the reuse.
  group('chapterRetainedBody', () {
    const origin = 'http://source.test';
    const bookAddress = 'http://source.test/catalog/book/1';
    const headerRule =
        '@js:source.put("headerRuns",String(Number(source.get("headerRuns")||"0")+1));JSON.stringify({"X-Source":"keep"})';
    const loginRule =
        "source.put('loginRuns',String(Number(source.get('loginRuns')||'0')+1)); result";

    for (final fresh in [false, true]) {
      for (final reuse in [false, true]) {
        test('retained page fresh=$fresh reuse=$reuse', () async {
          final page = _repair06Page(
            true,
            book: '/catalog/book/1',
            toc: '/catalog/book/1',
            chapter: reuse ? '' : '../book/1',
          );
          final document = jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Retained body',
          });
          final pages = _ContinuationPages(
            document,
            // Both book candidates are answerable, so a wrong chapter target
            // fails its own assertion instead of the fixture's path refusal.
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/book/1',
            ],
          );
          final state = SourceHostState();
          final source = _jsonSource(origin)
            ..['searchUrl'] = '/catalog/search?q=ascii'
            ..['bookUrlPattern'] = r'$^'
            ..['header'] = headerRule
            ..['loginCheckJs'] = loginRule;
          final headerKey = sourceRuleVariableKey(origin, 'headerRuns');
          final loginKey = sourceRuleVariableKey(origin, 'loginRuns');
          final producer = _openContinuation(true, source, pages, state: state);
          BookSourcePipeline? receiver;
          try {
            final hit = (await producer.search('ascii')).single;
            expect(hit.title, 'Book', reason: 'premise: a valid search result');
            final info = await producer.bookInfo(hit);
            expect(
              info.book.title,
              'Book',
              reason: 'premise: a valid information page',
            );
            expect(
              info.tocUrl,
              bookAddress,
              reason: 'premise: the TOC is the information page',
            );
            final (book, chapters) = await producer.tableOfContents(info);
            expect(
              pages.requests.map((request) => request.url.path),
              ['/catalog/search', '/catalog/book/1'],
              reason:
                  'premise: only the search and information requests are real',
            );
            final chapter = chapters.single;
            expect(
              chapter.name,
              'Chapter',
              reason: 'premise: the chapter list',
            );
            if (reuse) {
              expect(
                chapter.address,
                bookAddress,
                reason:
                    'premise: the ordinary empty fallback keeps the retained page own finished text',
              );
              expect(
                book.identityAddress,
                chapter.address,
                reason: 'premise: that finished text is the book own text',
              );
            } else {
              expect(
                chapter.address,
                '../book/1',
                reason: 'premise: the chapter raw text is not the book text',
              );
            }
            expect(
              '${chapter.url}',
              bookAddress,
              reason: 'premise: both rows name the same resolved target',
            );
            expect(
              await state.entry(origin, headerKey),
              '2',
              reason: 'premise: search and information each read a header',
            );
            expect(
              await state.entry(origin, loginKey),
              '2',
              reason: 'premise: one login check per fetched stage',
            );
            final key = chapter.storeKey;
            final saved = chapter.persistedAddress;
            final reader = fresh
                ? (receiver = _openContinuation(
                    true,
                    source,
                    pages,
                    state: state,
                  ))
                : producer;
            final body = await reader.chapter(chapter, book: book);
            expect(
              body.text,
              'Retained body',
              reason: 'target: the content rule reads the retained body',
            );
            expect(
              pages.requests.length,
              reuse ? 2 : 3,
              reason: reuse
                  ? 'target: retained content makes no new request'
                  : 'target: a different raw text fetches its own content request',
            );
            if (!reuse) {
              expect(
                '${pages.requests.last.url}',
                bookAddress,
                reason: 'target: the actual content request target',
              );
            }
            expect(
              await state.entry(origin, headerKey),
              reuse ? '2' : '3',
              reason: reuse
                  ? 'target: reuse runs no header processing'
                  : 'target: a real content request reads its own header',
            );
            expect(
              await state.entry(origin, loginKey),
              reuse ? '2' : '3',
              reason: reuse
                  ? 'target: reuse runs no login check'
                  : 'target: the content response runs one login check',
            );
            expect(
              chapter.storeKey,
              key,
              reason: 'target: the fetch leaves the key',
            );
            expect(
              chapter.persistedAddress,
              saved,
              reason: 'target: the fetch leaves the saved text',
            );
            expect(
              book.identityAddress,
              bookAddress,
              reason: 'target: the fetch leaves the book identity',
            );
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }
  });

  // The retained page and the requests around it keep their own
  // responsibilities: the reused first page reads no source header, sends
  // nothing and runs no address option, while a real request — the chapter's
  // first page or a page that first one declares — reads the source header
  // before it executes those options, and a later page resolves against the
  // complete native `BookChapter.getAbsoluteURL()` text the retained page
  // carries.
  group('chapterRetainedConsumers', () {
    const origin = 'http://source.test';
    const bookAddress = '$origin/catalog/book/1';

    for (final fresh in [false, true]) {
      test('header-order fresh=$fresh', () async {
        final tail =
            ',${jsonEncode({'js': "source.put('order',source.get('order')+'J');result"})}';
        final page = _repair06Page(
          true,
          book: '/catalog/book/1',
          toc: '/catalog/book/1',
          chapter: '$origin/catalog/content$tail',
        );
        final pages = _ContinuationPages(
          jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'Body',
          }),
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
          ],
        );
        final state = SourceHostState();
        final source = _jsonSource(origin)
          ..['searchUrl'] = '/catalog/search'
          ..['bookUrlPattern'] = r'$^'
          ..['header'] =
              '@js:source.put("order",(source.get("order")||"")+"H");JSON.stringify({"X-Source":"keep"})';
        final producer = _openContinuation(true, source, pages, state: state);
        BookSourcePipeline? receiver;
        try {
          final info = await producer.bookInfo(
            (await producer.search('ascii')).single,
          );
          final (book, chapters) = await producer.tableOfContents(info);
          final key = sourceRuleVariableKey(origin, 'order');
          expect(
            pages.requests.length,
            2,
            reason: 'premise: search and info only',
          );
          expect(
            await state.entry(origin, key),
            'HH',
            reason: 'premise: search and info each read the header',
          );
          final reader = fresh
              ? (receiver = _openContinuation(
                  true,
                  source,
                  pages,
                  state: state,
                ))
              : producer;
          final body = await reader.chapter(chapters.single, book: book);
          expect(body.text, 'Body');
          expect(pages.requests.length, 3);
          expect(pages.requests.last.url.path, '/catalog/content');
          expect(
            await state.entry(origin, key),
            'HHHJ',
            reason:
                'target: actual request reads source header before option script',
          );
        } finally {
          producer.cancel();
          receiver?.cancel();
        }
      });
    }

    for (final fresh in [false, true]) {
      for (final tail in [false, true]) {
        test('next-page fresh=$fresh tail=$tail', () async {
          final suffix = tail
              ? ',${jsonEncode({
                  'headers': {'X-Route': 'part/../../end'},
                })}'
              : '';
          final raw = '$bookAddress$suffix';
          final page = _repair06Page(true, chapter: '');
          final pages = _RetainedPagingPages(
            jsonEncode({
              ...jsonDecode(page) as Map<String, dynamic>,
              'text': 'First',
              'next': 'leaf',
            }),
          );
          final state = SourceHostState();
          final source = _jsonSource(origin)
            ..['header'] = '{"X-Source":"keep"}'
            ..['ruleContent'] = {
              'content': r'$.text',
              'nextContentUrl': r'$.next',
            };
          final producer = _openContinuation(true, source, pages, state: state);
          BookSourcePipeline? receiver;
          try {
            final info = await producer.bookInfo(
              HtmlBook(
                url: Uri.parse(bookAddress),
                rawAddress: raw,
                title: 'Book',
              ),
            );
            expect(info.tocHtml, isNotEmpty);
            expect(info.tocUrl, raw);
            expect(
              info.book.addressContext?.comparisonAddress ??
                  info.book.identityAddress,
              raw,
            );
            final (book, chapters) = await producer.tableOfContents(info);
            expect(pages.requests.length, 1, reason: 'premise: retained TOC');
            expect(chapters.single.address, raw);
            final reader = fresh
                ? (receiver = _openContinuation(
                    true,
                    source,
                    pages,
                    state: state,
                  ))
                : producer;
            final body = await reader.chapter(chapters.single, book: book);
            expect(body.text, 'First\nSecond');
            expect(
              pages.requests.length,
              2,
              reason:
                  'target: retained first page then exactly one real next request',
            );
            expect(
              pages.requests.last.headers.entries.any(
                (entry) =>
                    entry.key.toLowerCase() == 'x-source' &&
                    entry.value == 'keep',
              ),
              isTrue,
              reason: 'control: next request retains source header',
            );
            expect(
              pages.requests.last.url.path,
              tail ? '/catalog/leaf' : '/catalog/book/leaf',
              reason:
                  'target: next page uses native complete getAbsoluteURL base',
            );
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }

    for (final fresh in [false, true]) {
      test('next-header-order fresh=$fresh', () async {
        final tail =
            ',${jsonEncode({'js': "source.put('order',source.get('order')+'J');result"})}';
        final page = _repair06Page(true, chapter: '');
        final pages = _RetainedPagingPages(
          jsonEncode({
            ...jsonDecode(page) as Map<String, dynamic>,
            'text': 'First',
            'next': 'leaf$tail',
          }),
        );
        final state = SourceHostState();
        final source = _jsonSource(origin)
          ..['header'] =
              '@js:source.put("order",(source.get("order")||"")+"H");JSON.stringify({"X-Source":"keep"})'
          ..['ruleContent'] = {
            'content': r'$.text',
            'nextContentUrl': r'$.next',
          };
        final producer = _openContinuation(true, source, pages, state: state);
        BookSourcePipeline? receiver;
        try {
          final info = await producer.bookInfo(
            HtmlBook(
              url: Uri.parse(bookAddress),
              rawAddress: bookAddress,
              title: 'Book',
            ),
          );
          expect(info.tocHtml, isNotEmpty);
          final (book, chapters) = await producer.tableOfContents(info);
          final key = sourceRuleVariableKey(origin, 'order');
          expect(pages.requests.length, 1);
          expect(await state.entry(origin, key), 'H');
          final reader = fresh
              ? (receiver = _openContinuation(
                  true,
                  source,
                  pages,
                  state: state,
                ))
              : producer;
          final body = await reader.chapter(chapters.single, book: book);
          expect(body.text, 'First\nSecond');
          expect(pages.requests.length, 2);
          expect(pages.requests.last.url.path, '/catalog/book/leaf');
          expect(
            await state.entry(origin, key),
            'HHJ',
            reason:
                'target: real next-page request reads header before option script',
          );
        } finally {
          producer.cancel();
          receiver?.cancel();
        }
      });
    }
  });

  // Reuse reads the page the chapter was actually read from: a fetched later TOC
  // page's ordinary empty chapter fetches its own address instead of the first
  // retained body, and a retained first page hands a later-page rule its complete
  // native base, whose raw text survives until that request splits its own
  // options.
  group('chapterRetainedBoundaries', () {
    const origin = 'http://source.test';
    const bookAddress = '$origin/catalog/book/1';

    for (final fresh in [false, true]) {
      for (final empty in [false, true]) {
        test('later TOC fresh=$fresh empty=$empty', () async {
          final first = jsonEncode({
            ...jsonDecode(_repair06Page(true, chapter: '/catalog/first'))
                as Map<String, dynamic>,
            'text': 'First',
            'tocNext': '/catalog/dir/toc2',
          });
          final second = jsonEncode({
            ...jsonDecode(
                  _repair06Page(
                    true,
                    chapter: empty ? '' : '/catalog/nextcontent',
                  ),
                )
                as Map<String, dynamic>,
            'text': 'Second',
            'tocNext': '',
          });
          final pages = _RetainedSequencePages([first, second, second]);
          final source = _jsonSource(origin);
          (source['ruleToc'] as Map<String, dynamic>)['nextTocUrl'] =
              r'$.tocNext';
          final producer = _openContinuation(true, source, pages);
          BookSourcePipeline? receiver;
          try {
            final info = await producer.bookInfo(
              HtmlBook(
                url: Uri.parse(bookAddress),
                rawAddress: bookAddress,
                title: 'Book',
              ),
            );
            expect(info.tocHtml, isNotEmpty);
            final (book, chapters) = await producer.tableOfContents(info);
            expect(chapters.length, 2);
            expect(pages.requests.map((request) => request.url.path).toList(), [
              '/catalog/book/1',
              '/catalog/dir/toc2',
            ]);
            final selected = chapters.last;
            expect(
              selected.address,
              empty ? '$origin/catalog/dir/toc2' : '/catalog/nextcontent',
            );
            final reader = fresh
                ? (receiver = _openContinuation(true, source, pages))
                : producer;
            final body = await reader.chapter(selected, book: book);
            expect(
              body.text,
              'Second',
              reason:
                  'target: fetched TOC fallback must not reuse the first retained body',
            );
            expect(pages.requests.length, 3);
            expect(
              pages.requests.last.url.path,
              empty ? '/catalog/dir/toc2' : '/catalog/nextcontent',
            );
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }

    for (final fresh in [false, true]) {
      for (final tail in [false, true]) {
        test('fragment next fresh=$fresh tail=$tail', () async {
          final suffix = tail
              ? ',${jsonEncode({
                  'headers': {'X-Route': 'part/../../end'},
                })}'
              : '';
          final raw = '$bookAddress$suffix';
          final first = jsonEncode({
            ...jsonDecode(_repair06Page(true, chapter: ''))
                as Map<String, dynamic>,
            'text': 'First',
            'next': '#next',
          });
          final pages = _RetainedSequencePages([
            first,
            jsonEncode({'text': 'Second', 'next': ''}),
          ]);
          final source = _jsonSource(origin)
            ..['ruleContent'] = {
              'content': r'$.text',
              'nextContentUrl': r'$.next',
            };
          final producer = _openContinuation(true, source, pages);
          BookSourcePipeline? receiver;
          try {
            final info = await producer.bookInfo(
              HtmlBook(
                url: Uri.parse(bookAddress),
                rawAddress: raw,
                title: 'Book',
              ),
            );
            expect(info.tocHtml, isNotEmpty);
            expect(info.tocUrl, raw);
            final (book, chapters) = await producer.tableOfContents(info);
            expect(pages.requests.length, 1);
            final reader = fresh
                ? (receiver = _openContinuation(true, source, pages))
                : producer;
            final body = await reader.chapter(chapters.single, book: book);
            expect(body.text, 'First\nSecond');
            expect(pages.requests.length, 2);
            expect(
              pages.requests.last.url.path,
              '/catalog/book/1',
              reason:
                  'target: fragment next preserves complete raw base until request option splitting',
            );
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }
  });

  // Reuse hands the content stage the chapter's complete native request input:
  // the retained page's next address resolves against the finished native text,
  // while the published address and the stable identity keep their own facts.
  group('chapterRetainedNativeInput', () {
    const origin = 'http://source.test';

    for (final mode in ['same', 'fresh-book', 'fresh-carrier']) {
      final fresh = mode != 'same';
      for (final deep in [false, true]) {
        test('mode=$mode deep=$deep', () async {
          final header = deep ? 'a/../../b' : 'ab';
          final tail =
              ',${jsonEncode({
                'headers': {'X-Text': header},
              })}';
          final publication = '$origin/catalog/book/book/1$tail';
          final comparison = deep ? '$origin/catalog/book/b"}}' : publication;
          final first = jsonEncode({
            ...jsonDecode(_repair06Page(true, chapter: ''))
                as Map<String, dynamic>,
            'text': 'First',
            'next': '#next',
          });
          final pages = _RetainedSequencePages([
            first,
            jsonEncode({'text': 'Second', 'next': ''}),
          ]);
          final source = _jsonSource(origin)
            ..['bookSourceUrl'] = '$origin/catalog/search'
            ..['searchUrl'] = 'book/1$tail'
            ..['bookUrlPattern'] = '.*'
            ..['ruleContent'] = {
              'content': r'$.text',
              'nextContentUrl': r'$.next',
            };
          final state = SourceHostState();
          final producer = _openContinuation(true, source, pages, state: state);
          BookSourcePipeline? receiver;
          try {
            final hit = (await producer.search('1')).single;
            expect(hit.title, 'Book');
            expect(hit.infoHtml, isNotEmpty);
            expect(
              hit.addressContext?.comparisonAddress,
              comparison,
              reason: 'premise: genuine native logical text',
            );
            expect(
              hit.addressContext?.publicationAddress,
              publication,
              reason: 'premise: publication remains independent',
            );
            expect(pages.requests.single.url.path, '/catalog/book/1');
            final info = await producer.bookInfo(hit);
            expect(info.tocHtml, isNotEmpty);
            expect(info.tocAddress, '');
            expect(info.tocUrl, publication);
            final (book, chapters) = await producer.tableOfContents(info);
            expect(pages.requests.length, 1);
            expect(chapters.single.address, publication);
            final reader = fresh
                ? (receiver = _openContinuation(
                    true,
                    source,
                    pages,
                    state: state,
                  ))
                : producer;
            final body = await reader.chapter(
              chapters.single,
              book: mode == 'fresh-carrier' ? null : book,
            );
            expect(body.text, 'First\nSecond');
            expect(
              pages.requests.length,
              2,
              reason: 'premise: reuse then one actual content-next request',
            );
            expect(
              pages.requests.last.url.path,
              deep ? '/catalog/book/b%22%7D%7D' : '/catalog/book/book/1',
              reason:
                  'target: fragment next uses native logical text, not publication',
            );
            expect(chapters.single.storeKey, '$origin/catalog/book/book/1');
            expect(
              chapters.single.persistedAddress,
              comparison,
              reason: 'target: the saved input is the complete native text',
            );
            final copy = chapters.single.withVariable('{"kept":"yes"}');
            expect(copy.storeKey, chapters.single.storeKey);
            expect(copy.persistedAddress, comparison);
            expect(book.identityAddress, publication);
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }
  });

  test(
    'retained chapter response stays out of shelf rows after reopen',
    () async {
      const origin = 'http://source.test';
      const retainedBody = 'retained-response-body-not-a-row';
      final document = jsonEncode({
        ...jsonDecode(
              _repair06Page(
                true,
                book: '/catalog/book/1',
                toc: '/catalog/book/1',
                chapter: '',
              ),
            )
            as Map<String, dynamic>,
        'text': retainedBody,
      });
      final pages = _ContinuationPages(
        document,
        allowedPaths: const ['/catalog/search', '/catalog/book/1'],
      );
      final source = _jsonSource(
        origin,
        searchUrl: '/catalog/search',
        bookUrlPattern: r'$^',
      );
      final root = await Directory.systemTemp.createTemp('liber-retained-row-');
      var workspace = await Workspace.open(root: root);
      var shelf = ShelfService(await workspace.openSpace());
      final pipeline = _openContinuation(
        true,
        source,
        pages,
        state: shelf.hostState,
      );
      try {
        final hit = (await pipeline.search('Book')).single;
        final info = await pipeline.bookInfo(hit);
        final (book, chapters) = await pipeline.tableOfContents(info);
        expect(chapters.single.fetchContext?.retainedPage?.body, document);
        expect(jsonEncode(book.toJson()), isNot(contains(retainedBody)));
        await shelf.add(source, book, chapters);
        final identity = book.identityAddress;
        await workspace.close();
        workspace = await Workspace.open(root: root);
        shelf = ShelfService(await workspace.openSpace());
        final row = (await shelf.find(origin, identity))!.chapters.single;
        final serialized = jsonEncode(row.toJson());
        expect(serialized, isNot(contains(retainedBody)));
        expect(serialized, isNot(contains('fetchContext')));
        expect(serialized, isNot(contains('retainedPage')));
        expect(row.url, chapters.single.persistedAddress);
      } finally {
        pipeline.cancel();
        await workspace.close();
        await root.delete(recursive: true);
      }
    },
  );

  for (final (json, scriptResult) in [
    for (final json in [false, true])
      for (final scriptResult in ['no script', 'relative', 'absolute'])
        (json, scriptResult),
  ]) {
    test(
      '${json ? 'JSON' : 'HTML'} redirected empty TOC chapter before and after shelf reopen ($scriptResult)',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final origin = 'http://127.0.0.1:${server.port}';
        const toc = '/catalog/toc?key=one';
        const landed = '/redirect/landed?key=two';
        const bodyPath = '/body/child';
        final script = switch (scriptResult) {
          'relative' => "chapter == null ? result : 'child'",
          'absolute' => "chapter == null ? result : '$origin$bodyPath'",
          _ => null,
        };
        final tail =
            ',${jsonEncode({
              'method': 'POST',
              'body': 'q=chapter',
              'headers': {'X-Chapter': 'toc'},
              'js': ?script,
            })}';
        final requests = <(String, String, String, String?)>[];
        server.listen((request) async {
          final input = await utf8.decoder.bind(request).join();
          requests.add((
            request.method,
            '${request.uri}',
            input,
            request.headers.value('X-Chapter'),
          ));
          switch (request.uri.path) {
            case '/book':
              request.response.write(
                json
                    ? jsonEncode({'title': 'Book', 'toc': '$toc$tail'})
                    : '<h1>Book</h1><a class="toc" href="${const HtmlEscape().convert('$toc$tail')}">TOC</a>',
              );
            case '/catalog/toc':
              request.response.statusCode = HttpStatus.temporaryRedirect;
              request.response.headers.set(
                HttpHeaders.locationHeader,
                landed,
              );
            case '/redirect/landed':
            case bodyPath:
              request.response.write(
                json
                    ? '{"list":[{"label":"One","href":""}],"text":"Body"}'
                    : '<ul><li><a>One</a></li></ul><p id="content">Body</p>',
              );
            default:
              request.response.statusCode = HttpStatus.notFound;
          }
          await request.response.close();
        });
        final source = (json ? _jsonSource(origin) : _htmlSource(origin))
          ..['bookSourceName'] = 'Redirecting TOC';
        final root = await Directory.systemTemp.createTemp(
          'liber-empty-toc-',
        );
        var workspace = await Workspace.open(root: root);
        addTearDown(() async {
          await workspace.close();
          await root.delete(recursive: true);
        });
        var shelf = ShelfService(await workspace.openSpace());
        BookSourcePipeline open() => json
            ? JsonSourcePipeline(
                source,
                HttpSourceTransport(),
                hostState: shelf.hostState,
              )
            : HtmlSourcePipeline(
                source,
                HttpSourceTransport(),
                hostState: shelf.hostState,
              );
        final producer = open();
        final (book, chapters) = await producer.details(
          HtmlBook(url: Uri.parse('$origin/book'), title: 'Book'),
        );
        final chapter = chapters.single;
        expect(chapter.address, '$origin$toc$tail');
        expect(chapter.fetchContext?.retainedPage, isNull);
        const redirectTrace = [
          ('POST', toc, 'q=chapter', 'toc'),
          ('POST', landed, 'q=chapter', 'toc'),
        ];
        final contentTrace = switch (scriptResult) {
          'relative' => <(String, String, String, String?)>[],
          'absolute' => [('POST', bodyPath, 'q=chapter', 'toc')],
          _ => redirectTrace,
        };
        final invalidResult = isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('正文 URL 选项 js'),
        );
        Future<void> readBody(
          BookSourcePipeline pipeline,
          SourceChapter chapter,
          HtmlBook book,
        ) async {
          try {
            final body = pipeline.chapter(chapter, book: book);
            if (scriptResult == 'relative') {
              await expectLater(body, throwsA(invalidResult));
            } else {
              expect((await body).text, 'Body');
            }
          } finally {
            pipeline.cancel();
          }
        }

        await readBody(producer, chapter, book);
        expect(requests, [
          ('GET', '/book', '', null),
          ...redirectTrace,
          ...contentTrace,
        ]);
        requests.clear();
        await shelf.add(source, book, chapters);
        await workspace.close();
        workspace = await Workspace.open(root: root);
        shelf = ShelfService(await workspace.openSpace());
        final reopened = (await shelf.find(origin, book.identityAddress))!;
        final row = reopened.chapters.single;
        final restored = SourceChapter.fromAddress(
          row.name,
          row.url!,
          bookUrl: reopened.htmlBook.url,
          chapterKey: row.chapterKey,
        );
        await readBody(open(), restored, reopened.htmlBook);
        expect(
          [
            chapter.progressKey,
            row.chapterKey,
            row.url,
            restored.progressKey,
            restored.address,
            requests,
          ],
          [
            '$origin$toc',
            '$origin$toc',
            '$origin$toc$tail',
            '$origin$toc',
            '$origin$toc$tail',
            contentTrace,
          ],
          reason:
              'the saved key and full input preserve the request behavior',
        );
      },
    );
  }

  // A chapter this shelf saved and a fresh analysis rebuilt from the stored row
  // carries no in-memory request context: its real content request analyses the
  // complete saved text, so the request's own option script runs once at that
  // request while the stored key and saved text keep what was written.
  group('chapterStoredRequest', () {
    for (final scripted in [false, true]) {
      test('new record reopen scripted=$scripted', () async {
        const origin = 'http://source.test';
        const original = '$origin/catalog/content?q=ascii';
        const selected = '$origin/catalog/content-selected?q=ascii';
        final script =
            "source.put('storedRuns',String(Number(source.get('storedRuns')||'0')+1)); '$selected'";
        final tail =
            ',${jsonEncode({
              'headers': {'X-Chapter': 'stored'},
              if (scripted) 'js': script,
            })}';
        final source = _jsonSource(
          origin,
          searchUrl: '/catalog/search',
          bookUrlPattern: r'$^',
        )..['bookSourceName'] = 'Stored request test';
        final pages = _ContinuationPages(
          jsonEncode({
            ...jsonDecode(
                  _repair06Page(
                    true,
                    book: '/catalog/book/1',
                    toc: '/catalog/book/1',
                    chapter: '../content?q=ascii$tail',
                  ),
                )
                as Map<String, dynamic>,
            'text': 'Body',
          }),
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
            '/catalog/content-selected',
          ],
        );
        final root = await Directory.systemTemp.createTemp(
          'liber-chapter-stored-13-',
        );
        var workspace = await Workspace.open(root: root);
        var shelf = ShelfService(await workspace.openSpace());
        var pipeline = _openContinuation(
          true,
          source,
          pages,
          state: shelf.hostState,
        );
        try {
          final hit = (await pipeline.search('Book')).single;
          final info = await pipeline.bookInfo(hit);
          expect(info.book.title, 'Book');
          final (_, chapters) = await pipeline.tableOfContents(info);
          final chapter = chapters.single;
          expect(chapter.storeKey, original);
          expect(chapter.persistedAddress, '$original$tail');
          expect(pages.requests.map((request) => request.url.path), [
            '/catalog/search',
            '/catalog/book/1',
          ]);
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedRuns'),
            ),
            isNull,
            reason: 'premise: no request-option effect before storage',
          );
          await shelf.add(source, info.book, chapters);
          final bookIdentity = info.book.identityAddress;
          final saved = (await shelf.find(origin, bookIdentity))!;
          expect(saved.chapters.single.chapterKey, original);
          expect(saved.chapters.single.url, '$original$tail');
          expect(
            jsonEncode(saved.chapters.single.toJson()),
            isNot(contains('fetchContext')),
          );
          expect(
            jsonEncode(saved.chapters.single.toJson()),
            isNot(contains('retainedPage')),
          );
          expect(jsonEncode(info.book.toJson()), isNot(contains('infoHtml')));
          await shelf.saveProgress(
            saved.id,
            chapterKey: original,
            chapterIndex: 0,
            textOffset: 37,
          );
          await shelf.hostState.putChapterVariable(
            origin,
            bookIdentity,
            original,
            '{"owned":"chapter"}',
          );
          const otherIdentity = '$origin/catalog/other-book';
          await shelf.add(
            source,
            HtmlBook(url: Uri.parse(otherIdentity), title: 'Other'),
            [chapter.withVariable('{"owned":"other"}')],
          );
          expect(
            await shelf.hostState.chapterVariable(
              origin,
              otherIdentity,
              original,
            ),
            '{"owned":"other"}',
          );
          pipeline.cancel();
          await workspace.close();

          workspace = await Workspace.open(root: root);
          shelf = ShelfService(await workspace.openSpace());
          final reopened = (await shelf.find(origin, bookIdentity))!;
          expect(reopened.shelved, isTrue);
          expect(reopened.chapters.single.chapterKey, original);
          expect(reopened.chapters.single.url, '$original$tail');
          expect(reopened.chapterKey, original);
          expect(reopened.chapterIndex, 0);
          expect(reopened.textOffset, 37);
          expect(reopened.chapterName, 'Chapter');
          expect(reopened.chapters.single.variable, '{"owned":"chapter"}');
          expect(
            await shelf.hostState.chapterVariable(
              origin,
              otherIdentity,
              original,
            ),
            '{"owned":"other"}',
          );
          final row = reopened.chapters.single;
          final restored = SourceChapter.fromAddress(
            row.name,
            row.url!,
            bookUrl: reopened.htmlBook.url,
            chapterKey: row.chapterKey,
            tag: row.tag,
            isVolume: row.isVolume,
            isVip: row.isVip,
            isPay: row.isPay,
            variable: row.variable,
          );
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedRuns'),
            ),
            isNull,
            reason: 'premise: rebuilding stored text runs no request program',
          );
          pipeline = _openContinuation(
            true,
            reopened.sourceJson,
            pages,
            state: shelf.hostState,
          );
          final body = await pipeline.chapter(
            restored,
            book: reopened.htmlBook,
          );
          expect(body.text, 'Body');
          expect(pages.requests.length, 3);
          expect(
            pages.requests.last.url.toString(),
            scripted ? selected : original,
            reason: 'target: the reopened record analyzes its own request',
          );
          expect(pages.requests.last.headers['X-Chapter'], 'stored');
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedRuns'),
            ),
            scripted ? '1' : null,
            reason: 'target: one option effect for the real request',
          );
          expect(restored.progressKey, original);
          expect(restored.persistedAddress, '$original$tail');
          final after = (await shelf.find(origin, bookIdentity))!;
          expect(after.chapters.single.chapterKey, original);
          expect(after.chapters.single.url, '$original$tail');
          final refreshedInfo = await pipeline.bookInfo(reopened.htmlBook);
          final (refreshedBook, refreshedChapters) = await pipeline
              .tableOfContents(refreshedInfo);
          expect(refreshedChapters.single.variable, '{"owned":"chapter"}');
          expect(refreshedChapters.single.storeKey, original);
          expect(refreshedChapters.single.persistedAddress, '$original$tail');
          await shelf.updateCatalog(origin, refreshedBook, refreshedChapters);
          final refreshed = (await shelf.find(origin, bookIdentity))!;
          expect(refreshed.id, saved.id);
          expect(refreshed.chapterKey, original);
          expect(refreshed.chapterIndex, 0);
          expect(refreshed.textOffset, 37);
          expect(refreshed.chapterName, 'Chapter');
          expect(refreshed.chapters.single.variable, '{"owned":"chapter"}');
          expect(
            await shelf.hostState.chapterVariable(
              origin,
              bookIdentity,
              original,
            ),
            '{"owned":"chapter"}',
          );
          expect(refreshed.chapters.single.url, '$original$tail');
          expect(
            await shelf.hostState.chapterVariable(
              origin,
              otherIdentity,
              original,
            ),
            '{"owned":"other"}',
          );
          final again = await pipeline.chapter(
            refreshedChapters.single,
            book: refreshedBook,
          );
          expect(again.text, 'Body');
          expect(
            pages.requests.last.url.toString(),
            scripted ? selected : original,
          );
          expect(pages.requests.last.headers['X-Chapter'], 'stored');
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedRuns'),
            ),
            scripted ? '2' : null,
          );
        } finally {
          pipeline.cancel();
          await workspace.close();
          await root.delete(recursive: true);
        }
      });
    }
  });

  // A saved address form — plain, template or a whole request program — is the
  // chapter's pending input: rebuilding it from the stored row keeps that text
  // exactly and runs nothing, while the one real content request afterwards
  // analyses it and leaves the stable key and progress identity alone.
  group('chapterStoredProgram', () {
    for (final mode in ['plain', 'template', 'program']) {
      test('new record reopen mode=$mode', () async {
        const origin = 'http://source.test';
        const original = '$origin/catalog/content?q=ascii';
        const selected = '$origin/catalog/content-selected?q=ascii';
        const effect =
            "source.put('storedAddressRuns',String(Number(source.get('storedAddressRuns')||'0')+1));";
        const template = "{{$effect'ascii'}}";
        const program =
            "@js:$effect'$selected'+','+JSON.stringify({headers:{'X-Chapter':'stored'}})";
        final query = mode == 'template' ? template : 'ascii';
        final address = mode == 'program' ? program : '../content?q=$query';
        final tail =
            ',${jsonEncode({
              'headers': {'X-Chapter': 'stored'},
            })}';
        final savedInput = mode == 'program'
            ? program
            : '$origin/catalog/content?q=$query$tail';
        final source = _jsonSource(
          origin,
          searchUrl: '/catalog/search',
          bookUrlPattern: r'$^',
        )..['bookSourceName'] = 'Stored address program test';
        final pages = _ContinuationPages(
          jsonEncode({
            ...jsonDecode(
                  _repair06Page(
                    true,
                    book: '/catalog/book/1',
                    toc: '/catalog/book/1',
                    chapter: mode == 'program' ? address : '$address$tail',
                  ),
                )
                as Map<String, dynamic>,
            'text': 'Body',
          }),
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
            '/catalog/content-selected',
          ],
        );
        final root = await Directory.systemTemp.createTemp(
          'liber-stored-program-14-',
        );
        var workspace = await Workspace.open(root: root);
        var shelf = ShelfService(await workspace.openSpace());
        var pipeline = _openContinuation(
          true,
          source,
          pages,
          state: shelf.hostState,
        );
        try {
          final hit = (await pipeline.search('Book')).single;
          final info = await pipeline.bookInfo(hit);
          final (_, chapters) = await pipeline.tableOfContents(info);
          final chapter = chapters.single;
          final stableKey = chapter.storeKey;
          expect(info.book.title, 'Book');
          expect(chapter.url.isAbsolute, isTrue);
          expect(stableKey, isNot(selected));
          expect(chapter.persistedAddress, savedInput);
          expect(pages.requests.map((request) => request.url.path), [
            '/catalog/search',
            '/catalog/book/1',
          ]);
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            isNull,
            reason: 'premise: TOC leaves the address program unexecuted',
          );
          await shelf.add(source, info.book, chapters);
          final bookIdentity = info.book.identityAddress;
          final saved = (await shelf.find(origin, bookIdentity))!;
          expect(saved.chapters.single.chapterKey, stableKey);
          expect(saved.chapters.single.url, savedInput);
          pipeline.cancel();
          await workspace.close();

          workspace = await Workspace.open(root: root);
          shelf = ShelfService(await workspace.openSpace());
          final reopened = (await shelf.find(origin, bookIdentity))!;
          final row = reopened.chapters.single;
          expect(reopened.shelved, isTrue);
          expect(row.chapterKey, stableKey);
          expect(row.url, savedInput);
          late SourceChapter restored;
          try {
            restored = SourceChapter.fromAddress(
              row.name,
              row.url!,
              bookUrl: reopened.htmlBook.url,
              chapterKey: row.chapterKey,
              tag: row.tag,
              isVolume: row.isVolume,
              isVip: row.isVip,
              isPay: row.isPay,
              variable: row.variable,
            );
          } on FormatException catch (error, stack) {
            if (mode == 'program' &&
                error.message.contains(
                  'Scheme not starting with alphabetic character',
                )) {
              fail(
                'target: saved request programs rebuild as pending text, not URI schemes: $error',
              );
            }
            Error.throwWithStackTrace(error, stack);
          }
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            isNull,
            reason: 'premise: rebuilding does not execute the address',
          );
          pipeline = _openContinuation(
            true,
            reopened.sourceJson,
            pages,
            state: shelf.hostState,
          );
          final body = await pipeline.chapter(
            restored,
            book: reopened.htmlBook,
          );
          expect(body.text, 'Body');
          expect(pages.requests.length, 3);
          expect(
            pages.requests.last.url.toString(),
            mode == 'program' ? selected : original,
          );
          expect(pages.requests.last.headers['X-Chapter'], 'stored');
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            mode == 'plain' ? null : '1',
            reason: 'target: one address effect for the actual request',
          );
          expect(restored.progressKey, stableKey);
          expect(
            restored.persistedAddress,
            savedInput,
            reason: 'target: rebuilding preserves the complete pending input',
          );
          final copy = restored.withVariable('{"kept":"yes"}');
          expect(copy.progressKey, stableKey);
          expect(copy.persistedAddress, savedInput);
          final after = (await shelf.find(origin, bookIdentity))!;
          expect(after.chapters.single.chapterKey, stableKey);
          expect(after.chapters.single.url, savedInput);
        } finally {
          pipeline.cancel();
          await workspace.close();
          await root.delete(recursive: true);
        }
      });
    }
  });

  // The request-program spellings the frozen grammar already supports all reach
  // the same single real request, and rebuilding from the stored row keeps each
  // one's own produced text — the lower-case whole program, or the native prefix
  // the other spellings resolve to — instead of re-encoding it.
  group('chapterStoredGrammar', () {
    for (final mode in [
      'at-lower',
      'at-upper',
      'tag-lower',
      'tag-upper',
      'tag-literal-lower',
      'tag-literal-upper',
    ]) {
      test('new record reopen mode=$mode', () async {
        const origin = 'http://source.test';
        const selected = '$origin/catalog/content-selected?q=ascii';
        const effect =
            "source.put('storedAddressRuns',String(Number(source.get('storedAddressRuns')||'0')+1));";
        final tagged = mode.startsWith('tag-');
        final upper = mode.endsWith('-upper');
        final open = tagged
            ? (upper ? '<JS>' : '<js>')
            : (upper ? '@JS:' : '@js:');
        final close = tagged ? (upper ? '</JS>' : '</js>') : '';
        // The literal spellings return the complete request text as one string,
        // so the option delimiter sits inside the program's own JS string; the
        // other spellings build it by concatenation as they always have.
        final options = jsonEncode({
          'headers': {'X-Chapter': 'stored'},
        });
        final program = mode.contains('-literal-')
            ? "$open$effect'$selected,$options'$close"
            : "$open$effect'$selected'+','+JSON.stringify({headers:{'X-Chapter':'stored'}})$close";
        final address = program;
        final savedInput = mode == 'at-lower'
            ? program
            : '$origin/catalog/book/$program';
        final source = _jsonSource(
          origin,
          searchUrl: '/catalog/search',
          bookUrlPattern: r'$^',
        )..['bookSourceName'] = 'Stored address program test';
        final pages = _ContinuationPages(
          jsonEncode({
            ...jsonDecode(
                  _repair06Page(
                    true,
                    book: '/catalog/book/1',
                    toc: '/catalog/book/1',
                    chapter: address,
                  ),
                )
                as Map<String, dynamic>,
            'text': 'Body',
          }),
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
            '/catalog/content-selected',
          ],
        );
        final root = await Directory.systemTemp.createTemp(
          'liber-stored-grammar-15-',
        );
        var workspace = await Workspace.open(root: root);
        var shelf = ShelfService(await workspace.openSpace());
        var pipeline = _openContinuation(
          true,
          source,
          pages,
          state: shelf.hostState,
        );
        try {
          final hit = (await pipeline.search('Book')).single;
          final info = await pipeline.bookInfo(hit);
          final (_, chapters) = await pipeline.tableOfContents(info);
          final chapter = chapters.single;
          final stableKey = chapter.storeKey;
          expect(info.book.title, 'Book');
          expect(chapter.url.isAbsolute, isTrue);
          expect(stableKey, isNot(selected));
          expect(chapter.persistedAddress, savedInput);
          expect(pages.requests.map((request) => request.url.path), [
            '/catalog/search',
            '/catalog/book/1',
          ]);
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            isNull,
            reason: 'premise: TOC leaves the address program unexecuted',
          );
          await shelf.add(source, info.book, chapters);
          final bookIdentity = info.book.identityAddress;
          final saved = (await shelf.find(origin, bookIdentity))!;
          expect(saved.chapters.single.chapterKey, stableKey);
          expect(saved.chapters.single.url, savedInput);
          pipeline.cancel();
          await workspace.close();

          workspace = await Workspace.open(root: root);
          shelf = ShelfService(await workspace.openSpace());
          final reopened = (await shelf.find(origin, bookIdentity))!;
          final row = reopened.chapters.single;
          expect(reopened.shelved, isTrue);
          expect(row.chapterKey, stableKey);
          expect(row.url, savedInput);
          late SourceChapter restored;
          try {
            restored = SourceChapter.fromAddress(
              row.name,
              row.url!,
              bookUrl: reopened.htmlBook.url,
              chapterKey: row.chapterKey,
              tag: row.tag,
              isVolume: row.isVolume,
              isVip: row.isVip,
              isPay: row.isPay,
              variable: row.variable,
            );
          } on FormatException catch (error, stack) {
            if (error.message.contains(
              'Scheme not starting with alphabetic character',
            )) {
              fail(
                'target: saved request programs rebuild as pending text, not URI schemes: $error',
              );
            }
            Error.throwWithStackTrace(error, stack);
          }
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            isNull,
            reason: 'premise: rebuilding does not execute the address',
          );
          pipeline = _openContinuation(
            true,
            reopened.sourceJson,
            pages,
            state: shelf.hostState,
          );
          final body = await pipeline.chapter(
            restored,
            book: reopened.htmlBook,
          );
          expect(body.text, 'Body');
          expect(pages.requests.length, 3);
          expect(pages.requests.last.url.toString(), selected);
          expect(pages.requests.last.headers['X-Chapter'], 'stored');
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'storedAddressRuns'),
            ),
            '1',
            reason: 'target: one address effect for the actual request',
          );
          expect(restored.progressKey, stableKey);
          expect(
            restored.persistedAddress,
            savedInput,
            reason: 'target: rebuilding preserves the complete pending input',
          );
          final copy = restored.withVariable('{"kept":"yes"}');
          expect(copy.progressKey, stableKey);
          expect(copy.persistedAddress, savedInput);
          final after = (await shelf.find(origin, bookIdentity))!;
          expect(after.chapters.single.chapterKey, stableKey);
          expect(after.chapters.single.url, savedInput);
        } finally {
          pipeline.cancel();
          await workspace.close();
          await root.delete(recursive: true);
        }
      });
    }
  });

  // The HTML adapter's content stage: a chapter whose completed native text is
  // the book's own reuses the retained body without a request, header read or
  // login check, while a text that merely resolves to the same address is a real
  // request of its own.
  group('chapterHtmlRetainedBody', () {
    const origin = 'http://source.test';
    const bookAddress = '$origin/catalog/book/1';
    for (final fresh in [false, true]) {
      for (final kind in ['empty', 'exact', 'relative']) {
        test('fresh=$fresh kind=$kind', () async {
          final address = switch (kind) {
            'empty' => '',
            'exact' => bookAddress,
            _ => '../book/1',
          };
          final page =
              '${_repair06Page(false, book: '/catalog/book/1', chapter: address)}'
              '<div id="content">Body</div>';
          final pages = _ContinuationPages(
            page,
            allowedPaths: const ['/catalog/search', '/catalog/book/1'],
          );
          final source = _htmlSource(
            origin,
            searchUrl: '/catalog/search',
            bookUrlPattern: r'$^',
          );
          source['header'] =
              "@js:java.put('htmlHeaders', "
              "String(Number(java.get('htmlHeaders') || '0') + 1)); "
              "JSON.stringify({'X-Source':'html'})";
          source['loginCheckJs'] =
              "java.put('htmlLogins', "
              "String(Number(java.get('htmlLogins') || '0') + 1)); result";
          final state = SourceHostState();
          final pipeline = _openContinuation(
            false,
            source,
            pages,
            state: state,
          );
          final hits = await pipeline.search('book');
          final (book, chapters) = await pipeline.details(hits.single);
          expect(chapters, hasLength(1));
          expect(book.identityAddress, bookAddress);
          expect(chapters.single.storeKey, bookAddress);
          expect(
            chapters.single.address,
            kind == 'empty' ? bookAddress : address,
          );
          expect(pages.requests.map((r) => r.url.path), [
            '/catalog/search',
            '/catalog/book/1',
          ]);
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlHeaders'),
            ),
            '2',
          );
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlLogins'),
            ),
            '2',
          );
          final receiver = fresh
              ? _openContinuation(false, source, pages, state: state)
              : pipeline;
          final body = await receiver.chapter(chapters.single, book: book);
          expect(body.text, 'Body');
          final reuse = kind != 'relative';
          expect(
            pages.requests,
            hasLength(reuse ? 2 : 3),
            reason:
                'target: native-equal completed chapter text reuses the retained body',
          );
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlHeaders'),
            ),
            reuse ? '2' : '3',
            reason: 'target: reuse does not initialize or reevaluate headers',
          );
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlLogins'),
            ),
            reuse ? '2' : '3',
            reason: 'target: reuse never repeats login checking',
          );
          if (!reuse) {
            expect(pages.requests.last.url.toString(), bookAddress);
            expect(pages.requests.last.headers['X-Source'], 'html');
          }
          expect(chapters.single.storeKey, bookAddress);
          expect(chapters.single.progressKey, bookAddress);
          expect(book.identityAddress, bookAddress);
        });
      }
    }
  });

  // The HTML chapter identity is fixed before any request charset processing:
  // the declared raw text names the row while the actual request applies the
  // charset its own tail declares.
  group('chapterHtmlRequestCharset', () {
    const origin = 'http://source.test';
    const rawTarget = '$origin/catalog/content?q=中';
    const stableKey = '$origin/catalog/content?q=%E4%B8%AD';
    for (final charset in ['UTF-8', 'GBK']) {
      test('charset=$charset', () async {
        final address =
            '$rawTarget,${jsonEncode({
              'charset': charset,
              'headers': {'X-Chapter': 'keep'},
            })}';
        final page =
            '${_repair06Page(false, book: '/catalog/book/1', chapter: address)}'
            '<div id="content">Body</div>';
        final pages = _ContinuationPages(
          page,
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
          ],
        );
        final source = _htmlSource(
          origin,
          searchUrl: '/catalog/search',
          bookUrlPattern: r'$^',
        );
        final pipeline = _openContinuation(false, source, pages);
        final hits = await pipeline.search('book');
        final (book, chapters) = await pipeline.details(hits.single);
        expect(chapters, hasLength(1));
        expect(chapters.single.address, address);
        expect(pages.requests.map((r) => r.url.path), [
          '/catalog/search',
          '/catalog/book/1',
        ]);
        expect(
          chapters.single.storeKey,
          stableKey,
          reason: 'target: identity precedes request charset processing',
        );
        final body = await _openContinuation(
          false,
          source,
          pages,
        ).chapter(chapters.single, book: book);
        expect(body.text, 'Body');
        expect(pages.requests, hasLength(3));
        expect(
          pages.requests.last.url.toString(),
          charset == 'GBK' ? '$origin/catalog/content?q=%D6%D0' : stableKey,
          reason: 'target: this content request applies its own charset',
        );
        expect(pages.requests.last.headers['X-Chapter'], 'keep');
        expect(chapters.single.storeKey, stableKey);
        expect(chapters.single.progressKey, stableKey);
      });
    }
  });

  // An HTML chapter address that carries a request template expands it for the
  // real content request alone, once.
  group('chapterHtmlRequestTemplate', () {
    const origin = 'http://source.test';
    const target = '$origin/catalog/content?q=ascii';
    const template =
        "$origin/catalog/content?q={{java.put('htmlTemplateRuns', "
        "String(Number(java.get('htmlTemplateRuns') || '0') + 1)); 'ascii'}}";
    for (final scripted in [false, true]) {
      test('scripted=$scripted', () async {
        final address = scripted ? template : target;
        final page =
            '${_repair06Page(false, book: '/catalog/book/1', chapter: address)}'
            '<div id="content">Body</div>';
        final pages = _ContinuationPages(
          page,
          allowedPaths: const [
            '/catalog/search',
            '/catalog/book/1',
            '/catalog/content',
          ],
        );
        final source = _htmlSource(
          origin,
          searchUrl: '/catalog/search',
          bookUrlPattern: r'$^',
        );
        final state = SourceHostState();
        final pipeline = _openContinuation(false, source, pages, state: state);
        final hits = await pipeline.search('book');
        final (book, chapters) = await pipeline.details(hits.single);
        expect(chapters, hasLength(1));
        expect(chapters.single.address, address);
        expect(pages.requests.map((r) => r.url.path), [
          '/catalog/search',
          '/catalog/book/1',
        ]);
        expect(
          await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'htmlTemplateRuns'),
          ),
          isNull,
          reason: 'premise: a TOC never executes the request template',
        );
        final stableKey = chapters.single.storeKey;
        final body = await _openContinuation(
          false,
          source,
          pages,
          state: state,
        ).chapter(chapters.single, book: book);
        expect(body.text, 'Body');
        expect(pages.requests, hasLength(3));
        expect(
          pages.requests.last.url.toString(),
          target,
          reason:
              'target: the actual request expands its own original template',
        );
        expect(
          await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'htmlTemplateRuns'),
          ),
          scripted ? '1' : isNull,
          reason: 'target: the template runs only once, for that request',
        );
        expect(chapters.single.storeKey, stableKey);
        expect(chapters.single.progressKey, stableKey);
      });
    }
  });

  // The HTML content request evaluates its source header before its own template.
  group('chapterHtmlHeaderOrder', () {
    const origin = 'http://source.test';
    const target = '$origin/catalog/content?q=ascii';
    const template =
        "$origin/catalog/content?q={{java.put('htmlObservedHeader', "
        "java.get('htmlRealHeaders') || 'missing'); 'ascii'}}";
    for (final scripted in [false, true]) {
      test('scripted=$scripted', () async {
        final source = _htmlSource(origin);
        source['header'] =
            "@js:var n=String(Number(java.get('htmlRealHeaders') || '0') + 1); "
            "java.put('htmlRealHeaders', n); JSON.stringify({'X-Sequence':n})";
        final pages = _ContinuationPages(
          '<div id="content">Body</div>',
          allowedPaths: const ['/catalog/content'],
        );
        final state = SourceHostState();
        final book = HtmlBook(
          url: Uri.parse('$origin/catalog/book/1'),
          title: 'Book',
        );
        final chapter = SourceChapter(
          'Chapter',
          Uri.parse(target),
          rawAddress: scripted ? template : target,
          addressBase: book.url,
        );
        final body = await _openContinuation(
          false,
          source,
          pages,
          state: state,
        ).chapter(chapter, book: book);
        expect(body.text, 'Body');
        expect(pages.requests, hasLength(1));
        expect(pages.requests.single.url.toString(), target);
        expect(pages.requests.single.headers['X-Sequence'], '1');
        expect(
          await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'htmlRealHeaders'),
          ),
          '1',
        );
        expect(
          await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'htmlObservedHeader'),
          ),
          scripted ? '1' : isNull,
          reason:
              'target: a real HTML request reads headers before its template',
        );
        expect(chapter.storeKey, target);
        expect(chapter.progressKey, target);
      });
    }
  });

  // A retained first page belongs to the TOC page it was read from, and the
  // pages it declares resolve against that page's complete native raw text: a
  // later fetched TOC page keeps its own body, and a fragment next address is a
  // different logical page rather than a repeat of the first one.
  group('chapterHtmlRetainedPaging', () {
    const origin = 'http://source.test';
    const bookAddress = '$origin/catalog/book/1';
    for (final fresh in [false, true]) {
      for (final empty in [false, true]) {
        test('later TOC fresh=$fresh empty=$empty', () async {
          final first =
              '${_repair06Page(false, chapter: '/catalog/first')}'
              '<div id="content">First</div><a class="next-toc" href="/catalog/dir/toc2">next</a>';
          final second =
              '${_repair06Page(false, chapter: empty ? '' : '/catalog/nextcontent')}'
              '<div id="content">Second</div><a class="next-toc" href="">end</a>';
          final pages = _RetainedSequencePages([first, second, second]);
          final source = _htmlSource(origin);
          (source['ruleToc'] as Map<String, dynamic>)['nextTocUrl'] =
              'a.next-toc@href';
          final producer = _openContinuation(false, source, pages);
          BookSourcePipeline? receiver;
          try {
            final info = await producer.bookInfo(
              HtmlBook(
                url: Uri.parse(bookAddress),
                rawAddress: bookAddress,
                title: 'Book',
              ),
            );
            expect(info.tocHtml, isNotEmpty);
            final (book, chapters) = await producer.tableOfContents(info);
            expect(chapters, hasLength(2));
            expect(pages.requests.map((r) => r.url.path), [
              '/catalog/book/1',
              '/catalog/dir/toc2',
            ]);
            final selected = chapters.last;
            expect(
              selected.address,
              empty ? '$origin/catalog/dir/toc2' : '/catalog/nextcontent',
            );
            final reader = fresh
                ? (receiver = _openContinuation(false, source, pages))
                : producer;
            final body = await reader.chapter(selected, book: book);
            expect(
              body.text,
              'Second',
              reason:
                  'target: fetched TOC page does not reuse the initial book body',
            );
            expect(pages.requests, hasLength(3));
            expect(
              pages.requests.last.url.path,
              empty ? '/catalog/dir/toc2' : '/catalog/nextcontent',
            );
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }
    for (final fresh in [false, true]) {
      for (final tail in [false, true]) {
        for (final fragment in [false, true]) {
          test('fragment next fresh=$fresh tail=$tail fragment=$fragment', () async {
            final suffix = tail
                ? ',${jsonEncode({
                    'headers': {'X-Route': 'part/../../end'},
                  })}'
                : '';
            final raw = '$bookAddress$suffix';
            final first =
                '${_repair06Page(false, chapter: '')}'
                '<div id="content">First</div><a class="next-content" href="${fragment ? '#next' : '$origin/catalog/next-content'}">next</a>';
            const second =
                '<div id="content">Second</div><a class="next-content" href="">end</a>';
            final pages = _RetainedSequencePages([first, second]);
            final source = _htmlSource(origin);
            source['ruleContent'] = {
              'content': '#content@text',
              'nextContentUrl': 'a.next-content@href',
            };
            final producer = _openContinuation(false, source, pages);
            BookSourcePipeline? receiver;
            try {
              final info = await producer.bookInfo(
                HtmlBook(
                  url: Uri.parse(bookAddress),
                  rawAddress: raw,
                  title: 'Book',
                ),
              );
              expect(info.tocHtml, isNotEmpty);
              expect(info.tocUrl, raw);
              final (book, chapters) = await producer.tableOfContents(info);
              expect(pages.requests, hasLength(1));
              final reader = fresh
                  ? (receiver = _openContinuation(false, source, pages))
                  : producer;
              final HtmlChapterBody body;
              try {
                body = await reader.chapter(chapters.single, book: book);
              } on StateError catch (error) {
                if (error.message != '正文分页循环或超出 20 页') rethrow;
                fail(
                  'target: native-valid retained pagination must not be refused as a cycle',
                );
              }
              expect(body.text, 'First\nSecond');
              expect(pages.requests, hasLength(2));
              expect(
                pages.requests.last.url.path,
                fragment ? '/catalog/book/1' : '/catalog/next-content',
                reason:
                    'target: HTML fragment next keeps full native raw base before option splitting',
              );
            } finally {
              producer.cancel();
              receiver?.cancel();
            }
          });
        }
      }
    }
  });

  // A real HTML next-page request is its own analysis: it reads the source
  // header first, then expands its own pending text.
  group('chapterHtmlNextRequest', () {
    const origin = 'http://source.test';
    const firstTarget = '$origin/catalog/content/1';
    const nextTarget = '$origin/catalog/page-two?q=ascii';
    const template =
        "$origin/catalog/page-two?q={{java.put('htmlNextObserved', "
        "java.get('htmlNextHeaders') || 'missing'); 'ascii'}}";
    for (final scripted in [false, true]) {
      test('header then template scripted=$scripted', () async {
        final nextText = scripted ? template : nextTarget;
        final first =
            '<div id="content">First</div><a class="next-content" href="${HtmlEscape().convert(nextText)}">next</a>';
        const second =
            '<div id="content">Second</div><a class="next-content" href="">end</a>';
        final pages = _RetainedSequencePages([first, second]);
        final source = _htmlSource(origin);
        source['header'] =
            "@js:var n=String(Number(java.get('htmlNextHeaders') || '0')+1); "
            "java.put('htmlNextHeaders',n); JSON.stringify({'X-Sequence':n})";
        source['ruleContent'] = {
          'content': '#content@text',
          'nextContentUrl': 'a.next-content@href',
        };
        final state = SourceHostState();
        final receiver = _openContinuation(false, source, pages, state: state);
        final chapter = SourceChapter(
          'Chapter',
          Uri.parse(firstTarget),
          rawAddress: firstTarget,
        );
        final book = HtmlBook(
          url: Uri.parse('$origin/catalog/book/1'),
          title: 'Book',
        );
        try {
          final body = await receiver.chapter(chapter, book: book);
          expect(body.text, 'First\nSecond');
          expect(pages.requests, hasLength(2));
          expect(pages.requests.first.url.toString(), firstTarget);
          expect(pages.requests.map((r) => r.headers['X-Sequence']), [
            '1',
            '2',
          ]);
          expect(
            pages.requests.last.url.toString(),
            nextTarget,
            reason:
                'target: each real HTML next request expands its own pending text',
          );
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlNextObserved'),
            ),
            scripted ? '2' : isNull,
            reason:
                'target: next request reads its own header before request template',
          );
          expect(chapter.storeKey, firstTarget);
          expect(chapter.progressKey, firstTarget);
        } finally {
          receiver.cancel();
        }
      });
    }
  });

  group('chapterHtmlDefaultFragment', () {
    const origin = 'http://source.test';
    for (final stage in ['search', 'information', 'toc']) {
      for (final fragment in [false, true]) {
        test('stage=$stage fragment=$fragment', () async {
          final target =
              '$origin/catalog/${stage == 'search'
                  ? 'search'
                  : stage == 'information'
                  ? 'book/1'
                  : 'toc'}';
          final address = '$target${fragment ? '#declared' : ''}';
          final page = _repair06Page(false, toc: stage == 'toc' ? address : '');
          final pages = _ContinuationPages(
            page,
            allowedPaths: const [
              '/catalog/search',
              '/catalog/book/1',
              '/catalog/toc',
            ],
          );
          final source = _htmlSource(origin)..['bookUrlPattern'] = r'$^';
          if (stage == 'search') source['searchUrl'] = address;
          final pipeline = _openContinuation(false, source, pages);
          try {
            if (stage == 'search') {
              expect((await pipeline.search('1')).single.title, 'Book');
            } else {
              final bookAddress = stage == 'information'
                  ? address
                  : '$origin/catalog/book/1';
              final info = await pipeline.bookInfo(
                HtmlBook(
                  url: Uri.parse(bookAddress),
                  rawAddress: bookAddress,
                  title: 'Book',
                ),
              );
              expect(info.book.title, 'Book');
              if (stage == 'toc') {
                expect(
                  info.tocAddress,
                  address,
                  reason: 'premise: declared TOC text retains its own fragment',
                );
                final (_, chapters) = await pipeline.tableOfContents(info);
                expect(chapters, isNotEmpty);
              }
            }
            expect(
              pages.requests.last.url.toString(),
              target,
              reason:
                  'target: the granted content repair leaves default non-content request semantics unchanged',
            );
          } finally {
            pipeline.cancel();
          }
        });
      }
    }
  });

  group('chapterHtmlFullRawBase', () {
    const origin = 'http://source.test';
    const bookAddress = '$origin/catalog/book/1';
    for (final fresh in [false, true]) {
      for (final tail in [false, true]) {
        test('relative next fresh=$fresh tail=$tail', () async {
          final suffix = tail
              ? ',${jsonEncode({
                  'headers': {'X-Route': 'part/../../end'},
                })}'
              : '';
          final raw = '$bookAddress$suffix';
          final first =
              '${_repair06Page(false, chapter: '')}'
              '<div id="content">First</div><a class="next-content" href="next-part">next</a>';
          const second =
              '<div id="content">Second</div><a class="next-content" href="">end</a>';
          final pages = _RetainedSequencePages([first, second]);
          final source = _htmlSource(origin);
          source['ruleContent'] = {
            'content': '#content@text',
            'nextContentUrl': 'a.next-content@href',
          };
          final producer = _openContinuation(false, source, pages);
          BookSourcePipeline? receiver;
          try {
            final info = await producer.bookInfo(
              HtmlBook(
                url: Uri.parse(bookAddress),
                rawAddress: raw,
                title: 'Book',
              ),
            );
            expect(info.tocHtml, isNotEmpty);
            expect(info.tocUrl, raw);
            final (book, chapters) = await producer.tableOfContents(info);
            expect(pages.requests, hasLength(1));
            final reader = fresh
                ? (receiver = _openContinuation(false, source, pages))
                : producer;
            final body = await reader.chapter(chapters.single, book: book);
            expect(body.text, 'First\nSecond');
            expect(pages.requests, hasLength(2));
            expect(
              pages.requests.last.url.path,
              tail ? '/catalog/next-part' : '/catalog/book/next-part',
              reason:
                  'target: retained relative next uses the full native URL-object base, not its first-comma prefix',
            );
            expect(chapters.single.storeKey, bookAddress);
            expect(chapters.single.persistedAddress, raw);
          } finally {
            producer.cancel();
            receiver?.cancel();
          }
        });
      }
    }
  });

  group('chapterHtmlNextProgramData', () {
    const origin = 'http://source.test';
    const firstTarget = '$origin/catalog/content/1';
    const selected = '$origin/catalog/page-two';
    for (final inertOptions in [false, true]) {
      test('inert options text=$inertOptions', () async {
        final inert = inertOptions
            ? 'var inert=\',{"headers":{"X-Inert":"unused"}}\'; '
            : '';
        final nextText =
            '@js:${inert}java.put("htmlProgramRuns",String(Number(java.get("htmlProgramRuns")||"0")+1)); "$selected"';
        final first =
            '<div id="content">First</div><a class="next-content" href="${HtmlEscape().convert(nextText)}">next</a>';
        const second =
            '<div id="content">Second</div><a class="next-content" href="">end</a>';
        final pages = _RetainedSequencePages([first, second]);
        final source = _htmlSource(origin);
        source['ruleContent'] = {
          'content': '#content@text',
          'nextContentUrl': 'a.next-content@href',
        };
        final state = SourceHostState();
        final pipeline = _openContinuation(false, source, pages, state: state);
        final chapter = SourceChapter(
          'Chapter',
          Uri.parse(firstTarget),
          rawAddress: firstTarget,
        );
        final book = HtmlBook(
          url: Uri.parse('$origin/catalog/book/1'),
          title: 'Book',
        );
        try {
          final HtmlChapterBody body;
          try {
            body = await pipeline.chapter(chapter, book: book);
          } on UnsupportedError catch (error) {
            if (error.message != '暂不支持正文分页地址的 URL 选项') rethrow;
            fail(
              'target: inactive option-shaped program text is not a request option before expansion',
            );
          }
          expect(body.text, 'First\nSecond');
          expect(pages.requests, hasLength(2));
          expect(pages.requests.last.url.toString(), selected);
          expect(pages.requests.last.headers.containsKey('X-Inert'), isFalse);
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlProgramRuns'),
            ),
            '1',
          );
          expect(chapter.storeKey, firstTarget);
        } finally {
          pipeline.cancel();
        }
      });
    }
  });

  group('chapterHtmlFirstProgramData', () {
    const origin = 'http://source.test';
    const original = '$origin/catalog/content/1';
    const selected = '$origin/catalog/content-selected';
    for (final inertOptions in [false, true]) {
      test('inert options text=$inertOptions', () async {
        final inert = inertOptions
            ? 'var inert=\',{"headers":{"X-Inert":"unused"}}\'; '
            : '';
        final address =
            '@js:${inert}java.put("htmlFirstProgramRuns",String(Number(java.get("htmlFirstProgramRuns")||"0")+1)); "$selected"';
        final pages = _ContinuationPages(
          '<div id="content">Body</div>',
          allowedPaths: const [
            '/catalog/content/1',
            '/catalog/content-selected',
          ],
        );
        final source = _htmlSource(origin);
        source['ruleContent'] = {'content': '#content@text'};
        final state = SourceHostState();
        final pipeline = _openContinuation(false, source, pages, state: state);
        final chapter = SourceChapter(
          'Chapter',
          Uri.parse(original),
          rawAddress: address,
        );
        try {
          final body = await pipeline.chapter(chapter);
          expect(body.text, 'Body');
          expect(pages.requests, hasLength(1));
          expect(pages.requests.single.url.toString(), selected);
          expect(pages.requests.single.headers.containsKey('X-Inert'), isFalse);
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlFirstProgramRuns'),
            ),
            '1',
          );
          expect(chapter.storeKey, original);
          expect(chapter.persistedAddress, address);
        } finally {
          pipeline.cancel();
        }
      });
    }
  });

  group('chapterHtmlAliasedNext', () {
    const origin = 'http://source.test';
    const firstTarget = '$origin/catalog/content/1';
    const selected = '$origin/catalog/page-two';
    for (final aliased in [false, true]) {
      test('alias duplicate=$aliased', () async {
        final first =
            '<div id="content">First</div>'
            '<a class="next-content" href="$selected">next</a>'
            '${aliased ? '<a class="next-content" href="/catalog/page-two">alias</a>' : ''}';
        const second =
            '<div id="content">Second</div><a class="next-content" href="">end</a>';
        final pages = _RetainedSequencePages([first, second]);
        final source = _htmlSource(origin);
        source['header'] =
            '@js:var n=String(Number(java.get("htmlAliasHeaders")||"0")+1); java.put("htmlAliasHeaders",n); JSON.stringify({"X-Sequence":n})';
        source['ruleContent'] = {
          'content': '#content@text',
          'nextContentUrl': 'a.next-content@href',
        };
        final state = SourceHostState();
        final pipeline = _openContinuation(false, source, pages, state: state);
        final chapter = SourceChapter(
          'Chapter',
          Uri.parse(firstTarget),
          rawAddress: firstTarget,
        );
        try {
          final body = await pipeline.chapter(chapter);
          expect(body.text, 'First\nSecond');
          expect(pages.requests, hasLength(2));
          expect(pages.requests.map((r) => r.url.toString()), [
            firstTarget,
            selected,
          ]);
          expect(
            pages.requests.map((r) => r.headers['X-Sequence']),
            ['1', '2'],
            reason:
                'target: native URL deduplication precedes per-real-request header evaluation',
          );
          expect(
            await state.entry(
              origin,
              sourceRuleVariableKey(origin, 'htmlAliasHeaders'),
            ),
            '2',
          );
          expect(chapter.storeKey, firstTarget);
        } finally {
          pipeline.cancel();
        }
      });
    }
  });

  // A genuinely new ordinary request reads its own source header once, before
  // its own request program, and sends that same resulting map: the JSON search
  // request and the detail request that follows it therefore transmit different
  // maps and the owning source's counter records both reads.
  group('sourceHeaderPerRequest', () {
    const origin = 'http://source.test';
    test('json search/details', () async {
      final source = _jsonSource(
        origin,
        searchUrl: '/catalog/search',
        bookUrlPattern: r'$^',
      );
      source['header'] =
          "@js:var n=String(Number(java.get('sourceHeaderRuns') || '0') + 1); "
          "java.put('sourceHeaderRuns',n); JSON.stringify({'X-Sequence':n})";
      final pages = _ContinuationPages(
        _repair06Page(
          true,
          book: '/catalog/book/1',
          chapter: '/catalog/content',
        ),
        allowedPaths: const ['/catalog/search', '/catalog/book/1'],
      );
      final state = SourceHostState();
      final pipeline = _openContinuation(true, source, pages, state: state);
      final hits = await pipeline.search('book');
      final (book, chapters) = await pipeline.details(hits.single);
      expect(chapters, hasLength(1));
      expect(book.identityAddress, '$origin/catalog/book/1');
      expect(
        pages.requests,
        hasLength(2),
        reason: 'premise: search and details only',
      );
      expect(pages.requests.map((r) => r.url.path), [
        '/catalog/search',
        '/catalog/book/1',
      ]);
      expect(
        pages.requests.map((r) => r.headers['X-Sequence']),
        ['1', '2'],
        reason:
            'target: each native AnalyzeUrl evaluates source headers for its own request',
      );
      expect(
        await state.entry(
          origin,
          sourceRuleVariableKey(origin, 'sourceHeaderRuns'),
        ),
        '2',
      );
    });
  });

  // The frozen analyzes a book's address text for every details request
  // (`AnalyzeUrl.kt:214-242` over `WebBook.kt:163-169`), so the option script a
  // selected search hit carries runs once per details analysis: the
  // source-visible counter reads 1 and then 2, and the two requests reach the
  // two detail pages the script selects. Reusing the hit's recorded pre-option
  // request instead of analyzing its address skips that script and sends the
  // frozen never-sent target (HTTP-BOUNDARY-01 source O, #138).
  group('requestOptionScripts', () {
    const origin = 'http://source.test';
    const listPage =
        '<div class="item"><h3><a href="/o/book">O1</a></h3></div>';
    const detailPage = '<h1>O1</h1><div class="intro">OI</div>';
    const runScript =
        r"(function(){var n=(Number(String(source.get('optionRuns')))||0)+1;"
        r"source.put('optionRuns',String(n));return result+'/'+n;})()";
    // The frozen keeps the rule's result, option tail included, as the book's
    // identity (`BookList.kt:159-163`); only the request parses that tail.
    final addressTail = ',${jsonEncode({'js': runScript})}';
    final bookUrlRule =
        "h3 a@href@js:'$origin' + result + ',' + "
        'JSON.stringify({js:"$runScript"})';
    // The frozen `AnalyzeUrl` constructor reads the source header map before the
    // address it carries is analyzed (`AnalyzeUrl.kt:125-145`), so this header
    // only observes the counter each request started with.
    final counterHeader =
        "@js:JSON.stringify({'X-Option-Runs':"
        "String(Number(String(source.get('optionRuns')))||0)})";

    test('html same and fresh details run the selected hit option once each', () async {
      final searchPages = _RequestOptionPages({
        '/search': listPage,
        '/o/book/1': detailPage,
        '/o/book/2': detailPage,
      });
      final freshPages = _RequestOptionPages({
        '/o/book/1': detailPage,
        '/o/book/2': detailPage,
      });
      final source = _htmlSource(origin, bookUrlRule: bookUrlRule)
        ..['header'] = counterHeader;
      final state = SourceHostState();
      final search = HtmlSourcePipeline(source, searchPages, hostState: state);
      final fresh = HtmlSourcePipeline(source, freshPages, hostState: state);
      try {
        final hit = (await search.search('o')).single;
        expect(
          hit.url.toString(),
          '$origin/o/book',
          reason:
              'premise: the search keeps the option-free target as identity',
        );
        expect(
          hit.identityAddress,
          '$origin/o/book$addressTail',
          reason: 'premise: the hit keeps the rule text, option tail included',
        );
        expect(
          hit.addressContext,
          isNotNull,
          reason:
              'premise: the search captured the comparison and publication addresses',
        );
        final same = await search.bookInfo(hit);
        final afterSame = await state.entry(
          origin,
          sourceRuleVariableKey(origin, 'optionRuns'),
        );
        final other = await fresh.bookInfo(hit);
        final afterFresh = await state.entry(
          origin,
          sourceRuleVariableKey(origin, 'optionRuns'),
        );
        expect(
          [...searchPages.targets, ...freshPages.targets],
          ['/search', '/o/book/1', '/o/book/2'],
          reason:
              'target: each details analysis analyzes the hit address, and its option script selects that page',
        );
        expect(
          [afterSame, afterFresh],
          ['1', '2'],
          reason: 'target: one option script run per details analysis',
        );
        expect(
          [same.book.intro, other.book.intro],
          ['OI', 'OI'],
          reason: 'the two pages the script selected are the ones read',
        );
        expect(
          [same.book.identityAddress, other.book.identityAddress],
          [hit.identityAddress, hit.identityAddress],
          reason:
              'identity: a details analysis moves the request, not the #99 book identity',
        );
        expect(
          [
            for (final request in [
              ...searchPages.requests,
              ...freshPages.requests,
            ])
              request.headers['X-Option-Runs'],
          ],
          ['0', '0', '1'],
          reason:
              'target: the source headers are read before the address options run, so each request carries the count its own analysis started with',
        );
      } finally {
        fresh.cancel();
        search.cancel();
      }
    });

    test('html TOC continuation pages run their own option scripts', () async {
      const origin = 'http://source.test';
      // The frozen P source: one search hit, a declared TOC address, and two
      // continuation addresses whose own `js` option scripts select the page.
      final source = <String, dynamic>{
        'bookSourceUrl': origin,
        // The same constructor order as the O test: the source header map is
        // read before either continuation address runs its option script.
        'header':
            "@js:JSON.stringify({'X-Toc-Option':"
            "String(Number(String(source.get('tocOptionPage')))||0)})",
        'searchUrl': '/p/search?keyword={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': '.result li',
          'name': 'a.0@text',
          'author': 'span.author@text',
          'bookUrl': 'a.0@href',
        },
        'ruleBookInfo': {
          'name': 'h1@text',
          'author': '.info span.author@text',
          'intro': '.intro@text',
          'tocUrl': '.toc a@href',
        },
        'ruleToc': {
          'chapterList': '.chapters li a',
          'chapterName': 'text',
          'chapterUrl': 'href',
          'nextTocUrl': '.next a@href',
        },
        'ruleContent': {'content': '.c@text'},
      };
      final pages = _RequestOptionPages({
        '/p/search':
            '<ul class="result"><li><a href="$origin/p/book/1">P1</a>'
            '<span class="author">PA</span></li></ul>',
        '/p/book/1':
            '<h1>P1</h1><div class="info"><span class="author">PA</span></div>'
            '<div class="intro">PI</div>'
            '<div class="toc"><a href="$origin/p/book/1/toc">toc</a></div>',
        '/p/book/1/toc':
            '<ul class="chapters"><li><a href="$origin/p/c1">c1</a></li></ul>'
            '<div class="next">'
            "<a href='$origin/p/toc2,{\"js\":\"source.put(&#39;tocOptionPage&#39;,&#39;2&#39;);result + &#39;/2&#39;\"}'>2</a>"
            "<a href='$origin/p/toc3,{\"js\":\"source.put(&#39;tocOptionPage&#39;,&#39;3&#39;);result + &#39;/3&#39;\"}'>3</a>"
            '</div>',
        '/p/toc2/2':
            '<ul class="chapters"><li><a href="$origin/p/c2">c2</a></li></ul>',
        '/p/toc3/3':
            '<ul class="chapters"><li><a href="$origin/p/c3">c3</a></li></ul>',
      });
      final pipeline = HtmlSourcePipeline(source, pages);
      try {
        final hit = (await pipeline.search('p')).single;
        final info = await pipeline.bookInfo(hit);
        late (HtmlBook, List<SourceChapter>) toc;
        final error = await _errorOrNull(
          pipeline.tableOfContents(info).then((value) {
            toc = value;
          }),
        );
        expect(
          error,
          isNull,
          reason:
              'target: each declared continuation page runs its own URL option script and its chapters join the TOC, but the stage answered: $error',
        );
        final (_, chapters) = toc;
        expect(
          chapters.map((chapter) => chapter.name),
          ['c1', 'c2', 'c3'],
          reason: 'target: one chapter per page, in the declared page order',
        );
        expect(
          chapters.map((chapter) => chapter.url.path),
          ['/p/c1', '/p/c2', '/p/c3'],
          reason: 'target: the chapter addresses the pages themselves declare',
        );
        expect(
          pages.targets,
          ['/p/search', '/p/book/1', '/p/book/1/toc', '/p/toc2/2', '/p/toc3/3'],
          reason:
              'target: the first page and each declared continuation page are requested once, at the address its own script selects',
        );
        expect(
          [
            for (final request in pages.requests)
              request.headers['X-Toc-Option'],
          ],
          ['0', '0', '0', '0', '2'],
          reason:
              'target: each page reads its own source headers before its continuation script runs',
        );
      } finally {
        pipeline.cancel();
      }
    });
  });

  // #138: the frozen `Book.kind` has no value when the source leaves the
  // category unset, holds empty text when an explicitly declared kind rule
  // resolves to nothing, and keeps nonempty category text verbatim. The
  // carrier's public serialization and metadata copy must carry that three-way
  // distinction, so the absent state is neither written nor read back as the
  // empty one.
  group('kindNullability', () {
    test('an absent, empty and nonempty category serialize and copy apart', () {
      final url = Uri.parse('http://kind.test/book');
      final absent = HtmlBook(url: url, title: 'Book', author: '作者甲');
      final empty = HtmlBook(url: url, title: 'Book', author: '作者甲', kind: '');
      final nonempty = HtmlBook(
        url: url,
        title: 'Book',
        author: '作者甲',
        kind: '玄幻',
      );
      final cases = [
        (state: 'absent', book: absent, kind: null, serializedKind: null),
        (state: 'empty', book: empty, kind: '', serializedKind: ''),
        (state: 'nonempty', book: nonempty, kind: '玄幻', serializedKind: '玄幻'),
      ];
      for (final row in cases) {
        expect(
          row.book.kind,
          row.kind,
          reason: '${row.state}: the carrier holds the source category',
        );
        final json = row.book.toJson();
        expect(
          json['kind'],
          row.serializedKind,
          reason: '${row.state}: the serialized book carries the category',
        );
        expect(
          json.containsKey('kind'),
          row.serializedKind != null,
          reason:
              '${row.state}: an absent category is omitted, an empty one is written',
        );
        final roundTrip = HtmlBook.fromJson(json);
        expect(
          roundTrip.kind,
          row.kind,
          reason: '${row.state}: the stored row restores the same category',
        );
        expect(roundTrip.title, 'Book');
        expect(roundTrip.author, '作者甲');
        final copy = row.book.withVariable('probe');
        expect(
          copy.kind,
          row.kind,
          reason: '${row.state}: a metadata copy keeps the category',
        );
        expect(copy.variable, 'probe');
        expect(copy.title, 'Book');
        expect(copy.author, '作者甲');
        expect('${copy.url}', 'http://kind.test/book');
      }
      // A stored row whose category key is present but null is the absent
      // state, not the empty one.
      expect(
        HtmlBook.fromJson({...absent.toJson(), 'kind': null}).kind,
        isNull,
        reason: 'a null category in the row restores as absent',
      );
    });

    // The same contract through the public search → `bookInfo` seam. The
    // category a search rule produced — no rule or an exactly empty rule, a
    // declared rule that matches nothing, or real category text — survives the
    // details stage while its own kind rule matches nothing, and an ordinary
    // info-field script sees the same value inside the `book` snapshot. A
    // details value with text still replaces the incoming category.
    //
    // The script publishes the nullness of `book.kind` rather than its text
    // alone, and it is read on `ruleBookInfo.lastChapter`: the details stage
    // merges the category before it reads that field, and the field reaches the
    // carrier without a value formatter between the script and the assertion.
    const snapshotScript =
        '@js:JSON.stringify({kind: book.kind === null ? null : String(book.kind)})';

    test('the HTML pipeline keeps the category its search rule produced', () async {
      const origin = 'http://kind.test';
      const listPage =
          '<div class="item"><h3><a href="/book/1">列表标题</a></h3>'
          '<span class="kind">玄幻</span></div>';
      const detailPage = '<h1>真实标题</h1><span class="kind">仙侠</span>';
      Future<({String? searched, String? informed, String? snapshot})> run(
        String? searchRule,
        String detailKind,
      ) async {
        final source = _htmlSource(origin);
        if (searchRule != null) {
          (source['ruleSearch'] as Map)['kind'] = searchRule;
        }
        final detailsRules = source['ruleBookInfo'] as Map;
        detailsRules['kind'] = detailKind;
        detailsRules['lastChapter'] = snapshotScript;
        final pipeline = HtmlSourcePipeline(
          source,
          _Pages({'/search': listPage, '/book/1': detailPage}),
        );
        try {
          final hit = (await pipeline.search('书')).single;
          final info = await pipeline.bookInfo(hit);
          return (
            searched: hit.kind,
            informed: info.book.kind,
            snapshot: info.book.lastChapter,
          );
        } finally {
          pipeline.cancel();
        }
      }

      final absent = await run(null, 'span.missing@text');
      expect(
        absent.searched,
        isNull,
        reason: 'an absent search kind rule resolves no category',
      );
      expect(
        absent.informed,
        isNull,
        reason:
            'a declared details kind rule that matches nothing retains the absent category',
      );
      expect(
        absent.snapshot,
        '{"kind":null}',
        reason: 'the info-field script sees no category',
      );

      final empty = await run('', 'span.missing@text');
      expect(
        empty.searched,
        isNull,
        reason: 'an exactly empty search kind rule resolves no category',
      );
      expect(
        empty.informed,
        isNull,
        reason:
            'a declared details kind rule that matches nothing retains the absent category',
      );
      expect(
        empty.snapshot,
        '{"kind":null}',
        reason: 'the info-field script sees no category',
      );

      final noMatch = await run('span.missing@text', 'span.missing@text');
      expect(
        noMatch.searched,
        '',
        reason:
            'a declared search kind rule that matches nothing is empty text',
      );
      expect(
        noMatch.informed,
        '',
        reason:
            'a declared details kind rule that matches nothing retains the empty category',
      );
      expect(
        noMatch.snapshot,
        '{"kind":""}',
        reason: 'the info-field script sees empty category text',
      );

      final category = await run('span.kind@text', 'span.missing@text');
      expect(
        category.searched,
        '玄幻',
        reason: 'a declared search kind rule keeps its category text',
      );
      expect(
        category.informed,
        '玄幻',
        reason:
            'a declared details kind rule that matches nothing retains the searched category',
      );
      expect(
        category.snapshot,
        '{"kind":"玄幻"}',
        reason: 'the info-field script sees the searched category',
      );

      final replaced = await run(null, 'span.kind@text');
      expect(
        replaced.searched,
        isNull,
        reason: 'premise: the absent search rule supplies no category',
      );
      expect(
        replaced.informed,
        '仙侠',
        reason: 'a details kind rule with text replaces the incoming category',
      );
      expect(
        replaced.snapshot,
        '{"kind":"仙侠"}',
        reason: 'the info-field script sees the replacing category',
      );
    });

    test('the JSON pipeline keeps the category its search rule produced', () async {
      const origin = 'http://kind.test';
      final listDocument = jsonEncode({
        'listing': [
          {'name': '列表标题', 'url': '/book/1', 'kind': '玄幻'},
        ],
      });
      final detailDocument = jsonEncode({'title': '真实标题', 'kind': '仙侠'});
      Future<({String? searched, String? informed, String? snapshot})> run(
        String? searchRule,
        String detailKind,
      ) async {
        final source = _jsonSource(origin);
        if (searchRule != null) {
          (source['ruleSearch'] as Map)['kind'] = searchRule;
        }
        final detailsRules = source['ruleBookInfo'] as Map;
        detailsRules['kind'] = detailKind;
        detailsRules['lastChapter'] = snapshotScript;
        final pipeline = JsonSourcePipeline(
          source,
          _Pages({'/search': listDocument, '/book/1': detailDocument}),
        );
        try {
          final hit = (await pipeline.search('书')).single;
          final info = await pipeline.bookInfo(hit);
          return (
            searched: hit.kind,
            informed: info.book.kind,
            snapshot: info.book.lastChapter,
          );
        } finally {
          pipeline.cancel();
        }
      }

      final absent = await run(null, r'$.missing');
      expect(
        absent.searched,
        isNull,
        reason: 'an absent search kind rule resolves no category',
      );
      expect(
        absent.informed,
        isNull,
        reason:
            'a declared details kind rule that matches nothing retains the absent category',
      );
      expect(
        absent.snapshot,
        '{"kind":null}',
        reason: 'the info-field script sees no category',
      );

      final empty = await run('', r'$.missing');
      expect(
        empty.searched,
        isNull,
        reason: 'an exactly empty search kind rule resolves no category',
      );
      expect(
        empty.informed,
        isNull,
        reason:
            'a declared details kind rule that matches nothing retains the absent category',
      );
      expect(
        empty.snapshot,
        '{"kind":null}',
        reason: 'the info-field script sees no category',
      );

      final noMatch = await run(r'$.missing', r'$.missing');
      expect(
        noMatch.searched,
        '',
        reason:
            'a declared search kind rule that matches nothing is empty text',
      );
      expect(
        noMatch.informed,
        '',
        reason:
            'a declared details kind rule that matches nothing retains the empty category',
      );
      expect(
        noMatch.snapshot,
        '{"kind":""}',
        reason: 'the info-field script sees empty category text',
      );

      final category = await run(r'$.kind', r'$.missing');
      expect(
        category.searched,
        '玄幻',
        reason: 'a declared search kind rule keeps its category text',
      );
      expect(
        category.informed,
        '玄幻',
        reason:
            'a declared details kind rule that matches nothing retains the searched category',
      );
      expect(
        category.snapshot,
        '{"kind":"玄幻"}',
        reason: 'the info-field script sees the searched category',
      );

      final replaced = await run(null, r'$.kind');
      expect(
        replaced.searched,
        isNull,
        reason: 'premise: the absent search rule supplies no category',
      );
      expect(
        replaced.informed,
        '仙侠',
        reason: 'a details kind rule with text replaces the incoming category',
      );
      expect(
        replaced.snapshot,
        '{"kind":"仙侠"}',
        reason: 'the info-field script sees the replacing category',
      );
    });
  });
}
