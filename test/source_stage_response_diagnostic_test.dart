import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';
import 'tls_localhost_fixture.dart';

const _stages = [
  BookSourceStage.search,
  BookSourceStage.bookInfo,
  BookSourceStage.tableOfContents,
  BookSourceStage.content,
];
const _paths = ['/search', '/book', '/toc', '/chapter'];
const _blocked = '<p>access denied</p>';

// These are private synthetic pages, using the selector/JSON shapes of the
// existing pipeline and loginCheck tests. HTTP rows use local loopback only.
Map<String, String> _pages(bool json) => json
    ? {
        '/search': '{"items":[{"name":"Book","url":"/book"}]}',
        '/book': '{"name":"Detail","toc":"/toc"}',
        '/toc': '{"items":[{"name":"One","url":"/chapter"}]}',
        '/chapter': '{"text":"Content"}',
      }
    : {
        '/search': '<div class="item"><a href="/book">Book</a></div>',
        '/book': '<h1>Detail</h1><a class="toc" href="/toc">TOC</a>',
        '/toc': '<ul><li><a href="/chapter">One</a></li></ul>',
        '/chapter': '<div id="content">Content</div>',
      };

Map<String, dynamic> _source(bool json, String origin) => {
  'bookSourceUrl': origin,
  'searchUrl': '/search',
  'ruleSearch': {
    'bookList': json ? r'$.items' : 'div.item',
    'name': json ? r'$.name' : 'a@text',
    'bookUrl': json ? r'$.url' : 'a@href',
  },
  'ruleBookInfo': {
    'canReName': 'true',
    'name': json ? r'$.name' : 'h1@text',
    'tocUrl': json ? r'$.toc' : 'a.toc@href',
  },
  'ruleToc': {
    'chapterList': json ? r'$.items' : 'li',
    'chapterName': json ? r'$.name' : 'a@text',
    'chapterUrl': json ? r'$.url' : 'a@href',
  },
  'ruleContent': {'content': json ? r'$.text' : '#content@text'},
};

void _tocAddress(bool json, _Site site, String address) {
  site.pages['/book'] = [
    _Page(
      json
          ? jsonEncode({'name': 'Detail', 'toc': address})
          : '<h1>Detail</h1><a class="toc" href="${htmlEscape.convert(address)}">TOC</a>',
    ),
  ];
}

class _Page {
  _Page(String text, {this.status = 200, this.headers = const {}})
    : bytes = utf8.encode(text);
  _Page.bytes(this.bytes, {this.status = 200}) : headers = const {};
  const _Page.stalled() : bytes = null, status = 200, headers = const {};

  final List<int>? bytes;
  final int status;
  final Map<String, String> headers;
}

typedef _Seen = ({
  String method,
  Uri url,
  Map<String, String> headers,
  String body,
});

class _Site {
  _Site._(this.server, this.pages);

  static Future<_Site> start(bool json) async {
    final site = _Site._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      {
        for (final entry in _pages(json).entries)
          entry.key: [_Page(entry.value)],
      },
    );
    site.server.listen(site.handle);
    return site;
  }

  final HttpServer server;
  final Map<String, List<_Page>> pages;
  final seen = <_Seen>[];
  final reached = Completer<void>();
  String? watchedPath;
  String get origin => 'http://127.0.0.1:${server.port}';

  Future<void> close() async {
    await server.close(force: true);
  }

  Future<void> handle(HttpRequest request) async {
    final body = await utf8.decoder.bind(request).join();
    final headers = <String, String>{};
    request.headers.forEach((key, values) => headers[key] = values.join(', '));
    seen.add((
      method: request.method,
      url: request.uri,
      headers: headers,
      body: body,
    ));
    if (request.uri.path == watchedPath && !reached.isCompleted) {
      reached.complete();
    }
    final queue = pages[request.uri.path];
    if (queue == null || queue.isEmpty) {
      request.response.statusCode = 500;
      request.response.write('UNEXPECTED-FIXTURE-PATH');
      await request.response.close();
      return;
    }
    final page = queue.length > 1 ? queue.removeAt(0) : queue.single;
    final bytes = page.bytes;
    if (bytes == null) return;
    request.response.statusCode = page.status;
    request.response.headers.set('content-type', 'text/html; charset=utf-8');
    for (final header in page.headers.entries) {
      request.response.headers.set(header.key, header.value);
    }
    // Deliberately chunked: the body length cannot be borrowed from a header.
    request.response.add(bytes);
    await request.response.close();
  }
}

