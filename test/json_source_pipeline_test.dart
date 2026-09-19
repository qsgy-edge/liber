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
    // A source with no rule shape at all is not a JSON source.
    expect(
      openBookSourcePipeline(const {
        'bookSourceUrl': 'https://example.test',
      }, transport),
      isA<HtmlSourcePipeline>(),
    );
  });

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
    source['ruleContent'] = {'content': r'@Json:$.a'};
    await expectLater(pipeline.run('x', (_) {}), throwsUnsupportedError);
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
}

class _UnusedTransport implements BookSourceTransport {
  const _UnusedTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('该测试不经过传输层');
}
