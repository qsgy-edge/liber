import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/rule_field.dart';
import 'package:liber/source/source_host_state.dart';

import 'native_library.dart';

/// One rule field through both adapters' own entry points.
///
/// The frozen rule-field grammar — `@js:`, `<js>`, `{{...}}` interpolation,
/// `@get:key`, `@put:{json}` and the `##`/`###` fields — lives in
/// `lib/source/rule_field.dart`, and these rows prove the form from the
/// pipeline a page actually calls: `HtmlSourcePipeline.search/details/chapter`
/// over the Rust adapter, and `JsonSourcePipeline.search/…` over the bounded
/// JSON reader. A form neither engine can run is asserted as a refusal with its
/// reason, never as a value that quietly disappeared.

const _htmlUrl = 'http://rules.test';

/// The pages the HTML rows read: one search hit whose anchor text is the value
/// every rule below transforms.
const _pages = {
  '/search':
      '<div class="result"><a href="/book/1">回音</a><span class="sr-intro">搜索简介</span><span class="sr-last">搜索最新章</span><span class="sr-count">12001</span></div>',
  '/book/1':
      '<h1>回音</h1><div class="intro">简介</div><div class="info-word">23000</div><a class="toc" href="/toc/1">目录</a>',
  '/toc/1': '<div id="list"><a href="/chapter/1">第一章</a></div>',
  '/chapter/1':
      '<h2 class="chapter-title">正文标题</h2><div class="content">正文</div>',
};

class _HtmlPages implements BookSourceTransport {
  _HtmlPages([this.pages = _pages]);

  final Map<String, String> pages;
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    requests.add(target);
    return pages[target] ?? (throw StateError('Unexpected URL: $target'));
  }
}

Map<String, dynamic> _htmlSource({
  required String name,
  String content = '.content@text',
  String tocName = 'text',
  String kind = 'a.0@text',
}) => {
  'bookSourceUrl': _htmlUrl,
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': <String, dynamic>{
    'bookList': '.result',
    'name': name,
    'bookUrl': 'a.0@href',
    'kind': kind,
  },
  'ruleBookInfo': <String, dynamic>{'name': 'h1@text', 'tocUrl': '.toc@href'},
  'ruleToc': {
    'chapterList': '#list a',
    'chapterName': tocName,
    'chapterUrl': 'href',
  },
  'ruleContent': {'content': content},
};

/// The JSON rows read one replay body per path, exactly like the HTML rows.
class _JsonPages implements BookSourceTransport {
  final pages = <String, Map<String, Object?>>{};
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    requests.add(target);
    final body = pages[target];
    if (body == null) throw StateError('Unexpected URL: $target');
    return jsonEncode(body);
  }
}

Map<String, dynamic> _jsonSource({
  required String name,
  String content = r'$.content',
  String chapterName = r'$.label',
}) => {
  'bookSourceUrl': _jsonUrl,
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': <String, dynamic>{
    'bookList': r'$.items',
    'name': name,
    'bookUrl': r'$.path',
    'kind': r'$.kind',
  },
  'ruleBookInfo': <String, dynamic>{'name': r'$.title', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': chapterName,
    'chapterUrl': r'$.href',
  },
  'ruleContent': {'content': content},
};

