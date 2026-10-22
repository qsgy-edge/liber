import 'dart:convert';
import 'dart:io';

import 'runner.dart'
    show
        HttpBoundaryRefusal,
        httpBoundaryCorpusPath,
        httpBoundaryCorpusSha256Lf,
        httpBoundaryDeclaredRequests,
        httpBoundaryObservationIds,
        httpBoundaryResponseOwners,
        httpBoundaryResponses,
        httpBoundarySelectorOf,
        httpBoundarySourceOf,
        httpBoundarySteps,
        httpBoundaryStructuralOf,
        httpBoundaryTargetOf,
        loadHttpBoundaryCorpus,
        sha256File,
        sha256Text;

/// Compares one measured product record with both immutable frozen captures of
/// the controller's hash-bound handoff.
///
/// Usage:
///   `dart run tool/http_boundary/compare.dart --handoff=&lt;json&gt; \
///     --product=&lt;report.json&gt; --evidence=&lt;dir&gt;`
///
/// The comparison is strict over the corpus' portable surface: observations and
/// their values with presence, the causal request trace with its owners, raw
/// query bytes, body bytes, source-controlled headers and attempt kinds, the
/// family outcomes and the product's own receipts. The documented exclusions
/// are the corpus' own `nondeterministic` list plus the row position, the
/// header name case/order and the platform-generated headers the differential
/// contract names. Every other difference is a failure with its expected and
/// observed values; nothing is turned into an exemption.
const httpBoundaryCompareSurface = {
  'observations': ['id', 'outcome', 'category', 'value', 'requests'],
  'requests': [
    'owner',
    'family',
    'cohort',
    'attempt',
    'attemptKind',
    'selector',
    'method',
    'path',
    'rawQuery',
    'query',
    'target',
    'headers',
    'body',
    'bodyLength',
    'bodySha256',
    'status',
    'terminal',
    'declaredResponse',
    'outcome',
    'cohortComplete',
    'releaseReason',
  ],
};

/// The differential contract's platform-generated headers: ignored unless the
/// source sets them itself. A source-controlled header of the same name would
/// still be compared on both sides, because the filter only drops a name the
/// corpus does not declare as required or forbidden.
const httpBoundaryPlatformHeaders = {
  'host',
  'content-length',
  'accept-encoding',
  'connection',
};

/// One mismatch: which surface, which row, which field, and both values.
class HttpBoundaryMismatch {
  const HttpBoundaryMismatch({
    required this.surface,
    required this.row,
    required this.field,
    required this.expected,
    required this.observed,
    this.kind = 'value',
  });

  final String surface;
  final String row;
  final String field;
  final Object? expected;
  final Object? observed;
  final String kind;

  String get key => '$surface|$row|$field|$kind';

  Map<String, Object?> toJson() => {
    'surface': surface,
    'row': row,
    'field': field,
    'kind': kind,
    'expected': expected,
    'observed': observed,
  };

  @override
  String toString() =>
      '[$kind] $surface $row $field: expected ${jsonEncode(expected)}, '
      'observed ${jsonEncode(observed)}';
}

/// One compared pair: the product record against one frozen capture.
class HttpBoundaryComparison {
  HttpBoundaryComparison({
    required this.goldenId,
    required this.mismatches,
    required this.notes,
  });

  final String goldenId;
  final List<HttpBoundaryMismatch> mismatches;
  final List<String> notes;

  bool get passed => mismatches.isEmpty;

  Map<String, Object?> toJson() => {
    'golden': goldenId,
    'passed': passed,
    'mismatchCount': mismatches.length,
    'mismatches': [for (final mismatch in mismatches) mismatch.toJson()],
    'notes': notes,
  };
}

Map<String, dynamic> loadHttpBoundaryReport(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    throw HttpBoundaryRefusal('the report does not exist: $path');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map) {
    throw HttpBoundaryRefusal('the report is not a JSON object: $path');
  }
  return decoded.cast<String, dynamic>();
}

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw HttpBoundaryRefusal('$what is not a JSON object');
}

List<dynamic> _array(Object? value, String what) {
  if (value is List) return value;
  throw HttpBoundaryRefusal('$what is not a JSON array');
}

bool _isNegativeMode(Map<String, dynamic> report) =>
    report['negativeMode'] == true;

/// The frozen capture's own gates. A capture that fails one of these is not an
/// input, so the comparison refuses before any value is compared.
void validateFrozenCapture(
  Map<String, dynamic> golden, {
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String goldenId,
  required String expectedReportSha256,
  required String reportPath,
}) {
  final actualSha = sha256File(File(reportPath));
  if (actualSha != expectedReportSha256) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId report is $actualSha, the handoff pins '
      '$expectedReportSha256',
    );
  }
  if (golden['fixtureId'] != corpus['fixtureId'] ||
      golden['corpusVersion'] != corpus['corpusVersion'] ||
      golden['baselineCommit'] != corpus['baselineCommit']) {
    throw HttpBoundaryRefusal('the capture $goldenId names another corpus');
  }
  if (golden['status'] != 'ok' || golden['promotable'] != true) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId is ${golden['status']}/promotable='
      '${golden['promotable']}, not a promotable positive',
    );
  }
  if (_isNegativeMode(golden)) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId is a negative-mode control, never a golden',
    );
  }
  if (golden['negative'] != null) {
    throw HttpBoundaryRefusal('the capture $goldenId carries a negative block');
  }
  final identity = _object(golden['identity'], 'capture $goldenId identity');
  if (identity['corpusSha256Lf'] != corpusLf) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId measured another corpus: '
      '${identity['corpusSha256Lf']}',
    );
  }
  final target = httpBoundaryTargetOf(corpus);
  if (identity['targetApkSha256'] != target['apkSha256'] ||
      identity['targetBaselineCommit'] != target['baselineCommit'] ||
      identity['targetPackage'] != target['package']) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId ran another frozen target',
    );
  }
  // The capture's bundled asset is checked against the asset its own capture
  // manifest pinned, never against whatever line endings this checkout happens
  // to have. The canonical LF hash above is the semantic corpus identity, so an
  // LF or a CRLF working copy of the same corpus is equally acceptable.
  final assetSha = '${identity['corpusAssetSha256']}';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(assetSha)) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId records no corpus asset hash',
    );
  }
  final capturedAsset = corpus['_capturedAssetSha256'];
  if (capturedAsset is String && capturedAsset.isNotEmpty) {
    if (assetSha != capturedAsset) {
      throw HttpBoundaryRefusal(
        'the capture $goldenId bundled another corpus asset: $assetSha, the '
        'handoff pins $capturedAsset',
      );
    }
  }
  final structural = _object(
    golden['structural'],
    'capture $goldenId structural',
  );
  if (structural['match'] != true) {
    throw HttpBoundaryRefusal('the capture $goldenId structural model differs');
  }
  if (golden['terminalIntegrityOk'] != true) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId has no terminal integrity receipt',
    );
  }
  final requestCheck = _object(golden['requestCheck'], 'capture requestCheck');
  if (requestCheck['match'] != true) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId request trace does not match the corpus',
    );
  }
  final observationCheck = _object(
    golden['observationCheck'],
    'capture observationCheck',
  );
  if (observationCheck['match'] != true) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId observation set does not match the corpus',
    );
  }
  if (_array(golden['unmatchedRequests'], 'capture unmatched').isNotEmpty) {
    throw HttpBoundaryRefusal('the capture $goldenId has unmatched requests');
  }
  if (_array(golden['serverErrors'], 'capture serverErrors').isNotEmpty) {
    throw HttpBoundaryRefusal('the capture $goldenId has server errors');
  }
  final cleanup = _object(golden['cleanup'], 'capture cleanup');
  final terminal = _object(cleanup['terminal'], 'capture cleanup terminal');
  if (terminal['integrityOk'] != true) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId has no cleanup integrity receipt',
    );
  }
  final declaredObservations = _integerOf(
    _object(corpus['structural'], 'corpus structural')['observations'],
    'structural.observations',
  );
  if (_array(golden['observations'], 'capture observations').length !=
      declaredObservations) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId has ${_array(golden['observations'], 'obs').length} '
      'observations, the corpus declares $declaredObservations',
    );
  }
}

int _integerOf(Object? value, String what) {
  if (value is int) return value;
  throw HttpBoundaryRefusal('$what is not an integer');
}

// --- the product record's own schema, recomputed from its rows ---------------

/// The kinds the compared record declares. A JSON integer decodes to `int`; a
/// number written as `200.0` decodes to `double` and is therefore a refusal, so
/// a widened type can never pass as the declared one.
enum _Field {
  string,
  integer,
  boolean,
  object,
  array,
  nullableString,
  nullableBoolean,
  nullableObject;

  String get description => switch (this) {
    _Field.string => 'a string',
    _Field.integer => 'an integer',
    _Field.boolean => 'a boolean',
    _Field.object => 'an object',
    _Field.array => 'an array',
    _Field.nullableString => 'a string or null',
    _Field.nullableBoolean => 'a boolean or null',
    _Field.nullableObject => 'an object or null',
  };
}

/// One bounded validator for the product record: field presence and type, the
/// headline booleans checked against the rows they summarise, the receipts
/// checked against each other, the rate records' own interval/window relations
/// and the causal chronology. It replaces a patch per counterexample with one
/// declared shape plus the relations that shape claims.
class _ProductGate {
  _ProductGate(this.corpus)
    : stepIds = [for (final step in httpBoundarySteps(corpus)) '${step['id']}'],
      responseById = {
        for (final response in httpBoundaryResponses(corpus))
          '${response['id']}': response,
      },
      owners = httpBoundaryResponseOwners(corpus);

  final Map<String, dynamic> corpus;
  final List<String> stepIds;
  final Map<String, Map<String, dynamic>> responseById;
  final Map<String, ({String step, String family, String? cohort})> owners;
  final problems = <String>[];

  void fail(String message) {
    if (problems.length < 40) problems.add(message);
  }

  void throwIfAny() {
    if (problems.isEmpty) return;
    throw HttpBoundaryRefusal(
      'the product record is not a truthful measurement: ${problems.join('; ')}',
    );
  }

  Map<String, dynamic> object(Object? value, String path) {
    if (value is Map) return value.cast<String, dynamic>();
    fail('$path is not an object');
    return <String, dynamic>{};
  }

  List<dynamic> array(Object? value, String path) {
    if (value is List) return value;
    fail('$path is not an array');
    return const <Object?>[];
  }

  /// One declared field: it must be present, and its decoded type must be the
  /// declared one.
  void field(Map<String, dynamic> map, String key, String path, _Field kind) {
    final where = path.isEmpty ? key : '$path.$key';
    if (!map.containsKey(key)) {
      fail('$where is missing');
      return;
    }
    final value = map[key];
    final ok = switch (kind) {
      _Field.string => value is String,
      _Field.integer => value is int,
      _Field.boolean => value is bool,
      _Field.object => value is Map,
      _Field.array => value is List,
      _Field.nullableString => value == null || value is String,
      _Field.nullableBoolean => value == null || value is bool,
      _Field.nullableObject => value == null || value is Map,
    };
    if (!ok) fail('$where is ${value.runtimeType}, not ${kind.description}');
  }

  void emptyArray(Object? value, String path) {
    final list = array(value, path);
    if (list.isNotEmpty) fail('$path is not empty: ${list.length} entries');
  }

  void isTrue(Object? value, String path) {
    if (value != true) fail('$path is $value, not true');
  }

  /// Semantic equality: object key order is not a fact (the differential
  /// contract ignores it), while arrays, duplicate values and every scalar keep
  /// their order and their type. A decoded `1.0` is not the integer `1`.
  void equal(Object? actual, Object? expected, String path) {
    if (!_semanticEquals(actual, expected)) {
      fail(
        '$path is ${jsonEncode(actual)}, the declared value is '
        '${jsonEncode(expected)}',
      );
    }
  }

  String string(Map<String, dynamic> map, String key, String path) {
    field(map, key, path, _Field.string);
    final value = map[key];
    return value is String ? value : '';
  }

  int integer(Map<String, dynamic> map, String key, String path) {
    field(map, key, path, _Field.integer);
    final value = map[key];
    return value is int ? value : 0;
  }
}

String _normalizePath(String path) => path.replaceAll('\\', '/');

/// One corpus source's own key, the address its rate records and cancellation
/// evidence are keyed by. The failure source's `$FAILPORT` token is a binding,
/// not part of its key, so it is reported as it is declared only when no rate or
/// cancellation row uses that source.
String corpusSourceUrl(Map<String, dynamic> corpus, String id) =>
    '${httpBoundarySourceOf(corpus, id)['bookSourceUrl']}';

/// Recursive equality that ignores object key order and nothing else: arrays
/// keep their order (including repeated values), scalars keep their exact type
/// and value, and an absent key is not a null value.
bool _semanticEquals(Object? actual, Object? expected) {
  if (actual is Map || expected is Map) {
    if (actual is! Map || expected is! Map) return false;
    if (actual.length != expected.length) return false;
    for (final entry in actual.entries) {
      if (!expected.containsKey(entry.key)) return false;
      if (!_semanticEquals(entry.value, expected[entry.key])) return false;
    }
    return true;
  }
  if (actual is List || expected is List) {
    if (actual is! List || expected is! List) return false;
    if (actual.length != expected.length) return false;
    for (var index = 0; index < actual.length; index++) {
      if (!_semanticEquals(actual[index], expected[index])) return false;
    }
    return true;
  }
  if (actual == null || expected == null) return actual == expected;
  if (actual.runtimeType != expected.runtimeType) return false;
  return actual == expected;
}

