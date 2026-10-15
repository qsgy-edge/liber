// Auxiliary getters provide actual H1/H2 values and traces. Final normalized
// URLs/flags are caller controls; bare GET is a recorded product extension.
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

const _origin = 'https://fallback-get.test';
const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/fallback-get-case-host';
final _rows =
    (jsonDecode(
              File('$_root/fallback-get-case-fixtures.json').readAsStringSync(),
            )
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;

class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages, {this.responses = const {}});
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

Map<String, dynamic> _source(bool json) => {
  'bookSourceUrl': _origin,
  'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'$_origin/toc'}}"},
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
String _toc(bool json) => json
    ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
    : '<li><a href="/chapter">chapter</a></li>';
String _text(Object? units) =>
    String.fromCharCodes((units as List).cast<int>());
Future<String> _saved(SourceHostState state, String key) async =>
    (await state.entry(_origin, sourceRuleVariableKey(_origin, key))
        as String?) ??
    '';
Future<void> _seed(SourceHostState state, Map seed) async {
  for (final entry in seed.entries) {
    await state.putEntry(
      _origin,
      sourceRuleVariableKey(_origin, '${entry.key}'),
      '${entry.value}',
    );
  }
}

void _requests(_Pages pages, String tocUrl) =>
    expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
      ['GET', '$_origin/book'],
      ['GET', tocUrl],
    ]);
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('fallback publication and GET marker case supported caller', () {
    test('H1 H2 auxiliary identity and entity limitation', () {
      final m =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String p) => SHA256Digest()
          .process(File(p).readAsBytesSync())
          .map((v) => v.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(m['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      for (final entry in {
        'fixturesSha256': 'fallback-get-case-fixtures.json',
        'harnessSha256': 'FallbackGetCaseOracle.kt',
        'runnerSha256': 'run_fallback_get_case.py',
      }.entries) {
        expect(m[entry.key], hash('$_root/${entry.value}'));
      }
      expect(m['goldenSha256'], hash('$_evidence/golden.json'));
      expect([m['compileExit'], m['runExit'], m['observations']], [0, 0, 28]);
      expect(m['callerSourceSha256'] as Map, hasLength(6));
      expect(m['deviceRows'], 'not-run');
    });
    for (final row in _rows) {
      test('${row['name']} reaches actual pipeline getters', () async {
        final json = row['pipeline'] == 'json';
        final h1 = row['stage'] == 'h1';
        final source = _source(json);
        final state = SourceHostState();
        await _seed(state, row['seed'] as Map);
        final observed = _golden[row['name']] as Map;
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
        final pages = _Pages({
          '/book': h1 || row['form'] != 'list'
              ? (json ? '{}' : '<p>book</p>')
              : row['content'] as String,
          '/toc': h1 ? row['content'] as String : _toc(json),
        }, responses: h1 ? {'/toc': row['redirectUrl'] as String} : const {});
        final pipeline = _pipeline(json, source, pages, state);
        Object? failure;
        HtmlBook? book;
        List<SourceChapter>? chapters;
        try {
          final (b, c) = await pipeline.details(
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
          );
          book = b;
          chapters = c;
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
            // Getter string flags and final product booleans are separate facts.
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
              final expected = row['shape'] == 'raw-options'
                  ? Uri.parse('$_origin/chapter?slot=1')
                  : Uri.parse(row['redirectUrl'] as String);
              // Existing final normalization retained; redirect/base raw values
              // above are actual getter evidence, not whole final-URL parity.
              expect(c.url, expected);
            }
          } else {
            final expected = (observed['items'] as List).single as Map;
            expect(
              {
                'value':
                    (row['form'] == 'list'
                            ? book!.kind
                            : chapters!.single.tag ?? '')
                        .codeUnits,
                'variables': variables,
              },
              {
                'value': expected['value'],
                'variables': observed['sourceVariables'],
              },
            );
            if (row['shape'] == 'mixed-url') {
              expect(chapters!.single.rawAddress, _text(expected['value']));
              expect(
                chapters.single.url,
                Uri.parse('$_origin/toc').resolve(_text(expected['value'])),
              );
            }
          }
        }
        final address = h1
            ? (row['baseAddress'] as String).split(',{').first
            : '$_origin/toc';
        _requests(pages, address);
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
            await _seed(state, {'MiXeD': 'UP', 'mixed': 'lower'});
            final source = _source(json);
            (source['ruleToc'] as Map)['updateTime'] = rule;
            final pages = _Pages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': _toc(json),
            });
            final pipeline = _pipeline(json, source, pages, state);
            final (_, chapters) = await pipeline.details(
              HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
            );
            expect(
              chapters.single.tag,
              rule == '@GET:title' ? 'chapter' : 'UP|lower',
            );
            _requests(pages, '$_origin/toc');
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
