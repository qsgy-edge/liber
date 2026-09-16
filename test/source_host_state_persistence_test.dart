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
}
