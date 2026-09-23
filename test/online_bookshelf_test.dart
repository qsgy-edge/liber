import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/online_bookshelf.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'native_library.dart';

class OfflineTransport implements BookSourceTransport {
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => throw const SocketException('offline');
}

class RecordedPages implements BookSourceTransport {
  final stages = <BookSourceStage>[];
  final paths = <String>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    stages.add(stage);
    paths.add(path);
    return jsonEncode(switch (Uri.parse(path).path) {
      '/book/73' => {'title': '真实书名', 'toc': '/toc/73'},
      '/toc/73' => {
        'list': [
          {'name': '第一章', 'url': '/chapter/1'},
        ],
      },
      '/chapter/1' => {'text': '章节正文'},
      _ => throw StateError('不应请求：$path'),
    });
  }
}

Map<String, dynamic> matchingSource(
  String name,
  String sourceUrl,
  String pattern,
) => {
  'bookSourceUrl': sourceUrl,
  'bookSourceName': name,
  'bookUrlPattern': pattern,
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.title',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc', 'canReName': 'true'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
  'ruleContent': {'content': r'$.text'},
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);
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
        isVolume: false,
        isVip: false,
        isPay: false,
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

  Future<void> showShelf(
    WidgetTester tester,
    BookSourceTransport transport,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [OnlineBookshelf(service: shelf, transport: transport)],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> paste(WidgetTester tester, String url) async {
    await tester.enterText(find.byType(TextField), url);
    await tester.tap(find.byTooltip('打开书籍链接'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'one matching imported JSON source opens details, adds and reads without search',
    (tester) async {
      final transport = RecordedPages();
      await store.putSourceJson(
        matchingSource('书源甲', sourceUrl, r'.*/book/\d+'),
      );
      await showShelf(tester, transport);
      await paste(tester, '$sourceUrl/book/73');
      expect(find.byType(HtmlSourceBrowser), findsOneWidget);
      expect(find.text('真实书名'), findsOneWidget);
      expect(find.text('第一章'), findsOneWidget);
      expect(transport.stages, [
        BookSourceStage.bookInfo,
        BookSourceStage.tableOfContents,
      ]);
      expect(transport.paths, ['$sourceUrl/book/73', '$sourceUrl/toc/73']);

      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
      final entry = await shelf.find(sourceUrl, '$sourceUrl/book/73');
      expect(entry?.shelved, isTrue);
      expect(entry?.chapters.single.name, '第一章');
      await tester.tap(find.text('第一章'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(find.textContaining('章节正文'), findsWidgets);
      expect(transport.stages, [
        BookSourceStage.bookInfo,
        BookSourceStage.tableOfContents,
        BookSourceStage.content,
      ]);
    },
  );

  testWidgets(
    'credential-bearing URL is rejected before a permissive source can fetch',
    (tester) async {
      final transport = RecordedPages();
      await store.putSourceJson(matchingSource('书源甲', sourceUrl, r'.*'));
      await showShelf(tester, transport);
      await paste(tester, 'https://user:pass@example.test/book/73');
      expect(find.textContaining('请输入有效的 http(s)'), findsOneWidget);
      expect(find.byType(HtmlSourceBrowser), findsNothing);
      expect(transport.paths, isEmpty);
      expect(transport.stages, isEmpty);
      await paste(tester, 'https://');
      expect(find.textContaining('请输入有效的 http(s)'), findsOneWidget);
      expect(transport.paths, isEmpty);
    },
  );

  testWidgets('unmatched and invalid URLs report a result without requesting', (
    tester,
  ) async {
    final transport = RecordedPages();
    await store.putSourceJson(matchingSource('书源甲', sourceUrl, r'.*/book/\d+'));
    await showShelf(tester, transport);
    await paste(tester, '$sourceUrl/other');
    expect(find.text('没有匹配此链接的书源'), findsOneWidget);
    await paste(tester, 'file:///book/73');
    expect(find.textContaining('http(s)'), findsOneWidget);
    expect(transport.stages, isEmpty);
    expect(find.byType(HtmlSourceBrowser), findsNothing);
  });

  testWidgets(
    'multiple sources require a choice; cancellation makes no request',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final transport = RecordedPages();
      await store.putSourceJson(
        matchingSource('书源甲', sourceUrl, r'.*/book/\d+'),
      );
      await store.putSourceJson(
        matchingSource(
          '书源乙',
          'https://other.test',
          r'https://example.test/book/\d+',
        ),
      );
      await showShelf(tester, transport);
      await paste(tester, '$sourceUrl/book/73');
      expect(find.text('选择书源'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(transport.stages, isEmpty);
      expect(find.byType(HtmlSourceBrowser), findsNothing);
      await tester.tap(find.byTooltip('打开书籍链接'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('书源乙'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlSourceBrowser), findsOneWidget);
      expect(transport.stages, [
        BookSourceStage.bookInfo,
        BookSourceStage.tableOfContents,
      ]);
    },
  );

  testWidgets(
    'unsupported Java pattern is reported by source, not silently ignored',
    (tester) async {
      final transport = RecordedPages();
      await store.putSourceJson(
        matchingSource('坏规则', sourceUrl, r'\Qbook\E/\d+'),
      );
      await showShelf(tester, transport);
      await paste(tester, '$sourceUrl/book/73');
      expect(find.textContaining('没有匹配此链接的书源'), findsOneWidget);
      expect(
        find.textContaining('坏规则：Unsupported operation: bookUrlPattern'),
        findsOneWidget,
      );
      expect(transport.stages, isEmpty);
    },
  );

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

  testWidgets('书源被删除后，书留在书架上并标记为打不开', (tester) async {
    await shelf.deleteSource(sourceUrl);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(children: [OnlineBookshelf(service: shelf)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的书'), findsOneWidget, reason: '书还在书架上');
    expect(find.textContaining('书源已删除'), findsOneWidget);
    expect(find.text('第二章'), findsNothing, reason: '打不开的书不报它读到哪，先报它为什么打不开');

    // Nothing opens it: there is no source object to run.
    await tester.tap(find.text('保留的书'));
    await tester.pumpAndSettle();
    expect(find.byType(HtmlSourceBrowser), findsNothing);
    expect(tester.takeException(), isNull);

    // The one action left is taking it off the shelf, and the position the book
    // already had is not the source's to take.
    await tester.tap(find.byTooltip('书籍操作'));
    await tester.pumpAndSettle();
    expect(find.text('更新目录'), findsNothing);
    await tester.tap(find.text('移出书架（保留进度）'));
    await tester.pumpAndSettle();
    expect(find.text('保留的书'), findsNothing);
    expect((await store.bookById(bookId))!.shelved, isFalse);
    expect((await store.progressOf(bookId))!.textOffset, 77);
    expect((await store.chaptersOf(bookId)).map((c) => c.name), ['第二章']);
  });
}
