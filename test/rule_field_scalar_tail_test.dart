// Actual frozen getString/getStringList observations for the post-native tail.
// Direct setContent(Elements) stays frozen-only; product collection rows create
// real Elements inside a script whose caller content is a String on both sides.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';

import 'native_library.dart';

const _origin = 'https://review-rules.test';
const _oracle = 'tool/rule_field_oracle';
const _evidence = '$_oracle/evidence/scalar-tail-host';
final _cases =
    (jsonDecode(File('$_oracle/scalar-tail-fixtures.json').readAsStringSync())
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async =>
      pages[Uri.parse(path).path] ??
      (throw StateError('Unexpected fixture URL: $path'));
}

Map<String, dynamic> _source() => {
  'bookSourceUrl': _origin,
  'searchUrl': '/search',
  'ruleSearch': {'bookList': 'li', 'name': 'a@text', 'bookUrl': 'a@href'},
  'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
  'ruleToc': {
    'chapterList': 'li',
    'chapterName': 'a@text',
    'chapterUrl': 'a@href',
  },
};

String _expected(Map row) {
  final observed = _golden[row['name']] as Map;
  final units = row['form'] == 'list'
      ? observed['joinedUnits'] as List
      : (observed['values'] as List).single as List;
  return String.fromCharCodes(units.cast<int>());
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('executed script-only scalar tail', () {
    test('new corpus and actual frozen execution retain their identity', () {
      final manifest =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String path) => SHA256Digest()
          .process(File(path).readAsBytesSync())
          .map((unit) => unit.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(
        manifest['fixturesSha256'],
        hash('$_oracle/scalar-tail-fixtures.json'),
      );
      expect(manifest['harnessSha256'], hash('$_oracle/ScalarTailOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_oracle/run_scalar_tail.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(manifest['compileExit'], 0);
      expect(manifest['runExit'], 0);
      expect(manifest['deviceRows'], 'not-run');
      expect(manifest['observations'], 12);
      expect(manifest['productComparableRows'], 11);
      expect(manifest['frozenOnly'], ['collection-content-frozen-only']);
      for (final row in _cases) {
        final actual = _golden[row['name']] as Map;
        expect(actual['error'], isNull);
        expect(
          actual['type'],
          row['type'] == 'node'
              ? 'org.jsoup.nodes.Element'
              : row['type'] == 'collection'
              ? 'org.jsoup.select.Elements'
              : 'java.lang.String',
        );
      }
    });

    for (final row in _cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} at the actual scalar/list/content caller', () async {
        final source = _source();
        final state = SourceHostState();
        final rule = row['rule'] as String;
        final content = row['content'] as String? ?? '<p>body</p>';
        final list = row['form'] == 'list';
        final String actual;
        if (row['type'] == 'node') {
          (source['ruleSearch'] as Map)[list ? 'kind' : 'author'] = rule;
          final book = (await HtmlSourcePipeline(
            source,
            _Pages({'/search': content}),
            hostState: state,
          ).search('x')).single;
          actual = list ? book.kind : book.author;
        } else if (row['unescape'] == false) {
          // The same executed script removes tags and joins lines before the
          // content caller; its entity-bearing result survives the formatter.
          // Since #104 the content caller reads the rule with `unescape = false`
          // and runs the frozen per-page pass after it, so the caller answer is
          // the golden's raw read through `formatContentPage`.
          source['ruleContent'] = {'content': rule};
          final body = await HtmlSourcePipeline(
            source,
            _Pages({'/chapter': content}),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$_origin/chapter')));
          actual = body.text;
        } else {
          (source['ruleBookInfo'] as Map)[list ? 'kind' : 'author'] = rule;
          final (book, _) = await HtmlSourcePipeline(
            source,
            _Pages({
              '/book': content,
              '/toc': '<li><a href="/chapter">chapter</a></li>',
            }),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'));
          actual = list ? book.kind : book.author;
        }
        final expected = row['unescape'] == false
            ? formatContentPage(_expected(row))
            : _expected(row);
        expect(
          actual.codeUnits,
          expected.codeUnits,
          reason: '${row['name']}',
        );
        if (row['name'] == 'literal-sibling-count') {
          expect(
            await state.entry(_origin, sourceRuleVariableKey(_origin, 'count')),
            (_golden[row['name']] as Map)['count'],
          );
        }
      });
    }
  });
}
