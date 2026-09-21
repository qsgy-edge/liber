import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path_provider/path_provider.dart';

import 'cookie_store.dart';
import 'legado_http.dart';
import 'product_webview.dart';
import 'replay_server.dart';

/// Baseline commit the golden evidence was produced from.
const String baselineCommit = '14dd24945b2914ce2708b8abaa4ee67ceef892af';

/// The frozen baseline's configured `AppConfig.userAgent` in the golden run.
const String legadoUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

/// Writes evidence to the device path the run script pulls from. Fixtures are
/// bundled rather than pushed because installing the app clears its external
/// files directory, so a pushed fixture cannot survive the install that precedes
/// a test run. The asset copy is produced mechanically by
/// `tool/sync_fixtures.sh` from the committed fixtures, and each fixture's bytes
/// are hashed at run time, so a fixture cannot drift from the committed copy
/// without changing its recorded hash.
class DevicePaths {
  DevicePaths(this.root);

  static Future<DevicePaths> resolve() async {
    // Android keeps evidence and the run-time selector under the app's external
    // files directory, which `adb` can read and write. A desktop platform has no
    // such directory, and the application support directory is the app-private
    // location the host can reach on all of them.
    final root = Platform.isAndroid
        ? await getExternalStorageDirectory()
        : await getApplicationSupportDirectory();
    return DevicePaths(root ?? await getApplicationDocumentsDirectory());
  }

  final Directory root;

  Directory get evidenceDirectory =>
      Directory('${root.path}/ticket13-adapter');
}

class FixtureInput {
  FixtureInput(this.id, this.json, this.sha256);

  final String id;
  final Map<String, Object?> json;
  final String sha256;

  static Future<FixtureInput> load(String id) async {
    final data = await rootBundle.load('assets/fixtures/$id.json');
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final json = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
    return FixtureInput(id, json, sha256Hex(bytes));
  }
}

String sha256Hex(List<int> bytes) => sha256.convert(bytes).toString();

/// The destination row this run belongs to. The comparison uses it to decide
/// whether a same-device/same-WebView gate applies, so a platform must declare
/// its own row rather than inherit Android's.
String get destinationTarget {
  if (Platform.isAndroid) return 'android-destination-adapter';
  if (Platform.isWindows) return 'windows-destination-adapter';
  if (Platform.isMacOS) return 'macos-destination-adapter';
  if (Platform.isLinux) return 'linux-destination-adapter';
  if (Platform.isIOS) return 'ios-destination-adapter';
  throw UnsupportedError('unknown destination platform');
}

/// The engine's own user agent, measured in process.
///
/// `getDefaultUserAgent` is declared by the Windows wrapper but not implemented
/// natively, so there the value is read from a short-lived headless WebView that
/// carries no user-agent override. That also keeps the recorded engine version
/// tied to the engine the fixtures actually ran on rather than to a host-supplied
/// value.
String? _measuredDefaultUserAgent;

Future<String> defaultUserAgent() async {
  final cached = _measuredDefaultUserAgent;
  if (cached != null) return cached;
  if (!Platform.isWindows) {
    return _measuredDefaultUserAgent =
        await InAppWebViewController.getDefaultUserAgent();
  }
  final probe = HeadlessInAppWebView(
    initialSettings: InAppWebViewSettings(javaScriptEnabled: true),
  );
  try {
    await probe.run();
    final controller = probe.webViewController!;
    await controller.loadData(data: '<html></html>', mimeType: 'text/html');
    final agent = await controller.evaluateJavascript(
      source: 'navigator.userAgent',
    );
    return _measuredDefaultUserAgent = agent?.toString() ?? '';
  } finally {
    await probe.dispose();
  }
}

