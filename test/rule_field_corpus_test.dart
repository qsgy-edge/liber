import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html4_unescape.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';

import '../tool/html_adapter_gate.dart' as html_gate;
import 'native_library.dart';

const _oracle = 'tool/rule_field_oracle';

class _StringPages implements BookSourceTransport {
  _StringPages(this.pages, {this.recordPathOnly = false});
  final Map<String, String> pages;
  final bool recordPathOnly;
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final key = Uri.parse(path).path;
    requests.add(recordPathOnly ? key : path);
    return pages[key] ?? (throw StateError('Unexpected URL: $path'));
  }
}

class _HttpPages implements BookSourceTransport, SourceHttpTransport {
  _HttpPages(this.pages, {this.responses = const {}});
  final Map<String, String> pages;
  final Map<String, String> responses;
  final requests = <SourceHttpRequest>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('Real SourceHttpTransport.send required');

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final body = pages[request.url.path];
    if (body == null) {
      throw StateError(
        'Unexpected full request ${request.method} ${request.url}',
      );
    }
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: body,
      url: Uri.parse(responses[request.url.path] ?? '${request.url}'),
    );
  }
}

List<Map> _loadFixtureList(String file) =>
    (jsonDecode(File('$_oracle/$file').readAsStringSync()) as List).cast<Map>();

Map _loadGolden(String dir) =>
    jsonDecode(File('$_oracle/evidence/$dir/golden.json').readAsStringSync())
        as Map;

String _readUnits(Map read) => String.fromCharCodes(
  ((read['joinedUnits'] ?? (read['values'] as List).single) as List).cast<int>(),
);

String _unitsText(Object? units) =>
    String.fromCharCodes((units as List).cast<int>());

Future<String> _savedVar(
  SourceHostState state,
  String origin,
  String key,
) async =>
    (await state.entry(origin, sourceRuleVariableKey(origin, key))
        as String?) ??
    '';

Future<void> _seedVars(SourceHostState state, String origin, Map seed) async {
  for (final entry in seed.entries) {
    await state.putEntry(
      origin,
      sourceRuleVariableKey(origin, '${entry.key}'),
      '${entry.value}',
    );
  }
}

void _expectRequests(_HttpPages pages, String origin, List<String> addresses) =>
    expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
      for (final address in addresses) ['GET', '$origin$address'],
    ]);

class _CancelAtExpression extends InProcessSourceScriptRuntime {
  @override
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) {
    cancellation!.cancel();
    return super.evaluate(
      source: source,
      input: input,
      timeout: timeout,
      cancellation: cancellation,
    );
  }
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  _registerBlockFive();
  _registerBookVisibility();
  _registerCallerEdges();
  _registerFallbackGetCase();
  _registerIntroTail();
  _registerNextBookState();
  _registerReadContext();
  _registerRelativeFallback();
  _registerReview();
  _registerScalarTail();
  _registerTocChapterBinding();
}

void _registerBlockFive() {
  const origin = 'https://review-rules.test';
  final cases = _loadFixtureList('block-five-fixtures.json');
  final golden = _loadGolden('block-five-host');

  Map<String, dynamic> source({bool json = false}) => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {
      'bookList': json ? r'$.items' : 'li',
      'name': json ? r'$.name' : 'a@text',
      'bookUrl': json ? r"{{'/book'}}" : 'a@href',
    },
    'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
    'ruleToc': {
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  String? bookValue(HtmlBook book, String field) => switch (field) {
    'name' => book.title,
    'author' => book.author,
    'kind' => book.kind,
    'wordCount' => book.wordCount,
    'lastChapter' => book.lastChapter,
    'intro' => book.intro,
    'bookUrl' => book.rawAddress!,
    _ => throw StateError('Unexpected field $field'),
  };

  const bookFixture = <String, String>{
    '/book': '{"name":"root","item":{"name":"nested"}}',
    '/toc': '{"list":[{"name":"chapter","href":"/chapter"}]}',
  };
  HtmlBook oldBook({String author = 'old'}) =>
      HtmlBook(url: Uri.parse('$origin/book'), title: 'old', author: author);

  group('executed five finding regression', () {
    for (final scenario in const <String, ({String? init, String author})>{
      'no-init': (init: null, author: 'root'),
      'script-string': (init: "@js:'body'", author: 'old'),
      'script-list': (init: '@js:[1,2]', author: 'old'),
      'decoded-map': (init: r'$.item', author: 'nested'),
    }.entries) {
      test(
        'supported bare-key ${scenario.key} preserves its input boundary',
        () async {
          final src = source(json: true);
          final info = src['ruleBookInfo'] as Map;
          info['author'] = 'name';
          if (scenario.value.init != null) info['init'] = scenario.value.init;

          final bookPages = _StringPages(bookFixture);
          final infoResult = await JsonSourcePipeline(
            src,
            bookPages,
          ).bookInfo(oldBook());
          expect(infoResult.book.author, scenario.value.author);
          expect(infoResult.tocAddress, '/toc');
          expect(bookPages.requests, ['$origin/book']);

          final detailPages = _StringPages(bookFixture);
          final (book, chapters) = await JsonSourcePipeline(
            src,
            detailPages,
          ).details(oldBook());
          expect(book.author, scenario.value.author);
          expect(chapters, hasLength(1));
          expect(chapters.single.name, 'chapter');
          expect(chapters.single.rawAddress, '/chapter');
          expect(detailPages.requests, ['$origin/book', '$origin/toc']);

          final badSource = source(json: true);
          (badSource['ruleBookInfo'] as Map).addAll(<String, String>{
            'author': 'foo bar',
            if (scenario.value.init != null) 'init': scenario.value.init!,
          });
          final badPages = _StringPages(bookFixture);
          await expectLater(
            JsonSourcePipeline(badSource, badPages).bookInfo(oldBook()),
            throwsA(
              isA<UnsupportedError>()
                  .having(
                    (error) => '$error',
                    'field label',
                    contains('ruleBookInfo.author'),
                  )
                  .having(
                    (error) => '$error',
                    'rule text',
                    contains('foo bar'),
                  ),
            ),
          );
          expect(badPages.requests, isEmpty);
        },
      );
    }

    test(
      'ignored book-info updateTime stays outside the native-object getter whitelist',
      () async {
        final src = source(json: true);
        (src['ruleBookInfo'] as Map).addAll(<String, String>{
          'init': "@js:({toc:'/toc'})",
          'tocUrl': 'toc',
          'updateTime': 'name',
        });

        final bookPages = _StringPages(bookFixture);
        final infoResult = await JsonSourcePipeline(
          src,
          bookPages,
        ).bookInfo(oldBook());
        expect(infoResult.book.author, 'old');
        expect(infoResult.tocAddress, '/toc');
        expect(bookPages.requests, ['$origin/book']);

        final detailPages = _StringPages(bookFixture);
        final (book, chapters) = await JsonSourcePipeline(
          src,
          detailPages,
        ).details(oldBook());
        expect(book.author, 'old');
        expect(chapters, hasLength(1));
        expect(chapters.single.name, 'chapter');
        expect(chapters.single.rawAddress, '/chapter');
        expect(detailPages.requests, ['$origin/book', '$origin/toc']);

        final badSource = source(json: true);
        (badSource['ruleBookInfo'] as Map).addAll(<String, String>{
          'init': "@js:({toc:'/toc'})",
          'tocUrl': 'toc',
          'updateTime': 'foo bar',
        });
        final badPages = _StringPages(bookFixture);
        await expectLater(
          JsonSourcePipeline(badSource, badPages).bookInfo(oldBook()),
          throwsA(
            isA<UnsupportedError>()
                .having(
                  (error) => '$error',
                  'field label',
                  contains('ruleBookInfo.updateTime'),
                )
                .having((error) => '$error', 'rule text', contains('foo bar')),
          ),
        );
        expect(badPages.requests, isEmpty);
      },
    );

    test(
      'nested put keeps its existing named refusal without side effects',
      () async {
        final row = cases.singleWhere(
          (row) => row['name'] == 'nested-put-policy-frozen-only',
        );
        final src = source(json: true);
        (src['ruleBookInfo'] as Map)['author'] = row['rule'];
        final state = SourceHostState();
        await expectLater(
          JsonSourcePipeline(
            src,
            _StringPages({'/book': row['content'] as String}),
            hostState: state,
          ).details(oldBook(author: '')),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => '$error',
              'named refusal',
              contains('@put:'),
            ),
          ),
        );
        expect(
          await state.entry(origin, sourceRuleVariableKey(origin, 'saved')),
          isNull,
        );
      },
    );

    for (final name in [
      'nested-put-html-literal',
      'nested-put-html-literal-script',
    ]) {
      test('html adapter gate complete nested getter $name', () async {
        final row = cases.singleWhere((row) => row['name'] == name);
        final observed = golden[name] as Map;
        final read =
            (((observed['items'] as List).single as Map)['reads'] as List)
                    .single
                as Map;
        expect(
          (await html_gate.htmlAdapterRuleFieldValue(
            row['content'] as String,
            row['rule'] as String,
            baseUrl: '$origin/book',
          )).codeUnits,
          _readUnits(read).codeUnits,
        );
      });
    }

    for (final row in cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} uses the actual caller', () async {
        final state = SourceHostState();
        final name = row['name'] as String;
        final observed = golden[name] as Map;
        if (row['error'] == true) {
          final src = source(json: true);
          (src['ruleBookInfo'] as Map)['author'] = row['rule'];
          await expectLater(
            JsonSourcePipeline(
              src,
              _StringPages({'/book': row['content'] as String}),
              hostState: state,
            ).details(oldBook()),
            throwsA(
              isA<SourceScriptError>().having(
                (error) => error.message,
                'nested error',
                contains('nested-getter'),
              ),
            ),
          );
          return;
        }
        final items = (observed['items'] as List).cast<Map>();
        final json =
            row['pipeline'] == 'json' ||
            (row['pipeline'] != 'html' &&
                row['type'] != 'node' &&
                !name.startsWith('html-'));
        final content = row['content'] as String? ?? '<p>body</p>';
        final src = source(json: json);
        final sequence = row['reads'] as List?;
        if (sequence != null) {
          for (final read in sequence.cast<Map>()) {
            (src['ruleSearch'] as Map)[read['field']] = read['rule'];
          }
          final pages = _StringPages({'/search': content});
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(src, pages, hostState: state)
              : HtmlSourcePipeline(src, pages, hostState: state);
          final books = await pipeline.search('x');
          expect(books, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            for (final read in (items[i]['reads'] as List).cast<Map>()) {
              expect(
                bookValue(books[i], read['field'] as String)?.codeUnits,
                _readUnits(read).codeUnits,
                reason: '$name item=$i field=${read['field']}',
              );
            }
          }
        } else {
          final rule = row['rule'] as String;
          final list = row['form'] == 'list';
          final String? actual;
          if (row['type'] == 'node') {
            (src['ruleSearch'] as Map)[row['url'] == true
                    ? 'bookUrl'
                    : 'author'] =
                rule;
            final hit = (await HtmlSourcePipeline(
              src,
              _StringPages({'/search': content}),
              hostState: state,
            ).search('x')).first;
            actual = row['url'] == true ? hit.rawAddress! : hit.author;
          } else if (row['unescape'] == false) {
            src['ruleContent'] = {'content': rule};
            final body = await JsonSourcePipeline(
              src,
              _StringPages({'/chapter': content}),
              hostState: state,
            ).chapter(SourceChapter('chapter', Uri.parse('$origin/chapter')));
            actual = body.text;
          } else {
            final info = src['ruleBookInfo'] as Map;
            info[list ? 'kind' : 'author'] = rule;
            if (row['type'] == 'nativeObject') info['init'] = '@js:($content)';
            if (name == 'native-toc-key') info['tocUrl'] = rule;
            if (row['type'] == 'map') info['init'] = row['selector'];
            final pages = _StringPages({
              '/book': row['type'] == 'nativeObject'
                  ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                  : content,
              '/toc': json
                  ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                  : '<li><a href="/chapter">chapter</a></li>',
            });
            final BookSourcePipeline pipeline = json
                ? JsonSourcePipeline(src, pages, hostState: state)
                : HtmlSourcePipeline(src, pages, hostState: state);
            final (book, _) = await pipeline.details(oldBook(author: ''));
            actual = name == 'native-toc-key'
                ? Uri.parse(pages.requests.last).path
                : list
                ? book.kind
                : book.author;
          }
          final read = (items.single['reads'] as List).single as Map;
          final expected = row['unescape'] == false
              ? formatContentPage(_readUnits(read))
              : _readUnits(read);
          expect(actual?.codeUnits, expected.codeUnits, reason: name);
        }
        for (final entry in (observed['variables'] as Map).entries) {
          expect(
            await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, '${entry.key}'),
                ) ??
                '',
            entry.value,
            reason: '$name variable=${entry.key}',
          );
        }
      });
    }
  });
}

