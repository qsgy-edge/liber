import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart' show SourceChapter;
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_stage_diagnostic.dart';

import 'native_library.dart';

class SitePages implements BookSourceTransport {
  SitePages(this.pages, {this.gatePath, this.gate});
  final Map<String, String> pages;

  /// A path whose response is held until [gate] completes, so a test can cancel
  /// a page walk between two pages.
  final String? gatePath;
  final Completer<void>? gate;
  final List<String> requests = [];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path).path;
    requests.add(url);
    if (url == gatePath) await gate!.future;
    return pages[url] ?? (throw StateError('Unexpected URL: $url'));
  }
}

/// The book detail page, TOC entry and chapter body shapes the multi-URL tests
/// build their pages from.
Map<String, dynamic> _pageSource({
  String? nextTocUrl,
  String? nextContentUrl,
}) => {
  'bookSourceUrl': 'https://a.test',
  'ruleBookInfo': {
    'name': '@CSS:h1 a@text',
    'tocUrl': '@CSS:#dir a@href',
  },
  'ruleToc': {
    'chapterList': '@CSS:#list li a',
    'chapterName': '@CSS:a@text',
    'chapterUrl': '@CSS:a@href',
    'nextTocUrl': ?nextTocUrl,
  },
  'ruleContent': {
    'content': '@CSS:.con p@text',
    'nextContentUrl': ?nextContentUrl,
  },
};

const _bookPage =
    '<h1><a>书</a></h1><h2 id="dir"><a href="/toc/1">目录</a></h2>';
const _tocLink = '/toc/1';
const _listPage =
    '<div id="list"><li><a href="/chapter/1">第一章</a></li></div>';
const _pages = '<div id="pages">'
    '<a class="gr" href="/toc/1">1</a>'
    '<a class="gr" href="/toc/3">3</a>'
    '<a class="gr" href="/toc/2">2</a>'
    '<a class="gr" href="/toc/2">2</a>'
    '</div>';

