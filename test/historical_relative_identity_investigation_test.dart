// The `[#132]` lines are the raw evidence this investigation records (the
// requests the product sent and the exact error it raised); the lane log is the
// artifact that carries them, so `avoid_print` is suppressed for this harness.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

/// #132 investigation — a *stored historical relative* book identity driven
/// through the real product chain.
///
/// A historical relative identity is a `books.source_book_url` whose target has
/// no scheme (e.g. `/book/b29?isSearch=1,{"method":"GET"}`). #99 preserved it
/// verbatim; this file records what happens when `ShelfService` reconstructs
/// such a row and the JSON pipeline reopens it.
///
/// These are investigation tests, not a recovery implementation: nothing here
/// rewrites a stored row or invents a base. The only assertions are about the
/// observed requests, the observed error, and that no stored state moved.

const origin = 'https://origin.test';
const sourceUrl = origin;
const redirectBase = 'https://cdn.test';

/// A minimal JSON source with book-info and TOC rules, enough to reach the
/// details and TOC stages.
Map<String, dynamic> _jsonSource(String base) => {
  'bookSourceUrl': base,
  'bookSourceName': 'Relative source',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.title',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.name',
    'chapterUrl': r'$.url',
  },
};

/// One route: the body and, when the response is redirected, the URL the
/// response reports.
class _Route {
  const _Route(this.body, {this.responseUrl});
  final String body;
  final String? responseUrl;
}

