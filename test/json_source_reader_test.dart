import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

/// The acceptance of ticket #29: a JSON Book Source is searched, added to the
/// shelf, opened in the reader, paged, and its position written and restored.
///
/// The source runs over a scripted transport — one page per path, no socket and
/// no live site — and through the product's own path: the browser builds the
/// pipeline from the source's rules, so this test fails if the JSON adapter is
/// not the one a JSON source gets.
///
/// The body labels are `正文一`/`正文二` rather than the chapter names on
/// purpose: the reader now runs the frozen content stage (#17), which strips a
/// leading line that repeats the chapter title, so a fixture whose first line
/// starts with `第一章` would lose that prefix before it is rendered.

const sourceUrl = 'http://json.test';

String chapterPage(String label) => jsonEncode({
  'body': List.generate(40, (i) => '$label 第$i段 中文内容。').join('\n'),
});

final pages = <String, String>{
  '/search': jsonEncode({
    'items': [
      {'name': 'JSON 书', 'url': '/book/1', 'author': '作者甲'},
    ],
  }),
  '/book/1': jsonEncode({
    'title': 'JSON 书',
    'author': '作者甲',
    'intro': 'JSON 源的简介',
    'toc': '/toc/1',
  }),
  '/toc/1': jsonEncode({
    'list': [
      {'name': '第一章', 'url': '/ch/1'},
      {'name': '第二章', 'url': '/ch/2'},
    ],
  }),
  '/ch/1': chapterPage('正文一'),
  '/ch/2': chapterPage('正文二'),
};

final source = <String, dynamic>{
  'bookSourceUrl': sourceUrl,
  'bookSourceName': 'JSON 源',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.name',
    'bookUrl': r'$.url',
    'author': r'$.author',
  },
  'ruleBookInfo': {
    'name': r'$.title',
    'author': r'$.author',
    'intro': r'$.intro',
    'tocUrl': r'$.toc',
  },
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
  'ruleContent': {'content': r'$.body'},
};

/// The scripted transport: every response the corpus declares, and a recorded
/// request list, so an undeclared path fails the test instead of a live site
/// answering it.
class ScriptedJsonTransport
    implements BookSourceTransport, SourceHttpTransport {
  final requests = <String>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest sourceRequest) async {
    requests.add('${sourceRequest.method} ${sourceRequest.url.path}');
    final body = pages[sourceRequest.url.path];
    if (body == null) {
      throw StateError('未声明的请求：${sourceRequest.url.path}');
    }
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: body,
      url: sourceRequest.url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => pages[Uri.parse(path).path] ?? '';
}

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  late ScriptedJsonTransport transport;

  setUp(() {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    transport = ScriptedJsonTransport();
  });

  tearDown(() => store.close());

  Widget browser({String keyword = '', ShelfEntry? resume}) => MaterialApp(
    home: HtmlSourceBrowser(
      source: source,
      keyword: keyword,
      service: shelf,
      resume: resume,
      transport: transport,
    ),
  );

  testWidgets('a JSON source is searched, shelved and read', (tester) async {
    await tester.pumpWidget(browser(keyword: '关键词'));
    await tester.pumpAndSettle();
    expect(find.text('JSON 书'), findsOneWidget);
    expect(transport.requests, contains('GET /search'));

    await tester.tap(find.text('JSON 书'));
    await tester.pumpAndSettle();
    expect(find.text('JSON 源的简介'), findsOneWidget);
    expect(find.text('目录 · 2 章'), findsOneWidget);

    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();
    // The add confirmation is a SnackBar over the page; let it expire so it
    // cannot sit over the reader's own bottom bar.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    final entry = (await shelf.onlineShelf()).single;
    expect(entry.title, 'JSON 书');
    expect(entry.sourceRef, sourceUrl);
    expect(entry.chapters.map((chapter) => chapter.name), ['第一章', '第二章']);

    await tester.tap(find.text('第一章'));
    await tester.pumpAndSettle();
    expect(find.byType(OnlineReaderPage), findsOneWidget);
    expect(find.textContaining('正文一 第0段'), findsOneWidget);
    expect(find.textContaining('正文一 第39段'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the reader pages on and restores the position it wrote', (
    tester,
  ) async {
    await tester.pumpWidget(browser(keyword: '关键词'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('JSON 书'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();
    // The add confirmation is a SnackBar over the page; let it expire so it
    // cannot sit over the reader's own bottom bar.
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.tap(find.text('第一章'));
    await tester.pumpAndSettle();

    // Paging writes the chapter the reader switched to.
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(find.textContaining('正文二 第0段'), findsOneWidget);
    final bookId = (await shelf.onlineShelf()).single.id;
    expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/ch/2');

    // Scrolling writes the paragraph the reader is looking at.
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    final saved = (await store.progressOf(bookId))!.textOffset;
    expect(saved, greaterThan(0));

    // Reopening from the shelf resumes the chapter and the offset.
    await tester.pumpWidget(const SizedBox());
    final entry = (await shelf.onlineShelf()).single;
    await tester.pumpWidget(browser(resume: entry));
    await tester.pumpAndSettle();
    expect(find.byType(OnlineReaderPage), findsOneWidget);
    expect(find.text('第二章'), findsOneWidget);
    expect((await store.progressOf(bookId))!.textOffset, saved);
    expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/ch/2');
    expect(tester.takeException(), isNull);
  });
}
