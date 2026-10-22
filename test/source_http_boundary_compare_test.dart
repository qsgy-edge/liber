import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import '../tool/http_boundary/compare.dart';
import '../tool/http_boundary/runner.dart'
    show
        httpBoundaryDeclaredRequests,
        httpBoundaryStructuralOf,
        loadHttpBoundaryCorpus,
        validateHttpBoundaryCorpus;

/// Focused checks of the HTTP-BOUNDARY-01 comparer's own rules. They run on
/// small synthetic records and on the committed corpus; no controller capture
/// is needed, so the comparison rules can be reviewed and regressed without the
/// device evidence.
Map<String, Object?> _corpus() => {
  'fixtureId': 'HTTP-BOUNDARY-01',
  'corpusVersion': 2,
  'baselineCommit': 'b',
  'origins': {'replay': 'http://127.0.0.1:18771'},
  'target': {
    'package': 'io.legado.app.debug',
    'apkSha256': 'a' * 64,
    'baselineCommit': 'b',
    'manifest': 'm',
  },
  'sources': [
    {
      'id': 'H1',
      'bookSource': {'bookSourceUrl': 'http://127.0.0.1:18771/h1'},
    },
  ],
  'books': [
    {
      'id': 'book-1',
      'source': 'S',
      'bookUrl': 'http://127.0.0.1:18771/s/book/1',
    },
  ],
  'responses': [
    {
      'id': 'h1-single',
      'method': 'GET',
      'path': '/h1/single',
      'rawQuery': '',
      'status': 200,
      'body': 'SINGLE',
    },
    {
      'id': 's-book-1',
      'method': 'GET',
      'path': '/s/book/1',
      'rawQuery': '',
      'status': 200,
      'body': '<html></html>',
    },
    {
      'id': 's-book-1-toc2',
      'method': 'GET',
      'path': '/s/book/1/toc2',
      'rawQuery': '',
      'status': 200,
      'body': '',
      'cohort': 'stage.toc-tail',
    },
    {
      'id': 's-book-1-toc3',
      'method': 'GET',
      'path': '/s/book/1/toc3',
      'rawQuery': '',
      'status': 200,
      'body': '',
      'cohort': 'stage.toc-tail',
    },
  ],
  'steps': [
    {
      'id': 'helper.ajax',
      'kind': 'helper',
      'family': 'helper',
      'source': 'H1',
      'action': 'ajax',
      'requests': {
        'ordered': ['h1-single'],
      },
      'requiredHeaders': {
        'user-agent': 'HTTP-BOUNDARY-01/1.0',
        'x-declared': 'h1',
      },
      'expectedOutcome': 'ok',
    },
    {
      'id': 's1.details',
      'kind': 'stage',
      'family': 'stage',
      'stage': 'details',
      'source': 'S',
      'book': 'book-1',
      'requests': {
        'ordered': ['s-book-1'],
      },
      'requiredHeaders': {'user-agent': 'HTTP-BOUNDARY-01/1.0'},
      'expectedOutcome': 'ok',
    },
    {
      'id': 's1.toc',
      'kind': 'stage',
      'family': 'stage',
      'stage': 'toc',
      'source': 'S',
      'book': 'book-1',
      'requests': {
        'ordered': [],
        'batch': {
          'cohort': 'stage.toc-tail',
          'members': ['s-book-1-toc2', 's-book-1-toc3'],
        },
      },
      'expectedOutcome': 'ok',
    },
  ],
};

Map<String, Object?> _request({
  required String owner,
  required String selector,
  String method = 'GET',
  String path = '/h1/single',
  String rawQuery = '',
  int attempt = 1,
  String attemptKind = 'initial',
  Map<String, Object?>? headers,
  int status = 200,
  String terminal = 'responded',
  String? declaredResponse = 'h1-single',
  String? cohort,
}) => {
  'owner': owner,
  'family': 'helper',
  'cohort': cohort,
  'attempt': attempt,
  'attemptKind': attemptKind,
  'selector': selector,
  'method': method,
  'path': path,
  'target': rawQuery.isEmpty ? path : '$path?$rawQuery',
  'rawQuery': rawQuery,
  'query': rawQuery.isEmpty ? <String, Object?>{} : {'k': 'v'},
  'headers':
      headers ??
      <String, Object?>{
        'user-agent': 'HTTP-BOUNDARY-01/1.0',
        'x-declared': 'h1',
      },
  'body': '',
  'bodyLength': 0,
  'bodySha256':
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
  'status': status,
  'terminal': terminal,
  'declaredResponse': declaredResponse,
  'outcome': terminal,
};

