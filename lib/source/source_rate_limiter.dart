import '../domain/contracts.dart';

/// One source's frozen rate-limiter record (`AnalyzeUrl.ConcurrentRecord`).
class SourceRateRecord {
  SourceRateRecord({
    required this.isConcurrent,
    required this.time,
    required this.frequency,
  });

  /// Whether the source's rate is the `count/milliseconds` form.
  final bool isConcurrent;

  /// The window start, in milliseconds, the clock this limiter was built with
  /// answers. A plain-millisecond rate resets it to the instant a request was
  /// admitted; a `count/ms` rate to the start of the window it counts.
  int time;

  /// Requests admitted since [time]. A plain-millisecond rate keeps it at 1
  /// while a request is in flight; a `count/ms` rate counts the window's starts.
  int frequency;
}

/// Frozen `ConcurrentRateLimiter` (`help/ConcurrentRateLimiter.kt`): one record
/// per source key, and a wait-until-admitted loop around every source request.
///
/// The frozen limiter's records live in a companion object, so they are process
/// state keyed by `source.getKey()` and shared by every analysis of one source.
/// [shared] is that object. The clock and the wait are constructor arguments so
/// a test can make the wait deterministic instead of sleeping for real
/// milliseconds; nothing in the product passes them.
///
/// Two forms, as the frozen `fetchStart` reads them (`:34-79`): a plain number
/// is a gap in milliseconds between the starts of two requests of one source,
/// with one request in flight at a time, and `count/milliseconds` counts starts
/// inside a window, resetting it when the window has passed. A rate that is
/// empty or `0` means no limiting at all, and a malformed one never waits — the
/// frozen `catch (_: Exception) { 0 }`.
class SourceRateLimiter {
  SourceRateLimiter({
    int Function()? clock,
    Future<void> Function(Duration)? wait,
  }) : _clock = clock ?? _systemMillis,
       _wait = wait ?? _delay;

  /// The limiter every dispatcher shares unless a test injects its own.
  static final SourceRateLimiter shared = SourceRateLimiter();

  final int Function() _clock;
  final Future<void> Function(Duration) _wait;

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
      final (record: record, wait: milliseconds) = _fetchStart(sourceRef, rate);
      if (milliseconds > 0) {
        cancellation?.throwIfCancelled();
        await _wait(Duration(milliseconds: milliseconds));
        continue;
      }
      return record;
    }
  }

  /// Frozen `fetchEnd`: a plain-millisecond record counts down the request it
  /// admitted; a `count/ms` record counts starts and does not.
  void release(SourceRateRecord? record) {
    if (record != null && !record.isConcurrent) record.frequency -= 1;
  }

  /// Frozen `fetchStart`: the record when the caller may proceed, or the
  /// milliseconds it must wait first.
  ({SourceRateRecord? record, int wait}) _fetchStart(String sourceRef, String rate) {
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

  /// The frozen `synchronized(fetchRecord)` block (`ConcurrentRateLimiter.kt:39-78`).
  int _waitTime(SourceRateRecord record, String rate, int rateIndex) {
    try {
      if (!record.isConcurrent) {
        // One request at a time; the next may start `rate` milliseconds after
        // the admitted one started.
        if (record.frequency > 0) return int.parse(rate);
        final next = record.time + int.parse(rate);
        if (_clock() >= next) {
          record.time = _clock();
          record.frequency = 1;
          return 0;
        }
        return next - _clock();
      }
      final window = int.parse(rate.substring(rateIndex + 1));
      final next = record.time + window;
      if (_clock() >= next) {
        record.time = _clock();
        record.frequency = 1;
        return 0;
      }
      final count = int.parse(rate.substring(0, rateIndex));
      if (record.frequency > count) return next - _clock();
      record.frequency += 1;
      return 0;
    } catch (_) {
      // The frozen block catches every exception and admits the request.
      return 0;
    }
  }

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;

  static Future<void> _delay(Duration duration) => Future<void>.delayed(duration);
}