/// Records every request text the product sends, keyed by the URL it asked
/// for, and answers the configured body/response-URL.
class _RecordingTransport implements SourceHttpTransport, BookSourceTransport {
  _RecordingTransport(this.routes);
  final Map<String, _Route> routes;
  final requests = <String>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request.url.toString());
    final route = routes[request.url.toString()];
    if (route == null) {
      throw StateError('unexpected request: ${request.url}');
    }
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
  late SpaceStore store;
  late ShelfService shelf;

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
  });
  tearDown(() => store.close());

  test('historical relative carrier: ShelfService reconstruction drives a real '
      'details request, then fails resolving the relative TOC base', () async {
    const relative = '/book/b29?isSearch=1,{"method":"GET"}';
    final source = _jsonSource(origin);
    final chapters = [SourceChapter('Chapter', Uri.parse('$origin/chapter'))];

    // Stored exactly as the retired import/legacy path stores it: the
    // relative identity verbatim, no pre-option base.
    final historical = HtmlBook.fromJson({
      'url': relative,
      'title': 'Historical',
    });
    await shelf.add(source, historical, chapters);
    final entry = (await shelf.find(sourceUrl, relative))!;

    // Reconstructed the way a shelf page hands a row to a pipeline.
    final rebuilt = entry.htmlBook;
    expect(rebuilt.rawAddress, relative);
    expect(
      rebuilt.preOptionUrl,
      isNull,
      reason: 'The shelf row has no persisted pre-option base',
    );
    expect(rebuilt.identityAddress, relative);

    final transport = _RecordingTransport({
      '$origin/book/b29?isSearch=1': const _Route(
        '{"title":"Historical","toc":"/toc/b29"}',
      ),
      '$origin/toc/b29': const _Route(
        '{"list":[{"name":"Chapter","url":"/c/1"}]}',
      ),
    });
    final pipeline = JsonSourcePipeline(source, transport);

    Object? error;
    try {
      await pipeline.details(rebuilt);
    } catch (caught) {
      error = caught;
    }

    print('[#132] details requests = ${transport.requests}');
    print(
      '[#132] trace = '
      '${[for (final e in pipeline.trace) '${e.stage.name}:${e.path}']}',
    );
    print('[#132] observed error = ${error.runtimeType}: $error');

    expect(error, isA<FormatException>());
    expect((error! as FormatException).message, 'Invalid source URL');
    // A real details request ran; the failure is the later relative TOC base
    // resolution, not a zero-request failure.
    expect(transport.requests, ['$origin/book/b29?isSearch=1']);
    expect(pipeline.trace.map((entry) => entry.stage), [
      BookSourceStage.bookInfo,
    ]);
    expect(pipeline.trace.single.path, '$origin/book/b29?isSearch=1');
    expect(await store.shelf(), hasLength(1));
  });

  test(
    'the retained row and its import payload carry no original analysis base',
    () async {
      const relative = '/book/b29?isSearch=1,{"method":"GET"}';
      final source = _jsonSource(origin);

      // (a) the shelf write path.
      final historical = HtmlBook.fromJson({
        'url': relative,
        'title': 'Historical',
      });
      await shelf.add(source, historical);
      final entry = (await shelf.find(sourceUrl, relative))!;
      final row = (await store.bookById(entry.id))!;
      print('[#132] shelf row raw = ${row.raw}');
      expect(row.sourceBookUrl, relative);
      expect(row.raw, isNot(contains(origin)));
      expect(row.raw, isNot(contains(redirectBase)));

      // (b) the retired import payload the issue calls out.
      final home = await Directory.systemTemp.createTemp('liber-132-legacy-');
      addTearDown(() => home.delete(recursive: true));
      await File('${home.path}/online_reading.json').writeAsString(
        jsonEncode({
          'version': 2,
          'records': [
            {
              'source': source,
              'book': {'url': relative, 'title': 'Imported'},
              'chapterUrl': '$origin/chapter',
              'textOffset': 37,
              'chapters': [
                {'name': 'Chapter', 'url': '$origin/chapter'},
              ],
              'shelved': true,
            },
          ],
        }),
      );
      await LegacyImport(home: home).run(store);
      final imported = (await store.bookByNaturalKey(sourceUrl, relative))!;
      print('[#132] imported raw = ${imported.raw}');
      expect(imported.sourceBookUrl, relative);
      expect(imported.raw, isNot(contains(origin)));
      expect(imported.raw, isNot(contains(redirectBase)));
    },
  );

  test(
    'source origin is not the identity base: a redirected search resolves the '
    'book address against the response URL, which the stored row loses',
    () async {
      const relative = '/book/b29?isSearch=1,{"method":"GET"}';
      final source = _jsonSource(origin);

      // The search response itself is redirected: the product follows the
      // response URL, exactly as the frozen binds `baseUrl = res.url`.
      final redirectTransport = _RecordingTransport({
        '$origin/search?key=b29': const _Route(
          '{"items":[{"title":"Book","url":"/book/b29"}]}',
          responseUrl: '$redirectBase/search?key=b29',
        ),
        '$redirectBase/book/b29': const _Route(
          '{"title":"Book","toc":"/toc/b29"}',
        ),
        '$redirectBase/toc/b29': const _Route(
          '{"list":[{"name":"Chapter","url":"/c/1"}]}',
        ),
      });
      final search = JsonSourcePipeline(source, redirectTransport);
      final hit = (await search.search('b29')).single;
      print('[#132] redirect hit.url = ${hit.url}');
      print('[#132] redirect hit.identityAddress = ${hit.identityAddress}');
      // The identity base is the response URL (cdn), not the source origin.
      expect(hit.url.toString(), '$redirectBase/book/b29');
      expect(hit.preOptionUrl.toString(), '$redirectBase/book/b29');
      expect(hit.identityAddress, '$redirectBase/book/b29');
      final (_, _) = await search.details(hit);
      expect(redirectTransport.requests, [
        '$origin/search?key=b29',
        '$redirectBase/book/b29',
        '$redirectBase/toc/b29',
      ]);

      // A stored row with the same *relative* text has no recorded base. A
      // fresh pipeline resolves its details request against the source origin,
      // which is a heuristic and differs from the original response base.
      final lostBaseTransport = _RecordingTransport({
        '$origin/book/b29?isSearch=1': const _Route(
          '{"title":"Historical","toc":"/toc/b29"}',
        ),
        '$origin/toc/b29': const _Route(
          '{"list":[{"name":"Chapter","url":"/c/1"}]}',
        ),
      });
      final reopened = JsonSourcePipeline(source, lostBaseTransport);
      Object? error;
      try {
        await reopened.details(
          HtmlBook(
            url: Uri.parse(relative),
            rawAddress: relative,
            title: 'Historical',
          ),
        );
      } catch (caught) {
        error = caught;
      }
      print('[#132] lost-base requests = ${lostBaseTransport.requests}');
      print('[#132] lost-base error = ${error.runtimeType}: $error');
      // The heuristic sent the details request to the source origin, while the
      // original base was the redirect target — the base is not authoritative.
      expect(lostBaseTransport.requests, ['$origin/book/b29?isSearch=1']);
      expect(lostBaseTransport.requests.first, isNot(startsWith(redirectBase)));
      expect(error, isA<FormatException>());
    },
  );

  test('a failed relative reopen leaves the exact identity, id, progress, '
      'variables and shelf state untouched', () async {
    const relative = '/book/b29?isSearch=1,{"method":"GET"}';
    final source = _jsonSource(origin);
    final chapters = [SourceChapter('Chapter', Uri.parse('$origin/chapter'))];

    final historical = HtmlBook.fromJson({
      'url': relative,
      'title': 'Historical',
    });
    await shelf.add(source, historical, chapters);
    final entry = (await shelf.find(sourceUrl, relative))!;
    await shelf.saveProgress(entry.id, chapterIndex: 0, textOffset: 37);
    expect(
      await store.putBookVariable(sourceUrl, relative, 'book-before'),
      isTrue,
    );
    expect(
      await store.putChapterVariable(
        sourceUrl,
        relative,
        '$origin/chapter',
        'chapter-before',
      ),
      isTrue,
    );

    final transport = _RecordingTransport({
      '$origin/book/b29?isSearch=1': const _Route(
        '{"title":"Historical","toc":"/toc/b29"}',
      ),
    });
    await expectLater(
      JsonSourcePipeline(source, transport).details(entry.htmlBook),
      throwsA(isA<FormatException>()),
    );

    final after = (await store.bookById(entry.id))!;
    expect(after.sourceBookUrl, relative);
    expect((await store.progressOf(entry.id))!.textOffset, 37);
    expect(await store.bookVariable(sourceUrl, relative), 'book-before');
    expect(
      await store.chapterVariable(sourceUrl, relative, '$origin/chapter'),
      'chapter-before',
    );
    expect(await store.shelf(), hasLength(1));
    expect((await shelf.find(sourceUrl, relative))!.id, entry.id);
    // No invented absolute identity and no duplicate row.
    expect(await shelf.find(sourceUrl, '$origin/book/b29'), isNull);
  });
}
