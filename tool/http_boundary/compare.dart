import 'dart:convert';
import 'dart:io';

import 'runner.dart'
    show
        HttpBoundaryRefusal,
        httpBoundaryBatchWidth,
        httpBoundaryCorpusPath,
        httpBoundaryCorpusSha256Lf,
        httpBoundaryCorpusVersions,
        httpBoundaryDeclaredRequests,
        httpBoundaryObservationIds,
        httpBoundaryResponseOwners,
        httpBoundaryResponses,
        httpBoundarySelectorOf,
        httpBoundarySerialWalkWidth,
        httpBoundarySourceOf,
        httpBoundarySteps,
        httpBoundaryStructuralOf,
        httpBoundaryTargetOf,
        loadHttpBoundaryCorpus,
        sha256File,
        sha256Text,
        validateHttpBoundaryScriptProbeEnvelope;

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

/// One approved difference the amended differential contract requires this
/// harness to name instead of hiding or relabeling as a pass. It keeps the
/// strict mismatch itself and adds only the approval and its reason.
class HttpBoundaryNotCompared {
  const HttpBoundaryNotCompared({
    required this.mismatch,
    required this.approved,
    required this.reason,
  });

  final HttpBoundaryMismatch mismatch;
  final String approved;
  final String reason;

  /// The strict mismatch identity this disposition names: one entry is exactly
  /// one mismatch, never a second pass for a different behavioural fact.
  String get key => mismatch.key;

  Map<String, Object?> toJson() => {
    'approved': approved,
    'observation': '${mismatch.surface}|${mismatch.row}|${mismatch.field}',
    ...mismatch.toJson(),
    'reason': reason,
  };
}

/// One compared pair: the product record against one frozen capture.
class HttpBoundaryComparison {
  HttpBoundaryComparison({
    required this.goldenId,
    required this.mismatches,
    required this.notCompared,
    required this.notes,
  });

  final String goldenId;
  final List<HttpBoundaryMismatch> mismatches;
  final List<HttpBoundaryNotCompared> notCompared;
  final List<String> notes;

  bool get passed => mismatches.isEmpty;

