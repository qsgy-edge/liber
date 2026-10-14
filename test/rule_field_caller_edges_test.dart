// Actual auxiliary getters supply value/state expectations for N1-N4.
// N5 tests separately encode pinned BookInfo nonempty-update conditions;
// they are source-derived retention controls, not whole BookInfo execution.
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'native_library.dart';

const _origin = 'https://caller-edges.test';
const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/caller-edges-host';
final _rows =
    (jsonDecode(File('$_root/caller-edges-fixtures.json').readAsStringSync())
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;
String _text(Object? units) =>
    String.fromCharCodes((units as List).cast<int>());

class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <SourceHttpRequest>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('Actual pipeline must reach SourceHttpTransport.send');
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final body = pages[request.url.path];
    if (body == null) throw StateError('Unexpected request: ${request.url}');
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
  'searchUrl': '/search',
  'ruleSearch': <String, String>{
    'bookList': json ? r'$.items' : 'li',
    'name': json ? r'$.name' : 'a@text',
    'bookUrl': json ? r'$.href' : 'a@href',
  },
  'ruleBookInfo': <String, String>{'name': '', 'tocUrl': "{{'/toc'}}"},
  'ruleToc': <String, String>{
    'chapterList': json ? r'$.list' : 'li',
    'chapterName': json ? r'$.name' : 'a@text',
    'chapterUrl': json ? r'$.href' : 'a@href',
  },
};
String _toc(bool json) => json
    ? '{"list":[{"name":"chapter","href":"/chapter"}]}'
    : '<li><a href="/chapter">chapter</a></li>';
BookSourcePipeline _pipeline(
  bool json,
  Map<String, dynamic> source,
  _Pages pages,
  SourceHostState state,
) => json
    ? JsonSourcePipeline(source, pages, hostState: state)
    : HtmlSourcePipeline(source, pages, hostState: state);
