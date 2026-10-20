import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'runner.dart';

/// Compares the product's two `STATE-SESSION-01` phases with the controller's
/// frozen seed/restart captures.
///
/// Usage:
///   `dart run tool/state_session/compare.dart`
///   `--capture=<controller/state-capture-03>`
///   `--evidence=<state-product> --library=<fjs.dll> [--handoff=<json>]`
///
///   `dart run tool/state_session/compare.dart --compare-only <seed.json>`
///   `<restart.json> --golden-seed=<seed-report.json>`
///   `--golden-restart=<restart-report.json> [--library=<fjs.dll>]`
///   `[--out=<report.json>]`
///
/// The first form builds and runs the two product phases as two terminated Dart
/// processes, compares them, then runs the negative controls on copies of the
/// immutable captures. The second form compares two captures that already
/// exist; it is what those controls invoke, and it never marks a product-only
/// sample as a golden.
Future<void> main(List<String> args) async {
  if (args.contains('--compare-only')) {
    exitCode = await _compareOnly(args);
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

bool _isSha256(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);

Map<String, Object?> normalizeRequest(Object? raw) {
  final request = _object(raw, 'request');
  final query =
      (request['query'] as Map?)?.cast<String, dynamic>() ??
      const <String, dynamic>{};
  return {
    'method': '${request['method']}',
    'path': '${request['path']}',
    'query': {for (final entry in query.entries) entry.key: '${entry.value}'},
  };
}

List<Map<String, Object?>> _expectedRequests(
  Map<String, dynamic> corpus,
  String phase,
) => [
  for (final request in stateSessionExpectedRequests(corpus, phase))
    normalizeRequest(request),
];

/// The exact raw query bytes the frozen capture retained for each request.
///
/// The carrier is the ordered `stageTrace[i].path`: the resolved URL text the
/// frozen stage actually executed. Only the bytes after its first `?` are used
/// as the query identity; they are never decoded, re-encoded, sorted, trimmed or
/// reconstructed from the decoded `requests[i].query` map. The decoded row is
/// used solely to bind the trace entry to the same stage and path, so missing,
/// malformed or mismatched carrier evidence is refused instead of becoming an
/// empty query.
List<String> _goldenRawQueries({
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> golden,
  required String phase,
  required String goldenPath,
}) {
  final origin = '${corpus['origin']}';
  final requests = _array(golden['requests'], '$goldenPath requests');
  final traces = _array(golden['stageTrace'], '$goldenPath stageTrace');
  if (requests.isEmpty) {
    throw FormatException('$goldenPath holds no request trace');
  }
  if (traces.length != requests.length) {
    throw FormatException(
      '$goldenPath stageTrace has ${traces.length} entries for '
      '${requests.length} requests',
    );
  }
  final requestStages = [
    for (final step in stateSessionSteps(corpus, phase))
      if (const {'search', 'details', 'toc', 'content'}.contains(step['kind']))
        '${step['id']}',
  ];
  final actualStages = <String>[];
  final rawQueries = <String>[];
  for (var index = 0; index < requests.length; index++) {
    final request = _object(requests[index], '$goldenPath request $index');
    final trace = _object(traces[index], '$goldenPath stageTrace $index');
    final stage = request['stage'];
    if (stage is! String || stage.trim().isEmpty) {
      throw FormatException('$goldenPath request $index has no stage');
    }
    if (trace['stage'] != stage) {
      throw FormatException(
        '$goldenPath stageTrace $index is not request $index',
      );
    }
    actualStages.add(stage);
    final requestPath = request['path'];
    if (requestPath is! String || !requestPath.startsWith('/')) {
      throw FormatException('$goldenPath request $index has no path');
    }
    final tracePath = trace['path'];
    if (tracePath is! String || !tracePath.startsWith(origin)) {
      throw FormatException(
        '$goldenPath stageTrace $index is not on the corpus origin',
      );
    }
    final remainder = tracePath.substring(origin.length);
    final queryStart = remainder.indexOf('?');
    final path = queryStart < 0
        ? remainder
        : remainder.substring(0, queryStart);
    if (path != requestPath) {
      throw FormatException(
        '$goldenPath stageTrace $index path does not bind request $index',
      );
    }
    rawQueries.add(queryStart < 0 ? '' : remainder.substring(queryStart + 1));
  }
  if (!_deepEquals(requestStages, actualStages)) {
    throw FormatException(
      '$goldenPath request stages are not the corpus request stages',
    );
  }
  return rawQueries;
}

/// Structural and pairwise validation of the controller's raw captures before
/// any value is compared. A golden is only accepted when it names this corpus,
/// this frozen target, the measured harness and exactly the declared cases.
void checkStateSessionGolden({
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
  final target = stateSessionTargetOf(corpus);
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

  final expected = _expectedRequests(corpus, phase);
  final requests = _array(golden['requests'], '$goldenPath requests');
  if (requests.isEmpty) {
    throw FormatException('$goldenPath holds no request trace');
  }
  final actualRequests = [for (final raw in requests) normalizeRequest(raw)];
  if (!_deepEquals(actualRequests, expected)) {
    throw FormatException(
      '$goldenPath request trace is not this corpus phase declaration',
    );
  }
  _goldenRawQueries(
    corpus: corpus,
    golden: golden,
    phase: phase,
    goldenPath: goldenPath,
  );
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

  final steps = stateSessionSteps(corpus, phase);
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
  }

  final requestCheck = _object(
    golden['requestCheck'],
    '$goldenPath requestCheck',
  );
  if (requestCheck['match'] != true ||
      _integer(requestCheck['declaredCount'], 'declaredCount') !=
          expected.length ||
      _integer(requestCheck['actualCount'], 'actualCount') != expected.length) {
    throw FormatException(
      '$goldenPath does not record a matched request trace',
    );
  }
  final observationCheck = _object(
    golden['observationCheck'],
    '$goldenPath observationCheck',
  );
  if (observationCheck['match'] != true ||
      _array(observationCheck['missing'], 'missing').isNotEmpty ||
      _array(observationCheck['extra'], 'extra').isNotEmpty ||
      _array(observationCheck['duplicates'], 'duplicates').isNotEmpty) {
    throw FormatException(
      '$goldenPath does not record a complete observation set',
    );
  }

  final cleanup = _object(golden['cleanup'], '$goldenPath cleanup');
  if (cleanup['databaseClosed'] != true || cleanup['serverClosed'] != true) {
    throw FormatException('$goldenPath did not close its database and server');
  }
  final isolation = _object(golden['isolation'], '$goldenPath isolation');
  if (phase == 'seed') {
    if (cleanup['scratchRetained'] != true ||
        cleanup['scratchRemoved'] != false ||
        isolation['scratchCreatedByThisRun'] != true ||
        isolation['scratchRootExistedAtStart'] != false ||
        cleanup['ownership'] != 'created-fresh-root') {
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
        isolation['scratchCreatedByThisRun'] != false ||
        isolation['scratchRetainedFromSeed'] != true ||
        cleanup['ownership'] != 'validated-seed-owner') {
      throw FormatException('$goldenPath is not a validated restart');
    }
    _checkOwnedPreferences(
      _array(cleanup['preferencesRemoved'], 'preferencesRemoved'),
      goldenPath,
      'removed',
    );
  }

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
  final pinned = _object(handoff['corpus'], 'handoff corpus');
  if (pinned['fixtureId'] != corpus['fixtureId'] ||
      pinned['corpusVersion'] != corpus['corpusVersion'] ||
      pinned['sha256Lf'] != corpusSha256Lf) {
    throw const FormatException('the handoff pins other corpus bytes');
  }
  final pinnedTarget = _object(handoff['target'], 'handoff target');
  if (pinnedTarget['package'] != target['package'] ||
      pinnedTarget['apkSha256'] != target['apkSha256'] ||
      pinnedTarget['baselineCommit'] != target['baselineCommit']) {
    throw const FormatException('the handoff pins another frozen target');
  }
  final harness = _object(handoff['harness'], 'handoff harness');
  final identity = _object(golden['identity'], 'golden identity');
  if (harness['sha256'] != identity['harnessApkSha256']) {
    throw const FormatException('the handoff pins another harness APK');
  }
  final record = _object(handoff[phase], 'handoff $phase');
  if (record['pid'] != golden['pid'] || record['runId'] != golden['runId']) {
    throw const FormatException('the handoff recorded another process');
  }
  if (goldenSha256 != null && record['sha256'] != goldenSha256) {
    throw const FormatException('the golden file is not the handoff capture');
  }
}

void checkStateSessionGoldenPair({
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
  checkStateSessionGolden(
    corpus: corpus,
    corpusSha256Lf: corpusSha256Lf,
    golden: seed,
    phase: 'seed',
    handoff: handoff,
    goldenSha256: seedSha256,
    goldenPath: seedPath,
  );
  checkStateSessionGolden(
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

/// Semantic JSON equality: object member order is ignored, array order and
/// every primitive are exact, and a missing key is not an empty value.
bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is _RawColumnValue || right is _RawColumnValue) {
    return left is _RawColumnValue &&
        right is _RawColumnValue &&
        left.kind == right.kind &&
        _deepEquals(left.value, right.value);
  }
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

/// One raw column's representation kind and parsed value. A null column, valid
/// JSON text (whatever its member order), invalid text including the empty
/// string, and any other value are different observations; the tag keeps them
/// distinct without rewriting the raw value in a report.
class _RawColumnValue {
  const _RawColumnValue(this.kind, this.value);
  final String kind;
  final Object? value;
}

/// A `variableRaw` is JSON text; compare its parsed value, never its member
/// order or indentation. Text that is not JSON stays exact text, and a null
/// column is not the JSON text `null`.
Object? _semanticVariableRaw(Object? value) {
  if (value is Map) {
    final out = <String, Object?>{};
    for (final entry in value.entries) {
      final key = '${entry.key}';
      out[key] = key == 'variableRaw'
          ? _rawColumnValue(entry.value)
          : _semanticVariableRaw(entry.value);
    }
    return out;
  }
  if (value is List) {
    return [for (final item in value) _semanticVariableRaw(item)];
  }
  return value;
}

_RawColumnValue _rawColumnValue(Object? value) {
  if (value == null) return const _RawColumnValue('null-column', null);
  if (value is String) {
    try {
      return _RawColumnValue('json-text', jsonDecode(value));
    } on FormatException {
      return _RawColumnValue('text', value);
    }
  }
  return _RawColumnValue('other', value);
}

Object? _parseVariableText(String text) {
  try {
    return jsonDecode(text);
  } on FormatException {
    return text;
  }
}

void _collectRawTextDifferences(
  Object? expected,
  Object? actual,
  String path,
  List<Map<String, Object?>> out,
) {
  if (expected is Map && actual is Map) {
    for (final key in expected.keys) {
      if (!actual.containsKey(key)) continue;
      final next = path.isEmpty ? '$key' : '$path.$key';
      if (key == 'variableRaw' &&
          expected[key] is String &&
          actual[key] is String &&
          expected[key] != actual[key] &&
          _deepEquals(
            _parseVariableText(expected[key] as String),
            _parseVariableText(actual[key] as String),
          )) {
        out.add({
          'path': next,
          'expected': expected[key],
          'actual': actual[key],
          'note':
              'same parsed JSON; the raw column differs in member order or '
              'indentation and is reported, not normalised',
        });
        continue;
      }
      _collectRawTextDifferences(expected[key], actual[key], next, out);
    }
    return;
  }
  if (expected is List && actual is List) {
    for (
      var index = 0;
      index < expected.length && index < actual.length;
      index++
    ) {
      _collectRawTextDifferences(
        expected[index],
        actual[index],
        '$path[$index]',
        out,
      );
    }
  }
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

/// Compares the two real product phases with the validated frozen captures.
/// Structural problems with a capture throw; a difference between the actual
/// product and the capture is recorded as a failed row.
Map<String, Object?> compareStateSessionPhases({
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
  checkStateSessionGoldenPair(
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
  final target = stateSessionTargetOf(corpus);
  final mismatches = <Map<String, Object?>>[];
  final rawTextDifferences = <Map<String, Object?>>[];
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
      'status ${report['status']}',
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
    );
    final pinned = _object(identity['target'], '$path identity.target');
    check(
      'product-target-identity-$phase',
      pinned['package'] == target['package'] &&
          pinned['apkSha256'] == target['apkSha256'] &&
          pinned['baselineCommit'] == target['baselineCommit'],
      'target ${pinned['package']} ${pinned['apkSha256']}',
    );
    final library = _object(identity['library'], '$path identity.library');
    final libraryHash = library['sha256'];
    productLibraryHashes.add(libraryHash);
    check(
      'product-library-identity-$phase',
      _isSha256(libraryHash) &&
          (librarySha256 == null || libraryHash == librarySha256),
      'library ${library['path']} $libraryHash',
    );
    check(
      'product-process-identity-$phase',
      _integer(report['pid'], '$path pid') > 0 &&
          report['runId'] is String &&
          '${report['runId']}'.isNotEmpty,
      'pid ${report['pid']} run ${report['runId']}',
    );
    if (report['analysisFailure'] != null) {
      mismatches.add({
        'phase': phase,
        'surface': 'analysisFailure',
        'detail': '${report['analysisFailure']}',
      });
    }
    final requests = _array(report['requests'], '$path requests');
    final expectedRequests = _expectedRequests(corpus, phase);
    final actualRequests = [for (final raw in requests) normalizeRequest(raw)];
    final golden = phase == 'seed' ? seedGolden : restartGolden;
    final goldenPath = phase == 'seed' ? seedGoldenPath : restartGoldenPath;
    final goldenRawQueries = _goldenRawQueries(
      corpus: corpus,
      golden: golden,
      phase: phase,
      goldenPath: goldenPath,
    );
    check(
      'product-requests-$phase',
      _deepEquals(actualRequests, expectedRequests),
      '${actualRequests.length} requests, ${expectedRequests.length} declared',
    );
    if (!_deepEquals(actualRequests, expectedRequests)) {
      mismatches.add({
        'phase': phase,
        'surface': 'requests',
        'expected': expectedRequests,
        'actual': actualRequests,
      });
    }
    final unmatched = _array(
      report['unmatchedRequests'],
      '$path unmatchedRequests',
    );
    check(
      'product-unmatched-$phase',
      unmatched.isEmpty,
      '${unmatched.length} undeclared requests',
    );
    final requestCheck = _object(report['requestCheck'], '$path requestCheck');
    check(
      'product-request-check-$phase',
      requestCheck['match'] == true &&
          requestCheck['declaredCount'] == expectedRequests.length &&
          requestCheck['actualCount'] == actualRequests.length,
      requestCheck['mismatch'] ?? 'matched',
    );

    final rawQueryMismatches = <Map<String, Object?>>[];
    if (requests.length != goldenRawQueries.length) {
      rawQueryMismatches.add({
        'expectedCount': goldenRawQueries.length,
        'actualCount': requests.length,
      });
    } else {
      for (var index = 0; index < requests.length; index++) {
        final request = _object(requests[index], '$path request $index');
        final actual = request['rawQuery'];
        final expected = goldenRawQueries[index];
        if (actual is! String) {
          rawQueryMismatches.add({
            'index': index,
            'expected': expected,
            'actual': actual,
            'detail': 'rawQuery is missing or not a string',
          });
        } else if (actual != expected) {
          rawQueryMismatches.add({
            'index': index,
            'expected': expected,
            'actual': actual,
          });
        }
      }
    }
    check(
      'product-raw-query-$phase',
      rawQueryMismatches.isEmpty,
      rawQueryMismatches.isEmpty
          ? '${goldenRawQueries.length} exact raw queries'
          : rawQueryMismatches,
      phase: phase,
    );

    final steps = stateSessionSteps(corpus, phase);
    final observations = _array(report['observations'], '$path observations');
    final actualIds = [for (final raw in observations) '${(raw as Map)['id']}'];
    final declaredIds = [for (final step in steps) '${step['id']}'];
    check(
      'product-observations-$phase',
      observations.isNotEmpty && _deepEquals(actualIds, declaredIds),
      '${actualIds.length} observations, ${declaredIds.length} declared',
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
      if (goldenIndex < 0 || !row.containsKey('value')) {
        mismatches.add({
          'phase': phase,
          'surface': 'observation',
          'id': id,
          'detail': 'unknown id or no value',
        });
        continue;
      }
      final expected = goldenRows[goldenIndex]['value'];
      final actual = row['value'];
      if (!_deepEquals(
        _semanticVariableRaw(expected),
        _semanticVariableRaw(actual),
      )) {
        mismatches.add({
          'phase': phase,
          'surface': 'observation',
          'id': id,
          'expected': expected,
          'actual': actual,
        });
      }
      _collectRawTextDifferences(
        expected,
        actual,
        '$id.value',
        rawTextDifferences,
      );
    }
    check(
      'product-observation-check-$phase',
      _object(report['observationCheck'], '$path observationCheck')['match'] ==
          true,
      'recorded observation check',
    );

    final cleanup = _object(report['cleanup'], '$path cleanup');
    final isolation = _object(report['isolation'], '$path isolation');
    final owner = _object(report['owner'], '$path owner');
    if (phase == 'seed') {
      check(
        'product-seed-cleanup',
        cleanup['databaseClosed'] == true &&
            cleanup['serverClosed'] == true &&
            cleanup['nativeLibraryDisposed'] == true &&
            cleanup['ownerWritten'] == true &&
            cleanup['scratchRetained'] == true &&
            cleanup['scratchRemoved'] == false &&
            isolation['createdByThisRun'] == true &&
            isolation['validatedOwner'] == false &&
            isolation['validatedOwnerSha256'] == null &&
            owner['written'] == true,
        'retained ${isolation['root']}',
      );
    } else {
      check(
        'product-restart-cleanup',
        cleanup['databaseClosed'] == true &&
            cleanup['serverClosed'] == true &&
            cleanup['nativeLibraryDisposed'] == true &&
            cleanup['scratchRemoved'] == true &&
            cleanup['rootAbsentAfter'] == true &&
            cleanup['scratchRetained'] == false &&
            isolation['validatedOwner'] == true &&
            isolation['createdByThisRun'] == false &&
            owner['validated'] == true,
        'removed ${isolation['root']}',
      );
    }
    final ownerSha = cleanup['ownerSha256'];
    check(
      'product-owner-hash-$phase',
      _isSha256(ownerSha),
      'owner sha $ownerSha',
    );
    final startedAt = DateTime.tryParse('${report['startedAt']}');
    final completedAt = DateTime.tryParse('${report['completedAt']}');
    check(
      'product-timing-$phase',
      startedAt != null &&
          completedAt != null &&
          !completedAt.isBefore(startedAt),
      '${report['startedAt']} -> ${report['completedAt']}',
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
        rootExistence,
    'seed ${seedIsolation['root']} -> restart ${restartIsolation['root']}; '
        'agree=$rootPathsAgree inside=$rootPathsInside owner=$ownerBindings '
        'prefs=$preferenceBoundary existence=$rootExistence',
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

  final javaPolicy = <String, Object?>{};
  try {
    javaPolicy.addAll(
      _checkJavaPolicy(
        corpus: corpus,
        seed: seedProduct,
        restart: restartProduct,
        mismatches: mismatches,
      ),
    );
  } on FormatException catch (error) {
    mismatches.add({
      'phase': 'policy',
      'surface': 'java',
      'detail': error.message,
    });
  }

  final failedSurfaces = <String>[
    for (final mismatch in mismatches) '${mismatch['surface']}',
  ];
  final pass = mismatches.isEmpty;
  return {
    'status': pass ? 'pass' : 'fail',
    'mode': 'state-session',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'corpusSha256Lf': corpusSha256Lf,
    'target': target,
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
    'failedSurfaces': failedSurfaces,
    'rawTextDifferences': rawTextDifferences,
    'javaPolicy': javaPolicy,
    'notCompared': [
      for (final raw in (corpus['policyRows'] as List))
        {
          'id': (raw as Map)['id'],
          'status': raw['status'],
          'reason': raw['reason'],
          'owner': raw['owner'],
        },
    ],
    'coverageGaps': corpus['coverageGaps'],
  };
}

/// The product-side java policy rows, checked independently of the 26 frozen
/// observation ids: every source reads only its own key, and the restart reads
/// what the seed wrote.
Map<String, Object?> _checkJavaPolicy({
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> seed,
  required Map<String, dynamic> restart,
  required List<Map<String, Object?>> mismatches,
}) {
  final urls = [
    for (final raw in (corpus['sources'] as List))
      '${((raw as Map)['bookSource'] as Map)['bookSourceUrl']}',
  ];
  if (urls.length != stateSessionJavaPolicyKeys.length) {
    throw const FormatException(
      'the corpus does not declare one java policy key per source',
    );
  }
  final expected = {
    for (var index = 0; index < urls.length; index++)
      urls[index]: 'java-${index == 0 ? 'A' : 'B'}-seed',
  };
  final expectedRowKeys = [
    for (final url in urls)
      for (final key in stateSessionJavaPolicyKeys) 'v_${url}_$key',
  ]..sort();
  final result = <String, Object?>{};
  for (final entry in <String, Map<String, dynamic>>{
    'seed': seed,
    'restart': restart,
  }.entries) {
    final phase = entry.key;
    final report = entry.value;
    final errors = <String>[];
    Object? sources;
    Object? rows;
    Object? declaredPhase;
    Object? declaredVerdict;
    try {
      final policy = _object(report['javaPolicy'], '$phase javaPolicy');
      declaredPhase = policy['phase'];
      declaredVerdict = policy['verdict'];
      if (policy['phase'] != phase) {
        errors.add('the receipt names phase ${policy['phase']}');
      }
      if (policy['verdict'] != 'pass') {
        errors.add('the receipt verdict is ${policy['verdict']}');
      }
      if (policy['policy'] is! String || '${policy['policy']}'.trim().isEmpty) {
        errors.add('the receipt carries no policy statement');
      }
      if (!_deepEquals(policy['keys'], stateSessionJavaPolicyKeys)) {
        errors.add('the receipt keys are not the declared policy keys');
      }
      if (!_deepEquals(policy['expected'], expected)) {
        errors.add('the declared policy values are not the corpus sources');
      }
      sources = policy['sources'];
      rows = policy['rows'];
      final sourceMap = _object(sources, '$phase javaPolicy.sources');
      final actualUrls = [...sourceMap.keys]..sort();
      final declaredUrls = [...urls]..sort();
      if (!_deepEquals(actualUrls, declaredUrls)) {
        errors.add('the receipt sources are ${actualUrls.join(', ')}');
      }
      for (var index = 0; index < urls.length; index++) {
        final url = urls[index];
        final own = stateSessionJavaPolicyKeys[index];
        final other = stateSessionJavaPolicyKeys[1 - index];
        final reads = _object(sourceMap[url], '$phase javaPolicy $url');
        for (final surface in ['java', 'source']) {
          final values = _object(reads[surface], '$phase $surface reads');
          final ok = values[own] == expected[url] && values[other] == '';
          if (!ok) {
            errors.add('$surface reads ${jsonEncode(values)} for $url');
          }
        }
      }
      final rowList = _array(rows, '$phase javaPolicy.rows');
      final actualRowKeys = <String>[];
      for (final raw in rowList) {
        final row = _object(raw, '$phase javaPolicy row');
        if (row['source'] is! String ||
            row['key'] is! String ||
            row['present'] is! bool) {
          errors.add('malformed row ${jsonEncode(row)}');
          continue;
        }
        actualRowKeys.add('${row['key']}');
      }
      final sortedActualRows = [...actualRowKeys]..sort();
      if (!_deepEquals(sortedActualRows, expectedRowKeys)) {
        errors.add('the receipt rows are ${actualRowKeys.join(', ')}');
      }
      for (var index = 0; index < urls.length; index++) {
        final url = urls[index];
        final own = stateSessionJavaPolicyKeys[index];
        final other = stateSessionJavaPolicyKeys[1 - index];
        for (final key in [own, other]) {
          final matching = [
            for (final raw in rowList)
              if ((raw as Map)['source'] == url &&
                  raw['key'] == 'v_${url}_$key')
                raw,
          ];
          final Map? row = matching.length == 1 ? matching.single : null;
          final expectedValue = key == own ? expected[url] : null;
          final ok =
              row != null &&
              row['present'] == (key == own) &&
              row['value'] == expectedValue &&
              (key != own || row['deadline'] == 0);
          if (!ok) {
            errors.add('row v_${url}_$key is ${jsonEncode(row)}');
          }
        }
      }
    } on FormatException catch (error) {
      errors.add('malformed receipt: ${error.message}');
    }
    for (final error in errors) {
      mismatches.add({
        'phase': phase,
        'surface': 'javaPolicy',
        'detail': error,
      });
    }
    result[phase] = {
      'keys': stateSessionJavaPolicyKeys,
      'expected': expected,
      'sources': sources,
      'rows': rows,
      'verdict': errors.isEmpty ? 'pass' : 'fail',
      'errors': errors,
      'declaredPhase': declaredPhase,
      'declaredVerdict': declaredVerdict,
    };
  }
  return result;
}

// --------------------------------------------------------------------------
// CLI: run both phases, then compare and run the controls
// --------------------------------------------------------------------------

Map<String, String> _namedOptions(List<String> args) {
  final options = <String, String>{};
  for (final arg in args) {
    if (!arg.startsWith('--')) continue;
    if (arg == '--compare-only') continue;
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
  final corpusFile = File(stateSessionCorpusPath);
  final corpus = loadStateSessionCorpus(stateSessionCorpusPath);
  final corpusLf = stateSessionCorpusSha256Lf(corpusFile);
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
  checkStateSessionGoldenPair(
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
    'tool/state_session/runner.dart',
    'seed',
    libraryPath,
    root,
    seedReport,
    '--expected-corpus-sha256=$corpusLf',
  ], logPath: '${evidence.path}${Platform.pathSeparator}seed-runner.log');
  final restartRun = await _runProcess([
    'run',
    'tool/state_session/runner.dart',
    'restart',
    libraryPath,
    root,
    restartReport,
    '--expected-corpus-sha256=$corpusLf',
  ], logPath: '${evidence.path}${Platform.pathSeparator}restart-runner.log');
  final seedProduct = _readJsonOrNull(seedReport);
  final restartProduct = _readJsonOrNull(restartReport);
  Map<String, Object?> report;
  try {
    if (seedProduct == null || restartProduct == null) {
      throw FormatException('the runner did not write a phase report');
    }
    report = compareStateSessionPhases(
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
      'mode': 'state-session',
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
    'state-session comparison: ${report['status']} '
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

/// Demonstrates that the comparator rejects changed values, requests and
/// identities. Every control is a copy of the real captured report or of the
/// real product report; the originals are never written and are hashed again
/// after the run.
Future<Map<String, Object?>> _runNegativeControls({
  required Directory evidence,
  required String libraryPath,
  required String seedGoldenPath,
  required String restartGoldenPath,
  required String seedProductPath,
  required String restartProductPath,
  required String seedGoldenSha,
  required String restartGoldenSha,
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

  void mutateObservationValue(Map<String, dynamic> report) {
    final observations = report['observations'] as List;
    final first = (observations.first as Map).cast<String, dynamic>();
    final value = first['value'];
    first['value'] = value is Map
        ? {...value, '__mutationControl': 'changed-actual-value'}
        : 'mutated:${'$value'}';
  }

  void appendRequest(Map<String, dynamic> report) {
    (report['requests'] as List).add({
      'method': 'GET',
      'path': '/mutated-control',
      'query': <String, String>{},
      'headers': <String, String>{},
      'body': '',
    });
  }

  void swapRequests(Map<String, dynamic> report) {
    final requests = report['requests'] as List;
    if (requests.length < 2) {
      appendRequest(report);
      return;
    }
    final first = requests[0];
    requests[0] = requests[1];
    requests[1] = first;
  }

  void setRawQuery(Map<String, dynamic> report, String value) {
    ((report['requests'] as List).first as Map)['rawQuery'] = value;
  }

  void removeRawQuery(Map<String, dynamic> report) {
    ((report['requests'] as List).first as Map).remove('rawQuery');
  }

  final goldenSeedValue = copy(seedGolden)..also(mutateObservationValue);
  final goldenSeedRequests = copy(seedGolden)..also(swapRequests);
  final goldenSeedIdentity = copy(seedGolden);
  (goldenSeedIdentity['identity'] as Map)['targetApkSha256'] =
      '0000000000000000000000000000000000000000000000000000000000000000';
  final productSeedValue = copy(seedProduct)..also(mutateObservationValue);
  final productSeedRequests = copy(seedProduct)..also(appendRequest);
  final productSeedRawOrder = copy(seedProduct)
    ..also((report) => setRawQuery(report, 'page=1&keyword=state'));
  final productSeedRawEncoding = copy(seedProduct)
    ..also((report) => setRawQuery(report, 'keyword=%73tate&page=1'));
  final productSeedRawAbsent = copy(seedProduct)..also(removeRawQuery);
  final productRestartIdentity = copy(restartProduct);
  (productRestartIdentity['identity'] as Map)['corpusSha256Lf'] =
      '0000000000000000000000000000000000000000000000000000000000000000';

  Future<void> control(
    String name,
    int expectedExit, {
    required String goldenSeed,
    required String goldenRestart,
    required String productSeed,
    required String productRestart,
    required String mutation,
    String? requiredSurface,
  }) async {
    final out = '${directory.path}${Platform.pathSeparator}$name-report.json';
    final log = '${directory.path}${Platform.pathSeparator}$name.log';
    final args = [
      'run',
      'tool/state_session/compare.dart',
      '--compare-only',
      productSeed,
      productRestart,
      '--golden-seed=$goldenSeed',
      '--golden-restart=$goldenRestart',
      '--library=$libraryPath',
      '--out=$out',
    ];
    final run = await _runProcess(args, logPath: log);
    final output = _readJsonOrNull(out);
    final checks = output?['checks'];
    final failedChecks = <String>[
      if (checks is Map)
        for (final entry in checks.entries)
          if (entry.value is Map && (entry.value as Map)['ok'] != true)
            '${entry.key}',
    ];
    final mismatchSurfaces = <String>[
      if (output?['mismatches'] is List)
        for (final raw in output!['mismatches'] as List)
          if (raw is Map && raw['surface'] is String) '${raw['surface']}',
    ]..sort();
    final surfaceHit =
        requiredSurface == null ||
        failedChecks.contains(requiredSurface) ||
        mismatchSurfaces.contains(requiredSurface);
    controls.add({
      'name': name,
      'mutation': mutation,
      'expectedExit': expectedExit,
      'actualExit': run.exitCode,
      'requiredSurface': requiredSurface,
      'failedChecks': failedChecks,
      'mismatchSurfaces': mismatchSurfaces,
      'passed': run.exitCode == expectedExit && surfaceHit,
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
    mutation: 'a copied seed capture changed one observed value',
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
    'golden-identity-mutation',
    2,
    goldenSeed: writeCopy('golden-seed-identity', goldenSeedIdentity),
    goldenRestart: restartGoldenPath,
    productSeed: seedProductPath,
    productRestart: restartProductPath,
    mutation: 'a copied seed capture named another target APK',
  );
  await control(
    'product-value-mutation',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-value', productSeedValue),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report changed one observed value',
  );
  await control(
    'product-request-mutation',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-requests', productSeedRequests),
    productRestart: restartProductPath,
    mutation: 'a copied product seed report added an undeclared request',
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
  );

  await control(
    'product-raw-query-order',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy('product-seed-raw-query-order', productSeedRawOrder),
    productRestart: restartProductPath,
    requiredSurface: 'product-raw-query-seed',
    mutation: 'a copied product seed report reordered the first raw query',
  );
  await control(
    'product-raw-query-encoding',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy(
      'product-seed-raw-query-encoding',
      productSeedRawEncoding,
    ),
    productRestart: restartProductPath,
    requiredSurface: 'product-raw-query-seed',
    mutation:
        'a copied product seed report percent-encoded the first raw query',
  );
  await control(
    'product-raw-query-absent',
    1,
    goldenSeed: seedGoldenPath,
    goldenRestart: restartGoldenPath,
    productSeed: writeCopy(
      'product-seed-raw-query-absent',
      productSeedRawAbsent,
    ),
    productRestart: restartProductPath,
    requiredSurface: 'product-raw-query-seed',
    mutation: 'a copied product seed report omitted the first raw query',
  );

  final originalsUnchanged =
      sha256File(File(seedGoldenPath)) == seedGoldenSha &&
      sha256File(File(restartGoldenPath)) == restartGoldenSha;
  final failed = controls
      .where((control) => control['passed'] != true)
      .toList();
  return {
    'status': failed.isEmpty && originalsUnchanged ? 'pass' : 'fail',
    'immutableCapturesUnchanged': originalsUnchanged,
    'controls': controls,
    'failedControls': [for (final control in failed) control['name']],
  };
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
    final corpus = loadStateSessionCorpus(stateSessionCorpusPath);
    final corpusLf = stateSessionCorpusSha256Lf(File(stateSessionCorpusPath));
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
    report = compareStateSessionPhases(
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
      'mode': 'state-session-compare',
      'analysisFailure': error.message,
    };
  } on Object catch (error) {
    report = {
      'status': 'refused',
      'mode': 'state-session-compare',
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
