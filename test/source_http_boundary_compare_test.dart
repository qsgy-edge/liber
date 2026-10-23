import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/http_boundary/compare.dart';
import '../tool/http_boundary/runner.dart'
    show
        HttpBoundaryRefusal,
        httpBoundaryDeclaredRequests,
        httpBoundaryStructuralOf,
        httpBoundaryResponseOwners,
        httpBoundaryResponses,
        httpBoundarySelectorOf,
        httpBoundarySteps,
        httpBoundaryCorpusPath,
        httpBoundaryCorpusSha256Lf,
        probeOwnedReplayListener,
        settleOwnedTeardown,
        sha256Text,
        httpBoundaryObservationIds,
        loadHttpBoundaryCorpus,
        sha256File,
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
  'structural': {'observations': 3},
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
    'status': 'ok',
    'terminalIntegrityOk': true,
    'structural': {'match': true},
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
      // The frozen record keeps the target pin flat; the product keeps the same
      // three facts in a nested object. A fixture that stands in for both
      // carries both spellings of the identical pin.
      'target': {
        'package': 'io.legado.app.debug',
        'apkSha256': 'a' * 64,
        'baselineCommit': 'b',
      },
    },
    'runtimeConfiguration': {'threadCount': 16, 'resolved': true},
    'failEndpoint': {
      'acceptedConnections': 1,
      'transportReconnects': 0,
      // The separate connection trace is compared, so the fixture carries the
      // declared failure request's own measured attempt.
      'connections': [
        {
          'index': 1,
          'method': 'GET',
          'target': '/f/search?keyword=fail&page=1',
          'path': '/f/search',
          'rawQuery': 'keyword=fail&page=1',
          'headers': {
            'x-declared': 'f',
            'user-agent': 'HTTP-BOUNDARY-01/1.0',
            'host': '127.0.0.1:34545',
          },
          'classification': 'initial',
          'requestObserved': true,
          'terminal': 'accepted-and-closed-without-response',
        },
      ],
    },
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
    'unmatchedRequests': <Object?>[],
    'serverErrors': <Object?>[],
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

/// A record whose only step is the corpus' 3-member ordering cohort, so the
/// cohort-peak control has a baseline fact to corrupt.
Map<String, Object?> _batchReport() {
  final report = _report();
  final rows = <Map<String, Object?>>[
    for (final index in const [1, 2, 3])
      _request(
        owner: 'helper.ajaxAll-order',
        selector: 'GET /h1/order/$index?',
        path: '/h1/order/$index',
        declaredResponse: 'h1-order-$index',
        cohort: 'helper.order',
      ),
  ];
  report['requests'] = rows;
  report['observations'] = [
    {
      'id': 'helper.ajaxAll-order',
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'helper',
        'action': 'ajaxAll',
        'result': 'O1|O2|O3',
        'batch': {
          'cohort': 'helper.order',
          'cohortSize': 3,
          'cohortTimeoutMs': 5000,
          'entered': true,
          'cohortComplete': true,
          'releaseReason': 'complete',
          'inFlightPeak': 3,
          'membership': [
            'GET /h1/order/1?',
            'GET /h1/order/2?',
            'GET /h1/order/3?',
          ],
          'threadCount': 16,
        },
      },
      'requests': rows,
    },
  ];
  return report;
}

Map<String, Object?> relic(Map<String, Object?> report) =>
    (jsonDecode(jsonEncode(report)) as Map).cast<String, Object?>();

/// A record whose only step is the corpus' repeated-selector retry row.
Map<String, Object?> _retryReport() {
  final report = _report();
  final rows = <Map<String, Object?>>[
    for (var attempt = 1; attempt <= 3; attempt++)
      _request(
        owner: 's2.retry-non2xx',
        selector: 'GET /s/search?keyword=b4&page=1',
        path: '/s/search',
        rawQuery: 'keyword=b4&page=1',
        attempt: attempt,
        attemptKind: attempt == 1 ? 'initial' : 'source-status-retry',
        declaredResponse: 's-search-b4',
        status: 502,
      ),
  ];
  report['requests'] = rows;
  report['observations'] = [
    {
      'id': 's2.retry-non2xx',
      'outcome': 'ok',
      'category': null,
      'value': {'kind': 'stage', 'stage': 'search'},
      'requests': rows,
    },
  ];
  return report;
}

/// A record with two sequential single-request steps.
Map<String, Object?> _sequentialReport() {
  final report = _report();
  final first = _request(owner: 'helper.ajax', selector: 'GET /h1/single?');
  final second = _request(
    owner: 'helper.ajax-list-first',
    selector: 'GET /h1/first?',
    path: '/h1/first',
    declaredResponse: 'h1-first',
  );
  report['requests'] = [first, second];
  report['observations'] = [
    {
      'id': 'helper.ajax',
      'outcome': 'ok',
      'category': null,
      'value': {'kind': 'helper', 'action': 'ajax', 'result': 'SINGLE'},
      'requests': [first],
    },
    {
      'id': 'helper.ajax-list-first',
      'outcome': 'ok',
      'category': null,
      'value': {'kind': 'helper', 'action': 'ajaxList', 'result': 'FIRST'},
      'requests': [second],
    },
  ];
  return report;
}

// --- the product-record gate's own public boundary ---------------------------

