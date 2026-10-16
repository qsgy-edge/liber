import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'native_library.dart';

const _oracle = 'tool/html_get_elements_oracle';
const _origin = 'https://get-elements.test';
final _fixtures = jsonDecode(
  File('$_oracle/legal-string-v2-fixtures.json').readAsStringSync(),
) as Map;
final _golden = jsonDecode(
  File('$_oracle/legal-string-v2-golden.json').readAsStringSync(),
) as Map;
final _rows = (_fixtures['rows'] as List).cast<Map>();
final _html = _fixtures['html'] as String;
const _collectionOracle = '$_oracle/collection-probe-v1';
const _attributeOracle = '$_oracle/collection-attribute-probe-v1';
final _collectionFixtures = jsonDecode(
  File('$_collectionOracle/fixtures.json').readAsStringSync(),
) as Map;
final _collectionGolden = jsonDecode(
  File('$_collectionOracle/observed.json').readAsStringSync(),
) as Map;
final _attributeFixtures = jsonDecode(
  File('$_attributeOracle/fixtures.json').readAsStringSync(),
) as Map;
final _attributeGolden = jsonDecode(
  File('$_attributeOracle/observed.json').readAsStringSync(),
) as Map;
final _collectionRows = (_collectionFixtures['rows'] as List).cast<Map>();
final _attributeRows = (_attributeFixtures['rows'] as List).cast<Map>();
const _chainOracle = '$_oracle/collection-result-chain-probe-v1';
final _chainFixtures = jsonDecode(File('$_chainOracle/fixtures.json').readAsStringSync()) as Map;
final _chainObserved = jsonDecode(File('$_chainOracle/observed.json').readAsStringSync()) as Map;
const _nodeScopeOracle = '$_oracle/node-css-scope-probe-v1';
final _nodeScopeFixtures = jsonDecode(File('$_nodeScopeOracle/fixtures.json').readAsStringSync()) as Map;
final _nodeScopeObserved = jsonDecode(File('$_nodeScopeOracle/observed.json').readAsStringSync()) as Map;

Object? _collectionValue(String id) => (_collectionGolden['rows'] as List)
    .cast<Map>().singleWhere((row) => row['id'] == id)['value'];

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    return pages[target] ?? (throw StateError('Unexpected URL: $target'));
  }
}

Map<String, dynamic> _searchSource({
  required String list,
  String name = '@js:result.attr("data-name")',
  String author = '',
  String bookUrl = '@js:result.selectFirst("a").attr("href")',
}) => {
  'bookSourceUrl': _origin,
  'searchUrl': '/search',
  'ruleSearch': {
    'bookList': list,
    'name': name,
    'author': author,
    'bookUrl': bookUrl,
  },
};

Future<List<HtmlBook>> _search({
  required String list,
  String name = '@js:result.attr("data-name")',
  String author = '',
  String bookUrl = '@js:result.selectFirst("a").attr("href")',
}) async {
  final pipeline = HtmlSourcePipeline(
    _searchSource(list: list, name: name, author: author, bookUrl: bookUrl),
    _Pages({'/search': _html}),
  );
  try {
    return await pipeline.search('synthetic');
  } finally {
    pipeline.cancel();
  }
}

// A document rule runs with the exact retained HTML as the analysis content.
// The author field avoids content formatting and kind/list joining, so the
// fixture's JSON.stringify output reaches the assertion without reshaping.
Future<String> _readDocument(
  String script, {
  bool json = false,
  String? html,
}) async {
  final source = <String, dynamic>{
    'bookSourceUrl': _origin,
    'ruleBookInfo': {
      'name': '',
      'author': '@js:$script',
      'tocUrl': '@js:"/toc"',
    },
    'ruleToc': {
      'chapterList': json ? r'$.items' : 'a',
      'chapterName': json ? r'$.name' : 'a@text',
      'chapterUrl': json ? r'$.url' : 'a@href',
    },
  };
  final pages = _Pages({
    '/book': json ? '{"items":[{"name":"A"},{"name":"B"}]}' : (html ?? _html),
    '/toc': json
        ? '{"items":[{"name":"chapter","url":"/chapter"}]}'
        : '<a href="/chapter">chapter</a>',
  });
  final BookSourcePipeline pipeline = json
      ? JsonSourcePipeline(source, pages)
      : HtmlSourcePipeline(source, pages);
  try {
    final (book, _) = await pipeline.details(
      HtmlBook(url: Uri.parse('$_origin/book'), title: 'retained'),
    );
    return book.author;
  } finally {
    pipeline.cancel();
  }
}