const _jsonUrl = 'http://json-rules.test';
const _jsonPages = {
  '/search': {
    'items': [
      {
        'name': '回音',
        'path': '/book/1',
        'kind': '玄幻',
        'id': '7',
        'intro': '搜索简介',
        'lastChapter': '搜索最新章',
        'wordCount': '12001',
      },
    ],
  },
  '/book/1': {
    'title': '回音',
    'author': '作者',
    'toc': '/toc/1',
    'intro': '简介',
    'wordCount': '23000',
  },
  '/toc/1': {
    'list': [
      {'label': '第一章', 'href': '/chapter/1'},
    ],
  },
  '/chapter/1': {'content': '正文', 'title': '正文标题'},
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('frozen literal value reads', () {
    const oracle = 'tool/rule_field_oracle';
    const evidence = '$oracle/evidence/jvm-host';
    final cases =
        (jsonDecode(File('$oracle/fixtures.json').readAsStringSync()) as List)
            .cast<Map>();
    final golden =
        jsonDecode(File('$evidence/golden.json').readAsStringSync()) as Map;

    for (final format in ['html', 'xml', 'json']) {
      for (final row in cases) {
        final name = row['name'] as String;
        final frozen = golden['$format/$name'] as Map;
        if (frozen['error'] != null) continue;
        test(
          '$format/$name through search, detail and chapter value callers',
          () async {
            final rule = row['rule'] as String;
            final source = format == 'json'
                ? _jsonSource(name: r'$.name')
                : _htmlSource(name: 'a.0@text');
            (source['ruleSearch'] as Map)['author'] = rule;
            (source['ruleBookInfo'] as Map)['author'] = rule;
            (source['ruleBookInfo'] as Map)['canReName'] = 'yes';
            (source['ruleContent'] as Map)['title'] = rule;
            final BookSourcePipeline pipeline = format == 'json'
                ? JsonSourcePipeline(
                    source,
                    _JsonPages()..pages.addAll(_jsonPages),
                  )
                : HtmlSourcePipeline(
                    source,
                    _HtmlPages(
                      format == 'xml'
                          ? {
                              for (final entry in _pages.entries)
                                entry.key: '<root>${entry.value}</root>',
                            }
                          : _pages,
                    ),
                  );
            final hit = (await pipeline.search('关键字')).single;
            expect(hit.author, frozen['value']);
            final (book, _) = await pipeline.details(hit);
            expect(book.author, frozen['value']);
            final chapter = await pipeline.chapter(
              SourceChapter(
                '目录标题',
                Uri.parse(
                  '${format == 'json' ? _jsonUrl : _htmlUrl}/chapter/1',
                ),
              ),
            );
            expect(
              chapter.title,
              (frozen['value'] as String).isEmpty ? null : frozen['value'],
            );
          },
        );
      }
    }

    for (final json in [false, true]) {
      test(
        'literal values reach host reads, TOC and content (json=$json)',
        () async {
          final format = json ? 'json' : 'html';
          final literal =
              cases.singleWhere(
                    (row) => row['name'] == 'whole-non-selector',
                  )['rule']
                  as String;
          final content =
              cases.singleWhere(
                    (row) => row['name'] == 'whole-js-sibling',
                  )['rule']
                  as String;
          // Build the rule inside JS so outer script interpolation cannot consume
          // it before java.getString reaches the actual nested value-read caller.
          const name = '''@js:java.getString('{' + '{' + "'完结'" + '}' + '}')''';
          final source = json
              ? _jsonSource(name: name, chapterName: literal, content: content)
              : _htmlSource(name: name, tocName: literal, content: content);
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(
                  source,
                  _JsonPages()..pages.addAll(_jsonPages),
                )
              : HtmlSourcePipeline(source, _HtmlPages());
          final hit = (await pipeline.search('关键字')).single;
          expect(
            hit.title,
            (golden['$format/whole-non-selector'] as Map)['value'],
          );
          final (_, chapters) = await pipeline.details(hit);
          expect(chapters.single.name, hit.title);
          expect(
            (await pipeline.chapter(chapters.single)).text,
            (golden['$format/whole-js-sibling'] as Map)['value'],
          );
        },
      );
    }

    test('value application preserves expression count and failures', () async {
      var evaluations = 0;
      final failure = StateError('expression failure');
      final context = RuleFieldContext(
        evaluateScript: (script, result) async {
          evaluations++;
          if (script == 'fail') throw failure;
          return '完结';
        },
        extract: (_, _) async => throw StateError('unexpected extraction'),
        readVariable: (_) async => '',
        writeVariable: (_, _) async {},
      );
      final field = await RuleField.resolve(
        '{{value}}',
        context,
        content: 'page',
      );
      expect(evaluations, 1);
      expect(await field.apply('page', forValue: true), '完结');
      expect(evaluations, 1);
      await expectLater(
        RuleField.resolve('{{fail}}', context, content: 'page'),
        throwsA(same(failure)),
      );
      expect(evaluations, 2);
    });

    test(
      'an expression confined to replacement preserves selector extraction',
      () async {
        final rule =
            cases.singleWhere(
                  (row) => row['name'] == 'replacement-then-expression',
                )['rule']
                as String;
        final frozen = golden['html/replacement-then-expression'] as Map;
        expect(frozen['mode'], 'Default');
        expect(frozen['extraction'], 'a.0@text');
        final hit = (await HtmlSourcePipeline(
          _htmlSource(name: rule),
          _HtmlPages(),
        ).search('关键字')).single;
        expect(hit.title, 'new');
      },
    );
  });

  group('HTML adapter entry point', () {
    Future<HtmlBook> search(Map<String, dynamic> source) async {
      final pipeline = HtmlSourcePipeline(source, _HtmlPages());
      return (await pipeline.search('关键字')).single;
    }

    test(
      'a trailing @js: executes its value instead of being dropped',
      () async {
        final hit = await search(
          _htmlSource(name: r"a.0@text @js: result + '!'"),
        );
        expect(hit.title, '回音!');
      },
    );

    test('<js> runs its value and feeds the next segment nothing', () async {
      final hit = await search(
        _htmlSource(name: 'a.0@text<js>result + "?"</js>'),
      );
      expect(hit.title, '回音?');
    });

    test('a value segment and a script compose in order', () async {
      final hit = await search(
        _htmlSource(name: r'text.回音@href @js: result + "|" + result.length'),
      );
      expect(hit.title, '/book/1|7');
    });

    test('{{...}} interpolation resolves the frozen bindings', () async {
      final hit = await search(
        _htmlSource(name: r"a.0@text @js: '{{baseUrl}}' + '/' + '{{key}}'"),
      );
      expect(hit.title, '$_htmlUrl/关键字');
    });

    test('{{title}} binds the chapter title in the content stage', () async {
      final pipeline = HtmlSourcePipeline(
        _htmlSource(
          name: 'a.0@text',
          content: r".content@text @js: result + '<' + title + '>'",
        ),
        _HtmlPages(),
      );
      final (_, chapters) = await pipeline.details(
        (await pipeline.search('关键字')).single,
      );
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '正文<第一章>');
    });

    test('@put: writes a rule variable and @get: reads it back', () async {
      final hit = await search(
        _htmlSource(
          name: '@put:{"saved":"a.0@text"}a.0@text##回音##@get:{saved}',
        ),
      );
      expect(hit.title, '回音');
    });

    test('the ##/### fields keep their frozen meaning', () async {
      expect(
        (await search(_htmlSource(name: 'a.0@text##回音##回声##'))).title,
        '回声',
      );
      // The trailing `##` is a kept empty fourth field, so this is the frozen
      // `replaceFirst` branch: it answers with the replaced *match* only.
      expect(
        (await search(_htmlSource(name: 'a.0@text##回|音##X##'))).title,
        'X',
      );
      // The same branch explains `###`: `回|音` on 回音 replaces the first match
      // with itself, so the value is `X` and not the untouched 回音.
      expect(
        (await search(_htmlSource(name: 'a.0@text##回|音##X###'))).title,
        'X',
      );
    });

    test('an extraction after <js> is refused by name', () async {
      await expectLater(
        search(_htmlSource(name: 'a.0@text<js>"x"</js>@href')),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('<js>'),
          ),
        ),
      );
    });

    test('an unterminated <js> is refused by name', () async {
      await expectLater(
        search(_htmlSource(name: 'a.0@text<js>result')),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('</js>'),
          ),
        ),
      );
    });

    test(r'a $n capture reference is refused by name', () async {
      await expectLater(
        search(_htmlSource(name: r'tag.a$1@text')),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains(r'$n'),
          ),
        ),
      );
    });

    test('a script on an element-list rule runs with the body as result', () async {
      // #100: the frozen hands the element-list script the response body string
      // (`BookList.kt:50` `setContent(body)`); the extraction segment before it
      // selects the items, and the script answers them unchanged.
      final source = _htmlSource(name: 'a.0@text');
      (source['ruleSearch'] as Map)['bookList'] = r'.result @js: result';
      final hit = await HtmlSourcePipeline(source, _HtmlPages()).search(
        '关键字',
      );
      expect(hit.single.title, '回音');
    });

    test('{{...}} around a rule expression is refused by name', () async {
      await expectLater(
        search(_htmlSource(name: r'a.0@text @js: "{{@CSS:a@href}}"')),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('{{ }}'),
          ),
        ),
      );
    });

    test('a search runs on its own keyword whatever checkKeyWord holds', () async {
      // `ruleSearch.checkKeyWord` is a check keyword: the frozen readers of it
      // are the source check and the debug page's search box, so the search
      // stage must neither substitute it nor refuse a search because of it.
      for (final declared in <Object>[
        '校验词',
        42,
        <String>['not', 'a', 'string'],
        <String, Object>{'nested': 1},
      ]) {
        final source = _htmlSource(name: 'a.0@text');
        (source['ruleSearch'] as Map)['checkKeyWord'] = declared;
        final hit =
            (await HtmlSourcePipeline(source, _HtmlPages()).search('关键字')).single;
        expect(hit.title, '回音', reason: '$declared');
      }
    });
  });

  group('JSON adapter entry point', () {
    Future<HtmlBook> search(Map<String, dynamic> source) async {
      final transport = _JsonPages()..pages.addAll(_jsonPages);
      final pipeline = JsonSourcePipeline(source, transport);
      return (await pipeline.search('关键字')).single;
    }

    test(
      'a trailing @js: executes its value instead of being dropped',
      () async {
        final hit = await search(
          _jsonSource(name: r'$.name @js: result + "!"'),
        );
        expect(hit.title, '回音!');
      },
    );

    test('<js> runs its value', () async {
      final hit = await search(
        _jsonSource(name: r'$.name<js>result + "?"</js>'),
      );
      expect(hit.title, '回音?');
    });

    test('{{...}} interpolation resolves the frozen bindings', () async {
      final hit = await search(
        _jsonSource(name: r"$.name @js: '{{baseUrl}}' + '/' + '{{key}}'"),
      );
      expect(hit.title, '$_jsonUrl/关键字');
    });

    test(r'{{$.x}} in a literal rule stays a nested rule', () async {
      final hit = await search(_jsonSource(name: r'{{$.kind}}'));
      expect(hit.title, '玄幻');
    });

    test('@put: writes a rule variable and @get: reads it back', () async {
      final hit = await search(
        _jsonSource(name: r'@put:{"saved":"$.name"}$.name##回音##@get:{saved}'),
      );
      expect(hit.title, '回音');
    });

    test('the ##/### fields replace through the JSON reader', () async {
      expect(
        (await search(_jsonSource(name: r'$.name##回音##回声##'))).title,
        '回声',
      );
      // The trailing `##` keeps its empty fourth field, so the JSON reader runs
      // the frozen `replaceFirst` branch and answers with the replaced match.
      expect((await search(_jsonSource(name: r'$.name##回|音##X##'))).title, 'X');
      expect(
        (await search(_jsonSource(name: r'$.name##回|音##X###'))).title,
        'X',
      );
    });

    test('{{title}} binds the chapter title in the content stage', () async {
      final pipeline = JsonSourcePipeline(
        _jsonSource(
          name: r'$.name',
          content: r"$.content @js: result + '<' + title + '>'",
        ),
        _JsonPages()..pages.addAll(_jsonPages),
      );
      final hit = (await pipeline.search('关键字')).single;
      final (_, chapters) = await pipeline.details(hit);
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '正文<第一章>');
    });

    test('an extraction after <js> is refused by name', () async {
      // A `<js>` block at the end of the field is the whole remainder: legal.
      expect(
        (await search(_jsonSource(name: r'$.name<js> "x"</js>'))).title,
        'x',
      );
      await expectLater(
        search(_jsonSource(name: r'$.name<js>"x"</js>$.kind')),
        throwsA(isA<UnsupportedError>()),
      );
    });

    test(r'a $n capture reference is refused by name', () async {
      await expectLater(
        search(_jsonSource(name: r'$.name$1')),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains(r'$n'),
          ),
        ),
      );
    });

    test('a script on an element-list rule is refused by name', () async {
      final source = _jsonSource(name: r'$.name');
      (source['ruleSearch'] as Map)['bookList'] = r'$.items @js: result';
      await expectLater(
        JsonSourcePipeline(
          source,
          _JsonPages()..pages.addAll(_jsonPages),
        ).search('关键字'),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('列表规则'),
          ),
        ),
      );
    });

    test('JSON mode marker resolves, while an unreadable path is refused', () async {
      expect(
        (await search(_jsonSource(name: r'@jSoN:$.name'))).title,
        '回音',
      );
      await expectLater(
        search(_jsonSource(name: r'$.items[?(@.name=1)].name')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  // Frozen evidence: Legado baseline 14dd24945, BookList.kt:101-252
  // (search fields), BookInfo.kt:65-107 (canReName and wordCount),
  // BookContent.kt:64-72 (content title), and StringUtils.kt:252-266
  // (word-count formatting). The deterministic HTML/JSON replay bodies below
  // are the fixture for those frozen entry points. The intro and title-order
  // expectations follow the selected a7d37f1 behavior instead:
  // `HtmlFormatter.formatIntro` (empty paragraph indent) and the later
  // `BookContent.kt:65-69,169-182` title read after the joined body.
  group('remaining result fields', () {
    for (final json in [false, true]) {
      test('intro formatting and detail fallback (json=$json)', () async {
        final source = json
            ? _jsonSource(name: r'$.name')
            : _htmlSource(name: 'a.0@text');
        const raw = '<p>A&nbsp;&nbsp;B</p><p>C&thinsp;D</p><!--x-->&amp;';
        (source['ruleSearch'] as Map)['intro'] =
            '${json ? r'$.intro' : '.sr-intro@text'} @js:${jsonEncode(raw)}';
        final BookSourcePipeline pipeline = json
            ? JsonSourcePipeline(source, _JsonPages()..pages.addAll(_jsonPages))
            : HtmlSourcePipeline(source, _HtmlPages());
        final hit = (await pipeline.search('query')).single;
        // The selected `formatIntro` answer for `<p>A&nbsp;&nbsp;B</p><p>C&thinsp;D</p><!--x-->&amp;`
        // after the ordinary entity read: empty paragraph indent, U+00A0 kept.
        expect(hit.intro, 'A\u00A0\u00A0B\nCD\n&');
        final (book, _) = await pipeline.details(hit);
        expect(book.intro, hit.intro);
      });
      for (final blank in [false, true]) {
        test(
          'content scripts see the incoming chapter title before the later title read (json=$json, blank=$blank)',
          () async {
            final source = json
                ? _jsonSource(
                    name: r'$.name',
                    content:
                        r'$.content @js:title + ":" + chapter.title + ":" + result',
                  )
                : _htmlSource(
                    name: 'a.0@text',
                    content:
                        '.content@text @js:title + ":" + chapter.title + ":" + result',
                  );
            (source['ruleContent'] as Map)['title'] = blank
                ? '@js:"   "'
                : json
                ? r'$.title'
                : '.chapter-title@text';
            final BookSourcePipeline pipeline = json
                ? JsonSourcePipeline(
                    source,
                    _JsonPages()..pages.addAll(_jsonPages),
                  )
                : HtmlSourcePipeline(source, _HtmlPages());
            final result = await pipeline.chapter(
              SourceChapter(
                '目录标题',
                Uri.parse('${json ? _jsonUrl : _htmlUrl}/chapter/1'),
              ),
            );
            // The selected stage reads the title after the joined body
            // (`BookContent.kt:65-69,169-182`), so the body script sees the
            // incoming chapter title, and the extracted title is published
            // afterwards.
            expect(result.text, '目录标题:目录标题:正文');
            expect(result.title, blank ? null : '正文标题');
          },
        );
      }
    }
    test('word counts retain frozen Float and DecimalFormat rounding', () {
      // Executed on Temurin 17 with the frozen StringUtils expression.
      for (final row in {
        '10500': '1.1万字',
        '11500': '1.1万字',
        '12500': '1.2万字',
        '13500': '1.4万字',
        '14500': '1.4万字',
        '17500': '1.8万字',
        '16777217': '1677.7万字',
        '2147483647': '214748.4万字',
      }.entries) {
        expect(formatSourceWordCount(row.key), row.value, reason: row.key);
      }
      expect(() => formatSourceWordCount('2147483648'), throwsFormatException);
    });
    for (final rename in ['', '   ', 'yes']) {
      test(
        'detail fields preserve nonempty search values (rename=$rename)',
        () async {
          final source = _jsonSource(name: r'$.name');
          (source['ruleBookInfo'] as Map)['canReName'] = rename;
          final pipeline = JsonSourcePipeline(
            source,
            _JsonPages()..pages.addAll(_jsonPages),
          );
          final (book, _) = await pipeline.details(
            HtmlBook(
              url: Uri.parse('$_jsonUrl/book/1'),
              title: '搜索书名',
              author: '搜索作者',
              wordCount: '9万字',
              lastChapter: '搜索末章',
            ),
          );
          expect(book.title, rename.trim().isEmpty ? '搜索书名' : '回音');
          expect(book.author, '搜索作者');
          expect(book.wordCount, '9万字');
          expect(book.lastChapter, '搜索末章');
        },
      );
    }
    test(
      'detail fills an empty search author without rename permission',
      () async {
        final source = _jsonSource(name: r'$.name');
        (source['ruleBookInfo'] as Map)['author'] = r'$.author';
        final pipeline = JsonSourcePipeline(
          source,
          _JsonPages()..pages.addAll(_jsonPages),
        );
        final (book, _) = await pipeline.details(
          HtmlBook(url: Uri.parse('$_jsonUrl/book/1'), title: '搜索书名'),
        );
        expect(book.author, '作者');
      },
    );
    test(
      'HTML fields preserve frozen search, detail, rename, and title semantics',
      () async {
        final source = _htmlSource(name: 'a.0@text');
        (source['ruleSearch'] as Map).addAll(<String, dynamic>{
          'intro': '.sr-intro@text',
          'lastChapter': '.sr-last@text',
          'wordCount': '.sr-count@text',
          'checkKeyWord': '校验词',
        });
        (source['ruleBookInfo'] as Map).addAll(<String, dynamic>{
          'wordCount': '.info-word@text',
          'canReName': '允许改名',
        });
        (source['ruleContent'] as Map)['title'] = '.chapter-title@text';
        final pipeline = HtmlSourcePipeline(source, _HtmlPages());
        final hit = (await pipeline.search('关键字')).single;
        expect(
          (hit.intro, hit.lastChapter, hit.wordCount),
          ('搜索简介', '搜索最新章', '1.2万字'),
        );
        expect(sourceCheckKeyword(source, 'fallback'), '校验词');
        final (book, chapters) = await pipeline.details(
          HtmlBook(url: hit.url, title: '旧标题', author: '旧作者'),
        );
        expect(
          (book.title, book.author, book.wordCount),
          ('回音', '旧作者', '2.3万字'),
        );
        final body = await pipeline.chapter(chapters.single);
        expect(body.title, '正文标题');
      },
    );

    test(
      'JSON fields preserve frozen search, detail, rename, and title semantics',
      () async {
        final source = _jsonSource(name: r'$.name');
        (source['ruleSearch'] as Map).addAll(<String, dynamic>{
          'intro': r'$.intro',
          'lastChapter': r'$.lastChapter',
          'wordCount': r'$.wordCount',
          'checkKeyWord': '校验词',
        });
        (source['ruleBookInfo'] as Map).addAll(<String, dynamic>{
          'author': r'$.author',
          'wordCount': r'$.wordCount',
          'canReName': '允许改名',
        });
        (source['ruleContent'] as Map)['title'] = r'$.title';
        final pipeline = JsonSourcePipeline(
          source,
          _JsonPages()..pages.addAll(_jsonPages),
        );
        final hit = (await pipeline.search('关键字')).single;
        expect(
          (hit.intro, hit.lastChapter, hit.wordCount),
          ('搜索简介', '搜索最新章', '1.2万字'),
        );
        expect(sourceCheckKeyword(source, 'fallback'), '校验词');
        final (book, chapters) = await pipeline.details(
          HtmlBook(url: hit.url, title: '旧标题', author: '旧作者'),
        );
        expect(
          (book.title, book.author, book.wordCount),
          ('回音', '作者', '2.3万字'),
        );
        final body = await pipeline.chapter(chapters.single);
        expect(body.title, '正文标题');
      },
    );

    test('a scalar checkKeyWord is the frozen parse-layer coercion', () {
      // The frozen reader reads the field through Gson into `String?`: a JSON
      // scalar becomes its literal text while the source is parsed, and only an
      // array or object is refused. Executed on the handset for the numeric case
      // by the FIELDS-01 golden (`checkKeyword.number` -> "42").
      Map<String, dynamic> sourceWith(Object? value) => {
        'ruleSearch': <String, Object?>{'checkKeyWord': value},
      };
      expect(sourceCheckKeyword(sourceWith(42), 'fallback'), '42');
      expect(sourceCheckKeyword(sourceWith(0), 'fallback'), '0');
      expect(sourceCheckKeyword(sourceWith(1.0), 'fallback'), '1.0');
      expect(sourceCheckKeyword(sourceWith(true), 'fallback'), 'true');
      expect(sourceCheckKeyword(sourceWith('校验词'), 'fallback'), '校验词');
      expect(sourceCheckKeyword(sourceWith('   '), 'fallback'), 'fallback');
      expect(sourceCheckKeyword(sourceWith(''), 'fallback'), 'fallback');
      expect(sourceCheckKeyword(sourceWith(null), 'fallback'), 'fallback');
      expect(sourceCheckKeyword(const {}, 'fallback'), 'fallback');
      expect(
        sourceCheckKeyword(const <String, dynamic>{}, 'fallback'),
        'fallback',
      );
      for (final structured in <Object>[
        <Object>[42],
        <String, Object>{'nested': 1},
      ]) {
        expect(
          () => sourceCheckKeyword(sourceWith(structured), 'fallback'),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('ruleSearch.checkKeyWord'),
            ),
          ),
          reason: '$structured',
        );
      }
    });

    test('malformed optional fields fail with their field name', () async {
      final html = _htmlSource(name: 'a.0@text');
      (html['ruleSearch'] as Map)['intro'] = 42;
      await expectLater(
        HtmlSourcePipeline(html, _HtmlPages()).search('关键字'),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('ruleSearch.intro'),
          ),
        ),
      );
      final json = _jsonSource(name: r'$.name');
      // A simple bare name is json-path's canonical `$.name` and is read; the
      // shape this test keeps is one no supported form names.
      (json['ruleContent'] as Map)['title'] = 'a b';
      final pipeline = JsonSourcePipeline(
        json,
        _JsonPages()..pages.addAll(_jsonPages),
      );
      final hit = (await pipeline.search('关键字')).single;
      final (_, chapters) = await pipeline.details(hit);
      await expectLater(
        pipeline.chapter(chapters.single),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('ruleContent.title'),
          ),
        ),
      );
    });
  });

  group('shared rule-field parse', () {
    test('the ##/### fields follow the frozen split', () {
      expect(splitRuleFields('#a@text').rule, '#a@text');
      expect(splitRuleFields('#a@text').hasReplacement, isFalse);
      final two = splitRuleFields('a##x##');
      expect(
        (two.rule, two.regex, two.replacement, two.replaceFirst),
        ('a', 'x', '', false),
      );
      // Three delimiters are four fields: Kotlin's `split("##")` keeps the
      // trailing empty field, so `##` alone reaches the frozen `replaceFirst`.
      final trailing = splitRuleFields('a##x##y##');
      expect(
        (
          trailing.rule,
          trailing.regex,
          trailing.replacement,
          trailing.replaceFirst,
        ),
        ('a', 'x', 'y', true),
      );
      final four = splitRuleFields('a##x##y###');
      expect(
        (four.rule, four.regex, four.replacement, four.replaceFirst),
        ('a', 'x', 'y', true),
      );
    });

    test('a field is split into its extraction text and its scripts', () {
      final parts = parseRuleField(r'$.a @js: result');
      expect(parts.extractionRule, r'$.a');
      expect(parts.scripts, [' result']);
      expect(RuleField.extractionText('@js: result'), isNull);
      expect(RuleField.extractionText(''), '');
    });

    test('@put: must be a JSON string map', () {
      expect(() => parseRuleField('@put:{"a":1}'), returnsNormally);
      expect(() => RuleField.extractionText('@put:'), returnsNormally);
    });
  });

  _registerEmptyTocFallbackTests();
  _registerUrlScalarTests();
}

