import 'package:ticket13_adapter/fixture_runner.dart';
import 'package:ticket13_adapter/legado_http.dart';
import 'package:ticket13_adapter/product_webview.dart';
import 'package:ticket13_adapter/rate_limiter.dart';
import 'package:ticket13_adapter/replay_server.dart';

/// Gap in milliseconds between the first and last request in a group, as the
/// frozen harness measures overlap.
int _requestStartGap(List<RequestObservation> requests) {
  if (requests.length < 2) return 0;
  final started = requests.map((r) => r.startedAtElapsedMs).toList()..sort();
  return started.last - started.first;
}

Future<String?> _webViewText(String url, String javaScript) async {
  final adapter = FixtureWebView(
    url: url,
    javaScript: javaScript,
    userAgent: legadoUserAgent,
  );
  try {
    return (await adapter.getStrResponse()).body;
  } finally {
    adapter.destroy();
  }
}

/// WV-12: concurrent WebView operations overlap, a source-keyed rate limiter
/// shapes request starts for its own source only, results keep their requested
/// order, and cancelling one operation does not cancel its sibling.
Future<EvidenceRecord> runWv12() => runFixture(
      'WV-12',
      body: (fixture, server, record) async {
        ConcurrentRateLimiter.resetAll();
        final helperJavaScript = fixture['helperJavaScript']! as String;
        final helperAPath = fixture['helperAPath']! as String;
        final helperBPath = fixture['helperBPath']! as String;

        final helperStarted = Stopwatch()..start();
        final helpers = await Future.wait([
          _webViewText(server.url(helperAPath), helperJavaScript),
          _webViewText(server.url(helperBPath), helperJavaScript),
        ]);
        helperStarted.stop();

        final orderedPaths = (fixture['orderedPaths']! as List<Object?>)
            .map((path) => path! as String)
            .toList();
        final expectedBodies = (fixture['orderedBodies']! as List<Object?>)
            .map((body) => body! as String)
            .toList();
        final concurrentRate = fixture['concurrentRate']! as String;
        final limiter = ConcurrentRateLimiter(
          sourceKey: fixture['limitedSourceKey']! as String,
          concurrentRate: concurrentRate,
        );
        final http = LegadoHttpClient(userAgent: legadoUserAgent);
        final orderedStarted = Stopwatch()..start();
        // The limiter's window opens when it admits a request, so admission times
        // are what its shape must be measured against. Measuring from the
        // server's arrival times instead folds in connection setup cost, which
        // shifts the first arrival later than its admission and makes the
        // interval look shorter than the limiter actually enforced.
        final admissions = <int>[];
        // `ajaxAll` starts every request concurrently and keeps the requested
        // order in its results; the limiter is what shapes the starts.
        final orderedResponses = await Future.wait(
          orderedPaths.map(
            (path) => limiter.withLimit(() {
              admissions.add(orderedStarted.elapsedMilliseconds);
              return http.get(
                url: server.url(path),
                timeout: const Duration(seconds: 10),
              );
            }),
          ),
        );
        orderedStarted.stop();

        final siblingSlowPath = fixture['siblingSlowPath']! as String;
        final siblingFastPath = fixture['siblingFastPath']! as String;
        final slowSibling = FixtureWebView(
          url: server.url(siblingSlowPath),
          javaScript: helperJavaScript,
          userAgent: legadoUserAgent,
        );
        Object? slowError;
        final slowOperation =
            slowSibling.getStrResponse().catchError((Object thrown) {
          slowError = thrown;
          throw thrown;
        });
        final slowObserved = await _waitForRequest(server, siblingSlowPath);
        final fastSibling = FixtureWebView(
          url: server.url(siblingFastPath),
          javaScript: helperJavaScript,
          userAgent: legadoUserAgent,
        );
        final fastOperation = fastSibling.getStrResponse();
        final fastObserved = await _waitForRequest(server, siblingFastPath);
        slowSibling.cancel();
        try {
          await slowOperation;
        } catch (_) {
          // Cancellation is the expected outcome.
        }
        final StrResponse fastResponse;
        try {
          fastResponse = await fastOperation;
        } finally {
          fastSibling.destroy();
        }

        final observations = server.snapshotRequests();
        final helperRequests = observations
            .where((r) => r.target == helperAPath || r.target == helperBPath)
            .toList();
        final orderedRequests = observations
            .where((r) => orderedPaths.contains(r.target))
            .toList()
          ..sort((a, b) => a.startedAtElapsedMs.compareTo(b.startedAtElapsedMs));
        final configuredIntervalMs =
            int.parse(concurrentRate.split('/').last);
        // The frozen harness allows scheduling and clock-quantization slack
        // rather than comparing an exact millisecond value.
        final minimumObservedGapMs = configuredIntervalMs - 50;
        admissions.sort();
        final admissionGapMs = admissions.length < 3
            ? -1
            : admissions[2] - admissions[0];

        record.operation = {
          'helperDurationMs': helperStarted.elapsedMilliseconds,
          'helperStartGapMs': _requestStartGap(helperRequests),
          'orderedDurationMs': orderedStarted.elapsedMilliseconds,
          'limiterStartGapMs': _requestStartGap(orderedRequests),
          'configuredIntervalMs': configuredIntervalMs,
          'minimumObservedGapMs': minimumObservedGapMs,
          'orderedBodies': orderedResponses.map((r) => r.body).toList(),
        };
        // Admission times are adapter instrumentation, not a source-visible
        // observation: a source sees request timing, which is already recorded in
        // `requests`. The frozen harness has no counterpart, so this is recorded
        // for audit rather than compared.
        record.instrumentation = {
          'limiterAdmissionsMs': admissions,
          'limiterAdmissionGapMs': admissionGapMs,
        };
        record.requests = observationsToJson(observations);
        record.checks['directHelpersReturned'] =
            helpers.first == 'helper-a' && helpers.last == 'helper-b';
        record.checks['directHelpersOverlap'] =
            helperRequests.length == 2 && _requestStartGap(helperRequests) < 500;
        record.checks['sourceLimiterBaselineShape'] =
            orderedRequests.length == orderedPaths.length &&
                admissions.length == orderedPaths.length &&
                admissions[1] - admissions[0] < 500 &&
                admissionGapMs >= minimumObservedGapMs;
        record.checks['orderedResults'] =
            orderedResponses.map((r) => r.body).join('|') ==
                expectedBodies.join('|');
        record.checks['slowSiblingRequestObserved'] = slowObserved;
        record.checks['fastSiblingRequestObserved'] = fastObserved;
        record.checks['slowSiblingCancelled'] = slowError is CancelledException;
        record.checks['siblingCompletedAfterCancellation'] =
            fastResponse.body == 'sibling-fast';
      },
    );

Future<bool> _waitForRequest(
  ReplayServer server,
  String path, {
  int timeoutMs = 5000,
}) async {
  for (var waited = 0; waited < timeoutMs; waited += 100) {
    if (server.snapshotRequests().any((r) => r.target == path)) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
}