Future<String> _readObserved(Map row) async {
  final selector = row['contextSelector'] as String?;
  if (selector == null) return _readDocument(row['script'] as String);
  // GetElementsOracle.kt sets content to Jsoup.selectFirst(contextSelector).
  // Preserve that first-node binding, including context-self's first .book.
  final books = await _search(
    list: '@js:Jsoup.parse(result).selectFirst(${jsonEncode(selector)})',
    name: '@js:"context"',
    author: '@js:${row['script']}',
    bookUrl: '@js:"/book"',
  );
  expect(books, hasLength(1));
  return books.single.author;
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('HTML getElements retained evidence', () {
    test('actual v2 bytes and twelve row identities remain pinned', () {
      final pins = jsonDecode(File('$_oracle/pins.json').readAsStringSync()) as Map;
      for (final entry in (pins['files'] as Map).entries) {
        final bytes = File('$_oracle/${entry.key}').readAsBytesSync();
        final hash = SHA256Digest().process(bytes)
            .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        expect(hash, entry.value, reason: '${entry.key}');
      }
      final manifest = jsonDecode(
        File('$_oracle/legal-string-v2-manifest.json').readAsStringSync(),
      ) as Map;
      final ids = [for (final row in _rows) row['id']];
      expect(ids, hasLength(12));
      expect(ids.toSet(), hasLength(12));
      expect(_golden['corpus'], _fixtures['corpus']);
      expect(_golden['execution'], 'host-jvm');
      expect(manifest['frozenCommit'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(manifest['exitCode'], 0);
      expect(manifest['androidDevice'], 'not-run');
      expect(manifest['observedRowIds'], ids);
      expect(manifest['intendedRowIds'], ids);
      expect([for (final row in (_golden['rows'] as List).cast<Map>()) row['id']], ids);
      expect(manifest['nullObservation']['comparison'], 'fail / existing mismatch, never counted pass');
    });
  });

  group('HTML getElements observed', () {
    for (final row in _rows) {
      test('${row['id']}', () async {
        final observed = (_golden['rows'] as List).cast<Map>()
            .singleWhere((value) => value['id'] == row['id']);
        expect(
          jsonDecode(await _readObserved(row)),
          observed['value'],
          reason: 'actual frozen host-JVM observation ${row['id']}',
        );
      });
    }
  });

  // Product controls below are not additional frozen observations. In
  // particular, the preserved null/omitted guard differs from frozen's NPE.
  group('HTML getElements controls', () {
    test('null omitted undefined and empty rules retain the early guard', () async {
      expect(jsonDecode(await _readDocument(
        'JSON.stringify([java.getElements(null), java.getElements(), '
        'java.getElements(undefined), java.getElements("")])',
      )), [[], [], [], []]);
    });

    test('a second argument is refused before the empty-rule guard', () async {
      for (final rule in ['".book"', 'null']) {
        await expectLater(
          _readDocument('java.getElements($rule, {})'),
          throwsA(isA<SourceScriptError>().having(
            (error) => error.message, 'arguments',
            contains('java.getElements expects one argument'),
          )),
        );
      }
    });

    test('HTML getElement remains a named refusal', () async {
      await expectLater(
        _readDocument('java.getElement(".book")'),
        throwsA(isA<SourceScriptError>()
            .having((error) => error.category, 'category', 'policy')
            .having((error) => error.message, 'member', contains('java.getElement'))),
      );
    });

    test('JSON scripted list and element members remain named refusals', () async {
      for (final member in ['getElements', 'getElement', 'getStringList']) {
        await expectLater(
          _readDocument('java.$member("\$.items<js>result</js>")', json: true),
          throwsA(isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having((error) => error.message, 'member', contains('java.$member'))
              .having((error) => error.message, 'form', contains('列表/元素规则'))),
        );
      }
    });

    test('JSON pipeline scripted bookList remains a named refusal', () async {
      final pipeline = JsonSourcePipeline(
        _searchSource(
          list: r'$.items<js>result</js>', name: r'$.name',
          bookUrl: r'$.url',
        ),
        _Pages({'/search': '{"items":[{"name":"A","url":"/a"}]}'}),
      );
      try {
        await expectLater(pipeline.search('synthetic'), throwsA(
          isA<UnsupportedError>().having(
            (error) => '$error', 'form', contains('列表规则里的 JavaScript'),
          ),
        ));
      } finally {
        pipeline.cancel();
      }
    });

    test('ordinary JSON element results remain undecorated values', () async {
      expect(jsonDecode(await _readDocument(
        r'var es=java.getElements("$.items"); '
        r'var e=java.getElement("$.items[1]"); '
        r'JSON.stringify([es,e,typeof es.select,Object.keys(es[0])])',
        json: true,
      )), [
        [{'name': 'A'}, {'name': 'B'}],
        {'name': 'B'}, 'undefined', ['name'],
      ]);
    });

    test('existing Jsoup node and collection functions still work', () async {
      expect(jsonDecode(await _readDocument(
        'var doc=Jsoup.parse(src); var es=doc.select(".book"); '
        'JSON.stringify([es.length,es.attr("data-name"),es.text(),'
        'es.select("a").attr("href"),'
        'es[0].selectFirst("b").text(),doc.selectFirst(".missing")])',
      )), [3, 'A', 'A one B two C three', '/a', 'one', null]);
    });

    test('reordered merged nodes retain CSS scope and original sibling positions', () async {
      final books = await _search(
        list: '@js:var es=java.getElements("#second .book&&#first .book"); '
            '[es[2],es[0],es[1]]',
        author: '@js:JSON.stringify([String(src.attr("data-name")),'
            'src.select("#first .book").length,'
            'src.select("#second .book").length,'
            'src.select(":nth-child(2)").length,'
            'src.select(":nth-child(1)").length])',
      );
      expect(books.map((book) => book.title), ['B', 'C', 'A']);
      expect(books.map((book) => book.url.path), ['/b', '/c', '/a']);
      // Equivalent item-boundary control over the actual frozen node counts;
      // size() is adapted to length, including matching descendant counts.
      expect(books.map((book) => jsonDecode(book.author)).toList(),
          (_nodeScopeObserved['rows'] as List).single['value']);
    });

    test('list scripts bind the body as src and keep prior nodes as result', () async {
      final books = await _search(
        list: '.book<js>if(typeof src!=="string" || '
            'src.indexOf("id=second")<0 || result[1].attr("data-name")!=="B") '
            'throw new Error("list content binding"); result</js>',
      );
      expect(books.map((book) => book.title), ['A', 'B', 'C']);
    });

    test('nested getElements in a list script retains original analysis src', () async {
      final books = await _search(
        list: '.book<js>java.getElements("#second .book")</js>',
        author: '@js:JSON.stringify([src.attr("data-name"),'
            'java.getElements(".book").length])',
      );
      expect(books.single.title, 'C');
      expect(books.single.url.path, '/c');
      expect(jsonDecode(books.single.author), ['C', 1]);
    });

    test('selector to script result has usable collection methods', () async {
      final books = await _search(
        list: '.book<js>if(result.attr("data-name")!=="A" || '
            'result.select("a").length!==3) '
            'throw new Error("list collection methods"); [result[1]]</js>',
      );
      expect(books.single.title, 'B');
      expect(books.single.url.path, '/b');
    });

    test('plain scripted JSON items keep their own keys and arrays', () async {
      final books = await _search(
        list: '@js:[{name:"plain",url:"/plain",tags:["x","y"]}]',
        name: '@js:result.name',
        author: '@js:JSON.stringify([Object.keys(result),result.tags,'
            'typeof result.tags.select,typeof src.select])',
        bookUrl: '@js:result.url',
      );
      expect(books.single.title, 'plain');
      expect(jsonDecode(books.single.author), [
        unorderedEquals(['name', 'url', 'tags']), ['x', 'y'], 'undefined', 'undefined',
      ]);
    });

    test('nested rule scripts keep source state and original src', () async {
      final rule = jsonEncode(
        '.book<js>if(source.get("elementsScope")!=="kept" || '
        'typeof src!=="string") throw new Error("nested scope"); '
        '[result[2]]</js>',
      );
      expect(jsonDecode(await _readDocument(
        'source.put("elementsScope","kept"); '
        'var es=java.getElements($rule); '
        'JSON.stringify([es[0].attr("data-name"),source.get("elementsScope")])',
      )), ['C', 'kept']);
    });
  });

  group('HTML getElements collection evidence', () {
    test('actual collection and raw attribute bytes retain separate receipts', () {
      for (final (path, fixtures, observed, count) in [
        (_collectionOracle, _collectionFixtures, _collectionGolden, 8),
        (_attributeOracle, _attributeFixtures, _attributeGolden, 2),
        (_nodeScopeOracle, _nodeScopeFixtures, _nodeScopeObserved, 1),
      ]) {
        final pins = jsonDecode(File('$path/pins.json').readAsStringSync()) as Map;
        for (final entry in (pins['files'] as Map).entries) {
          final hash = SHA256Digest().process(File('$path/${entry.key}').readAsBytesSync())
              .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
          expect(hash, entry.value, reason: '$path/${entry.key}');
        }
        final manifest = jsonDecode(File('$path/manifest.json').readAsStringSync()) as Map;
        final ids = [for (final row in (fixtures['rows'] as List).cast<Map>()) row['id']];
        expect(ids, hasLength(count));
        expect(ids.toSet(), hasLength(count));
        expect(manifest['selectedRowCount'], count);
        expect(manifest['exitCode'], 0);
        expect(manifest['rowIdentityMatches'], isTrue);
        expect(manifest['observedRowIds'], ids);
        expect([for (final row in (observed['rows'] as List).cast<Map>()) row['id']], ids);
        expect(observed['execution'], 'host-jvm');
        // The unchanged original harness hardcodes this name, even though its
        // new fixture inputs carry different decision-corpus names.
        expect(observed['corpus'], 'HTML-GET-ELEMENTS-01');
        expect(manifest['actualOutputCorpus'], observed['corpus']);
        expect(manifest['frozenCommit'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
        expect(manifest['fixtureSha256'], pins['files']['fixtures.json']);
        expect(manifest['observedSha256'], pins['files']['observed.json']);
        expect(manifest['androidDevice'], 'not-run');
      }
    });
  });

  group('HTML getElements collection observed', () {
    for (final row in _collectionRows) {
      test('${row['id']}', () async {
        expect(
          jsonDecode(await _readDocument(
            row['script'] as String,
            html: _collectionFixtures['html'] as String,
          )),
          _collectionValue(row['id'] as String),
          reason: 'actual eight-row frozen getter observation ${row['id']}',
        );
      });
    }
  });

  group('HTML getElements raw attribute observed', () {
    for (final row in _attributeRows) {
      test('${row['id']}', () async {
        final observed = (_attributeGolden['rows'] as List).cast<Map>()
            .singleWhere((value) => value['id'] == row['id']);
        expect(
          jsonDecode(await _readDocument(
            row['script'] as String,
            html: _attributeFixtures['html'] as String,
          )),
          observed['value'],
          reason: 'actual raw-attribute charCode units ${row['id']}',
        );
      });
    }
  });

  // Equivalent-producer controls bypass unfinished getElements restoration.
  // They exercise the current Jsoup façade and compare the relevant actual
  // values; their adapted scripts are not extra frozen executions.
  group('HTML getElements collection source controls', () {
    test('Jsoup collection distinguishes missing from present empty attributes', () async {
      for (final id in ['attr-missing-first', 'attr-empty-first']) {
        final row = _collectionRows.singleWhere((row) => row['id'] == id);
        final script = (row['script'] as String)
            .replaceAll('java.getElements(', 'Jsoup.parse(src).select(');
        expect(
          jsonDecode(await _readDocument(script, html: _collectionFixtures['html'] as String)),
          _collectionValue(id),
          reason: 'equivalent producer control $id',
        );
      }
    });

    test('Jsoup collection select deduplicates overlapping roots', () async {
      final row = _collectionRows.singleWhere((row) => row['id'] == 'overlapping-roots-select');
      final script = (row['script'] as String).replaceFirst(
        "java.getElements('@CSS:#overlap, #inside')",
        "Jsoup.parse(src).select('#overlap, #inside')",
      );
      expect(
        jsonDecode(await _readDocument(script, html: _collectionFixtures['html'] as String)),
        _collectionValue('overlapping-roots-select'),
        reason: 'equivalent CSS producer; no getter restoration dependency',
      );
    });
  });

  group('HTML getElements raw attribute source controls', () {
    for (final row in _attributeRows) {
      test('${row['id']}', () async {
        final script = (row['script'] as String)
            .replaceAll('java.getElements(', 'Jsoup.parse(src).select(');
        final observed = (_attributeGolden['rows'] as List).cast<Map>()
            .singleWhere((value) => value['id'] == row['id']);
        expect(
          jsonDecode(await _readDocument(script, html: _attributeFixtures['html'] as String)),
          observed['value'],
          reason: 'equivalent Jsoup producer; units avoid scalar HTML tail',
        );
      });
    }
  });

  group('HTML getElements chain evidence', () {
    test('controller actual three-row chain bytes retain identity', () {
      final pins = jsonDecode(File('$_chainOracle/pins.json').readAsStringSync()) as Map;
      for (final entry in (pins['files'] as Map).entries) {
        final hash = SHA256Digest().process(File('$_chainOracle/${entry.key}').readAsBytesSync())
            .map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
        expect(hash, entry.value, reason: '${entry.key}');
      }
      final inputIds = [for (final row in (_chainFixtures['rows'] as List).cast<Map>()) row['id']];
      expect(inputIds, hasLength(3));
      expect([for (final row in (_chainObserved['rows'] as List).cast<Map>()) row['id']], inputIds);
      expect(_chainObserved['corpus'], 'HTML-GET-ELEMENTS-01');
    });
  });

  // Only es.size() -> es.length is adapted. These are equivalent count-accessor
  // controls over actual values, not exact-script Java collection API parity.
  group('HTML getElements chain count accessor controls', () {
    for (final row in (_chainFixtures['rows'] as List).cast<Map>()) {
      test('${row['id']}', () async {
        final observed = (_chainObserved['rows'] as List).cast<Map>()
            .singleWhere((value) => value['id'] == row['id']);
        expect(jsonDecode(await _readDocument(
          (row['script'] as String).replaceAll('es.size()', 'es.length'),
          html: _chainFixtures['html'] as String,
        )), observed['value']);
      });
    }
  });

  group('HTML getElements transport controls', () {
    test('stage element-result mode stays outside source bindings', () async {
      final books = await _search(
        list: '@js:if(typeof __elementsResult!=="undefined" || '
            'Object.prototype.hasOwnProperty.call(__LIBER_INPUT__,"__elementsResult")) '
            'throw new Error("transport option leaked"); Jsoup.parse(result).select(".book")',
      );
      expect(books.map((book) => book.title), ['A', 'B', 'C']);
    });
  });

  group('HTML getElements array extension controls', () {
    test('stage mutations and fresh node arrays retain actual values and order', () async {
      // Existing JavaScript-array extension only, not frozen Java mutation API
      // parity. The native converter currently preserves numeric array values.
      for (final (script, expected) in <(String, List<String>)>[
        ('es.reverse(); es', ['C', 'B', 'A']),
        ('es[0]=es[2]; es.length=1; es', ['C']),
        ('es[0].__selection=es[2].__selection; es.length=1; es', ['C']),
        ('var fresh=[es[1],es[0]]; '
            'if(typeof fresh.attr!=="undefined" || typeof fresh.text!=="undefined" || '
            'typeof fresh.select!=="undefined") throw new Error("decorated fresh array"); '
            'fresh', ['B', 'A']),
      ]) {
        final books = await _search(
          list: '@js:var es=Jsoup.parse(result).select(".book"); $script',
        );
        expect(books.map((book) => book.title), expected, reason: script);
        expect(books.map((book) => book.url.path),
            expected.map((name) => '/${name.toLowerCase()}'), reason: script);
      }
    });
  });
}
