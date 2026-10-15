import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'native_library.dart';

const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/book-visibility-host';
const _origin = 'https://context-rules.test';
final _cases = (jsonDecode(File('$_root/book-visibility-fixtures.json').readAsStringSync()) as List).cast<Map>();
final _golden = jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;
class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  @override
  Future<String> request({required BookSourceStage stage, required String path}) async =>
      pages[Uri.parse(path).path] ?? (throw StateError('Unexpected URL: $path'));
}
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  group('actual book read visibility', () {
    test('actual getter and source-verified Book merge evidence identity', () {
      final manifest = jsonDecode(File('$_evidence/manifest.json').readAsStringSync()) as Map;
      String hash(String path) => SHA256Digest().process(File(path).readAsBytesSync()).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(manifest['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
      expect(manifest['fixturesSha256'], hash('$_root/book-visibility-fixtures.json'));
      expect(manifest['harnessSha256'], hash('$_root/BookVisibilityOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_root/run_book_visibility.py'));
      expect(manifest['goldenSha256'], hash('$_evidence/golden.json'));
      expect(manifest['observations'], 8); expect(manifest['compileExit'], 0); expect(manifest['runExit'], 0);
      expect(manifest['deviceRows'], 'not-run');
    });
    test('actual bookName alias and ordinary state evidence identity', () {
      const evidence = '$_root/evidence/book-alias-host';
      final manifest = jsonDecode(File('$evidence/manifest.json').readAsStringSync()) as Map;
      String hash(String path) => SHA256Digest().process(File(path).readAsBytesSync()).map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      expect(manifest['fixturesSha256'], hash('$_root/book-alias-fixtures.json'));
      expect(manifest['harnessSha256'], hash('$_root/BookAliasOracle.kt'));
      expect(manifest['runnerSha256'], hash('$_root/run_book_alias.py'));
      expect(manifest['goldenSha256'], hash('$evidence/golden.json'));
      expect(manifest['compileExit'], 0); expect(manifest['runExit'], 0);
    });
    final aliases = (jsonDecode(File('$_root/book-alias-fixtures.json').readAsStringSync()) as List).cast<Map>();
    final aliasGolden = jsonDecode(File('$_root/evidence/book-alias-host/golden.json').readAsStringSync()) as Map;
    for (final row in aliases) {
      test('${row['name']} leaves source.get and ordinary fallback intact', () async {
        final state = SourceHostState();
        await state.putEntry(_origin, sourceRuleVariableKey(_origin, 'bookName'), 'stored');
        await state.putEntry(_origin, sourceRuleVariableKey(_origin, 'ordinary'), 'value');
        final result = await InProcessSourceScriptRuntime(hostState: state).evaluate(
          source: row['script'] as String,
          input: {'sourceKey': _origin, 'src': '{}', 'result': '{}',
            if (row['bookName'] != null) 'book': {'name': row['bookName']}},
          timeout: const Duration(seconds: 2),
        );
        expect('$result'.codeUnits, (aliasGolden[row['name']] as List).cast<int>());
      });
    }

    for (final row in _cases) {
      test('${row['name']} publishes each completed name/author getter', () async {
        final json = row['pipeline'] == 'json';
        final source = <String, dynamic>{
          'bookSourceUrl': _origin,
          'ruleBookInfo': <String, String>{
            ...(row['rules'] as Map).cast<String, String>(),
            'canReName': row['canReName'] == true ? 'yes' : '', 'tocUrl': r"{{'/toc'}}",
          },
          'ruleToc': {'chapterList': json ? r'$.list' : 'li', 'chapterName': json ? r'$.name' : 'a@text', 'chapterUrl': json ? r'$.href' : 'a@href'},
        };
        final pages = _Pages({'/book': row['content'] as String, '/toc': json
            ? '{"list":[{"name":"chapter","href":"/chapter"}]}' : '<li><a href="/chapter">chapter</a></li>'});
        final hit = HtmlBook(url: Uri.parse('$_origin/book'), title: row['initialName'] as String,
            author: row['initialAuthor'] as String, rawAddress: '$_origin/book');
        final (book, _) = json ? await JsonSourcePipeline(source, pages).details(hit)
            : await HtmlSourcePipeline(source, pages).details(hit);
        final observed = _golden[row['name']] as Map;
        expect(book.title.codeUnits, (observed['finalNameUnits'] as List).cast<int>());
        expect(book.author.codeUnits, (observed['finalAuthorUnits'] as List).cast<int>());
        expect(book.kind.codeUnits, ((observed['getterUnits'] as Map)['kind'] as List).cast<int>());
        expect(book.wordCount.codeUnits, ((observed['getterUnits'] as Map)['wordCount'] as List).cast<int>());
        expect(book.rawAddress, hit.rawAddress);
      });
    }
  });
}
