import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_url_rules.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Compares a frozen-oracle golden against the same run on this platform.
///
/// Modes:
///
/// - the JS oracle (default): `<fjs.dll> <golden.json> <new-result.json>`
/// - the request-semantics oracle:
///   `--requests <fjs.dll> <golden.json> <new-report.json>`
/// - the local jsLib shared-scope product capture (no golden; comparison is
///   explicitly `not-run`): `--jslib-record <fjs.dll> <new-capture.json>`
/// - the local jsLib shared-scope comparison against a frozen device golden:
///   `--jslib <fjs.dll> <golden.json> <new-report.json>`
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--requests-compare') {
    await _runRequestCompareOnly(args.sublist(1));
    return;
  }
  if (args.isNotEmpty && args.first == '--requests') {
    await _runRequestOracle(args.sublist(1));
    return;
  }
  if (args.isNotEmpty && args.first == '--jslib-record') {
    await _runJsLibRecord(args.sublist(1));
    return;
  }
  if (args.isNotEmpty && args.first == '--jslib') {
    await _runJsLib(args.sublist(1));
    return;
  }
  await _runScriptOracle(args);
}

/// Runs the exact Android oracle corpus against the desktop destination.
Future<void> _runScriptOracle(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('Usage: <fjs.dll> <golden.json> <new-result.json>');
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus =
      jsonDecode(File('tool/nested_oracle/fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final golden =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  if (golden['baselineCommit'] != corpus['baselineCommit'] ||
      golden['entryPoint'] != corpus['entryPoint']) {
    throw StateError('Oracle identity mismatch');
  }
  final observed = await _observeSteps(args[0], corpus);
  final observations = observed.observations;
  final requests = observed.requests;
  final expected = golden['observations'] as List;
  final mismatches = <Map<String, Object?>>[];
  for (var i = 0; i < observations.length; i++) {
    if (i >= expected.length ||
        jsonEncode(observations[i]) != jsonEncode(expected[i])) {
      mismatches.add({
        'index': i,
        'expected': i < expected.length ? expected[i] : null,
        'actual': observations[i],
      });
    }
  }
  final countMatches = observations.length == expected.length;
  final requestsMatch = jsonEncode(requests) == jsonEncode(golden['requests']);
  final pass = countMatches && requestsMatch && mismatches.isEmpty;
  final report = {
    'platform': Platform.operatingSystem,
    'baselineCommit': corpus['baselineCommit'],
    'golden': args[1],
    'status': pass ? 'pass' : 'fail',
    'observations': observations,
    'requests': requests,
    'countMatches': countMatches,
    'requestsMatch': requestsMatch,
    'mismatches': mismatches,
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
  if (!pass) exitCode = 1;
}

/// Runs one corpus' steps against the product and returns the observations and
/// the replay server's request trace. Shared by the default JS oracle and the
/// jsLib shared-scope modes so all three observe the same way.
Future<({List<Map<String, Object?>> observations, List<String> requests})>
_observeSteps(String dll, Map<String, dynamic> corpus) async {
  final requests = <String>[];
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 18763);
  const origin = 'http://127.0.0.1:18763';
  final clients = <Socket>{};
  server.listen((socket) {
    clients.add(socket);
    var header = '';
    var sent = false;
    socket.listen(
      (bytes) {
        if (sent) return;
        header += ascii.decode(bytes);
        if (!header.contains('\r\n\r\n')) return;
        sent = true;
        final first = header.split('\r\n').first.split(' ');
        final rawPath = first[1];
        requests.add('${first[0]} $rawPath');
        final path = Uri.decodeComponent(rawPath);
        final body = utf8.encode(
          path.startsWith('/value/') ? path.substring(7) : '',
        );
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
          ),
        );
        socket.add(body);
        unawaited(socket.close());
      },
      onDone: () {
        clients.remove(socket);
      },
    );
  });
  await InProcessSourceScriptRuntime.initialize(libraryPath: dll);
  final observations = <Map<String, Object?>>[];
  final host = SourceHostDispatcher(transport: HttpSourceTransport());
  try {
    for (final step in corpus['steps'] as List) {
      final runtime = InProcessSourceScriptRuntime(
        dispatcher: host,
        jsLib: corpus['jsLib'] as String,
      );
      final result = <String, Object?>{'id': step['id']};
      try {
        result['value'] = await runtime.evaluate(
          source: (step['script'] as String).replaceAll(r'$ORIGIN', origin),
          input: {
            'sourceKey': '$origin/source/${step['sourceKey'] ?? 'first'}',
            'key': 'outer-key',
            'page': 7,
          },
          timeout: const Duration(seconds: 5),
        );
      } on SourceScriptError catch (error) {
        result['error'] = error.category;
      }
      observations.add(result);
    }
  } finally {
    await InProcessSourceScriptRuntime.dispose();
    await server.close();
    for (final socket in clients.toList()) {
      socket.destroy();
    }
  }
  return (observations: observations, requests: requests);
}

// --------------------------------------------------------------------------
// Local jsLib shared-scope corpus (#74)
// --------------------------------------------------------------------------

/// The dedicated corpus for the local `jsLib` shared-scope family. It is
/// selected explicitly by `--jslib-record`/`--jslib`; the default JS oracle
/// keeps reading `tool/nested_oracle/fixtures.json`.
const jsLibCorpusPath = 'tool/nested_oracle/jslib-fixtures.json';

String _sha256Bytes(Uint8List bytes) => SHA256Digest()
    .process(bytes)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// SHA-256 of a file's raw bytes. The request corpus' manifest pin is the raw
/// identity, so it is read in binary and never through a text decoder.
String sha256File(File file) => _sha256Bytes(file.readAsBytesSync());

/// SHA-256 of a file after CRLF is normalized to LF. It is reported beside the
/// raw identity as evidence, never substituted for a recorded raw pin.
String sha256FileLf(File file) {
  final bytes = file.readAsBytesSync();
  final normalized = Uint8List(bytes.length);
  var length = 0;
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] == 0x0d &&
        index + 1 < bytes.length &&
        bytes[index + 1] == 0x0a) {
      continue;
    }
    normalized[length++] = bytes[index];
  }
  return _sha256Bytes(Uint8List.sublistView(normalized, 0, length));
}

/// SHA-256 of the corpus with CRLF normalized to LF. The device harness pins
/// the same value, so one pin means the same corpus on a Windows checkout and
/// on an LF checkout.
String jsLibCorpusSha256(File file) => _sha256Bytes(
  Uint8List.fromList(
    utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n')),
  ),
);

