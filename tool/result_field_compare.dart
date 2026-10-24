import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

/// Compares the frozen FIELDS-01 golden against the Liber-side observation of
/// the same corpus, field row by field row.
///
/// The golden is executed evidence from the installed, hash-pinned frozen APK
/// (`tool/result_field_oracle/FieldOracle.java`, driven through
/// `io.legado.app.model.webBook.WebBook`'s four suspend entry points and
/// `io.legado.app.data.entities.BookSource.getCheckKeyword`) and is never
/// rewritten here. A row passes only when both sides observed the same thing;
/// an unequal observation is reported as `fail` with the divergence named, and
/// an observation one side does not carry is named in `notCompared` with its
/// reason — never dropped and never normalized into a pass.
///
/// Usage:
///   `dart run tool/result_field_compare.dart <golden.json> <liber.json> <report.json>`
void main(List<String> args) {
  String? selectedCorpus;
  String? selectedLibrary;
  String? selectedHarnessApk;
  var productSourceRoot = '.';
  final positional = <String>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--fixture') {
      if (++index >= args.length) {
        throw ArgumentError('--fixture needs a value');
      }
      selectedCorpus = args[index];
    } else if (arg.startsWith('--fixture=')) {
      selectedCorpus = arg.substring('--fixture='.length);
    } else if (arg == '--library') {
      if (++index >= args.length) {
        throw ArgumentError('--library needs a value');
      }
      selectedLibrary = args[index];
    } else if (arg == '--harness-apk') {
      if (++index >= args.length) {
        throw ArgumentError('--harness-apk needs a value');
      }
      selectedHarnessApk = args[index];
    } else if (arg == '--product-source-root') {
      if (++index >= args.length) {
        throw ArgumentError('--product-source-root needs a value');
      }
      productSourceRoot = args[index];
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 3) {
    throw ArgumentError(
      'Usage: [--fixture <corpus.json>] [--library <fjs.dll>] '
      '[--harness-apk <apk>] [--product-source-root <repo>] '
      '<golden.json> <liber.json> <report.json>',
    );
  }
  final golden =
      jsonDecode(File(positional[0]).readAsStringSync())
          as Map<String, dynamic>;
  final liber =
      jsonDecode(File(positional[1]).readAsStringSync())
          as Map<String, dynamic>;
  final corpusBytes = File(selectedCorpus ?? corpusPath).readAsBytesSync();
  final corpus = jsonDecode(utf8.decode(corpusBytes)) as Map<String, dynamic>;
  // The manifest beside the golden pins the corpus bytes this run compared; a
  // checkout that rewrote them (a CRLF conversion, a corpus edit) has to fail
  // here rather than compare against a different corpus than the one recorded.
  final manifestFile = File('${File(positional[0]).parent.path}/manifest.json');
  String? manifestCorpusSha256;
  if (manifestFile.existsSync()) {
    final manifest = (jsonDecode(manifestFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    final corpusPin = (manifest['corpus'] as Map?)?.cast<String, Object?>();
    manifestCorpusSha256 = corpusPin?['sha256'] as String?;
  }
  final report = corpus['fixtureId'] == 'FIELDS-02'
      ? compareBookUrlMarkers(
          golden: golden,
          liber: liber,
          goldenPath: positional[0],
          liberPath: positional[1],
          corpus: corpus,
          corpusSha256: _sha256(corpusBytes),
          corpusSha256Lf: _sha256(_lf(corpusBytes)),
          corpusByteCount: corpusBytes.length,
          expectedHarnessApkSha256: _requiredMeasuredPath(
            selectedHarnessApk,
            '--harness-apk',
          ),
          expectedLibrarySha256: _requiredMeasuredPath(
            selectedLibrary,
            '--library',
          ),
          expectedProductSources: _measureProductSources(productSourceRoot),
          manifestCorpusSha256: manifestCorpusSha256,
        )
      : compareResultFields(
          golden: golden,
          liber: liber,
          goldenPath: positional[0],
          liberPath: positional[1],
          corpus: corpus,
          corpusSha256: _sha256(corpusBytes),
          manifestCorpusSha256: manifestCorpusSha256,
        );
  final output = File(positional[2]);
  if (output.existsSync()) {
    throw StateError('Refusing to overwrite a report: ${positional[2]}');
  }
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
  final failures = [
    for (final row in (report['rows'] as List).cast<Map>())
      if (row['status'] == 'fail') row['id'],
  ];
  if (failures.isNotEmpty) {
    stderr.writeln('rows that did not pass: ${failures.join(', ')}');
    exitCode = 1;
  }
}

const corpusPath = 'tool/result_field_oracle/fixtures.json';

/// The row-by-row comparison, pure over its inputs so it can be exercised
/// without a device or a report file.
Map<String, Object?> compareResultFields({
  required Map<String, dynamic> golden,
  required Map<String, dynamic> liber,
  required String goldenPath,
  required String liberPath,
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  String? manifestCorpusSha256,
}) {
  for (final field in [
    'fixtureId',
    'corpusVersion',
    'baselineCommit',
    'entryPoint',
  ]) {
    if (golden[field] != liber[field] || golden[field] != corpus[field]) {
      throw StateError('Corpus identity mismatch on $field');
    }
  }
  if (golden['analysisFailure'] != null) {
    throw StateError(
      'Golden recorded an analysis failure: ${golden['analysisFailure']}',
    );
  }
  if (liber['fixturesSha256'] != corpusSha256) {
    throw StateError(
      'The corpus bytes hash to $corpusSha256, not the fixturesSha256 the Liber '
      'observation recorded (${liber['fixturesSha256']})',
    );
  }
  if (manifestCorpusSha256 != null && manifestCorpusSha256 != corpusSha256) {
    throw StateError(
      'The corpus bytes hash to $corpusSha256, not the sha256 the manifest pins '
      '($manifestCorpusSha256)',
    );
  }

  final rows = <Map<String, Object?>>[];
  final notCompared = <Map<String, Object?>>[];
  final divergences = <Map<String, Object?>>[];

  void row(
    String id,
    String title,
    List<Map<String, Object?>> differences,
    String detail,
  ) {
    if (differences.isNotEmpty) {
      divergences.addAll([
        for (final difference in differences) {'row': id, ...difference},
      ]);
    }
    rows.add({
      'id': id,
      'title': title,
      'status': differences.isEmpty ? 'pass' : 'fail',
      'detail': detail,
      'differences': differences,
    });
  }

  final goldenCases = (golden['cases'] as Map).cast<String, dynamic>();
  final liberCases = (liber['cases'] as Map).cast<String, dynamic>();
  final goldenFailures = ((golden['caseFailures'] as Map?) ?? const {})
      .cast<String, dynamic>();
  final liberFailures = ((liber['caseFailures'] as Map?) ?? const {})
      .cast<String, dynamic>();
  final caseIds = <String>[
    for (final entry in (corpus['cases'] as List).cast<Map>())
      entry['id'] as String,
    for (final id in {...goldenCases.keys, ...liberCases.keys})
      if (!(corpus['cases'] as List).cast<Map>().any((c) => c['id'] == id)) id,
  ];

  /// One case observation both sides carry, or a named `notCompared` when a
  /// side did not reach the case at all.
  Map<String, dynamic>? observed(
    String id,
    String side,
    Map<String, dynamic> cases,
    Map<String, dynamic> failures,
    String observation,
  ) {
    final entry = cases[id];
    if (entry is Map) return entry.cast<String, dynamic>();
    notCompared.add({
      'observation': 'cases.$id.$observation',
      'reason':
          'the $side side did not observe case $id'
          '${failures[id] == null ? '' : ': ${failures[id]}'}; '
          'the row is compared from the cases both sides reached.',
    });
    return null;
  }

  /// One field of one case, as the difference list a row reports.
  void compareCaseField({
    required List<Map<String, Object?>> differences,
    required String id,
    required String observation,
    required Object? frozen,
    required Object? product,
  }) {
    if (!_deepEquals(frozen, product)) {
      differences.add({
        'observation': 'cases.$id.$observation',
        'frozen': frozen,
        'liber': product,
      });
    }
  }

  /// The search results of one case, or null when one side did not reach it.
  (List<dynamic>?, List<dynamic>?) searchResults(String id) {
    final frozen = observed(
      id,
      'frozen',
      goldenCases,
      goldenFailures,
      'search.results',
    );
    final product = observed(
      id,
      'liber',
      liberCases,
      liberFailures,
      'search.results',
    );
    if (frozen == null || product == null) return (null, null);
    return (
      (frozen['search'] as Map?)?['results'] as List?,
      (product['search'] as Map?)?['results'] as List?,
    );
  }

  List<Map<String, Object?>> compareSearchField(String field) {
    final differences = <Map<String, Object?>>[];
    for (final id in caseIds) {
      final (frozen, product) = searchResults(id);
      if (frozen == null || product == null) continue;
      if (frozen.length != product.length) {
        differences.add({
          'observation': 'cases.$id.search.results.length',
          'frozen': frozen.length,
          'liber': product.length,
        });
        continue;
      }
      for (var index = 0; index < frozen.length; index++) {
        compareCaseField(
          differences: differences,
          id: id,
          observation: 'search.results[$index].$field',
          frozen: (frozen[index] as Map)[field],
          product: (product[index] as Map)[field],
        );
      }
    }
    return differences;
  }

  /// One object field of one case (`bookInfo`, `chapter`).
  List<Map<String, Object?>> compareObjectFields(
    String object,
    List<String> fields,
  ) {
    final differences = <Map<String, Object?>>[];
    for (final id in caseIds) {
      final frozen = observed(
        id,
        'frozen',
        goldenCases,
        goldenFailures,
        object,
      );
      final product = observed(id, 'liber', liberCases, liberFailures, object);
      if (frozen == null || product == null) continue;
      for (final field in fields) {
        compareCaseField(
          differences: differences,
          id: id,
          observation: '$object.$field',
          frozen: (frozen[object] as Map?)?[field],
          product: (product[object] as Map?)?[field],
        );
      }
    }
    return differences;
  }

  // C1 — the corpus itself ran identically on both sides: the declared request
  // sequence, in order, with no undeclared request. It is what makes the field
  // rows comparable at all, so a broken corpus fails here instead of quietly
  // producing equal-looking empty observations.
  final corpusDifferences = <Map<String, Object?>>[];
  final goldenTrace = _requests(golden);
  final liberTrace = _requests(liber);
  if (goldenTrace.length != liberTrace.length) {
    corpusDifferences.add({
      'observation': 'requests.length',
      'frozen': goldenTrace.length,
      'liber': liberTrace.length,
    });
  }
  for (
    var index = 0;
    index < goldenTrace.length && index < liberTrace.length;
    index++
  ) {
    for (final field in ['method', 'path', 'rawQuery']) {
      if (goldenTrace[index][field] != liberTrace[index][field]) {
        corpusDifferences.add({
          'observation': 'requests[$index].$field',
          'frozen': goldenTrace[index][field],
          'liber': liberTrace[index][field],
        });
      }
    }
  }
  for (final side in [
    {'name': 'frozen', 'evidence': golden},
    {'name': 'liber', 'evidence': liber},
  ]) {
    final evidence = side['evidence'] as Map<String, dynamic>;
    if (((evidence['unmatchedRequests'] as List?) ?? const []).isNotEmpty) {
      corpusDifferences.add({
        'observation': '${side['name']}.unmatchedRequests',
        'frozen': null,
        'liber': evidence['unmatchedRequests'],
      });
    }
    final mismatch = _sequenceMismatch(corpus, _requests(evidence));
    if (mismatch != null) {
      corpusDifferences.add({
        'observation': '${side['name']}.request sequence',
        'frozen': null,
        'liber': mismatch,
      });
    }
  }
  row(
    'C1',
    'corpus: the declared request sequence ran identically on both sides',
    corpusDifferences,
    '${(corpus['expectedRequests'] as List).length} declared requests, '
        '${goldenTrace.length} on the frozen side and ${liberTrace.length} on the product side',
  );

  // F1 — ruleSearch.intro.
  row(
    'F1',
    'ruleSearch.intro: the extracted intro through the frozen HtmlFormatter',
    compareSearchField('intro'),
    _caseCount('intro', caseIds, goldenCases, liberCases),
  );

  // F2 — ruleSearch.lastChapter.
  row(
    'F2',
    'ruleSearch.lastChapter: the extracted latest chapter title',
    compareSearchField('lastChapter'),
    _caseCount('lastChapter', caseIds, goldenCases, liberCases),
  );

  // F3 — ruleSearch.wordCount, formatted the way the frozen StringUtils does.
  row(
    'F3',
    'ruleSearch.wordCount: the extracted count through the frozen wordCountFormat',
    compareSearchField('wordCount'),
    _caseCount('wordCount', caseIds, goldenCases, liberCases),
  );

  // F4 — ruleSearch.checkKeyWord, through BookSource.getCheckKeyword. A blank
  // or absent rule falls back to the caller's default; a non-string value is
  // refused by the product and either refused or coerced by the frozen parser,
  // so the compared observation is the outcome and, for a value, its bytes.
  final keywordDifferences = <Map<String, Object?>>[];
  final goldenKeyword = (golden['checkKeyword'] as Map).cast<String, dynamic>();
  final liberKeyword = (liber['checkKeyword'] as Map).cast<String, dynamic>();
  final keywordIds = [
    for (final entry in (corpus['checkKeywordCases'] as List).cast<Map>())
      entry['id'] as String,
    for (final id in {...goldenKeyword.keys, ...liberKeyword.keys})
      if (!(corpus['checkKeywordCases'] as List).cast<Map>().any(
        (c) => c['id'] == id,
      ))
        id,
  ];
  final refusedBoth = <String>[];
  for (final id in keywordIds) {
    final frozen = goldenKeyword[id];
    final product = liberKeyword[id];
    if (frozen is! Map || product is! Map) {
      notCompared.add({
        'observation': 'checkKeyword.$id',
        'reason':
            'the ${frozen is! Map ? 'frozen' : 'liber'} side did not observe this '
            'checkKeyWord case; the row is compared from the cases both sides reached.',
      });
      continue;
    }
    if (frozen['outcome'] != product['outcome']) {
      keywordDifferences.add({
        'observation': 'checkKeyword.$id.outcome',
        'frozen': frozen,
        'liber': product,
      });
      continue;
    }
    if (frozen['outcome'] == 'value' && frozen['value'] != product['value']) {
      keywordDifferences.add({
        'observation': 'checkKeyword.$id.value',
        'frozen': frozen['value'],
        'liber': product['value'],
      });
    }
    if (frozen['outcome'] == 'refused') {
      refusedBoth.add(
        '$id (frozen: ${frozen['reason']}; product: ${product['reason']})',
      );
    }
  }
  row(
    'F4',
    'ruleSearch.checkKeyWord: the default keyword path and a non-string value',
    keywordDifferences,
    '${keywordIds.length} checkKeyWord cases compared'
        '${refusedBoth.isEmpty ? '' : '; refused on both sides: ${refusedBoth.join('; ')}'}',
  );

  // F5 — ruleBookInfo.wordCount.
  row(
    'F5',
    'ruleBookInfo.wordCount: the detail count through the frozen wordCountFormat',
    compareObjectFields('bookInfo', ['wordCount']),
    _caseCount('bookInfo.wordCount', caseIds, goldenCases, liberCases),
  );

  // F6 — ruleBookInfo.canReName. The observable is what the gate decides: the
  // detail page's title and author replace the search result's only when the
  // rule is declared non-blank, and an empty search value is still filled.
  row(
    'F6',
    'ruleBookInfo.canReName: the detail title/author replacement gate',
    compareObjectFields('bookInfo', ['name', 'author']),
    _caseCount('bookInfo.name/author', caseIds, goldenCases, liberCases),
  );

  // F7 — ruleContent.title, as the effective chapter title the reader ends up
  // with: the content title replaced it, or the table of contents' own name
  // stayed.
  row(
    'F7',
    'ruleContent.title: the content title replacing the chapter title',
    compareObjectFields('chapter', ['title']),
    _caseCount('chapter.title', caseIds, goldenCases, liberCases),
  );

  // Observations one side does not carry. Naming them is the point: none of
  // them is silently dropped, and none of them is allowed to turn a row green.
  notCompared.addAll([
    {
      'observation': 'cases.<id>.search.results[].name, .author',
      'reason':
          'context for the canReName row, not one of this corpus\' field rows: '
          'the search result name and author are SLICE-01 row R5\'s, and F6 '
          'compares the same names where the rename gate decides them.',
    },
    {
      'observation': 'cases.<id>.chapter.text',
      'reason':
          'recorded so a case that produced no content is visible; the content '
          'text is not one of the seven field rows (SLICE-01 R8 owns it).',
    },
    {
      'observation': 'requests[].headers.*, requests[].body',
      'reason':
          'this corpus compares the request method, resolved path and raw query '
          'bytes only: source headers and injected request defaults are SLICE-01 '
          'row R3\'s, and every request here is a GET with an empty body.',
    },
    {
      'observation': 'state.*, cleanup.*, serverErrors',
      'reason':
          'frozen-side observations with no counterpart in the Liber evidence: '
          'cleanup is this harness\' own replay-server teardown '
          '(openConnections, serverClosed), not a source-observable cleanup '
          'effect, and serverErrors is the replay server\'s own error list.',
    },
    {
      'observation':
          'liber.scenario, liber.oracle, liber.fixturesPath/fixturesSha256, '
          'liber.libraryPath/librarySha256',
      'reason':
          'Liber-side fields the comparator does not read: `scenario` is the '
          'product run\'s own shape check (C1 recomputes it from `requests` and '
          'the corpus `expectedRequests`), `oracle` records that the observation '
          'was recorded before a golden existed, and the `fixtures*`/`library*` '
          'fields identify the input bytes. The corpus bytes are hashed and '
          'checked against the manifest pin instead.',
    },
    {
      'observation': 'platform, fingerprint, recordedAt',
      'reason':
          'provenance of the two runs, recorded in each evidence file and its '
          'manifest; not a compatibility observation.',
    },
  ]);

  final failures = rows.where((entry) => entry['status'] == 'fail').toList();
  return <String, Object?>{
    'comparison': 'FIELDS-01',
    'golden': goldenPath,
    'liber': liberPath,
    'goldenPlatform': golden['platform'],
    'goldenFingerprint': golden['fingerprint'],
    'corpus': corpusPath,
    'corpusSha256': corpusSha256,
    'manifestCorpusSha256': manifestCorpusSha256,
    'rows': rows,
    'notCompared': notCompared,
    'divergences': divergences,
    'status': failures.isEmpty ? 'pass' : 'fail',
    'summary': {
      'pass': rows.where((entry) => entry['status'] == 'pass').length,
      'fail': failures.length,
      'notCompared': notCompared.length,
    },
  };
}

String _caseCount(
  String observation,
  List<String> caseIds,
  Map<String, dynamic> goldenCases,
  Map<String, dynamic> liberCases,
) {
  final shared = [
    for (final id in caseIds)
      if (goldenCases.containsKey(id) && liberCases.containsKey(id)) id,
  ];
  return '${shared.length} of ${caseIds.length} cases compared on $observation';
}

List<Map<String, Object?>> _requests(Map<String, dynamic> evidence) => [
  for (final request in (evidence['requests'] as List).cast<Map>())
    request.cast<String, Object?>(),
];

/// Deep equality where array order matters and JSON object key order does not
/// (contract, Matching Rules -> Outputs).
const bookUrlMarkersFixtureId = 'FIELDS-02';
const bookUrlMarkersCorpusVersion = 1;

/// Strict FIELDS-02 admission and comparison. The native report uses `cases`;
/// the product report uses `caseRecords`. The two sides are admitted
/// independently before any equality row is produced. Missing facts are
/// refusals; a real observed difference is a `fail` row named for its field.
Map<String, Object?> compareBookUrlMarkers({
  required Map<String, dynamic> golden,
  required Map<String, dynamic> liber,
  required String goldenPath,
  required String liberPath,
  required Map<String, dynamic> corpus,
  required String corpusSha256,
  required String corpusSha256Lf,
  required int corpusByteCount,
  required String expectedHarnessApkSha256,
  required String expectedLibrarySha256,
  required Map<String, String> expectedProductSources,
  String? manifestCorpusSha256,
}) {
  final corpusCases = _admitCorpus(
    corpus,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    corpusByteCount: corpusByteCount,
  );
  final declaredIds = [for (final entry in corpusCases) entry['id'] as String];
  final expectedRequests = _admitExpectedRequests(corpus);
  final expectedResponses = _admitExpectedResponses(corpus);
  if (expectedRequests.length != expectedResponses.length) {
    throw StateError('corpus expectedRequests/responses are not aligned');
  }
  if (manifestCorpusSha256 != null && manifestCorpusSha256 != corpusSha256) {
    throw StateError('golden manifest corpus pin does not match the corpus');
  }
  final target = _map(corpus['target'], 'corpus.target');
  _admitGoldenIdentity(
    golden,
    corpus,
    target: target,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    corpusByteCount: corpusByteCount,
    expectedHarnessApkSha256: expectedHarnessApkSha256,
  );
  _admitProductIdentity(
    liber,
    corpus,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    corpusByteCount: corpusByteCount,
    expectedLibrarySha256: expectedLibrarySha256,
    expectedProductSources: expectedProductSources,
  );

  final goldenCases = _records(golden['cases'], 'golden.cases');
  final productCases = _records(liber['caseRecords'], 'liber.caseRecords');
  if (goldenCases.isEmpty || productCases.isEmpty) {
    throw StateError('both sides must carry a nonempty selected case array');
  }
  _admitExactIds(goldenCases, declaredIds, 'golden');
  _admitExactIds(productCases, declaredIds, 'liber');
  final goldenById = {for (final record in goldenCases) record['id']: record};
  final productById = {for (final record in productCases) record['id']: record};
  final corpusById = {for (final entry in corpusCases) entry['id']: entry};
  for (final id in declaredIds) {
    _admitCaseRecord(
      goldenById[id]!,
      corpusById[id]!,
      'golden.$id',
      native: true,
    );
    _admitCaseRecord(
      productById[id]!,
      corpusById[id]!,
      'liber.$id',
      native: false,
    );
  }

  final caseDifferences = <Map<String, Object?>>[];
  for (final id in declaredIds) {
    final frozen = goldenById[id]!;
    final product = productById[id]!;
    _compareCases(caseDifferences, id, frozen, product);
  }

  final requestDifferences = <Map<String, Object?>>[];
  final goldenRequests = _markerRequests(golden['requests'], 'golden.requests');
  final productRequests = _markerRequests(liber['requests'], 'liber.requests');
  _compareRequestsToDeclaration(
    requestDifferences,
    'golden',
    goldenRequests,
    expectedRequests,
    expectedResponses,
  );
  _compareRequestsToDeclaration(
    requestDifferences,
    'liber',
    productRequests,
    expectedRequests,
    expectedResponses,
  );

  final stageDifferences = <Map<String, Object?>>[];
  final goldenTrace = _admitStageTrace(
    trace: golden['stageTrace'],
    label: 'golden.stageTrace',
  );
  final productTrace = _admitStageTrace(
    trace: liber['stageTrace'],
    label: 'liber.stageTrace',
  );
  _diff(
    stageDifferences,
    'stageTrace',
    'stageTrace',
    goldenTrace,
    productTrace,
  );

  final cleanupDifferences = <Map<String, Object?>>[];
  final goldenCleanup = _map(golden['cleanup'], 'golden.cleanup');
  final productCleanup = _map(liber['cleanup'], 'liber.cleanup');
  _diff(
    cleanupDifferences,
    'cleanup',
    'serverClosed',
    goldenCleanup['serverClosed'],
    productCleanup['serverClosed'],
  );

  final rows = <Map<String, Object?>>[
    _row(
      'C1',
      'case records, markers and fixed raw/resolved quantities',
      caseDifferences,
    ),
    _row(
      'C2',
      'declared request sequence and actual response receipts',
      requestDifferences,
    ),
    _row('C3', 'actual stage trace', stageDifferences),
    _row('C4', 'isolation and cleanup', cleanupDifferences),
  ];
  final differences = [
    for (final row in rows) ...(row['differences'] as List).cast<Map>(),
  ];
  return {
    'fixtureId': bookUrlMarkersFixtureId,
    'corpusVersion': bookUrlMarkersCorpusVersion,
    'status': differences.isEmpty ? 'pass' : 'fail',
    'rows': rows,
    'differences': differences,
    'notCompared': <Object?>[],
    'goldenPath': goldenPath,
    'liberPath': liberPath,
    'corpusSha256': corpusSha256,
    'corpusSha256Lf': corpusSha256Lf,
    'corpusByteCount': corpusByteCount,
    'librarySha256': expectedLibrarySha256,
    'harnessApkSha256': expectedHarnessApkSha256,
  };
}

List<Map<String, dynamic>> _admitCorpus(
  Map<String, dynamic> corpus, {
  required String corpusSha256,
  required String corpusSha256Lf,
  required int corpusByteCount,
}) {
  if (corpus['fixtureId'] != bookUrlMarkersFixtureId) {
    throw StateError('Not the FIELDS-02 corpus');
  }
  if (corpus['corpusVersion'] is! int ||
      corpus['corpusVersion'] != bookUrlMarkersCorpusVersion) {
    throw StateError('FIELDS-02 corpusVersion must be integer 1');
  }
  _requiredString(corpus, 'baselineCommit', 'corpus');
  _requiredString(corpus, 'entryPoint', 'corpus');
  _requiredString(corpus, 'origin', 'corpus');
  final target = _map(corpus['target'], 'corpus.target');
  _requiredString(target, 'package', 'corpus.target');
  _requiredString(target, 'apkSha256', 'corpus.target');
  _requiredString(target, 'deviceFingerprint', 'corpus.target');
  final cases = _requiredList(corpus, 'cases', 'corpus');
  if (cases.isEmpty) {
    throw StateError('corpus.cases must not be empty');
  }
  final records = <Map<String, dynamic>>[];
  final ids = <String>{};
  for (final value in cases) {
    final entry = _map(value, 'corpus.cases[]');
    final id = _requiredString(entry, 'id', 'corpus.cases[]');
    if (id.isEmpty || !ids.add(id)) {
      throw StateError('corpus case ids must be nonempty and unique');
    }
    final terminal = entry.containsKey('terminal')
        ? _requiredString(entry, 'terminal', 'corpus.cases[$id]')
        : 'four-stage';
    if (terminal != 'four-stage' && terminal != 'search-empty') {
      throw StateError('unsupported corpus terminal: $terminal');
    }
    _requiredString(entry, 'keyword', 'corpus.cases[$id]');
    _map(entry['source'], 'corpus.cases[$id].source');
    records.add(entry);
  }
  return records;
}

List<Map<String, dynamic>> _admitExpectedRequests(Map<String, dynamic> corpus) {
  final values = _requiredList(corpus, 'expectedRequests', 'corpus');
  if (values.isEmpty) {
    throw StateError('corpus.expectedRequests must not be empty');
  }
  final requests = <Map<String, dynamic>>[];
  for (var index = 0; index < values.length; index++) {
    final request = _map(values[index], 'corpus.expectedRequests[$index]');
    _requiredString(request, 'method', 'expectedRequests[$index]');
    _requiredString(request, 'path', 'expectedRequests[$index]');
    final query = request['query'];
    if (query != null) _stringMap(query, 'expectedRequests[$index].query');
    requests.add(request);
  }
  return requests;
}

List<Map<String, dynamic>> _admitExpectedResponses(
  Map<String, dynamic> corpus,
) {
  final values = _requiredList(corpus, 'responses', 'corpus');
  if (values.isEmpty) throw StateError('corpus.responses must not be empty');
  final responses = <Map<String, dynamic>>[];
  final ids = <String>{};
  for (var index = 0; index < values.length; index++) {
    final response = _map(values[index], 'corpus.responses[$index]');
    final id = _requiredString(response, 'id', 'corpus.responses[$index]');
    if (id.isEmpty || !ids.add(id)) {
      throw StateError('response ids must be nonempty and unique');
    }
    _requiredString(response, 'method', 'corpus.responses[$index]');
    _requiredString(response, 'path', 'corpus.responses[$index]');
    if (_present(response, 'status', 'corpus.responses[$index]') is! int) {
      throw StateError('response status must be integer');
    }
    final headers = response['headers'];
    if (headers != null) {
      final headersMap = _map(headers, 'response.headers');
      for (final entry in headersMap.entries) {
        if (entry.value is! String) {
          throw StateError('response header values must be strings');
        }
      }
    }
    responses.add(response);
  }
  return responses;
}

void _admitGoldenIdentity(
  Map<String, dynamic> golden,
  Map<String, dynamic> corpus, {
  required Map<String, dynamic> target,
  required String corpusSha256,
  required String corpusSha256Lf,
  required int corpusByteCount,
  required String expectedHarnessApkSha256,
}) {
  _admitIdentityFields(golden, corpus, 'golden');
  final fingerprint = _requiredString(golden, 'fingerprint', 'golden');
  if (fingerprint != target['deviceFingerprint']) {
    throw StateError('golden fingerprint does not match the approved target');
  }
  final corpusBlock = _map(golden['corpus'], 'golden.corpus');
  if (corpusBlock['asset'] != 'field-fixtures.json' ||
      corpusBlock['fixtureId'] != bookUrlMarkersFixtureId ||
      corpusBlock['corpusVersion'] != bookUrlMarkersCorpusVersion) {
    throw StateError('golden corpus identity is malformed');
  }
  if (_present(corpusBlock, 'bytes', 'golden.corpus') != corpusByteCount) {
    throw StateError('golden measured corpus byte count differs');
  }
  if (_present(corpusBlock, 'sha256', 'golden.corpus') != corpusSha256 ||
      _present(corpusBlock, 'sha256Lf', 'golden.corpus') != corpusSha256Lf) {
    throw StateError('golden measured corpus digest differs');
  }
  final isolation = _map(golden['isolation'], 'golden.isolation');
  for (final field in ['bound', 'filesRouted', 'databaseRouted']) {
    if (_present(isolation, field, 'golden.isolation') != true) {
      throw StateError('golden isolation.$field must be true');
    }
  }
  if (isolation['deviceProtected'] != false ||
      isolation['rootExistedAtStart'] != false) {
    throw StateError('golden used a preexisting or device-protected scratch');
  }
  if (isolation['targetPackage'] != target['package'] ||
      isolation['targetApkSha256'] != target['apkSha256'] ||
      isolation['harnessApkSha256'] != expectedHarnessApkSha256 ||
      isolation['corpusSha256Lf'] != corpusSha256Lf) {
    throw StateError(
      'golden isolation identity does not bind to the selected input',
    );
  }
  _requiredString(isolation, 'harnessPackage', 'golden.isolation');
  _requiredString(isolation, 'preferencesPrefix', 'golden.isolation');
  _requiredString(isolation, 'scratchRoot', 'golden.isolation');
  final cleanup = _map(golden['cleanup'], 'golden.cleanup');
  for (final field in [
    'serverClosed',
    'ownerComplete',
    'rootRetained',
    'preferencesFenced',
  ]) {
    if (_present(cleanup, field, 'golden.cleanup') != true) {
      throw StateError('golden cleanup.$field must be true');
    }
  }
  _requiredString(cleanup, 'ownerRunId', 'golden.cleanup');
  _requiredString(cleanup, 'scratchRoot', 'golden.cleanup');
  _requiredString(cleanup, 'reportPath', 'golden.cleanup');
  final owned = _requiredList(cleanup, 'ownedPreferences', 'golden.cleanup');
  if (owned.isEmpty ||
      owned.any((value) => value is! String || value.isEmpty)) {
    throw StateError(
      'golden cleanup.ownedPreferences must be a nonempty string list',
    );
  }
  _admitErrorFacts(golden, 'golden');
}

void _admitProductIdentity(
  Map<String, dynamic> liber,
  Map<String, dynamic> corpus, {
  required String corpusSha256,
  required String corpusSha256Lf,
  required int corpusByteCount,
  required String expectedLibrarySha256,
  required Map<String, String> expectedProductSources,
}) {
  _admitIdentityFields(liber, corpus, 'liber');
  if (_present(liber, 'fixturesBytes', 'liber') != corpusByteCount ||
      _present(liber, 'fixturesSha256', 'liber') != corpusSha256 ||
      _present(liber, 'fixturesSha256Lf', 'liber') != corpusSha256Lf) {
    throw StateError('product fixture measurement does not match the corpus');
  }
  _requiredString(liber, 'fixturesPath', 'liber');
  _requiredString(liber, 'libraryPath', 'liber');
  if (_present(liber, 'librarySha256', 'liber') != expectedLibrarySha256) {
    throw StateError(
      'product library digest does not match the selected library',
    );
  }
  _requiredString(liber, 'platform', 'liber');
  _requiredString(liber, 'oracle', 'liber');
  final sources = _stringMap(liber['productSources'], 'liber.productSources');
  if (expectedProductSources.isEmpty ||
      sources.length != expectedProductSources.length) {
    throw StateError('product source hash set differs from the measured set');
  }
  for (final entry in expectedProductSources.entries) {
    if (sources[entry.key] != entry.value) {
      throw StateError('product source hash differs: ${entry.key}');
    }
  }
  final cleanup = _map(liber['cleanup'], 'liber.cleanup');
  if (_present(cleanup, 'serverClosed', 'liber.cleanup') != true) {
    throw StateError('product replay server did not close');
  }
  _admitErrorFacts(liber, 'liber');
}

void _admitIdentityFields(
  Map<String, dynamic> record,
  Map<String, dynamic> corpus,
  String label,
) {
  for (final field in [
    'fixtureId',
    'corpusVersion',
    'baselineCommit',
    'entryPoint',
  ]) {
    if (_present(record, field, label) != corpus[field]) {
      throw StateError('$label $field does not match the selected corpus');
    }
  }
}

void _admitErrorFacts(Map<String, dynamic> record, String label) {
  if (!record.containsKey('analysisFailure') ||
      record['analysisFailure'] != null) {
    throw StateError('$label.analysisFailure must be present and null');
  }
  final failures = _map(record['caseFailures'], '$label.caseFailures');
  if (failures.isNotEmpty) {
    throw StateError('$label recorded failed cases');
  }
  final unmatched = _requiredList(record, 'unmatchedRequests', label);
  final serverErrors = _requiredList(record, 'serverErrors', label);
  if (unmatched.isNotEmpty || serverErrors.isNotEmpty) {
    throw StateError('$label recorded undeclared requests or server errors');
  }
}

void _admitCaseRecord(
  Map<String, dynamic> record,
  Map<String, dynamic> corpusEntry,
  String label, {
  required bool native,
}) {
  final id = _requiredString(record, 'id', label);
  if (id != corpusEntry['id']) throw StateError('$label id differs');
  final terminal = _requiredString(record, 'terminal', label);
  final declaredTerminal = _requiredString(
    corpusEntry,
    'terminal',
    'corpus.cases[$id]',
  );
  if (terminal != declaredTerminal) {
    throw StateError('$label terminal differs from the declaration');
  }
  final search = _map(record['search'], '$label.search');
  final results = _requiredList(search, 'results', '$label.search');
  for (var index = 0; index < results.length; index++) {
    _admitSearchResult(
      results[index],
      '$label.search.results[$index]',
      native: native,
    );
  }
  if (terminal == 'search-empty') {
    if (results.isNotEmpty) {
      throw StateError('$label empty terminal has results');
    }
    for (final field in ['bookInfo', 'tableOfContents', 'chapter']) {
      if (!record.containsKey(field) || record[field] != null) {
        throw StateError(
          '$label empty terminal must carry explicit null $field',
        );
      }
    }
  } else {
    if (results.isEmpty) {
      throw StateError('$label positive case has no search result');
    }
    final bookInfo = _requiredMap(record, 'bookInfo', label);
    for (final field in ['name', 'author', 'bookUrl', 'tocUrl']) {
      _requiredString(bookInfo, field, '$label.bookInfo');
    }
    final toc = _requiredMap(record, 'tableOfContents', label);
    _requiredString(toc, 'tocUrl', '$label.tableOfContents');
    final chapters = _requiredList(toc, 'chapters', '$label.tableOfContents');
    if (chapters.isEmpty) {
      throw StateError('$label positive case has no chapter observations');
    }
    for (var index = 0; index < chapters.length; index++) {
      _admitChapter(
        _map(chapters[index], '$label.chapters[$index]'),
        '$label.chapters[$index]',
        native: native,
      );
    }
    final chapter = _requiredMap(record, 'chapter', label);
    final title = _requiredString(chapter, 'title', '$label.chapter');
    if (title.isEmpty) {
      throw StateError('$label chapter title must not be empty');
    }
    _requiredString(chapter, 'text', '$label.chapter');
  }
  final probes = _requiredMap(record, 'sourceProbes', label);
  for (final field in ['vipProbe', 'payProbe']) {
    _nullableStringPresent(probes, field, '$label.sourceProbes');
  }
  final caseRequests = _requiredList(record, 'requests', label);
  if (caseRequests.isEmpty) {
    throw StateError('$label case has no request slice');
  }
  for (var index = 0; index < caseRequests.length; index++) {
    _admitRequest(
      _map(caseRequests[index], '$label.requests[$index]'),
      '$label.requests[$index]',
    );
  }
}

void _admitSearchResult(Object? value, String label, {required bool native}) {
  final result = _map(value, label);
  for (final field in ['name', 'author', 'bookUrl']) {
    _requiredString(result, field, label);
  }
  if (native && result.containsKey('infoHtml') && result['infoHtml'] is! bool) {
    throw StateError('$label.infoHtml must be boolean when present');
  }
  for (final field in ['identityAddress', 'rawAddress']) {
    if (result.containsKey(field) &&
        result[field] != null &&
        result[field] is! String) {
      throw StateError('$label.$field must be string or null');
    }
  }
}

void _admitChapter(
  Map<String, dynamic> chapter,
  String label, {
  required bool native,
}) {
  _requiredString(chapter, 'title', label);
  if (_requiredString(chapter, 'title', label).isEmpty) {
    throw StateError('$label.title must not be empty');
  }
  final values = native ? ['url', 'absoluteUrl'] : ['url', 'address'];
  for (final field in values) {
    _requiredString(chapter, field, label);
  }
  _nullableStringPresent(chapter, 'tag', label);
  for (final field in ['isVolume', 'isVip', 'isPay']) {
    if (_present(chapter, field, label) is! bool) {
      throw StateError('$label.$field must be boolean');
    }
  }
  if (native) {
    if (chapter.containsKey('bookUrl') && chapter['bookUrl'] is! String) {
      throw StateError('$label.bookUrl must be a string when present');
    }
  } else {
    _nullableStringPresent(chapter, 'rawAddress', label);
    _requiredString(chapter, 'storeKey', label);
    _requiredString(chapter, 'persistedAddress', label);
  }
}

void _admitRequest(Map<String, dynamic> request, String label) {
  _requiredString(request, 'method', label);
  _requiredString(request, 'path', label);
  _requiredString(request, 'rawQuery', label);
  _stringMap(request['query'], '$label.query');
  final receipt = _requiredMap(request, 'receipt', label);
  _requiredString(receipt, 'terminal', '$label.receipt');
  if (_present(receipt, 'status', '$label.receipt') is! int) {
    throw StateError('$label.receipt.status must be integer');
  }
  if (_present(receipt, 'send', '$label.receipt') != 'completed') {
    throw StateError('$label.receipt.send must record actual completion');
  }
  _nullableStringPresent(receipt, 'responseId', '$label.receipt');
  _nullableStringPresent(receipt, 'redirect', '$label.receipt');
  if (receipt.containsKey('error') && receipt['error'] is! String) {
    throw StateError('$label.receipt.error must be a string when present');
  }
}

void _compareCases(
  List<Map<String, Object?>> differences,
  String id,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product,
) {
  _diff(differences, id, 'terminal', frozen['terminal'], product['terminal']);
  final frozenSearch = _map(frozen['search'], '$id.search');
  final productSearch = _map(product['search'], '$id.search');
  final frozenResults = _requiredList(
    frozenSearch,
    'results',
    '$id.search.results',
  );
  final productResults = _requiredList(
    productSearch,
    'results',
    '$id.search.results',
  );
  _diff(
    differences,
    id,
    'search.results.length',
    frozenResults.length,
    productResults.length,
  );
  final resultCount = frozenResults.length < productResults.length
      ? frozenResults.length
      : productResults.length;
  for (var index = 0; index < resultCount; index++) {
    final f = _map(frozenResults[index], '$id.search.results[$index]');
    final p = _map(productResults[index], '$id.search.results[$index]');
    for (final field in ['name', 'author', 'bookUrl']) {
      _diff(
        differences,
        id,
        'search.results[$index].$field',
        f[field],
        p[field],
      );
    }
  }

  if (frozen['bookInfo'] == null || product['bookInfo'] == null) {
    _diff(differences, id, 'bookInfo', frozen['bookInfo'], product['bookInfo']);
  } else {
    final f = _map(frozen['bookInfo'], '$id.bookInfo');
    final p = _map(product['bookInfo'], '$id.bookInfo');
    for (final field in ['name', 'author', 'bookUrl', 'tocUrl']) {
      _diff(differences, id, 'bookInfo.$field', f[field], p[field]);
    }
  }
  if (frozen['tableOfContents'] == null || product['tableOfContents'] == null) {
    _diff(
      differences,
      id,
      'tableOfContents',
      frozen['tableOfContents'],
      product['tableOfContents'],
    );
  } else {
    final f = _map(frozen['tableOfContents'], '$id.tableOfContents');
    final p = _map(product['tableOfContents'], '$id.tableOfContents');
    _diff(differences, id, 'tableOfContents.tocUrl', f['tocUrl'], p['tocUrl']);
    final fChapters = _requiredList(f, 'chapters', '$id.tableOfContents');
    final pChapters = _requiredList(p, 'chapters', '$id.tableOfContents');
    _diff(
      differences,
      id,
      'tableOfContents.chapters.length',
      fChapters.length,
      pChapters.length,
    );
    final count = fChapters.length < pChapters.length
        ? fChapters.length
        : pChapters.length;
    for (var index = 0; index < count; index++) {
      final fc = _map(fChapters[index], '$id.chapters[$index]');
      final pc = _map(pChapters[index], '$id.chapters[$index]');
      for (final field in ['title', 'tag', 'isVolume', 'isVip', 'isPay']) {
        _diff(differences, id, 'chapters[$index].$field', fc[field], pc[field]);
      }
      _diff(
        differences,
        id,
        'chapters[$index].url(raw vs address)',
        fc['url'],
        pc['address'],
      );
      _diff(
        differences,
        id,
        'chapters[$index].absoluteUrl(vs url)',
        fc['absoluteUrl'],
        pc['url'],
      );
    }
  }
  if (frozen['chapter'] == null || product['chapter'] == null) {
    _diff(differences, id, 'chapter', frozen['chapter'], product['chapter']);
  } else {
    final f = _map(frozen['chapter'], '$id.chapter');
    final p = _map(product['chapter'], '$id.chapter');
    for (final field in ['title', 'text']) {
      _diff(differences, id, 'chapter.$field', f[field], p[field]);
    }
  }
  final fProbes = _map(frozen['sourceProbes'], '$id.sourceProbes');
  final pProbes = _map(product['sourceProbes'], '$id.sourceProbes');
  for (final field in ['vipProbe', 'payProbe']) {
    _diff(
      differences,
      id,
      'sourceProbes.$field',
      fProbes[field],
      pProbes[field],
    );
  }
}

void _compareRequestsToDeclaration(
  List<Map<String, Object?>> differences,
  String side,
  List<Map<String, dynamic>> requests,
  List<Map<String, dynamic>> expected,
  List<Map<String, dynamic>> responses,
) {
  if (requests.length != expected.length) {
    differences.add({
      'row': 'C2',
      'field': '$side.requests.length',
      'frozen': expected.length,
      'liber': requests.length,
    });
  }
  final count = requests.length < expected.length
      ? requests.length
      : expected.length;
  for (var index = 0; index < count; index++) {
    final actual = requests[index];
    final wanted = expected[index];
    for (final field in ['method', 'path']) {
      if (actual[field] != wanted[field]) {
        differences.add({
          'row': 'C2',
          'field': '$side.requests[$index].$field',
          'frozen': wanted[field],
          'liber': actual[field],
        });
      }
    }
    final wantedQuery = wanted['query'] == null
        ? <String, String>{}
        : _stringMap(wanted['query'], 'expectedRequests[$index].query');
    final actualQuery = _stringMap(
      actual['query'],
      '$side.requests[$index].query',
    );
    if (!_deepEquals(wantedQuery, actualQuery)) {
      differences.add({
        'row': 'C2',
        'field': '$side.requests[$index].query',
        'frozen': wantedQuery,
        'liber': actualQuery,
      });
    }
    final response = responses[index];
    final receipt = _requiredMap(actual, 'receipt', '$side.requests[$index]');
    final expectedId = response['id'];
    final expectedStatus = response['status'];
    final headers = response['headers'] is Map
        ? _map(response['headers'], 'response.headers')
        : <String, dynamic>{};
    final expectedRedirect = headers['Location'];
    for (final entry in <String, Object?>{
      'terminal': 'responded',
      'status': expectedStatus,
      'responseId': expectedId,
      'redirect': expectedRedirect,
    }.entries) {
      if (receipt[entry.key] != entry.value) {
        differences.add({
          'row': 'C2',
          'field': '$side.requests[$index].receipt.${entry.key}',
          'frozen': entry.value,
          'liber': receipt[entry.key],
        });
      }
    }
  }
  for (var index = count; index < requests.length; index++) {
    differences.add({
      'row': 'C2',
      'field': '$side.requests[$index]',
      'frozen': null,
      'liber':
          'unexpected: ${requests[index]['method']} ${requests[index]['path']}',
    });
  }
  for (var index = count; index < expected.length; index++) {
    differences.add({
      'row': 'C2',
      'field': '$side.requests[$index]',
      'frozen': '${expected[index]['method']} ${expected[index]['path']}',
      'liber': null,
    });
  }
}

List<Map<String, dynamic>> _admitStageTrace({
  required Object? trace,
  required String label,
}) {
  final values = _requiredListValue(trace, label);
  if (values.isEmpty) throw StateError('$label must not be empty');
  final out = <Map<String, dynamic>>[];
  for (var index = 0; index < values.length; index++) {
    final entry = _map(values[index], '$label[$index]');
    _requiredString(entry, 'stage', '$label[$index]');
    _requiredString(entry, 'path', '$label[$index]');
    out.add(entry);
  }
  return out;
}

Map<String, Object?> _row(
  String id,
  String title,
  List<Map<String, Object?>> differences,
) => {
  'id': id,
  'title': title,
  'status': differences.isEmpty ? 'pass' : 'fail',
  'detail': differences.isEmpty
      ? 'matched'
      : '${differences.length} difference(s)',
  'differences': differences,
};

void _admitExactIds(
  List<Map<String, dynamic>> records,
  List<String> declared,
  String side,
) {
  if (declared.isEmpty) throw StateError('$side declared case set is empty');
  final ids = [
    for (final record in records) _requiredString(record, 'id', side),
  ];
  if (ids.length != declared.length ||
      ids.toSet().length != ids.length ||
      !ids.toSet().containsAll(declared)) {
    throw StateError('$side case ids are not exactly the declared unique set');
  }
}

Map<String, dynamic> _map(Object? value, String label) {
  if (value is! Map) throw StateError('$label must be an object');
  return value.cast<String, dynamic>();
}

Map<String, dynamic> _requiredMap(
  Map<String, dynamic> map,
  String key,
  String label,
) => _map(_present(map, key, label), '$label.$key');

List<Object?> _requiredList(
  Map<String, dynamic> map,
  String key,
  String label,
) => _requiredListValue(_present(map, key, label), '$label.$key');

List<Object?> _requiredListValue(Object? value, String label) {
  if (value is! List) throw StateError('$label must be an array');
  return value;
}

Object? _present(Map<String, dynamic> map, String key, String label) {
  if (!map.containsKey(key)) throw StateError('$label.$key is missing');
  return map[key];
}

String _requiredString(Map<String, dynamic> map, String key, String label) {
  final value = _present(map, key, label);
  if (value is! String) throw StateError('$label.$key must be a string');
  return value;
}

String? _nullableStringPresent(
  Map<String, dynamic> map,
  String key,
  String label,
) {
  final value = _present(map, key, label);
  if (value != null && value is! String) {
    throw StateError('$label.$key must be string or null');
  }
  return value as String?;
}

Map<String, String> _stringMap(Object? value, String label) {
  if (value is! Map) throw StateError('$label must be an object');
  final out = <String, String>{};
  for (final entry in value.entries) {
    if (entry.key is! String || entry.value is! String) {
      throw StateError('$label must contain string keys and values');
    }
    out[entry.key as String] = entry.value as String;
  }
  return out;
}

List<Map<String, dynamic>> _records(Object? value, String label) {
  final values = _requiredListValue(value, label);
  return [
    for (var index = 0; index < values.length; index++)
      _map(values[index], '$label[$index]'),
  ];
}

List<Map<String, dynamic>> _markerRequests(Object? value, String label) {
  final records = _records(value, label);
  for (var index = 0; index < records.length; index++) {
    _admitRequest(records[index], '$label[$index]');
  }
  return records;
}

void _diff(
  List<Map<String, Object?>> differences,
  String row,
  String field,
  Object? frozen,
  Object? product,
) {
  if (!_deepEquals(frozen, product)) {
    differences.add({
      'row': row,
      'field': field,
      'frozen': frozen,
      'liber': product,
    });
  }
}

bool _deepEquals(Object? frozen, Object? product) {
  if (frozen is Map && product is Map) {
    if (frozen.length != product.length) return false;
    for (final key in frozen.keys) {
      if (!product.containsKey(key) ||
          !_deepEquals(frozen[key], product[key])) {
        return false;
      }
    }
    return true;
  }
  if (frozen is List && product is List) {
    if (frozen.length != product.length) return false;
    for (var index = 0; index < frozen.length; index++) {
      if (!_deepEquals(frozen[index], product[index])) return false;
    }
    return true;
  }
  return frozen == product;
}

String? _sequenceMismatch(
  Map<String, dynamic> corpus,
  List<Map<String, Object?>> requests,
) {
  final expected = (corpus['expectedRequests'] as List).cast<Map>();
  if (requests.length != expected.length) {
    return '${requests.length} requests, ${expected.length} declared';
  }
  for (var index = 0; index < expected.length; index++) {
    final want = expected[index];
    final got = requests[index];
    final wantQuery =
        (want['query'] as Map?)?.cast<String, Object?>() ?? const {};
    final gotQuery = (got['query'] as Map).cast<String, Object?>();
    if (want['method'] != got['method'] ||
        want['path'] != got['path'] ||
        wantQuery.length != gotQuery.length ||
        !wantQuery.entries.every(
          (entry) => gotQuery[entry.key] == entry.value,
        )) {
      return 'request $index is ${got['method']} ${got['path']} ${jsonEncode(gotQuery)}';
    }
  }
  return null;
}

String _requiredMeasuredPath(String? path, String option) {
  if (path == null) throw ArgumentError('$option is required for FIELDS-02');
  final file = File(path);
  if (!file.existsSync()) throw ArgumentError('$option does not exist: $path');
  return _sha256(file.readAsBytesSync());
}

List<int> _lf(List<int> bytes) {
  final out = <int>[];
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] == 13 &&
        index + 1 < bytes.length &&
        bytes[index + 1] == 10) {
      continue;
    }
    out.add(bytes[index]);
  }
  return out;
}

const _productSourcePaths = <String>[
  'lib/source/book_source_pipeline.dart',
  'lib/source/html_source_pipeline.dart',
  'lib/source/json_source_pipeline.dart',
  'lib/source/html_rule_adapter.dart',
  'lib/source/json_source_rules.dart',
  'lib/source/http_source_transport.dart',
  'lib/source/source_host_state.dart',
  'lib/source/js_source_runtime.dart',
  'lib/source/source_url_rules.dart',
];

Map<String, String> _measureProductSources(String root) => {
  for (final path in _productSourcePaths)
    path: _sha256(File('$root/$path').readAsBytesSync()),
};

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
