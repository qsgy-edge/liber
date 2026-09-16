import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

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

  @override
  Future<HtmlChapterBody> chapter(SourceChapter chapter) async {
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
}
