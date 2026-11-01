import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';

import 'native_library.dart';

/// The two frozen stages this product runs as one composed `details` call:
/// `WebBook.getBookInfoAwait` (`WebBook.kt:152-198`) and
/// `WebBook.getChapterListAwait` (`WebBook.kt:224-270`). These checks pin the
/// separated entries: the information stage makes no TOC request and leaves its
/// own `loginCheckJs` marker, the TOC stage makes only its own request and
/// changes that marker, and the composed entry still produces the old pair.
///
/// Every request is real HTTP through [HttpSourceTransport], so the checks see
/// the wire (target and headers), not a model of it.
class _Site {
  _Site._(this._server, this.pages);

  static Future<_Site> start(Map<String, String> pages) async {
    final site = _Site._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      pages,
    );
    site._server.listen(site._handle);
    return site;
  }

  final HttpServer _server;
  final Map<String, String> pages;
  final requests = <_Seen>[];

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final headers = <String, String>{};
    request.headers.forEach(
      (name, values) => headers[name] = values.join(', '),
    );
    requests.add(_Seen(request.uri.path, headers));
    final body = pages[request.uri.path];
    if (body == null) {
      request.response.statusCode = 404;
      request.response.write('not found');
    } else {
      request.response.write(body);
    }
    await request.response.close();
  }
}

class _Seen {
  _Seen(this.path, this.headers);
  final String path;
  final Map<String, String> headers;
}

const _infoHtml =
    '<h1><a>书</a></h1><h2 id="dir"><a href="/book/1/toc">目录</a></h2>';
const _tocHtml =
    '<div id="list"><li><a href="/book/1/ch/1">第一章</a></li>'
    '<li><a href="/book/1/ch/2">第二章</a></li></div>';
const _infoJson = '{"name":"书","toc":"/book/1/toc"}';
const _tocJson =
    '{"chapters":[{"title":"第一章","url":"/book/1/ch/1"},'
    '{"title":"第二章","url":"/book/1/ch/2"}]}';

/// The check script both stages run: it appends `i` for the information
/// response and `t` for the TOC response to the source's own `runs` entry, so a
/// test can see exactly which stage wrote last.
const _checkScript =
    "(function(){var b=String(result.body());"
    "source.put('runs',(source.get('runs')||'')+(b.indexOf('第一章')>=0?"
    "'t':'i'));return result;})()";

Map<String, dynamic> _htmlSource(String origin) => {
  'bookSourceUrl': origin,
  'loginCheckJs': _checkScript,
  'ruleBookInfo': {'name': '@CSS:h1 a@text', 'tocUrl': '@CSS:#dir a@href'},
  'ruleToc': {
    'chapterList': '@CSS:#list li a',
    'chapterName': '@CSS:a@text',
    'chapterUrl': '@CSS:a@href',
  },
};

Map<String, dynamic> _jsonSource(String origin) => {
  'bookSourceUrl': origin,
  'loginCheckJs': _checkScript,
  'ruleSearch': {
    'bookList': r'$.items',
    'name': r'$.name',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': {'name': r'$.name', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.chapters[*]',
    'chapterName': r'$.title',
    'chapterUrl': r'$.url',
  },
};

BookSourcePipeline _pipeline(
  Map<String, dynamic> source, {
  SourceHostState? state,
  String androidId = '0123456789abcdef',
}) => openBookSourcePipeline(
  source,
  HttpSourceTransport(),
  hostState: state ?? SourceHostState(),
  androidId: androidId,
);

HtmlBook _hit(
  String origin, {
  String address = '/book/1',
  Map<String, dynamic>? variable,
}) => HtmlBook(
  url: Uri.parse('$origin$address'),
  rawAddress: '$origin$address',
  title: '书',
  variable: variable == null ? null : jsonEncode(variable),
);

