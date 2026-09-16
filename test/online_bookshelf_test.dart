import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/online_bookshelf.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

class OfflineTransport implements BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => throw const SocketException('offline');
}

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  late String bookId;

  const sourceUrl = 'https://example.test';
  const source = <String, dynamic>{
    'bookSourceUrl': sourceUrl,
    'bookSourceName': 'Example',
  };

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    bookId = await shelf.ensureBook(
      source,
      HtmlBook(url: Uri.parse('$sourceUrl/book'), title: '保留的书'),
    );
    await store.putChapters(bookId, [
      BookChapter(
        bookId: bookId,
        chapterKey: '$sourceUrl/c2',
        name: '第二章',
        url: '$sourceUrl/c2',
        chapterIndex: 0,
      ),
    ]);
    await shelf.saveProgress(
      bookId,
      chapterKey: '$sourceUrl/c2',
      chapterIndex: 0,
      textOffset: 77,
    );
    await shelf.add(
      source,
      HtmlBook(url: Uri.parse('$sourceUrl/book'), title: '保留的书'),
    );
  });

  tearDown(() => store.close());

  testWidgets('失败的目录刷新不动书架与进度；移出只改成员资格', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              OnlineBookshelf(service: shelf, transport: OfflineTransport()),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的书'), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget, reason: '副标题是目录里的章节名');

    await tester.tap(find.byTooltip('书籍操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('更新目录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('书架和进度仍保留'), findsOneWidget);
    expect(find.text('保留的书'), findsOneWidget);
    expect((await store.progressOf(bookId))!.textOffset, 77);
    expect((await store.chaptersOf(bookId)).map((c) => c.name), ['第二章']);

    await tester.tap(find.byTooltip('书籍操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移出书架（保留进度）'));
    await tester.pumpAndSettle();
    expect(find.text('保留的书'), findsNothing);
    expect((await store.bookById(bookId))!.shelved, isFalse);
    expect((await store.progressOf(bookId))!.textOffset, 77);
    expect(tester.takeException(), isNull);
  });
}