/// Provenance of the machine the destination adapter actually ran on.
Future<Map<String, Object?>> collectProvenance() async {
  final measuredUserAgent = await defaultUserAgent();
  if (Platform.isAndroid) {
    final info = await DeviceInfoPlugin().androidInfo;
    final webViewPackage =
        await InAppWebViewController.getCurrentWebViewPackage();
    return {
      'device': {
        'manufacturer': info.manufacturer,
        'model': info.model,
        'device': info.device,
        'androidRelease': info.version.release,
        'sdk': info.version.sdkInt,
        'fingerprint': info.fingerprint,
      },
      'runtime': {
        'webViewPackage': webViewPackage?.packageName,
        'webViewVersion': webViewPackage?.versionName,
        'defaultUserAgent': measuredUserAgent,
        'configuredUserAgent': legadoUserAgent,
      },
    };
  }
  if (Platform.isWindows) {
    final info = await DeviceInfoPlugin().windowsInfo;
    return {
      'device': {
        'manufacturer': 'Microsoft',
        'model': info.productName,
        'device': info.computerName,
        'windowsBuild':
            '${info.majorVersion}.${info.minorVersion}.${info.buildNumber}',
        'displayVersion': info.displayVersion,
        // A Windows install has no Android-style build fingerprint; the closest
        // stable identity is the OS build plus the machine's install id.
        'fingerprint':
            'windows/${info.productName}/${info.majorVersion}.${info.minorVersion}.${info.buildNumber}/${info.displayVersion}',
      },
      'runtime': {
        // The Windows implementation has no `getCurrentWebViewPackage`, so the
        // engine version is taken from the user agent the runtime itself
        // reports rather than from a host-supplied value.
        'webViewPackage': 'Microsoft.Web.WebView2',
        'webViewVersion':
            RegExp(r'Chrome/([0-9.]+)').firstMatch(measuredUserAgent)?.group(1),
        'defaultUserAgent': measuredUserAgent,
        'configuredUserAgent': legadoUserAgent,
      },
    };
  }
  throw UnsupportedError('provenance not implemented for this platform');
}

/// One executed destination fixture, written in the same shape as the frozen
/// oracle evidence so rows can be compared without reshaping either side.
class EvidenceRecord {
  EvidenceRecord(this.fixtureId, this.fixtureSha256);

  final String fixtureId;
  final String fixtureSha256;
  final DateTime startedAt = DateTime.now().toUtc();
  final Map<String, bool> checks = {};

  /// `main` or `restart`; the host driver keeps the two phases in separate files
  /// and merges them, mirroring how the frozen oracle appends a restart block.
  String phase = 'main';

  /// A map for single-operation fixtures, or a list where the frozen oracle
  /// records several operations for one fixture.
  Object? operation = const <String, Object?>{};

  /// Extra top-level fields the frozen oracle records for specific fixtures,
  /// such as `cookieStore` or `restart`.
  final Map<String, Object?> extra = {};
  List<Map<String, Object?>> requests = [];
  String verdict = 'fail';
  String? failure;

  /// Set where the fixture exercises a capability the security policy forbids.
  /// Such a fixture can never be a pass; with every observation satisfied it is
  /// recorded as `policy-rejected`.
  bool policyRejected = false;

  /// Adapter-side measurements that have no counterpart in the frozen oracle.
  /// They are recorded for audit and are not compared, because a source cannot
  /// observe them; anything a source can observe belongs in `requests`,
  /// `operation`, or `checks`.
  Map<String, Object?> instrumentation = const <String, Object?>{};

  /// The evidence payload. It is returned to the host through the integration
  /// test binding's report data rather than written on the device, because the
  /// test runner uninstalls the app when a run finishes and an uninstall removes
  /// the app's external files directory along with anything written there.
  Future<Map<String, Object?>> toJson() async {
    final provenance = await collectProvenance();
    return <String, Object?>{
      'schemaVersion': 1,
      'fixtureId': fixtureId,
      'fixtureSha256': fixtureSha256,
      'baselineCommit': baselineCommit,
      'target': destinationTarget,
      'adapter': {
        'implementation': 'flutter_inappwebview',
        'headlessWebView': true,
      },
      'phase': phase,
      'startedAtUtc': startedAt.toIso8601String(),
      'completedAtUtc': DateTime.now().toUtc().toIso8601String(),
      ...provenance,
      'operation': operation,
      if (instrumentation.isNotEmpty) 'instrumentation': instrumentation,
      ...extra,
      'requests': requests,
      'checks': checks,
      'failure': failure,
      'executionVerdict': verdict,
    };
  }
}

