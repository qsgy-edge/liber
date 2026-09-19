import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/http_source_transport.dart';

import 'native_library.dart';

class _Transport implements SourceHttpTransport, BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
    Map<String, String> query = const {},
  }) async => pages[Uri.parse(path).path]!;
  final requests = <SourceHttpRequest>[];
  final pages = <String, String>{};
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: request.url.path == '/b' ? 404 : 200,
      body: pages[request.url.path] ?? request.url.path,
      url: request.url,
      headers: {
        'x-path': [request.url.path],
      },
    );
  }
}

void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);
  late _Transport transport;
  late InProcessSourceScriptRuntime runtime;
  setUp(() {
    transport = _Transport();
    runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: transport),
    );
  });
  Future<Object?> run(String script, {Map<String, Object?> input = const {}}) =>
      runtime.evaluate(
        source: script,
        input: {'sourceKey': 'http://source.test', ...input},
        timeout: const Duration(seconds: 5),
      );

  test(
    'ajax list selects first URL; ajaxAll returns ordered full response accessors',
    () async {
      expect(
        await run('java.ajax(["http://a.test/a", "http://a.test/b"])'),
        '/a',
      );
      expect(transport.requests, hasLength(1));
      expect(
        await run(
          'JSON.stringify(java.ajaxAll(["http://a.test/a", "http://a.test/b"]).map(r => [r.body(), r.code(), r.url(), r.headers()["x-path"], r.raw().request().url()]))',
        ),
        jsonEncode([
          [
            '/a',
            200,
            'http://a.test/a',
            ['/a'],
            'http://a.test/a',
          ],
          [
            '/b',
            404,
            'http://a.test/b',
            ['/b'],
            'http://a.test/b',
          ],
        ]),
      );
      expect(await run('java.ajaxAll([]).length'), 0);
      expect(
        await run(
          'java.ajaxAll([]); source.get("emptyBatchHeader")',
          input: {
            'source': {
              'header':
                  '@js:source.put("emptyBatchHeader", "unexpected"); "{}"',
            },
          },
        ),
        '',
      );
      expect(transport.requests.every((r) => r.followRedirects), isTrue);
    },
  );

  test(
    'ajaxAll expands URL rules through the existing nested evaluator',
    () async {
      expect(
        await run('java.ajaxAll([\'http://a.test/{{"a"}}\'])[0].body()'),
        '/a',
      );
    },
  );

  test(
    'connect string headers override source; malformed headers use source fallback',
    () async {
      final input = <String, Object?>{
        'source': {'header': '{"X-Source":"source"}'},
      };
      await run(
        'java.connect("http://a.test/a", \'{"X-Override":"override"}\')',
        input: input,
      );
      expect(transport.requests.last.headers, {'X-Override': 'override'});
      for (final argument in ['null', '"invalid"', '""']) {
        await run('java.connect("http://a.test/a", $argument)', input: input);
        expect(transport.requests.last.headers['X-Source'], 'source');
      }
    },
  );

  test(
    'get overload selects HTTP by argument count even with undefined',
    () async {
      expect(await run('java.get("http://a.test/a", undefined).body()'), '/a');
      expect(await run('java.put("key", "value"); java.get("key")'), 'value');
      for (final script in [
        'java.get()',
        'java.connect()',
        'java.ajaxAll("http://a.test/a")',
        'java.ajaxAll([], {})',
      ]) {
        await expectLater(run(script), throwsA(isA<SourceScriptError>()));
      }
    },
  );

  test(
    'getHeaderMap defaults, source static JSON, case-insensitive UA and fresh mutable copy',
    () async {
      expect(
        await run('JSON.stringify(source.getHeaderMap())'),
        jsonEncode({'User-Agent': sourceDefaultUserAgent}),
      );
      final input = <String, Object?>{
        'source': {'header': '{"user-agent":"custom","X-N":2}'},
      };
      expect(
        await run(
          'const h = source.getHeaderMap(false); h["X-N"]="changed"; JSON.stringify(source.getHeaderMap())',
          input: input,
        ),
        jsonEncode({'user-agent': 'custom', 'X-N': '2'}),
      );
      expect(
        await run(
          'source.getHeaderMap()["User-Agent"]',
          input: {
            'source': {'header': 'invalid'},
          },
        ),
        sourceDefaultUserAgent,
      );
    },
  );

  test(
    'getHeaderMap executes both script forms and reads current source state',
    () async {
      for (final header in [
        '@js:JSON.stringify({"X-Token":source.get("token")})',
        '<js>JSON.stringify({"X-Token":source.get("token")})</js>',
      ]) {
        expect(
          await run(
            'source.put("token","a"); const first=source.getHeaderMap()["X-Token"]; source.put("token","b"); first+source.getHeaderMap()["X-Token"]',
            input: {
              'source': {'header': header},
            },
          ),
          'ab',
        );
      }
    },
  );

  test(
    'getHeaderMap keeps null values and tolerates script failures',
    () async {
      expect(
        await run(
          'JSON.stringify(source.getHeaderMap())',
          input: {
            'source': {'header': '{"User-Agent":null}'},
          },
        ),
        '{"User-Agent":null}',
      );
      expect(
        await run(
          'source.getHeaderMap()["User-Agent"]',
          input: {
            'source': {'header': '@js:throw Error("header")'},
          },
        ),
        sourceDefaultUserAgent,
      );
    },
  );

  test('login headers defer by name', () async {
    await expectLater(
      run('source.getHeaderMap(true)'),
      throwsA(
        isA<SourceScriptError>()
            .having(
              (e) => e.message,
              'member',
              contains('source.getHeaderMap(true)'),
            )
            .having((e) => e.message, 'owner', contains('#13')),
      ),
    );
  });

  test(
    'book/chapter snapshots expose actual fields and preserve source-owned state',
    () async {
      final input = <String, Object?>{
        'book': {'name': 'Book', 'bookUrl': 'http://a.test/book'},
        'chapter': {'title': 'Chapter', 'url': 'http://a.test/a'},
      };
      await run(
        'java.put("bookName", "stored-book"); java.put("title", "stored-title")',
        input: input,
      );
      expect(
        await run(
          'JSON.stringify([book.name,book.bookUrl,chapter.title,chapter.url,java.get("bookName"),java.get("title")])',
          input: input,
        ),
        jsonEncode([
          'Book',
          'http://a.test/book',
          'Chapter',
          'http://a.test/a',
          'stored-book',
          'stored-title',
        ]),
      );
      await run('java.put("token", "source-owned")', input: input);
      expect(await run('source.get("token")'), 'source-owned');
      expect(
        await runtime.hostState.entry(
          'http://source.test',
          sourceRuleVariableKey('http://source.test', 'token'),
        ),
        'source-owned',
      );
      expect(await run('book === null && chapter === null'), true);
    },
  );

  test(
    'unavailable variables, fields and mutations refuse by full member name',
    () async {
      for (final member in [
        'book.variable',
        'book.getVariable',
        'book.putVariable',
        'chapter.variable',
        'chapter.getVariable',
        'chapter.putVariable',
        'book.missing',
        'chapter.missing',
      ]) {
        await expectLater(
          run(
            member,
            input: {
              'book': {'name': 'Book'},
              'chapter': {'title': 'Chapter'},
            },
          ),
          throwsA(
            isA<SourceScriptError>()
                .having((e) => e.category, 'category', 'policy')
                .having((e) => e.message, 'member', contains(member)),
          ),
        );
      }
      await expectLater(
        run(
          'book.name = "changed"',
          input: {
            'book': {'name': 'Book'},
          },
        ),
        throwsA(
          isA<SourceScriptError>().having(
            (e) => e.message,
            'member',
            contains('book.name'),
          ),
        ),
      );
    },
  );

  for (final json in [true, false]) {
    test(
      '${json ? "JSON" : "HTML"} pipeline supplies actual stage snapshots and clears them on search',
      () async {
        transport.pages.addAll(
          json
              ? {
                  '/search': '{"items":[{"name":"Hit","url":"/book"}]}',
                  '/book': '{"name":"Details","toc":"/toc"}',
                  '/toc': '{"items":[{"name":"Chapter","url":"/content"}]}',
                  '/content': '{"text":"body"}',
                }
              : {
                  '/search': '<a href="/book">Hit</a>',
                  '/book': '<h1>Details</h1><a href="/toc">toc</a>',
                  '/toc': '<a href="/content">Chapter</a>',
                  '/content': '<p>body</p>',
                },
        );
        final source = <String, dynamic>{
          'bookSourceUrl': 'http://a.test',
          'header': '{"X-Actual":"pipeline"}',
          'searchUrl': '/search',
          'ruleSearch': {
            'bookList': json ? r'$.items' : 'a',
            'name':
                "${json ? r'$.name' : 'a@text'}"
                '@js:if(book !== null || chapter !== null || title !== null) throw Error("stale"); result',
            'bookUrl': json ? r'$.url' : 'a@href',
          },
          'ruleBookInfo': {
            'canReName': 'true',
            'name':
                "${json ? r'$.name' : 'h1@text'}"
                '@js:book.name + result',
            'tocUrl': json ? r'$.toc' : 'a@href',
          },
          'ruleToc': {
            'chapterList': json ? r'$.items' : 'a',
            'chapterName': json ? r'$.name' : 'a@text',
            'chapterUrl': json ? r'$.url' : 'a@href',
          },
          'ruleContent': {
            'content':
                "${json ? r'$.text' : 'p@text'}"
                '@js:book.name+"|"+chapter.title+"|"+source.getHeaderMap()["X-Actual"]',
          },
        };
        final pipeline = openBookSourcePipeline(source, transport);
        final hits = await pipeline.search('key');
        final (book, chapters) = await pipeline.details(hits.single);
        expect(book.title, 'HitDetails');
        final body = await pipeline.chapter(chapters.single);
        expect(body.text, 'HitDetails|Chapter|pipeline');
        pipeline.cancel();
        // Returning from the reader hands the browser a fresh analysis. It
        // must bind the selected book without fetching the details page again.
        final reopened = openBookSourcePipeline(source, transport);
        final requestsBefore = transport.requests.length;
        final reopenedBody = await reopened.chapter(
          chapters.single,
          book: book,
        );
        expect(reopenedBody.text, 'HitDetails|Chapter|pipeline');
        expect(transport.requests.skip(requestsBefore).map((r) => r.url.path), [
          '/content',
        ]);
        expect((await reopened.search('again')).single.title, 'Hit');
        reopened.cancel();
      },
    );
  }

  test(
    'toNumChapter preserves frozen conversion, shorthand, invalid and overflow outcomes',
    () async {
      // Source-derived: JsExtensions.kt:905-912; StringUtils.kt:133-218.
      final rows = <String, String>{
        '第一百二十三章 后文': '第123章',
        '第一千二章': '第1200章',
        '第壹仟零贰拾伍章': '第1025章',
        '第两万零三章': '第20003章',
        '第十二亿三千万章': '第1230000000章',
        '第〇一二三章': '第123章',
        '第１２3章 起点': '第123章',
        '第　＋００１２　章': '第12章',
        '第零章': '第0章',
        '第 abc 章': '第-1章',
        '第2147483648章': '第-1章',
        '第三十亿章': '第-1294967296章',
        '第万章': '第0章',
        '序章': '序章',
      };
      for (final row in rows.entries) {
        expect(
          await run('java.toNumChapter(${jsonEncode(row.key)})'),
          row.value,
          reason: row.key,
        );
      }
      expect(await run('java.toNumChapter(null)'), null);
    },
  );
}
