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
    } else {
      positional.add(arg);
    }
  }
  if (positional.length != 3) {
    throw ArgumentError(
      'Usage: [--fixture <corpus.json>] <golden.json> <liber.json> <report.json>',
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

/// Strict FIELDS-02 admission and comparison. Native case records are an array;
/// the product record carries them under `caseRecords`. Missing, duplicate,
/// extra or wrong-typed observations are admission refusals, never a
/// `notCompared` pass.
Map<String, Object?> compareBookUrlMarkers({
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
  if (corpus['fixtureId'] != bookUrlMarkersFixtureId ||
      corpus['corpusVersion'] != bookUrlMarkersCorpusVersion) {
    throw StateError('Not the FIELDS-02 corpus');
  }
  if (golden['analysisFailure'] != null) {
    throw StateError('Golden recorded an analysis failure');
  }
  if (liber['fixturesSha256'] != corpusSha256) {
    throw StateError('Product corpus bytes do not match the selected corpus');
  }
  if (manifestCorpusSha256 != null && manifestCorpusSha256 != corpusSha256) {
    throw StateError('Golden manifest corpus pin does not match the corpus');
  }
  final goldenCorpus = golden['corpus'];
  if (goldenCorpus is! Map ||
      goldenCorpus['asset'] != 'field-fixtures.json' ||
      goldenCorpus['bytes'] is! int ||
      goldenCorpus['sha256'] != corpusSha256 ||
      goldenCorpus['fixtureId'] != bookUrlMarkersFixtureId ||
      goldenCorpus['corpusVersion'] != bookUrlMarkersCorpusVersion) {
    throw StateError('Golden corpus binding is malformed');
  }
  final fingerprint = golden['fingerprint'];
  if (fingerprint is! String || fingerprint.isEmpty) {
    throw StateError('Golden device fingerprint missing');
  }
  final librarySha = liber['librarySha256'];
  if (librarySha is! String || librarySha.isEmpty || librarySha == 'unknown') {
    throw StateError('Product library binding missing');
  }
  final goldenCleanup = _map(golden['cleanup'], 'golden.cleanup');
  if (goldenCleanup['serverClosed'] != true) {
    throw StateError('Golden cleanup did not close the replay server');
  }
  final goldenIsolation = _map(golden['isolation'], 'golden.isolation');
  if (goldenIsolation['bound'] != true ||
      goldenIsolation['filesRouted'] != true ||
      goldenIsolation['databaseRouted'] != true) {
    throw StateError('Golden scratch application is not bound/routed');
  }
  final liberCleanup = _map(liber['cleanup'], 'liber.cleanup');
  if (liberCleanup['serverClosed'] is! bool) {
    throw StateError('liber.cleanup.serverClosed must be boolean');
  }
  if (((golden['caseFailures'] as Map?) ?? const {}).isNotEmpty ||
      ((liber['caseFailures'] as Map?) ?? const {}).isNotEmpty) {
    throw StateError('A FIELDS-02 case did not complete');
  }
  final liberCases = _records(liber['caseRecords'], 'liber.caseRecords');
  final goldenCases = _records(golden['cases'], 'golden.cases');
  final declared = [
    for (final entry in (corpus['cases'] as List).cast<Map>())
      entry['id'] as String,
  ];
  _admitExactIds(goldenCases, declared, 'golden');
  _admitExactIds(liberCases, declared, 'liber');

  final caseDifferences = <Map<String, Object?>>[];
  final goldenById = {for (final record in goldenCases) record['id']: record};
  final liberById = {for (final record in liberCases) record['id']: record};
  for (final id in declared) {
    final frozen = goldenById[id]!;
    final product = liberById[id]!;
    final terminal = _string(frozen, 'terminal');
    _diff(
      caseDifferences,
      id,
      'terminal',
      terminal,
      _string(product, 'terminal'),
    );

    final frozenSearch = _map(frozen['search'], '$id.search');
    final productSearch = _map(product['search'], '$id.search');
    final frozenResults = _list(frozenSearch['results'], '$id.search.results');
    final productResults = _list(
      productSearch['results'],
      '$id.search.results',
    );
    _diff(
      caseDifferences,
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
        _string(f, field);
        _string(p, field);
        _diff(
          caseDifferences,
          id,
          'search.results[$index].$field',
          f[field],
          p[field],
        );
      }
      if (f['infoHtml'] is! bool || p['infoHtml'] is! bool) {
        throw StateError('$id.search.results[$index].infoHtml must be boolean');
      }
      _diff(
        caseDifferences,
        id,
        'search.results[$index].infoHtml',
        f['infoHtml'],
        p['infoHtml'],
      );
    }

    _compareStageMap(
      caseDifferences,
      id,
      'bookInfo',
      frozen['bookInfo'],
      product['bookInfo'],
      const ['name', 'author', 'bookUrl', 'tocUrl'],
    );
    _compareTableOfContents(
      caseDifferences,
      id,
      frozen['tableOfContents'],
      product['tableOfContents'],
    );
    _compareStageMap(
      caseDifferences,
      id,
      'chapter',
      frozen['chapter'],
      product['chapter'],
      const ['title', 'text'],
    );
    _compareProbes(caseDifferences, id, frozen, product);
    _compareCaseRequests(caseDifferences, id, frozen, product);
  }

  final requestDifferences = <Map<String, Object?>>[];
  final frozenRequests = _list(golden['requests'], 'golden.requests');
  final productRequests = _list(liber['requests'], 'liber.requests');
  _diff(
    requestDifferences,
    'requests',
    'requests.length',
    frozenRequests.length,
    productRequests.length,
  );
  final requestCount = frozenRequests.length < productRequests.length
      ? frozenRequests.length
      : productRequests.length;
  for (var index = 0; index < requestCount; index++) {
    _compareRequest(
      requestDifferences,
      index,
      _map(frozenRequests[index], 'golden.requests[$index]'),
      _map(productRequests[index], 'liber.requests[$index]'),
    );
  }
  final stageDifferences = <Map<String, Object?>>[];
  _diff(
    stageDifferences,
    'stageTrace',
    'stageTrace',
    golden['stageTrace'] ?? const <Object?>[],
    liber['stageTrace'] ?? const <Object?>[],
  );
  final cleanupDifferences = <Map<String, Object?>>[];
  if (liberCleanup['serverClosed'] != true) {
    cleanupDifferences.add({
      'row': 'cleanup',
      'field': 'liber.cleanup.serverClosed',
      'frozen': true,
      'liber': liberCleanup['serverClosed'],
    });
  }

  final rows = <Map<String, Object?>>[
    _row('C1', 'case records and declared terminals', caseDifferences),
    _row('C2', 'request identity and response receipts', requestDifferences),
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
  };
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
  final ids = [for (final record in records) _string(record, 'id')];
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

List<Object?> _list(Object? value, String label) {
  if (value is! List) throw StateError('$label must be an array');
  return value;
}

List<Map<String, dynamic>> _records(Object? value, String label) {
  if (value is! List) throw StateError('$label must be an array');
  return [
    for (final raw in value)
      if (raw is Map)
        raw.cast<String, dynamic>()
      else
        throw StateError('$label must contain objects'),
  ];
}

String _string(Map<String, dynamic> map, String field) {
  final value = map[field];
  if (value is! String) throw StateError('$field must be a string');
  return value;
}

String? _nullableString(Map<String, dynamic> map, String field) {
  final value = map[field];
  if (value != null && value is! String) {
    throw StateError('$field must be a string or null');
  }
  return value as String?;
}

bool _bool(Map<String, dynamic> map, String field) {
  final value = map[field];
  if (value is! bool) throw StateError('$field must be boolean');
  return value;
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

void _compareStageMap(
  List<Map<String, Object?>> differences,
  String id,
  String name,
  Object? frozenValue,
  Object? productValue,
  List<String> fields,
) {
  if (frozenValue == null || productValue == null) {
    _diff(differences, id, name, frozenValue, productValue);
    return;
  }
  final frozen = _map(frozenValue, '$id.$name');
  final product = _map(productValue, '$id.$name');
  for (final field in fields) {
    _string(frozen, field);
    _string(product, field);
    _diff(differences, id, '$name.$field', frozen[field], product[field]);
  }
}

void _compareTableOfContents(
  List<Map<String, Object?>> differences,
  String id,
  Object? frozenValue,
  Object? productValue,
) {
  if (frozenValue == null || productValue == null) {
    _diff(differences, id, 'tableOfContents', frozenValue, productValue);
    return;
  }
  final frozen = _map(frozenValue, '$id.tableOfContents');
  final product = _map(productValue, '$id.tableOfContents');
  _string(frozen, 'tocUrl');
  _string(product, 'tocUrl');
  _diff(
    differences,
    id,
    'tableOfContents.tocUrl',
    frozen['tocUrl'],
    product['tocUrl'],
  );
  final frozenChapters = _list(frozen['chapters'], '$id.chapters');
  final productChapters = _list(product['chapters'], '$id.chapters');
  _diff(
    differences,
    id,
    'tableOfContents.chapters.length',
    frozenChapters.length,
    productChapters.length,
  );
  final count = frozenChapters.length < productChapters.length
      ? frozenChapters.length
      : productChapters.length;
  for (var index = 0; index < count; index++) {
    final f = _map(frozenChapters[index], '$id.chapters[$index]');
    final p = _map(productChapters[index], '$id.chapters[$index]');
    for (final field in ['title', 'url', 'absoluteUrl']) {
      if (_string(f, field).isEmpty) {
        throw StateError('chapters[$index].$field must not be empty');
      }
    }
    if (_string(p, 'title').isEmpty) {
      throw StateError('chapters[$index].title must not be empty');
    }
    _string(p, 'url');
    _string(p, 'address');
    _nullableString(p, 'rawAddress');
    _string(p, 'storeKey');
    _string(p, 'persistedAddress');
    _nullableString(f, 'tag');
    _nullableString(p, 'tag');
    for (final field in ['isVolume', 'isVip', 'isPay']) {
      _bool(f, field);
      _bool(p, field);
    }
    for (final field in ['title', 'tag', 'isVolume', 'isVip', 'isPay']) {
      _diff(differences, id, 'chapters[$index].$field', f[field], p[field]);
    }
    _diff(
      differences,
      id,
      'chapters[$index].url(raw vs address)',
      f['url'],
      p['address'],
    );
    _diff(
      differences,
      id,
      'chapters[$index].absoluteUrl(vs url)',
      f['absoluteUrl'],
      p['url'],
    );
  }
}

void _compareProbes(
  List<Map<String, Object?>> differences,
  String id,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product,
) {
  final f = _map(frozen['sourceProbes'], '$id.sourceProbes');
  final p = _map(product['sourceProbes'], '$id.sourceProbes');
  for (final field in ['vipProbe', 'payProbe']) {
    _nullableString(f, field);
    _nullableString(p, field);
    _diff(differences, id, 'sourceProbes.$field', f[field], p[field]);
  }
}

void _compareCaseRequests(
  List<Map<String, Object?>> differences,
  String id,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product,
) {
  final f = _list(frozen['requests'], '$id.requests');
  final p = _list(product['requests'], '$id.requests');
  _diff(differences, id, 'requests.length', f.length, p.length);
  final count = f.length < p.length ? f.length : p.length;
  for (var index = 0; index < count; index++) {
    _compareRequest(
      differences,
      index,
      _map(f[index], '$id.requests[$index]'),
      _map(p[index], '$id.requests[$index]'),
      row: id,
    );
  }
}

void _compareRequest(
  List<Map<String, Object?>> differences,
  int index,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product, {
  String row = 'requests',
}) {
  for (final field in ['method', 'path', 'rawQuery']) {
    _string(frozen, field);
    _string(product, field);
    _diff(differences, row, '[$index].$field', frozen[field], product[field]);
  }
  final frozenQuery = _map(frozen['query'], 'frozen.query');
  final productQuery = _map(product['query'], 'liber.query');
  for (final query in [frozenQuery, productQuery]) {
    for (final value in query.values) {
      if (value is! String) {
        throw StateError('request query values must be strings');
      }
    }
  }
  _diff(differences, row, '[$index].query', frozen['query'], product['query']);
  final fr = _map(frozen['receipt'], 'frozen.receipt');
  final pr = _map(product['receipt'], 'liber.receipt');
  _string(fr, 'terminal');
  _string(pr, 'terminal');
  if (fr['status'] is! int || pr['status'] is! int) {
    throw StateError('request receipt status must be an integer');
  }
  _nullableString(fr, 'responseId');
  _nullableString(pr, 'responseId');
  _nullableString(fr, 'redirect');
  _nullableString(pr, 'redirect');
  for (final field in ['terminal', 'status', 'responseId']) {
    _diff(differences, row, '[$index].receipt.$field', fr[field], pr[field]);
  }
  _diff(
    differences,
    row,
    '[$index].receipt.redirect',
    fr['redirect'],
    pr['redirect'],
  );
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

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
