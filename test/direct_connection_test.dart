import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/direct_connection.dart';
import 'package:liber/settings/direct_connection_page.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// The direct-connection switch (#87): the `network.direct` row, the page that
/// writes it, and the proxy answer the transport's client carries.
///
/// The proxy answer is read at [sourceFindProxy], the one function the client's
/// `findProxy` is. `HttpClient.findProxy` is write-only in `dart:io` — nothing
/// can read the policy back off a client — so the observable seam is the
/// function every client is handed, plus the flag the transport asks its client
/// factory for. No row here sends a request, and none fakes a network.
void main() {
  late SpaceStore store;

  setUp(() {
    // The in-memory space the settings rows are pinned against, the way
    // `test/auto_change_source_test.dart` opens one; nothing here touches a
    // file.
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
  });

  tearDown(() => store.close());

  group('DirectConnectionSetting', () {
    test('键是 network.direct，默认关闭：只有 putGlobal 写的 true 算开着', () {
      expect(DirectConnectionSetting.key, 'network.direct');
      expect(DirectConnectionSetting.defaultEnabled, isFalse);
      expect(DirectConnectionSetting.fromStored(null), isFalse);
      expect(DirectConnectionSetting.fromStored('true'), isTrue);
      // A `settings.value` is free text: a hand-edited row must not turn the
      // installation's traffic around the user's proxy.
      expect(DirectConnectionSetting.fromStored('false'), isFalse);
      expect(DirectConnectionSetting.fromStored('1'), isFalse);
      expect(DirectConnectionSetting.fromStored('yes'), isFalse);
    });

    test('开关往返：写下的行按 putGlobal 的拼写照读', () async {
      expect(await store.setting(DirectConnectionSetting.key), isNull);
      expect(await DirectConnectionSetting.resolve(store), isFalse);

      await DirectConnectionSetting.putGlobal(store, enabled: true);
      expect(await store.setting(DirectConnectionSetting.key), 'true');
      expect(await DirectConnectionSetting.resolve(store), isTrue);

      await DirectConnectionSetting.putGlobal(store, enabled: false);
      expect(await store.setting(DirectConnectionSetting.key), 'false');
      expect(await DirectConnectionSetting.resolve(store), isFalse);
    });
  });

  group('sourceFindProxy', () {
    // #87's measured failure: the source's detail URL, with the operator's own
    // proxy configured.
    final remote = Uri.parse('http://m.4020xs.com/Txt/XiaoShuo-375656.html');
    const proxied = {'HTTP_PROXY': 'http://127.0.0.1:7897'};
    final loopback = Uri.parse('http://127.0.0.1:41235/a');
    const proxiedLoopback = {
      'HTTP_PROXY': 'http://127.0.0.1:7897',
      'NO_PROXY': 'localhost,127.0.0.1',
    };

    test('打开时，不论环境里配了什么，答案都是 DIRECT', () {
      expect(
        sourceFindProxy(remote, directConnection: true, environment: proxied),
        'DIRECT',
      );
      expect(
        sourceFindProxy(loopback, directConnection: true, environment: proxied),
        'DIRECT',
      );
      // Nothing configured either: still the switch that answered.
      expect(
        sourceFindProxy(remote, directConnection: true, environment: const {}),
        'DIRECT',
      );
    });

    test('关闭时是 Dart 自己的默认：配了代理就照代理走，不偷偷直连', () {
      expect(
        HttpClient.findProxyFromEnvironment(remote, environment: proxied),
        'PROXY 127.0.0.1:7897',
        reason: '先钉住 Dart 默认的答案，下面的期望值不是写死的字符串',
      );
      expect(
        sourceFindProxy(remote, directConnection: false, environment: proxied),
        'PROXY 127.0.0.1:7897',
        reason: '关闭时经过代理：代理是用户自己配的，开关不替用户决定',
      );
      expect(
        sourceFindProxy(
          loopback,
          directConnection: false,
          environment: proxiedLoopback,
        ),
        'DIRECT',
        reason: 'no_proxy 是 Dart 默认自己的事，与开关无关',
      );
      expect(
        sourceFindProxy(remote, directConnection: false, environment: const {}),
        'DIRECT',
        reason: '没有代理配置时，默认本来也是 DIRECT',
      );
      // The product passes no environment: the answer is Dart's own for this
      // machine, whatever it is, and never a hardcoded DIRECT.
      expect(
        sourceFindProxy(remote, directConnection: false),
        HttpClient.findProxyFromEnvironment(remote),
      );
    });
  });

  group('HttpSourceTransport', () {
    SourceHttpRequest request() => SourceHttpRequest(
      method: 'GET',
      url: Uri.parse('http://127.0.0.1:1/x'),
    );

    /// The flag the transport asked its client factory for, without sending
    /// anything: the factory throws before a request can be built.
    Future<List<bool>> askedFlags({SpaceStore? withStore}) async {
      final asked = <bool>[];
      final transport = HttpSourceTransport(
        store: withStore,
        clientFactory: ({bool directConnection = false}) {
          asked.add(directConnection);
          throw StateError('工厂在发请求之前停下');
        },
      );
      await expectLater(transport.send(request()), throwsA(isA<StateError>()));
      return asked;
    }

    test('没有空间、也没有行时问的是关闭，也就是 Dart 的默认', () async {
      expect(await askedFlags(), [false], reason: '测试与工具建的传输层没有空间');
      expect(await askedFlags(withStore: store), [false], reason: '没有行等于关闭');
    });

    test('打开的行读出来就是客户端拿到的 true', () async {
      await DirectConnectionSetting.putGlobal(store, enabled: true);
      expect(await askedFlags(withStore: store), [true]);

      await DirectConnectionSetting.putGlobal(store, enabled: false);
      expect(await askedFlags(withStore: store), [false]);
    });
  });

  group('DirectConnectionPage', () {
    testWidgets('默认关闭：开关是关的，点开写 true，再点回写 false', (tester) async {
      await tester.pumpWidget(
        localizedApp(home: DirectConnectionPage(store: store)),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(
        const ValueKey('direct-connection-switch'),
      );
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(await store.setting(DirectConnectionSetting.key), isNull);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(DirectConnectionSetting.key), 'true');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(DirectConnectionSetting.key), 'false');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已存的行读回来就是开关的位置', (tester) async {
      await DirectConnectionSetting.putGlobal(store, enabled: true);
      await tester.pumpWidget(
        localizedApp(home: DirectConnectionPage(store: store)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('direct-connection-switch')),
            )
            .value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('页面读的是界面语言：默认简体，English 下就是英文', (tester) async {
      await tester.pumpWidget(
        localizedApp(home: DirectConnectionPage(store: store)),
      );
      await tester.pumpAndSettle();
      expect(find.text('直连'), findsOneWidget);
      expect(find.text('直连（不经过系统代理）'), findsOneWidget);

      await tester.pumpWidget(
        localizedApp(
          home: DirectConnectionPage(store: store),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Direct connection'), findsOneWidget);
      expect(
        find.text('Direct connection (bypass the system proxy)'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });
  });
}
