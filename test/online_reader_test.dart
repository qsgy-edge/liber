import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/reader_script.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

/// The conversion the reader runs is the engine's; a widget test cannot load the
/// native library, so it injects this double and reads the target it was given.
String markTarget(String text, ConvertTarget target) =>
    '<<${target.name}>>$text';

/// The reader only needs chapter text. Driving the real rule adapter here would
/// load the native library into a widget test, where the binding cannot settle
/// pending bridge work; the rule semantics have their own coverage in
/// `html_rule_adapter_test.dart` and in the HTML pipeline test.
class ScriptedPipeline extends HtmlSourcePipeline {
  ScriptedPipeline({this.gate})
    : super(const {
        'bookSourceUrl': 'https://example.test',
      }, _UnusedTransport());

  /// Holds the second chapter response so the loading header can be observed.
  final Completer<void>? gate;
  int calls = 0;

  /// How many chapters were fetched, whatever the gate is doing: the count a
  /// re-render must not raise.
  int fetches = 0;

  /// The next chapter URL the reader passed with each chapter fetch, in call
  /// order: the frozen next-chapter lookup the content stage's stop guard reads.
  final nextChapterUrls = <String?>[];

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    fetches += 1;
    nextChapterUrls.add(nextChapterUrl);
    if (gate != null && calls++ > 0) await gate!.future;
    return HtmlChapterBody(
      List.generate(60, (i) => '${chapter.url} 第$i段 中文内容。').join('\n'),
      1,
    );
  }
}

class _UnusedTransport implements BookSourceTransport {
  const _UnusedTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('该测试不经过传输层');
}

