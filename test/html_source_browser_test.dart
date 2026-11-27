import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/source_host_state.dart';
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

class _AliasCatalogPipeline extends ScriptedPipeline {
  _AliasCatalogPipeline(this.heldTitle);

  final String heldTitle;
  final releaseDetails = Completer<void>();

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async => [
    HtmlBook(url: Uri.parse('$sourceUrl/a'), title: 'A'),
    HtmlBook(
      url: Uri.parse('$sourceUrl/b'),
      rawAddress: '$sourceUrl/b,{"js":"result"}',
      title: 'Alias B',
    ),
    HtmlBook(url: Uri.parse('$sourceUrl/b'), title: 'Bare B'),
  ];

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    if (hit.title == heldTitle) await releaseDetails.future;
    return super.details(hit);
  }
}

class _AddGateShelf extends ShelfService {
  _AddGateShelf(super.store, {this.failFirst = false});
  final bool failFirst;
  final addStarted = Completer<void>();
  final releaseAdd = Completer<void>();

  @override
  Future<({String bookId, int? revision})> add(
    Map<String, dynamic> source,
    HtmlBook book, [
    List<SourceChapter> chapters = const [],
  ]) async {
    if (!addStarted.isCompleted) {
      addStarted.complete();
      await releaseAdd.future;
      if (failFirst) throw StateError('add failed');
    }
    return super.add(source, book, chapters);
  }
}

class _BookMissGateStore extends SpaceStore {
  _BookMissGateStore() : super(SpaceDatabase(NativeDatabase.memory()));

  int missesUntilPause = 0;
  final lookupMiss = Completer<void>();
  final release = Completer<void>();

  @override
  Future<ShelfBook?> bookByNaturalKey(String sourceRef, String bookUrl) async {
    final row = await super.bookByNaturalKey(sourceRef, bookUrl);
    if (row == null && missesUntilPause > 0 && --missesUntilPause == 0) {
      lookupMiss.complete();
      await release.future;
    }
    return row;
  }
}

class _EnsureBookGateShelf extends _AddGateShelf {
  _EnsureBookGateShelf(super.store);
  final provisionalBook = Completer<String>();
  final releaseEnsureBook = Completer<void>();

  @override
  Future<String> ensureBook(Map<String, dynamic> source, HtmlBook book) async {
    final id = await super.ensureBook(source, book);
    provisionalBook.complete(id);
    await releaseEnsureBook.future;
    return id;
  }
}

class _LookupGateShelf extends ShelfService {
  _LookupGateShelf(super.store);
  final lookupStarted = Completer<void>();
  final releaseLookup = Completer<void>();

  @override
  Future<ShelfEntry?> find(String bookSourceUrl, String bookUrl) async {
    final entry = await super.find(bookSourceUrl, bookUrl);
    if (!lookupStarted.isCompleted) {
      lookupStarted.complete();
      await releaseLookup.future;
    }
    return entry;
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

/// A browser analysis whose content stage writes no chapter variable and
/// returns the chapter's own carried text — the corrected snapshot the real
/// content stage produces for a relative TOC address whose row key holds no
/// entry (#132). The rule engine is scripted; the host/store writes are the
/// product's own, which is the read→return→add handoff it covers.
class _RelativeCarrierPipeline extends HtmlSourcePipeline {
  _RelativeCarrierPipeline(SourceHostState hostState)
    : super(source, const _UnusedTransport(), hostState: hostState);

  static const chapterVariable = '{"toc":"T"}';

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async => (
    hit,
    [
      SourceChapter(
        'Book章',
        Uri.parse('$bookUrl/1'),
        rawAddress: '/book/1',
        variable: chapterVariable,
      ),
    ],
  );

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async => HtmlChapterBody('正文', 1, chapterVariable: chapterVariable);
}

/// A resume whose chapter fetch returns the loaded chapter's final content
/// snapshot (#132): that chapter's replacement or deletion stays authoritative,
/// while a chapter the reader never fetched keeps the variable its stored row
/// carried.
class _ResumePipeline extends ScriptedPipeline {
  _ResumePipeline(
    this.loadedVariable, {
    this.contentTitle,
    super.chapterText = '已读章节正文',
  });

  final String? loadedVariable;
  final String? contentTitle;

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    chapterCalls.add('${chapter.url}');
    return HtmlChapterBody(
      chapterText,
      1,
      title: contentTitle,
      chapterVariable: loadedVariable,
    );
  }
}

/// A browser analysis whose content stage writes the entity state through the
/// real host surface and returns the same final snapshots a real content stage
/// returns (#132). The rule engine is scripted — a widget test cannot load the
/// native rule adapter — so this is not a native source run; the variable writes
/// are the product's own host/store writes, which is the read→return→add
/// handoff it covers.
class _ContentWritesPipeline extends HtmlSourcePipeline {
  _ContentWritesPipeline(SourceHostState hostState)
    : super(source, const _UnusedTransport(), hostState: hostState);

