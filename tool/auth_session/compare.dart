import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'runner.dart';

/// Compares the product's two `AUTH-SESSION-01` phases with the controller's
/// frozen seed/restart captures.
///
/// Usage:
///   `dart run tool/auth_session/compare.dart --capture=<capture>`
///   `--evidence=<a2-auth-product> --library=<fjs.dll> [--handoff=<json>]`
///
///   `dart run tool/auth_session/compare.dart --compare-only <seed.json>`
///   `<restart.json> --golden-seed=<seed-report.json>`
///   `--golden-restart=<restart-report.json> [--handoff=<json>]`
///   `[--library=<fjs.dll>] [--out=<report.json>]`
///
/// The first form runs the two product phases as two terminated Dart processes,
/// compares them, then runs the negative controls on copies of the immutable
/// captures. The second form compares two reports that already exist; it is
/// what those controls invoke, and it never marks a product-only sample as a
/// golden.
Future<void> main(List<String> args) async {
  if (args.contains('--compare-only')) {
    exitCode = await _compareOnly(args);
    return;
  }
  if (args.contains('--controls-only')) {
    exitCode = await _controlsOnly(args);
    return;
  }
  exitCode = await _runAndCompare(args);
}

// --------------------------------------------------------------------------
// Frozen capture validation
// --------------------------------------------------------------------------

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('$what is not a JSON object');
}

List<dynamic> _array(Object? value, String what) {
  if (value is List) return value;
  throw FormatException('$what is not a JSON array');
}

String _text(Object? value, String what) {
  final text = value is String ? value.trim() : '';
  if (text.isEmpty) throw FormatException('$what is empty');
  return text;
}

int _integer(Object? value, String what) {
  if (value is int) return value;
  throw FormatException('$what is not an integer');
}

/// A count the harness records as a number, or a list it records as rows.
bool _isEmptyCount(Object? value) =>
    value is List ? value.isEmpty : (value is int ? value == 0 : false);

