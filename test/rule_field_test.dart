import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
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
      '<div class="result"><a href="/book/1">回音</a></div>',
  '/book/1':
      '<h1>回音</h1><div class="intro">简介</div><a class="toc" href="/toc/1">目录</a>',
  '/toc/1': '<div id="list"><a href="/chapter/1">第一章</a></div>',
  '/chapter/1': '<div class="content">正文</div>',
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
  'ruleSearch': {
    'bookList': '.result',
    'name': name,
    'bookUrl': 'a.0@href',
    'kind': kind,
  },
  'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.toc@href'},
  'ruleToc': {'chapterList': '#list a', 'chapterName': tocName, 'chapterUrl': 'href'},
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
  'ruleSearch': {
    'bookList': r'$.items',
    'name': name,
    'bookUrl': r'$.path',
    'kind': r'$.kind',
  },
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
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
      {'name': '回音', 'path': '/book/1', 'kind': '玄幻', 'id': '7'},
    ],
  },
  '/book/1': {'title': '回音', 'toc': '/toc/1', 'intro': '简介'},
  '/toc/1': {
    'list': [
      {'label': '第一章', 'href': '/chapter/1'},
    ],
  },
  '/chapter/1': {'content': '正文'},
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('HTML adapter entry point', () {
    Future<HtmlBook> search(Map<String, dynamic> source) async {
      final pipeline = HtmlSourcePipeline(source, _HtmlPages());
      return (await pipeline.search('关键字')).single;
    }

    test('a trailing @js: executes its value instead of being dropped', () async {
      final hit = await search(
        _htmlSource(name: r"a.0@text @js: result + '!'"),
      );
      expect(hit.title, '回音!');
    });

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
  });

  group('JSON adapter entry point', () {
    Future<HtmlBook> search(Map<String, dynamic> source) async {
      final transport = _JsonPages()..pages.addAll(_jsonPages);
      final pipeline = JsonSourcePipeline(source, transport);
      return (await pipeline.search('关键字')).single;
    }

    test('a trailing @js: executes its value instead of being dropped', () async {
      final hit = await search(
        _jsonSource(name: r'$.name @js: result + "!"'),
      );
      expect(hit.title, '回音!');
    });

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
        _jsonSource(
          name: r'@put:{"saved":"$.name"}$.name##回音##@get:{saved}',
        ),
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
      expect(
        (await search(_jsonSource(name: r'$.name##回|音##X##'))).title,
        'X',
      );
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

    test('an unreadable extraction is still refused', () async {
      await expectLater(
        search(_jsonSource(name: r'@Json:$.name')),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });

  group('shared rule-field parse', () {
    test('the ##/### fields follow the frozen split', () {
      expect(splitRuleFields('#a@text').rule, '#a@text');
      expect(splitRuleFields('#a@text').hasReplacement, isFalse);
      final two = splitRuleFields('a##x##');
      expect((two.rule, two.regex, two.replacement, two.replaceFirst), (
        'a',
        'x',
        '',
        false,
      ));
      // Three delimiters are four fields: Kotlin's `split("##")` keeps the
      // trailing empty field, so `##` alone reaches the frozen `replaceFirst`.
      final trailing = splitRuleFields('a##x##y##');
      expect((
        trailing.rule,
        trailing.regex,
        trailing.replacement,
        trailing.replaceFirst,
      ), (
        'a',
        'x',
        'y',
        true,
      ));
      final four = splitRuleFields('a##x##y###');
      expect((four.rule, four.regex, four.replacement, four.replaceFirst), (
        'a',
        'x',
        'y',
        true,
      ));
    });

    test('a field is split into its extraction text and its scripts', () {
      final parts = parseRuleField(r'$.a @js: result');
      expect(parts.extractionRule, r'$.a');
      expect(parts.scripts, [' result']);
      expect(RuleField.extractionText('@js: result'), isNull);
      expect(RuleField.extractionText(''), '');
    });

    test('@put: must be a JSON string map', () {
      expect(
        () => parseRuleField('@put:{"a":1}'),
        returnsNormally,
      );
      expect(
        () => RuleField.extractionText('@put:'),
        returnsNormally,
      );
    });
  });
}