/// The product record's own gates: a finished run of the same corpus whose every
/// compared field is present and correctly typed, whose headline checks agree
/// with the rows they summarise, whose receipts agree with each other and whose
/// identity is bound to the files and roots this comparison can actually see.
void validateProductReport(
  Map<String, dynamic> product, {
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String productPath,
  Directory? workingDirectory,
}) {
  final gate = _ProductGate(corpus);
  final cwd = workingDirectory ?? Directory.current;

  // 1. The top level.
  if (product['status'] != 'completed') {
    throw HttpBoundaryRefusal(
      'the product run is ${product['status']}, not completed: '
      '${product['analysisFailure']}',
    );
  }
  for (final entry in const [
    ('schemaVersion', _Field.integer),
    ('product', _Field.string),
    ('platform', _Field.string),
    ('pid', _Field.integer),
    ('runId', _Field.string),
    ('recordedAt', _Field.string),
    ('completedAt', _Field.string),
    ('captureKind', _Field.string),
    ('fixtureId', _Field.string),
    ('corpusVersion', _Field.integer),
    ('baselineCommit', _Field.string),
    ('entryPoint', _Field.string),
    ('status', _Field.string),
    ('analysisFailure', _Field.nullableString),
    ('negativeMode', _Field.boolean),
    ('structural', _Field.object),
    ('identity', _Field.object),
    ('isolation', _Field.object),
    ('runtimeConfiguration', _Field.object),
    ('rateLimiter', _Field.object),
    ('failEndpoint', _Field.object),
    ('stageTrace', _Field.array),
    ('requests', _Field.array),
    ('unmatchedRequests', _Field.array),
    ('serverErrors', _Field.array),
    ('requestCheck', _Field.object),
    ('observations', _Field.array),
    ('observationCheck', _Field.object),
    ('inventory', _Field.object),
    ('cleanup', _Field.object),
    ('sourceDerivedNotes', _Field.object),
    ('coverageGaps', _Field.array),
    ('nondeterministic', _Field.array),
  ]) {
    gate.field(product, entry.$1, '', entry.$2);
  }
  if (product['analysisFailure'] != null) {
    gate.fail('analysisFailure is not null on a completed run');
  }
  if (product['negativeMode'] != false) {
    gate.fail('negativeMode is ${product['negativeMode']}, not false');
  }
  if (!product.containsKey('negative') || product['negative'] != null) {
    gate.fail('negative is not the explicit null of a positive run');
  }
  if (product['captureKind'] != 'product') {
    gate.fail('captureKind is ${product['captureKind']}, not product');
  }
  if (product['product'] != 'liber-http-boundary-runner') {
    gate.fail('product names another runner');
  }
  if (product['fixtureId'] != corpus['fixtureId'] ||
      product['corpusVersion'] != corpus['corpusVersion'] ||
      product['baselineCommit'] != corpus['baselineCommit']) {
    gate.fail('the run names another corpus');
  }

  // 2. Identity, bound to the files this comparison can actually resolve.
  final identity = gate.object(product['identity'], 'identity');
  for (final entry in const [
    ('fixtureId', _Field.string),
    ('corpusVersion', _Field.integer),
    ('baselineCommit', _Field.string),
    ('entryPoint', _Field.string),
    ('corpusPath', _Field.string),
    ('corpusRawSha256', _Field.string),
    ('corpusSha256Lf', _Field.string),
    ('corpusRawLineEndings', _Field.string),
    ('target', _Field.object),
    ('library', _Field.object),
    ('runner', _Field.object),
  ]) {
    gate.field(identity, entry.$1, 'identity', entry.$2);
  }
  if (identity['corpusSha256Lf'] != corpusLf) {
    gate.fail('identity.corpusSha256Lf is another corpus');
  }
  final identityTarget = gate.object(identity['target'], 'identity.target');
  final target = httpBoundaryTargetOf(corpus);
  for (final entry in const [
    ('package', _Field.string),
    ('apkSha256', _Field.string),
    ('baselineCommit', _Field.string),
    ('manifest', _Field.string),
  ]) {
    gate.field(identityTarget, entry.$1, 'identity.target', entry.$2);
  }
  if (identityTarget['package'] != target['package'] ||
      identityTarget['apkSha256'] != target['apkSha256'] ||
      identityTarget['baselineCommit'] != target['baselineCommit'] ||
      identityTarget['manifest'] != target['manifest']) {
    gate.fail('identity.target is not the corpus target pin');
  }
  final library = gate.object(identity['library'], 'identity.library');
  gate.field(library, 'path', 'identity.library', _Field.string);
  gate.field(library, 'sha256', 'identity.library', _Field.string);
  final libraryPath = '${library['path']}';
  final librarySha = '${library['sha256']}';
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(librarySha)) {
    gate.fail('identity.library.sha256 is not a SHA-256');
  }
  final libraryFile = File(libraryPath);
  final resolvedLibrary = libraryFile.isAbsolute
      ? libraryFile
      : File('${cwd.path}${Platform.pathSeparator}$libraryPath');
  if (!resolvedLibrary.existsSync()) {
    gate.fail('identity.library.path does not name a loadable file');
  } else if (sha256File(resolvedLibrary) != librarySha) {
    gate.fail('identity.library.sha256 is not that file');
  }
  final runner = gate.object(identity['runner'], 'identity.runner');
  gate.field(runner, 'path', 'identity.runner', _Field.string);
  gate.field(runner, 'sha256', 'identity.runner', _Field.string);
  if (runner['path'] != 'tool/http_boundary/runner.dart') {
    gate.fail('identity.runner.path is not this lane\'s runner');
  }
  final runnerFile = File(
    '${cwd.path}${Platform.pathSeparator}tool${Platform.pathSeparator}'
    'http_boundary${Platform.pathSeparator}runner.dart',
  );
  if (!runnerFile.existsSync()) {
    gate.fail('identity.runner.path cannot be resolved');
  } else if (runner['sha256'] != sha256File(runnerFile)) {
    gate.fail('identity.runner.sha256 is not the record\'s runner');
  }

  // 3. Isolation and ownership: one root, and every recorded path under it.
  final isolation = gate.object(product['isolation'], 'isolation');
  for (final entry in const [
    ('application', _Field.string),
    ('root', _Field.string),
    ('database', _Field.string),
    ('workspaceManifest', _Field.string),
    ('ownerFile', _Field.string),
    ('rootExistedAtStart', _Field.boolean),
    ('createdByThisRun', _Field.boolean),
    ('preferenceFilesOutsideRoot', _Field.array),
    ('preferenceBoundary', _Field.string),
  ]) {
    gate.field(isolation, entry.$1, 'isolation', entry.$2);
  }
  final root = '${isolation['root']}';
  if (root.isEmpty) gate.fail('isolation.root is empty');
  final normalizedRoot = _normalizePath(root);
  if (normalizedRoot != _normalizePath(isolatedRootOf(root))) {
    gate.fail('isolation.root is not a scratch root this lane can own');
  }
  gate.equal(
    _normalizePath('${isolation['database']}'),
    '$normalizedRoot/spaces/default/data.db',
    'isolation.database',
  );
  gate.equal(
    _normalizePath('${isolation['workspaceManifest']}'),
    '$normalizedRoot/manifest.json',
    'isolation.workspaceManifest',
  );
  gate.equal(
    _normalizePath('${isolation['ownerFile']}'),
    '$normalizedRoot/owner.json',
    'isolation.ownerFile',
  );
  if (isolation['rootExistedAtStart'] != false ||
      isolation['createdByThisRun'] != true) {
    gate.fail('isolation.root is not proven to be this run\'s own fresh root');
  }
  gate.emptyArray(
    isolation['preferenceFilesOutsideRoot'],
    'isolation.preferenceFilesOutsideRoot',
  );

  // 4. Runtime configuration and the rate limiter's own configuration.
  final runtime = gate.object(
    product['runtimeConfiguration'],
    'runtimeConfiguration',
  );
  for (final entry in const [
    ('threadCount', _Field.integer),
    ('threadCountSource', _Field.string),
    ('threadCountPreference', _Field.nullableString),
    ('declaredNativeDefault', _Field.integer),
    ('resolved', _Field.boolean),
  ]) {
    gate.field(runtime, entry.$1, 'runtimeConfiguration', entry.$2);
  }
  gate.equal(runtime['resolved'], true, 'runtimeConfiguration.resolved');
  gate.equal(
    runtime['declaredNativeDefault'],
    _object(corpus['runtime'], 'corpus runtime')['threadCountDefault'],
    'runtimeConfiguration.declaredNativeDefault',
  );
  final rateConfig = gate.object(product['rateLimiter'], 'rateLimiter');
  for (final entry in const [
    ('instance', _Field.string),
    ('reason', _Field.string),
    ('concurrentRate', _Field.string),
    ('windowMillis', _Field.integer),
    ('initialSnapshot', _Field.string),
  ]) {
    gate.field(rateConfig, entry.$1, 'rateLimiter', entry.$2);
  }
  final rate = _object(corpus['rate'], 'corpus rate');
  gate.equal(
    rateConfig['concurrentRate'],
    rate['concurrentRate'],
    'rateLimiter.concurrentRate',
  );
  gate.equal(
    rateConfig['windowMillis'],
    rate['windowMillis'],
    'rateLimiter.windowMillis',
  );
  gate.equal(
    rateConfig['initialSnapshot'],
    'empty',
    'rateLimiter.initialSnapshot',
  );
  final rateWindow = _integerOf(rate['windowMillis'], 'rate.windowMillis');

  // 5. The task-owned failure endpoint's measured connections.
  final failure = gate.object(product['failEndpoint'], 'failEndpoint');
  for (final entry in const [
    ('host', _Field.string),
    ('requestedPort', _Field.integer),
    ('assignedPort', _Field.integer),
    ('armedAtLeastOnce', _Field.boolean),
    ('armedAtNanos', _Field.integer),
    ('acceptedConnections', _Field.integer),
    ('transportReconnects', _Field.integer),
    ('connections', _Field.array),
    ('errors', _Field.array),
    ('closed', _Field.boolean),
    ('classification', _Field.object),
  ]) {
    gate.field(failure, entry.$1, 'failEndpoint', entry.$2);
  }
  if (failure['host'] != '127.0.0.1') {
    gate.fail('failEndpoint.host is not the owned loopback host');
  }
  if (failure['requestedPort'] != 0) {
    gate.fail('failEndpoint.requestedPort is not the ephemeral 0');
  }
  if (failure['assignedPort'] is int && (failure['assignedPort'] as int) <= 0) {
    gate.fail('failEndpoint.assignedPort is not a bound port');
  }
  final connections = gate.array(
    failure['connections'],
    'failEndpoint.connections',
  );
  for (var index = 0; index < connections.length; index++) {
    final connection = gate.object(
      connections[index],
      'failEndpoint.connections.$index',
    );
    for (final entry in const [
      ('index', _Field.integer),
      ('method', _Field.string),
      ('target', _Field.string),
      ('path', _Field.string),
      ('rawQuery', _Field.string),
      ('headers', _Field.object),
      ('armed', _Field.boolean),
      ('classification', _Field.string),
      ('requestObserved', _Field.boolean),
      ('acceptedAtNanos', _Field.integer),
      ('terminal', _Field.string),
      ('closedAtNanos', _Field.integer),
    ]) {
      gate.field(
        connection,
        entry.$1,
        'failEndpoint.connections.$index',
        entry.$2,
      );
    }
    if (!const {
      'initial',
      'transport-reconnect',
    }.contains('${connection['classification']}')) {
      gate.fail(
        'failEndpoint.connections.$index.classification is '
        '${connection['classification']}',
      );
    }
    // A recorded connection is an owned, armed, actually observed request that
    // ended in the declared terminal after it was accepted.
    gate.equal(
      connection['index'],
      index + 1,
      'failEndpoint.connections'
      '.$index.index',
    );
    gate.equal(
      connection['armed'],
      true,
      'failEndpoint.connections.$index.armed',
    );
    gate.equal(
      connection['requestObserved'],
      true,
      'failEndpoint.connections.$index.requestObserved',
    );
    gate.equal(
      connection['terminal'],
      'accepted-and-closed-without-response',
      'failEndpoint.connections.$index.terminal',
    );
    final accepted = connection['acceptedAtNanos'];
    final closed = connection['closedAtNanos'];
    if (accepted is int && closed is int && closed < accepted) {
      gate.fail(
        'failEndpoint.connections.$index closed before it was accepted',
      );
    }
    final connectionTarget = '${connection['target']}';
    final connectionPath = '${connection['path']}';
    final connectionQuery = '${connection['rawQuery']}';
    gate.equal(
      connectionTarget,
      connectionQuery.isEmpty
          ? connectionPath
          : '$connectionPath?$connectionQuery',
      'failEndpoint.connections.$index.target',
    );
  }
  gate.equal(
    failure['acceptedConnections'],
    connections.length,
    'failEndpoint.acceptedConnections',
  );
  gate.equal(
    failure['transportReconnects'],
    connections
        .where(
          (connection) =>
              (connection as Map)['classification'] == 'transport-reconnect',
        )
        .length,
    'failEndpoint.transportReconnects',
  );
  gate.emptyArray(failure['errors'], 'failEndpoint.errors');
  gate.isTrue(failure['closed'], 'failEndpoint.closed');

  // 6. The measured trace and the observation set: shape and cardinality.
  final requestRows = gate.array(product['requests'], 'requests');
  final observationRows = gate.array(product['observations'], 'observations');
  final declaredObservations = httpBoundaryObservationIds(corpus);
  gate.equal(
    [for (final row in observationRows) '${(row as Map)['id']}'],
    declaredObservations,
    'observations.order',
  );
  gate.equal(
    requestRows.length,
    _integerOf(
      _object(corpus['structural'], 'corpus structural')['requests'],
      'structural.requests',
    ),
    'requests.length',
  );
  gate.emptyArray(product['unmatchedRequests'], 'unmatchedRequests');
  gate.emptyArray(product['serverErrors'], 'serverErrors');
  final stageTrace = gate.array(product['stageTrace'], 'stageTrace');
  if (stageTrace.isEmpty) gate.fail('stageTrace is empty');
  for (var index = 0; index < stageTrace.length; index++) {
    final entry = gate.object(stageTrace[index], 'stageTrace.$index');
    for (final field in const ['stage', 'listener', 'target', 'owner']) {
      gate.field(entry, field, 'stageTrace.$index', _Field.string);
    }
  }
  gate.equal(product['coverageGaps'], corpus['coverageGaps'], 'coverageGaps');
  gate.equal(
    product['sourceDerivedNotes'],
    corpus['sourceDerivedNotes'],
    'sourceDerivedNotes',
  );
  gate.equal(
    product['nondeterministic'],
    corpus['nondeterministic'],
    'nondeterministic',
  );
  final structural = gate.object(product['structural'], 'structural');
  gate.field(structural, 'declared', 'structural', _Field.object);
  gate.field(structural, 'derived', 'structural', _Field.object);
  gate.isTrue(structural['match'], 'structural.match');
  gate.equal(
    structural['derived'],
    httpBoundaryStructuralOf(corpus),
    'structural.derived',
  );
  // The declared block is the corpus' own structural model, not just an object.
  gate.equal(
    structural['declared'],
    _object(corpus['structural'], 'corpus structural'),
    'structural.declared',
  );

  // 7. Every request row: its declared fields, its own internal consistency and
  //    its place in the causal chronology.
  final observationById = <String, Map<String, dynamic>>{
    for (final row in observationRows)
      '${(row as Map)['id']}': gate.object(row, 'observation'),
  };
  final stepById = {
    for (final step in httpBoundarySteps(corpus)) '${step['id']}': step,
  };
  final phaseOf = {
    for (var index = 0; index < declaredObservations.length; index++)
      declaredObservations[index]: index,
  };
  final attempts = <String, int>{};
  final lastTerminal = <String, String>{};
  final ownedByObservation = <String, List<Map<String, dynamic>>>{};
  var lastPhase = -1;
  for (var position = 0; position < requestRows.length; position++) {
    final row = gate.object(requestRows[position], 'requests.$position');
    final where = 'requests.$position';
    for (final entry in const [
      ('listener', _Field.string),
      ('owner', _Field.string),
      ('family', _Field.string),
      ('cohort', _Field.nullableString),
      ('attempt', _Field.integer),
      ('attemptKind', _Field.string),
      ('selector', _Field.string),
      ('method', _Field.string),
      ('path', _Field.string),
      ('rawQuery', _Field.string),
      ('target', _Field.string),
      ('query', _Field.object),
      ('headers', _Field.object),
      ('headerLines', _Field.array),
      ('body', _Field.string),
      ('bodyLength', _Field.integer),
      ('bodySha256', _Field.string),
      ('receivedAtNanos', _Field.integer),
      ('respondedAtNanos', _Field.integer),
      ('sentAtNanos', _Field.integer),
      ('sendSequence', _Field.integer),
      ('status', _Field.integer),
      ('terminal', _Field.string),
      ('declaredResponse', _Field.string),
      ('outcome', _Field.string),
      ('stage', _Field.string),
      ('index', _Field.integer),
    ]) {
      gate.field(row, entry.$1, where, entry.$2);
    }
    final owner = '${row['owner']}';
    final step = stepById[owner];
    if (step == null) {
      gate.fail('$where.owner $owner is not a corpus step');
      continue;
    }
    gate.equal(row['index'], position + 1, '$where.index');
    gate.equal(row['family'], '${step['family']}', '$where.family');
    final method = '${row['method']}';
    final path = '${row['path']}';
    final rawQuery = '${row['rawQuery']}';
    final selector = '$method $path?$rawQuery';
    gate.equal(row['selector'], selector, '$where.selector');
    gate.equal(
      row['target'],
      rawQuery.isEmpty ? path : '$path?$rawQuery',
      '$where.target',
    );
    gate.equal(row['query'], Uri.splitQueryString(rawQuery), '$where.query');
    gate.equal(
      row['bodyLength'],
      utf8.encode('${row['body']}').length,
      '$where.bodyLength',
    );
    gate.equal(
      row['bodySha256'],
      sha256Text('${row['body']}'),
      '$where.bodySha256',
    );
    final declaredResponse = '${row['declaredResponse']}';
    final declaredOwner = gate.owners[declaredResponse];
    if (declaredOwner == null) {
      gate.fail('$where.declaredResponse $declaredResponse is not declared');
    } else if (declaredOwner.step != owner) {
      gate.fail(
        '$where belongs to $owner, its declaration to '
        '${declaredOwner.step}',
      );
    } else {
      gate.equal(row['cohort'], declaredOwner.cohort, '$where.cohort');
      if (httpBoundarySelectorOf(gate.responseById[declaredResponse]!) !=
          selector) {
        gate.fail('$where selector is not its declared response selector');
      }
    }
    // Header names are case-insensitive on the wire (the differential
    // contract ignores their case); their values stay exact.
    final rawHeaders = gate.object(row['headers'], '$where.headers');
    final headers = <String, String>{};
    for (final entry in rawHeaders.entries) {
      if (entry.value is! String) {
        gate.fail('$where.headers.${entry.key} is not a string');
        continue;
      }
      final name = entry.key.toLowerCase();
      headers[name] = entry.value;
    }
    final required = step['requiredHeaders'];
    if (required is Map) {
      for (final entry in required.entries) {
        final name = entry.key.toLowerCase();
        final actual = headers[name];
        if (actual != entry.value) {
          gate.fail(
            '$where.headers.$name is $actual, the corpus declares '
            '${entry.value}',
          );
        }
      }
    }
    final forbidden = [
      for (final raw in _array(
        _object(
          corpus['requestChecks'],
          'corpus requestChecks',
        )['forbiddenHeaders'],
        'forbiddenHeaders',
      ))
        '$raw'.toLowerCase(),
      for (final raw in (step['forbiddenHeaders'] as List? ?? const []))
        '$raw'.toLowerCase(),
    ];
    for (final name in forbidden) {
      if (headers.containsKey(name)) {
        gate.fail('$where.headers carries the forbidden header $name');
      }
    }
    // The wire lines and the header map are the same facts.
    final lines = gate.array(row['headerLines'], '$where.headerLines');
    final fromLines = <String, String>{};
    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      if (line is! String) {
        gate.fail('$where.headerLines.$index is not a string');
        continue;
      }
      final boundary = line.indexOf(':');
      if (boundary <= 0) {
        gate.fail('$where.headerLines.$index is not a wire header line');
        continue;
      }
      final name = line.substring(0, boundary).trim().toLowerCase();
      final value = line.substring(boundary + 1).trim();
      fromLines[name] = fromLines.containsKey(name)
          ? '${fromLines[name]}, $value'
          : value;
    }
    gate.equal(fromLines, headers, '$where.headerLines');
    // Every header the corpus asked for must have its wire line too.
    if (required is Map) {
      for (final entry in required.entries) {
        final name = entry.key.toLowerCase();
        if (!fromLines.containsKey(name)) {
          gate.fail('$where.headerLines has no line for $name');
        }
      }
    }
    // The terminal, the status and the outcome are one fact.
    final terminal = '${row['terminal']}';
    if (!const {
      'responded',
      'client-aborted',
      'hold-window-expired',
    }.contains(terminal)) {
      gate.fail('$where.terminal $terminal is not an honest terminal');
    }
    gate.equal(row['outcome'], terminal, '$where.outcome');
    final status = row['status'];
    if (terminal == 'responded') {
      if (status is int && (status < 200 || status > 599)) {
        gate.fail('$where.status $status is not a response status');
      }
      if ((row['sentAtNanos'] as int? ?? 0) <= 0) {
        gate.fail('$where.sentAtNanos is not a send fact');
      }
    } else if (status != -1) {
      gate.fail('$where is $terminal but carries status $status');
    }
    // The causal chronology: the row order is the arrival order, a selector's
    // attempts increase from 1, and a sequential step cannot arrive after a
    // later one. Declared cohort members share their step's phase.
    final phase = phaseOf[owner];
    if (phase == null) {
      gate.fail('$where.owner $owner is not a declared observation');
    } else {
      if (phase < lastPhase) {
        gate.fail('$where ($owner) arrives after a later causal step');
      } else {
        lastPhase = phase;
      }
    }
    // The measured stage is the declared step the observer was on; a stage
    // that names no declared step is not a measurement of this run.
    if (!phaseOf.containsKey('${row['stage']}')) {
      gate.fail('$where.stage ${row['stage']} is not a declared step');
    }
    final received = row['receivedAtNanos'];
    final sent = row['sentAtNanos'];
    final responded = row['respondedAtNanos'];
    if (received is int && sent is int && sent < received) {
      gate.fail('$where.sentAtNanos precedes its own arrival');
    }
    if (received is int && responded is int && responded < received) {
      gate.fail('$where.respondedAtNanos precedes its own arrival');
    }
    final key = '$owner|$selector';
    final expectedAttempt = (attempts[key] ?? 0) + 1;
    final attempt = row['attempt'];
    if (attempt != expectedAttempt) {
      gate.fail(
        '$where.attempt is $attempt, the causal row expects '
        '$expectedAttempt',
      );
    }
    attempts[key] = attempt is int ? attempt : expectedAttempt;
    final attemptKind = '${row['attemptKind']}';
    if (expectedAttempt == 1) {
      if (attemptKind != 'initial') {
        gate.fail('$where.attemptKind is $attemptKind on a first attempt');
      }
    } else {
      final expectedKind = lastTerminal[key] == 'responded'
          ? 'source-status-retry'
          : 'transport-reconnect';
      if (attemptKind != expectedKind) {
        gate.fail(
          '$where.attemptKind is $attemptKind, its predecessor ended '
          '${lastTerminal[key] ?? 'absent'}',
        );
      }
    }
    lastTerminal[key] = terminal;
    (ownedByObservation[owner] ??= []).add(row);
  }
  // The stage trace is the same run's causal trace: every entry names a declared
  // step as both stage and owner and matches one actual request row, and no
  // request is missing from it.
  final traceMatches = <Map<String, dynamic>>[
    for (var index = 0; index < stageTrace.length; index++)
      gate.object(stageTrace[index], 'stageTrace.$index'),
  ];
  // The trace is the measured requests' own four-field multiset: a duplicated
  // entry can never stand in for a distinct request, while a reversed trace and
  // the identical retry rows keep exactly their counted multiplicities.
  String traceKey(Map row) =>
      '${row['stage']}|${row['listener']}|${row['target']}|${row['owner']}';
  final traceKeys = [for (final entry in traceMatches) traceKey(entry)];
  final requestKeys = [for (final raw in requestRows) traceKey(raw as Map)];
  for (var index = 0; index < traceMatches.length; index++) {
    final entry = traceMatches[index];
    for (final name in const ['stage', 'owner']) {
      if (!phaseOf.containsKey('${entry[name]}')) {
        gate.fail(
          'stageTrace.$index.$name ${entry[name]} is not a declared '
          'step',
        );
      }
    }
  }
  if (!_multisetEquals(traceKeys, requestKeys)) {
    gate.fail(
      'stageTrace is not the measured request trace (a duplicated or '
      'missing row changes the counted set)',
    );
  }

  // 8. Every observation: its own fields, its declared outcome, and its request
  //    slice recomputed from the trace above rather than trusted.
  for (var index = 0; index < declaredObservations.length; index++) {
    final id = declaredObservations[index];
    final row = observationById[id];
    if (row == null) {
      gate.fail('observation $id is missing');
      continue;
    }
    final where = 'observations.$id';
    for (final entry in const [
      ('outcome', _Field.string),
      ('category', _Field.nullableString),
      ('value', _Field.object),
      ('evidence', _Field.object),
      ('requests', _Field.array),
    ]) {
      gate.field(row, entry.$1, where, entry.$2);
    }
    final step = stepById[id]!;
    gate.equal(
      row['outcome'],
      '${step['expectedOutcome'] ?? 'ok'}',
      '$where.outcome',
    );
    final expectedCategory = step['expectedCategory'];
    if (expectedCategory == null) {
      if (row['category'] != null) {
        gate.fail('$where.category is ${row['category']}, not null');
      }
    } else {
      gate.equal(row['category'], '$expectedCategory', '$where.category');
    }
    final value = gate.object(row['value'], '$where.value');
    if (value.isEmpty) gate.fail('$where.value is empty');
    final owned = ownedByObservation[id] ?? const <Map<String, dynamic>>[];
    gate.equal(row['requests'], owned, '$where.requests');
    final declared = httpBoundaryDeclaredRequests(step);
    final expectedRequests = declared.ordered.length + declared.members.length;
    if ('${step['kind']}' == 'failure') {
      if (owned.isNotEmpty) {
        gate.fail(
          '$where is a failed connection row but owns '
          '${owned.length} ordinary requests',
        );
      }
    } else if (owned.length != expectedRequests) {
      gate.fail(
        '$where.requests has ${owned.length} rows, the corpus declares '
        '$expectedRequests',
      );
    }
    final kind = '${step['kind']}';
    if (kind == 'cancel') {
      _cancelRelations(gate, corpus, row, value);
    } else if ('${step['id']}' ==
        '${_cancellationBlock(corpus)['followUpStep']}') {
      _followUpRelations(gate, corpus, id, row, value, observationById);
    }
  }

  // 9. The rate rows' own typed records and within-run interval/window
  //    relations. Every comparison below is a difference, so one coherent
  //    cross-host epoch translation stays valid.
  final rateSteps = [
    for (final raw in _array(rate['steps'], 'rate.steps')) '$raw',
  ];
  final records = <String, Map<String, Object?>>{};
  for (var index = 0; index < rateSteps.length; index++) {
    final id = rateSteps[index];
    final row = observationById[id];
    if (row == null) continue;
    final value = gate.object(row['value'], 'observations.$id.value');
    final where = 'observations.$id.value';
    gate.field(value, 'kind', where, _Field.string);
    gate.field(value, 'index', where, _Field.integer);
    gate.field(value, 'result', where, _Field.string);
    gate.field(value, 'recordBefore', where, _Field.nullableObject);
    gate.field(value, 'recordAfter', where, _Field.nullableObject);
    gate.field(value, 'sameWindowAsPrevious', where, _Field.nullableBoolean);
    gate.field(value, 'scheduleComplete', where, _Field.boolean);
    gate.field(value, 'scheduleReason', where, _Field.nullableString);
    Map<String, Object?>? record(Object? raw, String path) {
      if (raw == null) return null;
      final map = gate.object(raw, path);
      gate.field(map, 'isConcurrent', path, _Field.boolean);
      gate.field(map, 'time', path, _Field.integer);
      gate.field(map, 'frequency', path, _Field.integer);
      return map;
    }

    final before = record(value['recordBefore'], '$where.recordBefore');
    final after = record(value['recordAfter'], '$where.recordAfter');
    final evidence = gate.object(row['evidence'], 'observations.$id.evidence');
    for (final key in const [
      'callStartMillis',
      'callFinishMillis',
      'durationNanos',
      'sourceKey',
      'windowMillis',
    ]) {
      gate.field(
        evidence,
        key,
        'observations.$id.evidence',
        key == 'sourceKey' ? _Field.string : _Field.integer,
      );
    }
    gate.equal(
      evidence['windowMillis'],
      rateWindow,
      'observations.$id.evidence.windowMillis',
    );
    // Every rate operation's own interval, duration and source key, checked
    // before any branch: the operation cannot finish before it started, its
    // measured duration cannot be negative, and it must be this source's call.
    final callStart = evidence['callStartMillis'];
    final callFinish = evidence['callFinishMillis'];
    final duration = evidence['durationNanos'];
    if (callStart is int && callFinish is int && callFinish < callStart) {
      gate.fail('observations.$id.evidence call interval is inverted');
    }
    if (duration is int && duration < 0) {
      gate.fail('observations.$id.evidence.durationNanos is negative');
    }
    gate.equal(
      evidence['sourceKey'],
      corpusSourceUrl(corpus, '${rate['source']}'),
      'observations.$id.evidence.sourceKey',
    );
    if (index == 0) {
      if (before != null) gate.fail('$where.recordBefore is not null');
      if (after == null) {
        gate.fail('$where.recordAfter is absent');
        continue;
      }
      gate.equal(
        after['isConcurrent'],
        true,
        '$where.recordAfter.isConcurrent',
      );
      gate.equal(after['frequency'], 1, '$where.recordAfter.frequency');
      gate.field(
        evidence,
        'windowStartMillis',
        'observations.$id.evidence',
        _Field.integer,
      );
      gate.equal(
        evidence['windowStartMillis'],
        after['time'],
        'observations.$id.evidence.windowStartMillis',
      );
      final recordTime = after['time'];
      if (callStart is int && callFinish is int && recordTime is int) {
        if (recordTime < callStart || recordTime > callFinish) {
          gate.fail(
            'observations.$id record was created outside its own '
            'operation interval',
          );
        }
      }
      records[id] = after;
      continue;
    }
    final previous = records[rateSteps[index - 1]];
    if (before == null || previous == null) {
      gate.fail('$where.recordBefore is absent');
      continue;
    }
    gate.equal(before, previous, '$where.recordBefore');
    if (after == null) {
      gate.fail('$where.recordAfter is absent');
      continue;
    }
    gate.equal(after['isConcurrent'], true, '$where.recordAfter.isConcurrent');
    final beforeTime = before['time'] as int? ?? 0;
    final afterTime = after['time'] as int? ?? 0;
    final sameWindow = value['sameWindowAsPrevious'] == true;
    gate.equal(
      sameWindow,
      beforeTime == afterTime,
      '$where.sameWindowAsPrevious',
    );
    if (sameWindow) {
      gate.field(
        evidence,
        'windowStartMillis',
        'observations.$id.evidence',
        _Field.integer,
      );
      gate.equal(
        evidence['windowStartMillis'],
        afterTime,
        'observations.$id.evidence.windowStartMillis',
      );
      if (index == 1) {
        gate.equal(after['frequency'], 2, '$where.recordAfter.frequency');
        if (callStart - afterTime >= rateWindow || callStart - afterTime < 0) {
          gate.fail('$where was admitted outside its declared window');
        }
      }
    } else {
      final advance = afterTime - beforeTime;
      gate.field(
        evidence,
        'windowAdvanceMillis',
        'observations.$id.evidence',
        _Field.integer,
      );
      gate.equal(
        evidence['windowAdvanceMillis'],
        advance,
        'observations.$id.evidence.windowAdvanceMillis',
      );
      gate.equal(after['frequency'], 1, '$where.recordAfter.frequency');
      final complete = advance >= rateWindow;
      gate.equal(
        value['scheduleComplete'],
        complete,
        '$where.scheduleComplete',
      );
      if (!complete) {
        gate.equal(
          value['scheduleReason'],
          'incomplete-schedule',
          '$where.scheduleReason',
        );
      }
    }
    final complete = value['scheduleComplete'] == true;
    gate.equal(
      value['scheduleReason'],
      complete ? null : 'incomplete-schedule',
      '$where.scheduleReason',
    );
    records[id] = after;
  }

  // 10. The two check objects must agree with the rows they summarise.
  final requestCheck = gate.object(product['requestCheck'], 'requestCheck');
  for (final entry in const [
    ('totalMatch', _Field.boolean),
    ('declaredTotal', _Field.integer),
    ('actualTotal', _Field.integer),
    ('ownerless', _Field.array),
    ('unknownOwners', _Field.array),
    ('duplicateIndices', _Field.integer),
    ('fieldProblems', _Field.array),
    ('terminalProblems', _Field.array),
    ('unmatchedRequests', _Field.integer),
    ('serverErrors', _Field.integer),
    ('steps', _Field.array),
  ]) {
    gate.field(requestCheck, entry.$1, 'requestCheck', entry.$2);
  }
  gate.isTrue(requestCheck['match'], 'requestCheck.match');
  gate.isTrue(requestCheck['totalMatch'], 'requestCheck.totalMatch');
  gate.equal(
    requestCheck['actualTotal'],
    requestRows.length,
    'requestCheck.actualTotal',
  );
  gate.equal(
    requestCheck['declaredTotal'],
    _object(corpus['structural'], 'corpus structural')['requests'],
    'requestCheck.declaredTotal',
  );
  gate.emptyArray(requestCheck['ownerless'], 'requestCheck.ownerless');
  gate.emptyArray(requestCheck['unknownOwners'], 'requestCheck.unknownOwners');
  gate.emptyArray(requestCheck['fieldProblems'], 'requestCheck.fieldProblems');
  gate.emptyArray(
    requestCheck['terminalProblems'],
    'requestCheck.terminalProblems',
  );
  gate.equal(
    requestCheck['duplicateIndices'],
    0,
    'requestCheck.duplicateIndices',
  );
  gate.equal(
    requestCheck['unmatchedRequests'],
    0,
    'requestCheck.unmatchedRequests',
  );
  gate.equal(requestCheck['serverErrors'], 0, 'requestCheck.serverErrors');
  final checkSteps = gate.array(requestCheck['steps'], 'requestCheck.steps');
  gate.equal(
    [for (final step in checkSteps) '${(step as Map)['id']}'],
    declaredObservations,
    'requestCheck.steps',
  );
  // Each step's summary is re-derived from the measured rows with the same
  // primitives the comparison uses, so a green flag cannot stand on data that
  // contradicts it.
  var allStepMatches = true;
  for (final step in checkSteps) {
    final row = gate.object(step, 'requestCheck.steps');
    final id = '${row['id']}';
    for (final entry in const [
      ('countMatch', _Field.boolean),
      ('orderMatch', _Field.boolean),
      ('batchMatch', _Field.boolean),
      ('match', _Field.boolean),
    ]) {
      gate.field(row, entry.$1, 'requestCheck.steps.$id', entry.$2);
    }
    final corpusStep = stepById[id];
    if (corpusStep == null) {
      gate.fail('requestCheck.steps names $id, not a corpus step');
      allStepMatches = false;
      continue;
    }
    final declaredStep = httpBoundaryDeclaredRequests(corpusStep);
    // A declared entry that repeats a selector is the next attempt of that
    // causal row, so the prefix is `#1,#2,#3` and not three identical rows.
    final seen = <String, int>{};
    String declaredKey(String responseId) {
      final selector = httpBoundarySelectorOf(gate.responseById[responseId]!);
      final attempt = (seen[selector] ?? 0) + 1;
      seen[selector] = attempt;
      return '$selector#$attempt';
    }

    final expectedOrdered = [
      for (final responseId in declaredStep.ordered) declaredKey(responseId),
    ];
    final expectedBatch = [
      for (final responseId in declaredStep.members) declaredKey(responseId),
    ];
    final actual = [
      for (final request in requestRows)
        if ('${(request as Map)['owner']}' == id)
          '${request['selector']}#${request['attempt']}',
    ];
    final countMatch =
        actual.length == expectedOrdered.length + expectedBatch.length;
    final orderMatch = _isPrefix(expectedOrdered, actual);
    final batchActual = actual.skip(expectedOrdered.length).toList();
    final batchMatch = _multisetEquals(expectedBatch, batchActual);
    gate.equal(
      row['countMatch'],
      countMatch,
      'requestCheck.steps.$id.countMatch',
    );
    gate.equal(
      row['orderMatch'],
      orderMatch,
      'requestCheck.steps.$id.orderMatch',
    );
    gate.equal(
      row['batchMatch'],
      batchMatch,
      'requestCheck.steps.$id.batchMatch',
    );
    gate.equal(
      row['match'],
      countMatch && orderMatch && batchMatch,
      'requestCheck.steps.$id.match',
    );
    gate.isTrue(row['match'], 'requestCheck.steps.$id.match');
    if (row['match'] != true) allStepMatches = false;
  }
  // The overall flags are those facts, not an independent claim.
  gate.equal(
    requestCheck['match'],
    requestCheck['totalMatch'] == true &&
        allStepMatches &&
        gate.array(requestCheck['ownerless'], 'ownerless').isEmpty &&
        gate.array(requestCheck['unknownOwners'], 'unknownOwners').isEmpty &&
        gate.array(requestCheck['fieldProblems'], 'fieldProblems').isEmpty &&
        gate
            .array(requestCheck['terminalProblems'], 'terminalProblems')
            .isEmpty,
    'requestCheck.match',
  );
  final observationCheck = gate.object(
    product['observationCheck'],
    'observationCheck',
  );
  for (final entry in const [
    ('declared', _Field.array),
    ('actual', _Field.array),
    ('missing', _Field.array),
    ('extra', _Field.array),
    ('duplicates', _Field.array),
    ('ordered', _Field.boolean),
    ('outcomeMismatches', _Field.array),
    ('requestCountMismatches', _Field.array),
    ('shapeMismatches', _Field.array),
  ]) {
    gate.field(observationCheck, entry.$1, 'observationCheck', entry.$2);
  }
  gate.isTrue(observationCheck['match'], 'observationCheck.match');
  gate.isTrue(observationCheck['ordered'], 'observationCheck.ordered');
  gate.equal(
    observationCheck['declared'],
    declaredObservations,
    'observationCheck.declared',
  );
  gate.equal(
    observationCheck['actual'],
    declaredObservations,
    'observationCheck.actual',
  );
  for (final key in const [
    'missing',
    'extra',
    'duplicates',
    'outcomeMismatches',
    'requestCountMismatches',
    'shapeMismatches',
  ]) {
    gate.emptyArray(observationCheck[key], 'observationCheck.$key');
  }

  // 11. The inventory must prove a measured, empty database, not an empty
  //     object, and the cleanup receipts must agree with each other.
  final inventory = gate.object(product['inventory'], 'inventory');
  gate.field(inventory, 'databaseOpened', 'inventory', _Field.boolean);
  gate.isTrue(inventory['databaseOpened'], 'inventory.databaseOpened');
  final initial = gate.object(inventory['initial'], 'inventory.initial');
  final finalCounts = gate.object(inventory['final'], 'inventory.final');
  if (initial.isEmpty) gate.fail('inventory.initial is empty');
  if (finalCounts.isEmpty) gate.fail('inventory.final is empty');
  gate.equal(
    finalCounts.keys.toList()..sort(),
    initial.keys.toList()..sort(),
    'inventory.tables',
  );
  // The observer's own fixed measurement contract: the four tables the runner
  // reads, not any non-empty map of zeros.
  const observedTables = _observedTableNames;
  for (final snapshot in [initial, finalCounts]) {
    gate.equal(
      snapshot.keys.toList()..sort(),
      observedTables.toList()..sort(),
      'inventory.tables',
    );
  }
  for (final snapshot in [initial, finalCounts]) {
    for (final entry in snapshot.entries) {
      if (entry.value is! int || (entry.value as int) < 0) {
        gate.fail('inventory count ${entry.key} is ${entry.value}');
      }
    }
  }
  final cleanup = gate.object(product['cleanup'], 'cleanup');
  for (final entry in const [
    ('admission', _Field.string),
    ('listenerClosed', _Field.boolean),
    ('failEndpointClosed', _Field.boolean),
    ('failEndpointConnections', _Field.integer),
    ('nativeLibraryDisposed', _Field.boolean),
    ('databaseClosed', _Field.boolean),
    ('ownerWritten', _Field.boolean),
    ('ownerSha256', _Field.string),
    ('scratchRetained', _Field.boolean),
    ('scratchRemoved', _Field.boolean),
    ('rootAbsentAfter', _Field.boolean),
    ('removalSkipped', _Field.string),
    ('lateErrorCount', _Field.integer),
    ('terminal', _Field.object),
    ('ownerManifest', _Field.object),
    ('startedAt', _Field.string),
  ]) {
    gate.field(cleanup, entry.$1, 'cleanup', entry.$2);
  }
  for (final name in const [
    'listenerClosed',
    'failEndpointClosed',
    'nativeLibraryDisposed',
    'databaseClosed',
    'ownerWritten',
    'scratchRemoved',
    'rootAbsentAfter',
  ]) {
    gate.isTrue(cleanup[name], 'cleanup.$name');
  }
  gate.equal(cleanup['scratchRetained'], false, 'cleanup.scratchRetained');
  gate.equal(cleanup['removalSkipped'], '', 'cleanup.removalSkipped');
  gate.equal(cleanup['lateErrorCount'], 0, 'cleanup.lateErrorCount');
  gate.equal(
    cleanup['lateErrorCount'],
    gate.array(product['serverErrors'], 'serverErrors').length,
    'cleanup.lateErrorCount',
  );
  gate.equal(
    cleanup['failEndpointConnections'],
    connections.length,
    'cleanup.failEndpointConnections',
  );
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch('${cleanup['ownerSha256']}')) {
    gate.fail('cleanup.ownerSha256 is not a SHA-256');
  }
  final ownerManifest = gate.object(
    cleanup['ownerManifest'],
    'cleanup.ownerManifest',
  );
  for (final entry in const [
    ('path', _Field.string),
    ('createdAt', _Field.string),
    ('written', _Field.boolean),
  ]) {
    gate.field(ownerManifest, entry.$1, 'cleanup.ownerManifest', entry.$2);
  }
  gate.equal(ownerManifest['written'], true, 'cleanup.ownerManifest.written');
  gate.equal(
    _normalizePath('${ownerManifest['path']}'),
    _normalizePath('${isolation['ownerFile']}'),
    'cleanup.ownerManifest.path',
  );
  final terminal = gate.object(cleanup['terminal'], 'cleanup.terminal');
  for (final entry in const [
    ('listeners', _Field.object),
    ('bridge', _Field.object),
    ('database', _Field.object),
    ('scratch', _Field.object),
    ('integrityOk', _Field.boolean),
  ]) {
    gate.field(terminal, entry.$1, 'cleanup.terminal', entry.$2);
  }
  gate.isTrue(terminal['integrityOk'], 'cleanup.terminal.integrityOk');
  final listeners = gate.object(
    terminal['listeners'],
    'cleanup.terminal.listeners',
  );
  gate.equal(
    listeners['replayClosed'],
    cleanup['listenerClosed'],
    'cleanup.terminal.listeners.replayClosed',
  );
  gate.equal(
    listeners['failEndpointClosed'],
    cleanup['failEndpointClosed'],
    'cleanup.terminal.listeners.failEndpointClosed',
  );
  final bridge = gate.object(terminal['bridge'], 'cleanup.terminal.bridge');
  gate.equal(
    bridge['nativeDisposed'],
    cleanup['nativeLibraryDisposed'],
    'cleanup.terminal.bridge.nativeDisposed',
  );
  final database = gate.object(
    terminal['database'],
    'cleanup.terminal.database',
  );
  gate.equal(
    database['closed'],
    cleanup['databaseClosed'],
    'cleanup.terminal.database.closed',
  );
  final scratch = gate.object(terminal['scratch'], 'cleanup.terminal.scratch');
  gate.equal(
    scratch['removed'],
    cleanup['scratchRemoved'],
    'cleanup.terminal.scratch.removed',
  );
  gate.equal(
    scratch['absentAfter'],
    cleanup['rootAbsentAfter'],
    'cleanup.terminal.scratch.absentAfter',
  );

  if (productPath.isEmpty) {
    throw HttpBoundaryRefusal('the product report path is empty');
  }
  gate.throwIfAny();
}