// Records actual pipeline options while delegating response collection and
// decoding to HttpSourceTransport. It does not manufacture HTTP metadata.
class _ObservedTransport implements BookSourceTransport, SourceHttpTransport {
  _ObservedTransport({Duration timeout = const Duration(seconds: 5)})
    : delegate = HttpSourceTransport(timeout: timeout);
  final HttpSourceTransport delegate;
  final requests = <SourceHttpRequest>[];
  final responses = <SourceHttpResponse>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final response = await delegate.send(request);
    responses.add(response);
    return response;
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('HTTP pipeline must use send');
}

class _FailingTransport implements BookSourceTransport, SourceHttpTransport {
  _FailingTransport(this.failure);
  final Object failure;
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    throw failure;
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('HTTP pipeline must use send');
}

class _LegacyTransport implements BookSourceTransport {
  final stages = <BookSourceStage>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    stages.add(stage);
    return '';
  }
}

class _EmptyWebView implements BookSourceWebViewAdapter {
  final requests = <SourceWebViewRequest>[];
  bool disposed = false;

  @override
  Future<SourceWebViewResponse> load(SourceWebViewRequest request) async {
    requests.add(request);
    return SourceWebViewResponse.page(request.url!, '');
  }

  @override
  void destroy() => disposed = true;
  @override
  bool get isDisposed => disposed;
  @override
  bool get hasWebView => !disposed;
}

class _EmptyWebViewFactory extends BookSourceWebViewAdapterFactory {
  _EmptyWebViewFactory(this.adapter)
    : super(sourceRef: 'https://rendered.test');
  final _EmptyWebView adapter;
  @override
  BookSourceWebViewAdapter create() => adapter;
}

Future<Object?> _until(
  BookSourcePipeline pipeline,
  BookSourceStage stage,
) async {
  final hits = await pipeline.search('Book');
  if (stage == BookSourceStage.search) return hits;
  expect(
    hits,
    hasLength(1),
    reason: 'the selected stage requires a real search hit',
  );
  final details = await pipeline.details(hits.single);
  if (stage != BookSourceStage.content) return details;
  expect(details.$2, hasLength(1), reason: 'content requires the fixture TOC');
  return pipeline.chapter(details.$2.single);
}

Future<({Object? value, Object? error})> _outcome(Future<Object?> work) async {
  try {
    return (value: await work, error: null);
  } catch (error) {
    return (value: null, error: error);
  }
}

void _requestSequence(_Site site, Iterable<String> paths) {
  expect(site.seen.map((request) => request.url.path), paths);
  expect(site.seen.map((request) => request.method), everyElement('GET'));
}

