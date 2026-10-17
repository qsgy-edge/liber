import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// The content stage's read order (#104), driven through the real pipelines.
///
/// The frozen content stage reads `ruleContent.content` with
/// `AnalyzeRule.getString(contentRule.content, unescape = false)`, runs
/// `HtmlFormatter.formatKeepImg` over that text, and only then unescapes once
/// when a `&` survives (`BookContent.kt:177-181`). Before #104 this product's
/// rule read spent the one unescape itself, so the formatter's entity folding
/// (`(&nbsp;)+` → one space) could not fire and `&nbsp;` reached the stored
/// chapter text as U+00A0.
///
/// Each case below runs one real pipeline ([HtmlSourcePipeline] for the `@js:`
/// and measured-shape controls, [JsonSourcePipeline] for the escaped-tag control
/// whose rule value is a plain JSON string) and reads the chapter body, not a
/// unit helper.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const origin = 'http://example.test';

  test(
    'a script-produced content value is not entity-decoded before the formatter',
    () async {
      // `@js:` produces `甲&nbsp;乙`; the frozen's `unescape = false` read leaves
      // the entity text, so `formatKeepImg` folds it to one space. A read that had
      // already unescaped would hand the formatter `甲\u00A0乙`, which no branch
      // folds.
      final pipeline = HtmlSourcePipeline(<String, dynamic>{
        'bookSourceUrl': origin,
        'ruleContent': {'content': "@js:'甲&nbsp;乙'"},
      }, _Pages({'/chapter/1': '<div>page</div>'}));

      final body = await pipeline.chapter(
        SourceChapter('第一章', Uri.parse('$origin/chapter/1')),
      );

      expect(body.text, '甲 乙');
      expect(body.text, isNot(contains('\u00A0')));
    },
  );

  test('an escaped-tag content value keeps its tags', () async {
    // The frozen formatter sees no `<` in `&lt;p&gt;…`, and the one unescape
    // runs after it, so the reader shows the tags. The JSON adapter's rule read
    // already passes `unescape = false`; the formatter/unescape order is what
    // #104 wires for the HTML adapter too.
    const input = '&lt;p&gt;不是标签&lt;/p&gt;&amp;&nbsp;乙';
    final pipeline = JsonSourcePipeline(
      <String, dynamic>{
        'bookSourceUrl': origin,
        'ruleContent': {'content': r'$.content'},
      },
      _Pages({
        '/chapter/1': jsonEncode({'content': input}),
      }),
    );

    final body = await pipeline.chapter(
      SourceChapter('第一章', Uri.parse('$origin/chapter/1')),
    );

    expect(body.text, '<p>不是标签</p>& 乙');
  });

  test('the measured 356/179 page shape stores the folded text', () async {
    // The operator's page (修真四万年 / 七七读书1) carried 356 `&nbsp;` and 179
    // `<br />` in the content element (issue #104). This synthetic page
    // reproduces that count; the frozen's fold must clear every U+00A0 before
    // the stored text, which is the one observable difference the ordering
    // makes.
    const paragraphs = 178;
    final lines = <String>[
      for (var index = 0; index < paragraphs; index++) '&nbsp;&nbsp;第$index段',
    ];
    final html =
        '<div class="page-content" id="ChapterContents">'
        '<br />\r\n${lines.join('<br />\r\n')}<br />\r\n'
        '</div>';
    expect('&nbsp;'.allMatches(html).length, 356);
    expect('<br />'.allMatches(html).length, 179);

    final pipeline = HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': origin,
      'ruleContent': {'content': 'id.ChapterContents@html'},
    }, _Pages({'/chapter/1': html}));

    final body = await pipeline.chapter(
      SourceChapter('第一章', Uri.parse('$origin/chapter/1')),
    );

    expect(body.text, isNot(contains('\u00A0')));
    expect(body.text, isNot(contains('&')));
    expect(body.text, isNot(contains('<')));
    expect(
      body.text.split('\n').where((line) => line.contains('段')).length,
      paragraphs,
    );
  });
}

/// A site that answers one page per path, without a source session.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);

  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';
}