Map<String, dynamic> _cancellationBlock(Map<String, dynamic> corpus) =>
    _object(corpus['cancellation'], 'corpus cancellation');

Map<String, dynamic> _cancelStep(Map<String, dynamic> corpus) =>
    httpBoundarySteps(corpus).firstWhere(
      (step) => '${step['kind']}' == 'cancel',
      orElse: () => throw const HttpBoundaryRefusal(
        'the corpus declares no cancellation step',
      ),
    );

/// The cancellation row's measured state, bound to the value summary it claims.
///
/// `cancellationState` is the real HTML pipeline's own state read before the
/// request, at the cancel request and after the worker settled; the value's
/// `jobInactive`/`jobDone`/`workerTerminated` and the derived outcome must be
/// exactly those facts, the quiet window and the late-request count are the
/// corpus' own measurements, and the execution identities are this run's
/// (compared within the run, never across runtimes).
void _cancelRelations(
  _ProductGate gate,
  Map<String, dynamic> corpus,
  Map<String, dynamic> observation,
  Map<String, dynamic> value,
) {
  const where = 'observations.s5.search-cancelled.value';
  final cancellation = _cancellationBlock(corpus);
  final evidence = gate.object(
    observation['evidence'],
    'observations.s5.search-cancelled.evidence',
  );
  final state = gate.object(evidence['cancellationState'], 'cancellationState');
  for (final entry in const [
    ('cancelledBeforeRequest', _Field.boolean),
    ('cancelledAtRequest', _Field.boolean),
    ('cancelledAfterSettle', _Field.boolean),
    ('workerSettled', _Field.boolean),
    ('quietWindowMs', _Field.integer),
    ('lateRequestCount', _Field.integer),
  ]) {
    gate.field(state, entry.$1, 'cancellationState', entry.$2);
  }
  for (final entry in const [
    ('holdEntered', _Field.boolean),
    ('cancelRequested', _Field.boolean),
    ('clientAborted', _Field.boolean),
    ('workerTerminated', _Field.boolean),
    ('jobInactive', _Field.boolean),
    ('jobCompleted', _Field.boolean),
    ('jobDone', _Field.boolean),
    ('workerOutcome', _Field.string),
    ('lateRequests', _Field.array),
    ('stateProbes', _Field.object),
    ('execution', _Field.object),
    ('derivedOutcome', _Field.object),
  ]) {
    gate.field(value, entry.$1, where, entry.$2);
  }
  final cancelledBeforeRequest = state['cancelledBeforeRequest'];
  final cancelledAtRequest = state['cancelledAtRequest'];
  final cancelledAfterSettle = state['cancelledAfterSettle'];
  final workerSettled = state['workerSettled'];
  final quietWindow = state['quietWindowMs'];
  final lateCount = state['lateRequestCount'];
  // The measured state must be the one the corpus' cancellation row describes.
  gate.equal(
    cancelledBeforeRequest,
    false,
    'cancellationState.cancelledBeforeRequest',
  );
  gate.equal(cancelledAtRequest, true, 'cancellationState.cancelledAtRequest');
  gate.equal(
    cancelledAfterSettle,
    true,
    'cancellationState.cancelledAfterSettle',
  );
  gate.equal(workerSettled, true, 'cancellationState.workerSettled');
  gate.equal(
    quietWindow,
    _integerOf(cancellation['quietWindowMs'], 'cancellation.quietWindowMs'),
    'cancellationState.quietWindowMs',
  );
  gate.equal(lateCount, 0, 'cancellationState.lateRequestCount');
  // …and the value summary must be exactly those facts.
  gate.equal(value['holdEntered'], true, '$where.holdEntered');
  gate.equal(value['cancelRequested'], true, '$where.cancelRequested');
  gate.equal(value['clientAborted'], true, '$where.clientAborted');
  gate.equal(
    value['workerTerminated'],
    workerSettled,
    '$where.workerTerminated',
  );
  gate.equal(value['jobInactive'], cancelledAfterSettle, '$where.jobInactive');
  gate.equal(value['jobCompleted'], workerSettled, '$where.jobCompleted');
  gate.equal(
    value['jobDone'],
    cancelledAtRequest == true &&
        cancelledAfterSettle == true &&
        workerSettled == true,
    '$where.jobDone',
  );
  gate.equal(value['workerOutcome'], 'cancelled', '$where.workerOutcome');
  gate.equal(
    gate.array(value['lateRequests'], '$where.lateRequests').length,
    lateCount,
    '$where.lateRequests',
  );
  final probes = gate.object(value['stateProbes'], '$where.stateProbes');
  for (final entry in const [
    ('sourceValues', _Field.object),
    ('variable', _Field.object),
    ('unchanged', _Field.boolean),
    ('databaseUnchanged', _Field.boolean),
  ]) {
    gate.field(probes, entry.$1, '$where.stateProbes', entry.$2);
  }
  gate.equal(probes['unchanged'], true, '$where.stateProbes.unchanged');
  gate.equal(
    probes['databaseUnchanged'],
    true,
    '$where.stateProbes.databaseUnchanged',
  );
  final derived = gate.object(value['derivedOutcome'], '$where.derivedOutcome');
  gate.equal(derived['outcome'], 'cancelled', '$where.derivedOutcome.outcome');
  gate.equal(
    derived['category'],
    'cancellation',
    '$where.derivedOutcome.category',
  );
  gate.equal(
    derived['receiptsComplete'],
    true,
    '$where.derivedOutcome.receiptsComplete',
  );
  final execution = gate.object(value['execution'], '$where.execution');
  gate.equal(
    execution['jobInactive'],
    cancelledAfterSettle,
    '$where.execution.jobInactive',
  );
  gate.equal(
    execution['jobCompleted'],
    workerSettled,
    '$where.execution.jobCompleted',
  );
  final evidenceExecution = gate.object(
    evidence['execution'],
    'cancellation execution evidence',
  );
  for (final entry in const [
    ('pipelineIdentity', _Field.integer),
    ('transportIdentity', _Field.integer),
    ('sourceObjectIdentity', _Field.integer),
    ('sourceKey', _Field.string),
    ('jobLevel', _Field.string),
    ('boundBeforeInvocation', _Field.boolean),
    ('tokenPresent', _Field.boolean),
    ('keyword', _Field.string),
  ]) {
    gate.field(
      evidenceExecution,
      entry.$1,
      'cancellation execution evidence',
      entry.$2,
    );
  }
  final cancelStep = _cancelStep(corpus);
  gate.equal(
    evidenceExecution['sourceKey'],
    corpusSourceUrl(corpus, '${cancelStep['source']}'),
    'cancellation execution evidence.sourceKey',
  );
  gate.equal(
    evidenceExecution['sourceKey'],
    execution['sourceKey'],
    'cancellation execution evidence.sourceKey',
  );
  gate.equal(
    evidenceExecution['jobLevel'],
    execution['jobLevel'],
    'cancellation execution evidence.jobLevel',
  );
  gate.equal(
    evidenceExecution['tokenPresent'],
    execution['tokenPresent'],
    'cancellation execution evidence.tokenPresent',
  );
  gate.equal(
    evidenceExecution['boundBeforeInvocation'],
    true,
    'cancellation execution evidence.boundBeforeInvocation',
  );
  gate.equal(
    evidenceExecution['keyword'],
    '${cancellation['keyword']}',
    'cancellation execution evidence.keyword',
  );
  // The abort proof is one of the runner's two measured branches: the peer's
  // own close as a present nullable non-empty string, or the failed write the
  // runner recorded on the bound held request whose terminal is the abort. An
  // arbitrary observation key or an unrelated request is never a receipt.
  if (!evidence.containsKey('peerClosed')) {
    gate.fail('cancellation evidence has no peerClosed receipt');
  }
  final peerClosed = evidence['peerClosed'];
  if (peerClosed != null && (peerClosed is! String || peerClosed.isEmpty)) {
    gate.fail('cancellation peerClosed is neither a non-empty string nor null');
  }
  final holdResponseId = _heldResponseId(corpus);
  final heldRequests = [
    for (final raw in gate.array(
      observation['requests'],
      'cancellation requests',
    ))
      gate.object(raw, 'cancellation request'),
  ].where((row) => '${row['declaredResponse']}' == holdResponseId).toList();
  final failedWrite = [
    for (final row in heldRequests)
      if (row['abortError'] is String &&
          (row['abortError'] as String).isNotEmpty)
        row,
  ];
  final closeReceipt = peerClosed is String && peerClosed.isNotEmpty;
  if (value['clientAborted'] == true) {
    if (heldRequests.isEmpty) {
      gate.fail('a claimed abort has no bound held request');
    }
    for (final row in heldRequests) {
      if ('${row['terminal']}' != 'client-aborted') {
        gate.fail('the bound held request does not record the abort terminal');
      }
    }
    if (!closeReceipt && failedWrite.isEmpty) {
      gate.fail(
        'cancellation claims an abort with neither a peer close nor a '
        'failed-write receipt on its held request',
      );
    }
  }
  for (final row in failedWrite) {
    if ('${row['terminal']}' != 'client-aborted') {
      gate.fail('a failed-write receipt is not on a client-aborted request');
    }
  }
  // Both database snapshots are actual measurements over the four tables this
  // observer reads, with non-negative integer counts, before they are compared.
  final dbProvenance = gate.object(
    evidence['dbProvenance'],
    'cancellation dbProvenance',
  );
  gate.equal(
    dbProvenance['productTableSnapshotIsProvenance'],
    true,
    'cancellation dbProvenance is not marked provenance',
  );
  Map<String, int>? snapshot(Object? raw, String path) {
    if (raw is! Map) {
      gate.fail('$path is not a measured snapshot');
      return null;
    }
    final counts = <String, int>{};
    for (final entry in raw.entries) {
      final name = '${entry.key}';
      final value = entry.value;
      if (value is! int || value < 0) {
        gate.fail('$path.$name is not a non-negative integer count');
        continue;
      }
      counts[name] = value;
    }
    if (counts.keys.toSet().length != _observedTableNames.length ||
        !counts.keys.toSet().containsAll(_observedTableNames)) {
      gate.fail("$path does not cover the observer's four database tables");
    }
    return counts;
  }

  final dbBefore = snapshot(
    dbProvenance['before'],
    'cancellation dbProvenance.before',
  );
  final dbAfter = snapshot(
    dbProvenance['after'],
    'cancellation dbProvenance.after',
  );
  if (dbBefore != null && dbAfter != null) {
    gate.equal(dbBefore, dbAfter, 'cancellation dbProvenance.before');
  }
  // A cancelled worker has a recorded failure: the runner stores the exception
  // it cancelled with, so a missing, null, empty or untyped receipt cannot
  // stand beside a `workerOutcome: cancelled` claim.
  if (value['workerOutcome'] == 'cancelled') {
    final workerFailure = evidence['workerFailure'];
    if (workerFailure is! String || workerFailure.isEmpty) {
      gate.fail('a cancelled worker has no recorded failure');
    }
  }
}

