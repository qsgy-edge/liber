// Expected units/state come from the separate actual pinned read-context run.
// Caller-sequence observations execute getters, not whole caller classes.
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
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'native_library.dart';

const _origin = 'https://context-rules.test';
const _oracle = 'tool/rule_field_oracle';
const _evidence = '$_oracle/evidence/read-context-host';
final _cases = (jsonDecode(File('$_oracle/read-context-fixtures.json').readAsStringSync()) as List).cast<Map>();
final _golden = jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <String>[];
  @override
  Future<String> request({required BookSourceStage stage, required String path}) async {
    final key = Uri.parse(path).path;
    requests.add(key);
    return pages[key] ?? (throw StateError('Unexpected URL: $path'));
  }
}

Map<String, dynamic> _source(bool json) => {
  'bookSourceUrl': _origin, 'searchUrl': '/search',
  'ruleSearch': {'bookList': json ? r'$.items' : 'li', 'name': json ? r'$.name' : 'a@text', 'bookUrl': json ? r'$.path' : 'a@href'},
  'ruleBookInfo': {'name': '', 'tocUrl': r"{{'/toc'}}", 'canReName': 'yes'},
  'ruleToc': {'chapterList': json ? r'$.list' : 'li', 'chapterName': json ? r'$.name' : 'a@text', 'chapterUrl': json ? r'$.href' : 'a@href'},
};

