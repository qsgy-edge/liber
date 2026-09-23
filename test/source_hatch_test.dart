import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_hatch.dart';
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
    return SourceHttpResponse(
      statusCode: 200,
      body: _body(request.url.path),
      url: request.url,
      headers: const {},
      // Only the verification-code image asks for bytes; the transport contract
      // answers them only then.
      bodyBytes: request.readBytes
          ? Uint8List.fromList(const [137, 80, 78, 71])
          : null,
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
      final source = _source('tag.h3@tag.a@text@js:java.getVerificationCode("$_codeUrl")');
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
        _source('tag.h3@tag.a@text@js:java.startBrowserAwait("$_pageUrl", "标题").body()'),
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

    test('startBrowserAwait takes the pages own HTML when it is not refetching', () async {
      final surface = _TestSurface(
        answer: SourceHatchAnswer.answered('<html>页面</html>'),
      );
      SourceHatchSurface.installed = surface;
      final transport = _Transport();
      final pipeline = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.startBrowserAwait("$_pageUrl", "t", false).body()'),
        transport,
      );

      final hits = await pipeline.search('书');
      expect(hits.single.title, '<html>页面</html>');
      expect(surface.requests.single.refetchAfterSuccess, isFalse);
      expect(
        transport.requests.where((request) => '${request.url}' == _pageUrl),
        isEmpty,
      );
    });

    test('startBrowser and openUrl show the page and the stage goes on', () async {
      final surface = _TestSurface(answer: SourceHatchAnswer.presented);
      SourceHatchSurface.installed = surface;
      final browser = HtmlSourcePipeline(
        _source('tag.h3@tag.a@text@js:java.startBrowser("$_pageUrl", "标题"); "shown"'),
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
    });

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
  });
}
