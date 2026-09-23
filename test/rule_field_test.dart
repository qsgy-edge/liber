import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/rule_field.dart';

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
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    requests.add(target);
    return _pages[target] ?? (throw StateError('Unexpected URL: $target'));
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

    test('a script on an element-list rule is refused by name', () async {
      final source = _htmlSource(name: 'a.0@text');
      (source['ruleSearch'] as Map)['bookList'] = r'.result a @js: result';
      await expectLater(
        HtmlSourcePipeline(source, _HtmlPages()).search('关键字'),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error',
            'message',
            contains('列表规则'),
          ),
        ),
      );
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
  // are the fixture for those frozen entry points.
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
        expect(hit.intro, '　　　　A B\n　　CD\n　　&amp;');
        final (book, _) = await pipeline.details(hit);
        expect(book.intro, hit.intro);
      });
      for (final blank in [false, true]) {
        test(
          'content scripts see the first-page title (json=$json, blank=$blank)',
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
            expect(
              result.text,
              '${blank ? '目录标题' : '正文标题'}:${blank ? '目录标题' : '正文标题'}:正文',
            );
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
      (json['ruleContent'] as Map)['title'] = 'bad';
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
}
