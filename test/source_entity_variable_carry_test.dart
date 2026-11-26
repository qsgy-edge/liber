import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';

import 'l10n_support.dart';
import 'native_library.dart';
import 'space_test_support.dart';

/// #132 entity-variable transport: the carrier/runtime contract that carries a
/// candidate's book and chapter variable text across stage handoffs, copies and
/// a new pipeline, without touching a stored row while the candidate is a draft.
///
/// The real [InProcessSourceScriptRuntime] runs every script here, through the
/// same `book.getVariable`/`putVariable`/`variable` and chapter pair the frozen
/// `Book`/`BookChapter` expose. Both adapters run the same checks.
void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);

  const origin = 'http://entity.test';
  const bookUrl = '$origin/book';
  const chapterUrl = '$origin/c/1';

  /// The text a write stores, the frozen `GSON.toJson(variableMap)` shape.
  String variableText(Map<String, String?> map) =>
      JsonEncoder.withIndent('  ').convert({
        for (final entry in map.entries)
          if (entry.value != null) entry.key: entry.value,
      });

  _Pages htmlPages() => _Pages({
    '/book': '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
    '/toc': '<ul id="list"><li><a href="/c/1">第一章</a></li></ul>',
    '/c/1': '<p>正文</p>',
  });
  _Pages jsonPages() => _Pages({
    '/book': '{"title":"书","toc":"/toc"}',
    '/toc': '{"list":[{"name":"第一章","url":"/c/1"}]}',
    '/c/1': '{"text":"正文"}',
  });

  Map<String, dynamic> htmlSource({
    required String infoScript,
    required String tocScript,
    required String contentScript,
  }) => {
    'bookSourceUrl': origin,
    'bookSourceName': '实体变量源',
    'ruleBookInfo': {
      'name': '@CSS:h2@text',
      'intro': infoScript,
      'tocUrl': '@CSS:#toc a@href',
    },
    'ruleToc': {
      'chapterList': '@CSS:#list li',
      'chapterName': '@CSS:a@text',
      'chapterUrl': '@CSS:a@href',
      'updateTime': tocScript,
    },
    'ruleContent': {'content': contentScript},
  };

  Map<String, dynamic> jsonSource({
    required String infoScript,
    required String tocScript,
    required String contentScript,
  }) => {
    'bookSourceUrl': origin,
    'bookSourceName': '实体变量源',
    'searchUrl': '/search?key={{key}}',
    'ruleSearch': {
      'bookList': r'$.items',
      'name': r'$.title',
      'bookUrl': r'$.url',
    },
    'ruleBookInfo': {
      'name': r'$.title',
      'intro': infoScript,
      'tocUrl': r'$.toc',
    },
    'ruleToc': {
      'chapterList': r'$.list',
      'chapterName': r'$.name',
      'chapterUrl': r'$.url',
      'updateTime': tocScript,
    },
    'ruleContent': {'content': contentScript},
  };

  for (final replaced in [false, true]) {
    testWidgets(
      'reader entity writes ${replaced ? 'cannot touch a replacement catalog' : 'still reach the current catalog'}',
      (tester) => tester.runAsync(() async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final finished = Completer<void>();
        final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
        addTearDown(store.close);
        final shelf = ShelfService(store);
        final source = htmlSource(
          infoScript: '',
          tocScript: '',
          contentScript:
              '@js:book.putVariable("who", "reader book"); '
              'chapter.putVariable("who", "reader"); '
              'book.getVariable("who") + ":" + chapter.getVariable("who")',
        );
        final chapter = SourceChapter(
          '目录名',
          Uri.parse(chapterUrl),
          variable: variableText({'who': 'initial'}),
        );
        final book = HtmlBook(url: Uri.parse(bookUrl), title: '书');
        await shelf.add(source, book, [chapter]);
        final entry = (await shelf.find(origin, bookUrl))!;
        final pages = _Pages(
          {'/c/1': '<p>正文</p>'},
          beforeResponse: () async {
            entered.complete();
            await release.future;
          },
        );
        final pipeline = _FinishingHtml(
          source,
          pages,
          shelf.hostState,
          finished,
        );
        await tester.pumpWidget(
          localizedApp(
            home: OnlineReaderPage(
              pipeline: pipeline,
              book: book,
              bookId: entry.id,
              chapters: [chapter],
              service: shelf,
              convert: (text, _) => text,
            ),
          ),
        );
        await tester.pump();
        try {
          await Future.any([
            entered.future,
            finished.future,
          ]).timeout(const Duration(seconds: 8));
          expect(entered.isCompleted, isTrue);
          if (replaced) {
            await shelf.updateCatalog(
              origin,
              book.withVariable(variableText({'who': 'new book'})),
              [
                chapter.withVariable(variableText({'who': 'new catalog'})),
              ],
            );
          }
        } finally {
          release.complete();
        }
        await finished.future.timeout(const Duration(seconds: 8));
        await tester.pumpAndSettle();
        final current = (await store.chaptersOf(entry.id)).single;
        expect(
          jsonDecode(current.variable!)['who'],
          replaced ? 'new catalog' : 'reader',
        );
        final storedBook = (await store.bookById(entry.id))!;
        expect(
          jsonDecode(storedBook.variable!)['who'],
          replaced ? 'new book' : 'reader book',
        );
        expect(
          find.textContaining('reader book:reader'),
          replaced ? findsNothing : findsOneWidget,
        );
      }),
    );
  }

  for (final json in [false, true]) {
    for (final replaced in [false, true]) {
      final callback = json ? 'JSON initUrl' : 'HTML getStrResponse';
      testWidgets(
        'reader login re-entry via $callback with ${replaced ? 'a replaced' : 'the current'} catalog',
        (tester) => tester.runAsync(() async {
          // Warm the native callback port outside any reader draft. The login
          // hook below must carry the initiating reader's context on re-entry.
          final warm = InProcessSourceScriptRuntime();
          expect(
            await warm.evaluate(
              source: 'java.get("warmCallbackPort"); 1',
              input: const {},
              timeout: const Duration(seconds: 3),
            ),
            1,
          );
          final entered = Completer<void>();
          final release = Completer<void>();
          final finished = Completer<void>();
          final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
          addTearDown(store.close);
          final shelf = ShelfService(store);
          final createSource = json ? jsonSource : htmlSource;
          final source = createSource(
            infoScript: '',
            tocScript: '',
            contentScript:
                '@js:book.getVariable("who") + ":" + chapter.getVariable("who")',
          );
          const write = '''
if (source.get("retry") === "yes") {
  book.putVariable("who", "nested book");
  chapter.putVariable("who", "nested chapter");
}
''';
          source['loginCheckJs'] =
              'source.put("retry", "yes"); '
              '${json ? 'java.initUrl(); ' : ''}java.getStrResponse();';
          if (!json) {
            source['header'] =
                '@js:$write JSON.stringify({"X-Retry": source.get("retry") || "no"});';
          }
          final address = json
              ? '$chapterUrl,${jsonEncode({'js': '$write result;'})}'
              : chapterUrl;
          final chapter = SourceChapter.fromAddress(
            '目录名',
            address,
            bookUrl: Uri.parse(bookUrl),
            variable: variableText({'who': 'initial chapter'}),
          );
          final book = HtmlBook(
            url: Uri.parse(bookUrl),
            title: '书',
            variable: variableText({'who': 'initial book'}),
          );
          await shelf.add(source, book, [chapter]);
          final entry = (await shelf.find(origin, bookUrl))!;
          final pages = _Pages(
            {'/c/1': json ? '{"text":"正文"}' : '<p>正文</p>'},
            beforeResponse: () async {
              if (!entered.isCompleted) {
                entered.complete();
                await release.future;
              }
            },
          );
          final pipeline = json
              ? _FinishingJson(source, pages, shelf.hostState, finished)
              : _FinishingHtml(source, pages, shelf.hostState, finished);
          final handedOff = <(HtmlBook, List<SourceChapter>)>[];
          await tester.pumpWidget(
            localizedApp(
              home: OnlineReaderPage(
                pipeline: pipeline,
                book: book,
                bookId: entry.id,
                chapters: [
                  for (final row in entry.chapters)
                    SourceChapter.fromAddress(
                      row.name,
                      row.url ?? row.chapterKey,
                      bookUrl: book.url,
                      chapterKey: row.chapterKey,
                      variable: row.variable,
                    ),
                ],
                chapterCatalogRevision: entry.chapterCatalogRevision,
                service: shelf,
                convert: (text, _) => text,
                onEntityState: (book, chapters) =>
                    handedOff.add((book, chapters)),
              ),
            ),
          );
          await tester.pump();
          try {
            await Future.any([
              entered.future,
              finished.future,
            ]).timeout(const Duration(seconds: 8));
            expect(entered.isCompleted, isTrue);
            if (replaced) {
              await shelf.updateCatalog(
                origin,
                book.withVariable(variableText({'who': 'replacement book'})),
                [
                  chapter.withVariable(
                    variableText({'who': 'replacement chapter'}),
                  ),
                ],
              );
            }
          } finally {
            release.complete();
          }
          await finished.future.timeout(const Duration(seconds: 8));
          await tester.pumpAndSettle();
          expect(pages.requests.map((request) => request.url.path), [
            '/c/1',
            '/c/1',
          ]);
          if (!json) {
            expect(
              pages.requests.map((request) => request.headers['X-Retry']),
              ['no', 'yes'],
            );
          }
          expect(
            await shelf.hostState.entry(
              origin,
              sourceRuleVariableKey(origin, 'retry'),
            ),
            'yes',
          );
          expect(
            variableMapOf((await store.bookById(entry.id))!.variable)['who'],
            replaced ? 'replacement book' : 'nested book',
          );
          expect(
            variableMapOf(
              (await store.chaptersOf(entry.id)).single.variable,
            )['who'],
            replaced ? 'replacement chapter' : 'nested chapter',
          );
          expect(
            find.textContaining('nested book:nested chapter'),
            replaced ? findsNothing : findsOneWidget,
          );
          if (replaced) {
            expect(handedOff, isEmpty);
          } else {
            final (savedBook, savedChapters) = handedOff.single;
            expect(variableMapOf(savedBook.variable)['who'], 'nested book');
            expect(
              variableMapOf(savedChapters.single.variable)['who'],
              'nested chapter',
            );
          }
        }),
      );
    }
  }

  HtmlBook hitWith(String? variable) => HtmlBook(
    url: Uri.parse(bookUrl),
    rawAddress: bookUrl,
    preOptionUrl: Uri.parse(bookUrl),
    title: '书',
    variable: variable,
  );

  const writeBook =
      '@js:book.putVariable("written","B"); '
      'book.getVariable("seed") + "|" + book.getVariable("written")';
  const writeChapter = '@js:(chapter.putVariable("c","T"), "")';
  const readBoth =
      '@js:book.getVariable("written") + "|" + chapter.getVariable("c")';

  for (final json in [false, true]) {
    final label = json ? 'JSON' : 'HTML';

    test('$label deferred details returns script-written book and chapter '
        'variables and a fresh pipeline reads them', () async {
      final pageMap = json ? jsonPages() : htmlPages();
      final source = json
          ? jsonSource(
              infoScript: writeBook,
              tocScript: writeChapter,
              contentScript: readBoth,
            )
          : htmlSource(
              infoScript: writeBook,
              tocScript: writeChapter,
              contentScript: readBoth,
            );
      final pipeline = json
          ? JsonSourcePipeline(source, pageMap, deferEntityVariables: true)
          : HtmlSourcePipeline(source, pageMap, deferEntityVariables: true);

      final (book, chapters) = await pipeline.details(
        hitWith(variableText({'seed': 'old'})),
      );

      expect(
        variableMapOf(book.variable),
        {'seed': 'old', 'written': 'B'},
        reason: 'the book snapshot carries the seed plus the script write',
      );
      expect(chapters, hasLength(1));
      expect(
        variableMapOf(chapters.single.variable),
        {'c': 'T'},
        reason: 'the TOC script write rides the chapter carrier',
      );

      // The carriers are usable by a later pipeline: it seeds its own draft
      // from the text on the book and chapter it is handed.
      final fresh = json
          ? JsonSourcePipeline(source, jsonPages(), deferEntityVariables: true)
          : HtmlSourcePipeline(source, htmlPages(), deferEntityVariables: true);
      final body = await fresh.chapter(chapters.single, book: book);
      expect(body.text, contains('B|T'));
    });

    test(
      '$label deferred details seeds, deletes and lets a later stage observe it',
      () async {
        final pageMap = json ? jsonPages() : htmlPages();
        final source = json
            ? jsonSource(
                infoScript:
                    '@js:book.putVariable("seed", null); '
                    'book.getVariable("keep")',
                tocScript:
                    '@js:(chapter.putVariable("seen", '
                    'book.getVariable("seed") || "empty"), "")',
                contentScript: readBoth,
              )
            : htmlSource(
                infoScript:
                    '@js:book.putVariable("seed", null); '
                    'book.getVariable("keep")',
                tocScript:
                    '@js:(chapter.putVariable("seen", '
                    'book.getVariable("seed") || "empty"), "")',
                contentScript: readBoth,
              );
        final pipeline = json
            ? JsonSourcePipeline(source, pageMap, deferEntityVariables: true)
            : HtmlSourcePipeline(source, pageMap, deferEntityVariables: true);

        final (book, chapters) = await pipeline.details(
          hitWith(variableText({'seed': 'old', 'keep': 'K'})),
        );

        expect(variableMapOf(book.variable), {'keep': 'K'});
        expect(variableMapOf(chapters.single.variable), {'seen': 'empty'});
      },
    );
  }

  for (final json in [false, true]) {
    test(
      '${json ? 'JSON' : 'HTML'} TOC restores stored chapter text after rules',
      () async {
        final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
        addTearDown(store.close);
        final state = SourceHostState(
          persistence: SpaceHostStatePersistence(store),
        );
        const old = '{"old":"whole"}';
        await store.putBook(
          BooksCompanion.insert(
            id: 'b1',
            title: '书',
            kind: const Value('network'),
            sourceRef: const Value(origin),
            sourceBookUrl: const Value(bookUrl),
          ),
        );
        await store.putChapters('b1', [
          BookChapter(
            bookId: 'b1',
            chapterKey: chapterUrl,
            name: '第一章',
            url: chapterUrl,
            chapterIndex: 0,
            isVolume: false,
            isVip: false,
            isPay: false,
            variable: old,
          ),
        ]);
        final source = json
            ? jsonSource(
                infoScript: '@js:""',
                tocScript: writeChapter,
                contentScript: readBoth,
              )
            : htmlSource(
                infoScript: '@js:""',
                tocScript: writeChapter,
                contentScript: readBoth,
              );
        final pipeline = json
            ? JsonSourcePipeline(source, jsonPages(), hostState: state)
            : HtmlSourcePipeline(source, htmlPages(), hostState: state);
        final (_, chapters) = await pipeline.details(hitWith(null));
        expect(chapters.single.variable, old);
        expect(await store.chapterVariable(origin, bookUrl, chapterUrl), old);
      },
    );
  }

  test(
    'JSON TOC restores variables only for the exact stored source key',
    () async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      final exactSource = origin.replaceFirst(
        Uri.parse(origin).host,
        Uri.parse(origin).host.toUpperCase(),
      );
      const exact = '{"owner":"exact"}';
      const other = '{"owner":"other"}';
      for (final (id, sourceRef, variable) in [
        ('a', exactSource, exact),
        ('b', origin, other),
      ]) {
        await store.putBook(
          BooksCompanion.insert(
            id: id,
            title: '书',
            kind: const Value('network'),
            sourceRef: Value(sourceRef),
            sourceBookUrl: const Value(bookUrl),
          ),
        );
        await store.putChapters(id, [
          BookChapter(
            bookId: id,
            chapterKey: chapterUrl,
            name: '第一章',
            url: chapterUrl,
            chapterIndex: 0,
            isVolume: false,
            isVip: false,
            isPay: false,
            variable: variable,
          ),
        ]);
      }
      final source = jsonSource(
        infoScript: '@js:""',
        tocScript: writeChapter,
        contentScript: readBoth,
      )..['bookSourceUrl'] = exactSource;
      final pipeline = JsonSourcePipeline(
        source,
        jsonPages(),
        hostState: state,
      );
      final (_, chapters) = await pipeline.details(hitWith(null));
      expect(chapters.single.variable, exact);
      expect(
        await store.chapterVariable(exactSource, bookUrl, chapterUrl),
        exact,
      );
      expect(await store.chapterVariable(origin, bookUrl, chapterUrl), other);
    },
  );

  for (final json in [false, true]) {
    for (final freshToken in ['new', null]) {
      test(
        '${json ? 'JSON' : 'HTML'} off-shelf TOC refresh hands off ${freshToken ?? 'no'} token',
        () async {
          final root = await Directory.systemTemp.createTemp(
            'liber-toc-token-',
          );
          var workspace = await Workspace.open(root: root);
          addTearDown(() async {
            await workspace.close();
            await root.delete(recursive: true);
          });
          var shelf = ShelfService(await workspace.openSpace());
          final pages = json ? jsonPages() : htmlPages();
          Map<String, dynamic> source(String? token) {
            const content =
                '@js:"token:" + (chapter.getVariable("token") || "missing")';
            final source = json
                ? jsonSource(
                    infoScript: '',
                    tocScript: '',
                    contentScript: content,
                  )
                : htmlSource(
                    infoScript: '',
                    tocScript: '',
                    contentScript: content,
                  );
            (source['ruleToc'] as Map)['isVip'] = token == null
                ? '@js:false'
                : '@js:(chapter.putVariable("token", "$token"), false)';
            return source;
          }

          BookSourcePipeline open(
            Map<String, dynamic> source, {
            bool deferred = false,
          }) => json
              ? JsonSourcePipeline(
                  source,
                  pages,
                  hostState: shelf.hostState,
                  deferEntityVariables: deferred,
                )
              : HtmlSourcePipeline(
                  source,
                  pages,
                  hostState: shelf.hostState,
                  deferEntityVariables: deferred,
                );
          final originalToc = pages.pages['/toc']!;
          pages.pages['/toc'] = originalToc.replaceFirst('/c/1', chapterUrl);
          final initial = open(source('old'));
          final (oldBook, oldChapters) = await initial.details(hitWith(null));
          expect(oldChapters.single.variable, variableText({'token': 'old'}));
          expect(oldChapters.single.address, chapterUrl);
          initial.cancel();

          pages.pages['/toc'] = originalToc;
          final preview = open(source('preview'), deferred: true);
          final (_, candidate) = await preview.details(hitWith(null));
          expect(candidate.single.variable, variableText({'token': 'preview'}));
          preview.cancel();
          final oldReader = open(source(null));
          expect(
            (await oldReader.chapter(oldChapters.single, book: oldBook)).text,
            'token:old',
            reason: 'a deferred preview does not replace the shared handoff',
          );
          oldReader.cancel();

          final freshSource = source(freshToken);
          final refresh = open(freshSource);
          final (book, chapters) = await refresh.details(hitWith(null));
          final chapter = chapters.single;
          final expectedVariable = freshToken == null
              ? null
              : variableText({'token': freshToken});
          expect(chapter.address, '/c/1');
          expect(chapter.progressKey, oldChapters.single.progressKey);
          expect(chapter.variable, expectedVariable);
          expect(await shelf.find(origin, bookUrl), isNull);
          refresh.cancel();

          final reader = open(freshSource);
          final body = await reader.chapter(chapter, book: book);
          reader.cancel();
          // Save the content snapshot the reader hands back, not the pre-read TOC.
          await shelf.add(freshSource, book, [
            chapter.withVariable(body.chapterVariable),
          ]);
          await workspace.close();
          workspace = await Workspace.open(root: root);
          shelf = ShelfService(await workspace.openSpace());
          final reopened = (await shelf.find(origin, bookUrl))!;
          final row = reopened.chapters.single;
          final reopenedReader = open(freshSource);
          final reopenedBody = await reopenedReader.chapter(
            SourceChapter.fromAddress(
              row.name,
              row.url!,
              bookUrl: reopened.htmlBook.url,
              chapterKey: row.chapterKey,
              variable: row.variable,
            ),
            book: reopened.htmlBook,
          );
          reopenedReader.cancel();
          expect(row.chapterKey, chapterUrl);
          expect(row.url, chapterUrl);
          expect(pages.requests.map((r) => r.url.path), [
            '/book', '/toc', // initial
            '/book', '/toc', '/c/1', // preview then old reader
            '/book', '/toc', '/c/1', '/c/1', // refresh then read/reopen
          ]);
          expect(
            (body.text, body.chapterVariable, row.variable, reopenedBody.text),
            (
              'token:${freshToken ?? 'missing'}',
              expectedVariable,
              expectedVariable,
              'token:${freshToken ?? 'missing'}',
            ),
            reason: 'content, reader handoff, saved row, and reopened content',
          );
        },
      );
    }
  }

  test('JSON TOC duplicate resolved keys keep their existing handoff', () async {
    final source = jsonSource(
      infoScript: '',
      tocScript:
          '@js:chapter.title == "First" ? (chapter.putVariable("c", "first"), "") : ""',
      contentScript: '@js:chapter.getVariable("c")',
    );
    final pages = jsonPages();
    pages.pages['/toc'] = jsonEncode({
      'list': [
        {'name': 'First', 'url': chapterUrl},
        {'name': 'Second', 'url': '/c/1'},
      ],
    });
    final pipeline = JsonSourcePipeline(source, pages);
    addTearDown(pipeline.cancel);
    final (book, chapters) = await pipeline.details(hitWith(null));
    expect(chapters.map((chapter) => chapter.progressKey), [
      chapterUrl,
      chapterUrl,
    ]);
    expect(chapters.last.variable, isNull);
    expect((await pipeline.chapter(chapters.first, book: book)).text, 'first');
  });

  for (final json in [false, true]) {
    for (final deferred in [false, true]) {
      test(
        '${json ? 'JSON' : 'HTML'} restoration matches index and title (deferred=$deferred)',
        () async {
          final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
          addTearDown(store.close);
          final state = SourceHostState(
            persistence: SpaceHostStatePersistence(store),
          );
          await store.putBook(
            BooksCompanion.insert(
              id: 'b1',
              title: '书',
              kind: const Value('network'),
              sourceRef: const Value(origin),
              sourceBookUrl: const Value(bookUrl),
            ),
          );
          final oldTitles = ['第一章', 'old title', '第三章', '第四章', '第五章', 'Moved'];
          final oldValues = [
            '{"old":"whole"}',
            '{"old":"renamed"}',
            null,
            '',
            'opaque',
            '{"moved":"old"}',
          ];
          await store.putChapters('b1', [
            for (var i = 0; i < oldTitles.length; i++)
              BookChapter(
                bookId: 'b1',
                chapterKey: '$origin/c/$i',
                name: oldTitles[i],
                url: '$origin/c/$i',
                chapterIndex: i,
                isVolume: false,
                isVip: false,
                isPay: false,
                variable: oldValues[i],
              ),
          ]);
          final names = ['第一章', 'renamed', '第三章', '第四章', '第五章', 'new', 'Moved'];
          final addresses = [
            '$origin/c/new',
            for (var i = 1; i < names.length; i++) '$origin/c/$i',
          ];
          final page = json
              ? jsonEncode({
                  'list': [
                    for (var i = 0; i < names.length; i++)
                      {'name': names[i], 'url': addresses[i]},
                  ],
                })
              : '<ul id="list">${[for (var i = 0; i < names.length; i++) '<li><a href="${addresses[i]}">${names[i]}</a></li>'].join()}</ul>';
          final pages = _Pages({
            '/book': json
                ? '{"title":"书","toc":"/toc"}'
                : '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
            '/toc': page,
            '/c/new': json ? '{"text":"body"}' : '<p>body</p>',
          });
          final source = json
              ? jsonSource(
                  infoScript: '@js:""',
                  tocScript: writeChapter,
                  contentScript: '@js:chapter.getVariable("old")',
                )
              : htmlSource(
                  infoScript: '@js:""',
                  tocScript: writeChapter,
                  contentScript: '@js:chapter.getVariable("old")',
                );
          final pipeline = json
              ? JsonSourcePipeline(
                  source,
                  pages,
                  hostState: state,
                  deferEntityVariables: deferred,
                )
              : HtmlSourcePipeline(
                  source,
                  pages,
                  hostState: state,
                  deferEntityVariables: deferred,
                );
          final (book, chapters) = await pipeline.details(hitWith(null));
          expect(chapters[0].variable, oldValues[0]);
          expect(chapters[0].storeKey, '$origin/c/new');
          expect(variableMapOf(chapters[1].variable), {'c': 'T'});
          expect(variableMapOf(chapters[2].variable), {'c': 'T'});
          expect(chapters[3].variable, '');
          expect(chapters[4].variable, 'opaque');
          expect(variableMapOf(chapters[5].variable), {'c': 'T'});
          expect(variableMapOf(chapters[6].variable), {'c': 'T'});
          final stored = await store.chaptersOf('b1');
          expect(stored.map((c) => c.variable).toList(), oldValues);
          final body = await pipeline.chapter(chapters[0], book: book);
          expect(body.text, contains('whole'));
          await ShelfService(store).updateCatalog(origin, book, chapters);
          final published = await store.chaptersOf('b1');
          expect(published.first.variable, oldValues[0]);
          expect(published.first.chapterKey, '$origin/c/new');
        },
      );
    }
  }

  for (final json in [false, true]) {
    for (final cancelled in [false, true]) {
      test(
        '${json ? 'JSON' : 'HTML'} ${cancelled ? 'cancelled' : 'failed'} TOC does not publish item writes',
        () async {
          final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
          addTearDown(store.close);
          final state = SourceHostState(
            persistence: SpaceHostStatePersistence(store),
          );
          await store.putBook(
            BooksCompanion.insert(
              id: 'b1',
              title: '书',
              kind: const Value('network'),
              sourceRef: const Value(origin),
              sourceBookUrl: const Value(bookUrl),
            ),
          );
          await store.putChapters('b1', [
            BookChapter(
              bookId: 'b1',
              chapterKey: chapterUrl,
              name: '第一章',
              url: chapterUrl,
              chapterIndex: 0,
              isVolume: false,
              isVip: false,
              isPay: false,
              variable: '{"old":"kept"}',
            ),
          ]);
          final source = json
              ? jsonSource(
                  infoScript: '@js:""',
                  tocScript: writeChapter,
                  contentScript: readBoth,
                )
              : htmlSource(
                  infoScript: '@js:""',
                  tocScript: writeChapter,
                  contentScript: readBoth,
                );
          (source['ruleToc'] as Map)['nextTocUrl'] = json
              ? r'$.next'
              : '@CSS:#next@href';
          late void Function() cancel;
          final pages = _Pages(
            {
              if (cancelled) '/missing': json ? '{"list":[]}' : '<html></html>',
              '/book': json
                  ? '{"title":"书","toc":"/toc"}'
                  : '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
              '/toc': json
                  ? jsonEncode({
                      'list': [
                        {'name': '第一章', 'url': chapterUrl},
                        {'name': '新章', 'url': '$origin/c/2'},
                      ],
                      'next': '/missing',
                    })
                  : '<ul id="list"><li><a href="$chapterUrl">第一章</a></li><li><a href="$origin/c/2">新章</a></li></ul><a id="next" href="/missing">next</a>',
            },
            onRequest: (url) {
              if (cancelled && url.path == '/missing') cancel();
            },
          );
          final pipeline = json
              ? JsonSourcePipeline(source, pages, hostState: state)
              : HtmlSourcePipeline(source, pages, hostState: state);
          cancel = pipeline.cancel;
          await expectLater(
            pipeline.details(hitWith(null)),
            throwsA(cancelled ? isA<SourceRequestCancelled>() : isA<Object>()),
          );
          expect(
            await store.chapterVariable(origin, bookUrl, chapterUrl),
            '{"old":"kept"}',
          );
          expect(
            await state.chapterVariableRow(origin, bookUrl, '$origin/c/2'),
            isNull,
          );
        },
      );
    }
  }

  test('deferred preview leaves a matching persisted row unchanged', () async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    await store.putBook(
      BooksCompanion.insert(
        id: 'b1',
        title: '书',
        kind: const Value('network'),
        sourceRef: const Value(origin),
        sourceBookUrl: const Value(bookUrl),
        variable: Value(variableText({'seed': 'stored'})),
      ),
    );
    await store.putChapters('b1', [
      BookChapter(
        bookId: 'b1',
        chapterKey: chapterUrl,
        name: '第一章',
        url: chapterUrl,
        chapterIndex: 0,
        isVolume: false,
        isVip: false,
        isPay: false,
        variable: variableText({'c': 'stored'}),
      ),
    ]);

    final pipeline = JsonSourcePipeline(
      jsonSource(
        infoScript: writeBook,
        tocScript: writeChapter,
        contentScript: readBoth,
      ),
      jsonPages(),
      hostState: state,
      deferEntityVariables: true,
    );
    final (book, chapters) = await pipeline.details(
      hitWith(variableText({'seed': 'old'})),
    );

    // The book remains candidate-local; the matching chapter restores its row.
    expect(variableMapOf(book.variable), {'seed': 'old', 'written': 'B'});
    expect(variableMapOf(chapters.single.variable), {'c': 'stored'});
    // ...while the persisted row and the shared host surface do not move, and
    // the draft did not leak into the shared unwritten-value caches.
    expect(
      await store.bookVariable(origin, bookUrl),
      variableText({'seed': 'stored'}),
    );
    expect(
      await store.chapterVariable(origin, bookUrl, chapterUrl),
      variableText({'c': 'stored'}),
    );
    expect(
      await state.bookVariable(origin, bookUrl),
      variableText({'seed': 'stored'}),
    );
    expect(
      await state.chapterVariable(origin, bookUrl, chapterUrl),
      variableText({'c': 'stored'}),
    );
  });

  test('a failed deferred draft leaves the persisted row unchanged', () async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    await store.putBook(
      BooksCompanion.insert(
        id: 'b1',
        title: '书',
        kind: const Value('network'),
        sourceRef: const Value(origin),
        sourceBookUrl: const Value(bookUrl),
        variable: Value(variableText({'seed': 'stored'})),
      ),
    );

    final pipeline = JsonSourcePipeline(
      jsonSource(
        infoScript: '@js:book.putVariable("written","B"); missing.handler()',
        tocScript: writeChapter,
        contentScript: readBoth,
      ),
      jsonPages(),
      hostState: state,
      deferEntityVariables: true,
    );

    await expectLater(
      pipeline.details(hitWith(variableText({'seed': 'old'}))),
      throwsA(isA<SourceScriptError>()),
    );
    expect(
      await store.bookVariable(origin, bookUrl),
      variableText({'seed': 'stored'}),
    );
    expect(
      await state.bookVariable(origin, bookUrl),
      variableText({'seed': 'stored'}),
    );
  });

  test(
    'a cancelled deferred draft leaves the persisted row unchanged',
    () async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      await store.putBook(
        BooksCompanion.insert(
          id: 'b1',
          title: '书',
          kind: const Value('network'),
          sourceRef: const Value(origin),
          sourceBookUrl: const Value(bookUrl),
          variable: Value(variableText({'seed': 'stored'})),
        ),
      );

      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: writeBook,
          tocScript: writeChapter,
          contentScript: readBoth,
        ),
        jsonPages(),
        hostState: state,
        deferEntityVariables: true,
      )..cancel();

      await expectLater(
        pipeline.details(hitWith(variableText({'seed': 'old'}))),
        throwsA(isA<SourceRequestCancelled>()),
      );
      expect(
        await store.bookVariable(origin, bookUrl),
        variableText({'seed': 'stored'}),
      );
    },
  );

  test('two deferred candidates over one host surface stay isolated', () async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    Map<String, dynamic> source() => jsonSource(
      infoScript: writeBook,
      tocScript: writeChapter,
      contentScript: readBoth,
    );

    final first = JsonSourcePipeline(
      source(),
      jsonPages(),
      hostState: state,
      deferEntityVariables: true,
    );
    final second = JsonSourcePipeline(
      source(),
      jsonPages(),
      hostState: state,
      deferEntityVariables: true,
    );
    final (firstBook, _) = await first.details(
      hitWith(variableText({'seed': 'first'})),
    );
    final (secondBook, _) = await second.details(
      hitWith(variableText({'seed': 'second'})),
    );

    expect(variableMapOf(firstBook.variable), {
      'seed': 'first',
      'written': 'B',
    });
    expect(variableMapOf(secondBook.variable), {
      'seed': 'second',
      'written': 'B',
    });
    // Neither candidate wrote the space's row.
    expect(await store.bookVariable(origin, bookUrl), isNull);
  });

  test(
    'a second chapter() on one deferred pipeline keeps the first book write',
    () async {
      final pageMap = _Pages({
        '/c/1': '{"text":"one"}',
        '/c/2': '{"text":"two"}',
      });
      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: '@js:""',
          tocScript: '""',
          contentScript:
              '@js:book.putVariable("n", '
              'String(Number(book.getVariable("n") || "0") + 1)); '
              'book.getVariable("n")',
        ),
        pageMap,
        deferEntityVariables: true,
      );
      final first = await pipeline.chapter(
        SourceChapter('一', Uri.parse('$origin/c/1'), rawAddress: '/c/1'),
        book: hitWith(variableText({'n': '0'})),
      );
      expect(first.text, '1');
      // The second request is handed an older carrier with the same starting
      // value; the draft keeps the first call's write instead of reseeding.
      final second = await pipeline.chapter(
        SourceChapter('二', Uri.parse('$origin/c/2'), rawAddress: '/c/2'),
        book: hitWith(variableText({'n': '0'})),
      );
      expect(second.text, '2');
    },
  );

  test(
    'a second details() on one deferred pipeline starts a fresh chapter draft',
    () async {
      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: '@js:""',
          tocScript:
              '@js:if (java.get("tocRan") !== "1") { '
              'chapter.putVariable("c","T"); java.put("tocRan","1"); } ""',
          contentScript: '""',
        ),
        jsonPages(),
        deferEntityVariables: true,
      );
      final (_, firstChapters) = await pipeline.details(hitWith(null));
      expect(variableMapOf(firstChapters.single.variable), {'c': 'T'});
      // The rebuilt TOC does not write the chapter variable this time, so a
      // stale draft entry from the first TOC must not come back.
      final (_, secondChapters) = await pipeline.details(hitWith(null));
      expect(secondChapters.single.variable, isNull);
    },
  );

  test(
    'a JSON chapter address option js write is captured exactly once',
    () async {
      const script =
          "java.put('addressRuns', "
          "String(Number(java.get('addressRuns') || '0') + 1)); "
          "chapter.putVariable('addressToken','ready'); void 0";
      final address = '/c/1,${jsonEncode({'js': script})}';
      final state = SourceHostState();
      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: '@js:""',
          tocScript: r'$.missing',
          contentScript: readBoth,
        ),
        _Pages({
          '/book': '{"title":"书","toc":"/toc"}',
          '/toc': jsonEncode({
            'list': [
              {'name': '第一章', 'url': address},
            ],
          }),
          '/c/1': '{"text":"正文"}',
        }),
        hostState: state,
        deferEntityVariables: true,
      );

      final (book, chapters) = await pipeline.details(hitWith(null));
      expect(
        variableMapOf(chapters.single.variable),
        isEmpty,
        reason:
            'the address-option write belongs to the actual content request',
      );
      expect(
        await state.entry(origin, sourceRuleVariableKey(origin, 'addressRuns')),
        isNull,
        reason: 'the address option script has not run at TOC',
      );
      final body = await pipeline.chapter(chapters.single, book: book);
      expect(
        variableMapOf(body.chapterVariable),
        {'addressToken': 'ready'},
        reason: 'the actual content request returns its own option variable',
      );
      expect(
        await state.entry(origin, sourceRuleVariableKey(origin, 'addressRuns')),
        '1',
        reason: 'the address option script ran exactly once, at that request',
      );
    },
  );

  test(
    'HTML chapter option JS writes its chapter variable at fetch only',
    () async {
      final tail = jsonEncode({
        'js': "chapter.putVariable('addressToken','ready'); void 0",
      }).replaceAll('"', '&quot;');
      final pipeline = HtmlSourcePipeline(
        htmlSource(
          infoScript: '@CSS:h2@text',
          tocScript: '""',
          contentScript: '@js:"正文"',
        ),
        _Pages({
          '/book': '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
          '/toc': '<ul id="list"><li><a href="/c/1,$tail">第一章</a></li></ul>',
          '/c/1': '<p>正文</p>',
        }),
        deferEntityVariables: true,
      );
      final (book, chapters) = await pipeline.details(hitWith(null));
      expect(variableMapOf(chapters.single.variable), isEmpty);
      final chapter = await pipeline.chapter(chapters.single, book: book);
      expect(chapter.text, '正文');
      expect(variableMapOf(chapter.chapterVariable), {'addressToken': 'ready'});
    },
  );

  for (final json in [false, true]) {
    final label = json ? 'JSON' : 'HTML';

    test(
      '$label content returns the final book and chapter entity snapshots',
      () async {
        const contentScript =
            '@js:book.putVariable("b","B"); '
            'chapter.putVariable("c","C"); "正文"';
        final source = json
            ? jsonSource(
                infoScript: '@js:""',
                tocScript: '""',
                contentScript: contentScript,
              )
            : htmlSource(
                infoScript: '@js:""',
                tocScript: '""',
                contentScript: contentScript,
              );
        final pipeline = json
            ? JsonSourcePipeline(
                source,
                jsonPages(),
                deferEntityVariables: true,
              )
            : HtmlSourcePipeline(
                source,
                htmlPages(),
                deferEntityVariables: true,
              );
        final body = await pipeline.chapter(
          SourceChapter('一', Uri.parse('$origin/c/1'), rawAddress: '/c/1'),
          book: hitWith(variableText({'seed': 'S'})),
        );

        expect(body.text, contains('正文'));
        expect(variableMapOf(body.bookVariable), {'seed': 'S', 'b': 'B'});
        expect(variableMapOf(body.chapterVariable), {'c': 'C'});
      },
    );

    test('$label content replaces and deletes the details variables', () async {
      const infoScript =
          '@js:book.putVariable("detail","D"); '
          'book.putVariable("shared","old"); ""';
      const contentScript =
          '@js:book.putVariable("detail", null); '
          'book.putVariable("shared","new"); '
          'book.putVariable("content","B"); '
          'chapter.putVariable("content","C"); "正文"';
      final source = json
          ? jsonSource(
              infoScript: infoScript,
              tocScript: '@js:(chapter.putVariable("toc","T"), "")',
              contentScript: contentScript,
            )
          : htmlSource(
              infoScript: infoScript,
              tocScript: '@js:(chapter.putVariable("toc","T"), "")',
              contentScript: contentScript,
            );
      // An absolute TOC address keys the TOC write and the content read alike,
      // so this covers the replacement and deletion the ordinary read→add
      // lifecycle publishes (the relative raw-key boundary is pre-existing).
      final pageMap = _Pages({
        '/book': json
            ? '{"title":"书","toc":"/toc"}'
            : '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
        '/toc': json
            ? jsonEncode({
                'list': [
                  {'name': '第一章', 'url': '$origin/c/1'},
                ],
              })
            : '<ul id="list"><li><a href="$origin/c/1">第一章</a></li></ul>',
        '/c/1': json ? '{"text":"正文"}' : '<p>正文</p>',
      });
      final pipeline = json
          ? JsonSourcePipeline(source, pageMap)
          : HtmlSourcePipeline(source, pageMap);
      final (book, chapters) = await pipeline.details(hitWith(null));

      expect(variableMapOf(book.variable), {'detail': 'D', 'shared': 'old'});
      expect(variableMapOf(chapters.single.variable), {'toc': 'T'});

      final body = await pipeline.chapter(chapters.single, book: book);
      expect(body.text, contains('正文'));
      expect(
        variableMapOf(body.bookVariable),
        {'shared': 'new', 'content': 'B'},
        reason: 'the content rule deleted detail and replaced shared',
      );
      expect(variableMapOf(body.chapterVariable), {'toc': 'T', 'content': 'C'});
    });
  }

  test('HTML content snapshots include every paginated page write', () async {
    final pageMap = _Pages({
      '/c/1':
          '<div class="con"><p>one</p></div>'
          '<div class="next"><a href="/c/1-2">next</a></div>',
      '/c/1-2': '<div class="con"><p>two</p></div>',
    });
    final pipeline = HtmlSourcePipeline(
      {
        'bookSourceUrl': origin,
        'bookSourceName': '实体变量源',
        'ruleBookInfo': {'name': '@CSS:h2@text', 'tocUrl': '@CSS:#toc a@href'},
        'ruleToc': {
          'chapterList': '@CSS:#list li',
          'chapterName': '@CSS:a@text',
          'chapterUrl': '@CSS:a@href',
        },
        'ruleContent': {
          'content':
              '@js:book.putVariable("pages", '
              'String(Number(book.getVariable("pages") || "0") + 1)); '
              '"page " + book.getVariable("pages")',
          'nextContentUrl': '@CSS:.next a@href',
        },
      },
      pageMap,
      deferEntityVariables: true,
    );
    final body = await pipeline.chapter(
      SourceChapter('一', Uri.parse('$origin/c/1'), rawAddress: '/c/1'),
      book: hitWith(variableText({'seed': 'S'})),
    );

    expect(body.pages, 2);
    expect(body.text, contains('page 1'));
    expect(body.text, contains('page 2'));
    expect(variableMapOf(body.bookVariable), {'seed': 'S', 'pages': '2'});
  });

  test(
    'a volume shortcut still returns the carriers\' entity snapshots',
    () async {
      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: '@js:""',
          tocScript: '""',
          contentScript: '@js:"unused"',
        ),
        jsonPages(),
        deferEntityVariables: true,
      );
      final body = await pipeline.chapter(
        SourceChapter.volume(
          '第一卷',
          0,
          tocUrl: Uri.parse('$origin/toc'),
          tag: '卷内容',
          variable: variableText({'v': 'V'}),
        ),
        book: hitWith(variableText({'seed': 'S'})),
      );

      expect(body.text, '卷内容');
      expect(body.pages, 0);
      expect(variableMapOf(body.bookVariable), {'seed': 'S'});
      expect(variableMapOf(body.chapterVariable), {'v': 'V'});
    },
  );

  test(
    'ordinary mode still writes the space row and returns its snapshot',
    () async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      await store.putBook(
        BooksCompanion.insert(
          id: 'b1',
          title: '书',
          kind: const Value('network'),
          sourceRef: const Value(origin),
          sourceBookUrl: const Value(bookUrl),
          variable: Value(variableText({'seed': 'stored'})),
        ),
      );

      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: writeBook,
          tocScript: writeChapter,
          contentScript: readBoth,
        ),
        jsonPages(),
        hostState: state,
      );
      final (book, chapters) = await pipeline.details(hitWith(null));

      expect(variableMapOf(book.variable), {'seed': 'stored', 'written': 'B'});
      expect(
        await store.bookVariable(origin, bookUrl),
        variableText({'seed': 'stored', 'written': 'B'}),
      );
      // The TOC chapter write is both in the host surface under the key the
      // script bound and on the carrier the details stage returns.
      expect(
        await state.chapterVariable(origin, bookUrl, '/c/1'),
        variableText({'c': 'T'}),
      );
      expect(variableMapOf(chapters.single.variable), {'c': 'T'});
    },
  );

  test(
    'a carrier copy keeps the raw identity and option tail verbatim',
    () async {
      const raw = '$bookUrl?isSearch=1,{"js":"java.toast(1)"}';
      final original = HtmlBook(
        url: Uri.parse('$bookUrl?isSearch=1'),
        rawAddress: raw,
        preOptionUrl: Uri.parse('$bookUrl?isSearch=1'),
        title: '书',
        variable: variableText({'a': '1'}),
      );
      final copied = original.withVariable(variableText({'a': '2'}));
      expect(copied.rawAddress, raw);
      expect(copied.preOptionUrl, original.preOptionUrl);
      expect(copied.identityAddress, raw);
      expect(copied.title, original.title);

      final round = HtmlBook.fromJson(copied.toJson());
      expect(round.variable, variableText({'a': '2'}));
      expect(round.title, original.title);
    },
  );

  test('a book option script runs once across a deferred analysis', () async {
    const increment =
        "java.put('expansionCount', "
        "String(Number(java.get('expansionCount') || '0') + 1)); void 0";
    final raw = '$bookUrl?isSearch=1,${jsonEncode({'js': increment})}';
    final state = SourceHostState();
    final pageMap = htmlPages();
    final pipeline = HtmlSourcePipeline(
      htmlSource(
        infoScript: '@CSS:h2@text',
        tocScript: '""',
        contentScript: readBoth,
      ),
      pageMap,
      hostState: state,
      deferEntityVariables: true,
    );
    final hit = HtmlBook(
      url: Uri.parse('$bookUrl?isSearch=1'),
      rawAddress: raw,
      preOptionUrl: Uri.parse('$bookUrl?isSearch=1'),
      title: '书',
    );

    final (book, _) = await pipeline.details(hit);
    expect(
      await state.entry(
        origin,
        sourceRuleVariableKey(origin, 'expansionCount'),
      ),
      '1',
      reason: 'the option script transformed the address once',
    );
    expect(book.rawAddress, raw, reason: 'the option tail stays verbatim');
    expect(book.identityAddress, raw);
    expect(pageMap.requests.map((request) => request.url.toString()), [
      '$bookUrl?isSearch=1',
      '$origin/toc',
    ]);
  });

  // #132 finding 2: a search response interpreted as a detail page must return
  // the final book-variable text its own rules wrote, so a search-only write
  // survives into the deferred details pipeline the association opens next.
  for (final json in [false, true]) {
    final label = json ? 'JSON' : 'HTML';

    test(
      '$label search detail fallback carries its final book variable',
      () async {
        final source = <String, dynamic>{
          'bookSourceUrl': origin,
          'bookSourceName': '实体变量源',
          'searchUrl': '/book',
          'bookUrlPattern': '$origin/book',
          'ruleSearch': {
            'bookList': json ? r'$.items' : '@CSS:li',
            'name': json ? r'$.title' : '@CSS:h2@text',
            'bookUrl': json ? r'$.url' : '@CSS:a@href',
          },
          'ruleBookInfo': {
            'name': json ? r'$.title' : '@CSS:h2@text',
            'intro': '@js:book.putVariable("searchWrite","new"); "intro"',
            'tocUrl': json ? r'$.toc' : '@CSS:#toc a@href',
          },
          'ruleToc': {
            'chapterList': json ? r'$.list' : '@CSS:#list li',
            'chapterName': json ? r'$.name' : '@CSS:a@text',
            'chapterUrl': json ? r'$.url' : '@CSS:a@href',
          },
          'ruleContent': {'content': '@js:"正文"'},
        };
        final pageMap = json ? jsonPages() : htmlPages();
        final search = json
            ? JsonSourcePipeline(source, pageMap, deferEntityVariables: true)
            : HtmlSourcePipeline(source, pageMap, deferEntityVariables: true);
        final hits = await search.search('书');
        expect(hits, hasLength(1));
        expect(
          variableMapOf(hits.single.variable),
          {'searchWrite': 'new'},
          reason: 'the source writes while its search response is book info',
        );

        // The carrier seeds a separate deferred details pipeline: the search-only
        // write reaches the details draft without a shared host fallback cache.
        final detailsPipeline = json
            ? JsonSourcePipeline(
                source,
                jsonPages(),
                deferEntityVariables: true,
              )
            : HtmlSourcePipeline(
                source,
                htmlPages(),
                deferEntityVariables: true,
              );
        final (book, _) = await detailsPipeline.details(hits.single);
        expect(variableMapOf(book.variable), {'searchWrite': 'new'});
      },
    );
  }

  /// The absolute TOC address a stored chapter row is keyed by, so a rebuilt
  /// item's address matches the row the previous directory wrote.
  Map<String, dynamic> tocSource() => {
    'bookSourceUrl': origin,
    'bookSourceName': '实体变量源',
    'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
    'ruleToc': {
      'chapterList': r'$.list',
      'chapterName': r'$.name',
      'chapterUrl': r'$.url',
    },
    'ruleContent': {'content': r'$.text'},
  };

  _Pages absoluteTocPages() => _Pages({
    '/book': '{"title":"书","toc":"/toc"}',
    '/toc': jsonEncode({
      'list': [
        {'name': '第一章', 'url': chapterUrl},
        {'name': '第二章', 'url': '$origin/c/2'},
      ],
    }),
    '/c/1': '{"text":"正文"}',
    '/c/2': '{"text":"正文"}',
  });

  test(
    'an ordinary TOC rebuild starts each chapter empty and drops the row value',
    () async {
      final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
      addTearDown(store.close);
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      await store.putBook(
        BooksCompanion.insert(
          id: 'b1',
          title: '书',
          kind: const Value('network'),
          sourceRef: const Value(origin),
          sourceBookUrl: const Value(bookUrl),
        ),
      );
      await store.putChapters('b1', [
        for (final key in [chapterUrl, '$origin/c/2'])
          BookChapter(
            bookId: 'b1',
            chapterKey: key,
            name: '章',
            url: key,
            chapterIndex: 0,
            isVolume: false,
            isVip: false,
            isPay: false,
            variable: variableText({'oldChapter': 'OLD'}),
          ),
      ]);

      final pipeline = JsonSourcePipeline(
        tocSource(),
        absoluteTocPages(),
        hostState: state,
      );
      final (_, chapters) = await pipeline.details(hitWith(null));

      expect(chapters, hasLength(2));
      expect(
        chapters.map((chapter) => chapter.variable),
        everyElement(isNull),
        reason:
            'a rebuilt item keeps only its own writes, not the row it replaces',
      );
      // The ordinary path does not write a row during the analysis: the rebuilt
      // directory is what replaces it.
      expect(
        await store.chapterVariable(origin, bookUrl, chapterUrl),
        variableText({'oldChapter': 'OLD'}),
      );
    },
  );

  test('a deferred TOC rebuild restores a matching stored chapter', () async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    await store.putBook(
      BooksCompanion.insert(
        id: 'b1',
        title: '书',
        kind: const Value('network'),
        sourceRef: const Value(origin),
        sourceBookUrl: const Value(bookUrl),
      ),
    );
    await store.putChapters('b1', [
      BookChapter(
        bookId: 'b1',
        chapterKey: chapterUrl,
        name: '第一章',
        url: chapterUrl,
        chapterIndex: 0,
        isVolume: false,
        isVip: false,
        isPay: false,
        variable: variableText({'oldChapter': 'OLD'}),
      ),
    ]);

    final pipeline = JsonSourcePipeline(
      tocSource(),
      absoluteTocPages(),
      hostState: state,
      deferEntityVariables: true,
    );
    final (_, chapters) = await pipeline.details(hitWith(null));

    expect(chapters, hasLength(2));
    expect(chapters[0].variable, variableText({'oldChapter': 'OLD'}));
    expect(chapters[1].variable, isNull);
    expect(
      await store.chapterVariable(origin, bookUrl, chapterUrl),
      variableText({'oldChapter': 'OLD'}),
      reason: 'a candidate preview never writes the stored row',
    );
  });

  test(
    'a JSON TOC item keeps its own writes and never leaks them to the next',
    () async {
      const addressScript = 'chapter.putVariable(\'token\',\'t1\'); void 0';
      final address = '/c/1,${jsonEncode({'js': addressScript})}';
      // The first item's rule writes while `chapter.url` is still the raw address
      // the directory declared; that write belongs to the item. The address-option
      // script runs for the actual content request instead, and the second item
      // starts empty.
      const tocScript =
          '@js:if (java.get("tocRuns") !== "1") { '
          'java.put("tocRuns","1"); '
          'chapter.putVariable("one", "first"); '
          '} else { '
          'chapter.putVariable("leak", chapter.getVariable("token") || "none"); } ""';
      final pipeline = JsonSourcePipeline(
        jsonSource(
          infoScript: '@js:""',
          tocScript: tocScript,
          contentScript: '@js:"正文"',
        ),
        _Pages({
          '/book': '{"title":"书","toc":"/toc"}',
          '/toc': jsonEncode({
            'list': [
              {'name': '第一章', 'url': address},
              {'name': '第二章', 'url': '/c/2'},
            ],
          }),
          '/c/1': '{"text":"正文"}',
          '/c/2': '{"text":"正文"}',
        }),
        deferEntityVariables: true,
      );

      final (book, chapters) = await pipeline.details(hitWith(null));

      expect(chapters, hasLength(2));
      expect(
        variableMapOf(chapters[0].variable),
        {'one': 'first'},
        reason: 'only the item rule has written when the TOC completes',
      );
      expect(
        variableMapOf(chapters[1].variable),
        {'leak': 'none'},
        reason:
            'the second item starts empty and does not see the first item\'s write',
      );
      final firstBody = await pipeline.chapter(chapters[0], book: book);
      expect(
        variableMapOf(firstBody.chapterVariable),
        {'one': 'first', 'token': 't1'},
        reason: 'the first content request adds its own option variable',
      );
      final secondBody = await pipeline.chapter(chapters[1], book: book);
      expect(
        variableMapOf(secondBody.chapterVariable),
        {'leak': 'none'},
        reason: 'the second content request never inherits the first token',
      );
    },
  );

  /// A TOC whose items the source marks as volumes: each item's own `isVip`
  /// rule writes its title under `v`, and a volume the rules left without a URL
  /// has no page, so its store identity is the frozen `title + index` text.
  Map<String, dynamic> volumeSource(bool json) => {
    'bookSourceUrl': origin,
    'bookSourceName': '实体变量源',
    'ruleBookInfo': {
      'name': json ? r'$.title' : '@CSS:h2@text',
      'tocUrl': json ? r'$.toc' : '@CSS:#toc a@href',
    },
    'ruleToc': {
      'chapterList': json ? r'$.list' : '@CSS:#list li',
      'chapterName': json ? r'$.name' : '@CSS:span@text',
      'chapterUrl': json ? r'$.missing' : '@CSS:a@href',
      'updateTime': json ? r'$.tag' : '@CSS:i@text',
      'isVolume': '@js:true',
      'isVip': '@js:chapter.putVariable("v", chapter.title); false',
    },
    'ruleContent': {'content': '@js:"正文"'},
  };

  _Pages volumePages(bool json) => _Pages({
    '/book': json
        ? '{"title":"书","toc":"/toc"}'
        : '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
    '/toc': json
        ? jsonEncode({
            'list': [
              {'name': 'Volume A', 'tag': 'A'},
              {'name': 'Volume B', 'tag': 'B'},
            ],
          })
        : '<ul id="list">'
              '<li><span>Volume A</span><i>A</i></li>'
              '<li><span>Volume B</span><i>B</i></li>'
              '</ul>',
  });

  for (final json in [false, true]) {
    final label = json ? 'JSON' : 'HTML';

    test(
      '$label deferred volume shortcuts keep their own chapter variables',
      () async {
        final pipeline = json
            ? JsonSourcePipeline(
                volumeSource(json),
                volumePages(json),
                deferEntityVariables: true,
              )
            : HtmlSourcePipeline(
                volumeSource(json),
                volumePages(json),
                deferEntityVariables: true,
              );
        final (book, chapters) = await pipeline.details(hitWith(null));

        expect(chapters, hasLength(2));
        expect(variableMapOf(chapters[0].variable), {'v': 'Volume A'});
        expect(variableMapOf(chapters[1].variable), {'v': 'Volume B'});
        // Both volumes share the TOC page URL; each keeps its own snapshot.
        final first = await pipeline.chapter(chapters[0], book: book);
        final second = await pipeline.chapter(chapters[1], book: book);
        expect(first.text, 'A');
        expect(second.text, 'B');
        expect(variableMapOf(first.chapterVariable), {'v': 'Volume A'});
        expect(variableMapOf(second.chapterVariable), {'v': 'Volume B'});
      },
    );

    test(
      '$label ordinary volume shortcuts keep their own chapter variables',
      () async {
        final state = SourceHostState();
        final pipeline = json
            ? JsonSourcePipeline(
                volumeSource(json),
                volumePages(json),
                hostState: state,
              )
            : HtmlSourcePipeline(
                volumeSource(json),
                volumePages(json),
                hostState: state,
              );
        final (book, chapters) = await pipeline.details(hitWith(null));

        final first = await pipeline.chapter(chapters[0], book: book);
        final second = await pipeline.chapter(chapters[1], book: book);
        expect(first.text, 'A');
        expect(second.text, 'B');
        expect(variableMapOf(first.chapterVariable), {'v': 'Volume A'});
        expect(variableMapOf(second.chapterVariable), {'v': 'Volume B'});
      },
    );

    test(
      '$label a volume and a chapter sharing the fetch URL stay separate',
      () async {
        // The non-volume chapter's own URL is the TOC page, which is the URL the
        // URL-less volume also carries: only their store identities tell them
        // apart.
        final source = <String, dynamic>{
          ...volumeSource(json),
          'ruleToc': {
            'chapterList': json ? r'$.list' : '@CSS:#list li',
            'chapterName': json ? r'$.name' : '@CSS:span@text',
            'chapterUrl': json ? r'$.url' : '@CSS:a@href',
            'updateTime': json ? r'$.tag' : '@CSS:i@text',
            'isVolume': '@js:chapter.title.indexOf("Volume") >= 0',
            'isVip':
                '@js:chapter.title.indexOf("Volume") >= 0 && '
                'chapter.putVariable("vol", chapter.title); false',
          },
          'ruleContent': {
            'content':
                '@js:chapter.putVariable("seen", '
                'chapter.getVariable("vol") || "none"); "正文"',
          },
        };
        final pageMap = _Pages({
          '/book': json
              ? '{"title":"书","toc":"/toc"}'
              : '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
          '/toc': json
              ? jsonEncode({
                  'list': [
                    {'name': 'Volume A', 'tag': 'A'},
                    {'name': 'Chapter C', 'url': '/toc', 'tag': 'C'},
                  ],
                })
              : '<ul id="list">'
                    '<li><span>Volume A</span><i>A</i></li>'
                    '<li><span>Chapter C</span><a href="/toc">c</a><i>C</i></li>'
                    '</ul>',
        });
        final pipeline = json
            ? JsonSourcePipeline(source, pageMap, deferEntityVariables: true)
            : HtmlSourcePipeline(source, pageMap, deferEntityVariables: true);
        final (book, chapters) = await pipeline.details(hitWith(null));

        expect(chapters, hasLength(2));
        expect(chapters[0].rendersTagAsContent, isTrue);
        expect(chapters[1].rendersTagAsContent, isFalse);
        expect('${chapters[0].url}', '${chapters[1].url}');
        expect(chapters[0].storeKey, isNot(chapters[1].storeKey));

        final volume = await pipeline.chapter(chapters[0], book: book);
        final chapter = await pipeline.chapter(chapters[1], book: book);
        expect(volume.text, 'A');
        expect(variableMapOf(volume.chapterVariable), {'vol': 'Volume A'});
        expect(
          variableMapOf(chapter.chapterVariable),
          {'seen': 'none'},
          reason: "the chapter does not see the volume's snapshot",
        );
      },
    );
  }

  test(
    'HTML reopened chapter persists its variable under the saved key',
    () async {
      const fullAddress = '$chapterUrl#part';
      final source = htmlSource(
        infoScript: '@js:""',
        tocScript: '@js:(chapter.putVariable("n","0"), "")',
        contentScript:
            '@js:chapter.putVariable("n", '
            'String(Number(chapter.getVariable("n") || "0") + 1)); '
            'chapter.url + ":" + chapter.getVariable("n")',
      );
      final pages = _Pages({
        '/book': '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
        '/toc': '<ul id="list"><li><a href="/c/1#part">第一章</a></li></ul>',
        '/c/1': '<p>正文</p>',
      });
      final space = await TestSpace.create();
      addTearDown(space.delete);
      var shelf = ShelfService(space.store);
      final initial = HtmlSourcePipeline(
        source,
        pages,
        hostState: shelf.hostState,
      );
      final (book, chapters) = await initial.details(hitWith(null));
      expect(chapters.single.progressKey, chapterUrl);
      expect(chapters.single.persistedAddress, fullAddress);
      await shelf.add(source, book, chapters);
      initial.cancel();

      Future<String> readReopened(ShelfService service) async {
        final entry = (await service.find(origin, book.identityAddress))!;
        final row = entry.chapters.single;
        expect(row.chapterKey, chapterUrl);
        expect(row.url, fullAddress);
        final chapter = SourceChapter.fromAddress(
          row.name,
          row.url!,
          bookUrl: entry.htmlBook.url,
          chapterKey: row.chapterKey,
          variable: row.variable,
        );
        final host = service.hostState;
        final pipeline = HtmlSourcePipeline(source, pages, hostState: host);
        try {
          final (body, changes) = await host.stageReaderVariables(
            () => pipeline.chapter(chapter, book: entry.htmlBook),
          );
          final publish = await service.store.transaction(
            () => host.saveReaderVariables(changes),
          );
          publish();
          return body.text;
        } finally {
          pipeline.cancel();
        }
      }

      shelf = ShelfService(await space.reopen());
      final first = await readReopened(shelf);
      final saved = (await shelf.find(origin, book.identityAddress))!;
      shelf = ShelfService(await space.reopen());
      final second = await readReopened(shelf);
      expect(pages.requests.map((request) => request.url.path), [
        '/book',
        '/toc',
        '/c/1',
        '/c/1',
      ]);
      expect(first, '$fullAddress:1');
      expect(
        (variableMapOf(saved.chapters.single.variable)['n'], second),
        ('1', '$fullAddress:2'),
      );
    },
  );

  // A relative TOC chapter's variable is written under
  // the TOC stage's own key ('/c/1'), while the content stage reads and writes
  // the row key ('$origin/c/1'). The content stage starts from the chapter's own
  // carrier text when — and only when — the row key holds no entry at all.
  for (final json in [false, true]) {
    final label = json ? 'JSON' : 'HTML';

    Map<String, dynamic> relativeSource(String contentScript) => json
        ? jsonSource(
            infoScript: '@js:""',
            tocScript: '@js:(chapter.putVariable("toc","T"), "")',
            contentScript: contentScript,
          )
        : htmlSource(
            infoScript: '@js:""',
            tocScript: '@js:(chapter.putVariable("toc","T"), "")',
            contentScript: contentScript,
          );

    Future<HtmlChapterBody> runContent(
      String contentScript, {
      SourceHostState? hostState,
    }) async {
      final source = relativeSource(contentScript);
      final pipeline = json
          ? JsonSourcePipeline(source, jsonPages(), hostState: hostState)
          : HtmlSourcePipeline(source, htmlPages(), hostState: hostState);
      final (book, chapters) = await pipeline.details(hitWith(null));
      expect(variableMapOf(chapters.single.variable), {'toc': 'T'});
      return pipeline.chapter(chapters.single, book: book);
    }

    test(
      '$label a relative TOC chapter keeps its variable with no content write',
      () async {
        final body = await runContent('@js:"正文"');
        expect(variableMapOf(body.chapterVariable), {'toc': 'T'});
      },
    );

    test('$label a relative TOC chapter merges a content write', () async {
      final body = await runContent(
        '@js:chapter.putVariable("content","C"); "正文"',
      );
      expect(variableMapOf(body.chapterVariable), {'toc': 'T', 'content': 'C'});
    });

    test(
      '$label a relative TOC chapter replaces a same-name key from the TOC value',
      () async {
        final body = await runContent(
          '@js:chapter.putVariable("toc", chapter.getVariable("toc") + "!"); "正文"',
        );
        expect(variableMapOf(body.chapterVariable), {'toc': 'T!'});
      },
    );

    test(
      '$label a relative TOC chapter deletion of the last key is not resurrected',
      () async {
        final body = await runContent(
          '@js:chapter.putVariable("toc", null); "正文"',
        );
        expect(variableMapOf(body.chapterVariable), isEmpty);
      },
    );

    test(
      '$label a relative TOC chapter keeps repeated reads without persistence',
      () async {
        final source = relativeSource(
          '@js:chapter.putVariable("n", '
          'String(Number(chapter.getVariable("n") || "0") + 1)); '
          'chapter.getVariable("n")',
        );
        final pipeline = json
            ? JsonSourcePipeline(source, jsonPages())
            : HtmlSourcePipeline(source, htmlPages());
        final (book, chapters) = await pipeline.details(hitWith(null));
        final first = await pipeline.chapter(chapters.single, book: book);
        final second = await pipeline.chapter(chapters.single, book: book);
        expect(variableMapOf(first.chapterVariable), {'toc': 'T', 'n': '1'});
        expect(variableMapOf(second.chapterVariable), {'toc': 'T', 'n': '2'});
      },
    );

    test(
      '$label an existing null chapter row is not reseeded from the carrier',
      () async {
        final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
        addTearDown(store.close);
        final state = SourceHostState(
          persistence: SpaceHostStatePersistence(store),
        );
        await store.putBook(
          BooksCompanion.insert(
            id: 'b1',
            title: '书',
            kind: const Value('network'),
            sourceRef: const Value(origin),
            sourceBookUrl: const Value(bookUrl),
          ),
        );
        await store.putChapters('b1', [
          BookChapter(
            bookId: 'b1',
            chapterKey: '$origin/c/1',
            name: '第一章',
            url: '$origin/c/1',
            chapterIndex: 0,
            isVolume: false,
            isVip: false,
            isPay: false,
          ),
        ]);

        final body = await runContent('@js:"正文"', hostState: state);

        expect(
          body.chapterVariable,
          isNull,
          reason: 'a present row is authoritative, even with no text',
        );
        expect(
          await store.chapterVariable(origin, bookUrl, '$origin/c/1'),
          isNull,
        );
      },
    );

    test(
      '$label an existing null unwritten entry is not reseeded from the carrier',
      () async {
        final state = SourceHostState();
        await state.putChapterVariable(origin, bookUrl, '$origin/c/1', null);

        final body = await runContent('@js:"正文"', hostState: state);

        expect(
          body.chapterVariable,
          isNull,
          reason: 'a present entry is authoritative, even with no text',
        );
      },
    );

    test('$label an existing unwritten entry wins over the carrier', () async {
      final state = SourceHostState();
      await state.putChapterVariable(
        origin,
        bookUrl,
        '$origin/c/1',
        '{"prior":"P"}',
      );

      final body = await runContent('@js:"正文"', hostState: state);

      expect(variableMapOf(body.chapterVariable), {'prior': 'P'});
    });
  }
}