void _registerBookVisibility() {
  const origin = 'https://context-rules.test';
  final cases = _loadFixtureList('book-visibility-fixtures.json');
  final golden = _loadGolden('book-visibility-host');
  final aliases = _loadFixtureList('book-alias-fixtures.json');
  final aliasGolden = _loadGolden('book-alias-host');

  group('actual book read visibility', () {
    for (final row in aliases) {
      test('${row['name']} leaves source.get and ordinary fallback intact', () async {
        final state = SourceHostState();
        await state.putEntry(
          origin,
          sourceRuleVariableKey(origin, 'bookName'),
          'stored',
        );
        await state.putEntry(
          origin,
          sourceRuleVariableKey(origin, 'ordinary'),
          'value',
        );
        final result = await InProcessSourceScriptRuntime(hostState: state)
            .evaluate(
              source: row['script'] as String,
              input: {
                'sourceKey': origin,
                'src': '{}',
                'result': '{}',
                if (row['bookName'] != null) 'book': {'name': row['bookName']},
              },
              timeout: const Duration(seconds: 2),
            );
        expect('$result'.codeUnits, (aliasGolden[row['name']] as List).cast<int>());
      });
    }

    for (final row in cases) {
      test('${row['name']} publishes each completed name/author getter', () async {
        final json = row['pipeline'] == 'json';
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'ruleBookInfo': <String, String>{
            ...(row['rules'] as Map).cast<String, String>(),
            'canReName': row['canReName'] == true ? 'yes' : '',
            'tocUrl': r"{{'/toc'}}",
          },
          'ruleToc': {
            'chapterList': json ? r'$.list' : 'li',
            'chapterName': json ? r'$.name' : 'a@text',
            'chapterUrl': json ? r'$.href' : 'a@href',
          },
        };
        final pages = _StringPages({
          '/book': row['content'] as String,
          '/toc': json
              ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
              : '<li><a href="/chapter">chapter</a></li>',
        });
        final hit = HtmlBook(
          url: Uri.parse('$origin/book'),
          title: row['initialName'] as String,
          author: row['initialAuthor'] as String,
          rawAddress: '$origin/book',
        );
        final (book, _) = json
            ? await JsonSourcePipeline(source, pages).details(hit)
            : await HtmlSourcePipeline(source, pages).details(hit);
        final observed = golden[row['name']] as Map;
        expect(
          book.title.codeUnits,
          (observed['finalNameUnits'] as List).cast<int>(),
        );
        expect(
          book.author.codeUnits,
          (observed['finalAuthorUnits'] as List).cast<int>(),
        );
        expect(
          book.kind?.codeUnits,
          ((observed['getterUnits'] as Map)['kind'] as List).cast<int>(),
        );
        expect(
          book.wordCount.codeUnits,
          ((observed['getterUnits'] as Map)['wordCount'] as List).cast<int>(),
        );
        expect(book.rawAddress, hit.rawAddress);
      });
    }
  });
}

void _registerCallerEdges() {
  const origin = 'https://caller-edges.test';
  final rows = _loadFixtureList('caller-edges-fixtures.json');
  final golden = _loadGolden('caller-edges-host');

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': <String, String>{
      'bookList': json ? r'$.items' : 'li',
      'name': json ? r'$.name' : 'a@text',
      'bookUrl': json ? r'$.href' : 'a@href',
    },
    'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'/toc'}}"},
    'ruleToc': <String, String>{
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  String tocBody(bool json) => json
      ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
      : '<li><a href="/chapter">chapter</a></li>';

  BookSourcePipeline makePipeline(
    bool json,
    Map<String, dynamic> source,
    _HttpPages pages,
    SourceHostState state,
  ) => json
      ? JsonSourcePipeline(source, pages, hostState: state)
      : HtmlSourcePipeline(source, pages, hostState: state);

  group('caller edges actual auxiliary getters and source controls', () {
    for (final row in rows) {
      test(
        '${row['name']} reaches the real supported pipeline caller',
        () async {
          final json = row['pipeline'] == 'json';
          final state = SourceHostState();
          final source = sourceMap(json);
          final observed = golden[row['name']] as Map;
          if (row['seed'] != null) {
            await _seedVars(state, origin, row['seed'] as Map);
          }
          final stage = row['stage'];
          if (stage == 'toc') {
            (source['ruleToc'] as Map).addAll(
              (row['rules'] as Map).cast<String, String>(),
            );
            final pages = _HttpPages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': row['content'] as String,
            });
            final pipeline = makePipeline(json, source, pages, state);
            final (_, chapters) = await pipeline.details(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
            );
            final expected = (observed['chapters'] as List).cast<Map>();
            expect(chapters, hasLength(expected.length));
            for (var i = 0; i < chapters.length; i++) {
              final chapter = chapters[i];
              final values = expected[i];
              expect(chapter.name.codeUnits, values['chapterName']);
              expect(chapter.rawAddress!.codeUnits, values['chapterUrl']);
              expect((chapter.tag ?? '').codeUnits, values['updateTime']);
              expect('${chapter.isVolume}'.codeUnits, values['isVolume']);
              expect('${chapter.isVip}'.codeUnits, values['isVip']);
              expect('${chapter.isPay}'.codeUnits, values['isPay']);
            }
            expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
            pipeline.cancel();
          } else if (stage == 'hostList') {
            (source['ruleBookInfo'] as Map)['author'] = row['rule'];
            final pages = _HttpPages({
              '/book': row['content'] as String,
              '/toc': tocBody(true),
            });
            final pipeline = makePipeline(true, source, pages, state);
            final (book, _) = await pipeline.details(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
            );
            expect(book.author.codeUnits, (observed['fields'] as Map)['value']);
            expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
            pipeline.cancel();
          } else {
            final info = source['ruleBookInfo'] as Map;
            info['name'] = row['nameRule'];
            info['tocUrl'] = row['tocRule'];
            if (row['initRule'] != null) info['init'] = row['initRule'];
            final fallback = stage == 'fallback';
            if (fallback && row['trigger'] == 'pattern') {
              source['bookUrlPattern'] = '.*search.*';
            }
            final pages = _HttpPages({
              fallback ? '/search' : '/book': row['content'] as String,
              '/toc': tocBody(json),
            });
            final pipeline = makePipeline(json, source, pages, state);
            Future<List<HtmlBook>> run() async {
              if (fallback) return pipeline.search('x');
              final (book, _) = await pipeline.details(
                HtmlBook(url: Uri.parse('$origin/book'), title: ''),
              );
              return [book];
            }

            if (row['error'] == true) {
              expect(observed['errorType'], isNotNull);
              await expectLater(
                run(),
                throwsA(
                  isA<SourceScriptError>().having(
                    (e) => e.message,
                    'message',
                    contains('fallback-toc'),
                  ),
                ),
              );
            } else {
              final books = await run();
              expect(books, hasLength(1));
              expect(
                books.single.title.codeUnits,
                (observed['fields'] as Map)['name'],
              );
              expect(
                '${books.single.url}',
                fallback ? '$origin/search' : '$origin/book',
              );
            }
            expect(
              pages.requests.map((r) => [r.method, '${r.url}']).toList(),
              fallback
                  ? [
                      ['GET', '$origin/search'],
                    ]
                  : [
                      ['GET', '$origin/book'],
                      ['GET', '$origin/toc'],
                    ],
            );
            pipeline.cancel();
          }
          for (final entry in (observed['variables'] as Map).entries) {
            expect(
              await _savedVar(state, origin, '${entry.key}'),
              entry.value,
              reason: 'variable ${entry.key}',
            );
          }
        },
      );
    }

    test(
      'n3 script-list policy is a named rejection guard, not parity',
      () async {
        const inner = r'$.title @js:result';
        final encoded = 'String.fromCharCode(${inner.codeUnits.join(',')})';
        final source = sourceMap(true);
        (source['ruleBookInfo'] as Map)['author'] =
            '@js:java.getStringList($encoded)[0]';
        final pages = _HttpPages({'/book': '{"title":"body"}'});
        final pipeline = makePipeline(true, source, pages, SourceHostState());
        await expectLater(
          pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          ),
          throwsA(
            isA<SourceScriptError>().having(
              (e) => e.category,
              'category',
              'policy',
            ),
          ),
        );
        expect(pages.requests.single.url.path, '/book');
        pipeline.cancel();
      },
    );

    for (final json in [false, true]) {
      for (final shape in ['missing', 'no-match', 'empty-value', 'nonempty']) {
        test('n5 source-derived retention json=$json shape=$shape', () async {
          final source = sourceMap(json);
          final info = source['ruleBookInfo'] as Map;
          if (shape == 'no-match') {
            info.addAll(<String, String>{
              'kind': json ? r'$.missing' : '.missing@text',
              'coverUrl': json ? r'$.missing' : '.missing@href',
            });
          } else if (shape == 'empty-value') {
            info.addAll(<String, String>{
              'kind': '@js:[]',
              'coverUrl': "{{''}}",
            });
          } else if (shape == 'nonempty') {
            info.addAll(<String, String>{
              'kind': json ? r'$.kind' : '.kind@text',
              'coverUrl': json ? r'$.cover' : '.cover@href',
            });
          }
          final pages = _HttpPages({
            '/book': json
                ? '{"kind":"new-kind","cover":"/new.png"}'
                : '<span class="kind">new-kind</span><a class="cover" href="/new.png"></a>',
            '/toc': tocBody(json),
          });
          final hit = HtmlBook(
            url: Uri.parse('$origin/book'),
            title: 'old',
            kind: 'old-kind',
            cover: '$origin/old.png',
            rawAddress: '$origin/book',
          );
          final pipeline = makePipeline(json, source, pages, SourceHostState());
          final (book, _) = await pipeline.details(hit);
          expect(
            [book.kind, book.cover],
            [
              shape == 'nonempty' ? 'new-kind' : hit.kind,
              shape == 'nonempty' ? '$origin/new.png' : hit.cover,
            ],
          );
          expect(book.rawAddress, hit.rawAddress);
          expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
          expect(pages.requests.every((r) => r.method == 'GET'), isTrue);
          pipeline.cancel();
        });
      }
    }
  });
}