List<Map<String, Object?>> observationsToJson(
  List<RequestObservation> observations,
) =>
    observations.map((observation) => observation.toJson()).toList();

Map<String, String> fixtureHeaders(Map<String, Object?> fixture, String key) {
  final headers = fixture[key] as Map<String, Object?>?;
  if (headers == null) return const {};
  return headers.map((name, value) => MapEntry(name, value! as String));
}

/// Runs one fixture, recording the operation, requests, and checks in the shape
/// the frozen oracle emits. A thrown error is recorded as a failure rather than
/// escaping, so the evidence file still exists for comparison.
Future<EvidenceRecord> runFixture(
  String id, {
  required Future<void> Function(
    Map<String, Object?> fixture,
    ReplayServer server,
    EvidenceRecord record,
  ) body,
  int port = 0,
  String phase = 'main',
}) async {
  final fixture = await FixtureInput.load(id);
  final record = EvidenceRecord(fixture.id, fixture.sha256)..phase = phase;
  final server = await ReplayServer.bind(fixture.json, port: port);
  try {
    await body(fixture.json, server, record);
    final satisfied = record.checks.isNotEmpty &&
        record.checks.values.every((value) => value) &&
        record.failure == null;
    record.verdict = satisfied
        ? (record.policyRejected ? 'policy-rejected' : 'pass')
        : 'fail';
  } catch (error) {
    record.failure = error.toString();
    record.verdict = 'fail';
  } finally {
    if (record.requests.isEmpty) {
      record.requests = observationsToJson(server.snapshotRequests());
    }
    await server.close();
  }
  return record;
}

/// WV-01: hidden direct GET, source header, default `outerHTML`, final URL,
/// synthetic `200`, and cleanup.
Future<EvidenceRecord> runWv01() async {
  final fixture = await FixtureInput.load('WV-01');
  final record = EvidenceRecord(fixture.id, fixture.sha256);
  final server = await ReplayServer.bind(fixture.json);
  final request = fixture.json['request']! as Map<String, Object?>;
  final headers = (request['headers']! as Map<String, Object?>)
      .map((name, value) => MapEntry(name, value! as String));
  final target = server.url(fixture.json['path']! as String);
  final adapter = FixtureWebView(
    url: target,
    headerMap: headers,
    userAgent: legadoUserAgent,
  );
  final stopwatch = Stopwatch()..start();
  try {
    final response = await adapter.getStrResponse();
    stopwatch.stop();
    final observations = server.snapshotRequests();
    final main = observations.isEmpty ? null : observations.first;
    record.operation = {
      'durationMs': stopwatch.elapsedMilliseconds,
      'responseUrl': response.url,
      'responseCode': response.code,
      'responseBody': response.body,
      'priorResponseCode': response.priorCode,
    };
    record.requests = observationsToJson(observations);
    record.checks['requestObserved'] = main != null;
    record.checks['requestMethod'] = main?.method == 'GET';
    record.checks['requestPath'] = main?.target == fixture.json['path'];
    record.checks['sourceHeader'] = main?.headers['x-wayfinder'] == 'wv01';
    record.checks['configuredUserAgent'] =
        main?.headers['user-agent'] == legadoUserAgent;
    record.checks['defaultOuterHtml'] = response.body != null &&
        response.body!.startsWith('<html>') &&
        response.body!.contains('<main id="oracle">frozen-android</main>');
    record.checks['finalUrl'] = response.url == target;
    record.checks['syntheticStatus'] =
        response.code == 200 && response.priorCode == null;
    record.checks['normalCleanup'] = adapter.isDisposed && !adapter.hasWebView;
    record.verdict =
        record.checks.values.every((value) => value) ? 'pass' : 'fail';
  } catch (error) {
    stopwatch.stop();
    record.failure = error.toString();
    record.requests = observationsToJson(server.snapshotRequests());
    record.verdict = 'fail';
  } finally {
    adapter.destroy();
    await server.close();
  }
  return record;
}