/// The post-cancellation search: its own fresh execution identity, measured in
/// the same run against the cancelled execution and the same source key.
void _followUpRelations(
  _ProductGate gate,
  Map<String, dynamic> corpus,
  String id,
  Map<String, dynamic> observation,
  Map<String, dynamic> value,
  Map<String, Map<String, dynamic>> observationById,
) {
  final cancellation = _cancellationBlock(corpus);
  final where = 'observations.$id.value';
  final evidence = gate.object(
    observation['evidence'],
    'observations.$id.evidence',
  );
  final execution = gate.object(
    evidence['followUpExecution'],
    'follow-up execution evidence',
  );
  for (final entry in const [
    ('pipelineIdentity', _Field.integer),
    ('transportIdentity', _Field.integer),
    ('sourceObjectIdentity', _Field.integer),
    ('sourceKey', _Field.string),
    ('jobLevel', _Field.string),
    ('boundBeforeInvocation', _Field.boolean),
    ('sourceKeyAfter', _Field.string),
    ('cancelledPipelineIdentity', _Field.integer),
    ('derivedFreshness', _Field.object),
    ('declaredStep', _Field.string),
  ]) {
    gate.field(execution, entry.$1, 'follow-up execution evidence', entry.$2);
  }
  final freshness = gate.object(
    execution['derivedFreshness'],
    'follow-up derivedFreshness',
  );
  for (final entry in const [
    ('jobIdentityFresh', _Field.boolean),
    ('contextIdentityFresh', _Field.boolean),
    ('sameSourceObject', _Field.boolean),
    ('sameSourceKey', _Field.boolean),
    ('proven', _Field.boolean),
  ]) {
    gate.field(freshness, entry.$1, 'follow-up derivedFreshness', entry.$2);
  }
  final followUp = gate.object(value['followUp'], '$where.followUp');
  for (final entry in const [
    ('jobIdentityFresh', _Field.boolean),
    ('contextIdentityFresh', _Field.boolean),
    ('sameSourceObject', _Field.boolean),
    ('sameSourceKey', _Field.boolean),
    ('jobLevel', _Field.string),
    ('jobClosed', _Field.boolean),
    ('sourceKey', _Field.string),
    ('tokenPresent', _Field.boolean),
  ]) {
    gate.field(followUp, entry.$1, '$where.followUp', entry.$2);
  }
  // Same run only: the cancelled execution this observation follows.
  final cancelledRow = observationById['${cancellation['step']}'];
  if (cancelledRow == null) {
    gate.fail('the follow-up has no cancelled execution to compare with');
    return;
  }
  final cancelledEvidence = gate.object(
    cancelledRow['evidence'],
    'cancellation evidence',
  );
  final cancelledExecution = gate.object(
    cancelledEvidence['execution'],
    'cancellation execution evidence',
  );
  gate.equal(
    execution['cancelledPipelineIdentity'],
    cancelledExecution['pipelineIdentity'],
    'follow-up cancelledPipelineIdentity',
  );
  final jobIdentityFresh =
      execution['pipelineIdentity'] != execution['cancelledPipelineIdentity'];
  final contextIdentityFresh =
      execution['transportIdentity'] != cancelledExecution['transportIdentity'];
  final sameSourceObject =
      execution['sourceObjectIdentity'] ==
      cancelledExecution['sourceObjectIdentity'];
  final sameSourceKey =
      '${execution['sourceKey']}' == '${execution['sourceKeyAfter']}';
  gate.equal(jobIdentityFresh, true, 'follow-up jobIdentityFresh');
  gate.equal(contextIdentityFresh, true, 'follow-up contextIdentityFresh');
  gate.equal(sameSourceObject, true, 'follow-up sameSourceObject');
  gate.equal(sameSourceKey, true, 'follow-up sameSourceKey');
  gate.equal(
    freshness['jobIdentityFresh'],
    jobIdentityFresh,
    'follow-up derivedFreshness.jobIdentityFresh',
  );
  gate.equal(
    freshness['contextIdentityFresh'],
    contextIdentityFresh,
    'follow-up derivedFreshness.contextIdentityFresh',
  );
  gate.equal(
    freshness['sameSourceObject'],
    sameSourceObject,
    'follow-up derivedFreshness.sameSourceObject',
  );
  gate.equal(
    freshness['sameSourceKey'],
    sameSourceKey,
    'follow-up derivedFreshness.sameSourceKey',
  );
  gate.equal(freshness['proven'], true, 'follow-up derivedFreshness.proven');
  gate.equal(
    execution['sourceKey'],
    corpusSourceUrl(corpus, '${_cancelStep(corpus)['source']}'),
    'follow-up execution evidence.sourceKey',
  );
  gate.equal(
    execution['boundBeforeInvocation'],
    true,
    'follow-up execution evidence.boundBeforeInvocation',
  );
  gate.equal(
    execution['declaredStep'],
    id,
    'follow-up execution evidence.declaredStep',
  );
  for (final field in const [
    'jobIdentityFresh',
    'contextIdentityFresh',
    'sameSourceObject',
    'sameSourceKey',
  ]) {
    gate.equal(followUp[field], freshness[field], '$where.followUp.$field');
  }
  gate.equal(
    followUp['jobLevel'],
    execution['jobLevel'],
    '$where.followUp.jobLevel',
  );
  gate.equal(
    followUp['sourceKey'],
    execution['sourceKey'],
    '$where.followUp.sourceKey',
  );
  gate.equal(followUp['jobClosed'], true, '$where.followUp.jobClosed');
  gate.equal(followUp['tokenPresent'], true, '$where.followUp.tokenPresent');
}