void _registerFallbackGetCase() {
  const origin = 'https://fallback-get.test';
  final rows = _loadFixtureList('fallback-get-case-fixtures.json');
  final golden = _loadGolden('fallback-get-case-host');

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'ruleBookInfo': <String, String>{
      'name': '',
      'tocUrl': "{{'$origin/toc'}}",
    },
    'ruleToc': <String, String>{
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  BookSourcePipeline makePipeline(
    bool json,
    Map<String, dynamic> source,
    _HttpPages pages,
    SourceHostState state,
  ) => json
      ? JsonSourcePipeline(source, pages, hostState: state)
      : HtmlSourcePipeline(source, pages, hostState: state);

  String tocBody(bool json) => json
      ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
      : '<li><a href="/chapter">chapter</a></li>';

  group('fallback publication and GET marker case supported caller', () {
    for (final row in rows) {
      test('${row['name']} reaches actual pipeline getters', () async {
        final json = row['pipeline'] == 'json';
        final h1 = row['stage'] == 'h1';
        final source = sourceMap(json);
        final state = SourceHostState();
        await _seedVars(state, origin, row['seed'] as Map);
        final observed = golden[row['name']] as Map;
        if (h1) {
          (source['ruleBookInfo'] as Map)['tocUrl'] =
              '@js:${jsonEncode(row['baseAddress'])}';
          (source['ruleToc'] as Map).addAll(<String, String>{
            'chapterList': row['listRule'] as String,
            'chapterName': row['nameRule'] as String,
            'chapterUrl': row['urlRule'] as String,
            'updateTime': row['tagRule'] as String,
            'isVolume': row['volumeRule'] as String,
            'isVip': row['vipRule'] as String,
            'isPay': row['payRule'] as String,
          });
        } else if (row['form'] == 'list') {
          (source['ruleBookInfo'] as Map)['kind'] = row['rule'] as String;
        } else {
          (source['ruleToc'] as Map)['updateTime'] = row['rule'] as String;
          if (row['shape'] == 'mixed-url') {
            (source['ruleToc'] as Map)['chapterUrl'] = row['rule'] as String;
          }
        }
        final pages = _HttpPages({
          '/book': h1 || row['form'] != 'list'
              ? (json ? '{}' : '<p>book</p>')
              : row['content'] as String,
          '/toc': h1 ? row['content'] as String : tocBody(json),
        }, responses: h1 ? {'/toc': row['redirectUrl'] as String} : const {});
        final pipeline = makePipeline(json, source, pages, state);
        Object? failure;
        HtmlBook? book;
        List<SourceChapter>? chapters;
        try {
          final (b, c) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          book = b;
          chapters = c;
        } catch (error) {
          failure = error;
        }
        final variables = {
          for (final key in (observed['sourceVariables'] as Map).keys)
            '$key': await _savedVar(state, origin, '$key'),
        };
        if (row['error'] == true) {
          expect(observed['errorType'], 'com.script.ScriptException');
          expect(
            {
              'category': failure is SourceScriptError
                  ? failure.category
                  : '$failure',
              'field':
                  failure is SourceScriptError &&
                  failure.message.contains('ruleToc.isPay'),
              'message':
                  failure is SourceScriptError &&
                  failure.message.contains('fallback-pay'),
              'variables': variables,
            },
            {
              'category': 'js',
              'field': true,
              'message': true,
              'variables': observed['sourceVariables'],
            },
          );
        } else {
          expect(failure, isNull);
          if (h1) {
            final items = (observed['items'] as List).cast<Map>();
            expect(
              {
                'chapters': [
                  for (final c in chapters!)
                    {
                      'name': c.name.codeUnits,
                      'address': c.rawAddress!.codeUnits,
                      'tag': (c.tag ?? '').codeUnits,
                      'volume': '${c.isVolume}'.codeUnits,
                      'vip': '${c.isVip}'.codeUnits,
                      'pay': '${c.isPay}'.codeUnits,
                    },
                ],
                'variables': variables,
              },
              {'chapters': items, 'variables': observed['sourceVariables']},
            );
            for (final c in chapters) {
              final target = switch (row['shape']) {
                'raw-options' => '$origin/chapter?slot=1',
                // The ordinary empty fallback uses the declared TOC address,
                // not the redirect destination (BookChapterList.kt).
                'redirect-options' =>
                  (row['baseAddress'] as String).split(',{').first,
                _ => row['redirectUrl'] as String,
              };
              expect(c.url, Uri.parse(target));
              if (row['shape'] == 'redirect-options') {
                expect(c.progressKey, target);
                expect(c.persistedAddress, row['baseAddress']);
              }
            }
          } else {
            final expected = (observed['items'] as List).single as Map;
            expect(
              {
                'value':
                    (row['form'] == 'list'
                            ? book!.kind
                            : chapters!.single.tag ?? '')
                        ?.codeUnits,
                'variables': variables,
              },
              {
                'value': expected['value'],
                'variables': observed['sourceVariables'],
              },
            );
            if (row['shape'] == 'mixed-url') {
              expect(
                chapters!.single.rawAddress,
                _unitsText(expected['value']),
              );
              expect(
                chapters.single.url,
                Uri.parse(
                  '$origin/toc',
                ).resolve(_unitsText(expected['value'])),
              );
            }
          }
        }
        final address = h1
            ? (row['baseAddress'] as String).split(',{').first
            : '$origin/toc';
        expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
          ['GET', '$origin/book'],
          ['GET', address],
        ]);
        if (row['shape'] == 'redirect-options') {
          expect(pages.requests.last.headers['X-Toc'], 'original');
        }
        pipeline.cancel();
      });
    }

    for (final json in [false, true]) {
      for (final rule in ['@GET:title', '@GeT:MiXeD|@GET:mixed']) {
        test(
          'H2 bare marker extension control json=$json rule=$rule',
          () async {
            final state = SourceHostState();
            await _seedVars(state, origin, {'MiXeD': 'UP', 'mixed': 'lower'});
            final source = sourceMap(json);
            (source['ruleToc'] as Map)['updateTime'] = rule;
            final pages = _HttpPages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': tocBody(json),
            });
            final pipeline = makePipeline(json, source, pages, state);
            final (_, chapters) = await pipeline.details(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
            );
            expect(
              chapters.single.tag,
              rule == '@GET:title' ? 'chapter' : 'UP|lower',
            );
            _expectRequests(pages, origin, ['/book', '/toc']);
            pipeline.cancel();
          },
        );
      }
    }

    test(
      'H2 case-insensitive scalar preflight retains list regex put and malformed gates',
      () {
        expect(
          () => JsonSourceRules.validate('/@GET:{title}'),
          returnsNormally,
        );
        expect(() => JsonSourceRules.validate('@GeT:{MiXeD}'), returnsNormally);
        expect(
          () => JsonSourceRules.validate('/@GET:{title}', forList: true),
          throwsUnsupportedError,
        );
        expect(
          () => JsonSourceRules.validate('@GET:{title}', forList: true),
          returnsNormally,
        );
        for (final rule in [
          '/@GET:',
          '/##@GET:{title}##x',
          '/##x##@GeT:{title}',
          '@put:{"v":"@GET:MiXeD"}/',
        ]) {
          expect(() => JsonSourceRules.validate(rule), throwsUnsupportedError);
        }
      },
    );
  });
}

