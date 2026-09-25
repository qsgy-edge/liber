import 'dart:async';

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
  }) : hits = hits ?? <HtmlBook>[],
       titles = titles ?? <String>[];

  final Map<String, dynamic> source;
  final List<HtmlBook> hits;
  Object? failure;
  final List<String> titles;
  Object? contentFailure;
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
    expect(find.textContaining('别人的作者'), findsNWidgets(2));
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect(
      tester.widget<Text>(find.byKey(const ValueKey('precise-status'))).data,
      '候选 3 本，其中精确匹配 1 本',
    );
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

  testWidgets('换源列表：默认只搜启用的书源；停用的书源可被显式选中（与冻结的差异）', (tester) async {
    // The frozen dialog searches only `enabled = 1` (`allEnabledPart`). This
    // page lists a chip for every source and pre-selects the enabled ones, so a
    // disabled source is skipped by default but can be searched once selected.
    await store.putSourceJson({...sourceB.source, 'enabled': false});
    sourceB.hits.add(candidate('https://b.test', '1', name, author));

    await pumpEntry(tester);

    expect(sourceB.searchCalls, 0, reason: '停用的书源默认不搜索');
    expect(find.textContaining('· 精确匹配'), findsNothing);

    await tester.tap(
      find.byKey(const ValueKey('precise-source-https://b.test')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('precise-search')));
    await tester.pumpAndSettle();

    expect(sourceB.searchCalls, 1, reason: '显式选中后停用的书源也被搜索');
    expect(find.textContaining('· 精确匹配'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面销毁后不再搜索后面的书源，也不新建分析', (tester) async {
    // 甲源's answer is held open, so the page can be disposed while its
    // analysis is in flight — the window in which the run would otherwise walk
    // on to 乙源 and 丙源 under a State that no longer exists. The run's own
    // cancellation hook is what stops that walk: the sources after the disposed
    // one are not asked at all, so no pipeline is opened for them and no
    // request is issued on their behalf.
    sourceA.gate = Completer<void>();
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
    for (var i = 0; i < 20 && sourceA.searchCalls == 0; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(sourceA.searchCalls, 1);
    expect(created, hasLength(1));

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    expect(created.single.cancelled, isTrue, reason: '在飞的分析随页面销毁取消');

    sourceA.gate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    expect(sourceB.searchCalls, 0, reason: '销毁后不得再为后面的书源发起搜索');
    expect(sourceC.searchCalls, 0);
    expect(created, hasLength(1), reason: '销毁后不得再新建 pipeline');
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

  testWidgets('换源列表：一个书源出错或没有精确命中，后面的候选照常按书源顺序入列', (tester) async {
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
