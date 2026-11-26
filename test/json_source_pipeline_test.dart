import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_state.dart';

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

  test('ordinary JSON title failure keeps body and reports once', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      request.response.write('{"body":"JSON BODY"}');
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final messages = <SourceHostMessage>[];
    final chapter = SourceChapter('目录标题', Uri.parse('$base/c/1'));
    final pipeline = JsonSourcePipeline({
      'bookSourceUrl': base,
      'ruleContent': {
        'content': r'$.body',
        'title': '@js: throw new Error("optional title failed")',
      },
    }, HttpSourceTransport())..onHostMessage = messages.add;

    final body = await pipeline.chapter(chapter);
    expect(body.text.trim(), 'JSON BODY');
    expect(body.title ?? chapter.name, '目录标题');
    expect(messages.single.message, contains('optional title failed'));
  });

  for (final cancelInNotice in [false, true]) {
    test(
      '${cancelInNotice ? "cancel on title diagnostic" : "refuse hatch scheme"} in JSON title',
      () async {
        final rule = cancelInNotice
            ? '@js: throw new Error("optional title")'
            : '@js: java.openUrl("file:///not-an-http-address", "title")';
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.write('{"body":"BODY"}');
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        final pipeline = JsonSourcePipeline({
          'bookSourceUrl': base,
          'ruleContent': {'content': r'$.body', 'title': rule},
        }, HttpSourceTransport());
        final notices = <SourceHostMessage>[];
        pipeline.onHostMessage = (notice) {
          notices.add(notice);
          if (cancelInNotice && notice.kind == 'ruleContent.title') {
            pipeline.cancel();
          }
        };
        addTearDown(pipeline.cancel);
        final chapter = SourceChapter('目录标题', Uri.parse('$base/c/1'));
        await expectLater(
          pipeline.chapter(chapter),
          throwsA(
            cancelInNotice
                ? isA<SourceRequestCancelled>()
                : isA<SourceScriptError>()
                      .having((e) => e.category, 'category', 'host-input')
                      .having(
                        (e) => e.message,
                        'member',
                        contains('java.openUrl'),
                      ),
          ),
        );
        expect(
          notices.where((m) => m.kind == 'ruleContent.title'),
          hasLength(cancelInNotice ? 1 : 0),
        );
      },
    );
  }

  for (final (category, rule) in [
    ('policy', '@js: java.readFile("not-used.txt")'),
    ('cancelled', '@js: java.toast("cancel title"); "unpublished"'),
    ('timeout', '@js: while (true) {}'),
  ]) {
    test(
      'JSON title $category still fails the chapter load',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        server.listen((request) async {
          request.response.write('{"body":"JSON BODY"}');
          await request.response.close();
        });
        final base = 'http://127.0.0.1:${server.port}';
        final pipeline = JsonSourcePipeline({
          'bookSourceUrl': base,
          'ruleContent': {'content': r'$.body', 'title': rule},
        }, HttpSourceTransport());
        final messages = <SourceHostMessage>[];
        pipeline.onHostMessage = (message) {
          messages.add(message);
          if (category == 'cancelled' && message.kind == 'toast') {
            pipeline.cancel();
          }
        };
        addTearDown(pipeline.cancel);
        final chapter = SourceChapter('目录标题', Uri.parse('$base/c/1'));
        final error = isA<SourceScriptError>().having(
          (error) => error.category,
          'category',
          category,
        );
        await expectLater(
          pipeline.chapter(chapter),
          throwsA(
            category == 'policy'
                ? error.having(
                    (error) => error.message,
                    'member',
                    contains('java.readFile'),
                  )
                : error,
          ),
        );
        expect(messages.where((m) => m.kind == 'ruleContent.title'), isEmpty);
        if (category == 'cancelled') {
          expect(messages.single.message, 'cancel title');
        }
      },
      timeout: const Timeout(Duration(seconds: 55)),
    );
  }

  test(
    'the JSON content title reads after all pages against the first page',
    () async {
      // The selected content stage joins every page before it reads
      // `ruleContent.title` (`BookContent.kt:65-69`, `:169-182`), against the
      // first page's document. The distinct page markers strengthen the existing
      // after-all-pages placement: page one writes `first`, the final page writes
      // `final`, so a page-one-only read would answer `first|第一页标题`; the title
      // document is still the first page, so a last-page document would answer
      // `final|第二页标题`.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = switch (request.uri.path) {
          '/c/1' => {
            'body': 'JSON BODY',
            'next': '/c/2',
            'title': '第一页标题',
            'marker': 'first',
          },
          '/c/2' => {'body': 'JSON PAGE2', 'title': '第二页标题', 'marker': 'final'},
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'ruleContent': {
          'content':
              r'@js: source.put("seenJson", java.getString("$.marker")); '
              r'java.getString("$.body")',
          'nextContentUrl': r'$.next',
          'title':
              '@js: (source.get("seenJson") || "none") + "|" + '
              r'java.getString("$.title") + "|" + baseUrl',
        },
      }, HttpSourceTransport());
      const options = ',{"headers":{"X-Source-Test":"own chapter"}}';
      final body = await pipeline.chapter(
        SourceChapter(
          '第一章',
          Uri.parse('$base/c/1'),
          rawAddress: '$base/c/1$options',
        ),
      );
      expect(body.title, 'final|第一页标题|$base/c/1$options');
      expect(body.text, 'JSON BODY\nJSON PAGE2');
    },
  );

  for (final (label, rule, expectedText) in [
    ('static replacement', r'##@@AD@@|tail\nsecond##', '　　first\n　　\n　　 page'),
    ('no replacement', null, '　　first@@AD@@\n　　@@AD@@\n　　tail\nsecond page'),
    (
      'scripted replacement remains unexecuted',
      '##@@AD@@@js: throw new Error("unexpected replacement script")',
      '　　first@@AD@@\n　　@@AD@@\n　　tail\nsecond page',
    ),
  ]) {
    test('JSON joined content: $label', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        final body = request.uri.path == '/c/1'
            ? {
                'body': '  first@@AD@@  \n@@AD@@\ntail',
                'next': '/c/2',
                'title': 'first title',
              }
            : {'body': 'second page', 'title': 'second title'};
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'ruleContent': {
          'content': r'$.body',
          'nextContentUrl': r'$.next',
          'title': r'$.title',
          'replaceRegex': ?rule,
        },
      }, HttpSourceTransport());
      final body = await pipeline.chapter(
        SourceChapter('TOC', Uri.parse('$base/c/1')),
      );
      expect(body.text, expectedText);
      expect(body.title, 'first title');
      expect(body.pages, 2);
      expect(paths, ['/c/1', '/c/2']);
    });
  }

  test(
    'a valid JSON null root still reads the declared title after the body',
    () async {
      // A four-byte valid JSON `null` decodes to a null root, not an absent first
      // response. The selected stage keeps the response's raw String as its
      // analysis content and reads a declared title after the body
      // (`BookContent.kt:65-69`, `:169-182`); the title script's state effect
      // must still run.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        request.response.headers.contentType = ContentType.json;
        request.response.write('null');
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final state = SourceHostState();
      final pipeline = JsonSourcePipeline(
        {
          'bookSourceUrl': base,
          'ruleContent': {
            'content': '@js:"BODY"',
            'title': '@js: source.put("nullRootTitleRan","yes"); "TITLE"',
          },
        },
        HttpSourceTransport(),
        hostState: state,
      );
      final body = await pipeline.chapter(
        SourceChapter('TOC', Uri.parse('$base/chapter')),
      );
      expect(body.text, 'BODY');
      expect(body.title, 'TITLE');
      expect(body.pages, 1);
      expect(paths, ['/chapter']);
      expect(
        await state.entry(
          base,
          sourceRuleVariableKey(base, 'nullRootTitleRan'),
        ),
        'yes',
      );
    },
  );

  test(
    'ordinary JSON intros use the empty paragraph indent and retain an empty details rule',
    () async {
      // `BookList.kt:260` and `BookInfo.kt:123` call `HtmlFormatter.formatIntro`,
      // whose only difference from `format` is the empty paragraph indent
      // (`HtmlFormatter.kt:35-50`). A blank information-intro rule keeps the
      // already formatted search intro (`BookInfo.kt:123-130`).
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final body = switch (request.uri.path) {
          '/search' => {
            'items': [
              {'name': 'JSON书', 'url': '/book/1', 'intro': '<p>JSON搜索简介</p>'},
            ],
          },
          '/book/1' => {'title': 'JSON书', 'toc': '/toc/1'},
          '/toc/1' => {
            'list': [
              {'name': '第一章', 'href': '/c/1'},
            ],
          },
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'searchUrl': '/search?keyword={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
          'intro': r'$.intro',
        },
        'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc', 'intro': ''},
        'ruleToc': {
          'chapterList': r'$.list',
          'chapterName': r'$.name',
          'chapterUrl': r'$.href',
        },
      }, HttpSourceTransport());
      final hit = (await pipeline.search('probe')).single;
      expect(hit.intro, 'JSON搜索简介');
      final (book, _) = await pipeline.details(hit);
      expect(book.intro, 'JSON搜索简介');
    },
  );

  test(
    'a reopened relative JSON chapter fetches against the owning book',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        request.response.write(jsonEncode({'body': '目标正文'}));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'ruleContent': {'content': r'$.body'},
      }, HttpSourceTransport());
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

  test('the composed JSON entry keeps its setup and failure order', () async {
    // An invalid TOC group refuses before any request, but only after the
    // source header script, the information rule group and the TOC group have
    // run in the order current callers already see.
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    final paths = <String>[];
    server.listen((request) async {
      paths.add(request.uri.path);
      request.response.write('{}');
      await request.response.close();
    });
    final origin = 'http://127.0.0.1:${server.port}';
    final state = SourceHostState();
    final source = <String, dynamic>{
      'bookSourceUrl': origin,
      'header': '@js:(source.put("hdr","ran"), "{}")',
      'ruleSearch': {
        'bookList': r'$.items',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
      'ruleBookInfo': {'name': r'$.name', 'tocUrl': r'$.toc'},
      // No chapterList: the TOC group is invalid.
      'ruleToc': {'chapterName': r'$.title', 'chapterUrl': r'$.url'},
    };
    final pipeline = JsonSourcePipeline(
      source,
      HttpSourceTransport(),
      hostState: state,
    );
    await expectLater(
      pipeline.details(
        HtmlBook(url: Uri.parse('$origin/book/1'), title: 'Book A'),
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('Missing ruleToc.chapterList'),
        ),
      ),
    );
    expect(
      await state.entry(origin, 'v_${origin}_hdr'),
      'ran',
      reason: 'the header script runs before the TOC group is refused',
    );
    expect(paths, isEmpty, reason: 'the refusal happens before any request');

    // A bad information rule is not replaced by the later TOC group error.
    final badInfo = <String, dynamic>{
      ...source,
      'ruleBookInfo': {'name': r'$.a['},
    };
    final badInfoPipeline = JsonSourcePipeline(
      badInfo,
      HttpSourceTransport(),
      hostState: SourceHostState(),
    );
    await expectLater(
      badInfoPipeline.details(
        HtmlBook(url: Uri.parse('$origin/book/1'), title: 'Book A'),
      ),
      throwsA(
        predicate(
          (error) => '$error'.contains('ruleBookInfo.name'),
          'names the information rule',
        ),
      ),
    );

    // The information entry stays information-only: the same source without a
    // TOC group still reads its information page.
    final infoOnly = <String, dynamic>{
      ...source,
      'ruleBookInfo': {'name': r'$.name', 'tocUrl': r'$.toc'},
    };
    final infoPipeline = JsonSourcePipeline(
      infoOnly,
      HttpSourceTransport(),
      hostState: SourceHostState(),
    );
    expect(
      (await infoPipeline.bookInfo(
        HtmlBook(url: Uri.parse('$origin/book/1'), title: 'Book A'),
      )).book.title,
      'Book A',
      reason: 'the information-only entry never validates the TOC group',
    );
  });

  test(
    'a static bare property reads the property; a literal stays literal',
    () async {
      // The AUTH corpus' source B declares `ruleSearch.kind = "json"`; json-path
      // compiles a bare name as `$.json`, so the field reads the root property
      // (empty when the document has none) instead of carrying its own text. An
      // explicit `{{...}}` expression is the literal-value form RuleField
      // resolves before the reader, so its text stays `json` even though this
      // document has a `json` property.
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'items': [
              {'name': 'B1', 'url': '/details/1', 'json': 'present'},
            ],
          }),
        );
        await request.response.close();
      });
      Future<String?> kindOf(Object? kind) async {
        final source = <String, dynamic>{
          'bookSourceUrl': 'http://127.0.0.1:${server.port}',
          'searchUrl': '/search?key={{key}}',
          'ruleSearch': {
            'bookList': r'$.items',
            'name': r'$.name',
            'bookUrl': r'$.url',
            'kind': ?kind,
          },
        };
        final hits = await JsonSourcePipeline(
          source,
          HttpSourceTransport(),
        ).search('书');
        return hits.single.kind;
      }

      expect(await kindOf('json'), 'present');
      expect(await kindOf(r'$.json'), 'present');
      expect(await kindOf('missing'), '');
      expect(
        await kindOf('{{"json"}}'),
        'json',
        reason: 'an explicit literal template stays its text, not the property',
      );
      expect(await kindOf('@js:"json"'), 'json');
      expect(
        await kindOf(
          r'$'
          '.json',
        ),
        'present',
      );
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
      throwsA(
        isA<SourceStageDiagnostic>()
            .having((error) => error.stage, 'stage', BookSourceStage.content)
            .having(
              (error) => error.kind,
              'failure kind',
              SourceStageFailureKind.extractionFailed,
            )
            .having(
              (error) => error.address,
              'response address',
              'http://127.0.0.1:${server.port}/text/108',
            )
            .having(
              (error) => error.httpResponse?.statusCode,
              'HTTP status',
              200,
            )
            .having(
              (error) => error.httpResponse?.bodyByteLength,
              'raw body bytes',
              utf8.encode(jsonEncode({'body': '正文'})).length,
            ),
      ),
    );
    expect(states.last, BookSourceStage.failed);
    expect(states, isNot(contains(BookSourceStage.completed)));
  });
  test('a source whose rules filter and slice reads through the stages', () async {
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
    // The filter kept two rows and the frozen join carries both. The frozen
    // content stage then indents the line after the join (`BookContent.kt:178`;
    // `tool/html_content_oracle`'s `json-page-value-multiline` row executes it), so
    // the value this pipeline stores carries the frozen's own indent.
    expect(output.content, '段落一\n　　段落二');
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
  });

  test(
    'a JSON source chains a declared nextTocUrl list and a nextContentUrl list',
    () async {
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
    },
  );

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

  test(
    'a JSON source still refuses a chaining field outside its own stage',
    () async {
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
    },
  );

  test(
    'a rule field\'s script failure names the field and the engine\'s message',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          jsonEncode({
            'items': [
              {'name': '书', 'url': '/details/1'},
            ],
          }),
        );
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
        },
        'ruleBookInfo': {
          'name': r'$.title',
          // The operator's own failure shape (ticket #89): a script in
          // `ruleBookInfo.kind` used to reach the interface as the bare `js`.
          'kind': "{{throw new Error('java.getString 未实现')}}",
        },
        'ruleToc': {
          'chapterList': r'$.list',
          'chapterName': r'$.label',
          'chapterUrl': r'$.href',
        },
        'ruleContent': {'content': r'$.body'},
      }, HttpSourceTransport());
      final hits = await pipeline.search('书');
      await expectLater(
        pipeline.details(hits.single),
        throwsA(
          // The classification the callers branch on is unchanged; the message
          // now carries the field and what the engine said.
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'js')
              .having(
                (error) => error.message,
                'message',
                contains('ruleBookInfo.kind'),
              )
              .having(
                (error) => error.message,
                'message',
                contains('java.getString 未实现'),
              ),
        ),
      );
    },
  );

  test(
    'a stage whose body is not JSON names the stage, the address and a bounded prefix',
    () async {
      const body =
          '<html><head><title>502 Bad Gateway</title></head><body>'
          '<p>CF-Challenge: enable JavaScript and cookies to continue</p>'
          '<p>sessionid=SECRET-BODY-TOKEN</p></body></html>';
      expect(
        body.length,
        greaterThan(sourceStageBodyPrefixLimit * 4),
        reason: 'the bound is only meaningful against a body longer than it',
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write(
          request.uri.path == '/search'
              ? jsonEncode({
                  'items': [
                    {'name': '书', 'url': '/details/1?key=SECRET-KEY'},
                  ],
                })
              : body,
        );
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        // A credential the request carries and the diagnostic must not: the
        // source's own header rule, and the key in the details URL's query.
        'header': '{"Authorization":"Bearer SECRET-TOKEN"}',
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
        },
        'ruleContent': {'content': r'$.body'},
      }, HttpSourceTransport());
      final hits = await pipeline.search('书');
      await expectLater(
        pipeline.details(hits.single),
        throwsA(
          isA<SourceStageFormatError>()
              .having((error) => error.stage, 'stage', BookSourceStage.bookInfo)
              .having((error) => error.address, 'address', '$base/details/1')
              .having((error) => error.prefix, 'prefix', startsWith('<html>'))
              .having(
                (error) => error.prefix.length,
                'prefix length',
                lessThanOrEqualTo(sourceStageBodyPrefixLimit),
              )
              .having(
                (error) => '$error',
                'message',
                contains('详情响应不是 JSON（可能是错误页）'),
              )
              .having(
                (error) => '$error',
                'message',
                contains('$base/details/1'),
              )
              .having(
                (error) => '$error',
                'message',
                isNot(contains('SECRET-KEY')),
              )
              .having(
                (error) => '$error',
                'message',
                isNot(contains('SECRET-TOKEN')),
              )
              .having(
                (error) => '$error',
                'message',
                isNot(contains('SECRET-BODY-TOKEN')),
              )
              .having((error) => '$error', 'message', isNot(contains('\n'))),
        ),
      );
    },
  );

  test('each stage names itself, not one hard-coded word', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    server.listen((request) async {
      // Every stage answers the same HTML page.
      request.response.write('<html><body>challenge</body></html>');
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final pipeline = JsonSourcePipeline({
      'bookSourceUrl': base,
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
      },
      'ruleContent': {'content': r'$.body'},
    }, HttpSourceTransport());
    await expectLater(
      pipeline.search('书'),
      throwsA(
        isA<SourceStageFormatError>()
            .having((error) => error.stage, 'stage', BookSourceStage.search)
            .having((error) => error.address, 'address', '$base/search')
            .having(
              (error) => '$error',
              'message',
              contains('搜索响应不是 JSON（可能是错误页）'),
            ),
      ),
    );
  });

  test(
    'a ruleBookInfo.init that selects a subtree keeps it a subtree (#94)',
    () async {
      // The operator's 猫眼 source: `init: $.data`, and a `tocUrl` that
      // interpolates a field from inside that subtree. Text-rendering the init
      // result turned the subtree into a String, so `{{$.novelId}}` read
      // nothing and the TOC address lost its id (a 403).
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.path);
        final body = switch (request.uri.path) {
          '/book/1' => {
            'code': 0,
            'data': {
              'novelId': 'X1',
              'novelName': '真名',
              'authorName': '作者甲',
              'list': [
                {'chapterName': '一', 'path': '/c/1'},
                {'chapterName': '二', 'path': '/c/2'},
              ],
            },
          },
          '/novel/X1/chapters' => {
            'data': {
              'list': [
                {'chapterName': '一', 'path': '/c/1'},
                {'chapterName': '二', 'path': '/c/2'},
              ],
            },
          },
          _ => {'data': <Object>[]},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final base = 'http://127.0.0.1:${server.port}';
      final pipeline = JsonSourcePipeline({
        'bookSourceUrl': base,
        'ruleBookInfo': {
          'init': r'$.data',
          'name': r'$.novelName',
          'author': r'$.authorName',
          'tocUrl': r'/novel/{{$.novelId}}/chapters',
        },
        'ruleToc': {
          'chapterList': r'$.data.list[*]',
          'chapterName': r'$.chapterName',
          'chapterUrl': r'$.path',
        },
        'ruleContent': {'content': r'$.body'},
      }, HttpSourceTransport());

      final (book, chapters) = await pipeline.details(
        HtmlBook(url: Uri.parse('$base/book/1'), title: ''),
      );
      expect(book.title, '真名');
      expect(book.author, '作者甲');
      expect(
        paths,
        contains('/novel/X1/chapters'),
        reason: 'the id comes from the subtree init selected',
      );
      expect(chapters.map((chapter) => chapter.name), ['一', '二']);
    },
  );
}

class _UnusedTransport implements BookSourceTransport {
  const _UnusedTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('该测试不经过传输层');
}