/// WV-02: the frozen POST path performs a real HTTP POST and then loads the
/// returned body into the WebView with the response URL as base URL.
Future<EvidenceRecord> runWv02() => runFixture(
      'WV-02',
      body: (fixture, server, record) async {
        final target = server.url(fixture['path']! as String);
        final headers = fixtureHeaders(fixture, 'requestHeaders');
        final postBody = fixture['postBody']! as String;
        final http = LegadoHttpClient(userAgent: legadoUserAgent);
        final bootstrap = await http.postJson(
          url: target,
          body: postBody,
          headers: headers,
        );
        final adapter = FixtureWebView(
          url: bootstrap.url,
          html: bootstrap.body,
          headerMap: headers,
          javaScript: fixture['javaScript'] as String?,
          delayTime: (fixture['delayTime'] as num?)?.toInt() ?? 0,
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        try {
          final response = await adapter.getStrResponse();
          stopwatch.stop();
          final observations = server.snapshotRequests();
          final first = observations.isEmpty ? null : observations.first;
          record.operation = {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
            'durationMs': stopwatch.elapsedMilliseconds,
          };
          record.requests = observationsToJson(observations);
          record.checks['postObserved'] = first?.method == 'POST';
          record.checks['postBody'] = first?.body == postBody;
          record.checks['sourceHeader'] =
              first?.headers['x-wayfinder'] == 'wv02';
          record.checks['relativeResource'] =
              observations.any((r) => r.target == '/relative.js');
          record.checks['customJavaScript'] =
              response.body?.contains('ASSET=true') == true;
          record.checks['baseUrl'] =
              response.body?.contains('BASE=${server.url('/post')}') == true;
          record.checks['responseUrl'] = response.url == server.url('/post');
        } finally {
          adapter.destroy();
        }
      },
    );

/// WV-03: inline HTML with no base URL keeps the frozen placeholder URL.
Future<EvidenceRecord> runWv03() => runFixture(
      'WV-03',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          html: fixture['html']! as String,
          javaScript: fixture['javaScript'] as String?,
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        try {
          final response = await adapter.getStrResponse();
          stopwatch.stop();
          record.operation = {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
            'durationMs': stopwatch.elapsedMilliseconds,
          };
          record.requests = observationsToJson(server.snapshotRequests());
          record.checks['inlineMarker'] =
              response.body?.contains('inline-no-base') == true;
          record.checks['inlineJavaScript'] =
              response.body?.contains('INLINE=ok') == true;
          record.checks['legacyPlaceholderUrl'] =
              response.url == 'http://localhost/';
        } finally {
          adapter.destroy();
        }
      },
    );

/// WV-04: server redirect plus a scripted late navigation, wrapped as a
/// synthetic `302 -> 200` with the last page as final URL.
Future<EvidenceRecord> runWv04() => runFixture(
      'WV-04',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          url: server.url(fixture['path']! as String),
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        try {
          final response = await adapter.getStrResponse();
          stopwatch.stop();
          final observations = server.snapshotRequests();
          final paths = observations
              .map((r) => r.target)
              .where((target) => target != '/favicon.ico')
              .toList();
          record.operation = {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
            'durationMs': stopwatch.elapsedMilliseconds,
          };
          record.requests = observationsToJson(observations);
          record.checks['redirectChain'] = paths.length >= 3 &&
              paths[0] == '/redirect' &&
              paths[1] == '/final' &&
              paths[2] == '/late';
          record.checks['lateBody'] =
              response.body?.contains('redirect-late') == true;
          record.checks['synthetic302'] = response.priorCode == 302;
          record.checks['synthetic200'] = response.code == 200;
          record.checks['finalUrl'] = response.url == server.url('/late');
        } finally {
          adapter.destroy();
        }
      },
    );