void _diagnostic(
  Object? error,
  BookSourceStage stage,
  Uri address, {
  int? status,
  int? bytes,
}) {
  expect(
    error,
    isNotNull,
    reason: 'an empty/failed stage must expose its diagnostic',
  );
  final message = '$error';
  expect(message, contains(SourceStageFormatError.stageWord(stage)));
  expect(message, contains(sourceStageAddress(address)));
  if (status != null) expect(message, contains('HTTP $status'));
  if (bytes != null) {
    expect(message, matches(RegExp('(?:^|[^0-9])$bytes\\s*字节')));
  }
  expect(message, isNot(contains('UNEXPECTED-FIXTURE-PATH')));
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  for (final json in [false, true]) {
    final kind = json ? 'JSON' : 'HTML';
    group('$kind stage response diagnostics', () {
      for (final stage in _stages) {
        final index = _stages.indexOf(stage);
        final path = _paths[index];
        final keepsEmptySuccess =
            !json &&
            (stage == BookSourceStage.search ||
                stage == BookSourceStage.bookInfo);
        test(
          'empty 200 ${stage.name} ${keepsEmptySuccess ? 'keeps its existing successful result' : 'reports its own response'}',
          () async {
            final site = await _Site.start(json);
            addTearDown(site.close);
            site.pages[path] = [_Page('')];
            final transport = _ObservedTransport();
            final source = _source(json, site.origin);
            if (!json && stage == BookSourceStage.bookInfo) {
              // Preserve the existing hit-title fallback and give it a valid TOC
              // address on an empty document; this row is a success control.
              (source['ruleBookInfo'] as Map)['tocUrl'] = '@js:"/toc"';
            }
            final pipeline = openBookSourcePipeline(source, transport);
            final result = await _outcome(_until(pipeline, stage));
            // HTML info falls back to the hit and continues to the valid TOC.
            // Include both pages in this successful fallback's request sequence.
            final expected =
                result.error == null &&
                    !json &&
                    stage == BookSourceStage.bookInfo
                ? _paths.take(3)
                : _paths.take(index + 1);
            _requestSequence(site, expected);
            expect(transport.requests, hasLength(expected.length));
            expect(
              transport.requests.every((request) => !request.readBytes),
              isTrue,
            );
            if (keepsEmptySuccess) {
              expect(result.error, isNull);
              if (stage == BookSourceStage.search) {
                expect(result.value, isEmpty);
              } else {
                final (book, chapters) =
                    result.value as (HtmlBook, List<SourceChapter>);
                expect(book.title, 'Book');
                expect(chapters.single.name, 'One');
              }
            } else {
              _diagnostic(
                result.error,
                stage,
                Uri.parse('${site.origin}$path'),
                status: 200,
                bytes: 0,
              );
            }
          },
        );

        test(
          'timeout ${stage.name} keeps failure kind and safe address',
          () async {
            final site = await _Site.start(json);
            addTearDown(site.close);
            site.pages[path] = [const _Page.stalled()];
            final pipeline = openBookSourcePipeline(
              _source(json, site.origin),
              _ObservedTransport(timeout: const Duration(milliseconds: 500)),
            );
            final result = await _outcome(_until(pipeline, stage));
            _requestSequence(site, _paths.take(index + 1));
            _diagnostic(result.error, stage, Uri.parse('${site.origin}$path'));
            expect('$result', isNot(contains('UNEXPECTED-FIXTURE-PATH')));
            expect(
              '${result.error}',
              matches(RegExp('timeout|超时', caseSensitive: false)),
            );
            expect('${result.error}', isNot(contains('响应为空')));
            expect('${result.error}', isNot(contains('HTTP 200')));
          },
        );

        test(
          'usable 403 ${stage.name} still reaches its rule result',
          () async {
            final site = await _Site.start(json);
            addTearDown(site.close);
            site.pages[path] = [_Page(_pages(json)[path]!, status: 403)];
            final transport = _ObservedTransport();
            final pipeline = openBookSourcePipeline(
              _source(json, site.origin),
              transport,
            );
            final result = await _until(pipeline, stage);
            final count = stage == BookSourceStage.search
                ? 1
                : stage == BookSourceStage.content
                ? 4
                : 3;
            _requestSequence(site, _paths.take(count));
            expect(transport.responses[index].statusCode, 403);
            if (stage == BookSourceStage.search) {
              expect((result as List<HtmlBook>).single.title, 'Book');
            } else if (stage == BookSourceStage.content) {
              expect((result as HtmlChapterBody).text, 'Content');
            } else {
              final (book, chapters) =
                  result as (HtmlBook, List<SourceChapter>);
              expect(book.title, 'Detail');
              expect(chapters.single.name, 'One');
            }
          },
        );

        // HTML book-info getters deliberately retain hit fields on no match;
        // a nonempty missing-info page is not necessarily a failed extraction.
        if (json ||
            stage == BookSourceStage.tableOfContents ||
            stage == BookSourceStage.content) {
          test(
            'failed 403 ${stage.name} reports status and actual body bytes',
            () async {
              final site = await _Site.start(json);
              addTearDown(site.close);
              site.pages[path] = [_Page(_blocked, status: 403)];
              final pipeline = openBookSourcePipeline(
                _source(json, site.origin),
                _ObservedTransport(),
              );
              final result = await _outcome(_until(pipeline, stage));
              _requestSequence(site, _paths.take(index + 1));
              _diagnostic(
                result.error,
                stage,
                Uri.parse('${site.origin}$path'),
                status: 403,
                bytes: utf8.encode(_blocked).length,
              );
            },
          );
        }
      }

      test(
        'credentials and request options stay outside the TOC diagnostic',
        () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          const secretQuery = 'SYNTHETIC-QUERY';
          const secretFragment = 'SYNTHETIC-FRAGMENT';
          const secretHeader = 'SYNTHETIC-AUTH';
          const secretCookie = 'SYNTHETIC-COOKIE';
          const secretBody = 'SYNTHETIC-POST-BODY';
          const blockedBody =
              '<p>access denied; a bounded harmless error-page prefix only</p>'
              'SYNTHETIC-BODY-TAIL';
          final source = _source(json, site.origin);
          source['header'] = jsonEncode({
            'Authorization': secretHeader,
            'Cookie': secretCookie,
          });
          _tocAddress(
            json,
            site,
            '/toc?token=$secretQuery#$secretFragment,'
            '${jsonEncode({
              'method': 'POST',
              'body': secretBody,
              'headers': {'X-Private': 'SYNTHETIC-OPTION'},
            })}',
          );
          site.pages['/toc'] = [
            _Page(
              blockedBody,
              status: 403,
              headers: {'set-cookie': 'SYNTHETIC-RESPONSE-COOKIE'},
            ),
          ];
          final pipeline = openBookSourcePipeline(source, _ObservedTransport());
          final result = await _outcome(
            _until(pipeline, BookSourceStage.tableOfContents),
          );
          expect(site.seen.map((request) => request.url.path), _paths.take(3));
          final request = site.seen.last;
          expect(request.method, 'POST');
          expect(request.url.queryParameters['token'], secretQuery);
          expect(request.headers['authorization'], secretHeader);
          expect(request.headers['cookie'], secretCookie);
          expect(request.headers['x-private'], 'SYNTHETIC-OPTION');
          expect(request.body, secretBody);
          _diagnostic(
            result.error,
            BookSourceStage.tableOfContents,
            Uri.parse('${site.origin}/toc'),
            status: 403,
            bytes: utf8.encode(blockedBody).length,
          );
          for (final secret in [
            secretQuery,
            secretFragment,
            secretHeader,
            secretCookie,
            secretBody,
            blockedBody,
            'SYNTHETIC-BODY-TAIL',
            'SYNTHETIC-OPTION',
            'SYNTHETIC-RESPONSE-COOKIE',
            'Authorization',
            'set-cookie',
            '{"method"',
          ]) {
            expect('${result.error}', isNot(contains(secret)));
          }
        },
      );

      for (final encoding in ['utf8', 'utf8-bom']) {
        test('$encoding body count comes from transport collection', () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          const text = '<p>拒绝😀</p>';
          final raw = [
            ...(encoding == 'utf8-bom' ? [0xef, 0xbb, 0xbf] : <int>[]),
            ...utf8.encode(text),
          ];
          site.pages['/toc'] = [_Page.bytes(raw, status: 403)];
          final transport = _ObservedTransport();
          final result = await _outcome(
            _until(
              openBookSourcePipeline(_source(json, site.origin), transport),
              BookSourceStage.tableOfContents,
            ),
          );
          _requestSequence(site, _paths.take(3));
          final response = transport.responses.last;
          expect(response.body, text);
          expect(
            response.bodyBytes,
            isNull,
            reason: 'ordinary pipeline requests stay decoded-only',
          );
          expect(transport.requests.last.readBytes, isFalse);
          expect(response.headers, isNot(contains('content-length')));
          expect(raw.length, isNot(text.length));
          if (encoding == 'utf8-bom') {
            expect(raw.length, isNot(utf8.encode(response.body).length));
          }
          _diagnostic(
            result.error,
            BookSourceStage.tableOfContents,
            response.url,
            status: 403,
            bytes: raw.length,
          );
        });
      }

      test(
        'redirect binds the final response address status and bytes',
        () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          site.pages['/toc'] = [
            _Page(
              'discarded redirect response body',
              status: 302,
              headers: {
                'location':
                    '/final?token=SYNTHETIC-REDIRECT#SYNTHETIC-FRAGMENT',
              },
            ),
          ];
          site.pages['/final'] = [_Page(_blocked, status: 403)];
          final result = await _outcome(
            _until(
              openBookSourcePipeline(
                _source(json, site.origin),
                _ObservedTransport(),
              ),
              BookSourceStage.tableOfContents,
            ),
          );
          _requestSequence(site, ['/search', '/book', '/toc', '/final']);
          expect(
            site.seen.last.url.queryParameters['token'],
            'SYNTHETIC-REDIRECT',
          );
          _diagnostic(
            result.error,
            BookSourceStage.tableOfContents,
            Uri.parse('${site.origin}/final'),
            status: 403,
            bytes: utf8.encode(_blocked).length,
          );
          expect('${result.error}', isNot(contains('${site.origin}/toc')));
          expect('${result.error}', isNot(contains('HTTP 302')));
          expect('${result.error}', isNot(contains('SYNTHETIC-REDIRECT')));
        },
      );

      for (final check in ['preserve', 'replace', 'discard', 'host']) {
        test('loginCheck $check keeps the selected response provenance', () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          final source = _source(json, site.origin);
          final original = _Page(_blocked, status: 403);
          final replacement = _Page('', status: 502);
          site.pages['/toc'] = [original, replacement];
          site.pages['/replacement'] = [replacement];
          source['loginCheckJs'] = switch (check) {
            'preserve' => 'result;',
            'replace' =>
              'result.url().indexOf("/toc") >= 0 ? java.getStrResponse() : result;',
            'discard' =>
              'if (result.url().indexOf("/toc") >= 0) { java.getStrResponse(); } result;',
            _ =>
              'result.url().indexOf("/toc") >= 0 ? java.connect("${site.origin}/replacement") : result;',
          };
          final result = await _outcome(
            _until(
              openBookSourcePipeline(source, _ObservedTransport()),
              BookSourceStage.tableOfContents,
            ),
          );
          final extra = check == 'preserve'
              ? <String>[]
              : [check == 'host' ? '/replacement' : '/toc'];
          _requestSequence(site, ['/search', '/book', '/toc', ...extra]);
          final replaced = check == 'replace' || check == 'host';
          _diagnostic(
            result.error,
            BookSourceStage.tableOfContents,
            Uri.parse(
              '${site.origin}${check == 'host' ? '/replacement' : '/toc'}',
            ),
            status: replaced ? 502 : 403,
            bytes: replaced ? 0 : utf8.encode(_blocked).length,
          );
          expect(
            '${result.error}',
            isNot(contains(replaced ? 'HTTP 403' : 'HTTP 502')),
          );
        });
      }

      test(
        'retry reports the last response after configured attempts',
        () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          final source = _source(json, site.origin);
          _tocAddress(json, site, '/toc,{"retry":1}');
          site.pages['/toc'] = [
            _Page('first attempt', status: 503),
            _Page(_blocked, status: 403),
          ];
          final transport = _ObservedTransport();
          final result = await _outcome(
            _until(
              openBookSourcePipeline(source, transport),
              BookSourceStage.tableOfContents,
            ),
          );
          _requestSequence(site, ['/search', '/book', '/toc', '/toc']);
          expect(transport.requests.last.retry, 1);
          expect(transport.requests, hasLength(3));
          _diagnostic(
            result.error,
            BookSourceStage.tableOfContents,
            Uri.parse('${site.origin}/toc'),
            status: 403,
            bytes: utf8.encode(_blocked).length,
          );
          expect('${result.error}', isNot(contains('HTTP 503')));
        },
      );

      for (final toc in [true, false]) {
        test('${toc ? 'TOC' : 'content'} later page owns its diagnostic', () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          final source = _source(json, site.origin);
          source['loginCheckJs'] =
              'if (result.url().indexOf("-later") >= 0) { throw new Error("later page must not check login"); } result;';
          if (toc) {
            (source['ruleToc'] as Map)['nextTocUrl'] = json
                ? r'$.next'
                : 'a.next@href';
            site.pages['/toc'] = [
              _Page(
                json
                    ? '{"items":[{"name":"One","url":"/chapter"}],"next":"/toc-later"}'
                    : '${_pages(false)['/toc']}<a class="next" href="/toc-later">next</a>',
              ),
            ];
          } else {
            (source['ruleContent'] as Map)['nextContentUrl'] = json
                ? r'$.next'
                : 'a.next@href';
            site.pages['/chapter'] = [
              _Page(
                json
                    ? '{"text":"Content","next":"/chapter-later"}'
                    : '${_pages(false)['/chapter']}<a class="next" href="/chapter-later">next</a>',
              ),
            ];
          }
          final later = toc ? '/toc-later' : '/chapter-later';
          site.pages[later] = [_Page(_blocked, status: 403)];
          final stage = toc
              ? BookSourceStage.tableOfContents
              : BookSourceStage.content;
          final result = await _outcome(
            _until(openBookSourcePipeline(source, _ObservedTransport()), stage),
          );
          _requestSequence(site, [..._paths.take(toc ? 3 : 4), later]);
          _diagnostic(
            result.error,
            stage,
            Uri.parse('${site.origin}$later'),
            status: 403,
            bytes: utf8.encode(_blocked).length,
          );
          expect(
            '${result.error}',
            isNot(contains('later page must not check login')),
          );
        });
      }

      test('cancellation during HTTP keeps the cancellation type', () async {
        final site = await _Site.start(json);
        addTearDown(site.close);
        site.watchedPath = '/search';
        site.pages['/search'] = [const _Page.stalled()];
        final pipeline = openBookSourcePipeline(
          _source(json, site.origin),
          _ObservedTransport(),
        );
        final pending = _outcome(pipeline.search('Book'));
        await site.reached.future.timeout(const Duration(seconds: 5));
        pipeline.cancel();
        final result = await pending;
        _requestSequence(site, ['/search']);
        expect(result.error, isA<SourceRequestCancelled>());
      });

      test(
        'real TLS refusal remains available to certificate confirmation',
        () async {
          final server = await TlsLocalhostFixtureServer.bind(
            pageText: 'unused',
          );
          addTearDown(server.close);
          final source = _source(json, 'https://${server.authority}');
          source['searchUrl'] = '/page';
          final result = await _outcome(
            openBookSourcePipeline(source, _ObservedTransport()).search('Book'),
          );
          expect(server.connectionsAccepted, greaterThan(0));
          expect(server.pageRequests, 0);
          expect(
            result.error,
            isA<SourceTlsCertificateFailure>()
                .having(
                  (failure) => failure.sourceRef,
                  'source',
                  source['bookSourceUrl'],
                )
                .having((failure) => failure.host, 'host', '127.0.0.1'),
          );
        },
      );

      test('response cap keeps its established type through fetch', () async {
        const failure = SourceIoLimitExceeded('response');
        final transport = _FailingTransport(failure);
        final result = await _outcome(
          openBookSourcePipeline(
            _source(json, 'https://fixture.test'),
            transport,
          ).search('Book'),
        );
        expect(transport.requests.single.url.path, '/search');
        expect(result.error, same(failure));
      });

      test(
        'connection failure names its kind without copying exception secrets',
        () async {
          final transport = _FailingTransport(
            const SocketException('SYNTHETIC-EXCEPTION-SECRET'),
          );
          final result = await _outcome(
            openBookSourcePipeline(
              _source(json, 'https://fixture.test'),
              transport,
            ).search('Book'),
          );
          expect(transport.requests.single.url.path, '/search');
          _diagnostic(
            result.error,
            BookSourceStage.search,
            Uri.parse('https://fixture.test/search'),
          );
          expect(
            '${result.error}',
            matches(RegExp('connection|连接', caseSensitive: false)),
          );
          expect(
            '${result.error}',
            isNot(contains('SYNTHETIC-EXCEPTION-SECRET')),
          );
          expect('${result.error}', isNot(contains('HTTP 200')));
        },
      );

      for (final policy in [false, true]) {
        test(
          '${policy ? 'policy' : 'rule script'} failure is not relabelled as network',
          () async {
            final site = await _Site.start(json);
            addTearDown(site.close);
            final source = _source(json, site.origin);
            (source['ruleContent'] as Map)['content'] = policy
                ? '@js:java.getStrResponse().body()'
                : '@js:throw new Error("SYNTHETIC-RULE-FAILURE")';
            final result = await _outcome(
              _until(
                openBookSourcePipeline(source, _ObservedTransport()),
                BookSourceStage.content,
              ),
            );
            _requestSequence(site, _paths);
            expect(result.error, isA<SourceScriptError>());
            if (policy) {
              expect((result.error as SourceScriptError).category, 'policy');
            } else {
              expect('${result.error}', contains('SYNTHETIC-RULE-FAILURE'));
            }
            expect('${result.error}', isNot(contains('HTTP 200')));
          },
        );
      }

      for (final forgery in ['clone', 'mutate']) {
        test('source $forgery cannot forge trusted HTTP facts', () async {
          final site = await _Site.start(json);
          addTearDown(site.close);
          final source = _source(json, site.origin);
          source['loginCheckJs'] =
              '''
var payload = result.__response();
if (Object.keys(payload).length !== 4 || !['body', 'url', 'headers', 'statusCode'].every(function(key) { return Object.prototype.hasOwnProperty.call(payload, key); })) {
  throw new Error('SYNTHETIC-INTERNAL-METADATA-LEAK');
}
if (result.url().indexOf('/toc') < 0) {
  result;
} else {
  ${forgery == 'clone' ? '({__response: function() { return {body: "", url: "https://synthetic.test/replacement", statusCode: 599, headers: {}, bodyByteLength: 999, httpResponse: {statusCode: 599, bodyByteLength: 999}}; }});' : 'payload.body = ""; payload.url = "https://synthetic.test/replacement"; payload.statusCode = 599; result;'}
}
''';
          final result = await _outcome(
            _until(
              openBookSourcePipeline(source, _ObservedTransport()),
              BookSourceStage.tableOfContents,
            ),
          );
          _requestSequence(site, _paths.take(3));
          expect(
            result.error,
            isNotNull,
            reason: 'forged responses must reach a real failed extraction',
          );
          expect(
            '${result.error}',
            isNot(contains('SYNTHETIC-INTERNAL-METADATA-LEAK')),
          );
          // Preserve the current source-returned response path, but never treat
          // source-controlled fields as facts observed by the HTTP transport.
          expect('${result.error}', isNot(matches(RegExp(r'HTTP\s+\d+'))));
          expect('${result.error}', isNot(matches(RegExp(r'\d+\s*字节'))));
        });
      }

      test('rendered document never claims actual HTTP metadata', () async {
        final transport = _LegacyTransport();
        final adapter = _EmptyWebView();
        final source = _source(json, 'https://rendered.test');
        source['searchUrl'] = '/search,{"webView":true}';
        final factory = _EmptyWebViewFactory(adapter);
        final BookSourcePipeline pipeline = json
            ? JsonSourcePipeline(source, transport, webViewFactory: factory)
            : HtmlSourcePipeline(source, transport, webViewFactory: factory);
        final result = await _outcome(pipeline.search('Book'));
        expect(transport.stages, isEmpty);
        expect(adapter.requests.single.url, 'https://rendered.test/search');
        expect(adapter.isDisposed, isTrue);
        if (json) {
          _diagnostic(
            result.error,
            BookSourceStage.search,
            Uri.parse('https://rendered.test/search'),
          );
        } else {
          expect(result.error, isNull);
          expect(result.value, isEmpty);
        }
        expect('${result.error}', isNot(matches(RegExp(r'HTTP\s+\d+'))));
        expect('${result.error}', isNot(matches(RegExp(r'\d+\s*字节'))));
      });

      test(
        'legacy string response never claims actual HTTP metadata',
        () async {
          final transport = _LegacyTransport();
          final result = await _outcome(
            openBookSourcePipeline(
              _source(json, 'https://legacy.test'),
              transport,
            ).search('Book'),
          );
          expect(transport.stages, [BookSourceStage.search]);
          if (json) {
            _diagnostic(
              result.error,
              BookSourceStage.search,
              Uri.parse('https://legacy.test/search'),
            );
          } else {
            expect(result.error, isNull);
            expect(result.value, isEmpty);
          }
          // Empty legacy text has no trusted HTTP response, even though its
          // source-visible StrResponse currently defaults to synthetic 200.
          expect('${result.error}', isNot(contains('HTTP 200')));
          expect('${result.error}', isNot(matches(RegExp(r'\d+\s*字节'))));
        },
      );
    });
  }

  test('actual response collection still enforces its raw-byte cap', () async {
    final site = await _Site.start(false);
    addTearDown(site.close);
    site.pages['/limit'] = [_Page.bytes(List<int>.filled(17, 0x61))];
    await expectLater(
      HttpSourceTransport().send(
        SourceHttpRequest(
          method: 'GET',
          url: Uri.parse('${site.origin}/limit'),
          maxResponseBytes: 16,
        ),
      ),
      throwsA(
        isA<SourceIoLimitExceeded>().having(
          (failure) => failure.direction,
          'direction',
          'response',
        ),
      ),
    );
    _requestSequence(site, ['/limit']);
  });

  test('stage address removes user info query and fragment', () {
    expect(
      sourceStageAddress(
        Uri.parse(
          'https://SYNTHETIC-USER:SYNTHETIC-PASSWORD@fixture.test:8443/toc?token=SYNTHETIC-QUERY#SYNTHETIC-FRAGMENT',
        ),
      ),
      'https://fixture.test:8443/toc',
    );
  });
}
