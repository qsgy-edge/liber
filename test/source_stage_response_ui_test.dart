import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/l10n/app_localizations.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/html_source_browser.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/online_reader_page.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';
import 'native_library.dart';

const _origin = 'https://fixture.test:8443';
const _safeOrigin = _origin;
const _responseUserInfo = 'SYNTHETIC-USER:SYNTHETIC-PASSWORD';
const _blockedBody = '<p>denied</p>';
const _blockedBytes = 13;
const _longTocPath =
    '/catalog/long-safe-segment-2026/long-safe-segment-2026/'
    'long-safe-segment-2026/long-safe-segment-2026/last-page';

enum _Fault { empty, blocked, timeout }

String _address(String path, {bool canaries = true}) => !canaries
    ? path
    : '$path?token=SYNTHETIC-QUERY#SYNTHETIC-FRAGMENT,'
          '${jsonEncode({
            'method': 'POST',
            'body': 'SYNTHETIC-POST-BODY',
            'headers': {'X-Option': 'SYNTHETIC-OPTION'},
          })}';

Map<String, dynamic> _source(
  bool json, {
  String origin = _origin,
  bool canaries = true,
}) => {
  'bookSourceUrl': origin,
  'bookSourceName': 'Fixture source',
  if (canaries)
    'header': jsonEncode({
      'Authorization': 'Bearer SYNTHETIC-AUTH',
      'Cookie': 'sid=SYNTHETIC-COOKIE',
      'X-Private': 'SYNTHETIC-HEADER',
    }),
  'searchUrl': _address('/search', canaries: canaries),
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

class _Reply {
  const _Reply(
    this.body, {
    this.status = 200,
    this.bytes,
    this.failure,
    this.responseUserInfo = false,
  });
  final String body;
  final int status;
  final int? bytes;
  final Object? failure;
  final bool responseUserInfo;
}

_Reply _failure(_Fault fault) => switch (fault) {
  _Fault.empty => const _Reply('', bytes: 0, responseUserInfo: true),
  _Fault.blocked => const _Reply(
    _blockedBody,
    status: 403,
    bytes: _blockedBytes,
    responseUserInfo: true,
  ),
  _Fault.timeout => _Reply(
    '',
    failure: TimeoutException('SYNTHETIC-TIMEOUT-DETAIL'),
  ),
};

// Typed synthetic facts prove widget propagation only. They are not raw-wire
// byte evidence; the frozen core tests cover collection, BOM and redirects.
class _HttpPages implements BookSourceTransport, SourceHttpTransport {
  _HttpPages(this.pages);
  final Map<String, _Reply> pages;
  final requests = <SourceHttpRequest>[];
  final responses = <SourceHttpResponse>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final reply = pages[request.url.path];
    if (reply == null) {
      throw StateError('Unexpected fixture path: ${request.url.path}');
    }
    if (reply.failure case final failure?) throw failure;
    final response = SourceHttpResponse(
      statusCode: reply.status,
      headers: const {
        'set-cookie': ['sid=SYNTHETIC-RESPONSE-COOKIE'],
      },
      body: reply.body,
      bodyByteLength: reply.bytes,
      // Stage facts can contain a credential-bearing final URL. The original
      // source/book URL remains valid so browser validation reaches the stage.
      url: request.url.removeFragment().replace(
        userInfo: reply.responseUserInfo
            ? _responseUserInfo
            : request.url.userInfo,
      ),
    );
    responses.add(response);
    return response;
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError('The HTTP pipeline must call send');
}

class _Fixture {
  _Fixture._(this.source, this.transport, this.tocPath, this.canaries);
  factory _Fixture(bool json, {String tocPath = '/toc', bool canaries = true}) {
    final source = _source(json, canaries: canaries);
    final toc = _address(tocPath, canaries: canaries);
    return _Fixture._(
      source,
      _HttpPages({
        '/search': _Reply(
          json
              ? '{"items":[{"name":"Fixture Book","url":"/book"}]}'
              : '<div class="item"><a href="/book">Fixture Book</a></div>',
        ),
        '/book': _Reply(
          json
              ? jsonEncode({'name': 'Fixture Book', 'toc': toc})
              : '<h1>Fixture Book</h1><a class="toc" href="${htmlEscape.convert(toc)}">TOC</a>',
        ),
        tocPath: _Reply(
          json
              ? '{"items":[{"name":"One","url":"/chapter"}]}'
              : '<ul><li><a href="/chapter">One</a></li></ul>',
        ),
        '/chapter': _Reply(
          json
              ? '{"text":"Recovered content"}'
              : '<div id="content">Recovered content</div>',
        ),
      }),
      tocPath,
      canaries,
    );
  }
  final Map<String, dynamic> source;
  final _HttpPages transport;
  final String tocPath;
  final bool canaries;

  HtmlBook get book => HtmlBook(
    url: Uri.parse('$_origin/book'),
    rawAddress: _address('/book', canaries: canaries),
    title: 'Direct Book',
  );

  SourceChapter get chapter => SourceChapter.fromAddress(
    'One',
    _address('/chapter', canaries: canaries),
    bookUrl: book.url,
  );
}

// The trial route uses the product HTTP transport. Its synthetic server needs
// a real client instead of Flutter's default empty-400 widget-test override.
class _LoopbackHttpOverrides extends HttpOverrides {}

class _EmptyLegacy implements BookSourceTransport {
  final paths = <String>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    expect(stage, BookSourceStage.search);
    paths.add(path);
    return '';
  }
}

