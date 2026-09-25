import 'dart:async';
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

class _BlockingTransport implements SourceHttpTransport {
  final started = Completer<SourceHttpRequest>();
  final pending = Completer<SourceHttpResponse>();

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) {
    started.complete(request);
    return pending.future;
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

  test('connect source header runs before URL expansion', () async {
    final input = <String, Object?>{
      'sourceKey': 'http://ordering.test',
      'source': {'header': '@js:source.put("segment", "a"); "{}"'},
    };
    for (final url in [
      'http://a.test/{{source.get("segment")}}',
      'http://a.test/{{source.get("segment")}},'
          '{method:"POST",body:"v=1",headers:{"X-Option":"yes"}}',
    ]) {
      expect(
        await run(
          'source.put("segment", ""); java.connect(${jsonEncode(url)}).body()',
          input: input,
        ),
        '/a',
      );
      expect(transport.requests.last.url.path, '/a');
    }
    expect(transport.requests.last.method, 'POST');
    expect(transport.requests.last.body, 'v=1');
    expect(transport.requests.last.headers['X-Option'], 'yes');

    await run(
      'source.put("segment", ""); '
      'java.connect("http://a.test/{{source.get(\'segment\')}}", "{}").body()',
      input: input,
    );
    expect(transport.requests.last.url.path, '/');
    expect(await run('source.get("segment")', input: input), '');
  });

  test(
    'connect URL options shape both overloads and preserve response accessors',
    () async {
      final source = <String, Object?>{
        'source': {'header': '{"X-Source":"yes"}'},
      };
      final url =
          'http://a.test/a,{method:"POST",body:"v=中 文",'
          'charset:"gbk",headers:{"X-Option":"yes"},retry:2}';
      final result = await run(
        'JSON.stringify([java.connect(${jsonEncode(url)}).body(),'
        'java.connect(${jsonEncode(url)}).code(),'
        'java.connect(${jsonEncode(url)}).headers().get("x-path"),'
        'java.connect(${jsonEncode(url)}).raw().request().url()])',
        input: source,
      );
      expect(result, jsonEncode(['/a', 200, '/a', 'http://a.test/a']));
      expect(transport.requests, hasLength(4));
      for (final request in transport.requests) {
        expect(request.url.toString(), 'http://a.test/a');
        expect(request.method, 'POST');
        expect(request.body, 'v=%D6%D0+%CE%C4');
        expect(request.retry, 2);
        expect(request.followRedirects, isTrue);
        expect(request.headers, {
          'X-Source': 'yes',
          'User-Agent': sourceDefaultUserAgent,
          'X-Option': 'yes',
          'Content-Type': 'application/x-www-form-urlencoded',
        });
      }
      final headerUrl =
          'http://a.test/b,{method:"POST",body:{a:1},'
          'headers:{"X-Explicit":"option"},retry:1}';
      await run(
        'java.connect(${jsonEncode(headerUrl)}, '
        '${jsonEncode('{"X-Explicit":"argument"}')})',
        input: source,
      );
      final explicit = transport.requests.last;
      expect(explicit.url.toString(), 'http://a.test/b');
      expect(explicit.method, 'POST');
      expect(explicit.body, '{"a":1}');
      expect(explicit.retry, 1);
      expect(explicit.headers, {
        'X-Explicit': 'option',
        'Content-Type': 'application/json; charset=UTF-8',
      });
      await run(
        'java.connect(${jsonEncode(headerUrl)}, "invalid")',
        input: source,
      );
      expect(transport.requests.last.headers['X-Source'], 'yes');

      final scopedRuntime = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(
          transport: transport,
          sourceRef: 'http://source.test',
        ),
      );
      await scopedRuntime.evaluate(
        source:
            'source.putLoginHeader(\'{"X-Login":"persisted"}\'); '
            'java.connect(${jsonEncode(headerUrl)}, '
            '${jsonEncode('{"X-Explicit":"argument"}')}).body()',
        input: {'sourceKey': 'http://source.test', ...source},
        timeout: const Duration(seconds: 5),
      );
      expect(transport.requests.last.headers, {
        'X-Login': 'persisted',
        'X-Explicit': 'option',
        'Content-Type': 'application/json; charset=UTF-8',
      });
    },
  );

  test(
    'connect GET encodes charset query and URL js, without changing get',
    () async {
      final url = 'http://a.test/a?q=中 文,{charset:"gbk",js:"result+\'&n=1\'"}';
      await run('java.connect(${jsonEncode(url)})');
      expect(
        transport.requests.single.url.toString(),
        'http://a.test/a?q=%D6%D0%20%CE%C4&n=1',
      );
      await expectLater(
        run('java.get(${jsonEncode(url)}, {}).body()'),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            contains('nested URL options unsupported'),
          ),
        ),
      );
      expect(transport.requests, hasLength(1));
    },
  );

  test(
    'connect refuses unsupported options before sending either overload',
    () async {
      for (final url in [
        'http://a.test/a,{webView:true}',
        'http://a.test/a,{type:"audio"}',
        'http://a.test/a,{retry:-1}',
      ]) {
        for (final argument in ['', ', "{\\"X-A\\":\\"yes\\"}"']) {
          await expectLater(
            run('java.connect(${jsonEncode(url)}$argument)'),
            throwsA(
              isA<SourceScriptError>()
                  .having((error) => error.category, 'category', 'policy')
                  .having(
                    (error) => error.message,
                    'member',
                    contains('java.connect'),
                  ),
            ),
          );
        }
      }
      expect(transport.requests, isEmpty);
    },
  );

  test('connect option request is cancelled with its script execution', () async {
    final blocked = _BlockingTransport();
    final token = SourceCancellation();
    final pending =
        InProcessSourceScriptRuntime(
          dispatcher: SourceHostDispatcher(transport: blocked),
        ).evaluate(
          source:
              'java.connect("http://a.test/a,{method:\\"POST\\",body:\\"v=1\\"}").body()',
          input: const {'sourceKey': 'http://source.test'},
          timeout: const Duration(seconds: 5),
          cancellation: token,
        );
    final request = await blocked.started.future;
    expect(request.method, 'POST');
    expect(request.cancellation?.isCancelled, isFalse);
    token.cancel();
    expect(request.cancellation?.isCancelled, isTrue);
    blocked.pending.complete(
      SourceHttpResponse(
        statusCode: 200,
        body: 'late',
        url: request.url,
        headers: const {},
      ),
    );
    await expectLater(
      pending,
      throwsA(
        isA<SourceScriptError>().having(
          (error) => error.category,
          'category',
          'cancelled',
        ),
      ),
    );
  });

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

  test('login headers are served instead of deferred', () async {
    // Since #60 the stored login header is part of the source's header map
    // (`BaseSource.getHeaderMap(true)`), not a named refusal.
    expect(
      await run(
        "source.putLoginHeader(JSON.stringify({'X-Login':'yes'})); "
        'JSON.stringify([source.getHeaderMap()["X-Login"], '
        'source.getHeaderMap(true)["X-Login"], source.getLoginHeader()])',
      ),
      jsonEncode([null, 'yes', '{"X-Login":"yes"}']),
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

  test('unknown snapshot fields and mutations refuse by full member name', () async {
    for (final member in ['book.missing', 'chapter.missing']) {
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
    // The frozen `variable` property has a setter, but its `variableMap` is
    // parsed lazily, so the frozen itself does not see a directly assigned
    // text; writes go through `putVariable`, and an assignment refuses by name.
    for (final member in ['book.variable', 'chapter.variable']) {
      await expectLater(
        run(
          '$member = \'{"k":"v"}\'',
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
      run('book.name = "changed"', input: {'book': {'name': 'Book'}}),
      throwsA(
        isA<SourceScriptError>().having(
          (e) => e.message,
          'member',
          contains('book.name'),
        ),
      ),
    );
  });

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
    'rule members answer the frozen empty results and name the forms left out',
    () async {
      // The frozen `AnalyzeRule.getString`/`getStringList`/`getElement`/
      // `getElements` (#90). With no content object the frozen answers
      // `""`/`null`/`null`/`[]` (`AnalyzeRule.kt:196-200,267-289,335-338,
      // 370-373`), and a null or empty rule is the `TextUtils.isEmpty` branch,
      // which never reaches a content at all.
      expect(
        await run(
          r'JSON.stringify([java.getString("$.a"), java.getStringList("$.a"), '
          r'java.getElement("$.a"), java.getElements("$.a")])',
        ),
        jsonEncode(['', null, null, <Object?>[]]),
      );
      expect(
        await run(
          r'JSON.stringify([java.getString(""), java.getStringList(null), '
          r'java.getElement(undefined), java.getElements("")])',
        ),
        jsonEncode(['', null, null, <Object?>[]]),
      );
      // A content object a source passes needs an analysis to read it with: a
      // runtime that owns no rule path refuses by name instead of reading it
      // with an engine of its own.
      await expectLater(
        run(r'java.getString("$.a", {a: 1})'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having((error) => error.message, 'member', contains('java.getString')),
        ),
      );
      // The two forms this slice leaves out refuse by name, in the frozen's own
      // shape: `getString(ruleStr, unescape)` is a Boolean second argument
      // (Rhino picks that overload by type), and `isUrl` is the third.
      await expectLater(
        run(r'java.getString("$.a", false)'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having((error) => error.message, 'form', contains('unescape=false')),
        ),
      );
      for (final member in ['java.getString', 'java.getStringList']) {
        await expectLater(
          run('$member("\$.a", null, true)'),
          throwsA(
            isA<SourceScriptError>()
                .having((error) => error.category, 'category', 'policy')
                .having((error) => error.message, 'member', contains(member))
                .having((error) => error.message, 'form', contains('isUrl')),
          ),
        );
      }
      // The frozen declares one argument for the element forms, so a second is
      // refused rather than read as the analysis's content (Rhino would find no
      // such overload either).
      await expectLater(
        run(r'java.getElement("$.a", {a: 1})'),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'arguments',
            contains('java.getElement expects one argument'),
          ),
        ),
      );
      // And a member this slice still defers keeps failing by name, which is
      // what the rule members must not turn into a `TypeError`.
      await expectLater(
        run('java.readFile("/tmp/x")'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having((error) => error.message, 'member', contains('java.readFile'))
              .having((error) => error.message, 'deferred', contains('deferred')),
        ),
      );
    },
  );

  test(
    'rule members read the analysis content through the pipeline rule path',
    () async {
      transport.pages.addAll({
        '/search': '{"items":[{"name":"Hit","url":"/book"}]}',
        '/book':
            '{"name":"书","toc":"/toc","status":"1",'
            '"tags":["甲","乙"],"meta":{"n":2}}',
        '/toc': '{"items":[{"name":"第一章","url":"/content"}]}',
        '/content': '{"text":"正文"}',
        '/html-search': '<a href="/html-book">Hit</a>',
        '/html-book':
            '<h1>书名</h1><p class="k">完结</p><a href="/html-toc">目录</a>',
        '/html-toc': '<a href="/html-content">第一章</a>',
        '/html-content': '<p>正文</p>',
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://a.test',
        'bookSourceName': '契约源',
        'searchUrl': '/search',
        'ruleSearch': {
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
          // A per-element field's content object is the matched element, which
          // is the frozen `AnalyzeRule.setContent(item)` (`BookList.kt:208`).
          'kind': "{{java.getString('\$.name')}}",
          // The member's rule runs in the analysis's own scope: its `@js:`
          // segment reads the source's variables and reaches the host surface
          // through the same bridge the field's script does.
          'intro':
              "@js:source.put('k', 'v'); "
              "java.getString('\$.name@js:source.get(\"k\") + result')",
        },
        'ruleBookInfo': {
          'tocUrl': r'$.toc',
          // The frozen `canReName` decides whether the detail page's name
          // replaces the search hit's, so the member's answer is readable.
          'canReName': 'true',
          // The operator's own failing shape (#90): a `{{…}}` rule that asks
          // the member for one field of the detail page.
          'kind': "{{java.getString('\$.status')=='1'?'完结':'连载';}}",
          'intro': "{{java.getStringList('\$.tags[*]').join('|')}}",
          'name': "{{java.getElement('\$.meta').n}}",
          'wordCount': "{{java.getElements('\$.tags[*]').length}}",
          // The member's own content argument, over the analysis's content:
          // the frozen `getString(ruleStr, mContent)`.
          'author': "{{java.getString('\$.n', {n: 7})}}",
          // A rule that itself carries `{{…}}` is resolved by the same rule
          // path a field is, for both the script form and the `$.` form. The
          // text is assembled in the script because a `{{…}}` written literally
          // in a rule field is resolved by the field before the script runs.
          'lastChapter':
              r"@js:java.getString('{'+'{source.getName()}}') + "
              r"java.getString('{'+'{$.status}}')",
        },
        'ruleToc': {
          'chapterList': r'$.items',
          'chapterName': r'$.name',
          'chapterUrl': r'$.url',
        },
        'ruleContent': {'content': r'$.text'},
      };
      final pipeline = openBookSourcePipeline(source, transport);
      final hits = await pipeline.search('key');
      expect(hits.single.kind, 'Hit');
      expect(hits.single.intro, 'vHit');
      final (book, chapters) = await pipeline.details(hits.single);
      expect(book.kind, '完结');
      expect(book.intro, '甲|乙');
      expect(book.title, '2');
      expect(book.lastChapter, '契约源1');
      expect(book.wordCount, '2字');
      expect(book.author, '7');
      expect(chapters.single.name, '第一章');
      pipeline.cancel();
      // The same members over HTML content read through the Rust adapter, which
      // is this source's own rule path. The list and element forms refuse by
      // name there: the frozen's jsoup element objects cannot cross this
      // boundary, so a source reads the same text with `java.getString`.
      final htmlSource = <String, dynamic>{
        'bookSourceUrl': 'http://a.test',
        'searchUrl': '/html-search',
        'ruleSearch': {'bookList': 'a', 'name': 'a@text', 'bookUrl': 'a@href'},
        // The member is asked from a `@js:` field here: an HTML field whose
        // whole text is one `{{…}}` is a shape this adapter reads differently
        // (its substituted text is re-read as a selector), which is a
        // divergence this ticket does not change.
        'ruleBookInfo': {
          'canReName': 'true',
          'name': 'h1@text',
          'tocUrl': 'a@href',
          'kind': "@js:java.getString('p@text')",
        },
        'ruleToc': {
          'chapterList': 'a',
          'chapterName': 'a@text',
          'chapterUrl': 'a@href',
        },
        'ruleContent': {'content': "@js:java.getString('p@text')"},
      };
      final htmlPipeline = openBookSourcePipeline(htmlSource, transport);
      final htmlHits = await htmlPipeline.search('key');
      final (htmlBook, htmlChapters) = await htmlPipeline.details(
        htmlHits.single,
      );
      expect(htmlBook.title, '书名');
      expect(htmlBook.kind, '完结');
      expect(
        (await htmlPipeline.chapter(htmlChapters.single)).text,
        '正文',
      );
      htmlPipeline.cancel();
      final refusalPipeline = openBookSourcePipeline(
        <String, dynamic>{...htmlSource}
          ..['ruleBookInfo'] = {
            'name': 'h1@text',
            'kind': "{{java.getElements('p')}}",
          },
        transport,
      );
      final refusalHits = await refusalPipeline.search('key');
      expect(refusalHits.single.title, 'Hit');
      await expectLater(
        refusalPipeline.details(refusalHits.single),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having(
                (error) => error.message,
                'member',
                contains('java.getElements'),
              ),
        ),
      );
      refusalPipeline.cancel();
    },
  );

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
