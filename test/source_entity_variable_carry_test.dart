import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';

import 'native_library.dart';

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

    // The candidate carries its own text...
    expect(variableMapOf(book.variable), {'seed': 'old', 'written': 'B'});
    expect(variableMapOf(chapters.single.variable), {'c': 'T'});
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

      final (_, chapters) = await pipeline.details(hitWith(null));
      expect(variableMapOf(chapters.single.variable), {
        'addressToken': 'ready',
      });
      expect(
        await state.entry(origin, sourceRuleVariableKey(origin, 'addressRuns')),
        '1',
        reason: 'the address option script ran once',
      );
    },
  );

  test('HTML keeps its named refusal for a chapter address js option', () async {
    final pageMap = _Pages({
      '/book': '<h2>书</h2><div id="toc"><a href="/toc">目录</a></div>',
      '/toc':
          '<ul id="list"><li><a href="/c/1,{&#34;js&#34;:&#34;void 0&#34;}">第一章</a></li></ul>',
    });
    final pipeline = HtmlSourcePipeline(
      htmlSource(
        infoScript: '@CSS:h2@text',
        tocScript: '""',
        contentScript: readBoth,
      ),
      pageMap,
      deferEntityVariables: true,
    );

    await expectLater(
      pipeline.details(hitWith(null)),
      throwsA(
        isA<UnsupportedError>().having(
          (error) => error.message,
          'message',
          '暂不支持章节地址的 URL 选项',
        ),
      ),
    );
  });

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

  test('a deferred TOC rebuild also starts each chapter empty', () async {
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
    expect(chapters.map((chapter) => chapter.variable), everyElement(isNull));
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
      // the directory declared; the address-option script then writes again. Both
      // belong to that item. The second item starts empty.
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
          contentScript: '@js:""',
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

      final (_, chapters) = await pipeline.details(hitWith(null));

      expect(chapters, hasLength(2));
      expect(
        variableMapOf(chapters[0].variable),
        {'one': 'first', 'token': 't1'},
        reason: 'the item rule write and the address-option write both stay',
      );
      expect(
        variableMapOf(chapters[1].variable),
        {'leak': 'none'},
        reason:
            'the second item starts empty and does not see the first item\'s write',
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
}

/// Answers one page per path and records every request.
class _Pages implements BookSourceTransport, SourceHttpTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
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
    return _body(url);
  }

  String _body(Uri url) {
    final body = pages[url.path];
    if (body == null) throw StateError('不应请求：$url');
    return body;
  }
}
