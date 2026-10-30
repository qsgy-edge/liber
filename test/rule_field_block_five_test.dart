// Expected units come only from the separately executed frozen finding corpus.
// Getter-sequence rows preserve the pinned caller order; they do not claim an
// execution of the full frozen BookList class or a Java input-type protocol.
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
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../tool/html_adapter_gate.dart' as html_gate;
import 'native_library.dart';

const _origin = 'https://review-rules.test';
const _oracle = 'tool/rule_field_oracle';
const _evidence = '$_oracle/evidence/block-five-host';
final _cases =
    (jsonDecode(File('$_oracle/block-five-fixtures.json').readAsStringSync())
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <String>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    return pages[Uri.parse(path).path] ??
        (throw StateError('Unexpected URL: $path'));
  }
}

Map<String, dynamic> _source({bool json = false}) => {
  'bookSourceUrl': _origin,
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

const _bookFixture = <String, String>{
  '/book': '{"name":"root","item":{"name":"nested"}}',
  '/toc': '{"list":[{"name":"chapter","href":"/chapter"}]}',
};

HtmlBook _oldBook() =>
    HtmlBook(url: Uri.parse('$_origin/book'), title: 'old', author: 'old');

String _expected(Map read) {
  final units = read['joinedUnits'] ?? (read['values'] as List).single;
  return String.fromCharCodes((units as List).cast<int>());
}

String? _bookValue(HtmlBook book, String field) => switch (field) {
  'name' => book.title,
  'author' => book.author,
  'kind' => book.kind,
  'wordCount' => book.wordCount,
  'lastChapter' => book.lastChapter,
  'intro' => book.intro,
  'bookUrl' => book.rawAddress!,
  _ => throw StateError('Unexpected field $field'),
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('executed five finding regression', () {
    test('actual finding corpus and golden retain their identity', () {
      final manifest =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String path) => SHA256Digest()
          .process(File(path).readAsBytesSync())
          .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(
        manifest['fixturesSha256'],
        hash('$_oracle/block-five-fixtures.json'),
      );
      expect(manifest['harnessSha256'], hash('$_oracle/BlockFiveOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_oracle/run_block_five.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(manifest['compileExit'], 0);
      expect(manifest['runExit'], 0);
      expect(manifest['observations'], 37);
      expect(manifest['productComparableRows'], 35);
      expect(manifest['frozenOnly'], [
        'native-key-false-frozen-only',
        'nested-put-policy-frozen-only',
      ]);
      expect(manifest['deviceRows'], 'not-run');
      for (final row in _cases) {
        expect(_golden, contains(row['name']));
        if (row['error'] == true) {
          expect(
            (_golden[row['name']] as Map)['errorType'],
            'com.script.ScriptException',
          );
          continue;
        }
        for (final item in (_golden[row['name']] as Map)['items'] as List) {
          expect(
            (item as Map)['type'],
            row['type'] == 'node'
                ? 'org.jsoup.nodes.Element'
                : row['type'] == 'nativeObject'
                ? 'org.mozilla.javascript.NativeObject'
                : row['type'] == 'map'
                ? 'java.util.LinkedHashMap'
                : 'java.lang.String',
          );
        }
      }
    });

    // These five product call-site guards are distinct from the 37 frozen
    // observations: they pin the supported simple-name/canonical-property
    // boundary and the unsupported-shape refusal at the information/details
    // caller, including the scripted-init deferred and ignored-field cases.
    for (final scenario in const <String, ({String? init, String author})>{
      'no-init': (init: null, author: 'root'),
      'script-string': (init: "@js:'body'", author: 'old'),
      'script-list': (init: '@js:[1,2]', author: 'old'),
      'decoded-map': (init: r'$.item', author: 'nested'),
    }.entries) {
      test(
        'supported bare-key ${scenario.key} preserves its input boundary',
        () async {
          final source = _source(json: true);
          final info = source['ruleBookInfo'] as Map;
          info['author'] = 'name';
          if (scenario.value.init != null) info['init'] = scenario.value.init;

          final bookPages = _Pages(_bookFixture);
          final infoResult = await JsonSourcePipeline(
            source,
            bookPages,
          ).bookInfo(_oldBook());
          expect(infoResult.book.author, scenario.value.author);
          expect(infoResult.tocAddress, '/toc');
          expect(bookPages.requests, ['$_origin/book']);

          final detailPages = _Pages(_bookFixture);
          final (book, chapters) = await JsonSourcePipeline(
            source,
            detailPages,
          ).details(_oldBook());
          expect(book.author, scenario.value.author);
          expect(chapters, hasLength(1));
          expect(chapters.single.name, 'chapter');
          expect(chapters.single.rawAddress, '/chapter');
          expect(detailPages.requests, ['$_origin/book', '$_origin/toc']);

          // The unsupported shape is outside the simple-name grammar, so it is
          // still a pre-request field refusal even for scripted init. The
          // supported bare name above is the supported post-init deferred case.
          final badSource = _source(json: true);
          (badSource['ruleBookInfo'] as Map).addAll(<String, String>{
            'author': 'foo bar',
            if (scenario.value.init != null) 'init': scenario.value.init!,
          });
          final badPages = _Pages(_bookFixture);
          await expectLater(
            JsonSourcePipeline(badSource, badPages).bookInfo(_oldBook()),
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
        final source = _source(json: true);
        (source['ruleBookInfo'] as Map).addAll(<String, String>{
          'init': "@js:({toc:'/toc'})",
          'tocUrl': 'toc',
          'updateTime': 'name',
        });

        final bookPages = _Pages(_bookFixture);
        final infoResult = await JsonSourcePipeline(
          source,
          bookPages,
        ).bookInfo(_oldBook());
        expect(infoResult.book.author, 'old');
        expect(infoResult.tocAddress, '/toc');
        expect(bookPages.requests, ['$_origin/book']);

        final detailPages = _Pages(_bookFixture);
        final (book, chapters) = await JsonSourcePipeline(
          source,
          detailPages,
        ).details(_oldBook());
        expect(book.author, 'old');
        expect(chapters, hasLength(1));
        expect(chapters.single.name, 'chapter');
        expect(chapters.single.rawAddress, '/chapter');
        expect(detailPages.requests, ['$_origin/book', '$_origin/toc']);

        // A supported static property in an ignored field is accepted and not
        // read; no book-info updateTime getter is introduced. A genuinely
        // unsupported ignored rule still refuses before the first request.
        final badSource = _source(json: true);
        (badSource['ruleBookInfo'] as Map).addAll(<String, String>{
          'init': "@js:({toc:'/toc'})",
          'tocUrl': 'toc',
          'updateTime': 'foo bar',
        });
        final badPages = _Pages(_bookFixture);
        await expectLater(
          JsonSourcePipeline(badSource, badPages).bookInfo(_oldBook()),
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
        final row = _cases.singleWhere(
          (row) => row['name'] == 'nested-put-policy-frozen-only',
        );
        final source = _source(json: true);
        (source['ruleBookInfo'] as Map)['author'] = row['rule'];
        final state = SourceHostState();
        await expectLater(
          JsonSourcePipeline(
            source,
            _Pages({'/book': row['content'] as String}),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old')),
          throwsA(
            isA<UnsupportedError>().having(
              (error) => '$error',
              'named refusal',
              contains('@put:'),
            ),
          ),
        );
        expect(
          await state.entry(_origin, sourceRuleVariableKey(_origin, 'saved')),
          isNull,
        );
        // Frozen actually supports this nested put; the preserved product policy
        // is a rejection guard, never a matched frozen row.
      },
    );

    for (final name in [
      'nested-put-html-literal',
      'nested-put-html-literal-script',
    ]) {
      test('html adapter gate complete nested getter $name', () async {
        final row = _cases.singleWhere((row) => row['name'] == name);
        final observed = _golden[name] as Map;
        final read =
            (((observed['items'] as List).single as Map)['reads'] as List)
                    .single
                as Map;
        expect(
          (await html_gate.htmlAdapterRuleFieldValue(
            row['content'] as String,
            row['rule'] as String,
            baseUrl: '$_origin/book',
          )).codeUnits,
          _expected(read).codeUnits,
        );
      });
    }

    for (final row in _cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} uses the actual caller', () async {
        final state = SourceHostState();
        final name = row['name'] as String;
        final observed = _golden[name] as Map;
        if (row['error'] == true) {
          final source = _source(json: true);
          (source['ruleBookInfo'] as Map)['author'] = row['rule'];
          await expectLater(
            JsonSourcePipeline(
              source,
              _Pages({'/book': row['content'] as String}),
              hostState: state,
            ).details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old')),
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
        final source = _source(json: json);
        final sequence = row['reads'] as List?;
        if (sequence != null) {
          for (final read in sequence.cast<Map>()) {
            (source['ruleSearch'] as Map)[read['field']] = read['rule'];
          }
          final pages = _Pages({'/search': content});
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final books = await pipeline.search('x');
          expect(books, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            for (final read in (items[i]['reads'] as List).cast<Map>()) {
              expect(
                _bookValue(books[i], read['field'] as String)?.codeUnits,
                _expected(read).codeUnits,
                reason: '$name item=$i field=${read['field']}',
              );
            }
          }
        } else {
          final rule = row['rule'] as String;
          final list = row['form'] == 'list';
          final String? actual;
          if (row['type'] == 'node') {
            (source['ruleSearch'] as Map)[row['url'] == true
                    ? 'bookUrl'
                    : 'author'] =
                rule;
            final hit = (await HtmlSourcePipeline(
              source,
              _Pages({'/search': content}),
              hostState: state,
            ).search('x')).first;
            actual = row['url'] == true ? hit.rawAddress! : hit.author;
          } else if (row['unescape'] == false) {
            source['ruleContent'] = {'content': rule};
            final body = await JsonSourcePipeline(
              source,
              _Pages({'/chapter': content}),
              hostState: state,
            ).chapter(SourceChapter('chapter', Uri.parse('$_origin/chapter')));
            actual = body.text;
          } else {
            final info = source['ruleBookInfo'] as Map;
            info[list ? 'kind' : 'author'] = rule;
            if (row['type'] == 'nativeObject') info['init'] = '@js:($content)';
            if (name == 'native-toc-key') info['tocUrl'] = rule;
            if (row['type'] == 'map') info['init'] = row['selector'];
            final pages = _Pages({
              // HTTP response parsing precedes init; init supplies the same
              // JS-origin object as the frozen row, independently of this body.
              '/book': row['type'] == 'nativeObject'
                  ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                  : content,
              '/toc': json
                  ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                  : '<li><a href="/chapter">chapter</a></li>',
            });
            final BookSourcePipeline pipeline = json
                ? JsonSourcePipeline(source, pages, hostState: state)
                : HtmlSourcePipeline(source, pages, hostState: state);
            final (book, _) = await pipeline.details(
              HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
            );
            actual = name == 'native-toc-key'
                ? Uri.parse(pages.requests.last).path
                : list
                ? book.kind
                : book.author;
          }
          final read = (items.single['reads'] as List).single as Map;
          // Since #104 the content caller reads the rule with `unescape = false`
          // and runs the frozen per-page pass, so its answer is the golden's raw
          // read through `formatContentPage`.
          final expected = row['unescape'] == false
              ? formatContentPage(_expected(read))
              : _expected(read);
          expect(actual?.codeUnits, expected.codeUnits, reason: name);
        }
        for (final entry in (observed['variables'] as Map).entries) {
          expect(
            await state.entry(
                  _origin,
                  sourceRuleVariableKey(_origin, '${entry.key}'),
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