/// WV-05: the resource sniffer returns the matched URL and destroys the WebView
/// immediately, so whether the matched subresource reaches the server is a race.
Future<EvidenceRecord> runWv05() => runFixture(
      'WV-05',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          url: server.url(fixture['path']! as String),
          sourceRegex: fixture['sourceRegex'] as String?,
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        try {
          final response = await adapter.getStrResponse();
          stopwatch.stop();
          final observations = server.snapshotRequests();
          final targetUrl = server.url('/asset/target?token=abc');
          record.operation = {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
            'durationMs': stopwatch.elapsedMilliseconds,
          };
          record.requests = observationsToJson(observations);
          record.checks['matchCallbackVisible'] = response.body == targetUrl;
          record.checks['subresourceRequestAtMostOnce'] = observations
                  .where((r) => r.target == '/asset/target?token=abc')
                  .length <=
              1;
          record.checks['firstMatchCleanup'] =
              adapter.isDisposed && !adapter.hasWebView;
          record.checks['sourceResponseOrigin'] =
              response.url == server.url('/sniff');
        } finally {
          adapter.destroy();
        }
      },
    );

/// WV-06: the override sniffer returns the matched navigation URL and blocks the
/// navigation, so the blocked path is never requested.
Future<EvidenceRecord> runWv06() => runFixture(
      'WV-06',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          url: server.url(fixture['path']! as String),
          overrideUrlRegex: fixture['overrideRegex'] as String?,
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        try {
          final response = await adapter.getStrResponse();
          stopwatch.stop();
          final observations = server.snapshotRequests();
          record.operation = {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
            'durationMs': stopwatch.elapsedMilliseconds,
          };
          record.requests = observationsToJson(observations);
          record.checks['matchedUrl'] = response.body == server.url('/blocked');
          record.checks['blockedRequestAbsent'] =
              observations.every((r) => r.target != '/blocked');
          record.checks['overrideCleanup'] =
              adapter.isDisposed && !adapter.hasWebView;
          record.checks['responseOrigin'] =
              response.url == server.url('/override');
        } finally {
          adapter.destroy();
        }
      },
    );