/// Structural JSON equality for the jsLib comparison: object member order is
/// ignored (`book-source-differential-contract.md` -> Matching Rules ->
/// Outputs), while array order and every primitive/string value are compared
/// exactly.
bool jsonSemanticEquals(Object? a, Object? b) {
  if (identical(a, b)) return true;
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !jsonSemanticEquals(a[key], b[key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonSemanticEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// The frozen target application pin a jsLib golden must match, or a refusal.
/// The pin comes from the existing device manifest pattern
/// (`evidence/android-17-os4.0.0.31/request-manifest.json`): the baseline
/// commit, the target package and the installed target APK SHA-256.
Map<String, dynamic> jsLibTargetOf(Map<String, dynamic> corpus) {
  final target = corpus['target'];
  if (target is! Map) {
    throw const FormatException('jsLib corpus has no frozen target pin');
  }
  final package = '${target['package'] ?? ''}'.trim();
  final apkSha256 = '${target['apkSha256'] ?? ''}'.trim();
  if (package.isEmpty || !RegExp(r'^[0-9a-f]{64}$').hasMatch(apkSha256)) {
    throw const FormatException('jsLib corpus target pin is incomplete');
  }
  if ('${target['baselineCommit'] ?? ''}'.trim() !=
      '${corpus['baselineCommit'] ?? ''}'.trim()) {
    throw const FormatException(
      'jsLib corpus target pin names another baseline',
    );
  }
  return target.cast<String, dynamic>();
}

/// Decodes and validates the dedicated jsLib corpus, failing closed on a
/// missing, malformed or empty corpus before anything runs.
Map<String, dynamic> loadJsLibCorpus() {
  final file = File(jsLibCorpusPath);
  if (!file.existsSync()) {
    throw StateError('jsLib corpus missing: $jsLibCorpusPath');
  }
  final corpus = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (corpus['schemaVersion'] != 1) {
    throw const FormatException('jsLib corpus schemaVersion is not 1');
  }
  if ('${corpus['fixtureId'] ?? ''}'.trim().isEmpty) {
    throw const FormatException('jsLib corpus has no fixtureId');
  }
  if (corpus['corpusVersion'] is! int) {
    throw const FormatException('jsLib corpus has no corpusVersion');
  }
  if ('${corpus['baselineCommit'] ?? ''}'.trim().isEmpty) {
    throw const FormatException('jsLib corpus has no baselineCommit');
  }
  if ('${corpus['entryPoint'] ?? ''}'.trim().isEmpty) {
    throw const FormatException('jsLib corpus has no entryPoint');
  }
  if (corpus['jsLib'] is! String) {
    throw const FormatException('jsLib corpus has no jsLib');
  }
  jsLibTargetOf(corpus);
  final steps = corpus['steps'];
  if (steps is! List || steps.isEmpty) {
    throw const FormatException('jsLib corpus has no rows');
  }
  final ids = <String>{};
  for (final step in steps) {
    if (step is! Map || '${step['id'] ?? ''}'.trim().isEmpty) {
      throw const FormatException('jsLib corpus row has no id');
    }
    if (step['script'] is! String) {
      throw const FormatException('jsLib corpus row has no script');
    }
    if (!ids.add('${step['id']}')) {
      throw FormatException('jsLib corpus row id is duplicated: ${step['id']}');
    }
  }
  return corpus;
}

/// Refuses a golden that is not a real frozen-device capture of exactly this
/// corpus. Every identity, hash, row and provenance problem is a hard refusal
/// (a `FormatException`), so no comparison can pass vacuously.
void checkJsLibGolden({
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required Map<String, dynamic> golden,
}) {
  if (golden['mode'] != null || golden['comparison'] != null) {
    throw const FormatException(
      'Not a frozen golden: the input carries a record-mode marker',
    );
  }
  for (final key in [
    'fixtureId',
    'corpusVersion',
    'baselineCommit',
    'entryPoint',
  ]) {
    if (golden[key] != corpus[key]) {
      throw FormatException('the golden does not describe this corpus ($key)');
    }
  }
  if (golden['corpusSha256'] != corpusSha256) {
    throw const FormatException(
      'the golden was captured against different corpus bytes',
    );
  }
  final target = jsLibTargetOf(corpus);
  final provenance = golden['provenance'];
  if (provenance is! Map || provenance['kind'] != 'frozen-device-capture') {
    throw const FormatException(
      'the golden carries no frozen-device capture provenance',
    );
  }
  // Every duplicated identity field is compared with the corpus, including the
  // frozen target package and APK bytes: a capture of another build, package or
  // entry point is refused rather than accepted under the corpus' label.
  for (final entry in <String, Object?>{
    'entryPoint': corpus['entryPoint'],
    'baselineCommit': corpus['baselineCommit'],
    'targetPackage': target['package'],
    'targetApkSha256': target['apkSha256'],
  }.entries) {
    if (provenance[entry.key] != entry.value) {
      throw FormatException(
        'the golden provenance does not match the corpus (${entry.key})',
      );
    }
  }
  if ('${provenance['targetApkPath'] ?? ''}'.trim().isEmpty ||
      '${provenance['deviceFingerprint'] ?? ''}'.trim().isEmpty ||
      '${provenance['capturedAt'] ?? ''}'.trim().isEmpty) {
    throw const FormatException(
      'the golden carries no frozen-device capture provenance',
    );
  }
  final expected = golden['observations'];
  if (expected is! List || expected.isEmpty) {
    throw const FormatException('the golden holds no observations');
  }
  final goldenRequests = golden['requests'];
  if (goldenRequests is! List || goldenRequests.isEmpty) {
    throw const FormatException('the golden holds no request trace');
  }
  final steps = corpus['steps'] as List;
  if (expected.length != steps.length) {
    throw FormatException(
      'row count mismatch: golden ${expected.length} vs corpus ${steps.length}',
    );
  }
  for (var i = 0; i < steps.length; i++) {
    final row = expected[i];
    if (row is! Map || row['id'] != (steps[i] as Map)['id']) {
      throw FormatException('row identity mismatch at index $i');
    }
  }
}

/// Compares the product's jsLib observations with a validated frozen golden.
/// The caller has already refused a bad golden with [checkJsLibGolden].
Map<String, Object?> compareJsLib({
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required Map<String, dynamic> golden,
  required List<Map<String, Object?>> observations,
  required List<String> requests,
  required String goldenPath,
  required String library,
}) {
  checkJsLibGolden(corpus: corpus, corpusSha256: corpusSha256, golden: golden);
  final steps = corpus['steps'] as List;
  if (observations.length != steps.length) {
    throw FormatException(
      'the product recorded ${observations.length} rows for '
      '${steps.length} corpus rows',
    );
  }
  final expected = golden['observations'] as List;
  final mismatches = <Map<String, Object?>>[];
  for (var i = 0; i < steps.length; i++) {
    if (!jsonSemanticEquals(observations[i], expected[i])) {
      mismatches.add({
        'index': i,
        'expected': expected[i],
        'actual': observations[i],
      });
    }
  }
  final requestsMatch = jsonSemanticEquals(requests, golden['requests']);
  final pass = requestsMatch && mismatches.isEmpty;
  return <String, Object?>{
    'platform': Platform.operatingSystem,
    'mode': 'jslib',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'corpusSha256': corpusSha256,
    'target': jsLibTargetOf(corpus),
    'golden': goldenPath,
    'library': library,
    'status': pass ? 'pass' : 'fail',
    'provenance': golden['provenance'],
    'observations': observations,
    'requests': requests,
    'countMatches': true,
    'requestsMatch': requestsMatch,
    'mismatches': mismatches,
  };
}

/// Prepares the product-only capture the later device comparison will need. It
/// runs the same corpus the frozen harness will serve and labels the result
/// `comparison: not-run`: no golden exists on this machine, so none is claimed.
Future<void> _runJsLibRecord(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Usage: --jslib-record <fjs.dll> <new-capture.json>');
  }
  final output = File(args[1]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus = loadJsLibCorpus();
  final corpusSha256 = jsLibCorpusSha256(File(jsLibCorpusPath));
  final target = jsLibTargetOf(corpus);
  final observed = await _observeSteps(args[0], corpus);
  final report = <String, Object?>{
    'mode': 'jslib-record',
    'comparison': 'not-run',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'corpusPath': jsLibCorpusPath,
    'corpusSha256': corpusSha256,
    'expectedTarget': {
      'package': target['package'],
      'apkSha256': target['apkSha256'],
      'baselineCommit': target['baselineCommit'],
      'manifest': target['manifest'],
    },
    'library': args[0],
    'platform': Platform.operatingSystem,
    'observations': observed.observations,
    'requests': observed.requests,
    'note':
        'Product-only prepared capture: no frozen golden was compared, so the '
        'comparison is explicitly not-run. A device golden is produced by '
        '`am instrument -e corpus jslib`, which measures and verifies the '
        'expected target package and APK before labelling the capture frozen, '
        'and is compared with --jslib.',
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
}

/// Runs the product against the dedicated corpus and compares it with a frozen
/// device golden, refusing to run the comparison at all without a genuine one.
Future<void> _runJsLib(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Usage: --jslib <fjs.dll> <golden.json> <new-report.json>',
    );
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus = loadJsLibCorpus();
  final corpusSha256 = jsLibCorpusSha256(File(jsLibCorpusPath));
  final golden =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  // Refuse a bad golden before running anything, so a stale or forged input
  // cannot leave a half-written report behind.
  checkJsLibGolden(corpus: corpus, corpusSha256: corpusSha256, golden: golden);
  final observed = await _observeSteps(args[0], corpus);
  final report = compareJsLib(
    corpus: corpus,
    corpusSha256: corpusSha256,
    golden: golden,
    observations: observed.observations,
    requests: observed.requests,
    goldenPath: args[1],
    library: args[0],
  );
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
  if (report['status'] != 'pass') exitCode = 1;
}

// --------------------------------------------------------------------------
// Request-semantics oracle
// --------------------------------------------------------------------------

/// The corpus' port on this side. The device run serves the same corpus on
/// 18731; the host keeps the port the JS oracle already uses, so a replay
/// server of another lane cannot collide with either side.
const _requestPort = 18763;

/// Headers the differential contract calls platform-generated: they are
/// ignored unless the row's own declared header map sets the name
/// (`book-source-differential-contract.md` -> Matching Rules -> Requests).
const _ignoredHeaders = {'host', 'content-length', 'accept-encoding'};

/// Observations that a recorded divergence covers: an approved product
/// decision makes the frozen bytes unreproducible, so the row is reported as
/// `notCompared` (never as a pass) and the disagreement is quoted in full.
///
/// Both entries mirror rows in the differential contract's known-divergence
/// table.
const _declaredDivergences = <String, Map<String, String>>{
  'defaults-user-agent-null': {
    'observation': 'requests[0].headers.user-agent',
    'reason':
        'The frozen client removes the declared `null` header and then sends '
        'OkHttp BridgeInterceptor\'s own default (`okhttp/4.12.0`). The '
        'product\'s transport is Dart\'s HttpClient, whose own default stands '
        'when the source declares `User-Agent: null` '
        '(lib/source/http_source_transport.dart, `withSourceRequestDefaults`).',
  },
  'redirect-cross-origin': {
    'observation': 'requests[1].headers.cookie',
    'reason':
        'The frozen client drops `Authorization` on a hop to another origin '
        'and forwards a declared `Cookie`; the product\'s transport drops both, '
        'the recorded credentials-policy divergence '
        '(lib/source/http_source_transport.dart, `_readOnce`).',
  },
  'query-exact-bytes': {
    'observation': 'requests[0].rawQuery',
    'reason':
        'The frozen client keeps the URL as text and hands its query to '
        '`HttpUrl.encodedQuery` (AnalyzeUrl.kt:265-278, OkHttpUtils.kt:105-109), '
        'which writes `{`, `}`, `|`, `^`, the backtick and the backslash as '
        'they are. The product\'s request URL is a Dart `Uri`, which '
        'percent-encodes those six characters while it resolves '
        '(lib/source/source_http_uri.dart), the platform seam the capability '
        'matrix already records for the query re-encoding row.',
  },
};

/// The committed request corpus and the retained record that pins the frozen
/// capture. Both paths are fixed inputs: the old CLI carries no file arguments
/// for them and a copied golden still has to match the pins below.
const requestCorpusPath = 'tool/nested_oracle/request-fixtures.json';
const requestManifestPath =
    'tool/nested_oracle/evidence/android-17-os4.0.0.31/request-manifest.json';
const requestComparerPath = 'tool/nested_oracle_compare.dart';

/// Reads one JSON object and fails closed on every other JSON shape.
Map<String, dynamic> _requestObject(Object? value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('$what is not a JSON object');
}

List<dynamic> _requestList(Object? value, String what) {
  if (value is List) return value;
  throw FormatException('$what is not a JSON array');
}

List<Map<String, Object?>> _requestObjectList(Object? value, String what) => [
  for (final raw in _requestList(value, what))
    _requestObject(raw, what).cast<String, Object?>(),
];

String _requestString(Object? value, String what) {
  if (value is String) return value;
  throw FormatException('$what is not a string');
}

String _requestText(Object? value, String what) {
  final text = _requestString(value, what);
  if (text.trim().isEmpty) throw FormatException('$what is empty');
  return text;
}

bool _isSha256Text(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// A request carrier is the exact observable shape the golden and the replay
/// server record: method, path, raw query bytes, source-controlled headers and
/// raw body bytes. Missing, malformed or untyped carriers are refused instead
/// of being compared as empty values.
void _checkRequestCarrier(Map<String, dynamic> request, String what) {
  final method = _requestText(request['method'], '$what method');
  if (!RegExp(r'^[A-Z]+$').hasMatch(method)) {
    throw FormatException('$what method is not an HTTP token');
  }
  final path = _requestText(request['path'], '$what path');
  if (!path.startsWith('/')) {
    throw FormatException('$what path is not an origin-form path');
  }
  _requestString(request['rawQuery'], '$what rawQuery');
  _requestString(request['body'], '$what body');
  final headers = _requestObject(request['headers'], '$what headers');
  for (final entry in headers.entries) {
    if (entry.key != entry.key.toLowerCase() || entry.key.isEmpty) {
      throw FormatException('$what header name is not a lowercase token');
    }
    if (entry.value is! String) {
      throw FormatException('$what header ${entry.key} is not a string');
    }
  }
  final query = request['query'];
  if (query != null) {
    final decoded = _requestObject(query, '$what query');
    for (final entry in decoded.entries) {
      if (entry.value is! String) {
        throw FormatException('$what query value is not a string');
      }
    }
  }
}

/// Decodes and validates the committed request corpus before anything runs.
Map<String, dynamic> loadRequestCorpus() {
  final file = File(requestCorpusPath);
  if (!file.existsSync()) {
    throw StateError('request corpus missing: $requestCorpusPath');
  }
  final corpus = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (corpus['schemaVersion'] != 1) {
    throw const FormatException('request corpus schemaVersion is not 1');
  }
  _requestText(corpus['fixtureId'], 'request corpus fixtureId');
  if (corpus['corpusVersion'] is! int) {
    throw const FormatException('request corpus has no corpusVersion');
  }
  final baseline = _requestText(
    corpus['baselineCommit'],
    'request corpus baselineCommit',
  );
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(baseline)) {
    throw const FormatException('request corpus baselineCommit is not a SHA-1');
  }
  _requestText(corpus['entryPoint'], 'request corpus entryPoint');
  final port = corpus['port'];
  if (port is! int || port < 1 || port > 65535) {
    throw const FormatException('request corpus has no valid port');
  }
  final origin = Uri.tryParse(
    _requestText(corpus['origin'], 'request corpus origin'),
  );
  final otherOrigin = Uri.tryParse(
    _requestText(corpus['otherOrigin'], 'request corpus otherOrigin'),
  );
  if (origin == null ||
      otherOrigin == null ||
      !origin.hasAuthority ||
      !otherOrigin.hasAuthority ||
      origin == otherOrigin) {
    throw const FormatException('request corpus origins are not distinct');
  }

  final rows = _requestList(corpus['rows'], 'request corpus rows');
  if (rows.isEmpty) throw const FormatException('request corpus has no rows');
  final ids = <String>{};
  for (final raw in rows) {
    final row = _requestObject(raw, 'request corpus row');
    final id = _requestText(row['id'], 'request corpus row id');
    if (!ids.add(id)) {
      throw FormatException('request corpus row id is duplicated: $id');
    }
    final request = _requestObject(row['request'], 'request corpus row $id');
    _requestText(request['rule'], 'request corpus row $id rule');
    if (request['key'] != null && request['key'] is! String) {
      throw FormatException('request corpus row $id key is not a string');
    }
    if (request['page'] != null && request['page'] is! int) {
      throw FormatException('request corpus row $id page is not an integer');
    }
    final headers = request['headers'];
    if (headers != null) {
      final declared = _requestObject(
        headers,
        'request corpus row $id headers',
      );
      for (final entry in declared.entries) {
        if (entry.key.trim().isEmpty || entry.value is! String) {
          throw FormatException(
            'request corpus row $id header ${entry.key} is not typed',
          );
        }
      }
    }
  }

  final responses = _requestList(
    corpus['responses'],
    'request corpus responses',
  );
  if (responses.isEmpty) {
    throw const FormatException('request corpus has no responses');
  }
  final responseKeys = <String>{};
  for (final raw in responses) {
    final response = _requestObject(raw, 'request corpus response');
    final method = _requestText(
      response['method'],
      'request corpus response method',
    );
    final path = _requestText(response['path'], 'request corpus response path');
    if (!path.startsWith('/')) {
      throw FormatException(
        'request corpus response path is not absolute: $path',
      );
    }
    if (!responseKeys.add('$method $path')) {
      throw FormatException(
        'request corpus response is duplicated: $method $path',
      );
    }
    final status = response['status'];
    if (status is! int || status < 100 || status > 599) {
      throw FormatException(
        'request corpus response $method $path has no status',
      );
    }
    final body = response['body'];
    if (body != null && body is! String) {
      throw FormatException(
        'request corpus response $method $path body is not a string',
      );
    }
    final headers = response['headers'];
    if (headers != null) {
      final declared = _requestObject(
        headers,
        'request corpus response $method $path headers',
      );
      for (final entry in declared.entries) {
        if (entry.key.trim().isEmpty || entry.value is! String) {
          throw FormatException(
            'request corpus response $method $path header ${entry.key} is not typed',
          );
        }
      }
    }
  }
  return corpus;
}

/// Decodes and validates the retained request manifest that pins the frozen
/// capture. The manifest is the root of trust on this side: it names the
/// corpus bytes, baseline, target/harness artifacts, golden bytes and both raw
/// captures. Today's edited producer source is deliberately not an identity.
Map<String, dynamic> loadRequestManifest() {
  final file = File(requestManifestPath);
  if (!file.existsSync()) {
    throw StateError('request manifest missing: $requestManifestPath');
  }
  final manifest = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (manifest['kind'] != 'frozen-request-semantics-corpus') {
    throw const FormatException('request manifest has the wrong kind');
  }
  _requestText(manifest['recordedAt'], 'request manifest recordedAt');
  final device = _requestObject(manifest['device'], 'request manifest device');
  _requestText(device['fingerprint'], 'request manifest device fingerprint');

  final baseline = _requestObject(
    manifest['baseline'],
    'request manifest baseline',
  );
  final commit = _requestText(
    baseline['commit'],
    'request manifest baseline commit',
  );
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(commit)) {
    throw const FormatException(
      'request manifest baseline commit is not SHA-1',
    );
  }
  final application = _requestObject(
    baseline['application'],
    'request manifest target application',
  );
  _requestText(application['package'], 'request manifest target package');
  if (!_isSha256Text(application['sha256'])) {
    throw const FormatException('request manifest target APK pin is missing');
  }
  if (application['installedBytesPulledAndVerified'] != true) {
    throw const FormatException(
      'request manifest target APK was not verified from installed bytes',
    );
  }
  _requestText(
    application['installedPath'],
    'request manifest target APK path',
  );

  final harness = _requestObject(
    manifest['harness'],
    'request manifest harness',
  );
  _requestText(harness['entryPoint'], 'request manifest harness entryPoint');
  if (!_isSha256Text(harness['apkSha256']) ||
      harness['installedApkSha256'] != harness['apkSha256']) {
    throw const FormatException(
      'request manifest harness APK pin is incomplete',
    );
  }
  final sources = _requestList(
    harness['sources'],
    'request manifest harness sources',
  );
  if (sources.isEmpty) {
    throw const FormatException('request manifest has no harness sources');
  }
  final sourcePaths = <String>{};
  for (final raw in sources) {
    final source = _requestObject(raw, 'request manifest harness source');
    final path = _requestText(source['path'], 'request manifest source path');
    sourcePaths.add(path);
    if (!_isSha256Text(source['sha256']) ||
        !_isSha256Text(source['gitBlobSha256AtStartingHead'])) {
      throw FormatException('request manifest source pin is incomplete: $path');
    }
  }
  if (!sourcePaths.contains('tool/nested_oracle/RequestOracle.java') ||
      !sourcePaths.contains(requestCorpusPath)) {
    throw const FormatException(
      'request manifest omits a required harness source',
    );
  }

  final corpus = _requestObject(manifest['corpus'], 'request manifest corpus');
  if (corpus['path'] != requestCorpusPath) {
    throw const FormatException('request manifest names another corpus path');
  }
  if (!_isSha256Text(corpus['sha256'])) {
    throw const FormatException('request manifest corpus pin is missing');
  }
  _requestText(corpus['fixtureId'], 'request manifest corpus fixtureId');
  if (corpus['corpusVersion'] is! int ||
      corpus['rows'] is! int ||
      corpus['rows'] < 1 ||
      corpus['responses'] is! int ||
      corpus['responses'] < 1) {
    throw const FormatException('request manifest corpus counts are missing');
  }
  final bundled = _requestObject(
    corpus['bundledAsset'],
    'request manifest bundled corpus',
  );
  _requestText(bundled['path'], 'request manifest bundled corpus path');
  if (!_isSha256Text(bundled['sha256'])) {
    throw const FormatException(
      'request manifest bundled corpus pin is missing',
    );
  }

  final run = _requestObject(manifest['run'], 'request manifest run');
  _requestText(run['result'], 'request manifest run result');
  if (run['rows'] is! int ||
      run['rows'] < 1 ||
      run['requests'] is! int ||
      run['requests'] < 1) {
    throw const FormatException('request manifest run counts are missing');
  }
  if (run['analysisFailure'] != null) {
    throw const FormatException('request manifest records an analysis failure');
  }
  final serverErrors = _requestList(
    run['serverErrors'],
    'request manifest server errors',
  );
  if (serverErrors.isNotEmpty) {
    throw const FormatException(
      'request manifest records replay-server errors',
    );
  }
  final cleanup = _requestObject(run['cleanup'], 'request manifest cleanup');
  if (cleanup['serverClosed'] != true) {
    throw const FormatException(
      'request manifest replay server was not closed',
    );
  }
  final golden = _requestObject(run['golden'], 'request manifest golden');
  _requestText(golden['path'], 'request manifest golden path');
  if (!_isSha256Text(golden['sha256'])) {
    throw const FormatException('request manifest golden pin is missing');
  }
  final captures = _requestList(run['captures'], 'request manifest captures');
  if (captures.isEmpty) {
    throw const FormatException('request manifest has no raw captures');
  }
  for (final raw in captures) {
    final capture = _requestObject(raw, 'request manifest capture');
    _requestText(capture['path'], 'request manifest capture path');
    if (!_isSha256Text(capture['sha256'])) {
      throw const FormatException('request manifest capture pin is missing');
    }
  }
  return manifest;
}

/// Refuses a golden that is not the retained frozen capture of exactly this
/// corpus, target and harness. Every identity, hash, target, row and request
/// problem is a hard refusal, so no comparison can pass vacuously.
void checkRequestGolden({
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required Map<String, dynamic> manifest,
  required Map<String, dynamic> golden,
  required String goldenSha256,
}) {
  if (golden['mode'] != null || golden['comparison'] != null) {
    throw const FormatException(
      'Not a frozen golden: the input carries a record-mode marker',
    );
  }
  if (golden['platform'] != 'android') {
    throw const FormatException('the golden is not a frozen Android capture');
  }
  for (final key in [
    'fixtureId',
    'corpusVersion',
    'baselineCommit',
    'entryPoint',
  ]) {
    if (golden[key] != corpus[key]) {
      throw FormatException('the golden does not describe this corpus ($key)');
    }
  }

  final device = _requestObject(manifest['device'], 'request manifest device');
  final fingerprint = _requestText(
    device['fingerprint'],
    'request manifest device fingerprint',
  );
  if (golden['fingerprint'] != fingerprint) {
    throw const FormatException('the golden names another target device');
  }
  if (golden['recordedAt'] != manifest['recordedAt']) {
    throw const FormatException('the golden names another capture time');
  }
  if (golden['analysisFailure'] != null) {
    throw const FormatException('the golden records an analysis failure');
  }
  final goldenServerErrors = _requestList(
    golden['serverErrors'],
    'the golden server errors',
  );
  if (goldenServerErrors.isNotEmpty) {
    throw const FormatException('the golden records replay-server errors');
  }
  final cleanup = _requestObject(golden['cleanup'], 'the golden cleanup');
  if (cleanup['serverClosed'] != true) {
    throw const FormatException('the golden replay server was not closed');
  }

  final manifestCorpus = _requestObject(
    manifest['corpus'],
    'request manifest corpus',
  );
  if (manifestCorpus['sha256'] != corpusSha256) {
    throw const FormatException(
      'the corpus bytes differ from the manifest pin',
    );
  }
  if (manifestCorpus['fixtureId'] != corpus['fixtureId'] ||
      manifestCorpus['corpusVersion'] != corpus['corpusVersion']) {
    throw const FormatException('the manifest names another corpus version');
  }
  final bundled = _requestObject(
    manifestCorpus['bundledAsset'],
    'request manifest bundled corpus',
  );
  if (bundled['sha256'] != corpusSha256) {
    throw const FormatException('the bundled corpus bytes differ from the pin');
  }
  final baseline = _requestObject(
    manifest['baseline'],
    'request manifest baseline',
  );
  if (baseline['commit'] != corpus['baselineCommit']) {
    throw const FormatException('the manifest names another baseline');
  }
  final application = _requestObject(
    baseline['application'],
    'request manifest target application',
  );
  _requestText(application['package'], 'request manifest target package');
  if (!_isSha256Text(application['sha256'])) {
    throw const FormatException('the manifest target APK pin is missing');
  }
  if (application['installedBytesPulledAndVerified'] != true) {
    throw const FormatException(
      'the manifest target APK was not verified from installed bytes',
    );
  }
  _requestText(
    application['installedPath'],
    'request manifest target APK path',
  );
  final harness = _requestObject(
    manifest['harness'],
    'request manifest harness',
  );
  if (!_isSha256Text(harness['apkSha256']) ||
      harness['installedApkSha256'] != harness['apkSha256']) {
    throw const FormatException('the manifest harness APK pin is incomplete');
  }
  if (harness['entryPoint'] != corpus['entryPoint']) {
    throw const FormatException(
      'the manifest names another harness entry point',
    );
  }

  final run = _requestObject(manifest['run'], 'request manifest run');
  final goldenPin = _requestObject(run['golden'], 'request manifest golden');
  if (goldenPin['sha256'] != goldenSha256) {
    throw const FormatException(
      'the golden bytes differ from the manifest pin',
    );
  }
  final captures = _requestList(run['captures'], 'request manifest captures');
  final captureMatched = captures.any(
    (raw) => (raw as Map)['sha256'] == goldenSha256,
  );
  if (!captureMatched) {
    throw const FormatException('the golden is not a retained raw capture');
  }
  if (run['analysisFailure'] != null ||
      _requestList(
        run['serverErrors'],
        'request manifest server errors',
      ).isNotEmpty) {
    throw const FormatException('the manifest records a failed capture run');
  }
  final runCleanup = _requestObject(run['cleanup'], 'request manifest cleanup');
  if (runCleanup['serverClosed'] != true) {
    throw const FormatException('the manifest replay server was not closed');
  }

  final goldenRows = _requestList(golden['rows'], 'the golden rows');
  final corpusRows = _requestList(corpus['rows'], 'request corpus rows');
  if (goldenRows.isEmpty || goldenRows.length != corpusRows.length) {
    throw FormatException(
      'row count mismatch: golden ${goldenRows.length} vs corpus '
      '${corpusRows.length}',
    );
  }
  if (run['rows'] != goldenRows.length ||
      manifestCorpus['rows'] != corpusRows.length) {
    throw const FormatException('the manifest row counts disagree');
  }
  if (manifestCorpus['responses'] !=
      _requestList(corpus['responses'], 'request corpus responses').length) {
    throw const FormatException('the manifest response count disagrees');
  }

  final flattened = <Map<String, dynamic>>[];
  final ids = <String>{};
  for (var index = 0; index < goldenRows.length; index++) {
    final row = _requestObject(goldenRows[index], 'the golden row $index');
    final corpusRow = _requestObject(
      corpusRows[index],
      'request corpus row $index',
    );
    final id = _requestText(row['id'], 'the golden row $index id');
    if (id != corpusRow['id']) {
      throw FormatException('row identity mismatch at index $index');
    }
    if (!ids.add(id)) {
      throw FormatException('the golden row id is duplicated: $id');
    }
    final outcome = _requestText(row['outcome'], 'the golden row $id outcome');
    if (outcome == 'ok') {
      if (row['status'] is! int) {
        throw FormatException('the golden row $id has no status');
      }
      _requestString(row['body'], 'the golden row $id body');
    } else if (outcome == 'error') {
      _requestText(row['error'], 'the golden row $id error');
    } else {
      throw FormatException('the golden row $id has an unknown outcome');
    }
    final requests = _requestList(
      row['requests'],
      'the golden row $id requests',
    );
    if (requests.isEmpty) {
      throw FormatException('the golden row $id holds no requests');
    }
    for (var requestIndex = 0; requestIndex < requests.length; requestIndex++) {
      final request = _requestObject(
        requests[requestIndex],
        'the golden row $id request $requestIndex',
      );
      _checkRequestCarrier(request, 'the golden row $id request $requestIndex');
      flattened.add(request);
    }
  }
  final trace = _requestList(golden['requests'], 'the golden request trace');
  if (trace.isEmpty) {
    throw const FormatException('the golden holds no request trace');
  }
  if (run['requests'] != trace.length || run['requests'] != flattened.length) {
    throw const FormatException('the manifest request counts disagree');
  }
  if (!jsonSemanticEquals(flattened, trace)) {
    throw const FormatException(
      'the golden request trace does not equal its ordered rows',
    );
  }
}

/// Loads the product-side observation from a prior `--requests` report. The
/// compare-only mode never runs the product or the native library; it replays
/// an already-recorded observation through the same comparison used by the
/// real CLI. Identity, corpus, golden and library pins are checked here.
List<Map<String, Object?>> loadRequestObservation({
  required Map<String, dynamic> observed,
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required String goldenSha256,
}) {
  if (observed['mode'] != 'requests') {
    throw const FormatException(
      'the observed input is not a --requests report',
    );
  }
  for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit']) {
    if (observed[key] != corpus[key]) {
      throw FormatException('the observed input names another corpus ($key)');
    }
  }
  if (observed['corpusSha256'] != corpusSha256) {
    throw const FormatException(
      'the observed input names another corpus bytes',
    );
  }
  if (observed['goldenSha256'] != goldenSha256) {
    throw const FormatException('the observed input names another golden');
  }
  _requestText(observed['library'], 'the observed input library');
  if (!_isSha256Text(observed['librarySha256'])) {
    throw const FormatException('the observed input has no native library pin');
  }
  final rows = _requestList(observed['rows'], 'the observed input rows');
  final corpusRows = _requestList(corpus['rows'], 'request corpus rows');
  if (rows.length != corpusRows.length) {
    throw FormatException(
      'the observed input records ${rows.length} rows for '
      '${corpusRows.length} corpus rows',
    );
  }
  final observations = <Map<String, Object?>>[];
  final ids = <String>{};
  for (var index = 0; index < rows.length; index++) {
    final row = _requestObject(rows[index], 'the observed row $index');
    final corpusRow = _requestObject(
      corpusRows[index],
      'request corpus row $index',
    );
    final id = _requestText(row['id'], 'the observed row $index id');
    if (id != corpusRow['id']) {
      throw FormatException('observed row identity mismatch at index $index');
    }
    if (!ids.add(id)) {
      throw FormatException('the observed row id is duplicated: $id');
    }
    final liber = _requestObject(row['liber'], 'the observed row $id liber');
    observations.add(<String, Object?>{'id': id, ...liber});
  }
  return observations;
}

/// The corpus' replay server: every response comes from the corpus, a row is
/// sliced out of the request log by offset, and an undeclared request is
/// recorded as unexpected while still being answered with the corpus' 404
/// placeholder. The comparison must fail such a run even if its 404 body happens
/// to look usable; [unmatchedRequests] and [serverErrors] are the evidence.
class RequestReplayServer {
  RequestReplayServer(
    this.corpus, {
    required this.origin,
    required this.otherOrigin,
    int? port,
  }) : _port = port ?? _requestPort;

  final Map<String, dynamic> corpus;
  final String origin;
  final String otherOrigin;
  final int _port;
  final requests = <Map<String, Object?>>[];
  final unmatchedRequests = <Map<String, Object?>>[];
  final serverErrors = <Map<String, Object?>>[];
  final _clients = <Socket>{};
  late final ServerSocket _server;
  var _closed = false;

  bool get closed => _closed;
  int get port => _server.port;

  Future<RequestReplayServer> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
    _server.listen(_accept, onError: (Object error) => _recordError('$error'));
    return this;
  }

  void _recordError(String error) => serverErrors.add({'error': error});

  void _accept(Socket socket) {
    _clients.add(socket);
    var buffer = '';
    var served = 0;
    socket.listen(
      (bytes) {
        try {
          buffer += latin1.decode(bytes);
          while (true) {
            final end = buffer.indexOf('\r\n\r\n');
            if (end < 0) return;
            final head = buffer.substring(0, end);
            final lines = head.split('\r\n');
            // A leading CRLF is legal before a request line.
            while (lines.isNotEmpty && lines.first.isEmpty) {
              lines.removeAt(0);
            }
            if (lines.isEmpty) return;
            final requestLine = lines.first.split(' ');
            if (requestLine.length < 2) {
              _recordError('malformed replay request line');
              socket.destroy();
              _clients.remove(socket);
              return;
            }
            final method = requestLine[0];
            final target = requestLine[1];
            final headers = <String, Object?>{};
            for (final line in lines.skip(1)) {
              final separator = line.indexOf(':');
              if (separator <= 0) continue;
              final name = line.substring(0, separator).trim().toLowerCase();
              final value = line.substring(separator + 1).trim();
              final existing = headers[name];
              headers[name] = existing == null ? value : '$existing, $value';
            }
            final declaredLength = int.tryParse(
              '${headers['content-length'] ?? ''}',
            );
            final chunked = '${headers['transfer-encoding'] ?? ''}'
                .toLowerCase()
                .contains('chunked');
            String body;
            int consumed;
            if (chunked) {
              // The platform frames a body of unknown length with chunked
              // encoding: Dart's HttpClient does for a request whose
              // contentLength was never set, OkHttp does not for a String body.
              final parsed = _readChunked(buffer.substring(end + 4));
              if (parsed == null) return;
              body = parsed.body;
              consumed = end + 4 + parsed.consumed;
            } else {
              final length = declaredLength ?? 0;
              if (buffer.length < end + 4 + length) return;
              body = length > 0
                  ? buffer.substring(end + 4, end + 4 + length)
                  : '';
              consumed = end + 4 + length;
            }
            buffer = buffer.substring(consumed);
            served++;
            final at = target.indexOf('?');
            final path = at < 0 ? target : target.substring(0, at);
            final rawQuery = at < 0 ? '' : target.substring(at + 1);
            final declared = (corpus['responses'] as List)
                .cast<Map<String, dynamic>>()
                .firstWhere(
                  (entry) => entry['method'] == method && entry['path'] == path,
                  orElse: () => <String, dynamic>{},
                );
            final request = <String, Object?>{
              'method': method,
              'path': path,
              'rawQuery': rawQuery,
              'headers': headers,
              'body': body,
              'declared': declared.isNotEmpty,
            };
            requests.add(request);
            if (declared.isEmpty) {
              unmatchedRequests.add({...request});
            }
            final status = declared['status'] as int?;
            final responseBody = _substitute(
              declared['body'] as String? ?? 'undeclared replay request',
            );
            final responseHeaders = <String, String>{
              for (final entry
                  in (declared['headers'] as Map<String, dynamic>? ??
                          const <String, dynamic>{})
                      .entries)
                entry.key: _substitute('${entry.value}'),
            };
            final bytes = utf8.encode(responseBody);
            final response = StringBuffer()
              ..writeln('HTTP/1.1 ${status ?? 404} OK')
              ..writeln('Content-Type: text/plain')
              ..writeln('Content-Length: ${bytes.length}');
            responseHeaders.forEach(
              (name, value) => response.writeln('$name: $value'),
            );
            response.write('\r\n');
            socket.add(latin1.encode(response.toString()));
            socket.add(bytes);
            unawaited(socket.flush());
            if (served > 64) {
              _recordError('replay request limit exceeded');
              socket.destroy();
              _clients.remove(socket);
              return;
            }
          }
        } on Object catch (error) {
          _recordError('$error');
          socket.destroy();
          _clients.remove(socket);
        }
      },
      onDone: () {
        socket.destroy();
        _clients.remove(socket);
      },
      onError: (Object error) {
        _recordError('$error');
        socket.destroy();
        _clients.remove(socket);
      },
    );
  }

  String _substitute(String text) => text
      .replaceAll(r'$OTHER_ORIGIN', otherOrigin)
      .replaceAll(r'$ORIGIN', origin);

  /// One chunked body, or null while the buffer does not hold all of it yet.
  ({String body, int consumed})? _readChunked(String rest) {
    var index = 0;
    final body = StringBuffer();
    while (true) {
      final lineEnd = rest.indexOf('\r\n', index);
      if (lineEnd < 0) return null;
      final size = int.tryParse(
        rest.substring(index, lineEnd).split(';').first.trim(),
        radix: 16,
      );
      if (size == null) {
        _recordError('malformed chunked replay body');
        return null;
      }
      index = lineEnd + 2;
      if (size == 0) {
        final trailerEnd = rest.indexOf('\r\n', index);
        if (trailerEnd < 0) return null;
        return (body: body.toString(), consumed: trailerEnd + 2);
      }
      if (rest.length < index + size + 2) return null;
      body.write(rest.substring(index, index + size));
      index += size + 2;
    }
  }

  List<Map<String, dynamic>> since(int offset) =>
      requests.skip(offset).cast<Map<String, dynamic>>().toList();

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _server.close();
    } finally {
      for (final socket in _clients.toList()) {
        socket.destroy();
      }
      _clients.clear();
    }
  }
}