bool _isSha256(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

/// The contract's platform-generated header rule (`Matching Rules` ->
/// `Requests`): `Host`, `Content-Length`, `Accept-Encoding` and `Connection`
/// are ignored unless the source explicitly sets them. None of this corpus'
/// sources declares any of them, so they are compared nowhere.
const authSessionPlatformHeaders = <String>{
  'host',
  'content-length',
  'accept-encoding',
  'connection',
};

/// One request's compared identity: the method, the resolved path and the raw
/// query bytes the client actually wrote. The decoded `query` map is a view; it
/// is never used to reconstruct the bytes.
Map<String, Object?> normalizeAuthSessionRequest(Object? raw, String what) {
  final request = _object(raw, what);
  final method = _text(request['method'], '$what method');
  final path = _text(request['path'], '$what path');
  final rawQuery = request['rawQuery'];
  if (rawQuery is! String) {
    throw FormatException('$what declares no raw query bytes');
  }
  return {'method': method, 'path': path, 'rawQuery': rawQuery};
}

/// The headers one request carries, lowercased, with the platform-generated
/// names dropped. A repeated name keeps every value, so a duplicate the source
/// declared is not hidden behind one.
Map<String, List<String>> comparedAuthSessionHeaders(Object? raw, String what) {
  final headers = _object(raw, '$what headers');
  final result = <String, List<String>>{};
  for (final entry in headers.entries) {
    final name = entry.key.toLowerCase();
    if (authSessionPlatformHeaders.contains(name)) continue;
    final value = entry.value;
    result[name] = value is List
        ? [for (final item in value) '$item']
        : ['$value'];
  }
  return result;
}

/// Structural and identity validation of the controller's raw captures before
/// any value is compared. A golden is only accepted when it names this corpus,
/// this frozen target, the measured harness, the declared request trace and
/// exactly the declared observation set.
void checkAuthSessionGolden({
  required Map<String, dynamic> corpus,
  required String corpusSha256Lf,
  required Map<String, dynamic> golden,
  required String phase,
  Map<String, dynamic>? handoff,
  String? goldenSha256,
  String goldenPath = 'golden.json',
}) {
  if (phase != 'seed' && phase != 'restart') {
    throw FormatException('unknown phase $phase');
  }
  final target = authSessionTargetOf(corpus);
  if (golden['phase'] != phase) {
    throw FormatException('$goldenPath is not the $phase capture');
  }
  for (final key in ['fixtureId', 'corpusVersion']) {
    if (golden[key] != corpus[key]) {
      throw FormatException('$goldenPath does not describe this corpus ($key)');
    }
  }
  for (final key in ['baselineCommit', 'entryPoint']) {
    if (golden[key] != corpus[key]) {
      throw FormatException('$goldenPath names another $key');
    }
  }
  final identity = _object(golden['identity'], '$goldenPath identity');
  for (final key in ['fixtureId', 'corpusVersion']) {
    if (identity[key] != corpus[key]) {
      throw FormatException('$goldenPath identity does not match ($key)');
    }
  }
  if (identity['targetPackage'] != target['package'] ||
      identity['targetApkSha256'] != target['apkSha256'] ||
      identity['targetBaselineCommit'] != corpus['baselineCommit']) {
    throw FormatException('$goldenPath captured another frozen target');
  }
  if (!_isSha256(identity['corpusAssetSha256']) ||
      identity['corpusAssetSha256'] != corpusSha256Lf ||
      identity['corpusSha256Lf'] != corpusSha256Lf) {
    throw FormatException('$goldenPath was captured against corpus bytes');
  }
  if (!_isSha256(identity['harnessApkSha256'])) {
    throw FormatException('$goldenPath names no measured harness APK');
  }
  _text(identity['harnessPackage'], '$goldenPath harnessPackage');
  if (identity['targetPinManifest'] != target['manifest']) {
    throw FormatException('$goldenPath names another target pin manifest');
  }
  if (_integer(golden['pid'], '$goldenPath pid') <= 0) {
    throw FormatException('$goldenPath names no process');
  }
  _text(golden['runId'], '$goldenPath runId');
  if (DateTime.tryParse('${golden['recordedAt']}') == null) {
    throw FormatException('$goldenPath has no capture time');
  }
  _text(golden['fingerprint'], '$goldenPath fingerprint');
  if (golden['analysisFailure'] != null) {
    throw FormatException('$goldenPath recorded an analysis failure');
  }

  final expected = authSessionExpectedRequests(corpus, phase);
  final requests = _array(golden['requests'], '$goldenPath requests');
  if (requests.isEmpty) {
    throw FormatException('$goldenPath holds no request trace');
  }
  if (requests.length != expected.length) {
    throw FormatException(
      '$goldenPath holds ${requests.length} requests for '
      '${expected.length} declared',
    );
  }
  for (var index = 0; index < expected.length; index++) {
    final declared = normalizeAuthSessionRequest(
      expected[index],
      'declared request $index',
    );
    final captured = normalizeAuthSessionRequest(
      requests[index],
      '$goldenPath request $index',
    );
    if (!_deepEquals(declared, captured)) {
      throw FormatException(
        '$goldenPath request $index is not the corpus declaration',
      );
    }
  }
  final stages = authSessionRequestStages(corpus, phase, requests, goldenPath);
  final trace = _array(golden['stageTrace'], '$goldenPath stageTrace');
  if (trace.length != requests.length) {
    throw FormatException(
      '$goldenPath stageTrace has ${trace.length} entries for '
      '${requests.length} requests',
    );
  }
  for (var index = 0; index < trace.length; index++) {
    final entry = _object(trace[index], '$goldenPath stageTrace $index');
    if (entry['stage'] != stages[index]) {
      throw FormatException(
        '$goldenPath stageTrace $index is not request $index',
      );
    }
    final request = _object(requests[index], '$goldenPath request $index');
    final target = request['target'];
    if (target is! String || !target.startsWith('${request['path']}')) {
      throw FormatException(
        '$goldenPath request $index has no raw request line',
      );
    }
    if (entry['target'] != target) {
      throw FormatException(
        '$goldenPath stageTrace $index carries another request line',
      );
    }
    final listener = _text(request['listener'], '$goldenPath listener');
    final path = '${request['path']}';
    final expectedListener = _listenerForPath(corpus, path);
    if (listener != expectedListener) {
      throw FormatException(
        '$goldenPath request $index came from another origin',
      );
    }
    if (entry['listener'] != listener) {
      throw FormatException(
        '$goldenPath stageTrace $index names another listener',
      );
    }
  }
  if (_array(
    golden['unmatchedRequests'],
    '$goldenPath unmatchedRequests',
  ).isNotEmpty) {
    throw FormatException('$goldenPath recorded unmatched requests');
  }
  if (_array(
    golden['serverErrors'] ?? const [],
    '$goldenPath serverErrors',
  ).isNotEmpty) {
    throw FormatException('$goldenPath recorded replay-server errors');
  }

  final steps = authSessionSteps(corpus, phase);
  final observations = _array(
    golden['observations'],
    '$goldenPath observations',
  );
  if (observations.isEmpty || observations.length != steps.length) {
    throw FormatException(
      '$goldenPath holds ${observations.length} observations for '
      '${steps.length} corpus steps',
    );
  }
  for (var index = 0; index < steps.length; index++) {
    final row = _object(observations[index], '$goldenPath observation $index');
    if (row['id'] != steps[index]['id']) {
      throw FormatException(
        '$goldenPath observation $index is not ${steps[index]['id']}',
      );
    }
    if (!row.containsKey('value')) {
      throw FormatException(
        '$goldenPath observation ${row['id']} has no value',
      );
    }
    final value = _object(row['value'], '$goldenPath observation value');
    if (value.isEmpty) {
      throw FormatException(
        '$goldenPath observation ${row['id']} carries no fields',
      );
    }
  }

  // The device harness records the declared and actual request lines beside its
  // match verdict; both must be exactly the corpus declaration.
  final requestCheck = _object(
    golden['requestCheck'],
    '$goldenPath requestCheck',
  );
  final declaredLines = _array(
    requestCheck['declared'],
    '$goldenPath requestCheck.declared',
  );
  final actualLines = _array(
    requestCheck['actual'],
    '$goldenPath requestCheck.actual',
  );
  if (requestCheck['match'] != true ||
      requestCheck['orderMatch'] != true ||
      declaredLines.length != expected.length ||
      actualLines.length != expected.length ||
      _array(
        requestCheck['mismatches'] ?? const [],
        '$goldenPath requestCheck.mismatches',
      ).isNotEmpty ||
      !_isEmptyCount(requestCheck['unmatched']) ||
      !_isEmptyCount(requestCheck['serverErrors']) ||
      _array(
        requestCheck['forbiddenHeaders'] ?? const [],
        '$goldenPath requestCheck.forbiddenHeaders',
      ).isNotEmpty) {
    throw FormatException(
      '$goldenPath does not record a matched request trace',
    );
  }
  final observationCheck = _object(
    golden['observationCheck'],
    '$goldenPath observationCheck',
  );
  if (observationCheck['match'] != true ||
      observationCheck['ordered'] != true ||
      _array(observationCheck['missing'], 'missing').isNotEmpty ||
      _array(observationCheck['extra'], 'extra').isNotEmpty ||
      _array(observationCheck['duplicates'], 'duplicates').isNotEmpty) {
    throw FormatException(
      '$goldenPath does not record a complete observation set',
    );
  }
  _checkGoldenTerminal(golden, phase, goldenPath);
  _checkGoldenWebView(corpus, golden, goldenPath);

  if (handoff != null) {
    _checkHandoff(
      handoff: handoff,
      corpus: corpus,
      corpusSha256Lf: corpusSha256Lf,
      target: target,
      golden: golden,
      phase: phase,
      goldenSha256: goldenSha256,
    );
  }
}

/// The frozen harness' own terminal, cleanliness and ownership receipts. They
/// are the capture's proof that the phase it reports is the phase it ran, so a
/// capture without them is refused before any value is compared.
void _checkGoldenTerminal(
  Map<String, dynamic> golden,
  String phase,
  String goldenPath,
) {
  final cleanup = _object(golden['cleanup'], '$goldenPath cleanup');
  if (cleanup['databaseClosed'] != true) {
    throw FormatException('$goldenPath did not close its database');
  }
  final replay = _object(cleanup['replay'], '$goldenPath cleanup.replay');
  if (replay['ok'] != true ||
      replay['listenersClosed'] != true ||
      replay['workersStopped'] != true ||
      _array(replay['listenerClosure'], '$goldenPath listenerClosure').length !=
          2 ||
      _array(
        replay['listenerCloseErrors'],
        '$goldenPath closeErrors',
      ).isNotEmpty) {
    throw FormatException('$goldenPath did not close both replay listeners');
  }
  for (final raw in _array(replay['listenerClosure'], 'listenerClosure')) {
    final listener = _object(raw, '$goldenPath listenerClosure entry');
    if (listener['created'] != true || listener['closed'] != true) {
      throw FormatException('$goldenPath has an unclosed replay listener');
    }
  }
  final terminal = _object(cleanup['terminal'], '$goldenPath cleanup.terminal');
  if (terminal['ok'] != true ||
      terminal['requestMatch'] != true ||
      terminal['observationMatch'] != true ||
      _integer(terminal['unmatched'], 'terminal.unmatched') != 0 ||
      _integer(terminal['serverErrors'], 'terminal.serverErrors') != 0) {
    throw FormatException(
      '$goldenPath did not take a matched terminal snapshot',
    );
  }
  if (_text(cleanup['scratchRoot'], '$goldenPath scratchRoot').isEmpty) {
    throw FormatException('$goldenPath names no scratch root');
  }
  final isolation = _object(golden['isolation'], '$goldenPath isolation');
  if (isolation['deviceProtected'] != false) {
    throw FormatException('$goldenPath ran on device-protected storage');
  }
  if (phase == 'seed') {
    // The seed writes the owner manifest the restart validates, and names it.
    if (_text(cleanup['ownerFile'], '$goldenPath ownerFile').isEmpty) {
      throw FormatException('$goldenPath names no owner file');
    }
    if (cleanup['scratchRetained'] != true ||
        cleanup['scratchRemoved'] != false ||
        cleanup['ownership'] != 'created-fresh-root' ||
        isolation['scratchCreatedByThisRun'] != true ||
        isolation['scratchRootExistedAtStart'] != false) {
      throw FormatException('$goldenPath is not a fresh retained seed');
    }
    _checkOwnedPreferences(
      _array(cleanup['preferencesFenced'], 'preferencesFenced'),
      goldenPath,
      'fenced',
    );
  } else {
    if (cleanup['scratchRemoved'] != true ||
        cleanup['scratchRetained'] != false ||
        cleanup['ownership'] != 'validated-seed-owner' ||
        isolation['scratchCreatedByThisRun'] != false ||
        isolation['scratchRetainedFromSeed'] != true) {
      throw FormatException('$goldenPath is not a validated restart');
    }
    _checkOwnedPreferences(
      _array(cleanup['preferencesRemoved'], 'preferencesRemoved'),
      goldenPath,
      'removed',
    );
  }
}

void _checkOwnedPreferences(
  List<dynamic> entries,
  String goldenPath,
  String verb,
) {
  if (entries.isEmpty) {
    throw FormatException('$goldenPath records no $verb preference files');
  }
  for (final raw in entries) {
    final entry = _object(raw, '$goldenPath preference');
    _text(entry['name'], '$goldenPath preference name');
    if (entry['ok'] != true) {
      throw FormatException('$goldenPath did not $verb ${entry['name']}');
    }
  }
}

/// The provider containment receipt: the measured provider identity and the
/// approved paths under the scratch root. It is the frozen capture's proof that
/// `removeCookie` stayed inside the task's own profile, so a capture without it
/// is refused.
void _checkGoldenWebView(
  Map<String, dynamic> corpus,
  Map<String, dynamic> golden,
  String goldenPath,
) {
  final webView = _object(golden['webView'], '$goldenPath webView');
  if (webView['suffixFailure'] != null || webView['preflightFailure'] != null) {
    throw FormatException(
      '$goldenPath recorded a provider containment failure',
    );
  }
  final pinned = _object(corpus['webViewProvider'], 'webViewProvider');
  final preflight = _object(
    webView['preflight'],
    '$goldenPath webView.preflight',
  );
  final provider = _object(preflight['provider'], '$goldenPath provider');
  if (provider['package'] != pinned['package'] ||
      provider['versionName'] != pinned['versionName']) {
    throw FormatException('$goldenPath initialised another WebView provider');
  }
  final computed = _object(preflight['computed'], '$goldenPath computed paths');
  final actual = _object(preflight['actual'], '$goldenPath actual paths');
  for (final key in ['data', 'cache', 'textures']) {
    final value = _text(actual[key], '$goldenPath actual $key');
    if (value != computed[key]) {
      throw FormatException('$goldenPath resolved another $key path');
    }
  }
  final precheck = _object(
    golden['isolation']['webViewPathPrecheck'],
    '$goldenPath webViewPathPrecheck',
  );
  if (precheck['insideRoot'] != true) {
    throw FormatException(
      '$goldenPath claimed a provider path outside the root',
    );
  }
  final androidx = _object(
    preflight['androidxProcessGlobalConfig'],
    '$goldenPath androidxProcessGlobalConfig',
  );
  if (androidx['configSet'] != false ||
      androidx['dataDirectorySuffixKey'] != false) {
    throw FormatException('$goldenPath had a process-global path override');
  }
  if (preflight['deviceProtected'] != false) {
    throw FormatException('$goldenPath resolved a device-protected context');
  }
}

/// The host an origin serves: the corpus' own origin, never a wildcard.
String _listenerForPath(Map<String, dynamic> corpus, String path) {
  final origins = _object(corpus['origins'], 'origins');
  for (final entry in origins.entries) {
    final origin = Uri.parse('${entry.value}');
    if (path.startsWith(origin.path)) return origin.host;
  }
  throw FormatException('no corpus origin serves $path');
}

void _checkHandoff({
  required Map<String, dynamic> handoff,
  required Map<String, dynamic> corpus,
  required String corpusSha256Lf,
  required Map<String, dynamic> target,
  required Map<String, dynamic> golden,
  required String phase,
  required String? goldenSha256,
}) {
  if (handoff['status'] != 'captured') {
    throw const FormatException('the controller handoff is not captured');
  }
  for (final key in ['fixtureId', 'corpusVersion']) {
    if (handoff[key] != corpus[key]) {
      throw FormatException('the handoff names another corpus ($key)');
    }
  }
  for (final key in ['baselineCommit', 'entryPoint']) {
    if (handoff[key] != corpus[key]) {
      throw FormatException('the handoff names another $key');
    }
  }
  final pinned = _object(handoff['corpus'], 'handoff corpus');
  if (pinned['sha256Lf'] != corpusSha256Lf) {
    throw const FormatException('the handoff pins other corpus bytes');
  }
  final harness = _object(handoff['harness'], 'handoff harness');
  final identity = _object(golden['identity'], 'golden identity');
  if (harness['sha256'] != identity['harnessApkSha256']) {
    throw const FormatException('the handoff pins another harness APK');
  }
  if (harness['targetApkSha256'] != target['apkSha256'] ||
      harness['targetPackage'] != target['package']) {
    throw const FormatException('the handoff pins another frozen target');
  }
  final device = _object(handoff['device'], 'handoff device');
  if (device['fingerprint'] != golden['fingerprint']) {
    throw const FormatException('the handoff names another device');
  }
  final provider = _object(device['provider'], 'handoff provider');
  final captured = _object(
    golden['webView']['preflight'],
    'golden webView.preflight',
  );
  final capturedProvider = _object(captured['provider'], 'golden provider');
  if (provider['package'] != capturedProvider['package'] ||
      provider['version'] != capturedProvider['versionName']) {
    throw const FormatException('the handoff names another WebView provider');
  }
  final captures = _array(handoff['captures'], 'handoff captures');
  Map<String, dynamic>? record;
  for (final raw in captures) {
    final capture = _object(raw, 'handoff capture');
    final entry = capture[phase];
    if (entry is! Map) continue;
    if (entry['pid'] == golden['pid'] && entry['runId'] == golden['runId']) {
      record = entry.cast<String, dynamic>();
      break;
    }
  }
  if (record == null) {
    throw const FormatException('the handoff recorded another process');
  }
  final report = _object(record['report'], 'handoff report');
  if (goldenSha256 != null && report['sha256'] != goldenSha256) {
    throw const FormatException('the golden file is not the handoff capture');
  }
}

void checkAuthSessionGoldenPair({
  required Map<String, dynamic> corpus,
  required String corpusSha256Lf,
  required Map<String, dynamic> seed,
  required Map<String, dynamic> restart,
  Map<String, dynamic>? handoff,
  String? seedSha256,
  String? restartSha256,
  String seedPath = 'seed-report.json',
  String restartPath = 'restart-report.json',
}) {
  checkAuthSessionGolden(
    corpus: corpus,
    corpusSha256Lf: corpusSha256Lf,
    golden: seed,
    phase: 'seed',
    handoff: handoff,
    goldenSha256: seedSha256,
    goldenPath: seedPath,
  );
  checkAuthSessionGolden(
    corpus: corpus,
    corpusSha256Lf: corpusSha256Lf,
    golden: restart,
    phase: 'restart',
    handoff: handoff,
    goldenSha256: restartSha256,
    goldenPath: restartPath,
  );
  if (seed['pid'] == restart['pid']) {
    throw const FormatException('seed and restart are the same process');
  }
  if (seed['runId'] == restart['runId']) {
    throw const FormatException('seed and restart are the same run');
  }
  final seedIdentity = _object(seed['identity'], 'seed identity');
  final restartIdentity = _object(restart['identity'], 'restart identity');
  for (final key in [
    'fixtureId',
    'corpusVersion',
    'targetPackage',
    'targetApkSha256',
    'targetBaselineCommit',
    'corpusAssetSha256',
    'corpusSha256Lf',
    'harnessPackage',
    'harnessApkSha256',
    'targetPinManifest',
  ]) {
    if (seedIdentity[key] != restartIdentity[key]) {
      throw FormatException('the two captures disagree on $key');
    }
  }
  final seedAt = DateTime.parse('${seed['recordedAt']}');
  final restartAt = DateTime.parse('${restart['recordedAt']}');
  if (!restartAt.isAfter(seedAt)) {
    throw const FormatException('the restart did not happen after the seed');
  }
}

// --------------------------------------------------------------------------
// Comparison
// --------------------------------------------------------------------------

/// One mismatch row's identity: its surface plus the row, index, header, field
/// or path that says which request, observation or receipt it is. A control
/// compares these keys with its own baseline, so a difference that already
/// existed cannot stand in for the difference the control introduced.
String mismatchKey(Map<dynamic, dynamic> mismatch) {
  final parts = <String>['${mismatch['surface']}'];
  for (final field in ['phase', 'index', 'header', 'field', 'id', 'path']) {
    final value = mismatch[field];
    if (value != null) parts.add('$value');
  }
  return parts.join('|');
}

/// Semantic JSON equality: object member order is ignored, array order and every
/// primitive are exact, and a missing key is not an empty value.
bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final key in left.keys) {
      if (!right.containsKey(key) || !_deepEquals(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  return left == right;
}

/// One field's difference between two compared maps, with each side's presence
/// kept: an explicit `null` and an absent key are different observations, so a
/// dropped nullable field fails instead of matching a null.
const absentField = '<absent>';

Map<String, Map<String, Object?>> _changedFields(Map expected, Map actual) => {
  for (final key in {...expected.keys, ...actual.keys})
    if (expected.containsKey(key) != actual.containsKey(key) ||
        !_deepEquals(expected[key], actual[key]))
      '$key': {
        'expected': expected.containsKey(key) ? expected[key] : absentField,
        'observed': actual.containsKey(key) ? actual[key] : absentField,
        if (expected.containsKey(key) != actual.containsKey(key))
          'presence': expected.containsKey(key)
              ? 'expected-only'
              : 'observed-only',
      },
};

/// A declared `[name, value]` pair list, or null when the field is absent or
/// has another shape. The list order is kept: the frozen harness records the
/// pairs sorted, so a different order is a different observation.
List<List<String>>? _declaredPairs(Object? value) {
  if (value is! List) return null;
  final pairs = <List<String>>[];
  for (final entry in value) {
    if (entry is! List || entry.length != 2) return null;
    if (entry[0] is! String || entry[1] is! String) return null;
    pairs.add(['${entry[0]}', '${entry[1]}']);
  }
  return pairs;
}

/// A pair list in the frozen harness' own rendering order: by name, then value.
List<List<String>> _sortedPairs(List<List<String>> pairs) =>
    [...pairs]..sort((left, right) {
      final byName = left[0].compareTo(right[0]);
      return byName != 0 ? byName : left[1].compareTo(right[1]);
    });

/// Whether a map is one source's cookie probe. The identity fields decide it, so
/// a probe whose mandatory `keys`/`persistent`/`session` field was dropped is
/// still compared as a probe and fails on that field instead of falling out of
/// the probe comparison entirely.
bool _looksLikeCookieProbe(Map value) =>
    value.containsKey('url') && value.containsKey('domain');

/// Compares one cookie probe and, where the frozen and product effective cookie
/// values differ only in the order of the same pairs, records that as a named
/// order-only difference instead of hiding it. Any name or value difference is
/// a mismatch.
void _compareCookieProbe({
  required Map expected,
  required Map actual,
  required String path,
  required List<Map<String, Object?>> mismatches,
  required List<Map<String, Object?>> notCompared,
  required List<Map<String, Object?>> orderOnly,
  required String phase,
  required Map<String, List<List<String>>> seedSessionPairs,
  String? sourceId,
}) {
  final changed = _changedFields(expected, actual);
  for (final key in changed.keys) {
    // `effective` has its own order-aware comparison below, `keys` is compared
    // against the frozen pair map below, and `persistent`/`session` are the
    // carried tier divergence. Every other declared field of a probe — the URL,
    // the domain key and both login-header values — is compared strictly.
    if (key == 'effective' ||
        key == 'keys' ||
        key == 'persistent' ||
        key == 'session') {
      continue;
    }
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie',
      'path': '$path.$key',
      'expected': changed[key]!['expected'],
      'observed': changed[key]!['observed'],
    });
  }
  // The declared `keys` field and the effective value, read exactly as the
  // capture records them. The product jar has one storage shape, so a *restart*
  // probe may carry exactly the session pairs the seed recorded for that source
  // — the approved session-cookie restart row — and nothing else. No seed
  // observation gets that allowance.
  final restart = phase == 'restart';
  final seedSession = restart
      ? (seedSessionPairs[sourceId] ?? const <List<String>>[])
      : const <List<String>>[];
  final expectedKeys = expected.containsKey('keys')
      ? _declaredPairs(expected['keys'])
      : null;
  final actualKeys = actual.containsKey('keys')
      ? _declaredPairs(actual['keys'])
      : null;
  final expectedEffective = expected['effective'];
  final actualEffective = actual['effective'];
  final expectedPairs = expectedEffective is String
      ? authSessionCookiePairs(expectedEffective)
      : null;
  final actualPairs = actualEffective is String
      ? authSessionCookiePairs(actualEffective)
      : null;
  final allowedPairs = expectedPairs == null
      ? null
      : _sortedPairs([
          for (final pair in [...expectedPairs, ...seedSession]) pair,
        ]);

  // 1. `keys` is a declared observation of its own: presence, type, order and
  //    contents. A missing, null or malformed side fails by name.
  if (expectedKeys == null || actualKeys == null) {
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie',
      'path': '$path.keys',
      'expected': expected.containsKey('keys') ? expected['keys'] : '<absent>',
      'observed': actual.containsKey('keys') ? actual['keys'] : '<absent>',
      'detail':
          'the declared keys field must be a list of [name, value] string '
          'pairs on both sides',
    });
  } else {
    // 2. Each side's declared pairs must agree with its own effective value:
    //    recomputing one from the other cannot stand in for the field.
    for (final entry in <String, (List<List<String>>, List<List<String>>)>{
      'expected': (expectedKeys, expectedPairs ?? const <List<String>>[]),
      'observed': (actualKeys, actualPairs ?? const <List<String>>[]),
    }.entries) {
      final declared = _sortedPairs(entry.value.$1);
      final fromEffective = _sortedPairs(entry.value.$2);
      if (!_deepEquals(declared, fromEffective)) {
        mismatches.add({
          'phase': phase,
          'surface': 'observation-cookie',
          'path': '$path.keys',
          'expected': expectedKeys,
          'observed': actualKeys,
          'detail':
              'the ${entry.key} declared keys disagree with its own effective '
              'value: $declared vs $fromEffective',
        });
      }
    }
    // 3. The two sides' declared pair maps, in their declared order.
    if (!_deepEquals(expectedKeys, actualKeys)) {
      if (restart &&
          _deepEquals(_sortedPairs(actualKeys), allowedPairs) &&
          _deepEquals(actualKeys, _sortedPairs(actualKeys))) {
        notCompared.add({
          'phase': phase,
          'row': 'session-tier',
          'path': '$path.keys',
          'expected': expectedKeys,
          'observed': actualKeys,
          'reason':
              'the approved session-cookie restart row: the frozen session '
              'pair is gone from its own storage at this point, and the product '
              'jar keeps the seed-recorded session pairs in its one map. The '
              'extras must be exactly the recorded seed session pairs for this '
              'source.',
        });
      } else {
        mismatches.add({
          'phase': phase,
          'surface': 'observation-cookie',
          'path': '$path.keys',
          'expected': expectedKeys,
          'observed': actualKeys,
        });
      }
    }
  }

  // 4. The effective value keeps its observable string type. Null, absent or
  //    non-string evidence is a failure of the field, never an empty pair set.
  if (expectedEffective is! String || actualEffective is! String) {
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie',
      'path': '$path.effective',
      'expected': expected.containsKey('effective')
          ? expectedEffective
          : '<absent>',
      'observed': actual.containsKey('effective')
          ? actualEffective
          : '<absent>',
      'detail': 'the effective value must be a string on both sides',
    });
  } else if (expectedEffective == actualEffective) {
    // The strict answer: identical bytes carry identical pairs.
  } else if (_deepEquals(expectedPairs, actualPairs)) {
    orderOnly.add({
      'phase': phase,
      'path': '$path.effective',
      'expected': expectedEffective,
      'observed': actualEffective,
      'pairsEqual': true,
      'note':
          'the same name/value pairs in another order: the frozen '
          'CookieStore.getCookie merges the persistent map before the '
          'session map, and the product jar keeps one insertion-ordered map '
          '(the recorded ADR 0011 §3 single-storage-shape divergence)',
    });
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie-order',
      'path': '$path.effective',
      'expected': expectedEffective,
      'observed': actualEffective,
    });
  } else if (restart && _deepEquals(allowedPairs, actualPairs)) {
    notCompared.add({
      'phase': phase,
      'row': 'session-tier',
      'path': '$path.effective',
      'expected': expectedEffective,
      'observed': actualEffective,
      'reason':
          'the approved session-cookie restart row: the frozen session pair '
          'is gone from its own storage at this point, and the product jar '
          'keeps the seed-recorded session pairs in its one map. The extras '
          'must be exactly the recorded seed session pairs for this source.',
    });
  } else {
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie',
      'path': '$path.effective',
      'expected': expectedEffective,
      'observed': actualEffective,
    });
  }
  // The product's own tier claim: one storage shape, so its persistent map is
  // the effective value and it has no session map. Both fields are mandatory
  // measurements, so a dropped field cannot pass as an explicit null: the
  // product must carry `persistent` equal to its string `effective` and
  // `session` present and null.
  final claimsOneTier =
      actual.containsKey('persistent') &&
      actual.containsKey('session') &&
      actual['persistent'] == actual['effective'] &&
      actual['session'] == null;
  if (!claimsOneTier) {
    mismatches.add({
      'phase': phase,
      'surface': 'observation-cookie-tier',
      'path': path,
      'expected':
          'persistent present and equal to effective, session present and null',
      'observed': {
        'persistent': actual.containsKey('persistent')
            ? actual['persistent']
            : '<absent>',
        'session': actual.containsKey('session')
            ? actual['session']
            : '<absent>',
        'effective': actual.containsKey('effective')
            ? actual['effective']
            : '<absent>',
      },
    });
  }
  if (!_deepEquals(expected['persistent'], actual['persistent']) ||
      !_deepEquals(expected['session'], actual['session'])) {
    notCompared.add({
      'phase': phase,
      'row': 'session-tier',
      'path': path,
      'expected': {
        'persistent': expected['persistent'],
        'session': expected['session'],
      },
      'observed': {
        'persistent': actual['persistent'],
        'session': actual['session'],
      },
      'reason':
          'book-source-differential-contract.md, known divergences: a '
          'non-persistent Set-Cookie lives in process memory only in the '
          'frozen baseline, and the product jar has one storage shape '
          '(ADR 0011 §3). The effective pair map is still compared strictly.',
    });
  }
}