HtmlBook _hit() =>
    HtmlBook(url: Uri.parse('https://a.test/book/1'), title: '书');

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'reader regression: HTML body script precedes next rule substitution',
    () async {
      final transport = SitePages({
        '/chapter/1':
            '<div class="con">FIRST</div><a class="next" href="/chapter/2">next</a>',
        '/chapter/2': '<div class="con">SECOND</div>',
      });
      final source = _pageSource(
        nextContentUrl: '{{source.get("nextRule") || "/missing"}}',
      );
      (source['ruleContent'] as Map)['content'] =
          '@js: source.put("nextRule", java.getString(".con@text") == "FIRST" ? "/chapter/2" : "/chapter/3"); java.getString(".con@text")';
      final body = await HtmlSourcePipeline(source, transport).chapter(
        SourceChapter('TOC', Uri.parse('https://a.test/chapter/1')),
        nextChapterUrl: 'https://a.test/chapter/3',
      );
      expect(body.text, contains('SECOND'));
      expect(transport.requests, ['/chapter/1', '/chapter/2']);
    },
  );

  test(
    'reader regression: erased HTML content fails and volume survives',
    () async {
      final transport = SitePages({
        '/chapter/1': '<div class="con"><p>ADVERTISEMENT</p></div>',
      });
      final source = _pageSource();
      (source['ruleContent'] as Map)['replaceRegex'] = '##ADVERTISEMENT##';
      final chapter = SourceChapter(
        'TOC',
        Uri.parse('https://a.test/chapter/1'),
      );
      await expectLater(
        HtmlSourcePipeline(source, transport).chapter(chapter),
        throwsA(isA<SourceStageDiagnostic>()),
      );
      expect(
        (await HtmlSourcePipeline(source, transport).chapter(
          SourceChapter('TOC', chapter.url, isVolume: true),
        )).text.trim(),
        isEmpty,
      );
    },
  );
  test(
    'reader regression: joined HTML replacement unescapes entities',
    () async {
      final transport = SitePages({
        '/chapter/1': '<div class="con"><p>ADVERTISEMENT</p></div>',
      });
      final source = _pageSource();
      (source['ruleContent'] as Map)['replaceRegex'] =
          '##ADVERTISEMENT##&copy;';
      final chapter = SourceChapter(
        'TOC',
        Uri.parse('https://a.test/chapter/1'),
      );
      expect(
        (await HtmlSourcePipeline(source, transport).chapter(chapter)).text,
        contains('©'),
      );
    },
  );

  test(
    'reader regression: blank page, erased body and HTML4 replacement',
    () async {
      final transport = SitePages({
        '/chapter/1': '<div class="con"></div><a href="/chapter/2">next</a>',
        '/chapter/2': '<div class="con"><p>READABLE</p></div>',
      });
      final source = _pageSource(nextContentUrl: '@CSS:a@href');
      final pipeline = HtmlSourcePipeline(source, transport);
      final chapter = SourceChapter(
        'TOC',
        Uri.parse('https://a.test/chapter/1'),
      );
      final body = await pipeline.chapter(chapter);
      expect(body.text, contains('READABLE'));
      expect(transport.requests, ['/chapter/1', '/chapter/2']);

      transport.pages['/chapter/1'] =
          '<div class="con"><p>ADVERTISEMENT</p></div>';
      (source['ruleContent'] as Map)['replaceRegex'] = '##ADVERTISEMENT##';
      (source['ruleContent'] as Map)['title'] = '@js: "NEW TITLE"';
      await expectLater(
        HtmlSourcePipeline(source, transport).chapter(chapter),
        throwsA(isA<SourceStageDiagnostic>()),
      );
      final volume = SourceChapter('TOC', chapter.url, isVolume: true);
      expect(
        (await HtmlSourcePipeline(source, transport).chapter(volume)).title,
        'NEW TITLE',
      );
      (source['ruleContent'] as Map)['replaceRegex'] =
          '##ADVERTISEMENT##&copy;';
      expect(
        (await HtmlSourcePipeline(source, transport).chapter(chapter)).text,
        contains('©'),
      );
    },
  );

  test(
    'source JSON drives all directory pages and only same-chapter content pages',
    () async {
      final source =
          (jsonDecode(await File('book_sources/shudugu.json').readAsString())
                      as List)
                  .first
              as Map<String, dynamic>;
      final transport = SitePages({
        '/i/sor.aspx':
            '<div class="container"><div class="item"><div class="itemtxt"><h3><a href="/book/">书</a></h3></div></div></div>',
        '/book/':
            '<div class="itemtxt"><h1><a>书</a></h1></div><h2 id="dir"><a href="/toc/1">目录</a></h2>',
        '/toc/1':
            '<div id="list"><li><a href="/chapter/1">第一章</a></li></div><div id="pages"><a class="gr" href="/toc/2">下一页</a></div>',
        '/toc/2': '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>',
        '/chapter/1':
            '<div class="con"><p>第一页</p></div><div class="prenext"><a href="/chapter/1-2">下一页</a></div>',
        '/chapter/1-2':
            '<div class="con"><p>第二页</p></div><div class="prenext"><a href="/chapter/2">下一章</a></div>',
      });
      final pipeline = HtmlSourcePipeline(source, transport);
      final hits = await pipeline.search('书');
      final (book, chapters) = await pipeline.details(hits.single);
      expect(book.title, '书');
      expect(pipeline.tocPages, 2);
      expect(chapters.map((c) => c.name), ['第一章', '第二章']);
      final body = await pipeline.chapter(chapters.first);
      expect(body.text, '第一页\n第二页');
      expect(body.pages, 2);
      expect(transport.requests, isNot(contains('/chapter/2')));
      transport.pages['/chapter/1-2'] =
          '<div class="con"><p>循环</p></div><div class="prenext"><a href="/chapter/1">下一页</a></div>';
      await expectLater(pipeline.chapter(chapters.first), throwsStateError);
    },
  );

  test('ordinary HTML title failure keeps body and reports once', () async {
    final messages = <SourceHostMessage>[];
    final chapter = SourceChapter('目录标题', Uri.parse('https://a.test/c/1'));
    final pipeline = HtmlSourcePipeline({
      'bookSourceUrl': 'https://a.test',
      'ruleContent': {
        'content': '@CSS:p@text',
        'title': '@js: throw new Error("optional title failed")',
      },
    }, SitePages({'/c/1': '<p>HTML BODY</p>'}))..onHostMessage = messages.add;

    final body = await pipeline.chapter(chapter);
    expect(body.text.trim(), 'HTML BODY');
    expect(body.title ?? chapter.name, '目录标题');
    expect(messages.single.message, contains('optional title failed'));
  });

  for (final cancelInNotice in [false, true]) {
    test(
      '${cancelInNotice ? "cancel on title diagnostic" : "refuse hatch scheme"} in HTML title',
      () async {
        final rule = cancelInNotice
            ? '@js: throw new Error("optional title")'
            : '@js: java.openUrl("file:///not-an-http-address", "title")';
        const base = 'https://a.test';
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': base,
          'ruleContent': {'content': '@CSS:p@text', 'title': rule},
        }, SitePages({'/c/1': '<p>BODY</p>'}));
        final notices = <SourceHostMessage>[];
        pipeline.onHostMessage = (notice) {
          notices.add(notice);
          if (cancelInNotice && notice.kind == 'ruleContent.title') {
            pipeline.cancel();
          }
        };
        addTearDown(pipeline.cancel);
        final chapter = SourceChapter('目录标题', Uri.parse('$base/c/1'));
        await expectLater(
          pipeline.chapter(chapter),
          throwsA(
            cancelInNotice
                ? isA<SourceRequestCancelled>()
                : isA<SourceScriptError>()
                      .having((e) => e.category, 'category', 'host-input')
                      .having((e) => e.message, 'member', contains('java.openUrl')),
          ),
        );
        expect(notices.where((m) => m.kind == 'ruleContent.title'),
            hasLength(cancelInNotice ? 1 : 0));
      },
    );
  }

  for (final (category, rule) in [
    ('policy', '@js: java.readFile("not-used.txt")'),
    ('cancelled', '@js: java.toast("cancel title"); "unpublished"'),
    ('timeout', '@js: while (true) {}'),
  ]) {
    test(
      'HTML title $category still fails the chapter load',
      () async {
        const base = 'https://a.test';
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': base,
          'ruleContent': {'content': '@CSS:p@text', 'title': rule},
        }, SitePages({'/c/1': '<p>HTML BODY</p>'}));
        final messages = <SourceHostMessage>[];
        pipeline.onHostMessage = (message) {
          messages.add(message);
          if (category == 'cancelled' && message.kind == 'toast') {
            pipeline.cancel();
          }
        };
        addTearDown(pipeline.cancel);
        final chapter = SourceChapter('目录标题', Uri.parse('$base/c/1'));
        final error = isA<SourceScriptError>().having(
          (error) => error.category,
          'category',
          category,
        );
        await expectLater(
          pipeline.chapter(chapter),
          throwsA(
            category == 'policy'
                ? error.having(
                    (error) => error.message,
                    'member',
                    contains('java.readFile'),
                  )
                : error,
          ),
        );
        expect(messages.where((m) => m.kind == 'ruleContent.title'), isEmpty);
        if (category == 'cancelled') {
          expect(messages.single.message, 'cancel title');
        }
      },
      timeout: const Timeout(Duration(seconds: 55)),
    );
  }

  test(
    'the content title reads after the joined body and replacement',
    () async {
      // The selected content stage joins the pages and runs the declared
      // replacement before it reads `ruleContent.title` (`BookContent.kt:65-69`,
      // `:169-182`), against the first page's document. The content script
      // writes the state the title reads; the second page carries a different
      // title marker, so a last-page read would answer `第二页标题`.
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1': _listPage,
        '/chapter/1':
            '<h2 class="chapter-title">第一页标题</h2>'
            '<div class="content">HTML BODY（广告）</div>'
            '<a class="next" href="/chapter/2">下一页</a>',
        '/chapter/2':
            '<h2 class="chapter-title">第二页标题</h2>'
            '<div class="content">HTML PAGE2</div>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': 'https://a.test',
        'ruleBookInfo': {
          'name': '@CSS:h1 a@text',
          'tocUrl': '@CSS:#dir a@href',
        },
        'ruleToc': {
          'chapterList': '@CSS:#list li a',
          'chapterName': '@CSS:a@text',
          'chapterUrl': '@CSS:a@href',
        },
        'ruleContent': {
          'content':
              '@js: source.put("seenHtml","content"); '
              'java.getString(".content@text")',
          'nextContentUrl': '.next@href',
          'replaceRegex': '##（广告）##{{source.put("seenHtml","replace");""}}',
          'title':
              '@js: (source.get("seenHtml") || "none") + "|" + '
              'java.getString(".chapter-title@text")',
        },
      }, transport);
      final (_, chapters) = await pipeline.details(_hit());
      final body = await pipeline.chapter(chapters.single);
      expect(body.title, 'replace|第一页标题');
      expect(body.text, '　　HTML BODY\n　　HTML PAGE2');
    },
  );

  test(
    'ordinary intros use the empty paragraph indent and retain an empty details rule',
    () async {
      // `BookList.kt:260` and `BookInfo.kt:123` call `HtmlFormatter.formatIntro`,
      // whose only difference from `format` is the empty paragraph indent
      // (`HtmlFormatter.kt:35-50`). A blank information-intro rule keeps the
      // already formatted search intro (`BookInfo.kt:123-130`).
      final transport = SitePages({
        '/search':
            '<div class="results"><div class="item">'
            '<a href="/book/1">书</a>'
            '<span class="intro"><p>搜索简介&nbsp;&nbsp;A</p></span>'
            '</div></div>',
        '/book/1': _bookPage,
        '/toc/1': _listPage,
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': 'https://a.test',
        'searchUrl': '/search?keyword={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': '@CSS:.results .item',
          'name': '@CSS:a@text',
          'bookUrl': '@CSS:a@href',
          'intro': '@CSS:span.intro@html',
        },
        'ruleBookInfo': {
          'name': '@CSS:h1 a@text',
          'tocUrl': '@CSS:#dir a@href',
          'intro': '',
        },
        'ruleToc': {
          'chapterList': '@CSS:#list li a',
          'chapterName': '@CSS:a@text',
          'chapterUrl': '@CSS:a@href',
        },
      }, transport);
      final hit = (await pipeline.search('书')).single;
      expect(hit.intro, '搜索简介\u00A0\u00A0A');
      final (book, _) = await pipeline.details(hit);
      expect(book.intro, '搜索简介\u00A0\u00A0A');
    },
  );

  group('multi-URL page results (BookChapterList.kt:48-121, BookContent.kt:54-135)', () {
    test('a multi-match nextTocUrl runs its ## field once per item', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        // The `##` field prefixes each matched href. The join would take the
        // prefix once, on its first line, so `/x/2` would never be asked for.
        '/toc/1':
            '$_listPage<div id="pages">'
            '<a class="gr" href="1">1</a>'
            '<a class="gr" href="2">2</a>'
            '</div>',
        '/x/1': '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>',
        '/x/2': '<div id="list"><li><a href="/chapter/3">第三章</a></li></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextTocUrl: '@CSS:#pages a.gr@href##^##/x/'),
        transport,
      );
      final (_, chapters) = await pipeline.details(_hit());
      expect(chapters.map((chapter) => chapter.name), [
        '第一章',
        '第二章',
        '第三章',
      ]);
      expect(pipeline.tocPages, 3);
      expect(transport.requests, ['/book/1', _tocLink, '/x/1', '/x/2']);
    });

    test(
      'a multi-match nextContentUrl runs its ## field once per item',
      () async {
        final transport = SitePages({
          '/book/1': _bookPage,
          '/toc/1': _listPage,
          '/chapter/1':
              '<div class="con"><p>第一页</p></div>'
                  '<div class="prenext">'
                  '<a href="1-2">2</a>'
                  '<a href="1-3">3</a>'
                  '</div>',
          '/c/1-2': '<div class="con"><p>第二页</p></div>',
          '/c/1-3': '<div class="con"><p>第三页</p></div>',
        });
        final pipeline = HtmlSourcePipeline(
          _pageSource(nextContentUrl: '@CSS:.prenext a@href##^##/c/'),
          transport,
        );
        final (_, chapters) = await pipeline.details(_hit());
        final body = await pipeline.chapter(chapters.single);
        expect(body.text, '第一页\n第二页\n第三页');
        expect(body.pages, 3);
        expect(transport.requests.skip(3).toList(), ['/c/1-2', '/c/1-3']);
      },
    );

    test(
      'an entity-bearing page address stays as the list read leaves it',
      () async {
        final transport = SitePages({
          '/book/1': _bookPage,
          // `&amp;amp;` parses once into `&amp;`; only the *single-value* read
          // unescapes that step, and the frozen list read does not.
          '/toc/1':
              '$_listPage<div id="pages">'
              '<a class="gr" href="/toc/a&amp;amp;b">1</a>'
              '</div>',
          '/toc/a&amp;b':
              '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>',
        });
        final pipeline = HtmlSourcePipeline(
          _pageSource(nextTocUrl: '@CSS:#pages a.gr@href'),
          transport,
        );
        final (_, chapters) = await pipeline.details(_hit());
        expect(chapters.map((chapter) => chapter.name), ['第一章', '第二章']);
        expect(transport.requests, ['/book/1', _tocLink, '/toc/a&amp;b']);
      },
    );

    test(
      'a declared TOC list is fetched whole, in declared order, and read no further',
      () async {
        final transport = SitePages({
          '/book/1': _bookPage,
          '/toc/1': '$_listPage$_pages',
          // Page 3 declares page 9 of its own: the declared branch reads no
          // page's list, so page 9 must never be fetched.
          '/toc/3':
              '<div id="list"><li><a href="/chapter/3">第三章</a></li></div>'
                  '<div id="pages"><a class="gr" href="/toc/9">9</a></div>',
          '/toc/2':
              '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>',
        });
        final pipeline = HtmlSourcePipeline(
          _pageSource(nextTocUrl: '@CSS:#pages a.gr@href'),
          transport,
        );
        final (_, chapters) = await pipeline.details(_hit());
        // Declared order (3 before 2), the page's own URL dropped, and the
        // repeated `/toc/2` collapsed to its first occurrence.
        expect(chapters.map((chapter) => chapter.name), [
          '第一章',
          '第三章',
          '第二章',
        ]);
        expect(pipeline.tocPages, 3);
        expect(transport.requests, ['/book/1', _tocLink, '/toc/3', '/toc/2']);
      },
    );

    test('a followed TOC page follows only the first URL of its own list', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        // One URL on the first page keeps the sequential walk.
        '/toc/1':
            '$_listPage<div id="pages"><a class="gr" href="/toc/2">2</a></div>',
        // The page the walk follows declares two; the frozen follows only the
        // first of them (`firstOrNull`), so `/toc/5` is never fetched.
        '/toc/2':
            '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>'
                '<div id="pages">'
                '<a class="gr" href="/toc/4">4</a>'
                '<a class="gr" href="/toc/5">5</a>'
                '</div>',
        '/toc/4':
            '<div id="list"><li><a href="/chapter/4">第四章</a></li></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextTocUrl: '@CSS:#pages a.gr@href'),
        transport,
      );
      final (_, chapters) = await pipeline.details(_hit());
      expect(chapters.map((chapter) => chapter.name), [
        '第一章',
        '第二章',
        '第四章',
      ]);
      expect(transport.requests, ['/book/1', _tocLink, '/toc/2', '/toc/4']);
    });

    test('a TOC page that names the first page again is refused, not looped', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1':
            '$_listPage<div id="pages"><a class="gr" href="/toc/2">2</a></div>',
        '/toc/2':
            '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>'
                '<div id="pages"><a class="gr" href="/toc/1">1</a></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextTocUrl: '@CSS:#pages a.gr@href'),
        transport,
      );
      await expectLater(pipeline.details(_hit()), throwsStateError);
      expect(transport.requests, ['/book/1', _tocLink, '/toc/2']);
    });

    test('a declared content list is merged in order and joined', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1': _listPage,
        '/chapter/1':
            '<div class="con"><p>第一页</p></div>'
                '<div class="prenext">'
                '<a href="/chapter/1-3">3</a>'
                '<a href="/chapter/1-2">2</a>'
                '</div>',
        '/chapter/1-3': '<div class="con"><p>第三页</p></div>',
        '/chapter/1-2': '<div class="con"><p>第二页</p></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextContentUrl: '@CSS:.prenext a@href'),
        transport,
      );
      final (_, chapters) = await pipeline.details(_hit());
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '第一页\n第三页\n第二页');
      expect(body.pages, 3);
      expect(transport.requests.skip(3), ['/chapter/1-3', '/chapter/1-2']);
    });

    test('the one-URL content walk stops before the next chapter page', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1': _listPage,
        '/chapter/1':
            '<div class="con"><p>第一页</p></div>'
                '<div class="prenext"><a href="/chapter/2">下一章</a></div>',
        '/chapter/2': '<div class="con"><p>下一章正文</p></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextContentUrl: '@CSS:.prenext a@href'),
        transport,
      );
      final (_, chapters) = await pipeline.details(_hit());
      final body = await pipeline.chapter(
        chapters.single,
        nextChapterUrl: 'https://a.test/chapter/2',
      );
      expect(body.text, '第一页');
      expect(body.pages, 1);
      expect(transport.requests, isNot(contains('/chapter/2')));
    });

    test('without a next chapter URL the walk has no boundary to stop at', () async {
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1': _listPage,
        '/chapter/1':
            '<div class="con"><p>第一页</p></div>'
                '<div class="prenext"><a href="/chapter/2">下一章</a></div>',
        '/chapter/2': '<div class="con"><p>下一章正文</p></div>',
      });
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextContentUrl: '@CSS:.prenext a@href'),
        transport,
      );
      final (_, chapters) = await pipeline.details(_hit());
      // No caller supplied a next chapter, so the guard has nothing to compare
      // with and the page is fetched: the frozen reads its store there instead.
      final body = await pipeline.chapter(chapters.single);
      expect(body.text, '第一页\n下一章正文');
      expect(body.pages, 2);
    });

    test(
      'a declared content list is not stopped by the next chapter URL (frozen list branch)',
      () async {
        final transport = SitePages({
          '/book/1': _bookPage,
          '/toc/1': _listPage,
          '/chapter/1':
              '<div class="con"><p>第一页</p></div>'
                  '<div class="prenext">'
                  '<a href="/chapter/1-2">2</a>'
                  '<a href="/chapter/2">下一章</a>'
                  '</div>',
          '/chapter/1-2': '<div class="con"><p>第二页</p></div>',
          '/chapter/2': '<div class="con"><p>下一章正文</p></div>',
        });
        final pipeline = HtmlSourcePipeline(
          _pageSource(nextContentUrl: '@CSS:.prenext a@href'),
          transport,
        );
        final (_, chapters) = await pipeline.details(_hit());
        // Reproduced from the frozen: `BookContent.kt:114-127` reads the
        // next-chapter guard only in its one-URL branch, so a two-URL list
        // fetches the next chapter's page and appends its body. A source that
        // wants that boundary must write a rule matching one page.
        final body = await pipeline.chapter(
          chapters.single,
          nextChapterUrl: 'https://a.test/chapter/2',
        );
        expect(body.text, '第一页\n第二页\n下一章正文');
        expect(body.pages, 3);
      },
    );

    test('cancelling between two declared pages stops the walk', () async {
      final gate = Completer<void>();
      final transport = SitePages({
        '/book/1': _bookPage,
        '/toc/1': '$_listPage$_pages',
        '/toc/3':
            '<div id="list"><li><a href="/chapter/3">第三章</a></li></div>',
        '/toc/2':
            '<div id="list"><li><a href="/chapter/2">第二章</a></li></div>',
      }, gatePath: '/toc/3', gate: gate);
      final pipeline = HtmlSourcePipeline(
        _pageSource(nextTocUrl: '@CSS:#pages a.gr@href'),
        transport,
      );
      final pending = pipeline.details(_hit());
      await pumpEventQueue();
      expect(transport.requests, ['/book/1', _tocLink, '/toc/3']);
      pipeline.cancel();
      gate.complete();
      await expectLater(pending, throwsA(isA<SourceRequestCancelled>()));
      // The page after the one in flight is never requested.
      expect(transport.requests, isNot(contains('/toc/2')));
    });
  });

  group('content stage final shaping (BookContent.kt:135-142)', () {
    Future<String> read(
      String html, {
      String? replaceRegex,
      String content = '.content@textNodes',
    }) async {
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://example.test',
        'ruleContent': {
          'content': content,
          'replaceRegex': ?replaceRegex,
        },
      };
      final pipeline = HtmlSourcePipeline(
        source,
        SitePages({'/chapter/1': html}),
      );
      final body = await pipeline.chapter(
        SourceChapter('第一章', Uri.parse('http://example.test/chapter/1')),
      );
      return body.text;
    }

    test('prefixes hard-coded indentation on every line when declared', () async {
      final text = await read(
        '<div class="content">第一段<br>第二段<br>第三段</div>',
        replaceRegex: '##（广告）',
      );
      expect(text, '　　第一段\n　　第二段\n　　第三段');
    });

    test('keeps the blank line a replacement leaves, as the frozen does', () async {
      // The trim the frozen stage runs before its replacement removes the
      // formatter's own indent, not the line: the emptied line survives into the
      // indented result, and the stage never re-formats after it
      // (`BookContent.kt:136-141`; `tool/html_content_oracle`, the
      // `marker-alone-on-a-line` row of `replace-golden.json`). This row pinned
      // the product's older order — the replacement inside the appended `##`
      // rule, ahead of the formatter — and the frozen bytes contradict it (#106).
      final text = await read(
        '<div class="content">第一段<br>（广告）<br>第二段</div>',
        replaceRegex: '##（广告）',
      );
      expect(text, '　　第一段\n　　\n　　第二段');
    });

    test('shapes the trailing empty line a trailing newline produces', () async {
      final text = await read(
        '<div class="content">第一段<br>（广告）</div>',
        replaceRegex: '##（广告）',
      );
      expect(text, '　　第一段\n　　');
    });

    test('indents the paragraphs of a source that declares no replaceRegex', () async {
      // The frozen content stage formats every page whatever the source
      // declares, so line two carries the formatter's indent even though the
      // `replaceRegex` branch never runs (`BookContent.kt:178`;
      // `tool/html_content_oracle`, the `blank-lines` and `crlf-lines` rows).
      final text = await read('<div class="content">第一段<br>第二段</div>');
      expect(text, '第一段\n　　第二段');
    });
  });

  test('a rule field\'s script failure names the field it ran in', () async {
    final transport = SitePages({
      '/search': '<div class="item"><h3><a href="/book/1">书</a></h3></div>',
    });
    final pipeline = HtmlSourcePipeline({
      'bookSourceUrl': 'https://a.test',
      'searchUrl': '/search?key={{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        // An `@js:` segment, which this path runs on the value the extraction
        // produced (`RuleField.apply`) — the field's own context carries the
        // label there, not just at substitution time.
        'name': '@CSS:h3 a@text@js:throw new Error("boom")',
        'bookUrl': '@CSS:h3 a@href',
      },
    }, transport);
    await expectLater(
      pipeline.search('书'),
      throwsA(
        isA<SourceScriptError>()
            .having((error) => error.category, 'category', 'js')
            .having(
              (error) => error.message,
              'message',
              contains('ruleSearch.name'),
            )
            .having((error) => error.message, 'message', contains('boom')),
      ),
    );
  });
}