/// Drives `tool/nested_oracle/request-fixtures.json` through the product's
/// request layer and compares the rows with the frozen golden.
///
/// The row's declared input is the same on both sides: the rule text (with its
/// optional `,{...}` object), the `{{key}}`/`{{page}}` bindings and the
/// declared header map. The product side resolves the rule with the same public
/// functions `HtmlSourcePipeline._request` uses (`expandSourceUrl`,
/// `splitSourceUrlOptions`, `encodeSourceQuery`, `sourceUrlTextWithRawQuery`),
/// then sends it through `HttpSourceTransport`, which is the transport under
/// test. The corpus declares no `js` option and no relative rule text, so the
/// pipeline's `js` branch and its URL validation are outside this corpus.
Future<void> _runRequestOracle(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Usage: --requests <fjs.dll> <golden.json> <new-report.json>',
    );
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus = loadRequestCorpus();
  final corpusSha256 = sha256File(File(requestCorpusPath));
  final corpusSha256Lf = sha256FileLf(File(requestCorpusPath));
  final manifest = loadRequestManifest();
  final manifestSha256 = sha256File(File(requestManifestPath));
  final goldenFile = File(args[1]);
  final goldenSha256 = sha256File(goldenFile);
  final golden =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  // Refuse a bad corpus/golden/manifest before loading the native library or
  // opening the replay server, so a forged input cannot run the product.
  checkRequestGolden(
    corpus: corpus,
    corpusSha256: corpusSha256,
    manifest: manifest,
    golden: golden,
    goldenSha256: goldenSha256,
  );
  final library = File(args[0]);
  if (!library.existsSync()) {
    throw StateError('the native library is missing: ${args[0]}');
  }
  final librarySha256 = sha256File(library);
  final origin = 'http://127.0.0.2:$_requestPort';
  final otherOrigin = 'http://127.0.0.3:$_requestPort';
  RequestReplayServer? replay;
  var nativeDisposed = false;
  final observations = <Map<String, Object?>>[];
  final analysisErrors = <Map<String, Object?>>[];
  try {
    // The transport decodes each response body the frozen way, which reaches
    // the engine for the `EncodingDetect` fallback; the corpus declares no
    // charset.
    await NativeLibrary.initialize(libraryPath: args[0]);
    final server = await RequestReplayServer(
      corpus,
      origin: origin,
      otherOrigin: otherOrigin,
    ).start();
    replay = server;
    final transport = HttpSourceTransport();
    for (final entry in corpus['rows'] as List) {
      final row = (entry as Map).cast<String, dynamic>();
      final id = '${row['id']}';
      final offset = server.requests.length;
      Map<String, Object?> observed;
      try {
        observed = await _liberRow(
          row,
          transport,
          origin: origin,
          otherOrigin: otherOrigin,
        );
      } catch (error, stack) {
        analysisErrors.add({'row': id, 'error': '$error', 'stack': '$stack'});
        observed = {'outcome': 'error', 'error': '$error'};
      }
      observed['id'] = id;
      observed['requests'] = server.since(offset);
      observations.add(observed);
    }
  } finally {
    if (replay != null) await replay.close();
    NativeLibrary.dispose();
    nativeDisposed = true;
  }
  final report = compareRequestRows(
    corpus: corpus,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    manifest: manifest,
    manifestSha256: manifestSha256,
    golden: golden,
    goldenSha256: goldenSha256,
    goldenPath: args[1],
    observations: observations,
    serverUnmatchedRequests: replay.unmatchedRequests,
    serverErrors: replay.serverErrors,
    analysisErrors: analysisErrors,
    library: args[0],
    librarySha256: librarySha256,
    replayClosed: replay.closed,
    nativeDisposed: nativeDisposed,
  );
  report['origins'] = {'origin': origin, 'otherOrigin': otherOrigin};
  final comparerSha256 = sha256File(File(requestComparerPath));
  final comparerSha256Lf = sha256FileLf(File(requestComparerPath));
  report['comparerSha256'] = comparerSha256;
  report['comparerSha256Lf'] = comparerSha256Lf;
  report['comparer'] = {
    'path': requestComparerPath,
    'sha256': comparerSha256,
    'sha256Lf': comparerSha256Lf,
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  for (final row in report['rows'] as List) {
    stdout.writeln('${(row as Map)['status']}\t${row['id']}');
  }
  stdout.writeln(
    'request corpus: ${report['status']} (${(report['rows'] as List).length} '
    'rows, ${(report['passedRows'] as List).length} pass, '
    '${(report['failedRows'] as List).length} fail, '
    '${(report['notComparedRows'] as List).length} notCompared)',
  );
  if (report['status'] != 'pass') exitCode = 1;
}

