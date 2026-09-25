import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';

import 'temp_directory.dart';

/// Reclaiming a source's host-surface rows (#36): both a source delete and a
/// `bookSourceUrl` change remove that source's `source_entries` rows and the
/// `source_cookies` rows it wrote, while a cookie another source of the same
/// site wrote — the shared session (ADR 0011 §3) — survives. The in-memory
/// [SourceHostState] drops the same rows as the store, so a read after the
/// cleanup cannot see what the store no longer holds.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-source-cleanup-');
  });

  tearDown(() => deleteTempDirectory(root));

  /// The `source_entries` keys the store holds for one source, by key.
  Future<List<String>> storedEntryKeys(
    SpaceStore store,
    String sourceRef,
  ) async {
    final rows =
        await (store.db.select(store.db.sourceEntries)
              ..where((e) => e.sourceRef.equals(sourceRef))
              ..orderBy([(e) => OrderingTerm(expression: e.key)]))
            .get();
    return [for (final row in rows) row.key];
  }

  /// Every `source_cookies` row the store holds, as `writer|domain|name`.
  Future<List<String>> storedCookies(SpaceStore store) async {
    final rows =
        await (store.db.select(store.db.sourceCookies)
              ..orderBy([
                (c) => OrderingTerm(expression: c.domain),
                (c) => OrderingTerm(expression: c.name),
              ]))
            .get();
    return [
      for (final row in rows) '${row.writerRef}|${row.domain}|${row.name}',
    ];
  }

  test('deleting a source reclaims its rows and keeps the shared session',
      () async {
    const first = 'https://first.example.com/book';
    const second = 'https://second.example.com/book';
    var workspace = await Workspace.open(root: root);
    var store = await workspace.openSpace();
    var state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    final firstJar = state.cookiesFor(first);
    final secondJar = state.cookiesFor(second);

    // The first source writes its own site's pair, a pair under another site,
    // and its cache entries and variables; the second source of the same site
    // writes the session's other pair.
    await firstJar.set('https://first.example.com/', 'sid=first');
    await firstJar.set('https://cdn.other.test/x', 'ad=first');
    await secondJar.set('https://second.example.com/', 'token=second');
    await state.putEntry(first, 'cache.keep', 'v');
    await state.putEntry(first, 'v_${first}_login', 'yes');
    await state.putEntry(second, 'cache.other', 'o');

    await state.deleteSource(first);

    // The deleted source's rows are gone from the store...
    expect(await storedEntryKeys(store, first), isEmpty);
    expect(await storedCookies(store), ['$second|example.com|token']);
    // ...and from the in-memory copy, which cannot read them back.
    expect(await state.entry(first, 'cache.keep'), isNull);
    expect(await state.entry(first, 'v_${first}_login'), isNull);
    expect(firstJar.value('https://first.example.com/', 'sid'), '');
    expect(firstJar.value('https://cdn.other.test/', 'ad'), '');
    // The other source of the site kept its pair and the other source's cache
    // entries are untouched.
    expect(secondJar.value('https://second.example.com/', 'token'), 'second');
    expect(secondJar.cookiesFor('https://second.example.com/'), 'token=second');
    expect(await state.entry(second, 'cache.other'), 'o');
    await workspace.close();

    // A restart reads the same: the deletion was durable, not just in memory.
    workspace = await Workspace.open(root: root);
    store = await workspace.openSpace();
    state = SourceHostState(persistence: SpaceHostStatePersistence(store));
    expect(await state.entry(first, 'cache.keep'), isNull);
    expect(
      state.cookiesFor(second).value('https://second.example.com/', 'token'),
      'second',
    );
    expect(state.cookiesFor(first).value('https://first.example.com/', 'sid'), '');
    await workspace.close();
  });

  test('re-pointing to another site reclaims the old rows, shares stay', () async {
    const first = 'https://first.example.com/book';
    const moved = 'https://first.example.org/book';
    const second = 'https://second.example.com/book';
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    final firstJar = state.cookiesFor(first);
    final secondJar = state.cookiesFor(second);

    await firstJar.set('https://first.example.com/', 'sid=first');
    await secondJar.set('https://second.example.com/', 'token=second');
    await state.putEntry(first, 'cache.old', 'v');

    // The re-point: the source's identity is its URL, so the edit is the old
    // URL's rows going and the source starting under the new one.
    await state.deleteSource(first);
    final movedJar = state.cookiesFor(moved);
    await movedJar.set('https://first.example.org/', 'sid=moved');
    await state.putEntry(moved, 'cache.new', 'n');

    // The old site lost only the re-pointed source's pair: the pair the other
    // source of that site wrote is still the session read through it.
    expect(await storedEntryKeys(store, first), isEmpty);
    expect(await storedCookies(store), [
      '$second|example.com|token',
      '$moved|example.org|sid',
    ]);
    expect(secondJar.cookiesFor('https://second.example.com/'), 'token=second');
    // The moved source starts with the new site and cannot read the old one's
    // session, which now belongs to the other source alone.
    expect(movedJar.value('https://first.example.org/', 'sid'), 'moved');
    expect(movedJar.value('https://second.example.com/', 'token'), '');
    expect(await state.entry(first, 'cache.old'), isNull);
    expect(await state.entry(moved, 'cache.new'), 'n');
    await workspace.close();
  });

  test('a delete empties the source bucket, so the next writes fit', () async {
    const sourceRef = 'https://first.example.com/book';
    const limit = SpaceHostStatePersistence.cacheEntryLimit;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );

    for (var i = 0; i < limit; i++) {
      await state.putEntry(sourceRef, 'cache.$i', 'v$i');
    }
    expect(await storedEntryKeys(store, sourceRef), hasLength(limit));

    await state.deleteSource(sourceRef);
    expect(await storedEntryKeys(store, sourceRef), isEmpty);

    // The bucket is empty, so the next writes are not evicted against the
    // rows the deleted source used to hold.
    await state.putEntry(sourceRef, 'cache.a', 'a');
    await state.putEntry(sourceRef, 'cache.b', 'b');
    expect(await storedEntryKeys(store, sourceRef), ['cache.a', 'cache.b']);
    expect(await state.entry(sourceRef, 'cache.a'), 'a');
    await workspace.close();
  });
}
