import 'dart:convert';
import 'dart:io';

import 'runner.dart'
    show
        HttpBoundaryRefusal,
        httpBoundaryCorpusPath,
        httpBoundaryCorpusSha256Lf,
        httpBoundaryDeclaredRequests,
        httpBoundaryObservationIds,
        httpBoundaryResponses,
        httpBoundarySelectorOf,
        httpBoundarySteps,
        httpBoundaryStructuralOf,
        httpBoundaryTargetOf,
        loadHttpBoundaryCorpus,
        sha256File;

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
  if (identity['corpusAssetSha256'] != corpus['_rawSha256']) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId bundled another corpus asset',
    );
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

/// The product record's own gates: a finished run of the same corpus with its
/// requests, observations and cleanup receipts intact.
void validateProductReport(
  Map<String, dynamic> product, {
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String productPath,
}) {
  if (product['status'] != 'completed') {
    throw HttpBoundaryRefusal(
      'the product run is ${product['status']}, not completed: '
      '${product['analysisFailure']}',
    );
  }
  if (product['fixtureId'] != corpus['fixtureId'] ||
      product['corpusVersion'] != corpus['corpusVersion'] ||
      product['baselineCommit'] != corpus['baselineCommit']) {
    throw HttpBoundaryRefusal('the product run names another corpus');
  }
  if (_isNegativeMode(product) || product['negative'] != null) {
    throw HttpBoundaryRefusal('the product run is a negative-mode record');
  }
  final identity = _object(product['identity'], 'product identity');
  if (identity['corpusSha256Lf'] != corpusLf) {
    throw HttpBoundaryRefusal('the product run measured another corpus');
  }
  final runner = _object(identity['runner'], 'product runner identity');
  if (runner['sha256'] != sha256File(File('tool/http_boundary/runner.dart'))) {
    throw HttpBoundaryRefusal(
      'the product run came from another runner.dart revision',
    );
  }
  final library = _object(identity['library'], 'product library identity');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch('${library['sha256']}')) {
    throw HttpBoundaryRefusal('the product run has no library identity');
  }
  if (_object(product['requestCheck'], 'product requestCheck')['match'] !=
      true) {
    throw HttpBoundaryRefusal('the product request trace fails its own check');
  }
  if (_object(
        product['observationCheck'],
        'product observationCheck',
      )['match'] !=
      true) {
    throw HttpBoundaryRefusal(
      'the product observation set fails its own check',
    );
  }
  if (_array(product['unmatchedRequests'], 'product unmatched').isNotEmpty) {
    throw HttpBoundaryRefusal('the product run has unmatched requests');
  }
  if (_array(product['serverErrors'], 'product serverErrors').isNotEmpty) {
    throw HttpBoundaryRefusal('the product run has server errors');
  }
  final cleanup = _object(product['cleanup'], 'product cleanup');
  final terminal = _object(cleanup['terminal'], 'product cleanup terminal');
  if (terminal['integrityOk'] != true) {
    throw HttpBoundaryRefusal(
      'the product run has no cleanup integrity receipt',
    );
  }
  if (cleanup['scratchRemoved'] != true || cleanup['rootAbsentAfter'] != true) {
    throw HttpBoundaryRefusal('the product run left its scratch root behind');
  }
  if (cleanup['listenerClosed'] != true ||
      cleanup['failEndpointClosed'] != true ||
      cleanup['nativeLibraryDisposed'] != true ||
      cleanup['databaseClosed'] != true) {
    throw HttpBoundaryRefusal('the product run left a resource open');
  }
  final inventory = _object(product['inventory'], 'product inventory');
  if (inventory['databaseOpened'] != true) {
    throw HttpBoundaryRefusal('the product run never opened its database');
  }
  if (productPath.isEmpty) {
    throw HttpBoundaryRefusal('the product report path is empty');
  }
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
    final name = '${entry.key}'.toLowerCase();
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

  // 4. The causal order: ordered prefixes in declared order, batches as
  //    multisets, per declared step.
  for (final step in steps) {
    final id = '${step['id']}';
    final declared = httpBoundaryDeclaredRequests(step);
    final responses = {
      for (final response in httpBoundaryResponses(corpus))
        '${response['id']}': response,
    };
    final expectedOrdered = [
      for (final responseId in declared.ordered)
        httpBoundarySelectorOf(responses[responseId]!),
    ];
    final expectedBatch = [
      for (final responseId in declared.members)
        httpBoundarySelectorOf(responses[responseId]!),
    ];
    final goldenSelectors = [
      for (final request in goldenRequests)
        if ('${request['owner']}' == id) '${request['selector']}',
    ];
    final productSelectors = [
      for (final request in productRequests)
        if ('${request['owner']}' == id) '${request['selector']}',
    ];
    if (expectedOrdered.isNotEmpty) {
      if (!_isPrefix(expectedOrdered, goldenSelectors)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'golden-ordered-prefix',
            expected: expectedOrdered,
            observed: goldenSelectors,
          ),
        );
      }
      if (!_isPrefix(expectedOrdered, productSelectors)) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'order',
            row: id,
            field: 'product-ordered-prefix',
            expected: expectedOrdered,
            observed: productSelectors,
          ),
        );
      }
    }
    if (expectedBatch.isNotEmpty) {
      final goldenBatch = goldenSelectors.skip(expectedOrdered.length).toList();
      final productBatch = productSelectors
          .skip(expectedOrdered.length)
          .toList();
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
      final value = _object(
        observation(productCopy, 's1.toc')['value'],
        'value',
      );
      _object((value['chapters'] as List).first as Map, 'chapter')['title'] =
          'c1-MUTATED';
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
    if (handoffCorpus['sha256Lf'] != corpusLf ||
        handoffCorpus['sha256'] != rawSha) {
      throw HttpBoundaryRefusal('the handoff pins another corpus');
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
        result['controls'] = [
          for (final entry in result['controls']! as List)
            if (entry is Map && entry['golden'] == goldenId) entry,
          {...control.toJson(), 'golden': goldenId},
        ];
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