/// Replays an already-recorded `--requests` report through the same comparison
/// without loading the native library or opening a replay server. It is a
/// compare-only seam for copied-input negative controls; it never labels its
/// observation as a golden.
Future<void> _runRequestCompareOnly(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Usage: --requests-compare <observed-report.json> <golden.json> '
      '<new-report.json>',
    );
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus = loadRequestCorpus();
  final corpusSha256 = sha256File(File(requestCorpusPath));
  final corpusSha256Lf = sha256FileLf(File(requestCorpusPath));
  final manifest = loadRequestManifest();
  final manifestSha256 = sha256File(File(requestManifestPath));
  final goldenFile = File(args[1]);
  final goldenSha256 = sha256File(goldenFile);
  final golden =
      jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  checkRequestGolden(
    corpus: corpus,
    corpusSha256: corpusSha256,
    manifest: manifest,
    golden: golden,
    goldenSha256: goldenSha256,
  );
  final observedFile = File(args[0]);
  final observedSha256 = sha256File(observedFile);
  final observed =
      jsonDecode(observedFile.readAsStringSync()) as Map<String, dynamic>;
  final observations = loadRequestObservation(
    observed: observed,
    corpus: corpus,
    corpusSha256: corpusSha256,
    goldenSha256: goldenSha256,
  );
  if (observed['manifestSha256'] != manifestSha256) {
    throw const FormatException('the observed input names another manifest');
  }
  final comparerSha256 = sha256File(File(requestComparerPath));
  final comparerSha256Lf = sha256FileLf(File(requestComparerPath));
  // The LF identity is the semantic source identity; the raw hash is recorded
  // as evidence and may differ after a checkout line-ending conversion.
  if (observed['comparerSha256Lf'] != comparerSha256Lf) {
    throw const FormatException('the observed input names another comparer');
  }
  final observedLibrary = File(
    _requestText(observed['library'], 'the observed input library'),
  );
  if (!observedLibrary.existsSync()) {
    throw const FormatException('the observed native library is missing');
  }
  if (sha256File(observedLibrary) != observed['librarySha256']) {
    throw const FormatException(
      'the observed native library bytes differ from their pin',
    );
  }
  final serverUnmatchedRequests = observed['unmatchedRequests'] == null
      ? const <Map<String, Object?>>[]
      : _requestObjectList(
          observed['unmatchedRequests'],
          'the observed server unmatched requests',
        );
  final serverErrors = observed['serverErrors'] == null
      ? const <Map<String, Object?>>[]
      : _requestObjectList(
          observed['serverErrors'],
          'the observed server errors',
        );
  final analysisErrors = observed['analysisErrors'] == null
      ? const <Map<String, Object?>>[]
      : _requestObjectList(
          observed['analysisErrors'],
          'the observed analysis errors',
        );
  final report = compareRequestRows(
    corpus: corpus,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    manifest: manifest,
    manifestSha256: manifestSha256,
    golden: golden,
    goldenSha256: goldenSha256,
    goldenPath: args[1],
    observations: observations,
    serverUnmatchedRequests: serverUnmatchedRequests,
    serverErrors: serverErrors,
    analysisErrors: analysisErrors,
    library: _requestText(observed['library'], 'the observed input library'),
    librarySha256: _requestText(
      observed['librarySha256'],
      'the observed input librarySha256',
    ),
    observedPath: args[0],
    observedSha256: observedSha256,
  );
  report['mode'] = 'requests-compare';
  report['note'] =
      'Compare-only replay of a recorded --requests observation; no product '
      'run, native library load or replay server is claimed.';
  report['comparerSha256'] = comparerSha256;
  report['comparerSha256Lf'] = comparerSha256Lf;
  report['comparer'] = {
    'path': requestComparerPath,
    'sha256': comparerSha256,
    'sha256Lf': comparerSha256Lf,
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(
    'request comparison: ${report['status']} (${(report['rows'] as List).length} '
    'rows, ${(report['passedRows'] as List).length} pass, '
    '${(report['failedRows'] as List).length} fail, '
    '${(report['notComparedRows'] as List).length} notCompared)',
  );
  if (report['status'] != 'pass') exitCode = 1;
}

