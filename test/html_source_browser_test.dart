import 'dart:async';
import 'dart:convert';
import 'dart:io';

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
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

const sourceUrl = 'https://example.test';
const bookUrl = '$sourceUrl/book';

const source = <String, dynamic>{
  'bookSourceUrl': sourceUrl,
  'bookSourceName': 'Example',
};

/// The browser's analyses are scripted: the real `details()`/`chapter()` drive
/// the Rust rule adapter, which a widget test cannot load (the binding never
/// settles flutter_rust_bridge's pending work).
///
/// [analysisMarker] stands in for the pipeline fields one analysis owns
/// (`_page`/`_ruleState`/`_bookOptions` in the real pipeline), so a second
/// analysis overwriting them under a running one is observable.
class ScriptedPipeline extends HtmlSourcePipeline {
  ScriptedPipeline({
    this.detailsGate,
    this.chapterGate,
    this.detailsError,
    this.chapterText = '正文',
  }) : super(source, const _UnusedTransport());

  /// Holds a `details()` response so the overlap can be driven.
  final Completer<void>? detailsGate;

  /// Holds a `chapter()` response so a `details()` can run under it.
  final Completer<void>? chapterGate;
  final Object? detailsError;
  final String chapterText;
  int searchCalls = 0;

  final detailsCalls = <String>[];
  final chapterCalls = <String>[];
  int analysisMarker = 0;
  bool chapterSawMarkerChange = false;

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    searchCalls++;
    return [
      HtmlBook(url: Uri.parse('$sourceUrl/a'), title: 'A'),
      HtmlBook(url: Uri.parse('$sourceUrl/b'), title: 'B'),
    ];
  }

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    detailsCalls.add(hit.title);
    analysisMarker++;
    if (detailsGate != null) await detailsGate!.future;
    if (detailsError != null) throw detailsError!;
    return (hit, [SourceChapter('${hit.title}章', Uri.parse('${hit.url}/1'))]);
  }

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    expect(book?.title, isNotEmpty);
    chapterCalls.add('${chapter.url}');
    final marker = analysisMarker;
    if (chapterGate != null) await chapterGate!.future;
    if (analysisMarker != marker) chapterSawMarkerChange = true;
    return HtmlChapterBody(chapterText, 1);
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

/// A details stage that returns table-of-contents markers (#13), so the TOC
/// list's rendering of them can be driven without the rule adapter.
class _MarkerPipeline extends ScriptedPipeline {
  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async => (
    hit,
    [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1'), tag: '2026-01-01'),
      SourceChapter.volume(
        '第一卷',
        0,
        tocUrl: Uri.parse('$sourceUrl/v'),
        tag: '卷首',
      ),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2'), isVip: true),
      SourceChapter('第四章', Uri.parse('$sourceUrl/4'), tag: _longTag),
    ],
  );
}

/// A tag long enough to wrap without the frozen `singleLine="true"`.
const _longTag = '2026-01-01 12:34:56 更新时间很长很长很长很长很长很长很长很长很长很长很长很长';