class _FinishingHtml extends HtmlSourcePipeline {
  _FinishingHtml(
    super.source,
    super.transport,
    SourceHostState state,
    this.finished,
  ) : super(hostState: state);

  final Completer<void> finished;

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    try {
      return await super.chapter(
        chapter,
        book: book,
        nextChapterUrl: nextChapterUrl,
      );
    } finally {
      finished.complete();
    }
  }
}

class _FinishingJson extends JsonSourcePipeline {
  _FinishingJson(
    super.source,
    super.transport,
    SourceHostState state,
    this.finished,
  ) : super(hostState: state);

  final Completer<void> finished;

  @override
  Future<HtmlChapterBody> chapter(
    SourceChapter chapter, {
    HtmlBook? book,
    String? nextChapterUrl,
  }) async {
    try {
      return await super.chapter(
        chapter,
        book: book,
        nextChapterUrl: nextChapterUrl,
      );
    } finally {
      finished.complete();
    }
  }
}

/// Answers one page per path and records every request.
class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages, {this.onRequest, this.beforeResponse});
  final Map<String, String> pages;
  final void Function(Uri)? onRequest;
  final Future<void> Function()? beforeResponse;
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    onRequest?.call(request.url);
    if (beforeResponse != null) await beforeResponse!();
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: _body(request.url),
      url: request.url,
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path);
    requests.add(SourceHttpRequest(method: 'GET', url: url));
    onRequest?.call(url);
    if (beforeResponse != null) await beforeResponse!();
    return _body(url);
  }

  String _body(Uri url) {
    final body = pages[url.path];
    if (body == null) throw StateError('不应请求：$url');
    return body;
  }
}
