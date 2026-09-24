import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_webview_adapter.dart';
import 'package:liber/source/inappwebview_book_source_adapter.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_tls_confirmation.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';

import '../test/l10n_support.dart';
import '../test/tls_localhost_fixture.dart';

/// ADR 0011 §5's agreeing and refusing halves on the rendered WebView path, on a
/// device (#75).
///
/// The `dart:io` half is witnessed by its own rows; what needs an engine is the
/// *rendered* half: a source whose page sits behind a certificate the platform
/// rejects, driven through the product's real
/// `InAppWebViewBookSourceAdapter` behind `BookSourceWebViewAdapterFactory`, the
/// application's own confirmation (`withTlsExceptionConfirmation`) asking the
/// question, and the answer given by the test's Flutter input — no OS-level
/// input, and nothing here touches the WV-01..WV-14 corpus or its fixtures.
///
/// The endpoint is a loopback HTTPS server serving the committed self-signed
/// fixture certificate (`test/fixtures/tls/localhost.{crt,key}`, carried into
/// the program by `test/tls_localhost_fixture.dart` because a device has no
/// checkout). A refusal still counts as a connection there, so the rows can tell
/// "the certificate was presented and rejected" from "the client never reached
/// the fixture" — the distinction the earlier Windows driver could not make.
///
/// Run it on the handset the ADR records:
///
/// ```text
/// flutter test integration_test/webview_tls_confirmation_test.dart -d 5615f742
/// ```
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The composition root's own installation (`lib/main.dart`), once for the
  // process: without it the model layer refuses the WebView path by name.
  setUpAll(installInAppWebViewBookSourceAdapter);

  // The engine's server-trust challenge is what this file drives, and only
  // Android's adapter surfaces it today: the Windows WebView2 plugin never raises
  // one (the committed Windows `WV-14` row shows the engine connecting and
  // timing out instead, #75) and the Apple and Linux adapters do not exist yet
  // (#56). On any other platform the rows are not-run, named, rather than red for
  // a reason the ticket already records.
  final skipReason = Platform.isAndroid
      ? null
      : 'this row needs a WebView whose engine raises the server-trust '
            'challenge: Windows never does (committed WV-14 row), and the Apple '
            'and Linux adapters do not exist yet (#56)';

  group('the rendered WebView path under a real engine', skip: skipReason, () {
    // The refusal row runs first on purpose. Android's WebView persists a
    // user's *proceed* decision for a host, so once the agree row has answered
    // 继续（不安全） the engine raises no challenge for a later row on the same host
    // (only the port differs) and that row would assert against a platform
    // memory instead of the product. A cancel leaves no persisted preference,
    // so the refusing row's challenge is the one the engine always raises.
    // The platform fact itself is worth recording (#75): the product's
    // confirmation is per source *and* host, but the engine can skip it for a
    // host the user has already accepted elsewhere.

    testWidgets(
      'answering 取消 stores nothing and leaves the failure named',
      (tester) async {
        final directory = await Directory.systemTemp.createTemp(
          'liber-tls-refuse-',
        );
        final store = SpaceStore(
          SpaceDatabase.file(File('${directory.path}/data.db')),
        );
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });
        final state = SourceHostState(
          persistence: SpaceHostStatePersistence(store),
        );
        final server = await TlsLocalhostFixtureServer.bind(
          pageText: _pageText,
        );
        addTearDown(server.close);
        final sourceRef = 'https://${server.authority}/book';

        final factory = _CountingFactory(
          sourceRef: sourceRef,
          hostState: state,
        );
        final read = await _driveRead(
          tester,
          state: state,
          factory: factory,
          url: server.url,
          answer: _cancel,
        );

        expect(read.asks, 1);
        expect(
          read.namedSourceAndHost,
          isTrue,
          reason: 'the confirmation names the source and the challenged host',
        );
        expect(read.body, isNull, reason: 'a refusal renders nothing');
        expect(
          read.error,
          isA<SourceTlsCertificateFailure>()
              .having((failure) => failure.sourceRef, 'sourceRef', sourceRef)
              .having((failure) => failure.host, 'host', _challengedHost)
              .having(
                (failure) => failure.reason,
                'reason',
                SourceTlsCertificateFailure.unspecifiedReason,
              ),
        );
        expect(factory.attempts, 1, reason: 'a refusal re-runs nothing');
        expect(
          state.allowsInvalidCertificate(sourceRef, _challengedHost),
          isFalse,
        );
        expect(
          await store.db.select(store.db.sourceTlsExceptions).get(),
          isEmpty,
        );
        expect(
          server.connectionsAccepted,
          greaterThanOrEqualTo(1),
          reason:
              'the certificate was presented; the client reached the fixture',
        );
        expect(
          server.pageRequests,
          0,
          reason: 'nothing was rendered through the certificate',
        );
        expect(tester.takeException(), isNull);

        debugPrint(
          'TLS_CONFIRMATION_REFUSE asks=${read.asks} attempts=${factory.attempts} '
          'storedExceptions=0 connections=${server.connectionsAccepted} '
          'pageRequests=${server.pageRequests} error=${read.error}',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    testWidgets(
      'a rendered certificate failure asks once, stores the exception and proceeds',
      (tester) async {
        final directory = await Directory.systemTemp.createTemp(
          'liber-tls-agree-',
        );
        final store = SpaceStore(
          SpaceDatabase.file(File('${directory.path}/data.db')),
        );
        addTearDown(() async {
          await store.close();
          await directory.delete(recursive: true);
        });
        final state = SourceHostState(
          persistence: SpaceHostStatePersistence(store),
        );
        final server = await TlsLocalhostFixtureServer.bind(
          pageText: _pageText,
        );
        addTearDown(server.close);
        final sourceRef = 'https://${server.authority}/book';

        // The first read: nothing is stored, so the engine's challenge refuses the
        // page, the confirmation asks, and 继续（不安全） stores the pair and re-runs
        // the operation.
        final first = _CountingFactory(sourceRef: sourceRef, hostState: state);
        final read = await _driveRead(
          tester,
          state: state,
          factory: first,
          url: server.url,
          answer: _continueUnsafe,
        );

        expect(read.asks, 1, reason: 'the confirmation asks once');
        expect(
          read.namedSourceAndHost,
          isTrue,
          reason: 'the confirmation names the source and the challenged host',
        );
        expect(read.error, isNull, reason: 'the read proceeded after agreeing');
        expect(read.body?.trim(), _pageText);
        expect(first.attempts, 2, reason: 'the refused attempt and the retry');
        expect(server.pageRequests, greaterThanOrEqualTo(1));

        // The stored exception is the product's own `source_tls_exceptions` row,
        // keyed by the source and the host the challenge named.
        final stored = await store.db
            .select(store.db.sourceTlsExceptions)
            .get();
        expect(
          stored.map((row) => (row.sourceRef, row.host)),
          contains((sourceRef, _challengedHost)),
        );

        // A second read through a state re-read from `data.db`, so what proceeds
        // is the persisted row and not this process's memory of the answer.
        final restarted = SourceHostState(
          persistence: SpaceHostStatePersistence(store),
        );
        await restarted.ready();
        expect(
          restarted.allowsInvalidCertificate(sourceRef, _challengedHost),
          isTrue,
        );
        final second = _CountingFactory(
          sourceRef: sourceRef,
          hostState: restarted,
        );
        final reread = await _driveRead(
          tester,
          state: restarted,
          factory: second,
          url: server.url,
          answer: null,
        );

        expect(
          reread.asks,
          0,
          reason: 'the stored exception is not asked again',
        );
        expect(reread.error, isNull);
        expect(reread.body?.trim(), _pageText);
        expect(second.attempts, 1);
        expect(server.connectionsAccepted, greaterThanOrEqualTo(1));
        expect(tester.takeException(), isNull);

        debugPrint(
          'TLS_CONFIRMATION_ACCEPT asks=${read.asks}+${reread.asks} '
          'attempts=${first.attempts}+${second.attempts} '
          'storedExceptions=${stored.length} '
          'connections=${server.connectionsAccepted} '
          'pageRequests=${server.pageRequests} body=${read.body}',
        );
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}

/// The page the endpoint serves, read back out of the rendered document.
const String _pageText = 'a page behind an untrusted certificate';

/// The source the confirmation names.
const String _sourceName = '证书测试书源';

/// The dialog copy the confirmation is found by, in the 简体 interface these
/// rows pump.
const String _dialogTitle = '证书校验失败';
const String _continueUnsafe = '继续（不安全）';
const String _cancel = '取消';

/// The host the engine challenges: the endpoint's own loopback address, not the
/// source's identity URL, because a certificate failure is the host's.
const String _challengedHost = '127.0.0.1';

/// What one driven read produced, and what the drive itself observed.
class _Read {
  _Read({
    required this.body,
    required this.error,
    required this.asks,
    required this.namedSourceAndHost,
  });

  final String? body;
  final Object? error;

  /// How many times the confirmation appeared while this read ran.
  final int asks;

  /// Whether the confirmation it saw named the source and the host.
  final bool namedSourceAndHost;
}

/// A factory that counts the adapters one operation created, so "the retry ran"
/// and "nothing re-ran" are numbers rather than inferences. Nothing else is
/// substituted: `create()` is the binding the application installs.
class _CountingFactory extends BookSourceWebViewAdapterFactory {
  _CountingFactory({required super.sourceRef, required super.hostState});

  int attempts = 0;

  @override
  BookSourceWebViewAdapter create() {
    attempts++;
    return super.create();
  }
}

/// Drives one rendered read the way the pages that show sources do: the real
/// factory's adapter under the application's own [withTlsExceptionConfirmation],
/// in a widget whose only control starts it.
///
/// [answer] is the confirmation button this read's user presses, or null for a
/// read that must not be asked at all. The dialog is pumped and answered with
/// Flutter test input; no OS-level input is used or needed.
Future<_Read> _driveRead(
  WidgetTester tester, {
  required SourceHostState state,
  required _CountingFactory factory,
  required String url,
  required String? answer,
}) async {
  final host = Uri.parse(url).host;

  final done = Completer<void>();
  String? body;
  Object? error;
  await tester.pumpWidget(
    localizedApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async {
                try {
                  final response = await withTlsExceptionConfirmation(
                    context: context,
                    hostState: state,
                    sourceRef: factory.sourceRef,
                    sourceName: _sourceName,
                    run: () => factory.create().load(
                      SourceWebViewRequest(
                        url: url,
                        javaScript: 'document.body.innerText',
                      ),
                    ),
                  );
                  body = response.body;
                } catch (thrown) {
                  error = thrown;
                } finally {
                  if (!done.isCompleted) done.complete();
                }
              },
              child: const Text('run'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('run'));

  var asks = 0;
  var namedSourceAndHost = false;
  var confirmationUp = false;
  var answered = false;
  // The engine's own load has a 60 s timeout inside it, so a drive that outlives
  // this bound is a failure of the row, not a slow device.
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    final up = find.text(_dialogTitle).evaluate().isNotEmpty;
    if (up && !confirmationUp) {
      asks++;
      namedSourceAndHost =
          find.textContaining(_sourceName).evaluate().isNotEmpty &&
          find.textContaining(host).evaluate().isNotEmpty;
    }
    confirmationUp = up;
    if (up) {
      expect(
        answer,
        isNotNull,
        reason: 'the confirmation asked where none should',
      );
      if (!answered) {
        answered = true;
        await tester.tap(find.text(answer!));
        // Wait for the dialog to leave the tree, so a later appearance counts as
        // its own ask rather than as a fading frame of this one.
        for (
          var index = 0;
          index < 50 && find.text(_dialogTitle).evaluate().isNotEmpty;
          index++
        ) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        confirmationUp = false;
      }
    }
    if (done.isCompleted) break;
  }
  expect(
    done.isCompleted,
    isTrue,
    reason:
        'the driven read did not finish within 120 s '
        '(asks=$asks, attempts=${factory.attempts})',
  );
  return _Read(
    body: body,
    error: error,
    asks: asks,
    namedSourceAndHost: namedSourceAndHost,
  );
}
