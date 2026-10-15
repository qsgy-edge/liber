// Actual preserved chapter/title getters with source-transcribed item binding.
// Page/repeat/content lifetime controls derive from pinned caller construction.
// Original Chapter stub is unchanged; tag/flag entity state is not claimed.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'native_library.dart';

const _origin = 'https://toc-binding.test';
const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/toc-chapter-binding-host';
final _rows =
    (jsonDecode(
              File(
                '$_root/toc-chapter-binding-fixtures.json',
              ).readAsStringSync(),
            )
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;

class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
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
      url: request.url,
    );
  }
}

Map<String, dynamic> _source(bool json) => {
  'bookSourceUrl': _origin,
  'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'/toc'}}"},
  'ruleToc': <String, String>{
    'chapterList': json ? r'$.list' : 'li',
    'chapterName': json ? r'$.name' : 'a@text',
    'chapterUrl': json ? r'$.href' : 'a@href',
  },
};
BookSourcePipeline _pipeline(
  bool json,
  Map<String, dynamic> source,
  _Pages pages,
  SourceHostState state,
) => json
    ? JsonSourcePipeline(source, pages, hostState: state)
    : HtmlSourcePipeline(source, pages, hostState: state);
Future<String> _saved(SourceHostState state, String key) async =>
    (await state.entry(_origin, sourceRuleVariableKey(_origin, key))
        as String?) ??
    '';
Future<void> _seed(SourceHostState state) =>
    state.putEntry(_origin, sourceRuleVariableKey(_origin, 'title'), 'stored');
void _requests(_Pages pages, List<String> addresses) =>
    expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
      for (final address in addresses) ['GET', '$_origin$address'],
    ]);
String _page(bool json, String name, {List<String> next = const []}) => json
    ? jsonEncode({
        'list': [
          {'name': name, 'href': '/$name'},
        ],
        'next': next,
      })
    : '<li><a href="/$name">$name</a></li>${next.map((n) => '<a class="next" href=\'$n\'>next</a>').join()}';