  static const detailsBook = '{"detail":"D","shared":"old"}';
  static const detailsChapter = '{"toc":"T"}';
  static const contentBook = '{"shared":"new","content":"B"}';
  static const contentChapter = '{"toc":"T","content":"C"}';

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async => (
    hit.withVariable(detailsBook),
    [
      SourceChapter(
        'Book章',
        Uri.parse('$bookUrl/1'),
        rawAddress: '/book/1',
        variable: detailsChapter,
      ),
    ],
  );

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    final bookKey = book!.identityAddress;
    // The content rule deletes `detail`, replaces `shared` and writes
    // `content`; the chapter rule adds `content` beside the TOC `toc`.
    await hostState!.putBookVariable(sourceUrl, bookKey, contentBook);
    await hostState!.putChapterVariable(
      sourceUrl,
      bookKey,
      chapter.storeKey,
      contentChapter,
    );
    return HtmlChapterBody(
      '正文',
      1,
      bookVariable: contentBook,
      chapterVariable: contentChapter,
    );
  }
}

void main() {
  late SpaceStore store;
  late ShelfService shelf;

  setUp(() {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
  });

  tearDown(() => store.close());

  testWidgets(
    'raw book address refreshes and reads the existing shelf identity',
    (tester) async {
      const address = '$bookUrl?isSearch=1,{"js":"result"}';
      final book = HtmlBook(
        url: Uri.parse(address),
        rawAddress: address,
        title: 'Raw book',
      );
      await shelf.add(source, book);
      // Seed the contractual imported shape independently of the add writer so
      // this also catches an encoded-input caller against an existing raw row.
      final id = (await shelf.onlineShelf()).single.id;
      await store.putBook(
        BooksCompanion(
          id: Value(id),
          title: Value(book.title),
          sourceBookUrl: const Value(address),
        ),
      );
      await shelf.saveProgress(id, textOffset: 37);
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            directBook: book,
            pipeline: ScriptedPipeline(),
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已在书架'), findsOneWidget);
      expect((await store.chaptersOf(id)).single.name, 'Raw book章');
      await tester.tap(find.text('Raw book章'));
      await tester.pumpAndSettle();
      final reader = tester.widget<OnlineReaderPage>(
        find.byType(OnlineReaderPage),
      );
      expect(reader.bookId, id);
      expect(await store.shelf(), hasLength(1));
      expect(tester.takeException(), isNull);
    },
  );

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

  testWidgets('a rule-field script failure reaches the page named', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline(
      detailsError: const SourceScriptError(
        'js',
        'ruleBookInfo.kind: Error: java.getString 未实现',
      ),
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
    // The pipeline's diagnostic stays Chinese (#72's classification); the
    // page's own words around it come from the ARB bundle.
    expect(
      find.text('读取失败：js: ruleBookInfo.kind: Error: java.getString 未实现'),
      findsOneWidget,
    );
  });

  testWidgets('a stage whose body is not JSON reaches the page named', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline(
      detailsError: const SourceStageFormatError(
        stage: BookSourceStage.bookInfo,
        address: 'https://a.test/book',
        prefix: '<html><head><title>502 Bad</titl…',
      ),
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
    expect(
      find.text(
        '读取失败：详情响应不是 JSON（可能是错误页）：'
        '<html><head><title>502 Bad</titl…（https://a.test/book）',
      ),
      findsOneWidget,
    );
  });

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

  testWidgets('two search-result adds both reach the shelf', (tester) async {
    final gatedShelf = _AddGateShelf(store);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          service: gatedShelf,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final addButtons = find.byIcon(Icons.playlist_add);
    expect(addButtons, findsNWidgets(2));
    await tester.tap(addButtons.at(0));
    await tester.pump();
    expect(gatedShelf.addStarted.isCompleted, isTrue);
    await tester.tap(addButtons.at(1));
    await tester.pump();
    gatedShelf.releaseAdd.complete();
    await tester.pumpAndSettle();
    expect(
      (await gatedShelf.onlineShelf()).map((entry) => entry.title),
      containsAll(['A', 'B']),
    );
    expect(await gatedShelf.onlineShelf(), hasLength(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a failed add does not discard the next add', (tester) async {
    final gatedShelf = _AddGateShelf(store, failFirst: true);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          service: gatedShelf,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final addButtons = find.byIcon(Icons.playlist_add);
    await tester.tap(addButtons.at(0));
    await tester.pump();
    await tester.tap(addButtons.at(1));
    gatedShelf.releaseAdd.complete();
    await tester.pumpAndSettle();
    expect((await gatedShelf.onlineShelf()).single.title, 'B');
    expect(find.textContaining('add failed'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('repeating a pending catalog add reports one successful add', (
    tester,
  ) async {
    final gatedShelf = _AddGateShelf(store);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: 'Book');
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: gatedShelf,
          directBook: book,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('加入书架'));
    await tester.pump();
    expect(gatedShelf.addStarted.isCompleted, isTrue);
    await tester.tap(find.text('加入书架'));
    gatedShelf.releaseAdd.complete();
    await tester.pumpAndSettle();

    final entry = (await shelf.onlineShelf()).single;
    expect(entry.title, 'Book');
    expect(
      (await shelf.find(sourceUrl, bookUrl))!.chapters.single.name,
      'Book章',
    );
    expect(find.text('已加入书架：Book'), findsOneWidget);
    expect(find.textContaining('加入书架失败'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('queued catalog add survives returning to search results', (
    tester,
  ) async {
    final gatedShelf = _AddGateShelf(store);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          service: gatedShelf,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add).first);
    await tester.pump();
    expect(gatedShelf.addStarted.isCompleted, isTrue);
    try {
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入书架'));
      await tester.pump();
      await tester.tap(find.text('返回搜索结果'));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.playlist_add), findsNWidgets(2));
    } finally {
      gatedShelf.releaseAdd.complete();
    }
    await tester.pumpAndSettle();
    final entry = await shelf.find(sourceUrl, '$sourceUrl/b');
    expect(entry, isNotNull);
    expect(entry!.shelved, isTrue);
    expect(entry.chapters.single.name, 'B章');
    expect(find.textContaining('加入书架失败'), findsNothing);
  });

  testWidgets('queued catalog add survives popping the browser route', (
    tester,
  ) async {
    final gatedShelf = _AddGateShelf(store);
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => HtmlSourceBrowser(
                  source: source,
                  keyword: '书',
                  service: gatedShelf,
                  pipeline: ScriptedPipeline(),
                ),
              ),
            ),
            child: const Text('Open browser'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open browser'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add).first);
    await tester.pump();
    expect(gatedShelf.addStarted.isCompleted, isTrue);
    try {
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入书架'));
      await tester.pump();
      Navigator.of(tester.element(find.byType(HtmlSourceBrowser))).pop();
      await tester.pumpAndSettle();
      expect(find.text('Open browser'), findsOneWidget);
      expect(find.byType(HtmlSourceBrowser), findsNothing);
    } finally {
      gatedShelf.releaseAdd.complete();
    }
    await tester.pumpAndSettle();
    final entry = await shelf.find(sourceUrl, '$sourceUrl/b');
    expect(entry, isNotNull);
    expect(entry!.shelved, isTrue);
    expect(entry.chapters.single.name, 'B章');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reopening a book with a queued catalog add can read it', (
    tester,
  ) async {
    final gatedShelf = _AddGateShelf(store);
    final pipeline = ScriptedPipeline(chapterText: '重新打开后可以读到的正文');
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          service: gatedShelf,
          pipeline: pipeline,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add).first);
    await tester.pump();
    expect(gatedShelf.addStarted.isCompleted, isTrue);
    try {
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入书架'));
      await tester.pump();
      await tester.tap(find.text('返回搜索结果'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('B'));
      await tester.pump(const Duration(milliseconds: 350));
    } finally {
      gatedShelf.releaseAdd.complete();
    }
    await tester.pumpAndSettle();
    expect(pipeline.detailsCalls, ['B', 'B']);
    expect((await shelf.find(sourceUrl, '$sourceUrl/b'))?.shelved, isTrue);
    await tester.tap(find.text('B章'));
    await tester.pumpAndSettle();
    expect(pipeline.chapterCalls, ['$sourceUrl/b/1']);
    expect(find.textContaining('重新打开后可以读到的正文'), findsOneWidget);
  });

  for (final rowAlreadyExists in [true, false]) {
    testWidgets('reopening through an alias waits for the same row '
        '(row initially present: $rowAlreadyExists)', (tester) async {
      final bookUrl = '$sourceUrl/b';
      final existing = HtmlBook(url: Uri.parse(bookUrl), title: 'Existing B');
      String? existingId;
      if (rowAlreadyExists) {
        final seeded = await shelf.add(source, existing, [
          SourceChapter('previous', Uri.parse('$bookUrl/1')),
        ]);
        await shelf.remove(seeded.bookId);
        existingId = seeded.bookId;
      }
      final first = rowAlreadyExists ? 'Alias B' : 'Bare B';
      final reopened = rowAlreadyExists ? 'Bare B' : 'Alias B';
      final gatedShelf = _AddGateShelf(store);
      final pipeline = _AliasCatalogPipeline(reopened);
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '书',
            service: gatedShelf,
            pipeline: pipeline,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.playlist_add).first);
      await tester.pump();
      expect(gatedShelf.addStarted.isCompleted, isTrue);
      try {
        await tester.tap(find.text(first));
        await tester.pumpAndSettle();
        await tester.tap(find.text('加入书架'));
        await tester.pump();
        await tester.tap(find.text('返回搜索结果'));
        await tester.pumpAndSettle();
        existingId ??= await shelf.ensureBook(source, existing);
        await tester.tap(find.text(reopened));
        await tester.pump();
        gatedShelf.releaseAdd.complete();
        ShelfEntry? shelved;
        for (var i = 0; i < 8; i++) {
          await tester.pump();
          shelved = await shelf.find(sourceUrl, bookUrl);
          if (shelved?.shelved == true) break;
        }
        expect(shelved?.shelved, isTrue);
        expect(shelved?.id, existingId);
      } finally {
        if (!gatedShelf.releaseAdd.isCompleted) {
          gatedShelf.releaseAdd.complete();
        }
        pipeline.releaseDetails.complete();
      }
      await tester.pumpAndSettle();
      expect(pipeline.detailsCalls, [first, reopened]);
      final chapter = find.text('$reopened章');
      expect(chapter, findsOneWidget);
      await tester.tap(chapter);
      await tester.pumpAndSettle();
      expect(pipeline.chapterCalls, ['$bookUrl/1']);
      expect(find.textContaining('正文'), findsOneWidget);
    });
  }

  testWidgets('queued catalog add cannot overwrite an external refresh', (
    tester,
  ) async {
    final gatedShelf = _AddGateShelf(store);
    final book = HtmlBook(url: Uri.parse('$sourceUrl/b'), title: 'B');
    final original = SourceChapter('original', Uri.parse('$sourceUrl/b/1'));
    await shelf.add(source, book, [original]);
    final entry = (await shelf.find(sourceUrl, '$sourceUrl/b'))!;
    await shelf.remove(entry.id);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '书',
          service: gatedShelf,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add).first);
    await tester.pump();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pump();
    await shelf.updateCatalog(sourceUrl, book, [original.withName('fresh')]);
    gatedShelf.releaseAdd.complete();
    await tester.pumpAndSettle();
    final result = (await shelf.find(sourceUrl, '$sourceUrl/b'))!;
    expect(result.chapters.single.name, 'fresh');
    expect(result.shelved, isFalse);
    expect(find.textContaining('加入书架失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('opening after an in-flight add uses its published catalog', (
    tester,
  ) async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final seed = ShelfService(store);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: 'Book');
    final chapter = SourceChapter('Book章', Uri.parse('$bookUrl/1'));
    final seeded = await seed.add(source, book, [chapter]);
    await seed.remove(seeded.bookId);
    final shelf = _AddGateShelf(store);
    final pipeline = ScriptedPipeline(chapterText: '等待加书后读到的正文');
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: shelf,
          directBook: book,
          pipeline: pipeline,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.playlist_add));
    await tester.pump();
    expect(shelf.addStarted.isCompleted, isTrue);
    await tester.tap(find.text('Book章'));
    await tester.pump();
    expect(find.byType(OnlineReaderPage), findsNothing);
    shelf.releaseAdd.complete();
    await tester.pumpAndSettle();

    expect(pipeline.chapterCalls, ['$bookUrl/1']);
    expect(find.textContaining('等待加书后读到的正文'), findsOneWidget);
    final progress = (await store.progressOf(seeded.bookId))!;
    expect(progress.chapterKey, chapter.progressKey);
    expect(progress.chapterIndex, 0);
  });

  for (final addFinishesFirst in [false, true]) {
    final first = addFinishesFirst ? 'add publishes' : 'ensureBook returns';
    testWidgets('read then add opens the published catalog when $first first', (
      tester,
    ) async {
      final gatedShelf = _EnsureBookGateShelf(store);
      final book = HtmlBook(url: Uri.parse(bookUrl), title: 'Book');
      final pipeline = ScriptedPipeline(chapterText: '并发加书后读到的正文');
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            service: gatedShelf,
            directBook: book,
            pipeline: pipeline,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Book章'));
      await tester.pump();
      expect(gatedShelf.provisionalBook.isCompleted, isTrue);
      final bookId = await gatedShelf.provisionalBook.future;
      try {
        final provisional = (await shelf.find(sourceUrl, bookUrl))!;
        expect(provisional.id, bookId);
        expect(provisional.shelved, isFalse);
        expect(provisional.chapters, isEmpty);
        await tester.tap(find.text('加入书架'));
        await tester.pump();
        expect(gatedShelf.addStarted.isCompleted, isTrue);

        if (addFinishesFirst) {
          gatedShelf.releaseAdd.complete();
          await tester.pumpAndSettle();
          expect(find.text('已在书架'), findsOneWidget);
        } else {
          gatedShelf.releaseEnsureBook.complete();
          await tester.pump();
        }
      } finally {
        if (!gatedShelf.releaseAdd.isCompleted) {
          gatedShelf.releaseAdd.complete();
        }
        if (!gatedShelf.releaseEnsureBook.isCompleted) {
          gatedShelf.releaseEnsureBook.complete();
        }
      }
      await tester.pumpAndSettle();

      final entry = (await shelf.onlineShelf()).single;
      expect(entry.id, bookId);
      final published = (await shelf.find(sourceUrl, bookUrl))!;
      expect(published.chapters.single.name, 'Book章');
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(find.textContaining('并发加书后读到的正文'), findsOneWidget);
      expect(pipeline.chapterCalls, ['$bookUrl/1']);
      final progress = (await store.progressOf(bookId))!;
      expect(progress.chapterKey, published.chapters.single.chapterKey);
      expect(progress.chapterIndex, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('read and add share one book after an overlapping lookup miss', (
    tester,
  ) async {
    final stagedStore = _BookMissGateStore();
    addTearDown(stagedStore.close);
    final stagedShelf = ShelfService(stagedStore);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: 'Book');
    final pipeline = ScriptedPipeline(chapterText: '目录已出版的正文');
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: stagedShelf,
          directBook: book,
          pipeline: pipeline,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The browser's read-only find misses first; pause the create lookup.
    stagedStore.missesUntilPause = 2;
    try {
      await tester.tap(find.text('Book章'));
      await tester.pump();
      expect(stagedStore.lookupMiss.isCompleted, isTrue);
      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();
    } finally {
      stagedStore.release.complete();
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final entry = (await stagedShelf.onlineShelf()).single;
    expect(find.textContaining('目录已出版的正文'), findsOneWidget);
    expect(pipeline.chapterCalls, ['$bookUrl/1']);
    expect(
      (await stagedStore.progressOf(entry.id))?.chapterKey,
      entry.chapters.single.chapterKey,
    );
  });

  testWidgets('a catalog refreshed during ensureBook rejects the old read', (
    tester,
  ) async {
    final gatedShelf = _EnsureBookGateShelf(store);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: 'Book');
    final pipeline = _ResumePipeline(null, contentTitle: '旧正文标题');
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: gatedShelf,
          directBook: book,
          pipeline: pipeline,
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Book章'));
    await tester.pump();
    expect(gatedShelf.provisionalBook.isCompleted, isTrue);
    final bookId = await gatedShelf.provisionalBook.future;
    final fresh = SourceChapter('新目录', Uri.parse('$bookUrl/1'));
    try {
      await shelf.updateCatalog(sourceUrl, book, [fresh]);
    } finally {
      gatedShelf.releaseEnsureBook.complete();
    }
    await tester.pumpAndSettle();

    expect(pipeline.chapterCalls, isEmpty);
    expect((await store.chaptersOf(bookId)).single.name, fresh.name);
    expect(await store.progressOf(bookId), isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a slow refresh cannot overwrite a newer catalog', (
    tester,
  ) async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final shelf = ShelfService(store);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '旧详情');
    final old = SourceChapter('旧目录', Uri.parse('$bookUrl/1'));
    await shelf.add(source, book, [old]);
    final gate = Completer<void>();
    final pipeline = ScriptedPipeline(detailsGate: gate);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: shelf,
          directBook: book,
          pipeline: pipeline,
        ),
      ),
    );
    await tester.pump();
    expect(pipeline.detailsCalls, ['旧详情']);
    await shelf.updateCatalog(sourceUrl, book, [old.withName('新目录')]);
    gate.complete();
    await tester.pumpAndSettle();
    final entry = (await shelf.find(sourceUrl, bookUrl))!;
    expect(entry.chapters.single.name, '新目录');
    expect(find.text('旧详情章'), findsNothing);
  });

  testWidgets('a TOC cannot renew its version after the book lookup', (
    tester,
  ) async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final shelf = _LookupGateShelf(store);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '旧详情');
    final old = SourceChapter('旧目录', Uri.parse('$bookUrl/1'));
    await shelf.add(source, book, [old]);
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          service: shelf,
          directBook: book,
          pipeline: ScriptedPipeline(),
        ),
      ),
    );
    await tester.pump();
    expect(shelf.lookupStarted.isCompleted, isTrue);
    final fresh = HtmlBook(url: book.url, title: '新详情');
    await shelf.updateCatalog(sourceUrl, fresh, [old.withName('新目录')]);
    shelf.releaseLookup.complete();
    await tester.pumpAndSettle();
    final entry = (await shelf.find(sourceUrl, bookUrl))!;
    expect(entry.chapters.single.name, '新目录');
    expect(entry.title, '新详情');
    expect(find.text('旧详情章'), findsNothing);
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

  testWidgets(
    'read then add publishes the content stage\'s final entity state',
    (tester) async {
      // The details carriers carry {detail, shared}; the reader's content stage
      // deletes detail, replaces shared and writes content. Returning to the
      // browser and adding must publish the content stage's state, not the
      // stale details/TOC carriers (#132).
      final pipeline = _ContentWritesPipeline(shelf.hostState);
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            directBook: HtmlBook(url: Uri.parse(bookUrl), title: 'Book'),
            pipeline: pipeline,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Book章'), findsOneWidget);
      expect(find.text('加入书架'), findsOneWidget);

      // Open the reader: the content stage writes through the host surface and
      // reports its final snapshots back to the browser.
      await tester.tap(find.text('Book章'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);

      await tapBack(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();

      expect(
        variableMapOf(await store.bookVariable(sourceUrl, bookUrl)),
        {'shared': 'new', 'content': 'B'},
        reason: 'the content stage replaced shared and dropped detail',
      );
      expect(
        variableMapOf(
          await store.chapterVariable(sourceUrl, bookUrl, '$bookUrl/1'),
        ),
        {'toc': 'T', 'content': 'C'},
        reason: 'the chapter keeps its TOC write and the content write',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'read then add keeps a relative TOC chapter variable the content did not rewrite',
    (tester) async {
      // The content stage writes no chapter variable, so the published carrier
      // must still be the chapter's own TOC text (#132).
      final pipeline = _RelativeCarrierPipeline(shelf.hostState);
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            directBook: HtmlBook(url: Uri.parse(bookUrl), title: 'Book'),
            pipeline: pipeline,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Book章'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);

      await tapBack(tester);
      await tester.pumpAndSettle();

      await tester.tap(find.text('加入书架'));
      await tester.pumpAndSettle();

      expect(
        variableMapOf(
          await store.chapterVariable(sourceUrl, bookUrl, '$bookUrl/1'),
        ),
        {'toc': 'T'},
        reason: 'reading without a chapter-variable write keeps the TOC text',
      );
      expect(tester.takeException(), isNull);
    },
  );

  /// A stored two-chapter book with per-chapter variables, removed from the
  /// shelf, resumed through `lastRead()`.
  Future<ShelfEntry> removedBook({
    required String? firstVariable,
    required String? secondVariable,
  }) async {
    await shelf.add(
      source,
      HtmlBook(
        url: Uri.parse(bookUrl),
        title: '恢复书籍',
        variable: '{"book":"B"}',
      ),
      [
        SourceChapter(
          '已读章节',
          Uri.parse('$sourceUrl/c/1'),
          variable: firstVariable,
        ),
        SourceChapter(
          '未读章节',
          Uri.parse('$sourceUrl/c/2'),
          variable: secondVariable,
        ),
      ],
    );
    final id = (await shelf.onlineShelf()).single.id;
    await shelf.saveProgress(
      id,
      chapterIndex: 0,
      chapterKey: '$sourceUrl/c/1',
      textOffset: 0,
    );
    await shelf.remove(id);
    return (await shelf.lastRead())!;
  }

  /// Resumes [resume], reads its saved chapter, returns and adds it back,
  /// answering the stored chapter rows. The stored TOC must be used as it is:
  /// only the saved chapter is fetched, and no details/TOC refresh runs.
  Future<List<BookChapter>> resumeReadAndReadd(
    WidgetTester tester,
    ShelfEntry resume,
    _ResumePipeline pipeline,
  ) async {
    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          resume: resume,
          pipeline: pipeline,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(pipeline.detailsCalls, isEmpty, reason: '沿用已存目录，不刷新');
    expect(pipeline.chapterCalls, ['$sourceUrl/c/1'], reason: '只读已保存的那一章');
    expect(find.byType(OnlineReaderPage), findsOneWidget);

    await tapBack(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();
    return store.chaptersOf(resume.id);
  }

  testWidgets('re-adding a reopened chapter keeps its saved request and key', (
    tester,
  ) async {
    const key = '$sourceUrl/chapter?q=%E4%B8%AD';
    const address = '/chapter?q=中#part,{"charset":"gbk","js":"result"}';
    const first = '　　第一段';
    final offset = first.length + 1;
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '原书');
    final id = (await shelf.add(source, book)).bookId;
    await store.putChapters(id, [
      BookChapter(
        bookId: id,
        chapterKey: key,
        name: '目录标题',
        url: address,
        chapterIndex: 0,
        isVolume: false,
        isVip: false,
        isPay: false,
        variable: '{"loaded":"old"}',
      ),
    ]);
    await shelf.saveProgress(
      id,
      chapterKey: key,
      chapterIndex: 0,
      textOffset: offset,
    );
    await shelf.remove(id);
    final resume = (await shelf.lastRead())!;
    final pipeline = _ResumePipeline(
      '{"loaded":"new"}',
      contentTitle: '正文标题',
      chapterText: '$first\n　　第二段\n　　第三段',
    );

    await tester.pumpWidget(
      localizedApp(
        home: HtmlSourceBrowser(
          source: source,
          keyword: '',
          resume: resume,
          pipeline: pipeline,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('正文标题'), findsOneWidget);
    expect(pipeline.detailsCalls, isEmpty);
    expect(pipeline.chapterCalls, ['$key#part']);
    final read = (await store.progressOf(id))!;
    expect(read.textOffset, offset);
    await tapBack(tester);
    await tester.pumpAndSettle();
    await tester.tap(find.text('加入书架'));
    await tester.pumpAndSettle();

    final entry = (await shelf.onlineShelf()).single;
    expect(entry.id, id);
    final row = (await store.chaptersOf(id)).single;
    expect((row.chapterKey, row.url), (key, address));
    expect(row.name, '正文标题');
    expect(row.variable, '{"loaded":"new"}');
    expect(await store.progressOf(id), read);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'resuming a removed book keeps unread chapter variables through read then add',
    (tester) async {
      final resume = await removedBook(
        firstVariable: '{"loaded":"old"}',
        secondVariable: '{"unread":"U"}',
      );
      final pipeline = _ResumePipeline('{"loaded":"L"}');

      final rows = await resumeReadAndReadd(tester, resume, pipeline);

      expect(
        (await shelf.onlineShelf()).single.id,
        resume.id,
        reason: '原 id 保留',
      );
      expect(rows, hasLength(2));
      expect(rows[0].variable, '{"loaded":"L"}', reason: '已读章节以正文快照为准');
      expect(rows[1].variable, '{"unread":"U"}', reason: '未读章节变量原样保留');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resuming a removed book keeps a present-empty unread chapter variable',
    (tester) async {
      final resume = await removedBook(
        firstVariable: '{"loaded":"old"}',
        secondVariable: '',
      );
      final pipeline = _ResumePipeline('{"loaded":"L"}');

      final rows = await resumeReadAndReadd(tester, resume, pipeline);

      expect(rows[1].variable, '', reason: '存在但为空的变量原样保留，不回退为 null');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    "resuming a removed book publishes the loaded chapter's deleted variable",
    (tester) async {
      final resume = await removedBook(
        firstVariable: '{"loaded":"old"}',
        secondVariable: '{"unread":"U"}',
      );
      final pipeline = _ResumePipeline('{}');

      final rows = await resumeReadAndReadd(tester, resume, pipeline);

      expect(rows[0].variable, '{}', reason: '已读章节的显式删除生效');
      expect(rows[1].variable, '{"unread":"U"}');
      expect(tester.takeException(), isNull);
    },
  );
}
