import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/auto_change_source.dart';
import 'package:liber/settings/auto_change_source_page.dart';
import 'package:liber/source/auto_change_source.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// One source's scripted answers: what its search returns, the table of
/// contents its details stage answers with, whether its content stage answers,
/// and how often each stage ran.
class FakeSource {
  FakeSource(
    this.source, {
    List<HtmlBook>? hits,
    List<String>? chapters,
    this.searchFailure,
    this.detailsFailure,
    this.contentFailure,
  }) : hits = hits ?? <HtmlBook>[],
       chapters = chapters ?? <String>[];

  final Map<String, dynamic> source;
  final List<HtmlBook> hits;
  final List<String> chapters;
  Object? searchFailure;
  Object? detailsFailure;
  Object? contentFailure;

  int searchCalls = 0;
  int detailsCalls = 0;
  int contentCalls = 0;

  /// The chapters whose content was requested, and the `nextChapterUrl` each
  /// request carried.
  final List<String> requestedChapters = <String>[];
  final List<String?> nextChapterUrls = <String?>[];

  String get ref => '${source['bookSourceUrl']}';
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
    if (fake.searchFailure != null) throw fake.searchFailure!;
    return fake.hits;
  }

  @override
  Future<(HtmlBook, List<SourceChapter>)> details(HtmlBook hit) async {
    fake.detailsCalls++;
    if (fake.detailsFailure != null) throw fake.detailsFailure!;
    return (
      hit,
      [
        for (var i = 0; i < fake.chapters.length; i++)
          SourceChapter(fake.chapters[i], Uri.parse('${fake.ref}/chapter/$i')),
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
    fake.requestedChapters.add(chapter.name);
    fake.nextChapterUrls.add(nextChapterUrl);
    if (fake.contentFailure != null) throw fake.contentFailure!;
    return HtmlChapterBody('${chapter.name}的正文', 1);
  }
}

/// The frozen reader's automatic switch-source (#69), driven through scripted
/// pipelines.
///
/// The real adapters cannot run in this test (the native rule adapter is not
/// loaded), so what these drive are the flow's own decisions: whether the
/// setting is read before anything is asked, which sources are candidates, what
/// a candidate has to prove, where the walk stops, and what the switch writes.
/// The switch's own store step and its position mapping are pinned in
/// `switch_source_test.dart` and `chapter_position_test.dart`.
void main() {
  late SpaceStore store;
  late ShelfService shelf;

  const name = '凡人修仙传';
  const author = '忘语';

  final sourceA = <String, dynamic>{
    'bookSourceUrl': 'https://a.test',
    'bookSourceName': '甲源',
  };
  final sourceB = <String, dynamic>{
    'bookSourceUrl': 'https://b.test',
    'bookSourceName': '乙源',
  };
  final sourceC = <String, dynamic>{
    'bookSourceUrl': 'https://c.test',
    'bookSourceName': '丙源',
  };

  HtmlBook hitFor(String ref, {String title = name, String by = author}) =>
      HtmlBook(url: Uri.parse('$ref/book/1'), title: title, author: by);

  late FakeSource a;
  late FakeSource b;
  late FakeSource c;
  late Map<String, FakeSource> byRef;

  BookSourcePipeline open(Map<String, dynamic> source) =>
      ScriptedPipeline(byRef['${source['bookSourceUrl']}']!);

  setUp(() async {
    // A widget test cannot await a background-isolate database
    // (`SpaceDatabase.file`), so this drives an in-memory store in the test's
    // own isolate, the way `precise_search_test.dart` does.
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    a = FakeSource(sourceA);
    b = FakeSource(sourceB);
    c = FakeSource(sourceC);
    byRef = {
      'https://a.test': a,
      'https://b.test': b,
      'https://c.test': c,
    };
    for (final fake in byRef.values) {
      await store.putSourceJson(fake.source);
    }
  });

  tearDown(() => store.close());

  /// The shelf book whose source is gone: five chapters from 甲源, read at the
  /// third one, 42 characters in. Its source row is deleted afterwards, which is
  /// the state #53 leaves and the state the automatic switch starts from.
  Future<ShelfEntry> lostBook() async {
    await shelf.add(sourceA, hitFor('https://a.test'), [
      for (var i = 0; i < 5; i++)
        SourceChapter(
          '第${['一', '二', '三', '四', '五'][i]}章',
          Uri.parse('https://a.test/chapter/$i'),
        ),
    ]);
    final entry = (await shelf.find('https://a.test', 'https://a.test/book/1'))!;
    await shelf.saveProgress(
      entry.id,
      chapterKey: 'https://a.test/chapter/2',
      chapterIndex: 2,
      textOffset: 42,
    );
    await shelf.deleteSource('https://a.test');
    final lost = (await shelf.find('https://a.test', 'https://a.test/book/1'))!;
    expect(lost.sourceMissing, isTrue);
    return lost;
  }

  test('自动换源把失源的书换到第一个通过验证的候选，身份和进度都留下', () async {
    final lost = await lostBook();
    // 乙源 answers the exact name and author; its table of contents is not the
    // old one — a 楔子 is prepended — so only the frozen name-and-number mapping
    // can find 第三章, at index 3.
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['楔子', '第一章', '第二章', '第三章', '第四章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(result.ran, isTrue);
    final switched = result.switched!;
    expect(switched.id, lost.id, reason: 'D2：换源不重写书的身份');
    expect(switched.sourceRef, 'https://b.test');
    expect(switched.book.sourceBookUrl, 'https://b.test/book/1');
    expect(switched.title, name);
    expect(switched.chapters.map((chapter) => chapter.name), [
      '楔子',
      '第一章',
      '第二章',
      '第三章',
      '第四章',
    ]);
    expect(switched.chapterIndex, 3, reason: '第三章在新目录的下标 3');
    expect(switched.chapterKey, 'https://b.test/chapter/3');
    expect(switched.textOffset, 42, reason: '偏移原样带过去（冻结的 durChapterPos）');
    expect(switched.shelved, isTrue);
    final progress = (await store.progressOf(lost.id))!;
    expect(progress.chapterKey, 'https://b.test/chapter/3');
    expect(progress.chapterIndex, 3);
    expect(progress.textOffset, 42);
    expect((await shelf.onlineShelf()).length, 1, reason: '还是一行');
    expect(await store.setting(AutoChangeSourceSetting.key), isNull);
    // The frozen `take(1)`: the sources after the accepting one are not asked.
    expect(b.searchCalls, 1);
    expect(b.detailsCalls, 1);
    expect(b.contentCalls, 1);
    expect(c.searchCalls, 0);
  });

  test('搜索命中要不精确的书名与作者，近似命中不是候选', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test', by: '忘语著'));
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章', '第三章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(
      b.detailsCalls,
      0,
      reason: '作者只包含搜索词的命中不是 preciseSearchAwait 要的那一本',
    );
    expect(b.searchCalls, 1);
    expect(result.switched!.sourceRef, 'https://c.test');
  });

  test('同一页上第一处精确命中的那本就是候选', () async {
    final lost = await lostBook();
    b.hits.addAll([
      hitFor('https://b.test', by: '别人的笔名'),
      hitFor('https://b.test'),
      HtmlBook(url: Uri.parse('https://b.test/book/2'), title: name, author: author),
    ]);
    b.chapters.addAll(const ['第一章', '第二章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    // 甲源's first item is a near hit and its second is the book the frozen
    // `preciseSearchAwait` filters for: the switched book is that one, not the
    // same-name book after it on the same page.
    expect(result.switched!.book.sourceBookUrl, 'https://b.test/book/1');
  });

  test('书源顺序是 customOrder 再按 URL，两个都合格时先问 customOrder 小的', () async {
    final lost = await lostBook();
    // 乙源's URL sorts before 丙源's while its `customOrder` is larger: the store's
    // order (`SpaceStore.allSources`) decides, so 丙源 is asked first and wins.
    await store.putSourceJson({...sourceB, 'customOrder': 5});
    await store.putSourceJson({...sourceC, 'customOrder': 1});
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['第一章', '第二章']);
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(c.searchCalls, 1);
    expect(b.searchCalls, 0, reason: 'customOrder 小的先问，问到了就不再问后面的');
    expect(result.switched!.sourceRef, 'https://c.test');
  });

  test('调用方取消后不再问后面的书源，也不写换源', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['第一章', '第二章']);
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章']);
    // The owner goes away while the first source's analysis is in flight — the
    // window `isCancelled` exists for.
    var cancelled = false;

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: (source) {
        if ('${source['bookSourceUrl']}' == 'https://b.test') cancelled = true;
        return open(source);
      },
      isCancelled: () => cancelled,
    );

    expect(b.searchCalls, 1);
    expect(c.searchCalls, 0, reason: '取消停在下一处检查，不搜后面的书源');
    expect(result.switched, isNull);
    expect(result.ran, isFalse, reason: '被取消的运行没有结果要报');
    expect((await store.bookById(lost.id))!.sourceRef, 'https://a.test');
    expect((await store.chaptersOf(lost.id)).length, 5);
  });

  test('正文取的是候选目录的第一章，冻结传的下一章 URL 就是这一章', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['第一章', '第二章', '第三章']);

    await autoChangeSource(service: shelf, book: lost, openPipeline: open);

    expect(b.requestedChapters, ['第一章'], reason: '冻结取 durChapterIndex 0');
    expect(
      b.nextChapterUrls,
      ['https://b.test/chapter/0'],
      reason: 'toc.getOrElse(chapter.index)：第一章自己的 index 是 0，所以传的就是它自己',
    );
  });

  test('取不到目录或取不到正文的候选被拒绝，下一个候选接着试', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test'));
    // 乙源 answers the search and a details page whose table of contents is
    // empty — the frozen `getChapterListAwait` throws `TocEmptyException`.
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章']);
    c.contentFailure = StateError('正文分页读取失败');

    final noContent = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );
    expect(noContent.switched, isNull);
    expect(noContent.ran, isTrue);
    expect(b.detailsCalls, 1);
    expect(b.contentCalls, 0, reason: '目录为空就不取正文');
    expect(c.contentCalls, 1);

    // 丙源 gets its content back: the same walk now accepts it.
    c.contentFailure = null;
    final switched = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );
    expect(switched.switched!.sourceRef, 'https://c.test');
  });

  test('搜索出错的书源不阻断后面的书源', () async {
    final lost = await lostBook();
    b.searchFailure = StateError('页面读取失败');
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(b.searchCalls, 1);
    expect(result.switched!.sourceRef, 'https://c.test');
  });

  test('没有候选时 ran 为真、没有换源，书一行不动', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test', by: '别人'));
    c.hits.add(hitFor('https://c.test', title: '另一本书'));

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(result.switched, isNull);
    expect(result.ran, isTrue, reason: '调用方据此报冻结的“没有合适书源”');
    final still = (await store.bookById(lost.id))!;
    expect(still.sourceRef, 'https://a.test', reason: '书还指着那个已删除的书源');
    expect((await store.chaptersOf(lost.id)).length, 5);
    expect((await store.progressOf(lost.id))!.textOffset, 42);
  });

  test('开关关闭时不发起任何请求', () async {
    final lost = await lostBook();
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['第一章', '第二章']);
    await AutoChangeSourceSetting.putGlobal(store, enabled: false);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(result.switched, isNull);
    expect(result.ran, isFalse, reason: '冻结的 if (!AppConfig.autoChangeSource) return');
    expect(b.searchCalls, 0);
    expect(b.detailsCalls, 0);
    expect((await store.bookById(lost.id))!.sourceRef, 'https://a.test');
  });

  test('停用的书源与非文本书源不作为候选', () async {
    final lost = await lostBook();
    await store.putSourceJson({...sourceB, 'enabled': false});
    await store.putSourceJson({...sourceC, 'bookSourceType': 2});
    byRef = {
      'https://a.test': a,
      'https://b.test': FakeSource({...sourceB, 'enabled': false}),
      'https://c.test': FakeSource({...sourceC, 'bookSourceType': 2}),
    };
    byRef['https://b.test']!.hits.add(hitFor('https://b.test'));
    byRef['https://b.test']!.chapters.addAll(const ['第一章']);
    byRef['https://c.test']!.hits.add(hitFor('https://c.test'));
    byRef['https://c.test']!.chapters.addAll(const ['第一章']);

    final result = await autoChangeSource(
      service: shelf,
      book: lost,
      openPipeline: open,
    );

    expect(byRef['https://b.test']!.searchCalls, 0, reason: '停用的书源不搜索');
    expect(byRef['https://c.test']!.searchCalls, 0, reason: '非文本书源不搜索');
    expect(result.switched, isNull);
    expect(result.ran, isTrue);
  });

  test('候选这本书已在书架上时错误向上抛，不吞掉也不继续试', () async {
    final lost = await lostBook();
    // 乙源 already holds the same book as another shelf row: `switchSource`
    // refuses it, and the frozen's `changeTo` runs outside its per-source
    // swallow too (`take(1)` then the write).
    await shelf.add(sourceB, hitFor('https://b.test'), [
      SourceChapter('第一章', Uri.parse('https://b.test/chapter/0')),
    ]);
    b.hits.add(hitFor('https://b.test'));
    b.chapters.addAll(const ['第一章', '第二章']);
    c.hits.add(hitFor('https://c.test'));
    c.chapters.addAll(const ['第一章', '第二章']);

    await expectLater(
      () => autoChangeSource(service: shelf, book: lost, openPipeline: open),
      throwsA(isA<StateError>()),
    );

    expect(c.searchCalls, 0, reason: '换源写失败不是“这个书源不合格”，不再试下一个');
    expect((await store.bookById(lost.id))!.sourceRef, 'https://a.test');
    expect((await store.chaptersOf(lost.id)).length, 5);
  });

  group('AutoChangeSourceSetting', () {
    test('默认开启：没有行或行不是 putGlobal 写的 false 时都算开着', () {
      expect(AutoChangeSourceSetting.key, 'source.auto_change');
      expect(AutoChangeSourceSetting.fromStored(null), isTrue);
      expect(AutoChangeSourceSetting.fromStored('true'), isTrue);
      expect(AutoChangeSourceSetting.fromStored('1'), isTrue);
      expect(AutoChangeSourceSetting.fromStored('false'), isFalse);
    });

    test('写入的行按 putGlobal 的拼写读回来', () async {
      await AutoChangeSourceSetting.putGlobal(store, enabled: false);
      expect(await AutoChangeSourceSetting.resolve(store), isFalse);
      await AutoChangeSourceSetting.putGlobal(store, enabled: true);
      expect(await AutoChangeSourceSetting.resolve(store), isTrue);
    });

    testWidgets('已存的行读回来就是开关的位置', (tester) async {
      await AutoChangeSourceSetting.putGlobal(store, enabled: false);
      await tester.pumpWidget(
        localizedApp(home: AutoChangeSourcePage(store: store)),
      );
      await tester.pumpAndSettle();

      // The page reads the row it owns before its first frame with a switch:
      // `false` is on screen as off, not as the default it would start from.
      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('auto-change-source-switch')),
            )
            .value,
        isFalse,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('设置页的一个开关：默认开着，关掉写下 false，再打开写回 true', (
      tester,
    ) async {
      await tester.pumpWidget(
        localizedApp(home: AutoChangeSourcePage(store: store)),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(
        const ValueKey('auto-change-source-switch'),
      );
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);
      expect(await store.setting(AutoChangeSourceSetting.key), isNull);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(AutoChangeSourceSetting.key), 'false');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(AutoChangeSourceSetting.key), 'true');
      expect(tester.takeException(), isNull);
    });
  });
}
