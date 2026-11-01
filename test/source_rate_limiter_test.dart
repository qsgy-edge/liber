import 'dart:async';

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

/// A transport whose first request stays in flight until the test releases it,
/// so a source can be measured while one of its own requests is still open.
class GatedTransport implements SourceHttpTransport {
  final started = <String>[];
  final _firstStarted = Completer<void>();
  final _release = Completer<void>();

  Future<void> get firstStarted => _firstStarted.future;

  void releaseAll() {
    if (!_release.isCompleted) _release.complete();
  }

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    started.add(request.url.path);
    if (started.length == 1) {
      _firstStarted.complete();
      await _release.future;
    }
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: request.url.path,
      url: request.url,
    );
  }
}

/// A wait that ends the probe instead of looping: under the completion-dependent
/// branch the limiter keeps asking for a fresh interval, which would spin on the
/// injected wait forever. Any wait at or past [elapsedAt] is exactly that defect,
/// so the probe fails immediately rather than starving its own deadlines.
Future<void> Function(Duration) failFastWaitAfter(
  FakeClock clock,
  int elapsedAt,
) => (duration) async {
  if (clock.now >= elapsedAt) {
    fail(
      'the limiter asked to wait ${duration.inMilliseconds} ms when the '
      '$elapsedAt ms mark had already been passed',
    );
  }
  clock.waits.add(duration.inMilliseconds);
  clock.now += duration.inMilliseconds;
};

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

  test('a plain-millisecond rate admits one start per interval', () async {
    final first = await limiter.acquire('a', '1000');
    expect(first, isNotNull);
    expect(first!.isConcurrent, isFalse);
    expect(first.frequency, 1);

    // The selected reference has no fetchEnd, so completing a request neither
    // replenishes an admission nor blocks a later start.
    limiter.release(first);
    expect(first.frequency, 1);

    // The next start waits only for the interval to elapse.
    final second = await limiter.acquire('a', '1000');
    expect(clock.waits, [1000]);
    expect(second!.time, 1000);
    limiter.release(second);

    // A start that finds the interval already passed starts immediately.
    clock.now += 1000;
    final third = await limiter.acquire('a', '1000');
    expect(clock.waits, [1000]);
    expect(third!.time, 2000);
    limiter.release(third);
  });

  test('N/T admits N starts, not N+1', () async {
    final first = await limiter.acquire('a', '1/2000');
    expect(first!.frequency, 1);
    expect(clock.waits, isEmpty);

    // The second start must wait out the window: the admitted start consumed
    // its own admission instead of leaving an extra slot.
    final second = await limiter.acquire('a', '1/2000');
    expect(clock.waits, [2000]);
    expect(second!.time, 2000);
    expect(second.frequency, 1);
  });

  test(
    'a count/millisecond rate admits its window and then waits it out',
    () async {
      final counts = <int>[];
      final records = <SourceRateRecord?>[];
      for (var attempt = 0; attempt < 2; attempt++) {
        final record = await limiter.acquire('a', '2/1000');
        records.add(record);
        counts.add(record!.frequency);
      }
      // Exactly the declared two starts are admitted inside the first window.
      expect(clock.waits, isEmpty);
      expect(counts, [1, 2]);

      // The third start waits for the window to pass, which resets the count.
      final third = await limiter.acquire('a', '2/1000');
      expect(clock.waits, [1000]);
      expect(third!.time, 1000);
      expect(third.frequency, 1);

      // A completion never replenishes an admission in the window it belonged to.
      for (final record in records) {
        limiter.release(record);
      }
      expect(limiter.recordOf('a')!.frequency, 1);
      final fourth = await limiter.acquire('a', '2/1000');
      expect(clock.waits, [1000]);
      expect(fourth!.frequency, 2);
    },
  );

  test('a late completion does not corrupt a later window', () async {
    final first = await limiter.acquire('a', '1/1000');
    expect(first!.frequency, 1);
    clock.now = 1000;
    final second = await limiter.acquire('a', '1/1000');
    expect(second!.time, 1000);
    expect(second.frequency, 1);
    // The first request finishing now belongs to the window it was admitted in.
    limiter.release(first);
    expect(limiter.recordOf('a')!.frequency, 1);
    expect(limiter.recordOf('a')!.time, 1000);
    final third = await limiter.acquire('a', '1/1000');
    expect(clock.waits, [1000]);
    expect(third!.time, 2000);
  });

  test('a plain interval admits the next start after it even while a request '
      'is unfinished', () async {
    final probe = SourceRateLimiter(
      clock: clock.read,
      wait: failFastWaitAfter(clock, 2500),
    );
    // The first request is never released: it is still open when the interval ends.
    await probe.acquire('a', '2000');
    clock.now = 2500;
    final second = await probe.acquire('a', '2000');
    expect(clock.waits, isEmpty);
    expect(second!.time, 2500);
    expect(second.frequency, 1);
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

  test(
    'a concurrent batch keeps input order and reports the source rate state',
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
        for (final path in ['1', '2', '3'])
          (
            method: 'GET',
            url: 'http://a.test/$path',
            headers: const <String, String>{},
            body: null,
            retry: 0,
          ),
      ], concurrency: 2);
      // The declared batch preserves input order regardless of which worker
      // finishes first...
      expect(responses.map((response) => response.body), ['/1', '/2', '/3']);
      expect(transport.started, ['/1', '/2', '/3']);
      // ...and the source-keyed record counts this window's three starts.
      expect(clock.waits, isEmpty);
      expect(limiter.recordOf('https://a.test/book')!.frequency, 3);
    },
  );

  test('the dispatcher admits a second plain start while the first request is '
      'still in flight', () async {
    final transport = GatedTransport();
    final dispatcher = SourceHostDispatcher(
      transport: transport,
      sourceRef: 'https://a.test/book',
      concurrentRate: '2000',
      // A start that arrives after the interval must not wait at all, so any
      // wait request here is the completion-dependent branch under test.
      rateLimiter: SourceRateLimiter(
        clock: clock.read,
        wait: failFastWaitAfter(clock, 0),
      ),
    );
    final first = dispatcher.get('http://a.test/1');
    await transport.firstStarted;
    // The interval elapses while request 1 is still waiting for its response.
    clock.now = 2500;
    final second = await dispatcher.get('http://a.test/2');
    expect(clock.waits, isEmpty);
    expect(transport.started, ['/1', '/2']);
    // Releasing the first request adds no admission to the window it began in.
    transport.releaseAll();
    final firstResponse = await first;
    expect([firstResponse.body, second.body], ['/1', '/2']);
  });

  test('a cancelled rate waiter never reaches the transport', () async {
    final gate = Completer<void>();
    final transport = ImmediateTransport();
    final probe = SourceRateLimiter(
      clock: clock.read,
      wait: (duration) {
        clock.now += duration.inMilliseconds;
        return gate.future;
      },
    );
    final cancellation = SourceCancellation();
    final dispatcher = SourceHostDispatcher(
      transport: transport,
      sourceRef: 'https://a.test/book',
      concurrentRate: '1/5000',
      cancellation: cancellation,
      rateLimiter: probe,
    );
    await dispatcher.get('http://a.test/1');
    expect(transport.started, ['/1']);

    final waiting = dispatcher.get('http://a.test/2');
    await Future<void>.delayed(Duration.zero);
    cancellation.cancel();
    await expectLater(waiting, throwsA(isA<SourceRequestCancelled>()));
    // The cancelled operation is never transmitted: no second logical send.
    expect(transport.started, ['/1']);
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(transport.started, ['/1']);
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

  test('cancelling an active wait settles at once and admits nothing', () async {
    // The injected wait advances the clock but only completes when told, so the
    // probe can hold a real in-flight wait and then cancel it.
    final gate = Completer<void>();
    final waits = <int>[];
    final probe = SourceRateLimiter(
      clock: clock.read,
      wait: (duration) {
        waits.add(duration.inMilliseconds);
        clock.now += duration.inMilliseconds;
        return gate.future;
      },
    );
    await probe.acquire('a', '1/2000');
    final cancellation = SourceCancellation();
    final waiting = probe.acquire('a', '1/2000', cancellation: cancellation);
    await Future<void>.delayed(Duration.zero);
    expect(waits, [2000]);
    expect(probe.recordOf('a')!.time, 0);

    cancellation.cancel();
    // The waiter settles from the cancellation, not from the interval's end.
    await expectLater(waiting, throwsA(isA<SourceRequestCancelled>()));
    // A cancelled waiter never rolls the window or counts an admission.
    expect(probe.recordOf('a')!.time, 0);
    expect(probe.recordOf('a')!.frequency, 1);

    // The abandoned timer completing later must not resume the operation.
    gate.complete();
    await Future<void>.delayed(Duration.zero);
    expect(probe.recordOf('a')!.time, 0);

    // A fresh, uncancelled operation proceeds from the same record.
    final followUp = await probe.acquire('a', '1/2000');
    expect(followUp!.time, 2000);
    expect(waits, [2000]);
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
