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

    test('collapses the blank line a replacement leaves, as the frozen does', () async {
      // The replacement's blank line is gone before the final shaping sees it:
      // the frozen content stage's own formatter runs per page, ahead of the
      // `replaceRegex` branch (`BookContent.kt:178` then `:135-142`), and its
      // `\s*\n+\s*` collapses a run of blank lines
      // (`tool/html_content_oracle`, the `blank-lines` row).
      final text = await read(
        '<div class="content">第一段<br>（广告）<br>第二段</div>',
        replaceRegex: '##（广告）',
      );
      expect(text, '　　第一段\n　　第二段');
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
