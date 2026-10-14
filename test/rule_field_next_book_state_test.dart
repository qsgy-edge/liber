// F1 uses executed auxiliary getters; F2 is pinned BookInfo source-derived
// publication/retention control. The original Book stub has no new members.
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

const _origin = 'https://next-book-state.test';
const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/next-book-state-host';
final _rows =
    (jsonDecode(File('$_root/next-book-state-fixtures.json').readAsStringSync())
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
    if (body == null)
      throw StateError(
        'Unexpected full request ${request.method} ${request.url}',
      );
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
String _toc(bool json, String name) => json
    ? jsonEncode({
        'list': [
          {'name': name, 'href': '/$name'},
        ],
      })
    : '<li><a href="/$name">$name</a></li>';
Future<String> _saved(SourceHostState state, String key) async =>
    (await state.entry(_origin, sourceRuleVariableKey(_origin, key))
        as String?) ??
    '';
void _requests(_Pages pages, List<String> addresses) =>
    expect(pages.requests.map((r) => [r.method, '${r.url}']).toList(), [
      for (final address in addresses) ['GET', '$_origin$address'],
    ]);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('next getter and supported Book metadata caller controls', () {
    test('F1 auxiliary identity; F2 entity sources are pins only', () {
      final manifest =
          jsonDecode(File('$_evidence/manifest.json').readAsStringSync())
              as Map;
      String hash(String path) => SHA256Digest()
          .process(File(path).readAsBytesSync())
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      for (final entry in {
        'fixturesSha256': 'next-book-state-fixtures.json',
        'harnessSha256': 'NextBookStateOracle.kt',
        'runnerSha256': 'run_next_book_state.py',
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
        [0, 0, 12],
      );
      expect((manifest['callerSourceSha256'] as Map), hasLength(4));
      expect(manifest['deviceRows'], 'not-run');
    });
    for (final row in _rows) {
      test('${row['name']} actual next completes before item', () async {
        final json = row['pipeline'] == 'json';
        final state = SourceHostState();
        final source = _source(json);
        (source['ruleToc'] as Map).addAll(<String, String>{
          'chapterList': row['listRule'] as String,
          'chapterName': row['nameRule'] as String,
          'chapterUrl': row['urlRule'] as String,
          'nextTocUrl': row['nextRule'] as String,
        });
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
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
          );
          chapters = result;
        } catch (error) {
          failure = error;
        }
        final variables = {
          for (final key in (observed['variables'] as Map).keys)
            '$key': await _saved(state, '$key'),
        };
        if (row['error'] == true) {
          expect(observed['errorType'], 'com.script.ScriptException');
          // Compare error category/field/message and pre-error state together,
          // so an empty-TOC refusal cannot hide whether next/item executed.
          expect(
            {
              'category': failure is SourceScriptError
                  ? failure.category
                  : '$failure',
              'nextLabel':
                  failure is SourceScriptError &&
                  failure.message.contains('ruleToc.nextTocUrl'),
              'message':
                  failure is SourceScriptError &&
                  failure.message.contains('next-before-item'),
              'variables': variables,
            },
            {
              'category': 'js',
              'nextLabel': true,
              'message': true,
              'variables': observed['variables'],
            },
          );
        } else if ('${row['shape']}'.startsWith('zero-')) {
          expect(
            failure,
            isA<StateError>(),
            reason:
                'Existing empty-TOC policy remains; next/state must complete first',
          );
          expect(variables, observed['variables']);
        } else {
          expect(failure, isNull);
          expect(
            {
              'chapters': [
                for (final chapter in chapters!)
                  {
                    'name': chapter.name.codeUnits,
                    'address': chapter.rawAddress!.codeUnits,
                  },
              ],
              'variables': variables,
            },
            {
              'chapters': observed['chapters'],
              'variables': observed['variables'],
            },
          );
          for (final chapter in chapters) {
            expect(
              chapter.url,
              Uri.parse('$_origin/toc').resolve(chapter.rawAddress!),
            );
          }
        }
        expect(observed['next'], isEmpty);
        _requests(pages, ['/book', '/toc']);
        pipeline.cancel();
      });
    }
    for (final json in [false, true]) {
      test(
        'F1 declared pages skip next getter and retain URL/options json=$json',
        () async {
          final state = SourceHostState();
          final source = _source(json);
          (source['ruleToc'] as Map)['nextTocUrl'] =
              '@js:java.put("nextCount",String(Number(java.get("nextCount")||"0")+1));if(java.get("nextCount")!=="1")throw new Error("declared-must-skip-next");[\'/toc-b?slot=2,{"headers":{"X-Page":"B"}}\',\'/toc-c?slot=3\']';
          final pages = _Pages({
            '/book': json ? '{}' : '<p>book</p>',
            '/toc': _toc(json, 'one'),
            '/toc-b': _toc(json, 'two'),
            '/toc-c': _toc(json, 'three'),
          });
          final pipeline = _pipeline(json, source, pages, state);
          final (_, chapters) = await pipeline.details(
            HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'),
          );
          expect(chapters.map((c) => c.name), ['one', 'two', 'three']);
          expect(await _saved(state, 'nextCount'), '1');
          _requests(pages, ['/book', '/toc', '/toc-b?slot=2', '/toc-c?slot=3']);
          expect(pages.requests[2].headers['X-Page'], 'B');
          pipeline.cancel();
        },
      );
      for (final shape in ['update', 'rename-retained', 'empty', 'no-match']) {
        test(
          'F2 source-derived every detail metadata publication json=$json shape=$shape',
          () async {
            final state = SourceHostState();
            final source = _source(json);
            final info = source['ruleBookInfo'] as Map;
            final update = shape == 'update' || shape == 'rename-retained';
            final missing = json ? r'$.missing' : '.missing@text';
            String value(String text) => shape == 'no-match'
                ? "java.getString('$missing')"
                : jsonEncode(text);
            info.addAll(<String, String>{
              'name': update ? "{{'new-name'}}" : "{{''}}",
              'author': update ? "{{'new-author'}}" : "{{''}}",
              'kind': update
                  ? "{{'new-kind'}}"
                  : shape == 'no-match'
                  ? missing
                  : '@js:[]',
              'wordCount':
                  "@js:java.put('seenKind',book.kind);${value(update
                      ? '12000'
                      : shape == 'empty'
                      ? '0'
                      : '')}",
              'lastChapter':
                  "@js:java.put('seenWord',book.wordCount);${value(update ? 'new-last' : '')}",
              'intro':
                  "@js:java.put('seenLast',book.latestChapterTitle);${value(update ? '<p>new intro</p>' : '')}",
              'coverUrl':
                  "@js:java.put('seenIntro',book.intro);${value(update ? '/new.png' : '')}",
              'tocUrl':
                  "@js:java.put('seenCover',book.coverUrl);java.put('seenBook',JSON.stringify([book.name,book.author,book.kind,book.wordCount,book.latestChapterTitle,book.intro,book.coverUrl,book.bookUrl]));java.put('tocCount',String(Number(java.get('tocCount')||'0')+1));'/toc?page=1'",
              if (shape == 'update') 'canReName': 'yes',
            });
            const raw = '/book?keep=1,{"headers":{"X-Detail":"retained"}}';
            final hit = HtmlBook(
              url: Uri.parse('$_origin/book?keep=1'),
              rawAddress: raw,
              title: 'old-name',
              author: 'old-author',
              kind: 'old-kind',
              wordCount: 'old-word',
              lastChapter: 'old-last',
              intro: 'old-intro',
              cover: '$_origin/old.png',
            );
            final pages = _Pages({
              '/book': json ? '{}' : '<p>book</p>',
              '/toc': _toc(json, 'chapter'),
            });
            final pipeline = _pipeline(json, source, pages, state);
            final (book, _) = await pipeline.details(hit);
            final finalFields = [
              book.title,
              book.author,
              book.kind,
              book.wordCount,
              book.lastChapter,
              book.intro,
              book.cover,
              '${book.url}',
            ];
            expect(finalFields.take(5).toList(), [
              shape == 'update' ? 'new-name' : hit.title,
              shape == 'update' ? 'new-author' : hit.author,
              update ? 'new-kind' : hit.kind,
              update ? '1.2万字' : hit.wordCount,
              update ? 'new-last' : hit.lastChapter,
            ]);
            expect(book.cover, update ? '$_origin/new.png' : hit.cover);
            if (update)
              expect(book.intro, isNot(hit.intro));
            else
              expect(book.intro, hit.intro);
            // Existing formatter/resolver behavior is retained. Later getters must
            // see the actual completed formatted/merged value, including retention.
            expect(
              [
                for (final key in [
                  'seenKind',
                  'seenWord',
                  'seenLast',
                  'seenIntro',
                  'seenCover',
                ])
                  await _saved(state, key),
              ],
              [
                book.kind,
                book.wordCount,
                book.lastChapter,
                book.intro,
                book.cover,
              ],
            );
            expect(jsonDecode(await _saved(state, 'seenBook')), finalFields);
            expect(await _saved(state, 'tocCount'), '1');
            expect(book.url, hit.url);
            expect(book.rawAddress, raw);
            _requests(pages, ['/book?keep=1', '/toc?page=1']);
            expect(pages.requests.first.headers['X-Detail'], 'retained');
            pipeline.cancel();
          },
        );
      }
    }
  });
}