class _EmptyTocPages implements BookSourceTransport, SourceHttpTransport {
  _EmptyTocPages(this.body);
  final String body;
  final requests = <SourceHttpRequest>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('Real SourceHttpTransport.send required');

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: body,
      url: request.url,
    );
  }
}

void _registerEmptyTocFallbackTests() {
  const origin = 'https://fallback-get.test';

  group('empty-toc fallback controls', () {
    for (final json in [false, true]) {
      test(
        'empty declared TOC reuses the resolved book identity json=$json',
        () async {
          final body = json
              ? jsonEncode({
                  'list': [
                    {'name': 'chapter'},
                  ],
                })
              : '<h2>book</h2><ul id="list"><li><a href="">chapter</a></li></ul>';
          final pages = _EmptyTocPages(body);
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'ruleBookInfo': {
              'name': json ? r'$.title' : 'h2@text',
              'tocUrl': '',
            },
            'ruleToc': {
              'chapterList': json ? r'$.list' : 'li',
              'chapterName': json ? r'$.name' : 'a@text',
              'chapterUrl': "{{''}}",
            },
          };
          final pipeline = json
              ? JsonSourcePipeline(source, pages)
              : HtmlSourcePipeline(source, pages);
          final (_, chapters) = await pipeline.details(
            HtmlBook(
              url: Uri.parse('$origin/exact/book/1'),
              preOptionUrl: Uri.parse('$origin/exact/book/1'),
              rawAddress: 'book/1',
              title: 'book',
            ),
          );
          expect(chapters.single.name, 'chapter');
          expect(chapters.single.address, '$origin/exact/book/1');
          expect(pages.requests, hasLength(1));
          expect(pages.requests.single.url.path, '/exact/book/1');
          pipeline.cancel();
        },
      );

      test(
        'H1 first empty toc uses original Book address source control json=$json',
        () async {
          const rawBook =
              '$origin/book?keep=1,{"headers":{"X-Book":"fallback"}}';
          final state = SourceHostState();
          final source = <String, dynamic>{
            'bookSourceUrl': origin,
            'ruleBookInfo': <String, String>{'name': '', 'tocUrl': ''},
            'ruleToc': <String, String>{
              'chapterList': json ? r'$.list' : 'li',
              'chapterName': "{{'chapter'}}",
              'chapterUrl': "{{''}}",
              'updateTime':
                  "@js:source.put('trace',source.get('trace')+'tag:'+String(chapter.url)+';');'tag'",
              'isVolume':
                  "@js:source.put('trace',source.get('trace')+'volume:'+String(chapter.url)+';');'false'",
              'isVip':
                  "@js:source.put('trace',source.get('trace')+'vip:'+String(chapter.url)+';');String(chapter.url)!==''?'true':'false'",
              'isPay':
                  "@js:source.put('trace',source.get('trace')+'pay:'+String(chapter.url)+';');String(chapter.url)!==''?'true':'false'",
            },
          };
          final pages = _EmptyTocPages(
            json
                ? jsonEncode({
                    'list': [{}],
                  })
                : '<li>chapter</li>',
          );
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (_, chapters) = await pipeline.details(
            HtmlBook(
              url: Uri.parse('$origin/book?keep=1'),
              rawAddress: rawBook,
              title: 'book',
            ),
          );
          expect(
            await state.entry(origin, sourceRuleVariableKey(origin, 'trace')),
            'tag:;volume:;vip:$rawBook;pay:$rawBook;',
          );
          expect(chapters.map((c) => [c.name, c.isVip, c.isPay]).toList(), [
            ['chapter', true, true],
          ]);
          expect(chapters.single.url, Uri.parse('$origin/book?keep=1'));
          expect(
            pages.requests
                .map((r) => [r.method, '${r.url}', r.headers['X-Book']])
                .toList(),
            [
              ['GET', '$origin/book?keep=1', 'fallback'],
            ],
          );
          pipeline.cancel();
        },
      );
    }
  });
}

