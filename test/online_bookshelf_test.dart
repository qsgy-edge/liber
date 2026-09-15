import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_bookshelf.dart';
import 'package:liber/source/online_reading_store.dart';

class ShelfMemory extends OnlineReadingStore {
  ShelfMemory() : super(file: File('unused'));
  final record = <String, dynamic>{
    'source': {'bookSourceUrl': 'https://example.test'},
    'book': {'url': 'https://example.test/book', 'title': '保留的书'},
    'chapterUrl': 'https://example.test/c2',
    'textOffset': 77,
    'shelved': true,
  };
  int updates = 0;
  @override
  Future<List<Map<String, dynamic>>> loadBooks() async =>
      record['shelved'] == true ? [record] : [];
  @override
  Future<void> updateCatalog(
    Map<String, dynamic> source,
    HtmlBook book,
    List<SourceChapter> chapters,
  ) async {
    updates++;
  }

  @override
  Future<void> removeBook(Map<String, dynamic> value) async {
    record['shelved'] = false;
  }
}

class OfflineTransport implements BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => throw const SocketException('offline');
}

void main() {
  testWidgets(
    'failed catalog refresh retains bookshelf and progress; remove only changes admission',
    (tester) async {
      final store = ShelfMemory();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ListView(
              children: [
                OnlineBookshelf(store: store, transport: OfflineTransport()),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('书籍操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('更新目录'));
      await tester.pumpAndSettle();
      expect(find.textContaining('书架和进度仍保留'), findsOneWidget);
      expect(find.text('保留的书'), findsOneWidget);
      expect(store.updates, 0);
      expect(store.record['textOffset'], 77);
      await tester.tap(find.byTooltip('书籍操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('移出书架（保留进度）'));
      await tester.pumpAndSettle();
      expect(find.text('保留的书'), findsNothing);
      expect(store.record['textOffset'], 77);
      expect(tester.takeException(), isNull);
    },
  );
}
