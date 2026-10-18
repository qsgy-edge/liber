import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/auto_change_source.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/precise_search.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'native_library.dart';
import 'space_test_support.dart';

/// #132 association: the explicit re-search recovery of a stored historical
/// relative network-book identity, driven through the real search → details/TOC
/// → shelf path, and the entity-variable rules the switch publishes.
///
/// The stored row keeps its id, order, group, settings, metadata and progress;
/// the same-source seed keeps old-only variable keys, replaces same-key values
/// and honours a later deletion; a cross-source candidate replaces the old
/// source's variables (a missing new value clears them). A failed, previewed or
/// colliding candidate leaves every stored row exactly as it was.
const origin = 'https://origin.test';
const cdn = 'https://cdn.test';
const candidateOrigin = 'https://other.test';

const name = 'Book';
const author = 'Writer';

/// The text a write stores, the frozen `GSON.toJson(variableMap)` shape.
String variableText(Map<String, String?> map) =>
    JsonEncoder.withIndent('  ').convert({
      for (final entry in map.entries)
        if (entry.value != null) entry.key: entry.value,
    });

/// A JSON source whose info and TOC scripts write entity variables, so a
/// deferred candidate analysis carries real writes.
Map<String, dynamic> sourceJson(
  String sourceUrl, {
  String infoScript = '',
  String tocScript = '',
  String contentScript = '',
}) => {
  'bookSourceUrl': sourceUrl,
  'bookSourceName': '源',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.title',
    'author': r'$.author',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.title', 'intro': infoScript, 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
    'updateTime': tocScript,
  },
  'ruleContent': {'content': contentScript},
};

class _Route {
  const _Route(this.body, {this.responseUrl});
  final String body;
  final String? responseUrl;
}

/// Answers one route per request URL and records every request. A route may
/// report a different response URL, which is how a redirected search is driven.
class _Site implements BookSourceTransport, SourceHttpTransport {
  _Site(this.routes);
  final Map<String, _Route> routes;
  final requests = <String>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request.url.toString());
    final route = routes[request.url.toString()];
    if (route == null) throw StateError('unexpected request: ${request.url}');
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: route.body,
      url: Uri.parse(route.responseUrl ?? request.url.toString()),
    );
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(path);
    final route = routes[path];
    if (route == null) throw StateError('unexpected request: $path');
    return route.body;
  }
}