/// The session pairs the seed capture recorded per source, from its final state
/// observation. Empty when the seed kept none, which makes the restart
/// comparison strict again for that source.
Map<String, List<List<String>>> _seedSessionPairs(Map<String, dynamic> seed) {
  final result = <String, List<List<String>>>{};
  for (final raw in (seed['observations'] as List? ?? const [])) {
    if (raw is! Map || raw['id'] != 'seed.state.seed') continue;
    final value = raw['value'];
    if (value is! Map) continue;
    final sessions = value['sessions'];
    if (sessions is! Map) continue;
    for (final entry in sessions.entries) {
      final text = entry.value;
      if (text is! String || text.isEmpty) continue;
      result['${entry.key}'] = authSessionCookiePairs(text);
    }
  }
  return result;
}

/// Compares one observation's declared fields. A cookie probe's tiers are the
/// recorded divergence; every other field, type and order is strict.
void _compareObservation({
  required Map<String, dynamic> corpus,
  required Map expected,
  required Map actual,
  required String phase,
  required String id,
  required List<Map<String, Object?>> mismatches,
  required List<Map<String, Object?>> notCompared,
  required List<Map<String, Object?>> orderOnly,
  required Map<String, List<List<String>>> seedSessionPairs,
}) {
  if (!_deepEquals(expected['kind'], actual['kind'])) {
    mismatches.add({
      'phase': phase,
      'surface': 'observation-kind',
      'id': id,
      'expected': expected['kind'],
      'observed': actual['kind'],
    });
    return;
  }
  final expectedRest = Map<String, Object?>.from(expected);
  final actualRest = Map<String, Object?>.from(actual);
  final probes = <String>[];
  for (final key in expectedRest.keys.toList()) {
    final value = expectedRest[key];
    if (value is Map && _looksLikeCookieProbe(value)) probes.add(key);
  }
  // A probe's own source: the observation's `source`, or the key a cookie-state
  // or state map files it under.
  final observationSource = expected['source'] is String
      ? '${expected['source']}'
      : null;
  for (final key in probes) {
    final expectedProbe = _object(expectedRest.remove(key), 'probe');
    final actualProbe = _object(actualRest.remove(key), 'probe');
    _compareCookieProbe(
      expected: expectedProbe,
      actual: actualProbe,
      sourceId: observationSource ?? (probes.length == 1 ? null : key),
      path: '$id.$key',
      mismatches: mismatches,
      notCompared: notCompared,
      orderOnly: orderOnly,
      phase: phase,
      seedSessionPairs: seedSessionPairs,
    );
  }
  // A state observation carries one cookie probe per source; each is compared
  // with the probe rules instead of as an opaque nested map.
  final stateCrumbs = expectedRest['cookies'];
  if (stateCrumbs is Map && actualRest['cookies'] is Map) {
    final expectedProbes = _object(expectedRest.remove('cookies'), 'cookies');
    final actualProbes = _object(actualRest.remove('cookies'), 'cookies');
    for (final key in expectedProbes.keys) {
      final expectedProbe = expectedProbes[key];
      final actualProbe = actualProbes[key];
      if (expectedProbe is Map &&
          actualProbe is Map &&
          _looksLikeCookieProbe(expectedProbe) &&
          _looksLikeCookieProbe(actualProbe)) {
        _compareCookieProbe(
          expected: expectedProbe,
          actual: actualProbe,
          path: '$id.cookies.$key',
          sourceId: key,
          mismatches: mismatches,
          notCompared: notCompared,
          orderOnly: orderOnly,
          phase: phase,
          seedSessionPairs: seedSessionPairs,
        );
      } else {
        mismatches.add({
          'phase': phase,
          'surface': 'observation',
          'id': id,
          'field': 'cookies.$key',
          'expected': expectedProbe,
          'observed': actualProbe,
        });
      }
    }
    for (final key in actualProbes.keys) {
      if (expectedProbes.containsKey(key)) continue;
      mismatches.add({
        'phase': phase,
        'surface': 'observation',
        'id': id,
        'field': 'cookies.$key',
        'expected': null,
        'observed': actualProbes[key],
      });
    }
  }
  // `sessions` is the frozen CookieManager's process-memory map, which the
  // product has no counterpart for: the same divergence row as a probe's tiers.
  final expectedSessions = expectedRest.remove('sessions');
  final actualSessions = actualRest.remove('sessions');
  if (expectedSessions != null || actualSessions != null) {
    notCompared.add({
      'phase': phase,
      'row': 'session-tier',
      'path': '$id.sessions',
      'expected': expectedSessions,
      'observed': actualSessions,
      'reason':
          'the frozen CookieManager keeps session cookies in process memory '
          '(CookieManager.kt:42-53); the product jar has one storage shape '
          '(ADR 0011 §3)',
    });
  }
  // `webViewInitialized` is the frozen harness' provider setup: it is the
  // native capture's containment receipt, not a browser-parity value.
  expectedRest.remove('webViewInitialized');
  actualRest.remove('webViewInitialized');
  if (!_deepEquals(expectedRest, actualRest)) {
    final changed = _changedFields(expectedRest, actualRest);
    for (final entry in changed.entries) {
      mismatches.add({
        'phase': phase,
        'surface': 'observation',
        'id': id,
        'field': entry.key,
        'expected': entry.value['expected'],
        'observed': entry.value['observed'],
      });
    }
  }
}