/// Compares one recorded product observation per declared corpus row with the
/// validated frozen golden. The caller supplies the observation from the live
/// `--requests` run or from a copied `--requests` report; both use this exact
/// function.
Map<String, Object?> compareRequestRows({
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required String corpusSha256Lf,
  required Map<String, dynamic> manifest,
  required String manifestSha256,
  required Map<String, dynamic> golden,
  required String goldenSha256,
  required String goldenPath,
  required List<Map<String, Object?>> observations,
  required List<Map<String, Object?>> serverUnmatchedRequests,
  required List<Map<String, Object?>> serverErrors,
  required List<Map<String, Object?>> analysisErrors,
  String? library,
  String? librarySha256,
  String? observedPath,
  String? observedSha256,
  bool? replayClosed,
  bool? nativeDisposed,
}) {
  checkRequestGolden(
    corpus: corpus,
    corpusSha256: corpusSha256,
    manifest: manifest,
    golden: golden,
    goldenSha256: goldenSha256,
  );
  final corpusRows = _requestList(corpus['rows'], 'request corpus rows');
  final goldenRows = _requestList(golden['rows'], 'the golden rows');
  if (observations.isEmpty) {
    throw const FormatException('the product observation holds no rows');
  }
  if (observations.length != corpusRows.length) {
    throw FormatException(
      'the product recorded ${observations.length} rows for '
      '${corpusRows.length} corpus rows',
    );
  }
  if (library != null || librarySha256 != null) {
    if (!_isSha256Text(librarySha256)) {
      throw const FormatException('the native library pin is missing');
    }
  }
  if (observedPath != null || observedSha256 != null) {
    _requestText(observedPath, 'the observed report path');
    if (!_isSha256Text(observedSha256)) {
      throw const FormatException('the observed report pin is missing');
    }
  }
  final declaredKeys = <String>{
    for (final raw in _requestList(corpus['responses'], 'request responses'))
      '${raw['method']} ${raw['path']}',
  };
  final rows = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final ids = <String>{};
  var observedRequests = 0;
  for (var index = 0; index < corpusRows.length; index++) {
    final corpusRow = _requestObject(
      corpusRows[index],
      'request corpus row $index',
    );
    final id = _requestText(corpusRow['id'], 'request corpus row $index id');
    final observed = observations[index];
    final observedId = _requestText(
      observed['id'],
      'the observed row $index id',
    );
    if (observedId != id) {
      throw FormatException('observed row identity mismatch at index $index');
    }
    if (!ids.add(id)) {
      throw FormatException('the observed row id is duplicated: $id');
    }
    final outcome = _requestText(
      observed['outcome'],
      'the observed row $id outcome',
    );
    if (outcome == 'ok') {
      if (observed['status'] is! int) {
        throw FormatException('the observed row $id has no status');
      }
      _requestString(observed['body'], 'the observed row $id body');
    } else if (outcome == 'error') {
      _requestText(observed['error'], 'the observed row $id error');
    } else {
      throw FormatException('the observed row $id has an unknown outcome');
    }
    final rawRequests = _requestList(
      observed['requests'],
      'the observed row $id requests',
    );
    if (rawRequests.isEmpty) {
      throw FormatException('the observed row $id holds no requests');
    }
    final requests = <Map<String, dynamic>>[];
    for (
      var requestIndex = 0;
      requestIndex < rawRequests.length;
      requestIndex++
    ) {
      final request = _requestObject(
        rawRequests[requestIndex],
        'the observed row $id request $requestIndex',
      );
      _checkRequestCarrier(
        request,
        'the observed row $id request $requestIndex',
      );
      requests.add(request);
      observedRequests++;
      if (!declaredKeys.contains('${request['method']} ${request['path']}')) {
        unmatched.add({
          'row': id,
          'index': requestIndex,
          ...request,
          'declared': false,
        });
      }
    }
    final frozen = _requestObject(goldenRows[index], 'the golden row $index');
    rows.add(_compareRow(id, frozen, observed, requests, declaredKeys));
  }

  // A replay server can see a request that the row slice did not attribute
  // (for example a connection-level request). Keep that actual request too and
  // fail, rather than hiding it behind a summary.
  for (var index = 0; index < serverUnmatchedRequests.length; index++) {
    final raw = Map<String, dynamic>.from(serverUnmatchedRequests[index]);
    _checkRequestCarrier(raw, 'the server unexpected request $index');
    final duplicated = unmatched.any(
      (entry) =>
          entry['method'] == raw['method'] &&
          entry['path'] == raw['path'] &&
          entry['rawQuery'] == raw['rawQuery'] &&
          entry['body'] == raw['body'],
    );
    if (!duplicated) {
      unmatched.add({...raw, 'row': raw['row'], 'serverObserved': true});
    }
  }

  final failed = rows.where((row) => row['status'] == 'fail').toList();
  final notCompared = rows
      .where((row) => row['status'] == 'notCompared')
      .toList();
  final failedBySelection =
      unmatched.isNotEmpty ||
      serverErrors.isNotEmpty ||
      analysisErrors.isNotEmpty;
  final status = failed.isEmpty && !failedBySelection ? 'pass' : 'fail';
  final targetApplication = _requestObject(
    _requestObject(
      manifest['baseline'],
      'request manifest baseline',
    )['application'],
    'request manifest target application',
  );
  final harness = _requestObject(
    manifest['harness'],
    'request manifest harness',
  );
  final corpusSource = (harness['sources'] as List)
      .cast<Map<String, dynamic>>()
      .firstWhere((source) => source['path'] == requestCorpusPath);
  final manifestCorpus = _requestObject(
    manifest['corpus'],
    'request manifest corpus',
  );
  final run = _requestObject(manifest['run'], 'request manifest run');
  final goldenPin = _requestObject(run['golden'], 'request manifest golden');
  return <String, Object?>{
    'platform': Platform.operatingSystem,
    'mode': 'requests',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'corpusPath': requestCorpusPath,
    'corpusSha256': corpusSha256,
    'corpusSha256Lf': corpusSha256Lf,
    'corpusIdentity': {
      'rawSha256': corpusSha256,
      'lfSha256': corpusSha256Lf,
      'manifestRawPin': manifestCorpus['sha256'],
      'manifestSourceSha256': corpusSource['sha256'],
      'manifestGitBlobSha256AtStartingHead':
          corpusSource['gitBlobSha256AtStartingHead'],
      'rawMatchesManifestPin': corpusSha256 == manifestCorpus['sha256'],
      'lfMatchesManifestPin': corpusSha256Lf == manifestCorpus['sha256'],
    },
    'manifest': requestManifestPath,
    'manifestSha256': manifestSha256,
    'golden': goldenPath,
    'goldenSha256': goldenSha256,
    'target': {
      'baselineCommit': corpus['baselineCommit'],
      'deviceFingerprint': _requestObject(
        manifest['device'],
        'request manifest device',
      )['fingerprint'],
      'applicationPackage': targetApplication['package'],
      'targetApkSha256': targetApplication['sha256'],
      'harnessApkSha256': harness['apkSha256'],
    },
    'capture': {
      'recordedAt': manifest['recordedAt'],
      'goldenPath': goldenPin['path'],
      'goldenSha256': goldenPin['sha256'],
      'captures': run['captures'],
    },
    'library': library,
    'librarySha256': librarySha256,
    'observed': ?observedPath,
    'observedSha256': ?observedSha256,
    'ignoredHeaders': _ignoredHeaders.toList(),
    'declaredDivergences': _declaredDivergences.map(
      (row, entry) => MapEntry(row, entry['reason']!),
    ),
    'status': status,
    'rows': rows,
    'passedRows': [
      for (final row in rows)
        if (row['status'] == 'pass') row['id'],
    ],
    'failedRows': [for (final row in failed) row['id']],
    'notComparedRows': [for (final row in notCompared) row['id']],
    'unmatchedRequests': unmatched,
    'serverUnmatchedRequests': serverUnmatchedRequests,
    'serverErrors': serverErrors,
    'analysisErrors': analysisErrors,
    'cleanup': {
      'replayClosed': ?replayClosed,
      'nativeDisposed': ?nativeDisposed,
    },
    'counts': {
      'corpusRows': corpusRows.length,
      'goldenRows': goldenRows.length,
      'observedRows': observations.length,
      'observedRequests': observedRequests,
      'goldenRequests': (golden['requests'] as List).length,
      'unmatchedRequests': unmatched.length,
    },
  };
}