  Map<String, Object?> toJson() => {
    'golden': goldenId,
    'passed': passed,
    'mismatchCount': mismatches.length,
    'notComparedCount': notCompared.length,
    'unattributedCount': mismatches.length - notCompared.length,
    'mismatches': [for (final mismatch in mismatches) mismatch.toJson()],
    'notCompared': [for (final entry in notCompared) entry.toJson()],
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
  final captureRows = _array(golden['observations'], 'capture observations');
  if (captureRows.length != declaredObservations) {
    throw HttpBoundaryRefusal(
      'the capture $goldenId has ${captureRows.length} observations, the '
      'corpus declares $declaredObservations',
    );
  }
  final declaredIds = httpBoundaryObservationIds(corpus);
  final actualIds = [
    for (final raw in captureRows)
      '${_object(raw, 'capture observation')['id']}',
  ];
  final counts = <String, int>{};
  for (final id in actualIds) {
    counts[id] = (counts[id] ?? 0) + 1;
  }
  for (final id in declaredIds) {
    if (counts[id] != 1) {
      throw HttpBoundaryRefusal(
        'the capture $goldenId does not carry observation $id exactly once',
      );
    }
  }
  final declaredSet = declaredIds.toSet();
  for (final id in counts.keys) {
    if (!declaredSet.contains(id)) {
      throw HttpBoundaryRefusal(
        'the capture $goldenId carries unexpected observation $id',
      );
    }
  }
  _validateFrozenV3Facts(golden, corpus, goldenId);
}

Map<String, dynamic> _relationObject(Object? raw, String where) {
  if (raw is! Map) throw FormatException('$where is not an object');
  return raw.cast<String, dynamic>();
}

int _relationInt(Map<String, dynamic> value, String key, String where) {
  final raw = value[key];
  if (raw is! int) throw FormatException('$where.$key is not an integer');
  return raw;
}

bool _relationBool(Map<String, dynamic> value, String key, String where) {
  final raw = value[key];
  if (raw is! bool) throw FormatException('$where.$key is not a boolean');
  return raw;
}

String _relationString(
  Map<String, dynamic> value,
  String key,
  String where, {
  bool nonEmpty = true,
}) {
  final raw = value[key];
  if (raw is! String || (nonEmpty && raw.isEmpty)) {
    throw FormatException('$where.$key is not a string');
  }
  return raw;
}

Map<String, dynamic> _relationObservationsById(Map<String, dynamic> record) {
  final rows = record['observations'];
  if (rows is! List) {
    throw const FormatException('observations is not an array');
  }
  final byId = <String, Map<String, dynamic>>{};
  for (final raw in rows) {
    final row = _relationObject(raw, 'observation');
    final id = '${row['id']}';
    byId[id] = row;
  }
  return byId;
}

List<Map<String, dynamic>> _relationRequests(Map<String, dynamic> record) {
  final rows = record['requests'];
  if (rows is! List) throw const FormatException('requests is not an array');
  return [for (final raw in rows) _relationObject(raw, 'request')];
}

void validateFrozenCarrierRelations(
  Map<String, dynamic> golden,
  Map<String, dynamic> corpus, {
  String where = 'frozen capture',
}) {
  final carrierSteps = [
    for (final step in httpBoundarySteps(corpus))
      if (step['carrier'] != null) step,
  ];
  if (carrierSteps.isEmpty) return;
  final byId = _relationObservationsById(golden);
  final same = carrierSteps.where((step) => step['carrier'] == 'same').toList();
  final fresh = carrierSteps
      .where((step) => step['carrier'] == 'fresh')
      .toList();
  if (same.length != 1 || fresh.length != 1) {
    throw FormatException('$where corpus has no one same/fresh carrier pair');
  }
  if ('${same.single['book']}' != '${fresh.single['book']}') {
    throw FormatException('$where carriers name different retained books');
  }
  Map<String, dynamic> rowOf(Map<String, dynamic> step) {
    final row = byId['${step['id']}'];
    if (row == null) {
      throw FormatException('$where lacks carrier row ${step['id']}');
    }
    return row;
  }

  final sameRow = rowOf(same.single);
  final freshRow = rowOf(fresh.single);
  final book = _declaredBook(corpus, '${same.single['book']}');
  final bookUrl = '${book['bookUrl']}';
  Map<String, dynamic> checkRow(
    Map<String, dynamic> step,
    Map<String, dynamic> row,
  ) {
    final value = _relationObject(row['value'], '$where ${step['id']} value');
    final evidence = _relationObject(
      row['evidence'],
      '$where ${step['id']} evidence',
    );
    final carrier = _relationObject(
      evidence['carrier'],
      '$where ${step['id']} carrier',
    );
    final hit = _relationObject(
      evidence['hitReference'],
      '$where ${step['id']} hit',
    );
    if (_relationString(carrier, 'declared', '$where ${step['id']} carrier') !=
        '${step['carrier']}') {
      throw FormatException('$where ${step['id']} carrier declaration differs');
    }
    _relationString(carrier, 'actual', '$where ${step['id']} carrier');
    final sourceKey = _relationString(
      carrier,
      'sourceKey',
      '$where ${step['id']} carrier',
    );
    final source = httpBoundarySourceOf(corpus, '${step['source']}');
    if (sourceKey != '${source['bookSourceUrl']}') {
      throw FormatException(
        '$where ${step['id']} source key is not the source',
      );
    }
    if (_relationString(value, 'bookUrl', '$where ${step['id']} value') !=
        bookUrl) {
      throw FormatException(
        '$where ${step['id']} does not publish the retained book identity',
      );
    }
    final counter = _relationString(
      value,
      'counterAfter',
      '$where ${step['id']} value',
    );
    if (!RegExp(r'^[0-9]+$').hasMatch(counter)) {
      throw FormatException('$where ${step['id']} counter is not decimal');
    }
    _relationInt(hit, 'identity', '$where ${step['id']} hit');
    if (_relationString(hit, 'bookId', '$where ${step['id']} hit') !=
        '${step['book']}') {
      throw FormatException('$where ${step['id']} hit book differs');
    }
    if (_relationString(hit, 'rawAddress', '$where ${step['id']} hit') !=
        bookUrl) {
      throw FormatException('$where ${step['id']} hit address differs');
    }
    if (_relationString(hit, 'sourceKey', '$where ${step['id']} hit') !=
        _relationString(carrier, 'sourceKey', '$where ${step['id']} carrier')) {
      throw FormatException('$where ${step['id']} hit source key differs');
    }
    if (_relationString(hit, 'counterAfter', '$where ${step['id']} hit') !=
        counter) {
      throw FormatException('$where ${step['id']} hit counter differs');
    }
    return {'row': row, 'value': value, 'carrier': carrier, 'hit': hit};
  }

  final sameFacts = checkRow(same.single, sameRow);
  final freshFacts = checkRow(fresh.single, freshRow);
  final sameHit = sameFacts['hit'] as Map<String, dynamic>;
  final freshHit = freshFacts['hit'] as Map<String, dynamic>;
  final sameValue = sameFacts['value'] as Map<String, dynamic>;
  final freshValue = freshFacts['value'] as Map<String, dynamic>;
  if (sameHit['identity'] != freshHit['identity'] ||
      '${sameHit['rawAddress']}' != '${freshHit['rawAddress']}' ||
      '${sameHit['sourceKey']}' != '${freshHit['sourceKey']}') {
    throw FormatException('$where paired carriers did not retain one hit');
  }
  if ('${sameValue['counterAfter']}' != '1' ||
      '${freshValue['counterAfter']}' != '2') {
    throw FormatException('$where paired counters are not the retained 1/2');
  }
}

void validateHttpBoundaryCarrierRelations(
  Map<String, dynamic> product,
  Map<String, dynamic> corpus, {
  String where = 'product',
}) {
  final carrierSteps = [
    for (final step in httpBoundarySteps(corpus))
      if (step['carrier'] != null) step,
  ];
  if (carrierSteps.isEmpty) return;
  final byId = _relationObservationsById(product);
  final requests = _relationRequests(product);
  final same = carrierSteps.where((step) => step['carrier'] == 'same').toList();
  final fresh = carrierSteps
      .where((step) => step['carrier'] == 'fresh')
      .toList();
  if (same.length != 1 || fresh.length != 1) {
    throw FormatException('$where corpus has no one same/fresh carrier pair');
  }
  if ('${same.single['book']}' != '${fresh.single['book']}') {
    throw FormatException('$where carriers name different retained books');
  }
  final book = _declaredBook(corpus, '${same.single['book']}');
  final bookUrl = '${book['bookUrl']}';
  final responseById = {
    for (final response in httpBoundaryResponses(corpus))
      '${response['id']}': response,
  };
  Map<String, dynamic> checkRow(
    Map<String, dynamic> step,
    String expectedCounter,
  ) {
    final id = '${step['id']}';
    final row = byId[id];
    if (row == null) throw FormatException('$where lacks observation $id');
    final value = _relationObject(row['value'], '$where $id value');
    final evidence = _relationObject(row['evidence'], '$where $id evidence');
    final carrier = _relationObject(
      evidence['carrier'],
      '$where $id evidence.carrier',
    );
    final hit = _relationObject(
      evidence['hitReference'],
      '$where $id evidence.hitReference',
    );
    final declared = _relationString(carrier, 'declared', '$where $id carrier');
    if (declared != '${step['carrier']}') {
      throw FormatException('$where $id carrier declaration differs');
    }
    final actual = _relationString(carrier, 'actual', '$where $id carrier');
    if (actual != '${step['carrier']}') {
      throw FormatException('$where $id carrier actual label differs');
    }
    final source = httpBoundarySourceOf(corpus, '${step['source']}');
    final expectedSourceKey = '${source['bookSourceUrl']}';
    final sourceKey = _relationString(
      carrier,
      'sourceKey',
      '$where $id carrier',
    );
    if (sourceKey != expectedSourceKey) {
      throw FormatException('$where $id source key is not the O source');
    }
    final pipelineIdentity = _relationInt(
      carrier,
      'pipelineIdentity',
      '$where $id carrier',
    );
    final cachedPipelineIdentity = _relationInt(
      carrier,
      'cachedPipelineIdentity',
      '$where $id carrier',
    );
    final transportIdentity = _relationInt(
      carrier,
      'transportIdentity',
      '$where $id carrier',
    );
    final cachedTransportIdentity = _relationInt(
      carrier,
      'cachedTransportIdentity',
      '$where $id carrier',
    );
    final sourceObjectIdentity = _relationInt(
      carrier,
      'sourceObjectIdentity',
      '$where $id carrier',
    );
    final cachedSourceObjectIdentity = _relationInt(
      carrier,
      'cachedSourceObjectIdentity',
      '$where $id carrier',
    );
    _relationInt(carrier, 'hostStateIdentity', '$where $id carrier');
    final reusedPipeline = _relationBool(
      carrier,
      'reusedPipeline',
      '$where $id carrier',
    );
    final distinctTransport = _relationBool(
      carrier,
      'distinctTransport',
      '$where $id carrier',
    );
    if (reusedPipeline != (pipelineIdentity == cachedPipelineIdentity)) {
      throw FormatException('$where $id reusedPipeline contradicts identities');
    }
    if (distinctTransport != (transportIdentity != cachedTransportIdentity)) {
      throw FormatException(
        '$where $id distinctTransport contradicts identities',
      );
    }
    if (sourceObjectIdentity != cachedSourceObjectIdentity) {
      throw FormatException('$where $id source object is not the cached one');
    }
    if ('${step['carrier']}' == 'same') {
      if (pipelineIdentity != cachedPipelineIdentity ||
          transportIdentity != cachedTransportIdentity ||
          !reusedPipeline ||
          distinctTransport) {
        throw FormatException('$where $id did not reuse the search pipeline');
      }
    } else {
      if (pipelineIdentity == cachedPipelineIdentity ||
          transportIdentity == cachedTransportIdentity ||
          reusedPipeline ||
          !distinctTransport) {
        throw FormatException(
          '$where $id did not use a fresh pipeline and transport',
        );
      }
    }
    final bookValue = _relationString(value, 'bookUrl', '$where $id value');
    if (bookValue != bookUrl) {
      throw FormatException('$where $id bookUrl is not the retained identity');
    }
    final counter = _relationString(value, 'counterAfter', '$where $id value');
    if (counter != expectedCounter) {
      throw FormatException('$where $id counterAfter is not $expectedCounter');
    }
    if (_relationInt(hit, 'identity', '$where $id hit') !=
        _relationInt(hit, 'storedIdentity', '$where $id hit')) {
      throw FormatException('$where $id actual hit differs from stored hit');
    }
    if (!_relationBool(hit, 'sameObject', '$where $id hit')) {
      throw FormatException('$where $id sameObject is not true');
    }
    if (_relationString(hit, 'bookId', '$where $id hit') != '${step['book']}') {
      throw FormatException('$where $id hit book differs');
    }
    if (_relationString(hit, 'rawAddress', '$where $id hit') != bookUrl) {
      throw FormatException('$where $id hit address differs');
    }
    if (_relationString(hit, 'sourceKey', '$where $id hit') != sourceKey) {
      throw FormatException('$where $id hit source key differs');
    }
    if (_relationString(hit, 'counterAfter', '$where $id hit') != counter) {
      throw FormatException('$where $id hit counter differs');
    }
    final declaredRequests = httpBoundaryDeclaredRequests(step);
    if (declaredRequests.ordered.length != 1 ||
        declaredRequests.members.isNotEmpty) {
      throw FormatException('$where $id carrier request declaration differs');
    }
    final expectedSelector = httpBoundarySelectorOf(
      responseById[declaredRequests.ordered.single]!,
    );
    final owned = [
      for (final request in requests)
        if ('${request['owner']}' == id) '${request['selector']}',
    ];
    if (owned.length != 1 || owned.single != expectedSelector) {
      throw FormatException('$where $id carrier request target differs');
    }
    return {'carrier': carrier, 'hit': hit, 'value': value};
  }

  final sameFacts = checkRow(same.single, '1');
  final freshFacts = checkRow(fresh.single, '2');
  final sameCarrier = sameFacts['carrier'] as Map<String, dynamic>;
  final freshCarrier = freshFacts['carrier'] as Map<String, dynamic>;
  final sameHit = sameFacts['hit'] as Map<String, dynamic>;
  final freshHit = freshFacts['hit'] as Map<String, dynamic>;
  final sameSource = _relationInt(
    sameCarrier,
    'sourceObjectIdentity',
    '$where same carrier',
  );
  final freshSource = _relationInt(
    freshCarrier,
    'sourceObjectIdentity',
    '$where fresh carrier',
  );
  final sameHost = _relationInt(
    sameCarrier,
    'hostStateIdentity',
    '$where same carrier',
  );
  final freshHost = _relationInt(
    freshCarrier,
    'hostStateIdentity',
    '$where fresh carrier',
  );
  if (sameSource != freshSource || sameHost != freshHost) {
    throw FormatException('$where paired carriers do not share source/state');
  }
  if (_relationInt(
        sameCarrier,
        'cachedPipelineIdentity',
        '$where same carrier',
      ) !=
      _relationInt(
        freshCarrier,
        'cachedPipelineIdentity',
        '$where fresh carrier',
      )) {
    throw FormatException(
      '$where paired carriers do not share the cached pipeline',
    );
  }
  if (_relationInt(
        sameCarrier,
        'cachedTransportIdentity',
        '$where same carrier',
      ) !=
      _relationInt(
        freshCarrier,
        'cachedTransportIdentity',
        '$where fresh carrier',
      )) {
    throw FormatException(
      '$where paired carriers do not share the cached transport',
    );
  }
  if (_relationString(sameCarrier, 'sourceKey', '$where same carrier') !=
      _relationString(freshCarrier, 'sourceKey', '$where fresh carrier')) {
    throw FormatException('$where paired carriers do not share the source key');
  }
  if (sameHit['identity'] != freshHit['identity'] ||
      sameHit['storedIdentity'] != freshHit['storedIdentity'] ||
      '${sameHit['rawAddress']}' != '${freshHit['rawAddress']}' ||
      '${sameHit['sourceKey']}' != '${freshHit['sourceKey']}') {
    throw FormatException('$where paired carriers did not retain one hit');
  }
}

void _validateFrozenV3Facts(
  Map<String, dynamic> golden,
  Map<String, dynamic> corpus,
  String goldenId,
) {
  final byId = {
    for (final raw in _array(golden['observations'], 'capture observations'))
      '${(raw as Map)['id']}': _object(raw, 'capture observation'),
  };
  for (final step in httpBoundarySteps(corpus)) {
    final id = '${step['id']}';
    final row = byId[id];
    if (row == null) continue;
    final value = _object(row['value'], 'capture $id value');
    if ('${step['action']}' == 'scriptProbe') {
      final evidence = _object(row['evidence'], 'capture $id evidence');
      final probe = _object(evidence['scriptProbe'], 'capture $id scriptProbe');
      final diagnostics = probe['diagnostics'];
      try {
        validateHttpBoundaryScriptProbeEnvelope({
          'portable': value['result'],
          'diagnostics': diagnostics,
        }, where: 'capture $goldenId $id');
      } on FormatException catch (error) {
        throw HttpBoundaryRefusal(
          'the capture $goldenId probe $id is not typed: ${error.message}',
        );
      }
    }
  }
  try {
    validateFrozenCarrierRelations(golden, corpus, where: 'capture $goldenId');
  } on FormatException catch (error) {
    throw HttpBoundaryRefusal(error.message);
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

Map<String, dynamic> _declaredBook(Map<String, dynamic> corpus, String id) =>
    _object(
      _array(corpus['books'], 'corpus books').firstWhere(
        (raw) => '${(raw as Map)['id']}' == id,
        orElse: () =>
            throw HttpBoundaryRefusal('the corpus declares no book $id'),
      ),
      'book $id',
    );

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
    // The connection is the declared failure step's own request, not any peer:
    // its method, path, raw query and the source-controlled headers are that
    // request's identity.
    final declaredFailure = _declaredFailureRequest(corpus);
    gate.equal(
      '${connection['method']}',
      declaredFailure.method,
      'failEndpoint.connections.$index.method',
    );
    gate.equal(
      connectionPath,
      declaredFailure.path,
      'failEndpoint.connections.$index.path',
    );
    gate.equal(
      connectionQuery,
      declaredFailure.rawQuery,
      'failEndpoint.connections.$index.rawQuery',
    );
    final connectionHeaders = gate.object(
      connection['headers'],
      'failEndpoint.connections.$index.headers',
    );
    for (final entry in declaredFailure.headers.entries) {
      Object? actual;
      for (final key in connectionHeaders.keys) {
        if (key.toLowerCase() == entry.key) actual = connectionHeaders[key];
      }
      if (actual != entry.value) {
        gate.fail(
          'failEndpoint.connections.$index.headers.${entry.key} is '
          '$actual, the corpus declares ${entry.value}',
        );
      }
    }
    if (connectionQuery.contains('cookie') ||
        connectionHeaders.keys.any((key) => key.toLowerCase() == 'cookie')) {
      gate.fail('failEndpoint.connections.$index carries a cookie');
    }
    gate.equal(
      '${connection['classification']}',
      index == 0 ? 'initial' : 'transport-reconnect',
      'failEndpoint.connections.$index.classification',
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
  // The frozen carrier schema of the successful declared search/details
  // stages, including the post-cancel search. The gate checks the published
  // fields' presence and declared types; value derivation stays with the
  // strict comparison. Failed, cancelled and non-carrier stages keep their
  // existing declared shape.
  final carrierStageById = <String, String>{
    for (final step in stepById.values)
      if ('${step['kind']}' == 'stage' &&
          '${step['expectedOutcome'] ?? 'ok'}' == 'ok' &&
          ('${step['stage']}' == 'search' || '${step['stage']}' == 'details'))
        '${step['id']}': '${step['stage']}',
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
    final sentAt = row['sentAtNanos'] as int? ?? 0;
    final respondedAt = row['respondedAtNanos'] as int? ?? 0;
    final sendSequence = row['sendSequence'] as int? ?? 0;
    if (terminal == 'responded') {
      if (status is int && (status < 200 || status > 599)) {
        gate.fail('$where.status $status is not a response status');
      }
      // A responded row really wrote: the send facts exist and are ordered.
      if (sentAt <= 0) gate.fail('$where.sentAtNanos is not a send fact');
      if (respondedAt <= 0) {
        gate.fail('$where.respondedAtNanos is not a completion fact');
      }
      if (sendSequence <= 0) {
        gate.fail('$where.sendSequence is not a send fact');
      }
      if (respondedAt < sentAt) {
        gate.fail('$where completed before its own send');
      }
    } else {
      if (status != -1) {
        gate.fail('$where is $terminal but carries status $status');
      }
      // Nothing was written on an aborted/failed row: no send, no completion.
      if (sentAt != 0 || respondedAt != 0 || sendSequence != 0) {
        gate.fail('$where is $terminal but reports a send or a completion');
      }
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
    if (received is int && sent is int && sent != 0 && sent < received) {
      gate.fail('$where.sentAtNanos precedes its own arrival');
    }
    if (received is int &&
        responded is int &&
        responded != 0 &&
        responded < received) {
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
    // The declared batch block's own schema: its counts and configuration are
    // integers, its flags booleans and its membership strings. A same-valued
    // double is not the declared integer.
    if (value.containsKey('batch')) {
      final batch = gate.object(value['batch'], '$where.value.batch');
      gate.field(batch, 'cohort', '$where.value.batch', _Field.string);
      for (final name in const [
        'cohortSize',
        'cohortTimeoutMs',
        'inFlightPeak',
        'threadCount',
      ]) {
        gate.field(batch, name, '$where.value.batch', _Field.integer);
      }
      for (final name in const ['entered', 'cohortComplete']) {
        gate.field(batch, name, '$where.value.batch', _Field.boolean);
      }
      gate.field(batch, 'releaseReason', '$where.value.batch', _Field.string);
      final membership = gate.array(
        batch['membership'],
        '$where.value.batch.membership',
      );
      for (var slot = 0; slot < membership.length; slot++) {
        if (membership[slot] is! String) {
          gate.fail('$where.value.batch.membership.$slot is not a string');
        }
      }
    }
    // The frozen carrier fields the successful search/details stages publish.
    // A search result's origin/originName are required strings and its type a
    // required integer; a details row publishes a required origin string.
    final carrierStage = carrierStageById[id];
    if (carrierStage == 'search') {
      final results = gate.array(value['results'], '$where.value.results');
      for (var slot = 0; slot < results.length; slot++) {
        final resultPath = '$where.value.results.$slot';
        final result = gate.object(results[slot], resultPath);
        gate.field(result, 'origin', resultPath, _Field.string);
        gate.field(result, 'originName', resultPath, _Field.string);
        gate.field(result, 'type', resultPath, _Field.integer);
      }
    } else if (carrierStage == 'details') {
      gate.field(value, 'origin', '$where.value', _Field.string);
    }
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
    _v3ObservationFacts(
      gate,
      corpus,
      step,
      row,
      value,
      ownedByObservation,
      observationById,
    );
  }
  _v3CarrierPairFacts(gate, corpus, product);

  // 9. The rate rows' own typed records and within-run interval/window
  //    relations. Every comparison below is a difference, so one coherent
  //    cross-host epoch translation stays valid. The corpus declares which
  //    record fields it really carries and which window relation each row means:
  //    the historical corpus keeps its three original row meanings, the selected
  //    one declares its own because the selected reference rolls the window on
  //    every start instead of admitting an extra same-window start.
  /// The rate record fields this corpus compares, with the historical three as
  /// the default. A corpus may only declare a field the record really carries.
  List<String> rateRecordFields(Map<String, dynamic> rate) {
    final declared = rate['recordFields'];
    if (declared == null) {
      return const ['isConcurrent', 'time', 'frequency'];
    }
    final fields = [
      for (final raw in _array(declared, 'rate.recordFields')) '$raw',
    ];
    if (fields.isEmpty) {
      throw const FormatException('rate.recordFields declares no field');
    }
    const known = {'isConcurrent', 'time', 'frequency'};
    for (final field in fields) {
      if (!known.contains(field)) {
        throw FormatException(
          'rate.recordFields declares the unknown field $field',
        );
      }
    }
    return fields;
  }

  /// The window relation and window count a rate row declares, with the
  /// historical three row meanings as the default.
  ({String window, int frequency}) rateScheduleRow(
    Map<String, dynamic> corpus,
    Map<String, dynamic> step,
    int index,
  ) {
    final declared = _object(corpus['rate'], 'rate')['schedule'];
    if (declared == null) {
      return switch (index) {
        0 => (window: 'opens', frequency: 1),
        1 => (window: 'same', frequency: 2),
        _ => (window: 'rolls', frequency: 1),
      };
    }
    final rowIndex = step['index'];
    for (final raw in _array(declared, 'rate.schedule')) {
      final row = _object(raw, 'rate.schedule row');
      if (row['index'] != rowIndex) continue;
      final window = '${row['window']}';
      if (window != 'opens' && window != 'same' && window != 'rolls') {
        throw FormatException(
          'rate.schedule declares the unknown window $window',
        );
      }
      final frequency = row['frequency'];
      if (frequency is! int) {
        throw const FormatException(
          'rate.schedule frequency is not an integer',
        );
      }
      return (window: window, frequency: frequency);
    }
    throw FormatException('rate.schedule declares no row for index $rowIndex');
  }

  final rateSteps = [
    for (final raw in _array(rate['steps'], 'rate.steps')) '$raw',
  ];
  final rateFields = rateRecordFields(rate);
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
      for (final field in rateFields) {
        gate.field(
          map,
          field,
          path,
          field == 'isConcurrent' ? _Field.boolean : _Field.integer,
        );
      }
      return map;
    }

    final before = record(value['recordBefore'], '$where.recordBefore');
    final after = record(value['recordAfter'], '$where.recordAfter');
    final schedule = rateScheduleRow(corpus, stepById[id]!, index);
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
    // A record this operation created or reset carries that operation's own
    // admission instant; a same-window record carries the shared window start.
    final createdHere =
        schedule.window == 'opens' || value['sameWindowAsPrevious'] == false;
    if (createdHere && callStart is int && callFinish is int && after != null) {
      final recordTime = after['time'];
      if (recordTime is int &&
          (recordTime < callStart || recordTime > callFinish)) {
        gate.fail(
          '$where.recordAfter.time lies outside its own operation '
          'interval',
        );
      }
    }
    if (schedule.window == 'opens') {
      if (before != null) gate.fail('$where.recordBefore is not null');
      if (after == null) {
        gate.fail('$where.recordAfter is absent');
        continue;
      }
      if (rateFields.contains('isConcurrent')) {
        gate.equal(
          after['isConcurrent'],
          true,
          '$where.recordAfter.isConcurrent',
        );
      }
      gate.equal(
        after['frequency'],
        schedule.frequency,
        '$where.recordAfter.frequency',
      );
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
    if (rateFields.contains('isConcurrent')) {
      gate.equal(
        after['isConcurrent'],
        true,
        '$where.recordAfter.isConcurrent',
      );
    }
    final beforeTime = before['time'] as int? ?? 0;
    final afterTime = after['time'] as int? ?? 0;
    final sameWindow = value['sameWindowAsPrevious'] == true;
    gate.equal(
      sameWindow,
      beforeTime == afterTime,
      '$where.sameWindowAsPrevious',
    );
    if (schedule.window == 'same') {
      if (!sameWindow) gate.fail('$where did not stay in its window');
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
      gate.equal(
        after['frequency'],
        schedule.frequency,
        '$where.recordAfter.frequency',
      );
      if (callStart - afterTime >= rateWindow || callStart - afterTime < 0) {
        gate.fail('$where was admitted outside its declared window');
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
      gate.equal(
        after['frequency'],
        schedule.frequency,
        '$where.recordAfter.frequency',
      );
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

  // The owned-worker teardown receipt is a measurement, not a label: its types
  // and its relations to the cleanup facts decide whether the run may claim a
  // clean exit.
  if (!product.containsKey('ownedTeardown')) {
    gate.fail(
      'ownedTeardown is missing from a run that owns a cancellation row',
    );
  } else {
    final teardown = gate.object(product['ownedTeardown'], 'ownedTeardown');
    for (final entry in const [
      ('workerSettled', _Field.boolean),
      ('stepsAttempted', _Field.array),
      ('stepsRun', _Field.array),
      ('errors', _Field.array),
      ('residueRetained', _Field.boolean),
      ('timeoutMillis', _Field.integer),
    ]) {
      gate.field(teardown, entry.$1, 'ownedTeardown', entry.$2);
    }
    for (final key in const ['stepsAttempted', 'stepsRun']) {
      final steps = gate.array(teardown[key], 'ownedTeardown.$key');
      for (var slot = 0; slot < steps.length; slot++) {
        if (steps[slot] is! String) {
          gate.fail('ownedTeardown.$key.$slot is not a string');
        }
      }
    }
    final stepsRun = gate.array(teardown['stepsRun'], 'ownedTeardown.stepsRun');
    final teardownErrors = gate.array(
      teardown['errors'],
      'ownedTeardown.errors',
    );
    for (var slot = 0; slot < teardownErrors.length; slot++) {
      final failure = gate.object(
        teardownErrors[slot],
        'ownedTeardown.errors.$slot',
      );
      for (final entry in const [
        ('step', _Field.string),
        ('errorType', _Field.string),
        ('error', _Field.string),
      ]) {
        gate.field(failure, entry.$1, 'ownedTeardown.errors.$slot', entry.$2);
      }
    }
    final timeoutMillis = teardown['timeoutMillis'];
    if (timeoutMillis is int && timeoutMillis <= 0) {
      gate.fail('ownedTeardown.timeoutMillis is not a positive deadline');
    }
    final workerSettled = teardown['workerSettled'];
    if (workerSettled == true) {
      gate.equal(
        teardown['residueRetained'],
        false,
        'ownedTeardown.residueRetained',
      );
      gate.equal(teardown['stepsAttempted'], const [
        'snapshotDatabase',
        'closeDatabase',
        'disposeNative',
      ], 'ownedTeardown.stepsAttempted');
      gate.equal(stepsRun, const [
        'snapshotDatabase',
        'closeDatabase',
        'disposeNative',
      ], 'ownedTeardown.stepsRun');
      gate.emptyArray(teardown['errors'], 'ownedTeardown.errors');
      gate.equal(
        cleanup['databaseClosed'],
        true,
        'ownedTeardown implies a closed database',
      );
      gate.equal(
        cleanup['nativeLibraryDisposed'],
        true,
        'ownedTeardown implies a disposed native runtime',
      );
    } else if (workerSettled == false) {
      gate.equal(
        teardown['residueRetained'],
        true,
        'ownedTeardown.residueRetained',
      );
      gate.equal(
        teardown['stepsAttempted'],
        const <Object?>[],
        'ownedTeardown.stepsAttempted',
      );
      gate.equal(stepsRun, const <Object?>[], 'ownedTeardown.stepsRun');
      gate.emptyArray(teardown['errors'], 'ownedTeardown.errors');
      gate.equal(
        cleanup['databaseClosed'],
        false,
        'an unresolved owned worker cannot have closed the database',
      );
      gate.equal(
        cleanup['nativeLibraryDisposed'],
        false,
        'an unresolved owned worker cannot have disposed the native runtime',
      );
      gate.equal(
        cleanup['scratchRemoved'],
        false,
        'an unresolved owned worker keeps its owned root',
      );
      gate.equal(
        cleanup['rootAbsentAfter'],
        false,
        'an unresolved owned worker keeps its owned root',
      );
      gate.equal(
        terminal['integrityOk'],
        false,
        'an unresolved owned worker cannot claim a clean terminal',
      );
    }
  }

  if (productPath.isEmpty) {
    throw HttpBoundaryRefusal('the product report path is empty');
  }
  gate.throwIfAny();
}

void _v3ObservationFacts(
  _ProductGate gate,
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  Map<String, dynamic> row,
  Map<String, dynamic> value,
  Map<String, List<Map<String, dynamic>>> ownedByObservation,
  Map<String, Map<String, dynamic>> observationById,
) {
  final id = '${step['id']}';
  final where = 'observations.$id';
  final stage = '${step['stage'] ?? ''}';
  final expectedOutcome = '${step['expectedOutcome'] ?? 'ok'}';
  if ('${step['kind']}' == 'stage' &&
      stage == 'details' &&
      expectedOutcome == 'ok') {
    final book = _declaredBook(corpus, '${step['book']}');
    gate.equal(value['bookUrl'], book['bookUrl'], '$where.value.bookUrl');
  }
  if ('${step['action']}' != 'scriptProbe') return;
  final result = value['result'];
  final evidence = gate.object(row['evidence'], '$where.evidence');
  final probe = gate.object(
    evidence['scriptProbe'],
    '$where.evidence.scriptProbe',
  );
  final diagnostics = probe['diagnostics'];
  if (diagnostics is! Map) {
    gate.fail('$where.evidence.scriptProbe.diagnostics is not an object');
    return;
  }
  try {
    validateHttpBoundaryScriptProbeEnvelope({
      'portable': result,
      'diagnostics': diagnostics,
    }, where: '$where.evidence.scriptProbe');
  } on FormatException catch (error) {
    gate.fail('$where script probe projection is not typed: ${error.message}');
  }
  final owned = ownedByObservation[id] ?? const <Map<String, dynamic>>[];
  if (owned.isNotEmpty) {
    gate.fail('$where script probe owns ${owned.length} requests');
  }
  if (value['action'] != 'scriptProbe' ||
      '${value['source']}' != '${step['source']}') {
    gate.fail('$where value does not name the script-probe source/action');
  }
}

void _v3CarrierPairFacts(
  _ProductGate gate,
  Map<String, dynamic> corpus,
  Map<String, dynamic> product,
) {
  try {
    validateHttpBoundaryCarrierRelations(product, corpus, where: 'product');
  } on Object catch (error) {
    gate.fail('$error');
  }
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

/// The failure step's own declared request: its source's `searchUrl` template
/// expanded with the step's keyword and page, exactly as the corpus declares it
/// and the pipeline issues it. Used to bind the separate connection trace.
({String method, String path, String rawQuery, Map<String, String> headers})
_declaredFailureRequest(Map<String, dynamic> corpus) {
  final endpoint = _object(corpus['failureEndpoint'], 'failureEndpoint');
  final stepId = '${endpoint['step']}';
  final step = httpBoundarySteps(corpus).firstWhere(
    (candidate) => '${candidate['id']}' == stepId,
    orElse: () =>
        throw const HttpBoundaryRefusal('the corpus declares no failure step'),
  );
  final source = httpBoundarySourceOf(corpus, '${step['source']}');
  final template = '${source['searchUrl']}';
  final cut = template.indexOf(',{');
  final path = cut < 0 ? template : template.substring(0, cut);
  final expanded = path
      .replaceAll(r'{{key}}', '${step['keyword']}')
      .replaceAll(r'{{page}}', '1');
  final boundary = expanded.indexOf('?');
  final headers = <String, String>{};
  // The source's own static header rule is part of the request's identity; a
  // script rule is left to the runtime and is not re-evaluated here.
  final declaredHeader = '${source['header'] ?? ''}'.trim();
  if (declaredHeader.startsWith('{')) {
    try {
      final decoded = jsonDecode(declaredHeader);
      if (decoded is Map) {
        for (final entry in decoded.entries) {
          headers['${entry.key}'.toLowerCase()] = '${entry.value}';
        }
      }
    } on FormatException {
      // A non-static rule is not an authored header map; the step's own
      // requirements below still apply.
    }
  }
  final required = step['requiredHeaders'];
  if (required is Map) {
    for (final entry in required.entries) {
      headers['${entry.key}'.toLowerCase()] = '${entry.value}';
    }
  }
  return (
    method: 'GET',
    path: boundary < 0 ? expanded : expanded.substring(0, boundary),
    rawQuery: boundary < 0 ? '' : expanded.substring(boundary + 1),
    headers: headers,
  );
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
  // The separate connection trace is compared, not only counted: every actual
  // attempt's portable request identity and its classification, in causal order.
  final expectedConnections = [
    for (final raw in _array(
      expectedFailure['connections'],
      'golden failEndpoint.connections',
    ))
      _object(raw, 'golden connection'),
  ];
  final productConnections = [
    for (final raw in _array(
      productFailure['connections'],
      'product failEndpoint.connections',
    ))
      _object(raw, 'product connection'),
  ];
  if (expectedConnections.length != productConnections.length) {
    mismatches.add(
      HttpBoundaryMismatch(
        surface: 'failEndpoint',
        row: 'connections',
        field: 'count',
        expected: expectedConnections.length,
        observed: productConnections.length,
        kind: 'count',
      ),
    );
  }
  final sharedConnections =
      expectedConnections.length < productConnections.length
      ? expectedConnections.length
      : productConnections.length;
  for (var index = 0; index < sharedConnections; index++) {
    final expectedConnection = expectedConnections[index];
    final productConnection = productConnections[index];
    for (final field in const [
      'classification',
      'method',
      'path',
      'rawQuery',
      'target',
      'requestObserved',
      'terminal',
    ]) {
      if (expectedConnection[field] != productConnection[field]) {
        mismatches.add(
          HttpBoundaryMismatch(
            surface: 'failEndpoint',
            row: 'connections.$index',
            field: field,
            expected: expectedConnection[field],
            observed: productConnection[field],
          ),
        );
      }
    }
    // The source-controlled headers only: the ephemeral host header is already
    // one of the corpus' documented exclusions.
    final expectedHeaders = portableHeaders(expectedConnection['headers']);
    final productHeaders = portableHeaders(productConnection['headers']);
    if (_canonical(expectedHeaders) != _canonical(productHeaders)) {
      mismatches.add(
        HttpBoundaryMismatch(
          surface: 'failEndpoint',
          row: 'connections.$index',
          field: 'headers',
          expected: expectedHeaders,
          observed: productHeaders,
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
  // 8. The approved named differences. Each one remains in the strict mismatch
  //    list above; this disposition names both actual values and the approved
  //    reason. A mismatch the classifier does not bind stays unattributed, and
  //    nothing here can turn a difference into a pass.
  final notCompared = <HttpBoundaryNotCompared>[];
  for (final mismatch in mismatches) {
    final named = attributeHttpBoundaryMismatch(
      corpus: corpus,
      product: product,
      mismatch: mismatch,
    );
    if (named != null) notCompared.add(named);
  }
  return HttpBoundaryComparison(
    goldenId: goldenId,
    mismatches: mismatches,
    notCompared: notCompared,
    notes: notes,
  );
}

/// The configured `ajaxAll` width and the declared page-list scheduling are
/// approved architecture facts: the strict mismatch stays visible, and this
/// disposition records why it is not a frozen parity claim.
const httpBoundaryConfiguredWidthReason =
    'Approved experience-first default: SourceHostDispatcher.ajaxAll batches '
    'four requests, while the frozen capture records AppConfig.threadCount 16. '
    'Returned order, request values, the per-source rate limiter and '
    'cancellation remain strictly compared.';

const httpBoundaryWidthCohortReason =
    '$httpBoundaryConfiguredWidthReason The declared 5-member cohort '
    'consequently records the measured peak 4 and a cohort-window release; '
    'those are the measured consequences of that configured width.';

const httpBoundaryPageListSchedulingReason =
    'Approved current behavior: a declared TOC/content page list is fetched '
    'serially at width 1, while the frozen baseline batches it at '
    'AppConfig.threadCount 16. Declared output order and the per-source rate '
    'limiter are preserved; the measured cohort and request facts are the '
    'consequence of that scheduling.';

const httpBoundaryZeroArityReason =
    'Approved supported product extension: the frozen Rhino binding refuses '
    'the zero-argument source.getHeaderMap() call, while the product answers '
    'it. The returned value is required to equal the product\'s explicit '
    'getHeaderMap(false) form; explicit false/true calls, ordinary property '
    'reads and .get() remain required comparisons.';

const httpBoundaryCancellationOwnerReason =
    'Cancellation-owner names are provenance: the frozen oracle records its '
    'created Kotlin parent Job and the product records its pipeline '
    'cancellation. Request/script stopping, late effects, job/terminal state, '
    'state/database preservation, owned cleanup and the fresh follow-up remain '
    'strictly compared.';

const httpBoundaryJavaReturnStringReason =
    'Approved named difference: a Java method or map return reaches the source '
    'script as a Java String object, so its typeof is object and its strict '
    'literal equality with the same text fails, while the product returns the '
    'primitive JS string. Only the enumerated type and strict-equality leaves '
    'of this v3 group differ and stay in the mismatch list with their measured '
    'values; text, coercion, loose equality, boolean returns, every other leaf '
    'and every other row stay strictly compared, and the comparison does not '
    'pass. Primitive JS string returns are retained; a complete cross-segment '
    'Java-object carrier needs a separately approved reopening of the closed '
    'container determination (#128).';

/// The twelve measured scalar Java-return leaves: the declared row, its own
/// source and the exact object->string or false->true pair the two captures
/// recorded.
const _javaReturnScalarLeaves =
    <
      ({
        String row,
        String source,
        String field,
        Object expected,
        Object observed,
      })
    >[
      (
        row: 'helper.script-probe-hg0',
        source: 'HG0',
        field: 'value.result.lookup.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg0',
        source: 'HG0',
        field: 'value.result.lookup.strictLiteral',
        expected: false,
        observed: true,
      ),
      (
        row: 'helper.script-probe-hg1',
        source: 'HG1',
        field: 'value.result.getDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg1',
        source: 'HG1',
        field: 'value.result.getBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        source: 'HG2',
        field: 'value.result.keySetDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        source: 'HG2',
        field: 'value.result.keySetBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        source: 'HG2',
        field: 'value.result.lookup.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        source: 'HG2',
        field: 'value.result.lookup.strictLiteral',
        expected: false,
        observed: true,
      ),
      (
        row: 'helper.script-probe-hg3',
        source: 'HG3',
        field: 'value.result.getDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        source: 'HG3',
        field: 'value.result.getBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        source: 'HG3',
        field: 'value.result.keySetDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        source: 'HG3',
        field: 'value.result.keySetBracket.type',
        expected: 'object',
        observed: 'string',
      ),
    ];

/// The flat `v1.details` probe envelope's exact keys and the ten measured
/// type/strict leaves the two captures report on it.
const _javaReturnDetailsEnvelopeKeys = <String>[
  'directType',
  'directStrict',
  'directText',
  'chainedType',
  'chainedStrict',
  'chainedLoose',
  'chainedText',
  'bookBeforeType',
  'bookBeforeStrict',
  'bookBeforeText',
  'bookPutType',
  'bookPutStrict',
  'bookAfterType',
  'bookAfterStrict',
  'bookAfterLoose',
  'bookAfterText',
  'sourceBeforeType',
  'sourceBeforeStrict',
  'sourceBeforeText',
  'sourceAfterType',
  'sourceAfterStrict',
  'sourceAfterLoose',
  'sourceAfterText',
];

const _javaReturnDetailsEnvelopeAxes = <String, (Object, Object)>{
  'chainedType': ('object', 'string'),
  'chainedStrict': (false, true),
  'bookBeforeType': ('object', 'string'),
  'bookBeforeStrict': (false, true),
  'bookAfterType': ('object', 'string'),
  'bookAfterStrict': (false, true),
  'sourceBeforeType': ('object', 'string'),
  'sourceBeforeStrict': (false, true),
  'sourceAfterType': ('object', 'string'),
  'sourceAfterStrict': (false, true),
};

/// The flat `v1.content` probe envelope's exact keys and the eight measured
/// type/strict leaves the two captures report on it.
const _javaReturnContentEnvelopeKeys = <String>[
  'directType',
  'directStrict',
  'directText',
  'chapterBeforeType',
  'chapterBeforeStrict',
  'chapterBeforeText',
  'chapterPutType',
  'chapterPutStrict',
  'chapterAfterType',
  'chapterAfterStrict',
  'chapterAfterLoose',
  'chapterAfterText',
  'bookPersistType',
  'bookPersistStrict',
  'bookPersistLoose',
  'bookPersistText',
  'sourcePersistType',
  'sourcePersistStrict',
  'sourcePersistLoose',
  'sourcePersistText',
];

const _javaReturnContentEnvelopeAxes = <String, (Object, Object)>{
  'chapterBeforeType': ('object', 'string'),
  'chapterBeforeStrict': (false, true),
  'chapterAfterType': ('object', 'string'),
  'chapterAfterStrict': (false, true),
  'bookPersistType': ('object', 'string'),
  'bookPersistStrict': (false, true),
  'sourcePersistType': ('object', 'string'),
  'sourcePersistStrict': (false, true),
};

/// The two V rows whose whole measured field is one JSON probe envelope string.
final _javaReturnEnvelopeCases =
    <
      ({
        String row,
        String stage,
        String field,
        List<String> keys,
        Map<String, (Object, Object)> axes,
      })
    >[
      (
        row: 'v1.details',
        stage: 'details',
        field: 'value.latestChapterTitle',
        keys: _javaReturnDetailsEnvelopeKeys,
        axes: _javaReturnDetailsEnvelopeAxes,
      ),
      (
        row: 'v1.content',
        stage: 'content',
        field: 'value.text',
        keys: _javaReturnContentEnvelopeKeys,
        axes: _javaReturnContentEnvelopeAxes,
      ),
    ];

/// Binds one strict mismatch to the measured Java-return string identity: the
/// twelve scalar helper leaves of the committed v3 probes and the two V
/// whole-field probe envelopes. The row, its declared step, its source, the
/// field and the measured value pair are all required, and a named difference
/// is never equality: the strict mismatch and its values stay in the list.
({String group, String reason})? _javaReturnStringDisposition(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  HttpBoundaryMismatch mismatch,
) {
  if (!httpBoundaryCorpusVersions.contains(corpus['corpusVersion'])) {
    return null;
  }
  if (!_javaReturnScalarLeaf(step, mismatch) &&
      !_javaReturnEnvelopeLeaf(step, mismatch)) {
    return null;
  }
  return (
    group: 'java-return-string-identity',
    reason: httpBoundaryJavaReturnStringReason,
  );
}

/// One of the twelve measured scalar identities: a helper observation of a
/// scriptProbe step on its own source with the exact field and value pair.
bool _javaReturnScalarLeaf(
  Map<String, dynamic> step,
  HttpBoundaryMismatch mismatch,
) {
  if ('${step['kind']}' != 'helper' ||
      '${step['family']}' != 'helper' ||
      '${step['action']}' != 'scriptProbe' ||
      mismatch.kind != 'type-or-value') {
    return false;
  }
  for (final leaf in _javaReturnScalarLeaves) {
    if (mismatch.row != leaf.row ||
        '${step['id']}' != leaf.row ||
        '${step['source']}' != leaf.source ||
        mismatch.field != leaf.field) {
      continue;
    }
    return mismatch.expected == leaf.expected &&
        mismatch.observed == leaf.observed;
  }
  return false;
}

/// One of the two V envelope rows: the row's own stage details/content step and
/// the exact flat envelope keys, where only the enumerated type/strict leaves
/// may differ and every other key stays equal.
bool _javaReturnEnvelopeLeaf(
  Map<String, dynamic> step,
  HttpBoundaryMismatch mismatch,
) {
  if (mismatch.kind != 'type-or-value') return false;
  for (final envelope in _javaReturnEnvelopeCases) {
    if (mismatch.row != envelope.row ||
        mismatch.field != envelope.field ||
        '${step['kind']}' != 'stage' ||
        '${step['family']}' != 'stage' ||
        '${step['stage'] ?? ''}' != envelope.stage ||
        '${step['source']}' != 'V') {
      continue;
    }
    final expected = _javaReturnEnvelope(mismatch.expected);
    final observed = _javaReturnEnvelope(mismatch.observed);
    if (expected == null || observed == null) return false;
    if (expected.length != envelope.keys.length ||
        observed.length != envelope.keys.length) {
      return false;
    }
    for (final key in envelope.keys) {
      if (!expected.containsKey(key) || !observed.containsKey(key)) {
        return false;
      }
      final axis = envelope.axes[key];
      if (axis == null) {
        if (expected[key] != observed[key]) return false;
        continue;
      }
      if (expected[key] != axis.$1 || observed[key] != axis.$2) return false;
    }
    return true;
  }
  return false;
}

/// The flat probe envelope a V row's measured field carries, or null when the
/// field is not exactly one readable JSON object.
Map<String, Object?>? _javaReturnEnvelope(Object? raw) {
  if (raw is! String) return null;
  try {
    final decoded = jsonDecode(raw);
    return decoded is Map ? decoded.cast<String, Object?>() : null;
  } on FormatException {
    return null;
  }
}

/// Binds one strict mismatch to one of the amended differential contract's
/// approved named differences, or returns null so the mismatch stays an
/// unattributed failure. Every branch reads the corpus' own declared rows and
/// the actual values; no row is matched by a wildcard and no unknown width,
/// peak, result or changed behavioral fact is absorbed.
HttpBoundaryNotCompared? attributeHttpBoundaryMismatch({
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> product,
  required HttpBoundaryMismatch mismatch,
}) {
  final approved = _approvedDifference(corpus, product, mismatch);
  if (approved == null) return null;
  return HttpBoundaryNotCompared(
    mismatch: mismatch,
    approved: approved.group,
    reason: approved.reason,
  );
}

({String group, String reason})? _approvedDifference(
  Map<String, dynamic> corpus,
  Map<String, dynamic> product,
  HttpBoundaryMismatch mismatch,
) {
  final steps = httpBoundarySteps(corpus);
  final stepById = {for (final step in steps) '${step['id']}': step};
  final runtime = corpus['runtime'];
  final frozenWidth = runtime is Map && runtime['threadCountDefault'] is int
      ? runtime['threadCountDefault'] as int
      : null;

  // The configured batch width itself, as the run's runtime configuration and
  // as each helper batch's own measured configuration.
  if (mismatch.surface == 'runtimeConfiguration' &&
      mismatch.row == 'batch-width' &&
      mismatch.field == 'threadCount' &&
      frozenWidth != null &&
      mismatch.expected == frozenWidth &&
      mismatch.observed == httpBoundaryBatchWidth) {
    return (
      group: 'ajaxall-configured-width',
      reason: httpBoundaryConfiguredWidthReason,
    );
  }

  if (mismatch.surface == 'observation') {
    final step = stepById[mismatch.row];
    if (step != null) {
      final declared = httpBoundaryDeclaredRequests(step);
      final cohort = declared.cohort;
      final family = '${step['family']}';
      final stage = '${step['stage'] ?? ''}';
      final isHelperBatch = family == 'helper' && cohort != null;
      final isPageListBatch =
          family == 'stage' &&
          (stage == 'toc' || stage == 'content') &&
          cohort != null;
      if (mismatch.field == 'value.batch.threadCount' &&
          frozenWidth != null &&
          mismatch.expected == frozenWidth) {
        if (isHelperBatch && mismatch.observed == httpBoundaryBatchWidth) {
          return (
            group: 'ajaxall-configured-width',
            reason: httpBoundaryConfiguredWidthReason,
          );
        }
        if (isPageListBatch &&
            mismatch.observed == httpBoundarySerialWalkWidth) {
          return (
            group: 'page-list-scheduling',
            reason: httpBoundaryPageListSchedulingReason,
          );
        }
      }
      final cohortSize = cohort == null
          ? null
          : _declaredCohortSize(corpus, cohort);
      if (isHelperBatch &&
          cohortSize == 5 &&
          _isCohortConsequence(mismatch, cohortSize!, httpBoundaryBatchWidth)) {
        return (
          group: 'ajaxall-configured-width',
          reason: httpBoundaryWidthCohortReason,
        );
      }
      if (isPageListBatch &&
          cohortSize != null &&
          _isCohortConsequence(
            mismatch,
            cohortSize,
            httpBoundarySerialWalkWidth,
          )) {
        return (
          group: 'page-list-scheduling',
          reason: httpBoundaryPageListSchedulingReason,
        );
      }
      if ('${step['action']}' == 'headerMap') {
        final zero = _zeroArityDisposition(product, mismatch);
        if (zero != null) return zero;
      }
      final javaString = _javaReturnStringDisposition(corpus, step, mismatch);
      if (javaString != null) return javaString;
    }
    // The two cancellation-owner labels, bound to the corpus' own steps.
    final cancellation = corpus['cancellation'];
    if (cancellation is Map) {
      var cancelId = '';
      for (final step in steps) {
        if ('${step['kind']}' == 'cancel') {
          cancelId = '${step['id']}';
          break;
        }
      }
      final followUpId = '${cancellation['followUpStep']}';
      final ownerField =
          (mismatch.row == cancelId &&
              mismatch.field == 'value.execution.jobLevel') ||
          (mismatch.row == followUpId &&
              mismatch.field == 'value.followUp.jobLevel');
      if (ownerField &&
          mismatch.expected == 'created-parent' &&
          mismatch.observed == 'pipeline-cancellation') {
        return (
          group: 'cancellation-owner-provenance',
          reason: httpBoundaryCancellationOwnerReason,
        );
      }
    }
    return null;
  }

  if (mismatch.surface == 'request') {
    final row = mismatch.row;
    final first = row.indexOf('|');
    final last = row.lastIndexOf('|');
    if (first <= 0 || last <= first) return null;
    final owner = row.substring(0, first);
    final step = stepById[owner];
    if (step == null) return null;
    final declared = httpBoundaryDeclaredRequests(step);
    final cohort = declared.cohort;
    if (cohort == null) return null;
    final family = '${step['family']}';
    final stage = '${step['stage'] ?? ''}';
    final isHelperBatch = family == 'helper';
    final isPageListBatch =
        family == 'stage' && (stage == 'toc' || stage == 'content');
    if (!isHelperBatch && !isPageListBatch) return null;
    // The row must be one of the step's declared batch members at its own
    // counted attempt; an undeclared selector or attempt is never absorbed.
    if (!_declaredRequestKeys(corpus, step).contains(row)) return null;
    final cohortSize = _declaredCohortSize(corpus, cohort);
    final cohortFact =
        (mismatch.field == 'cohortComplete' &&
            mismatch.expected == true &&
            mismatch.observed == false) ||
        (mismatch.field == 'releaseReason' &&
            mismatch.expected == 'complete' &&
            mismatch.observed == 'cohort-window');
    if (!cohortFact) return null;
    if (isHelperBatch && cohortSize == 5) {
      return (
        group: 'ajaxall-configured-width',
        reason: httpBoundaryWidthCohortReason,
      );
    }
    if (isPageListBatch) {
      return (
        group: 'page-list-scheduling',
        reason: httpBoundaryPageListSchedulingReason,
      );
    }
    return null;
  }
  return null;
}

bool _isCohortConsequence(
  HttpBoundaryMismatch mismatch,
  int cohortSize,
  int width,
) {
  if (mismatch.field == 'value.batch.cohortComplete') {
    return mismatch.expected == true && mismatch.observed == false;
  }
  if (mismatch.field == 'value.batch.releaseReason') {
    return mismatch.expected == 'complete' &&
        mismatch.observed == 'cohort-window';
  }
  if (mismatch.field == 'value.batch.inFlightPeak') {
    return mismatch.expected == cohortSize && mismatch.observed == width;
  }
  return false;
}

({String group, String reason})? _zeroArityDisposition(
  Map<String, dynamic> product,
  HttpBoundaryMismatch mismatch,
) {
  if (!_zeroArityAgreesWithFalseForm(product, mismatch.row)) return null;
  if (mismatch.field == 'value.arities.zero.returned' &&
      mismatch.expected == false &&
      mismatch.observed == true) {
    return (
      group: 'header-map-zero-arity',
      reason: httpBoundaryZeroArityReason,
    );
  }
  if (mismatch.field == 'value.arities.zero.value' &&
      mismatch.kind == 'extra-observed-field' &&
      mismatch.expected == null) {
    return (
      group: 'header-map-zero-arity',
      reason: httpBoundaryZeroArityReason,
    );
  }
  return null;
}

/// The zero-argument result is approved only while it is the same map the
/// product's explicit `getHeaderMap(false)` call answers. A corrupt or missing
/// zero-argument value stays an unattributed strict failure.
bool _zeroArityAgreesWithFalseForm(Map<String, dynamic> product, String rowId) {
  final value = _productObservationValue(product, rowId);
  final arities = value?['arities'];
  if (arities is! Map) return false;
  final zero = arities['zero'];
  final explicitFalse = arities['falseArity'];
  return zero is Map &&
      explicitFalse is Map &&
      zero['returned'] == true &&
      explicitFalse['returned'] == true &&
      zero.containsKey('value') &&
      _semanticEquals(zero['value'], explicitFalse['value']);
}

Map<String, dynamic>? _productObservationValue(
  Map<String, dynamic> product,
  String id,
) {
  final rows = product['observations'];
  if (rows is! List) return null;
  for (final raw in rows) {
    if (raw is Map && '${raw['id']}' == id) {
      final value = raw['value'];
      return value is Map ? value.cast<String, dynamic>() : null;
    }
  }
  return null;
}

int? _declaredCohortSize(Map<String, dynamic> corpus, String cohortId) {
  final cohorts = corpus['cohorts'];
  if (cohorts is! List) return null;
  for (final raw in cohorts) {
    if (raw is Map && '${raw['id']}' == cohortId) {
      final size = raw['size'];
      return size is int ? size : null;
    }
  }
  return null;
}

/// The step's declared batch member keys, with the same counted attempt
/// identity the comparer uses: an ordered selector first, then each member.
Set<String> _declaredRequestKeys(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
) {
  final responseById = {
    for (final response in httpBoundaryResponses(corpus))
      '${response['id']}': response,
  };
  final declared = httpBoundaryDeclaredRequests(step);
  final attempts = <String, int>{};
  String keyOf(String responseId) {
    final response = responseById[responseId];
    if (response == null) return '';
    final selector = httpBoundarySelectorOf(response);
    final attempt = (attempts[selector] ?? 0) + 1;
    attempts[selector] = attempt;
    return '${step['id']}|$selector|$attempt';
  }

  for (final responseId in declared.ordered) {
    keyOf(responseId);
  }
  return {for (final responseId in declared.members) keyOf(responseId)}
    ..remove('');
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

/// One control's outcome: the mismatch keys it was required to introduce, the
/// subset of them the approved classifier left unattributed, and whether the
/// comparison it ran on was its own unmutated baseline.
class HttpBoundaryControl {
  const HttpBoundaryControl({
    required this.id,
    required this.applied,
    required this.target,
    required this.newKeys,
    required this.unattributedNewKeys,
    required this.baselinePassed,
    this.relationFailure,
  });

  final String id;
  final bool applied;
  final String target;
  final List<String> newKeys;
  final List<String> unattributedNewKeys;
  final bool baselinePassed;

  /// A measured-relation control's precise validation failure, when the
  /// mutation corrupts a fact the portable comparison cannot see.
  final String? relationFailure;

  /// A control passes when it really introduced its own new strict difference
  /// or its own measured-relation validation failure, and no approved
  /// disposition absorbed that result.
  bool get passed {
    if (!applied) return false;
    if (relationFailure != null) return relationFailure!.isNotEmpty;
    return newKeys.isNotEmpty && unattributedNewKeys.length == newKeys.length;
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'applied': applied,
    'target': target,
    'newMismatchKeys': newKeys,
    'unattributedNewMismatchKeys': unattributedNewKeys,
    'baselinePassed': baselinePassed,
    'relationFailure': relationFailure,
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
          unattributedNewKeys: const [],
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
    final namedKeys = {for (final entry in compared.notCompared) entry.key};
    final unattributed = keys.where((key) => !namedKeys.contains(key)).toList()
      ..sort();
    return [
      HttpBoundaryControl(
        id: id,
        applied: true,
        target: target,
        newKeys: keys,
        unattributedNewKeys: unattributed,
        baselinePassed: baseline.passed,
      ),
    ];
  }

  // A measured-relation control mutates one actual identity and runs the same
  // pure rule the admission gate uses. The baseline must already be valid; an
  // invalid baseline is refused rather than credited to a control.
  final carrierSteps = [
    for (final step in httpBoundarySteps(corpus))
      if (step['carrier'] != null) step,
  ];
  bool hasCarrierRows(Map<String, dynamic> record) {
    final rows = record['observations'];
    if (rows is! List) return false;
    final ids = {for (final raw in rows) '${(raw as Map)['id']}'};
    for (final step in carrierSteps) {
      if (!ids.contains('${step['id']}')) return false;
    }
    return true;
  }

  final canControlRelations =
      carrierSteps.isNotEmpty &&
      hasCarrierRows(product) &&
      hasCarrierRows(golden);
  if (canControlRelations) {
    try {
      validateHttpBoundaryCarrierRelations(
        product,
        corpus,
        where: 'control product baseline',
      );
    } on Object catch (error) {
      throw HttpBoundaryRefusal('control product baseline is invalid: $error');
    }
    try {
      validateFrozenCarrierRelations(
        golden,
        corpus,
        where: 'control frozen baseline',
      );
    } on Object catch (error) {
      throw HttpBoundaryRefusal('control frozen baseline is invalid: $error');
    }
  }
  List<HttpBoundaryControl> runRelation(
    String id,
    String target,
    void Function(
      Map<String, dynamic> goldenCopy,
      Map<String, dynamic> productCopy,
    )
    mutate, {
    bool frozen = false,
  }) {
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
          unattributedNewKeys: const [],
          baselinePassed: baseline.passed,
        ),
      ];
    }
    try {
      if (frozen) {
        validateFrozenCarrierRelations(
          goldenCopy,
          corpus,
          where: 'control $id',
        );
      } else {
        validateHttpBoundaryCarrierRelations(
          productCopy,
          corpus,
          where: 'control $id',
        );
      }
      return [
        HttpBoundaryControl(
          id: id,
          applied: true,
          target: target,
          newKeys: const [],
          unattributedNewKeys: const [],
          baselinePassed: baseline.passed,
        ),
      ];
    } on Object catch (error) {
      return [
        HttpBoundaryControl(
          id: id,
          applied: true,
          target: target,
          newKeys: const [],
          unattributedNewKeys: const [],
          baselinePassed: baseline.passed,
          relationFailure: '$error',
        ),
      ];
    }
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
  controls.addAll(
    run('product-carrier-origin', 'product s1.search result origin', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 's1.search')['value'],
        'value',
      );
      _object(_array(value['results'], 'results').first, 'result')['origin'] =
          'http://127.0.0.1:18771/other';
    }),
  );
  controls.addAll(
    run('product-carrier-type', 'product s1.search result type', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 's1.search')['value'],
        'value',
      );
      _object(_array(value['results'], 'results').first, 'result')['type'] = 32;
    }),
  );
  controls.addAll(
    run('product-cancellation-behavior', 'product s5 worker termination', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 's5.search-cancelled')['value'],
        'value',
      );
      value['workerTerminated'] = false;
    }),
  );
  // The v3 observation controls: each targets a fact its own new row carries,
  // so a green baseline cannot be satisfied by an unrelated existing mismatch.
  controls.addAll(
    run(
      'product-script-probe-value',
      'product helper.script-probe-hg1 projection',
      (goldenCopy, productCopy) {
        final value = _object(
          observation(productCopy, 'helper.script-probe-hg1')['value'],
          'value',
        );
        final result = _object(value['result'], 'result');
        final lookup = _object(result['lookup'], 'lookup');
        lookup['returned'] = lookup['returned'] != true;
      },
    ),
  );
  controls.addAll(
    run(
      'product-native-return-presence',
      'product v1.details latestChapterTitle',
      (goldenCopy, productCopy) {
        _object(
          observation(productCopy, 'v1.details')['value'],
          'value',
        ).remove('latestChapterTitle');
      },
    ),
  );
  controls.addAll(
    run('product-fresh-binding', 'product o1.details-same retained bookUrl', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 'o1.details-same')['value'],
        'value',
      );
      // The analyzed target is a different concept; publish it as the retained
      // book identity and the control adds its own key.
      value['bookUrl'] = 'http://127.0.0.1:18771/o/book';
    }),
  );
  if (canControlRelations) {
    controls.addAll(
      runRelation(
        'product-fresh-substituted-hit',
        'product o1.details-fresh retained hit address',
        (goldenCopy, productCopy) {
          final hit = _object(
            _object(
              observation(productCopy, 'o1.details-fresh')['evidence'],
              'evidence',
            )['hitReference'],
            'hitReference',
          );
          hit['rawAddress'] =
              'http://127.0.0.1:18771/o/book/SUBSTITUTED,{"js":"other"}';
        },
      ),
    );
    controls.addAll(
      runRelation(
        'product-fresh-reused-pipeline',
        'product o1.details-fresh pipeline relation',
        (goldenCopy, productCopy) {
          final carrier = _object(
            _object(
              observation(productCopy, 'o1.details-fresh')['evidence'],
              'evidence',
            )['carrier'],
            'carrier',
          );
          carrier['pipelineIdentity'] = carrier['cachedPipelineIdentity'];
          carrier['reusedPipeline'] = true;
        },
      ),
    );
    controls.addAll(
      runRelation(
        'product-fresh-reused-transport',
        'product o1.details-fresh transport relation',
        (goldenCopy, productCopy) {
          final carrier = _object(
            _object(
              observation(productCopy, 'o1.details-fresh')['evidence'],
              'evidence',
            )['carrier'],
            'carrier',
          );
          carrier['transportIdentity'] = carrier['cachedTransportIdentity'];
          carrier['distinctTransport'] = false;
        },
      ),
    );
    controls.addAll(
      runRelation(
        'product-fresh-wrong-source-object',
        'product o1.details-fresh source object relation',
        (goldenCopy, productCopy) {
          final carrier = _object(
            _object(
              observation(productCopy, 'o1.details-fresh')['evidence'],
              'evidence',
            )['carrier'],
            'carrier',
          );
          final current = carrier['sourceObjectIdentity'] as int;
          carrier['sourceObjectIdentity'] = current == 0 ? 1 : 0;
        },
      ),
    );
    controls.addAll(
      runRelation(
        'product-fresh-wrong-stored-hit',
        'product o1.details-fresh stored hit relation',
        (goldenCopy, productCopy) {
          final hit = _object(
            _object(
              observation(productCopy, 'o1.details-fresh')['evidence'],
              'evidence',
            )['hitReference'],
            'hitReference',
          );
          final current = hit['storedIdentity'] as int;
          hit['storedIdentity'] = current == 0 ? 1 : 0;
        },
      ),
    );
    controls.addAll(
      runRelation(
        'golden-fresh-retained-book',
        'golden o1.details-fresh retained book identity',
        (goldenCopy, productCopy) {
          final value = _object(
            observation(goldenCopy, 'o1.details-fresh')['value'],
            'value',
          );
          value['bookUrl'] = 'http://127.0.0.1:18771/o/book/1';
        },
        frozen: true,
      ),
    );
  }
  controls.addAll(
    run('product-same-extra-execution', 'product o1.details-same counter', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 'o1.details-same')['value'],
        'value',
      );
      final current = int.tryParse('${value['counterAfter']}') ?? 0;
      value['counterAfter'] = '${current + 1}';
    }),
  );
  controls.addAll(
    run('product-fresh-missing-execution', 'product o1.details-fresh counter', (
      goldenCopy,
      productCopy,
    ) {
      final value = _object(
        observation(productCopy, 'o1.details-fresh')['value'],
        'value',
      );
      final current = int.tryParse('${value['counterAfter']}') ?? 0;
      value['counterAfter'] = '${current > 0 ? current - 1 : 0}';
    }),
  );
  controls.addAll(
    run(
      'product-option-counter',
      'product n1.toc counter-backed chapter title',
      (goldenCopy, productCopy) {
        final value = _object(
          observation(productCopy, 'n1.toc')['value'],
          'value',
        );
        final chapters = _array(value['chapters'], 'chapters');
        _object(chapters.first, 'chapter')['title'] = '';
      },
    ),
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
  var corpusPath = httpBoundaryCorpusPath;
  for (final arg in args) {
    if (arg.startsWith('--handoff=')) {
      handoffPath = arg.substring('--handoff='.length);
    } else if (arg.startsWith('--product=')) {
      productPath = arg.substring('--product='.length);
    } else if (arg.startsWith('--evidence=')) {
      evidencePath = arg.substring('--evidence='.length);
    } else if (arg.startsWith('--corpus=')) {
      final value = arg.substring('--corpus='.length).trim();
      if (value.isEmpty) {
        stderr.writeln('--corpus is empty');
        exitCode = 64;
        return;
      }
      corpusPath = value;
    } else {
      stderr.writeln('unknown comparer argument: $arg');
      exitCode = 64;
      return;
    }
  }
  if (handoffPath == null || productPath == null || evidencePath == null) {
    stderr.writeln(
      'Usage: dart run tool/http_boundary/compare.dart --handoff=<json> '
      '--product=<report.json> --evidence=<dir> [--corpus=<path>]',
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
    'notCompared': <Map<String, Object?>>[],
    'analysisFailure': null,
  };
  var exit = 1;
  try {
    final corpusFile = File(corpusPath);
    final corpus = loadHttpBoundaryCorpus(corpusPath);
    final corpusLf = httpBoundaryCorpusSha256Lf(corpusFile);
    final rawSha = sha256File(corpusFile);
    corpus['_rawSha256'] = rawSha;
    final handoff = loadHttpBoundaryReport(handoffPath);
    if (handoff['status'] != 'captured') {
      throw HttpBoundaryRefusal('the handoff is not a captured session');
    }
    if (handoff['integrationHead'] !=
        '276a625e4aef0104240beac1908e597c6023ef93') {
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
      for (final entry in comparison.notCompared) {
        // Every capture's approved names stay in the aggregate result with the
        // capture they came from; neither capture can hide the other's rows.
        (result['notCompared']! as List).add({
          ...entry.toJson(),
          'golden': goldenId,
        });
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
  final named = [
    for (final run in result['runs']! as List)
      for (final entry in ((run as Map)['notCompared'] as List)) entry,
  ];
  stdout.writeln(
    'http-boundary comparison: ${result['status']} '
    '(${(result['runs']! as List).length} captures, '
    '${failures.length} strict differences, ${named.length} named-approved, '
    '${failures.length - named.length} unattributed) -> ${out.path}',
  );
  for (final failure in failures.take(60)) {
    stdout.writeln(failure);
  }
  exitCode = exit;
}
