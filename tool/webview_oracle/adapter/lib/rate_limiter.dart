/// Port of the frozen baseline's `ConcurrentRateLimiter`.
///
/// The record map is process-global and keyed by source key, matching the frozen
/// `companion object` map, so the limiter is source-scoped state a rule can
/// observe across operations.
///
/// The `n/ms` branch is reproduced exactly, including its off-by-one: the
/// frequency check is `frequency > n`, so with `1/800` the second request in a
/// window is still admitted immediately and only the third one waits. That is
/// observable request timing, so the port keeps it rather than "fixing" it.
class ConcurrentRecord {
  ConcurrentRecord(this.isConcurrent, this.time, this.frequency);

  final bool isConcurrent;
  int time;
  int frequency;
}

class ConcurrentRateLimiter {
  ConcurrentRateLimiter({required this.sourceKey, required this.concurrentRate});

  static final Map<String, ConcurrentRecord> _records = {};

  final String sourceKey;
  final String? concurrentRate;

  ConcurrentRecord? _fetchStart() {
    try {
      return _fetchStartOrThrow();
    } on FormatException {
      // The frozen implementation wraps its whole decision in a catch that
      // returns a zero wait, so a malformed source-authored rate silently
      // disables limiting instead of failing the operation.
      return _records[sourceKey];
    }
  }

  ConcurrentRecord? _fetchStartOrThrow() {
    final rate = concurrentRate;
    if (rate == null || rate.isEmpty || rate == '0') return null;
    final rateIndex = rate.indexOf('/');
    var record = _records[sourceKey];
    if (record == null) {
      record = ConcurrentRecord(
        rateIndex > 0,
        DateTime.now().millisecondsSinceEpoch,
        1,
      );
      _records[sourceKey] = record;
      return record;
    }
    final int waitTime;
    if (!record.isConcurrent) {
      final interval = int.parse(rate);
      if (record.frequency > 0) {
        waitTime = interval;
      } else {
        final nextTime = record.time + interval;
        final now = DateTime.now().millisecondsSinceEpoch;
        if (now >= nextTime) {
          record.time = now;
          record.frequency = 1;
          waitTime = 0;
        } else {
          waitTime = nextTime - now;
        }
      }
    } else {
      final interval = int.parse(rate.substring(rateIndex + 1));
      final allowed = int.parse(rate.substring(0, rateIndex));
      final nextTime = record.time + interval;
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now >= nextTime) {
        record.time = now;
        record.frequency = 1;
        waitTime = 0;
      } else if (record.frequency > allowed) {
        waitTime = nextTime - now;
      } else {
        record.frequency += 1;
        waitTime = 0;
      }
    }
    if (waitTime > 0) throw _ConcurrentException(waitTime);
    return record;
  }

  void _fetchEnd(ConcurrentRecord? record) {
    if (record != null && !record.isConcurrent) record.frequency -= 1;
  }

  Future<T> withLimit<T>(Future<T> Function() block) async {
    ConcurrentRecord? record;
    while (true) {
      try {
        record = _fetchStart();
        break;
      } on _ConcurrentException catch (exception) {
        await Future<void>.delayed(Duration(milliseconds: exception.waitTime));
      }
    }
    try {
      return await block();
    } finally {
      _fetchEnd(record);
    }
  }

  /// Test-visible reset of the process-global state, so one fixture's limiter
  /// window cannot leak into another's.
  static void resetAll() => _records.clear();
}

class _ConcurrentException implements Exception {
  _ConcurrentException(this.waitTime);

  final int waitTime;
}
