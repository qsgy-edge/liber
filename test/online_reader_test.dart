import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/reader_script.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// The conversion the reader runs is the engine's; a widget test cannot load the
/// native library, so it injects this double and reads the target it was given.
String markTarget(String text, ConvertTarget target) =>
    '<<${target.name}>>$text';

/// The reader only needs chapter text. Driving the real rule adapter here would
/// load the native library into a widget test, where the binding cannot settle
/// pending bridge work; the rule semantics have their own coverage in
/// `html_rule_adapter_test.dart` and in the HTML pipeline test.
class ScriptedPipeline extends HtmlSourcePipeline {
  ScriptedPipeline({this.gate, this.contentTitle, this.secondBody})
    : super(const {
        'bookSourceUrl': 'https://example.test',
      }, _UnusedTransport());

  /// Holds the second chapter response so the loading header can be observed.
  final Completer<void>? gate;
  final String? contentTitle;
  final String? secondBody;
  int calls = 0;

  /// How many chapters were fetched, whatever the gate is doing: the count a
  /// re-render must not raise.
  int fetches = 0;

  /// The next chapter URL the reader passed with each chapter fetch, in call
  /// order: the frozen next-chapter lookup the content stage's stop guard reads.
  final nextChapterUrls = <String?>[];

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    fetches += 1;
    nextChapterUrls.add(nextChapterUrl);
    if (gate != null && calls++ > 0) await gate!.future;
    return HtmlChapterBody(
      (fetches > 1 ? secondBody : null) ??
          List.generate(60, (i) => '${chapter.url} 第$i段 中文内容。').join('\n'),
      1,
      title: contentTitle,
    );
  }
}

class _OpenGateStore extends SpaceStore {
  _OpenGateStore(super.db, this.gate);
  final Completer<void> gate;
  bool waiting = false;

  @override
  Future<List<ReplaceRule>> replaceRules() async {
    waiting = true;
    await gate.future;
    return super.replaceRules();
  }
}

class _ScriptGateStore extends SpaceStore {
  _ScriptGateStore(super.db);
  Completer<void>? settingGate;
  var blocked = false;

