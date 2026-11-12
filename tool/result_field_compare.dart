import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:liber/source/source_url_rules.dart';
import 'package:pointycastle/export.dart';

const _selectedCorpusHashes = {
  '049b46bbd98b9367516f923fc052d9d454057d99bd6875a89b88ce6fae09d500',
  '0cfa3b2ddb4a43ec8e62c0b9f5396e638c6c2dde40033a27be316ee5b74055c8',
  '98934998a2c5cc702bd24888f8ed59ce595d617870c2c5a45b79e0b947d7c7d0',
  '1e8f9517a4fb12da0ddf37c74bb2a024b35620e89a32b50f531f7bc11330ba6a',
  '88eba883d045dcd73c187ecd6cb7508e37d5721ef550000f4b21b1312dc1e8e0',
  '0f87c6c775ff54164bc11a9a30efaa48e5155def31c37e9b7eb8e721bd776be9',
  '4ead870ef7a5951016e56915e6e249a95a94525e3f353cdd1dff9d2ebdb09c7c',
};

/// The one terminal whose case also saves a chapter and refreshes the TOC.
const _titleLifecycleTerminal = 'four-stage-refresh';

/// The four ordered phases a title-lifecycle case observes.
const _titleLifecyclePhases = [
  'beforeContent',
  'storedAfterContent',
  'refreshedChapters',
  'storedAfterRefresh',
];

