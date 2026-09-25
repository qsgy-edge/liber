import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';

import 'temp_directory.dart';

/// The per-source cap (#37): one source's `cache.*` entries and its
/// `java.put`/`java.get` variables live in two separate buckets, the write path
/// keeps each bucket at its cap, and the least recently written row of a bucket
/// a write overflows is the one evicted — a re-write makes its key the newest
/// again.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-source-quota-');
  });

  tearDown(() => deleteTempDirectory(root));

  /// The keys the store holds for one source, oldest write first.
  Future<List<String>> storedKeys(SpaceStore store, String sourceRef) async {
    final rows =
        await (store.db.select(store.db.sourceEntries)
              ..where((e) => e.sourceRef.equals(sourceRef))
              ..orderBy([(e) => OrderingTerm(expression: e.writtenAt)]))
            .get();
    return [for (final row in rows) row.key];
  }

  test('一个源写满 cache 桶后保持上限，最旧的先淘汰', () async {
    const sourceRef = 'https://www.example.com/book';
    const limit = SpaceHostStatePersistence.cacheEntryLimit;
    var now = 1000;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );

    // One write past the cap: every write is a millisecond later than the last,
    // so `cache.0` is the single least recently written row.
    for (var i = 0; i <= limit; i++) {
      now = 1000 + i;
      await state.putEntry(sourceRef, 'cache.$i', 'v$i');
    }

    final keys = await storedKeys(store, sourceRef);
    expect(keys, hasLength(limit));
    expect(keys, contains('cache.1'));
    expect(keys, contains('cache.$limit'));
    expect(keys, isNot(contains('cache.0')));

    // The eviction is the same fact in memory and after a restart.
    expect(await state.entry(sourceRef, 'cache.0'), isNull);
    expect(await state.entry(sourceRef, 'cache.$limit'), 'v$limit');
    await workspace.close();

    final reopened = await Workspace.open(root: root);
    final restarted = SourceHostState(
      persistence: SpaceHostStatePersistence(await reopened.openSpace()),
    );
    expect(await restarted.entry(sourceRef, 'cache.0'), isNull);
    expect(await restarted.entry(sourceRef, 'cache.1'), 'v1');
    await reopened.close();
  });

  test('一个源的两桶互不挤占：变量写满淘汰变量，不动 cache', () async {
    const sourceRef = 'https://www.example.com/book';
    const cacheLimit = SpaceHostStatePersistence.cacheEntryLimit;
    const variableLimit = SpaceHostStatePersistence.variableEntryLimit;
    var now = 1000;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );

    // A cache bucket at its cap.
    for (var i = 0; i < cacheLimit; i++) {
      now++;
      await state.putEntry(sourceRef, 'cache.$i', 'v$i');
    }
    final cacheKeys = await storedKeys(store, sourceRef);

    // The variable bucket is its own: 601 variable writes evict the oldest two
    // variables and leave every cache row alone.
    for (var i = 0; i <= variableLimit; i++) {
      now++;
      await state.putEntry(sourceRef, 'v_${sourceRef}_k$i', 't$i');
    }

    final keys = await storedKeys(store, sourceRef);
    expect(keys, hasLength(cacheLimit + variableLimit));
    expect(keys, containsAll(cacheKeys));
    expect(keys.where((key) => key.startsWith('v_${sourceRef}_')), [
      for (var i = 1; i <= variableLimit; i++) 'v_${sourceRef}_k$i',
    ]);
    expect(await state.entry(sourceRef, 'cache.0'), 'v0');
    expect(
      await state.entry(sourceRef, 'v_${sourceRef}_k$variableLimit'),
      't$variableLimit',
    );
    await workspace.close();
  });

  test('淘汰看当前写入时间：重写把键变回最新', () async {
    const sourceRef = 'https://www.example.com/book';
    const limit = SpaceHostStatePersistence.cacheEntryLimit;
    var now = 1000;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );

    // `cache.keep` is written first, so without the refresh it would be the
    // oldest write and the next overflow's victim. The refresh makes it the
    // newest, so the write after it evicts `cache.0` — written later than
    // `cache.keep`'s first write, earlier than its refresh.
    now = 1000;
    await state.putEntry(sourceRef, 'cache.keep', 'keep');
    for (var i = 0; i < limit - 1; i++) {
      now = 1001 + i;
      await state.putEntry(sourceRef, 'cache.$i', 'v$i');
    }
    now = 9000;
    await state.putEntry(sourceRef, 'cache.keep', 'refreshed');
    now = 9001;
    await state.putEntry(sourceRef, 'cache.new', 'new');

    final keys = await storedKeys(store, sourceRef);
    expect(keys, hasLength(limit));
    expect(keys, contains('cache.keep'));
    expect(keys, contains('cache.new'));
    expect(keys, isNot(contains('cache.0')));
    expect(await state.entry(sourceRef, 'cache.keep'), 'refreshed');
    await workspace.close();
  });

  test('上限按源计算：另一个源的行不受影响', () async {
    const busy = 'https://busy.example.com/book';
    const quiet = 'https://quiet.example.com/book';
    const limit = SpaceHostStatePersistence.cacheEntryLimit;
    var now = 1000;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );

    await state.putEntry(quiet, 'cache.keep', 'kept');
    for (var i = 0; i <= limit; i++) {
      now = 1000 + i;
      await state.putEntry(busy, 'cache.$i', 'v$i');
    }

    expect(await storedKeys(store, busy), hasLength(limit));
    expect(await storedKeys(store, quiet), ['cache.keep']);
    expect(await state.entry(quiet, 'cache.keep'), 'kept');
    await workspace.close();
  });
}
