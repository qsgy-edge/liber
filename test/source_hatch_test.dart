import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/inappwebview_source_hatch.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_hatch.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_rate_limiter.dart';

import 'native_library.dart';

/// The confirmation surface a test installs: it records what the runtime asked
/// for — naming the source, the member and the address — and answers what the
/// test programs, so refuse, answer, timeout and cancel are all driven without a
/// window.
class _TestSurface implements SourceHatchSurface {
  _TestSurface({
    this.answer = SourceHatchAnswer.refused,
    this.blocking = false,
    this.delay = Duration.zero,
    this.fetchesImage = false,
  });

  SourceHatchAnswer answer;

  /// Whether the user never answers, so only the cap or the analysis's
  /// cancellation can end the wait.
  final bool blocking;

  /// How long the user works before answering.
  final Duration delay;

  /// Whether the surface drives the image request after the confirmation, as
  /// the application's own surface does.
  final bool fetchesImage;

  /// The cookie string the surface hands the source's jar for the confirmed
  /// page, the write the visible page's page-finished hook makes.
  String pageCookies = '';

  final requests = <SourceHatchRequest>[];
  final images = <SourceHatchImage>[];
  final stops = <SourceHatchStop>[];
  final entered = Completer<void>();
  bool stopped = false;

  @override
  Future<SourceHatchAnswer> interact(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    requests.add(request);
    stops.add(stop);
    unawaited(stop.ended.then((_) => stopped = true));
    if (!entered.isCompleted) entered.complete();
    if (pageCookies.isNotEmpty && request.onPageCookies != null) {
      await request.onPageCookies!(request.url, pageCookies);
    }
    if (fetchesImage && request.fetchImage != null) {
      images.add(await request.fetchImage!());
    }
    if (blocking) return Completer<SourceHatchAnswer>().future;
    if (delay > Duration.zero) await Future<void>.delayed(delay);
    return answer;
  }
}

/// One fixture site that also answers the source-host requests, so a pipeline
/// row can see what the image request and the verification refetch put on the
/// wire.
class _Transport implements SourceHttpTransport, BookSourceTransport {
  /// The one search page the fixture site answers, so the element rules have
  /// something to extract before the hatch runs.
  static const searchPage =
      '<div class="item"><h3><a href="/book/">书</a></h3></div>';

  final pages = <String, String>{};

  /// The bytes an image request answers, when a caller wants a response whose
  /// decoded text is not the same size as the bytes.
  Uint8List? imageBytes;

  final requests = <SourceHttpRequest>[];

  String _body(String path) =>
      pages[path] ?? (path == '/search' ? searchPage : 'refetched:$path');

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => _body(Uri.parse(path).path);

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final bytes = request.readBytes ? imageBytes : null;
    return SourceHttpResponse(
      statusCode: 200,
      // A binary response's decoded text is the transport's own business; this
      // fake answers the bytes as characters, which is what the escaping cap
      // sees.
      body: bytes == null
          ? _body(request.url.path)
          : String.fromCharCodes(bytes),
      url: request.url,
      headers: const {},
      // Only the verification-code image asks for bytes; the transport contract
      // answers them only then.
      bodyBytes:
          bytes ??
          (request.readBytes
              ? Uint8List.fromList(const [137, 80, 78, 71])
              : null),
    );
  }
}

Map<String, dynamic> _source(String nameRule) => {
  'bookSourceUrl': 'http://source.test',
  'bookSourceName': '验证源',
  'header': '{"X-Contract":"yes"}',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': 'class.item',
    'name': nameRule,
    'bookUrl': 'tag.a@href',
  },
};

const _codeUrl = 'http://source.test/captcha';
const _pageUrl = 'http://source.test/verify';

Future<Object?> _run(
  InProcessSourceScriptRuntime runtime,
  String script, {
  Duration timeout = const Duration(seconds: 15),
}) => runtime.evaluate(
  source: script,
  input: const {
    'sourceKey': 'http://source.test',
    'source': <String, Object?>{
      'bookSourceUrl': 'http://source.test',
      'bookSourceName': '验证源',
    },
    'headers': <String, String>{},
  },
  timeout: timeout,
);