  @override
  Future<String?> setting(String key, {String bookId = ''}) async {
    final gate = settingGate;
    if (key == ReaderScriptSetting.key && bookId.isNotEmpty && gate != null) {
      blocked = true;
      await gate.future;
    }
    return super.setting(key, bookId: bookId);
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

/// A tag long enough to wrap without the frozen `singleLine="true"`.
const _longTag = '2026-01-01 12:34:56 更新时间很长很长很长很长很长很长很长很长很长很长很长很长';

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  late String bookId;

  const sourceUrl = 'https://example.test';
  const bookUrl = '$sourceUrl/book';

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    bookId = await shelf.ensureBook(const {
      'bookSourceUrl': sourceUrl,
    }, HtmlBook(url: Uri.parse(bookUrl), title: '书'));
  });

  tearDown(() => store.close());

  Future<void> addChapters(List<(String, String)> chapters) =>
      store.putChapters(bookId, [
        for (var index = 0; index < chapters.length; index++)
          BookChapter(
            bookId: bookId,
            chapterKey: chapters[index].$2,
            name: chapters[index].$1,
            url: chapters[index].$2,
            chapterIndex: index,
            isVolume: false,
            isVip: false,
            isPay: false,
          ),
      ]);

  testWidgets(
    'cached shelf resume waits for route construction before opening reader',
    (tester) async {
      const source = {
        'bookSourceUrl': sourceUrl,
        'ruleContent': {'content': '@CSS:.con p@text'},
      };
      final pipeline = ScriptedPipeline();
      await addChapters([('第一章', '$sourceUrl/1')]);
      final entry = (await shelf.find(sourceUrl, bookUrl))!;

      await tester.pumpWidget(
        localizedApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => HtmlSourceBrowser(
                    source: source,
                    keyword: '',
                    pipeline: pipeline,
                    service: shelf,
                    resume: entry,
                  ),
                ),
              ),
              child: const Text('打开书架书籍'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开书架书籍'));
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'reader saves visible paragraph, restores it, and switches chapters',
    (tester) async {
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      // Each reader owns the pipeline it fetches through, so a remount gets a
      // fresh one and the replaced reader cancelling its own is the point.
      Widget page(int index, int offset) => localizedApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
          chapterIndex: index,
          textOffset: offset,
        ),
      );
      await tester.pumpWidget(page(0, 0));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      final saved = (await store.progressOf(bookId))!.textOffset;
      expect(saved, greaterThan(0));

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(page(0, saved));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.textOffset, saved);

      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/2');
      expect((await store.progressOf(bookId))!.textOffset, 0);
      expect((await store.progressOf(bookId))!.chapterIndex, 1);

      await tester.tap(find.text('上一章'));
      await tester.pumpAndSettle();
      expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/1');
      expect(tester.takeException(), isNull);
    },
  );

  for (final replaceCatalog in [false, true]) {
    testWidgets(
      replaceCatalog
          ? 'a queued reader position cannot update a replaced catalog'
          : 'leaving the reader preserves a queued visible position',
      (tester) async {
        const source = {'bookSourceUrl': sourceUrl};
        final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
        final chapter = SourceChapter('第一章', Uri.parse('$sourceUrl/1'));
        await shelf.add(source, book, [chapter]);
        await tester.pumpWidget(
          localizedApp(
            home: OnlineReaderPage(
              pipeline: ScriptedPipeline(),
              book: book,
              bookId: bookId,
              chapters: [chapter],
              service: shelf,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final before = (await store.progressOf(bookId))!;
        expect(before.textOffset, 0);

        final locked = Completer<void>();
        final release = Completer<void>();
        final blocker = store.transaction(() async {
          locked.complete();
          await release.future;
          if (replaceCatalog) {
            await shelf.updateCatalog(sourceUrl, book, [
              chapter.withName('刷新后的目录标题'),
            ]);
          }
        });
        await locked.future;
        try {
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(0, -800),
          );
          await tester.pumpAndSettle();
          await tester.pumpWidget(const SizedBox());
        } finally {
          release.complete();
          await blocker;
        }
        await store.transaction(() async {});

        final position = (await store.progressOf(bookId))!;
        expect(position.chapterKey, chapter.progressKey);
        if (replaceCatalog) {
          expect((await store.chaptersOf(bookId)).single.name, '刷新后的目录标题');
          expect(position, before);
        } else {
          expect(position.textOffset, greaterThan(0));
        }
      },
    );
  }

  testWidgets('reader saves the source title on the chapter it loaded', (
    tester,
  ) async {
    const source = {'bookSourceUrl': sourceUrl};
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1'), variable: 'first'),
      SourceChapter.fromAddress(
        '第二章',
        '$sourceUrl/2,{"method":"GET"}',
        bookUrl: Uri.parse(bookUrl),
        variable: 'second',
      ),
    ];
    await shelf.add(source, book, chapters);
    final before = (await shelf.find(sourceUrl, bookUrl))!.chapters;
    List<SourceChapter>? handed;
    Widget page(String? title, int offset) => localizedApp(
      home: OnlineReaderPage(
        pipeline: ScriptedPipeline(contentTitle: title),
        book: book,
        bookId: bookId,
        chapters: chapters,
        service: shelf,
        chapterIndex: 1,
        textOffset: offset,
        onEntityState: (_, updated) => handed = updated,
      ),
    );
    await tester.pumpWidget(page(null, 0));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -800),
    );
    await tester.pumpAndSettle();
    final resumeOffset = (await store.progressOf(bookId))!.textOffset;
    expect(resumeOffset, greaterThan(0));

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(page('正文标题', resumeOffset));
    await tester.pumpAndSettle();

    final reopened = (await ShelfService(store).find(sourceUrl, bookUrl))!;
    expect(reopened.chapters, [before[0], before[1].copyWith(name: '正文标题')]);
    expect(reopened.chapterKey, before[1].chapterKey);
    expect(reopened.textOffset, resumeOffset);
    expect(handed!.map((chapter) => chapter.name), ['第一章', '正文标题']);
    expect(find.text('正文标题'), findsOneWidget);
  });

  for (final (label, title, expected) in [
    ('U+0085', '\u0085', '\u0085'),
    ('U+001C', '\u001C', '目录标题'),
  ]) {
    testWidgets('reader content title uses selected blankness: $label', (
      tester,
    ) async {
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final chapter = SourceChapter('目录标题', Uri.parse('$sourceUrl/1'));
      await shelf.add(source, book, [chapter]);
      final before = (await store.chaptersOf(bookId)).single;
      List<SourceChapter>? handed;

      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: ScriptedPipeline(contentTitle: title),
            book: book,
            bookId: bookId,
            chapters: [chapter],
            service: shelf,
            onEntityState: (_, updated) => handed = updated,
          ),
        ),
      );
      await tester.pumpAndSettle();

      final row = (await store.chaptersOf(bookId)).single;
      expect(row.name.codeUnits, expected.codeUnits);
      expect(row, before.copyWith(name: expected));
      expect(handed!.single.name, expected);
      expect(find.text(expected), findsOneWidget);
    });
  }

  test(
    'title publication leaves a replaced chapter and another source alone',
    () async {
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final old = SourceChapter('目录标题', Uri.parse('$sourceUrl/1'));
      final current = SourceChapter.fromAddress(
        old.name,
        '$sourceUrl/1,{"method":"GET"}',
        bookUrl: book.url,
        variable: 'current',
      );
      await shelf.add(source, book, [current]);

      Future<void> publish(String owner, SourceChapter chapter, bool current) =>
          shelf.saveChapterTitle(
            bookId: bookId,
            sourceRef: owner,
            book: book,
            chapter: chapter,
            chapterIndex: 0,
            title: '正文标题',
            isCurrent: () => current,
          );

      final before = (await shelf.find(sourceUrl, bookUrl))!.chapters;
      await publish(sourceUrl, old, true);
      await publish('https://other.test', current, true);
      await publish(sourceUrl, current, false);
      expect((await shelf.find(sourceUrl, bookUrl))!.chapters, before);
    },
  );

  testWidgets('reading an imported relative chapter updates its name only', (
    tester,
  ) async {
    const address = '../chapter/1,{"webView":true}';
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
    await addChapters([('目录标题', address)]);
    final before = (await store.chaptersOf(bookId)).single;
    final chapter = SourceChapter.fromAddress(
      before.name,
      address,
      bookUrl: book.url,
      chapterKey: before.chapterKey,
    );
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(contentTitle: '正文标题'),
          book: book,
          bookId: bookId,
          chapters: [chapter],
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      (await store.chaptersOf(bookId)).single,
      before.copyWith(name: '正文标题'),
    );
  });

  for (final (sameRow, title) in [
    (false, '晚到标题'),
    (true, '晚到标题'),
    (true, null),
  ]) {
    testWidgets(
      'a pending read cannot publish after replacement (${sameRow ? 'same fields' : 'updated metadata'}, ${title == null ? 'no title' : 'with title'})',
      (tester) async {
        const source = {'bookSourceUrl': sourceUrl};
        final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
        final uri = Uri.parse('$sourceUrl/1');
        final before = SourceChapter('目录标题', uri, tag: '旧标记');
        final after = SourceChapter('目录标题', uri, tag: sameRow ? '旧标记' : '刷新标记');
        await shelf.add(source, book, [before]);
        await shelf.saveProgress(
          bookId,
          chapterKey: before.progressKey,
          chapterIndex: 0,
          textOffset: 348,
        );
        final progress = await store.progressOf(bookId);
        final gate = Completer<void>();
        final pipeline = ScriptedPipeline(gate: gate, contentTitle: title)
          ..calls = 1;
        var publications = 0;
        await tester.pumpWidget(
          localizedApp(
            home: OnlineReaderPage(
              pipeline: pipeline,
              book: book,
              bookId: bookId,
              chapters: [before],
              service: shelf,
              onEntityState: (_, _) => publications++,
            ),
          ),
        );
        await tester.pump();
        expect(pipeline.fetches, 1);
        await shelf.updateCatalog(sourceUrl, book, [after]);
        final freshRow = (await store.chaptersOf(bookId)).single;
        gate.complete();
        await tester.pumpAndSettle();
        expect((await store.chaptersOf(bookId)).single, freshRow);
        expect(publications, 0);
        expect(await store.progressOf(bookId), progress);
      },
    );
  }

  testWidgets(
    'replacement while the reader opens cannot authorize an old catalog',
    (tester) async {
      final openGate = Completer<void>();
      final gatedStore = _OpenGateStore(
        SpaceDatabase(NativeDatabase.memory()),
        openGate,
      );
      addTearDown(gatedStore.close);
      final gatedShelf = ShelfService(gatedStore);
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final chapter = SourceChapter('目录标题', Uri.parse('$sourceUrl/1'));
      await gatedShelf.add(source, book, [chapter]);
      final entry = (await gatedShelf.find(sourceUrl, bookUrl))!;
      final pipeline = ScriptedPipeline(contentTitle: '旧正文标题');
      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: pipeline,
            book: book,
            bookId: entry.id,
            chapters: [chapter],
            service: gatedShelf,
          ),
        ),
      );
      await tester.pump();
      expect(gatedStore.waiting, isTrue);
      expect(pipeline.fetches, 0);
      await gatedShelf.updateCatalog(sourceUrl, book, [chapter]);
      openGate.complete();
      await tester.pumpAndSettle();
      expect(
        (await gatedStore.chaptersOf(entry.id)).single,
        entry.chapters.single,
      );
      expect(await gatedStore.progressOf(entry.id), isNull);
    },
  );

  testWidgets(
    'a shelf entry opened after catalog replacement cannot rename that catalog',
    (tester) async {
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final chapter = SourceChapter('目录标题', Uri.parse('$sourceUrl/1'));
      await shelf.add(source, book, [chapter]);
      final entry = (await shelf.find(sourceUrl, bookUrl))!;
      await shelf.updateCatalog(sourceUrl, book, [chapter]);
      final pipeline = ScriptedPipeline(contentTitle: '旧正文标题');
      await tester.pumpWidget(
        localizedApp(
          home: HtmlSourceBrowser(
            source: source,
            keyword: '',
            service: shelf,
            resume: entry,
            pipeline: pipeline,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(OnlineReaderPage), findsOneWidget);
      expect((await store.chaptersOf(bookId)).single, entry.chapters.single);
      expect(await store.progressOf(bookId), isNull);
    },
  );

  testWidgets(
    'replacement while idle prevents a second chapter from publishing',
    (tester) async {
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      await shelf.add(source, book, chapters);
      final pipeline = ScriptedPipeline(contentTitle: '正文标题');
      var reports = 0;
      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: pipeline,
            book: book,
            bookId: bookId,
            chapters: chapters,
            service: shelf,
            onEntityState: (_, _) => reports++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reports, 1);
      await shelf.updateCatalog(sourceUrl, book, [
        chapters.first.withName('正文标题'),
        chapters.last,
      ]);
      final refreshed = await store.chaptersOf(bookId);
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      expect(await store.chaptersOf(bookId), refreshed);
      expect(reports, 1);
      expect(
        (await store.progressOf(bookId))!.chapterKey,
        chapters.first.progressKey,
      );
    },
  );

  testWidgets(
    'script changes cannot render a rejected chapter as the previous chapter',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale(
        'zh',
        'CN',
      );
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      const source = {'bookSourceUrl': sourceUrl};
      final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      await shelf.add(source, book, chapters);
      final gate = Completer<void>();
      final pipeline = ScriptedPipeline(
        gate: gate,
        contentTitle: '正文标题',
        secondBody: 'REJECTED CHAPTER 正文',
      );
      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: pipeline,
            book: book,
            bookId: bookId,
            chapters: chapters,
            service: shelf,
            convert: markTarget,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byType(SingleChildScrollView),
        const Offset(0, -800),
      );
      await tester.pumpAndSettle();
      final progress = (await store.progressOf(bookId))!;
      expect(progress.textOffset, greaterThan(0));
      await tester.tap(find.text('下一章'));
      await tester.pump();
      expect(pipeline.fetches, 2);
      await shelf.updateCatalog(sourceUrl, book, chapters);
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.textContaining('REJECTED CHAPTER'), findsNothing);
      await tester.tap(find.byTooltip('中文转换'));
      await tester.pumpAndSettle();
      final choice = find.byKey(
        const ValueKey('reader-script-book-traditional_generic'),
      );
      await tester.scrollUntilVisible(choice, 300);
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tapBack(tester);
      await tester.pumpAndSettle();
      expect(find.textContaining('https://example.test/1 第'), findsWidgets);
      expect(find.textContaining('<<traditionalGeneric>>'), findsWidgets);
      expect(find.textContaining('REJECTED CHAPTER'), findsNothing);
      expect(await store.progressOf(bookId), progress);
      expect(pipeline.fetches, 2);
    },
  );

  for (final shelved in [true, false]) {
    testWidgets(
      'volume saves a URL-prefix title and stays readable on ${shelved ? 'shelf' : 'add'}',
      (tester) async {
        const address = '$sourceUrl/c/1,{"method":"GET"}';
        const title = '$sourceUrl/c';
        const catalogName = '目录卷';
        const source = {'bookSourceUrl': sourceUrl};
        final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
        final chapter = SourceChapter(
          catalogName,
          Uri.parse('$sourceUrl/c/1'),
          rawAddress: '/c/1,{"method":"GET"}',
          isVolume: true,
          tag: '卷标',
          isVip: true,
          fetchContext: (requestAddress: address, retainedPage: null),
        );
        if (shelved) await shelf.add(source, book, [chapter]);
        final before = await store.chaptersOf(bookId);
        List<SourceChapter>? handed;
        await tester.pumpWidget(
          localizedApp(
            home: OnlineReaderPage(
              pipeline: ScriptedPipeline(contentTitle: title),
              book: book,
              bookId: bookId,
              chapters: [chapter],
              service: shelf,
              onEntityState: (_, updated) => handed = updated,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(title), findsOneWidget);
        expect(find.textContaining('第0段'), findsOneWidget);
        final returned = handed!.single;
        expect(returned.name, title);
        expect(returned.progressKey, '$sourceUrl/c/1');
        expect(returned.address, '/c/1,{"method":"GET"}');
        expect(returned.fetchContext, same(chapter.fetchContext));
        if (shelved) {
          expect(
            (await store.chaptersOf(bookId)).single,
            before.single.copyWith(name: title),
          );
        } else {
          expect(await store.chaptersOf(bookId), isEmpty);
          await shelf.add(source, book, handed!);
        }
        final reopened = (await shelf.find(sourceUrl, bookUrl))!;
        final row = reopened.chapters.single;
        expect(row.name, title);
        expect(row.url, address);
        expect(row.tag, '卷标');
        expect(row.isVip, isTrue);
        expect(reopened.chapterKey, '$sourceUrl/c/1');
        final reopenedChapter = SourceChapter.fromAddress(
          row.name,
          row.url!,
          bookUrl: book.url,
          chapterKey: row.chapterKey,
          tag: row.tag,
          isVolume: row.isVolume,
          rendersTagAsContent: row.rendersTagAsContent,
        );
        expect(row.rendersTagAsContent, isFalse);
        expect(reopenedChapter.rendersTagAsContent, isFalse);
      },
    );
  }

  test('renaming a readable volume does not turn its address into a tag', () {
    final target = Uri.parse('$sourceUrl/c/1');
    const address = '/c/1,{"method":"GET"}';
    final chapter = SourceChapter(
      '目录卷',
      target,
      rawAddress: address,
      isVolume: true,
      fetchContext: (
        requestAddress: '$sourceUrl/c/1,{"method":"GET"}',
        retainedPage: null,
      ),
    );
    final renamed = chapter.withName('/c/1');
    expect(renamed.name, '/c/1');
    expect(renamed.rendersTagAsContent, isFalse);
    expect(renamed.progressKey, '$sourceUrl/c/1');
    expect(renamed.persistedAddress, '$sourceUrl/c/1,{"method":"GET"}');
    expect(renamed.fetchContext, same(chapter.fetchContext));
    expect(renamed.withVariable('updated').rendersTagAsContent, isFalse);
  });

  testWidgets(
    'reader passes the frozen next-chapter URL, index-0 fallback included',
    (tester) async {
      final pipeline = ScriptedPipeline();
      final chapters = [
        SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
        SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
      ];
      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: pipeline,
            book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
            bookId: bookId,
            chapters: chapters,
            service: shelf,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('下一章'));
      await tester.pumpAndSettle();
      // The content stage's next-page guard reads the next chapter; the last
      // chapter falls back to the chapter at index 0, which is the frozen
      // lookup's own quirk (`BookContent.kt:49-53`) reproduced as it stands.
      expect(pipeline.nextChapterUrls, ['$sourceUrl/2', '$sourceUrl/1']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('reload cannot overlap a next-chapter fetch', (tester) async {
    final gate = Completer<void>();
    final pipeline = ScriptedPipeline(gate: gate);
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: [
            SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
            SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
          ],
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Both buttons still have their old callbacks until the next frame.
    await tester.tap(find.text('下一章'));
    await tester.tap(find.text('重新加载'));
    gate.complete();
    await tester.pumpAndSettle();

    expect(pipeline.fetches, 2);
    expect(find.text('第二章'), findsOneWidget);
    expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/2');

    await tester.tap(find.text('重新加载'));
    await tester.pumpAndSettle();
    expect(pipeline.fetches, 3);
    expect(find.text('第二章'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader blanks the chapter name while a chapter loads', (
    tester,
  ) async {
    final pipeline = ScriptedPipeline(gate: Completer<void>());
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
    ];
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('第一章'), findsOneWidget);
    await tester.tap(find.text('下一章'));
    await tester.pump();
    // Neither the stale nor the incoming name may sit next to the spinner.
    expect(find.text('第一章'), findsNothing);
    expect(find.text('第二章'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pipeline.gate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('第二章'), findsOneWidget);
    expect((await store.progressOf(bookId))!.chapterKey, '$sourceUrl/2');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader applies the space replace rules to the title and the body', (
    tester,
  ) async {
    // The rules the frozen reader reads per book: a content rule that reaches
    // every source, and a title rule. Both are literal, because a regex rule runs
    // in its own isolate (the deadline) and a widget test's binding does not
    // deliver another isolate's messages; `content_processing_test.dart` covers
    // the regex path.
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'content-rule',
        name: '去广告',
        pattern: '第0段',
        replacement: const Value('第零段'),
        isRegex: const Value(false),
      ),
    );
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'title-rule',
        name: '章改回',
        pattern: '章',
        replacement: const Value('回'),
        scopeTitle: const Value(true),
        scopeContent: const Value(false),
        isRegex: const Value(false),
      ),
    );
    final chapters = [SourceChapter('第一章 广告', Uri.parse('$sourceUrl/1'))];
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The body carries the content rule's replacement.
    expect(find.textContaining('第零段'), findsWidgets);
    expect(find.textContaining('第0段'), findsNothing);
    // The reader's own title is the replaced one.
    expect(find.text('第一回 广告'), findsOneWidget);
    // The table of contents stays raw: the frozen list replaces a title only
    // when `AppConfig.tocUiUseReplace` is on, and it defaults to false.
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();
    expect(find.text('第一章 广告'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reader table of contents shows the tag, the volume and the lock', (
    tester,
  ) async {
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1'), tag: '2026-01-01'),
      SourceChapter.volume(
        '第一卷',
        0,
        tocUrl: Uri.parse('$sourceUrl/v'),
        tag: '卷首',
      ),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2'), isVip: true),
      SourceChapter('第三章', Uri.parse('$sourceUrl/3'), isVip: true, isPay: true),
      SourceChapter('第四章', Uri.parse('$sourceUrl/4'), tag: _longTag),
    ];
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: ScriptedPipeline(),
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('目录'));
    await tester.pumpAndSettle();

    // A non-volume chapter's `tag` is its secondary line
    // (`ChapterListAdapter.kt:146-150`).
    expect(find.text('2026-01-01'), findsOneWidget);
    // A volume is a heading and keeps its `tag` hidden (`:138-150`).
    expect(find.text('第一卷'), findsOneWidget);
    expect(find.text('卷首'), findsNothing);
    // The volume row differs from its siblings only in its background
    // (`:138-139`): no bold title.
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
    // The frozen row is `singleLine="true"`
    // (`res/layout/item_chapter_list.xml`), so a long name or tag stays on one
    // line instead of growing the row.
    expect(volumeName.maxLines, 1);
    expect(volumeName.overflow, TextOverflow.ellipsis);
    final longTag = tester.widget<Text>(find.text(_longTag));
    expect(longTag.maxLines, 1);
    expect(longTag.overflow, TextOverflow.ellipsis);
    // The lock is `isVip && !isPay` (`:162-165`), so the paid chapter has none.
    expect(find.byIcon(Icons.lock_outline), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'reader renders the script the system locale asks for, 正文和目录标题一样',
    (tester) async {
      tester.binding.platformDispatcher.localeTestValue = const Locale(
        'zh',
        'TW',
      );
      addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
      final chapters = [SourceChapter('第一章 龍鳳', Uri.parse('$sourceUrl/1'))];
      await tester.pumpWidget(
        localizedApp(
          home: OnlineReaderPage(
            pipeline: ScriptedPipeline(),
            book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
            bookId: bookId,
            chapters: chapters,
            service: shelf,
            convert: markTarget,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The body and the chapter title above it carry the locale's target.
      expect(find.textContaining('<<traditionalTaiwan>>'), findsWidgets);
      // The table of contents converts the chapter name too, and the raw name is
      // nowhere on the page any more.
      await tester.tap(find.text('目录'));
      await tester.pumpAndSettle();
      expect(find.text('<<traditionalTaiwan>>第一章 龍鳳'), findsWidgets);
      expect(find.text('第一章 龍鳳'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('改设置后在线章节重新渲染，且不重新抓取，本书覆盖生效', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'zh',
      'CN',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final pipeline = ScriptedPipeline();
    final chapters = [SourceChapter('第一章', Uri.parse('$sourceUrl/1'))];
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
          convert: markTarget,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('<<simplifiedMainland>>'), findsWidgets);
    final fetches = pipeline.fetches;

    await tester.tap(find.byTooltip('中文转换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
      300,
    );
    await tester.tap(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
    );
    await tester.pumpAndSettle();
    await tapBack(tester);
    await tester.pumpAndSettle();

    // The override is what the open chapter renders in, and the chapter was not
    // fetched a second time for it.
    expect(find.textContaining('<<traditionalGeneric>>'), findsWidgets);
    expect(find.textContaining('<<simplifiedMainland>>'), findsNothing);
    expect(pipeline.fetches, fetches, reason: '改设置不重新抓取章节');
    expect(
      await store.setting(ReaderScriptSetting.key, bookId: bookId),
      'traditional_generic',
    );
    expect(
      await store.setting(ReaderScriptSetting.key),
      isNull,
      reason: '本书覆盖不动安装的选择',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('conversion lookup cannot race chapter navigation', (
    tester,
  ) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'zh',
      'CN',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final gated = _ScriptGateStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(gated.close);
    final serviced = ShelfService(gated);
    final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
    final chapters = [
      SourceChapter('第一章', Uri.parse('$sourceUrl/1')),
      SourceChapter('第二章', Uri.parse('$sourceUrl/2')),
    ];
    await serviced.add(const {'bookSourceUrl': sourceUrl}, book, chapters);
    final entry = (await serviced.find(sourceUrl, bookUrl))!;
    final pipeline = ScriptedPipeline(secondBody: 'SECOND BODY');
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: book,
          bookId: entry.id,
          chapters: chapters,
          service: serviced,
          convert: markTarget,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('中文转换'));
    await tester.pumpAndSettle();
    final option = find.byKey(
      const ValueKey('reader-script-book-traditional_generic'),
    );
    await tester.scrollUntilVisible(option, 300);
    await tester.tap(option);
    await tester.pumpAndSettle();
    final gate = gated.settingGate = Completer<void>();
    await tapBack(tester);
    await tester.pumpAndSettle();
    expect(gated.blocked, isTrue);
    expect(find.textContaining('<<simplifiedMainland>>'), findsWidgets);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    final requestsWhileResolving = pipeline.fetches;
    gate.complete();
    await tester.pumpAndSettle();
    expect(requestsWhileResolving, 1);
    expect(find.textContaining('<<traditionalGeneric>>'), findsWidgets);
    await tester.tap(find.text('下一章'));
    await tester.pumpAndSettle();
    expect(pipeline.fetches, 2);
    expect(
      find.textContaining('<<traditionalGeneric>>SECOND BODY'),
      findsOneWidget,
    );
    expect((await gated.progressOf(entry.id))!.chapterIndex, 1);
  });

  testWidgets('转换失败时页面报错，而不是让异常逃出设置回调', (tester) async {
    tester.binding.platformDispatcher.localeTestValue = const Locale(
      'zh',
      'CN',
    );
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
    final pipeline = ScriptedPipeline();
    final chapters = [SourceChapter('第一章', Uri.parse('$sourceUrl/1'))];
    await tester.pumpWidget(
      localizedApp(
        home: OnlineReaderPage(
          pipeline: pipeline,
          book: HtmlBook(url: Uri.parse(bookUrl), title: '书'),
          bookId: bookId,
          chapters: chapters,
          service: shelf,
          // The target the settings screen changes to is the one that fails,
          // the way a native conversion error or a rule failure would.
          convert: (text, target) => target == ConvertTarget.traditionalGeneric
              ? throw StateError('转换失败')
              : markTarget(text, target),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('<<simplifiedMainland>>'), findsWidgets);
    final fetches = pipeline.fetches;

    await tester.tap(find.byTooltip('中文转换'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
      300,
    );
    await tester.tap(
      find.byKey(const ValueKey('reader-script-book-traditional_generic')),
    );
    await tester.pumpAndSettle();
    await tapBack(tester);
    await tester.pumpAndSettle();

    // The reader is told on the error line it already has, nothing escapes the
    // app-bar callback, and the chapter is still not fetched again.
    expect(find.textContaining('中文转换失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(pipeline.fetches, fetches, reason: '失败的重渲染也不重新抓取章节');
  });
}