void _registerIntroTail() {
  const origin = 'http://rules.test';
  const selectedParagraphIntro = 'A\u00A0\u00A0B\nCD\n&';
  const paragraphIntroRows = {
    'intro-json-string',
    'intro-json-map',
    'intro-html-node',
    'intro-html-string',
  };
  final cases = _loadFixtureList('intro-tail-fixtures.json');
  final golden = _loadGolden('intro-tail-host');

  List<int> introExpectation(String name, Map observed) =>
      paragraphIntroRows.contains(name)
      ? selectedParagraphIntro.codeUnits
      : (observed['formattedUnits'] as List).cast<int>();

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {
      'bookList': json ? r'$.items' : '.result',
      'name': json ? r'$.name' : 'a@text',
      'bookUrl': json ? r'$.path' : 'a@href',
    },
    'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
    'ruleToc': {
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  group('executed intro scalar tail', () {
    test(
      'product intro formatter matches the selected empty-indent outputs',
      () {
        for (final row in cases) {
          final observed = golden[row['name']] as Map;
          final getter = String.fromCharCodes(
            (observed['getterUnits'] as List).cast<int>(),
          );
          expect(
            formatSourceIntro(getter).codeUnits,
            introExpectation(row['name'] as String, observed),
            reason: '${row['name']}',
          );
        }
      },
    );

    test('html adapter gate uses the same actual String scalar tail', () async {
      final row = cases.singleWhere(
        (row) => row['name'] == 'intro-html-string',
      );
      final actual = await html_gate.htmlAdapterRuleFieldValue(
        row['content'] as String,
        row['rule'] as String,
        baseUrl: '$origin/book',
      );
      expect(
        actual.codeUnits,
        ((golden[row['name']] as Map)['getterUnits'] as List).cast<int>(),
      );
    });

    for (final row in cases) {
      test('${row['name']} at the true String/node/map caller', () async {
        final json = row['pipeline'] == 'json';
        final source = sourceMap(json);
        final rule = row['rule'] as String;
        final content = row['content'] as String;
        final observed = golden[row['name']] as Map;
        final state = SourceHostState();
        final HtmlBook book;
        if (row['stage'] == 'toc') {
          (source['ruleToc'] as Map).addAll(<String, String>{
            'chapterList': '.result',
            'chapterName': rule,
            'chapterUrl': 'a@href',
          });
          final (_, chapters) = await HtmlSourcePipeline(
            source,
            _StringPages({'/book': '<p>book</p>', '/toc': content}),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
          expect(
            chapters.single.name.codeUnits,
            (observed['getterUnits'] as List).cast<int>(),
          );
          return;
        }
        if (row['stage'] == 'title') {
          source['ruleContent'] = {'content': '.sr-intro@text', 'title': rule};
          final body = await HtmlSourcePipeline(
            source,
            _StringPages({'/chapter': content}),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$origin/chapter')));
          expect(
            body.title!.codeUnits,
            (observed['getterUnits'] as List).cast<int>(),
          );
          return;
        }
        if (row['unescape'] == false) {
          source['ruleContent'] = {'content': rule};
          final body = await HtmlSourcePipeline(
            source,
            _StringPages({'/chapter': content}),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$origin/chapter')));
          expect(
            body.text.codeUnits,
            formatContentPage(
              String.fromCharCodes(
                (observed['getterUnits'] as List).cast<int>(),
              ),
            ).codeUnits,
          );
          return;
        }
        if (row['type'] == 'string') {
          (source['ruleBookInfo'] as Map).addAll(<String, String>{
            'author': rule,
            'intro': rule,
          });
          final pages = _StringPages({
            '/book': content,
            '/toc': json
                ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                : '<li><a href="/chapter">chapter</a></li>',
          });
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final result = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          book = result.$1;
        } else {
          if (row['url'] == true) {
            (source['ruleSearch'] as Map)['bookUrl'] = rule;
          } else if (row['form'] == 'list') {
            (source['ruleSearch'] as Map)['kind'] = rule;
          } else {
            (source['ruleSearch'] as Map).addAll(<String, String>{
              'author': rule,
              'intro': rule,
            });
          }
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(
                  source,
                  _StringPages({'/search': content}),
                  hostState: state,
                )
              : HtmlSourcePipeline(
                  source,
                  _StringPages({'/search': content}),
                  hostState: state,
                );
          book = (await pipeline.search('x')).single;
        }
        final actual = row['url'] == true
            ? book.rawAddress!
            : row['form'] == 'list'
            ? book.kind
            : book.author;
        expect(
          actual?.codeUnits,
          (observed['getterUnits'] as List).cast<int>(),
          reason: '${row['name']} getter',
        );
        if (row['url'] != true && row['form'] != 'list') {
          expect(
            book.intro.codeUnits,
            introExpectation(row['name'] as String, observed),
            reason: '${row['name']} formatted',
          );
        }
        expect(
          await state.entry(origin, sourceRuleVariableKey(origin, 'count')) ??
              '',
          observed['count'],
        );
      });
    }
  });
}

void _registerNextBookState() {
  const origin = 'https://next-book-state.test';
  final rows = _loadFixtureList('next-book-state-fixtures.json');
  final golden = _loadGolden('next-book-state-host');

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'/toc'}}"},
    'ruleToc': <String, String>{
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  BookSourcePipeline makePipeline(
    bool json,
    Map<String, dynamic> source,
    _HttpPages pages,
    SourceHostState state,
  ) => json
      ? JsonSourcePipeline(source, pages, hostState: state)
      : HtmlSourcePipeline(source, pages, hostState: state);

  String tocBody(bool json, String name) => json
      ? jsonEncode({
          'list': [
            {'name': name, 'href': '/$name'},
          ],
        })
      : '<li><a href="/$name">$name</a></li>';

  group('next getter and supported Book metadata caller controls', () {
    for (final row in rows) {
      test('${row['name']} actual next completes before item', () async {
        final json = row['pipeline'] == 'json';
        final state = SourceHostState();
        final source = sourceMap(json);
        (source['ruleToc'] as Map).addAll(<String, String>{
          'chapterList': row['listRule'] as String,
          'chapterName': row['nameRule'] as String,
          'chapterUrl': row['urlRule'] as String,
          'nextTocUrl': row['nextRule'] as String,
        });
        final pages = _HttpPages({
          '/book': json ? '{}' : '<p>book</p>',
          '/toc': row['content'] as String,
        });
        final pipeline = makePipeline(json, source, pages, state);
        final observed = golden[row['name']] as Map;
        Object? failure;
        List<SourceChapter>? chapters;
        try {
          final (_, result) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          chapters = result;
        } catch (error) {
          failure = error;
        }
        final variables = {
          for (final key in (observed['variables'] as Map).keys)
            '$key': await _savedVar(state, origin, '$key'),
        };
        if (row['error'] == true) {
          expect(observed['errorType'], 'com.script.ScriptException');
          expect(
            {
              'category': failure is SourceScriptError
                  ? failure.category
                  : '$failure',
              'nextLabel':
                  failure is SourceScriptError &&
                  failure.message.contains('ruleToc.nextTocUrl'),
              'message':
                  failure is SourceScriptError &&
                  failure.message.contains('next-before-item'),
              'variables': variables,
            },
            {
              'category': 'js',
              'nextLabel': true,
              'message': true,
              'variables': observed['variables'],
            },
          );
        } else if ('${row['shape']}'.startsWith('zero-')) {
          expect(
            failure,
            isA<SourceStageDiagnostic>()
                .having(
                  (error) => error.stage,
                  'stage',
                  BookSourceStage.tableOfContents,
                )
                .having(
                  (error) => error.kind,
                  'failure kind',
                  SourceStageFailureKind.extractionFailed,
                )
                .having(
                  (error) => error.address,
                  'safe address',
                  '$origin/toc',
                )
                .having(
                  (error) => error.httpResponse?.statusCode,
                  'HTTP status',
                  200,
                )
                .having(
                  (error) => error.httpResponse?.bodyByteLength,
                  'unknown byte count',
                  isNull,
                ),
            reason:
                'Existing empty-TOC policy remains; next/state must complete first',
          );
          expect(variables, observed['variables']);
        } else {
          expect(failure, isNull);
          expect(
            {
              'chapters': [
                for (final chapter in chapters!)
                  {
                    'name': chapter.name.codeUnits,
                    'address': chapter.rawAddress!.codeUnits,
                  },
              ],
              'variables': variables,
            },
            {
              'chapters': observed['chapters'],
              'variables': observed['variables'],
            },
          );
          for (final chapter in chapters) {
            expect(
              chapter.url,
              Uri.parse('$origin/toc').resolve(chapter.rawAddress!),
            );
          }
        }
        expect(observed['next'], isEmpty);
        _expectRequests(pages, origin, ['/book', '/toc']);
        pipeline.cancel();
      });
    }

    for (final json in [false, true]) {
      test(
        'F1 declared pages skip next getter and retain URL/options json=$json',
        () async {
          final state = SourceHostState();
          final source = sourceMap(json);
          (source['ruleToc'] as Map)['nextTocUrl'] =
              '@js:java.put("nextCount",String(Number(java.get("nextCount")||"0")+1));if(java.get("nextCount")!=="1")throw new Error("declared-must-skip-next");[\'/toc-b?slot=2,{"headers":{"X-Page":"B"}}\',\'/toc-c?slot=3\']';
          final pages = _HttpPages({
            '/book': json ? '{}' : '<p>book</p>',
            '/toc': tocBody(json, 'one'),
            '/toc-b': tocBody(json, 'two'),
            '/toc-c': tocBody(json, 'three'),
          });
          final pipeline = makePipeline(json, source, pages, state);
          final (_, chapters) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          expect(chapters.map((c) => c.name), ['one', 'two', 'three']);
          expect(await _savedVar(state, origin, 'nextCount'), '1');
          _expectRequests(pages, origin, [
            '/book',
            '/toc',
            '/toc-b?slot=2',
            '/toc-c?slot=3',
          ]);
          expect(pages.requests[2].headers['X-Page'], 'B');
          pipeline.cancel();
        },
      );

      for (final shape in ['update', 'rename-retained', 'empty', 'no-match']) {
        test(
          'F2 source-derived every detail metadata publication json=$json shape=$shape',
          () async {
            final state = SourceHostState();
            final source = sourceMap(json);
            final info = source['ruleBookInfo'] as Map;
            final update = shape == 'update' || shape == 'rename-retained';
            final missing = json ? r'$.missing' : '.missing@text';
            String value(String text) => shape == 'no-match'
                ? "java.getString('$missing')"
                : jsonEncode(text);
            info.addAll(<String, String>{
              'name': update ? "{{'new-name'}}" : "{{''}}",
              'author': update ? "{{'new-author'}}" : "{{''}}",
              'kind': update
                  ? "{{'new-kind'}}"
                  : shape == 'no-match'
                  ? missing
                  : '@js:[]',
              'wordCount':
                  "@js:java.put('seenKind',book.kind);${value(update
                      ? '12000'
                      : shape == 'empty'
                      ? '0'
                      : '')}",
              'lastChapter':
                  "@js:java.put('seenWord',book.wordCount);${value(update ? 'new-last' : '')}",
              'intro':
                  "@js:java.put('seenLast',book.latestChapterTitle);${value(update ? '<p>new intro</p>' : '')}",
              'coverUrl':
                  "@js:java.put('seenIntro',book.intro);${value(update ? '/new.png' : '')}",
              'tocUrl':
                  "@js:java.put('seenCover',book.coverUrl);java.put('seenBook',JSON.stringify([book.name,book.author,book.kind,book.wordCount,book.latestChapterTitle,book.intro,book.coverUrl,book.bookUrl]));java.put('tocCount',String(Number(java.get('tocCount')||'0')+1));'/toc?page=1'",
              if (shape == 'update') 'canReName': 'yes',
            });
            const raw = '/book?keep=1,{"headers":{"X-Detail":"retained"}}';
            final hit = HtmlBook(
              url: Uri.parse('$origin/book?keep=1'),
              preOptionUrl: Uri.parse('$origin/book?keep=1'),
              rawAddress: raw,
              title: 'old-name',
              author: 'old-author',
              kind: 'old-kind',
              wordCount: 'old-word',
              lastChapter: 'old-last',
              intro: 'old-intro',
              cover: '$origin/old.png',
            );
            final pages = _HttpPages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': tocBody(json, 'chapter'),
            });
            final pipeline = makePipeline(json, source, pages, state);
            final (book, _) = await pipeline.details(hit);
            final finalFields = [
              book.title,
              book.author,
              book.kind,
              book.wordCount,
              book.lastChapter,
              book.intro,
              book.cover,
              '$origin$raw',
            ];
            expect(finalFields.take(5).toList(), [
              shape == 'update' ? 'new-name' : hit.title,
              shape == 'update' ? 'new-author' : hit.author,
              update ? 'new-kind' : hit.kind,
              update ? '1.2万字' : hit.wordCount,
              update ? 'new-last' : hit.lastChapter,
            ]);
            expect(book.cover, update ? '$origin/new.png' : hit.cover);
            if (update) {
              expect(book.intro, isNot(hit.intro));
            } else {
              expect(book.intro, hit.intro);
            }
            expect(
              [
                for (final key in [
                  'seenKind',
                  'seenWord',
                  'seenLast',
                  'seenIntro',
                  'seenCover',
                ])
                  await _savedVar(state, origin, key),
              ],
              [
                book.kind,
                book.wordCount,
                book.lastChapter,
                book.intro,
                book.cover,
              ],
            );
            expect(
              jsonDecode(await _savedVar(state, origin, 'seenBook')),
              finalFields,
            );
            expect(await _savedVar(state, origin, 'tocCount'), '1');
            expect(book.url, hit.url);
            expect(book.rawAddress, raw);
            _expectRequests(pages, origin, ['/book?keep=1', '/toc?page=1']);
            expect(pages.requests.first.headers['X-Detail'], 'retained');
            pipeline.cancel();
          },
        );
      }
    }
  });
}

