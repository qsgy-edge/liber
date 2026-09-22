import 'package:drift/drift.dart';

import '../source/source_host_state.dart';
import 'database.dart';
import 'space_store.dart';

/// The space's half of the host surface's state (ADR 0011 §3): the cookie jar
/// and the per-source entries as rows of the same `data.db` the shelf, the
/// sources and the reading progress live in — plus the confirmed TLS
/// exceptions (ADR 0011 §5) — not a file beside the store, so a private
/// space's later encryption covers runtime state as a unit.
///
/// One source's entries are bounded (#37): [saveCacheEntry] keeps its `cache.*`
/// entries in one bucket of [cacheEntryLimit] rows and its `java.put`/
/// `java.get` variables in a second bucket of [variableEntryLimit], and a write
/// past a bucket's cap evicts that bucket's least recently written rows — the
/// `source_entries.written_at` order. The frozen baseline's persistent `caches`
/// table is unbounded and only its in-memory `LruCache` is capped (50 MB, one
/// global key space, access order), so the cap, the order and the separate
/// variable bucket are the recorded divergences (differential contract, Policy
/// divergences). A cookie row is not bounded here; the baseline's 4096-character
/// trim stays its own recorded divergence.
class SpaceHostStatePersistence implements SourceHostStatePersistence {
  const SpaceHostStatePersistence(this.store);

  /// The `cache.*` rows one source may keep: the frozen `CacheManager`'s own
  /// number.
  static const int cacheEntryLimit = 600;

  /// The `java.put`/`java.get` rows one source may keep. The frozen baseline
  /// gives them no separate number — they sit in the same unbounded `caches`
  /// table under `v_<sourceKey>_<key>` (`BaseSource.kt:220-233`) — so this
  /// bucket reuses the frozen 600 instead of inventing a second number. The two
  /// buckets are separate, so cache churn never evicts a login variable.
  static const int variableEntryLimit = 600;

  final SpaceStore store;

  SpaceDatabase get _db => store.db;

  @override
  Future<List<SourceCookiePair>> loadCookies() async {
    final rows = await _db.select(_db.sourceCookies).get();
    return [
      for (final row in rows)
        SourceCookiePair(
          domain: row.domain,
          name: row.name,
          value: row.value,
          writerRef: row.writerRef,
        ),
    ];
  }

  @override
  Future<void> saveCookie(SourceCookiePair cookie) async {
    await _db
        .into(_db.sourceCookies)
        .insertOnConflictUpdate(
          StoredCookie(
            domain: cookie.domain,
            name: cookie.name,
            value: cookie.value,
            writerRef: cookie.writerRef,
          ),
        );
  }

  @override
  Future<void> deleteCookie(String domain, String name) async {
    await (_db.delete(_db.sourceCookies)..where(
          (cookie) => cookie.domain.equals(domain) & cookie.name.equals(name),
        ))
        .go();
  }

  @override
  Future<List<SourceCacheEntry>> loadCache() async {
    final rows = await _db.select(_db.sourceEntries).get();
    return [
      for (final row in rows)
        SourceCacheEntry(
          sourceRef: row.sourceRef,
          key: row.key,
          value: row.value,
          expiresAt: row.expiresAt,
          writtenAt: row.writtenAt,
        ),
    ];
  }

  /// Stores [entry] and keeps its bucket at its cap, and returns the evicted
  /// keys so a caller holding the same rows in memory can drop them.
  ///
  /// Eviction runs on write only: a `cache.get` is a read of the in-memory copy
  /// and must not turn into a durable write. That is where the order differs
  /// from the frozen `LruCache`, which promotes an entry on read too.
  @override
  Future<List<String>> saveCacheEntry(SourceCacheEntry entry) async {
    await _db
        .into(_db.sourceEntries)
        .insertOnConflictUpdate(
          StoredSourceEntry(
            sourceRef: entry.sourceRef,
            key: entry.key,
            value: entry.value,
            expiresAt: entry.expiresAt,
            writtenAt: entry.writtenAt,
          ),
        );
    return _evictOverflow(
      entry.sourceRef,
      isVariable: _isVariable(entry.sourceRef, entry.key),
    );
  }

