// The frozen URL-mode scalar read, `AnalyzeRule.getString(rule, isUrl = true)`:
// `AnalyzeByJSoup.getString0` answers the first extraction match, and the
// field's own `##` replacement then one HTML4 unescape run over that one value
// (`AnalyzeRule.kt:293-296,304-313`, `AnalyzeByJSoup.kt:66-67`). Its scalar call
// sites are the information stage's TOC address (`BookInfo.kt:150`) and a search
// hit's book address (`BookList.kt:272`). The reads that share their extraction
// stage are not URL mode: an ordinary scalar joins every match with newlines,
// the cover address (`BookInfo.kt:135`) and a TOC item's chapter address
// (`BookChapterList.kt:216`) resolve as addresses but keep that join.
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

const _origin = 'https://url-scalar.test';
const _ascending = '$_origin/index/1/asc/1.html';
const _descending = '$_origin/index/1/desc/1.html';

class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final target = Uri.parse(path).path;
    requests.add(target);
    return pages[target] ?? (throw StateError('Unexpected request: $path'));
  }
}

/// The book page the TOC-address rows read: the real two-link `.more` pattern.
const _twoTocLinks =
    '<h1>book</h1>'
    '<a class="more" href="$_ascending">正序目录</a>'
    '<a class="more" href="$_descending">倒序目录</a>';

HtmlBook _retainedBook(String html) =>
    HtmlBook(url: Uri.parse('$_origin/book/1'), title: 'book', infoHtml: html);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('frozen URL-mode scalar read', () {
    test(
      'the information TOC address is the first match of two links',
      () async {
        final pages = _Pages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': _origin,
          'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.more@href'},
        }, pages);
        final info = await pipeline.bookInfo(_retainedBook(_twoTocLinks));
        // `book.tocUrl` is the first link, not the two matches joined by a
        // newline (`BookInfo.kt:150`).
        expect(info.tocAddress, _ascending);
        expect(info.tocUrl, _ascending);
        expect(pages.requests, isEmpty);
        pipeline.cancel();
      },
    );

    test('a search hit book address is the first match of its links', () async {
      final pages = _Pages({
        '/search':
            '<div class="result">'
            '<span class="name">回音</span>'
            '<a class="more" href="$_origin/book/1">正序</a>'
            '<a class="more" href="$_origin/book/1/2">倒序</a>'
            '</div>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': _origin,
        'searchUrl': '/search?key={{key}}',
        'ruleSearch': {
          'bookList': '.result',
          'name': '.name@text',
          'bookUrl': '.more@href',
        },
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.toc@href'},
      }, pages);
      final hit = (await pipeline.search('关键字')).single;
      // `searchBook.bookUrl = analyzeRule.getString(ruleBookUrl, isUrl = true)`
      // (`BookList.kt:272`): the hit keeps the first link.
      expect(hit.rawAddress, '$_origin/book/1');
      expect('${hit.url}', '$_origin/book/1');
      expect(pages.requests, ['/search']);
      pipeline.cancel();
    });

    test(
      'the first match takes the field replacement and one entity unescape',
      () async {
        final pages = _Pages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': _origin,
          // A `##` field that introduces an entity: the replacement runs on the
          // first match alone and the frozen read unescapes that result exactly
          // once (`AnalyzeRule.kt:304-313`).
          'ruleBookInfo': {
            'name': 'h1@text',
            'tocUrl': '.more@href##^##&amp;amp;',
          },
        }, pages);
        final info = await pipeline.bookInfo(_retainedBook(_twoTocLinks));
        expect(info.tocAddress, '&amp;$_ascending');
        expect(pages.requests, isEmpty);
        pipeline.cancel();
      },
    );

    test(
      'a scripted TOC address keeps the first match before its script',
      () async {
        final pages = _Pages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': _origin,
          'ruleBookInfo': {
            'name': 'h1@text',
            'tocUrl': '.more@href@js:result.trim()',
          },
        }, pages);
        final info = await pipeline.bookInfo(_retainedBook(_twoTocLinks));
        expect(info.tocAddress, _ascending);
        pipeline.cancel();
      },
    );

    for (final entry in {
      'a literal TOC address': "{{'&amp;amp;/toc'}}",
      'a script-only TOC address': "@js:'&amp;amp;/toc'",
    }.entries) {
      test('${entry.key} keeps one entity pass', () async {
        final pages = _Pages(const {});
        final pipeline = HtmlSourcePipeline({
          'bookSourceUrl': _origin,
          'ruleBookInfo': {'name': 'h1@text', 'tocUrl': entry.value},
        }, pages);
        final info = await pipeline.bookInfo(_retainedBook(_twoTocLinks));
        // These forms keep the tail's own entity pass (`AnalyzeRule.kt:304-313`),
        // so the URL-mode read must not add a second one.
        expect(info.tocAddress, '&amp;/toc');
        pipeline.cancel();
      });
    }
  });

  group('reads that share the extraction stage', () {
    test('an ordinary scalar still joins every match with a newline', () async {
      final pages = _Pages({
        '/book/1':
            '<h1>book</h1>'
            '<span class="writer">甲</span><span class="writer">乙</span>'
            '<a class="cover" href="/cover/a.png"></a>'
            '<a class="cover" href="/cover/b.png"></a>'
            '<a class="toc" href="/toc">目录</a>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': _origin,
        'ruleBookInfo': {
          'name': 'h1@text',
          'author': '.writer@text',
          'coverUrl': '.cover@href',
          'tocUrl': '.toc@href',
        },
      }, pages);
      final info = await pipeline.bookInfo(
        HtmlBook(url: Uri.parse('$_origin/book/1'), title: 'book'),
      );
      expect(info.book.author, '甲\n乙');
      // `BookInfo.kt:135` reads the cover with the ordinary `getString`, so its
      // two matches reach the address resolution joined, as before.
      expect(info.book.cover, '$_origin/cover/a.png%0A/cover/b.png');
      pipeline.cancel();
    });

    test('a TOC item chapter address stays an ordinary join', () async {
      final pages = _Pages({
        '/toc':
            '<div id="list"><li><span>第一章</span>'
            '<a href="/chapter/1">正文</a><a href="/chapter/2">备用</a>'
            '</li></div>',
      });
      final pipeline = HtmlSourcePipeline({
        'bookSourceUrl': _origin,
        'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '.toc@href'},
        'ruleToc': {
          'chapterList': '#list li',
          'chapterName': 'span@text',
          'chapterUrl': 'a@href',
        },
      }, pages);
      final (_, chapters) = await pipeline.details(
        _retainedBook('<h1>book</h1><a class="toc" href="/toc">目录</a>'),
      );
      expect(chapters.single.name, '第一章');
      expect(chapters.single.rawAddress, '/chapter/1\n/chapter/2');
      expect(pages.requests, ['/toc']);
      pipeline.cancel();
    });
  });
}
