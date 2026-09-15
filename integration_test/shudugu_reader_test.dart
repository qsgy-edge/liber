import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/online_bookshelf.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/online_reading_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'shudugu Windows two-book shelf and independent reading restoration',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'liber-native-shelf-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/reading.json');
      final source =
          (jsonDecode(await rootBundle.loadString('book_sources/shudugu.json'))
                      as List)
                  .first
              as Map<String, dynamic>;
      final store = OnlineReadingStore(file: file);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Live source test running')),
        ),
      );
      for (final name in ['凡人修仙传', '青山']) {
        final pipeline = HtmlSourcePipeline(source, HttpSourceTransport());
        final hits = await pipeline.search(name);
        final (book, chapters) = await pipeline.details(
          hits.firstWhere((hit) => hit.title == name),
        );
        expect(chapters.length, greaterThan(2));
        await store.addBook(source, book, chapters);
        await store.addBook(source, book, chapters);
        pipeline.cancel();
      }
      expect(await store.loadBooks(), hasLength(2));

      Future<void> settle() => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 90),
      );
      Widget shelf(OnlineReadingStore current) => MaterialApp(
        home: Scaffold(
          body: ListView(children: [OnlineBookshelf(store: current)]),
        ),
      );
      await tester.pumpWidget(shelf(store));
      await settle();
      await tester.tap(find.text('凡人修仙传'));
      await settle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      await tester.tap(find.text('下一章'));
      await settle();
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -650),
      );
      await settle();
      final first = await store.load();
      expect((first!['book'] as Map)['title'], '凡人修仙传');
      expect(first['textOffset'] as int, greaterThan(0));
      expect(first['chapterName'], '第2章 青牛镇');

      // Rebuild all routes and instantiate a new store to exercise disk restore.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(shelf(OnlineReadingStore(file: file)));
      await settle();
      await tester.tap(find.text('青山'));
      await settle();
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -450),
      );
      await settle();
      final second = await store.load();
      expect((second!['book'] as Map)['title'], '青山');
      expect(second['textOffset'] as int, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      final reopened = OnlineReadingStore(file: file);
      await tester.pumpWidget(shelf(reopened));
      await settle();
      await tester.tap(find.text('凡人修仙传'));
      await settle();
      final restored = await reopened.load();
      expect(restored!['chapterUrl'], first['chapterUrl']);
      expect(restored['textOffset'], first['textOffset']);
      final other = await reopened.find(
        source,
        (second['book'] as Map)['url'] as String,
      );
      expect(other!['textOffset'], second['textOffset']);
      expect(await reopened.loadBooks(), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugPrint(
        'SHUDUGU_TWO_BOOK_PASS firstOffset=${first['textOffset']} secondOffset=${second['textOffset']} shelfCount=2',
      );
    },
  );
}
