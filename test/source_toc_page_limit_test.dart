// The sequential page walk, as the two rule adapters apply it (`walkSourcePages`,
// the frozen `BookChapterList.kt:48-121` and `BookContent.kt:54-135`). Neither
// stage has a page-count bound: an empty next-page declaration ends the walk,
// and the content stage also stops before the next chapter's own address. These
// rows cover 32-page TOC order, repeated-URL refusal, cancellation with page 31
// in flight, and the content walk collecting 25 ordered pages before its own
// empty declaration, next-chapter stop, repeated-URL refusal and cancellation
// past page 20.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

const _origin = 'https://toc-pages.test';
const _tocPages = 32;
const _contentPages = 25;

/// One generated body per requested path, holding [holdPath] until [gate]
/// completes so a test can cancel a walk with a page in flight. Both adapters
/// read it: HTML answers [request] text, JSON sends through [send].
class _PageServer implements BookSourceTransport, SourceHttpTransport {
  _PageServer(this.bodies, {this.holdPath, this.gate});
  final Map<String, String> bodies;
  final String? holdPath;
  final Completer<void>? gate;
  final requests = <String>[];

  Future<String> _body(String path) async {
    requests.add(path);
    if (path == holdPath) await gate!.future;
    return bodies[path] ?? (throw StateError('Unexpected path: $path'));
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => _body(Uri.parse(path).path);

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async =>
      SourceHttpResponse(
        statusCode: 200,
        headers: const {},
        body: await _body(request.url.path),
        url: request.url,
      );
}

Map<String, dynamic> _source(bool json) => {
  'bookSourceUrl': _origin,
  'ruleBookInfo': {
    'name': json ? r'$.title' : 'h1@text',
    'tocUrl': json ? r'$.toc' : '#dir a@href',
  },
  'ruleToc': {
    'chapterList': json ? r'$.list' : '#list li a',
    'chapterName': json ? r'$.label' : 'a@text',
    'chapterUrl': json ? r'$.href' : 'a@href',
    'nextTocUrl': json ? r'$.next' : '#pages a@href',
  },
  'ruleContent': {
    'content': json ? r'$.body' : '.con p@text',
    'nextContentUrl': json ? r'$.next' : '.prenext a@href',
  },
};

/// [count] sequential TOC pages; [repeatAt] makes that page declare page 5
/// again, which is a repeated address rather than a new one.
Map<String, String> _tocBodies(bool json, int count, {int? repeatAt}) => {
  '/book/1': json
      ? jsonEncode({'title': '书', 'toc': '/toc/1'})
      : '<h1>书</h1><h2 id="dir"><a href="/toc/1">目录</a></h2>',
  for (var page = 1; page <= count; page++)
    '/toc/$page': json
        ? jsonEncode({
            'list': [
              {'label': '第$page章', 'href': '/chapter/$page'},
            ],
            if (page == repeatAt)
              'next': '/toc/5'
            else if (page < count)
              'next': '/toc/${page + 1}',
          })
        : '<div id="list"><li><a href="/chapter/$page">第$page章</a></li></div>'
              '${page == repeatAt
                  ? '<div id="pages"><a class="gr" href="/toc/5">5</a></div>'
                  : page < count
                  ? '<div id="pages"><a class="gr" href="/toc/${page + 1}">下一页</a></div>'
                  : ''}',
};

/// [count] sequential content pages. [stopAt] makes that page declare no next
/// page instead of chaining on, and [repeatAt] makes it declare page 5 again,
/// which is a repeated address rather than a new page. Both adapters serve every
/// generated body, so a test can also prove which one was never requested.
Map<String, String> _contentBodies(
  bool json, {
  int count = _contentPages,
  int? stopAt,
  int? repeatAt,
}) => {
  for (var page = 1; page <= count; page++)
    '/chapter/$page': json
        ? jsonEncode({
            'body': '第$page页',
            if (page == repeatAt)
              'next': '/chapter/5'
            else if (page < count && page != stopAt)
              'next': '/chapter/${page + 1}',
          })
        : '<div class="con"><p>第$page页</p></div>'
              '${page == repeatAt
                  ? '<div class="prenext"><a href="/chapter/5">5</a></div>'
                  : page < count && page != stopAt
                  ? '<div class="prenext"><a href="/chapter/${page + 1}">下一页</a></div>'
                  : ''}',
};

