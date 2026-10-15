// Fixed BookInfo empty-toc fallback source controls; not frozen entity goldens.
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'native_library.dart';
const _origin = 'https://fallback-get.test';
class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.body);
  final String body;
  final requests = <SourceHttpRequest>[];
  @override
  Future<String> request({required BookSourceStage stage, required String path}) => throw StateError('Real SourceHttpTransport.send required');
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(statusCode: 200, headers: const {}, body: body, url: request.url);
  }
}
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
  for (final json in [false, true]) {
    test('H1 first empty toc uses original Book address source control json=$json', () async {
      const rawBook = '$_origin/book?keep=1,{"headers":{"X-Book":"fallback"}}';
      final state = SourceHostState();
      final source = <String, dynamic>{
        'bookSourceUrl': _origin,
        'ruleBookInfo': <String, String>{'name': '', 'tocUrl': ''},
        'ruleToc': <String, String>{
          'chapterList': json ? r'$.list' : 'li',
          'chapterName': "{{'chapter'}}",
          'chapterUrl': "{{''}}",
          'updateTime': "@js:source.put('trace',source.get('trace')+'tag:'+String(chapter.url)+';');'tag'",
          'isVolume': "@js:source.put('trace',source.get('trace')+'volume:'+String(chapter.url)+';');'false'",
          'isVip': "@js:source.put('trace',source.get('trace')+'vip:'+String(chapter.url)+';');String(chapter.url)!==''?'true':'false'",
          'isPay': "@js:source.put('trace',source.get('trace')+'pay:'+String(chapter.url)+';');String(chapter.url)!==''?'true':'false'",
        },
      };
      final pages = _Pages(json ? jsonEncode({'list': [{}]}) : '<li>chapter</li>');
      final BookSourcePipeline pipeline = json ? JsonSourcePipeline(source, pages, hostState: state) : HtmlSourcePipeline(source, pages, hostState: state);
      final (_, chapters) = await pipeline.details(HtmlBook(url: Uri.parse('$_origin/book?keep=1'), rawAddress: rawBook, title: 'book'));
      expect(await state.entry(_origin, sourceRuleVariableKey(_origin, 'trace')), 'tag:;volume:;vip:$rawBook;pay:$rawBook;');
      expect(chapters.map((c) => [c.name, c.isVip, c.isPay]).toList(), [['chapter', true, true]]);
      expect(chapters.single.url, Uri.parse('$_origin/book?keep=1'));
      expect(pages.requests.map((r) => [r.method, '${r.url}', r.headers['X-Book']]).toList(), [['GET', '$_origin/book?keep=1', 'fallback'], ['GET', '$_origin/book?keep=1', 'fallback']]);
      // This controls temporary publication; final rawAddress carrier is not
      // changed or advertised as whole frozen chapter normalization evidence.
      pipeline.cancel();
    });
  }
}
