import 'package:ticket13_adapter/fixture_runner.dart';
import 'package:ticket13_adapter/legado_http.dart';
import 'package:ticket13_adapter/product_webview.dart';

/// WV-13: an HTTP 500 is an ordinary response, an aborted connection throws, and
/// a main-frame 500 still yields its body with synthetic `200` metadata.
Future<EvidenceRecord> runWv13() => runFixture(
      'WV-13',
      body: (fixture, server, record) async {
        final http = LegadoHttpClient(userAgent: legadoUserAgent);
        final http500 =
            await http.get(url: server.url(fixture['http500Path']! as String));
        Object? abortError;
        try {
          await http.get(url: server.url(fixture['abortPath']! as String));
        } catch (thrown) {
          abortError = thrown;
        }
        final adapter = FixtureWebView(
          url: server.url(fixture['webView500Path']! as String),
          javaScript: fixture['javaScript'] as String?,
          userAgent: legadoUserAgent,
        );
        final StrResponse webView500;
        final bool webView500Cleaned;
        try {
          webView500 = await adapter.getStrResponse();
          // Observed before any explicit destroy, so the check measures whether
          // the adapter cleaned up on its own terminal path.
          webView500Cleaned = adapter.isDisposed && !adapter.hasWebView;
        } finally {
          adapter.destroy();
        }
        record.operation = {
          'http500': {
            'responseUrl': http500.url,
            'responseCode': http500.code,
            'responseBody': http500.body,
            'priorResponseCode': null,
          },
          'abortError': abortError == null ? null : errorJson(abortError),
          'webView500': {
            'responseUrl': webView500.url,
            'responseCode': webView500.code,
            'responseBody': webView500.body,
            'priorResponseCode': webView500.priorCode,
          },
        };
        record.requests = observationsToJson(server.snapshotRequests());
        record.checks['http500IsOrdinaryResponse'] =
            http500.code == 500 && http500.body == 'http-500';
        record.checks['abortedConnectionThrows'] = abortError != null;
        record.checks['mainFrame500BodyReturned'] =
            webView500.body == 'webview-500';
        record.checks['mainFrame500MetadataSynthetic200'] =
            webView500.code == 200;
        record.checks['mainFrameErrorCleanup'] = webView500Cleaned;
      },
    );

/// WV-14: the frozen baseline accepts an invalid TLS certificate, which the
/// security policy forbids, so this fixture can never be a pass. The destination
/// adapter refuses the certificate instead, and that refusal is recorded as a
/// policy divergence rather than as equivalent behavior.
///
/// The fixture's second half exercises an operation with neither URL nor HTML.
/// The frozen baseline fails and leaks its WebView; an internal resource leak is
/// a fixable defect rather than source-visible behavior, so the adapter cleans up
/// and the difference is recorded.
Future<EvidenceRecord> runWv14() => runFixture(
      'WV-14',
      body: (fixture, server, record) async {
        final tlsPath = fixture['tlsPath']! as String;
        final tlsAdapter = FixtureWebView(
          url: server.url(tlsPath),
          javaScript: fixture['javaScript'] as String?,
          userAgent: legadoUserAgent,
        );
        StrResponse? tlsResponse;
        Object? tlsError;
        bool tlsCleaned;
        try {
          tlsResponse = await tlsAdapter.getStrResponse();
          tlsCleaned = tlsAdapter.isDisposed && !tlsAdapter.hasWebView;
        } catch (thrown) {
          tlsError = thrown;
          // Observed before any explicit destroy, so the check measures the
          // adapter's own cleanup on the refusal path.
          tlsCleaned = tlsAdapter.isDisposed && !tlsAdapter.hasWebView;
        } finally {
          tlsAdapter.destroy();
        }

        final setupAdapter = FixtureWebView(userAgent: legadoUserAgent);
        Object? setupError;
        try {
          await setupAdapter.getStrResponse();
        } catch (thrown) {
          setupError = thrown;
        }
        final setupCleaned = setupAdapter.isDisposed && !setupAdapter.hasWebView;
        setupAdapter.destroy();

        final observations = server.snapshotRequests();
        // A TLS refusal is expected to abort the handshake, so the fixture is
        // reached without producing a request. The accepted-connection count is
        // what proves the certificate was actually presented.
        final reachedFixture = server.connectionsAccepted > 0;
        record.operation = {
          'tls': tlsResponse == null
              ? null
              : {
                  'responseUrl': tlsResponse.url,
                  'responseCode': tlsResponse.code,
                  'responseBody': tlsResponse.body,
                  'priorResponseCode': tlsResponse.priorCode,
                },
          'tlsError': tlsError == null ? null : errorJson(tlsError),
          'setupError': setupError == null ? null : errorJson(setupError),
          'adapterSetupCleanup': setupCleaned,
        };
        record.instrumentation = {
          'serverConnectionsAccepted': server.connectionsAccepted,
        };
        record.requests = observationsToJson(observations);
        // The forbidden capability is refused when the fixture's certificate was
        // presented and the operation did not proceed through it. The platform's
        // server-trust callback is one way to observe that; an engine that
        // refuses the handshake itself and reports no trust callback at all is
        // the same refusal, so the check is the observable outcome rather than
        // which callback fired.
        final refusedInvalidTls = reachedFixture &&
            tlsResponse == null &&
            tlsError != null;
        record.extra['policyReason'] = 'destination-refuses-invalid-tls';
        record.extra['policyRefusal'] = {
          'check': 'invalidTlsRefusedAfterCertificatePresented',
          'reason':
              'the fixture certificate was presented and the operation did not '
                  'proceed through it',
        };
        record.checks['invalidTlsReachedFixture'] = reachedFixture;
        record.checks['invalidTlsRefusedAfterCertificatePresented'] =
            refusedInvalidTls;
        record.checks['invalidTlsRefused'] =
            tlsResponse?.body != 'invalid-tls-accepted';
        record.checks['invalidTlsBodyNotReturned'] = tlsResponse == null;
        record.checks['tlsOperationCleanup'] = tlsCleaned;
        record.checks['setupFailureObserved'] = setupError != null;
        record.checks['setupCleanupCompleted'] = setupCleaned;
        record.policyRejected = refusedInvalidTls;
      },
    );