/// The approved field-specific wire difference: the frozen login header wins a
/// key the source's static `header` rule declares too, while the product merges
/// the login header under the request's own headers (capability matrix,
/// `login header precedence`). The entry pins both sides' values, so any other
/// value is a mismatch.
Map<String, Object?>? _approvedLoginHeaderPrecedence({
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> step,
  required String key,
  required String expected,
  required String actual,
}) {
  final sourceId = '${step['source']}';
  final source = authSessionSourceOf(corpus, sourceId);
  final object = _object(source['bookSource'], 'source bookSource');
  final header = object['header'];
  if (header is! String) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(header);
  } on FormatException {
    return null;
  }
  if (decoded is! Map) return null;
  final declared = <String, String>{};
  for (final entry in decoded.entries) {
    declared['${entry.key}'.toLowerCase()] = '${entry.value}';
  }
  if (!declared.containsKey(key)) return null;
  if (actual != declared[key]) return null;
  if (expected == actual) return null;
  return {
    'row': 'login-header-precedence',
    'path': '${step['id']}',
    'header': key,
    'expected': expected,
    'observed': actual,
    'staticHeader': declared[key],
    'reason':
        'capability matrix, login flow and login headers: the frozen login '
        'header is merged last and wins a key the static header rule also '
        'declares; the product merges it under the request\'s own headers '
        '(lib/source/source_host_dispatcher.dart, _send)',
  };
}

/// Compares the product's ordered `stageTrace` with the validated capture's and
/// with the product's own requests: every entry is a map with exactly the three
/// causal keys, and its stage, listener and raw target are the same ones the
/// capture recorded and the request at that position actually made. A forged or
/// reordered trace of the same length fails here.
void _compareStageTrace({
  required Map<String, dynamic> golden,
  required Map<String, dynamic> product,
  required String phase,
  required List<Map<String, Object?>> mismatches,
  required String productPath,
}) {
  const keys = {'stage', 'listener', 'target'};
  final goldenTrace = _array(golden['stageTrace'], 'golden stageTrace');
  final actualTrace = product['stageTrace'];
  final requests = product['requests'];
  if (actualTrace is! List ||
      requests is! List ||
      actualTrace.length != goldenTrace.length ||
      actualTrace.length != requests.length) {
    mismatches.add({
      'phase': phase,
      'surface': 'product-stage-trace',
      'expected': '${goldenTrace.length} causal entries',
      'observed': actualTrace is List
          ? '${actualTrace.length} entries for ${requests is List ? requests.length : '?'} requests'
          : absentField,
    });
    return;
  }
  for (var index = 0; index < actualTrace.length; index++) {
    final entry = actualTrace[index];
    final expected = _object(goldenTrace[index], 'golden stageTrace $index');
    final request = _object(requests[index], '$productPath request $index');
    String? failure;
    if (entry is! Map) {
      failure = 'the entry is not a map';
    } else if (entry.keys.toSet().length != keys.length ||
        !keys.containsAll(entry.keys.cast<String>())) {
      failure = 'the entry does not carry exactly stage, listener and target';
    } else if (entry['stage'] is! String ||
        entry['listener'] is! String ||
        entry['target'] is! String) {
      failure = 'the entry values are not strings';
    } else if (entry['stage'] != expected['stage'] ||
        entry['listener'] != expected['listener'] ||
        entry['target'] != expected['target']) {
      failure = 'the entry is not the captured causal entry';
    } else if (entry['stage'] != request['stage'] ||
        entry['listener'] != request['listener'] ||
        entry['target'] != request['target']) {
      failure = 'the entry does not belong to its own request';
    }
    if (failure != null) {
      mismatches.add({
        'phase': phase,
        'surface': 'product-stage-trace',
        'index': index,
        'expected': expected,
        'observed': entry is Map
            ? {for (final key in entry.keys) '$key': entry[key]}
            : entry,
        'detail': failure,
      });
    }
  }
}

/// The bounded restart-session wire attribution: null unless removing the
/// exact, wholly recognised session-only segments from the actual header leaves
/// the native expected header byte for byte.
///
/// The segments here are raw wire text, never parsed and re-rendered: the split
/// keeps every segment's own spelling (an empty one, a leading space, a value
/// with a trailing space included) and nothing is trimmed or skipped. An
/// attributable addition is one whole `;`-separated segment whose text is
/// exactly `<name>=<value>` for a recorded session pair — a leading segment
/// carries no separator of its own, so it is matched without the leading space.
/// Each recorded pair may be attributed once. Any other segment, a changed
/// separator, an empty segment or an unattributed session pair leaves the
/// remainder different from the expected header, so the row stays a mismatch.
Map<String, Object?>? _restartSessionWireRow({
  required String expectedHeader,
  required String actualHeader,
  required List<List<String>> sessionPairs,
}) {
  if (sessionPairs.isEmpty) return null;
  final pool = <String>[
    for (final pair in sessionPairs) '${pair[0]}=${pair[1]}',
  ];
  final actualSegments = actualHeader.split(';');
  final attributed = <List<String>>[];
  final attributedSegments = <String>[];
  final remainingSegments = <String>[];
  for (var index = 0; index < actualSegments.length; index++) {
    final segment = actualSegments[index];
    final bare = index == 0
        ? segment
        : (segment.startsWith(' ') ? segment.substring(1) : null);
    final poolIndex = bare == null ? -1 : pool.indexOf(bare);
    if (poolIndex >= 0) {
      final pair = pool.removeAt(poolIndex);
      final split = pair.indexOf('=');
      attributed.add([pair.substring(0, split), pair.substring(split + 1)]);
      attributedSegments.add(segment);
      continue;
    }
    remainingSegments.add(segment);
  }
  if (pool.isNotEmpty) return null;
  if (remainingSegments.join(';') != expectedHeader) return null;
  return {
    'row': 'session-tier',
    'kind': 'restart-session-cookie-wire',
    'attributed': attributed,
    'attributedSegments': attributedSegments,
    'frozenHeader': expectedHeader,
    'reason':
        'the existing session-cookie restart divergence '
        '(book-source-differential-contract.md:132): the frozen baseline keeps a '
        'non-persistent Set-Cookie in process memory only, so it is gone after '
        'the restart, while the product jar keeps the seed-recorded session '
        'pairs in its one map. Only those exact pairs are attributed; every '
        'frozen byte, separator and order is kept, and no other wire text is '
        'normalised away.',
  };
}

/// Compares one phase's request trace: the causal order, the method, the raw
/// target and the source-controlled headers. The corpus declares the method,
/// path and raw query bytes of every request in order, so a reordered,
/// re-encoded, extra or missing request fails here.
void _compareRequests({
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> golden,
  required Map<String, dynamic> product,
  required String phase,
  required List<Map<String, Object?>> mismatches,
  required List<Map<String, Object?>> notCompared,
  required List<Map<String, Object?>> orderOnly,
  required String productPath,
  required Map<String, List<List<String>>> seedSessionPairs,
}) {
  final expected = authSessionExpectedRequests(corpus, phase);
  final productRequests = _array(product['requests'], '$productPath requests');
  if (productRequests.length != expected.length) {
    mismatches.add({
      'phase': phase,
      'surface': 'product-requests',
      'detail':
          '${productRequests.length} requests, ${expected.length} declared',
    });
  }
  // The requests the product did make are always compared index by index: a
  // phase that stopped early still reports which of its requests differ, so a
  // control can show a difference from its own baseline rather than hiding
  // behind the count.
  final compared = productRequests.length < expected.length
      ? productRequests.length
      : expected.length;
  final steps = authSessionSteps(corpus, phase);
  final stepById = {for (final step in steps) '${step['id']}': step};
  final goldenRequests = _array(golden['requests'], 'golden requests');
  for (var index = 0; index < compared; index++) {
    final declared = normalizeAuthSessionRequest(
      expected[index],
      'declared request $index',
    );
    final productRow = _object(
      productRequests[index],
      '$productPath request $index',
    );
    // A product request with no raw query bytes is a difference this comparer
    // reports, not a capture it refuses: the corpus declared the bytes.
    final rawQuery = productRow['rawQuery'];
    if (rawQuery is! String) {
      mismatches.add({
        'phase': phase,
        'surface': 'product-requests',
        'index': index,
        'expected': declared,
        'observed': {
          'method': productRow['method'],
          'path': productRow['path'],
          'rawQuery': rawQuery,
        },
        'detail': 'the request carries no raw query bytes',
      });
      continue;
    }
    final captured = normalizeAuthSessionRequest(
      productRow,
      '$productPath request $index',
    );
    if (!_deepEquals(declared, captured)) {
      mismatches.add({
        'phase': phase,
        'surface': 'product-requests',
        'index': index,
        'expected': declared,
        'observed': captured,
      });
      continue;
    }
    final productRequest = _object(
      productRequests[index],
      '$productPath request $index',
    );
    final goldenRequest = _object(
      goldenRequests[index],
      'golden request $index',
    );
    final productTarget = productRequest['target'];
    if (productTarget != goldenRequest['target']) {
      mismatches.add({
        'phase': phase,
        'surface': 'product-request-target',
        'index': index,
        'expected': goldenRequest['target'],
        'observed': productTarget,
      });
    }
    final expectedHeaders = comparedAuthSessionHeaders(
      goldenRequest['headers'],
      'golden request $index',
    );
    final actualHeaders = comparedAuthSessionHeaders(
      productRequest['headers'],
      '$productPath request $index',
    );
    for (final entry in expectedHeaders.entries) {
      final actual = actualHeaders[entry.key];
      if (actual == null) {
        mismatches.add({
          'phase': phase,
          'surface': 'product-request-headers',
          'index': index,
          'header': entry.key,
          'expected': entry.value,
          'observed': null,
        });
        continue;
      }
      if (_deepEquals(entry.value, actual)) continue;
      if (entry.key == 'cookie' &&
          entry.value.length == 1 &&
          actual.length == 1 &&
          _deepEquals(
            authSessionCookiePairs(entry.value.single),
            authSessionCookiePairs(actual.single),
          )) {
        // The same outbound pairs in another order. The raw wire value is
        // strict, so this stays a failure; both strings and the semantic map
        // equality are kept so the difference is not hidden or sorted away.
        orderOnly.add({
          'phase': phase,
          'path': 'requests[$index].headers.cookie',
          'request': '${productRequest['target']}',
          'expected': entry.value.single,
          'observed': actual.single,
          'pairsEqual': true,
          'note':
              'the same name/value pairs in another order: the frozen '
              'CookieStore.getCookie merges the persistent map before the '
              'session map, and the product jar keeps one insertion-ordered '
              'map (the recorded ADR 0011 §3 single-storage-shape divergence); '
              'the raw wire value stays compared and this is a failure',
        });
      }
      final step = stepById['${productRequest['stage']}'];
      // The existing session-cookie restart divergence
      // (`book-source-differential-contract.md:132`): a genuine restart wire
      // header may carry exactly the session-only pairs the validated native
      // seed capture recorded for that same source, with every frozen pair kept
      // at its own value and order. Everything else stays strict.
      if (entry.key == 'cookie' &&
          phase == 'restart' &&
          entry.value.length == 1 &&
          actual.length == 1 &&
          step != null) {
        final sourceId = '${step['source']}';
        final attribution = _restartSessionWireRow(
          expectedHeader: entry.value.single,
          actualHeader: actual.single,
          sessionPairs: seedSessionPairs[sourceId] ?? const <List<String>>[],
        );
        if (attribution != null) {
          notCompared.add({
            ...attribution,
            'phase': phase,
            'index': index,
            'source': sourceId,
            'request': '${productRequest['target']}',
            'expected': entry.value.single,
            'observed': actual.single,
          });
          continue;
        }
      }
      final approved = step == null
          ? null
          : _approvedLoginHeaderPrecedence(
              corpus: corpus,
              step: step,
              key: entry.key,
              expected: entry.value.join(', '),
              actual: actual.join(', '),
            );
      if (approved != null) {
        notCompared.add({
          ...approved,
          'phase': phase,
          'index': index,
          'request': '${productRequest['target']}',
        });
        continue;
      }
      mismatches.add({
        'phase': phase,
        'surface': 'product-request-headers',
        'index': index,
        'header': entry.key,
        'expected': entry.value,
        'observed': actual,
      });
    }
    for (final entry in actualHeaders.entries) {
      if (expectedHeaders.containsKey(entry.key)) continue;
      mismatches.add({
        'phase': phase,
        'surface': 'product-request-headers',
        'index': index,
        'header': entry.key,
        'expected': null,
        'observed': entry.value,
      });
    }
    if (!_deepEquals(goldenRequest['body'], productRequest['body'])) {
      mismatches.add({
        'phase': phase,
        'surface': 'product-request-body',
        'index': index,
        'expected': goldenRequest['body'],
        'observed': productRequest['body'],
      });
    }
  }
  // The forbidden internal marker must not reach the wire on either side.
  for (final raw in _array(
    _object(corpus['requestChecks'], 'requestChecks')['forbiddenHeaders'],
    'forbiddenHeaders',
  )) {
    final name = '$raw'.toLowerCase();
    for (final request in productRequests) {
      final headers = comparedAuthSessionHeaders(
        _object(request, 'product request')['headers'],
        'product request headers',
      );
      if (headers.containsKey(name)) {
        mismatches.add({
          'phase': phase,
          'surface': 'product-request-headers',
          'detail': 'the internal $name marker reached the wire',
        });
      }
    }
  }
}