Map<String, Object?> _report() {
  final request = _request(owner: 'helper.ajax', selector: 'GET /h1/single?');
  final details = _request(
    owner: 's1.details',
    selector: 'GET /s/book/1?',
    path: '/s/book/1',
    declaredResponse: 's-book-1',
  );
  final toc2 = _request(
    owner: 's1.toc',
    selector: 'GET /s/book/1/toc2?',
    path: '/s/book/1/toc2',
    declaredResponse: 's-book-1-toc2',
    cohort: 'stage.toc-tail',
  );
  final toc3 = _request(
    owner: 's1.toc',
    selector: 'GET /s/book/1/toc3?',
    path: '/s/book/1/toc3',
    declaredResponse: 's-book-1-toc3',
    cohort: 'stage.toc-tail',
  );
  return {
    'fixtureId': 'HTTP-BOUNDARY-01',
    'corpusVersion': 2,
    'baselineCommit': 'b',
    'promotable': true,
    'terminalIntegrityOk': true,
    'negativeMode': false,
    'negative': null,
    'identity': {
      'corpusSha256Lf': 'c' * 64,
      'corpusVersion': 2,
      'corpusAssetSha256': 'a' * 64,
      'corpusRawLineEndings': 'crlf',
      'targetPackage': 'io.legado.app.debug',
      'targetApkSha256': 'a' * 64,
      'targetBaselineCommit': 'b',
    },
    'runtimeConfiguration': {'threadCount': 16, 'resolved': true},
    'failEndpoint': {'acceptedConnections': 1, 'transportReconnects': 0},
    'inventory': {
      'databaseOpened': true,
      'initial': {'books': 0},
      'final': {'books': 0},
    },
    'requestCheck': {'match': true},
    'observationCheck': {'match': true},
    'cleanup': {
      'listenerClosed': true,
      'failEndpointClosed': true,
      'nativeLibraryDisposed': true,
      'databaseClosed': true,
      'scratchRemoved': true,
      'rootAbsentAfter': true,
      'terminal': {'integrityOk': true},
    },
    'requests': [request, details, toc2, toc3],
    'observations': [
      {
        'id': 'helper.ajax',
        'outcome': 'ok',
        'category': null,
        'value': {'kind': 'helper', 'action': 'ajax', 'result': 'SINGLE'},
      },
      {
        'id': 's1.details',
        'outcome': 'ok',
        'category': null,
        'value': {
          'kind': 'stage',
          'name': 'B1',
          'origin': 'http://127.0.0.1:18771/s',
          'tocUrl': 'http://127.0.0.1:18771/s/book/1/toc',
        },
      },
      {
        'id': 's1.toc',
        'outcome': 'ok',
        'category': null,
        'value': {
          'kind': 'stage',
          'chapters': [
            {'index': 0, 'title': 'c1', 'url': 'u1', 'tag': ''},
          ],
          'batch': {
            'cohort': 'stage.toc-tail',
            'cohortSize': 2,
            'cohortComplete': true,
            'releaseReason': 'complete',
            'inFlightPeak': 2,
            'membership': ['GET /s/book/1/toc2?', 'GET /s/book/1/toc3?'],
            'threadCount': 16,
          },
        },
      },
    ],
  };
}

Map<String, Object?> _product() {
  final product = (jsonDecode(jsonEncode(_report())) as Map)
      .cast<String, Object?>();
  // The product identity is the same pins in the product's own shape.
  product['identity'] = {
    'corpusSha256Lf': 'c' * 64,
    'corpusVersion': 2,
    'target': {
      'package': 'io.legado.app.debug',
      'apkSha256': 'a' * 64,
      'baselineCommit': 'b',
    },
  };
  product['runtimeConfiguration'] = {'threadCount': 16, 'resolved': true};
  return product;
}

