import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/precise_search.dart';
import 'package:liber/source/precise_search_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// One source's scripted answers: what its search returns, what its details
/// stage answers with, whether its content stage answers, and how often each
/// was asked.
class FakeSource {
  FakeSource(
    this.source, {
    List<HtmlBook>? hits,
    this.failure,
    List<String>? titles,
    this.contentFailure,
    this.delay,
  }) : hits = hits ?? <HtmlBook>[],
       titles = titles ?? <String>[];

  final Map<String, dynamic> source;
  final List<HtmlBook> hits;
  Object? failure;
  final List<String> titles;
  Object? contentFailure;

  /// How long this source's search takes, for the walk's own rows.
  final Duration? delay;

  /// Whether this source's pipeline was already cancelled when its search
  /// returned from its own delay — the walk's cancellation, seen from inside a
  /// search that was in flight.
  bool? cancelledDuringSearch;
  int searchCalls = 0;
  int detailsCalls = 0;
  int contentCalls = 0;
  final keywords = <String>[];

  /// Holds this source's search response so a page can be disposed while its
  /// analysis is in flight.
  Completer<void>? gate;
}

class _UnusedTransport implements BookSourceTransport {
  const _UnusedTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('该测试不经过传输层');
}

class ScriptedPipeline extends HtmlSourcePipeline {
  ScriptedPipeline(this.fake) : super(fake.source, const _UnusedTransport());
  final FakeSource fake;

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    fake.searchCalls++;
    fake.keywords.add(keyword);
    if (fake.gate != null) await fake.gate!.future;
    if (fake.failure != null) throw fake.failure!;
    return fake.hits;
  }

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    fake.detailsCalls++;
    final sourceUrl = '${fake.source['bookSourceUrl']}';
    return (
      hit,
      [
        for (var i = 0; i < fake.titles.length; i++)
          SourceChapter(fake.titles[i], Uri.parse('$sourceUrl/chapter/$i')),
      ],
    );
  }

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    fake.contentCalls++;
    if (fake.contentFailure != null) throw fake.contentFailure!;
    return HtmlChapterBody('${chapter.name}的正文', 1);
  }
}

/// How many of a run's sources are being searched at the same time, and what
/// has happened to them — the #108 rows' own instrument. The pipeline below
/// feeds it, so a row can assert the bound the walk kept and when answers
/// arrived rather than only what the page ended up showing.
class WalkWatch {
  /// Sources whose search has begun.
  int started = 0;

  /// Sources whose search is running right now.
  int inFlight = 0;

  /// The most that were ever running at once — the walk's real bound.
  int maxInFlight = 0;

  /// Sources whose search has returned.
  int completed = 0;

  void begin() {
    started++;
    inFlight++;
    if (inFlight > maxInFlight) maxInFlight = inFlight;
  }

  void end() {
    inFlight--;
    completed++;
  }
}

/// A scripted source whose search answers after [fake]'s own [FakeSource.delay]
/// and which reports to [watch] — the timing, cancellation and timeout rows of
/// #108 drive this one.
class TimedPipeline extends ScriptedPipeline {
  TimedPipeline(super.fake, this.watch);

  final WalkWatch watch;

  @override
  Future<List<HtmlBook>> search(String keyword, {int page = 1}) async {
    watch.begin();
    try {
      final delay = fake.delay;
      if (delay != null) await Future<void>.delayed(delay);
      fake.cancelledDuringSearch = cancelled;
      return await super.search(keyword, page: page);
    } finally {
      watch.end();
    }
  }
}