void _registerUrlScalarTests() {
  const origin = 'https://url-scalar.test';
  const ascending = '$origin/index/1/asc/1.html';
  const descending = '$origin/index/1/desc/1.html';
  const twoTocLinks =
      '<h1>book</h1>'
      '<a class="more" href="$ascending">正序目录</a>'
      '<a class="more" href="$descending">倒序目录</a>';

  HtmlBook retainedBook(String html) =>
      HtmlBook(url: Uri.parse('$origin/book/1'), title: 'book', infoHtml: html);

  group('frozen URL-mode scalar read', () {
    test(
      'the information TOC address is the first match of two links',
      () async {
        final pages = _HtmlPages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': origin,
          'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.more@href'},
        }, pages);
        final info = await pipeline.bookInfo(retainedBook(twoTocLinks));
        expect(info.tocAddress, ascending);
        expect(info.tocUrl, ascending);
        expect(pages.requests, isEmpty);
        pipeline.cancel();
      },
    );

    test('a search hit book address is the first match of its links', () async {
      final pages = _HtmlPages({
        '/search':
            '<div class="result">'
            '<span class="name">回音</span>'
            '<a class="more" href="$origin/book/1">正序</a>'
            '<a class="more" href="$origin/book/1/2">倒序</a>'
            '</div>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': origin,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': '.result',
          'name': '.name@text',
          'bookUrl': '.more@href',
        },
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.toc@href'},
      }, pages);
      final hit = (await pipeline.search('关键字')).single;
      expect(hit.rawAddress, '$origin/book/1');
      expect('${hit.url}', '$origin/book/1');
      expect(pages.requests, ['/search']);
      pipeline.cancel();
    });

    test(
      'the first match takes the field replacement and one entity unescape',
      () async {
        final pages = _HtmlPages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': origin,
          'ruleBookInfo': {
            'name': 'h1@text',
            'tocUrl': '.more@href##^##&amp;amp;',
          },
        }, pages);
        final info = await pipeline.bookInfo(retainedBook(twoTocLinks));
        expect(info.tocAddress, '&amp;$ascending');
        expect(pages.requests, isEmpty);
        pipeline.cancel();
      },
    );

    test(
      'a scripted TOC address keeps the first match before its script',
      () async {
        final pages = _HtmlPages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': origin,
          'ruleBookInfo': {
            'name': 'h1@text',
            'tocUrl': '.more@href@js:result.trim()',
          },
        }, pages);
        final info = await pipeline.bookInfo(retainedBook(twoTocLinks));
        expect(info.tocAddress, ascending);
        pipeline.cancel();
      },
    );

    for (final entry in {
      'a literal TOC address': "{{'&amp;amp;/toc'}}",
      'a script-only TOC address': "@js:'&amp;amp;/toc'",
    }.entries) {
      test('${entry.key} keeps one entity pass', () async {
        final pages = _HtmlPages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': origin,
          'ruleBookInfo': {'name': 'h1@text', 'tocUrl': entry.value},
        }, pages);
        final info = await pipeline.bookInfo(retainedBook(twoTocLinks));
        expect(info.tocAddress, '&amp;/toc');
        pipeline.cancel();
      });
    }
  });

  group('reads that share the extraction stage', () {
    test('an ordinary scalar still joins every match with a newline', () async {
      final pages = _HtmlPages({
        '/book/1':
            '<h1>book</h1>'
            '<span class="writer">甲</span><span class="writer">乙</span>'
            '<a class="cover" href="/cover/a.png"></a>'
            '<a class="cover" href="/cover/b.png"></a>'
            '<a class="toc" href="/toc">目录</a>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': origin,
        'ruleBookInfo': {
          'name': 'h1@text',
          'author': '.writer@text',
          'coverUrl': '.cover@href',
          'tocUrl': '.toc@href',
        },
      }, pages);
      final info = await pipeline.bookInfo(
        HtmlBook(url: Uri.parse('$origin/book/1'), title: 'book'),
      );
      expect(info.book.author, '甲\n乙');
      expect(info.book.cover, '$origin/cover/a.png%0A/cover/b.png');
      pipeline.cancel();
    });

    test('a TOC item chapter address stays an ordinary join', () async {
      final pages = _HtmlPages({
        '/toc':
            '<div id="list"><li><span>第一章</span>'
            '<a href="/chapter/1">正文</a><a href="/chapter/2">备用</a>'
            '</li></div>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': origin,
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.toc@href'},
        'ruleToc': {
          'chapterList': '#list li',
          'chapterName': 'span@text',
          'chapterUrl': 'a@href',
        },
      }, pages);
      final (_, chapters) = await pipeline.details(
        retainedBook('<h1>book</h1><a class="toc" href="/toc">目录</a>'),
      );
      expect(chapters.single.name, '第一章');
      expect(chapters.single.rawAddress, '/chapter/1\n/chapter/2');
      expect(pages.requests, ['/toc']);
      pipeline.cancel();
    });
  });
}