/// WV-07: cookies across one operation and the source-visible store. The frozen
/// baseline does not send an app-supplied `Cookie` header on the first WebView
/// request; only cookies the page sets appear on later requests and in the store.
Future<EvidenceRecord> runWv07() => runFixture(
      'WV-07',
      body: (fixture, server, record) async {
        final store = await CookieStore.open();
        await store.clear();
        final origin = server.url(fixture['path']! as String);
        final headers = fixtureHeaders(fixture, 'requestHeaders');
        final first = FixtureWebView(
          url: origin,
          tag: origin,
          headerMap: headers,
          userAgent: legadoUserAgent,
          onPageCookies: (pageUrl, cookies) async =>
              store.setCookie(origin, cookies),
        );
        final StrResponse firstResponse;
        try {
          firstResponse = await first.getStrResponse();
        } finally {
          first.destroy();
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        final stored = await store.getCookie(origin);
        final second = FixtureWebView(
          url: server.url('/echo'),
          tag: origin,
          userAgent: legadoUserAgent,
          onPageCookies: (pageUrl, cookies) async =>
              store.setCookie(origin, cookies),
        );
        final StrResponse secondResponse;
        try {
          secondResponse = await second.getStrResponse();
        } finally {
          second.destroy();
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final observations = server.snapshotRequests();
        final durableCookie = store.durableCookie(origin);
        final echoCookie = observations
                .firstWhere(
                  (r) => r.target == '/echo',
                  orElse: () => RequestObservation(
                    method: '',
                    target: '',
                    headers: const {},
                    body: '',
                    startedAtElapsedMs: 0,
                  ),
                )
                .headers['cookie'] ??
            '';
        final initialCookie = observations
            .where((r) => r.target == '/cookie')
            .map((r) => r.headers['cookie'] ?? '')
            .firstOrNull;
        record.operation = [
          {
            'responseUrl': firstResponse.url,
            'responseCode': firstResponse.code,
            'responseBody': firstResponse.body,
            'priorResponseCode': firstResponse.priorCode,
          },
          {
            'responseUrl': secondResponse.url,
            'responseCode': secondResponse.code,
            'responseBody': secondResponse.body,
            'priorResponseCode': secondResponse.priorCode,
          },
        ];
        record.extra['cookieStore'] = stored;
        record.extra['durableCookieStore'] = durableCookie;
        record.extra['echoCookie'] = echoCookie;
        record.requests = observationsToJson(observations);
        record.checks['initialAppCookieAbsent'] =
            initialCookie == null || initialCookie.isEmpty;
        record.checks['firstResponse'] =
            firstResponse.body?.contains('cookie') == true;
        record.checks['storeHasPageCookie'] = stored.contains('sid=from-page');
        record.checks['storeHasJavaScriptCookie'] = stored.contains('js=from-js');
        record.checks['webViewOutboundPageCookie'] =
            echoCookie.contains('sid=from-page');
        record.checks['webViewOutboundJavaScriptCookie'] =
            echoCookie.contains('js=from-js');
        record.checks['durableStoreHasPageCookie'] =
            durableCookie.contains('sid=from-page');
        record.checks['durableStoreHasJavaScriptCookie'] =
            durableCookie.contains('js=from-js');
        record.checks['secondResponse'] =
            secondResponse.body?.contains('echo') == true;
      },
    );

/// WV-08: `localStorage` persists across WebView instances for the same origin
/// while `sessionStorage` does not.
Future<EvidenceRecord> runWv08() => runFixture(
      'WV-08',
      body: (fixture, server, record) async {
        final base = server.url(fixture['path']! as String);
        final html = fixture['html']! as String;
        Future<StrResponse> load(String javaScript) async {
          final adapter = FixtureWebView(
            url: base,
            html: html,
            javaScript: javaScript,
            userAgent: legadoUserAgent,
          );
          try {
            return await adapter.getStrResponse();
          } finally {
            adapter.destroy();
          }
        }

        final firstResponse =
            await load(fixture['firstJavaScript']! as String);
        final secondResponse =
            await load(fixture['secondJavaScript']! as String);
        record.operation = [
          {
            'responseUrl': firstResponse.url,
            'responseCode': firstResponse.code,
            'responseBody': firstResponse.body,
            'priorResponseCode': firstResponse.priorCode,
          },
          {
            'responseUrl': secondResponse.url,
            'responseCode': secondResponse.code,
            'responseBody': secondResponse.body,
            'priorResponseCode': secondResponse.priorCode,
          },
        ];
        record.requests = observationsToJson(server.snapshotRequests());
        record.checks['firstLocalStorage'] =
            firstResponse.body?.contains('persisted') == true;
        record.checks['firstSessionStorage'] =
            firstResponse.body?.contains('instance') == true;
        record.checks['sameOrigin'] =
            secondResponse.body?.contains('persisted') == true;
        record.checks['newInstanceSessionStorageAbsent'] =
            secondResponse.body?.contains('"session":null') == true;
      },
    );

/// WV-07 restart phase. The frozen baseline's durable store keeps the page
/// cookies across a process restart, the first WebView after the restart does not
/// inject them, and page completion then overwrites the durable value with the
/// empty native cookie.
Future<EvidenceRecord> runWv07Restart(int port) => runFixture(
      'WV-07',
      port: port,
      phase: 'restart',
      body: (fixture, server, record) async {
        final store = await CookieStore.open();
        final origin = server.url(fixture['path']! as String);
        // Read before any WebView exists, so the value is the restarted
        // process's own durable state.
        final storeBeforeWebView = await store.getCookie(origin);
        final adapter = FixtureWebView(
          url: server.url('/echo'),
          tag: origin,
          userAgent: legadoUserAgent,
          onPageCookies: (pageUrl, cookies) async =>
              store.setCookie(origin, cookies),
        );
        final StrResponse response;
        try {
          response = await adapter.getStrResponse();
        } finally {
          adapter.destroy();
        }
        await Future<void>.delayed(const Duration(seconds: 1));
        final observations = server.snapshotRequests();
        final storeAfterWebView = await store.getCookie(origin);
        final echoCookie = observations
            .where((r) => r.target == '/echo')
            .map((r) => r.headers['cookie'] ?? '')
            .firstOrNull ??
            '';
        final checks = <String, bool>{
          'response': response.body?.contains('echo') == true,
          'durableStorePresentBeforeWebView':
              storeBeforeWebView.contains('sid=from-page') &&
                  storeBeforeWebView.contains('js=from-js'),
          'nativeSessionCookiesAbsentAfterRestart': echoCookie.isEmpty,
          'webViewCompletionOverwritesStoreWithEmptyNativeCookie':
              storeAfterWebView.isEmpty,
        };
        record.requests = observationsToJson(observations);
        record.extra['restart'] = {
          'response': {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
          },
          'storeBeforeWebView': storeBeforeWebView,
          'storeAfterWebView': storeAfterWebView,
          'echoCookie': echoCookie,
          'requests': record.requests,
          'checks': checks,
        };
        record.checks.addAll(checks);
      },
    );

/// WV-08 restart phase. `localStorage` survives the process restart for the same
/// origin; `sessionStorage` does not.
Future<EvidenceRecord> runWv08Restart(int port) => runFixture(
      'WV-08',
      port: port,
      phase: 'restart',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          url: server.url(fixture['path']! as String),
          html: fixture['html']! as String,
          javaScript: fixture['secondJavaScript']! as String,
          userAgent: legadoUserAgent,
        );
        final StrResponse response;
        try {
          response = await adapter.getStrResponse();
        } finally {
          adapter.destroy();
        }
        final checks = <String, bool>{
          'localStorageAfterRestart':
              response.body?.contains('persisted') == true,
          'sessionStorageAfterRestartAbsent':
              response.body?.contains('"session":null') == true,
        };
        record.requests = observationsToJson(server.snapshotRequests());
        record.extra['restart'] = {
          'response': {
            'responseUrl': response.url,
            'responseCode': response.code,
            'responseBody': response.body,
            'priorResponseCode': response.priorCode,
          },
          'checks': checks,
          'requests': record.requests,
        };
        record.checks.addAll(checks);
      },
    );