void _registerReadContext() {
  const origin = 'https://context-rules.test';
  final cases = _loadFixtureList('read-context-fixtures.json');
  final golden = _loadGolden('read-context-host');

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {
      'bookList': json ? r'$.items' : 'li',
      'name': json ? r'$.name' : 'a@text',
      'bookUrl': json ? r'$.path' : 'a@href',
    },
    'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
    'ruleToc': {
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  String? bookValue(HtmlBook book, String field) => switch (field) {
    'name' => book.title,
    'author' => book.author,
    'kind' => book.kind,
    'wordCount' => book.wordCount,
    'lastChapter' => book.lastChapter,
    'intro' => book.intro,
    'coverUrl' => book.cover.isEmpty ? '' : Uri.parse(book.cover).path,
    _ => throw StateError('Unexpected field $field'),
  };

  group('executed read-context regression', () {
    for (final row in cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} at the actual read caller', () async {
        final name = row['name'] as String;
        final observed = golden[name] as Map;
        final state = SourceHostState();
        final json = row['pipeline'] == 'json';
        final source = sourceMap(json);
        final content = row['content'] as String;
        final rule = row['rule'] as String?;
        final items = (observed['items'] as List).cast<Map>();
        final tocBody = json
            ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
            : '<li><a href="/chapter">chapter</a></li>';
        if (row['error'] == true) {
          (source['ruleBookInfo'] as Map)['author'] = rule;
          final pipeline = JsonSourcePipeline(
            source,
            _StringPages({'/book': content}, recordPathOnly: true),
            hostState: state,
          );
          var cancellationMarkerReached = false;
          if (row['cancelled'] == true) {
            pipeline.onHostMessage = (_) {
              cancellationMarkerReached = true;
              pipeline.cancel();
            };
          }
          await expectLater(
            pipeline.details(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
            ),
            throwsA(
              isA<SourceScriptError>().having(
                (error) =>
                    row['cancelled'] == true ? error.category : error.message,
                'failure',
                contains(row['cancelled'] == true ? 'cancelled' : 'read-context'),
              ),
            ),
          );
          if (row['cancelled'] == true) {
            expect(cancellationMarkerReached, isTrue);
          }
        } else if (row['stage'] == 'info') {
          final info = source['ruleBookInfo'] as Map;
          for (final read in (row['reads'] as List).cast<Map>()) {
            info[read['field']] = read['rule'];
          }
          final pages = _StringPages({
            '/book': content,
            '/toc': tocBody,
            '/bad': tocBody,
          }, recordPathOnly: true);
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (book, _) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          for (final read in (items.single['reads'] as List).cast<Map>()) {
            final value = read['field'] == 'tocUrl'
                ? pages.requests.last
                : bookValue(book, read['field'] as String);
            expect(
              value?.codeUnits,
              _readUnits(read).codeUnits,
              reason: '$name ${read['field']}',
            );
          }
        } else if (row['stage'] == 'toc') {
          final toc = source['ruleToc'] as Map;
          toc['chapterList'] = row['listRule'] ?? 'li';
          if (row['reads'] != null) {
            for (final read in (row['reads'] as List).cast<Map>()) {
              toc[read['field']] = read['rule'];
            }
          } else {
            toc['updateTime'] = rule;
          }
          final (_, chapters) = await HtmlSourcePipeline(
            source,
            _StringPages({
              '/book': '<p>book</p>',
              '/toc': content,
            }, recordPathOnly: true),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
          expect(chapters, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            for (final read in (items[i]['reads'] as List).cast<Map>()) {
              final chapter = chapters[i];
              final value = switch (read['field']) {
                'chapterName' => chapter.name,
                'chapterUrl' => chapter.rawAddress!,
                'isVolume' => '${chapter.isVolume}',
                'isVip' => '${chapter.isVip}',
                'isPay' => '${chapter.isPay}',
                _ => chapter.tag ?? '',
              };
              expect(
                value.codeUnits,
                _readUnits(read).codeUnits,
                reason: '$name item=$i ${read['field']}',
              );
            }
          }
        } else if (row['type'] == 'node' || row['stage'] == 'search') {
          final search = source['ruleSearch'] as Map;
          search['bookList'] = row['listRule'] ?? row['selector'] ?? 'li';
          final list = row['form'] == 'list';
          search[list ? 'kind' : 'author'] = rule;
          final books = await HtmlSourcePipeline(
            source,
            _StringPages({'/search': content}, recordPathOnly: true),
            hostState: state,
          ).search('x');
          expect(books, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            final read = (items[i]['reads'] as List).single as Map;
            expect(
              (list ? books[i].kind : books[i].author)?.codeUnits,
              _readUnits(read).codeUnits,
              reason: '$name item=$i',
            );
          }
        } else if (row['unescape'] == false) {
          source['ruleContent'] = {'content': rule};
          final body = await JsonSourcePipeline(
            source,
            _StringPages({'/chapter': content}, recordPathOnly: true),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$origin/chapter')));
          expect(
            body.text.codeUnits,
            formatContentPage(
              _readUnits((items.single['reads'] as List).single as Map),
            ).codeUnits,
          );
        } else {
          (source['ruleBookInfo'] as Map)['author'] = rule;
          final pages = _StringPages({
            '/book': content,
            '/toc': tocBody,
          }, recordPathOnly: true);
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (book, _) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'old'),
          );
          expect(
            book.author.codeUnits,
            _readUnits((items.single['reads'] as List).single as Map).codeUnits,
          );
        }
        for (final entry in (observed['variables'] as Map).entries) {
          expect(
            await state.entry(
                  origin,
                  sourceRuleVariableKey(origin, '${entry.key}'),
                ) ??
                '',
            entry.value,
            reason: '$name variable=${entry.key}',
          );
        }
      });
    }

    for (final json in [false, true]) {
      test('existing detail name/author retention (json=$json)', () async {
        final source = sourceMap(json);
        (source['ruleBookInfo'] as Map).addAll(<String, String>{
          'name': "{{'new'}}",
          'author': "{{'new-author'}}",
          'canReName': '',
        });
        final pages = _StringPages({
          '/book': json ? '{}' : '<p>book</p>',
          '/toc': json
              ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
              : '<li><a href="/chapter">chapter</a></li>',
        }, recordPathOnly: true);
        final BookSourcePipeline pipeline = json
            ? JsonSourcePipeline(source, pages)
            : HtmlSourcePipeline(source, pages);
        final original = HtmlBook(
          url: Uri.parse('$origin/book'),
          title: 'retained',
          author: 'retained-author',
        );
        final (book, _) = await pipeline.details(original);
        expect(book.title, original.title);
        expect(book.author, original.author);
      });
    }
  });
}

void _registerRelativeFallback() {
  const origin = 'https://fallback-get.test';
  final rows = _loadFixtureList('relative-fallback-fixtures.json');
  final golden = _loadGolden('relative-fallback-host');

  String body(bool json, String name, String address) => json
      ? jsonEncode({
          'list': [
            {'name': name, 'href': address},
          ],
        })
      : '<li><a href="$address">$name</a></li>';

  group('relative auxiliary and H1 fallback controls', () {
    for (final json in [false, true]) {
      test(
        'ordinary empty chapter keeps published raw query json=$json',
        () async {
          const toc = '/toc?q=书';
          final pages = _HttpPages({
            '/book': json
                ? jsonEncode({'title': 'book', 'toc': toc})
                : '<h2>book</h2><a id="toc" href="$toc">toc</a>',
            '/toc': json
                ? jsonEncode({
                    'list': [
                      {'name': 'chapter', 'href': ''},
                    ],
                  })
                : '<ul id="list"><li><a href="">chapter</a></li></ul>',
          });
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'ruleBookInfo': {
              'name': json ? r'$.title' : 'h2@text',
              'tocUrl': json ? r'$.toc' : 'a@href',
            },
            'ruleToc': {
              'chapterList': json ? r'$.list' : 'li',
              'chapterName': json ? r'$.name' : 'a@text',
              'chapterUrl': json ? r'$.href' : 'a@href',
            },
          };
          final pipeline = json
              ? JsonSourcePipeline(source, pages)
              : HtmlSourcePipeline(source, pages);
          final (_, chapters) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book'), title: 'book'),
          );
          expect(chapters.single.address, '$origin/toc?q=书');
          expect(pages.requests.last.url.toString(), '$origin/toc?q=%E4%B9%A6');
          pipeline.cancel();
        },
      );

      for (final row in rows) {
        test('H1 ${row['name']} actual relative fallback json=$json', () async {
          final next = row['stage'] == 'next';
          final relative = row['relative'] as String;
          final expected = golden[row['name']] as Map;
          final absolute = _unitsText(expected['baseAddress']);
          final targetPath = Uri.parse(absolute.split(',{').first).path;
          final state = SourceHostState();
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'ruleBookInfo': <String, String>{
              'name': '',
              'tocUrl': '@js:${jsonEncode(next ? row['inputBase'] : relative)}',
            },
            'ruleToc': <String, String>{
              'chapterList': json ? r'$.list' : 'li',
              'chapterName': json ? r'$.name' : 'a@text',
              'chapterUrl': json ? r'$.href' : 'a@href',
              'updateTime': "@js:source.put('before',String(chapter.url));'tag'",
              'isVolume': "{{'false'}}",
              'isVip': "@js:source.put('vip',String(chapter.url));'true'",
              if (next)
                'nextTocUrl':
                    "@js:source.put('nextReads',String(Number(source.get('nextReads')||'0')+1));source.get('nextReads')==='1'?${jsonEncode([relative])}:[]",
            },
          };
          final pages = _HttpPages(
            {
              '/book': json ? '{}' : '<p>book</p>',
              if (next) '/dir/start': body(json, 'first', '/first'),
              targetPath: body(json, 'chapter', ''),
            },
            responses: {targetPath: row['responseUrl'] as String},
          );
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (_, chapters) = await pipeline.details(
            HtmlBook(url: Uri.parse('$origin/book?book=1'), title: 'book'),
          );
          final before = await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'before'),
          );
          final vip = await state.entry(
            origin,
            sourceRuleVariableKey(origin, 'vip'),
          );
          final target = absolute.split(',{').first;
          final expectedUrls = [
            '$origin/book?book=1',
            if (next) row['inputBase'] as String,
            target,
          ];
          expect(
            {
              'beforeUnits': '$before'.codeUnits,
              'vipUnits': '$vip'.codeUnits,
              'requests': pages.requests
                  .map((r) => [r.method, '${r.url}'])
                  .toList(),
              'header': pages.requests.last.headers['X-Relative'],
            },
            {
              'beforeUnits': expected['beforeFallback'],
              'vipUnits': expected['vipUrl'],
              'requests': [
                for (final url in expectedUrls) ['GET', url],
              ],
              'header': row['options'] == true ? 'keep' : null,
            },
          );
          final chapter = chapters.last;
          expect(chapter.rawAddress, absolute);
          expect(chapter.url, Uri.parse(target));
          expect(chapter.progressKey, target);
          expect(chapter.persistedAddress, absolute);
          expect(chapter.name, 'chapter');
          if (next) {
            expect(
              await state.entry(
                origin,
                sourceRuleVariableKey(origin, 'nextReads'),
              ),
              '2',
            );
          }
          pipeline.cancel();
        });
      }
    }
  });
}