/// Compares the two real product phases with the validated frozen captures.
/// Structural problems with a capture throw; a difference between the actual
/// product and the capture is recorded as a failed row.
Map<String, Object?> compareAuthSessionPhases({
  required Map<String, dynamic> corpus,
  required String corpusSha256Lf,
  required Map<String, dynamic> seedGolden,
  required Map<String, dynamic> restartGolden,
  required Map<String, dynamic> seedProduct,
  required Map<String, dynamic> restartProduct,
  String? librarySha256,
  Map<String, dynamic>? handoff,
  String? seedGoldenSha256,
  String? restartGoldenSha256,
  String seedGoldenPath = 'seed-report.json',
  String restartGoldenPath = 'restart-report.json',
  String seedProductPath = 'seed-product.json',
  String restartProductPath = 'restart-product.json',
  int? seedExitCode,
  int? restartExitCode,
}) {
  checkAuthSessionGoldenPair(
    corpus: corpus,
    corpusSha256Lf: corpusSha256Lf,
    seed: seedGolden,
    restart: restartGolden,
    handoff: handoff,
    seedSha256: seedGoldenSha256,
    restartSha256: restartGoldenSha256,
    seedPath: seedGoldenPath,
    restartPath: restartGoldenPath,
  );
  final target = authSessionTargetOf(corpus);
  // The session pairs the frozen seed capture recorded for each source: the
  // product's single tier keeps exactly these across the restart, which is the
  // approved session-cookie restart row.
  final seedSessionPairs = _seedSessionPairs(seedGolden);
  final mismatches = <Map<String, Object?>>[];
  final notCompared = <Map<String, Object?>>[];
  final orderOnly = <Map<String, Object?>>[];
  final checks = <String, Object?>{};

  void check(
    String name,
    bool passed,
    Object? detail, {
    String phase = 'pair',
  }) {
    checks[name] = {'ok': passed, 'detail': detail};
    if (!passed) {
      mismatches.add({'phase': phase, 'surface': name, 'detail': detail});
    }
  }

  check(
    'genuine-restart',
    seedProduct['pid'] != restartProduct['pid'] &&
        seedProduct['runId'] != restartProduct['runId'],
    'seed pid ${seedProduct['pid']} run ${seedProduct['runId']}; restart pid '
        '${restartProduct['pid']} run ${restartProduct['runId']}',
  );
  if (seedExitCode != null) {
    check(
      'seed-process-exited',
      seedExitCode == 0,
      'seed runner exit code $seedExitCode',
    );
  }
  if (restartExitCode != null) {
    check(
      'restart-process-exited',
      restartExitCode == 0,
      'restart runner exit code $restartExitCode',
    );
  }

  final productLibraryHashes = <Object?>[];
  for (final entry in <String, Map<String, dynamic>>{
    'seed': seedProduct,
    'restart': restartProduct,
  }.entries) {
    final phase = entry.key;
    final report = entry.value;
    final path = phase == 'seed' ? seedProductPath : restartProductPath;
    final golden = phase == 'seed' ? seedGolden : restartGolden;
    if (report['phase'] != phase) {
      throw FormatException('$path is not the $phase product report');
    }
    for (final key in ['fixtureId', 'corpusVersion']) {
      if (report[key] != corpus[key]) {
        throw FormatException('$path does not describe this corpus ($key)');
      }
    }
    for (final key in ['baselineCommit', 'entryPoint']) {
      if (report[key] != corpus[key]) {
        throw FormatException('$path names another $key');
      }
    }
    check(
      'product-status-$phase',
      report['status'] == 'completed',
      'status ${report['status']}${report['analysisFailure'] == null ? '' : ': ${report['analysisFailure']}'}',
      phase: phase,
    );
    // A completed phase carries a clean terminal receipt: `serverErrors` present
    // and empty, `analysisFailure` present and explicitly null.
    final serverErrors = report['serverErrors'];
    check(
      'product-terminal-$phase',
      report.containsKey('serverErrors') &&
          serverErrors is List &&
          serverErrors.isEmpty &&
          report.containsKey('analysisFailure') &&
          report['analysisFailure'] == null,
      {
        'serverErrors': report.containsKey('serverErrors')
            ? serverErrors
            : absentField,
        'analysisFailure': report.containsKey('analysisFailure')
            ? report['analysisFailure']
            : absentField,
      },
      phase: phase,
    );
    final identity = _object(report['identity'], '$path identity');
    check(
      'product-corpus-identity-$phase',
      identity['corpusSha256Lf'] == corpusSha256Lf &&
          _isSha256(identity['corpusRawSha256']) &&
          identity['fixtureId'] == corpus['fixtureId'] &&
          identity['corpusVersion'] == corpus['corpusVersion'],
      'corpus ${identity['corpusSha256Lf']}',
      phase: phase,
    );
    final pinned = _object(identity['target'], '$path identity.target');
    check(
      'product-target-identity-$phase',
      pinned['package'] == target['package'] &&
          pinned['apkSha256'] == target['apkSha256'] &&
          pinned['baselineCommit'] == target['baselineCommit'] &&
          pinned['manifest'] == target['manifest'],
      'target ${pinned['package']} ${pinned['apkSha256']}',
      phase: phase,
    );
    final library = _object(identity['library'], '$path identity.library');
    final libraryHash = library['sha256'];
    productLibraryHashes.add(libraryHash);
    check(
      'product-library-identity-$phase',
      _isSha256(libraryHash) &&
          (librarySha256 == null || libraryHash == librarySha256),
      'library ${library['path']} $libraryHash',
      phase: phase,
    );
    check(
      'product-process-identity-$phase',
      _integer(report['pid'], '$path pid') > 0 &&
          report['runId'] is String &&
          '${report['runId']}'.isNotEmpty,
      'pid ${report['pid']} run ${report['runId']}',
      phase: phase,
    );
    final requests = _array(report['requests'], '$path requests');
    check(
      'product-request-count-$phase',
      requests.length == authSessionExpectedRequests(corpus, phase).length,
      '${requests.length} requests',
      phase: phase,
    );
    final unmatched = _array(
      report['unmatchedRequests'],
      '$path unmatchedRequests',
    );
    check(
      'product-unmatched-$phase',
      unmatched.isEmpty,
      '${unmatched.length} undeclared requests',
      phase: phase,
    );
    final requestCheck = _object(report['requestCheck'], '$path requestCheck');
    check(
      'product-request-check-$phase',
      requestCheck['match'] == true &&
          requestCheck['orderMatch'] == true &&
          requestCheck['declaredCount'] ==
              authSessionExpectedRequests(corpus, phase).length &&
          requestCheck['actualCount'] == requests.length,
      requestCheck['mismatch'] ?? 'matched',
      phase: phase,
    );
    _compareRequests(
      corpus: corpus,
      golden: golden,
      product: report,
      phase: phase,
      mismatches: mismatches,
      notCompared: notCompared,
      orderOnly: orderOnly,
      productPath: path,
      seedSessionPairs: seedSessionPairs,
    );
    _compareStageTrace(
      golden: golden,
      product: report,
      phase: phase,
      mismatches: mismatches,
      productPath: path,
    );

    final steps = authSessionSteps(corpus, phase);
    final observations = _array(report['observations'], '$path observations');
    final actualIds = [for (final raw in observations) '${(raw as Map)['id']}'];
    final declaredIds = [for (final step in steps) '${step['id']}'];
    check(
      'product-observations-$phase',
      observations.isNotEmpty && _deepEquals(actualIds, declaredIds),
      '${actualIds.length} observations, ${declaredIds.length} declared',
      phase: phase,
    );
    final goldenRows = (golden['observations'] as List)
        .map((raw) => (raw as Map))
        .toList();
    for (final raw in observations) {
      final row = _object(raw, '$path observation');
      final id = '${row['id']}';
      final goldenIndex = goldenRows.indexWhere(
        (goldenRow) => goldenRow['id'] == id,
      );
      final actual = row['value'];
      if (goldenIndex < 0 || actual is! Map) {
        mismatches.add({
          'phase': phase,
          'surface': 'observation',
          'id': id,
          'detail': 'unknown id or no value',
        });
        continue;
      }
      _compareObservation(
        corpus: corpus,
        expected: goldenRows[goldenIndex]['value'] as Map,
        actual: actual,
        phase: phase,
        id: id,
        mismatches: mismatches,
        notCompared: notCompared,
        orderOnly: orderOnly,
        seedSessionPairs: seedSessionPairs,
      );
    }
    check(
      'product-observation-check-$phase',
      _object(report['observationCheck'], '$path observationCheck')['match'] ==
          true,
      'recorded observation check',
      phase: phase,
    );

    final cleanup = _object(report['cleanup'], '$path cleanup');
    final isolation = _object(report['isolation'], '$path isolation');
    final owner = _object(report['owner'], '$path owner');
    if (phase == 'seed') {
      check(
        'product-seed-cleanup',
        cleanup['databaseClosed'] == true &&
            cleanup['serversClosed'] == true &&
            cleanup['nativeLibraryDisposed'] == true &&
            cleanup['ownerWritten'] == true &&
            cleanup['scratchRetained'] == true &&
            cleanup['scratchRemoved'] == false &&
            isolation['createdByThisRun'] == true &&
            isolation['validatedOwner'] == false &&
            isolation['validatedOwnerSha256'] == null &&
            owner['written'] == true,
        'retained ${isolation['root']}',
        phase: phase,
      );
    } else {
      check(
        'product-restart-cleanup',
        cleanup['databaseClosed'] == true &&
            cleanup['serversClosed'] == true &&
            cleanup['nativeLibraryDisposed'] == true &&
            cleanup['scratchRemoved'] == true &&
            cleanup['rootAbsentAfter'] == true &&
            cleanup['scratchRetained'] == false &&
            isolation['validatedOwner'] == true &&
            isolation['createdByThisRun'] == false &&
            owner['validated'] == true,
        'removed ${isolation['root']}',
        phase: phase,
      );
    }
    check(
      'product-owner-hash-$phase',
      _isSha256(cleanup['ownerSha256']),
      'owner sha ${cleanup['ownerSha256']}',
      phase: phase,
    );
    final startedAt = DateTime.tryParse('${report['startedAt']}');
    final completedAt = DateTime.tryParse('${report['completedAt']}');
    check(
      'product-timing-$phase',
      startedAt != null &&
          completedAt != null &&
          !completedAt.isBefore(startedAt),
      '${report['startedAt']} -> ${report['completedAt']}',
      phase: phase,
    );
  }

  check(
    'product-library-agreement',
    productLibraryHashes.length == 2 &&
        productLibraryHashes.first == productLibraryHashes.last,
    'seed ${productLibraryHashes.first} restart ${productLibraryHashes.last}',
  );
  final seedOwner = _object(seedProduct['owner'], 'seed owner');
  final restartOwner = _object(restartProduct['owner'], 'restart owner');
  check(
    'restart-read-this-seed',
    restartOwner['seedRunId'] == seedProduct['runId'] &&
        restartOwner['seedPid'] == seedProduct['pid'] &&
        restartOwner['sha256'] == seedOwner['sha256'],
    'seed run ${seedProduct['runId']} pid ${seedProduct['pid']}',
  );
  final seedIsolation = _object(seedProduct['isolation'], 'seed isolation');
  final restartIsolation = _object(
    restartProduct['isolation'],
    'restart isolation',
  );
  final seedCleanup = _object(seedProduct['cleanup'], 'seed cleanup');
  final restartCleanup = _object(restartProduct['cleanup'], 'restart cleanup');
  final seedRoot = _recordPath(seedIsolation['root']);
  final restartRoot = _recordPath(restartIsolation['root']);
  final seedRootName = '${seedIsolation['rootName'] ?? ''}'.trim();
  final restartRootName = '${restartIsolation['rootName'] ?? ''}'.trim();
  final ownerSha = seedCleanup['ownerSha256'];
  final rootPathsAgree =
      seedRoot != null &&
      restartRoot != null &&
      seedRoot == restartRoot &&
      seedRootName.isNotEmpty &&
      seedRootName == restartRootName &&
      _pathSegment(seedRoot) == seedRootName;
  final rootPathsInside =
      _recordPath(seedIsolation['database']) ==
          '$seedRoot/spaces/default/data.db' &&
      _recordPath(restartIsolation['database']) ==
          '$restartRoot/spaces/default/data.db' &&
      _recordPath(seedIsolation['workspaceManifest']) ==
          '$seedRoot/manifest.json' &&
      _recordPath(restartIsolation['workspaceManifest']) ==
          '$restartRoot/manifest.json' &&
      _recordPath(seedIsolation['ownerFile']) == '$seedRoot/owner.json' &&
      _recordPath(restartIsolation['ownerFile']) == '$restartRoot/owner.json';
  final ownerBindings =
      seedOwner['written'] == true &&
      restartOwner['validated'] == true &&
      seedOwner['complete'] == true &&
      restartOwner['complete'] == true &&
      seedOwner['rootName'] == seedRootName &&
      restartOwner['rootName'] == restartRootName &&
      _isSha256(ownerSha) &&
      seedOwner['sha256'] == ownerSha &&
      restartOwner['sha256'] == ownerSha &&
      restartIsolation['validatedOwnerSha256'] == ownerSha &&
      restartCleanup['ownerSha256'] == ownerSha;
  final preferenceBoundary =
      seedIsolation['preferenceFilesOutsideRoot'] is List &&
      (seedIsolation['preferenceFilesOutsideRoot'] as List).isEmpty &&
      restartIsolation['preferenceFilesOutsideRoot'] is List &&
      (restartIsolation['preferenceFilesOutsideRoot'] as List).isEmpty &&
      seedIsolation['preferenceBoundary'] is String &&
      '${seedIsolation['preferenceBoundary']}'.trim().isNotEmpty &&
      restartIsolation['preferenceBoundary'] is String &&
      '${restartIsolation['preferenceBoundary']}'.trim().isNotEmpty;
  final tierClaim =
      seedProduct['sessionTier'] is Map &&
      restartProduct['sessionTier'] is Map &&
      (seedProduct['sessionTier'] as Map)['tier'] == 'single' &&
      (restartProduct['sessionTier'] as Map)['tier'] == 'single';
  final rootExistence =
      seedIsolation['rootExistedAtStart'] == false &&
      restartIsolation['rootExistedAtStart'] == true &&
      seedCleanup['rootAbsentAfter'] == false &&
      restartCleanup['rootAbsentAfter'] == true;
  check(
    'product-retained-root',
    rootPathsAgree &&
        rootPathsInside &&
        ownerBindings &&
        preferenceBoundary &&
        tierClaim &&
        rootExistence,
    'seed ${seedIsolation['root']} -> restart ${restartIsolation['root']}; '
        'agree=$rootPathsAgree inside=$rootPathsInside owner=$ownerBindings '
        'prefs=$preferenceBoundary tier=$tierClaim existence=$rootExistence',
  );
  final seedStarted = DateTime.tryParse('${seedProduct['startedAt']}');
  final restartStarted = DateTime.tryParse('${restartProduct['startedAt']}');
  final seedCompleted = DateTime.tryParse('${seedProduct['completedAt']}');
  check(
    'restart-after-terminated-seed',
    seedStarted != null &&
        restartStarted != null &&
        seedCompleted != null &&
        restartStarted.isAfter(seedCompleted),
    'seed ended ${seedProduct['completedAt']}, restart started '
        '${restartProduct['startedAt']}',
  );

  final failedSurfaces = <String>[
    for (final mismatch in mismatches) '${mismatch['surface']}',
  ];
  return {
    'status': mismatches.isEmpty ? 'pass' : 'fail',
    'mode': 'auth-session',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'corpusSha256Lf': corpusSha256Lf,
    'target': target,
    'webViewProvider': corpus['webViewProvider'],
    'golden': {
      'seed': {'path': seedGoldenPath, 'sha256': seedGoldenSha256},
      'restart': {'path': restartGoldenPath, 'sha256': restartGoldenSha256},
      'harnessApkSha256': (seedGolden['identity'] as Map)['harnessApkSha256'],
      'provenance': 'controller frozen device capture (raw phase reports)',
    },
    'product': {
      'seed': {
        'path': seedProductPath,
        'pid': seedProduct['pid'],
        'runId': seedProduct['runId'],
        'exitCode': seedExitCode,
      },
      'restart': {
        'path': restartProductPath,
        'pid': restartProduct['pid'],
        'runId': restartProduct['runId'],
        'exitCode': restartExitCode,
      },
    },
    'checks': checks,
    'observedCounts': {
      'seed': {
        'observations': (seedProduct['observations'] as List).length,
        'requests': (seedProduct['requests'] as List).length,
      },
      'restart': {
        'observations': (restartProduct['observations'] as List).length,
        'requests': (restartProduct['requests'] as List).length,
      },
    },
    'mismatches': mismatches,
    'mismatchKeys': [for (final mismatch in mismatches) mismatchKey(mismatch)],
    'failedSurfaces': failedSurfaces,
    'notCompared': notCompared,
    'cookieOrderDifferences': orderOnly,
    'nativeOnlyProvenance': {
      'inventory':
          'the capture\'s cookie-row and cache-key inventories are the '
          'frozen database receipts, never a portable compared schema',
      'webView':
          'the provider package/version and the approved profile paths are '
          'the frozen harness\' containment receipt',
      'webViewInitialized':
          'recorded by the frozen removeLoginHeader step after its provider '
          'preflight; the product has no WebView in this path',
    },
    'coverageGaps': corpus['coverageGaps'],
  };
}

