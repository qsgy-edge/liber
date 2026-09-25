import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The frozen comparison for the content stage's HTML pass (#101).
///
/// The golden is executed evidence from the frozen `HtmlFormatter.kt` at
/// `14dd2494` on a host JVM (`tool/html_content_oracle/`), produced by running
/// the frozen `BookContent.kt:178` call — `HtmlFormatter.formatKeepImg(content,
/// rUrl)` — and the unescape that follows it over `fixtures.json`. This test
/// runs the product's ported pass (`formatChapterContent`) over the same
/// fixture inputs and compares byte for byte.
///
/// A case whose `compare` is `exact` is one both sides must answer identically.
/// The other two `compare` values are the two divergences the product carries
/// deliberately, and their rows assert *both* answers, the frozen one and this
/// product's, so neither can drift into the other:
///
/// - `img-src-verbatim`: the frozen also rewrites a kept `<img>` element's `src`
///   to an absolute address (`NetworkUtils.getAbsoluteURL(rUrl, …)`); this
///   product resolves an image's address against the chapter's own URL when it
///   fetches it (`#67`).
/// - `unescape-order`: the frozen unescapes entities *after* this pass
///   (`BookContent.kt:179-181`) and reads the rule with `unescape = false`
///   (`:177`), while this product's rule read has already unescaped once. A page
///   that wrote its tags escaped keeps them on the frozen side and loses them
///   here; the resolved forms of `&nbsp;`/`&ensp;`/`&emsp;` keep the pass from
///   folding them (#104).
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const fixturesPath = 'tool/html_content_oracle/fixtures.json';
  const goldenPath = 'tool/html_content_oracle/evidence/jvm-host/golden.json';

  final fixtures = (jsonDecode(File(fixturesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final cases = (fixtures['cases'] as List).cast<Map>();
  final golden = (jsonDecode(File(goldenPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final goldenCases = (golden['cases'] as Map).cast<String, dynamic>();

  Map row(String name) => (goldenCases[name] as Map).cast<String, dynamic>();

  test('the corpus and the golden carry the same rows', () {
    expect(
      goldenCases.keys.toSet(),
      {for (final c in cases) c['name'] as String},
      reason: 'a fixture row without a golden row cannot be compared',
    );
    expect(golden['fixtureId'], fixtures['fixtureId']);
    expect(golden['baseline'], fixtures['baseline']);
  });

  test('the ported pass matches the frozen formatter for every exact row', () {
    final exact = cases.where((c) => (c['compare'] ?? 'exact') == 'exact');
    expect(exact, isNotEmpty);
    for (final c in exact) {
      final name = c['name'] as String;
      expect(
        formatChapterContent(c['input'] as String),
        row(name)['formatted'],
        reason: '$name: ${c['note']}',
      );
    }
  });

  test(
    'an image keeps the source\'s own address where the frozen rewrites it',
    () {
      for (final c in cases.where((c) => c['compare'] == 'img-src-verbatim')) {
        final name = c['name'] as String;
        final product = formatChapterContent(c['input'] as String);
        // The frozen answer is the one the golden holds: it carries an absolute
        // address (or the `<img …>` rewrite of a look-alike tag).
        expect(row(name)['formatted'], isNot(product), reason: name);
        switch (name) {
          case 'image-absolute-base':
            expect(product, contains('<img src="/i/1.png">'), reason: name);
            expect(row(name)['formatted'], contains('http://a.test/i/1.png'));
          case 'img-prefix-tags':
            expect(product, contains('<imgs src="y">'), reason: name);
            expect(row(name)['formatted'], contains('<img src="y">'));
        }
      }
    },
  );

  test(
    'a rule value that still carries an entity is where the orders differ',
    () {
      for (final c in cases.where((c) => c['compare'] == 'unescape-order')) {
        final name = c['name'] as String;
        final product = formatChapterContent(c['input'] as String);
        // The frozen's own unescape turn, after the formatter: the escaped tags
        // reach the reader. This product's pass has no unescape of its own — its
        // rule read already spent the one unescape (`#104`).
        expect(row(name)['content'], '<p>不是标签</p>& 乙', reason: name);
        expect(product, '&lt;p&gt;不是标签&lt;/p&gt;&amp; 乙', reason: name);
      }
    },
  );

  test('the operator\'s source shape reads as text, not as tags', () async {
    final siteShape = cases.singleWhere(
      (c) => c['name'] == 'site-shape-contentdiv',
    );
    final html = siteShape['input'] as String;
    final pipeline = HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': 'http://example.test',
      'ruleContent': {'content': 'id.ChapterContents@html'},
    }, _Pages({'/chapter/1': html}));

    final body = await pipeline.chapter(
      SourceChapter('第一章', Uri.parse('http://example.test/chapter/1')),
    );

    // What the frozen content stage answers for this page (`site-shape-contentdiv`
    // in the golden): the ad `<div>` and the `<b>` are gone, every `<br />`
    // became a paragraph, and the `&nbsp;` run folded into one space that the
    // frozen's own paragraph trim then took away.
    expect(
      row('site-shape-contentdiv')['content'],
      '　　　　最新网址：x.test\n'
      '　　铁锈湖。\n'
      '　　第二十三号特种垃圾处理场。\n'
      '　　也被称为“法宝坟墓”。\n'
      '　　',
    );
    // The same page through this product. The tags are gone; each paragraph
    // keeps the four `\u00A0` the rule read left of the page's `&nbsp;` run,
    // because the frozen folds the entity text before its own unescape and this
    // product's read has already resolved it (#104).
    const resolvedNbsp = '\u00A0\u00A0\u00A0\u00A0';
    expect(
      body.text,
      '　　　　最新网址：x.test\n'
      '　　$resolvedNbsp铁锈湖。\n'
      '　　$resolvedNbsp第二十三号特种垃圾处理场。\n'
      '　　$resolvedNbsp也被称为“法宝坟墓”。\n'
      '　　',
    );
    expect(body.text, isNot(contains('<')));
    expect(body.text, isNot(contains('&')));

    // The reader's own content stage is the text the reader pages, and that is
    // where the raw difference above stops: the frozen's replace-stage line trim
    // is Kotlin's `Char.isWhitespace()`, which carries U+00A0, so the resolved
    // run is trimmed here exactly as the frozen's folded space is there. Both
    // raw texts answer the same visible text — this is the operator's page.
    final processing = ContentProcessing(
      rules: const ReplaceRuleSet(titleRules: [], contentRules: []),
      bookName: '修真四万年',
    );
    final processed = await processing.content(body.text, chapterTitle: '第一章');
    final frozenProcessed = await processing.content(
      row('site-shape-contentdiv')['content'] as String,
      chapterTitle: '第一章',
    );
    expect(
      processed.text,
      '　　最新网址：x.test\n'
      '　　铁锈湖。\n'
      '　　第二十三号特种垃圾处理场。\n'
      '　　也被称为“法宝坟墓”。',
    );
    expect(processed.text, frozenProcessed.text);
  });
}

/// A site that answers one page per path, without a source session: the
/// content stage reads the document through the rule adapter.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);

  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';
}