/// The four database categories this observer actually reads: the runner's own
/// fixed measurement contract (`runner.dart` inventory query), not a generic
/// database schema.
const _observedTableNames = {
  'books',
  'chapters',
  'source_entries',
  'source_cookies',
};

/// The corpus' one held response: the request whose abort the cancellation row
/// measures.
String _heldResponseId(Map<String, dynamic> corpus) =>
    '${httpBoundaryResponses(corpus).firstWhere((response) => response['hold'] == true, orElse: () => throw const HttpBoundaryRefusal('the corpus declares no held response'))['id']}';

/// The scratch root a measured run may own: the isolation root is a fresh
/// directory this lane created, so it may not be a volume root, a shared system
/// directory or the worktree itself.
String isolatedRootOf(String root) {
  final normalized = _normalizePath(root);
  final trimmed = normalized.endsWith('/')
      ? normalized.substring(0, normalized.length - 1)
      : normalized;
  final segments = trimmed.split('/').where((segment) => segment.isNotEmpty);
  if (segments.length < 3) return '';
  final name = segments.last;
  if (name == 'tool' || name == 'lib' || name == 'build') return '';
  return trimmed;
}

/// The portable header map: lowercased names, the contract's platform-generated
/// names dropped when the corpus does not declare them for that step, values
/// exact and duplicates in declaration order.
Map<String, String> portableHeaders(
  Object? headers, {
  Set<String> declared = const {},
}) {
  final result = <String, String>{};
  if (headers is! Map) return result;
  for (final entry in headers.entries) {
    final name = entry.key.toLowerCase();
    if (httpBoundaryPlatformHeaders.contains(name) &&
        !declared.contains(name)) {
      continue;
    }
    result[name] = '${entry.value}';
  }
  return result;
}