/// The record form of a scratch path: absolute, separator-normalised and free
/// of `.`/`..`; null when the receipt does not name one. This is a string
/// validator only: the comparator never opens or deletes a reported path.
String? _recordPath(Object? value) {
  if (value is! String) return null;
  var text = value.trim().replaceAll('\\', '/');
  while (text.length > 1 && text.endsWith('/')) {
    text = text.substring(0, text.length - 1);
  }
  if (text.isEmpty || text == '/' || RegExp(r'^[A-Za-z]:$').hasMatch(text)) {
    return null;
  }
  final absolute =
      RegExp(r'^[A-Za-z]:/').hasMatch(text) || text.startsWith('/');
  if (!absolute) return null;
  final segments = [
    for (final segment in text.split('/'))
      if (segment.isNotEmpty) segment,
  ];
  if (segments.length < 2 ||
      segments.any((segment) => segment == '.' || segment == '..')) {
    return null;
  }
  return text;
}

String _pathSegment(String path) => path.split('/').last;

// --------------------------------------------------------------------------
// CLI: run both phases, then compare and run the controls
// --------------------------------------------------------------------------

/// The corpus `--corpus=<path>` names, or the historical corpus. The path is a
/// tool-side selector only; every identity the comparison uses is inside the file.
String _selectedCorpusPath(Map<String, String> options) {
  final path = options['corpus']?.trim();
  return path == null || path.isEmpty ? authSessionCorpusPath : path;
}

Map<String, String> _namedOptions(List<String> args) {
  final options = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    if (arg == '--compare-only' || arg == '--controls-only') continue;
    if (!arg.contains('=')) {
      throw FormatException('expected --name=value, got $arg');
    }
    final index = arg.indexOf('=');
    options[arg.substring(2, index)] = arg.substring(index + 1);
  }
  return options;
}

String _required(Map<String, String> options, String name) {
  final value = options[name];
  if (value == null || value.trim().isEmpty) {
    throw FormatException('--$name is required');
  }
  return value;
}