/// The chapter count every lifecycle phase must carry.
const _titleLifecycleChapters = 2;

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
  final manifest = manifestFile.existsSync()
      ? (jsonDecode(manifestFile.readAsStringSync()) as Map)
            .cast<String, dynamic>()
      : <String, dynamic>{};
  final manifestCorpusSha256 =
      (manifest['corpus'] as Map?)?['sha256'] as String?;
  Map<String, dynamic>? harnessProvenance;
  String? harnessProvenanceSha256;
  String? harnessAssetSha256;
  if (corpus['fixtureId'] == 'FIELDS-02') {
    if (selectedHarnessApk == null) {
      throw ArgumentError('--harness-apk is required for FIELDS-02');
    }
    final inspected = _inspectHarnessApk(selectedHarnessApk);
    harnessProvenance = inspected['provenance'] as Map<String, dynamic>;
    harnessProvenanceSha256 = inspected['provenanceSha256'] as String;
    harnessAssetSha256 = inspected['selectedAssetSha256'] as String;
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
          expectedHarnessAssetSha256: harnessAssetSha256!,
          expectedProvenanceSha256: harnessProvenanceSha256!,
          expectedProvenance: harnessProvenance!,
          expectedLibrarySha256: _requiredMeasuredPath(
            selectedLibrary,
            '--library',
          ),
          expectedProductSources: _measureProductSources(productSourceRoot),
          externalManifest: manifest,
          selectedFixturePath: selectedCorpus,
          selectedHarnessApkPath: selectedHarnessApk,
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
const _ownedPreferencePrefix = 'liber_fields_02_';
const _harnessPackage = 'io.liber.oracle.fields';

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
  required String expectedHarnessAssetSha256,
  required String expectedProvenanceSha256,
  required Map<String, dynamic> expectedProvenance,
  required String expectedLibrarySha256,
  required Map<String, String> expectedProductSources,
  required Map<String, dynamic> externalManifest,
  String? manifestCorpusSha256,
  String? selectedFixturePath,
  String? selectedHarnessApkPath,
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
  if (corpus['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716') {
    _verifySelectedBundle(
      goldenPath: goldenPath,
      golden: golden,
      manifest: externalManifest,
      corpus: corpus,
      fixturePath: selectedFixturePath,
      harnessApkPath: selectedHarnessApkPath,
      corpusSha256: corpusSha256,
      harnessApkSha256: expectedHarnessApkSha256,
      provenanceSha256: expectedProvenanceSha256,
      provenance: expectedProvenance,
    );
  }
  _admitExternalArtifact(
    externalManifest,
    golden,
    corpus,
    target,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    corpusByteCount: corpusByteCount,
    expectedHarnessApkSha256: expectedHarnessApkSha256,
    expectedHarnessAssetSha256: expectedHarnessAssetSha256,
    expectedProvenanceSha256: expectedProvenanceSha256,
    expectedProvenance: expectedProvenance,
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
    _compareCases(caseDifferences, id, frozen, product, corpusById[id]!);
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
  final origin = _requiredString(corpus, 'origin', 'corpus');
  _admitOperationSpans(
    goldenCases,
    goldenRequests,
    goldenTrace,
    'golden',
    origin,
    nativeSide: true,
  );
  _admitOperationSpans(
    productCases,
    productRequests,
    productTrace,
    'liber',
    origin,
    nativeSide: false,
  );
  _admitCausalRelationships(
    requestDifferences,
    'golden',
    goldenRequests,
    goldenCases,
    goldenTrace,
    origin,
  );
  _admitCausalRelationships(
    requestDifferences,
    'liber',
    productRequests,
    productCases,
    productTrace,
    origin,
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

Map<String, dynamic> inspectSelectedHarnessApk(String path) =>
    _inspectHarnessApk(path);

Map<String, dynamic> _inspectHarnessApk(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoder = ZipDecoder();
  final archive = decoder.decodeBytes(bytes);
  final rawNames = [
    for (final header in decoder.directory.fileHeaders) header.filename,
  ];
  final names = archive.files.map((file) => file.name).toList();
  for (final required in const [
    'assets/field-fixtures.json',
    'assets/field-provenance.json',
  ]) {
    if (rawNames.where((name) => name == required).length != 1 ||
        names.where((name) => name == required).length != 1) {
      throw StateError('selected APK must contain exactly one $required');
    }
  }
  final asset = archive.findFile('assets/field-fixtures.json')!;
  final provenanceFile = archive.findFile('assets/field-provenance.json')!;
  final provenanceBytes = Uint8List.fromList(provenanceFile.content);
  final decoded = jsonDecode(utf8.decode(provenanceBytes));
  if (decoded is! Map) {
    throw StateError('embedded provenance is not an object');
  }
  final provenance = decoded.cast<String, dynamic>();
  final corpus = _map(provenance['corpus'], 'provenance.corpus');
  final assetBytes = Uint8List.fromList(asset.content);
  final embedded = jsonDecode(utf8.decode(assetBytes));
  if (embedded is! Map ||
      embedded['fixtureId'] != bookUrlMarkersFixtureId ||
      embedded['corpusVersion'] is! int ||
      embedded['corpusVersion'] != bookUrlMarkersCorpusVersion) {
    throw StateError('embedded corpus selection is not FIELDS-02 version 1');
  }
  final selectedReference =
      embedded['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716';
  final target = embedded['target'];
  if (!selectedReference &&
      target is Map &&
      (target['package'] == 'com.legado.app.debug' ||
          target['apkSha256'] ==
              '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5')) {
    throw StateError('selected target requires its fixed baseline');
  }
  if (selectedReference) {
    if (!_selectedCorpusHashes.contains(_sha256(assetBytes)) ||
        target is! Map ||
        target.length != 3 ||
        target['package'] != 'com.legado.app.debug' ||
        target['apkSha256'] !=
            '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5' ||
        target['deviceFingerprint'] !=
            'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys') {
      throw StateError('selected reference corpus identity differs');
    }
  }
  _admitProvenanceObject(
    provenance,
    'provenance',
    selectedReference: selectedReference,
  );
  if (_requiredInt(corpus, 'bytes', 'provenance.corpus') != assetBytes.length ||
      corpus['sha256'] != _sha256(assetBytes) ||
      corpus['sha256Lf'] != _sha256(_lf(assetBytes))) {
    throw StateError('embedded provenance does not bind embedded corpus bytes');
  }
  return {
    'apkSha256': _sha256(bytes),
    'assetBytes': assetBytes,
    'selectedAssetSha256': _sha256(assetBytes),
    'selectedAssetSha256Lf': _sha256(_lf(assetBytes)),
    'selectedAssetBytes': assetBytes.length,
    'provenance': provenance,
    'provenanceSha256': _sha256(provenanceBytes),
  };
}

void _admitProvenanceObject(
  Map<String, dynamic> provenance,
  String label, {
  bool selectedReference = false,
}) {
  if (_requiredInt(provenance, 'schemaVersion', label) != 1) {
    throw StateError('$label.schemaVersion must be integer 1');
  }
  if (_requiredString(provenance, 'fixtureId', label) !=
      bookUrlMarkersFixtureId) {
    throw StateError('$label.fixtureId differs');
  }
  final corpus = _map(provenance['corpus'], '$label.corpus');
  if (_requiredString(corpus, 'asset', '$label.corpus') !=
          'field-fixtures.json' ||
      _requiredString(corpus, 'fixtureId', '$label.corpus') !=
          bookUrlMarkersFixtureId ||
      _requiredInt(corpus, 'corpusVersion', '$label.corpus') != 1) {
    throw StateError('$label corpus identity differs');
  }
  if (_requiredInt(corpus, 'bytes', '$label.corpus') < 0) {
    throw StateError('$label corpus bytes are negative');
  }
  for (final field in ['sha256', 'sha256Lf']) {
    final digest = _requiredString(corpus, field, '$label.corpus');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw StateError('$label corpus digest is malformed');
    }
  }
  final sources = _stringMap(provenance['sources'], '$label.sources');
  const historical = {
    'FieldOracle.java',
    'StateSessionOracle.java',
    'AndroidManifest.xml',
    'build.ps1',
    'capture.py',
  };
  const current = {
    ...historical,
    'HostRuntimeInit.java',
    'ShortcutStartupGuard.java',
  };
  const selected = {
    ...current,
    'GuardedReaderApplication.java',
    'SelectedFieldHostBridge.java',
    'AndroidManifest-selected.xml',
  };
  final names = sources.keys.toSet();
  final accepted = selectedReference
      ? names.length == selected.length && names.containsAll(selected)
      : (names.length == historical.length && names.containsAll(historical)) ||
            (names.length == current.length && names.containsAll(current));
  if (!accepted) {
    throw StateError('$label source key set differs');
  }
  for (final digest in sources.values) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw StateError('$label source digest is malformed');
    }
  }
}

void _admitExternalArtifact(
  Map<String, dynamic> manifest,
  Map<String, dynamic> golden,
  Map<String, dynamic> corpus,
  Map<String, dynamic> target, {
  required String corpusSha256,
  required String corpusSha256Lf,
  required int corpusByteCount,
  required String expectedHarnessApkSha256,
  required String expectedHarnessAssetSha256,
  required String expectedProvenanceSha256,
  required Map<String, dynamic> expectedProvenance,
}) {
  if (corpus['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716' &&
      (!_selectedCorpusHashes.contains(corpusSha256) ||
          corpusSha256Lf != corpusSha256 ||
          target['package'] != 'com.legado.app.debug' ||
          target['apkSha256'] !=
              '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5' ||
          target['deviceFingerprint'] !=
              'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys')) {
    throw StateError('selected reference corpus or target differs');
  }
  if (manifest.isEmpty) {
    throw StateError('external capture manifest is missing');
  }
  if (manifest['status'] != 'observed' ||
      manifest['existingDataHashesUnchanged'] != true ||
      manifest['frozenAppDataUnchanged'] != true) {
    throw StateError('external manifest does not record a successful capture');
  }
  final privateFileChanges = manifest['privateFileChanges'];
  if (privateFileChanges is! Map || privateFileChanges.isNotEmpty) {
    throw StateError('external manifest records private file changes');
  }
  final artifact = _map(manifest['artifact'], 'manifest.artifact');
  final artifactApkSha = _requiredString(
    artifact,
    'apkSha256',
    'manifest.artifact',
  );
  final artifactAssetSha = _requiredString(
    artifact,
    'selectedAssetSha256',
    'manifest.artifact',
  );
  final artifactAssetLfSha = _requiredString(
    artifact,
    'selectedAssetSha256Lf',
    'manifest.artifact',
  );
  final artifactAssetBytes = _requiredInt(
    artifact,
    'selectedAssetBytes',
    'manifest.artifact',
  );
  final artifactProvenanceSha = _requiredString(
    artifact,
    'provenanceSha256',
    'manifest.artifact',
  );
  if (artifactApkSha != expectedHarnessApkSha256 ||
      artifactAssetSha != expectedHarnessAssetSha256 ||
      artifactAssetLfSha != corpusSha256Lf ||
      artifactAssetBytes != corpusByteCount) {
    throw StateError(
      'external artifact bytes do not match the selected APK/corpus',
    );
  }
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(artifactProvenanceSha) ||
      artifactProvenanceSha != expectedProvenanceSha256) {
    throw StateError('external artifact provenance digest differs');
  }
  final selectedReference =
      corpus['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716';
  _admitProvenanceObject(
    expectedProvenance,
    'provenance',
    selectedReference: selectedReference,
  );
  final artifactProvenance = _map(
    artifact['provenance'],
    'manifest.artifact.provenance',
  );
  _admitProvenanceObject(
    artifactProvenance,
    'manifest.artifact.provenance',
    selectedReference: selectedReference,
  );
  if (!_deepEquals(artifactProvenance, expectedProvenance)) {
    throw StateError(
      'external artifact provenance differs from the selected APK',
    );
  }
  final provenance = expectedProvenance;
  final pcorpus = _map(provenance['corpus'], 'provenance.corpus');
  if (pcorpus['sha256'] != corpusSha256 ||
      pcorpus['sha256Lf'] != corpusSha256Lf ||
      pcorpus['bytes'] != corpusByteCount ||
      pcorpus['fixtureId'] != bookUrlMarkersFixtureId ||
      _requiredInt(pcorpus, 'corpusVersion', 'provenance.corpus') != 1) {
    throw StateError(
      'embedded provenance corpus does not match selected bytes',
    );
  }
  final sources = _stringMap(provenance['sources'], 'provenance.sources');
  final manifestSources = _stringMap(
    manifest['harnessSources'],
    'manifest.harnessSources',
  );
  if (!_deepEquals(manifestSources, sources)) {
    throw StateError('external manifest source map differs from the APK');
  }
  final isolation = _map(golden['isolation'], 'golden.isolation');
  if (isolation['harnessApkSha256'] != expectedHarnessApkSha256) {
    throw StateError('golden harness APK differs from selected APK');
  }
  final manifestCorpus = _map(manifest['corpus'], 'manifest.corpus');
  if (_requiredInt(manifestCorpus, 'bytes', 'manifest.corpus') !=
          corpusByteCount ||
      manifestCorpus['sha256'] != corpusSha256 ||
      manifestCorpus['sha256Lf'] != corpusSha256Lf) {
    throw StateError('external manifest corpus measurement differs');
  }
  if (selectedReference) return;
  final cleanup = _map(manifest['scratchCleanup'], 'manifest.scratchCleanup');
  final owner = _map(manifest['scratchOwner'], 'manifest.scratchOwner');
  final targetRoot = _requiredString(manifest, 'targetPrivateRoot', 'manifest');
  final scratchRoot = '$targetRoot/cache/liber-fields-02';
  final nativeCleanup = _map(golden['cleanup'], 'golden.cleanup');
  final nativeIsolation = _map(golden['isolation'], 'golden.isolation');
  if (nativeCleanup['fixtureId'] != bookUrlMarkersFixtureId ||
      _requiredInt(nativeCleanup, 'corpusVersion', 'golden.cleanup') != 1 ||
      nativeIsolation['harnessPackage'] != _harnessPackage ||
      nativeIsolation['scratchRoot'] != scratchRoot ||
      nativeIsolation['preferencesPrefix'] != _ownedPreferencePrefix ||
      nativeCleanup['scratchRoot'] != scratchRoot ||
      nativeCleanup['reportPath'] != '$scratchRoot/field-oracle.json') {
    throw StateError(
      'native cleanup/root is not the measured target-private relation',
    );
  }
  if (nativeCleanup['ownerRunId'] != cleanup['ownerRunId']) {
    throw StateError('external and native cleanup attempts differ');
  }
  if (cleanup['postStop'] != true ||
      cleanup['rootAbsent'] != true ||
      cleanup['ownedPreferencesAbsent'] != true ||
      cleanup['root'] != scratchRoot ||
      cleanup['ownerRunId'] != nativeCleanup['ownerRunId']) {
    throw StateError('external post-stop cleanup proof is incomplete');
  }
  if (owner['complete'] != true ||
      owner['seedRunId'] != nativeCleanup['ownerRunId'] ||
      _requiredInt(owner, 'seedPid', 'manifest.scratchOwner') <= 0 ||
      owner['fixtureId'] != bookUrlMarkersFixtureId ||
      _requiredInt(owner, 'corpusVersion', 'manifest.scratchOwner') != 1 ||
      owner['targetPackage'] != target['package'] ||
      owner['harnessPackage'] != _harnessPackage ||
      owner['targetApkSha256'] != target['apkSha256'] ||
      owner['harnessApkSha256'] != expectedHarnessApkSha256 ||
      owner['corpusSha256Lf'] != corpusSha256Lf) {
    throw StateError('external owner proof is not bound to selected evidence');
  }
  final ownerPrefs = owner['preferences'];
  final cleanupPrefs = cleanup['reportedOwnedPreferences'];
  final nativePrefs = nativeCleanup['ownedPreferences'];
  bool safePrefs(List<dynamic> values) =>
      values.isNotEmpty &&
      values.every(
        (value) =>
            value is String &&
            RegExp(
              r'^liber_fields_02_[A-Za-z0-9][A-Za-z0-9_.:+-]*$',
            ).hasMatch(value) &&
            !value.contains('/'),
      );
  if (ownerPrefs is! List ||
      cleanupPrefs is! List ||
      nativePrefs is! List ||
      !safePrefs(ownerPrefs) ||
      !safePrefs(cleanupPrefs) ||
      !safePrefs(nativePrefs) ||
      ownerPrefs.length != nativePrefs.length ||
      cleanupPrefs.length != nativePrefs.length ||
      ownerPrefs.toSet().length != ownerPrefs.length ||
      cleanupPrefs.toSet().length != cleanupPrefs.length ||
      nativePrefs.toSet().length != nativePrefs.length ||
      !ownerPrefs.toSet().containsAll(nativePrefs.cast<Object?>()) ||
      !nativePrefs.toSet().containsAll(ownerPrefs.cast<Object?>()) ||
      !cleanupPrefs.toSet().containsAll(ownerPrefs.cast<Object?>()) ||
      !ownerPrefs.toSet().containsAll(cleanupPrefs.cast<Object?>()) ||
      !ownerPrefs.contains('${_ownedPreferencePrefix}probe') ||
      !cleanupPrefs.contains('${_ownedPreferencePrefix}probe') ||
      !nativePrefs.contains('${_ownedPreferencePrefix}probe')) {
    throw StateError('external owner/cleanup preference inventory differs');
  }
  final probe = _map(
    nativeIsolation['preferenceProbe'],
    'golden.isolation.preferenceProbe',
  );
  if (probe['name'] != '${_ownedPreferencePrefix}probe' ||
      probe['installationFile'] != false ||
      probe['registered'] != true ||
      probe['committed'] != true ||
      probe['scopedFile'] != true) {
    throw StateError('native preference probe flags are incomplete');
  }
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
    if (terminal != 'four-stage' &&
        terminal != 'search-empty' &&
        terminal != _titleLifecycleTerminal) {
      throw StateError('unsupported corpus terminal: $terminal');
    }
    _requiredString(entry, 'keyword', 'corpus.cases[$id]');
    _map(entry['source'], 'corpus.cases[$id].source');
    // Materialize the validated ABSENT-only default in an internal admitted
    // entry; the caller's corpus object and frozen bytes remain untouched.
    records.add({...entry, 'terminal': terminal});
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

/// Delegates selected physical admission to the collector's read-only verifier.
void _verifySelectedBundle({
  required String goldenPath,
  required Map<String, dynamic> golden,
  required Map<String, dynamic> manifest,
  required Map<String, dynamic> corpus,
  required String? fixturePath,
  required String? harnessApkPath,
  required String corpusSha256,
  required String harnessApkSha256,
  required String provenanceSha256,
  required Map<String, dynamic> provenance,
}) {
  if (fixturePath == null || harnessApkPath == null) {
    throw StateError(
      'selected raw-bundle requires fixture and harness APK paths',
    );
  }
  final goldenFile = File(goldenPath);
  final bundle = goldenFile.parent;
  final rawGolden = File('${bundle.path}/golden.json');
  final rawManifest = File('${bundle.path}/manifest.json');
  final targetApk = File('${bundle.path}/frozen.apk');
  final fixture = File(fixturePath);
  final apk = File(harnessApkPath);
  if (![
    goldenFile,
    rawGolden,
    rawManifest,
    targetApk,
    fixture,
    apk,
  ].every((f) => f.existsSync())) {
    throw StateError('selected raw-bundle input is missing');
  }
  final goldenBytes = goldenFile.readAsBytesSync();
  final manifestBytes = rawManifest.readAsBytesSync();
  final fixtureBytes = fixture.readAsBytesSync();
  final inspected = inspectSelectedHarnessApk(apk.path);
  if (!_deepEquals(goldenBytes, rawGolden.readAsBytesSync()) ||
      !_deepEquals(jsonDecode(utf8.decode(goldenBytes)), golden) ||
      !_deepEquals(jsonDecode(utf8.decode(manifestBytes)), manifest) ||
      !_deepEquals(jsonDecode(utf8.decode(fixtureBytes)), corpus) ||
      _sha256(fixtureBytes) != corpusSha256 ||
      inspected['apkSha256'] != harnessApkSha256 ||
      inspected['provenanceSha256'] != provenanceSha256 ||
      !_deepEquals(inspected['provenance'], provenance)) {
    throw StateError('selected raw-bundle passed inputs differ from files');
  }
  final local = Platform.environment['LOCALAPPDATA'];
  if (local == null || local.isEmpty) {
    throw StateError('selected raw-bundle Android SDK location unavailable');
  }
  final temporary = Directory.systemTemp.createTempSync('liber-fields-verify-');
  var verified = false;
  try {
    final output = '${temporary.path}/verification';
    final result = Process.runSync('python', [
      'tool/result_field_oracle/capture.py',
      '--verify-bundle',
      bundle.absolute.path,
      '--fixture',
      fixture.absolute.path,
      '--apk',
      apk.absolute.path,
      '--target-apk',
      targetApk.absolute.path,
      '--frozen-source',
      'C:/Users/17945/AppData/Local/liber-evidence/spec133/'
          'phone-resume-20261020-01a15796/controller/team-baseline-migration-01/'
          'reference-stage/source',
      '--java-home',
      'C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8',
      '--android-sdk',
      '$local/Android/Sdk',
      '--output',
      output,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'selected raw-bundle verification failed (evidence $output): ${result.stdout} ${result.stderr}',
      );
    }
    final receipt = jsonDecode(
      File('$output/verification.json').readAsStringSync(),
    );
    if (receipt is! Map ||
        receipt['status'] != 'verified-bundle' ||
        receipt['goldenSha256'] != _sha256(goldenBytes) ||
        receipt['manifestSha256'] != _sha256(manifestBytes) ||
        receipt['fixtureSha256'] != corpusSha256 ||
        receipt['harnessApkSha256'] != harnessApkSha256 ||
        receipt['provenanceSha256'] != provenanceSha256 ||
        receipt['targetApkSha256'] != _sha256(targetApk.readAsBytesSync())) {
      throw StateError(
        'selected raw-bundle verification binding differs (evidence $output)',
      );
    }
    verified = true;
  } finally {
    if (verified) temporary.deleteSync(recursive: true);
  }
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
      _requiredInt(corpusBlock, 'corpusVersion', 'golden.corpus') !=
          bookUrlMarkersCorpusVersion) {
    throw StateError('golden corpus identity is malformed');
  }
  if (_requiredInt(corpusBlock, 'bytes', 'golden.corpus') != corpusByteCount) {
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
  if (corpus['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716') {
    _admitErrorFacts(golden, 'golden');
    return;
  }
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
  final ownerRunId = _requiredString(cleanup, 'ownerRunId', 'golden.cleanup');
  if (ownerRunId.isEmpty) {
    throw StateError('golden ownerRunId must not be empty');
  }
  _requiredString(cleanup, 'scratchRoot', 'golden.cleanup');
  _requiredString(cleanup, 'reportPath', 'golden.cleanup');
  final owned = _requiredList(cleanup, 'ownedPreferences', 'golden.cleanup');
  if (owned.isEmpty ||
      owned.any(
        (value) =>
            value is! String ||
            !value.startsWith(_ownedPreferencePrefix) ||
            value.length == _ownedPreferencePrefix.length,
      )) {
    throw StateError(
      'golden cleanup.ownedPreferences must be owned, nonempty names',
    );
  }
  if (isolation['preferencesPrefix'] != _ownedPreferencePrefix) {
    throw StateError('golden preference namespace differs');
  }
  final probe = _map(
    isolation['preferenceProbe'],
    'golden.isolation.preferenceProbe',
  );
  if (probe['installationFile'] != false ||
      probe['registered'] != true ||
      probe['committed'] != true ||
      probe['scopedFile'] != true) {
    throw StateError('golden preference probe flags are incomplete');
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
  if (_requiredInt(liber, 'fixturesBytes', 'liber') != corpusByteCount ||
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
    if (field == 'corpusVersion') {
      if (_requiredInt(record, field, label) !=
          _requiredInt(corpus, field, 'corpus')) {
        throw StateError('$label $field does not match the selected corpus');
      }
    } else if (_present(record, field, label) != corpus[field]) {
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

bool _declaresRuleField(
  Map<String, dynamic> corpusEntry,
  String ruleName,
  String field,
) {
  final source = corpusEntry['source'];
  if (source is! Map) return false;
  final rules = source[ruleName];
  return rules is Map && rules.containsKey(field);
}

void _admitCaseRecord(
  Map<String, dynamic> record,
  Map<String, dynamic> corpusEntry,
  String label, {
  required bool native,
}) {
  final searchIntroDeclared = _declaresRuleField(
    corpusEntry,
    'ruleSearch',
    'intro',
  );
  final infoIntroDeclared = _declaresRuleField(
    corpusEntry,
    'ruleBookInfo',
    'intro',
  );
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
      introDeclared: searchIntroDeclared,
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
    if (infoIntroDeclared) {
      _requiredString(bookInfo, 'intro', '$label.bookInfo');
    } else if (bookInfo.containsKey('intro')) {
      throw StateError('$label.bookInfo.intro is not declared by the corpus');
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
  _admitTitleLifecycle(record, terminal, label, native: native);
  if (native) _admitTitleLifecycleProof(record, terminal, label);
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

/// The shared saved-name/refresh observation, present only where declared.
///
/// Only the four ordered phase arrays are shared with the product. Everything
/// about the native setup, storage containment, preference and event guard is
/// producer evidence and is admitted separately by [_admitTitleLifecycleProof],
/// so a product record never has to invent a native cache, database,
/// preference or guard fact.
///
/// A case whose terminal is not the lifecycle terminal must not carry either
/// field at all, so an old or non-observing case cannot smuggle one in.
void _admitTitleLifecycle(
  Map<String, dynamic> record,
  String terminal,
  String label, {
  required bool native,
}) {
  if (terminal != _titleLifecycleTerminal) {
    for (final field in ['titleLifecycle', 'titleLifecycleProof']) {
      if (record.containsKey(field)) {
        throw StateError('$label.$field is not declared by its terminal');
      }
    }
    return;
  }
  // The native proof is producer evidence; a product record that carries one
  // is claiming a native fact it cannot have.
  if (!native && record.containsKey('titleLifecycleProof')) {
    throw StateError('$label.titleLifecycleProof is native producer evidence');
  }
  final lifecycle = _requiredMap(record, 'titleLifecycle', label);
  if (lifecycle.length != _titleLifecyclePhases.length ||
      !lifecycle.keys.every(_titleLifecyclePhases.contains)) {
    throw StateError(
      '$label.titleLifecycle fields differ: ${lifecycle.keys.toList()..sort()}',
    );
  }
  for (final phase in _titleLifecyclePhases) {
    final rows = _requiredList(lifecycle, phase, '$label.titleLifecycle');
    if (rows.length != _titleLifecycleChapters) {
      throw StateError('$label.titleLifecycle.$phase row count differs');
    }
    for (var index = 0; index < rows.length; index++) {
      final rowLabel = '$label.titleLifecycle.$phase[$index]';
      final row = _map(rows[index], rowLabel);
      // A missing field is named before the extra-field check, so a missing
      // `variable` is never reported as some other shape error.
      for (final field in ['index', 'title', 'variable']) {
        if (!row.containsKey(field)) {
          throw StateError('$rowLabel.$field is missing');
        }
      }
      if (row.length != 3) {
        throw StateError('$rowLabel fields differ');
      }
      if (_requiredInt(row, 'index', rowLabel) != index) {
        throw StateError('$rowLabel.index is not its ordered position');
      }
      if (_requiredString(row, 'title', rowLabel).isEmpty) {
        throw StateError('$rowLabel.title must not be empty');
      }
      _nullableStringPresent(row, 'variable', rowLabel);
    }
  }
}

/// The actual native producer evidence for the saved-content observation.
///
/// Required on the native report only, and never on the product: it binds the
/// case's own book and first chapter, the real observer registration/removal
/// acknowledgements, the counted save event, the restored preference value and
/// the content files. The process guard's own closure is a report cleanup fact
/// and is admitted separately.
void _admitTitleLifecycleProof(
  Map<String, dynamic> record,
  String terminal,
  String label,
) {
  if (terminal != _titleLifecycleTerminal) return;
  final proof = _requiredMap(record, 'titleLifecycleProof', label);
  _exactKeys(proof, const {
    'bookParent',
    'chapterSeed',
    'saveObserver',
    'tocCountWordsApplied',
    'saveEvent',
    'contentFiles',
    'saveObserverClose',
    'tocCountWords',
  }, '$label.titleLifecycleProof');
  final info = _requiredMap(record, 'bookInfo', label);
  final bookUrl = _requiredString(info, 'bookUrl', '$label.bookInfo');
  final toc = _requiredMap(record, 'tableOfContents', label);
  final chapters = _requiredList(toc, 'chapters', '$label.tableOfContents');
  if (chapters.isEmpty) {
    throw StateError('$label has no chapter observation');
  }
  final first = _map(chapters.first, '$label.tableOfContents.chapters[0]');
  final chapterUrl = _requiredString(
    first,
    'url',
    '$label.tableOfContents.chapters[0]',
  );

  final parent = _requiredMap(
    proof,
    'bookParent',
    '$label.titleLifecycleProof',
  );
  _exactKeys(parent, const {
    'bookUrl',
    'stored',
    'readBack',
  }, '$label.titleLifecycleProof.bookParent');
  if (_requiredString(
        parent,
        'bookUrl',
        '$label.titleLifecycleProof.bookParent',
      ) !=
      bookUrl) {
    throw StateError(
      '$label.titleLifecycleProof.bookParent.bookUrl differs from this case',
    );
  }
  for (final field in ['stored', 'readBack']) {
    if (_requiredBool(parent, field, '$label.titleLifecycleProof.bookParent') !=
        true) {
      throw StateError(
        '$label.titleLifecycleProof.bookParent.$field must be true',
      );
    }
  }

  final seed = _requiredMap(proof, 'chapterSeed', '$label.titleLifecycleProof');
  _exactKeys(seed, const {
    'rows',
    'inserted',
  }, '$label.titleLifecycleProof.chapterSeed');
  final rows = _requiredInt(
    seed,
    'rows',
    '$label.titleLifecycleProof.chapterSeed',
  );
  if (rows != chapters.length || rows != _titleLifecycleChapters) {
    throw StateError('$label.titleLifecycleProof.chapterSeed.rows differs');
  }
  if (_requiredBool(
        seed,
        'inserted',
        '$label.titleLifecycleProof.chapterSeed',
      ) !=
      true) {
    throw StateError(
      '$label.titleLifecycleProof.chapterSeed.inserted must be true',
    );
  }

  final observer = _requiredMap(
    proof,
    'saveObserver',
    '$label.titleLifecycleProof',
  );
  _exactKeys(observer, const {
    'tag',
    'interface',
    'declaringClass',
    'onMain',
    'registered',
  }, '$label.titleLifecycleProof.saveObserver');
  if (_requiredString(
        observer,
        'tag',
        '$label.titleLifecycleProof.saveObserver',
      ) !=
      'saveContent') {
    throw StateError('$label.titleLifecycleProof.saveObserver.tag differs');
  }
  for (final field in ['interface', 'declaringClass']) {
    if (_requiredString(
          observer,
          field,
          '$label.titleLifecycleProof.saveObserver',
        ) !=
        _observableInterface) {
      throw StateError(
        '$label.titleLifecycleProof.saveObserver.$field differs',
      );
    }
  }
  for (final field in ['onMain', 'registered']) {
    if (_requiredBool(
          observer,
          field,
          '$label.titleLifecycleProof.saveObserver',
        ) !=
        true) {
      throw StateError(
        '$label.titleLifecycleProof.saveObserver.$field must be true',
      );
    }
  }

  final applied = _requiredMap(
    proof,
    'tocCountWordsApplied',
    '$label.titleLifecycleProof',
  );
  _exactKeys(applied, const {
    'name',
    'applied',
    'committed',
    'observed',
  }, '$label.titleLifecycleProof.tocCountWordsApplied');
  if (_requiredString(
        applied,
        'name',
        '$label.titleLifecycleProof.tocCountWordsApplied',
      ) !=
      'tocCountWords') {
    throw StateError(
      '$label.titleLifecycleProof.tocCountWordsApplied.name differs',
    );
  }
  for (final field in ['applied', 'committed', 'observed']) {
    if (_requiredBool(
          applied,
          field,
          '$label.titleLifecycleProof.tocCountWordsApplied',
        ) !=
        true) {
      throw StateError(
        '$label.titleLifecycleProof.tocCountWordsApplied.$field must be true',
      );
    }
  }

  final event = _requiredMap(proof, 'saveEvent', '$label.titleLifecycleProof');
  _admitSaveTerminal(
    event,
    '$label.titleLifecycleProof.saveEvent',
    bookUrl,
    chapterUrl,
  );

  final close = _requiredMap(
    proof,
    'saveObserverClose',
    '$label.titleLifecycleProof',
  );
  _admitSaveTerminal(
    close,
    '$label.titleLifecycleProof.saveObserverClose',
    bookUrl,
    chapterUrl,
    cached: true,
  );
  for (final field in const [
    'events',
    'duplicates',
    'foreignEvents',
    'callbackErrors',
    'offMainEvents',
    'malformedEvents',
    'lastEvent',
    'removal',
  ]) {
    if (!_deepEquals(close[field], event[field])) {
      throw StateError(
        '$label.titleLifecycleProof.saveObserverClose.$field differs from '
        'the first close',
      );
    }
  }

  final files = _requiredList(
    proof,
    'contentFiles',
    '$label.titleLifecycleProof',
  );
  if (files.isEmpty) {
    throw StateError(
      '$label.titleLifecycleProof.contentFiles must not be empty',
    );
  }
  final names = <String>[];
  for (var index = 0; index < files.length; index++) {
    final name = files[index];
    if (name is! String ||
        name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw StateError(
        '$label.titleLifecycleProof.contentFiles[$index] must be a safe '
        'content basename',
      );
    }
    names.add(name);
  }
  for (var index = 1; index < names.length; index++) {
    if (names[index].compareTo(names[index - 1]) <= 0) {
      throw StateError(
        '$label.titleLifecycleProof.contentFiles must be sorted unique '
        'basenames',
      );
    }
  }

  final preference = _requiredMap(
    proof,
    'tocCountWords',
    '$label.titleLifecycleProof',
  );
  _exactKeys(preference, const {
    'previousPresent',
    'previous',
    'committed',
    'presentAfter',
    'observedAfter',
    'restored',
  }, '$label.titleLifecycleProof.tocCountWords');
  for (final field in const [
    'previousPresent',
    'previous',
    'committed',
    'presentAfter',
    'observedAfter',
    'restored',
  ]) {
    _requiredBool(
      preference,
      field,
      '$label.titleLifecycleProof.tocCountWords',
    );
  }
  if (preference['restored'] != true) {
    throw StateError(
      '$label.titleLifecycleProof.tocCountWords was not restored',
    );
  }
  if (preference['committed'] != true) {
    throw StateError(
      '$label.titleLifecycleProof.tocCountWords restore did not commit',
    );
  }
  if (preference['presentAfter'] != preference['previousPresent']) {
    throw StateError(
      '$label.titleLifecycleProof.tocCountWords presence differs',
    );
  }
  if (preference['observedAfter'] != preference['previous']) {
    throw StateError(
      '$label.titleLifecycleProof.tocCountWords observed value differs from '
      'the actual prior value',
    );
  }
}

const _observableInterface = 'com.jeremyliao.liveeventbus.core.Observable';

void _admitSaveTerminal(
  Map<String, dynamic> terminal,
  String label,
  String bookUrl,
  String chapterUrl, {
  bool cached = false,
}) {
  final expected = <String>{
    'events',
    'duplicates',
    'foreignEvents',
    'callbackErrors',
    'offMainEvents',
    'malformedEvents',
    'lastEvent',
    'removal',
  };
  if (cached) expected.addAll(const {'alreadyClosed', 'removed'});
  _exactKeys(terminal, expected, label);
  if (_requiredInt(terminal, 'events', label) != 1) {
    throw StateError('$label did not observe exactly one save event');
  }
  for (final field in const [
    'duplicates',
    'foreignEvents',
    'callbackErrors',
    'offMainEvents',
    'malformedEvents',
  ]) {
    if (_requiredInt(terminal, field, label) != 0) {
      throw StateError('$label.$field is not clean');
    }
  }
  if (terminal.containsKey('failed')) {
    throw StateError('$label carries a failure flag');
  }
  final event = _requiredMap(terminal, 'lastEvent', label);
  _exactKeys(event, const {
    'bookUrl',
    'chapterUrl',
    'correlates',
  }, '$label.lastEvent');
  if (_requiredString(event, 'bookUrl', '$label.lastEvent') != bookUrl) {
    throw StateError('$label.lastEvent.bookUrl differs from this case');
  }
  if (_requiredString(event, 'chapterUrl', '$label.lastEvent') != chapterUrl) {
    throw StateError(
      '$label.lastEvent.chapterUrl differs from the first chapter',
    );
  }
  if (_requiredBool(event, 'correlates', '$label.lastEvent') != true) {
    throw StateError('$label.lastEvent does not correlate');
  }
  final removal = _requiredMap(terminal, 'removal', label);
  _exactKeys(removal, const {
    'interface',
    'declaringClass',
    'onMain',
    'removed',
  }, '$label.removal');
  for (final field in ['interface', 'declaringClass']) {
    if (_requiredString(removal, field, '$label.removal') !=
        _observableInterface) {
      throw StateError('$label.removal.$field differs');
    }
  }
  if (_requiredBool(removal, 'onMain', '$label.removal') != true) {
    throw StateError('$label.removal did not run on the main thread');
  }
  if (_requiredBool(removal, 'removed', '$label.removal') != true) {
    throw StateError('$label.removal was not acknowledged');
  }
  if (cached) {
    if (_requiredBool(terminal, 'alreadyClosed', label) != true) {
      throw StateError('$label.alreadyClosed must be true');
    }
    if (_requiredBool(terminal, 'removed', label) != true) {
      throw StateError('$label.removed must be true');
    }
  }
}

void _exactKeys(
  Map<String, dynamic> mapping,
  Set<String> expected,
  String label,
) {
  final actual = mapping.keys.toSet();
  if (actual.length != expected.length ||
      !actual.containsAll(expected) ||
      !expected.containsAll(actual)) {
    throw StateError(
      '$label fields differ: missing=${expected.difference(actual).toList()..sort()} '
      'extra=${actual.difference(expected).toList()..sort()}',
    );
  }
}

void _admitSearchResult(
  Object? value,
  String label, {
  required bool native,
  required bool introDeclared,
}) {
  final result = _map(value, label);
  for (final field in ['name', 'author', 'bookUrl']) {
    _requiredString(result, field, label);
  }
  if (introDeclared) {
    _requiredString(result, 'intro', label);
  } else if (result.containsKey('intro')) {
    throw StateError('$label.intro is not declared by the corpus');
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
  Map<String, dynamic> corpusEntry,
) {
  final searchFields = ['name', 'author', 'bookUrl'];
  if (_declaresRuleField(corpusEntry, 'ruleSearch', 'intro')) {
    searchFields.add('intro');
  }
  final bookInfoFields = ['name', 'author', 'bookUrl', 'tocUrl'];
  if (_declaresRuleField(corpusEntry, 'ruleBookInfo', 'intro')) {
    bookInfoFields.add('intro');
  }
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
    for (final field in searchFields) {
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
    for (final field in bookInfoFields) {
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
        pc['isVolume'] == true
            ? 'chapters[$index].absoluteUrl(vs url)'
            : 'chapters[$index].absoluteUrl(vs persistedAddress)',
        fc['absoluteUrl'],
        pc['isVolume'] == true ? pc['url'] : pc['persistedAddress'],
      );
      if (fc['isVolume'] == false) {
        final nativeAddress = fc['absoluteUrl'] as String;
        final boundary = sourceUrlOptionBoundaryOf(nativeAddress);
        final path = sourceKotlinTrim(
          boundary == null
              ? nativeAddress
              : nativeAddress.substring(0, boundary),
        );
        final target = Uri.parse(path);
        if (!target.hasScheme || target.host.isEmpty) {
          throw StateError(
            '$id.chapters[$index].absoluteUrl has no absolute target',
          );
        }
        for (final field in ['url', 'storeKey']) {
          _diff(
            differences,
            id,
            'chapters[$index].$field(vs native pre-option target)',
            '$target',
            pc[field],
          );
        }
      }
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
  _compareTitleLifecycle(differences, id, frozen, product);
}

/// Every declared lifecycle phase compared row by row, field by field.
///
/// A side that does not carry the field is a difference, not a skip: the
/// admission already refuses the undeclared case, so reaching here means both
/// sides declared it.
void _compareTitleLifecycle(
  List<Map<String, Object?>> differences,
  String id,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product,
) {
  final frozenLifecycle = frozen['titleLifecycle'];
  final productLifecycle = product['titleLifecycle'];
  if (frozenLifecycle == null || productLifecycle == null) {
    _diff(differences, id, 'titleLifecycle', frozenLifecycle, productLifecycle);
    return;
  }
  final f = _map(frozenLifecycle, '$id.titleLifecycle');
  final p = _map(productLifecycle, '$id.titleLifecycle');
  for (final phase in _titleLifecyclePhases) {
    final fRows = _requiredList(f, phase, '$id.titleLifecycle');
    final pRows = _requiredList(p, phase, '$id.titleLifecycle');
    _diff(
      differences,
      id,
      'titleLifecycle.$phase.length',
      fRows.length,
      pRows.length,
    );
    final count = fRows.length < pRows.length ? fRows.length : pRows.length;
    for (var index = 0; index < count; index++) {
      final fRow = _map(fRows[index], '$id.titleLifecycle.$phase[$index]');
      final pRow = _map(pRows[index], '$id.titleLifecycle.$phase[$index]');
      for (final field in ['index', 'title', 'variable']) {
        _diff(
          differences,
          id,
          'titleLifecycle.$phase[$index].$field',
          fRow[field],
          pRow[field],
        );
      }
    }
  }
}

String _expectedRawQuery(Map<String, dynamic> request) {
  final query = request['query'];
  if (query == null) return '';
  final map = _stringMap(query, 'expected.query');
  if (request.containsKey('rawQuery')) {
    return _requiredString(request, 'rawQuery', 'expected');
  }
  return map.entries
      .map(
        (entry) =>
            '${Uri.encodeQueryComponent(entry.key)}=${Uri.encodeQueryComponent(entry.value)}',
      )
      .join('&');
}

void _admitOperationSpans(
  List<Map<String, dynamic>> cases,
  List<Map<String, dynamic>> requests,
  List<Map<String, dynamic>> trace,
  String side,
  String origin, {
  required bool nativeSide,
}) {
  var requestCursor = 0;
  var traceCursor = 0;
  for (final record in cases) {
    final id = _requiredString(record, 'id', '$side.case');
    final terminal = _requiredString(record, 'terminal', '$side.case.$id');
    final expectedNames = switch (terminal) {
      'search-empty' => const ['search'],
      // The saved-name case runs the ordinary four stages and then a real
      // table-of-contents refresh, which is the same producer stage again.
      _titleLifecycleTerminal => const [
        'search',
        'bookInfo',
        'tableOfContents',
        'content',
        'tableOfContents',
      ],
      _ => const ['search', 'bookInfo', 'tableOfContents', 'content'],
    };
    final operations = _requiredList(record, 'operations', '$side.case.$id');
    if (operations.length != expectedNames.length) {
      throw StateError('$side.$id operation set differs for its terminal');
    }
    var previousRequest = -1;
    var previousTrace = -1;
    var firstRequest = -1;
    var lastRequest = -1;
    var firstTrace = -1;
    var lastTrace = -1;
    for (var index = 0; index < operations.length; index++) {
      final operation = _map(operations[index], '$side.$id.operations[$index]');
      final name = _requiredString(
        operation,
        'name',
        '$side.$id.operations[$index]',
      );
      if (name != expectedNames[index]) {
        throw StateError('$side.$id operation name is not the declared term');
      }
      if (_requiredString(
            operation,
            'outcome',
            '$side.$id.operations[$index]',
          ) !=
          'completed') {
        throw StateError('$side.$id operation did not complete');
      }
      final requestStart = _requiredInt(
        operation,
        'requestStart',
        '$side.$id.operations[$index]',
      );
      final requestEnd = _requiredInt(
        operation,
        'requestEnd',
        '$side.$id.operations[$index]',
      );
      final traceStart = _requiredInt(
        operation,
        'traceStart',
        '$side.$id.operations[$index]',
      );
      final traceEnd = _requiredInt(
        operation,
        'traceEnd',
        '$side.$id.operations[$index]',
      );
      if (requestStart < 0 ||
          requestEnd < requestStart ||
          requestEnd > requests.length ||
          traceStart < 0 ||
          traceEnd < traceStart ||
          traceEnd > trace.length) {
        throw StateError('$side.$id operation span is outside its producer');
      }
      if (nativeSide && requestEnd - requestStart != traceEnd - traceStart) {
        throw StateError(
          '$side.$id operation request/trace span count differs',
        );
      }
      if (nativeSide) {
        for (
          var requestIndex = requestStart;
          requestIndex < requestEnd;
          requestIndex++
        ) {
          final requestStage = _requiredString(
            requests[requestIndex],
            'stage',
            '$side.requests[$requestIndex]',
          );
          if (requestStage != name) {
            throw StateError(
              '$side.$id operation $name owns an unrelated request stage',
            );
          }
          final request = requests[requestIndex];
          final path = _requiredString(
            request,
            'path',
            '$side.requests[$requestIndex]',
          );
          final raw = _requiredString(
            request,
            'rawQuery',
            '$side.requests[$requestIndex]',
          );
          final traceEntry = trace[traceStart + (requestIndex - requestStart)];
          final traced = _requiredString(
            traceEntry,
            'path',
            '$side.trace[${traceStart + (requestIndex - requestStart)}]',
          );
          if (traced != '$origin$path${raw.isEmpty ? '' : '?$raw'}') {
            throw StateError(
              '$side.$id operation $name owns an unrelated request target',
            );
          }
        }
      }
      for (var traceIndex = traceStart; traceIndex < traceEnd; traceIndex++) {
        final stage = _requiredString(
          trace[traceIndex],
          'stage',
          '$side.trace[$traceIndex]',
        );
        if (stage != name) {
          throw StateError(
            '$side.$id operation $name owns an unrelated trace stage',
          );
        }
      }
      if (previousRequest >= 0 &&
          (requestStart != previousRequest || traceStart != previousTrace)) {
        throw StateError('$side.$id operation spans are not contiguous');
      }
      if (firstRequest < 0) {
        firstRequest = requestStart;
        firstTrace = traceStart;
        if (firstRequest != requestCursor || firstTrace != traceCursor) {
          throw StateError('$side.$id operation spans skip or overlap a case');
        }
      }
      previousRequest = requestEnd;
      previousTrace = traceEnd;
      lastRequest = requestEnd;
      lastTrace = traceEnd;
    }
    final caseRequests = _requiredList(
      record,
      'requests',
      '$side.$id.requests',
    );
    final expectedRequests = firstRequest == lastRequest
        ? const <Object?>[]
        : requests.sublist(firstRequest, lastRequest);
    if (!_deepEquals(caseRequests, expectedRequests)) {
      throw StateError('$side.$id request slice is not its operation span');
    }
    if (lastTrace < firstTrace || lastTrace > trace.length) {
      throw StateError('$side.$id trace span is outside the global trace');
    }
    requestCursor = lastRequest;
    traceCursor = lastTrace;
  }
  if (requestCursor != requests.length || traceCursor != trace.length) {
    throw StateError(
      '$side operation spans do not cover the producer sequences',
    );
  }
}

void _admitCausalRelationships(
  List<Map<String, Object?>> differences,
  String side,
  List<Map<String, dynamic>> requests,
  List<Map<String, dynamic>> cases,
  List<Map<String, dynamic>> trace,
  String origin,
) {
  final concatenated = <Map<String, dynamic>>[];
  for (final record in cases) {
    final slices = _requiredList(
      record,
      'requests',
      '$side.case.${record['id']}',
    );
    for (final value in slices) {
      concatenated.add(_map(value, '$side.case.${record['id']}.requests[]'));
    }
  }
  if (!_deepEquals(concatenated, requests)) {
    differences.add({
      'row': 'C2',
      'field': '$side.caseRequestSlices',
      'frozen': 'global request sequence',
      'liber': 'case slices do not reconstruct the global sequence',
    });
  }

  if (side == 'liber') {
    for (final record in cases) {
      final id = _requiredString(record, 'id', '$side.case');
      final operations = _requiredList(
        record,
        'operations',
        '$side.case.$id.operations',
      );
      for (var opIndex = 0; opIndex < operations.length; opIndex++) {
        final operation = _map(
          operations[opIndex],
          '$side.case.$id.operations[$opIndex]',
        );
        final requestStart = _requiredInt(
          operation,
          'requestStart',
          '$side.case.$id.operations[$opIndex]',
        );
        final requestEnd = _requiredInt(
          operation,
          'requestEnd',
          '$side.case.$id.operations[$opIndex]',
        );
        final traceStart = _requiredInt(
          operation,
          'traceStart',
          '$side.case.$id.operations[$opIndex]',
        );
        final traceEnd = _requiredInt(
          operation,
          'traceEnd',
          '$side.case.$id.operations[$opIndex]',
        );
        var cursor = requestStart;
        for (var traceIndex = traceStart; traceIndex < traceEnd; traceIndex++) {
          final path = _requiredString(
            trace[traceIndex],
            'path',
            '$side.trace[$traceIndex]',
          );
          var matched = -1;
          for (
            var requestIndex = cursor;
            requestIndex < requestEnd;
            requestIndex++
          ) {
            final request = requests[requestIndex];
            final requestPath = _requiredString(
              request,
              'path',
              '$side.request[$requestIndex]',
            );
            final raw = _requiredString(
              request,
              'rawQuery',
              '$side.request[$requestIndex]',
            );
            final candidates = <String>{
              requestPath,
              requestPath + (raw.isEmpty ? '' : '?$raw'),
              origin + requestPath + (raw.isEmpty ? '' : '?$raw'),
            };
            if (candidates.contains(path)) {
              matched = requestIndex;
              break;
            }
          }
          if (matched < 0) {
            differences.add({
              'row': 'C3',
              'field': '$side.trace[$traceIndex].path',
              'frozen': 'forward request context',
              'liber': path,
            });
            break;
          }
          cursor = matched;
        }
      }
    }
  }

  for (final record in cases) {
    final id = _requiredString(record, 'id', '$side.case');
    final slices = _requiredList(record, 'requests', '$side.case.$id.requests');
    if (slices.isEmpty) continue;
    final first = _map(slices.first, '$side.case.$id.requests[0]');
    final path = _requiredString(first, 'path', '$side.case.$id.requests[0]');
    final raw = _requiredString(
      first,
      'rawQuery',
      '$side.case.$id.requests[0]',
    );
    final candidates = <String>{
      path,
      path + (raw.isEmpty ? '' : '?$raw'),
      origin + path + (raw.isEmpty ? '' : '?$raw'),
    };
    final traced = trace.any(
      (entry) => entry['path'] is String && candidates.contains(entry['path']),
    );
    if (!traced) {
      differences.add({
        'row': 'C3',
        'field': '$side.trace.case.$id',
        'frozen': 'case search request traced',
        'liber': 'missing case trace evidence',
      });
    }
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
    final expectedRawQuery = _expectedRawQuery(wanted);
    if (actual['rawQuery'] != expectedRawQuery) {
      differences.add({
        'row': 'C2',
        'field': '$side.requests[$index].rawQuery',
        'frozen': expectedRawQuery,
        'liber': actual['rawQuery'],
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
    final stage = _requiredString(entry, 'stage', '$label[$index]');
    if (!const {
      'search',
      'bookInfo',
      'tableOfContents',
      'content',
    }.contains(stage)) {
      throw StateError('$label[$index].stage is not a producer stage');
    }
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
      !ids.toSet().containsAll(declared) ||
      !_deepEquals(ids, declared)) {
    throw StateError('$side case ids are not the declared chronological set');
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

int _requiredInt(Map<String, dynamic> map, String key, String label) {
  final value = _present(map, key, label);
  if (value is! int) throw StateError('$label.$key must be an integer');
  return value;
}

bool _requiredBool(Map<String, dynamic> map, String key, String label) {
  final value = _present(map, key, label);
  if (value is! bool) throw StateError('$label.$key must be boolean');
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
