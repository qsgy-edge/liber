import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/json_source_pipeline.dart';

import 'package:liber/source/native_library.dart';

import 'native_library.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  test(
    'Legado JSON fields drive the four stages through the pipeline entries',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.toString());
        final body = switch (request.uri.path) {
          '/search' => {
            'items': [
              {'name': 'Changed title', 'url': '/details/73', 'author': '作者甲'},
            ],
          },
          '/details/73' => {
            'title': '真实解析标题',
            'toc': '/chapters/95',
            'intro': '简介',
          },
          '/chapters/95' => {
            'list': [
              {'label': '首章', 'href': '/text/108'},
              {'label': '次章', 'href': '/text/109'},
            ],
          },
          '/text/108' => {'body': '正文包含中文和 emoji 😀'},
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://127.0.0.1:${server.port}',
        'searchUrl': '/search?key={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
          'author': r'$.author',
        },
        'ruleBookInfo': {
          'canReName': 'true',
          'name': r'$.title',
          'tocUrl': r'$.toc',
          'intro': r'$.intro',
        },
        'ruleToc': {
          'chapterList': r'$.list',
          'chapterName': r'$.label',
          'chapterUrl': r'$.href',
        },
        'ruleContent': {'content': r'$.body'},
      };
      final pipeline = JsonSourcePipeline(source, HttpSourceTransport());

      // The three entries the pages hold, one pipeline and one analysis.
      final hits = await pipeline.search('书 & A');
      expect(hits.single.title, 'Changed title');
      expect(hits.single.author, '作者甲');
      final (book, chapters) = await pipeline.details(hits.single);
      expect(book.title, '真实解析标题');
      expect(book.intro, '简介');
      expect(book.url, hits.single.url);
      expect(chapters.map((chapter) => chapter.name), ['首章', '次章']);
      final body = await pipeline.chapter(chapters.first);
      expect(body.text, '正文包含中文和 emoji 😀');

      expect(paths.skip(1), ['/details/73', '/chapters/95', '/text/108']);
      // The frozen runtime substitutes `{{key}}` raw and only then re-encodes
      // the query, so a keyword `&` splits the query exactly as it does there:
      // the literal first pair, then an empty pair from the ` A` remainder.
      expect(Uri.parse(paths.first).queryParameters, {
        'key': '书 ',
        ' A': '',
        'page': '1',
      });
      expect(pipeline.trace, hasLength(4));
    },
  );

  test('a reopened relative JSON chapter fetches against the owning book', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      request.response.write(jsonEncode({'body': '目标正文'}));
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final pipeline = JsonSourcePipeline(
      {'bookSourceUrl': base, 'ruleContent': {'content': r'$.body'}},
      HttpSourceTransport(),
    );
    for (final address in [
      '../chapter/1',
      '../chapter/1,{"webView":false}',
      '$base/chapter/1',
    ]) {
      final chapter = SourceChapter.fromAddress(
        '第一章',
        address,
        bookUrl: Uri.parse('$base/book/1'),
        chapterKey: address,
      );
      expect(chapter.progressKey, address);
      expect(chapter.address, address);
      expect((await pipeline.chapter(chapter)).text, '目标正文');
    }
    expect(paths, ['/chapter/1', '/chapter/1', '/chapter/1']);
  });

  test('the factory gives each source the adapter its rules need', () {
    const transport = _UnusedTransport();
    expect(
      openBookSourcePipeline(const {
        'bookSourceUrl': 'https://example.test',
        'ruleSearch': {'bookList': r'$.items'},
      }, transport),
      isA<JsonSourcePipeline>(),
    );
    expect(
      openBookSourcePipeline(const {
        'bookSourceUrl': 'https://example.test',
        'ruleSearch': {'bookList': '@CSS:.item'},
      }, transport),
      isA<HtmlSourcePipeline>(),
    );
    expect(
      openBookSourcePipeline(const {
        'bookSourceUrl': 'https://example.test',
        'ruleSearch': {'bookList': '@jSoN:\$.items'},
      }, transport),
      isA<JsonSourcePipeline>(),
    );
    // A source with no rule shape at all is not a JSON source.
    expect(
      openBookSourcePipeline(const {
        'bookSourceUrl': 'https://example.test',
      }, transport),
      isA<HtmlSourcePipeline>(),
    );
  });

  test(
    'JSON mode and rule-level merges reach search and content fields',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = switch (request.uri.path) {
          '/search' => {
            'scalar': 'not a list',
            'nul': null,
            'books': [
              {'name': 'A', 'other': 'B', 'url': '/book'},
            ],
          },
          '/book' => {'title': 'Detail', 'toc': '/toc'},
          '/toc' => {
            'first': [
              {'name': 'One', 'url': '/chapter'},
            ],
            'second': [
              {'name': 'Two', 'url': '/chapter'},
            ],
          },
          '/chapter' => {'main': null, 'extra': 'Tail'},
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://127.0.0.1:${server.port}',
        'searchUrl': '/search',
        'ruleSearch': {
          'bookList': r'@jSoN:$.books',
          'name': r'@Json:$.name&&$.other',
          'bookUrl': r'@JSON:$.url',
        },
        'ruleBookInfo': {
          'canReName': 'true',
          'name': r'$.title',
          'tocUrl': r'@Json:$.toc',
        },
        'ruleToc': {
          'chapterList': r'@JSON:$.first%%$.second',
          'chapterName': r'$.name',
          'chapterUrl': r'$.url',
        },
        'ruleContent': {'content': r'$.main||$.extra'},
      };
      final pipeline =
          openBookSourcePipeline(source, HttpSourceTransport())
              as JsonSourcePipeline;
      expect(pipeline, isA<JsonSourcePipeline>());
      final output = await pipeline.run('query', (_) {});
      expect(output.title, 'Detail');
      expect(output.chapters.map((chapter) => chapter.name), ['One', 'Two']);
      expect(output.content, 'Tail');
      expect((await pipeline.search('query')).single.title, 'A\nB');
      (source['ruleSearch'] as Map)['bookList'] = r'$.scalar||$.books';
      expect((await pipeline.search('query')).single.title, 'A\nB');
      (source['ruleSearch'] as Map)['bookList'] = r'$.nul||$.books';
      expect((await pipeline.search('query')).single.title, 'A\nB');
    },
  );

  test('run reads one book end to end with the stage stream', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.toString());
      final body = switch (request.uri.path) {
        '/search' => {
          'items': [
            {'name': 'Changed title', 'url': '/details/73'},
          ],
        },
        '/details/73' => {'title': '真实解析标题', 'toc': '/chapters/95'},
        '/chapters/95' => {
          'list': [
            {'label': '首章', 'href': '/text/108'},
            {'label': '次章', 'href': '/text/109'},
          ],
        },
        '/text/108' => {'body': '正文'},
        _ => {'error': 'Unexpected path'},
      };
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'searchUrl': '/search?key={{key}}&page={{page}}',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
      'ruleBookInfo': {
        'name': r'$.title',
        'tocUrl': r'$.toc',
        'canReName': 'true',
      },
      'ruleToc': {
        'chapterList': r'$.list',
        'chapterName': r'$.label',
        'chapterUrl': r'$.href',
      },
      'ruleContent': {'content': r'$.body'},
    };
    final states = <BookSourceStage>[];
    final pipeline = JsonSourcePipeline(source, HttpSourceTransport());
    final output = await pipeline.run('书', (state) => states.add(state.stage));

    expect(output.title, '真实解析标题');
    expect(output.chapters.map((chapter) => chapter.name), ['首章', '次章']);
    expect(output.content, '正文');
    expect(paths.skip(1), ['/details/73', '/chapters/95', '/text/108']);
    expect(output.trace, hasLength(4));
    expect(states, [
      BookSourceStage.search,
      BookSourceStage.bookInfo,
      BookSourceStage.tableOfContents,
      BookSourceStage.content,
      BookSourceStage.completed,
    ]);

    // Unsupported rules fail before sending any request: every rule group is
    // read before the first one. A `@js:` field is supported now, so the
    // refused shape is one the JSON reader genuinely cannot run.
    source['ruleContent'] = {'content': r'$.rows[?(@.hasContent=1)].content'};
    await expectLater(pipeline.run('x', (_) {}), throwsUnsupportedError);
    expect(paths, hasLength(4));

    source['ruleContent'] = {'content': r'$.body%%$.missing'};
    await expectLater(
      JsonSourcePipeline(source, HttpSourceTransport()).run('x', (_) {}),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => '$error',
          'field',
          contains('ruleContent.content'),
        ),
      ),
    );
    expect(paths, hasLength(4));

    // Missing response data fails, rather than announcing canned success.
    source['ruleContent'] = {'content': r'$.missing'};
    states.clear();
    await expectLater(
      pipeline.run('x', (state) => states.add(state.stage)),
      throwsFormatException,
    );
    expect(states.last, BookSourceStage.failed);
    expect(states, isNot(contains(BookSourceStage.completed)));
  });
  test(
    'a source whose rules filter and slice reads through the stages',
    () async {
      // The used filter shape through the product's own path: the book list and
      // the chapter body are filters, the table of contents is a slice, and the
      // content rule carries every row it matched joined with "\n"
      // (`AnalyzeByJSonPath.getString`).
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        final body = switch (request.uri.path) {
          '/search' => {
            'list': [
              {'hasContent': 1, 'name': '书甲', 'url': '/b/1', 'author': '作者'},
              {'hasContent': 0, 'name': '跳过', 'url': '/b/0'},
            ],
          },
          '/b/1' => {
            'info': {'title': '真实标题'},
            'toc': '/toc/1',
          },
          '/toc/1' => {
            'chapters': [
              {'label': '第一章', 'href': '/ch/1'},
              {'label': '第二章', 'href': '/ch/2'},
              {'label': '第三章', 'href': '/ch/3'},
            ],
          },
          '/ch/1' => {
            'rows': [
              {'hasContent': 1, 'content': '段落一'},
              {'hasContent': 0, 'content': '跳过'},
              {'hasContent': 1, 'content': '段落二'},
            ],
          },
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://127.0.0.1:${server.port}',
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': r'$.list[?(@.hasContent==1)]',
          'name': r'$.name',
          'bookUrl': r'$.url',
          'author': r'$.author',
        },
        'ruleBookInfo': {
          'canReName': 'true',
          'name': r'$.info.title',
          'tocUrl': r'$.toc',
        },
        'ruleToc': {
          'chapterList': r'$.chapters[0:2]',
          'chapterName': r'$.label',
          'chapterUrl': r'$.href',
        },
        'ruleContent': {'content': r'$.rows[?(@.hasContent==1)].content'},
      };
      final pipeline = JsonSourcePipeline(source, HttpSourceTransport());
      final output = await pipeline.run('书', (_) {});

      expect(output.title, '真实标题');
      // The slice kept the first two of the three declared chapters.
      expect(output.chapters.map((chapter) => chapter.name), ['第一章', '第二章']);
      // The filter kept two rows and the frozen join carries both.
      expect(output.content, '段落一\n段落二');
      expect(paths, ['/search', '/b/1', '/toc/1', '/ch/1']);

      // An unsupported form is refused with its field name before any request is
      // sent: the run reads every rule group first.
      source['ruleContent'] = {'content': r'$.rows[?(@.hasContent=1)].content'};
      await expectLater(
        JsonSourcePipeline(source, HttpSourceTransport()).run('书', (_) {}),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('ruleContent.content'),
          ),
        ),
      );
      expect(paths, ['/search', '/b/1', '/toc/1', '/ch/1']);
    },
  );

  test('a JSON source chains a declared nextTocUrl list and a nextContentUrl list', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.toString());
      final body = switch (request.uri.path) {
        '/search' => {
          'items': [
            {'name': '书', 'url': '/details/1'},
          ],
        },
        '/details/1' => {'title': '书', 'toc': '/chapters/1'},
        // A declared list, out of page order and with the page's own URL in it;
        // page 3's list names a page that must never be read.
        '/chapters/1' => {
          'list': [
            {'label': '第一章', 'href': '/text/1'},
          ],
          'next': ['/chapters/3', '/chapters/1', '/chapters/2'],
        },
        '/chapters/3' => {
          'list': [
            {'label': '第三章', 'href': '/text/3'},
          ],
          'next': ['/chapters/9'],
        },
        '/chapters/2' => {
          'list': [
            {'label': '第二章', 'href': '/text/2'},
          ],
        },
        '/text/1' => {
          'body': '第一页',
          'next': ['/text/1-3', '/text/1-2'],
        },
        '/text/1-3' => {'body': '第三页'},
        '/text/1-2' => {'body': '第二页'},
        _ => {'error': 'Unexpected path'},
      };
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'searchUrl': '/search?key={{key}}',
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
        'nextTocUrl': r'$.next',
      },
      'ruleContent': {'content': r'$.body', 'nextContentUrl': r'$.next'},
    };
    final pipeline = JsonSourcePipeline(source, HttpSourceTransport());
    final hits = await pipeline.search('书');
    final (_, chapters) = await pipeline.details(hits.single);
    // Declared order, the page's own URL dropped, and no page of the declared
    // list reads its own list (`/chapters/9`).
    expect(chapters.map((chapter) => chapter.name), ['第一章', '第三章', '第二章']);
    final body = await pipeline.chapter(chapters.first);
    expect(body.text, '第一页\n第三页\n第二页');
    expect(body.pages, 3);
    expect(paths.skip(1), [
      '/details/1',
      '/chapters/1',
      '/chapters/3',
      '/chapters/2',
      '/text/1',
      '/text/1-3',
      '/text/1-2',
    ]);
  });

  test('the JSON content walk stops before the next chapter page', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      final body = switch (request.uri.path) {
        '/text/1' => {'body': '第一页', 'next': '/text/2'},
        '/text/2' => {'body': '下一章正文'},
        _ => {'error': 'Unexpected path'},
      };
      request.response.write(jsonEncode(body));
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final pipeline = JsonSourcePipeline({
      'bookSourceUrl': base,
      'ruleContent': {'content': r'$.body', 'nextContentUrl': r'$.next'},
    }, HttpSourceTransport());
    final body = await pipeline.chapter(
      SourceChapter('第一章', Uri.parse('$base/text/1')),
      nextChapterUrl: '$base/text/2',
    );
    expect(body.text, '第一页');
    expect(body.pages, 1);
    expect(paths, ['/text/1']);
  });

  test('a JSON source still refuses a chaining field outside its own stage', () async {
    final transport = HttpSourceTransport();
    // `nextTocUrl` belongs to `ruleToc`; declared on `ruleSearch` it is refused
    // by name, as every other field this adapter does not implement is.
    final search = JsonSourcePipeline({
      'bookSourceUrl': 'http://127.0.0.1:1',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
        'nextTocUrl': r'$.next',
      },
    }, transport);
    await expectLater(
      search.search('书'),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          'Unsupported field: ruleSearch.nextTocUrl',
        ),
      ),
    );
    // ... and `nextContentUrl` belongs to `ruleContent`.
    final toc = JsonSourcePipeline({
      'bookSourceUrl': 'http://127.0.0.1:1',
      'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
      'ruleToc': {
        'chapterList': r'$.list',
        'chapterName': r'$.label',
        'chapterUrl': r'$.href',
        'nextContentUrl': r'$.next',
      },
    }, transport);
    await expectLater(
      toc.details(
        HtmlBook(url: Uri.parse('http://127.0.0.1:1/book/1'), title: '书'),
      ),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          'Unsupported field: ruleToc.nextContentUrl',
        ),
      ),
    );
  });
}

class _UnusedTransport implements BookSourceTransport {
  const _UnusedTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('该测试不经过传输层');
}