/// One step's declared source-controlled header names, so the platform filter
/// never hides a header the corpus asked for.
Set<String> declaredHeaderNames(Map<String, dynamic> step) {
  final names = <String>{};
  final required = step['requiredHeaders'];
  if (required is Map) {
    for (final key in required.keys) {
      names.add('$key'.toLowerCase());
    }
  }
  final forbidden = step['forbiddenHeaders'];
  if (forbidden is List) {
    for (final key in forbidden) {
      names.add('$key'.toLowerCase());
    }
  }
  return names;
}

/// Compares one observation's `value` tree with presence: an absent field and an
/// explicit null are different observations, an added field is a difference, and
/// a rate record's `time` is compared only through the relations the corpus
/// declares (its epoch value is provenance).
void compareValue({
  required Object? expected,
  required Object? observed,
  required String row,
  required String field,
  required List<HttpBoundaryMismatch> into,
}) {
  if (row.startsWith('rate.record.') &&
      (field.endsWith('recordBefore.time') ||
          field.endsWith('recordAfter.time'))) {
    return;
  }
  if (expected is Map && observed is Map) {
    for (final key in expected.keys) {
      if (!observed.containsKey(key)) {
        into.add(
          HttpBoundaryMismatch(
            surface: 'observation',
            row: row,
            field: '$field.$key',
            expected: expected[key],
            observed: null,
            kind: 'missing-observed-field',
          ),
        );
        continue;
      }
      compareValue(
        expected: expected[key],
        observed: observed[key],
        row: row,
        field: '$field.$key',
        into: into,
      );
    }
    for (final key in observed.keys) {
      if (!expected.containsKey(key)) {
        into.add(
          HttpBoundaryMismatch(
            surface: 'observation',
            row: row,
            field: '$field.$key',
            expected: null,
            observed: observed[key],
            kind: 'extra-observed-field',
          ),
        );
      }
    }
    return;
  }
  if (expected is List && observed is List) {
    if (expected.length != observed.length) {
      into.add(
        HttpBoundaryMismatch(
          surface: 'observation',
          row: row,
          field: '$field.length',
          expected: expected.length,
          observed: observed.length,
          kind: 'length',
        ),
      );
    }
    final shared = expected.length < observed.length
        ? expected.length
        : observed.length;
    for (var index = 0; index < shared; index++) {
      compareValue(
        expected: expected[index],
        observed: observed[index],
        row: row,
        field: '$field.$index',
        into: into,
      );
    }
    return;
  }
  if (expected is num && observed is num) {
    if (expected != observed) {
      into.add(
        HttpBoundaryMismatch(
          surface: 'observation',
          row: row,
          field: field,
          expected: expected,
          observed: observed,
          kind: 'number',
        ),
      );
    }
    return;
  }
  if (expected != observed || expected.runtimeType != observed.runtimeType) {
    into.add(
      HttpBoundaryMismatch(
        surface: 'observation',
        row: row,
        field: field,
        expected: expected,
        observed: observed,
        kind: 'type-or-value',
      ),
    );
  }
}

String requestKey(Map<String, dynamic> request) =>
    '${request['owner']}|${request['selector']}|${request['attempt']}';

