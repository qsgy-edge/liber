import 'dart:convert';
import 'dart:io';

/// Compares the frozen SLICE-01 golden against the committed Liber-side
/// observation, row by row, following `docs/compatibility/first-slice.md`.
///
/// The golden is executed evidence from the installed, hash-pinned frozen APK and
/// is never rewritten here. A row passes only when both sides observed the same
/// thing; an unequal row is reported as `fail` with the divergence named, and an
/// observation one side does not carry is named in `notCompared` with its reason —
/// never dropped and never normalized into a pass.
///
/// Usage: `dart run tool/first_slice_compare.dart <golden.json> <liber.json> <report.json>`
void main(List<String> args) {
  if (args.length != 3) {
    throw ArgumentError('Usage: <golden.json> <liber.json> <report.json>');
  }
  final golden =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  final liber =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  final corpus =
      jsonDecode(File('tool/first_slice/fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final output = File(args[2]);
  if (output.existsSync()) {
    throw StateError('Refusing to overwrite a report: ${args[2]}');
  }

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
    throw StateError('Golden recorded an analysis failure: ${golden['analysisFailure']}');
  }

  final rows = <Map<String, Object?>>[];
  final notCompared = <Map<String, Object?>>[];
  final divergences = <Map<String, Object?>>[];

  void row(String id, String title, List<Object?> differences, String detail) {
    if (differences.isNotEmpty) {
      divergences.addAll([
        for (final difference in differences)
          {'row': id, ...(difference as Map).cast<String, Object?>()},
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

  // R2 — request trace: method, resolved URL, raw query bytes, order, and which
  // stage issued each request.
  final goldenTrace = _requests(golden);
  final liberTrace = _requests(liber);
  final traceDifferences = <Map<String, Object?>>[];
  if (goldenTrace.length != liberTrace.length) {
    traceDifferences.add({
      'observation': 'requests.length',
      'frozen': goldenTrace.length,
      'liber': liberTrace.length,
    });
  }
  for (var index = 0; index < goldenTrace.length && index < liberTrace.length; index++) {
    for (final field in ['method', 'path', 'rawQuery']) {
      if (goldenTrace[index][field] != liberTrace[index][field]) {
        traceDifferences.add({
          'observation': 'requests[$index].$field',
          'frozen': goldenTrace[index][field],
          'liber': liberTrace[index][field],
        });
      }
    }
    if (jsonEncode(goldenTrace[index]['query']) !=
        jsonEncode(liberTrace[index]['query'])) {
      traceDifferences.add({
        'observation': 'requests[$index].query',
        'frozen': goldenTrace[index]['query'],
        'liber': liberTrace[index]['query'],
      });
    }
  }
  if (jsonEncode(_stageTrace(golden)) != jsonEncode(_stageTrace(liber))) {
    traceDifferences.add({
      'observation': 'stageTrace',
      'frozen': _stageTrace(golden),
      'liber': _stageTrace(liber),
    });
  }
  row(
    'R2',
    'request trace: method, resolved URL, raw query bytes, order, stage',
    traceDifferences,
    '${goldenTrace.length} requests on both sides',
  );

  // R3 — source-controlled headers and the injected request defaults.
  final headerDifferences = <Map<String, Object?>>[];
  for (var index = 0; index < goldenTrace.length && index < liberTrace.length; index++) {
    final frozen = (goldenTrace[index]['headers'] as Map).cast<String, Object?>();
    final product = (liberTrace[index]['headers'] as Map).cast<String, Object?>();
    final names = {...frozen.keys, ...product.keys}.toList()..sort();
    for (final name in names) {
      if (frozen[name] != product[name]) {
        headerDifferences.add({
          'observation': 'requests[$index].headers.$name',
          'frozen': frozen[name],
          'liber': product[name],
        });
      }
    }
  }
  row(
    'R3',
    'source-controlled headers and injected request defaults',
    headerDifferences,
    'every header on every request compared, values included',
  );

  // R4 — session cookie: Set-Cookie on search, Cookie on the five later requests.
  final cookieName = '${(corpus['sessionCookie'] as Map)['name']}='
      '${(corpus['sessionCookie'] as Map)['value']}';
  final goldenCookie = _cookieCarriage(golden, cookieName);
  final liberCookie = _cookieCarriage(liber, cookieName);
  final cookieDifferences = <Map<String, Object?>>[];
  if (jsonEncode(goldenCookie) != jsonEncode(liberCookie)) {
    cookieDifferences.add({
      'observation': 'cookie carriage per request',
      'frozen': goldenCookie,
      'liber': liberCookie,
    });
  }
  row(
    'R4',
    'session cookie set on search and carried by the five later requests',
    cookieDifferences,
    '$cookieName: ${liberCookie.where((carried) => carried == true).length} of '
        '${liberCookie.length} requests carry it on both sides',
  );

  // R5 — search output: ordered results, name/author/kind/book URL.
  final goldenSearch = _stage(golden, 'search');
  final liberSearch = _stage(liber, 'search');
  row(
    'R5',
    'search output: ordered results, name/author/kind/book URL',
    _differences('search', goldenSearch, liberSearch),
    '${(liberSearch['results'] as List?)?.length ?? 0} results compared in order',
  );

  // R6 — book information output. The compared field set is the one both
  // evidence shapes carry; a field only the golden carries is named below.
  const bookInfoFields = ['name', 'author', 'kind', 'lastChapter', 'cover', 'intro'];
  final goldenInfo = _stage(golden, 'bookInfo');
  final liberInfo = _stage(liber, 'bookInfo');
  row(
    'R6',
    'book information output: name/author/kind/last chapter/cover/intro',
    _differences(
      'bookInfo',
      {for (final field in bookInfoFields) field: goldenInfo[field]},
      {for (final field in bookInfoFields) field: liberInfo[field]},
    ),
    '${bookInfoFields.length} shared fields compared',
  );

  // R7 — table of contents: order, chapter URLs, nextTocUrl pages.
  final goldenToc = _stage(golden, 'toc');
  final liberToc = _stage(liber, 'toc');
  final tocDifferences = <Map<String, Object?>>[];
  if (goldenToc['pages'] != liberToc['pages']) {
    tocDifferences.add({
      'observation': 'toc.pages',
      'frozen': goldenToc['pages'],
      'liber': liberToc['pages'],
    });
  }
  final goldenChapters = (goldenToc['chaptersAbsolute'] as List?) ?? const [];
  final liberChapters = ((liberToc['chapters'] as List?) ?? const [])
      .cast<Map>()
      .toList();
  if (goldenChapters.length != liberChapters.length) {
    tocDifferences.add({
      'observation': 'toc.chapters.length',
      'frozen': goldenChapters.length,
      'liber': liberChapters.length,
    });
  }
  for (var index = 0;
      index < goldenChapters.length && index < liberChapters.length;
      index++) {
    final frozenChapter = (goldenToc['chapters'] as List)[index] as Map;
    if (frozenChapter['name'] != liberChapters[index]['name']) {
      tocDifferences.add({
        'observation': 'toc.chapters[$index].name',
        'frozen': frozenChapter['name'],
        'liber': liberChapters[index]['name'],
      });
    }
    if (goldenChapters[index] != liberChapters[index]['url']) {
      tocDifferences.add({
        'observation': 'toc.chapters[$index].url (resolved)',
        'frozen': goldenChapters[index],
        'liber': liberChapters[index]['url'],
      });
    }
  }
  row(
    'R7',
    'table of contents: order, chapter URLs, nextTocUrl pages',
    tocDifferences,
    '${goldenChapters.length} chapters over ${goldenToc['pages']} pages on both sides',
  );

  // R8 — content: page chain, replaceRegex, final text.
  final goldenContent = _stage(golden, 'content');
  final liberContent = _stage(liber, 'content');
  final contentDifferences = <Map<String, Object?>>[];
  for (final field in ['chapter', 'pages', 'text']) {
    if (goldenContent[field] != liberContent[field]) {
      contentDifferences.add({
        'observation': 'content.$field',
        'frozen': goldenContent[field],
        'liber': liberContent[field],
      });
    }
  }
  final stripped = _withoutParagraphIndent('${goldenContent['text']}');
  row(
    'R8',
    'content: page chain, replaceRegex, final text',
    contentDifferences,
    stripped == liberContent['text']
        ? 'the two texts are equal once the frozen reader\'s paragraph indent is '
            'removed from the frozen side; the row still fails as observed'
        : 'the two texts differ by more than the paragraph indent',
  );

  // R9 — the scenario's declared request sequence, and no undeclared request.
  final scenarioDifferences = <Map<String, Object?>>[];
  for (final side in [
    {'name': 'frozen', 'evidence': golden},
    {'name': 'liber', 'evidence': liber},
  ]) {
    final evidence = side['evidence'] as Map<String, dynamic>;
    final unmatched = (evidence['unmatchedRequests'] as List?)?.length ?? 0;
    if (unmatched != 0) {
      scenarioDifferences.add({
        'observation': '${side['name']}.unmatchedRequests',
        'frozen': null,
        'liber': unmatched,
      });
    }
    final mismatch = _sequenceMismatch(corpus, _requests(evidence));
    if (mismatch != null) {
      scenarioDifferences.add({
        'observation': '${side['name']}.request sequence',
        'frozen': null,
        'liber': mismatch,
      });
    }
  }
  row(
    'R9',
    "the scenario's declared request sequence, and no undeclared request",
    scenarioDifferences,
    '${(corpus['expectedRequests'] as List).length} declared requests matched on both sides',
  );

  // Observations one side does not carry. Naming them is the point: none of
  // them is silently dropped, and none of them is allowed to turn a row green.
  notCompared.addAll([
    {
      'observation': 'stages.bookInfo.tocUrl',
      'reason': 'the golden carries the resolved TOC URL the frozen entity holds; '
          "the product's book-information evidence shape does not record it. The "
          'chapters it leads to are compared by R7, and the TOC request is in R2.',
    },
    {
      'observation': 'stages.toc.chapters[].url (as stored)',
      'reason': 'the frozen entity stores the raw rule output (a relative path) and '
          'resolves it when used; the product stores the resolved URL. The resolved '
          'values are what R7 compares (chaptersAbsolute against the Liber url), and '
          'the request trace shows both sides resolving to the same URLs.',
    },
    {
      'observation': 'state.*, cleanup.*, serverErrors',
      'reason': 'frozen-side observations with no counterpart in the Liber evidence: '
          'state repeats what R4/R7/R8 compare, and cleanup is this harness\'s own '
          'teardown.',
    },
    {
      'observation': 'platform, fingerprint, recordedAt',
      'reason': 'provenance of the two runs, recorded in each evidence file and its '
          'manifest; not a compatibility observation.',
    },
  ]);

  final failures = rows.where((entry) => entry['status'] == 'fail').toList();
  final report = <String, Object?>{
    'comparison': 'SLICE-01',
    'golden': args[0],
    'liber': args[1],
    'goldenPlatform': golden['platform'],
    'goldenFingerprint': golden['fingerprint'],
    'corpus': 'tool/first_slice/fixtures.json',
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
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
  if (failures.isNotEmpty) {
    stderr.writeln(
      'rows that did not pass: ${failures.map((entry) => entry['id']).join(', ')}',
    );
    exitCode = 1;
  }
}

List<Map<String, Object?>> _requests(Map<String, dynamic> evidence) => [
  for (final request in (evidence['requests'] as List).cast<Map>())
    request.cast<String, Object?>(),
];

List<Map<String, Object?>> _stageTrace(Map<String, dynamic> evidence) => [
  for (final entry in (evidence['stageTrace'] as List).cast<Map>())
    entry.cast<String, Object?>(),
];

Map<String, dynamic> _stage(Map<String, dynamic> evidence, String name) =>
    ((evidence['stages'] as Map)[name] as Map).cast<String, dynamic>();

/// Which requests carry the corpus' session cookie, in request order.
List<Object?> _cookieCarriage(Map<String, dynamic> evidence, String pair) => [
  for (final request in _requests(evidence))
    '${((request['headers'] as Map)['cookie'] ?? '')}'.contains(pair),
];

/// The frozen reader indents every paragraph with `ReadBookConfig.paragraphIndent`
/// (`ContentProcessor.kt:199`), two full-width spaces by default. This strips that
/// prefix per line so the two texts can be compared beyond it — the row's verdict
/// is unaffected.
String _withoutParagraphIndent(String text) => text
    .split('\n')
    .map((line) => line.startsWith('　　') ? line.substring(2) : line)
    .join('\n');

List<Object?> _differences(
  String prefix,
  Map<String, dynamic> frozen,
  Map<String, dynamic> product,
) {
  final differences = <Object?>[];
  final keys = {...frozen.keys, ...product.keys}.toList()..sort();
  for (final key in keys) {
    if (jsonEncode(frozen[key]) != jsonEncode(product[key])) {
      differences.add({
        'observation': '$prefix.$key',
        'frozen': frozen[key],
        'liber': product[key],
      });
    }
  }
  return differences;
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
        !wantQuery.entries.every((entry) => gotQuery[entry.key] == entry.value)) {
      return 'request $index is ${got['method']} ${got['path']} ${jsonEncode(gotQuery)}';
    }
  }
  return null;
}