/// One row's product-side run: the resolved rule text, the transport call and
/// the request/outcome evidence the replay server saw.
Future<Map<String, Object?>> _liberRow(
  Map<String, dynamic> row,
  HttpSourceTransport transport, {
  required String origin,
  required String otherOrigin,
}) async {
  final declared = row['request'] as Map<String, dynamic>;
  final page = declared['page'] as int?;
  final key = declared['key'] as String?;
  final ruleText = (declared['rule'] as String)
      .replaceAll(r'$OTHER_ORIGIN', otherOrigin)
      .replaceAll(r'$ORIGIN', origin);
  final declaredHeaders = <String, String>{
    for (final entry
        in (declared['headers'] as Map<String, dynamic>? ?? const {}).entries)
      entry.key: '${entry.value}',
  };
  final expanded = await expandSourceUrl(ruleText, (expression, result) {
    switch (expression.trim()) {
      case 'key':
        return Future<Object?>.value(key);
      case 'page':
        return Future<Object?>.value(page);
      default:
        throw UnsupportedError(
          'the request corpus declares no JavaScript in a request rule: '
          '$expression',
        );
    }
  }, page: page);
  final split = splitSourceUrlOptions(expanded);
  final base = Uri.parse(origin);
  var url = base.resolve(split.path);
  if (!split.options.isPost) {
    url = base.resolve(
      await encodeSourceQuery(
        sourceUrlTextWithRawQuery(url, split.path),
        charset: split.options.charset,
      ),
    );
  }
  final merged = {...declaredHeaders, ...split.options.headers};
  final shape = await sourceRequestShape(split.options, merged);
  final observed = <String, Object?>{
    'ruleText': ruleText,
    'resolvedUrl': '$url',
    'method': shape.method,
    // The names the source itself declared: the contract compares a
    // platform-generated name (`Connection`) when the source sets it.
    'declaredHeaders': [
      for (final name in {...declaredHeaders.keys, ...merged.keys})
        name.toLowerCase(),
    ],
  };
  try {
    final result = await transport.send(
      SourceHttpRequest(
        method: shape.method,
        url: url,
        headers: {...merged, ...shape.headers},
        body: shape.body,
        followRedirects: true,
      ),
    );
    observed['outcome'] = 'ok';
    observed['status'] = result.statusCode;
    observed['finalUrl'] = '${result.url}';
    observed['body'] = result.body;
  } catch (error) {
    observed['outcome'] = 'error';
    observed['error'] = '$error';
  }
  return observed;
}