Future<void> _variables(SourceHostState state, Map observed) async {
  for (final entry in (observed['variables'] as Map).entries) {
    expect(
      await state.entry(
            _origin,
            sourceRuleVariableKey(_origin, '${entry.key}'),
          ) ??
          '',
      entry.value,
      reason: 'variable ${entry.key}',
    );
  }
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('caller edges actual auxiliary getters and source controls', () {
    test('frozen auxiliary identity and explicit caller-source boundaries', () {
      final manifest =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String path) => SHA256Digest()
          .process(File(path).readAsBytesSync())
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(
        manifest['fixturesSha256'],
        hash('$_root/caller-edges-fixtures.json'),
      );
      expect(manifest['harnessSha256'], hash('$_root/CallerEdgesOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_root/run_caller_edges.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(manifest['compileExit'], 0);
      expect(manifest['runExit'], 0);
      expect(manifest['observations'], 24);
      expect(manifest['deviceRows'], 'not-run');
      expect((manifest['callerSourceSha256'] as Map), hasLength(3));
    });
    for (final row in _rows) {
      test(
        '${row['name']} reaches the real supported pipeline caller',
        () async {
          final json = row['pipeline'] == 'json';
          final state = SourceHostState();
          final source = _source(json);
          final observed = _golden[row['name']] as Map;
          if (row['seed'] != null) {
            for (final entry in (row['seed'] as Map).entries) {
              await state.putEntry(
                _origin,
                sourceRuleVariableKey(_origin, '${entry.key}'),
                '${entry.value}',
              );
            }
          }
          final stage = row['stage'];
          if (stage == 'toc') {
            (source['ruleToc'] as Map).addAll(
              (row['rules'] as Map).cast<String, String>(),
            );
            final pages = _Pages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': row['content'] as String,
            });
            final pipeline = _pipeline(json, source, pages, state);
            final (_, chapters) = await pipeline.details(
              HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
            );
            final expected = (observed['chapters'] as List).cast<Map>();
            expect(chapters, hasLength(expected.length));
            for (var i = 0; i < chapters.length; i++) {
              final chapter = chapters[i];
              final values = expected[i];
              expect(chapter.name.codeUnits, values['chapterName']);
              expect(chapter.rawAddress!.codeUnits, values['chapterUrl']);
              expect((chapter.tag ?? '').codeUnits, values['updateTime']);
              expect('${chapter.isVolume}'.codeUnits, values['isVolume']);
              expect('${chapter.isVip}'.codeUnits, values['isVip']);
              expect('${chapter.isPay}'.codeUnits, values['isPay']);
            }
            expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
            pipeline.cancel();
          } else if (stage == 'hostList') {
            (source['ruleBookInfo'] as Map)['author'] = row['rule'];
            final pages = _Pages({
              '/book': row['content'] as String,
              '/toc': _toc(true),
            });
            final pipeline = _pipeline(true, source, pages, state);
            final (book, _) = await pipeline.details(
              HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
            );
            expect(book.author.codeUnits, (observed['fields'] as Map)['value']);
            expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
            pipeline.cancel();
          } else {
            final info = source['ruleBookInfo'] as Map;
            info['name'] = row['nameRule'];
            info['tocUrl'] = row['tocRule'];
            if (row['initRule'] != null) info['init'] = row['initRule'];
            final fallback = stage == 'fallback';
            if (fallback && row['trigger'] == 'pattern')
              source['bookUrlPattern'] = '.*search.*';
            final pages = _Pages({
              fallback ? '/search' : '/book': row['content'] as String,
              '/toc': _toc(json),
            });
            final pipeline = _pipeline(json, source, pages, state);
            Future<List<HtmlBook>> run() async {
              if (fallback) return pipeline.search('x');
              final (book, _) = await pipeline.details(
                HtmlBook(url: Uri.parse('$_origin/book'), title: ''),
              );
              return [book];
            }

            if (row['error'] == true) {
              expect(observed['errorType'], isNotNull);
              await expectLater(
                run(),
                throwsA(
                  isA<SourceScriptError>().having(
                    (e) => e.message,
                    'message',
                    contains('fallback-toc'),
                  ),
                ),
              );
            } else {
              final books = await run();
              expect(books, hasLength(1));
              expect(
                books.single.title.codeUnits,
                (observed['fields'] as Map)['name'],
              );
              expect(
                '${books.single.url}',
                fallback ? '$_origin/search' : '$_origin/book',
              );
            }
            expect(
              pages.requests.map((r) => [r.method, '${r.url}']).toList(),
              fallback
                  ? [
                      ['GET', '$_origin/search'],
                    ]
                  : [
                      ['GET', '$_origin/book'],
                      ['GET', '$_origin/toc'],
                    ],
            );
            pipeline.cancel();
          }
          await _variables(state, observed);
        },
      );
    }
    test(
      'n3 script-list policy is a named rejection guard, not parity',
      () async {
        const inner = r'$.title @js:result';
        final encoded = 'String.fromCharCode(${inner.codeUnits.join(',')})';
        final source = _source(true);
        (source['ruleBookInfo'] as Map)['author'] =
            '@js:java.getStringList($encoded)[0]';
        final pages = _Pages({'/book': '{"title":"body"}'});
        final pipeline = _pipeline(true, source, pages, SourceHostState());
        await expectLater(
          pipeline.details(
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
          ),
          throwsA(
            isA<SourceScriptError>().having(
              (e) => e.category,
              'category',
              'policy',
            ),
          ),
        );
        expect(pages.requests.single.url.path, '/book');
        pipeline.cancel();
      },
    );
    for (final json in [false, true]) {
      for (final shape in ['missing', 'no-match', 'empty-value', 'nonempty']) {
        test('n5 source-derived retention json=$json shape=$shape', () async {
          final source = _source(json);
          final info = source['ruleBookInfo'] as Map;
          if (shape == 'no-match') {
            info.addAll(<String, String>{
              'kind': json ? r'$.missing' : '.missing@text',
              'coverUrl': json ? r'$.missing' : '.missing@href',
            });
          } else if (shape == 'empty-value') {
            info.addAll(<String, String>{
              'kind': '@js:[]',
              'coverUrl': "{{''}}",
            });
          } else if (shape == 'nonempty') {
            info.addAll(<String, String>{
              'kind': json ? r'$.kind' : '.kind@text',
              'coverUrl': json ? r'$.cover' : '.cover@href',
            });
          }
          final pages = _Pages({
            '/book': json
                ? '{"kind":"new-kind","cover":"/new.png"}'
                : '<span class="kind">new-kind</span><a class="cover" href="/new.png"></a>',
            '/toc': _toc(json),
          });
          final hit = HtmlBook(
            url: Uri.parse('$_origin/book'),
            title: 'old',
            kind: 'old-kind',
            cover: '$_origin/old.png',
            rawAddress: '$_origin/book',
          );
          final pipeline = _pipeline(json, source, pages, SourceHostState());
          final (book, _) = await pipeline.details(hit);
          // BookInfo.kt:85-88/135-138 nonempty-update source contract only.
          expect(
            [book.kind, book.cover],
            [
              shape == 'nonempty' ? 'new-kind' : hit.kind,
              shape == 'nonempty' ? '$_origin/new.png' : hit.cover,
            ],
          );
          expect(book.rawAddress, hit.rawAddress);
          expect(pages.requests.map((r) => r.url.path), ['/book', '/toc']);
          expect(pages.requests.every((r) => r.method == 'GET'), isTrue);
          pipeline.cancel();
        });
      }
    }
  });
}
