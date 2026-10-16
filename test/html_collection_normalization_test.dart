import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

const _origin = 'https://collection-identity.test';
const _html =
    '<section><article class="book" data-name="A">'
    '<a href="/a"><b>one</b></a></article>'
    '<article class="book" data-name="B">'
    '<a href="/b"><b>two</b></a></article></section>'
    '<section><article class="book" data-name="C">'
    '<a href="/c"><b>three</b></a></article></section>';

class _Pages implements BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    if (Uri.parse(path).path != '/search') {
      throw StateError('Unexpected request: $path');
    }
    return _html;
  }
}

Future<List<HtmlBook>> _search(String listRule) async {
  final pipeline = HtmlSourcePipeline({
    'bookSourceUrl': _origin,
    'searchUrl': '/search',
    'ruleSearch': {
      'bookList': listRule,
      'name': '@js:result.attr("data-name")',
      'author': '@js:result.selectFirst("b").text()',
      'bookUrl': '@js:result.selectFirst("a").attr("href")',
    },
  }, _Pages());
  try {
    return await pipeline.search('identity');
  } finally {
    pipeline.cancel();
  }
}

Future<List<HtmlBook>> _script(String tail) =>
    _search('@js:var es=Jsoup.parse(result).select(".book"); $tail');

void _expectBooks(List<HtmlBook> books, List<String> names) {
  const authors = {'A': 'one', 'B': 'two', 'C': 'three'};
  expect(books.map((book) => book.title), names);
  expect(books.map((book) => book.author), names.map((name) => authors[name]));
  expect(
    books.map((book) => book.url.path),
    names.map((name) => '/${name.toLowerCase()}'),
  );
  expect(books.every((book) => book.url.origin == _origin), isTrue);
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  // Ordinary JS Array/transport controls over the real HTML list pipeline.
  // These are not new Rhino/Java Elements observations or frozen goldens.
  group('HTML collection candidate identity', () {
    test(
      'descriptor clone reverse keeps returned order and node paths',
      () async {
        final books = await _script(
          'var copy=Object.defineProperties([],Object.getOwnPropertyDescriptors(es)); '
          'copy.reverse(); copy',
        );
        _expectBooks(books, ['C', 'B', 'A']);
      },
    );

    test('descriptor clone replacement keeps returned membership', () async {
      final books = await _script(
        'var copy=Object.defineProperties([],Object.getOwnPropertyDescriptors(es)); '
        'copy[0]=copy[2]; copy.length=1; copy',
      );
      _expectBooks(books, ['C']);
    });

    test(
      'owner mutation does not change an untouched descriptor clone',
      () async {
        final books = await _script(
          'var copy=Object.defineProperties([],Object.getOwnPropertyDescriptors(es)); '
          'es.reverse(); copy',
        );
        _expectBooks(books, ['A', 'B', 'C']);
      },
    );

    test(
      'genuine collection retains methods across list script results',
      () async {
        final books = await _search(
          '.book<js>result</js><js>'
          'if(typeof result.select!=="function" || result.select("a").length!==3) '
          'throw new Error("lost genuine collection"); result</js>',
        );
        _expectBooks(books, ['A', 'B', 'C']);
      },
    );

    for (final testCase in [
      (
        label: 'owner accessor',
        descriptor: '{enumerable:true,get:function(){return 1;}}',
        returned: 'es',
      ),
      (
        label: 'ordinary-array accessor',
        descriptor: '{enumerable:true,get:function(){return 1;}}',
        returned: 'es.slice()',
      ),
      (
        label: 'owner data property',
        descriptor: '{enumerable:true,value:1}',
        returned: 'es',
      ),
    ]) {
      test('same-length ${testCase.label} keeps focused node paths', () async {
        final books = await _search(
          '@js:var es=Jsoup.parse(result).select("section").select(".book"); '
          'var step=Object.assign({},es[0].__selection[1]); '
          'Object.defineProperty(step,"parentIndex",${testCase.descriptor}); '
          'es[0].__selection[1]=step; ${testCase.returned}',
        );
        _expectBooks(books, ['C', 'B', 'C']);
      });
    }

    test('mutated producer array keeps its actual order', () async {
      _expectBooks(await _script('es.reverse(); es'), ['C', 'B', 'A']);
    });

    test(
      'fresh node array stays undecorated and retains its own order',
      () async {
        final books = await _script(
          'var fresh=[es[2],es[0]]; '
          'if(typeof fresh.select!=="undefined" || typeof fresh.attr!=="undefined") '
          'throw new Error("decorated fresh array"); fresh',
        );
        _expectBooks(books, ['C', 'A']);
      },
    );
  });
}