Future<String> _runs(SourceHostState state, String origin) async =>
    '${await state.entry(origin, 'v_${origin}_runs') ?? ''}';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  for (final adapter in ['HTML', 'JSON']) {
    final isHtml = adapter == 'HTML';

    group('$adapter information and TOC stages', () {
      Future<_Site> site({bool withToc = true}) => _Site.start({
        '/book/1': isHtml ? _infoHtml : _infoJson,
        if (withToc) '/book/1/toc': isHtml ? _tocHtml : _tocJson,
      });

      Map<String, dynamic> source(String origin) =>
          isHtml ? _htmlSource(origin) : _jsonSource(origin);

      test(
        'information-only makes no TOC request and keeps its own marker',
        () async {
          final server = await site();
          addTearDown(server.close);
          final state = SourceHostState();
          final pipeline = _pipeline(source(server.origin), state: state);

          final info = await pipeline.bookInfo(_hit(server.origin));

          expect(
            [for (final request in server.requests) request.path],
            ['/book/1'],
            reason: 'the information stage makes exactly one request',
          );
          expect(await _runs(state, server.origin), 'i');
          expect(info.book.title, '书');
          expect(info.tocAddress, '/book/1/toc');
          expect(info.tocUrl, '${server.origin}/book/1/toc');
        },
      );

      test(
        'the TOC stage makes only its own request and changes the marker',
        () async {
          final server = await site();
          addTearDown(server.close);
          final state = SourceHostState();
          final pipeline = _pipeline(source(server.origin), state: state);

          final info = await pipeline.bookInfo(_hit(server.origin));
          final (book, chapters) = await pipeline.tableOfContents(info);

          expect(
            [for (final request in server.requests) request.path],
            ['/book/1', '/book/1/toc'],
          );
          expect(
            await _runs(state, server.origin),
            'it',
            reason: 'the TOC check runs at its own boundary, once',
          );
          expect(book.identityAddress, '${server.origin}/book/1');
          expect(
            [for (final chapter in chapters) chapter.name],
            ['第一章', '第二章'],
          );
          expect(
            [for (final chapter in chapters) '${chapter.url}'],
            ['${server.origin}/book/1/ch/1', '${server.origin}/book/1/ch/2'],
          );
        },
      );

      test(
        'the composed details call is the same pair in the same order',
        () async {
          final pair = await site();
          addTearDown(pair.close);
          final pairState = SourceHostState();
          final pairPipeline = _pipeline(source(pair.origin), state: pairState);
          final info = await pairPipeline.bookInfo(_hit(pair.origin));
          final (pairBook, pairChapters) = await pairPipeline.tableOfContents(
            info,
          );

          final composed = await site();
          addTearDown(composed.close);
          final composedState = SourceHostState();
          final composedPipeline = _pipeline(
            source(composed.origin),
            state: composedState,
          );
          final (composedBook, composedChapters) = await composedPipeline
              .details(_hit(composed.origin));

          expect(
            [for (final request in composed.requests) request.path],
            [for (final request in pair.requests) request.path],
          );
          expect(
            await _runs(composedState, composed.origin),
            await _runs(pairState, pair.origin),
          );
          expect(composedBook.title, pairBook.title);
          expect(
            Uri.parse(composedBook.identityAddress).path,
            Uri.parse(pairBook.identityAddress).path,
          );
          expect(
            composedBook.variable,
            pairBook.variable,
            reason: 'the composed path carries the same book variable text',
          );
          expect(
            [
              for (final chapter in composedChapters)
                '${chapter.name}|${Uri.parse('${chapter.url}').path}|'
                    '${chapter.tag}',
            ],
            [
              for (final chapter in pairChapters)
                '${chapter.name}|${Uri.parse('${chapter.url}').path}|'
                    '${chapter.tag}',
            ],
          );
        },
      );

      test(
        'a details-only book stops after its information response',
        () async {
          final server = await site(withToc: false);
          addTearDown(server.close);
          final state = SourceHostState();
          final pipeline = _pipeline(source(server.origin), state: state);

          final info = await pipeline.bookInfo(_hit(server.origin));
          expect(info.book.title, '书');
          expect(
            [for (final request in server.requests) request.path],
            ['/book/1'],
            reason:
                'the information stage never asks for a TOC it does not read',
          );
          await expectLater(pipeline.tableOfContents(info), throwsA(anything));
          expect(
            [for (final request in server.requests) request.path],
            ['/book/1', '/book/1/toc'],
            reason: 'the TOC stage is the one that requests the missing page',
          );
        },
      );

      test('each stage evaluates only its own address options', () async {
        final server = await site();
        addTearDown(server.close);
        final pipeline = _pipeline(source(server.origin));
        // The book's own address text carries an option tail the information
        // request must apply; the TOC stage must not re-evaluate it.
        final hit = HtmlBook(
          url: Uri.parse('${server.origin}/book/1,{"headers":{"X-Info":"1"}}'),
          rawAddress: '${server.origin}/book/1,{"headers":{"X-Info":"1"}}',
          title: '书',
        );
        final info = await pipeline.bookInfo(hit);
        final (_, chapters) = await pipeline.tableOfContents(info);

        expect(chapters, isNotEmpty);
        final infoRequest = server.requests.first;
        expect(infoRequest.headers['x-info'], '1');
        final tocRequest = server.requests[1];
        expect(
          tocRequest.headers.containsKey('x-info'),
          isFalse,
          reason: 'the TOC stage does not re-evaluate the book address options',
        );
      });

      test(
        'the split pair carries the same entity variables as details',
        () async {
          final pair = await site();
          addTearDown(pair.close);
          final pairState = SourceHostState();
          final pairPipeline = _pipeline(source(pair.origin), state: pairState);
          final info = await pairPipeline.bookInfo(
            _hit(pair.origin, variable: {'seed': 'S'}),
          );
          final (pairBook, pairChapters) = await pairPipeline.tableOfContents(
            info,
          );

          final composed = await site();
          addTearDown(composed.close);
          final composedState = SourceHostState();
          final composedPipeline = _pipeline(
            source(composed.origin),
            state: composedState,
          );
          final (composedBook, composedChapters) = await composedPipeline
              .details(_hit(composed.origin, variable: {'seed': 'S'}));

          expect(pairBook.variable, composedBook.variable);
          expect(
            [for (final chapter in pairChapters) chapter.variable],
            [for (final chapter in composedChapters) chapter.variable],
          );
        },
      );
    });
  }

  for (final adapter in ['HTML', 'JSON']) {
    final isHtml = adapter == 'HTML';
    test(
      '$adapter: the TOC stage continues its own information context',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => server.close(force: true));
        final requests = <String>[];
        server.listen((request) async {
          requests.add('${request.uri}');
          final String body;
          switch (request.uri.path) {
            case '/book/1':
              body = isHtml
                  ? '<h1>Book A</h1><a id="toc" href="/toc">toc</a>'
                  : '{"name":"Book A","toc":"/toc"}';
            case '/search':
              body = isHtml
                  ? '<ul id="results"><li><a href="/book/2">Book B</a></li></ul>'
                  : '{"items":[{"name":"Book B","url":"/book/2"}]}';
            case '/toc':
              body = isHtml
                  ? '<ul id="chapters"><li><a href="/c1">chapter</a></li></ul>'
                  : '{"chapters":[{"name":"chapter","url":"/c1"}]}';
            default:
              request.response.statusCode = 404;
              body = 'not found';
          }
          if (!isHtml) {
            request.response.headers.contentType = ContentType.json;
          }
          request.response.write(body);
          await request.response.close();
        });
        final origin = 'http://127.0.0.1:${server.port}';
        Map<String, dynamic> source() => {
          'bookSourceUrl': origin,
          'searchUrl': '/search?key={{key}}&page={{page}}',
          'ruleSearch': isHtml
              ? {
                  'bookList': '@CSS:#results li',
                  'name': '@CSS:a@text',
                  'bookUrl': '@CSS:a@href',
                }
              : {
                  'bookList': r'$.items',
                  'name': r'$.name',
                  'bookUrl': r'$.url',
                },
          'ruleBookInfo': isHtml
              ? {'name': '@CSS:h1@text', 'tocUrl': '@CSS:#toc@href'}
              : {'name': r'$.name', 'tocUrl': r'$.toc'},
          'ruleToc': {
            'chapterList': isHtml ? '@CSS:#chapters li' : r'$.chapters[*]',
            'chapterName': '@js:String(key) + "|" + String(page)',
            'chapterUrl': isHtml ? '@CSS:a@href' : r'$.url',
          },
        };
        HtmlBook hit() => HtmlBook(
          url: Uri.parse('$origin/book/1'),
          rawAddress: '$origin/book/1',
          title: 'Book A',
        );

        // The information context is read when the information stage runs; a
        // later search on the same pipeline does not reach the TOC stage.
        final baseline = _pipeline(source());
        final info = await baseline.bookInfo(hit());
        final (book, chapters) = await baseline.tableOfContents(info);
        expect(book.title, 'Book A');
        expect([for (final chapter in chapters) chapter.name], ['|null']);
        expect(requests, ['/book/1', '/toc']);

        requests.clear();
        final interleaved = _pipeline(source());
        final deferred = await interleaved.bookInfo(hit());
        final searched = await interleaved.search('B', page: 7);
        expect(searched, hasLength(1));
        final (againBook, againChapters) = await interleaved.tableOfContents(
          deferred,
        );
        expect(againBook.title, 'Book A');
        expect(
          [for (final chapter in againChapters) chapter.name],
          ['|null'],
          reason:
              'the TOC stage keeps the context its own information ran with',
        );
        expect(requests, ['/book/1', '/search?key=B&page=7', '/toc']);

        // When the information stage itself followed a search, that search's key
        // is the context it continues with; its page is the information stage's
        // own null page.
        requests.clear();
        final searchedFirst = _pipeline(source());
        await searchedFirst.search('A', page: 3);
        final afterSearch = await searchedFirst.bookInfo(hit());
        final (_, afterSearchChapters) = await searchedFirst.tableOfContents(
          afterSearch,
        );
        expect(
          [for (final chapter in afterSearchChapters) chapter.name],
          ['A|null'],
          reason: 'the information stage carries the key it ran with, no page',
        );
      },
    );
  }

  test('an absolute declared TOC address is carried as declared', () async {
    final server = await _Site.start({
      '/book/1':
          '<h1><a>书</a></h1>'
          '<h2 id="dir"><a href="${'/abs/toc'}">目录</a></h2>',
    });
    addTearDown(server.close);
    final source = _htmlSource(server.origin);
    final pipeline = _pipeline(source);
    final info = await pipeline.bookInfo(_hit(server.origin));
    expect(info.tocAddress, '/abs/toc');
    expect(
      info.tocBase,
      Uri.parse('${server.origin}/book/1'),
      reason:
          'the declared address resolves against the response it was read from',
    );
  });
}
