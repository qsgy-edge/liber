import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

const _sourceUrl = 'https://example.test';
const _bookUrl = '$_sourceUrl/book';

/// One recording fixture site that answers the reader's image requests.
///
/// Implementing [SourceHttpTransport] is what gives the pipeline a source
/// session, so these rows see the wire the reader's images went over — a
/// `failImages` site is how a failed load is driven, and a
/// `rejectsCertificate` site fails certificate verification until the source's
/// stored exception reaches the request, which is how ADR 0011 §5's
/// confirmation is driven.
class _Site implements BookSourceTransport, SourceHttpTransport {
  _Site({
    required this.image,
    this.failImages = false,
    this.rejectsCertificate = false,
  });

  final Uint8List image;
  final bool failImages;
  final bool rejectsCertificate;
  final requests = <SourceHttpRequest>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => throw StateError('这个测试不经过文本请求');

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    if (rejectsCertificate && !request.allowInvalidCertificate) {
      throw SourceTlsCertificateFailure(
        sourceRef: request.sourceRef,
        host: request.url.host,
        reason: '证书无效、过期或不受信任',
      );
    }
    if (failImages) throw StateError('图片站点没有应答');
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {
        'content-type': ['image/png'],
      },
      body: '',
      url: request.url,
      bodyBytes: request.readBytes ? image : null,
    );
  }
}

/// The chapter reader's own body, with the images the extraction carries.
///
/// The chapter stage is scripted — a widget test's binding cannot settle the
/// rule adapter's bridge calls — but the extraction is the product's own, so the
/// image offsets are the ones the pipelines produce.
class _ScriptedPipeline extends HtmlSourcePipeline {
  _ScriptedPipeline({
    required _Site site,
    required String imageStyle,
    required this.body,
    required SourceHostState hostState,
  }) : super({
         'bookSourceUrl': _sourceUrl,
         'header': '{"X-Contract":"yes"}',
         'ruleContent': {'content': '@CSS:.x@html', 'imageStyle': imageStyle},
       }, site, hostState: hostState);

  final String body;

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async => HtmlChapterBody(body, 1, images: extractChapterImages(body));
}

/// One real PNG, encoded by the engine itself: `Image.memory` decodes it on
/// every platform, so a hand-written fixture cannot pass as a rendered image.
Future<Uint8List> _png(WidgetTester tester) async {
  final bytes = await tester.runAsync(() async {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawRect(
      const Rect.fromLTWH(0, 0, 60, 20),
      Paint()..color = const Color(0xFF3355AA),
    );
    final image = await recorder.endRecording().toImage(60, 20);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    return data!.buffer.asUint8List();
  });
  return bytes!;
}