void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);

  late TestSpace space;
  late SpaceStore store;
  late ShelfService shelf;

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    shelf = ShelfService(store);
  });
  tearDown(() => space.delete());

  List<SourceChapter> storedChapters() => [
    for (var i = 0; i < 3; i++)
      SourceChapter('第${i + 1}章', Uri.parse('$origin/chapter/$i')),
  ];

  /// A stored historical relative row: the identity verbatim (option tail and
  /// all, no recorded base), a group, a per-book setting, a position and a
  /// variable map.
  Future<ShelfEntry> storedRelativeBook({String? variable}) async {
    const relative = '/book/b29?isSearch=1,{"method":"GET"}';
    await shelf.add(
      sourceJson(origin),
      HtmlBook(
        url: Uri.parse(relative),
        rawAddress: relative,
        title: name,
        author: author,
      ),
      storedChapters(),
    );
    final entry = (await shelf.find(origin, relative))!;
    if (variable != null) {
      await store.putBookVariable(origin, relative, variable);
      return (await shelf.find(origin, relative))!;
    }
    return entry;
  }

  test(
    'same-source historical relative row recovers through search -> details -> shelf',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O', 'shared': 'old', 'del': 'D'}),
      );
      final group = await store.ensureGroup('在追');
      await store.setBookGroups(before.id, [group.id]);
      await store.putSetting('convert', 't2s', bookId: before.id);
      await shelf.saveProgress(
        before.id,
        chapterKey: '$origin/chapter/1',
        chapterIndex: 1,
        textOffset: 37,
      );

      // The search response is redirected to the CDN base, so the candidate's
      // resolved identity is the redirect target, not the source origin.
      final searchSite = _Site({
        '$origin/search?key=$name': const _Route(
          '{"items":[{"title":"Book","author":"Writer","url":"/book/b29"}]}',
          responseUrl: '$cdn/search?key=$name',
        ),
      });
      final search = PreciseSearch(
        name: name,
        author: author,
        openPipeline: (source) => JsonSourcePipeline(source, searchSite),
      );
      final outcome = await search.searchSource(sourceJson(origin));
      expect(outcome.failure, isNull);
      final hit = outcome.hits.single;
      expect(hit.exact, isTrue);
      expect(hit.book.identityAddress, '$cdn/book/b29');

      final prepared = shelf.associationCandidate(
        before,
        sourceJson(origin),
        hit.book,
      );
      expect(
        prepared.variable,
        variableText({'old': 'O', 'shared': 'old', 'del': 'D'}),
        reason: 'the same-source seed keeps the stored text verbatim',
      );

      final detailsSite = _Site({
        '$cdn/book/b29': const _Route('{"title":"Book","toc":"/toc/b29"}'),
        '$cdn/toc/b29': const _Route(
          '{"list":[{"name":"楔子","url":"/c/0"},'
          '{"name":"第1章","url":"/c/1"},'
          '{"name":"第2章","url":"/c/2"},'
          '{"name":"第3章","url":"/c/3"}]}',
        ),
      });
      final pipeline = JsonSourcePipeline(
        sourceJson(origin),
        detailsSite,
        deferEntityVariables: true,
      );
      final (details, newChapters) = await pipeline.details(prepared);
      expect(detailsSite.requests, ['$cdn/book/b29', '$cdn/toc/b29']);

      final switched = await shelf.switchSource(
        before.id,
        sourceJson(origin),
        details,
        newChapters,
      );

      expect(switched.id, before.id, reason: 'D2：换源不重写书的身份');
      expect(switched.sourceRef, origin);
      expect(switched.book.sourceBookUrl, '$cdn/book/b29');
      expect(switched.book.bookOrder, before.book.bookOrder);
      expect((await store.groupsOf(before.id)).map((row) => row.name), ['在追']);
      expect(await store.setting('convert', bookId: before.id), 't2s');
      expect(switched.chapterIndex, 2, reason: '第2章在新目录的下标 2');
      expect(switched.chapterKey, '$cdn/c/2');
      expect(switched.textOffset, 37, reason: '偏移原样带过去（冻结的 durChapterPos）');
      expect((await shelf.onlineShelf()).length, 1, reason: '还是一行');
      expect(
        await shelf.find(origin, '/book/b29?isSearch=1,{"method":"GET"}'),
        isNull,
        reason: '旧相对身份不再单独留一行',
      );
    },
  );

  test(
    'same-source seed keeps old-only keys, replaces same-key values and honours a deletion',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O', 'shared': 'old', 'del': 'D'}),
      );

      final prepared = shelf.associationCandidate(
        before,
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/b29'),
          rawAddress: '$origin/book/b29',
          preOptionUrl: Uri.parse('$origin/book/b29'),
          title: name,
          variable: variableText({'shared': 'search', 'added': 'A'}),
        ),
      );
      expect(
        variableMapOf(prepared.variable),
        {'old': 'O', 'shared': 'search', 'del': 'D', 'added': 'A'},
        reason: 'the search map overlays the stored map, old-only keys survive',
      );

      final site = _Site({
        '$origin/book/b29': const _Route('{"title":"Book","toc":"/toc/b29"}'),
        '$origin/toc/b29': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
      });
      final pipeline = JsonSourcePipeline(
        sourceJson(
          origin,
          infoScript:
              '@js:book.putVariable("shared","new"); '
              'book.putVariable("del",null); book.putVariable("added",null); ""',
          tocScript: '@js:(chapter.putVariable("c","T"), "")',
        ),
        site,
        deferEntityVariables: true,
      );
      final (details, chapters) = await pipeline.details(prepared);
      final switched = await shelf.switchSource(
        before.id,
        sourceJson(origin),
        details,
        chapters,
      );

      expect(
        variableMapOf(
          await store.bookVariable(origin, switched.book.sourceBookUrl!),
        ),
        {'old': 'O', 'shared': 'new'},
        reason:
            'old-only retained, same-key replaced, later deletion not restored',
      );
    },
  );

  test(
    'cross-source candidate drops the old variables and takes the new chapter variables',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O'}),
      );
      await store.putChapterVariable(
        origin,
        '/book/b29?isSearch=1,{"method":"GET"}',
        '$origin/chapter/0',
        variableText({'oldc': 'X'}),
      );

      final prepared = shelf.associationCandidate(
        before,
        sourceJson(candidateOrigin),
        HtmlBook(
          url: Uri.parse('$candidateOrigin/book/1'),
          rawAddress: '$candidateOrigin/book/1',
          preOptionUrl: Uri.parse('$candidateOrigin/book/1'),
          title: name,
        ),
      );
      expect(
        prepared.variable,
        isNull,
        reason: 'cross-source starts from the new map only',
      );

      final site = _Site({
        '$candidateOrigin/book/1': const _Route(
          '{"title":"Book","toc":"/toc/1"}',
        ),
        '$candidateOrigin/toc/1': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
      });
      final pipeline = JsonSourcePipeline(
        sourceJson(
          candidateOrigin,
          tocScript: '@js:(chapter.putVariable("c","T"), "")',
        ),
        site,
        deferEntityVariables: true,
      );
      final (details, chapters) = await pipeline.details(prepared);
      final switched = await shelf.switchSource(
        before.id,
        sourceJson(candidateOrigin),
        details,
        chapters,
      );

      expect(
        await store.bookVariable(candidateOrigin, switched.book.sourceBookUrl!),
        isNull,
        reason: 'the old source\'s book variables are not carried across',
      );
      expect(
        await store.chapterVariable(
          candidateOrigin,
          switched.book.sourceBookUrl!,
          '$candidateOrigin/c/1',
        ),
        variableText({'c': 'T'}),
        reason: 'new chapter variables persist',
      );
    },
  );

  test(
    'a destination identity already on the shelf is previewed without mutating it',
    () async {
      // A stored destination row on the same source and identity the candidate
      // resolves to: a deferred preview must leave it exactly as it was.
      final targetSource = sourceJson(origin);
      await store.putSourceJson(targetSource);
      await store.putBook(
        BooksCompanion.insert(
          id: 'target',
          kind: const Value('network'),
          sourceRef: const Value(origin),
          sourceBookUrl: const Value('$origin/book/b29'),
          title: name,
          variable: Value(variableText({'stored': 'S'})),
        ),
      );
      await store.putChapters('target', [
        BookChapter(
          bookId: 'target',
          chapterKey: '$origin/c/1',
          name: '第1章',
          url: '$origin/c/1',
          chapterIndex: 0,
          isVolume: false,
          isVip: false,
          isPay: false,
          variable: variableText({'c': 'stored'}),
        ),
      ]);

      final before = await storedRelativeBook(
        variable: variableText({'old': 'O'}),
      );
      final prepared = shelf.associationCandidate(
        before,
        targetSource,
        HtmlBook(
          url: Uri.parse('$origin/book/b29'),
          rawAddress: '$origin/book/b29',
          preOptionUrl: Uri.parse('$origin/book/b29'),
          title: name,
        ),
      );
      final site = _Site({
        '$origin/book/b29': const _Route('{"title":"Book","toc":"/toc/b29"}'),
        '$origin/toc/b29': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
      });
      final pipeline = JsonSourcePipeline(
        targetSource,
        site,
        deferEntityVariables: true,
      );
      final (details, chapters) = await pipeline.details(prepared);

      // The preview returned its own snapshots...
      expect(details.variable, variableText({'old': 'O'}));
      expect(chapters.single.variable, isNull);
      // ...while the stored destination row did not move.
      expect(
        await store.bookVariable(origin, '$origin/book/b29'),
        variableText({'stored': 'S'}),
      );
      expect(
        await store.chapterVariable(origin, '$origin/book/b29', '$origin/c/1'),
        variableText({'c': 'stored'}),
      );
    },
  );

  test(
    'a destination collision refuses the switch and leaves both rows untouched',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O'}),
      );
      await shelf.add(
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/b29'),
          rawAddress: '$origin/book/b29',
          title: name,
          variable: variableText({'stored': 'S'}),
        ),
        [SourceChapter('第1章', Uri.parse('$origin/c/1'))],
      );

      await expectLater(
        () => shelf.switchSource(
          before.id,
          sourceJson(origin),
          HtmlBook(
            url: Uri.parse('$origin/book/b29'),
            rawAddress: '$origin/book/b29',
            title: name,
            variable: variableText({'new': 'N'}),
          ),
          [SourceChapter('第1章', Uri.parse('$origin/c/1'))],
        ),
        throwsA(isA<StateError>()),
      );

      final stillRelative = (await store.bookById(before.id))!;
      expect(
        stillRelative.sourceBookUrl,
        '/book/b29?isSearch=1,{"method":"GET"}',
      );
      expect(
        await store.bookVariable(
          origin,
          '/book/b29?isSearch=1,{"method":"GET"}',
        ),
        variableText({'old': 'O'}),
      );
      expect(
        await store.bookVariable(origin, '$origin/book/b29'),
        variableText({'stored': 'S'}),
      );
      expect((await shelf.onlineShelf()).length, 2, reason: '两边都还在');
    },
  );

  test('the switched variables survive a store reopen', () async {
    final before = await storedRelativeBook(
      variable: variableText({'old': 'O'}),
    );
    final site = _Site({
      '$origin/book/b29': const _Route('{"title":"Book","toc":"/toc/b29"}'),
      '$origin/toc/b29': const _Route('{"list":[{"name":"第1章","url":"/c/1"}]}'),
    });
    final pipeline = JsonSourcePipeline(
      sourceJson(
        origin,
        infoScript: '@js:book.putVariable("kept","K"); ""',
        tocScript: '@js:(chapter.putVariable("c","T"), "")',
      ),
      site,
      deferEntityVariables: true,
    );
    final (details, chapters) = await pipeline.details(
      shelf.associationCandidate(
        before,
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/b29'),
          rawAddress: '$origin/book/b29',
          preOptionUrl: Uri.parse('$origin/book/b29'),
          title: name,
        ),
      ),
    );
    await shelf.switchSource(before.id, sourceJson(origin), details, chapters);

    final reopened = await space.reopen();
    final reopenedShelf = ShelfService(reopened);
    final entry = (await reopenedShelf.onlineShelf()).single;
    expect(entry.book.sourceBookUrl, '$origin/book/b29');
    expect(
      await reopened.bookVariable(origin, '$origin/book/b29'),
      variableText({'old': 'O', 'kept': 'K'}),
    );
    expect(
      await reopened.chapterVariable(origin, '$origin/book/b29', '$origin/c/1'),
      variableText({'c': 'T'}),
    );
  });

  test('a failed candidate analysis leaves the stored row untouched', () async {
    final before = await storedRelativeBook(
      variable: variableText({'old': 'O'}),
    );
    await shelf.saveProgress(
      before.id,
      chapterKey: '$origin/chapter/1',
      chapterIndex: 1,
      textOffset: 37,
    );
    final prepared = shelf.associationCandidate(
      before,
      sourceJson(origin),
      HtmlBook(
        url: Uri.parse('$origin/book/b29'),
        rawAddress: '$origin/book/b29',
        preOptionUrl: Uri.parse('$origin/book/b29'),
        title: name,
      ),
    );
    // The details page answers and its info script writes, but the TOC request
    // has no route, so the analysis fails after the write.
    final site = _Site({
      '$origin/book/b29': const _Route('{"title":"Book","toc":"/toc/b29"}'),
    });
    final pipeline = JsonSourcePipeline(
      sourceJson(origin, infoScript: '@js:book.putVariable("wrote","W"); ""'),
      site,
      deferEntityVariables: true,
    );

    await expectLater(pipeline.details(prepared), throwsA(isA<StateError>()));

    expect(
      await store.bookVariable(origin, '/book/b29?isSearch=1,{"method":"GET"}'),
      variableText({'old': 'O'}),
      reason: 'the deferred write never reached the stored row',
    );
    final still = (await store.bookById(before.id))!;
    expect(still.sourceBookUrl, '/book/b29?isSearch=1,{"method":"GET"}');
    expect((await store.progressOf(before.id))!.textOffset, 37);
  });

  test(
    'same-source recovery preserves the candidate\'s raw option tail in the identity',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O'}),
      );
      const candidateRaw = '$origin/book/b29?isSearch=1,{"method":"GET"}';
      final prepared = shelf.associationCandidate(
        before,
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/b29?isSearch=1'),
          rawAddress: candidateRaw,
          preOptionUrl: Uri.parse('$origin/book/b29?isSearch=1'),
          title: name,
        ),
      );
      expect(prepared.identityAddress, candidateRaw);

      final site = _Site({
        '$origin/book/b29?isSearch=1': const _Route(
          '{"title":"Book","toc":"/toc/b29"}',
        ),
        '$origin/toc/b29': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
      });
      final pipeline = JsonSourcePipeline(
        sourceJson(origin),
        site,
        deferEntityVariables: true,
      );
      final (details, chapters) = await pipeline.details(prepared);
      expect(site.requests, [
        '$origin/book/b29?isSearch=1',
        '$origin/toc/b29',
      ], reason: 'the fetch parses the option tail off the identity');

      final switched = await shelf.switchSource(
        before.id,
        sourceJson(origin),
        details,
        chapters,
      );
      expect(switched.book.sourceBookUrl, candidateRaw);
    },
  );

  test(
    'the automatic switch publishes the content probe\'s final book and chapter variables',
    () async {
      // A book whose source row is gone, on a source whose candidate writes a
      // book variable in details and both a book and a chapter variable in the
      // content probe.
      await shelf.add(
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/1'),
          rawAddress: '$origin/book/1',
          title: name,
          author: author,
        ),
        [SourceChapter('第1章', Uri.parse('$origin/c/0'))],
      );
      await store.putBookVariable(
        origin,
        '$origin/book/1',
        variableText({'old': 'O'}),
      );
      await shelf.deleteSource(origin);
      final book = (await shelf.find(origin, '$origin/book/1'))!;
      expect(book.sourceMissing, isTrue);

      final candidateSource = sourceJson(
        candidateOrigin,
        infoScript: '@js:book.putVariable("info","I"); ""',
        tocScript: '@js:(chapter.putVariable("toc","T"), "")',
        contentScript:
            '@js:book.putVariable("probed","P"); '
            'chapter.putVariable("probedc","PC"); "正文"',
      );
      await store.putSourceJson(candidateSource);

      final site = _Site({
        '$candidateOrigin/search?key=$name': const _Route(
          '{"items":[{"title":"Book","author":"Writer","url":"/book/1"}]}',
        ),
        '$candidateOrigin/book/1': const _Route(
          '{"title":"Book","toc":"/toc/1"}',
        ),
        '$candidateOrigin/toc/1': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
        '$candidateOrigin/c/1': const _Route('{"text":"正文"}'),
      });

      final result = await autoChangeSource(
        service: shelf,
        book: book,
        openPipeline: (source) => JsonSourcePipeline(source, site),
        openDeferredPipeline: (source) =>
            JsonSourcePipeline(source, site, deferEntityVariables: true),
      );

      expect(result.ran, isTrue);
      final switched = result.switched!;
      expect(switched.id, book.id);
      expect(switched.sourceRef, candidateOrigin);
      expect(
        variableMapOf(
          await store.bookVariable(
            candidateOrigin,
            switched.book.sourceBookUrl!,
          ),
        ),
        {'info': 'I', 'probed': 'P'},
        reason: 'the content probe\'s book write survives the switch',
      );
      expect(
        variableMapOf(
          await store.chapterVariable(
            candidateOrigin,
            switched.book.sourceBookUrl!,
            '$candidateOrigin/c/1',
          ),
        ),
        {'toc': 'T', 'probedc': 'PC'},
        reason: 'the content probe\'s chapter write survives the switch',
      );
    },
  );

  test(
    'the automatic search is deferred: a fallback detail page never writes the stored destination',
    () async {
      // The book being switched: its source is gone.
      await shelf.add(
        sourceJson(origin),
        HtmlBook(
          url: Uri.parse('$origin/book/1'),
          rawAddress: '$origin/book/1',
          title: name,
          author: author,
        ),
        [SourceChapter('第1章', Uri.parse('$origin/c/0'))],
      );
      await store.putBookVariable(
        origin,
        '$origin/book/1',
        variableText({'old': 'O'}),
      );
      await shelf.deleteSource(origin);
      final book = (await shelf.find(origin, '$origin/book/1'))!;
      expect(book.sourceMissing, isTrue);

      // A stored destination row at the identity the candidate's search
      // fallback describes: an ordinary search would write it before any
      // candidate is accepted.
      final candidateSource = <String, dynamic>{
        ...sourceJson(candidateOrigin),
        'searchUrl': '/book/1',
        'bookUrlPattern': '$candidateOrigin/book/1',
        'ruleBookInfo': {
          'name': r'$.title',
          'author': r'$.author',
          'intro': '@js:book.putVariable("searchWrite","new"); ""',
          'tocUrl': r'$.toc',
        },
      };
      await store.putSourceJson(candidateSource);
      await store.putBook(
        BooksCompanion.insert(
          id: 'target',
          kind: const Value('network'),
          sourceRef: const Value(candidateOrigin),
          sourceBookUrl: const Value('$candidateOrigin/book/1'),
          title: name,
          variable: Value(variableText({'persisted': 'P'})),
        ),
      );

      // The search response is the detail page; its TOC route is absent, so the
      // candidate fails before acceptance and nothing may be published.
      final site = _Site({
        '$candidateOrigin/book/1': const _Route(
          '{"title":"Book","author":"Writer","toc":"/toc/1"}',
        ),
      });

      var ordinaryOpens = 0;
      var deferredOpens = 0;
      final result = await autoChangeSource(
        service: shelf,
        book: book,
        openPipeline: (source) {
          ordinaryOpens++;
          return JsonSourcePipeline(source, site);
        },
        openDeferredPipeline: (source) {
          deferredOpens++;
          return JsonSourcePipeline(source, site, deferEntityVariables: true);
        },
      );

      expect(result.ran, isTrue);
      expect(result.switched, isNull);
      expect(
        ordinaryOpens,
        0,
        reason: 'the automatic search is a candidate stage and runs deferred',
      );
      expect(deferredOpens, greaterThanOrEqualTo(2));
      expect(
        await store.bookVariable(candidateOrigin, '$candidateOrigin/book/1'),
        variableText({'persisted': 'P'}),
        reason:
            'a search fallback write before acceptance must not reach the row',
      );
      expect(
        await store.bookVariable(origin, '$origin/book/1'),
        variableText({'old': 'O'}),
      );
    },
  );

  test(
    'an accepted empty replacement does not resurrect a prior unwritten value',
    () async {
      final before = await storedRelativeBook(
        variable: variableText({'old': 'O'}),
      );
      final site = _Site({
        '$candidateOrigin/book/1': const _Route(
          '{"title":"Book","toc":"/toc/1"}',
        ),
        '$candidateOrigin/toc/1': const _Route(
          '{"list":[{"name":"第1章","url":"/c/1"}]}',
        ),
        '$candidateOrigin/c/1': const _Route('{"text":"正文"}'),
      });
      // An ordinary unsaved details view has no row to receive its write, so
      // the value stays on the space's shared host surface.
      final prior = JsonSourcePipeline(
        sourceJson(
          candidateOrigin,
          infoScript: '@js:book.putVariable("discarded","STALE"); ""',
        ),
        site,
        hostState: shelf.hostState,
      );
      await prior.details(
        HtmlBook(
          url: Uri.parse('$candidateOrigin/book/1'),
          rawAddress: '$candidateOrigin/book/1',
          title: name,
          author: author,
        ),
      );
      expect(
        await store.bookByNaturalKey(
          candidateOrigin,
          '$candidateOrigin/book/1',
        ),
        isNull,
      );
      expect(
        variableMapOf(
          await shelf.hostState.bookVariable(
            candidateOrigin,
            '$candidateOrigin/book/1',
          ),
        ),
        {'discarded': 'STALE'},
      );

      // A cross-source candidate carries no book variables; the accepted switch
      // writes the row's empty value.
      final candidateSource = sourceJson(candidateOrigin);
      final prepared = shelf.associationCandidate(
        before,
        candidateSource,
        HtmlBook(
          url: Uri.parse('$candidateOrigin/book/1'),
          rawAddress: '$candidateOrigin/book/1',
          preOptionUrl: Uri.parse('$candidateOrigin/book/1'),
          title: name,
        ),
      );
      final candidate = JsonSourcePipeline(
        candidateSource,
        site,
        hostState: shelf.hostState,
        deferEntityVariables: true,
      );
      final (details, chapters) = await candidate.details(prepared);
      expect(details.variable, isNull);
      await shelf.switchSource(before.id, candidateSource, details, chapters);
      expect(
        await store.bookVariable(candidateOrigin, '$candidateOrigin/book/1'),
        isNull,
      );

      // The reading source reads the row, not the unwritten value the row
      // replaced.
      final reader = JsonSourcePipeline(
        sourceJson(
          candidateOrigin,
          contentScript: '@js:book.getVariable("discarded") || "CLEAN"',
        ),
        site,
        hostState: shelf.hostState,
      );
      final body = await reader.chapter(chapters.single, book: details);
      expect(
        body.text,
        'CLEAN',
        reason: 'the accepted final null replaces all candidate book variables',
      );
    },
  );
}