void _registerReview() {
  const origin = 'https://review-rules.test';
  const single = '<ul><li><a href="/book">body</a></li></ul>';
  final cases = _loadFixtureList('review-fixtures.json');
  final golden = _loadGolden('review-host');

  Map<String, dynamic> htmlSource({String name = 'a@text'}) => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {'bookList': 'li', 'name': name, 'bookUrl': 'a@href'},
    'ruleContent': {'content': '.content@text'},
  };

  Map<String, dynamic> jsonSource() => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {
      'bookList': r'$.items',
      'name': r'$.name',
      'bookUrl': r'$.path',
    },
    'ruleBookInfo': {'name': r'$.name', 'tocUrl': r'$.toc', 'canReName': 'yes'},
    'ruleToc': {
      'chapterList': r'$.list',
      'chapterName': r'$.name',
      'chapterUrl': r'$.href',
    },
  };

  List<String> valuesOf(String name) => [
    for (final units in (golden[name] as Map)['values'] as List? ?? const [])
      units == null ? 'null' : String.fromCharCodes((units as List).cast<int>()),
  ];
  String valueOf(String name) => valuesOf(name).single;
  String joinedOf(String name) =>
      String.fromCharCodes(((golden[name] as Map)['joinedUnits'] as List).cast<int>());
  Map caseRow(String name) => cases.singleWhere((row) => row['name'] == name);

  String? kindAfterDetails(String name) {
    final values = (golden[name] as Map)['values'] as List?;
    if (const {
      'kind-map-blank',
      'native-object-list',
      'native-number-list',
      'native-boolean-list',
      'native-null-list',
    }.contains(name)) {
      expect(values, isNull, reason: '$name frozen list read');
      expect(joinedOf(name), isEmpty, reason: '$name harness null fallback');
    }
    if (values == null) return null;
    final joined = joinedOf(name);
    return joined.isEmpty ? null : joined;
  }

  Future<HtmlBook> detailField(Map row, {bool kind = false}) async {
    final type = row['type'] ?? 'string';
    final body = row['content'] as String? ?? '<p>body</p>';
    final rule = row['rule'] as String;
    if (type == 'string') {
      final source = htmlSource();
      source['ruleBookInfo'] = {
        'name': '',
        kind ? 'kind' : 'author': rule,
        'tocUrl': r"{{'/toc'}}",
        'canReName': 'yes',
      };
      source['ruleToc'] = {
        'chapterList': 'li',
        'chapterName': 'a@text',
        'chapterUrl': 'a@href',
      };
      final (book, _) = await HtmlSourcePipeline(
        source,
        _StringPages({
          '/book': body,
          '/toc': '<li><a href="/chapter">chapter</a></li>',
        }, recordPathOnly: true),
      ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
      return book;
    }
    final source = jsonSource();
    (source['ruleBookInfo'] as Map).addAll(<String, String>{
      kind ? 'kind' : 'author': rule,
      'init': type == 'nativeObject'
          ? '@js:($body)'
          : type == 'list'
          ? r'$.list'
          : r'$.item',
      'tocUrl': r"{{'/toc'}}##unused##unused",
    });
    final (book, _) = await JsonSourcePipeline(
      source,
      _StringPages({
        '/book': body,
        '/toc': jsonEncode({
          'list': [
            {'name': 'chapter', 'href': '/chapter'},
          ],
        }),
      }, recordPathOnly: true),
    ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
    return book;
  }

  group('executed typed rule-field differential', () {
    test(
      'all 252 exported members and numeric outcomes match in UTF-16 units',
      () {
        final names = golden.keys
            .where((key) => '$key'.startsWith('table:'))
            .toList();
        expect(names, hasLength(252));
        final checks = [
          ...names,
          ...golden.keys.where((key) => '$key'.startsWith('entity-')),
        ];
        for (final name in checks) {
          final row = golden[name] as Map;
          final input = String.fromCharCodes(
            (row['contentUnits'] as List).cast<int>(),
          );
          if (row['error'] == null) {
            expect(
              unescapeHtml4(input).codeUnits,
              ((row['values'] as List).single as List).cast<int>(),
              reason: '$name',
            );
          } else {
            expect(
              row['error'],
              startsWith('java.lang.IllegalArgumentException:'),
            );
            expect(
              () => unescapeHtml4(input),
              throwsRangeError,
              reason: '$name',
            );
          }
        }
      },
    );

    for (final type in ['string', 'map', 'list', 'nativeObject']) {
      for (final shape in [
        'empty-replacement',
        'sole-expression',
        'mixed-expression',
      ]) {
        final name = '$type-$shape';
        test('$name uses the actual scalar caller type', () async {
          final book = await detailField(caseRow(name));
          expect(book.author.codeUnits, valueOf(name).codeUnits);
        });
      }
    }
    for (final name in [
      'original-@@',
      'original-@json:',
      'original-@xpath:',
      'post-script',
      'single-pass',
      'native-object-scalar',
    ]) {
      test('$name through a scalar author field', () async {
        expect((await detailField(caseRow(name))).author, valueOf(name));
      });
    }
    for (final name in [
      'kind-string-named',
      'kind-map-named',
      'kind-string-blank',
      'kind-map-blank',
      'kind-string-replacement',
      'kind-map-replacement',
      'kind-string-js-list',
      'kind-map-js-list',
      'native-object-list',
      'native-array-list',
    ]) {
      test('$name executes list then Kotlin join boundary', () async {
        expect(
          (await detailField(caseRow(name), kind: true)).kind,
          kindAfterDetails(name),
        );
      });
    }

    test(
      'NativeArray scalar keeps the observed format mismatch explicit',
      () async {
        const prefix = 'org.mozilla.javascript.NativeArray@';
        expect(valueOf('native-array-scalar'), startsWith(prefix));
        expect(valueOf('native-array-scalar/repeat'), startsWith(prefix));
        final actual =
            (await detailField(caseRow('native-array-scalar'))).author;
        expect(actual, isNot(startsWith(prefix)));
      },
    );

    for (final name in [
      'node-string-scalar-entity',
      'node-string-before-scalar',
      'map-script-string',
      'list-script-string',
    ]) {
      test('node/container serialization differential $name', () async {
        final row = caseRow(name);
        final String actual;
        if (row['type'] == 'node') {
          final source = htmlSource();
          (source['ruleSearch'] as Map)['author'] = row['rule'];
          actual = (await HtmlSourcePipeline(
            source,
            _StringPages({'/search': row['content'] as String}, recordPathOnly: true),
          ).search('x')).single.author;
        } else {
          actual = (await detailField(row)).author;
        }
        final expected = valueOf(name);
        if (name.startsWith('node-') ||
            Platform.environment['LIBER_REQUIRE_RULE_FIELD_PARITY'] == '1') {
          expect(actual.codeUnits, expected.codeUnits);
        } else {
          expect(actual.codeUnits, isNot(expected.codeUnits));
        }
      });
    }
    for (final name in [
      'node-raw-double',
      'node-raw-script-style',
      'collection-raw-double',
      'collection-raw-script-style',
      'collection-raw-empty',
    ]) {
      test(
        '$name keeps raw outer serialization before any scalar tail',
        () async {
          final row = caseRow(name);
          final chosen = row['type'] == 'node' ? 'nodes[0]' : 'nodes';
          final code =
              '@js: var nodes = Jsoup.parse(result).select("li"); '
              'var text = String($chosen); var units = []; '
              'for(var i=0;i<text.length;i++) units.push(text.charCodeAt(i)); '
              'JSON.stringify(units);';
          final actual = (await detailField(<String, Object?>{
            'type': 'string',
            'content': row['content'],
            'rule': code,
          })).author;
          expect(
            (jsonDecode(actual) as List).cast<int>(),
            valueOf(name).codeUnits,
          );
        },
      );
    }
    for (final property in ['number', 'boolean', 'null']) {
      for (final form in ['scalar', 'list']) {
        final name = 'native-$property-$form';
        test('$name retains its actual primitive caller boundary', () async {
          final book = await detailField(
            caseRow(name),
            kind: form == 'list',
          );
          expect(
            form == 'list' ? book.kind : book.author,
            form == 'list' ? kindAfterDetails(name) : valueOf(name),
          );
        });
      }
    }

    test(
      'known raw-init NativeObject String(result) uses its key boundary',
      () async {
        expect(
          (await detailField(caseRow('nativeObject-script-string'))).author,
          valueOf('nativeObject-script-string'),
        );
      },
    );

    for (final name in ['url-toc-sibling', 'url-toc-empty-script']) {
      test(
        '$name runs scalar URL before existing address resolution',
        () async {
          final source = jsonSource();
          (source['ruleBookInfo'] as Map)['tocUrl'] = caseRow(name)['rule'];
          final target = Uri.parse(valueOf(name));
          final body = jsonEncode({
            'name': 'body',
            'list': [
              {'name': 'chapter', 'href': '/chapter'},
            ],
          });
          final pages = _StringPages({
            '/book': body,
            '/ok': jsonEncode({
              'list': [
                {'name': 'chapter', 'href': '/chapter'},
              ],
            }),
          }, recordPathOnly: true);
          final pipeline = JsonSourcePipeline(source, pages);
          final hit = HtmlBook(url: Uri.parse('$origin/book'), title: 'old');
          final HtmlBook book;
          final List<SourceChapter> chapters;
          if (name == 'url-toc-empty-script') {
            expect(target, hit.url);
            final info = await pipeline.bookInfo(hit);
            expect(info.tocHtml, body);
            (book, chapters) = await pipeline.tableOfContents(info);
            expect(pages.requests, ['/book']);
          } else {
            (book, chapters) = await pipeline.details(hit);
            expect(pages.requests, ['/book', target.path]);
          }
          expect(book.title, 'body');
          expect(chapters, hasLength(1));
        },
      );
    }

    test(
      'per-node interpolation runs exactly once against each actual item',
      () async {
        final state = SourceHostState();
        final row = caseRow('item-sequence');
        final hits = await HtmlSourcePipeline(
          htmlSource(name: row['rule'] as String),
          _StringPages({'/search': row['content'] as String}, recordPathOnly: true),
          hostState: state,
        ).search('x');
        expect(hits.map((hit) => hit.title).toList(), valuesOf('item-sequence'));
        expect(
          await state.entry(origin, sourceRuleVariableKey(origin, 'count')),
          (golden['item-sequence'] as Map)['count'],
        );
      },
    );

    test('all sibling scripts preserve order and execute once', () async {
      final state = SourceHostState();
      final hit = (await HtmlSourcePipeline(
        htmlSource(name: caseRow('multiple-siblings-count')['rule'] as String),
        _StringPages({'/search': single}, recordPathOnly: true),
        hostState: state,
      ).search('x')).single;
      expect(hit.title, valueOf('multiple-siblings-count'));
      expect(
        await state.entry(origin, sourceRuleVariableKey(origin, 'count')),
        (golden['multiple-siblings-count'] as Map)['count'],
      );
    });

    test('cancellation reaches the literal expression runtime', () async {
      expect(
        (golden['cancelled-expression'] as Map)['error'],
        startsWith('kotlinx.coroutines.JobCancellationException:'),
      );
      await expectLater(
        HtmlSourcePipeline(
          htmlSource(name: caseRow('cancelled-expression')['rule'] as String),
          _StringPages({'/search': single}, recordPathOnly: true),
          scriptRuntime: _CancelAtExpression(),
        ).search('x'),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.category,
            'category',
            'cancelled',
          ),
        ),
      );
    });

    for (final json in [false, true]) {
      test(
        'content leaves its scalar entity tail disabled (json=$json)',
        () async {
          final rule = caseRow('content-false')['rule'] as String;
          final source = json ? jsonSource() : htmlSource();
          source['ruleContent'] = {'content': rule};
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(
                  source,
                  _StringPages({'/chapter': '{"content":"body"}'}, recordPathOnly: true),
                )
              : HtmlSourcePipeline(
                  source,
                  _StringPages({'/chapter': '<div>body</div>'}, recordPathOnly: true),
                );
          final body = await pipeline.chapter(
            SourceChapter('chapter', Uri.parse('$origin/chapter')),
          );
          expect(body.text, formatContentPage(valueOf('content-false')));
        },
      );
    }
  });

  group('controller #93 review reproduction', () {
    for (final row in const {
      r"{{'@@h1@text'}}": 'generated-@@h1@text',
      r"{{'@json:$.name'}}": 'generated-@json',
      r"{{'@xpath://p'}}": 'generated-@xpath',
    }.entries) {
      test('expression-generated mode head ${row.value}', () async {
        final hit = (await HtmlSourcePipeline(
          htmlSource(name: row.key),
          _StringPages({'/search': single}, recordPathOnly: true),
        ).search('x')).single;
        expect(hit.title, valueOf(row.value));
      });
    }

    for (final row in const <String, String>{
      '{{null}}##': 'empty-regex',
      r"{{'body'}}####X": 'zero-width',
    }.entries) {
      test('empty replacement regex ${row.key}', () async {
        final source = htmlSource();
        (source['ruleContent'] as Map)['title'] = row.key;
        final body = await HtmlSourcePipeline(
          source,
          _StringPages({'/chapter': '<div class="content">body</div>'}, recordPathOnly: true),
        ).chapter(SourceChapter('original', Uri.parse('$origin/chapter')));
        final expected = valueOf(row.value);
        expect(body.title, expected.isEmpty ? null : expected);
      });
    }

    test(
      'JSON root keeps actual response text for empty literal replacement',
      () async {
        final source = jsonSource();
        (source['ruleBookInfo'] as Map)['name'] = '{{null}}##name##title';
        final original = jsonEncode({'name': 'body', 'toc': '/toc'});
        final (book, _) = await JsonSourcePipeline(
          source,
          _StringPages({
            '/book': original,
            '/toc': jsonEncode({
              'list': [
                {'name': 'chapter', 'href': '/chapter'},
              ],
            }),
          }, recordPathOnly: true),
        ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
        expect(book.title, valueOf('empty-nonempty-regex'));
      },
    );

    test('DOM descriptor does not become scalar field text', () async {
      final source = htmlSource(name: '{{null}}##body##title');
      (source['ruleSearch'] as Map)['bookList'] = 'li @js:result';
      final hit = (await HtmlSourcePipeline(
        source,
        _StringPages({'/search': single}, recordPathOnly: true),
      ).search('x')).single;
      expect(hit.title, valueOf('node-empty-replacement'));
      expect(hit.title, isNot(contains('__dom')));
      expect(hit.title, isNot(contains('__rule')));
    });

    test(
      'ordinary scalar literal receives final HTML4 entity unescape',
      () async {
        final hit = (await HtmlSourcePipeline(
          htmlSource(name: r"{{'A &amp; B'}}"),
          _StringPages({'/search': single}, recordPathOnly: true),
        ).search('x')).single;
        expect(hit.title, valueOf('scalar-entity'));
      },
    );

    test(
      'interpolation result is resolved for each actual HTML item',
      () async {
        final source = htmlSource(
          name: r"{{String(result).indexOf('完结') >= 0 ? '完结' : '连载'}}",
        );
        final hits = await HtmlSourcePipeline(
          source,
          _StringPages({
            '/search':
                '<ul><li><a href="/one">完结</a></li>'
                '<li><a href="/two">连载</a></li></ul>',
          }, recordPathOnly: true),
        ).search('x');
        expect(hits.map((hit) => hit.title).toList(), valuesOf('item-sequence'));
      },
    );

    test('JSON scalar URL runs interpolation before sibling JS', () async {
      final source = jsonSource();
      (source['ruleSearch'] as Map)['bookUrl'] =
          r"{{'/book'}} @js: result.trim() == '/book' ? '/ok' : '/bad'";
      final hit = (await JsonSourcePipeline(
        source,
        _StringPages({
          '/search': jsonEncode({
            'items': [
              {'name': 'body', 'path': '/book'},
            ],
          }),
        }, recordPathOnly: true),
      ).search('x')).single;
      expect(hit.url, Uri.parse(valueOf('url-sibling')));
    });

    test('empty HTML scalar URL uses analysis base URL', () async {
      final source = htmlSource();
      (source['ruleSearch'] as Map)['bookUrl'] = '{{null}}';
      final hit = (await HtmlSourcePipeline(
        source,
        _StringPages({'/search': single}, recordPathOnly: true),
      ).search('x')).single;
      expect(hit.url, Uri.parse(valueOf('url-empty')));
    });

    for (final json in [false, true]) {
      test('kind uses frozen string-list join (json=$json)', () async {
        final source = json ? jsonSource() : htmlSource();
        (source['ruleSearch'] as Map)['kind'] = r"{{'甲\n乙'}}";
        final BookSourcePipeline pipeline = json
            ? JsonSourcePipeline(
                source,
                _StringPages({
                  '/search': jsonEncode({
                    'items': [
                      {'name': 'body', 'path': '/book'},
                    ],
                  }),
                }, recordPathOnly: true),
              )
            : HtmlSourcePipeline(
                source,
                _StringPages({'/search': single}, recordPathOnly: true),
              );
        final hit = (await pipeline.search('x')).single;
        expect(
          hit.kind,
          joinedOf(json ? 'kind-map-multiline' : 'kind-node-multiline'),
        );
      });
    }
  });
}

