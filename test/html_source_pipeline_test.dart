import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart' show SourceChapter;
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

class SitePages implements BookSourceTransport {
  SitePages(this.pages);
  final Map<String, String> pages;
  final List<String> requests = [];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path).path;
    requests.add(url);
    return pages[url] ?? (throw StateError('Unexpected URL: $url'));
  }
}

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

    test('keeps the blank line a replacement leaves behind, indented', () async {
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

    test('leaves the text untouched when the source declares no replaceRegex', () async {
      final text = await read('<div class="content">第一段<br>第二段</div>');
      expect(text, '第一段\n第二段');
    });
  });
}