/// A legitimate product record built from the committed corpus: every declared
/// request, observation, receipt and relation the exported validator checks, so
/// a mutation of one fact is what a test asserts, not the fixture's arithmetic.
/// The runner and library identities are bound to real files (the committed
/// runner and a temp library), which is the artifact setup the gate requires.
Map<String, dynamic> _validProduct({
  required String libraryPath,
  required String librarySha,
}) {
  final corpus = loadHttpBoundaryCorpus();
  final steps = httpBoundarySteps(corpus);
  final responses = {
    for (final response in httpBoundaryResponses(corpus))
      '${response['id']}': response,
  };
  final owners = httpBoundaryResponseOwners(corpus);
  const root = 'C:/evidence/repair-02/root';
  var clock = 1000;
  var position = 0;
  final requests = <Map<String, Object?>>[];
  final observations = <Map<String, Object?>>[];
  final attempts = <String, int>{};
  final lastTerminal = <String, String>{};
  final stageTrace = <Map<String, Object?>>[];
  final cancelBy = <String, Map<String, Object?>>{};
  for (final step in steps) {
    final id = '${step['id']}';
    final declared = httpBoundaryDeclaredRequests(step);
    final rows = <Map<String, Object?>>[];
    for (final responseId in [...declared.ordered, ...declared.members]) {
      final response = responses[responseId]!;
      final method = '${response['method']}';
      final path = '${response['path']}';
      final rawQuery = '${response['rawQuery'] ?? ''}';
      final selector = '$method $path?$rawQuery';
      final attempt = (attempts[selector] ?? 0) + 1;
      attempts[selector] = attempt;
      final terminal = id == 's5.search-cancelled'
          ? 'client-aborted'
          : 'responded';
      final attemptKind = attempt == 1
          ? 'initial'
          : lastTerminal[selector] == 'responded'
          ? 'source-status-retry'
          : 'transport-reconnect';
      lastTerminal[selector] = terminal;
      final received = clock;
      clock += 100;
      // An aborted row wrote nothing: its send facts stay zero.
      final sent = terminal == 'client-aborted' ? 0 : clock;
      clock += 10;
      final responded = terminal == 'client-aborted' ? 0 : clock;
      clock += 10;
      position++;
      final row = <String, Object?>{
        'index': position,
        'listener': '127.0.0.1',
        'owner': id,
        'family': '${step['family']}',
        'cohort': owners[responseId]!.cohort,
        'attempt': attempt,
        'attemptKind': attemptKind,
        'selector': selector,
        'method': method,
        'path': path,
        'rawQuery': rawQuery,
        'target': rawQuery.isEmpty ? path : '$path?$rawQuery',
        'query': Uri.splitQueryString(rawQuery),
        'headers': {
          for (final entry
              in ((step['requiredHeaders'] as Map?) ?? const {}).entries)
            '${entry.key}'.toLowerCase(): '${entry.value}',
          'keep-alive': '300',
        },
        'headerLines': [
          for (final entry
              in ((step['requiredHeaders'] as Map?) ?? const {}).entries)
            '${entry.key}: ${entry.value}',
          'Keep-Alive: 300',
        ],
        'body': '',
        'bodyLength': 0,
        'bodySha256': sha256Text(''),
        'receivedAtNanos': received,
        'respondedAtNanos': responded,
        'sentAtNanos': sent,
        'sendSequence': sent == 0 ? 0 : position,
        'status': terminal == 'responded' ? 200 : -1,
        'terminal': terminal,
        'declaredResponse': responseId,
        'outcome': terminal,
        'stage': id,
      };
      rows.add(row);
      requests.add(row);
      stageTrace.add({
        'stage': id,
        'listener': '127.0.0.1',
        'target': row['target'],
        'owner': id,
      });
    }
    final value = <String, Object?>{
      'kind': 'stage',
      'stage': '${step['kind']}',
    };
    // A helper batch's own declared block, so the batch integer/configuration
    // schema has a real subject in this fixture.
    if (declared.cohort != null && '${step['family']}' == 'helper') {
      value['batch'] = {
        'cohort': declared.cohort,
        'cohortSize': declared.members.length,
        'cohortTimeoutMs': 5000,
        'entered': true,
        'cohortComplete': true,
        'releaseReason': 'complete',
        'inFlightPeak': declared.members.length,
        'membership': [
          for (final responseId in declared.members)
            '${responses[responseId]!['method']} '
                '${responses[responseId]!['path']}?'
                '${responses[responseId]!['rawQuery'] ?? ''}',
        ]..sort(),
        'threadCount': 4,
      };
    }
    final evidence = <String, Object?>{};
    if ('${step['kind']}' == 'cancel') {
      final execution = <String, Object?>{
        'pipelineIdentity': 11,
        'transportIdentity': 12,
        'sourceObjectIdentity': 13,
        'sourceKey': 'http://127.0.0.1:18771/s',
        'jobLevel': 'pipeline-cancellation',
        'boundBeforeInvocation': true,
        'tokenPresent': true,
        'keyword': 'hold',
      };
      cancelBy[id] = execution;
      value.addAll({
        'holdEntered': true,
        'cancelRequested': true,
        'clientAborted': true,
        'workerTerminated': true,
        'jobInactive': true,
        'jobCompleted': true,
        'jobDone': true,
        'workerOutcome': 'cancelled',
        'lateRequests': <Object?>[],
        'stateProbes': {
          'sourceValues': {
            'before': {
              'cancel.probe': {'present': true, 'value': ''},
            },
            'after': {
              'cancel.probe': {'present': true, 'value': ''},
            },
          },
          'variable': {
            'before': {'present': true, 'value': ''},
            'after': {'present': true, 'value': ''},
          },
          'unchanged': true,
          'databaseUnchanged': true,
        },
        'execution': {
          'sourceKey': 'http://127.0.0.1:18771/s',
          'jobLevel': 'pipeline-cancellation',
          'tokenPresent': true,
          'jobInactive': true,
          'jobCompleted': true,
        },
        'derivedOutcome': {
          'outcome': 'cancelled',
          'category': 'cancellation',
          'receiptsComplete': true,
        },
      });
      evidence.addAll({
        'cancellationState': {
          'cancelledBeforeRequest': false,
          'cancelledAtRequest': true,
          'cancelledAfterSettle': true,
          'workerSettled': true,
          'quietWindowMs': 750,
          'lateRequestCount': 0,
        },
        'execution': execution,
        'peerClosed': 'peer-closed',
        'workerFailure': 'cancelled: source request cancelled',
        // The observer's own four-table snapshot, complete and typed: the gate
        // requires both sides of this receipt before it compares them.
        'dbProvenance': {
          'before': {
            'books': 0,
            'chapters': 0,
            'source_entries': 0,
            'source_cookies': 0,
          },
          'after': {
            'books': 0,
            'chapters': 0,
            'source_entries': 0,
            'source_cookies': 0,
          },
          'productTableSnapshotIsProvenance': true,
        },
      });
    } else if (id == 's6.search-after-cancel') {
      final cancelled = cancelBy['s5.search-cancelled']!;
      final execution = <String, Object?>{
        'pipelineIdentity': 21,
        'transportIdentity': 22,
        'sourceObjectIdentity': cancelled['sourceObjectIdentity'],
        'sourceKey': 'http://127.0.0.1:18771/s',
        'jobLevel': 'pipeline-cancellation',
        'boundBeforeInvocation': true,
        'sourceKeyAfter': 'http://127.0.0.1:18771/s',
        'cancelledPipelineIdentity': cancelled['pipelineIdentity'],
        'derivedFreshness': {
          'jobIdentityFresh': true,
          'contextIdentityFresh': true,
          'sameSourceObject': true,
          'sameSourceKey': true,
          'proven': true,
        },
        'declaredStep': id,
      };
      value['followUp'] = {
        'jobIdentityFresh': true,
        'contextIdentityFresh': true,
        'sameSourceObject': true,
        'sameSourceKey': true,
        'jobLevel': 'pipeline-cancellation',
        'jobClosed': true,
        'sourceKey': 'http://127.0.0.1:18771/s',
        'tokenPresent': true,
      };
      evidence['followUpExecution'] = execution;
    } else if ('${step['kind']}' == 'rate') {
      // The three real records chain: one window start, a second admission in
      // that window, then a window advance that resets the frequency.
      final index = step['index'] as int;
      const windowStart = 1792687280573;
      Map<String, Object?> record(int time, int frequency) => {
        'isConcurrent': true,
        'time': time,
        'frequency': frequency,
      };
      value.addAll({
        'kind': 'rate',
        'index': index,
        'result': 'R$index',
        'recordBefore': switch (index) {
          1 => null,
          2 => record(windowStart, 1),
          _ => record(windowStart, 2),
        },
        'recordAfter': switch (index) {
          1 => record(windowStart, 1),
          2 => record(windowStart, 2),
          _ => record(windowStart + 2000, 1),
        },
        'sameWindowAsPrevious': switch (index) {
          1 => null,
          2 => true,
          _ => false,
        },
        'scheduleComplete': true,
        'scheduleReason': null,
      });
      evidence.addAll({
        'callStartMillis': switch (index) {
          1 => windowStart - 5,
          2 => windowStart + 5,
          _ => windowStart + 40,
        },
        'callFinishMillis': switch (index) {
          1 => windowStart + 10,
          2 => windowStart + 30,
          _ => windowStart + 2040,
        },
        'durationNanos': 18000000,
        'sourceKey': 'http://127.0.0.1:18771/r',
        'windowMillis': 2000,
        'windowStartMillis': index == 3 ? null : windowStart,
        'windowAdvanceMillis': index == 3 ? 2000 : null,
      });
    }
    observations.add({
      'id': id,
      'outcome': '${step['expectedOutcome'] ?? 'ok'}',
      'category': step['expectedCategory'],
      'value': value,
      'evidence': evidence,
      'requests': rows,
    });
  }
  final requestCheckSteps = <Map<String, Object?>>[];
  for (final step in steps) {
    final id = '${step['id']}';
    final declared = httpBoundaryDeclaredRequests(step);
    final seen = <String, int>{};
    String key(String responseId) {
      final selector = httpBoundarySelectorOf(responses[responseId]!);
      final attempt = (seen[selector] ?? 0) + 1;
      seen[selector] = attempt;
      return '$selector#$attempt';
    }

    final expectedOrdered = [
      for (final responseId in declared.ordered) key(responseId),
    ];
    final expectedBatch = [
      for (final responseId in declared.members) key(responseId),
    ];
    final actual = [
      for (final request in requests)
        if ('${(request)['owner']}' == id)
          '${request['selector']}#${request['attempt']}',
    ];
    final countMatch =
        actual.length == expectedOrdered.length + expectedBatch.length;
    final orderMatch = expectedOrdered.isEmpty
        ? true
        : (() {
            for (var i = 0; i < expectedOrdered.length; i++) {
              if (actual[i] != expectedOrdered[i]) return false;
            }
            return true;
          })();
    final batch = actual.skip(expectedOrdered.length).toList()..sort();
    final expectedSorted = [...expectedBatch]..sort();
    final batchMatch = '$batch' == '$expectedSorted';
    requestCheckSteps.add({
      'id': id,
      'expectedOrdered': expectedOrdered,
      'expectedBatch': expectedBatch,
      'actual': actual,
      'countMatch': countMatch,
      'orderMatch': orderMatch,
      'batchMatch': batchMatch,
      'match': countMatch && orderMatch && batchMatch,
    });
  }
  final ids = httpBoundaryObservationIds(corpus);
  return <String, dynamic>{
    'schemaVersion': 1,
    'product': 'liber-http-boundary-runner',
    'platform': 'windows',
    'pid': 1,
    'runId': 'synthetic-run',
    'recordedAt': '2026-10-22T00:00:00.000Z',
    'completedAt': '2026-10-22T00:00:30.000Z',
    'captureKind': 'product',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'status': 'completed',
    'analysisFailure': null,
    'negativeMode': false,
    'negative': null,
    'identity': {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'corpusPath': httpBoundaryImportCorpusPath,
      'corpusRawSha256': 'a' * 64,
      'corpusSha256Lf': 'c' * 64,
      'corpusRawLineEndings': 'crlf',
      'target': {
        'package': (corpus['target'] as Map)['package'],
        'apkSha256': (corpus['target'] as Map)['apkSha256'],
        'baselineCommit': (corpus['target'] as Map)['baselineCommit'],
        'manifest': (corpus['target'] as Map)['manifest'],
      },
      'library': {'path': libraryPath, 'sha256': librarySha},
      'runner': {
        'path': httpBoundaryImportRunnerPath,
        'sha256': sha256File(File(httpBoundaryImportRunnerPath)),
      },
    },
    'isolation': {
      'application': 'dart:io process over Workspace/SpaceStore',
      'root': root,
      'database': '$root\\spaces\\default\\data.db',
      'workspaceManifest': '$root\\manifest.json',
      'ownerFile': '$root\\owner.json',
      'rootExistedAtStart': false,
      'createdByThisRun': true,
      'preferenceFilesOutsideRoot': <Object?>[],
      'preferenceBoundary': 'inside this root',
    },
    'runtimeConfiguration': {
      'threadCount': 4,
      'threadCountSource': 'SourceHostDispatcher.ajaxAll concurrency default',
      'threadCountPreference': null,
      'declaredNativeDefault': 16,
      'resolved': true,
    },
    'rateLimiter': {
      'instance': 'SourceRateLimiter()',
      'reason': 'injected',
      'concurrentRate': '1/2000',
      'windowMillis': 2000,
      'initialSnapshot': 'empty',
    },
    'failEndpoint': {
      'host': '127.0.0.1',
      'requestedPort': 0,
      'assignedPort': 54369,
      'armedAtLeastOnce': true,
      'armedAtNanos': 10,
      'acceptedConnections': 1,
      'transportReconnects': 0,
      'connections': [
        {
          'index': 1,
          'method': 'GET',
          'target': '/f/search?keyword=fail&page=1',
          'path': '/f/search',
          'rawQuery': 'keyword=fail&page=1',
          'headers': {'user-agent': 'HTTP-BOUNDARY-01/1.0', 'x-declared': 'f'},
          'armed': true,
          'classification': 'initial',
          'requestObserved': true,
          'acceptedAtNanos': 20,
          'terminal': 'accepted-and-closed-without-response',
          'closedAtNanos': 21,
        },
      ],
      'errors': <Object?>[],
      'closed': true,
      'classification': {
        'first': 'initial',
        'subsequent': 'transport-reconnect',
        'statusRetryImpossible': 'no response is written',
      },
    },
    'stageTrace': stageTrace,
    'structural': {
      'declared': corpus['structural'],
      'derived': httpBoundaryStructuralOf(corpus),
      'match': true,
    },
    'requests': requests,
    'unmatchedRequests': <Object?>[],
    'serverErrors': <Object?>[],
    'requestCheck': {
      'steps': requestCheckSteps,
      'declaredTotal': 31,
      'actualTotal': requests.length,
      'totalMatch': requests.length == 31,
      'ownerless': <Object?>[],
      'unknownOwners': <Object?>[],
      'duplicateIndices': 0,
      'fieldProblems': <Object?>[],
      'terminalProblems': <Object?>[],
      'unmatchedRequests': 0,
      'serverErrors': 0,
      'match': true,
    },
    'observations': observations,
    'observationCheck': {
      'declared': ids,
      'actual': ids,
      'missing': <Object?>[],
      'extra': <Object?>[],
      'duplicates': <Object?>[],
      'ordered': true,
      'outcomeMismatches': <Object?>[],
      'requestCountMismatches': <Object?>[],
      'shapeMismatches': <Object?>[],
      'match': true,
    },
    'inventory': {
      'databaseOpened': true,
      'initial': {
        'books': 0,
        'chapters': 0,
        'source_entries': 0,
        'source_cookies': 0,
      },
      'final': {
        'books': 0,
        'chapters': 0,
        'source_entries': 0,
        'source_cookies': 0,
      },
    },
    // The owned-worker teardown receipt of a settled, normal run.
    'ownedTeardown': {
      'workerSettled': true,
      'stepsRun': ['closeDatabase', 'disposeNative'],
      'residueRetained': false,
      'timeoutMillis': 20000,
    },
    'cleanup': {
      'admission': 'stopped before teardown',
      'listenerClosed': true,
      'failEndpointClosed': true,
      'failEndpointConnections': 1,
      'nativeLibraryDisposed': true,
      'databaseClosed': true,
      'ownerWritten': true,
      'ownerSha256': 'd' * 64,
      'scratchRetained': false,
      'scratchRemoved': true,
      'rootAbsentAfter': true,
      'removalSkipped': '',
      'lateErrorCount': 0,
      'terminal': {
        'listeners': {'replayClosed': true, 'failEndpointClosed': true},
        'bridge': {'nativeDisposed': true},
        'database': {'closed': true},
        'scratch': {'removed': true, 'absentAfter': true},
        'integrityOk': true,
      },
      'ownerManifest': {
        'path': '$root\\owner.json',
        'createdAt': '2026-10-22T00:00:00.000Z',
        'written': true,
      },
      'startedAt': '2026-10-22T00:00:00.000Z',
    },
    'sourceDerivedNotes': corpus['sourceDerivedNotes'],
    'coverageGaps': corpus['coverageGaps'],
    'nondeterministic': corpus['nondeterministic'],
  };
}

