import 'package:drift/drift.dart';

import '../source/source_host_state.dart';
import 'database.dart';
import 'space_store.dart';

/// The space's half of the host surface's state (ADR 0011 §3): the cookie jar
/// and the per-source entries as rows of the same `data.db` the shelf, the
/// sources and the reading progress live in — not a file beside the store, so a
/// private space's later encryption covers runtime state as a unit.
///
/// Nothing is evicted here: a row stays until the source that owns it writes
/// over it or deletes it, which is #21's recorded consequence (the baseline's
/// LRU capacity and its cookie trim are divergences, not mechanisms this store
/// reproduces).
class SpaceHostStatePersistence implements SourceHostStatePersistence {
  const SpaceHostStatePersistence(this.store);

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
        ),
    ];
  }

  @override
  Future<void> saveCacheEntry(SourceCacheEntry entry) async {
    await _db
        .into(_db.sourceEntries)
        .insertOnConflictUpdate(
          StoredSourceEntry(
            sourceRef: entry.sourceRef,
            key: entry.key,
            value: entry.value,
            expiresAt: entry.expiresAt,
          ),
        );
  }

  @override
  Future<void> deleteCacheEntry(String sourceRef, String key) async {
    await (_db.delete(_db.sourceEntries)..where(
          (entry) => entry.sourceRef.equals(sourceRef) & entry.key.equals(key),
        ))
        .go();
  }
}
