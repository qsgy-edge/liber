import 'dart:async';

import '../domain/contracts.dart';

/// One source's selected-reference rate-limiter record
/// (`AnalyzeUrl.ConcurrentRecord` at `a7d37f1`, which carries `time`,
/// `accessLimit`, `interval` and `frequency`).
class SourceRateRecord {
  SourceRateRecord({
    required this.isConcurrent,
    required this.time,
    required this.frequency,
  });

  /// Whether the source's rate is the `count/milliseconds` form. This is the
  /// product's own reading of the declared rate string; the selected reference
  /// stores the parsed `accessLimit`/`interval` instead and keeps both as
  /// provenance, never as a compared value.
  final bool isConcurrent;

  /// The window start, in milliseconds, the clock this limiter was built with
  /// answers: the instant the admitted start that opened the current window
  /// began.
  int time;

  /// Starts admitted since [time]. A `count/ms` rate counts the window's starts
  /// and resets to 1 when the window rolls over; a plain-millisecond rate keeps
  /// it at 1, because the selected reference has no per-request count-down.
  int frequency;
}

/// The selected reference's `ConcurrentRateLimiter` (`a7d37f1`,
/// `help/ConcurrentRateLimiter.kt`): one record per source key, and a
/// wait-until-admitted loop around every source request.
///
/// The reference's records live in a companion object, so they are process
/// state keyed by `source.getKey()` and shared by every analysis of one source.
/// [shared] is that object. The clock and the wait are constructor arguments so
/// a test can make the wait deterministic instead of sleeping for real
/// milliseconds; nothing in the product passes them.
///
/// Two supported forms, as the reference's `fetchStart` reads them: a plain
/// number is the interval between two starts of one source, and
/// `count/milliseconds` admits at most `count` starts inside a window, resetting
/// the window when it has passed. Admission is pure start spacing: the reference
/// removed `fetchEnd`, so a request finishing never returns an admission, adds
/// one, or moves the window. A rate that is empty or `0` means no limiting at
/// all; an unsupported (unparseable) rate admits without waiting, which is this
/// product's documented behaviour for input outside the supported grammar.
class SourceRateLimiter {
  SourceRateLimiter({
    int Function()? clock,
    Future<void> Function(Duration)? wait,
  }) : _clock = clock ?? _systemMillis,
       _wait = wait ?? _delay,
       _ownsWait = wait == null;

  /// The limiter every dispatcher shares unless a test injects its own.
  static final SourceRateLimiter shared = SourceRateLimiter();

  final int Function() _clock;
  final Future<void> Function(Duration) _wait;

  /// Whether [wait] is this limiter's own timer: those are cancelled on
  /// cancellation, an injected wait keeps its own lifecycle.
  final bool _ownsWait;

  /// The process-global records, one per source key.
  final Map<String, SourceRateRecord> _records = {};

  /// The record [sourceRef] currently holds, for observation and tests.
  SourceRateRecord? recordOf(String sourceRef) => _records[sourceRef];

  /// Forgets every record, the way a fixture resets the frozen process state.
  void clear() => _records.clear();

  /// Whether [rate] limits [sourceRef] at all: the frozen `fetchStart` answers
  /// null for a source-less or empty/`"0"` rate, and this lets a caller keep
  /// the no-rate path synchronous.
  bool applies(String sourceRef, String rate) =>
      sourceRef.isNotEmpty && rate.isNotEmpty && rate != '0';

