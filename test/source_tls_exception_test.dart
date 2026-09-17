import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';

/// The fixture certificates live in `test/fixtures/tls/`, and their exact
/// generation commands are in that directory's `README.md`. Two servers are
/// used, one per trust outcome:
///
/// * `localhost.crt` is self-signed, so no client trusts it: the certificate
///   failure ADR 0011 §5 is about, and the server the exception tests use.
/// * `localhost-signed.crt` is issued by `testca.crt`, the test certificate
///   authority the "trusts it" test installs as its anchor.
///
/// The leaf the client trusts carries a `serverAuth` ExtendedKeyUsage, a
/// subject alternative name holding both the DNS and the IP form of
/// `127.0.0.1`, and an 820-day lifetime (under 825), because macOS verifies a
/// client connection with `Security.framework` — the SDK's
/// `runtime/bin/security_context_macos.cc` calls
/// `SecTrustCreateWithCertificates`/`SecTrustSetAnchorCertificates` and reads
/// `SecTrustGetTrustResult` — and that evaluator enforces Apple's post-2019 TLS
/// server certificate rules for a certificate issued after 2019-07-01
/// (<https://support.apple.com/en-us/103769>). BoringSSL, which verifies on
/// Linux and Windows, enforces none of them, so a fixture that skipped them was
/// accepted there and rejected on macOS.
const _selfSignedCertificate = 'test/fixtures/tls/localhost.crt';
const _selfSignedPrivateKey = 'test/fixtures/tls/localhost.key';
const _testCaCertificate = 'test/fixtures/tls/testca.crt';
const _signedCertificate = 'test/fixtures/tls/localhost-signed.crt';
const _signedPrivateKey = 'test/fixtures/tls/localhost-signed.key';

SecurityContext _serverContext(String certificate, String privateKey) =>
    SecurityContext()
      ..useCertificateChain(certificate)
      ..usePrivateKey(privateKey);

class _TlsServer {
  _TlsServer(this._context);

  final SecurityContext _context;
  final List<Socket> _sockets = [];
  late final SecureServerSocket _server;

  String get authority => '127.0.0.1:${_server.port}';

  Future<void> start({String body = 'ok'}) async {
    _server = await SecureServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
      _context,
    );
    final response =
        'HTTP/1.1 200 OK\r\nContent-Length: ${body.length}\r\n'
        'Connection: close\r\n\r\n$body';
    _server.listen((socket) {
      _sockets.add(socket);
      var buffer = '';
      var sent = false;
      socket.listen(
        (bytes) {
          if (sent) return;
          buffer += utf8.decode(bytes, allowMalformed: true);
          if (!buffer.contains('\r\n\r\n')) return;
          sent = true;
          socket.add(utf8.encode(response));
          unawaited(socket.flush().then((_) => socket.close()));
        },
        // A client that aborts the handshake because it does not trust the
        // certificate is the failure under test, not a server error.
        onError: (Object _) {},
        onDone: () => _sockets.remove(socket),
      );
    }, onError: (Object _) {});
  }

  Future<void> stop() async {
    await _server.close();
    for (final socket in _sockets.toList()) {
      socket.destroy();
    }
  }
}

/// A transport that answers without a network and records the requests the
/// dispatcher built, so the resolved per-source, per-host flag is observable.
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

void main() {
  late _TlsServer server;
  late _TlsServer trustedServer;
  late SpaceStore store;
  late SourceHostState state;

  const sourceA = 'https://a.test/book';
  const sourceB = 'https://b.test/book';

  setUp(() async {
    server = _TlsServer(
      _serverContext(_selfSignedCertificate, _selfSignedPrivateKey),
    );
    trustedServer = _TlsServer(
      _serverContext(_signedCertificate, _signedPrivateKey),
    );
    await server.start();
    await trustedServer.start();
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    state = SourceHostState(persistence: SpaceHostStatePersistence(store));
  });

  tearDown(() async {
    await server.stop();
    await trustedServer.stop();
    await store.close();
  });

  SourceHostDispatcher dispatcher(
    String sourceRef, {
    SourceHttpTransport? transport,
  }) => SourceHostDispatcher(
    transport: transport ?? HttpSourceTransport(),
    hostState: state,
    sourceRef: sourceRef,
  );

  test(
    'a self-signed certificate is a named failure, not a generic one',
    () async {
      await expectLater(
        dispatcher(sourceA).get('https://${server.authority}/a'),
        throwsA(
          isA<SourceTlsCertificateFailure>()
              .having((e) => e.sourceRef, 'sourceRef', sourceA)
              .having((e) => e.host, 'host', '127.0.0.1')
              .having((e) => e.reason, 'reason', isNotEmpty)
              .having((e) => e.detail, 'detail', isNotEmpty),
        ),
      );
    },
  );

  test('the remembered exception lets that source reach that host', () async {
    // Before the confirmation, the source fails as above.
    await expectLater(
      dispatcher(sourceA).get('https://${server.authority}/a'),
      throwsA(isA<SourceTlsCertificateFailure>()),
    );

    // The confirmation's write, exactly as the dialog performs it.
    await state.allowInvalidCertificate(sourceA, '127.0.0.1');

    final response = await dispatcher(
      sourceA,
    ).get('https://${server.authority}/a');
    expect(response.statusCode, 200);
    expect(response.body, 'ok');
  });

  test('the exception never applies to another source', () async {
    await state.allowInvalidCertificate(sourceA, '127.0.0.1');
    await expectLater(
      dispatcher(sourceB).get('https://${server.authority}/b'),
      throwsA(isA<SourceTlsCertificateFailure>()),
    );
  });

  test('the exception never applies to another host', () async {
    final transport = _RecordingTransport();
    await state.allowInvalidCertificate(sourceA, 'other.test');
    await dispatcher(
      sourceA,
      transport: transport,
    ).get('https://${server.authority}/a');
    expect(transport.requests.single.sourceRef, sourceA);
    expect(transport.requests.single.allowInvalidCertificate, isFalse);
  });

  test('a certificate the client trusts needs no exception', () async {
    // The certificate authority that issued this server's leaf, installed as
    // this client's trust anchor, makes the certificate valid: the request
    // succeeds without a stored exception, so no confirmation is ever offered
    // for a certificate the client already trusts.
    final trusted = SecurityContext()
      ..setTrustedCertificates(_testCaCertificate);
    // The client is built outside the override zone (its constructor reads
    // `HttpOverrides.current`), then reused for every request the transport
    // makes inside it.
    final client = HttpClient(context: trusted);
    await HttpOverrides.runZoned(() async {
      final response = await dispatcher(
        sourceA,
      ).get('https://${trustedServer.authority}/a');
      expect(response.statusCode, 200);
      expect(response.body, 'ok');
      expect(state.allowsInvalidCertificate(sourceA, '127.0.0.1'), isFalse);
    }, createHttpClient: (_) => client);
  });

  test('the flag is resolved per source and host, not globally', () async {
    final transport = _RecordingTransport();
    await state.allowInvalidCertificate(sourceA, 'one.test');
    await dispatcher(sourceA, transport: transport).get('https://one.test/a');
    await dispatcher(sourceA, transport: transport).get('https://two.test/a');
    await dispatcher(sourceB, transport: transport).get('https://one.test/a');
    expect(transport.requests.map((r) => r.allowInvalidCertificate), [
      true,
      false,
      false,
    ]);
  });
}