Future<int> _runAndCompare(List<String> args) async {
  final options = _namedOptions(args);
  final capture = Directory(_required(options, 'capture'));
  final evidence = Directory(_required(options, 'evidence'));
  final libraryPath = _required(options, 'library');
  final handoffPath = options['handoff'];
  final corpusPath = _selectedCorpusPath(options);
  final corpusFile = File(corpusPath);
  final corpus = loadAuthSessionCorpus(corpusPath);
  final corpusLf = authSessionCorpusSha256Lf(corpusFile);
  final librarySha = sha256File(File(libraryPath));
  final seedGoldenPath =
      '${capture.path}${Platform.pathSeparator}seed-report.json';
  final restartGoldenPath =
      '${capture.path}${Platform.pathSeparator}restart-report.json';
  final seedGoldenSha = sha256File(File(seedGoldenPath));
  final restartGoldenSha = sha256File(File(restartGoldenPath));
  final seedGolden = _readJson(seedGoldenPath);
  final restartGolden = _readJson(restartGoldenPath);
  final handoff = handoffPath == null ? null : _readJson(handoffPath);
  checkAuthSessionGoldenPair(
    corpus: corpus,
    corpusSha256Lf: corpusLf,
    seed: seedGolden,
    restart: restartGolden,
    handoff: handoff,
    seedSha256: seedGoldenSha,
    restartSha256: restartGoldenSha,
    seedPath: seedGoldenPath,
    restartPath: restartGoldenPath,
  );

  evidence.createSync(recursive: true);
  final scratch = Directory('${evidence.path}${Platform.pathSeparator}scratch')
    ..createSync(recursive: true);
  final runId =
      '${DateTime.now().toUtc().toIso8601String().replaceAll(':', '-')}'
      '-${Random.secure().nextInt(1 << 32).toRadixString(16)}';
  final root = '${scratch.path}${Platform.pathSeparator}$runId';
  final seedReport =
      '${evidence.path}${Platform.pathSeparator}seed-report.json';
  final restartReport =
      '${evidence.path}${Platform.pathSeparator}restart-report.json';
  final seedRun = await _runProcess([
    'run',
    'tool/auth_session/runner.dart',
    'seed',
    libraryPath,
    root,
    seedReport,
    '--expected-corpus-sha256=$corpusLf',
    '--corpus=$corpusPath',
  ], logPath: '${evidence.path}${Platform.pathSeparator}seed-runner.log');
  final restartRun = await _runProcess([
    'run',
    'tool/auth_session/runner.dart',
    'restart',
    libraryPath,
    root,
    restartReport,
    '--expected-corpus-sha256=$corpusLf',
    '--corpus=$corpusPath',
  ], logPath: '${evidence.path}${Platform.pathSeparator}restart-runner.log');
  final seedProduct = _readJsonOrNull(seedReport);
  final restartProduct = _readJsonOrNull(restartReport);
  Map<String, Object?> report;
  try {
    if (seedProduct == null || restartProduct == null) {
      throw const FormatException('the runner did not write a phase report');
    }
    report = compareAuthSessionPhases(
      corpus: corpus,
      corpusSha256Lf: corpusLf,
      seedGolden: seedGolden,
      restartGolden: restartGolden,
      seedProduct: seedProduct,
      restartProduct: restartProduct,
      librarySha256: librarySha,
      handoff: handoff,
      seedGoldenSha256: seedGoldenSha,
      restartGoldenSha256: restartGoldenSha,
      seedGoldenPath: seedGoldenPath,
      restartGoldenPath: restartGoldenPath,
      seedProductPath: seedReport,
      restartProductPath: restartReport,
      seedExitCode: seedRun.exitCode,
      restartExitCode: restartRun.exitCode,
    );
  } on FormatException catch (error) {
    report = {
      'status': 'fail',
      'mode': 'auth-session',
      'analysisFailure': error.message,
      'formula':
          'the product phases could not be compared; the raw reports and '
          'runner logs are beside this report',
      'mismatches': [
        {'phase': 'pair', 'surface': 'reports', 'detail': error.message},
      ],
    };
  }
  _writeJson(
    '${evidence.path}${Platform.pathSeparator}comparison.json',
    report,
  );
  stdout.writeln(
    'auth-session comparison: ${report['status']} '
    '(${report['mismatches'] is List ? (report['mismatches'] as List).length : 0} '
    'mismatches)',
  );

  final controls = await _runNegativeControls(
    evidence: evidence,
    libraryPath: libraryPath,
    seedGoldenPath: seedGoldenPath,
    restartGoldenPath: restartGoldenPath,
    seedProductPath: seedReport,
    restartProductPath: restartReport,
    seedGoldenSha: seedGoldenSha,
    restartGoldenSha: restartGoldenSha,
    baseline: report,
  );
  _writeJson(
    '${evidence.path}${Platform.pathSeparator}negative-controls.json',
    controls,
  );
  final originalsUnchanged =
      sha256File(File(seedGoldenPath)) == seedGoldenSha &&
      sha256File(File(restartGoldenPath)) == restartGoldenSha;
  final pass =
      report['status'] == 'pass' &&
      controls['status'] == 'pass' &&
      originalsUnchanged;
  stdout.writeln(
    'negative controls: ${controls['status']}; immutable captures unchanged: '
    '$originalsUnchanged',
  );
  return pass ? 0 : 1;
}

/// Demonstrates that the comparator rejects changed values, requests,
/// identities, receipts and cookie order. Every control is a copy of the real
/// captured report or of the real product report; the originals are never
/// written and are hashed again after the run.
Future<Map<String, Object?>> _runNegativeControls({
  required Directory evidence,
  required String? libraryPath,
  required String seedGoldenPath,
  required String restartGoldenPath,
  required String seedProductPath,
  required String restartProductPath,
  required String seedGoldenSha,
  required String restartGoldenSha,
  required Map<String, Object?> baseline,
}) async {
  final directory = Directory(
    '${evidence.path}${Platform.pathSeparator}negative-controls',
  )..createSync(recursive: true);
  final seedGolden = _readJson(seedGoldenPath);
  final seedProduct = _readJson(seedProductPath);
  final restartProduct = _readJson(restartProductPath);
  final controls = <Map<String, Object?>>[];

  Map<String, dynamic> copy(Map<String, dynamic> source) =>
      jsonDecode(jsonEncode(source)) as Map<String, dynamic>;
  String writeCopy(String name, Map<String, dynamic> source) {
    final path = '${directory.path}${Platform.pathSeparator}$name.json';
    _writeJson(path, source);
    return path;
  }

  /// The mismatch keys this run's own comparison already reports: a control's
  /// difference must be new relative to them, never one of theirs.
  final baselineKeys = {
    for (final raw in (baseline['mismatchKeys'] as List? ?? const [])) '$raw',
  };

  void mutateObservationValue(Map<String, dynamic> report, String id) {
    final observations = report['observations'] as List;
    final row =
        observations.firstWhere(
              (raw) => (raw as Map)['id'] == id,
              orElse: () => throw StateError('no observation $id to mutate'),
            )
            as Map;
    final value = (row['value'] as Map).cast<String, Object?>();
    final field = value.containsKey('withLogin')
        ? 'withLogin'
        : value.keys.first;
    value[field] = 'mutated:$field';
  }

  void appendRequest(Map<String, dynamic> report) {
    (report['requests'] as List).add({
      'listener': '127.0.0.1',
      'method': 'GET',
      'target': '/mutated-control',
      'path': '/mutated-control',
      'rawQuery': '',
      'query': <String, String>{},
      'headers': <String, String>{},
      'body': '',
      'stage': '${(report['steps'] as List).last}',
    });
  }

  void swapRequests(Map<String, dynamic> report) {
    final requests = report['requests'] as List;
    if (requests.length < 3) {
      appendRequest(report);
      return;
    }
    // Two requests of the same declared stage, so the trace stays a declared
    // stage sequence and the difference is the request itself.
    final first = requests[1];
    requests[1] = requests[2];
    requests[2] = first;
  }

  void swapOrders(Map<String, dynamic> report) {
    final observations = report['observations'] as List;
    if (observations.length < 2) return;
    final first = observations[0];
    observations[0] = observations[1];
    observations[1] = first;
    final check = report['observationCheck'];
    if (check is Map) check['ordered'] = false;
  }

  void setRawQuery(Map<String, dynamic> report, String value) {
    final request = (report['requests'] as List).first as Map;
    request['rawQuery'] = value;
    request['target'] = '${request['path']}?$value';
  }

  void removeRawQuery(Map<String, dynamic> report) {
    ((report['requests'] as List).first as Map).remove('rawQuery');
  }

  /// The first request whose [name] header is present and whose comparison key
  /// this run does not already report, so the control's difference is its own.
  int? otherwiseMatchingHeaderIndex(
    Map<String, dynamic> report,
    String name, {
    bool multiPairCookie = false,
  }) {
    final requests = report['requests'] as List;
    for (var index = 0; index < requests.length; index++) {
      final headers = ((requests[index] as Map)['headers'] as Map)
          .cast<String, Object?>();
      final value = headers[name];
      if (value is! String) continue;
      if (multiPairCookie && !value.contains('; ')) continue;
      if (baselineKeys.contains('product-request-headers|seed|$index|$name')) {
        continue;
      }
      return index;
    }
    return null;
  }

  void setHeader(
    Map<String, dynamic> report,
    int index,
    String name,
    String value,
  ) {
    final headers =
        (((report['requests'] as List)[index] as Map)['headers'] as Map)
            .cast<String, Object?>();
    headers[name] = value;
  }

  void reorderCookie(Map<String, dynamic> report, int index) {
    final headers =
        (((report['requests'] as List)[index] as Map)['headers'] as Map)
            .cast<String, Object?>();
    final pairs = '${headers['cookie']}'.split('; ');
    if (pairs.length < 2) {
      throw StateError('request $index carries no multi-pair cookie');
    }
    headers['cookie'] = [...pairs.skip(1), pairs.first].join('; ');
  }

  final goldenSeedValue = copy(seedGolden)
    ..also((report) => mutateObservationValue(report, 'seed.headers.A'));
  final goldenSeedRequests = copy(seedGolden)..also(swapRequests);
  final goldenSeedOrders = copy(seedGolden)..also(swapOrders);
  final goldenSeedIdentity = copy(seedGolden);
  (goldenSeedIdentity['identity'] as Map)['targetApkSha256'] =
      '0000000000000000000000000000000000000000000000000000000000000000';
  final goldenSeedReceipt = copy(seedGolden);
  ((goldenSeedReceipt['cleanup'] as Map) as Map<String, dynamic>)['replay'] = {
    'ok': false,
    'listenersClosed': false,
  };
  final productSeedValue = copy(seedProduct)
    ..also((report) => mutateObservationValue(report, 'seed.headers.A'));
  final productSeedRequests = copy(seedProduct)..also(swapRequests);
  final productSeedRawOrder = copy(seedProduct)
    ..also((report) => setRawQuery(report, 'page=1&user=synthetic-a-user'));
  final productSeedRawEncoding = copy(seedProduct)
    ..also(
      (report) =>
          setRawQuery(report, 'user=synthetic-a-user&pass=synthetic-a-pass%20'),
    );
  final productSeedRawAbsent = copy(seedProduct)..also(removeRawQuery);
  final productRestartIdentity = copy(restartProduct);
  (productRestartIdentity['identity'] as Map)['corpusSha256Lf'] =
      '0000000000000000000000000000000000000000000000000000000000000000';
  final productSeedTiming = copy(seedProduct)
    ..['startedAt'] = '2999-01-01T00:00:00.000Z';

  Future<void> control(
    String name,
    int expectedExit, {
    required String goldenSeed,
    required String goldenRestart,
    required String productSeed,
    required String productRestart,
    required String mutation,
    String? requiredDelta,
  }) async {
    final out = '${directory.path}${Platform.pathSeparator}$name-report.json';
    final log = '${directory.path}${Platform.pathSeparator}$name.log';
    final args = [
      'run',
      'tool/auth_session/compare.dart',
      '--compare-only',
      productSeed,
      productRestart,
      '--golden-seed=$goldenSeed',
      '--golden-restart=$goldenRestart',
      if (libraryPath != null) '--library=$libraryPath',
      '--out=$out',
    ];
    final run = await _runProcess(args, logPath: log);
    final output = _readJsonOrNull(out);
    final keys = <String>[
      for (final raw in (output?['mismatchKeys'] as List? ?? const [])) '$raw',
    ];
    final delta = <String>[
      for (final key in keys)
        if (!baselineKeys.contains(key)) key,
    ]..sort();
    final deltaHit = requiredDelta == null || delta.contains(requiredDelta);
    controls.add({
      'name': name,
      'mutation': mutation,
      'expectedExit': expectedExit,
      'actualExit': run.exitCode,
      'requiredDelta': requiredDelta,
      'baselineKeysConsidered': baselineKeys.length,
      'newMismatchKeys': delta,
      'passed': run.exitCode == expectedExit && deltaHit,
      'report': out,
      'log': log,
      'stdout': run.stdout.trim(),
      'stderr': run.stderr.trim(),
    });
  }

  await control(
    'golden-value-mutation',
    1,
    goldenSeed: writeCopy('golden-seed-value', goldenSeedValue),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture changed seed.headers.A first field',
    requiredDelta: 'observation|seed|withLogin|seed.headers.A',
  );
  await control(
    'golden-request-mutation',
    2,
    goldenSeed: writeCopy('golden-seed-requests', goldenSeedRequests),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture swapped two request rows',
  );
  await control(
    'golden-observation-order',
    2,
    goldenSeed: writeCopy('golden-seed-orders', goldenSeedOrders),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture swapped two observation ids',
  );
  await control(
    'golden-identity-mutation',
    2,
    goldenSeed: writeCopy('golden-seed-identity', goldenSeedIdentity),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture named another target APK',
  );
  await control(
    'golden-receipt-mutation',
    2,
    goldenSeed: writeCopy('golden-seed-receipt', goldenSeedReceipt),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture claimed its replay listeners were open',
  );
  await control(
    'product-value-mutation',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-value', productSeedValue),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report changed seed.headers.A withLogin',
    requiredDelta: 'observation|seed|withLogin|seed.headers.A',
  );
  await control(
    'product-request-mutation',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-requests', productSeedRequests),
    productRestart: restartProductPath,
    mutation:
        'a copied product seed report swapped its second and third requests',
    requiredDelta: 'product-requests|seed|1',
  );
  await control(
    'product-identity-mutation',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: writeCopy(
      'product-restart-identity',
      productRestartIdentity,
    ),
    mutation: 'a copied product restart report named another corpus hash',
    requiredDelta: 'product-corpus-identity-restart|restart',
  );
  await control(
    'product-raw-query-order',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-raw-order', productSeedRawOrder),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report reordered the first raw query',
    requiredDelta: 'product-requests|seed|0',
  );
  await control(
    'product-raw-query-encoding',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-raw-encoding', productSeedRawEncoding),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report re-encoded the first raw query',
    requiredDelta: 'product-requests|seed|0',
  );
  await control(
    'product-raw-query-absent',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-raw-absent', productSeedRawAbsent),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report omitted the first raw query',
    requiredDelta: 'product-requests|seed|0',
  );
  await control(
    'product-timing-receipt',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-timing', productSeedTiming),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report started after it completed',
    requiredDelta: 'product-timing-seed|seed',
  );

  // A header control on a request and a header this run already compares
  // successfully: the difference is the control's own, never an inherited
  // Cookie row.
  final headerIndex = otherwiseMatchingHeaderIndex(seedProduct, 'x-declared');
  if (headerIndex == null) {
    controls.add({
      'name': 'product-header-value',
      'status': 'not-applicable',
      'reason': 'no otherwise-matching x-declared request in this run',
      'passed': false,
    });
  } else {
    final mutated = copy(seedProduct)
      ..also(
        (report) => setHeader(report, headerIndex, 'x-declared', 'mutated'),
      );
    await control(
      'product-header-value',
      1,
      goldenSeed: seedGoldenPath,
      goldenRestart: restartGoldenPath,
      productSeed: writeCopy('product-seed-header', mutated),
      productRestart: restartProductPath,
      mutation:
          'a copied product seed report changed x-declared on request '
          '$headerIndex, a request this run otherwise matches',
      requiredDelta: 'product-request-headers|seed|$headerIndex|x-declared',
    );
  }

  final cookieIndex = otherwiseMatchingHeaderIndex(seedProduct, 'cookie');
  if (cookieIndex == null) {
    controls.add({
      'name': 'product-cookie-value',
      'status': 'not-applicable',
      'reason': 'no otherwise-matching cookie request in this run',
      'passed': false,
    });
  } else {
    final mutated = copy(seedProduct)
      ..also(
        (report) => setHeader(report, cookieIndex, 'cookie', 'scriptB=mutated'),
      );
    await control(
      'product-cookie-value',
      1,
      goldenSeed: seedGoldenPath,
      goldenRestart: restartGoldenPath,
      productSeed: writeCopy('product-seed-cookie-value', mutated),
      productRestart: restartProductPath,
      mutation:
          'a copied product seed report changed the cookie value on request '
          '$cookieIndex, a request this run otherwise matches',
      requiredDelta: 'product-request-headers|seed|$cookieIndex|cookie',
    );
  }

  final orderIndex = otherwiseMatchingHeaderIndex(
    seedProduct,
    'cookie',
    multiPairCookie: true,
  );
  if (orderIndex == null) {
    controls.add({
      'name': 'product-cookie-order',
      'status': 'not-applicable',
      'reason':
          'no otherwise-matching multi-pair cookie in this run: the Cookie '
          'rows this run already fails must not stand in for the control',
      'passed': false,
    });
  } else {
    final mutated = copy(seedProduct)
      ..also((report) => reorderCookie(report, orderIndex));
    await control(
      'product-cookie-order',
      1,
      goldenSeed: seedGoldenPath,
      goldenRestart: restartGoldenPath,
      productSeed: writeCopy('product-seed-cookie-order', mutated),
      productRestart: restartProductPath,
      mutation:
          'a copied product seed report reordered the cookie pairs on request '
          '$orderIndex, a request this run otherwise matches',
      requiredDelta: 'product-request-headers|seed|$orderIndex|cookie',
    );
  }

  final originalsUnchanged =
      sha256File(File(seedGoldenPath)) == seedGoldenSha &&
      sha256File(File(restartGoldenPath)) == restartGoldenSha;
  final failed = controls
      .where((control) => control['passed'] != true)
      .toList();
  final notApplicable = [
    for (final control in controls)
      if (control['status'] == 'not-applicable') control['name'],
  ];
  return {
    'status': failed.isEmpty && originalsUnchanged ? 'pass' : 'fail',
    'immutableCapturesUnchanged': originalsUnchanged,
    'baselineMismatchKeys': baselineKeys.toList()..sort(),
    'controls': controls,
    'failedControls': [for (final control in failed) control['name']],
    'notApplicableControls': notApplicable,
  };
}

