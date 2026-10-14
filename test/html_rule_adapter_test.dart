import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_rule_adapter.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/js_source_runtime.dart';

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

  test('a document list job reads the frozen getStringList answer', () async {
    final batch = HtmlRuleBatch(
      '<div id="e">A&amp;amp;B</div>'
      '<div id="pages"><a href="/p/1">1</a><a href="/p/2">2</a></div>',
    );
    final pages = batch.documentTextList(
      'pages',
      '#pages a@href##^/p/##/page/',
    );
    final joined = batch.documentText('joined', '#pages a@href##^/p/##/page/');
    final entity = batch.documentTextList('entity', '#e@text');
    final entityValue = batch.documentText('entity-value', '#e@text');
    final single = batch.documentTextList(
      'single',
      '#pages a.0@href##^/p/##/page/',
    );
    await batch.run();

    // The `##` field runs once per matched value; the single-value read runs the
    // same field on the join, where the anchor reaches the first line only.
    expect(pages.values, ['/page/1', '/page/2']);
    expect(joined.value, '/page/1\n/p/2');
    // The list read answers the extraction as it is; only the single-value read
    // unescapes entities, and it does so last.
    expect(entity.values, ['A&amp;B']);
    expect(entityValue.value, 'A&B');
    // A one-match rule is the same value either read.
    expect(single.values, ['/page/1']);
  });

  test('a list value that contains a newline stays one value', () async {
    final batch = HtmlRuleBatch(
      '<div id="pages"><a href="/p/1">1</a><a href="/p/2\n/p/3">2</a></div>',
    );
    final pages = batch.documentTextList('pages', '#pages a@href');
    final joined = batch.documentText('joined', '#pages a@href');
    await batch.run();

    expect(pages.values, ['/p/1', '/p/2\n/p/3']);
    // The joined read of the same rule cannot say whether that was two values or
    // three lines, which is why the list read exists.
    expect(joined.value, '/p/1\n/p/2\n/p/3');
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
    },
  );

  test('unsupported rule families fail with the reader-facing error', () async {
    final batch = HtmlRuleBatch(document);
    batch.documentText('js', 'div@js:result');
    await expectLater(batch.run(), throwsA(isA<UnsupportedError>()));
  });
  test(
    'indexed paths retain final CSS and reorder selection positions',
    () async {
      const html =
          '<ul class="shelf"><li><a href="/one">one</a></li><li><a href="/two">two</a></li></ul>';
      for (final (rule, expected) in [
        ('@CSS:ul.shelf > li', ['', 'two']),
        ('li[1,0]', ['two', '']),
      ]) {
        final batch = HtmlRuleBatch(html);
        final jobs = <HtmlStringList>[];
        for (var index = 0; index < 2; index++) {
          final focus = batch.selection('focus:$index', [
            (rule: rule, parentIndex: null),
            (rule: ':root', parentIndex: index),
          ]);
          jobs.add(
            batch.elementsText(
              'value:$index',
              '@CSS:li:nth-child(2)@text',
              focus,
            ),
          );
        }
        await batch.run();
        expect([for (final job in jobs) job.values.single], expected);
      }
    },
  );

  test('parentIndex refuses absent negative and out-of-range parent', () async {
    for (final index in [-1, 2147483648, 4294967297]) {
      final batch = HtmlRuleBatch('<li>one</li><li>two</li>');
      final parent = batch.elements('items', 'li');
      expect(
        () => batch.elements(
          'focus',
          ':root',
          parent: parent,
          parentIndex: index,
        ),
        throwsA(
          isA<UnsupportedError>().having(
            (error) => error.message,
            'message',
            contains('parentIndex'),
          ),
        ),
      );
    }
    final beyond = HtmlRuleBatch('<li>one</li><li>two</li>');
    final parent = beyond.elements('items', 'li');
    beyond.elements('focus', ':root', parent: parent, parentIndex: 2);
    await expectLater(
      beyond.run(),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('parentIndex'),
        ),
      ),
    );
    final batch = HtmlRuleBatch('<li>one</li>');
    batch.elements('focus', ':root', parentIndex: 0);
    await expectLater(
      batch.run(),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          contains('parentIndex'),
        ),
      ),
    );
  });

  test(
    'node selection DTO rejects malformed paths and unsafe integer indices',
    () {
      for (final index in [-1, 0.5, 2147483648, '0']) {
        expect(
          () => sourceDomSelectionOf({
            '__selection': [
              {'rule': 'li'},
              {'rule': ':root', 'parentIndex': index},
            ],
          }),
          throwsA(
            isA<SourceScriptError>().having(
              (error) => error.message,
              'message',
              contains('parentIndex'),
            ),
          ),
        );
      }
      expect(
        () => sourceDomSelectionOf({
          '__selection': [
            {'rule': ':root', 'parentIndex': 0},
          ],
        }),
        throwsA(isA<SourceScriptError>()),
      );
      for (final selection in [
        null,
        'li',
        [
          {'rule': 1},
        ],
      ]) {
        expect(
          () => sourceDomSelectionOf({'__selection': selection}),
          throwsA(isA<SourceScriptError>()),
        );
      }
      expect(sourceDomSelectionOf({'__rule': 'li.1'}), [
        (rule: 'li.1', parentIndex: null),
      ]);
      expect(sourceDomSelectionOf({'__rule': null}), isEmpty);
    },
  );
}
