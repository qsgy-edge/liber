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
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'shudugu Windows two-book shelf and independent reading restoration',
    (tester) async {
      final directory = await Directory.systemTemp.createTemp(
        'liber-native-shelf-',
      );
      final database = File('${directory.path}/data.db');
      ShelfService? service;
      // Every open replaces the previous connection, and the last one is closed
      // when the test ends, so the temporary directory can go away.
      Future<ShelfService> open() async {
        await service?.close();
        return service = ShelfService(SpaceStore(SpaceDatabase.file(database)));
      }

      addTearDown(() async {
        await service?.close();
        await directory.delete(recursive: true);
      });

      final source =
          (jsonDecode(await rootBundle.loadString('book_sources/shudugu.json'))
                      as List)
                  .first
              as Map<String, dynamic>;
      service = await open();
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Live source test running')),
        ),
      );
      final urls = <String, String>{};
      for (final name in ['凡人修仙传', '青山']) {
        final pipeline = HtmlSourcePipeline(source, HttpSourceTransport());
        final hits = await pipeline.search(name);
        final (book, chapters) = await pipeline.details(
          hits.firstWhere((hit) => hit.title == name),
        );
        expect(chapters.length, greaterThan(2));
        urls[name] = '${book.url}';
        await service!.add(source, book, chapters);
        await service!.add(source, book, chapters);
        pipeline.cancel();
      }
      expect(await service!.onlineShelf(), hasLength(2));

      Future<void> settle() => tester.pumpAndSettle(
        const Duration(milliseconds: 100),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 90),
      );
      Widget shelf(ShelfService current) => MaterialApp(
        home: Scaffold(
          body: ListView(children: [OnlineBookshelf(service: current)]),
        ),
      );

      await tester.pumpWidget(shelf(service!));
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
      final first = (await service!.lastRead())!;
      expect(first.title, '凡人修仙传');
      expect(first.textOffset, greaterThan(0));
      expect(first.chapterName, '第2章 青牛镇');

      // Rebuild all routes and reopen the same database to exercise disk
      // restore.
      await tester.pumpWidget(const SizedBox());
      service = await open();
      await tester.pumpWidget(shelf(service!));
      await settle();
      await tester.tap(find.text('青山'));
      await settle();
      await tester.drag(
        find.byType(SingleChildScrollView).last,
        const Offset(0, -450),
      );
      await settle();
      final second = (await service!.lastRead())!;
      expect(second.title, '青山');
      expect(second.textOffset, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      service = await open();
      await tester.pumpWidget(shelf(service!));
      await settle();
      await tester.tap(find.text('凡人修仙传'));
      await settle();
      final restored = (await service!.lastRead())!;
      expect(restored.title, '凡人修仙传');
      expect(restored.chapterKey, first.chapterKey);
      expect(restored.textOffset, first.textOffset);
      final other = (await service!.find(
        '${source['bookSourceUrl']}',
        urls['青山']!,
      ))!;
      expect(other.textOffset, second.textOffset);
      expect(await service!.onlineShelf(), hasLength(2));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      debugPrint(
        'SHUDUGU_TWO_BOOK_PASS firstOffset=${first.textOffset} secondOffset=${second.textOffset} shelfCount=2',
      );
    },
  );
}
