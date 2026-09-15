import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart';
import 'package:liber/source/html_source_rules.dart';
import 'package:liber/source/online_reading_store.dart';

void main() {
  test('Legado ordered indices, exclusion chains and direct text nodes', () {
    final doc = parse(
      '<div class="info"><span>A</span><span>B</span><span>C</span><span>D</span></div><ul class="chapters"><li><a href="/ad">忽略</a></li><li><a href="/1">第一章</a></li></ul><div class="chapter_content">第一段<br>第二段<span>嵌套广告</span><br>第三段</div><a href="/2">下一页</a>',
    );
    expect(HtmlSourceRules.text(doc, '.info span.1:3:0@text'), 'B\nD\nA');
    final chapter = HtmlSourceRules.elements(doc, '.chapters li!0@a').single;
    expect(HtmlSourceRules.text(chapter, 'href'), '/1');
    expect(HtmlSourceRules.text(chapter, 'text'), '第一章');
    expect(
      HtmlSourceRules.text(doc, '.chapter_content@textNodes'),
      '第一段\n第二段\n第三段',
    );
    expect(HtmlSourceRules.text(doc, 'text.下一页@href'), '/2');
    expect(HtmlSourceRules.text(doc, '.info span.-1@text##D'), '');
  });

  test(
    'CSS context anchor, paragraph boundaries, author and next-page distinction',
    () {
      final doc = parse(
        '<div id="list"><a href="/c1">章节一</a></div><a href="/zuozhe/?tag=x">作者：忘语</a><div class="con"><p>A&nbsp; B</p><p>中文😀</p></div><div class="prenext"><a href="/c1-2">下一页</a><a href="/c2">下一章</a></div>',
      );
      final item = HtmlSourceRules.elements(doc, '@CSS:#list a').single;
      expect(HtmlSourceRules.text(item, '@CSS:a@href'), '/c1');
      expect(HtmlSourceRules.text(item, '@CSS:a@text'), '章节一');
      expect(
        HtmlSourceRules.text(doc, '@CSS:a[href^=/zuozhe/]@text##^作者：##'),
        '忘语',
      );
      expect(HtmlSourceRules.text(doc, '@CSS:.con p@text'), 'A B\n中文😀');
      expect(
        HtmlSourceRules.text(doc, r'@CSS:.prenext a:matchesOwn(^下一页$)@href'),
        '/c1-2',
      );
      expect(
        HtmlSourceRules.text(
          parse('<div class="prenext"><a href="/c2">下一章</a></div>'),
          r'@CSS:.prenext a:matchesOwn(^下一页$)@href',
        ),
        isEmpty,
      );
    },
  );

  test(
    'reading state survives a new store and serializes rapid position writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('liber-online-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final store = OnlineReadingStore(file: file);
      Map<String, dynamic> record(int offset) => {
        'source': {'bookSourceUrl': 'https://example.test'},
        'book': {'title': '书', 'url': 'https://example.test/book'},
        'chapterUrl': 'https://example.test/c2',
        'textOffset': offset,
      };
      await Future.wait([
        store.save(record(30)),
        store.save(record(100)),
        store.save(record(60)),
      ]);
      expect((await OnlineReadingStore(file: file).load())!['textOffset'], 60);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );
}
