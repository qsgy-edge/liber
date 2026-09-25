import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_rate_limiter.dart';

import 'native_library.dart';

/// One recording fixture site.
///
/// Implementing [SourceHttpTransport] is what gives a pipeline a source session
/// at all (`SourceHostPipeline._host`), so the rows below see exactly what an
/// image request put on the wire — the source's own headers included.
class _Site implements BookSourceTransport, SourceHttpTransport {
  _Site(this.pages, {this.image = const <int>[137, 80, 78, 71]});

  final Map<String, String> pages;
  final List<int> image;
  final requests = <SourceHttpRequest>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final bytes = Uint8List.fromList(image);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: request.readBytes ? '' : pages[request.url.path] ?? '',
      url: request.url,
      bodyBytes: request.readBytes ? bytes : null,
    );
  }
}

const _chapterHtml =
    '<div class="con">第一段<img src="/i/1.png">第二段<img src="/i/2.png">尾</div>';

Map<String, dynamic> _htmlSource(String content, {String? imageStyle}) => {
  'bookSourceUrl': 'https://a.test',
  'header': '{"X-Contract":"yes"}',
  'ruleContent': {'content': content, 'imageStyle': ?imageStyle},
};

Map<String, dynamic> _jsonSource(String content, {String? imageStyle}) => {
  'bookSourceUrl': 'https://a.test',
  'header': '{"X-Contract":"yes"}',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.name',
    'bookUrl': r'$.url',
  },
  'ruleContent': {'content': content, 'imageStyle': ?imageStyle},
};

