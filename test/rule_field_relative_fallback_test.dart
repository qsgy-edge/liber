// Four executed relative isUrl getter observations; pipeline raw carriers and
// normalized final URLs remain separate controls, not whole entity parity.
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

const _origin = 'https://fallback-get.test';
const _root = 'tool/rule_field_oracle';
const _evidence = '$_root/evidence/relative-fallback-host';
final _rows =
    (jsonDecode(
              File('$_root/relative-fallback-fixtures.json').readAsStringSync(),
            )
            as List)
        .cast<Map>();
final _golden =
    jsonDecode(File('$_evidence/golden.json').readAsStringSync()) as Map;
String _text(Object? units) =>
    String.fromCharCodes((units as List).cast<int>());
String _body(bool json, String name, String address) => json
    ? jsonEncode({
        'list': [
          {'name': name, 'href': address},
        ],
      })
    : '<li><a href="$address">$name</a></li>';

class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages, this.responses);
  final Map<String, String> pages, responses;
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

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  test('relative auxiliary identity and actual URL algorithm boundary', () {
    final m =
        jsonDecode(File('$_evidence/manifest.json').readAsStringSync()) as Map;
    String hash(String path) => SHA256Digest()
        .process(File(path).readAsBytesSync())
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    expect(m['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
    for (final entry in {
      'fixturesSha256': 'relative-fallback-fixtures.json',
      'harnessSha256': 'RelativeFallbackOracle.kt',
      'runnerSha256': 'run_relative_fallback.py',
    }.entries) {
      expect(m[entry.key], hash('$_root/${entry.value}'));
    }
    expect(m['goldenSha256'], hash('$_evidence/golden.json'));
    expect([m['compileExit'], m['runExit'], m['observations']], [0, 0, 4]);
    expect(m['deviceRows'], 'not-run');
  });
  for (final json in [false, true]) {
    for (final row in _rows) {
      test('H1 ${row['name']} actual relative fallback json=$json', () async {
        final next = row['stage'] == 'next';
        final relative = row['relative'] as String;
        final expected = _golden[row['name']] as Map;
        final absolute = _text(expected['baseAddress']);
        final targetPath = Uri.parse(absolute.split(',{').first).path;
        final state = SourceHostState();
        final source = <String, dynamic>{
          'bookSourceUrl': _origin,
          'ruleBookInfo': <String, String>{
            'name': '',
            'tocUrl': '@js:${jsonEncode(next ? row['inputBase'] : relative)}',
          },
          'ruleToc': <String, String>{
            'chapterList': json ? r'$.list' : 'li',
            'chapterName': json ? r'$.name' : 'a@text',
            'chapterUrl': json ? r'$.href' : 'a@href',
            'updateTime': "@js:source.put('before',String(chapter.url));'tag'",
            'isVolume': "{{'false'}}",
            'isVip': "@js:source.put('vip',String(chapter.url));'true'",
            if (next)
              'nextTocUrl':
                  "@js:source.put('nextReads',String(Number(source.get('nextReads')||'0')+1));source.get('nextReads')==='1'?${jsonEncode([relative])}:[]",
          },
        };
        final pages = _Pages(
          {
            '/book': json ? '{}' : '<p>book</p>',
            if (next) '/dir/start': _body(json, 'first', '/first'),
            targetPath: _body(json, 'chapter', ''),
          },
          {targetPath: row['responseUrl'] as String},
        );
        final BookSourcePipeline pipeline = json
            ? JsonSourcePipeline(source, pages, hostState: state)
            : HtmlSourcePipeline(source, pages, hostState: state);
        final (_, chapters) = await pipeline.details(
          HtmlBook(url: Uri.parse('$_origin/book?book=1'), title: 'book'),
        );
        final before = await state.entry(
          _origin,
          sourceRuleVariableKey(_origin, 'before'),
        );
        final vip = await state.entry(
          _origin,
          sourceRuleVariableKey(_origin, 'vip'),
        );
        final target = absolute.split(',{').first;
        final expectedUrls = [
          '$_origin/book?book=1',
          if (next) row['inputBase'] as String,
          target,
        ];
        // Return carriers retain their existing raw relative text/current URI;
        // only temporary getter value is compared to the actual auxiliary base.
        expect(
          {
            'beforeUnits': '$before'.codeUnits,
            'vipUnits': '$vip'.codeUnits,
            'requests': pages.requests
                .map((r) => [r.method, '${r.url}'])
                .toList(),
            'header': pages.requests.last.headers['X-Relative'],
          },
          {
            'beforeUnits': expected['beforeFallback'],
            'vipUnits': expected['vipUrl'],
            'requests': [
              for (final url in expectedUrls) ['GET', url],
            ],
            'header': row['options'] == true ? 'keep' : null,
          },
        );
        expect(chapters.last.rawAddress, relative);
        expect(chapters.last.url, Uri.parse(row['responseUrl'] as String));
        expect(chapters.last.name, 'chapter');
        if (next) {
          expect(
            await state.entry(
              _origin,
              sourceRuleVariableKey(_origin, 'nextReads'),
            ),
            '2',
          );
        }
        pipeline.cancel();
      });
    }
  }
}