void _registerScalarTail() {
  const origin = 'https://review-rules.test';
  final cases = _loadFixtureList('scalar-tail-fixtures.json');
  final golden = _loadGolden('scalar-tail-host');

  Map<String, dynamic> sourceMap() => {
    'bookSourceUrl': origin,
    'searchUrl': '/search',
    'ruleSearch': {'bookList': 'li', 'name': 'a@text', 'bookUrl': 'a@href'},
    'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
    'ruleToc': {
      'chapterList': 'li',
      'chapterName': 'a@text',
      'chapterUrl': 'a@href',
    },
  };

  String expectedOf(Map row) {
    final observed = golden[row['name']] as Map;
    final units = row['form'] == 'list'
        ? observed['joinedUnits'] as List
        : (observed['values'] as List).single as List;
    return String.fromCharCodes(units.cast<int>());
  }

  group('executed script-only scalar tail', () {
    for (final row in cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} at the actual scalar/list/content caller', () async {
        final source = sourceMap();
        final state = SourceHostState();
        final rule = row['rule'] as String;
        final content = row['content'] as String? ?? '<p>body</p>';
        final list = row['form'] == 'list';
        final String? actual;
        if (row['type'] == 'node') {
          (source['ruleSearch'] as Map)[list ? 'kind' : 'author'] = rule;
          final book = (await HtmlSourcePipeline(
            source,
            _StringPages({'/search': content}, recordPathOnly: true),
            hostState: state,
          ).search('x')).single;
          actual = list ? book.kind : book.author;
        } else if (row['unescape'] == false) {
          source['ruleContent'] = {'content': rule};
          final body = await HtmlSourcePipeline(
            source,
            _StringPages({'/chapter': content}, recordPathOnly: true),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$origin/chapter')));
          actual = body.text;
        } else {
          (source['ruleBookInfo'] as Map)[list ? 'kind' : 'author'] = rule;
          final (book, _) = await HtmlSourcePipeline(
            source,
            _StringPages({
              '/book': content,
              '/toc': '<li><a href="/chapter">chapter</a></li>',
            }, recordPathOnly: true),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$origin/book'), title: 'old'));
          actual = list ? book.kind : book.author;
        }
        final expected = row['unescape'] == false
            ? formatContentPage(expectedOf(row))
            : expectedOf(row);
        expect(actual?.codeUnits, expected.codeUnits, reason: '${row['name']}');
        if (row['name'] == 'literal-sibling-count') {
          expect(
            await state.entry(origin, sourceRuleVariableKey(origin, 'count')),
            (golden[row['name']] as Map)['count'],
          );
        }
      });
    }
  });
}

