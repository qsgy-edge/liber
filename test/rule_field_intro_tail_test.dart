// Actual typed frozen getter outputs and compiled HtmlFormatter.format outputs.
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

const _oracle = 'tool/rule_field_oracle';
const _evidence = '$_oracle/evidence/intro-tail-host';
const _origin = 'http://rules.test';
final _cases =
    (jsonDecode(File('$_oracle/intro-tail-fixtures.json').readAsStringSync())
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
      (throw StateError('Unexpected URL: $path'));
}

Map<String, dynamic> _source(bool json) => {
  'bookSourceUrl': _origin,
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

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('executed intro scalar tail', () {
    test('typed getter and actual compiled formatter evidence identity', () {
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
        hash('$_oracle/intro-tail-fixtures.json'),
      );
      expect(manifest['harnessSha256'], hash('$_oracle/IntroTailOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_oracle/run_intro_tail.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(
        manifest['formatterSourcePath'],
        'app/src/main/java/io/legado/app/utils/HtmlFormatter.kt',
      );
      expect(manifest['formatterSourceSha256'], isNotEmpty);
      expect(manifest['compileExit'], 0);
      expect(manifest['runExit'], 0);
      expect(manifest['observations'], 18);
      expect(manifest['deviceRows'], 'not-run');
    });

    test(
      'unchanged product intro formatter matches actual frozen format outputs',
      () {
        for (final row in _cases) {
          final observed = _golden[row['name']] as Map;
          final getter = String.fromCharCodes(
            (observed['getterUnits'] as List).cast<int>(),
          );
          expect(
            formatSourceIntro(getter).codeUnits,
            (observed['formattedUnits'] as List).cast<int>(),
            reason: '${row['name']}',
          );
        }
      },
    );

    test('html adapter gate uses the same actual String scalar tail', () async {
      final row = _cases.singleWhere(
        (row) => row['name'] == 'intro-html-string',
      );
      final actual = await html_gate.htmlAdapterRuleFieldValue(
        row['content'] as String,
        row['rule'] as String,
        baseUrl: '$_origin/book',
      );
      expect(
        actual.codeUnits,
        ((_golden[row['name']] as Map)['getterUnits'] as List).cast<int>(),
      );
    });

    for (final row in _cases) {
      test('${row['name']} at the true String/node/map caller', () async {
        final json = row['pipeline'] == 'json';
        final source = _source(json);
        final rule = row['rule'] as String;
        final content = row['content'] as String;
        final observed = _golden[row['name']] as Map;
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
            _Pages({'/book': '<p>book</p>', '/toc': content}),
            hostState: state,
          ).details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'));
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
            _Pages({'/chapter': content}),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$_origin/chapter')));
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
            _Pages({'/chapter': content}),
            hostState: state,
          ).chapter(SourceChapter('chapter', Uri.parse('$_origin/chapter')));
          expect(
            body.text.codeUnits,
            (observed['getterUnits'] as List).cast<int>(),
          );
          return;
        }
        if (row['type'] == 'string') {
          (source['ruleBookInfo'] as Map).addAll(<String, String>{
            'author': rule,
            'intro': rule,
          });
          final pages = _Pages({
            '/book': content,
            '/toc': json
                ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
                : '<li><a href="/chapter">chapter</a></li>',
          });
          final BookSourcePipeline pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final result = await pipeline.details(
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
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
                  _Pages({'/search': content}),
                  hostState: state,
                )
              : HtmlSourcePipeline(
                  source,
                  _Pages({'/search': content}),
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
          actual.codeUnits,
          (observed['getterUnits'] as List).cast<int>(),
          reason: '${row['name']} getter',
        );
        if (row['url'] != true && row['form'] != 'list') {
          expect(
            book.intro.codeUnits,
            (observed['formattedUnits'] as List).cast<int>(),
            reason: '${row['name']} formatted',
          );
        }
        expect(
          await state.entry(_origin, sourceRuleVariableKey(_origin, 'count')) ??
              '',
          observed['count'],
        );
      });
    }
  });
}
