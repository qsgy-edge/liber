import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/auto_change_source.dart';
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

import 'l10n_support.dart';

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

/// The candidate source of the automatic switch (#69): the whole four-stage
/// chain over one JSON fixture, whose search answers the shelf's own book.
const autoSwitchSourceUrl = 'https://candidate.test';

Map<String, dynamic> autoSwitchSource() => {
  'bookSourceUrl': autoSwitchSourceUrl,
  'bookSourceName': '候选源',
  'enabled': true,
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.title',
    'author': r'$.author',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
  'ruleContent': {'content': r'$.text'},
};

/// The candidate source's pages: its search answers the shelf's book by name
/// and author, its own table of contents is not the old one, and its first
/// chapter has a body — which is what the frozen flow's candidate check asks
/// for before it accepts a source.
class AutoSwitchPages implements BookSourceTransport {
  final stages = <BookSourceStage>[];
  final paths = <String>[];

  /// Holds every answer open, so a test can observe the switch while it runs.
  Completer<void>? gate;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    stages.add(stage);
    paths.add(path);
    final gate = this.gate;
    if (gate != null) await gate.future;
    return jsonEncode(switch (Uri.parse(path).path) {
      '/search' => {
        'items': [
          {'title': '保留的书', 'author': '', 'url': '/book/9'},
        ],
      },
      '/book/9' => {'title': '保留的书', 'toc': '/toc/9'},
      '/toc/9' => {
        'list': [
          {'name': '楔子', 'url': '/chapter/0'},
          {'name': '第二章', 'url': '/chapter/1'},
        ],
      },
      '/chapter/0' => {'text': '这一章的正文'},
      _ => throw StateError('不应请求：$path'),
    });
  }
}

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
      localizedApp(
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
      localizedApp(
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

  testWidgets('书源被删除后，书留在书架上；打开它跑自动换源，找不到书源时只报错', (tester) async {
    await shelf.deleteSource(sourceUrl);
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: ListView(children: [OnlineBookshelf(service: shelf)]),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('保留的书'), findsOneWidget, reason: '书还在书架上');
    expect(find.textContaining('书源已删除'), findsOneWidget);
    expect(find.text('第二章'), findsNothing, reason: '打不开的书不报它读到哪，先报它为什么打不开');

    // Opening it is the frozen reader's automatic switch (#69). This space has
    // no other source, so nothing was switched and the flow reports the frozen
    // 没有合适书源; the book keeps its row.
    await tester.tap(find.text('保留的书'));
    await tester.pumpAndSettle();
    expect(find.byType(HtmlSourceBrowser), findsNothing);
    expect(find.textContaining('自动换源失败'), findsOneWidget);
    expect(find.textContaining('没有合适书源'), findsOneWidget);
    expect((await store.bookById(bookId))!.sourceRef, sourceUrl);
    expect(tester.takeException(), isNull);

    // The other action is taking it off the shelf, and the position the book
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

  testWidgets('打开失源的书：自动换源读到新书源的目录，书的身份与进度都留下', (tester) async {
    await store.putSourceJson(autoSwitchSource());
    final transport = AutoSwitchPages();
    await shelf.deleteSource(sourceUrl);
    await showShelf(tester, transport);
    expect(find.textContaining('书源已删除'), findsOneWidget);

    await tester.tap(find.text('保留的书'));
    await tester.pumpAndSettle();

    // The candidate proved itself on its own first chapter before the switch
    // was written, and the switch wrote the same row (D2) with the position on
    // the new table of contents.
    expect(transport.stages.first, BookSourceStage.search);
    expect(transport.paths, contains('$autoSwitchSourceUrl/chapter/0'));
    final switched = (await store.bookById(bookId))!;
    expect(switched.sourceRef, autoSwitchSourceUrl);
    expect(switched.sourceBookUrl, '$autoSwitchSourceUrl/book/9');
    expect(switched.title, '保留的书');
    expect((await shelf.onlineShelf()).length, 1, reason: '还是一条书架行');
    expect(
      (await store.chaptersOf(bookId)).map((chapter) => chapter.name),
      ['楔子', '第二章'],
    );
    final progress = (await store.progressOf(bookId))!;
    expect(progress.chapterKey, '$autoSwitchSourceUrl/chapter/0');
    expect(progress.chapterIndex, 0);
    // The offset the switch carried over (77) is what the reader then resumes
    // from: it re-derives the row its body holds at that anchor, and this
    // chapter's body is short enough that the row is the first one. The
    // switch's own write of the carried offset is pinned in
    // `auto_change_source_test.dart` and `switch_source_test.dart`.

    // The switched book is then opened the way any other row is: its page,
    // then its reader (which covers the page, so the page is read offstage).
    expect(
      find.byType(HtmlSourceBrowser, skipOffstage: false),
      findsOneWidget,
    );
    expect(find.byType(OnlineReaderPage), findsOneWidget);
    expect(find.textContaining('这一章的正文'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('自动换源进行中，那一行说的是冻结的正在自动换源', (tester) async {
    await store.putSourceJson(autoSwitchSource());
    final transport = AutoSwitchPages();
    await shelf.deleteSource(sourceUrl);
    await showShelf(tester, transport);
    final gate = Completer<void>();
    transport.gate = gate;

    await tester.tap(find.text('保留的书'));
    await tester.pump();
    expect(find.text('正在自动换源'), findsOneWidget, reason: '冻结的 source_auto_changing');
    expect(find.textContaining('书源已删除'), findsNothing);

    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('正在自动换源'), findsNothing);
    expect(find.byType(OnlineReaderPage), findsOneWidget);
  });

  testWidgets('自动换源关闭时，打开失源的书不发起任何请求', (tester) async {
    await store.putSourceJson(autoSwitchSource());
    final transport = AutoSwitchPages();
    await AutoChangeSourceSetting.putGlobal(store, enabled: false);
    await shelf.deleteSource(sourceUrl);
    await showShelf(tester, transport);

    await tester.tap(find.text('保留的书'));
    await tester.pumpAndSettle();

    expect(transport.stages, isEmpty, reason: '冻结的 if (!AppConfig.autoChangeSource) return');
    expect(find.byType(HtmlSourceBrowser), findsNothing);
    expect(find.textContaining('书源已删除'), findsOneWidget);
    expect(find.textContaining('自动换源失败'), findsNothing);
    expect((await store.bookById(bookId))!.sourceRef, sourceUrl);
    expect((await store.progressOf(bookId))!.textOffset, 77);
    expect(tester.takeException(), isNull);
  });
}