  /// Waits until [sourceRef] may start a request under [rate], and returns the
  /// record the caller hands back to [release] when the request is finished.
  ///
  /// Answers null — and waits for nothing — when there is no rate to apply: an
  /// empty rate, the frozen `"0"`, or no source identity at all (`source ?:
  /// return null` in the frozen `fetchStart`).
  Future<SourceRateRecord?> acquire(
    String sourceRef,
    String rate, {
    SourceCancellation? cancellation,
  }) async {
    if (!applies(sourceRef, rate)) return null;
    while (true) {
      // Checked before the record is read *and* before it is mutated: a
      // cancelled waiter must not create, roll a window or count an admission,
      // so a later operation starts from the record as it really is.
      cancellation?.throwIfCancelled();
      final (record: record, wait: milliseconds) = _fetchStart(sourceRef, rate);
      if (milliseconds > 0) {
        await _awaitWait(milliseconds, cancellation);
        continue;
      }
      return record;
    }
  }

  /// Waits [milliseconds] of injected time, or settles as soon as
  /// [cancellation] fires — a caller's deadline must not be delayed by the rest
  /// of a rate interval. The injected [SourceRateLimiter.wait] signature is
  /// preserved; only the caller's token joins the wait.
  Future<void> _awaitWait(
    int milliseconds,
    SourceCancellation? cancellation,
  ) async {
    if (cancellation == null) {
      return _wait(Duration(milliseconds: milliseconds));
    }
    final cancelled = Completer<void>();
    final detach = cancellation.listen(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    // A wait this limiter scheduled itself is owned: cancellation drops its timer
    // instead of leaving it armed for the rest of the interval. An injected wait
    // keeps its own lifecycle and is only raced.
    Timer? ownedTimer;
    final Future<void> pending;
    if (_ownsWait) {
      final done = Completer<void>();
      ownedTimer = Timer(Duration(milliseconds: milliseconds), () {
        if (!done.isCompleted) done.complete();
      });
      pending = done.future;
    } else {
      pending = _wait(Duration(milliseconds: milliseconds));
    }
    try {
      await Future.any([pending, cancelled.future]);
    } finally {
      ownedTimer?.cancel();
      detach();
    }
    // Neither the normal end nor the cancellation may continue an operation the
    // caller has already given up on.
    cancellation.throwIfCancelled();
  }

  /// The selected reference has no `fetchEnd`: its window count is never
  /// decremented when a request finishes, so completing a request neither
  /// replenishes an admission nor disturbs a later window. The parameter stays
  /// because every caller acquires and releases symmetrically.
  void release(SourceRateRecord? record) {}

  /// The reference's `fetchStart`: the record when the caller may proceed, or the
  /// milliseconds it must wait first.
  ({SourceRateRecord? record, int wait}) _fetchStart(
    String sourceRef,
    String rate,
  ) {
    final rateIndex = rate.indexOf('/');
    var record = _records[sourceRef];
    if (record == null) {
      record = SourceRateRecord(
        isConcurrent: rateIndex > 0,
        time: _clock(),
        frequency: 1,
      );
      _records[sourceRef] = record;
      return (record: record, wait: 0);
    }
    final wait = _waitTime(record, rate, rateIndex);
    return (record: wait > 0 ? null : record, wait: wait);
  }

  /// The reference's `synchronized(fetchRecord)` admission block: the record
  /// when the caller may proceed, or the milliseconds it must wait first.
  int _waitTime(SourceRateRecord record, String rate, int rateIndex) {
    try {
      final interval = rateIndex > 0
          ? int.parse(rate.substring(rateIndex + 1))
          : int.parse(rate);
      final next = record.time + interval;
      if (_clock() >= next) {
        // The window has passed: this start opens the next one.
        record.time = _clock();
        record.frequency = 1;
        return 0;
      }
      if (record.isConcurrent) {
        final count = int.parse(rate.substring(0, rateIndex));
        if (record.frequency >= count) return next - _clock();
        record.frequency += 1;
        return 0;
      }
      // A plain interval is spacing only: an unfinished earlier request does not
      // add a wait once the interval has elapsed.
      return next - _clock();
    } catch (_) {
      // Unsupported input outside the supported grammar admits the request rather
      // than inventing a wait the reference never asks for.
      return 0;
    }
  }

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> _delay(Duration duration) =>
      Future<void>.delayed(duration);
}