HttpBoundaryComparison _compare(
  Map<String, Object?> golden,
  Map<String, Object?> product,
) => compareHttpBoundaryRecords(
  golden: golden.cast<String, dynamic>(),
  product: product.cast<String, dynamic>(),
  corpus: _corpus().cast<String, dynamic>(),
  goldenId: 'synthetic',
);

void main() {
  test('identical records have no difference', () {
    final golden = _report();
    final product = _product();
    expect(_compare(golden, product).mismatches, isEmpty);
  });

  test('a changed observation value reports its own field path', () {
    final product = _product();
    ((product['observations'] as List).first as Map)['value']['result'] =
        'OTHER';
    final comparison = _compare(_report(), product);
    expect(comparison.mismatches, hasLength(1));
    expect(comparison.mismatches.single.surface, 'observation');
    expect(comparison.mismatches.single.field, 'value.result');
  });

  test('an absent field is a presence difference, not a null', () {
    final product = _product();
    ((product['observations'] as List)[1] as Map)['value'].remove('origin');
    final comparison = _compare(_report(), product);
    expect(comparison.mismatches.single.kind, 'missing-observed-field');
    expect(comparison.mismatches.single.field, 'value.origin');
  });

  test('an added field is a difference too', () {
    final product = _product();
    ((product['observations'] as List)[1] as Map)['value']['extra'] = 1;
    final comparison = _compare(_report(), product);
    expect(comparison.mismatches.single.kind, 'extra-observed-field');
  });

  test('the raw query bytes are compared exactly', () {
    final product = _product();
    final details = (product['requests'] as List)[1] as Map;
    // The same row, a re-encoded query: the bytes and the target differ.
    details['rawQuery'] = 'k=%76';
    final comparison = _compare(_report(), product);
    expect(
      comparison.mismatches.map((mismatch) => mismatch.field),
      contains('rawQuery'),
    );
    // A changed selector is a different row: the declared one is missing and
    // this one is extra, which is the strictest form of the same difference.
    final moved = _product();
    final row = (moved['requests'] as List)[1] as Map;
    row['selector'] = 'GET /s/book/1?k=%76';
    row['rawQuery'] = 'k=%76';
    row['target'] = '/s/book/1?k=%76';
    final kinds = _compare(
      _report(),
      moved,
    ).mismatches.map((mismatch) => mismatch.kind);
    expect(kinds, containsAll(['missing-request', 'extra-request']));
  });

  test('a declared batch is a multiset and a causal row is its own key', () {
    final product = _product();
    final rows = (product['requests'] as List).cast<Map>();
    // Swapping the two declared batch members is not a difference.
    final third = rows[2];
    rows[2] = rows[3];
    rows[3] = third;
    expect(_compare(_report(), product).mismatches, isEmpty);
    // A different attempt is a different causal row.
    final moved = _product();
    final row = (moved['requests'] as List)[1] as Map;
    row['attempt'] = 2;
    final kinds = _compare(
      _report(),
      moved,
    ).mismatches.map((mismatch) => mismatch.kind);
    expect(kinds, containsAll(['missing-request', 'extra-request']));
  });

  test('platform headers are ignored and a source header change is not', () {
    final product = _product();
    final helper = (product['requests'] as List).first as Map;
    (helper['headers'] as Map)['host'] = '127.0.0.1:18771';
    expect(_compare(_report(), product).mismatches, isEmpty);
    (helper['headers'] as Map)['user-agent'] = 'OTHER-UA/9.9';
    final comparison = _compare(_report(), product);
    expect(comparison.mismatches.single.field, 'headers');
  });

  test('a request row the corpus does not declare is an extra request', () {
    final product = _product();
    (product['requests'] as List).add(
      _request(
        owner: 'helper.ajax',
        selector: 'GET /h1/undeclared?',
        path: '/h1/undeclared',
        declaredResponse: null,
        status: 404,
      ),
    );
    final comparison = _compare(_report(), product);
    expect(
      comparison.mismatches.map((mismatch) => mismatch.kind),
      contains('extra-request'),
    );
  });

  test('a product receipt that is not true is a difference', () {
    final product = _product();
    (product['cleanup'] as Map)['scratchRemoved'] = false;
    final comparison = _compare(_report(), product);
    expect(
      comparison.mismatches.map((mismatch) => mismatch.surface),
      contains('receipt'),
    );
  });

  test(
    'a capture receipt that is not true is a native-provenance difference',
    () {
      final golden = _report()..['terminalIntegrityOk'] = false;
      final comparison = _compare(golden, _product());
      expect(
        comparison.mismatches.map((mismatch) => mismatch.surface),
        contains('native-receipt'),
      );
    },
  );

  test('a rate record epoch value is compared only through its relations', () {
    final mismatches = <HttpBoundaryMismatch>[];
    Map<String, Object?> rate(int time, int frequency) => {
      'kind': 'rate',
      'index': 2,
      'recordAfter': {
        'isConcurrent': true,
        'time': time,
        'frequency': frequency,
      },
      'sameWindowAsPrevious': true,
      'scheduleComplete': true,
      'scheduleReason': null,
    };
    compareValue(
      expected: rate(1000, 2),
      observed: rate(999999, 2),
      row: 'rate.record.2',
      field: 'value',
      into: mismatches,
    );
    expect(mismatches, isEmpty);
    compareValue(
      expected: rate(1000, 2),
      observed: rate(999999, 3),
      row: 'rate.record.2',
      field: 'value',
      into: mismatches,
    );
    expect(mismatches.single.field, 'value.recordAfter.frequency');
  });

  test('the comparer controls introduce a new key on their own baseline', () {
    final golden = _report();
    final product = _product();
    final baseline = _compare(golden, product);
    final controls = runHttpBoundaryControls(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: _corpus().cast<String, dynamic>(),
      goldenId: 'synthetic',
      baseline: baseline,
    );
    expect(controls, isNotEmpty);
    // A control may be not-applicable on a record that does not carry the row it
    // targets; every applied one must add its own mismatch key.
    for (final control in controls.where((control) => control.applied)) {
      expect(
        control.newKeys,
        isNotEmpty,
        reason: '${control.id} changed ${control.target} without a difference',
      );
    }
    // The originals are untouched: the same comparison still passes.
    expect(_compare(golden, product).mismatches, isEmpty);
  });

  test('the committed corpus derives the declared structural model', () {
    final corpus = loadHttpBoundaryCorpus();
    final derived = httpBoundaryStructuralOf(corpus);
    expect(derived['observations'], 22);
    expect(derived['requests'], 31);
    expect(derived['responses'], 29);
    expect(derived['helperSelectors'], 12);
    expect(derived['rateSelectors'], 3);
    expect(derived['stageSelectors'], 14);
    expect(derived['stageRequests'], 16);
    expect(derived['requestsExceedingSelectors'], 2);
    final declared = (corpus['structural'] as Map).cast<String, dynamic>();
    for (final entry in derived.entries) {
      if (entry.key == 'requestsExceedingSelectorsReason') continue;
      expect(jsonEncode(entry.value), jsonEncode(declared[entry.key]));
    }
    // Every declared selector has exactly one causal owner, and the retry row is
    // the only place a selector repeats.
    final steps = (corpus['steps'] as List).cast<Map>();
    final repeated = [
      for (final step in steps)
        if (httpBoundaryDeclaredRequests(
              step.cast<String, dynamic>(),
            ).ordered.toSet().length !=
            httpBoundaryDeclaredRequests(
              step.cast<String, dynamic>(),
            ).ordered.length)
          '${step['id']}',
    ];
    expect(repeated, ['s2.retry-non2xx']);
  });

  test(
    'a corpus whose declared model disagrees with its declarations is refused',
    () {
      final corpus = (jsonDecode(jsonEncode(loadHttpBoundaryCorpus())) as Map)
          .cast<String, dynamic>();
      (corpus['structural'] as Map)['requests'] = 30;
      expect(
        () => validateHttpBoundaryCorpus(corpus),
        throwsA(isA<FormatException>()),
      );
    },
  );

  test('a corpus source without the declared user agent is refused', () {
    final corpus = (jsonDecode(jsonEncode(loadHttpBoundaryCorpus())) as Map)
        .cast<String, dynamic>();
    final source =
        ((corpus['sources'] as List).first as Map)['bookSource'] as Map;
    source['header'] = '{"X-Declared": "h1"}';
    expect(
      () => validateHttpBoundaryCorpus(corpus),
      throwsA(isA<FormatException>()),
    );
  });
}
