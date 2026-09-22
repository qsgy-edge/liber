import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_login.dart';
import 'package:liber/source/source_login_dialog.dart';

import 'native_library.dart';

/// The installation id the form is handed: 16 lowercase hex characters, the
/// shape ADR 0011 §6 gives a real one.
const _installationId = '0123456789abcdef';
const _origin = 'http://a.test';

const _loginUi =
    '[{"name":"user"},'
    '{"name":"password","type":"password"},'
    '{"name":"submit","type":"button","action":"cache.put(\'button-result\', JSON.stringify(result))"},'
    '{"name":"verify","type":"button","action":"https://a.test/verify"}]';

Map<String, dynamic> _source({String loginUrl = ''}) => {
  'bookSourceUrl': _origin,
  'bookSourceName': '登录源',
  'loginUi': _loginUi,
  if (loginUrl.isNotEmpty) 'loginUrl': loginUrl,
};

SourceLoginSession _session(
  Map<String, dynamic> source, {
  required SourceHostState state,
}) => SourceLoginSession(
  source: source,
  hostState: state,
  androidId: _installationId,
  transport: HttpSourceTransport(),
);

/// Opens the dialog the way the migration page does. Runs inside
/// [WidgetTester.runAsync], where the login script's real work can finish.
Future<void> _open(WidgetTester tester, SourceLoginSession session) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => SourceLoginDialog(session: session),
            ),
            child: const Text('打开登录'),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.tap(find.text('打开登录'));
  await _waitFor(tester, find.byType(SourceLoginDialog));
}

/// Real work finishes on real time, so wait for the widget instead of guessing
/// a duration.
Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

/// The other half of [_waitFor]: wait for a widget the form is supposed to drop.
Future<void> _waitForGone(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (finder.evaluate().isEmpty) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _waitForEntry(SourceHostState state, String key) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    if (await state.entry(_origin, key) != null) return;
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  testWidgets('the form renders text, password and button rows and OK logs in', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final state = SourceHostState();
      final session = _session(
        _source(
          loginUrl:
              "@js:function login(){ cache.put('logged-in', source.getLoginInfo()); }",
        ),
        state: state,
      );
      await _open(tester, session);

      // The row kinds the frozen dialog renders.
      expect(find.byKey(const ValueKey('login-field-user')), findsOneWidget);
      expect(find.byKey(const ValueKey('login-field-password')), findsOneWidget);
      expect(find.byKey(const ValueKey('login-button-submit')), findsOneWidget);
      expect(find.byKey(const ValueKey('login-button-verify')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('login-field-password')))
            .obscureText,
        isTrue,
        reason: 'a password row is an obscured field',
      );

      await tester.enterText(
        find.byKey(const ValueKey('login-field-user')),
        'alice',
      );
      await tester.enterText(
        find.byKey(const ValueKey('login-field-password')),
        'pw',
      );

      // A button row runs the source's login script followed by the action, with
      // the collected form data bound as `result`
      // (`SourceLoginDialog.kt:126-153`).
      await tester.tap(find.byKey(const ValueKey('login-button-submit')));
      await _waitForEntry(state, 'button-result');
      expect(
        await state.entry(_origin, 'button-result'),
        jsonEncode({'user': 'alice', 'password': 'pw'}),
      );

      // OK stores the collected map and runs `login()`, then the surface closes.
      await tester.tap(find.text('确定'));
      await _waitForEntry(state, 'logged-in');
      expect(
        await state.entry(_origin, 'logged-in'),
        jsonEncode({'user': 'alice', 'password': 'pw'}),
      );
      expect(await getSourceLoginInfoMap(state, _origin, _installationId), {
        'user': 'alice',
        'password': 'pw',
      });
      await _waitForGone(tester, find.byType(SourceLoginDialog));
      expect(find.byType(SourceLoginDialog), findsNothing);
    });
  });

  testWidgets('the form opens with the stored login information', (tester) async {
    await tester.runAsync(() async {
      final state = SourceHostState();
      await putSourceLoginInfo(
        state,
        _origin,
        '{"user":"kept"}',
        _installationId,
      );
      await putSourceLoginHeader(
        state,
        _origin,
        '{"X-Login":"yes"}',
        state.cookiesFor(_origin),
      );
      final session = _session(_source(), state: state);
      await _open(tester, session);

      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('login-field-user')))
            .controller
            ?.text,
        'kept',
      );

      // The frozen 显示登录头 menu item shows what was stored.
      await tester.tap(find.text('登录头部'));
      await _waitFor(tester, find.text('{"X-Login":"yes"}'));
      await tester.tap(find.text('关闭'));
      await _waitForGone(tester, find.text('{"X-Login":"yes"}'));
      expect(
        find.byKey(const ValueKey('login-button-verify')),
        findsOneWidget,
        reason: 'closing the header dialog leaves the form open',
      );

      // 删除登录头 clears it together with the jar entry its `Cookie` replaced.
      await tester.tap(find.text('清除登录头部'));
      await _waitFor(tester, find.textContaining('已清除登录头部信息'));
      expect(await session.loginHeader(), isNull);
      expect(state.cookiesFor(_origin).cookiesFor(_origin), '');
    });
  });

  testWidgets('an absolute-URL button action refuses by name in the form', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final session = _session(_source(), state: SourceHostState());
      await _open(tester, session);
      await tester.tap(find.byKey(const ValueKey('login-button-verify')));
      await _waitFor(tester, find.byKey(const ValueKey('login-status')));
      expect(
        find.textContaining('绝对 URL'),
        findsOneWidget,
        reason: 'the refusal names the policy instead of a bare failure',
      );
    });
  });
}
