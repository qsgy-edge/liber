import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/online_reading_store.dart';

class MemoryStore extends OnlineReadingStore {
  MemoryStore() : super(file: File('not-used'));
  Map<String, dynamic>? value;
  @override
  Future<void> save(Map<String, dynamic> value) async {
    this.value = value;
  }
}

/// The reader only needs chapter text. Driving the real rule adapter here would
/// load the native library into a widget test, where the binding cannot settle
/// pending bridge work; the rule semantics have their own coverage in
/// `html_rule_adapter_test.dart` and in the HTML pipeline test.
class ScriptedPipeline extends HtmlSourcePipeline {
  ScriptedPipeline({this.gate})
    : super(const {'bookSourceUrl': 'https://example.test'}, _UnusedTransport());

  /// Holds the second chapter response so the loading header can be observed.
  final Completer<void>? gate;
  int calls = 0;

  @override
  Future<HtmlChapterBody> chapter(SourceChapter chapter) async {
    if (gate != null && calls++ > 0) await gate!.future;
    return HtmlChapterBody(
      List.generate(
        60,
        (i) => '${chapter.url} 第$i段 中文内容。',
      ).join('\n'),
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
  testWidgets(
    'cached shelf resume waits for route construction before opening reader',
    (tester) async {
      final source = <String, dynamic>{
        'bookSourceUrl': 'https://example.test',
        'ruleContent': {'content': '@CSS:.con p@text'},
      };
      final pipeline = ScriptedPipeline();
      final store = MemoryStore();
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
                    store: store,
                    resume: {
                      'source': source,
                      'book': {
                        'url': 'https://example.test/book',
                        'title': '书',
                      },
                      'chapterUrl': 'https://example.test/1',
                      'textOffset': 0,
                      'chapters': [
                        {'name': '第一章', 'url': 'https://example.test/1'},
                      ],
                    },
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
      final store = MemoryStore();
      final pipeline = ScriptedPipeline();
      final chapters = [
        SourceChapter('第一章', Uri.parse('https://example.test/1')),
        SourceChapter('第二章', Uri.parse('https://example.test/2')),
      ];
      Widget page(int index, int offset) => MaterialApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(
            url: Uri.parse('https://example.test/book'),
            title: '书',
          ),
          chapters: chapters,
          store: store,
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
      final saved = store.value!['textOffset'] as int;
      expect(saved, greaterThan(0));
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(0, saved));
      await tester.pumpAndSettle();
      expect(store.value!['textOffset'], saved);
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect(store.value!['chapterUrl'], 'https://example.test/2');
      expect(store.value!['textOffset'], 0);
      await tester.tap(find.text('上一章'));
      await tester.pumpAndSettle();
      expect(store.value!['chapterUrl'], 'https://example.test/1');
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('reader blanks the chapter name while a chapter loads', (
    tester,
  ) async {
    final store = MemoryStore();
    final pipeline = ScriptedPipeline(gate: Completer<void>());
    final chapters = [
      SourceChapter('第一章', Uri.parse('https://example.test/1')),
      SourceChapter('第二章', Uri.parse('https://example.test/2')),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(
            url: Uri.parse('https://example.test/book'),
            title: '书',
          ),
          chapters: chapters,
          store: store,
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
    expect(store.value!['chapterUrl'], 'https://example.test/2');
    expect(tester.takeException(), isNull);
  });
}