void main() {
  late SpaceStore store;
  late ShelfService shelf;

  setUp(() {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
  });

  tearDown(() => store.close());

  testWidgets(
    'direct book starts details without search; failure leaves no selection or shelf row',
    (tester) async {
      final pipeline = ScriptedPipeline(
        detailsError: StateError('detail failed'),
      );
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            directBook: HtmlBook(url: Uri.parse(bookUrl), title: ''),
            pipeline: pipeline,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(pipeline.searchCalls, 0);
      expect(pipeline.detailsCalls, ['']);
      expect(find.textContaining('detail failed'), findsOneWidget);
      expect(await shelf.find(sourceUrl, bookUrl), isNull);
      expect(find.text('加入书架'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('the TOC list shows the tag, the volume heading and the lock', (
    tester,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          directBook: HtmlBook(url: Uri.parse(bookUrl), title: ''),
          pipeline: _MarkerPipeline(),
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // A non-volume chapter's `tag` is its secondary line and a volume is a
    // heading that keeps its own `tag` hidden (`ChapterListAdapter.kt:138-150`).
    expect(find.text('2026-01-01'), findsOneWidget);
    expect(find.text('第一卷'), findsOneWidget);
    expect(find.text('卷首'), findsNothing);
    // A volume row differs only in its background (`:138-139`), and the frozen
    // row is `singleLine="true"` (`res/layout/item_chapter_list.xml`), so a
    // long name or tag stays on one line instead of growing the row.
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
    expect(volumeName.maxLines, 1);
    expect(volumeName.overflow, TextOverflow.ellipsis);
    final longTag = tester.widget<Text>(find.text(_longTag));
    expect(longTag.maxLines, 1);
    expect(longTag.overflow, TextOverflow.ellipsis);
    // The lock is `isVip && !isPay` (`ChapterListAdapter.kt:162-165`).
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposing a direct-book analysis cancels its pipeline', (
    tester,
  ) async {
    final gate = Completer<void>();
    final pipeline = ScriptedPipeline(detailsGate: gate);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          directBook: HtmlBook(url: Uri.parse(bookUrl), title: ''),
          pipeline: pipeline,
          service: shelf,
        ),
      ),
    );
    await tester.pump();
    expect(pipeline.searchCalls, 0);
    expect(pipeline.detailsCalls, ['']);
    await tester.pumpWidget(localizedApp(home: SizedBox()));
    expect(pipeline.cancelled, isTrue);
    gate.complete();
    await tester.pumpAndSettle();
    expect(await shelf.find(sourceUrl, bookUrl), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('two overlapping details() run one analysis, never two', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline(detailsGate: Completer<void>());
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          pipeline: pipeline,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('A'), findsOneWidget);

    // Two taps before the frame rebuilds: the first starts an analysis and owns
    // the pipeline; the second must not run beside it.
    await tester.tap(find.text('A'));
    await tester.tap(find.text('B'));
    expect(pipeline.detailsCalls, [
      'A',
    ], reason: '第二次 details() 只能被忽略，不能与第一次共用同一个 pipeline');

    pipeline.detailsGate!.complete();
    await tester.pumpAndSettle();
    // The book, its chapter list and every value they were built from belong
    // to the one admitted call.
    expect(find.text('A章'), findsOneWidget);
    expect(find.text('B章'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a stored chapter address resumes with its options', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline();
    final bookId = await shelf.ensureBook(
      source,
      HtmlBook(url: Uri.parse(bookUrl), title: '书'),
    );
    await store.putChapters(bookId, [
      BookChapter(
        bookId: bookId,
        chapterKey: '$sourceUrl/1',
        name: '第一章',
        // What the shelf writes (#58): the key is the bare request target, the
        // url is the address text the TOC rule produced.
        url: '$sourceUrl/1,{"webView":true,"webViewDelayTime":25}',
        chapterIndex: 0,
        isVolume: false,
        isVip: false,
        isPay: false,
      ),
    ]);
    final entry = (await shelf.find(sourceUrl, bookUrl))!;

    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          pipeline: pipeline,
          service: shelf,
          resume: entry,
        ),
      ),
    );
    await tester.pumpAndSettle();
    final reader = tester.widget<OnlineReaderPage>(
      find.byType(OnlineReaderPage),
    );
    final chapter = reader.chapters.single;
    expect('${chapter.url}', '$sourceUrl/1', reason: '请求目标不带选项');
    expect(chapter.options.webView, isTrue, reason: '重启后选项仍在');
    expect(chapter.options.webViewDelayTime, 25);
  });

  for (final address in [
    '../chapter/1',
    '../chapter/1,{"webView":true}',
    'https://example.test/chapter/1',
  ]) {
    testWidgets('an imported chapter $address resolves for reading only', (
      tester,
    ) async {
      final pipeline = ScriptedPipeline();
      final home = await tester.runAsync(
        () => Directory.systemTemp.createTemp('liber-relative-chapter-'),
      );
      try {
        await tester.runAsync(() async {
          await File('${home!.path}/online_reading.json').writeAsString(
            jsonEncode({
              'version': 2,
              'records': [
                {
                  'source': source,
                  'book': {'url': '$bookUrl/1', 'title': '书'},
                  'chapterUrl': address,
                  'chapterName': '第一章',
                  'textOffset': 0,
                  'chapters': [
                    {'name': '第一章', 'url': address},
                  ],
                  'shelved': true,
                },
              ],
            }),
          );
          await LegacyImport(home: home).run(store);
        });
        final entry = (await shelf.find(sourceUrl, '$bookUrl/1'))!;
        await tester.pumpWidget(
          localizedApp(
            home: HtmlSourceBrowser(
              source: source,
              keyword: '',
              pipeline: pipeline,
              service: shelf,
              resume: entry,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final chapter = tester
            .widget<OnlineReaderPage>(find.byType(OnlineReaderPage))
            .chapters
            .single;
        expect('${chapter.url}', 'https://example.test/chapter/1');
        expect(chapter.address, address);
        expect(chapter.options.webView, address.contains('webView'));
        expect(entry.chapters.single.chapterKey, address);
        expect(entry.chapters.single.url, address);
        expect(pipeline.chapterCalls.single, 'https://example.test/chapter/1');
        expect(chapter.progressKey, address);
        expect((await store.progressOf(entry.id))!.chapterKey, address);
      } finally {
        await tester.runAsync(() => home!.delete(recursive: true));
      }
    });
  }

  testWidgets(
    'catalog reorder resumes an imported chapter by resolved identity',
    (tester) async {
      const chapterA = '../chapters/a';
      const chapterB = '../chapters/b';
      final pipeline = ScriptedPipeline(
        chapterText: '${List.filled(77, 'x').join()}\n正文',
      );
      final home = await tester.runAsync(
        () => Directory.systemTemp.createTemp('liber-refresh-chapter-'),
      );
      try {
        await tester.runAsync(() async {
          await File('${home!.path}/online_reading.json').writeAsString(
            jsonEncode({
              'version': 2,
              'records': [
                {
                  'source': source,
                  'book': {'url': '$bookUrl/1', 'title': '书'},
                  'chapterUrl': chapterB,
                  'chapterName': 'B',
                  'textOffset': 78,
                  'chapters': [
                    {'name': 'A', 'url': chapterA},
                    {'name': 'B', 'url': chapterB},
                  ],
                  'shelved': true,
                },
              ],
            }),
          );
          await LegacyImport(home: home).run(store);
        });
        final initial = (await shelf.find(sourceUrl, '$bookUrl/1'))!;
        expect(initial.chapterKey, chapterB);
        expect(initial.chapterIndex, 1);
        await shelf.updateCatalog(sourceUrl, initial.htmlBook, [
          SourceChapter('B', Uri.parse('$sourceUrl/chapters/b')),
          SourceChapter('A', Uri.parse('$sourceUrl/chapters/a')),
        ]);
        final refreshed = (await shelf.find(sourceUrl, '$bookUrl/1'))!;
        expect(refreshed.chapterKey, chapterB);
        expect(refreshed.chapterIndex, 1);
        expect(refreshed.chapters.map((chapter) => chapter.name), ['B', 'A']);
        expect(refreshed.textOffset, 78);
        await tester.pumpWidget(
          localizedApp(
            home: HtmlSourceBrowser(
              source: source,
              keyword: '',
              pipeline: pipeline,
              service: shelf,
              resume: refreshed,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(pipeline.chapterCalls.single, '$sourceUrl/chapters/b');
        final reader = tester.widget<OnlineReaderPage>(
          find.byType(OnlineReaderPage),
        );
        expect(reader.chapterIndex, 0);
        expect(reader.textOffset, 78);
        expect(find.text('B'), findsWidgets);
        final progress = (await store.progressOf(refreshed.id))!;
        expect(progress.chapterKey, '$sourceUrl/chapters/b');
      } finally {
        await tester.runAsync(() => home!.delete(recursive: true));
      }
    },
  );

  testWidgets(
    'disposing the browser leaves the pipeline its reader holds alone',
    (tester) async {
      final pipeline = ScriptedPipeline();
      final bookId = await shelf.ensureBook(
        source,
        HtmlBook(url: Uri.parse(bookUrl), title: '书'),
      );
      await store.putChapters(bookId, [
        BookChapter(
          bookId: bookId,
          chapterKey: '$sourceUrl/1',
          name: '第一章',
          url: '$sourceUrl/1',
          chapterIndex: 0,
          isVolume: false,
          isVip: false,
          isPay: false,
        ),
      ]);
      final entry = (await shelf.find(sourceUrl, bookUrl))!;

      var showBrowser = true;
      late StateSetter hostSetState;
      await tester.pumpWidget(
        localizedApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              hostSetState = setState;
              return showBrowser
                  ? HtmlSourceBrowser(
                      source: source,
                      keyword: '',
                      pipeline: pipeline,
                      service: shelf,
                      resume: entry,
                    )
                  : const SizedBox();
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final reader = tester.widget<OnlineReaderPage>(
        find.byType(OnlineReaderPage),
      );
      expect(
        reader.pipeline,
        same(pipeline),
        reason: '阅读器接管浏览器交给它的 pipeline，而不是另起一个',
      );

      showBrowser = false;
      hostSetState(() {});
      await tester.pumpAndSettle();
      expect(pipeline.cancelled, isFalse, reason: '浏览器页面销毁不得取消阅读器正在进行的取章');
    },
  );

  testWidgets(
    'a details() under an in-flight chapter fetch cannot overwrite it',
    (tester) async {
      final pipeline = ScriptedPipeline(chapterGate: Completer<void>());
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '书',
            pipeline: pipeline,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('A'));
      await tester.pumpAndSettle();
      expect(find.text('A章'), findsOneWidget);

      // Capture the browser's 更新目录 entry while it is onstage; the reader
      // covers this page, but the browser still holds a pipeline.
      final refresh = tester
          .widget<OutlinedButton>(find.widgetWithText(OutlinedButton, '更新目录'))
          .onPressed!;

      await tester.tap(find.text('A章'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(pipeline.chapterCalls, ['$sourceUrl/a/1']);

      refresh();
      await tester.pump();

      pipeline.chapterGate!.complete();
      await tester.pumpAndSettle();
      expect(
        pipeline.chapterSawMarkerChange,
        isFalse,
        reason: 'details() 不得覆写正在取章的 pipeline 的页面与规则状态',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