/// The multi-source search entry (#40): the frozen precise search across the
/// selected sources, its candidates, its early stop and its no-match answer,
/// driven through scripted pipelines.
///
/// The real adapters cannot run in a widget test (the binding never settles
/// flutter_rust_bridge's pending work), so what these drive is the entry's own
/// decisions: which sources are searched, in what order, which hits are
/// admitted, where the early stop cuts, and what the switch writes. The search
/// stage's own rule semantics have their coverage in the pipeline tests.
void main() {
  late SpaceStore store;
  late ShelfService shelf;

  const name = '凡人修仙传';
  const author = '忘语';

  HtmlBook candidate(String sourceUrl, String id, String title, String by) =>
      HtmlBook(url: Uri.parse('$sourceUrl/book/$id'), title: title, author: by);

  late FakeSource sourceA;
  late FakeSource sourceB;
  late FakeSource sourceC;

  Map<String, FakeSource> byRef = {};

  BookSourcePipeline open(Map<String, dynamic> source) =>
      ScriptedPipeline(byRef['${source['bookSourceUrl']}']!);

  /// One scripted source as the walk takes it.
  ImportedBookSource imported(FakeSource fake) => ImportedBookSource(
    id: '${fake.source['bookSourceUrl']}',
    data: fake.source,
  );

  /// [count] more scripted sources past 甲/乙/丙, in the store and in [byRef]:
  /// the #108 rows need more sources than the walk's own bound, so that there
  /// is a queue behind the sources already in flight.

  setUp(() async {
    // A widget test cannot await a background-isolate database
    // (`SpaceDatabase.file`), so this drives an in-memory store in the test's
    // own isolate, the way `html_source_browser_test.dart` does.
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    sourceA = FakeSource({
      'bookSourceUrl': 'https://a.test',
      'bookSourceName': '甲源',
    });
    sourceB = FakeSource({
      'bookSourceUrl': 'https://b.test',
      'bookSourceName': '乙源',
    });
    sourceC = FakeSource({
      'bookSourceUrl': 'https://c.test',
      'bookSourceName': '丙源',
    });
    byRef = {
      'https://a.test': sourceA,
      'https://b.test': sourceB,
      'https://c.test': sourceC,
    };
    for (final fake in byRef.values) {
      await store.putSourceJson(fake.source);
    }
  });

  Future<List<FakeSource>> moreSources(int count) async {
    final more = <FakeSource>[];
    for (var i = 0; i < count; i++) {
      final fake = FakeSource({
        'bookSourceUrl': 'https://s$i.test',
        'bookSourceName': '源$i',
      });
      byRef['https://s$i.test'] = fake;
      await store.putSourceJson(fake.source);
      more.add(fake);
    }
    return more;
  }

  tearDown(() => store.close());

  Future<void> pumpEntry(WidgetTester tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(
          service: shelf,
          initialName: name,
          initialAuthor: author,
          openPipeline: open,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('搜索按书源顺序进行，每源只收录到第一处精确命中', (tester) async {
    sourceA.hits.addAll([
      candidate('https://a.test', '1', name, '别人的作者'),
      candidate('https://a.test', '2', name, author),
      candidate('https://a.test', '3', name, '第三本'),
    ]);
    sourceB.hits.add(candidate('https://b.test', '1', name, '别人的作者'));

    await pumpEntry(tester);

    expect(sourceA.keywords, [name], reason: '冻结用书名搜索');
    expect(sourceB.searchCalls, 1);
    expect(sourceC.searchCalls, 1);
    // 甲源 list order: the inexact hit before the exact one is a candidate, and
    // the early stop drops the one after it.
    expect(find.text('第三本'), findsNothing);
    expect(find.textContaining('别人的作者'), findsOneWidget);
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '候选 3 本，其中精确匹配 1 本',
    );
    // The candidate list is lazy (#86), so 乙源's row is built when the viewport
    // reaches it: the two inexact candidates are both there, 乙源's below 甲源's.
    await tester.scrollUntilVisible(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('别人的作者'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源搜索出错只记录该书源，其他书源的结果照常列出', (tester) async {
    sourceA.failure = StateError('页面读取失败');
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);

    expect(find.textContaining('甲源 出错：'), findsOneWidget);
    expect(find.textContaining('页面读取失败'), findsOneWidget);
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('没有命中时给出冻结的没有搜索到', (tester) async {
    sourceA.hits.add(candidate('https://a.test', '1', '另一本书', author));
    sourceB.hits.add(candidate('https://b.test', '2', name, '别人的作者'));

    await pumpEntry(tester);

    // 乙源's hit carries the right name but another author: with the frozen
    // default `changeSourceCheckAuthor` off it is still a candidate.
    expect(find.textContaining('候选 1 本，其中精确匹配 0 本'), findsOneWidget);

    // The author check on turns it away, and then nothing matched at all.
    await tester.tap(find.byKey(const ValueKey('precise-check-author')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('precise-search')));
    await tester.pumpAndSettle();

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '没有搜索到<$name>$author',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('只搜索选中的书源', (tester) async {
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);
    expect(sourceB.searchCalls, 1);

    await tester.tap(
      find.byKey(const ValueKey('precise-source-https://b.test')),
    );
    await tester.pumpAndSettle();
    sourceB.searchCalls = 0;
    await tester.tap(find.byKey(const ValueKey('precise-search')));
    await tester.pumpAndSettle();

    expect(sourceB.searchCalls, 0, reason: '未选中的书源不被搜索');
    expect(find.textContaining('· 精确匹配'), findsNothing);
  });

  /// 乙源 as the operator's backup carries a disabled used source (#107: 5 of
  /// 150): grouped, ordered, a text source, and `enabled: false`.
  Map<String, dynamic> disabledUsedStyle(FakeSource fake) => {
    ...fake.source,
    'bookSourceGroup': '精品,常用',
    'bookSourceType': 0,
    'customOrder': 1,
    'enabled': false,
  };

  testWidgets('换源列表：停用的书源不列出、不被搜索，启用的照常搜索（冻结 allEnabledPart）', (tester) async {
    // The frozen dialog searches only `enabled = 1` (`allEnabledPart`) and has
    // no way to add a disabled source to the run (#114).
    await store.putSourceJson(disabledUsedStyle(sourceB));
    sourceA.hits.add(candidate('https://a.test', '1', name, '别人的作者'));
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);

    expect(sourceA.searchCalls, 1, reason: '启用的书源照常搜索一次');
    expect(sourceC.searchCalls, 1, reason: '启用的书源照常搜索一次');
    expect(sourceB.searchCalls, 0, reason: '停用的书源不被搜索');
    expect(
      find.byKey(const ValueKey('precise-source-https://b.test')),
      findsNothing,
      reason: '停用的书源没有筛选项，也就无从选中',
    );
    expect(
      find.byKey(const ValueKey('precise-source-https://a.test')),
      findsOneWidget,
    );
    expect(find.textContaining('· 精确匹配'), findsNothing);
    expect(find.textContaining('候选 1 本，其中精确匹配 0 本'), findsOneWidget);

    // Searching again from the page still leaves the disabled source out.
    await tester.tap(find.byKey(const ValueKey('precise-search')));
    await tester.pumpAndSettle();
    expect(sourceB.searchCalls, 0, reason: '再搜一次也不搜停用的书源');
    expect(sourceA.searchCalls, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源：停用的书源在库里被启用后，下一次打开页面就能被搜索', (tester) async {
    // No product surface flips `enabled` yet (the source-management gap #114
    // records); the store row is what the page reads on each load.
    await store.putSourceJson(disabledUsedStyle(sourceB));
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);
    expect(sourceB.searchCalls, 0);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await store.putSourceJson({...disabledUsedStyle(sourceB), 'enabled': true});

    await pumpEntry(tester);
    expect(sourceB.searchCalls, 1, reason: '重新启用后下一次搜索就包括它');
    expect(
      find.byKey(const ValueKey('precise-source-https://b.test')),
      findsOneWidget,
    );
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('书源没有 raw 时仍按存储的 enabled 排除停用源', (tester) async {
    await store.deleteSource('https://b.test');
    await store.putSource(
      SourcesCompanion.insert(
        bookSourceUrl: 'https://b.test',
        name: '乙源',
        enabled: const Value(false),
      ),
    );
    expect((await store.sourceByUrl('https://b.test'))!.raw, isNull);

    await pumpEntry(tester);

    expect(sourceB.searchCalls, 0);
    expect(sourceA.searchCalls, 1);
    expect(sourceC.searchCalls, 1);
    expect(
      find.byKey(const ValueKey('precise-source-https://b.test')),
      findsNothing,
    );
    expect(await shelf.sources(), hasLength(3), reason: '仅搜索页过滤，不删除存储的书源');
    expect(tester.takeException(), isNull);
  });

  testWidgets('空间里的书源全部停用：不搜索，并说明没有启用的书源', (tester) async {
    for (final fake in byRef.values) {
      await store.putSourceJson({...fake.source, 'enabled': false});
    }

    await pumpEntry(tester);

    expect(byRef.values.every((fake) => fake.searchCalls == 0), isTrue);
    expect(find.byType(FilterChip), findsNothing);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '空间里没有启用的书源',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面销毁后不再为后面的书源发起搜索，在飞的分析被取消', (tester) async {
    // The walk searches several sources at once (#108), so the "sources after
    // the one in flight" are the ones behind its own bound: the page is given
    // more sources than that bound, so there is a queue that must never start.
    // Every source is held, so nothing settles until this row says so.
    // 甲/乙/丙 plus enough for a queue behind the walk's own bound.
    final more = await moreSources(PreciseSearch.defaultConcurrency);
    final all = [...byRef.values];
    expect(all, hasLength(3 + more.length));
    expect(
      all.length,
      greaterThan(PreciseSearch.defaultConcurrency),
      reason: '比走查自己的上界多出几个书源，队列才有意义',
    );
    for (final fake in all) {
      fake.gate = Completer<void>();
    }
    final created = <ScriptedPipeline>[];
    BookSourcePipeline openRecording(Map<String, dynamic> source) {
      final pipeline = ScriptedPipeline(byRef['${source['bookSourceUrl']}']!);
      created.add(pipeline);
      return pipeline;
    }

    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(
          service: shelf,
          initialName: name,
          initialAuthor: author,
          openPipeline: openRecording,
        ),
      ),
    );
    for (
      var i = 0;
      i < 50 && created.length < PreciseSearch.defaultConcurrency;
      i++
    ) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    int searched() => all.where((fake) => fake.searchCalls > 0).length;
    expect(
      created,
      hasLength(PreciseSearch.defaultConcurrency),
      reason: '一次最多这么多个书源在飞',
    );
    expect(searched(), PreciseSearch.defaultConcurrency);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(
      created.every((pipeline) => pipeline.cancelled),
      isTrue,
      reason: '在飞的分析随页面销毁取消',
    );

    // Every held source answers now: the queue behind the walk must still not
    // be started, and no pipeline may be opened for it.
    for (final fake in all) {
      fake.gate!.complete();
    }
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(
      created,
      hasLength(PreciseSearch.defaultConcurrency),
      reason: '销毁后不得再新建 pipeline',
    );
    expect(
      searched(),
      PreciseSearch.defaultConcurrency,
      reason: '销毁后不得再为后面的书源发起搜索',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源：选中的候选把书换到新书源并带着进度', (tester) async {
    final bookId = await shelf.ensureBook(
      sourceA.source,
      HtmlBook(
        url: Uri.parse('https://a.test/book/1'),
        title: name,
        author: author,
      ),
    );
    await shelf.add(
      sourceA.source,
      HtmlBook(
        url: Uri.parse('https://a.test/book/1'),
        title: name,
        author: author,
      ),
      [
        for (var i = 0; i < 5; i++)
          SourceChapter('第${i + 1}章', Uri.parse('https://a.test/chapter/$i')),
      ],
    );
    await shelf.saveProgress(
      bookId,
      chapterKey: 'https://a.test/chapter/2',
      chapterIndex: 2,
      textOffset: 42,
    );
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章', '第四章']);

    final entry = (await shelf.find(
      'https://a.test',
      'https://a.test/book/1',
    ))!;
    expect(entry.chapterName, '第3章');

    var popped = false;
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final switched = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => PreciseSearchPage(
                    service: shelf,
                    switchBook: entry,
                    openPipeline: open,
                  ),
                ),
              );
              popped = switched == true;
            },
            child: const Text('打开换源'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开换源'));
    await tester.pumpAndSettle();

    expect(find.textContaining('当前书源：甲源'), findsOneWidget);
    // 甲源's own copy of the book matches too, so pick 乙源's card by its key.
    await tester.tap(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    final switched = (await store.bookById(bookId))!;
    expect(switched.sourceRef, 'https://b.test');
    expect(switched.sourceBookUrl, 'https://b.test/book/1');
    final progress = (await store.progressOf(bookId))!;
    expect(progress.chapterIndex, 2);
    expect(progress.chapterKey, 'https://b.test/chapter/2');
    expect(progress.textOffset, 42);
    expect((await shelf.onlineShelf()).single.chapterName, '第三章');
    expect(tester.takeException(), isNull);
  });

  /// A book on 甲源, read at the third of five chapters (偏移 42) — the row a
  /// switch re-points. The rows below drive the switch flow through it.
  Future<ShelfEntry> shelvedBook() async {
    await shelf.add(
      sourceA.source,
      HtmlBook(
        url: Uri.parse('https://a.test/book/1'),
        title: name,
        author: author,
      ),
      [
        for (var i = 0; i < 5; i++)
          SourceChapter(
            '第${['一', '二', '三', '四', '五'][i]}章',
            Uri.parse('https://a.test/chapter/$i'),
          ),
      ],
    );
    final entry = (await shelf.find(
      'https://a.test',
      'https://a.test/book/1',
    ))!;
    await shelf.saveProgress(
      entry.id,
      chapterKey: 'https://a.test/chapter/2',
      chapterIndex: 2,
      textOffset: 42,
    );
    return (await shelf.find('https://a.test', 'https://a.test/book/1'))!;
  }

  /// Opens the switch-source page on [entry] through a pushed route, so a
  /// pick's `pop(true)` has somewhere to go.
  Future<void> pumpSwitchEntry(
    WidgetTester tester,
    ShelfEntry entry, {
    void Function(bool)? onPopped,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () async {
              final switched = await Navigator.of(context).push<bool>(
                MaterialPageRoute(
                  builder: (_) => PreciseSearchPage(
                    service: shelf,
                    switchBook: entry,
                    openPipeline: open,
                  ),
                ),
              );
              onPopped?.call(switched == true);
            },
            child: const Text('打开换源'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开换源'));
    await tester.pumpAndSettle();
  }

  Future<void> groupedSources({bool hits = true}) async {
    await store.putSourceJson({
      ...sourceA.source,
      'bookSourceGroup': '常用, 精品 ,常用',
    });
    await store.putSourceJson({
      ...disabledUsedStyle(sourceB),
      'bookSourceGroup': '精品,停用组',
    });
    await store.putSourceJson({...sourceC.source, 'bookSourceGroup': '备用'});
    if (hits) {
      sourceA.hits.add(candidate('https://a.test', '1', name, author));
      sourceC.hits.add(candidate('https://c.test', '1', name, author));
    }
  }

  // Fixed pumps allow using the real menu while a search is still in flight;
  // pumpAndSettle would wait forever on the walk's progress indicator.
  Future<void> chooseGroup(WidgetTester tester, String group) async {
    await tester.tap(find.byKey(const ValueKey('precise-source-group')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(ValueKey('precise-group-$group')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('分组：仅启用的成员可选，菜单排除停用组，切组持久化并跨入口重读', (tester) async {
    final entry = await shelvedBook();
    await groupedSources();
    await store.putSetting('searchGroup', '精品');
    await pumpSwitchEntry(tester, entry);

    expect(sourceA.searchCalls, 1);
    expect(sourceB.searchCalls, 0);
    expect(sourceC.searchCalls, 0);
    expect(
      find.byKey(const ValueKey('precise-source-https://a.test')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('precise-source-https://b.test')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('precise-source-https://c.test')),
      findsNothing,
    );
    await tester.tap(find.byKey(const ValueKey('precise-source-group')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('precise-group-停用组')), findsNothing);
    expect(find.byKey(const ValueKey('precise-group-常用')), findsOneWidget);
    final items = tester
        .widgetList<CheckedPopupMenuItem<String>>(
          find.byType(CheckedPopupMenuItem<String>),
        )
        .map((item) => item.value)
        .toList();
    expect(items, ['', '备用', '常用', '精品'], reason: '确定的 Dart 字符序，不冒充冻结 ICU 排序');
    await tester.tap(find.byKey(const ValueKey('precise-group-备用')));
    await tester.pumpAndSettle();

    expect(sourceA.searchCalls, 1);
    expect(sourceC.searchCalls, 1);
    expect(await store.setting('searchGroup'), '备用');
    expect(
      find.byKey(const ValueKey('precise-source-https://a.test')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey('precise-hit-https://a.test-https://a.test/book/1'),
      ),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey('precise-source-https://c.test')),
      findsOneWidget,
    );
    // Close the pushed switch route before opening the plain search entry;
    // swapping in a bare MaterialApp would strip its localization delegates
    // while Navigator still owns that route.
    await tapBack(tester);
    expect(find.byType(PreciseSearchPage), findsNothing);
    await pumpEntry(tester);
    expect(sourceC.searchCalls, 2, reason: '普通搜索入口共享空间分组设置');
    expect(sourceA.searchCalls, 1);
    expect(find.text('备用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final missingGroup in ['不存在', '停用组', '精']) {
    testWidgets('分组 $missingGroup 无启用成员：可见重置为全部并持久化，不弹空结果确认', (tester) async {
      await groupedSources();
      await store.putSetting('searchGroup', missingGroup);
      await pumpEntry(tester);
      expect(await store.setting('searchGroup'), '');
      expect(find.text('全部书源'), findsOneWidget);
      expect(sourceA.searchCalls, 1);
      expect(sourceC.searchCalls, 1);
      expect(sourceB.searchCalls, 0);
      expect(find.byType(AlertDialog), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final confirm in [false, true]) {
    testWidgets('分组有书源但无结果：${confirm ? '确认才搜索全部' : '取消保持分组且不重搜'}', (
      tester,
    ) async {
      final entry = await shelvedBook();
      await groupedSources(hits: false);
      sourceC.hits.add(candidate('https://c.test', '1', name, author));
      await store.putSetting('searchGroup', '精品');
      await pumpSwitchEntry(tester, entry);
      expect(find.text('精品分组搜索结果为空，是否切换到全部分组？'), findsOneWidget);
      expect(sourceA.searchCalls, 1);
      expect(sourceC.searchCalls, 0);
      await tester.tap(
        find.byKey(
          ValueKey(confirm ? 'precise-group-confirm' : 'precise-group-cancel'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      expect(sourceA.searchCalls, confirm ? 2 : 1);
      expect(sourceB.searchCalls, 0);
      expect(sourceC.searchCalls, confirm ? 1 : 0);
      expect(await store.setting('searchGroup'), confirm ? '' : '精品');
      expect(find.text(confirm ? '全部书源' : '精品'), findsOneWidget);
      expect((await store.bookById(entry.id))!.sourceRef, 'https://a.test');
      expect((await store.progressOf(entry.id))!.textOffset, 42);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('所有源停用时也重置已存分组，不搜索、不弹确认', (tester) async {
    await groupedSources();
    for (final fake in byRef.values) {
      await store.putSourceJson({
        ...fake.source,
        'enabled': false,
        'bookSourceGroup': '精品',
      });
    }
    await store.putSetting('searchGroup', '精品');
    await pumpEntry(tester);
    expect(await store.setting('searchGroup'), '');
    expect(find.text('全部书源'), findsOneWidget);
    expect(find.text('空间里没有启用的书源'), findsOneWidget);
    expect(byRef.values.every((fake) => fake.searchCalls == 0), isTrue);
    expect(find.byType(AlertDialog), findsNothing);
  });

  for (final rapid in [false, true]) {
    testWidgets('搜索中${rapid ? '快速连续' : ''}切组：旧任务取消排空后才搜最新组，过期结果不污染', (
      tester,
    ) async {
      final old = [sourceA, ...await moreSources(12)];
      for (final fake in old) {
        fake.gate = Completer<void>();
        await store.putSourceJson({...fake.source, 'bookSourceGroup': '旧组'});
      }
      sourceA.hits.add(candidate('https://a.test', '1', name, author));
      await store.putSourceJson({...sourceB.source, 'bookSourceGroup': '中组'});
      await store.putSourceJson({...sourceC.source, 'bookSourceGroup': '新组'});
      sourceB.hits.add(candidate('https://b.test', '1', name, author));
      sourceC.hits.add(candidate('https://c.test', '1', name, author));
      await store.putSetting('searchGroup', '旧组');
      final created = <ScriptedPipeline>[];
      await tester.pumpWidget(
        localizedApp(
          home: PreciseSearchPage(
            service: shelf,
            initialName: name,
            initialAuthor: author,
            openPipeline: (source) {
              final pipeline = ScriptedPipeline(
                byRef['${source['bookSourceUrl']}']!,
              );
              created.add(pipeline);
              return pipeline;
            },
          ),
        ),
      );
      for (
        var i = 0;
        i < 50 && created.length < PreciseSearch.defaultConcurrency;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      expect(created, hasLength(PreciseSearch.defaultConcurrency));
      await chooseGroup(tester, '中组');
      if (rapid) await chooseGroup(tester, '新组');
      expect(created.every((pipeline) => pipeline.cancelled), isTrue);
      expect(sourceB.searchCalls, 0, reason: '等待旧的在飞请求结束，不叠加新走查');
      expect(sourceC.searchCalls, 0);
      for (final fake in old) {
        fake.gate!.complete();
      }
      await tester.pumpAndSettle();
      expect(
        old.fold<int>(0, (count, fake) => count + fake.searchCalls),
        PreciseSearch.defaultConcurrency,
        reason: '取消后旧组队列没有继续启动',
      );
      expect(created, hasLength(PreciseSearch.defaultConcurrency + 1));
      expect(sourceB.searchCalls, rapid ? 0 : 1);
      expect(sourceC.searchCalls, rapid ? 1 : 0);
      expect(await store.setting('searchGroup'), rapid ? '新组' : '中组');
      expect(find.byType(AlertDialog), findsNothing, reason: '过期走查不能弹空结果提示');
      expect(
        find.byKey(
          const ValueKey('precise-hit-https://a.test-https://a.test/book/1'),
        ),
        findsNothing,
      );
      expect(find.text('候选 1 本，其中精确匹配 1 本'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('切组等待旧请求时销毁页面，不再启动新组或弹出确认', (tester) async {
    await groupedSources(hits: false);
    sourceA.gate = Completer<void>();
    await store.putSetting('searchGroup', '精品');
    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(
          service: shelf,
          initialName: name,
          initialAuthor: author,
          openPipeline: open,
        ),
      ),
    );
    for (var i = 0; i < 50 && sourceA.searchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(sourceA.searchCalls, 1);
    await chooseGroup(tester, '备用');
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    sourceA.gate!.complete();
    await tester.pumpAndSettle();
    expect(sourceC.searchCalls, 0);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分组内数百筛选项保持惰性，滚动后的取消选择不丢失', (tester) async {
    final more = await moreSources(300);
    for (var i = 0; i < more.length; i++) {
      await store.putSourceJson({
        ...more[i].source,
        'bookSourceGroup': '规模',
        'customOrder': i,
      });
    }
    await store.putSetting('searchGroup', '规模');
    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(service: shelf, openPipeline: open),
      ),
    );
    await tester.pumpAndSettle();
    final first = find.byKey(const ValueKey('precise-source-https://s0.test'));
    final last = find.byKey(const ValueKey('precise-source-https://s299.test'));
    expect(find.byType(FilterChip).evaluate().length, lessThan(40));
    expect(last, findsNothing);
    await tester.tap(first);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      last,
      600,
      maxScrolls: 60,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilterChip>(last).selected, isTrue);
    await tester.tap(last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      first,
      -600,
      maxScrolls: 60,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.widget<FilterChip>(first).selected, isFalse);
    expect(find.byType(FilterChip).evaluate().length, lessThan(60));
    expect(
      find.byKey(const ValueKey('precise-source-https://a.test')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('手动换源只列出并搜索启用源，保留冻结 allEnabledPart 的类型范围', (tester) async {
    final entry = await shelvedBook();
    await store.putSourceJson(disabledUsedStyle(sourceB));
    // allEnabledPart has no bookSourceType predicate. This pins eligibility,
    // not support for reading a non-text source (the real pipeline owns that).
    await store.putSourceJson({...sourceC.source, 'bookSourceType': 1});
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceC.hits.add(candidate('https://c.test', '1', name, author));

    await pumpSwitchEntry(tester, entry);

    expect(sourceA.searchCalls, 1);
    expect(sourceB.searchCalls, 0);
    expect(sourceC.searchCalls, 1);
    expect(
      find.byKey(const ValueKey('precise-source-https://b.test')),
      findsNothing,
    );
    expect(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
      findsNothing,
    );
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect((await store.sourceByUrl('https://b.test'))!.enabled, isFalse);
    expect(await shelf.sources(), hasLength(3));
    expect((await store.bookById(entry.id))!.sourceRef, 'https://a.test');
    expect((await store.progressOf(entry.id))!.textOffset, 42);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源列表：一个书源出错或没有精确命中，后面的候选照常按书源顺序入列', (tester) async {
    // The rows now carry the frozen card's fields (#115), so both of them need a
    // taller surface than the default to be built at once: the list is lazy
    // (#86), and the position comparison below needs both rows in the tree.
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final entry = await shelvedBook();
    sourceA.failure = StateError('页面读取失败');
    sourceB.hits.add(candidate('https://b.test', '1', name, '别人的作者'));
    sourceC.hits.add(candidate('https://c.test', '1', name, author));

    await pumpSwitchEntry(tester, entry);

    // The failing source is reported on its own line and does not stop the
    // others: 乙源's name-match and 丙源's exact hit are both candidates.
    expect(find.textContaining('甲源 出错：'), findsOneWidget);
    expect(find.textContaining('别人的作者'), findsOneWidget);
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    // The list keeps the source order: 乙源's card sits above 丙源's.
    final b = find.byKey(
      const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
    );
    final c = find.byKey(
      const ValueKey('precise-hit-https://c.test-https://c.test/book/1'),
    );
    expect(tester.getTopLeft(b).dy, lessThan(tester.getTopLeft(c).dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源列表：没有候选时给出冻结的“没有搜索到”，书一行不动', (tester) async {
    final entry = await shelvedBook();
    sourceA.hits.add(candidate('https://a.test', '9', '另一本书', author));
    sourceB.hits.add(candidate('https://b.test', '2', '另一本书', '别人的作者'));

    await pumpSwitchEntry(tester, entry);

    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '没有搜索到<$name>$author',
    );
    // Nothing was written: the book still resolves 甲源, with its chapters and
    // its position.
    expect((await store.bookById(entry.id))!.sourceRef, 'https://a.test');
    expect(await store.chaptersOf(entry.id), hasLength(5));
    expect((await store.progressOf(entry.id))!.textOffset, 42);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源：新目录顺序变了，进度按冻结的映射落到同一章', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    await store.putSourceJson({...sourceB.source, 'bookSourceGroup': '精品'});
    await store.putSetting('searchGroup', '精品');
    // 乙源 prepends a 楔子, so the old 第三章 is at index 3 — only the frozen
    // name-and-number mapping finds it; carrying the old index would land on
    // 第二章.
    sourceB.titles.addAll(const ['楔子', '第一章', '第二章', '第三章', '第四章']);

    var popped = false;
    await pumpSwitchEntry(tester, entry, onPopped: (value) => popped = value);
    await tester.tap(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
    );
    await tester.pumpAndSettle();

    expect(popped, isTrue);
    final progress = (await store.progressOf(entry.id))!;
    expect(progress.chapterIndex, 3, reason: '第三章落在新目录的下标 3');
    expect(progress.chapterKey, 'https://b.test/chapter/3');
    expect(progress.textOffset, 42, reason: '冻结的 durChapterPos 原样带过去');
    expect((await shelf.onlineShelf()).single.chapterName, '第三章');
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源列表按搜索命中收录候选：正文取不到的候选也入列并被选中换源', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章']);
    sourceB.contentFailure = StateError('正文分页读取失败');

    var popped = false;
    await pumpSwitchEntry(tester, entry, onPopped: (value) => popped = value);
    await tester.tap(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
    );
    await tester.pumpAndSettle();

    // The list admits a search hit the way the frozen dialog does — it makes no
    // content request at all — so a source whose content stage would fail is
    // still a candidate, and the switch writes it.
    expect(sourceB.contentCalls, 0, reason: '列表流程不取正文');
    expect(popped, isTrue);
    expect((await store.bookById(entry.id))!.sourceRef, 'https://b.test');
    expect(tester.takeException(), isNull);
  });

  /// Scrolls the candidate list until the row for [url] on [sourceUrl] is
  /// built: the list is lazy (#86), so a row below the fold is not in the tree
  /// yet.
  Future<void> showHit(WidgetTester tester, String sourceUrl, String url) =>
      tester.scrollUntilVisible(
        find.byKey(ValueKey('precise-hit-$sourceUrl-$url')),
        200,
        scrollable: find.byType(Scrollable).first,
      );

  testWidgets('候选行给出冻结的最新章节，空值答冻结的无最新章节信息', (tester) async {
    // `SearchBook.getDisplayLastChapterTitle`: the field as the search page
    // answered it, or 无最新章节信息 when it is empty.
    sourceA.hits.add(
      HtmlBook(
        url: Uri.parse('https://a.test/book/1'),
        title: name,
        author: '别人的作者',
        lastChapter: '第 1300 章 大战',
      ),
    );
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);

    await showHit(tester, 'https://a.test', 'https://a.test/book/1');
    expect(find.text('第 1300 章 大战'), findsOneWidget);
    await showHit(tester, 'https://b.test', 'https://b.test/book/1');
    expect(find.text('无最新章节信息'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('换源：当前书源的那一行带冻结的逐行勾选（oldBookUrl == bookUrl）', (tester) async {
    final entry = await shelvedBook();
    sourceA.hits.add(candidate('https://a.test', '1', name, author));
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpSwitchEntry(tester, entry);

    expect(
      find.byKey(
        const ValueKey(
          'precise-current-source-https://a.test-https://a.test/book/1',
        ),
      ),
      findsOneWidget,
      reason: '甲源正是这本书当前的来源',
    );
    expect(
      find.byKey(
        const ValueKey(
          'precise-current-source-https://b.test-https://b.test/book/1',
        ),
      ),
      findsNothing,
      reason: '乙源不是当前来源',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载字数默认关闭：候选行没有字数与响应时间行，候选不多取一次正文', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章']);

    await pumpSwitchEntry(tester, entry);

    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('precise-load-word-count')),
          )
          .value,
      isFalse,
      reason: '冻结的 AppConfig.changeSourceLoadWordCount 默认关着',
    );
    expect(sourceB.detailsCalls, 0, reason: '关着时读搜索页答复的字段，不读详情');
    expect(sourceB.contentCalls, 0, reason: '关着时不取正文');
    expect(find.textContaining('响应时间：'), findsNothing);
    expect(find.textContaining('字数：'), findsNothing);
    // 最新章节的空值占位仍在
    expect(find.text('无最新章节信息'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载字数打开：候选行给出冻结的字数行与响应时间，每个候选取一次正文', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章', '第四章']);

    await pumpSwitchEntry(tester, entry);
    await tester.tap(find.byKey(const ValueKey('precise-load-word-count')));
    await tester.pumpAndSettle();

    await showHit(tester, 'https://b.test', 'https://b.test/book/1');
    // 进度在第三章，冻结的 BookHelp.getDurChapter 落回新目录的下标 2，正文是
    // 脚本给出的“第三章的正文”,6 个码元。
    expect(find.text('[3] 第三章\n字数：6'), findsOneWidget);
    expect(find.textContaining('响应时间：'), findsOneWidget);
    expect(sourceB.detailsCalls, 1, reason: '每个候选读一次自己的目录');
    expect(sourceB.contentCalls, 1, reason: '每个候选取一次正文');
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载字数开关跨页面重开仍然有效', (tester) async {
    sourceA.hits.add(candidate('https://a.test', '1', name, author));
    sourceA.titles.addAll(const ['第一章', '第二章', '第三章']);

    await pumpEntry(tester);
    await tester.tap(find.byKey(const ValueKey('precise-load-word-count')));
    await tester.pumpAndSettle();
    expect(await store.setting('changeSourceLoadWordCount'), '1');
    expect(sourceA.contentCalls, 1);
    // 没有换源的入口就没有阅读进度，冻结取目录的最后一章（chapters.lastIndex）
    await showHit(tester, 'https://a.test', 'https://a.test/book/1');
    expect(find.text('[3] 第三章\n字数：6'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    sourceA.detailsCalls = 0;
    await pumpEntry(tester);

    expect(
      tester
          .widget<Checkbox>(
            find.byKey(const ValueKey('precise-load-word-count')),
          )
          .value,
      isTrue,
    );
    // 重开的页面已经把开关读回来了，按冻结的链自己补上字数
    expect(sourceA.detailsCalls, 1);
    expect(sourceA.contentCalls, 2);
    await showHit(tester, 'https://a.test', 'https://a.test/book/1');
    expect(find.text('[3] 第三章\n字数：6'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载字数关掉后可选行隐藏，也不再多发请求', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章']);

    await pumpSwitchEntry(tester, entry);
    await tester.tap(find.byKey(const ValueKey('precise-load-word-count')));
    await tester.pumpAndSettle();
    expect(sourceB.contentCalls, 1);

    await tester.tap(find.byKey(const ValueKey('precise-load-word-count')));
    await tester.pumpAndSettle();

    expect(await store.setting('changeSourceLoadWordCount'), '');
    expect(sourceB.contentCalls, 1, reason: '关掉不再发请求');
    expect(find.textContaining('响应时间：'), findsNothing);
    expect(find.textContaining('字数：'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('取正文失败时仍给冻结的获取字数失败行', (tester) async {
    final entry = await shelvedBook();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceB.titles.addAll(const ['第一章', '第二章', '第三章']);
    sourceB.contentFailure = StateError('正文分页读取失败');

    await pumpSwitchEntry(tester, entry);
    await tester.tap(find.byKey(const ValueKey('precise-load-word-count')));
    await tester.pumpAndSettle();

    await showHit(tester, 'https://b.test', 'https://b.test/book/1');
    expect(find.textContaining('[3] 第三章\n获取字数失败：'), findsOneWidget);
    expect(find.textContaining('响应时间：'), findsOneWidget);
    // 候选仍在列表里：字数取不到不改变收录
    expect(
      find.byKey(
        const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  test('第一个精确命中的书源之后的书源不再被搜索', () async {
    sourceA.hits.add(candidate('https://a.test', '1', name, author));
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: open,
    );
    final hit = await search.firstExact([
      for (final fake in byRef.values)
        ImportedBookSource(
          id: '${fake.source['bookSourceUrl']}',
          data: fake.source,
        ),
    ]);

    expect(hit!.sourceRef, 'https://a.test');
    expect(sourceA.searchCalls, 1);
    expect(sourceB.searchCalls, 0, reason: '冻结的 preciseSearch 在第一个命中处返回');
    expect(sourceC.searchCalls, 0);
  });

  test('没有任何书源精确命中时 preciseSearch 给出空结果', () async {
    sourceA.hits.add(candidate('https://a.test', '1', name, '别人的作者'));

    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: open,
    );
    final hit = await search.firstExact([
      ImportedBookSource(
        id: '${sourceA.source['bookSourceUrl']}',
        data: sourceA.source,
      ),
    ]);

    expect(hit, isNull);
  });

  /// The walk's own rows (#108) drive timed scripted pipelines: this file's
  /// transport is a scripted pipeline, because the native rule adapter cannot
  /// load in a widget test and a real loopback site cannot be searched without
  /// it. What the timings pin is the walk's own shape, not a site's speed.
  List<FakeSource> timedSources(List<Duration> delays) => [
    for (var i = 0; i < delays.length; i++)
      FakeSource({
        'bookSourceUrl': 'https://t$i.test',
        'bookSourceName': '源$i',
      }, delay: delays[i]),
  ];

  BookSourcePipeline Function(Map<String, dynamic>) timedOpen(
    List<FakeSource> fakes,
    WalkWatch watch,
  ) {
    final byUrl = {
      for (final fake in fakes) '${fake.source['bookSourceUrl']}': fake,
    };
    return (source) =>
        TimedPipeline(byUrl['${source['bookSourceUrl']}']!, watch);
  }

  test('并发上界：9 个书源、最慢的排在最前，耗时由并发而不是 N×最慢决定', () async {
    final watch = WalkWatch();
    // Slowest first, so a sequential walk would take their sum — 900 ms — while
    // three at a time take three rounds of it.
    final fakes = timedSources([
      for (var i = 0; i < 9; i++) Duration(milliseconds: 120 - i * 5),
    ]);
    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: timedOpen(fakes, watch),
      // The frozen's own bound, made small so the row walks nine sources.
      concurrency: 3,
    );

    final arrived = <PreciseSearchOutcome>[];
    var startedAtFirstAnswer = -1;
    final stopwatch = Stopwatch()..start();
    await for (final outcome in search.searchAll([
      for (final fake in fakes) imported(fake),
    ])) {
      if (arrived.isEmpty) startedAtFirstAnswer = watch.started;
      arrived.add(outcome);
    }
    stopwatch.stop();

    expect(arrived, hasLength(9));
    expect(watch.maxInFlight, 3, reason: '一次只有三个书源在飞');
    expect(
      startedAtFirstAnswer,
      lessThan(9),
      reason: '第一条结果在走查结束之前就到了：还有书源没有开始',
    );
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 600)),
      reason: '串行会是 900ms（九个书源耗时之和）',
    );
  });

  test('取消订阅：不再问后面的书源，且等三个在飞的书源结束后才完成', () async {
    final watch = WalkWatch();
    final fakes = timedSources([
      for (var i = 0; i < 6; i++) const Duration(milliseconds: 150),
    ]);
    final byUrl = {
      for (final fake in fakes) '${fake.source['bookSourceUrl']}': fake,
    };
    final created = <TimedPipeline>[];
    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: (source) {
        final pipeline = TimedPipeline(
          byUrl['${source['bookSourceUrl']}']!,
          watch,
        );
        created.add(pipeline);
        return pipeline;
      },
      concurrency: 3,
    );

    final received = <PreciseSearchOutcome>[];
    final answers = search
        .searchAll([for (final fake in fakes) imported(fake)])
        .listen(received.add);
    for (var i = 0; i < 100 && watch.started < 3; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(watch.started, 3, reason: '一次三个书源在飞');
    expect(watch.inFlight, 3);

    await answers.cancel();

    expect(watch.started, 3, reason: '取消后不再问后面的书源');
    expect(watch.inFlight, 0);
    expect(watch.completed, 3, reason: '取消要等在飞的书源结束，调用方拿到它时它们已经结束');
    expect(received, isEmpty);
    expect(created, hasLength(3));
    expect(
      created.every((pipeline) => pipeline.cancelled),
      isTrue,
      reason: '在飞的分析被取消',
    );
    expect(
      [for (final fake in fakes.take(3)) fake.cancelledDuringSearch],
      everyElement(isTrue),
      reason: '取消时这三个书源的搜索还在飞，走查已经把它们停了',
    );
  });

  test('一个书源超过限时：记为失败，请求停下，位置让给下一个书源', () async {
    final held = Completer<void>();
    final hanging = FakeSource({
      'bookSourceUrl': 'https://hang.test',
      'bookSourceName': '挂源',
    })..gate = held;
    final answering = FakeSource(
      {'bookSourceUrl': 'https://ok.test', 'bookSourceName': '好源'},
      hits: [candidate('https://ok.test', '1', name, author)],
    );
    final watch = WalkWatch();
    final fakes = [hanging, answering];
    final byUrl = {
      for (final fake in fakes) '${fake.source['bookSourceUrl']}': fake,
    };
    TimedPipeline? hangingPipeline;
    final search = PreciseSearch(
      name: name,
      author: author,
      openPipeline: (source) {
        final pipeline = TimedPipeline(
          byUrl['${source['bookSourceUrl']}']!,
          watch,
        );
        if ('${source['bookSourceUrl']}' == 'https://hang.test') {
          hangingPipeline = pipeline;
        }
        return pipeline;
      },
      concurrency: 1,
      // The frozen's own per-source budget, made short enough to wait for: the
      // dialog bounds one source at 60000L (`ChangeBookSourceViewModel.kt:237-243`).
      sourceTimeout: const Duration(milliseconds: 50),
    );

    final outcomes = <PreciseSearchOutcome>[];
    bool? stoppedWhenTimedOut;
    final stopwatch = Stopwatch()..start();
    final answers = search
        .searchAll([for (final fake in fakes) imported(fake)])
        .listen((outcome) {
          outcomes.add(outcome);
          if (outcome.failure != null) {
            // Read while the walk is still running: 好源 has not answered yet,
            // so nothing has closed the run's pipelines at this point.
            stoppedWhenTimedOut = hangingPipeline!.cancelled;
          }
        });
    await answers.asFuture<void>();
    stopwatch.stop();

    expect(outcomes, hasLength(2));
    expect(outcomes.first.sourceRef, 'https://hang.test');
    expect(outcomes.first.failure, contains('书源搜索超时'));
    expect(outcomes.first.hits, isEmpty);
    expect(outcomes.last.sourceRef, 'https://ok.test', reason: '限时后位置让给下一个书源');
    expect(outcomes.last.hits.single.book.title, name);
    expect(
      stoppedWhenTimedOut,
      isTrue,
      reason: '限时一到这本书源的请求就停了（冻结的 withTimeout 一样取消调用）',
    );
    expect(stopwatch.elapsed, greaterThan(const Duration(milliseconds: 50)));
    expect(
      stopwatch.elapsed,
      lessThan(const Duration(milliseconds: 1000)),
      reason: '一个挂住的书源不把走查拖在它身上',
    );

    // The abandoned search settles after the walk is over and must not touch a
    // closed stream.
    held.complete();
    await Future<void>.delayed(Duration.zero);
    expect(outcomes, hasLength(2));
  });

  testWidgets('走查还在进行时命中就上屏，进度行说出已经走过多少书源', (tester) async {
    // All three sources are held, so this row can look at the page while the
    // walk is still running: the bound must be visible before anyone answers,
    // the candidates must appear as their sources answer, and the run must
    // still be running when they do.
    sourceA.gate = Completer<void>();
    sourceB.gate = Completer<void>();
    sourceC.gate = Completer<void>();
    sourceB.hits.add(candidate('https://b.test', '1', name, author));
    sourceC.hits.add(candidate('https://c.test', '1', name, author));

    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(
          service: shelf,
          initialName: name,
          initialAuthor: author,
          openPipeline: open,
        ),
      ),
    );
    for (var i = 0; i < 40 && sourceC.searchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    await tester.pump();
    expect(sourceC.searchCalls, 1, reason: '三个书源一起开始');
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '正在搜索 3 个书源',
      reason: '还没人回答时也看得见这一次走查多少书源',
    );

    // 乙源 and 丙源 answer while 甲源 stays held.
    sourceB.gate!.complete();
    sourceC.gate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(
      find.textContaining('· 精确匹配'),
      findsNWidgets(2),
      reason: '走查还在跑，命中已经在页面上',
    );
    expect(
      find.byType(CircularProgressIndicator),
      findsOneWidget,
      reason: '走查还没结束',
    );
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '结果 2, 当前进度 2 / 3: 丙源',
      reason: '冻结换源对话框自己的进度行',
    );

    sourceA.gate!.complete();
    await tester.pumpAndSettle();
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '候选 2 本，其中精确匹配 2 本',
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('先回答的书源不插队：候选还是按书源顺序列', (tester) async {
    // 甲源 answers last, 乙源 first — the walk streams in completion order, and
    // the list must still be the sources' own order.
    sourceA.gate = Completer<void>();
    sourceA.hits.add(candidate('https://a.test', '1', name, author));
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await tester.pumpWidget(
      localizedApp(
        home: PreciseSearchPage(
          service: shelf,
          initialName: name,
          initialAuthor: author,
          openPipeline: open,
        ),
      ),
    );
    for (var i = 0; i < 40 && sourceB.searchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    final fromA = find.byKey(
      const ValueKey('precise-hit-https://a.test-https://a.test/book/1'),
    );
    final fromB = find.byKey(
      const ValueKey('precise-hit-https://b.test-https://b.test/book/1'),
    );
    expect(fromB, findsOneWidget, reason: '乙源先回答，先上屏');
    expect(fromA, findsNothing);

    sourceA.gate!.complete();
    await tester.pumpAndSettle();

    expect(fromA, findsOneWidget);
    expect(
      tester.getTopLeft(fromA).dy,
      lessThan(tester.getTopLeft(fromB).dy),
      reason: '甲源后回答，但排在乙源前面',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('几百本候选只构建可见的几行', (tester) async {
    // #86's lesson: a run over thousands of sources can admit hundreds of
    // candidates, and building every one of them on every answer is what makes
    // such a page unusable. 300 rows make "the rows on screen" and "all of
    // them" unmistakable.
    for (var i = 0; i < 300; i++) {
      sourceA.hits.add(candidate('https://a.test', '$i', name, '别人的作者'));
    }

    await pumpEntry(tester);

    expect(find.textContaining('候选 300 本'), findsOneWidget);
    expect(
      find.byType(Card).evaluate().length,
      lessThan(40),
      reason: '300 行里只有可见的几十行被构建',
    );
    final last = find.byKey(
      const ValueKey('precise-hit-https://a.test-https://a.test/book/299'),
    );
    expect(last, findsNothing, reason: '视口之外的行根本没有建');

    await tester.scrollUntilVisible(
      last,
      600,
      maxScrolls: 60,
      scrollable: find.byType(Scrollable).first,
    );
    expect(last, findsOneWidget);
    expect(
      find.byType(Card).evaluate().length,
      lessThan(40),
      reason: '滚到末尾也一样',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('几百个书源只构建可见的书源筛选项', (tester) async {
    // Source chips must have the same viewport-backed construction as the
    // candidate rows: the last of 300 extra sources is not built at first.
    await moreSources(300);

    await tester.pumpWidget(
      localizedApp(home: PreciseSearchPage(service: shelf)),
    );
    await tester.pumpAndSettle();

    expect(
      find.byType(FilterChip).evaluate().length,
      lessThan(40),
      reason: '303 个书源里只有可见的几十个筛选项被构建',
    );
    final last = find.byKey(const ValueKey('precise-source-https://s299.test'));
    expect(last, findsNothing, reason: '视口之外的书源筛选项根本没有建');

    await tester.scrollUntilVisible(
      last,
      600,
      maxScrolls: 60,
      scrollable: find.byType(Scrollable).first,
    );
    expect(last, findsOneWidget);
    expect(
      find.byType(FilterChip).evaluate().length,
      lessThan(60),
      reason: '滚到末尾也只构建视口和缓存附近的书源筛选项',
    );
    expect(tester.takeException(), isNull);
  });

  group('formatSearchBookName / formatSearchBookAuthor', () {
    test('去掉搜索页写在书名里的作者与作者字段的前后缀', () {
      expect(formatSearchBookName('凡人修仙传 作者 忘语'), '凡人修仙传');
      expect(formatSearchBookName('凡人修仙传 忘语 著'), '凡人修仙传');
      expect(formatSearchBookName(' 凡人修仙传 '), '凡人修仙传');
      expect(formatSearchBookAuthor('作者：忘语'), '忘语');
      expect(formatSearchBookAuthor('忘语 著'), '忘语');
      expect(formatSearchBookAuthor('忘语著'), '忘语著', reason: '冻结的规则要求空格');
    });
  });
}
