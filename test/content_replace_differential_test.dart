import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart' show SourceChapter;
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';

/// One page's body, as the frozen corpus declares it.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path).path;
    return pages[url] ?? (throw StateError('Unexpected URL: $url'));
  }
}

/// The frozen comparison for the content stage's *replace pass* (#106).
///
/// The golden is executed evidence from the frozen revision at `14dd2494` on a
/// host JVM (`tool/html_content_oracle/`): the frozen `AnalyzeRule` rule path and
/// the frozen script engine (the revision's own Rhino 1.8.0) run
/// `BookContent.kt:133-142` — trim every line of the joined page text, read the
/// trimmed text through `ruleContent.replaceRegex`, then prefix every line,
/// empty lines included, with `"　　"` — over `replace_fixtures.json`. This test
/// builds a source from each fixture row, runs the product's content stage over
/// the same page, and compares the chapter text byte for byte.
///
/// The corpus is synthetic: it carries the *shapes* the operator's used sources
/// declare (`tool/refusal_shapes.dart` measured 3 records with a `{{…}}`
/// expression beyond `{{chapter.title}}` inside the replacement and 2 with a
/// `##` field on the content rule beside a non-empty replacement), never their
/// rule text, and the frozen's own binding names — `title`, `book.author`,
/// `chapter.title`, `result` — are what the rows exercise.
///
/// A row whose `compare` is not `exact` is a divergence the product carries
/// deliberately; its test asserts *both* answers, the frozen one and this
/// product's, so neither can drift into the other:
///
/// - `entity-unescaped-by-the-frozen-read`: the stage's read is
///   `getString(replaceRegex, text)` with its default `unescape = true`
///   (`AnalyzeRule.kt:289-296`), which decodes an entity the replacement
///   introduced through Apache Commons' HTML4 table. The product's replacement
///   runs in Dart over the adapter's value and leaves the entity text; the
///   read-level entity pass is #104.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  const fixturesPath = 'tool/html_content_oracle/replace_fixtures.json';
  const goldenPath =
      'tool/html_content_oracle/evidence/jvm-host/replace-golden.json';

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

  /// The stage's own answer for one fixture row.
  Future<String> productText(Map c) async {
    final pageUrl = c['pageUrl'] as String;
    final source = <String, dynamic>{
      'bookSourceUrl': 'http://example.test',
      'ruleContent': {
        'content': c['contentField'],
        'replaceRegex': c['replaceRegex'],
      },
    };
    final pipeline = HtmlSourcePipeline(
      source,
      _Pages({Uri.parse(pageUrl).path: c['pageHtml'] as String}),
    );
    final body = await pipeline.chapter(
      SourceChapter(c['chapterTitle'] as String, Uri.parse(pageUrl)),
      book: HtmlBook(
        url: Uri.parse('http://example.test/book/1'),
        title: c['bookName'] as String,
        author: c['bookAuthor'] as String,
      ),
    );
    return body.text;
  }

  test('the stage matches the frozen replace pass for every exact row', () async {
    final exact = cases.where((c) => (c['compare'] ?? 'exact') == 'exact');
    expect(exact, isNotEmpty);
    for (final c in exact) {
      final name = c['name'] as String;
      expect(
        await productText(c),
        row(name)['content'],
        reason: '$name (${c['shape']}): ${c['note']}',
      );
    }
  });

  test('an entity the replacement introduced follows the read, not this stage',
      () async {
    for (final c in cases.where(
      (c) => c['compare'] == 'entity-unescaped-by-the-frozen-read',
    )) {
      final name = c['name'] as String;
      final product = await productText(c);
      // The frozen answer is the one the golden holds: the read decoded `&amp;`.
      expect(row(name)['content'], '　　第一段\n　　&\n　　第二段', reason: name);
      // This product keeps the entity text: the replacement runs in Dart, and the
      // adapter's entity pass never sees it (#104).
      expect(product, '　　第一段\n　　&amp;\n　　第二段', reason: name);
      expect(product, isNot(row(name)['content']), reason: name);
    }
  });
}
