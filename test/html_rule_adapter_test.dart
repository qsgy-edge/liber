import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_rule_adapter.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The adapter boundary: the frozen rule semantics run in Rust and reach Dart
/// through the bridge. Per-operation coverage of the rule layer lives in the
/// crate's own tests; these rows prove the shipped path.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const document =
      '<div class="info"><span>A</span><span>B</span><span>C</span><span>D</span></div>'
      '<ul class="chapters"><li><a href="/ad">忽略</a></li><li><a href="/1">第一章</a></li></ul>'
      '<div class="chapter_content">第一段<br>第二段<span>嵌套广告</span><br>第三段</div>'
      '<a href="/2">下一页</a>'
      '<div id="meta" data-id="42">作者：忘语</div>';

  test('one batch evaluates ordered indices, merges and attribute names', () async {
    final batch = HtmlRuleBatch(document);
    final indices = batch.documentText('indices', '.info span.1:3:0@text');
    final chapters = batch.elements('chapters', '.chapters li');
    final hrefs = batch.elementsText('hrefs', 'a@href', chapters);
    final merged = batch.documentText('merged', '#nothing@text||#meta@text');
    final interleaved = batch.documentText(
      'interleaved',
      '.info span.0:1@text%%#meta@data-id',
    );
    final own = batch.documentText('own', '.chapter_content@ownText');
    final nodes = batch.documentText('nodes', '.chapter_content@textNodes');
    final html = batch.documentText('html', '.chapters li@a@html');
    await batch.run();

    expect(indices.value, 'B\nD\nA');
    expect(chapters.length, 2);
    expect(hrefs.values, ['/ad', '/1']);
    expect(merged.value, '作者：忘语');
    expect(interleaved.value, 'A\n42\nB');
    expect(own.value, '第一段 第二段 第三段');
    expect(nodes.value, '第一段\n第二段\n第三段');
    expect(html.value, '<a href="/ad">忽略</a>\n<a href="/1">第一章</a>');
  });

  test('no-match scalar and element values skip append replacement', () async {
    final batch = HtmlRuleBatch(document);
    final missing = batch.documentText(
      'missing',
      'a.absent@href##\$##Fallback',
    );
    final chapters = batch.elements('chapters', '.chapters li');
    final urls = batch.elementsText(
      'urls',
      'a.absent@href##\$##Fallback',
      chapters,
    );
    await batch.run();

    expect(missing.value, isEmpty);
    expect(missing.hasMatch, isFalse);
    expect(urls.values, ['', '']);
  });

  test('CSS mode and legacy sub-syntax reach the same jsoup semantics', () async {
    final batch = HtmlRuleBatch(document);
    final selection = batch.elements('list', '@CSS:ul.chapters li:first-child');
    final chapter = batch.elementsText('chapter', '@CSS:a@href', selection);
    final nth = batch.elements('nth', '@CSS:.chapters li:nth-child(2)');
    final legacyClass = batch.documentText('class', 'class.info@text');
    final legacyTag = batch.elements('tag', 'tag.span');
    final contains = batch.documentText('contains', '@CSS:a:contains(第二)@href');
    await batch.run();

    expect(selection.length, 1);
    expect(chapter.values, ['/ad']);
    expect(nth.length, 1);
    expect(legacyClass.value, 'ABCD');
    expect(legacyTag.length, 5);
    expect(contains.value, isEmpty);
  });

  test('unsupported rule families fail with the reader-facing error', () async {
    final batch = HtmlRuleBatch(document);
    batch.documentText('js', 'div@js:result');
    await expectLater(batch.run(), throwsA(isA<UnsupportedError>()));
  });
}