void _registerTocChapterBinding() {
  const origin = 'https://toc-binding.test';
  final rows = _loadFixtureList('toc-chapter-binding-fixtures.json');
  final golden = _loadGolden('toc-chapter-binding-host');

  Map<String, dynamic> sourceMap(bool json) => {
    'bookSourceUrl': origin,
    'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'/toc'}}"},
    'ruleToc': <String, String>{
      'chapterList': json ? r'$.list' : 'li',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.href' : 'a@href',
    },
  };

  BookSourcePipeline makePipeline(
    bool json,
    Map<String, dynamic> source,
    _HttpPages pages,
    SourceHostState state,
  ) => json
      ? JsonSourcePipeline(source, pages, hostState: state)
      : HtmlSourcePipeline(source, pages, hostState: state);

  String pageBody(bool json, String name, {List<String> next = const []}) =>
      json
      ? jsonEncode({
          'list': [
            {'name': name, 'href': '/$name'},
          ],
          'next': next,
        })
      : '<li><a href="/$name">$name</a></li>${next.map((n) => '<a class="next" href=\'$n\'>next</a>').join()}';

  String encoded(String rule) => 'String.fromCharCode(${rule.codeUnits.join(',')})';

  group(
    'supported TOC chapter binding actual getters and source lifetime controls',
    () {
      group('G1 scalar preflight boundaries', () {
        test('mixed and pure scalar title variables are literal values', () {
          expect(
            () => JsonSourceRules.validate('/@get:{title}'),
            returnsNormally,
          );
          expect(
            () => JsonSourceRules.validate('@get:{title}'),
            returnsNormally,
          );
        });
        test(
          'mixed element-list rule retains refusal and pure token old allowance',
          () {
            expect(
              () => JsonSourceRules.validate('/@get:{title}', forList: true),
              throwsUnsupportedError,
            );
            expect(
              () => JsonSourceRules.validate('@get:{title}', forList: true),
              returnsNormally,
            );
          },
        );
        test('replacement tokens do not hide malformed extraction', () {
          for (final rule in ['/##@get:{title}##x', '/##x##@get:{title}']) {
            expect(() => JsonSourceRules.validate(rule), throwsUnsupportedError);
          }
        });
        test('put alone does not hide malformed extraction', () {
          expect(
            () => JsonSourceRules.validate('@put:{"v":"seed"}/'),
            throwsUnsupportedError,
          );
        });
        test('incomplete get and plain malformed rules remain refused', () {
          for (final rule in ['/@get:', '/', 'a b', 'a.b', '1name']) {
            expect(() => JsonSourceRules.validate(rule), throwsUnsupportedError);
          }
          expect(() => JsonSourceRules.validate('name'), returnsNormally);
        });
        test('a getter inside put is not a top-level literal getter', () {
          expect(
            () => JsonSourceRules.validate('@put:{"v":"@get:title"}/'),
            throwsUnsupportedError,
          );
        });
      });

      for (final row in rows) {
        test('${row['name']} real item chapter/title publication', () async {
          final json = row['pipeline'] == 'json';
          final source = sourceMap(json);
          (source['ruleToc'] as Map).addAll(<String, String>{
            'chapterList': row['listRule'] as String,
            'chapterName': row['nameRule'] as String,
            'chapterUrl': row['urlRule'] as String,
            'updateTime': row['tagRule'] as String,
            'isVolume': row['volumeRule'] as String,
            'isVip': row['vipRule'] as String,
            'isPay': row['payRule'] as String,
          });
          final state = SourceHostState();
          await state.putEntry(
            origin,
            sourceRuleVariableKey(origin, 'title'),
            'stored',
          );
          final pages = _HttpPages({
            '/book': json ? '{}' : '<p>book</p>',
            '/toc': row['content'] as String,
          });
          final pipeline = makePipeline(json, source, pages, state);
          final observed = golden[row['name']] as Map;
          Object? failure;
          List<SourceChapter>? chapters;
          try {
            final (_, result) = await pipeline.details(
              HtmlBook(url: Uri.parse('$origin/book'), title: 'book'),
            );
            chapters = result;
          } catch (error) {
            failure = error;
          }
          final variables = {
            for (final key in (observed['sourceVariables'] as Map).keys)
              '$key': await _savedVar(state, origin, '$key'),
          };
          if (row['error'] == true) {
            expect(observed['errorType'], 'com.script.ScriptException');
            expect(
              {
                'category': failure is SourceScriptError
                    ? failure.category
                    : '$failure',
                'field':
                    failure is SourceScriptError &&
                    failure.message.contains('ruleToc.chapterUrl'),
                'message':
                    failure is SourceScriptError &&
                    failure.message.contains('toc-url-binding'),
                'sourceVariables': variables,
              },
              {
                'category': 'js',
                'field': true,
                'message': true,
                'sourceVariables': observed['sourceVariables'],
              },
            );
          } else {
            expect(failure, isNull);
            expect(
              {
                'items': [
                  for (final chapter in chapters!)
                    {
                      'name': chapter.name.codeUnits,
                      'address': chapter.rawAddress!.codeUnits,
                      'tag': (chapter.tag ?? '').codeUnits,
                    },
                ],
                'sourceVariables': variables,
              },
              {
                'items': observed['items'],
                'sourceVariables': observed['sourceVariables'],
              },
            );
            for (final chapter in chapters) {
              final target = chapter.rawAddress!.split(',{').first;
              expect(chapter.url, Uri.parse('$origin/toc').resolve(target));
            }
          }
          _expectRequests(pages, origin, ['/book', '/toc']);
          pipeline.cancel();
        });
      }

      for (final json in [false, true]) {
        for (final declared in [false, true]) {
          test(
            'G1 source-derived per-page list/next has no previous chapter json=$json declared=$declared',
            () async {
              final state = SourceHostState();
              await state.putEntry(
                origin,
                sourceRuleVariableKey(origin, 'title'),
                'stored',
              );
              final source = sourceMap(json);
              final stamp =
                  "JSON.stringify([chapter===null,title===null,java.get('title'),java.getString(${encoded('@get:{title}')})])";
              final listPut = jsonEncode({
                'listSeen':
                    "@js:source.put('listTrace',source.get('listTrace')+$stamp+';');'list'",
              }).replaceAll('@js:', r'\u0040js:');
              final nextPath = json ? r'$.next[*]' : 'a.next@href';
              final nextScript =
                  "@js:source.put('nextTrace',source.get('nextTrace')+$stamp+';');source.put('nextCount',String(Number(source.get('nextCount')||'0')+1));java.getStringList('$nextPath')";
              (source['ruleToc'] as Map).addAll(<String, String>{
                'chapterList': '@put:$listPut${json ? r'$.list' : 'li'}',
                'updateTime': '@get:{title}',
                'nextTocUrl': nextScript,
              });
              const nextB = '/toc-b?slot=2,{"headers":{"X-Page":"B"}}';
              const nextC = '/toc-c?slot=3';
              final pages = _HttpPages({
                '/book': json ? '{}' : '<p>book</p>',
                '/toc': pageBody(
                  json,
                  'one',
                  next: declared ? [nextB, nextC] : [nextB],
                ),
                '/toc-b': pageBody(json, 'two'),
                '/toc-c': pageBody(json, 'three'),
              });
              final pipeline = makePipeline(json, source, pages, state);
              final (_, chapters) = await pipeline.details(
                HtmlBook(url: Uri.parse('$origin/book'), title: 'book'),
              );
              const initial = '[true,true,"stored","stored"];';
              final expectedAddresses = declared
                  ? ['/book', '/toc', '/toc-b?slot=2', '/toc-c?slot=3']
                  : ['/book', '/toc', '/toc-b?slot=2'];
              expect(
                {
                  'chapters': chapters.map((c) => [c.name, c.tag]).toList(),
                  'listTrace': await _savedVar(state, origin, 'listTrace'),
                  'nextTrace': await _savedVar(state, origin, 'nextTrace'),
                  'nextCount': await _savedVar(state, origin, 'nextCount'),
                  'requests': pages.requests
                      .map((r) => [r.method, '${r.url}'])
                      .toList(),
                  'pageHeader': pages.requests[2].headers['X-Page'],
                },
                {
                  'chapters': declared
                      ? [
                          ['one', 'one'],
                          ['two', 'two'],
                          ['three', 'three'],
                        ]
                      : [
                          ['one', 'one'],
                          ['two', 'two'],
                        ],
                  'listTrace': List.filled(declared ? 3 : 2, initial).join(),
                  'nextTrace': List.filled(declared ? 1 : 2, initial).join(),
                  'nextCount': declared ? '1' : '2',
                  'requests': [
                    for (final address in expectedAddresses)
                      ['GET', '$origin$address'],
                  ],
                  'pageHeader': 'B',
                },
              );
              pipeline.cancel();
            },
          );
        }

        test(
          'G1 source-derived supplied empty Uri keeps normal snapshot json=$json',
          () async {
            final state = SourceHostState();
            final source = sourceMap(json);
            source['header'] =
                '@js:source.put("emptySnapshot",JSON.stringify([chapter.url,chapter.title,title]));"{}"';
            source['ruleContent'] = <String, String>{'content': '@js:result'};
            final pages = _HttpPages({});
            final pipeline = makePipeline(json, source, pages, state);
            Object? failure;
            try {
              await pipeline.chapter(
                SourceChapter(
                  'provided-empty',
                  Uri(),
                  rawAddress: '$origin/provided',
                ),
                book: HtmlBook(url: Uri.parse('$origin/book'), title: 'book'),
              );
            } catch (error) {
              failure = error;
            }
            expect(
              failure,
              isA<StateError>().having(
                (e) => e.message,
                'fixture refusal',
                'Unexpected full request GET $origin/provided',
              ),
            );
            expect(
              await _savedVar(state, origin, 'emptySnapshot'),
              '["","provided-empty","provided-empty"]',
            );
            expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
              ['GET', '$origin/provided'],
            ]);
            pipeline.cancel();
          },
        );

        test(
          'G1 source-derived repeat details and provided content chapter stay separate json=$json',
          () async {
            final state = SourceHostState();
            await state.putEntry(
              origin,
              sourceRuleVariableKey(origin, 'title'),
              'stored',
            );
            final source = sourceMap(json);
            (source['ruleBookInfo'] as Map)['author'] =
                "@js:source.put('detailTrace',source.get('detailTrace')+JSON.stringify([chapter===null,title===null])+';');''";
            (source['ruleToc'] as Map)['updateTime'] = '@get:{title}';
            source['ruleContent'] = <String, String>{
              'content':
                  "@js:chapter.title+'|'+title+'|'+java.getString(${encoded('@get:{title}')})",
            };
            final pages = _HttpPages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': pageBody(json, 'toc-name'),
              '/provided': json ? '{}' : '<p>body</p>',
            });
            final pipeline = makePipeline(json, source, pages, state);
            final hit = HtmlBook(url: Uri.parse('$origin/book'), title: 'book');
            final (_, first) = await pipeline.details(hit);
            expect(first.single.tag, 'toc-name');
            final body = await pipeline.chapter(
              SourceChapter('provided', Uri.parse('$origin/provided')),
              book: hit,
            );
            expect(body.text, 'provided|provided|provided');
            final (_, second) = await pipeline.details(hit);
            expect(second.single.tag, 'toc-name');
            expect(
              await _savedVar(state, origin, 'detailTrace'),
              '[true,true];[true,true];',
            );
            _expectRequests(pages, origin, [
              '/book',
              '/toc',
              '/provided',
              '/book',
              '/toc',
            ]);
            pipeline.cancel();
          },
        );
      }
    },
  );
}