// A document adapter double exercises the existing rendered stage boundary;
// it is not evidence of any platform WebView or its HTTP response.
class _EmptyDocument implements BookSourceWebViewAdapter {
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

class _DocumentFactory extends BookSourceWebViewAdapterFactory {
  _DocumentFactory(this.document) : super(sourceRef: _origin);
  final _EmptyDocument document;
  @override
  BookSourceWebViewAdapter create() => document;
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  // Like the existing store/widget harness, real work gets real time. Native
  // FRB futures must not be waited on with pumpAndSettle in the fake zone.
  for (var attempt = 0; attempt < 250; attempt++) {
    await tester.pump();
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  expect(
    finder,
    findsOneWidget,
    reason: 'bounded wait for the actual UI outcome',
  );
}

Future<void> _routeFrames(WidgetTester tester) async {
  for (var frame = 0; frame < 10; frame++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
  await tester.pumpAndSettle(
    const Duration(milliseconds: 50),
    EnginePhase.sendSemanticsUpdate,
    const Duration(seconds: 5),
  );
}

Future<void> _withStore(
  WidgetTester tester,
  Future<void> Function(ShelfService) body, {
  double width = 960,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 900);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.runAsync(() async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    try {
      await body(ShelfService(store));
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await store.close();
    }
  });
  expect(tester.takeException(), isNull);
}

Finder _errorAt(String address) => find.byWidgetPredicate(
  (widget) => widget is Text && (widget.data?.contains(address) ?? false),
  description: 'visible stage error containing its safe address',
);

String _stageWord(BookSourceStage stage) => switch (stage) {
  BookSourceStage.search => '搜索',
  BookSourceStage.bookInfo => '详情',
  BookSourceStage.tableOfContents => '目录',
  BookSourceStage.content => '正文',
  _ => throw StateError('Not a response stage'),
};

void _assertError(
  WidgetTester tester, {
  required String address,
  required BookSourceStage stage,
  required _Fault fault,
  required bool json,
  bool reader = false,
  bool unknown = false,
  Locale locale = const Locale('en'),
}) {
  final finder = _errorAt(address);
  expect(finder, findsOneWidget);
  final text = tester.widget<Text>(finder);
  final message = text.data!;
  final word = _stageWord(stage);
  expect(message, contains(word));
  expect(message, contains(address));
  final context = tester.element(finder);
  final l10n = AppLocalizations.of(context);
  expect(Localizations.localeOf(context), locale);
  final prefix = locale.languageCode == 'en'
      ? (reader ? 'Loading the chapter failed: ' : 'Reading failed: ')
      : locale.scriptCode == 'Hant'
      ? (reader ? '章節讀取失敗：' : '讀取失敗：')
      : (reader ? '章节读取失败：' : '读取失败：');
  expect(message, startsWith(prefix));
  // Isolate the raw stage data from the observed Text and verify the actual
  // ARB wrapper. Independent facts below prevent a self-comparison assertion.
  final diagnostic = message.substring(message.indexOf(word));
  expect(
    message,
    reader
        ? l10n.chapterLoadFailed(diagnostic)
        : l10n.readSourceFailed(diagnostic),
  );
  if (fault == _Fault.timeout) {
    expect(diagnostic, contains('请求超时'));
    expect(diagnostic, isNot(contains('响应为空')));
  } else if (json) {
    expect(diagnostic, contains('响应不是 JSON（可能是错误页）'));
    if (fault == _Fault.blocked) expect(diagnostic, contains(_blockedBody));
  } else {
    expect(diagnostic, contains(fault == _Fault.empty ? '响应为空' : '响应未匹配到内容'));
  }
  if (unknown || fault == _Fault.timeout) {
    expect(message, isNot(matches(RegExp(r'HTTP\s+\d+'))));
    expect(message, isNot(matches(RegExp(r'\d+\s*字节'))));
  } else {
    expect(message, contains(fault == _Fault.empty ? 'HTTP 200' : 'HTTP 403'));
    final bytes = fault == _Fault.empty ? 0 : _blockedBytes;
    expect(message, matches(RegExp('(?:^|[^0-9])$bytes\\s*字节')));
  }
  for (final canary in [
    'SYNTHETIC-USER',
    'SYNTHETIC-PASSWORD',
    'SYNTHETIC-QUERY',
    'SYNTHETIC-FRAGMENT',
    'SYNTHETIC-AUTH',
    'SYNTHETIC-COOKIE',
    'SYNTHETIC-HEADER',
    'SYNTHETIC-OPTION',
    'SYNTHETIC-POST-BODY',
    'SYNTHETIC-RESPONSE-COOKIE',
    'SYNTHETIC-TIMEOUT-DETAIL',
    'Authorization',
    'set-cookie',
    '{"method"',
    'Bad state:',
    '目录页为空',
  ]) {
    expect(message, isNot(contains(canary)));
  }
  expect(text.maxLines, isNull);
  expect(text.overflow, isNot(TextOverflow.ellipsis));
  expect(text.semanticsLabel, anyOf(isNull, message));
  final paragraph = tester.renderObject<RenderParagraph>(finder);
  expect(paragraph.softWrap, isTrue);
  expect(paragraph.didExceedMaxLines, isFalse);
  final rect = tester.getRect(finder);
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(tester.view.physicalSize.width));
  expect(rect.bottom, lessThanOrEqualTo(tester.view.physicalSize.height));
}

String? _header(SourceHttpRequest request, String name) {
  for (final entry in request.headers.entries) {
    if (entry.key.toLowerCase() == name.toLowerCase()) return entry.value;
  }
  return null;
}

void _assertRequests(
  _Fixture fixture,
  List<String> paths, {
  String method = 'POST',
  bool options = true,
}) {
  expect(fixture.transport.requests.map((request) => request.url.path), paths);
  final last = fixture.transport.requests.last;
  expect(last.method, method);
  if (fixture.canaries) {
    expect(last.url.userInfo, isEmpty);
    if (fixture.transport.pages[last.url.path]!.responseUserInfo) {
      expect(fixture.transport.responses.last.url.userInfo, _responseUserInfo);
    }
    expect(_header(last, 'Authorization'), 'Bearer SYNTHETIC-AUTH');
    expect(_header(last, 'Cookie'), 'sid=SYNTHETIC-COOKIE');
    expect(_header(last, 'X-Private'), 'SYNTHETIC-HEADER');
  }
  if (options) {
    // The existing request encoder may carry the fragment canary as encoded
    // query text. Pin its presence without imposing a new URL-normalization rule.
    expect(last.url.queryParameters['token'], startsWith('SYNTHETIC-QUERY'));
    expect('${last.url}', contains('SYNTHETIC-FRAGMENT'));
    expect(_header(last, 'X-Option'), 'SYNTHETIC-OPTION');
    expect(last.body, 'SYNTHETIC-POST-BODY');
  }
}

Future<void> _browserFailure(
  WidgetTester tester,
  ShelfService shelf, {
  required _Fixture fixture,
  required BookSourceStage stage,
  required _Fault fault,
  required bool json,
  Locale locale = testLocale,
}) async {
  final path = stage == BookSourceStage.search
      ? '/search'
      : stage == BookSourceStage.bookInfo
      ? '/book'
      : fixture.tocPath;
  fixture.transport.pages[path] = _failure(fault);
  await tester.pumpWidget(
    localizedApp(
      locale: locale,
      home: HtmlSourceBrowser(
        source: fixture.source,
        keyword: 'Fixture',
        service: shelf,
        transport: fixture.transport,
        directBook: stage == BookSourceStage.search ? null : fixture.book,
      ),
    ),
  );
  await _waitFor(tester, _errorAt('$_safeOrigin$path'));
  _assertError(
    tester,
    address: '$_safeOrigin$path',
    stage: stage,
    fault: fault,
    json: json,
    locale: locale,
  );
  _assertRequests(
    fixture,
    stage == BookSourceStage.tableOfContents ? ['/book', path] : [path],
  );
  expect(find.byType(CircularProgressIndicator), findsNothing);
  expect(await shelf.find(_origin, '${fixture.book.url}'), isNull);
}

Future<void> _readerFailure(
  WidgetTester tester,
  ShelfService shelf, {
  required bool json,
  required _Fault fault,
  required Locale locale,
}) async {
  final fixture = _Fixture(json);
  fixture.transport.pages['/chapter'] = _failure(fault);
  final id = await shelf.ensureBook(fixture.source, fixture.book);
  await tester.pumpWidget(
    localizedApp(
      locale: locale,
      home: OnlineReaderPage(
        pipeline: openBookSourcePipeline(
          fixture.source,
          fixture.transport,
          hostState: shelf.hostState,
        ),
        book: fixture.book,
        bookId: id,
        chapters: [fixture.chapter],
        service: shelf,
        convert: (text, _) => text,
      ),
    ),
  );
  await _waitFor(tester, _errorAt('$_safeOrigin/chapter'));
  _assertError(
    tester,
    address: '$_safeOrigin/chapter',
    stage: BookSourceStage.content,
    fault: fault,
    json: json,
    reader: true,
    locale: locale,
  );
  _assertRequests(fixture, ['/chapter']);
  final l10n = AppLocalizations.of(
    tester.element(find.byType(OnlineReaderPage)),
  );
  expect(
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, l10n.reloadChapter))
        .onPressed,
    isNotNull,
  );
  expect(find.byType(CircularProgressIndicator), findsNothing);
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  for (final locale in testSupportedLocales) {
    for (final width in [360.0, 960.0]) {
      testWidgets(
        'browser HTML failed TOC ${locale.toLanguageTag()} width ${width.toInt()}',
        (tester) async {
          await _withStore(tester, (shelf) async {
            await _browserFailure(
              tester,
              shelf,
              fixture: _Fixture(false, tocPath: _longTocPath),
              stage: BookSourceStage.tableOfContents,
              fault: _Fault.blocked,
              json: false,
              locale: locale,
            );
          }, width: width);
        },
      );
    }
  }

  const browserCases = [
    (json: true, stage: BookSourceStage.search, fault: _Fault.empty),
    (json: false, stage: BookSourceStage.search, fault: _Fault.timeout),
    (json: true, stage: BookSourceStage.bookInfo, fault: _Fault.blocked),
    (json: false, stage: BookSourceStage.bookInfo, fault: _Fault.timeout),
    (json: false, stage: BookSourceStage.tableOfContents, fault: _Fault.empty),
    (json: true, stage: BookSourceStage.tableOfContents, fault: _Fault.blocked),
    (json: true, stage: BookSourceStage.tableOfContents, fault: _Fault.timeout),
  ];
  for (final row in browserCases) {
    testWidgets(
      'browser ${row.json ? 'JSON' : 'HTML'} ${row.stage.name} ${row.fault.name} facts use incumbent ARB',
      (tester) async {
        await _withStore(
          tester,
          (shelf) => _browserFailure(
            tester,
            shelf,
            fixture: _Fixture(row.json),
            stage: row.stage,
            fault: row.fault,
            json: row.json,
            locale: const Locale('en'),
          ),
        );
      },
    );
  }

  for (final locale in testSupportedLocales) {
    testWidgets(
      'reader HTML failed content ${locale.toLanguageTag()} uses chapter ARB',
      (tester) async {
        await _withStore(
          tester,
          (shelf) => _readerFailure(
            tester,
            shelf,
            json: false,
            fault: _Fault.blocked,
            locale: locale,
          ),
        );
      },
    );
  }
  for (final fault in [_Fault.empty, _Fault.timeout]) {
    testWidgets('reader JSON content ${fault.name} keeps diagnostic family', (
      tester,
    ) async {
      await _withStore(
        tester,
        (shelf) => _readerFailure(
          tester,
          shelf,
          json: true,
          fault: fault,
          locale: const Locale('en'),
        ),
      );
    });
  }

  for (final json in [false, true]) {
    testWidgets(
      'reader ${json ? 'JSON' : 'HTML'} keeps the hook error diagnostic',
      (tester) async {
        await _withStore(tester, (shelf) async {
          final fixture = _Fixture(json, canaries: false);
          final url =
              '$_origin/unused,${jsonEncode({'js': 'throw new ReferenceError("SYNTHETIC-READER-HOOK")'})}';
          fixture.source['loginCheckJs'] =
              'java.ajax(${jsonEncode(url)}); result;';
          final id = await shelf.ensureBook(fixture.source, fixture.book);
          await tester.pumpWidget(
            localizedApp(
              locale: const Locale('en'),
              home: OnlineReaderPage(
                pipeline: openBookSourcePipeline(
                  fixture.source,
                  fixture.transport,
                  hostState: shelf.hostState,
                ),
                book: fixture.book,
                bookId: id,
                chapters: [fixture.chapter],
                service: shelf,
                convert: (text, _) => text,
              ),
            ),
          );
          final failure = find.byWidgetPredicate(
            (widget) =>
                widget is Text &&
                (widget.data?.startsWith(
                      'Loading the chapter failed: js: ReferenceError: SYNTHETIC-READER-HOOK',
                    ) ??
                    false),
          );
          await _waitFor(tester, failure);
          final message = tester.widget<Text>(failure).data!;
          expect(message, isNot(contains("converting from js 'bridge'")));
          expect(
            fixture.transport.requests.map((request) => request.url.path),
            ['/chapter'],
          );
          expect(find.byType(CircularProgressIndicator), findsNothing);
        });
      },
    );
  }

  for (final rendered in [false, true]) {
    for (final json in [false, true]) {
      testWidgets(
        'browser ${json ? 'JSON' : 'HTML'} ${rendered ? 'rendered' : 'legacy'} ${json ? 'keeps unknown facts on parse failure' : 'keeps successful empty result'}',
        (tester) async {
          await _withStore(tester, (shelf) async {
            final source = _source(json, canaries: false);
            final legacy = _EmptyLegacy();
            final document = _EmptyDocument();
            if (rendered) source['searchUrl'] = '/search,{"webView":true}';
            final BookSourcePipeline pipeline = json
                ? JsonSourcePipeline(
                    source,
                    legacy,
                    hostState: shelf.hostState,
                    webViewFactory: _DocumentFactory(document),
                  )
                : HtmlSourcePipeline(
                    source,
                    legacy,
                    hostState: shelf.hostState,
                    webViewFactory: _DocumentFactory(document),
                  );
            await tester.pumpWidget(
              localizedApp(
                locale: const Locale('en'),
                home: HtmlSourceBrowser(
                  source: source,
                  keyword: 'Fixture',
                  service: shelf,
                  pipeline: pipeline,
                ),
              ),
            );
            if (json) {
              await _waitFor(tester, _errorAt('$_safeOrigin/search'));
              _assertError(
                tester,
                address: '$_safeOrigin/search',
                stage: BookSourceStage.search,
                fault: _Fault.empty,
                json: true,
                unknown: true,
              );
            } else {
              final l10n = AppLocalizations.of(
                tester.element(find.byType(HtmlSourceBrowser)),
              );
              await _waitFor(tester, find.text(l10n.booksFound(0)));
              expect(_errorAt('$_safeOrigin/search'), findsNothing);
              expect(find.textContaining('Reading failed:'), findsNothing);
            }
            expect(find.byType(CircularProgressIndicator), findsNothing);
            if (rendered) {
              expect(legacy.paths, isEmpty);
              expect(document.requests.single.url, '$_origin/search');
              expect(document.disposed, isTrue);
            } else {
              expect(legacy.paths, ['$_origin/search']);
              expect(document.requests, isEmpty);
            }
          });
        },
      );
    }
  }

  testWidgets(
    'browser empty HTML info keeps hit fallback and a valid catalog',
    (tester) async {
      await _withStore(tester, (shelf) async {
        final fixture = _Fixture(false, canaries: false);
        fixture.transport.pages['/book'] = const _Reply('', bytes: 0);
        (fixture.source['ruleBookInfo'] as Map)['tocUrl'] = '@js:"/toc"';
        await tester.pumpWidget(
          localizedApp(
            home: HtmlSourceBrowser(
              source: fixture.source,
              keyword: '',
              directBook: fixture.book,
              service: shelf,
              transport: fixture.transport,
            ),
          ),
        );
        await _waitFor(tester, find.text('One'));
        expect(find.text('Direct Book'), findsOneWidget);
        expect(find.textContaining('读取失败'), findsNothing);
        _assertRequests(
          fixture,
          ['/book', '/toc'],
          method: 'GET',
          options: false,
        );
      });
    },
  );

  testWidgets(
    'browser reader retry and back preserve catalog after actual content failures',
    (tester) async {
      await _withStore(tester, (shelf) async {
        final fixture = _Fixture(false);
        fixture.transport.pages['/chapter'] = _failure(_Fault.blocked);
        await tester.pumpWidget(
          localizedApp(
            locale: const Locale('en'),
            home: HtmlSourceBrowser(
              source: fixture.source,
              keyword: '',
              directBook: fixture.book,
              service: shelf,
              transport: fixture.transport,
            ),
          ),
        );
        await _waitFor(tester, find.text('One'));
        await tester.tap(find.text('One'));
        await _waitFor(tester, _errorAt('$_safeOrigin/chapter'));
        await _routeFrames(tester);
        expect(find.byType(OnlineReaderPage), findsOneWidget);
        _assertError(
          tester,
          address: '$_safeOrigin/chapter',
          stage: BookSourceStage.content,
          fault: _Fault.blocked,
          json: false,
          reader: true,
        );
        _assertRequests(
          fixture,
          ['/book', '/toc', '/chapter'],
          method: 'GET',
          options: false,
        );
        fixture.transport.pages['/chapter'] = _failure(_Fault.empty);
        final l10n = AppLocalizations.of(
          tester.element(find.byType(OnlineReaderPage)),
        );
        await tester.tap(find.widgetWithText(TextButton, l10n.reloadChapter));
        await _waitFor(tester, find.textContaining('正文响应为空'));
        _assertError(
          tester,
          address: '$_safeOrigin/chapter',
          stage: BookSourceStage.content,
          fault: _Fault.empty,
          json: false,
          reader: true,
        );
        _assertRequests(
          fixture,
          ['/book', '/toc', '/chapter', '/chapter'],
          method: 'GET',
          options: false,
        );
        await tester.tap(find.byType(BackButton));
        await _routeFrames(tester);
        await _waitFor(tester, find.text('One'));
        expect(find.byType(OnlineReaderPage), findsNothing);
        expect(find.byType(HtmlSourceBrowser), findsOneWidget);
        expect(find.text('Fixture Book'), findsOneWidget);
      });
    },
  );

  testWidgets(
    'source trial pushes real browser and keeps its failure off the background route',
    (tester) async {
      await HttpOverrides.runWithHttpOverrides(
        () => _withStore(tester, (shelf) async {
          // SourceTrialPage has no transport injection seam: a bounded loopback
          // server exercises its actual navigation and product HTTP transport.
          final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
          final seen = <(String, String)>[];
          server.listen((request) async {
            seen.add((request.method, request.uri.path));
            request.response.statusCode = 403;
            request.response.headers.set(
              'content-type',
              'text/plain; charset=utf-8',
            );
            request.response.add(utf8.encode(_blockedBody));
            await request.response.close();
          });
          try {
            final origin = 'http://127.0.0.1:${server.port}';
            final source = _source(true, origin: origin, canaries: false);
            await tester.pumpWidget(
              localizedApp(
                locale: const Locale('en'),
                home: SourceTrialPage(
                  sources: [
                    ImportedBookSource(id: 'synthetic-trial', data: source),
                  ],
                  service: shelf,
                ),
              ),
            );
            final l10n = AppLocalizations.of(
              tester.element(find.byType(SourceTrialPage)),
            );
            await tester.enterText(find.byType(TextField), 'Fixture');
            await tester.ensureVisible(
              find.widgetWithText(FilledButton, l10n.search),
            );
            await tester.tap(find.widgetWithText(FilledButton, l10n.search));
            await _waitFor(tester, _errorAt('$origin/search'));
            await _routeFrames(tester);
            _assertError(
              tester,
              address: '$origin/search',
              stage: BookSourceStage.search,
              fault: _Fault.blocked,
              json: true,
            );
            expect(
              find.descendant(
                of: find.byType(HtmlSourceBrowser),
                matching: _errorAt('$origin/search'),
              ),
              findsOneWidget,
            );
            expect(
              find.byType(SourceTrialPage, skipOffstage: false),
              findsOneWidget,
            );
            expect(seen, [('GET', '/search')]);
            await tester.tap(find.byType(BackButton));
            await _routeFrames(tester);
            expect(find.byType(HtmlSourceBrowser), findsNothing);
            expect(find.byType(SourceTrialPage), findsOneWidget);
          } finally {
            await server.close(force: true);
          }
        }),
        _LoopbackHttpOverrides(),
      );
    },
  );
}