void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);
  tearDown(() => SourceHatchSurface.installed = null);

  group('the confirmed hatches through a pipeline', () {
    test('a refused member fails the stage and nothing is shown', () async {
      final surface = _TestSurface();
      SourceHatchSurface.installed = surface;
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.getVerificationCode("$_codeUrl")'),
        _Transport(),
      );

      await expectLater(
        pipeline.search('书'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'verification')
              .having(
                (error) => error.message,
                'message',
                contains('java.getVerificationCode'),
              ),
        ),
      );
      final asked = surface.requests.single;
      expect(asked.member, 'java.getVerificationCode');
      expect(asked.url, _codeUrl);
      expect(asked.sourceRef, 'http://source.test');
      expect(asked.sourceName, '验证源');
      expect(asked.waits, isTrue);
      // The image request happens only after the user agreed, and the user did
      // not.
      expect(surface.images, isEmpty);
    });

    test('an answered verification code becomes the rule value', () async {
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        fetchesImage: true,
      );
      SourceHatchSurface.installed = surface;
      final transport = _Transport();
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.getVerificationCode("$_codeUrl")'),
        transport,
      );

      final hits = await pipeline.search('书');
      expect(hits.single.title, '1234');
      // The image came through the source's own request path: the rule's header
      // rule reached the wire, and the bytes the surface got are the response's.
      expect(surface.images.single.bytes, [137, 80, 78, 71]);
      final imageRequest = transport.requests.last;
      expect('${imageRequest.url}', _codeUrl);
      expect(imageRequest.method, 'GET');
      expect(imageRequest.headers['X-Contract'], 'yes');
    });

    test('the image request goes through the source rate limiter', () async {
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        fetchesImage: true,
      );
      SourceHatchSurface.installed = surface;
      final source = _source(
        'tag.h3@tag.a@text@js:java.getVerificationCode("$_codeUrl")',
      );
      source['bookSourceUrl'] = 'http://rate.test';
      source['concurrentRate'] = '1000';
      final pipeline = HtmlSourcePipeline(source, _Transport());

      await pipeline.search('书');
      // The frozen image loader does not pass `withLimit`; keeping the request
      // inside the source's own rate is this product's stricter path (ADR 0011
      // §4), and the record is what proves it was entered.
      expect(SourceRateLimiter.shared.recordOf('http://rate.test'), isNotNull);
    });

    test('startBrowserAwait refetches with the sources own headers', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.answered(''));
      SourceHatchSurface.installed = surface;
      final transport = _Transport();
      final pipeline = HtmlSourcePipeline(
        _source(
          'tag.h3@tag.a@text@js:java.startBrowserAwait("$_pageUrl", "标题").body()',
        ),
        transport,
      );

      final hits = await pipeline.search('书');
      expect(hits.single.title, 'refetched:/verify');
      final asked = surface.requests.single;
      expect(asked.kind, SourceHatchKind.waitingPage);
      expect(asked.title, '标题');
      expect(asked.refetchAfterSuccess, isTrue);
      final refetch = transport.requests.last;
      expect('${refetch.url}', _pageUrl);
      expect(refetch.headers['X-Contract'], 'yes');
    });

    test('startBrowserAwait answers the frozen response shape', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.answered(''));
      SourceHatchSurface.installed = surface;
      final pipeline = HtmlSourcePipeline(
        _source(
          'tag.h3@tag.a@text@js:const r = java.startBrowserAwait("$_pageUrl", "t"); '
          'String(r.code()) + "|" + r.url() + "|" + r.headers().get("x-path")',
        ),
        _Transport(),
      );

      final hits = await pipeline.search('书');
      // The frozen `StrResponse(url, body)`: 200, the address, no headers.
      expect(hits.single.title, '200|$_pageUrl|null');
    });

    test(
      'startBrowserAwait takes the pages own HTML when it is not refetching',
      () async {
        final surface = _TestSurface(
          answer: SourceHatchAnswer.answered('<html>页面</html>'),
        );
        SourceHatchSurface.installed = surface;
        final transport = _Transport();
        final pipeline = HtmlSourcePipeline(
          _source(
            'tag.h3@tag.a@text@js:java.startBrowserAwait("$_pageUrl", "t", false).body()',
          ),
          transport,
        );

        final hits = await pipeline.search('书');
        expect(hits.single.title, '<html>页面</html>');
        expect(surface.requests.single.refetchAfterSuccess, isFalse);
        expect(
          transport.requests.where((request) => '${request.url}' == _pageUrl),
          isEmpty,
        );
      },
    );

    test(
      'startBrowser and openUrl show the page and the stage goes on',
      () async {
        final surface = _TestSurface(answer: SourceHatchAnswer.presented);
        SourceHatchSurface.installed = surface;
        final browser = HtmlSourcePipeline(
          _source(
            'tag.h3@tag.a@text@js:java.startBrowser("$_pageUrl", "标题"); "shown"',
          ),
          _Transport(),
        );
        expect((await browser.search('书')).single.title, 'shown');
        expect(surface.requests.single.kind, SourceHatchKind.page);
        expect(surface.requests.single.waits, isFalse);

        final open = HtmlSourcePipeline(
          _source('tag.h3@tag.a@text@js:java.openUrl("$_pageUrl"); "opened"'),
          _Transport(),
        );
        expect((await open.search('书')).single.title, 'opened');
        expect(surface.requests.last.kind, SourceHatchKind.openUrl);
        expect(surface.requests.last.member, 'java.openUrl');
      },
    );

    test('a refused openUrl is not a stage failure', () async {
      final surface = _TestSurface();
      SourceHatchSurface.installed = surface;
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.openUrl("$_pageUrl"); "opened"'),
        _Transport(),
      );
      // The frozen `openUrl` returns nothing whether or not the confirmation is
      // accepted; only the page is missing.
      expect((await pipeline.search('书')).single.title, 'opened');
      expect(surface.requests.single.member, 'java.openUrl');
    });

    test('the confirmed pages cookies reach the refetch', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.answered(''))
        ..pageCookies = 'sid=fromPage';
      SourceHatchSurface.installed = surface;
      final transport = _Transport();
      final pipeline = HtmlSourcePipeline(
        _source(
          'tag.h3@tag.a@text@js:'
          'java.startBrowserAwait("$_pageUrl", "t").body()',
        ),
        transport,
      );

      final hits = await pipeline.search('书');
      expect(hits.single.title, 'refetched:/verify');
      // The session the page established is the one the refetch carries: the
      // frozen `WebViewActivity.onPageFinished` writes it into the source's own
      // cookie store, and every later request reads that store.
      expect(transport.requests.last.headers['Cookie'], 'sid=fromPage');
    });

    test('a hatch address with an option tail is normalized', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.presented);
      SourceHatchSurface.installed = surface;
      final tail =
          ',${jsonEncode({
            'headers': {'X-Tail': '1'},
          })}';
      final pipeline = HtmlSourcePipeline(
        _source(
          'tag.h3@tag.a@text@js:'
          'java.startBrowser("$_pageUrl" + ${jsonEncode(tail)}, "标题"); '
          '"shown"',
        ),
        _Transport(),
      );

      expect((await pipeline.search('书')).single.title, 'shown');
      final asked = surface.requests.single;
      // The page loads (and the confirmation names) the address before the tail,
      // with the tail's own headers on the load — what the frozen `AnalyzeUrl`
      // normalizes and what `WebViewActivity` uses.
      expect(asked.url, _pageUrl);
      expect(asked.headers['X-Tail'], '1');
      expect(asked.headers['X-Contract'], 'yes');
      expect(asked.headers['User-Agent'], isNotNull);
    });

    test('a hatch address keeps its query through the shaping', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.presented);
      SourceHatchSurface.installed = surface;
      const url = 'http://source.test/verify?x=%E4%B9%A6&y=1';
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.startBrowser("$url"); "ran"'),
        _Transport(),
      );

      expect((await pipeline.search('书')).single.title, 'ran');
      // The address the page loads is the script's own, query included: the
      // shaping strips the option tail and merges its headers, and touches
      // nothing else.
      expect(surface.requests.single.url, url);
    });

    test('cancelling the analysis ends a parked hatch', () async {
      final surface = _TestSurface(blocking: true);
      SourceHatchSurface.installed = surface;
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.getVerificationCode("$_codeUrl")'),
        _Transport(),
      );

      final pending = pipeline.search('书');
      await surface.entered.future.timeout(const Duration(seconds: 5));
      pipeline.cancel();
      await expectLater(
        pending,
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.category,
            'category',
            'cancelled',
          ),
        ),
      );
      // The wait's end reaches the surface, so what it shows is closed instead
      // of outliving the analysis.
      expect(surface.stops.single.ended, completes);
      await surface.stops.single.ended;
    });
  });

  group('the hatches through the script runtime', () {
    test('the product cap is five minutes', () {
      expect(sourceHatchWaitCap, const Duration(minutes: 5));
      expect(InProcessSourceScriptRuntime().hatchWaitCap, sourceHatchWaitCap);
    });

    test('the attempt and its outcome are in the source log', () async {
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        fetchesImage: true,
      );
      final runtime = InProcessSourceScriptRuntime(hatchSurface: surface);

      expect(
        await _run(runtime, 'java.getVerificationCode("$_codeUrl")'),
        '1234',
      );
      final log = runtime.messages
          .where((message) => message.kind == 'verification')
          .map((message) => message.message)
          .toList();
      expect(log.first, contains('java.getVerificationCode'));
      expect(log.first, contains(_codeUrl));
      expect(log.last, contains('用户已给出结果'));
    });

    test('a blank or closed answer is the frozen empty result', () async {
      final runtime = InProcessSourceScriptRuntime(
        hatchSurface: _TestSurface(answer: SourceHatchAnswer.answered('  ')),
      );
      await expectLater(
        _run(runtime, 'java.getVerificationCode("$_codeUrl")'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'verification')
              .having((error) => error.message, 'message', '验证结果为空'),
        ),
      );

      final closed = InProcessSourceScriptRuntime(
        hatchSurface: _TestSurface(answer: SourceHatchAnswer.closed),
      );
      await expectLater(
        _run(closed, 'java.getVerificationCode("$_codeUrl")'),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            '验证结果为空',
          ),
        ),
      );
    });

    test('the absolute cap ends a wait nobody answers', () async {
      final surface = _TestSurface(blocking: true);
      final runtime = InProcessSourceScriptRuntime(
        hatchSurface: surface,
        hatchWaitCap: const Duration(milliseconds: 120),
      );

      await expectLater(
        _run(runtime, 'java.startBrowserAwait("$_pageUrl", "t", false)'),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'verification')
              .having(
                (error) => error.message,
                'message',
                contains('java.startBrowserAwait'),
              ),
        ),
      );
      expect(
        runtime.messages.any(
          (message) =>
              message.kind == 'verification' && message.message.contains('超过'),
        ),
        isTrue,
      );
      await surface.stops.single.ended;
    });

    test('a hatch wait keeps the scripts own deadline, which still ends it', () async {
      // The user works for 700 ms while the script's whole budget is 600 ms: the
      // 200 ms of the script's own work after the answer can only finish if the
      // parked time did not consume the budget.
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        delay: const Duration(milliseconds: 700),
      );
      final runtime = InProcessSourceScriptRuntime(hatchSurface: surface);

      expect(
        await _run(
          runtime,
          'java.getVerificationCode("$_codeUrl"); '
          'const until = Date.now() + 200; while (Date.now() < until) {} "done"',
          timeout: const Duration(milliseconds: 600),
        ),
        'done',
      );

      // The same runtime is still bounded: a script that never returns after a
      // hatch dies at its own deadline.
      await expectLater(
        _run(
          runtime,
          'java.getVerificationCode("$_codeUrl"); while (true) {}',
          timeout: const Duration(milliseconds: 600),
        ),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.category,
            'category',
            'timeout',
          ),
        ),
      );
    });

    test('the park is taken for the hatch and released when it ends', () async {
      final paused = <BigInt>[];
      final resumed = <BigInt>[];
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        fetchesImage: true,
      );
      final runtime = InProcessSourceScriptRuntime(
        hatchSurface: surface,
        pauseDeadline: (id) async {
          paused.add(id);
          return true;
        },
        resumeDeadline: (id) async {
          resumed.add(id);
          return true;
        },
      );

      expect(
        await _run(runtime, 'java.getVerificationCode("$_codeUrl")'),
        '1234',
      );
      // One park around the interaction, released when the wait is over: a park
      // left behind would suspend the execution's deadline for good.
      expect(paused, hasLength(1));
      expect(resumed, paused);
    });

    test(
      'a hatch for an execution that is already gone shows nothing',
      () async {
        final surface = _TestSurface(
          answer: SourceHatchAnswer.answered('1234'),
        );
        var resumed = 0;
        final runtime = InProcessSourceScriptRuntime(
          hatchSurface: surface,
          pauseDeadline: (id) async => false,
          resumeDeadline: (id) async {
            resumed++;
            return false;
          },
        );

        await expectLater(
          _run(runtime, 'java.getVerificationCode("$_codeUrl")'),
          throwsA(
            isA<SourceScriptError>()
                .having((error) => error.category, 'category', 'policy')
                .having(
                  (error) => error.message,
                  'message',
                  contains('执行已经结束'),
                ),
          ),
        );
        // Nothing was shown for it, and nothing was released: there was no park.
        expect(surface.requests, isEmpty);
        expect(surface.images, isEmpty);
        expect(resumed, 0);
      },
    );

    test('the image cap counts the bytes that arrived', () async {
      // 40 NUL bytes are inside a 64-byte cap, but 240 characters once the
      // response's text is JSON-escaped; the transport's own cap is on bytes.
      final transport = _Transport()
        ..imageBytes = Uint8List.fromList(List<int>.filled(40, 0));
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('1234'),
        fetchesImage: true,
      );
      final runtime = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(
          transport: transport,
          maxResponseBytes: 64,
        ),
        hatchSurface: surface,
      );
      expect(
        await _run(runtime, 'java.getVerificationCode("$_codeUrl")'),
        '1234',
      );
      expect(surface.images.single.bytes, hasLength(40));

      // The cap still bites when the bytes themselves exceed it: the image is
      // the dialog's placeholder, and the member still takes the user's answer.
      transport.imageBytes = Uint8List.fromList(List<int>.filled(80, 0));
      final over = _TestSurface(
        answer: SourceHatchAnswer.answered('5678'),
        fetchesImage: true,
      );
      final capped = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(
          transport: transport,
          maxResponseBytes: 64,
        ),
        hatchSurface: over,
      );
      expect(
        await _run(capped, 'java.getVerificationCode("$_codeUrl")'),
        '5678',
      );
      expect(over.images.single.bytes, isNull);
      expect(over.images.single.failure, contains('cap'));
    });
  });

  group('the visible surface', () {
    /// One request to show: the kind does not matter for these rows, because
    /// nothing may be shown at all.
    SourceHatchRequest request({
      SourceHatchKind kind = SourceHatchKind.openUrl,
    }) => SourceHatchRequest(
      member: 'java.openUrl',
      kind: kind,
      sourceRef: 'http://source.test',
      sourceName: '验证源',
      url: _pageUrl,
    );

    /// One real PNG: `Image.memory` decodes it instead of failing the row.
    final pngBytes = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAADwAAAAUCAYAAACdDh9/AAAAGklEQVR42mP8//8/AybIQAEwCkYBo2AUjAAAAA/4/wGj1PDiAAAAAElFTkSuQmCC',
    );

    Future<void> pumpApp(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: sourceHatchNavigatorKey,
          home: const Scaffold(body: SizedBox()),
        ),
      );
      await tester.pump();
      addTearDown(
        () => sourceHatchNavigatorKey.currentState?.popUntil(
          (route) => route.isFirst,
        ),
      );
    }

    testWidgets('a wait that has already ended shows nothing', (tester) async {
      await pumpApp(tester);
      final stop = SourceHatchStop()..end();
      SourceHatchAnswer? answer;
      // The surface is driven through pumps rather than by awaiting it: a row
      // that awaited the call would sit on a dialog only the test's own frames
      // can close.
      unawaited(
        InAppWebViewSourceHatch()
            .interact(request(), stop)
            .then((value) => answer = value),
      );
      await tester.pump();
      // The confirmation included: a source that has stopped waiting is not
      // still asking whether its page may be shown, so not even a dialog is
      // built.
      expect(find.byType(AlertDialog), findsNothing);
      await tester.pump();
      expect(find.byType(SourceHatchPage), findsNothing);
      expect(answer?.outcome, SourceHatchOutcome.refused);
    });

    testWidgets('a stop while the confirmation is up refuses it', (
      tester,
    ) async {
      await pumpApp(tester);
      final stop = SourceHatchStop();
      SourceHatchAnswer? answer;
      unawaited(
        InAppWebViewSourceHatch()
            .interact(request(), stop)
            .then((value) => answer = value),
      );
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);

      stop.end();
      await tester.pump();
      await tester.pump();
      expect(answer?.outcome, SourceHatchOutcome.refused);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(SourceHatchPage), findsNothing);
    });

    testWidgets('the confirmations buttons answer what they name', (
      tester,
    ) async {
      await pumpApp(tester);

      // 取消 is the default the focus lands on; a tap on it answers no.
      bool? cancelled;
      unawaited(
        showSourceHatchConfirmation(
          sourceHatchNavigatorKey.currentContext!,
          request(kind: SourceHatchKind.waitingPage),
        ).then((value) => cancelled = value),
      );
      await tester.pump();
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump();
      expect(cancelled, isFalse);

      // 打开页面 answers yes — the answer the page route is opened for.
      bool? confirmed;
      unawaited(
        showSourceHatchConfirmation(
          sourceHatchNavigatorKey.currentContext!,
          request(kind: SourceHatchKind.waitingPage),
        ).then((value) => confirmed = value),
      );
      await tester.pump();
      await tester.tap(find.text('打开页面'));
      await tester.pump();
      await tester.pump();
      expect(confirmed, isTrue);
    });

    testWidgets('the image dialog answers the code the user typed', (
      tester,
    ) async {
      await pumpApp(tester);
      SourceHatchAnswer? answer;
      unawaited(
        showSourceHatchImageDialog(
          sourceHatchNavigatorKey.currentContext!,
          request: request(kind: SourceHatchKind.waitingImage),
          image: SourceHatchImage(pngBytes),
          stop: SourceHatchStop(),
        ).then((value) => answer = value),
      );
      await tester.pump();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byKey(const ValueKey('hatch-image')), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('hatch-code')), '测试码');
      await tester.tap(find.text('确定'));
      await tester.pump();
      await tester.pump();
      expect(answer?.outcome, SourceHatchOutcome.answered);
      expect(answer?.text, '测试码');
    });

    testWidgets('both dialogs fit the window they are shown in', (
      tester,
    ) async {
      // A scaled 1280-wide display: the logical window is narrower than the
      // pixels, which is where an unbounded dialog runs off the screen.
      tester.view.physicalSize = const Size(1280, 720);
      tester.view.devicePixelRatio = 1.5;
      addTearDown(tester.view.reset);
      await pumpApp(tester);

      final surface = Offset.zero & tester.view.physicalSize / 1.5;

      unawaited(
        showSourceHatchConfirmation(
          sourceHatchNavigatorKey.currentContext!,
          request(kind: SourceHatchKind.waitingPage),
        ),
      );
      await tester.pump();
      for (final label in ['取消', '打开页面']) {
        final rect = tester.getRect(find.text(label));
        expect(
          surface.contains(rect.topLeft) && surface.contains(rect.bottomRight),
          isTrue,
          reason: '$label is inside $surface, was $rect',
        );
      }
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump();

      unawaited(
        showSourceHatchImageDialog(
          sourceHatchNavigatorKey.currentContext!,
          request: request(kind: SourceHatchKind.waitingImage),
          image: SourceHatchImage(pngBytes),
          stop: SourceHatchStop(),
        ),
      );
      await tester.pump();
      for (final label in ['取消', '确定']) {
        final rect = tester.getRect(find.text(label));
        expect(
          surface.contains(rect.topLeft) && surface.contains(rect.bottomRight),
          isTrue,
          reason: '$label is inside $surface, was $rect',
        );
      }
      await tester.tap(find.text('取消'));
      await tester.pump();
      await tester.pump();
    });
  });
}