/// The strict comparison of one product record with one frozen capture.
HttpBoundaryComparison compareHttpBoundaryRecords({
  required Map<String, dynamic> golden,
  required Map<String, dynamic> product,
  required Map<String, dynamic> corpus,
  required String goldenId,
}) {
  final mismatches = <HttpBoundaryMismatch>[];
  final notes = <String>[];
  final steps = httpBoundarySteps(corpus);
  final stepById = {for (final step in steps) '${step['id']}': step};

  // 1. The ordered observation set.
  final expectedIds = httpBoundaryObservationIds(corpus);
  final goldenObservations = [
    for (final raw in _array(golden['observations'], 'golden observations'))
      _object(raw, 'golden observation'),
  ];
  final productObservations = [
    for (final raw in _array(product['observations'], 'product observations'))
      _object(raw, 'product observation'),
  ];
  final goldenOrder = [for (final row in goldenObservations) '${row['id']}'];
  final productOrder = [for (final row in productObservations) '${row['id']}'];
  if (jsonEncode(goldenOrder) != jsonEncode(expectedIds)) {
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'observations',
        row: 'order',
        field: 'golden',
        expected: expectedIds,
        observed: goldenOrder,
        kind: 'golden-observation-order',
      ),
    );
  }
  if (jsonEncode(productOrder) != jsonEncode(expectedIds)) {
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'observations',
        row: 'order',
        field: 'product',
        expected: expectedIds,
        observed: productOrder,
        kind: 'product-observation-order',
      ),
    );
  }

  // 2. Each observation's outcome, category and value.
  final productById = <String, Map<String, dynamic>>{};
  for (final row in productObservations) {
    productById['${row['id']}'] = row;
  }
  for (final goldenRow in goldenObservations) {
    final id = '${goldenRow['id']}';
    final productRow = productById[id];
    if (productRow == null) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'observation',
          row: id,
          field: 'row',
          expected: 'present',
          observed: null,
          kind: 'missing-observation',
        ),
      );
      continue;
    }
    for (final field in const ['outcome', 'category']) {
      if (goldenRow[field] != productRow[field]) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'observation',
            row: id,
            field: field,
            expected: goldenRow[field],
            observed: productRow[field],
          ),
        );
      }
    }
    compareValue(
      expected: goldenRow['value'],
      observed: productRow['value'],
      row: id,
      field: 'value',
      into: mismatches,
    );
  }

  // 3. The causal request trace: every row by its own key, the ordered prefixes
  //    in order, and each declared batch as a multiset.
  final goldenRequests = [
    for (final raw in _array(golden['requests'], 'golden requests'))
      _object(raw, 'golden request'),
  ];
  final productRequests = [
    for (final raw in _array(product['requests'], 'product requests'))
      _object(raw, 'product request'),
  ];
  final productByKey = <String, Map<String, dynamic>>{};
  for (final request in productRequests) {
    final key = requestKey(request);
    if (productByKey.containsKey(key)) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'requests',
          row: key,
          field: 'duplicate',
          expected: 1,
          observed: 2,
          kind: 'duplicate-request',
        ),
      );
    }
    productByKey[key] = request;
  }
  final goldenKeys = <String>{};
  for (final goldenRequest in goldenRequests) {
    final key = requestKey(goldenRequest);
    goldenKeys.add(key);
    final productRequest = productByKey[key];
    if (productRequest == null) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'requests',
          row: key,
          field: 'row',
          expected: 'present',
          observed: null,
          kind: 'missing-request',
        ),
      );
      continue;
    }
    final owner = '${goldenRequest['owner']}';
    final step = stepById[owner];
    final declared = step == null
        ? const <String>{}
        : declaredHeaderNames(step);
    for (final field in httpBoundaryCompareSurface['requests']!) {
      if (field == 'headers') {
        final expectedHeaders = portableHeaders(
          goldenRequest['headers'],
          declared: declared,
        );
        final observedHeaders = portableHeaders(
          productRequest['headers'],
          declared: declared,
        );
        if (_canonical(expectedHeaders) != _canonical(observedHeaders)) {
          mismatches.add(
            HttpBoundaryMismatch(
              surface: 'request',
              row: key,
              field: 'headers',
              expected: expectedHeaders,
              observed: observedHeaders,
            ),
          );
        }
        continue;
      }
      final expected = goldenRequest[field];
      final observed = productRequest[field];
      final equal = expected is Map || observed is Map
          ? _canonical(expected) == _canonical(observed)
          : expected == observed;
      if (!equal) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'request',
            row: key,
            field: field,
            expected: expected,
            observed: observed,
          ),
        );
      }
    }
  }
  for (final request in productRequests) {
    final key = requestKey(request);
    if (goldenKeys.contains(key)) continue;
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'requests',
        row: key,
        field: 'row',
        expected: null,
        observed: 'present',
        kind: 'extra-request',
      ),
    );
  }

  // 4. The causal order: the complete `(selector, attempt)` identity of every
  //    row, its declared dependency and where it sits in the run. Ordered
  //    prefixes are ordered; only a declared cohort is a multiset; arrival or
  //    completion order is never compared inside a cohort.
  String causalId(Map<String, dynamic> request) =>
      '${request['selector']}#${request['attempt']}';
  for (final step in steps) {
    final id = '${step['id']}';
    final declared = httpBoundaryDeclaredRequests(step);
    final responses = {
      for (final response in httpBoundaryResponses(corpus))
        '${response['id']}': response,
    };
    // A declared entry that repeats a selector is the next attempt of that
    // causal row, exactly as the frozen retry loop emits it.
    final seenAttempts = <String, int>{};
    String declaredId(String responseId) {
      final selector = httpBoundarySelectorOf(responses[responseId]!);
      final attempt = (seenAttempts[selector] ?? 0) + 1;
      seenAttempts[selector] = attempt;
      return '$selector#$attempt';
    }

    final expectedOrdered = [
      for (final responseId in declared.ordered) declaredId(responseId),
    ];
    final expectedBatch = [
      for (final responseId in declared.members) declaredId(responseId),
    ];
    final goldenIds = [
      for (final request in goldenRequests)
        if ('${request['owner']}' == id) causalId(request),
    ];
    final productIds = [
      for (final request in productRequests)
        if ('${request['owner']}' == id) causalId(request),
    ];
    if (expectedOrdered.isNotEmpty) {
      if (!_isPrefix(expectedOrdered, goldenIds)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'golden-ordered-prefix',
            expected: expectedOrdered,
            observed: goldenIds,
          ),
        );
      }
      if (!_isPrefix(expectedOrdered, productIds)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'product-ordered-prefix',
            expected: expectedOrdered,
            observed: productIds,
          ),
        );
      }
    }
    if (expectedBatch.isNotEmpty) {
      final goldenBatch = goldenIds.skip(expectedOrdered.length).toList();
      final productBatch = productIds.skip(expectedOrdered.length).toList();
      if (!_multisetEquals(expectedBatch, goldenBatch)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'golden-batch',
            expected: expectedBatch,
            observed: goldenBatch,
          ),
        );
      }
      if (!_multisetEquals(expectedBatch, productBatch)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'product-batch',
            expected: expectedBatch,
            observed: productBatch,
          ),
        );
      }
    }
  }
  // The run's own causal sequence: which step each row belongs to, in row
  // order, with consecutive duplicates collapsed. A sequential step cannot be
  // entered twice and cannot be reached after a later one; the declared
  // cohorts are the only rows that may interleave inside one step.
  List<String> phaseOrder(List<Map<String, dynamic>> rows) {
    final order = <String>[];
    for (final row in rows) {
      final owner = '${row['owner']}';
      if (order.isNotEmpty && order.last == owner) continue;
      order.add(owner);
    }
    return order;
  }

  final goldenPhases = phaseOrder(goldenRequests);
  final productPhases = phaseOrder(productRequests);
  if (jsonEncode(goldenPhases) != jsonEncode(productPhases)) {
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'order',
        row: 'run',
        field: 'causal-steps',
        expected: goldenPhases,
        observed: productPhases,
      ),
    );
  }
  final stepIndex = {
    for (var index = 0; index < steps.length; index++)
      '${steps[index]['id']}': index,
  };
  final declaredPhases = [
    for (final owner in productPhases)
      if (stepIndex.containsKey(owner)) stepIndex[owner]!,
  ];
  for (var index = 1; index < declaredPhases.length; index++) {
    if (declaredPhases[index] < declaredPhases[index - 1]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'order',
          row: 'run',
          field: 'product-sequential-order',
          expected: productPhases[index - 1],
          observed: productPhases[index],
        ),
      );
      break;
    }
  }

  // 5. The families' own facts: runtime configuration and the failure endpoint's
  //    measured connections. The port and timestamps stay provenance.
  final expectedRuntime = _object(
    golden['runtimeConfiguration'],
    'golden runtimeConfiguration',
  );
  final productRuntime = _object(
    product['runtimeConfiguration'],
    'product runtimeConfiguration',
  );
  if (expectedRuntime['threadCount'] != productRuntime['threadCount']) {
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'runtimeConfiguration',
        row: 'batch-width',
        field: 'threadCount',
        expected: expectedRuntime['threadCount'],
        observed: productRuntime['threadCount'],
        kind: 'configured-width',
      ),
    );
  }
  final expectedFailure = _object(
    golden['failEndpoint'],
    'golden failEndpoint',
  );
  final productFailure = _object(
    product['failEndpoint'],
    'product failEndpoint',
  );
  for (final field in const ['acceptedConnections', 'transportReconnects']) {
    if (expectedFailure[field] != productFailure[field]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'failEndpoint',
          row: 'connections',
          field: field,
          expected: expectedFailure[field],
          observed: productFailure[field],
        ),
      );
    }
  }
  final expectedInventory = _object(golden['inventory'], 'golden inventory');
  final productInventory = _object(product['inventory'], 'product inventory');
  for (final field in const ['databaseOpened']) {
    if (expectedInventory[field] != productInventory[field]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'inventory',
          row: 'database',
          field: field,
          expected: expectedInventory[field],
          observed: productInventory[field],
        ),
      );
    }
  }
  for (final snapshot in const ['initial', 'final']) {
    final expectedEmpty = _allZero(expectedInventory[snapshot]);
    final observedEmpty = _allZero(productInventory[snapshot]);
    if (expectedEmpty != observedEmpty) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'inventory',
          row: snapshot,
          field: 'empty',
          expected: expectedEmpty,
          observed: observedEmpty,
        ),
      );
    }
  }

  // 6. The two sides' identity pins and the frozen capture's own receipts. The
  //    product identity is validated before this point and the capture's gates
  //    too; restating them here is what makes a mutated copy a visible
  //    difference instead of an assumption.
  final expectedIdentity = _object(golden['identity'], 'golden identity');
  final observedIdentity = _object(product['identity'], 'product identity');
  for (final pair in const [
    ('fixtureId', 'corpusSha256Lf'),
    ('corpusVersion', 'corpusSha256Lf'),
    ('baselineCommit', 'corpusSha256Lf'),
  ]) {
    if (golden[pair.$1] != product[pair.$1]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'identity',
          row: pair.$2,
          field: pair.$1,
          expected: golden[pair.$1],
          observed: product[pair.$1],
        ),
      );
    }
  }
  for (final field in const ['corpusSha256Lf', 'corpusVersion']) {
    if (expectedIdentity[field] != observedIdentity[field]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'identity',
          row: 'corpus',
          field: field,
          expected: expectedIdentity[field],
          observed: observedIdentity[field],
        ),
      );
    }
  }
  // The frozen identity carries the target pin as three flat fields; the product
  // identity keeps the same three facts beside its corpus pin.
  final observedTargetPin = _object(
    observedIdentity['target'],
    'product target identity',
  );
  for (final pin in const [
    ('targetPackage', 'package'),
    ('targetApkSha256', 'apkSha256'),
    ('targetBaselineCommit', 'baselineCommit'),
  ]) {
    if (expectedIdentity[pin.$1] != observedTargetPin[pin.$2]) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'identity',
          row: 'target',
          field: pin.$1,
          expected: expectedIdentity[pin.$1],
          observed: observedTargetPin[pin.$2],
        ),
      );
    }
  }
  for (final entry in [
    ('terminalIntegrityOk', golden['terminalIntegrityOk']),
    ('promotable', golden['promotable']),
    (
      'requestCheck.match',
      _object(golden['requestCheck'], 'golden requestCheck')['match'],
    ),
    (
      'observationCheck.match',
      _object(golden['observationCheck'], 'golden observationCheck')['match'],
    ),
    (
      'cleanup.terminal.integrityOk',
      _object(
        _object(golden['cleanup'], 'golden cleanup')['terminal'],
        'golden cleanup terminal',
      )['integrityOk'],
    ),
  ]) {
    if (entry.$2 != true) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'native-receipt',
          row: goldenId,
          field: entry.$1,
          expected: true,
          observed: entry.$2,
          kind: 'capture-receipt',
        ),
      );
    }
  }

  // 7. The product's own receipts, restated as compared facts rather than
  //    assumed: its request/observation gates and its cleanup gate.
  for (final entry in const [
    ('requestCheck', 'match'),
    ('observationCheck', 'match'),
  ]) {
    final productGate = _object(product[entry.$1], 'product ${entry.$1}');
    if (productGate[entry.$2] != true) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'receipt',
          row: entry.$1,
          field: entry.$2,
          expected: true,
          observed: productGate[entry.$2],
        ),
      );
    }
  }
  final productCleanup = _object(product['cleanup'], 'product cleanup');
  final productTerminal = _object(
    productCleanup['terminal'],
    'product cleanup terminal',
  );
  for (final entry in const [
    ('listenerClosed', 'listeners'),
    ('failEndpointClosed', 'listeners'),
    ('nativeLibraryDisposed', 'bridge'),
    ('databaseClosed', 'database'),
    ('scratchRemoved', 'scratch'),
    ('rootAbsentAfter', 'scratch'),
  ]) {
    if (productCleanup[entry.$1] != true) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'receipt',
          row: entry.$2,
          field: entry.$1,
          expected: true,
          observed: productCleanup[entry.$1],
        ),
      );
    }
  }
  if (productTerminal['integrityOk'] != true) {
    mismatches.add(
      const HttpBoundaryMismatch(
        surface: 'receipt',
        row: 'cleanup',
        field: 'terminal.integrityOk',
        expected: true,
        observed: false,
      ),
    );
  }

  // 7. The declarations this comparison relies on, checked rather than assumed.
  final structural = httpBoundaryStructuralOf(corpus);
  if (goldenRequests.length != structural['requests']) {
    notes.add('the golden request count is not the derived model');
  }
  if (productRequests.length != expectedIds.length + 0 &&
      productRequests.length != structural['requests']) {
    notes.add('the product request count is not the derived model');
  }
  notes.add(
    'excluded by the corpus nondeterministic list and the differential '
    'contract: recordedAt, runId, pid, stageTrace, observations[].evidence, '
    'request timestamps and sendSequence, requests[].stage, the rate records\' '
    'epoch values (compared through their relations), the fail endpoint\'s '
    'assigned port and nanosecond stamps, the owner manifest timestamp, the '
    'header name case and order, and the platform-generated Host, '
    'Content-Length, Accept-Encoding and Connection headers',
  );
  return HttpBoundaryComparison(
    goldenId: goldenId,
    mismatches: mismatches,
    notes: notes,
  );
}

/// A comparable text form of a JSON value: object keys sorted, so key order is
/// never a difference (the differential contract's own rule) while presence,
/// typed values and array order stay compared.
String _canonical(Object? value) {
  Object? normalize(Object? node) {
    if (node is Map) {
      final keys = [for (final key in node.keys) '$key']..sort();
      return {for (final key in keys) key: normalize(node[key])};
    }
    if (node is List) return [for (final item in node) normalize(item)];
    return node;
  }

  return jsonEncode(normalize(value));
}

bool _allZero(Object? map) {
  if (map is! Map) return false;
  return map.values.every((value) => value == 0);
}

