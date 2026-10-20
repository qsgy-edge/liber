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
  final corpus =
      jsonDecode(
            File('tool/nested_oracle/request-fixtures.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final golden =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  if (golden['fixtureId'] != corpus['fixtureId'] ||
      golden['corpusVersion'] != corpus['corpusVersion'] ||
      golden['baselineCommit'] != corpus['baselineCommit']) {
    throw StateError('Oracle identity mismatch');
  }
  final origin = 'http://127.0.0.2:$_requestPort';
  final otherOrigin = 'http://127.0.0.3:$_requestPort';
  // The transport decodes each response body the frozen way, which reaches the
  // engine for the `EncodingDetect` fallback; the corpus declares no charset.
  await NativeLibrary.initialize(libraryPath: args[0]);
  final replay = await _ReplayServer(
    corpus,
    origin: origin,
    otherOrigin: otherOrigin,
  ).start();
  final transport = HttpSourceTransport();
  final rows = <Map<String, Object?>>[];
  try {
    for (final entry in corpus['rows'] as List) {
      final row = entry as Map<String, dynamic>;
      final id = row['id'] as String;
      final frozen =
          (golden['rows'] as List).firstWhere(
                (goldenRow) => (goldenRow as Map)['id'] == id,
                orElse: () => throw StateError('the golden has no row $id'),
              )
              as Map<String, dynamic>;
      final offset = replay.requests.length;
      final observed = await _liberRow(
        row,
        transport,
        origin: origin,
        otherOrigin: otherOrigin,
      );
      rows.add(_compareRow(id, frozen, observed, replay.since(offset)));
    }
  } finally {
    await replay.close();
    NativeLibrary.dispose();
  }
  final failed = rows.where((row) => row['status'] == 'fail').toList();
  final notCompared = rows
      .where((row) => row['status'] == 'notCompared')
      .toList();
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'mode': 'requests',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'golden': args[1],
    'status': failed.isEmpty ? 'pass' : 'fail',
    'origins': {'origin': origin, 'otherOrigin': otherOrigin},
    'library': args[0],
    'ignoredHeaders': _ignoredHeaders.toList(),
    'declaredDivergences': _declaredDivergences.map(
      (row, entry) => MapEntry(row, entry['reason']!),
    ),
    'rows': rows,
    'passedRows': [
      for (final row in rows)
        if (row['status'] == 'pass') row['id'],
    ],
    'failedRows': [for (final row in failed) row['id']],
    'notComparedRows': [for (final row in notCompared) row['id']],
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  for (final row in rows) {
    stdout.writeln('${row['status']}\t${row['id']}');
  }
  stdout.writeln(
    'request corpus: ${report['status']} (${rows.length} rows, '
    '${(report['passedRows'] as List).length} pass, '
    '${failed.length} fail, ${notCompared.length} notCompared)',
  );
  if (failed.isNotEmpty) exitCode = 1;
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
) {
  final liber = <String, Object?>{
    'requests': liberRequests,
    'outcome': observed['outcome'],
    if (observed['status'] != null) 'status': observed['status'],
    if (observed['body'] != null) 'body': observed['body'],
    if (observed['error'] != null) 'error': observed['error'],
  };
  final mismatches = <Map<String, Object?>>[];
  final divergences = <Map<String, Object?>>[];
  final declaredNames = {
    for (final name in (observed['declaredHeaders'] as List)) '$name',
  };
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
  for (var index = 0; index < frozenRequests.length; index++) {
    final expected = frozenRequests[index];
    if (index >= liberRequests.length) {
      _record(id, 'requests[$index]', expected, null, mismatches, divergences);
      continue;
    }
    final actual = liberRequests[index];
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
    'frozen': {'requests': frozenRequests, 'outcome': frozen['outcome']},
    'liber': liber,
    'liberRule': {
      'ruleText': observed['ruleText'],
      'resolvedUrl': observed['resolvedUrl'],
      'method': observed['method'],
    },
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

/// The corpus' replay server: every response comes from the corpus, a row is
/// sliced out of the request log by offset, and an undeclared request is
/// answered 404 (which this corpus has none of).
class _ReplayServer {
  _ReplayServer(this.corpus, {required this.origin, required this.otherOrigin});

  final Map<String, dynamic> corpus;
  final String origin;
  final String otherOrigin;
  final requests = <Map<String, Object?>>[];
  final _clients = <Socket>{};
  late final ServerSocket _server;

  Future<_ReplayServer> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, _requestPort);
    _server.listen(_accept);
    return this;
  }

  void _accept(Socket socket) {
    _clients.add(socket);
    var buffer = '';
    var served = 0;
    socket.listen(
      (bytes) {
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
          if (requestLine.length < 2) return;
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
          requests.add({
            'method': method,
            'path': path,
            'rawQuery': rawQuery,
            'headers': headers,
            'body': body,
          });
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
            socket.destroy();
            return;
          }
        }
      },
      onDone: () {
        socket.destroy();
        _clients.remove(socket);
      },
      onError: (_) {
        socket.destroy();
        _clients.remove(socket);
      },
    );
  }

  String _substitute(String text) => text
      .replaceAll(r'$OTHER_ORIGIN', otherOrigin)
      .replaceAll(r'$ORIGIN', origin);

  /// One chunked body, or null while the buffer does not hold all of it yet.
  static ({String body, int consumed})? _readChunked(String rest) {
    var index = 0;
    final body = StringBuffer();
    while (true) {
      final lineEnd = rest.indexOf('\r\n', index);
      if (lineEnd < 0) return null;
      final size = int.tryParse(
        rest.substring(index, lineEnd).split(';').first.trim(),
        radix: 16,
      );
      if (size == null) return null;
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
    await _server.close();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
  }
}