String _encoded(String rule) =>
    'String.fromCharCode(${rule.codeUnits.join(',')})';
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('supported TOC chapter binding actual getters and source lifetime controls', () {
    test('G1 auxiliary identity and original Chapter member boundary', () {
      final manifest =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String path) => SHA256Digest()
          .process(File(path).readAsBytesSync())
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      for (final entry in {
        'fixturesSha256': 'toc-chapter-binding-fixtures.json',
        'harnessSha256': 'TocChapterBindingOracle.kt',
        'runnerSha256': 'run_toc_chapter_binding.py',
      }.entries) {
        expect(manifest[entry.key], hash('$_root/${entry.value}'));
      }
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(
        [
          manifest['compileExit'],
          manifest['runExit'],
          manifest['observations'],
        ],
        [0, 0, 16],
      );
      expect(manifest['callerSourceSha256'] as Map, hasLength(5));
      expect(manifest['deviceRows'], 'not-run');
    });
    group('G1 scalar preflight boundaries', () {
      test('mixed and pure scalar title variables are literal values', () {
        expect(
          () => JsonSourceRules.validate('/@get:{title}'),
          returnsNormally,
        );
        expect(() => JsonSourceRules.validate('@get:{title}'), returnsNormally);
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
      test(
        'incomplete get and plain malformed or bare rule remain refused',
        () {
          for (final rule in ['/@get:', '/', 'name']) {
            expect(
              () => JsonSourceRules.validate(rule),
              throwsUnsupportedError,
            );
          }
        },
      );
      test('a getter inside put is not a top-level literal getter', () {
        expect(
          () => JsonSourceRules.validate('@put:{"v":"@get:title"}/'),
          throwsUnsupportedError,
        );
      });
    });
    for (final row in _rows) {
      test('${row['name']} real item chapter/title publication', () async {
        final json = row['pipeline'] == 'json';
        final source = _source(json);
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
        await _seed(state);
        final pages = _Pages({
          '/book': json ? '{}' : '<p>book</p>',
          '/toc': row['content'] as String,
        });
        final pipeline = _pipeline(json, source, pages, state);
        final observed = _golden[row['name']] as Map;
        Object? failure;
        List<SourceChapter>? chapters;
        try {
          final (_, result) = await pipeline.details(
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'book'),
          );
          chapters = result;
        } catch (error) {
          failure = error;
        }
        final variables = {
          for (final key in (observed['sourceVariables'] as Map).keys)
            '$key': await _saved(state, '$key'),
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
            expect(chapter.url, Uri.parse('$_origin/toc').resolve(target));
          }
        }
        _requests(pages, ['/book', '/toc']);
        pipeline.cancel();
      });
    }
    for (final json in [false, true]) {
      for (final declared in [false, true]) {
        test(
          'G1 source-derived per-page list/next has no previous chapter json=$json declared=$declared',
          () async {
            final state = SourceHostState();
            await _seed(state);
            final source = _source(json);
            final stamp =
                "JSON.stringify([chapter===null,title===null,java.get('title'),java.getString(${_encoded('@get:{title}')})])";
            // No braces inside the put value: preserve the existing put parser.
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
            final pages = _Pages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': _page(
                json,
                'one',
                next: declared ? [nextB, nextC] : [nextB],
              ),
              '/toc-b': _page(json, 'two'),
              '/toc-c': _page(json, 'three'),
            });
            final pipeline = _pipeline(json, source, pages, state);
            final (_, chapters) = await pipeline.details(
              HtmlBook(url: Uri.parse('$_origin/book'), title: 'book'),
            );
            const initial = '[true,true,"stored","stored"];';
            final expectedAddresses = declared
                ? ['/book', '/toc', '/toc-b?slot=2', '/toc-c?slot=3']
                : ['/book', '/toc', '/toc-b?slot=2'];
            expect(
              {
                'chapters': chapters.map((c) => [c.name, c.tag]).toList(),
                'listTrace': await _saved(state, 'listTrace'),
                'nextTrace': await _saved(state, 'nextTrace'),
                'nextCount': await _saved(state, 'nextCount'),
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
                    ['GET', '$_origin$address'],
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
          final source = _source(json);
          source['header'] =
              '@js:source.put("emptySnapshot",JSON.stringify([chapter.url,chapter.title,title]));"{}"';
          source['ruleContent'] = <String, String>{'content': '@js:result'};
          final pages = _Pages({});
          final pipeline = _pipeline(json, source, pages, state);
          Object? failure;
          try {
            await pipeline.chapter(
              SourceChapter(
                'provided-empty',
                Uri(),
                rawAddress: '$_origin/provided',
              ),
              book: HtmlBook(url: Uri.parse('$_origin/book'), title: 'book'),
            );
          } catch (error) {
            failure = error;
          }
          // The header keeps the existing normalized-empty snapshot. The real
          // transport receives GET with an empty URI and this fixture refuses it.
          expect(
            failure,
            isA<StateError>().having(
              (e) => e.message,
              'fixture refusal',
              'Unexpected full request GET ',
            ),
          );
          expect(
            await _saved(state, 'emptySnapshot'),
            '["","provided-empty","provided-empty"]',
          );
          expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
            ['GET', ''],
          ]);
          pipeline.cancel();
        },
      );
      test(
        'G1 source-derived repeat details and provided content chapter stay separate json=$json',
        () async {
          final state = SourceHostState();
          await _seed(state);
          final source = _source(json);
          (source['ruleBookInfo'] as Map)['author'] =
              "@js:source.put('detailTrace',source.get('detailTrace')+JSON.stringify([chapter===null,title===null])+';');''";
          (source['ruleToc'] as Map)['updateTime'] = '@get:{title}';
          source['ruleContent'] = <String, String>{
            'content':
                "@js:chapter.title+'|'+title+'|'+java.getString(${_encoded('@get:{title}')})",
          };
          final pages = _Pages({
            '/book': json ? '{}' : '<p>book</p>',
            '/toc': _page(json, 'toc-name'),
            '/provided': json ? '{}' : '<p>body</p>',
          });
          final pipeline = _pipeline(json, source, pages, state);
          final hit = HtmlBook(url: Uri.parse('$_origin/book'), title: 'book');
          final (_, first) = await pipeline.details(hit);
          expect(first.single.tag, 'toc-name');
          final body = await pipeline.chapter(
            SourceChapter('provided', Uri.parse('$_origin/provided')),
            book: hit,
          );
          expect(body.text, 'provided|provided|provided');
          final (_, second) = await pipeline.details(hit);
          expect(second.single.tag, 'toc-name');
          expect(
            await _saved(state, 'detailTrace'),
            '[true,true];[true,true];',
          );
          _requests(pages, ['/book', '/toc', '/provided', '/book', '/toc']);
          pipeline.cancel();
        },
      );
    }
  });
}
