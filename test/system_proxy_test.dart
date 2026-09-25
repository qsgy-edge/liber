import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/settings/system_proxy.dart';
import 'package:liber/settings/system_proxy_page.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// The system-proxy switch (#87): the `network.system_proxy` row, the page that
/// writes it, and the proxy answer the transport's client carries.
///
/// The polarity is the operator's confirmed one: **off is the direct
/// connection** this application has always used (the transport hardcoded
/// `DIRECT` before the switch existed), and on hands the request to Dart's
/// default, `HttpClient.findProxyFromEnvironment`.
///
/// The proxy answer is read at [sourceFindProxy], the one function the client's
/// `findProxy` is. `HttpClient.findProxy` is write-only in `dart:io` — nothing
/// can read the policy back off a client — so the observable seam is the
/// function every client is handed, plus the setting the transport asks its
/// client factory for. No row here sends a request, and none fakes a network.
void main() {
  late SpaceStore store;

  setUp(() {
    // The in-memory space the settings rows are pinned against, the way
    // `test/auto_change_source_test.dart` opens one; nothing here touches a
    // file.
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
  });

  tearDown(() => store.close());

  group('SystemProxySetting', () {
    test('键是 network.system_proxy，默认关闭：只有 putGlobal 写的 true 算开着', () {
      expect(SystemProxySetting.key, 'network.system_proxy');
      expect(SystemProxySetting.defaultEnabled, isFalse);
      expect(SystemProxySetting.fromStored(null), isFalse);
      expect(SystemProxySetting.fromStored('true'), isTrue);
      // A `settings.value` is free text: a hand-edited row must not quietly
      // move the installation's requests onto a proxy.
      expect(SystemProxySetting.fromStored('false'), isFalse);
      expect(SystemProxySetting.fromStored('1'), isFalse);
      expect(SystemProxySetting.fromStored('yes'), isFalse);
    });

    test('开关往返：写下的行按 putGlobal 的拼写照读', () async {
      expect(await store.setting(SystemProxySetting.key), isNull);
      expect(await SystemProxySetting.resolve(store), isFalse);

      await SystemProxySetting.putGlobal(store, enabled: true);
      expect(await store.setting(SystemProxySetting.key), 'true');
      expect(await SystemProxySetting.resolve(store), isTrue);

      await SystemProxySetting.putGlobal(store, enabled: false);
      expect(await store.setting(SystemProxySetting.key), 'false');
      expect(await SystemProxySetting.resolve(store), isFalse);
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

    test('关闭时，不论环境里配了什么，答案都是 DIRECT（本应用一直以来的行为）', () {
      expect(
        sourceFindProxy(remote, useSystemProxy: false, environment: proxied),
        'DIRECT',
        reason: '关闭就是直连：这一条钉住 master 一直硬写的那个行为',
      );
      expect(
        sourceFindProxy(loopback, useSystemProxy: false, environment: proxied),
        'DIRECT',
      );
      expect(
        sourceFindProxy(remote, useSystemProxy: false, environment: const {}),
        'DIRECT',
      );
      expect(
        sourceFindProxy(remote, useSystemProxy: false),
        'DIRECT',
        reason: '产品不传环境：默认这一侧仍然是直连',
      );
    });

    test('打开时按 Dart 自己的默认走：配了代理就照代理，不偷偷直连', () {
      expect(
        HttpClient.findProxyFromEnvironment(remote, environment: proxied),
        'PROXY 127.0.0.1:7897',
        reason: '先钉住 Dart 默认的答案，下面的期望值不是写死的字符串',
      );
      expect(
        sourceFindProxy(remote, useSystemProxy: true, environment: proxied),
        'PROXY 127.0.0.1:7897',
        reason: '打开时经过代理：用户要的就是系统代理',
      );
      expect(
        sourceFindProxy(
          loopback,
          useSystemProxy: true,
          environment: proxiedLoopback,
        ),
        'DIRECT',
        reason: 'no_proxy 是 Dart 默认自己的事，与开关无关',
      );
      expect(
        sourceFindProxy(remote, useSystemProxy: true, environment: const {}),
        'DIRECT',
        reason: '没有代理配置时，默认本来也是 DIRECT',
      );
      // No environment argument at all: the answer is Dart's own for this
      // machine, whatever it is, and never a hardcoded DIRECT.
      expect(
        sourceFindProxy(remote, useSystemProxy: true),
        HttpClient.findProxyFromEnvironment(remote),
      );
    });
  });

  group('HttpSourceTransport', () {
    SourceHttpRequest request() => SourceHttpRequest(
      method: 'GET',
      url: Uri.parse('http://127.0.0.1:1/x'),
    );

    /// The setting the transport asked its client factory for, without sending
    /// anything: the factory throws before a request can be built.
    Future<List<bool>> askedSettings({SpaceStore? withStore}) async {
      final asked = <bool>[];
      final transport = HttpSourceTransport(
        store: withStore,
        clientFactory: ({bool useSystemProxy = false}) {
          asked.add(useSystemProxy);
          throw StateError('工厂在发请求之前停下');
        },
      );
      await expectLater(transport.send(request()), throwsA(isA<StateError>()));
      return asked;
    }

    test('没有空间、也没有行时问的是关闭，也就是直连', () async {
      expect(await askedSettings(), [false], reason: '测试与工具建的传输层没有空间');
      expect(await askedSettings(withStore: store), [
        false,
      ], reason: '没有行等于关闭：直连，和开关存在之前一样');
    });

    test('打开的行读出来就是客户端拿到的 true', () async {
      await SystemProxySetting.putGlobal(store, enabled: true);
      expect(await askedSettings(withStore: store), [true]);

      await SystemProxySetting.putGlobal(store, enabled: false);
      expect(await askedSettings(withStore: store), [false]);
    });
  });

  group('SystemProxyPage', () {
    testWidgets('默认关闭：开关是关的，点开写 true，再点回写 false', (tester) async {
      await tester.pumpWidget(
        localizedApp(home: SystemProxyPage(store: store)),
      );
      await tester.pumpAndSettle();

      final switchFinder = find.byKey(const ValueKey('system-proxy-switch'));
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(await store.setting(SystemProxySetting.key), isNull);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(SystemProxySetting.key), 'true');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isTrue);

      await tester.tap(switchFinder);
      await tester.pumpAndSettle();
      expect(await store.setting(SystemProxySetting.key), 'false');
      expect(tester.widget<SwitchListTile>(switchFinder).value, isFalse);
      expect(tester.takeException(), isNull);
    });

    testWidgets('已存的行读回来就是开关的位置', (tester) async {
      await SystemProxySetting.putGlobal(store, enabled: true);
      await tester.pumpWidget(
        localizedApp(home: SystemProxyPage(store: store)),
      );
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<SwitchListTile>(
              find.byKey(const ValueKey('system-proxy-switch')),
            )
            .value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('页面读的是界面语言：默认简体是使用系统代理，English 下是英文', (tester) async {
      await tester.pumpWidget(
        localizedApp(home: SystemProxyPage(store: store)),
      );
      await tester.pumpAndSettle();
      expect(find.text('使用系统代理'), findsNWidgets(2), reason: '标题与开关');

      await tester.pumpWidget(
        localizedApp(
          home: SystemProxyPage(store: store),
          locale: const Locale('en'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Use the system proxy'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    });
  });
}
