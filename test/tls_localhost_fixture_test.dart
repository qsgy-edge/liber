import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'tls_localhost_fixture.dart';

/// The fixture library the instrumented TLS-confirmation row depends on
/// (`integration_test/webview_tls_confirmation_test.dart`, #75), rehearsed where
/// it runs without a device — plus the pin that keeps its certificate copy the
/// committed fixture.
///
/// What only a device can show is the WebView's own trust challenge and the
/// confirmation above it; what this file shows is that the endpoint the device
/// row dials presents the committed self-signed certificate, that a client which
/// trusts nothing is refused, and that the refusal is still counted as a
/// connection — the distinction that tells "the certificate was presented and
/// rejected" from "the client never connected".
void main() {
  /// The DER bytes a PEM file wraps, base64 as the constants hold them.
  String committedDer(String path) {
    final body = File(path)
        .readAsStringSync()
        .replaceAll(RegExp(r'-----[^-]+-----'), '')
        .replaceAll(RegExp(r'\s+'), '');
    return base64.encode(base64.decode(body));
  }

  test('the embedded certificate pair is the committed fixture', () {
    expect(
      localhostCertificateDer,
      committedDer('test/fixtures/tls/localhost.crt'),
      reason:
          'the device has no checkout, so the copy is the only certificate '
          'the instrumented row can serve',
    );
    expect(
      localhostPrivateKeyDer,
      committedDer('test/fixtures/tls/localhost.key'),
    );
  });

  test(
    'a client that trusts nothing is refused, and the refusal is counted',
    () async {
      final server = await TlsLocalhostFixtureServer.bind(
        pageText: 'fixture page',
      );
      addTearDown(server.close);

      Object? thrown;
      Socket? socket;
      try {
        socket = await SecureSocket.connect(
          InternetAddress.loopbackIPv4,
          server.port,
          context: SecurityContext(withTrustedRoots: false),
          // A handshake that fails here is the point; a dial that hangs is not,
          // so the wait is bounded.
          timeout: const Duration(seconds: 10),
        );
      } catch (error) {
        thrown = error;
      }
      socket?.destroy();

      expect(
        thrown,
        isA<TlsException>(),
        reason: 'localhost.crt is self-signed: no client trusts it',
      );
      expect(
        server.connectionsAccepted,
        1,
        reason: 'the refused client still reached the fixture',
      );
      expect(
        server.pageRequests,
        0,
        reason: 'the refused client never saw the page',
      );
    },
  );
}