SourceChapter _chapter() =>
    SourceChapter('第一章', Uri.parse('https://a.test/chapter/1'));

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('the content rules carry their images', () {
    test(
      'an HTML chapter body extracts every img element, keyed like its text',
      () async {
        final site = _Site({'/chapter/1': _chapterHtml});
        final pipeline = HtmlSourcePipeline(
          _htmlSource('@CSS:.con@html'),
          site,
        );

        final body = await pipeline.chapter(_chapter());

        // The frozen `AppPattern.imgPattern`'s own matches, in document order.
        expect(body.images.map((image) => image.src), ['/i/1.png', '/i/2.png']);
        for (final image in body.images) {
          // The image is keyed like the text beside it: its own range in the body
          // is where its element stands.
          expect(
            body.text.substring(image.offset, image.offset + image.length),
            '<img src="${image.src}">',
          );
        }
        // The extraction reads the text; it does not rewrite the image's own
        // address (the frozen `formatKeepImg` does, `tool/html_content_oracle`'s
        // `image-absolute-base` row — the divergence `formatChapterContent`
        // records), and the frozen formatter has taken the wrapper's tags out.
        expect(body.text, contains('<img src="/i/1.png">'));
        expect(
          body.text,
          '　　　　第一段<img src="/i/1.png">第二段<img src="/i/2.png">尾\n　　',
        );
      },
    );

    test('a JSON chapter body extracts the same elements', () async {
      final site = _Site({
        '/chapter/1': jsonEncode({'body': _chapterHtml}),
      });
      final pipeline = JsonSourcePipeline(_jsonSource(r'$.body'), site);

      final body = await pipeline.chapter(_chapter());

      expect(body.images.map((image) => image.src), ['/i/1.png', '/i/2.png']);
      expect(
        body.text.substring(
          body.images.first.offset,
          body.images.first.offset + body.images.first.length,
        ),
        '<img src="/i/1.png">',
      );
    });

    test('a chapter whose body carries no image still gets the frozen text', () async {
      final site = _Site({'/chapter/1': '<div class="con">第一段</div>'});
      final pipeline = HtmlSourcePipeline(_htmlSource('@CSS:.con@html'), site);

      final body = await pipeline.chapter(_chapter());

      expect(body.images, isEmpty);
      // No image means no image element: the text is still the frozen content
      // stage's own, which took the wrapper's tags out and indented the
      // paragraph (`BookContent.kt:178`; `tool/html_content_oracle`'s
      // `site-shape-contentdiv` and `p-tags` rows execute the same pass).
      expect(body.text, '　　　　第一段\n　　');
    });

    test('the pattern is the frozen one, its own overshoots included', () {
      const text =
          'a<img data-src="/lazy.png">b<IMG SRC="/upper.png">'
          'c<img class="x" src="/ok.png">d';

      final images = extractChapterImages(text);

      // `[^>]*src="` reads a `data-src` too — the frozen pattern's own
      // overshoot — and does not read an uppercase `<IMG` at all. Both are the
      // frozen pattern (`AppPattern.kt:12`), reproduced as it stands.
      expect(images.map((image) => image.src), ['/lazy.png', '/ok.png']);
      for (final image in images) {
        expect(
          text.substring(image.offset, image.offset + image.length),
          startsWith('<img'),
        );
      }
      expect(images.first.offset, 1);
      expect(images.first.length, '<img data-src="/lazy.png">'.length);
    });

    test('the style is the content rule\'s own value, case-insensitively', () {
      expect(
        sourceImageStyle({
          'ruleContent': {'imageStyle': 'FULL'},
        }),
        SourceImageStyle.full,
      );
      expect(
        sourceImageStyle({
          'ruleContent': {'imageStyle': 'text'},
        }),
        SourceImageStyle.text,
      );
      expect(
        sourceImageStyle({
          'ruleContent': {'imageStyle': 'Single'},
        }),
        SourceImageStyle.single,
      );
      expect(
        sourceImageStyle({
          'ruleContent': {'imageStyle': 'DEFAULT'},
        }),
        SourceImageStyle.natural,
      );
      expect(sourceImageStyle(const {}), SourceImageStyle.natural);
      // A value the frozen does not know falls to its `else` branch, which is
      // the default size; it is not trimmed toward a known one.
      expect(
        sourceImageStyle({
          'ruleContent': {'imageStyle': ' FULL '},
        }),
        SourceImageStyle.natural,
      );
    });
  });

  group('the image request goes through the source\'s own session', () {
    test(
      'the bytes come back and the source\'s header rule is on the wire',
      () async {
        final site = _Site(const {}, image: const [1, 2, 3, 4]);
        final pipeline = HtmlSourcePipeline(
          _htmlSource('@CSS:.con@html'),
          site,
        );

        final bytes = await pipeline.chapterImage(
          '/i/1.png',
          base: Uri.parse('https://a.test/chapter/1'),
        );

        expect(bytes, [1, 2, 3, 4]);
        final request = site.requests.single;
        expect('${request.url}', 'https://a.test/i/1.png');
        expect(request.method, 'GET');
        expect(request.readBytes, isTrue);
        expect(request.headers['X-Contract'], 'yes');
        expect(request.sourceRef, 'https://a.test');
      },
    );

    test('a JSON source fetches the same way', () async {
      final site = _Site(const {}, image: const [9, 9]);
      final pipeline = JsonSourcePipeline(_jsonSource(r'$.body'), site);

      final bytes = await pipeline.chapterImage('https://a.test/i/2.png');

      expect(bytes, [9, 9]);
      expect('${site.requests.single.url}', 'https://a.test/i/2.png');
      expect(site.requests.single.headers['X-Contract'], 'yes');
      expect(site.requests.single.readBytes, isTrue);
    });

    test('the source\'s rate limiter wraps the image request', () async {
      final site = _Site(const {});
      final source = _htmlSource('@CSS:.con@html');
      source['bookSourceUrl'] = 'https://rate.test';
      source['concurrentRate'] = '1000';
      final pipeline = HtmlSourcePipeline(source, site);

      await pipeline.chapterImage(
        '/i/1.png',
        base: Uri.parse('https://rate.test/c/1'),
      );

      expect(SourceRateLimiter.shared.recordOf('https://rate.test'), isNotNull);
    });

    test('the reader\'s cancellation ends the image request', () async {
      final site = _Site(const {});
      final pipeline = HtmlSourcePipeline(_htmlSource('@CSS:.con@html'), site);

      pipeline.cancel();

      await expectLater(
        pipeline.chapterImage(
          '/i/1.png',
          base: Uri.parse('https://a.test/c/1'),
        ),
        throwsA(isA<SourceRequestCancelled>()),
      );
      expect(site.requests, isEmpty);
    });

    test('a transport without a source session says so by name', () async {
      final pipeline = HtmlSourcePipeline(
        _htmlSource('@CSS:.con@html'),
        _TextOnlySite(),
      );

      await expectLater(
        pipeline.chapterImage(
          '/i/1.png',
          base: Uri.parse('https://a.test/c/1'),
        ),
        throwsA(isA<UnsupportedError>()),
      );
    });
  });
}

class _TextOnlySite implements BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => '';
}