bool _isPrefix(List<String> expected, List<String> actual) {
  if (actual.length < expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _multisetEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  final counts = <String, int>{};
  for (final value in left) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  for (final value in right) {
    final remaining = counts[value];
    if (remaining == null || remaining == 0) return false;
    counts[value] = remaining - 1;
  }
  return counts.values.every((count) => count == 0);
}

// --- controls -----------------------------------------------------------------

/// One control's outcome: the mismatch key it was required to introduce and
/// whether the comparison it ran on was its own unmutated baseline.
class HttpBoundaryControl {
  const HttpBoundaryControl({
    required this.id,
    required this.applied,
    required this.target,
    required this.newKeys,
    required this.baselinePassed,
  });

  final String id;
  final bool applied;
  final String target;
  final List<String> newKeys;
  final bool baselinePassed;

  bool get passed => applied && newKeys.isNotEmpty;

  Map<String, Object?> toJson() => {
    'id': id,
    'applied': applied,
    'target': target,
    'newMismatchKeys': newKeys,
    'baselinePassed': baselinePassed,
    'passed': passed,
  };
}

/// Runs the control set on deep copies of the immutable inputs. Each control
/// compares its own copy against the same baseline comparison, so a row the
/// baseline already reports can never satisfy a control.
List<HttpBoundaryControl> runHttpBoundaryControls({
  required Map<String, dynamic> golden,
  required Map<String, dynamic> product,
  required Map<String, dynamic> corpus,
  required String goldenId,
  required HttpBoundaryComparison baseline,
}) {
  final baselineKeys = {
    for (final mismatch in baseline.mismatches) mismatch.key,
  };
  List<HttpBoundaryControl> run(
    String id,
    String target,
    void Function(
      Map<String, dynamic> goldenCopy,
      Map<String, dynamic> productCopy,
    )
    mutate,
  ) {
    final goldenCopy = _deepCopy(golden);
    final productCopy = _deepCopy(product);
    try {
      mutate(goldenCopy, productCopy);
    } on Object catch (error) {
      return [
        HttpBoundaryControl(
          id: id,
          applied: false,
          target: '$target ($error)',
          newKeys: const [],
          baselinePassed: baseline.passed,
        ),
      ];
    }
    final compared = compareHttpBoundaryRecords(
      golden: goldenCopy,
      product: productCopy,
      corpus: corpus,
      goldenId: goldenId,
    );
    final keys = {
      for (final mismatch in compared.mismatches) mismatch.key,
    }.difference(baselineKeys).toList()..sort();
    return [
      HttpBoundaryControl(
        id: id,
        applied: true,
        target: target,
        newKeys: keys,
        baselinePassed: baseline.passed,
      ),
    ];
  }

  final controls = <HttpBoundaryControl>[];
  Map<String, dynamic> observation(Map<String, dynamic> report, String id) =>
      _object(
        _array(report['observations'], 'observations').firstWhere(
          (raw) => '${(raw as Map)['id']}' == id,
          orElse: () => throw StateError('no observation $id'),
        ),
        'observation $id',
      );
  Map<String, dynamic> request(Map<String, dynamic> report, String owner) =>
      _object(
        _array(report['requests'], 'requests').firstWhere(
          (raw) => '${(raw as Map)['owner']}' == owner,
          orElse: () => throw StateError('no request of $owner'),
        ),
        'request of $owner',
      );

  controls.addAll(
    run('product-value', 'product helper.ajax result', (
      goldenCopy,
      productCopy,
    ) {
      observation(productCopy, 'helper.ajax')['value']['result'] =
          'SINGLE-MUTATED';
    }),
  );
  controls.addAll(
    run('golden-value', 'golden s1.details name', (goldenCopy, productCopy) {
      observation(goldenCopy, 's1.details')['value']['name'] = 'B1-MUTATED';
    }),
  );
  controls.addAll(
    run('product-raw-query', 'product s1.search rawQuery', (
      goldenCopy,
      productCopy,
    ) {
      final row = request(productCopy, 's1.search');
      final encoded = '${row['rawQuery']}'.replaceAll('b1', '%62%31');
      row['rawQuery'] = encoded;
      row['target'] = '${row['path']}?$encoded';
      row['selector'] = '${row['method']} ${row['path']}?$encoded';
    }),
  );
  controls.addAll(
    run('product-order', 'product s2 attempt order', (goldenCopy, productCopy) {
      final rows = [
        for (final raw in _array(productCopy['requests'], 'requests'))
          _object(raw, 'request'),
      ].where((row) => '${row['owner']}' == 's2.retry-non2xx').toList();
      final first = rows[0]['attempt'];
      rows[0]['attempt'] = rows[1]['attempt'];
      rows[1]['attempt'] = first;
    }),
  );
  controls.addAll(
    run('product-identity', 'product corpus identity', (
      goldenCopy,
      productCopy,
    ) {
      _object(productCopy['identity'], 'identity')['corpusSha256Lf'] = '0' * 64;
    }),
  );
  controls.addAll(
    run('product-presence', 'product s1.details tocUrl field', (
      goldenCopy,
      productCopy,
    ) {
      (_object(
        observation(productCopy, 's1.details')['value'],
        'value',
      )).remove('tocUrl');
    }),
  );
  controls.addAll(
    run('product-receipt', 'product cleanup integrity', (
      goldenCopy,
      productCopy,
    ) {
      _object(
        _object(productCopy['cleanup'], 'cleanup')['terminal'],
        'terminal',
      )['integrityOk'] = false;
    }),
  );
  controls.addAll(
    run('golden-receipt', 'golden terminal integrity', (
      goldenCopy,
      productCopy,
    ) {
      goldenCopy['terminalIntegrityOk'] = false;
    }),
  );
  controls.addAll(
    run('unmatched-request', 'product undeclared request', (
      goldenCopy,
      productCopy,
    ) {
      final rows = _array(productCopy['requests'], 'requests');
      rows.add({
        'owner': '',
        'family': '',
        'cohort': null,
        'attempt': 1,
        'attemptKind': 'initial',
        'selector': 'GET /h1/undeclared?',
        'method': 'GET',
        'target': '/h1/undeclared',
        'path': '/h1/undeclared',
        'rawQuery': '',
        'query': <String, String>{},
        'headers': <String, Object?>{},
        'headerLines': <String>[],
        'body': '',
        'bodyLength': 0,
        'bodySha256': '0' * 64,
        'status': 404,
        'terminal': 'omitted-unmatched',
        'declaredResponse': null,
        'outcome': 'omitted-unmatched',
      });
    }),
  );
  controls.addAll(
    run('product-header', 'product s1.details user-agent', (
      goldenCopy,
      productCopy,
    ) {
      final headers = _object(
        request(productCopy, 's1.details')['headers'],
        'headers',
      );
      headers['user-agent'] = 'OTHER-UA/9.9';
    }),
  );
  controls.addAll(
    run('product-body', 'product helper.ajax body', (goldenCopy, productCopy) {
      final row = request(productCopy, 'helper.ajax');
      row['body'] = 'SINGLE-MUTATED';
      row['bodyLength'] = 15;
      row['bodySha256'] = '0' * 64;
    }),
  );
  controls.addAll(
    run('product-attempt-kind', 'product s2 attemptKind', (
      goldenCopy,
      productCopy,
    ) {
      request(productCopy, 'helper.connect-source-header')['attemptKind'] =
          'transport-reconnect';
    }),
  );
  controls.addAll(
    run('product-batch-width', 'product cohort peak', (
      goldenCopy,
      productCopy,
    ) {
      // A batch fact that genuinely matches at baseline: corrupting it must
      // produce that same path, not an unrelated chapter title.
      final value = _object(
        observation(productCopy, 'helper.ajaxAll-order')['value'],
        'value',
      );
      _object(value['batch'], 'batch')['inFlightPeak'] = 2;
    }),
  );
  controls.addAll(
    run('product-retry-order', 'product s2 retry row order', (
      goldenCopy,
      productCopy,
    ) {
      final rows = [
        for (final raw in _array(productCopy['requests'], 'requests'))
          _object(raw, 'request'),
      ];
      final indices = [
        for (var index = 0; index < rows.length; index++)
          if ('${rows[index]['owner']}' == 's2.retry-non2xx') index,
      ];
      final first = rows[indices.first];
      rows[indices.first] = rows[indices.last];
      rows[indices.last] = first;
      productCopy['requests'] = rows;
    }),
  );
  controls.addAll(
    run('product-sequential-order', 'product sequential step order', (
      goldenCopy,
      productCopy,
    ) {
      final rows = [
        for (final raw in _array(productCopy['requests'], 'requests'))
          _object(raw, 'request'),
      ];
      final first = rows[0];
      rows[0] = rows[1];
      rows[1] = first;
      productCopy['requests'] = rows;
    }),
  );
  controls.addAll(
    run('product-terminal', 'product held row terminal', (
      goldenCopy,
      productCopy,
    ) {
      final rows = [
        for (final raw in _array(productCopy['requests'], 'requests'))
          _object(raw, 'request'),
      ].where((row) => '${row['owner']}' == 's5.search-cancelled').toList();
      rows.first['terminal'] = 'responded';
      rows.first['status'] = 200;
    }),
  );
  return controls;
}

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

// --- entry point --------------------------------------------------------------

Future<void> main(List<String> args) async {
  String? handoffPath;
  String? productPath;
  String? evidencePath;
  for (final arg in args) {
    if (arg.startsWith('--handoff=')) {
      handoffPath = arg.substring('--handoff='.length);
    } else if (arg.startsWith('--product=')) {
      productPath = arg.substring('--product='.length);
    } else if (arg.startsWith('--evidence=')) {
      evidencePath = arg.substring('--evidence='.length);
    } else {
      stderr.writeln('unknown comparer argument: $arg');
      exitCode = 64;
      return;
    }
  }
  if (handoffPath == null || productPath == null || evidencePath == null) {
    stderr.writeln(
      'Usage: dart run tool/http_boundary/compare.dart --handoff=<json> '
      '--product=<report.json> --evidence=<dir>',
    );
    exitCode = 64;
    return;
  }
  final result = <String, Object?>{
    'product': 'liber-http-boundary-compare',
    'comparer': 'tool/http_boundary/compare.dart',
    'handoff': handoffPath,
    'productReport': productPath,
    'status': 'failed',
    'runs': <Map<String, Object?>>[],
    'controls': <Map<String, Object?>>[],
    'analysisFailure': null,
  };
  var exit = 1;
  try {
    final corpusFile = File(httpBoundaryCorpusPath);
    final corpus = loadHttpBoundaryCorpus(httpBoundaryCorpusPath);
    final corpusLf = httpBoundaryCorpusSha256Lf(corpusFile);
    final rawSha = sha256File(corpusFile);
    corpus['_rawSha256'] = rawSha;
    final handoff = loadHttpBoundaryReport(handoffPath);
    if (handoff['status'] != 'captured') {
      throw HttpBoundaryRefusal('the handoff is not a captured session');
    }
    if (handoff['integrationHead'] !=
        'fbf556130176841fea14196bf94555823be589c7') {
      throw HttpBoundaryRefusal(
        'the handoff names another integration head: '
        '${handoff['integrationHead']}',
      );
    }
    final handoffCorpus = _object(handoff['corpus'], 'handoff corpus');
    if (handoffCorpus['sha256Lf'] != corpusLf) {
      throw HttpBoundaryRefusal('the handoff pins another corpus');
    }
    // The capture's bundled asset is pinned by the handoff; the working file's
    // own line endings are not the capture's identity.
    final capturedAsset = '${handoffCorpus['assetSha256'] ?? ''}';
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(capturedAsset)) {
      throw HttpBoundaryRefusal('the handoff pins no captured corpus asset');
    }
    corpus['_capturedAssetSha256'] = capturedAsset;
    if (rawSha != capturedAsset && rawSha != corpusLf) {
      throw HttpBoundaryRefusal(
        'the working corpus is neither the captured asset nor its LF form',
      );
    }
    final product = loadHttpBoundaryReport(productPath);
    validateProductReport(
      product,
      corpus: corpus,
      corpusLf: corpusLf,
      productPath: productPath,
    );
    final captures = _array(handoff['captures'], 'handoff captures');
    if (captures.length != 2) {
      throw HttpBoundaryRefusal(
        'the handoff pins ${captures.length} positives, the brief requires two',
      );
    }
    // Two independently captured positives, not one capture counted twice: the
    // ids, the report paths, the report hashes and the run ids must differ.
    final seenIds = <String>{};
    final seenPaths = <String>{};
    final seenHashes = <String>{};
    final seenRuns = <String>{};
    for (final raw in captures) {
      final capture = _object(raw, 'handoff capture');
      final id = '${capture['id']}';
      final report = _object(capture['report'], 'capture report');
      final runId = '${capture['runId'] ?? ''}';
      if (!seenIds.add(id)) {
        throw HttpBoundaryRefusal('the handoff pins capture $id twice');
      }
      if (!seenPaths.add('${report['path']}')) {
        throw HttpBoundaryRefusal(
          'the handoff pins one capture report as both inputs',
        );
      }
      if (!seenHashes.add('${report['sha256']}')) {
        throw HttpBoundaryRefusal(
          'the handoff pins one capture report hash as both inputs',
        );
      }
      if (runId.isEmpty || !seenRuns.add(runId)) {
        throw HttpBoundaryRefusal(
          'the handoff does not pin two independently captured runs',
        );
      }
      if (capture['status'] != 'ok' || capture['promotable'] != true) {
        throw HttpBoundaryRefusal(
          'the capture $id is not a promotable positive',
        );
      }
    }
    final runs = <Map<String, Object?>>[];
    var comparisonsPassed = true;
    for (final raw in captures) {
      final capture = _object(raw, 'handoff capture');
      final goldenId = '${capture['id']}';
      final reportPath =
          '${_object(capture['report'], 'capture report')['path']}';
      final expectedSha =
          '${_object(capture['report'], 'capture report')['sha256']}';
      final golden = loadHttpBoundaryReport(reportPath);
      validateFrozenCapture(
        golden,
        corpus: corpus,
        corpusLf: corpusLf,
        goldenId: goldenId,
        expectedReportSha256: expectedSha,
        reportPath: reportPath,
      );
      final comparison = compareHttpBoundaryRecords(
        golden: golden,
        product: product,
        corpus: corpus,
        goldenId: goldenId,
      );
      final controls = runHttpBoundaryControls(
        golden: golden,
        product: product,
        corpus: corpus,
        goldenId: goldenId,
        baseline: comparison,
      );
      final controlsPassed = controls.every((control) => control.passed);
      comparisonsPassed = comparisonsPassed && comparison.passed;
      runs.add({
        ...comparison.toJson(),
        'captureReportSha256': expectedSha,
        'captureProducerCommit': capture['producerCommit'],
        'captureHarnessApkSha256': capture['harnessApkSha256'],
        'controls': [for (final control in controls) control.toJson()],
        'controlsPassed': controlsPassed,
      });
      for (final control in controls) {
        // Every capture's controls stay in the aggregate result; a later
        // capture must not hide the earlier one's rows.
        (result['controls']! as List).add({
          ...control.toJson(),
          'golden': goldenId,
        });
      }
      if (!controlsPassed) {
        result['controlFailures'] = [
          for (final control in controls)
            if (!control.passed) control.toJson(),
        ];
      }
      if (!comparison.passed) comparisonsPassed = false;
    }
    final controlsOk = runs.every((run) => run['controlsPassed'] == true);
    result['runs'] = runs;
    if (!controlsOk) {
      result['status'] = 'controls-failed';
      exit = 4;
    } else if (!comparisonsPassed) {
      result['status'] = 'differences';
      exit = 3;
    } else {
      result['status'] = 'compared';
      exit = 0;
    }
  } on HttpBoundaryRefusal catch (error) {
    result['status'] = 'refused';
    result['analysisFailure'] = '$error';
    exit = 2;
  } on Object catch (error, stack) {
    result['status'] = 'failed';
    result['analysisFailure'] = '$error';
    result['analysisStack'] = '$stack';
    exit = 1;
  }
  final directory = Directory(evidencePath);
  directory.createSync(recursive: true);
  final out = File('${directory.path}${Platform.pathSeparator}comparison.json');
  out.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(result)}\n',
  );
  final failures = [
    for (final run in result['runs']! as List)
      for (final mismatch in ((run as Map)['mismatches'] as List)) '$mismatch',
  ];
  stdout.writeln(
    'http-boundary comparison: ${result['status']} '
    '(${(result['runs']! as List).length} captures, '
    '${failures.length} differences) -> ${out.path}',
  );
  for (final failure in failures.take(60)) {
    stdout.writeln(failure);
  }
  exitCode = exit;
}