/// The corpus path and runner path the gate binds to, re-exported from the
/// entry points so a test never spells them twice.
const httpBoundaryImportCorpusPath = httpBoundaryCorpusPath;
const httpBoundaryImportRunnerPath = 'tool/http_boundary/runner.dart';

Map<String, dynamic> _validProductCopy({
  required String libraryPath,
  required String librarySha,
}) =>
    (jsonDecode(
              jsonEncode(
                _validProduct(libraryPath: libraryPath, librarySha: librarySha),
              ),
            )
            as Map)
        .cast<String, dynamic>();

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

  test('a repeated declared selector expects its own attempt sequence', () {
    // The corpus declares one selector three times for the retry row; the
    // comparator must require #1, #2, #3 rather than three identical rows.
    final corpus = loadHttpBoundaryCorpus();
    final golden = _retryReport();
    final product = _retryReport();
    // The record carries only this one step, so the other steps' declared
    // prefixes are absent; the retry row's own order is what this checks.
    int retryOrderRows(List<HttpBoundaryMismatch> mismatches) => mismatches
        .where(
          (mismatch) =>
              mismatch.surface == 'order' && mismatch.row == 's2.retry-non2xx',
        )
        .length;
    expect(
      retryOrderRows(
        compareHttpBoundaryRecords(
          golden: golden,
          product: product,
          corpus: corpus,
          goldenId: 'synthetic',
        ).mismatches,
      ),
      0,
    );
    final swapped = _retryReport();
    final rows = (swapped['requests'] as List).cast<Map>();
    final first = rows[0];
    rows[0] = rows[2];
    rows[2] = first;
    final mismatches = compareHttpBoundaryRecords(
      golden: golden,
      product: swapped,
      corpus: corpus,
      goldenId: 'synthetic',
    ).mismatches;
    expect(
      mismatches.map((mismatch) => mismatch.field),
      contains('product-ordered-prefix'),
    );
  });

  test('a swapped sequential step order is a causal difference', () {
    final corpus = loadHttpBoundaryCorpus();
    final golden = _sequentialReport();
    final product = _sequentialReport();
    final rows = (product['requests'] as List).cast<Map>();
    final first = rows[0];
    rows[0] = rows[1];
    rows[1] = first;
    final mismatches = compareHttpBoundaryRecords(
      golden: golden,
      product: product,
      corpus: corpus,
      goldenId: 'synthetic',
    ).mismatches;
    expect(
      mismatches.map((mismatch) => mismatch.field),
      contains('causal-steps'),
    );
  });

  test('the batch control corrupts a real cohort-peak fact', () {
    final corpus = loadHttpBoundaryCorpus();
    final golden = _batchReport();
    final product = _batchReport();
    final baseline = compareHttpBoundaryRecords(
      golden: golden,
      product: product,
      corpus: corpus,
      goldenId: 'synthetic',
    );
    final controls = runHttpBoundaryControls(
      golden: golden,
      product: product,
      corpus: corpus,
      goldenId: 'synthetic',
      baseline: baseline,
    );
    final batch = controls.firstWhere(
      (control) => control.id == 'product-batch-width',
    );
    expect(batch.applied, isTrue, reason: 'the batch control did not apply');
    expect(
      batch.newKeys,
      contains(
        'observation|helper.ajaxAll-order|value.batch.inFlightPeak|number',
      ),
    );
  });

  test('the retry and sequential order controls add their own keys', () {
    final corpus = loadHttpBoundaryCorpus();
    final golden = _retryReport();
    final product = _retryReport();
    final baseline = compareHttpBoundaryRecords(
      golden: golden,
      product: product,
      corpus: corpus,
      goldenId: 'synthetic',
    );
    final controls = runHttpBoundaryControls(
      golden: golden,
      product: product,
      corpus: corpus,
      goldenId: 'synthetic',
      baseline: baseline,
    );
    for (final id in const [
      'product-retry-order',
      'product-sequential-order',
    ]) {
      final control = controls.firstWhere((control) => control.id == id);
      expect(control.applied, isTrue, reason: '$id did not apply');
      expect(
        control.newKeys,
        isNotEmpty,
        reason: '$id must add its own mismatch key',
      );
    }
  });

  test('the capture asset pin is the captured asset, not the working bytes', () {
    final directory = Directory.systemTemp.createTempSync('http-boundary-lf-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final golden = _report();
    (golden['identity'] as Map)['corpusAssetSha256'] = 'd' * 64;
    final file = File('${directory.path}/positive.json')
      ..writeAsStringSync(jsonEncode(golden));
    final reportSha = sha256File(file);
    final corpus = _corpus().cast<String, dynamic>();
    void validate() => validateFrozenCapture(
      golden.cast<String, dynamic>(),
      corpus: corpus,
      corpusLf: 'c' * 64,
      goldenId: 'synthetic',
      expectedReportSha256: reportSha,
      reportPath: file.path,
    );
    // The captured asset pin is accepted whether the working corpus is CRLF or
    // LF: the semantic LF hash above is the identity that matters.
    corpus['_capturedAssetSha256'] = 'd' * 64;
    corpus['_rawSha256'] = 'f' * 64;
    expect(validate, returnsNormally);
    corpus['_capturedAssetSha256'] = 'e' * 64;
    expect(validate, throwsA(isA<HttpBoundaryRefusal>()));
    corpus.remove('_capturedAssetSha256');
    corpus['_rawSha256'] = 'd' * 64;
    expect(validate, returnsNormally);
  });

  group('the product-record gate', () {
    late Directory work;
    late String libraryPath;
    late String librarySha;
    late Map<String, dynamic> corpus;
    late String corpusLf;

    setUpAll(() {
      work = Directory.systemTemp.createTempSync('http-boundary-gate-');
      final library = File('${work.path}${Platform.pathSeparator}fjs.dll')
        ..writeAsBytesSync(List<int>.generate(64, (index) => index));
      libraryPath = library.path;
      librarySha = sha256File(library);
      corpus = loadHttpBoundaryCorpus();
      corpusLf = httpBoundaryCorpusSha256Lf(File(httpBoundaryCorpusPath));
    });

    tearDownAll(() => work.deleteSync(recursive: true));

    Map<String, dynamic> fresh() {
      final record = _validProductCopy(
        libraryPath: libraryPath,
        librarySha: librarySha,
      );
      (record['identity'] as Map)['corpusSha256Lf'] = corpusLf;
      return record;
    }

    void gate(Map<String, dynamic> record) => validateProductReport(
      record,
      corpus: corpus,
      corpusLf: corpusLf,
      productPath: 'synthetic-product.json',
    );

    Map<String, dynamic> observation(Map<String, dynamic> record, String id) =>
        (record['observations'] as List)
            .cast<Map>()
            .firstWhere((row) => row['id'] == id)
            .cast<String, dynamic>();

    Map<String, dynamic> firstRequest(Map<String, dynamic> record) =>
        (record['requests'] as List).first as Map<String, dynamic>;

    test('a legitimate record passes the exported gate', () {
      expect(() => gate(fresh()), returnsNormally);
    });

    test(
      'object key order, header-line order and header-name case are not facts',
      () {
        Object? reverseKeys(Object? input) {
          if (input is Map) {
            final keys = input.keys.toList().reversed;
            return {for (final key in keys) key: reverseKeys(input[key])};
          }
          if (input is List) {
            return [for (final value in input) reverseKeys(value)];
          }
          return input;
        }

        final reordered = (reverseKeys(fresh()) as Map).cast<String, dynamic>();
        expect(() => gate(reordered), returnsNormally);
        final record = fresh();
        // Every measured copy of a request row is transformed together: the top
        // level trace and each observation's own slice are the same facts.
        void eachRequest(
          Map<String, dynamic> report,
          void Function(Map) change,
        ) {
          for (final row in (report['requests'] as List).cast<Map>()) {
            change(row);
          }
          for (final observation
              in (report['observations'] as List).cast<Map>()) {
            for (final row in (observation['requests'] as List).cast<Map>()) {
              change(row);
            }
          }
        }

        eachRequest(record, (row) {
          row['headerLines'] = (row['headerLines'] as List).reversed.toList(
            growable: false,
          );
          // The same names and values with different wire case.
          row['headers'] = {
            for (final entry in (row['headers'] as Map).entries)
              '${entry.key}'
                  .split('-')
                  .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
                  .join('-'): entry
                  .value,
          };
        });
        expect(() => gate(record), returnsNormally);
        // The stage trace's own order is not a compared fact either.
        final trace = fresh();
        trace['stageTrace'] = (trace['stageTrace'] as List).reversed.toList();
        expect(() => gate(trace), returnsNormally);
      },
    );

    test('contradictory cancellation evidence is refused', () {
      final missing = fresh();
      (observation(missing, 's5.search-cancelled')['evidence'] as Map).remove(
        'cancellationState',
      );
      expect(() => gate(missing), throwsA(isA<HttpBoundaryRefusal>()));

      final running = fresh();
      (((observation(running, 's5.search-cancelled')['evidence']
                  as Map)['cancellationState']
              as Map))['workerSettled'] =
          false;
      expect(() => gate(running), throwsA(isA<HttpBoundaryRefusal>()));

      final quiet = fresh();
      (((observation(quiet, 's5.search-cancelled')['evidence']
                  as Map)['cancellationState']
              as Map))['quietWindowMs'] =
          0;
      expect(() => gate(quiet), throwsA(isA<HttpBoundaryRefusal>()));

      final notCancelled = fresh();
      (((observation(notCancelled, 's5.search-cancelled')['evidence']
                  as Map)['cancellationState']
              as Map))['cancelledAtRequest'] =
          false;
      expect(() => gate(notCancelled), throwsA(isA<HttpBoundaryRefusal>()));

      final emptyCancel = fresh();
      observation(emptyCancel, 's5.search-cancelled')['evidence'] = {};
      expect(() => gate(emptyCancel), throwsA(isA<HttpBoundaryRefusal>()));

      final emptyFollowUp = fresh();
      observation(emptyFollowUp, 's6.search-after-cancel')['evidence'] = {};
      expect(() => gate(emptyFollowUp), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('a false value summary cannot stand on a measured cancellation', () {
      final record = fresh();
      observation(record, 's5.search-cancelled')['value']['jobDone'] = false;
      expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test(
      'every rate operation keeps its own interval, duration and source',
      () {
        for (final id in const ['rate.record.1', 'rate.record.3']) {
          final record = fresh();
          final evidence = observation(record, id)['evidence'] as Map;
          evidence['callFinishMillis'] =
              (evidence['callStartMillis'] as int) - 1;
          expect(
            () => gate(record),
            throwsA(isA<HttpBoundaryRefusal>()),
            reason: '$id allowed an inverted call interval',
          );
        }
        final outside = fresh();
        final first = observation(outside, 'rate.record.1')['evidence'] as Map;
        first['callStartMillis'] = 1792687280573 + 5000;
        first['callFinishMillis'] = 1792687280573 + 5001;
        expect(() => gate(outside), throwsA(isA<HttpBoundaryRefusal>()));

        final negative = fresh();
        (observation(negative, 'rate.record.1')['evidence']
                as Map)['durationNanos'] =
            -1;
        expect(() => gate(negative), throwsA(isA<HttpBoundaryRefusal>()));

        final otherSource = fresh();
        (observation(otherSource, 'rate.record.2')['evidence']
                as Map)['sourceKey'] =
            'another-source';
        expect(() => gate(otherSource), throwsA(isA<HttpBoundaryRefusal>()));

        final window = fresh();
        (observation(window, 'rate.record.3')['evidence']
                as Map)['windowAdvanceMillis'] =
            1;
        expect(() => gate(window), throwsA(isA<HttpBoundaryRefusal>()));
      },
    );

    test('a request and a failure connection keep their own clock order', () {
      final request = fresh();
      final row = firstRequest(request);
      row['receivedAtNanos'] = (row['sentAtNanos'] as int) + 1;
      expect(() => gate(request), throwsA(isA<HttpBoundaryRefusal>()));

      final connection = fresh();
      final closed =
          ((connection['failEndpoint'] as Map)['connections'] as List).first
              as Map;
      closed['closedAtNanos'] = (closed['acceptedAtNanos'] as int) - 1;
      expect(() => gate(connection), throwsA(isA<HttpBoundaryRefusal>()));

      final unobserved = fresh();
      final unseen =
          ((unobserved['failEndpoint'] as Map)['connections'] as List).first
              as Map;
      unseen['requestObserved'] = false;
      expect(() => gate(unobserved), throwsA(isA<HttpBoundaryRefusal>()));

      final noTerminal = fresh();
      final terminal =
          ((noTerminal['failEndpoint'] as Map)['connections'] as List).first
              as Map;
      terminal['terminal'] = '';
      expect(() => gate(noTerminal), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('a request stage and the stage trace name measured steps only', () {
      final stage = fresh();
      firstRequest(stage)['stage'] = 'bogus-stage';
      expect(() => gate(stage), throwsA(isA<HttpBoundaryRefusal>()));

      final owner = fresh();
      ((owner['stageTrace'] as List).first as Map)['owner'] =
          'nonexistent-owner';
      expect(() => gate(owner), throwsA(isA<HttpBoundaryRefusal>()));

      final traceStage = fresh();
      ((traceStage['stageTrace'] as List).first as Map)['stage'] =
          'bogus-stage';
      expect(() => gate(traceStage), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('a per-step summary cannot contradict the rows it summarises', () {
      for (final field in const ['countMatch', 'orderMatch', 'batchMatch']) {
        final record = fresh();
        (((record['requestCheck'] as Map)['steps'] as List).first
                as Map)[field] =
            false;
        expect(
          () => gate(record),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason: 'a false $field summary was accepted',
        );
      }
      final declared = fresh();
      (declared['structural'] as Map)['declared'] = <String, Object?>{};
      expect(() => gate(declared), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('the inventory is the four tables this observer reads', () {
      final record = fresh();
      for (final snapshot in const ['initial', 'final']) {
        (record['inventory'] as Map)[snapshot] = {'not-an-actual-table': 0};
      }
      expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('the stage trace keeps its multiplicity', () {
      final duplicate = fresh();
      final trace = duplicate['stageTrace'] as List;
      trace[1] = Map<String, Object?>.from(trace.first as Map);
      expect(() => gate(duplicate), throwsA(isA<HttpBoundaryRefusal>()));

      // An identical retry entry may stand for another identical one: the
      // counted set of measured rows is unchanged.
      final identical = fresh();
      final rows = identical['stageTrace'] as List;
      final retries = [
        for (final entry in rows)
          if ('${(entry as Map)['stage']}' == 's2.retry-non2xx') entry,
      ];
      expect(retries, hasLength(3));
      expect(
        retries.map((entry) => jsonEncode(entry)).toSet(),
        hasLength(1),
        reason: 'the three retry rows are not identical in the fixture',
      );
      rows[rows.lastIndexWhere(
        (entry) => (entry as Map)['stage'] == 's2.retry-non2xx',
      )] = Map<String, Object?>.from(
        retries.first,
      );
      expect(() => gate(identical), returnsNormally);
    });

    test(
      'an abort needs a measured close or a failed write on the held request',
      () {
        for (final bad in <Object?>[false, '', <String, Object?>{}]) {
          final record = fresh();
          (observation(record, 's5.search-cancelled')['evidence']
                  as Map)['peerClosed'] =
              bad;
          expect(
            () => gate(record),
            throwsA(isA<HttpBoundaryRefusal>()),
            reason: 'peerClosed=$bad was accepted as a close receipt',
          );
        }

        Map<String, Object?> cancelEvidence(Map<String, dynamic> record) =>
            observation(record, 's5.search-cancelled')['evidence']
                as Map<String, Object?>;

        List<Map> heldRows(Map<String, dynamic> record) => [
          for (final raw in (record['requests'] as List).cast<Map>())
            if ('${raw['declaredResponse']}' == 's-search-hold') raw,
        ];

        final nullNoWrite = fresh();
        cancelEvidence(nullNoWrite)['peerClosed'] = null;
        expect(() => gate(nullNoWrite), throwsA(isA<HttpBoundaryRefusal>()));

        final emptyMarker = fresh();
        cancelEvidence(emptyMarker)['peerClosed'] = null;
        cancelEvidence(emptyMarker)['abortError'] = '';
        expect(() => gate(emptyMarker), throwsA(isA<HttpBoundaryRefusal>()));

        // The runner's other real branch: the failing write is recorded on the
        // bound held request, whose terminal is the abort.
        final writeFailure = fresh();
        cancelEvidence(writeFailure)['peerClosed'] = null;
        final held = heldRows(writeFailure);
        expect(held, isNotEmpty);
        for (final row in held) {
          row['abortError'] =
              'SocketException: peer closed during response write';
        }
        for (final row
            in (observation(writeFailure, 's5.search-cancelled')['requests']
                    as List)
                .cast<Map>()) {
          if ('${row['declaredResponse']}' == 's-search-hold') {
            row['abortError'] =
                'SocketException: peer closed during response write';
          }
        }
        expect(() => gate(writeFailure), returnsNormally);

        final unrelated = fresh();
        cancelEvidence(unrelated)['peerClosed'] = null;
        final other = (unrelated['requests'] as List).first as Map;
        other['abortError'] = 'unrelated failure';
        final otherInSlice =
            (observation(unrelated, 'helper.ajax')['requests'] as List).first
                as Map;
        otherInSlice['abortError'] = 'unrelated failure';
        expect(() => gate(unrelated), throwsA(isA<HttpBoundaryRefusal>()));
      },
    );

    test('a cancelled worker keeps a recorded failure receipt', () {
      Map<String, Object?> cancelEvidence(Map<String, dynamic> record) =>
          observation(record, 's5.search-cancelled')['evidence']
              as Map<String, Object?>;

      // The legitimate neighbor first: the runner's own cancelled-worker receipt.
      final valid = fresh();
      expect(
        cancelEvidence(valid)['workerFailure'],
        'cancelled: source request cancelled',
      );
      expect(() => gate(valid), returnsNormally);

      final variants = <String, void Function(Map<String, Object?>)>{
        'missing': (evidence) => evidence.remove('workerFailure'),
        'null': (evidence) => evidence['workerFailure'] = null,
        'empty': (evidence) => evidence['workerFailure'] = '',
        'boolean': (evidence) => evidence['workerFailure'] = false,
        'object': (evidence) => evidence['workerFailure'] = <String, Object?>{},
        'array': (evidence) => evidence['workerFailure'] = <Object?>[],
      };
      for (final entry in variants.entries) {
        final record = fresh();
        entry.value(cancelEvidence(record));
        expect(
          () => gate(record),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason:
              'the ${entry.key} worker-failure variant was accepted beside a '
              'cancelled worker',
        );
      }
    });

    test(
      'both database snapshots are complete and typed before comparison',
      () {
        Map<String, Object?> snapshots(Map<String, dynamic> record) =>
            (observation(record, 's5.search-cancelled')['evidence']
                    as Map)['dbProvenance']
                as Map<String, Object?>;

        final variants = <String, void Function(Map<String, Object?>)>{
          'absent': (db) {
            db.remove('before');
            db.remove('after');
          },
          'null': (db) {
            db['before'] = null;
            db['after'] = null;
          },
          'empty': (db) {
            db['before'] = <String, Object?>{};
            db['after'] = <String, Object?>{};
          },
          'not-a-snapshot': (db) {
            db['before'] = 'snapshot';
            db['after'] = 'snapshot';
          },
          'dropped-category': (db) {
            for (final key in const ['before', 'after']) {
              (db[key] as Map).remove('chapters');
            }
          },
          'string-count': (db) {
            for (final key in const ['before', 'after']) {
              (db[key] as Map)['books'] = '0';
            }
          },
          'changed-count': (db) {
            (db['after'] as Map)['books'] = 1;
          },
        };
        for (final entry in variants.entries) {
          final record = fresh();
          entry.value(snapshots(record));
          expect(
            () => gate(record),
            throwsA(isA<HttpBoundaryRefusal>()),
            reason: 'the ${entry.key} snapshot variant was accepted',
          );
        }
      },
    );

    test('the owned-worker teardown receipt is typed and consistent', () {
      final variants = <String, void Function(Map<String, dynamic>)>{
        'false': (record) =>
            (record['ownedTeardown'] as Map)['workerSettled'] = false,
        'string': (record) =>
            (record['ownedTeardown'] as Map)['workerSettled'] = 'true',
        'missing': (record) => record.remove('ownedTeardown'),
        'steps': (record) =>
            (record['ownedTeardown'] as Map)['stepsRun'] = ['closeDatabase'],
        'zero-deadline': (record) =>
            (record['ownedTeardown'] as Map)['timeoutMillis'] = 0,
        'residue': (record) =>
            (record['ownedTeardown'] as Map)['residueRetained'] = true,
      };
      for (final entry in variants.entries) {
        final record = fresh();
        entry.value(record);
        expect(
          () => gate(record),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason: 'the ${entry.key} ownedTeardown variant was accepted',
        );
      }
    });

    test('arrays keep their order and their duplicate values', () {
      final reversed = fresh();
      reversed['coverageGaps'] = (reversed['coverageGaps'] as List).reversed
          .toList();
      expect(() => gate(reversed), throwsA(isA<HttpBoundaryRefusal>()));

      final duplicated = fresh();
      final gaps = (duplicated['coverageGaps'] as List).toList()
        ..add((duplicated['coverageGaps'] as List).first);
      duplicated['coverageGaps'] = gaps;
      expect(() => gate(duplicated), throwsA(isA<HttpBoundaryRefusal>()));

      final typed = fresh();
      firstRequest(typed)['status'] = 200.0;
      expect(() => gate(typed), throwsA(isA<HttpBoundaryRefusal>()));
    });
  });

  group('the owned raw replay listener', () {
    Map<String, Object?> response({
      String method = 'GET',
      String path = '/probe',
      String rawQuery = '',
      bool hold = false,
      String body = 'probe response',
    }) => {
      'id': 'probe',
      'method': method,
      'path': path,
      'rawQuery': rawQuery,
      'status': 200,
      'body': body,
      if (hold) 'hold': true,
      if (hold) 'holdTimeoutMs': 5000,
    };

    String request(
      String target, {
      String method = 'GET',
      String body = '',
      Map<String, String> headers = const {'Host': '127.0.0.1'},
      bool close = false,
    }) {
      final buffer = StringBuffer('$method $target HTTP/1.1\r\n');
      for (final entry in headers.entries) {
        buffer.write('${entry.key}: ${entry.value}\r\n');
      }
      buffer.write('Content-Length: ${utf8.encode(body).length}\r\n');
      if (close) buffer.write('Connection: close\r\n');
      buffer.write('\r\n$body');
      return buffer.toString();
    }

    test(
      'the literal request target is recorded and matched byte-exactly',
      () async {
        final encoded = await probeOwnedReplayListener(
          response: response(rawQuery: 'p=%62%31'),
          rawRequests: [request('/probe?p=%62%31')],
        );
        final recorded = (encoded['requests'] as List).single as Map;
        expect(recorded['rawQuery'], 'p=%62%31');
        expect(recorded['target'], '/probe?p=%62%31');
        expect(recorded['declaredResponse'], 'probe');
        expect(recorded['terminal'], 'responded');
        expect((encoded['unmatched'] as List), isEmpty);
        expect((encoded['serverErrors'] as List), isEmpty);

        // The semantically equivalent but differently encoded target is a
        // different request; the declaration decides which one matches.
        final nearMiss = await probeOwnedReplayListener(
          response: response(rawQuery: 'p=%62%31'),
          rawRequests: [request('/probe?p=b1')],
        );
        expect((nearMiss['unmatched'] as List), hasLength(1));
        final unmatchedRow = (nearMiss['unmatched'] as List).single as Map;
        expect(unmatchedRow['rawQuery'], 'p=b1');

        final literal = await probeOwnedReplayListener(
          response: response(rawQuery: 'p=b1'),
          rawRequests: [request('/probe?p=%62%31')],
        );
        expect((literal['unmatched'] as List), hasLength(1));
      },
    );

    test('a GET body is read from its declared framing', () async {
      final probe = await probeOwnedReplayListener(
        response: response(path: '/probe'),
        rawRequests: [request('/probe', body: 'ABC')],
      );
      final recorded = (probe['requests'] as List).single as Map;
      expect(recorded['method'], 'GET');
      expect(recorded['body'], 'ABC');
      expect(recorded['bodyLength'], 3);
      expect(recorded['bodySha256'], sha256Text('ABC'));
      expect(recorded['terminal'], 'responded');
    });

    test(
      'a normal write records real send facts and content-length framing',
      () async {
        final probe = await probeOwnedReplayListener(
          response: response(body: 'hello'),
          rawRequests: [request('/probe', close: true)],
        );
        final recorded = (probe['requests'] as List).single as Map;
        expect(recorded['terminal'], 'responded');
        expect(recorded['status'], 200);
        expect(recorded['sentAtNanos'] as int, greaterThan(0));
        expect(recorded['respondedAtNanos'] as int, greaterThan(0));
        expect(recorded['sendSequence'], 1);
        expect(probe['responseText'], contains('Content-Length: 5'));
        expect(probe['responseText'], endsWith('hello'));
      },
    );

    test(
      'a peer abort before the write keeps every send fact unsent',
      () async {
        final probe = await probeOwnedReplayListener(
          response: response(path: '/held', hold: true, body: 'held'),
          rawRequests: [request('/held', close: true)],
          abortHeld: true,
        );
        final recorded = (probe['requests'] as List).single as Map;
        expect(recorded['terminal'], 'client-aborted');
        expect(recorded['status'], -1);
        expect(recorded['sentAtNanos'], 0);
        expect(recorded['respondedAtNanos'], 0);
        expect(recorded['sendSequence'], 0);
        expect(probe['responseBytes'], 0);
      },
    );

    test(
      'split reads and sequential keep-alive requests are framed per request',
      () async {
        final fragmented = await probeOwnedReplayListener(
          response: response(body: 'frag'),
          rawRequests: [request('/probe', close: true)],
          fragment: true,
        );
        expect((fragmented['requests'] as List), hasLength(1));
        expect(
          ((fragmented['requests'] as List).single as Map)['terminal'],
          'responded',
        );

        final sequential = await probeOwnedReplayListener(
          response: response(body: 'seq'),
          rawRequests: [request('/probe'), request('/probe', close: true)],
          sequential: true,
        );
        final rows = (sequential['requests'] as List).cast<Map>();
        expect(rows, hasLength(2));
        expect(rows.map((row) => row['attempt']), [1, 2]);
        expect(rows.map((row) => row['attemptKind']), [
          'initial',
          'source-status-retry',
        ]);
        expect(rows.every((row) => row['terminal'] == 'responded'), isTrue);
      },
    );

    test('only the held request own connection can report its abort', () async {
      // The held request's own peer stays open; a separate idle connection is
      // closed. The held row must still be answered, not marked aborted.
      final unrelated = await probeOwnedReplayListener(
        response: response(path: '/held', hold: true, body: 'held'),
        rawRequests: [request('/held', close: true)],
        idlePeerClose: true,
      );
      final row = (unrelated['requests'] as List).single as Map;
      expect(row['terminal'], 'responded');
      expect(row['status'], 200);
      expect(row['sentAtNanos'] as int, greaterThan(0));
      expect((unrelated['serverErrors'] as List), isEmpty);

      // The owner's own close is still the measured abort, with nothing sent.
      final own = await probeOwnedReplayListener(
        response: response(path: '/held', hold: true, body: 'held'),
        rawRequests: [request('/held', close: true)],
        abortHeld: true,
      );
      final aborted = (own['requests'] as List).single as Map;
      expect(aborted['terminal'], 'client-aborted');
      expect(aborted['sentAtNanos'], 0);
      expect(aborted['respondedAtNanos'], 0);
      expect(aborted['sendSequence'], 0);
      expect(own['responseBytes'], 0);
    });

    test(
      'the literal header line and the frozen status reason are kept',
      () async {
        final literal = await probeOwnedReplayListener(
          response: response(body: 'x'),
          rawRequests: [
            'GET /probe HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                'Content-Length: 0\r\nX-Controller-Probe:\towned \t\r\n'
                'Connection: close\r\n\r\n',
          ],
        );
        final row = (literal['requests'] as List).single as Map;
        expect(
          (row['headerLines'] as List),
          contains('X-Controller-Probe:\towned \t'),
        );
        expect((row['headers'] as Map)['x-controller-probe'], 'owned');

        final unavailable = await probeOwnedReplayListener(
          response: <String, Object?>{
            'id': 'probe',
            'method': 'GET',
            'path': '/probe',
            'rawQuery': '',
            'status': 503,
            'body': 'unavailable',
            'headers': <String, Object?>{'Content-Type': 'text/plain'},
          },
          rawRequests: [request('/probe', close: true)],
        );
        expect(
          unavailable['responseText'] as String,
          startsWith('HTTP/1.1 503 Service Unavailable\r\n'),
        );

        final missing = await probeOwnedReplayListener(
          response: response(),
          rawRequests: [request('/nothing-here', close: true)],
        );
        expect(
          missing['responseText'] as String,
          startsWith('HTTP/1.1 404 Not Found\r\n'),
        );
      },
    );

    test('Content-Length is decimal HTTP framing only', () async {
      Future<List<String>> errorsFor(String raw) async =>
          ((await probeOwnedReplayListener(
                    response: response(),
                    rawRequests: [raw],
                    closeAfterWrite: true,
                  ))['serverErrors']
                  as List)
              .cast<String>();

      // Legal optional whitespace around a value is trimmed by the framing (HTTP
      // OWS); the grammar itself is decimal digits only.
      for (final spelling in const ['+3', '0x3', '3.0', '-0']) {
        final errors = await errorsFor(
          'POST /probe HTTP/1.1\r\nHost: 127.0.0.1\r\n'
          'Content-Length: $spelling\r\nConnection: close\r\n\r\nABC',
        );
        expect(
          errors.any((error) => error.contains('Content-Length')),
          isTrue,
          reason: 'the $spelling spelling was accepted',
        );
      }

      // The legal decimal forms keep working, including a split body.
      for (final body in const ['', 'ABC']) {
        final legal = await probeOwnedReplayListener(
          response: response(body: 'ok'),
          rawRequests: [
            'GET /probe HTTP/1.1\r\nHost: 127.0.0.1\r\n'
                'Content-Length: ${body.length}\r\nConnection: close\r\n\r\n$body',
          ],
        );
        final row = (legal['requests'] as List).single as Map;
        expect(row['terminal'], 'responded');
        expect(row['body'], body);
        expect(row['bodyLength'], body.length);
      }
    });

    test('unsupported framing and truncated bodies are named refusals', () async {
      Future<List<String>> errorsFor(
        String raw, {
        bool closeAfterWrite = false,
      }) async =>
          ((await probeOwnedReplayListener(
                    response: response(),
                    rawRequests: [raw],
                    closeAfterWrite: closeAfterWrite,
                  ))['serverErrors']
                  as List)
              .cast<String>();

      final chunked = await errorsFor(
        'POST /probe HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n',
      );
      expect(
        chunked.any((error) => error.contains('Transfer-Encoding')),
        isTrue,
      );

      final expectContinue = await errorsFor(
        'GET /probe HTTP/1.1\r\nHost: x\r\nExpect: 100-continue\r\n\r\n',
      );
      expect(expectContinue.any((error) => error.contains('Expect')), isTrue);

      final badLength = await errorsFor(
        'GET /probe HTTP/1.1\r\nHost: x\r\nContent-Length: -2\r\n\r\n',
      );
      expect(
        badLength.any((error) => error.contains('Content-Length')),
        isTrue,
      );

      final truncated = await errorsFor(
        'GET /probe HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nAB',
        closeAfterWrite: true,
      );
      expect(truncated.any((error) => error.contains('declared body')), isTrue);

      final badRequestLine = await errorsFor('GET\r\nHost: x\r\n\r\n');
      expect(
        badRequestLine.any((error) => error.contains('request line')),
        isTrue,
      );
    });
  });

  group('the full-review repairs', () {
    late Directory work;
    late String libraryPath;
    late String librarySha;
    late Map<String, dynamic> corpus;
    late String corpusLf;

    setUpAll(() {
      work = Directory.systemTemp.createTempSync('http-boundary-full-');
      final library = File('${work.path}${Platform.pathSeparator}fjs.dll')
        ..writeAsBytesSync(List<int>.generate(32, (index) => index));
      libraryPath = library.path;
      librarySha = sha256File(library);
      corpus = loadHttpBoundaryCorpus();
      corpusLf = httpBoundaryCorpusSha256Lf(File(httpBoundaryCorpusPath));
    });

    tearDownAll(() => work.deleteSync(recursive: true));

    Map<String, dynamic> fresh() {
      final record = _validProductCopy(
        libraryPath: libraryPath,
        librarySha: librarySha,
      );
      (record['identity'] as Map)['corpusSha256Lf'] = corpusLf;
      return record;
    }

    void gate(Map<String, dynamic> record) => validateProductReport(
      record,
      corpus: corpus,
      corpusLf: corpusLf,
      productPath: 'synthetic-product.json',
    );

    Map<String, dynamic> observation(Map<String, dynamic> record, String id) =>
        (record['observations'] as List)
            .cast<Map>()
            .firstWhere((row) => row['id'] == id)
            .cast<String, dynamic>();

    Map<String, dynamic> firstRequest(Map<String, dynamic> record) =>
        (record['requests'] as List).first as Map<String, dynamic>;

    Map<String, dynamic> failureConnection(Map<String, dynamic> record) =>
        ((record['failEndpoint'] as Map)['connections'] as List).first
            as Map<String, dynamic>;

    test('send facts exist only where bytes were really written', () {
      final responded = fresh();
      firstRequest(responded)['sentAtNanos'] = 0;
      expect(() => gate(responded), throwsA(isA<HttpBoundaryRefusal>()));

      final aborted = fresh();
      final held = (aborted['requests'] as List).cast<Map>().firstWhere(
        (row) => row['terminal'] == 'client-aborted',
      );
      held['sentAtNanos'] = 12345;
      expect(() => gate(aborted), throwsA(isA<HttpBoundaryRefusal>()));

      final sequence = fresh();
      final answered = firstRequest(sequence);
      answered['sendSequence'] = 0;
      expect(() => gate(sequence), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('the failure connection is the declared source request', () {
      final method = fresh();
      failureConnection(method)['method'] = 'POST';
      expect(() => gate(method), throwsA(isA<HttpBoundaryRefusal>()));

      final target = fresh();
      final altered = failureConnection(target);
      altered['path'] = '/controller-other';
      altered['rawQuery'] = 'q=altered';
      altered['target'] = '/controller-other?q=altered';
      expect(() => gate(target), throwsA(isA<HttpBoundaryRefusal>()));

      final header = fresh();
      (failureConnection(header)['headers'] as Map)['x-declared'] =
          'controller-altered';
      expect(() => gate(header), throwsA(isA<HttpBoundaryRefusal>()));

      // The comparison half: a golden whose attempt differs is a mismatch, not a
      // silent pass, even on an already-failing baseline.
      final golden = _report()..['failEndpoint'] = _report()['failEndpoint'];
      final goldenConnection =
          ((golden['failEndpoint'] as Map)['connections'] as List).first as Map;
      goldenConnection['method'] = 'HEAD';
      final compared = compareHttpBoundaryRecords(
        golden: golden.cast<String, dynamic>(),
        product: _product().cast<String, dynamic>(),
        corpus: _corpus().cast<String, dynamic>(),
        goldenId: 'synthetic',
      );
      expect(
        compared.mismatches.any(
          (mismatch) =>
              mismatch.surface == 'failEndpoint' && mismatch.field == 'method',
        ),
        isTrue,
      );
    });

    test('a rate reset record stays inside its own operation interval', () {
      final record = fresh();
      final evidence = observation(record, 'rate.record.3')['evidence'] as Map;
      final value = observation(record, 'rate.record.3')['value'] as Map;
      final after = value['recordAfter'] as Map;
      after['time'] = (after['time'] as int) + 86400000;
      evidence['windowAdvanceMillis'] =
          (evidence['windowAdvanceMillis'] as int) + 86400000;
      expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('the batch block keeps its declared integer fields', () {
      for (final field in const ['cohortSize', 'cohortTimeoutMs']) {
        final record = fresh();
        final batch =
            observation(record, 'helper.ajaxAll-order')['value']['batch']
                as Map;
        batch[field] = (batch[field] as int).toDouble();
        expect(
          () => gate(record),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason: 'a $field double was accepted',
        );
      }
      final missing = fresh();
      (observation(missing, 'helper.ajaxAll-order')['value']['batch'] as Map)
          .remove('cohortSize');
      expect(() => gate(missing), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test(
      'the owned teardown settles workers before the database and native steps',
      () async {
        final steps = <String>[];
        final settled = await settleOwnedTeardown(
          workers: [Future<void>.value()],
          deadline: const Duration(seconds: 5),
          closeDatabase: () async => steps.add('closeDatabase'),
          disposeNative: () async => steps.add('disposeNative'),
        );
        expect(settled.workerSettled, isTrue);
        expect(settled.residueRetained, isFalse);
        expect(settled.stepsRun, ['closeDatabase', 'disposeNative']);
        expect(steps, ['closeDatabase', 'disposeNative']);

        // An owned worker that never settles: the database and native callbacks do
        // not run and the owned residue is retained.
        final never = Completer<void>();
        addTearDown(() => never.complete());
        final retainedSteps = <String>[];
        final busy = await settleOwnedTeardown(
          workers: [never.future],
          deadline: const Duration(milliseconds: 50),
          closeDatabase: () async => retainedSteps.add('closeDatabase'),
          disposeNative: () async => retainedSteps.add('disposeNative'),
        );
        expect(busy.workerSettled, isFalse);
        expect(busy.residueRetained, isTrue);
        expect(busy.stepsRun, isEmpty);
        expect(retainedSteps, isEmpty);
      },
    );
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