List<String> _contentTexts(int from, int to) => [
  for (var page = from; page <= to; page++) '第$page页',
];

BookSourcePipeline _pipeline(
  bool json,
  Map<String, dynamic> source,
  _PageServer pages,
) => json
    ? JsonSourcePipeline(source, pages)
    : HtmlSourcePipeline(source, pages);

HtmlBook _hit() => HtmlBook(url: Uri.parse('$_origin/book/1'), title: '书');

List<String> _chapterNames(int from, int to) => [
  for (var page = from; page <= to; page++) '第$page章',
];

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  for (final json in [false, true]) {
    final adapter = json ? 'JSON' : 'HTML';

    test(
      '$adapter TOC collects $_tocPages sequential pages in order',
      () async {
        final pages = _PageServer(_tocBodies(json, _tocPages));
        final pipeline = _pipeline(json, _source(json), pages);
        final (_, chapters) = await pipeline.details(_hit());
        expect(
          chapters.map((chapter) => chapter.name),
          _chapterNames(1, _tocPages),
        );
        // The last two pages' own records, and the effective request order the
        // walk really made (the information page, then each TOC page once).
        expect(
          chapters
              .sublist(30)
              .map((chapter) => [chapter.name, '${chapter.url}']),
          [
            ['第31章', '$_origin/chapter/31'],
            ['第32章', '$_origin/chapter/32'],
          ],
        );
        expect(pages.requests, [
          '/book/1',
          for (var page = 1; page <= _tocPages; page++) '/toc/$page',
        ]);
        if (!json) expect((pipeline as HtmlSourcePipeline).tocPages, _tocPages);
      },
    );

    test('$adapter TOC refuses a repeated page past the old cutoff', () async {
      final pages = _PageServer(_tocBodies(json, _tocPages, repeatAt: 31));
      final pipeline = _pipeline(json, _source(json), pages);
      await expectLater(
        pipeline.details(_hit()),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            json ? 'TOC page cycle' : '目录分页循环',
          ),
        ),
      );
      // Page 31 was fetched, and the repeated page 5 was never asked for again.
      expect(pages.requests, [
        '/book/1',
        for (var page = 1; page <= 31; page++) '/toc/$page',
      ]);
    });

    test('$adapter TOC cancellation past page 30 stops and recovers', () async {
      final gate = Completer<void>();
      final pages = _PageServer(
        _tocBodies(json, _tocPages),
        holdPath: '/toc/31',
        gate: gate,
      );
      final pipeline = _pipeline(json, _source(json), pages);
      final pending = expectLater(
        pipeline.details(_hit()),
        throwsA(isA<SourceRequestCancelled>()),
      );
      await pumpEventQueue();
      // Thirty pages answered and page 31 is the one in flight.
      expect(pages.requests, [
        '/book/1',
        for (var page = 1; page <= 31; page++) '/toc/$page',
      ]);
      pipeline.cancel();
      gate.complete();
      await pending;
      // The following page is never requested after the cancellation.
      expect(pages.requests, isNot(contains('/toc/32')));

      // A fresh follow-up on the same generated pages completes the walk.
      final recovered = _PageServer(_tocBodies(json, _tocPages));
      final (_, chapters) = await _pipeline(
        json,
        _source(json),
        recovered,
      ).details(_hit());
      expect(
        chapters.map((chapter) => chapter.name),
        _chapterNames(1, _tocPages),
      );
      expect(recovered.requests, hasLength(_tocPages + 1));
    });

    test('$adapter content collects $_contentPages pages in order', () async {
      final pages = _PageServer(_contentBodies(json));
      final pipeline = _pipeline(json, _source(json), pages);
      final body = await pipeline.chapter(
        SourceChapter('第一章', Uri.parse('$_origin/chapter/1')),
      );
      expect(body.pages, _contentPages);
      // Every page's own text, in declared order to the last one.
      expect(body.text, _contentTexts(1, _contentPages).join('\n'));
      // Each declared page was sent once, and the last page declares nothing.
      expect(pages.requests, [
        for (var page = 1; page <= _contentPages; page++) '/chapter/$page',
      ]);
    });

    test('$adapter content ends at a page that declares nothing', () async {
      final pages = _PageServer(_contentBodies(json, stopAt: 21));
      final pipeline = _pipeline(json, _source(json), pages);
      final body = await pipeline.chapter(
        SourceChapter('第一章', Uri.parse('$_origin/chapter/1')),
      );
      expect(body.pages, 21);
      expect(body.text, _contentTexts(1, 21).join('\n'));
      // Page 22 exists but was never declared, so the walk ended on page 21.
      expect(pages.requests, [
        for (var page = 1; page <= 21; page++) '/chapter/$page',
      ]);
    });

    test(
      '$adapter content stops before the next chapter after page 20',
      () async {
        final pages = _PageServer(_contentBodies(json));
        final pipeline = _pipeline(json, _source(json), pages);
        final body = await pipeline.chapter(
          SourceChapter('第一章', Uri.parse('$_origin/chapter/1')),
          nextChapterUrl: '$_origin/chapter/21',
        );
        expect(body.pages, 20);
        expect(body.text, _contentTexts(1, 20).join('\n'));
        // Page 20 declares the next chapter's own address: the walk stops before
        // sending it, so its remaining generated pages are never requested.
        expect(pages.requests, [
          for (var page = 1; page <= 20; page++) '/chapter/$page',
        ]);
      },
    );

    test(
      '$adapter content refuses a repeated page past the old cutoff',
      () async {
        final pages = _PageServer(_contentBodies(json, repeatAt: 23));
        final pipeline = _pipeline(json, _source(json), pages);
        await expectLater(
          pipeline.chapter(
            SourceChapter('第一章', Uri.parse('$_origin/chapter/1')),
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              json ? 'Content page cycle' : '正文分页循环',
            ),
          ),
        );
        // Page 23 declared page 5 again: the refusal came before that page was
        // sent a second time.
        expect(pages.requests, [
          for (var page = 1; page <= 23; page++) '/chapter/$page',
        ]);
      },
    );

    test(
      '$adapter content cancellation past page 20 stops and recovers',
      () async {
        final gate = Completer<void>();
        final pages = _PageServer(
          _contentBodies(json),
          holdPath: '/chapter/21',
          gate: gate,
        );
        final pipeline = _pipeline(json, _source(json), pages);
        final pending = expectLater(
          pipeline.chapter(
            SourceChapter('第一章', Uri.parse('$_origin/chapter/1')),
          ),
          throwsA(isA<SourceRequestCancelled>()),
        );
        await pumpEventQueue();
        // Twenty pages answered and page 21 is the one in flight.
        expect(pages.requests, [
          for (var page = 1; page <= 21; page++) '/chapter/$page',
        ]);
        pipeline.cancel();
        gate.complete();
        await pending;
        // The following page is never requested after the cancellation.
        expect(pages.requests, isNot(contains('/chapter/22')));

        // A fresh follow-up on the same generated pages completes the walk.
        final recovered = _PageServer(_contentBodies(json));
        final body = await _pipeline(
          json,
          _source(json),
          recovered,
        ).chapter(SourceChapter('第一章', Uri.parse('$_origin/chapter/1')));
        expect(body.pages, _contentPages);
        expect(recovered.requests, hasLength(_contentPages));
      },
    );
  }
}