String _expected(Map read) => String.fromCharCodes(
  ((read['joinedUnits'] ?? (read['values'] as List).single) as List).cast<int>(),
);
String _bookValue(HtmlBook book, String field) => switch (field) {
  'name' => book.title, 'author' => book.author, 'kind' => book.kind,
  'wordCount' => book.wordCount, 'lastChapter' => book.lastChapter,
  'intro' => book.intro, 'coverUrl' => book.cover.isEmpty ? '' : Uri.parse(book.cover).path,
  _ => throw StateError('Unexpected field $field'),
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('executed read-context regression', () {
    test('original context corpus and actual frozen output retain identity', () {
      final manifest = jsonDecode(File('$_evidence/manifest.json').readAsStringSync()) as Map;
      String hash(String path) => SHA256Digest().process(File(path).readAsBytesSync()).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(manifest['fixturesSha256'], hash('$_oracle/read-context-fixtures.json'));
      expect(manifest['harnessSha256'], hash('$_oracle/ReadContextOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_oracle/run_read_context.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(manifest['compileExit'], 0); expect(manifest['runExit'], 0);
      expect(manifest['observations'], 37); expect(manifest['productComparableRows'], 36);
      expect(manifest['deviceRows'], 'not-run');
      expect(manifest['frozenOnly'], ['p4-detached-frozen-only']);
      for (final row in _cases) { expect(_golden, contains(row['name'])); }
    });

    for (final row in _cases.where((row) => row['product'] != 'not-run')) {
      test('${row['name']} at the actual read caller', () async {
        final name = row['name'] as String;
        final observed = _golden[name] as Map;
        final state = SourceHostState();
        final json = row['pipeline'] == 'json';
        final source = _source(json);
        final content = row['content'] as String;
        final rule = row['rule'] as String?;
        final items = (observed['items'] as List).cast<Map>();
        final tocBody = json ? '{"list":[{"name":"chapter","href":"/chapter"}]}' : '<li><a href="/chapter">chapter</a></li>';
        if (row['error'] == true) {
          (source['ruleBookInfo'] as Map)['author'] = rule;
          final pipeline = JsonSourcePipeline(source, _Pages({'/book': content}), hostState: state);
          var cancellationMarkerReached = false;
          if (row['cancelled'] == true) {
            pipeline.onHostMessage = (_) {
              cancellationMarkerReached = true;
              pipeline.cancel();
            };
          }
          await expectLater(pipeline.details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old')),
            throwsA(isA<SourceScriptError>().having(
              (error) => row['cancelled'] == true ? error.category : error.message,
              'failure', contains(row['cancelled'] == true ? 'cancelled' : 'read-context'),
            )),
          );
          if (row['cancelled'] == true) expect(cancellationMarkerReached, isTrue);
        } else if (row['stage'] == 'info') {
          final info = source['ruleBookInfo'] as Map;
          for (final read in (row['reads'] as List).cast<Map>()) { info[read['field']] = read['rule']; }
          final pages = _Pages({'/book': content, '/toc': tocBody, '/bad': tocBody});
          final BookSourcePipeline pipeline = json ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (book, _) = await pipeline.details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'));
          for (final read in (items.single['reads'] as List).cast<Map>()) {
            final value = read['field'] == 'tocUrl' ? pages.requests.last : _bookValue(book, read['field'] as String);
            expect(value.codeUnits, _expected(read).codeUnits, reason: '$name ${read['field']}');
          }
        } else if (row['stage'] == 'toc') {
          final toc = source['ruleToc'] as Map;
          toc['chapterList'] = row['listRule'] ?? 'li';
          if (row['reads'] != null) {
            for (final read in (row['reads'] as List).cast<Map>()) { toc[read['field']] = read['rule']; }
          } else { toc['updateTime'] = rule; }
          final (_, chapters) = await HtmlSourcePipeline(source, _Pages({'/book': '<p>book</p>', '/toc': content}), hostState: state)
              .details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'));
          expect(chapters, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            for (final read in (items[i]['reads'] as List).cast<Map>()) {
              final chapter = chapters[i];
              final value = switch (read['field']) {
                'chapterName' => chapter.name, 'chapterUrl' => chapter.rawAddress!,
                'isVolume' => '${chapter.isVolume}', 'isVip' => '${chapter.isVip}', 'isPay' => '${chapter.isPay}',
                _ => chapter.tag ?? '',
              };
              expect(value.codeUnits, _expected(read).codeUnits, reason: '$name item=$i ${read['field']}');
            }
          }
        } else if (row['type'] == 'node' || row['stage'] == 'search') {
          final search = source['ruleSearch'] as Map;
          search['bookList'] = row['listRule'] ?? row['selector'] ?? 'li';
          final list = row['form'] == 'list';
          search[list ? 'kind' : 'author'] = rule;
          final books = await HtmlSourcePipeline(source, _Pages({'/search': content}), hostState: state).search('x');
          expect(books, hasLength(items.length));
          for (var i = 0; i < items.length; i++) {
            final read = (items[i]['reads'] as List).single as Map;
            expect((list ? books[i].kind : books[i].author).codeUnits, _expected(read).codeUnits, reason: '$name item=$i');
          }
        } else if (row['unescape'] == false) {
          source['ruleContent'] = {'content': rule};
          final body = await JsonSourcePipeline(source, _Pages({'/chapter': content}), hostState: state)
              .chapter(SourceChapter('chapter', Uri.parse('$_origin/chapter')));
          expect(body.text.codeUnits, _expected((items.single['reads'] as List).single as Map).codeUnits);
        } else {
          (source['ruleBookInfo'] as Map)['author'] = rule;
          final pages = _Pages({'/book': content, '/toc': tocBody});
          final BookSourcePipeline pipeline = json ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          final (book, _) = await pipeline.details(HtmlBook(url: Uri.parse('$_origin/book'), title: 'old'));
          expect(book.author.codeUnits, _expected((items.single['reads'] as List).single as Map).codeUnits);
        }
        for (final entry in (observed['variables'] as Map).entries) {
          expect(await state.entry(_origin, sourceRuleVariableKey(_origin, '${entry.key}')) ?? '', entry.value,
              reason: '$name variable=${entry.key}');
        }
      });
    }

    for (final json in [false, true]) {
      test('existing detail name/author retention (json=$json)', () async {
        final source = _source(json);
        (source['ruleBookInfo'] as Map).addAll(<String, String>{'name': "{{'new'}}", 'author': "{{'new-author'}}", 'canReName': ''});
        final pages = _Pages({'/book': json ? '{}' : '<p>book</p>', '/toc': json
          ? '{"list":[{"name":"chapter","href":"/chapter"}]}' : '<li><a href="/chapter">chapter</a></li>'});
        final BookSourcePipeline pipeline = json ? JsonSourcePipeline(source, pages) : HtmlSourcePipeline(source, pages);
        final original = HtmlBook(url: Uri.parse('$_origin/book'), title: 'retained', author: 'retained-author');
        final (book, _) = await pipeline.details(original);
        expect(book.title, original.title); expect(book.author, original.author);
      });
    }
  });
}
