import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/workspace.dart';

/// A transport that answers without a network and records every request, so the
/// outbound `Cookie` header a restarted source sends is observable.
class _RecordingTransport implements SourceHttpTransport {
  final requests = <SourceHttpRequest>[];

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: const {},
      body: 'ok',
      url: request.url,
    );
  }
}

/// The host surface lives in the space's `data.db` (ADR 0011 §3): what a run
/// writes is what the next run reads, and no other space reads it. These tests
/// close and reopen the space file the way the app restarts.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-host-state-');
  });

  tearDown(() => root.delete(recursive: true));

  test('cookies, cache entries and rule state survive a restart', () async {
    const sourceRef = 'https://www.example.com/book';
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    await state.cookiesFor(sourceRef).set('https://www.example.com/', 'sid=1');
    await state.putEntry(sourceRef, 'cache.key', 'cached');
    // `java.put`'s variable is stored under the baseline's own key
    // (`v_<sourceKey>_<key>`), which is the same mechanism as a cache entry.
    await state.putEntry(sourceRef, 'v_${sourceRef}_token', 'abc');
    await workspace.close();

    // The process ends here; the same space file is opened again.
    final reopened = await Workspace.open(root: root);
    final store2 = await reopened.openSpace();
    final restarted = SourceHostState(
      persistence: SpaceHostStatePersistence(store2),
    );
    final transport = _RecordingTransport();
    final dispatcher = SourceHostDispatcher(
      transport: transport,
      hostState: restarted,
      sourceRef: sourceRef,
    );
    await dispatcher.get('https://www.example.com/echo');
    expect(transport.requests.single.headers['Cookie'], 'sid=1');
    expect(await restarted.entry(sourceRef, 'cache.key'), 'cached');
    expect(await restarted.entry(sourceRef, 'v_${sourceRef}_token'), 'abc');
    await reopened.close();
  });

  test('a confirmed TLS exception survives a restart and never spills over',
      () async {
    const sourceRef = 'https://www.example.com/book';
    var workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    await state.allowInvalidCertificate(sourceRef, 'self-signed.example');
    await workspace.close();

    // The process ends here; the same space file is opened again.
    workspace = await Workspace.open(root: root);
    final reopened = SourceHostState(
      persistence: SpaceHostStatePersistence(await workspace.openSpace()),
    );
    await reopened.ready();
    expect(
      reopened.allowsInvalidCertificate(sourceRef, 'self-signed.example'),
      isTrue,
    );
    // The stored exception is the pair: another host, and another source on
    // the same host, both still fail.
    expect(
      reopened.allowsInvalidCertificate(sourceRef, 'other.example'),
      isFalse,
    );
    expect(
      reopened.allowsInvalidCertificate(
        'https://other.example/book',
        'self-signed.example',
      ),
      isFalse,
    );
    await workspace.close();
  });

  test('a second space has its own jar and cache', () async {
    const sourceRef = 'https://www.example.com/book';
    var workspace = await Workspace.open(root: root);
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(await workspace.openSpace()),
    );
    await state.cookiesFor(sourceRef).set('https://www.example.com/', 'sid=1');
    await state.putEntry(sourceRef, 'cache.key', 'cached');
    await workspace.close();

    // The private space owns its own database, so nothing of the first space's
    // sources is here (ADR 0011 §3, the space is the isolation unit).
    workspace = await Workspace.open(root: root);
    final other = SourceHostState(
      persistence: SpaceHostStatePersistence(
        await workspace.openSpace('private'),
      ),
    );
    await other.ready();
    expect(
      other.cookiesFor(sourceRef).cookiesFor('https://www.example.com/'),
      '',
    );
    expect(await other.entry(sourceRef, 'cache.key'), isNull);
    await workspace.close();
  });

  test('the saveTime deadline is one rule on the write and read paths', () async {
    var now = 1000;
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final state = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );
    await state.putEntry('s', 'permanent', 'p', saveTime: 0);
    await state.putEntry('s', 'timed', 't', saveTime: 1);
    // A `saveTime` of 0 has no deadline, and a deadline still ahead is a hit.
    expect(await state.entry('s', 'permanent'), 'p');
    expect(await state.entry('s', 'timed'), 't');
    // Reaching the deadline makes the same entry a miss, and the miss removes
    // the row instead of leaving it to be read again.
    now = 2000;
    expect(await state.entry('s', 'timed'), isNull);
    final rows = await store.db.select(store.db.sourceEntries).get();
    expect(rows.map((row) => row.key), ['permanent']);
    await workspace.close();
  });

  test('a row that expired while the space was closed is not read back', () async {
    var now = 1000;
    var workspace = await Workspace.open(root: root);
    var store = await workspace.openSpace();
    final before = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );
    await before.putEntry('s', 'timed', 't', saveTime: 1);
    await workspace.close();

    now = 5000;
    workspace = await Workspace.open(root: root);
    store = await workspace.openSpace();
    final after = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
      clock: () => now,
    );
    expect(await after.entry('s', 'timed'), isNull);
    expect(await store.db.select(store.db.sourceEntries).get(), isEmpty);
    await workspace.close();
  });
}