/// The stable error category a fixture compares, in place of a platform
/// exception class name.
Map<String, Object?> errorJson(Object error) => {
      'type': error.runtimeType.toString(),
      'message': error.toString(),
    };

/// WV-09: a script that yields `undefined` retries until the frozen retry
/// budget is spent, then fails with the baseline's own message.
Future<EvidenceRecord> runWv09() => runFixture(
      'WV-09',
      body: (fixture, server, record) async {
        final adapter = FixtureWebView(
          html: fixture['html']! as String,
          javaScript: fixture['javaScript'] as String?,
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        Object? error;
        try {
          await adapter.getStrResponse();
        } catch (thrown) {
          error = thrown;
        } finally {
          stopwatch.stop();
        }
        record.operation = {
          'durationMs': stopwatch.elapsedMilliseconds,
          'error': error == null ? null : errorJson(error),
        };
        record.checks['expectedErrorType'] = error is JsTimeoutException;
        record.checks['expectedErrorMessage'] =
            error?.toString() == fixture['expectedError'];
        record.checks['retriedForAtLeast30Seconds'] =
            stopwatch.elapsedMilliseconds >= 30000;
        record.checks['completedBeforeOuterTimeout'] =
            stopwatch.elapsedMilliseconds < 60000;
        record.checks['errorCleanup'] =
            adapter.isDisposed && !adapter.hasWebView;
      },
    );

/// WV-10: the outer timeout fires at 60 seconds, destroys the WebView, and the
/// server stays open past the delayed response so a post-terminal request would
/// be visible if one happened.
Future<EvidenceRecord> runWv10() => runFixture(
      'WV-10',
      body: (fixture, server, record) async {
        final path = fixture['path']! as String;
        final adapter = FixtureWebView(
          url: server.url(path),
          userAgent: legadoUserAgent,
        );
        final stopwatch = Stopwatch()..start();
        Object? error;
        try {
          await adapter.getStrResponse();
        } catch (thrown) {
          error = thrown;
        } finally {
          stopwatch.stop();
        }
        final cleaned = adapter.isDisposed && !adapter.hasWebView;
        await Future<void>.delayed(Duration(
          milliseconds: (fixture['postTerminalObservationMs']! as num).toInt(),
        ));
        final observations = server.snapshotRequests();
        record.operation = {
          'durationMs': stopwatch.elapsedMilliseconds,
          'error': error == null ? null : errorJson(error),
        };
        record.requests = observationsToJson(observations);
        record.checks['requestObserved'] =
            observations.any((r) => r.target == path);
        record.checks['outerTimeoutError'] = error is OuterTimeoutException;
        record.checks['timeoutAtSixtySeconds'] =
            stopwatch.elapsedMilliseconds >= 59000 &&
                stopwatch.elapsedMilliseconds <= 65000;
        record.checks['postTerminalRequestAbsent'] = observations
            .every((r) => r.target != fixture['postTerminalPath']);
        record.checks['timeoutCleanup'] = cleaned;
      },
    );

/// WV-11: cancellation before the load is dispatched and while a request is in
/// flight. Whether the queued load still reaches the server is a race, so it is
/// recorded rather than asserted; what must hold is that cancellation completes,
/// cleans up, and produces no post-terminal request.
Future<EvidenceRecord> runWv11() => runFixture(
      'WV-11',
      body: (fixture, server, record) async {
        final queuedPath = fixture['queuedPath']! as String;
        final flightPath = fixture['flightPath']! as String;
        final queued = FixtureWebView(
          url: server.url(queuedPath),
          userAgent: legadoUserAgent,
        );
        Object? queuedError;
        final queuedOperation = queued.getStrResponse().catchError((Object e) {
          queuedError = e;
          throw e;
        });
        queued.cancel();
        try {
          await queuedOperation;
        } catch (_) {
          // Cancellation is the expected outcome.
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
        final queuedLoadAfterCancellation =
            server.snapshotRequests().any((r) => r.target == queuedPath);

        final flight = FixtureWebView(
          url: server.url(flightPath),
          userAgent: legadoUserAgent,
        );
        Object? flightError;
        final flightOperation = flight.getStrResponse().catchError((Object e) {
          flightError = e;
          throw e;
        });
        var flightRequestObserved = false;
        for (var waited = 0; waited < 5000; waited += 100) {
          if (server.snapshotRequests().any((r) => r.target == flightPath)) {
            flightRequestObserved = true;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        flight.cancel();
        try {
          await flightOperation;
        } catch (_) {
          // Cancellation is the expected outcome.
        }
        await Future<void>.delayed(Duration(
          milliseconds: (fixture['postTerminalObservationMs']! as num).toInt(),
        ));
        final observations = server.snapshotRequests();
        record.operation = {
          'queuedLoadAfterCancellation': queuedLoadAfterCancellation,
          'queuedCancelled': queuedError is CancelledException,
          'flightCancelled': flightError is CancelledException,
        };
        record.requests = observationsToJson(observations);
        record.checks['queuedCancellationCompleted'] =
            queuedError is CancelledException;
        record.checks['queuedCancellationCleanup'] =
            queued.isDisposed && !queued.hasWebView;
        record.checks['flightRequestObserved'] = flightRequestObserved;
        record.checks['flightCancellationCompleted'] =
            flightError is CancelledException;
        record.checks['flightCancellationCleanup'] =
            flight.isDisposed && !flight.hasWebView;
        record.checks['postCancellationRequestAbsent'] = observations
            .every((r) => r.target != fixture['postTerminalPath']);
      },
    );