/// Runs the whole negative-control set against a pair of product reports that
/// already exist, comparing them with the capture first. This is the replay the
/// controls need for a comparator-only change: no phase runs, so no HTTP, phone
/// or product process is repeated.
Future<int> _controlsOnly(List<String> args) async {
  final options = _namedOptions(args);
  final capture = Directory(_required(options, 'capture'));
  final evidence = Directory(_required(options, 'evidence'));
  final seedProductPath = _required(options, 'seed-product');
  final restartProductPath = _required(options, 'restart-product');
  final libraryPath = options['library'];
  final corpusPath = _selectedCorpusPath(options);
  final corpus = loadAuthSessionCorpus(corpusPath);
  final corpusLf = authSessionCorpusSha256Lf(File(corpusPath));
  final seedGoldenPath =
      '${capture.path}${Platform.pathSeparator}seed-report.json';
  final restartGoldenPath =
      '${capture.path}${Platform.pathSeparator}restart-report.json';
  final seedGoldenSha = sha256File(File(seedGoldenPath));
  final restartGoldenSha = sha256File(File(restartGoldenPath));
  final seedGolden = _readJson(seedGoldenPath);
  final restartGolden = _readJson(restartGoldenPath);
  final handoff = options['handoff'] == null
      ? null
      : _readJson(options['handoff']!);
  final Map<String, Object?> baseline;
  try {
    baseline = compareAuthSessionPhases(
      corpus: corpus,
      corpusSha256Lf: corpusLf,
      seedGolden: seedGolden,
      restartGolden: restartGolden,
      seedProduct: _readJson(seedProductPath),
      restartProduct: _readJson(restartProductPath),
      librarySha256: libraryPath == null ? null : sha256File(File(libraryPath)),
      handoff: handoff,
      seedGoldenSha256: seedGoldenSha,
      restartGoldenSha256: restartGoldenSha,
      seedGoldenPath: seedGoldenPath,
      restartGoldenPath: restartGoldenPath,
      seedProductPath: seedProductPath,
      restartProductPath: restartProductPath,
    );
  } on FormatException catch (error) {
    _writeJson('${evidence.path}${Platform.pathSeparator}comparison.json', {
      'status': 'refused',
      'mode': 'auth-session-controls',
      'analysisFailure': error.message,
    });
    stdout.writeln('refused: ${error.message}');
    return 2;
  }
  evidence.createSync(recursive: true);
  _writeJson(
    '${evidence.path}${Platform.pathSeparator}comparison.json',
    baseline,
  );
  stdout.writeln(
    'auth-session comparison: ${baseline['status']} '
    '(${(baseline['mismatches'] as List).length} mismatches)',
  );
  final controls = await _runNegativeControls(
    evidence: evidence,
    libraryPath: libraryPath,
    seedGoldenPath: seedGoldenPath,
    restartGoldenPath: restartGoldenPath,
    seedProductPath: seedProductPath,
    restartProductPath: restartProductPath,
    seedGoldenSha: seedGoldenSha,
    restartGoldenSha: restartGoldenSha,
    baseline: baseline,
  );
  _writeJson(
    '${evidence.path}${Platform.pathSeparator}negative-controls.json',
    controls,
  );
  stdout.writeln('negative controls: ${controls['status']}');
  return controls['status'] == 'pass' ? 0 : 1;
}

/// Compares two captures that already exist. This mode never runs the product,
/// so it can compare a copied (mutated) capture while the originals stay
/// untouched.
Future<int> _compareOnly(List<String> args) async {
  final positional = <String>[
    for (final arg in args)
      if (arg != '--compare-only' && !arg.startsWith('--')) arg,
  ];
  final options = _namedOptions(args);
  final outPath = options['out'];
  Map<String, Object?> report;
  try {
    if (positional.length != 2) {
      throw const FormatException(
        'usage: --compare-only <seed.json> <restart.json> '
        '--golden-seed=<seed-report.json> '
        '--golden-restart=<restart-report.json>',
      );
    }
    final corpusPath = _selectedCorpusPath(options);
    final corpus = loadAuthSessionCorpus(corpusPath);
    final corpusLf = authSessionCorpusSha256Lf(File(corpusPath));
    final seedGoldenPath = _required(options, 'golden-seed');
    final restartGoldenPath = _required(options, 'golden-restart');
    final seedGoldenSha = sha256File(File(seedGoldenPath));
    final restartGoldenSha = sha256File(File(restartGoldenPath));
    final seedGolden = _readJson(seedGoldenPath);
    final restartGolden = _readJson(restartGoldenPath);
    final handoff = options['handoff'] == null
        ? null
        : _readJson(options['handoff']!);
    final libraryPath = options['library'];
    final librarySha = libraryPath == null
        ? null
        : sha256File(File(libraryPath));
    report = compareAuthSessionPhases(
      corpus: corpus,
      corpusSha256Lf: corpusLf,
      seedGolden: seedGolden,
      restartGolden: restartGolden,
      seedProduct: _readJson(positional[0]),
      restartProduct: _readJson(positional[1]),
      librarySha256: librarySha,
      handoff: handoff,
      seedGoldenSha256: seedGoldenSha,
      restartGoldenSha256: restartGoldenSha,
      seedGoldenPath: seedGoldenPath,
      restartGoldenPath: restartGoldenPath,
      seedProductPath: positional[0],
      restartProductPath: positional[1],
    );
  } on FormatException catch (error) {
    report = {
      'status': 'refused',
      'mode': 'auth-session-compare',
      'analysisFailure': error.message,
    };
  } on Object catch (error) {
    report = {
      'status': 'refused',
      'mode': 'auth-session-compare',
      'analysisFailure': '$error',
    };
  }
  if (outPath != null) _writeJson(outPath, report);
  stdout.writeln('${report['status']}: ${report['analysisFailure'] ?? ''}');
  return switch (report['status']) {
    'pass' => 0,
    'refused' => 2,
    _ => 1,
  };
}

// --------------------------------------------------------------------------
// Process and file helpers
// --------------------------------------------------------------------------

({int exitCode, String stdout, String stderr}) _processResult(
  int exitCode,
  String out,
  String err,
) => (exitCode: exitCode, stdout: out, stderr: err);

Future<({int exitCode, String stdout, String stderr})> _runProcess(
  List<String> args, {
  required String logPath,
  Duration timeout = const Duration(minutes: 15),
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    args,
    workingDirectory: Directory.current.path,
    runInShell: false,
  );
  final out = StringBuffer();
  final err = StringBuffer();
  final outDone = process.stdout.transform(utf8.decoder).forEach(out.write);
  final errDone = process.stderr.transform(utf8.decoder).forEach(err.write);
  int exitCode;
  try {
    exitCode = await process.exitCode.timeout(timeout);
  } on TimeoutException {
    process.kill();
    exitCode = -1;
  }
  await Future.wait([outDone, errDone]);
  File(logPath).writeAsStringSync(
    '\$ ${args.join(' ')}\nexit: $exitCode\n--- stdout ---\n$out\n'
    '--- stderr ---\n$err\n',
  );
  return _processResult(exitCode, out.toString(), err.toString());
}

Map<String, dynamic> _readJson(String path) {
  final file = File(path);
  if (!file.existsSync()) throw FormatException('missing JSON file: $path');
  final decoded = jsonDecode(file.readAsStringSync());
  return _object(decoded, path);
}

Map<String, dynamic>? _readJsonOrNull(String path) {
  final file = File(path);
  if (!file.existsSync()) return null;
  final decoded = jsonDecode(file.readAsStringSync());
  return _object(decoded, path);
}

void _writeJson(String path, Map<String, Object?> report) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}

extension _Also<T> on T {
  T also(void Function(T value) action) {
    action(this);
    return this;
  }
}
