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
  if (args.length != 3) {
    throw ArgumentError('Usage: <golden.json> <liber.json> <report.json>');
  }
  final golden =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final liber =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  final corpusBytes = File(corpusPath).readAsBytesSync();
  final corpus = jsonDecode(utf8.decode(corpusBytes)) as Map<String, dynamic>;
  // The manifest beside the golden pins the corpus bytes this run compared; a
  // checkout that rewrote them (a CRLF conversion, a corpus edit) has to fail
  // here rather than compare against a different corpus than the one recorded.
  final manifestFile = File('${File(args[0]).parent.path}/manifest.json');
  String? manifestCorpusSha256;
  if (manifestFile.existsSync()) {
    final manifest = (jsonDecode(manifestFile.readAsStringSync()) as Map)
        .cast<String, Object?>();
    final corpusPin = (manifest['corpus'] as Map?)?.cast<String, Object?>();
    manifestCorpusSha256 = corpusPin?['sha256'] as String?;
  }
  final report = compareResultFields(
    golden: golden,
    liber: liber,
    goldenPath: args[0],
    liberPath: args[1],
    corpus: corpus,
    corpusSha256: _sha256(corpusBytes),
    manifestCorpusSha256: manifestCorpusSha256,
  );
  final output = File(args[2]);
  if (output.existsSync()) {
    throw StateError('Refusing to overwrite a report: ${args[2]}');
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