/// Lets `Image.memory` run its codec, which a widget test's fake clock never
/// completes on its own, and then settles the frames it produced.
Future<void> _settleImages(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  late String bookId;

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    bookId = await shelf.ensureBook(const {
      'bookSourceUrl': _sourceUrl,
    }, HtmlBook(url: Uri.parse(_bookUrl), title: '书'));
  });

  tearDown(() => store.close());

  Future<void> mount(
    WidgetTester tester, {
    required String body,
    required _Site site,
    String imageStyle = 'DEFAULT',
    int resume = 0,
  }) async {
    await tester.pumpWidget(
      // The application's own delegates and locale: the page reads its copy
      // through `AppLocalizations` (#28).
      localizedApp(
        home: OnlineReaderPage(
          pipeline: _ScriptedPipeline(
            site: site,
            imageStyle: imageStyle,
            body: body,
            // The page's own host surface: the TLS confirmation writes the
            // exception here and the dispatcher reads it here, as they do in the
            // product, where every page builds its pipeline over the shelf's
            // state.
            hostState: shelf.hostState,
          ),
          book: HtmlBook(url: Uri.parse(_bookUrl), title: '书'),
          bookId: bookId,
          chapters: [SourceChapter('第一章', Uri.parse('$_sourceUrl/1'))],
          service: shelf,
          textOffset: resume,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The width the reader's own column gives an image: the page's column, minus
  /// the padding around the text (the reader's `_columnMaxWidth` and
  /// `_contentPadding`).
  double columnWidth(WidgetTester tester) =>
      math.min(tester.getSize(find.byType(SingleChildScrollView)).width, 760) -
      48;

  /// One image on its own line: what a source that formatted its chapter with
  /// `java.htmlFormat` hands the reader.
  const imageLine = '第一行\n<img src="https://img.test/one.png">\n第二行';

  testWidgets('the default shape keeps the image\'s own size, centred', (
    tester,
  ) async {
    final site = _Site(image: await _png(tester));
    await mount(tester, body: imageLine, site: site);
    await _settleImages(tester);

    // The element's own markup is gone: what replaced it is an image.
    expect(find.textContaining('<img'), findsNothing);
    final image = tester.getSize(find.byType(Image));
    expect(image, const Size(60, 20));
    // Centred in the column, as the frozen natural style is centred in the
    // visible page.
    expect(
      tester.getCenter(find.byType(Image)).dx,
      closeTo(tester.getCenter(find.byType(SingleChildScrollView)).dx, 1),
    );
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.scaleDown);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the FULL shape fills the reading column', (tester) async {
    final site = _Site(image: await _png(tester));
    await mount(tester, body: imageLine, site: site, imageStyle: 'FULL');
    await _settleImages(tester);

    final column = columnWidth(tester);
    final image = tester.getSize(find.byType(Image));
    expect(image.width, closeTo(column, 1));
    // The ratio is kept, taller than the screen included (the frozen
    // `visibleWidth` rule).
    expect(image.height, closeTo(column * 20 / 60, 1));
    expect(tester.widget<Image>(find.byType(Image)).fit, BoxFit.fitWidth);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the SINGLE shape gives one image one screen', (tester) async {
    const two =
        '第一行\n<img src="https://img.test/one.png">'
        '\n<img src="https://img.test/two.png">\n第二行';
    final site = _Site(image: await _png(tester));
    await mount(tester, body: two, site: site, imageStyle: 'SINGLE');
    await _settleImages(tester);

    final viewport = tester.getSize(find.byType(SingleChildScrollView));
    final images = find.byType(Image);
    expect(images, findsNWidgets(2));
    for (final element in images.evaluate()) {
      // One image per screen: each fills a viewport-high box, so two of them
      // cannot share one screen.
      expect(
        tester.getSize(find.byWidget(element.widget)).height,
        viewport.height,
      );
      expect(
        tester.widget<Image>(find.byWidget(element.widget)).fit,
        BoxFit.contain,
      );
    }
    // The two boxes are a viewport apart: the second image is not on the first
    // image's screen.
    final first = tester.getTopLeft(images.at(0)).dy;
    final second = tester.getTopLeft(images.at(1)).dy;
    expect(second - first, greaterThanOrEqualTo(viewport.height));
    expect(tester.takeException(), isNull);
  });

  testWidgets('the TEXT shape draws the image inside its own line', (
    tester,
  ) async {
    final site = _Site(image: await _png(tester));
    await mount(
      tester,
      body: '第一行<img src="https://img.test/one.png">尾行',
      site: site,
      imageStyle: 'TEXT',
    );
    await _settleImages(tester);

    // One paragraph, and the image sits where the element stood: the frozen
    // replaces the element with its placeholder character and draws the image in
    // that character's own column.
    final paragraph = tester
        .widgetList<RichText>(find.byType(RichText))
        .firstWhere((widget) => widget.text.toPlainText().contains('尾行'));
    final plain = paragraph.text.toPlainText();
    // The row's own text, with the element gone and one placeholder character
    // where it was (a `WidgetSpan`'s replacement character): the indent the
    // reader shapes its paragraphs with, the text before the image, then the
    // text after it.
    expect(plain, '　　第一行\uFFFC尾行');
    final image = tester.getSize(find.byType(Image));
    expect(image, const Size(20, 36));
    expect(tester.takeException(), isNull);
  });

  testWidgets('every image comes through the source\'s own session', (
    tester,
  ) async {
    final site = _Site(image: await _png(tester));
    await mount(tester, body: imageLine, site: site);
    await _settleImages(tester);

    final request = site.requests.single;
    expect('${request.url}', 'https://img.test/one.png');
    expect(request.method, 'GET');
    expect(request.readBytes, isTrue);
    // The source's own header rule, not a bare HTTP client's request.
    expect(request.headers['X-Contract'], 'yes');
    expect(request.sourceRef, _sourceUrl);
  });

  testWidgets('an image that does not load leaves the chapter readable', (
    tester,
  ) async {
    final site = _Site(image: await _png(tester), failImages: true);
    await mount(tester, body: imageLine, site: site);
    await tester.pumpAndSettle();

    expect(find.text('图片加载失败'), findsOneWidget);
    expect(find.textContaining('第一行'), findsOneWidget);
    expect(find.textContaining('第二行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'an image host with a bad certificate asks once, then loads',
    (tester) async {
      final site = _Site(
        image: await _png(tester),
        rejectsCertificate: true,
      );
      await mount(tester, body: imageLine, site: site);
      await tester.pumpAndSettle();

      // The image request runs under the page's own TLS confirmation, the way
      // the chapter fetch does: the user is asked once, naming the source and
      // the image's host.
      expect(find.text('证书校验失败'), findsOneWidget);
      expect(find.textContaining('img.test'), findsOneWidget);
      expect(find.textContaining('证书无效'), findsOneWidget);
      expect(site.requests.single.allowInvalidCertificate, isFalse);

      await tester.tap(find.text('继续（不安全）'));
      await _settleImages(tester);

      // The exception is remembered for this source and host, the request is
      // retried under it, and the image is what the shape draws.
      expect(
        shelf.hostState.allowsInvalidCertificate(_sourceUrl, 'img.test'),
        isTrue,
      );
      expect(site.requests, hasLength(2));
      expect(site.requests.last.allowInvalidCertificate, isTrue);
      expect(find.text('证书校验失败'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a refused certificate leaves the image as its placeholder', (
    tester,
  ) async {
    final site = _Site(image: await _png(tester), rejectsCertificate: true);
    await mount(tester, body: imageLine, site: site);
    await tester.pumpAndSettle();

    // 取消 is the dialog's default: refusing leaves validation as it was, and
    // the chapter still reads.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('图片加载失败'), findsOneWidget);
    expect(
      shelf.hostState.allowsInvalidCertificate(_sourceUrl, 'img.test'),
      isFalse,
    );
    expect(site.requests, hasLength(1));
    expect(find.textContaining('第一行'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the progress record stays the five-field one', (tester) async {
    // The reader pages the chapter body *after* `ContentProcessing` shaped it,
    // and that shaping prepends the frozen paragraph indent — two ideographic
    // spaces — to every non-empty line (`content_processing.dart`),
    // `_shapeParagraphs`. A row's own start is therefore in the processed text's
    // space (6, 45 …), never the raw body's (4, 41 …), which is what this row
    // pins: a reader that stored the raw offset would fail it.
    final lines = [
      for (var i = 0; i < 30; i++) '第$i行 中文内容。',
      '<img src="https://img.test/one.png">',
      for (var i = 30; i < 40; i++) '第$i行 中文内容。',
    ];
    const indent = 2;
    final rawStarts = <int>[];
    final processedStarts = <int>[];
    var raw = 0;
    var processed = 0;
    for (final line in lines) {
      rawStarts.add(raw);
      processedStarts.add(processed);
      raw += line.length + 1;
      processed += line.length + indent + 1;
    }
    // Well past the first screen: a mounted top position of 0 cannot pass this.
    const row = 31;
    expect(processedStarts[row], isNot(rawStarts[row]));

    final site = _Site(image: await _png(tester));
    await mount(
      tester,
      body: lines.join('\n'),
      site: site,
      resume: processedStarts[row] + 2,
    );
    await _settleImages(tester);

    // The row the reader settled on is displayed with its indent: the space the
    // recorded offset measures is this one.
    expect(find.text('　　${lines[row]}'), findsOneWidget);

    // D4's record, unchanged: an image has no position field of its own, because
    // where an image is follows from the text offset the row already stores.
    expect(store.db.progress.$columns.map((column) => column.name), [
      'book_id',
      'text_offset',
      'line_index',
      'offset_in_line',
      'text_length',
      'chapter_key',
      'chapter_index',
      'anchor',
      'updated_at',
    ]);
    final progress = (await store.progressOf(bookId))!;
    expect(progress.chapterKey, '$_sourceUrl/1');
    expect(progress.chapterIndex, 0);
    // The offset is that line's own start in the body the reader displays.
    expect(progress.textOffset, processedStarts[row]);
  });
}
