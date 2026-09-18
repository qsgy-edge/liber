import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_rate_limiter.dart';

/// A deterministic clock and wait: every wait advances the clock by exactly what
/// the limiter asked for, so the frozen algorithm is asserted without sleeping.
class FakeClock {
  int now = 0;
  final waits = <int>[];

  int read() => now;

  Future<void> wait(Duration duration) async {
    waits.add(duration.inMilliseconds);
    now += duration.inMilliseconds;
  }
}

/// A transport that answers without a controlled completion, so a declared batch
/// can be observed without parking requests by hand.
class ImmediateTransport implements SourceHttpTransport {
  final started = <String>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    started.add(request.url.path);
    await Future<void>.delayed(Duration.zero);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: request.url.path,
      url: request.url,
    );
  }
}

void main() {
  late FakeClock clock;
  late SourceRateLimiter limiter;

  setUp(() {
    clock = FakeClock();
    limiter = SourceRateLimiter(clock: clock.read, wait: clock.wait);
  });

  test('the rate records are keyed by source', () async {
    await limiter.acquire('https://a.test/book', '1000');
    await limiter.acquire('https://b.test/book', '1000');
    final a = limiter.recordOf('https://a.test/book');
    final b = limiter.recordOf('https://b.test/book');
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(identical(a, b), isFalse);
    expect(limiter.recordOf('https://c.test/book'), isNull);
    // The first call of each source only creates its record; nothing waits.
    expect(clock.waits, isEmpty);
  });

  test('a plain-millisecond rate admits one request at a time', () async {
    final first = await limiter.acquire('a', '1000');
    expect(first, isNotNull);
    expect(first!.isConcurrent, isFalse);
    expect(first.frequency, 1);

    // A second request while the first is still in flight waits the gap, and
    // is admitted only after the first is released.
    final waiting = limiter.acquire('a', '1000');
    limiter.release(first);
    expect(first.frequency, 0);
    final second = await waiting;
    expect(clock.waits, [1000]);
    expect(second!.time, 1000);
    limiter.release(second);

    // A request that finds the gap already passed starts immediately.
    clock.now += 1000;
    final third = await limiter.acquire('a', '1000');
    expect(clock.waits, [1000]);
    expect(third!.time, 2000);
    limiter.release(third);
  });

  test('a count/millisecond rate admits its window and then waits it out',
      () async {
    final counts = <int>[];
    final records = <SourceRateRecord?>[];
    for (var attempt = 0; attempt < 3; attempt++) {
      final record = await limiter.acquire('a', '2/1000');
      records.add(record);
      counts.add(record!.frequency);
    }
    // The frozen record starts at 1, so the `count` comparison admits one more
    // start than the count sounds like: 1 is created, then 1 > 2 and 2 > 2 are
    // both false.
    expect(clock.waits, isEmpty);
    expect(counts, [1, 2, 3]);
    for (final record in records) {
      limiter.release(record);
    }
    // A concurrent record counts starts, so release changes nothing.
    expect(limiter.recordOf('a')!.frequency, 3);

    // The fourth start waits for the window to pass, which resets the count.
    final fourth = await limiter.acquire('a', '2/1000');
    expect(clock.waits, [1000]);
    expect(fourth!.time, 1000);
    expect(fourth.frequency, 1);
  });

  test('an empty, zero or source-less rate does not limit', () async {
    expect(await limiter.acquire('a', ''), isNull);
    expect(await limiter.acquire('a', '0'), isNull);
    expect(await limiter.acquire('', '1000'), isNull);
    expect(limiter.recordOf('a'), isNull);
    expect(clock.waits, isEmpty);
  });

  test('a malformed rate never waits, as the frozen catch does', () async {
    // The frozen `catch (_: Exception) { 0 }` admits the request: `"1000ms"`
    // parses in neither language.
    await limiter.acquire('a', '1000ms');
    final second = await limiter.acquire('a', '1000ms');
    expect(second, isNotNull);
    expect(clock.waits, isEmpty);
  });

  test('a concurrent batch keeps input order and reports the source rate state',
      () async {
    final transport = ImmediateTransport();
    final dispatcher = SourceHostDispatcher(
      transport: transport,
      sourceRef: 'https://a.test/book',
      // The window admits every start of the batch, so nothing is parked while
      // the batch runs and only the batch's own ordering is under test.
      concurrentRate: '3/1000',
      rateLimiter: limiter,
    );
    final responses = await dispatcher.ajaxAll([
      'http://a.test/1',
      'http://a.test/2',
      'http://a.test/3',
    ], concurrency: 2);
    // The declared batch preserves input order regardless of which worker
    // finishes first...
    expect(responses.map((response) => response.body), ['/1', '/2', '/3']);
    expect(transport.started, ['/1', '/2', '/3']);
    // ...and the source-keyed record counts this window's three starts.
    expect(clock.waits, isEmpty);
    expect(limiter.recordOf('https://a.test/book')!.frequency, 3);
  });

  test('two sources of one process are limited independently', () async {
    final first = SourceHostDispatcher(
      transport: ImmediateTransport(),
      sourceRef: 'https://a.test/book',
      concurrentRate: '500',
      rateLimiter: limiter,
    );
    final second = SourceHostDispatcher(
      transport: ImmediateTransport(),
      sourceRef: 'https://b.test/book',
      concurrentRate: '500',
      rateLimiter: limiter,
    );
    await first.get('http://a.test/1');
    // a.test's second request waits its own gap...
    await first.get('http://a.test/2');
    // ...while b.test's first request never waits behind a.test's record.
    await second.get('http://b.test/1');
    expect(clock.waits, [500]);
    expect(limiter.recordOf('https://a.test/book')!.time, 500);
    expect(limiter.recordOf('https://b.test/book')!.isConcurrent, isFalse);
  });

  test('cancellation stops a waiting acquire', () async {
    await limiter.acquire('a', '5000');
    limiter.release(limiter.recordOf('a'));
    final cancellation = SourceCancellation()..cancel();
    await expectLater(
      limiter.acquire('a', '5000', cancellation: cancellation),
      throwsA(isA<SourceRequestCancelled>()),
    );
  });
}