/// Compares one row's frozen golden with the product's own observation.
Map<String, Object?> _compareRow(
  String id,
  Map<String, dynamic> frozen,
  Map<String, Object?> observed,
  List<Map<String, dynamic>> liberRequests,
  Set<String> declaredRequestKeys,
) {
  final declaredNames = <String>{};
  if (observed['declaredHeaders'] != null) {
    for (final name in _requestList(
      observed['declaredHeaders'],
      'the observed row $id declared headers',
    )) {
      declaredNames.add(
        _requestText(name, 'the observed row $id header name').toLowerCase(),
      );
    }
  }
  final liber = <String, Object?>{
    'requests': liberRequests,
    'outcome': observed['outcome'],
    if (observed['status'] != null) 'status': observed['status'],
    if (observed['body'] != null) 'body': observed['body'],
    if (observed['error'] != null) 'error': observed['error'],
    if (declaredNames.isNotEmpty)
      'declaredHeaders': declaredNames.toList()..sort(),
  };
  final mismatches = <Map<String, Object?>>[];
  final divergences = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final frozenRequests = (frozen['requests'] as List)
      .cast<Map<String, dynamic>>();
  if (frozenRequests.length != liberRequests.length) {
    _record(
      id,
      'requests.length',
      frozenRequests.length,
      liberRequests.length,
      mismatches,
      divergences,
    );
  }
  for (var index = 0; index < liberRequests.length; index++) {
    final actual = liberRequests[index];
    if (!declaredRequestKeys.contains(
      '${actual['method']} ${actual['path']}',
    )) {
      final unexpected = {
        'row': id,
        'index': index,
        ...actual,
        'declared': false,
      };
      unmatched.add(unexpected);
      _record(
        id,
        'requests[$index].unmatched',
        null,
        unexpected,
        mismatches,
        divergences,
      );
    }
    if (index >= frozenRequests.length) {
      _record(id, 'requests[$index]', null, actual, mismatches, divergences);
      continue;
    }
    final expected = frozenRequests[index];
    for (final field in ['method', 'path', 'rawQuery', 'body']) {
      if (expected[field] != actual[field]) {
        _record(
          id,
          'requests[$index].$field',
          expected[field],
          actual[field],
          mismatches,
          divergences,
        );
      }
    }
    final frozenHeaders = (expected['headers'] as Map).cast<String, Object?>();
    final liberHeaders = (actual['headers'] as Map).cast<String, Object?>();
    final names = {...frozenHeaders.keys, ...liberHeaders.keys}.toList()
      ..sort();
    for (final name in names) {
      if (_ignoredHeaders.contains(name) && !declaredNames.contains(name)) {
        continue;
      }
      final expectedValue = frozenHeaders[name];
      final actualValue = liberHeaders[name];
      if (jsonEncode(expectedValue) != jsonEncode(actualValue)) {
        _record(
          id,
          'requests[$index].headers.$name',
          expectedValue,
          actualValue,
          mismatches,
          divergences,
        );
      }
    }
  }
  if (frozenRequests.length > liberRequests.length) {
    for (
      var index = liberRequests.length;
      index < frozenRequests.length;
      index++
    ) {
      _record(
        id,
        'requests[$index]',
        frozenRequests[index],
        null,
        mismatches,
        divergences,
      );
    }
  }
  // The outcome is compared as its two shapes (a completed call with a status
  // and body, or a failed call); the platform's exception class is not part of
  // the comparison. `finalUrl` stays out of it as well: the two sides serve
  // the same corpus on their own port, so only the request-target bytes are
  // comparable.
  if (frozen['outcome'] != liber['outcome']) {
    _record(
      id,
      'outcome',
      frozen['outcome'],
      liber['outcome'],
      mismatches,
      divergences,
    );
  } else if (frozen['outcome'] == 'ok') {
    for (final field in ['status', 'body']) {
      if (frozen[field] != liber[field]) {
        _record(
          id,
          field,
          frozen[field],
          liber[field],
          mismatches,
          divergences,
        );
      }
    }
  }
  final status = mismatches.isNotEmpty
      ? 'fail'
      : (divergences.isNotEmpty ? 'notCompared' : 'pass');
  return {
    'id': id,
    'status': status,
    'frozen': {
      'requests': frozenRequests,
      'outcome': frozen['outcome'],
      if (frozen['status'] != null) 'status': frozen['status'],
      if (frozen['body'] != null) 'body': frozen['body'],
      if (frozen['error'] != null) 'error': frozen['error'],
    },
    'liber': liber,
    'liberRule': {
      'ruleText': observed['ruleText'],
      'resolvedUrl': observed['resolvedUrl'],
      'method': observed['method'],
    },
    if (unmatched.isNotEmpty) 'unmatchedRequests': unmatched,
    'mismatches': mismatches,
    'divergences': divergences,
  };
}

void _record(
  String id,
  String observation,
  Object? frozen,
  Object? liber,
  List<Map<String, Object?>> mismatches,
  List<Map<String, Object?>> divergences,
) {
  final declared = _declaredDivergences[id];
  final entry = <String, Object?>{
    'observation': observation,
    'frozen': frozen,
    'liber': liber,
  };
  if (declared != null && declared['observation'] == observation) {
    entry['reason'] = declared['reason'];
    divergences.add(entry);
  } else {
    mismatches.add(entry);
  }
}