  /// Deletes the least recently written rows that put [sourceRef]'s bucket over
  /// its cap and returns their keys, oldest first.
  ///
  /// A v4 row carries no instant (0) and so is evicted before any v5 write; the
  /// key breaks a tie between rows written in the same millisecond, so the
  /// victim set is deterministic.
  Future<List<String>> _evictOverflow(
    String sourceRef, {
    required bool isVariable,
  }) async {
    final limit = isVariable ? variableEntryLimit : cacheEntryLimit;
    final count = _db.sourceEntries.key.count();
    final total =
        (await (_db.selectOnly(_db.sourceEntries)
                  ..addColumns([count])
                  ..where(
                    _inBucket(
                      _db.sourceEntries,
                      sourceRef,
                      isVariable: isVariable,
                    ),
                  ))
                .getSingle())
            .read(count) ??
        0;
    final excess = total - limit;
    if (excess <= 0) return const [];
    final victims =
        await (_db.select(_db.sourceEntries)
              ..where((e) => _inBucket(e, sourceRef, isVariable: isVariable))
              ..orderBy([
                (e) => OrderingTerm(expression: e.writtenAt),
                (e) => OrderingTerm(expression: e.key),
              ])
              ..limit(excess))
            .get();
    final keys = [for (final row in victims) row.key];
    await (_db.delete(
      _db.sourceEntries,
    )..where((e) => e.sourceRef.equals(sourceRef) & e.key.isIn(keys))).go();
    return keys;
  }

  /// The prefix a `java.put`/`java.get` variable is stored under
  /// (`BaseSource.kt:220-233`), which `js_source_runtime.dart` builds as well: a
  /// row whose key starts with it is a variable, every other row is a `cache.*`
  /// entry.
  static String _variablePrefix(String sourceRef) => 'v_${sourceRef}_';

  static bool _isVariable(String sourceRef, String key) =>
      key.startsWith(_variablePrefix(sourceRef));

  /// The same classification expressed in SQL, for the count and the ordered
  /// select: `substr(key, 1, len) = prefix` is startswith (`LIKE` is not used —
  /// `_` is a wildcard in it and a source ref contains dots, slashes and
  /// underscores). `key` is never null.
  static Expression<bool> _inBucket(
    SourceEntries entries,
    String sourceRef, {
    required bool isVariable,
  }) {
    final prefix = _variablePrefix(sourceRef);
    final head = entries.key.substr(1, prefix.length).equals(prefix);
    return isVariable ? head : head.not();
  }

  @override
  Future<void> deleteCacheEntry(String sourceRef, String key) async {
    await (_db.delete(_db.sourceEntries)..where(
          (entry) => entry.sourceRef.equals(sourceRef) & entry.key.equals(key),
        ))
        .go();
  }

  /// Removes every host-surface row [sourceRef] owns (#36, #53), in one
  /// transaction: its `source_entries` rows, the `source_cookies` pairs whose
  /// `writer_ref` is the source, and the `source_tls_exceptions` the user
  /// confirmed for it. A pair another source of the same site wrote keeps its
  /// own `writer_ref` and stays (ADR 0011 §3).
  ///
  /// The TLS rows go with the URL for the same reason the other two do (#53):
  /// the exception's key is the pair (source, host), so a source row that is
  /// gone or renamed can never consult the row again — and a source imported
  /// later under the same URL must not silently inherit a confirmation the user
  /// gave for an earlier definition of it.
  @override
  Future<void> deleteSource(String sourceRef) async {
    await _db.transaction(() async {
      await (_db.delete(_db.sourceEntries)..where(
            (entry) => entry.sourceRef.equals(sourceRef),
          ))
          .go();
      await (_db.delete(_db.sourceCookies)..where(
            (cookie) => cookie.writerRef.equals(sourceRef),
          ))
          .go();
      await (_db.delete(_db.sourceTlsExceptions)..where(
            (exception) => exception.sourceRef.equals(sourceRef),
          ))
          .go();
    });
  }

  @override
  Future<List<SourceTlsException>> loadTlsExceptions() async {
    final rows = await _db.select(_db.sourceTlsExceptions).get();
    return [
      for (final row in rows)
        SourceTlsException(sourceRef: row.sourceRef, host: row.host),
    ];
  }

  @override
  Future<void> saveTlsException(SourceTlsException exception) async {
    await _db
        .into(_db.sourceTlsExceptions)
        .insertOnConflictUpdate(
          StoredTlsException(
            sourceRef: exception.sourceRef,
            host: exception.host,
          ),
        );
  }
}