/// A tag long enough to wrap without the frozen `singleLine="true"`.
const _longTag = '2026-01-01 12:34:56 更新时间很长很长很长很长很长很长很长很长很长很长很长很长';

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  late String bookId;

  const sourceUrl = 'https://example.test';
  const bookUrl = '$sourceUrl/book';

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    bookId = await shelf.ensureBook(const {
      'bookSourceUrl': sourceUrl,
    }, HtmlBook(url: Uri.parse(bookUrl), title: '书'));
  });

  tearDown(() => store.close());

  Future<void> addChapters(List<(String, String)> chapters) =>
      store.putChapters(bookId, [
        for (var index = 0; index < chapters.length; index++)
          BookChapter(
            bookId: bookId,
            chapterKey: chapters[index].$2,
            name: chapters[index].$1,
            url: chapters[index].$2,
            chapterIndex: index,
            isVolume: false,
            isVip: false,
            isPay: false,
          ),
      ]);

  testWidgets(
    'cached shelf resume waits for route construction before opening reader',
    (tester) async {
      const source = {
        'bookSourceUrl': sourceUrl,
        'ruleContent': {'content': '@CSS:.con p@text'},
      };
      final pipeline = ScriptedPipeline();
      await addChapters([('第一章', '$sourceUrl/1')]);
      final entry = (await shelf.find(sourceUrl, bookUrl))!;

      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HtmlSourceBrowser(
                    source: source,
                    keyword: '',
                    pipeline: pipeline,
                    service: shelf,
                    resume: entry,
                  ),
                ),
              ),
              child: const Text('打开书架书籍'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开书架书籍'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader saves visible paragraph, restores it, and switches chapters',
    (tester) async {
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      // Each reader owns the pipeline it fetches through, so a remount gets a
      // fresh one and the replaced reader cancelling its own is the point.
      Widget page(int index, int offset) => MaterialApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
          chapterIndex: index,
          textOffset: offset,
        ),
      );
      await tester.pumpWidget(page(0, 0));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      final saved = (await store.progressOf(bookId))!.textOffset;
      expect(saved, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(0, saved));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.textOffset, saved);

      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/2');
      expect((await store.progressOf(bookId))!.textOffset, 0);
      expect((await store.progressOf(bookId))!.chapterIndex, 1);

      await tester.tap(find.text('上一章'));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/1');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader passes the frozen next-chapter URL, index-0 fallback included',
    (tester) async {
      final pipeline = ScriptedPipeline();
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      await tester.pumpWidget(
        MaterialApp(
          home: OnlineReaderPage(
            pipeline: pipeline,
            book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
            bookId: bookId,
            chapters: chapters,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      // The content stage's next-page guard reads the next chapter; the last
      // chapter falls back to the chapter at index 0, which is the frozen
      // lookup's own quirk (`BookContent.kt:49-53`) reproduced as it stands.
      expect(pipeline.nextChapterUrls, ['$sourceUrl/2', '$sourceUrl/1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reader blanks the chapter name while a chapter loads', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline(gate: Completer<void>());
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    await tester.tap(find.text('下一章'));
    await tester.pump();
    // Neither the stale nor the incoming name may sit next to the spinner.
    expect(find.text('第一章'), findsNothing);
    expect(find.text('第二章'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pipeline.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('第二章'), findsOneWidget);
    expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader applies the space replace rules to the title and the body', (
    tester,
  ) async {
    // The rules the frozen reader reads per book: a content rule that reaches
    // every source, and a title rule. Both are literal, because a regex rule runs
    // in its own isolate (the deadline) and a widget test's binding does not
    // deliver another isolate's messages; `content_processing_test.dart` covers
    // the regex path.
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'content-rule',
        name: '去广告',
        pattern: '第0段',
        replacement: const Value('第零段'),
        isRegex: const Value(false),
      ),
    );
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'title-rule',
        name: '章改回',
        pattern: '章',
        replacement: const Value('回'),
        scopeTitle: const Value(true),
        scopeContent: const Value(false),
        isRegex: const Value(false),
      ),
    );
    final chapters = [SourceChapter('第一章 广告', Uri.parse('$sourceUrl/1'))];
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The body carries the content rule's replacement.
    expect(find.textContaining('第零段'), findsWidgets);
    expect(find.textContaining('第0段'), findsNothing);
    // The reader's own title is the replaced one.
    expect(find.text('第一回 广告'), findsOneWidget);
    // The table of contents stays raw: the frozen list replaces a title only
    // when `AppConfig.tocUiUseReplace` is on, and it defaults to false.
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 广告'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader table of contents shows the tag, the volume and the lock', (
    tester,
  ) async {
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1'), tag: '2026-01-01'),
      SourceChapter.volume(
        '第一卷',
        0,
        tocUrl: Uri.parse('$sourceUrl/v'),
        tag: '卷首',
      ),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2'), isVip: true),
      SourceChapter('第三章', Uri.parse('$sourceUrl/3'), isVip: true, isPay: true),
      SourceChapter('第四章', Uri.parse('$sourceUrl/4'), tag: _longTag),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();

    // A non-volume chapter's `tag` is its secondary line
    // (`ChapterListAdapter.kt:146-150`).
    expect(find.text('2026-01-01'), findsOneWidget);
    // A volume is a heading and keeps its `tag` hidden (`:138-150`).
    expect(find.text('第一卷'), findsOneWidget);
    expect(find.text('卷首'), findsNothing);
    // The volume row differs from its siblings only in its background
    // (`:138-139`): no bold title.
    expect(
      tester
          .widget<ListTile>(
            find.ancestor(
              of: find.text('第一卷'),
              matching: find.byType(ListTile),
            ),
          )
          .tileColor,
      isNotNull,
    );
    final volumeName = tester.widget<Text>(find.text('第一卷'));
    expect(volumeName.style?.fontWeight, isNot(FontWeight.bold));
    // The frozen row is `singleLine="true"`
    // (`res/layout/item_chapter_list.xml`), so a long name or tag stays on one
    // line instead of growing the row.
    expect(volumeName.maxLines, 1);
    expect(volumeName.overflow, TextOverflow.ellipsis);
    final longTag = tester.widget<Text>(find.text(_longTag));
    expect(longTag.maxLines, 1);
    expect(longTag.overflow, TextOverflow.ellipsis);
    // The lock is `isVip && !isPay` (`:162-165`), so the paid chapter has none.
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader renders the script the system locale asks for, 正文和目录标题一样',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale(
        'zh',
        'TW',
      );
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final chapters = [SourceChapter('第一章 龍鳳', Uri.parse('$sourceUrl/1'))];
      await tester.pumpWidget(
        MaterialApp(
          home: OnlineReaderPage(
            pipeline: ScriptedPipeline(),
            book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
            bookId: bookId,
            chapters: chapters,
            service: shelf,
            convert: markTarget,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The body and the chapter title above it carry the locale's target.
      expect(find.textContaining('<<traditionalTaiwan>>'), findsWidgets);
      // The table of contents converts the chapter name too, and the raw name is
      // nowhere on the page any more.
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(find.text('<<traditionalTaiwan>>第一章 龍鳳'), findsWidgets);
      expect(find.text('第一章 龍鳳'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('改设置后在线章节重新渲染，且不重新抓取，本书覆盖生效', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'zh',
      'CN',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final pipeline = ScriptedPipeline();
    final chapters = [SourceChapter('第一章', Uri.parse('$sourceUrl/1'))];
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
          convert: markTarget,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('<<simplifiedMainland>>'), findsWidgets);
    final fetches = pipeline.fetches;

    await tester.tap(find.byTooltip('中文转换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
      300,
    );
    await tester.tap(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
    );
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();

    // The override is what the open chapter renders in, and the chapter was not
    // fetched a second time for it.
    expect(find.textContaining('<<traditionalGeneric>>'), findsWidgets);
    expect(find.textContaining('<<simplifiedMainland>>'), findsNothing);
    expect(pipeline.fetches, fetches, reason: '改设置不重新抓取章节');
    expect(
      await store.setting(ReaderScriptSetting.key, bookId: bookId),
      'traditional_generic',
    );
    expect(
      await store.setting(ReaderScriptSetting.key),
      isNull,
      reason: '本书覆盖不动安装的选择',
    );
    expect(tester.takeException(), isNull);
  });
}
