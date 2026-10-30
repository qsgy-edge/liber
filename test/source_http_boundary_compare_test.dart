import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import '../tool/http_boundary/compare.dart';
import 'package:liber/source/js_source_runtime.dart' show SourceScriptError;
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
        HttpBoundaryTeardownReceipt,
        probeHeaderMapEvaluationError,
        sha256Text,
        httpBoundaryBookCarrierOf,
        httpBoundaryBookTypeOf,
        httpBoundaryObservationIds,
        loadHttpBoundaryCorpus,
        sha256File,
        validateHttpBoundaryCorpus,
        validateHttpBoundaryScriptProbeProjection,
        validateHttpBoundaryScriptProbeEnvelope;

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
Map<String, Object?> _validProbeProjection() => {
  'getDot': <String, Object?>{'type': 'string', 'text': 'synthetic'},
  'getBracket': <String, Object?>{'type': 'string', 'text': 'synthetic'},
  'keySetDot': <String, Object?>{'type': 'function', 'text': null},
  'keySetBracket': <String, Object?>{'type': 'function', 'text': null},
  'lookup': <String, Object?>{
    'returned': true,
    'type': 'string',
    'strictLiteral': true,
    'looseLiteral': true,
    'text': 'synthetic',
  },
  'enumeration': <String, Object?>{
    'returned': true,
    'keys': ['User-Agent', 'X-Declared'],
  },
};

Map<String, Object?> _validProbeDiagnostics() => {
  'lookup': <String, Object?>{'caught': false},
  'enumeration': <String, Object?>{'caught': false},
};

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
  final books = {
    for (final raw in (corpus['books'] as List).cast<Map>())
      '${raw['id']}': raw.cast<String, dynamic>(),
  };
  final owners = httpBoundaryResponseOwners(corpus);
  final sources = {
    for (final raw in (corpus['sources'] as List).cast<Map>())
      '${raw['id']}': (raw['bookSource'] as Map).cast<String, dynamic>(),
  };
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
    // The frozen carrier schema of the successful declared stages, read from
    // the same source object the runner hands to the pipeline. A search result
    // publishes origin/originName strings and an integer type; details publish
    // only the origin string. Failed/cancelled stages keep their own shape.
    final corpusStage = '${step['stage'] ?? ''}';
    final carrierSource = sources['${step['source']}'];
    if ('${step['kind']}' == 'stage' &&
        '${step['expectedOutcome'] ?? 'ok'}' == 'ok' &&
        carrierSource != null &&
        (corpusStage == 'search' || corpusStage == 'details')) {
      final carrier = httpBoundaryBookCarrierOf(carrierSource);
      if (corpusStage == 'search') {
        value['results'] = [
          for (final raw in (step['expectBooks'] as List? ?? const []))
            {'id': '$raw', ...carrier},
        ];
      } else {
        value['origin'] = carrier['origin'];
        final declaredBook = books['${step['book']}'];
        if (declaredBook != null) {
          value['bookUrl'] = declaredBook['bookUrl'];
        }
      }
    }
    final evidence = <String, Object?>{};
    if ('${step['action']}' == 'scriptProbe') {
      value
        ..clear()
        ..addAll({
          'kind': 'helper',
          'action': 'scriptProbe',
          'source': '${step['source']}',
          'result': _validProbeProjection(),
        });
      evidence['scriptProbe'] = {'diagnostics': _validProbeDiagnostics()};
    }
    if (step['carrier'] != null) {
      final same = '${step['carrier']}' == 'same';
      value['counterAfter'] = same ? '1' : '2';
      final book = books['${step['book']}']!;
      evidence['carrier'] = {
        'declared': '${step['carrier']}',
        'actual': '${step['carrier']}',
        'pipelineIdentity': same ? 101 : 102,
        'cachedPipelineIdentity': 101,
        'reusedPipeline': same,
        'transportIdentity': same ? 201 : 202,
        'cachedTransportIdentity': 201,
        'distinctTransport': !same,
        'sourceObjectIdentity': 301,
        'cachedSourceObjectIdentity': 301,
        'hostStateIdentity': 401,
        'sourceKey': 'http://127.0.0.1:18771/o',
      };
      evidence['hitReference'] = {
        'identity': 501,
        'storedIdentity': 501,
        'sameObject': true,
        'bookId': '${step['book']}',
        'rawAddress': '${book['bookUrl']}',
        'preOptionUrl': 'http://127.0.0.1:18771/o/book',
        'sourceKey': 'http://127.0.0.1:18771/o',
        'counterAfter': same ? '1' : '2',
      };
    }
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
  final declaredTotal = httpBoundaryStructuralOf(corpus)['requests'] as int;
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
      'declaredTotal': declaredTotal,
      'actualTotal': requests.length,
      'totalMatch': requests.length == declaredTotal,
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
      'stepsAttempted': ['snapshotDatabase', 'closeDatabase', 'disposeNative'],
      'stepsRun': ['snapshotDatabase', 'closeDatabase', 'disposeNative'],
      'errors': <Object?>[],
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

// --- the approved Java-return string contract --------------------------------
//
// The captured identities come from the independent difference audit: twelve
// scalar helper leaves whose typeof is object and whose strict literal equality
// fails in the native capture while the product returns the primitive string,
// plus the two V rows whose measured field is a whole JSON probe envelope
// string. Each envelope differs only on the leaves listed below; every other
// key, value and shape agrees, and the encoded native envelope is the captured
// expected string itself.

const _capturedScalarLeaves =
    <({String row, String field, Object? expected, Object? observed})>[
      (
        row: 'helper.script-probe-hg0',
        field: 'value.result.lookup.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg0',
        field: 'value.result.lookup.strictLiteral',
        expected: false,
        observed: true,
      ),
      (
        row: 'helper.script-probe-hg1',
        field: 'value.result.getDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg1',
        field: 'value.result.getBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        field: 'value.result.keySetDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        field: 'value.result.keySetBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        field: 'value.result.lookup.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg2',
        field: 'value.result.lookup.strictLiteral',
        expected: false,
        observed: true,
      ),
      (
        row: 'helper.script-probe-hg3',
        field: 'value.result.getDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        field: 'value.result.getBracket.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        field: 'value.result.keySetDot.type',
        expected: 'object',
        observed: 'string',
      ),
      (
        row: 'helper.script-probe-hg3',
        field: 'value.result.keySetBracket.type',
        expected: 'object',
        observed: 'string',
      ),
    ];

const _latestChapterTitleNative = <String, Object?>{
  'directType': 'string',
  'directStrict': true,
  'directText': 'direct',
  'chainedType': 'object',
  'chainedStrict': false,
  'chainedLoose': true,
  'chainedText': 'direct',
  'bookBeforeType': 'object',
  'bookBeforeStrict': false,
  'bookBeforeText': '',
  'bookPutType': 'boolean',
  'bookPutStrict': true,
  'bookAfterType': 'object',
  'bookAfterStrict': false,
  'bookAfterLoose': true,
  'bookAfterText': 'bv',
  'sourceBeforeType': 'object',
  'sourceBeforeStrict': false,
  'sourceBeforeText': '',
  'sourceAfterType': 'object',
  'sourceAfterStrict': false,
  'sourceAfterLoose': true,
  'sourceAfterText': 'sv',
};

const _latestChapterTitleProductOverrides = <String, Object?>{
  'chainedType': 'string',
  'chainedStrict': true,
  'bookBeforeType': 'string',
  'bookBeforeStrict': true,
  'bookAfterType': 'string',
  'bookAfterStrict': true,
  'sourceBeforeType': 'string',
  'sourceBeforeStrict': true,
  'sourceAfterType': 'string',
  'sourceAfterStrict': true,
};

const _contentTextNative = <String, Object?>{
  'directType': 'string',
  'directStrict': true,
  'directText': 'P1',
  'chapterBeforeType': 'object',
  'chapterBeforeStrict': false,
  'chapterBeforeText': '',
  'chapterPutType': 'boolean',
  'chapterPutStrict': true,
  'chapterAfterType': 'object',
  'chapterAfterStrict': false,
  'chapterAfterLoose': true,
  'chapterAfterText': 'cv',
  'bookPersistType': 'object',
  'bookPersistStrict': false,
  'bookPersistLoose': true,
  'bookPersistText': 'bv',
  'sourcePersistType': 'object',
  'sourcePersistStrict': false,
  'sourcePersistLoose': true,
  'sourcePersistText': 'sv',
};

const _contentTextProductOverrides = <String, Object?>{
  'chapterBeforeType': 'string',
  'chapterBeforeStrict': true,
  'chapterAfterType': 'string',
  'chapterAfterStrict': true,
  'bookPersistType': 'string',
  'bookPersistStrict': true,
  'sourcePersistType': 'string',
  'sourcePersistStrict': true,
};

/// The two V rows whose measured field is one whole JSON envelope string.
final _capturedEnvelopes =
    <
      ({
        String row,
        String stage,
        String field,
        Map<String, Object?> native,
        Map<String, Object?> product,
      })
    >[
      (
        row: 'v1.details',
        stage: 'details',
        field: 'value.latestChapterTitle',
        native: _latestChapterTitleNative,
        product: {
          ..._latestChapterTitleNative,
          ..._latestChapterTitleProductOverrides,
        },
      ),
      (
        row: 'v1.content',
        stage: 'content',
        field: 'value.text',
        native: _contentTextNative,
        product: {..._contentTextNative, ..._contentTextProductOverrides},
      ),
    ];

/// The committed v3 corpus' own step and source declarations, so a row is bound
/// to its real corpus identity instead of an invented one.
Map<String, Object?> _committedStep(String id) =>
    ((loadHttpBoundaryCorpus()['steps'] as List).cast<Map>().firstWhere(
      (step) => step['id'] == id,
    )).cast<String, Object?>();

Map<String, Object?> _committedSource(String id) =>
    ((loadHttpBoundaryCorpus()['sources'] as List).cast<Map>().firstWhere(
      (source) => source['id'] == id,
    )).cast<String, Object?>();

/// A synthetic v3 corpus that carries one committed row: its own step
/// declaration and source. The declared request prefix is emptied because these
/// records carry no request trace, while every identity the classifier reads
/// (id, family, action, stage, source) stays the committed one.
Map<String, Object?> _v3CorpusWithRow(String stepId) {
  final corpus = _corpus();
  corpus['corpusVersion'] = 3;
  final step = _committedStep(stepId);
  corpus['sources'] = <Object?>[
    ...(corpus['sources'] as List),
    _committedSource('${step['source']}'),
  ];
  corpus['steps'] = <Object?>[
    ...(corpus['steps'] as List),
    <String, Object?>{
      ...step,
      'requests': {'ordered': <Object?>[]},
    },
  ];
  return corpus;
}

/// One synthetic v3 record pair whose only difference is one whole envelope
/// string on the row's own field, so the difference the comparer reports is the
/// measured field itself and not a parsed sub-result.
HttpBoundaryComparison _v3EnvelopeComparison({
  required String rowId,
  required String stage,
  required String field,
  required String nativeText,
  required String productText,
}) {
  // The measured field is the public observation path `value.<leaf>`; inside
  // the row's value map the difference is that leaf itself.
  final leaf = field.substring('value.'.length);
  Map<String, Object?> envelopeRow(String text) => {
    'id': rowId,
    'outcome': 'ok',
    'category': null,
    'value': {'kind': 'stage', 'stage': stage, 'source': 'V', leaf: text},
  };
  final golden = _report()..['corpusVersion'] = 3;
  (golden['observations'] as List).add(envelopeRow(nativeText));
  final product = _product()..['corpusVersion'] = 3;
  (product['observations'] as List).add(envelopeRow(productText));
  return compareHttpBoundaryRecords(
    golden: golden.cast<String, dynamic>(),
    product: product.cast<String, dynamic>(),
    corpus: _v3CorpusWithRow(rowId).cast<String, dynamic>(),
    goldenId: 'synthetic',
  );
}

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

  test('an approved configured width is a named difference, not a pass', () {
    // The strict mismatch stays in the difference list; the amended contract
    // also requires the harness to name the approved disposition with both
    // values. A narrow classifier must attribute this one and nothing else.
    final corpus = _corpus()..['runtime'] = {'threadCountDefault': 16};
    final golden = _report();
    final product = _product();
    (product['runtimeConfiguration'] as Map)['threadCount'] = 4;
    final comparison = compareHttpBoundaryRecords(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: corpus.cast<String, dynamic>(),
      goldenId: 'synthetic',
    );
    expect(comparison.mismatches, hasLength(1));
    expect(comparison.passed, isFalse);
    final named = comparison.toJson()['notCompared'] as List;
    expect(named, hasLength(1));
    expect(named.single['approved'], 'ajaxall-configured-width');
    expect(
      named.single['observation'],
      'runtimeConfiguration|batch-width|threadCount',
    );
    expect(named.single['expected'], 16);
    expect(named.single['observed'], 4);
    expect(comparison.toJson()['unattributedCount'], 0);
  });

  test('an unknown width stays an unattributed strict failure', () {
    final corpus = _corpus()..['runtime'] = {'threadCountDefault': 16};
    final golden = _report();
    final product = _product();
    (product['runtimeConfiguration'] as Map)['threadCount'] = 8;
    final comparison = compareHttpBoundaryRecords(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: corpus.cast<String, dynamic>(),
      goldenId: 'synthetic',
    );
    expect(comparison.mismatches, hasLength(1));
    expect(comparison.notCompared, isEmpty);
    expect(comparison.toJson()['unattributedCount'], 1);
  });

  test('only the declared cohort rows can carry a width consequence', () {
    final corpus = loadHttpBoundaryCorpus();
    HttpBoundaryMismatch request(
      String row,
      String field,
      Object? expected,
      Object? observed,
    ) => HttpBoundaryMismatch(
      surface: 'request',
      row: row,
      field: field,
      expected: expected,
      observed: observed,
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: request(
          'helper.ajaxAll-width|GET /h1/width/2?|1',
          'cohortComplete',
          true,
          false,
        ),
      )?.approved,
      'ajaxall-configured-width',
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: request(
          's1.toc|GET /s/book/1/toc2?|1',
          'releaseReason',
          'complete',
          'cohort-window',
        ),
      )?.approved,
      'page-list-scheduling',
    );
    // An undeclared selector, a wrong value pair and a non-cohort field are
    // never absorbed by the approved scheduling facts.
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: request(
          'helper.ajaxAll-width|GET /h1/width/9?|1',
          'cohortComplete',
          true,
          false,
        ),
      ),
      isNull,
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: request(
          'helper.ajaxAll-width|GET /h1/width/2?|1',
          'releaseReason',
          'complete',
          'incomplete-schedule',
        ),
      ),
      isNull,
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: request(
          'helper.ajaxAll-width|GET /h1/width/2?|1',
          'status',
          200,
          500,
        ),
      ),
      isNull,
    );
  });

  test(
    'the zero-argument extension is named only while its map is the false form',
    () {
      final corpus = loadHttpBoundaryCorpus();
      Map<String, Object?> product(String zeroValue) => {
        'observations': [
          {
            'id': 'helper.header-map-js',
            'value': {
              'arities': {
                'zero': {
                  'returned': true,
                  'value': [
                    ['User-Agent', 'HTTP-BOUNDARY-01/1.0'],
                    ['X-Script', zeroValue],
                  ],
                },
                'falseArity': {
                  'returned': true,
                  'value': [
                    ['User-Agent', 'HTTP-BOUNDARY-01/1.0'],
                    ['X-Script', 's1'],
                  ],
                },
              },
            },
          },
        ],
      };
      const returned = HttpBoundaryMismatch(
        surface: 'observation',
        row: 'helper.header-map-js',
        field: 'value.arities.zero.returned',
        expected: false,
        observed: true,
      );
      const value = HttpBoundaryMismatch(
        surface: 'observation',
        row: 'helper.header-map-js',
        field: 'value.arities.zero.value',
        kind: 'extra-observed-field',
        expected: null,
        observed: [
          ['User-Agent', 'HTTP-BOUNDARY-01/1.0'],
          ['X-Script', 's1'],
        ],
      );
      expect(
        attributeHttpBoundaryMismatch(
          corpus: corpus,
          product: product('s1'),
          mismatch: returned,
        )?.approved,
        'header-map-zero-arity',
      );
      expect(
        attributeHttpBoundaryMismatch(
          corpus: corpus,
          product: product('s1'),
          mismatch: value,
        )?.approved,
        'header-map-zero-arity',
      );
      // A corrupt zero-argument map is not the approved extension: neither the
      // returned fact nor its value may hide behind the approval.
      expect(
        attributeHttpBoundaryMismatch(
          corpus: corpus,
          product: product('OTHER'),
          mismatch: returned,
        ),
        isNull,
      );
      expect(
        attributeHttpBoundaryMismatch(
          corpus: corpus,
          product: product('OTHER'),
          mismatch: value,
        ),
        isNull,
      );
    },
  );

  test('the two cancellation owner labels are named and nothing else', () {
    final corpus = loadHttpBoundaryCorpus();
    const owner = HttpBoundaryMismatch(
      surface: 'observation',
      row: 's5.search-cancelled',
      field: 'value.execution.jobLevel',
      expected: 'created-parent',
      observed: 'pipeline-cancellation',
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: owner,
      )?.approved,
      'cancellation-owner-provenance',
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: const HttpBoundaryMismatch(
          surface: 'observation',
          row: 's6.search-after-cancel',
          field: 'value.followUp.jobLevel',
          expected: 'created-parent',
          observed: 'pipeline-cancellation',
        ),
      )?.approved,
      'cancellation-owner-provenance',
    );
    // A different label and every behavioral fact beside it stay strict: the
    // owner-name disposition cannot conceal a cancellation failure.
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: const HttpBoundaryMismatch(
          surface: 'observation',
          row: 's5.search-cancelled',
          field: 'value.execution.jobLevel',
          expected: 'created-parent',
          observed: 'invented-owner',
        ),
      ),
      isNull,
    );
    expect(
      attributeHttpBoundaryMismatch(
        corpus: corpus,
        product: const {},
        mismatch: const HttpBoundaryMismatch(
          surface: 'observation',
          row: 's5.search-cancelled',
          field: 'value.workerTerminated',
          expected: true,
          observed: false,
        ),
      ),
      isNull,
    );
  });

  test('the captured HG0 returned-map pair stays strict and is named', () {
    // `helper.script-probe-hg0`'s captured pair, with the values the native
    // capture and the product record measured: Rhino returns the header map's
    // `X-Declared` value as a Java String object, so its typeof is `object` and
    // its strict literal equality fails; the product returns a primitive JS
    // string, so its typeof is `string` and the strict comparison is true. Only
    // these two leaves differ; the loose equality and every other leaf already
    // agree and come from this file's synthetic probe projection. The strict
    // mismatch must stay in the difference list, and the comparer must name it
    // `java-return-string-identity` instead of leaving it unattributed. A
    // named difference is not equality, so the comparison still does not pass.
    Map<String, Object?> projection({
      required String lookupType,
      required bool strictLiteral,
    }) {
      final result = _validProbeProjection();
      (result['lookup'] as Map)
        ..['type'] = lookupType
        ..['strictLiteral'] = strictLiteral;
      return result;
    }

    Map<String, Object?> probeObservation({
      required String lookupType,
      required bool strictLiteral,
    }) => {
      'id': 'helper.script-probe-hg0',
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'helper',
        'action': 'scriptProbe',
        'source': 'HG0',
        'result': projection(
          lookupType: lookupType,
          strictLiteral: strictLiteral,
        ),
      },
    };

    final corpus = _corpus();
    corpus['corpusVersion'] = 3;
    // The probe row belongs to the committed corpus' own HG0 source, so the
    // step's declaration and its source definition are not invented here.
    final hg0 =
        ((loadHttpBoundaryCorpus()['sources'] as List).cast<Map>().firstWhere(
          (source) => source['id'] == 'HG0',
        )).cast<String, Object?>();
    // The scaffolding's own source list is reified with narrower element types,
    // so the HG0 entry rides in a fresh list beside the original entries.
    corpus['sources'] = <Object?>[...(corpus['sources'] as List), hg0];
    (corpus['steps'] as List).add({
      'id': 'helper.script-probe-hg0',
      'kind': 'helper',
      'family': 'helper',
      'source': 'HG0',
      'action': 'scriptProbe',
      'requests': {'ordered': <Object?>[]},
      'expectedOutcome': 'ok',
    });
    final golden = _report()..['corpusVersion'] = 3;
    (golden['observations'] as List).add(
      probeObservation(lookupType: 'object', strictLiteral: false),
    );
    final product = _product()..['corpusVersion'] = 3;
    (product['observations'] as List).add(
      probeObservation(lookupType: 'string', strictLiteral: true),
    );
    final comparison = compareHttpBoundaryRecords(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: corpus.cast<String, dynamic>(),
      goldenId: 'synthetic',
    );

    // The raw difference survives: two leaves, both values as measured.
    expect(comparison.mismatches, hasLength(2));
    HttpBoundaryMismatch measured(String field) =>
        comparison.mismatches.firstWhere(
          (mismatch) =>
              mismatch.row == 'helper.script-probe-hg0' &&
              mismatch.field == field,
          orElse: () => throw StateError('no HG0 mismatch at $field'),
        );
    final lookupType = measured('value.result.lookup.type');
    expect(lookupType.surface, 'observation');
    expect(lookupType.kind, 'type-or-value');
    expect(lookupType.expected, 'object');
    expect(lookupType.observed, 'string');
    final strictLiteral = measured('value.result.lookup.strictLiteral');
    expect(strictLiteral.surface, 'observation');
    expect(strictLiteral.kind, 'type-or-value');
    expect(strictLiteral.expected, false);
    expect(strictLiteral.observed, true);
    expect(comparison.passed, isFalse);

    // Both are named as the approved Java-return string identity, and each
    // named entry is the same measured mismatch rather than a second pass.
    expect(
      {for (final entry in comparison.notCompared) entry.approved},
      {'java-return-string-identity'},
    );
    expect(
      {for (final entry in comparison.notCompared) entry.mismatch.key},
      {lookupType.key, strictLiteral.key},
    );
    final output = comparison.toJson();
    expect(output['mismatchCount'], 2);
    expect(output['notComparedCount'], 2);
    expect(output['unattributedCount'], 0);
    expect(output['passed'], isFalse);
  });

  // One case per independently captured field identity: the strict mismatch
  // keeps its own values and the classifier names that same mismatch.
  for (final leaf in _capturedScalarLeaves) {
    test(
      'the captured ${leaf.row} ${leaf.field} pair is a named Java-return string',
      () {
        final mismatch = HttpBoundaryMismatch(
          surface: 'observation',
          row: leaf.row,
          field: leaf.field,
          expected: leaf.expected,
          observed: leaf.observed,
          kind: 'type-or-value',
        );
        final named = attributeHttpBoundaryMismatch(
          corpus: _v3CorpusWithRow(leaf.row).cast<String, dynamic>(),
          product: const {},
          mismatch: mismatch,
        );
        expect(named?.approved, 'java-return-string-identity');
        expect(named!.mismatch, same(mismatch));
        expect(named.mismatch.expected, leaf.expected);
        expect(named.mismatch.observed, leaf.observed);
        expect(named.reason, isNotEmpty);
      },
    );
  }

  for (final envelope in _capturedEnvelopes) {
    test(
      'the captured ${envelope.row} ${envelope.field} envelope is one named Java-return string',
      () {
        final nativeText = jsonEncode(envelope.native);
        final productText = jsonEncode(envelope.product);
        final comparison = _v3EnvelopeComparison(
          rowId: envelope.row,
          stage: envelope.stage,
          field: envelope.field,
          nativeText: nativeText,
          productText: productText,
        );
        // The measured difference is one whole-field string pair, not a
        // rewritten parsed result, and it survives as a strict mismatch.
        expect(comparison.mismatches, hasLength(1));
        final mismatch = comparison.mismatches.single;
        expect(mismatch.surface, 'observation');
        expect(mismatch.row, envelope.row);
        expect(mismatch.field, envelope.field);
        expect(mismatch.kind, 'type-or-value');
        expect(mismatch.expected, nativeText);
        expect(mismatch.observed, productText);
        expect(comparison.passed, isFalse);
        expect(
          [for (final entry in comparison.notCompared) entry.approved],
          ['java-return-string-identity'],
        );
        expect(comparison.notCompared.single.mismatch, same(mismatch));
        expect(comparison.toJson()['unattributedCount'], 0);
      },
    );
  }

  test('a scalar Java-return mismatch outside the measured identities is '
      'unattributed', () {
    String? named(
      Map<String, Object?> corpus,
      String row,
      String field,
      Object? expected,
      Object? observed, {
      String kind = 'type-or-value',
      String surface = 'observation',
    }) => attributeHttpBoundaryMismatch(
      corpus: corpus.cast<String, dynamic>(),
      product: const {},
      mismatch: HttpBoundaryMismatch(
        surface: surface,
        row: row,
        field: field,
        expected: expected,
        observed: observed,
        kind: kind,
      ),
    )?.approved;
    Map<String, Object?> withStepValue(
      String stepId,
      String key,
      Object? value,
    ) {
      final corpus = _v3CorpusWithRow(stepId);
      ((corpus['steps'] as List).last as Map)[key] = value;
      return corpus;
    }

    // The disposition is a corpus-v3 boundary.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1')..['corpusVersion'] = 2,
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'a corpus that is not version 3',
    );
    // A row the corpus does not declare.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg0'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'an undeclared row',
    );
    // A field measured on another row.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg0'),
        'helper.script-probe-hg0',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'another row\'s measured field',
    );
    // The row bound to a source other than its own.
    expect(
      named(
        withStepValue('helper.script-probe-hg1', 'source', 'HG2'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'a foreign source binding',
    );
    // A declared step that is no longer the measured action.
    expect(
      named(
        withStepValue('helper.script-probe-hg1', 'action', 'headerMap'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'another helper action',
    );
    // The row must keep its helper observation kind as well as its family.
    expect(
      named(
        withStepValue('helper.script-probe-hg0', 'kind', 'stage'),
        'helper.script-probe-hg0',
        'value.result.lookup.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'HG0 declared with another execution kind',
    );
    expect(
      named(
        withStepValue('helper.script-probe-hg1', 'kind', 'stage'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
      ),
      isNull,
      reason: 'HG1 declared with another execution kind',
    );
    // The measured direction is object -> string, never the reverse.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'string',
        'object',
      ),
      isNull,
      reason: 'the reverse direction',
    );
    // Another value pair on the same row and field.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'number',
        'string',
      ),
      isNull,
      reason: 'an unrelated value pair',
    );
    // Another mismatch kind on a measured pair.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
        kind: 'value',
      ),
      isNull,
      reason: 'an unrelated mismatch kind',
    );
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg0'),
        'helper.script-probe-hg0',
        'value.result.lookup.strictLiteral',
        false,
        true,
        kind: 'value',
      ),
      isNull,
      reason: 'a measured boolean pair under another kind',
    );
    // The surrounding leaves of the same projection stay strict.
    for (final leaf in const [
      ('value.result.lookup.text', 'hg0', 'other'),
      ('value.result.lookup.looseLiteral', true, false),
      ('value.result.lookup.returned', true, false),
    ]) {
      expect(
        named(
          _v3CorpusWithRow('helper.script-probe-hg0'),
          'helper.script-probe-hg0',
          leaf.$1,
          leaf.$2,
          leaf.$3,
        ),
        isNull,
        reason: 'the ${leaf.$1} leaf',
      );
    }
    // An injected strict-equality axis where only the type was measured.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1'),
        'helper.script-probe-hg1',
        'value.result.getDot.strictLiteral',
        false,
        true,
      ),
      isNull,
      reason: 'an injected axis',
    );
    // The disposition is an observation-row difference.
    expect(
      named(
        _v3CorpusWithRow('helper.script-probe-hg1'),
        'helper.script-probe-hg1',
        'value.result.getDot.type',
        'object',
        'string',
        surface: 'request',
      ),
      isNull,
      reason: 'another comparison surface',
    );
  });

  test(
    'a V probe envelope outside the measured leaf difference is unattributed',
    () {
      String? named(
        Map<String, Object?> corpus,
        String row,
        String field,
        Object? expected,
        Object? observed,
      ) => attributeHttpBoundaryMismatch(
        corpus: corpus.cast<String, dynamic>(),
        product: const {},
        mismatch: HttpBoundaryMismatch(
          surface: 'observation',
          row: row,
          field: field,
          expected: expected,
          observed: observed,
          kind: 'type-or-value',
        ),
      )?.approved;
      final latest = <String, Object?>{
        ..._latestChapterTitleNative,
        ..._latestChapterTitleProductOverrides,
      };
      final content = <String, Object?>{
        ..._contentTextNative,
        ..._contentTextProductOverrides,
      };
      String? latestNamed(
        Map<String, Object?> product, {
        Map<String, Object?>? corpus,
        String row = 'v1.details',
        String field = 'value.latestChapterTitle',
      }) => named(
        corpus ?? _v3CorpusWithRow('v1.details'),
        row,
        field,
        jsonEncode(_latestChapterTitleNative),
        jsonEncode(product),
      );

      // The measured envelopes themselves are the two positive controls in the
      // suite; this test only fixes the boundaries around them.
      // A changed text leaf, a missing key and a new key are other facts.
      expect(
        latestNamed({...latest, 'directText': 'other'}),
        isNull,
        reason: 'a changed direct text',
      );
      expect(
        latestNamed({...latest}..remove('bookAfterText')),
        isNull,
        reason: 'a missing envelope key',
      );
      expect(
        latestNamed({...latest, 'injected': 'x'}),
        isNull,
        reason: 'a new envelope key',
      );
      // A measured axis with another value or type stays strict.
      expect(
        latestNamed({...latest, 'chainedType': 'number'}),
        isNull,
        reason: 'another value on a measured axis',
      );
      expect(
        latestNamed({...latest, 'chainedStrict': 'yes'}),
        isNull,
        reason: 'another type on a measured axis',
      );
      // An unmeasured boolean leaf keeps its strict comparison.
      expect(
        latestNamed({...latest, 'directStrict': false}),
        isNull,
        reason: 'an unmeasured boolean leaf',
      );
      // A frame that is not a readable envelope at all.
      expect(
        named(
          _v3CorpusWithRow('v1.details'),
          'v1.details',
          'value.latestChapterTitle',
          jsonEncode(_latestChapterTitleNative),
          '{"directType":',
        ),
        isNull,
        reason: 'a truncated envelope',
      );
      expect(
        named(
          _v3CorpusWithRow('v1.details'),
          'v1.details',
          'value.latestChapterTitle',
          jsonEncode(_latestChapterTitleNative),
          'plain text',
        ),
        isNull,
        reason: 'a non-JSON field value',
      );
      // The row and the field of the measured envelope are one identity.
      expect(
        latestNamed(
          latest,
          corpus: _v3CorpusWithRow('v1.content'),
          row: 'v1.content',
        ),
        isNull,
        reason: 'the field on another row',
      );
      expect(
        latestNamed(latest, field: 'value.text'),
        isNull,
        reason: 'another field of the same row',
      );
      // A corpus that is not version 3 does not define this boundary.
      expect(
        latestNamed(
          latest,
          corpus: _v3CorpusWithRow('v1.details')..['corpusVersion'] = 2,
        ),
        isNull,
        reason: 'a corpus that is not version 3',
      );
      // The content text envelope follows the same rules.
      String? contentNamed(
        Map<String, Object?> product, {
        Map<String, Object?>? corpus,
      }) => named(
        corpus ?? _v3CorpusWithRow('v1.content'),
        'v1.content',
        'value.text',
        jsonEncode(_contentTextNative),
        jsonEncode(product),
      );
      expect(
        contentNamed({...content, 'directText': 'P2'}),
        isNull,
        reason: 'a changed content text',
      );
      expect(
        contentNamed({...content}..remove('sourcePersistStrict')),
        isNull,
        reason: 'a missing content key',
      );
      expect(
        named(
          _v3CorpusWithRow('v1.content'),
          'v1.content',
          'value.text',
          jsonEncode(_contentTextNative),
          '{',
        ),
        isNull,
        reason: 'a malformed content envelope',
      );
      // The measured frame must stay on a stage row of its own family and kind.
      Map<String, Object?> withStepValue(
        Map<String, Object?> corpus,
        String key,
        Object? value,
      ) {
        ((corpus['steps'] as List).last as Map)[key] = value;
        return corpus;
      }

      for (final tag in const [('family', 'helper'), ('kind', 'helper')]) {
        expect(
          latestNamed(
            latest,
            corpus: withStepValue(
              _v3CorpusWithRow('v1.details'),
              tag.$1,
              tag.$2,
            ),
          ),
          isNull,
          reason: 'the details frame declared with another ${tag.$1}',
        );
        expect(
          contentNamed(
            content,
            corpus: withStepValue(
              _v3CorpusWithRow('v1.content'),
              tag.$1,
              tag.$2,
            ),
          ),
          isNull,
          reason: 'the content frame declared with another ${tag.$1}',
        );
      }
    },
  );

  test(
    'the frozen book carrier is projected from the actual source context',
    () {
      // The corpus source is only one actual context: changed URL, name and type
      // must change the projection, so 8 cannot be a hardcoded corpus answer.
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://127.0.0.1:18771/other',
        'bookSourceName': 'Another source',
        'bookSourceType': 0,
      };
      expect(httpBoundaryBookCarrierOf(source), {
        'origin': 'http://127.0.0.1:18771/other',
        'originName': 'Another source',
        'type': 8,
      });
      source['bookSourceType'] = 1;
      expect(httpBoundaryBookTypeOf(source['bookSourceType']), 32);
      source['bookSourceType'] = 2;
      expect(httpBoundaryBookTypeOf(source['bookSourceType']), 64);
      source['bookSourceType'] = 3;
      expect(httpBoundaryBookTypeOf(source['bookSourceType']), 136);
      source['bookSourceType'] = 4;
      expect(httpBoundaryBookTypeOf(source['bookSourceType']), 8);
      source['bookSourceType'] = null;
      expect(httpBoundaryBookTypeOf(source['bookSourceType']), 8);
      source['bookSourceType'] = 0;
      source['bookSourceUrl'] = 'http://127.0.0.1:18771/changed';
      expect(
        httpBoundaryBookCarrierOf(source)['origin'],
        'http://127.0.0.1:18771/changed',
      );
    },
  );

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

  test(
    'the shared probe projection refuses empty, missing and wrong types',
    () {
      expect(
        () =>
            validateHttpBoundaryScriptProbeProjection(const {}, where: 'probe'),
        throwsFormatException,
      );
      final missing = _validProbeProjection()..remove('lookup');
      expect(
        () =>
            validateHttpBoundaryScriptProbeProjection(missing, where: 'probe'),
        throwsFormatException,
      );
      final wrongType = _validProbeProjection();
      (wrongType['getDot'] as Map)['type'] = 1;
      expect(
        () => validateHttpBoundaryScriptProbeProjection(
          wrongType,
          where: 'probe',
        ),
        throwsFormatException,
      );
      final missingNullable = _validProbeProjection();
      (missingNullable['getDot'] as Map)['type'] = 'function';
      (missingNullable['getDot'] as Map).remove('text');
      expect(
        () => validateHttpBoundaryScriptProbeProjection(
          missingNullable,
          where: 'probe',
        ),
        throwsFormatException,
      );
      final wrongLookup = _validProbeProjection();
      (wrongLookup['lookup'] as Map)['returned'] = 'yes';
      expect(
        () => validateHttpBoundaryScriptProbeProjection(
          wrongLookup,
          where: 'probe',
        ),
        throwsFormatException,
      );
      final wrongKeys = _validProbeProjection();
      (wrongKeys['enumeration'] as Map)['keys'] = [1];
      expect(
        () => validateHttpBoundaryScriptProbeProjection(
          wrongKeys,
          where: 'probe',
        ),
        throwsFormatException,
      );
      final unexpected = _validProbeProjection();
      unexpected['lookup'] = <String, Object?>{
        'returned': false,
        'errorName': 'RangeError',
      };
      final unexpectedDiagnostics = _validProbeDiagnostics();
      unexpectedDiagnostics['lookup'] = <String, Object?>{
        'caught': true,
        'name': 'RangeError',
        'message': 'injected',
        'text': 'RangeError: injected',
        'stack': null,
      };
      expect(
        () => validateHttpBoundaryScriptProbeEnvelope({
          'portable': unexpected,
          'diagnostics': unexpectedDiagnostics,
        }, where: 'probe'),
        throwsFormatException,
      );
      final wrongDiagnostics = _validProbeDiagnostics();
      (wrongDiagnostics['lookup'] as Map)['caught'] = 'yes';
      expect(
        () => validateHttpBoundaryScriptProbeEnvelope({
          'portable': _validProbeProjection(),
          'diagnostics': wrongDiagnostics,
        }, where: 'probe'),
        throwsFormatException,
      );
      expect(
        validateHttpBoundaryScriptProbeEnvelope({
          'portable': _validProbeProjection(),
          'diagnostics': _validProbeDiagnostics(),
        }, where: 'probe')['portable'],
        isA<Map>(),
      );
    },
  );

  test('diagnostics are provenance and do not enter portable comparison', () {
    final left = _report();
    final right = _product();
    for (final report in [left, right]) {
      (report['observations'] as List).add({
        'id': 'helper.script-probe-hg0',
        'outcome': 'ok',
        'category': null,
        'value': {
          'kind': 'helper',
          'action': 'scriptProbe',
          'source': 'HG0',
          'result': _validProbeProjection(),
        },
        'evidence': {
          'scriptProbe': {
            'diagnostics': {
              'lookup': {
                'caught': true,
                'name': 'TypeError',
                'message': report == left ? 'left message' : 'right message',
                'text': report == left ? 'left text' : 'right text',
                'stack': null,
              },
              'enumeration': {'caught': false},
            },
          },
        },
      });
    }
    expect(_compare(left, right).notCompared, isEmpty);
    expect(
      _compare(
        left,
        right,
      ).mismatches.where((mismatch) => mismatch.surface == 'observation'),
      isEmpty,
    );
  });

  test('the v3 observation controls target their own new rows', () {
    final corpus = loadHttpBoundaryCorpus();
    final oBook = ((corpus['books'] as List).cast<Map>().firstWhere(
      (book) => book['id'] == 'o-book-1',
    )).cast<String, dynamic>();
    final oBookUrl = '${oBook['bookUrl']}';
    final golden = _report();
    final product = _product();
    Map<String, Object?> probeRow() => {
      'id': 'helper.script-probe-hg1',
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'helper',
        'action': 'scriptProbe',
        'source': 'HG1',
        'result': _validProbeProjection(),
      },
      'evidence': {
        'scriptProbe': {'diagnostics': _validProbeDiagnostics()},
      },
    };
    Map<String, Object?> nativeRow() => {
      'id': 'v1.details',
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'stage',
        'stage': 'details',
        'source': 'V',
        'bookUrl': 'http://127.0.0.1:18771/v/book/1',
        'latestChapterTitle': '{"bookAfterText":"bv"}',
      },
    };
    Map<String, Object?> carrierRow(String id, String mode, String counter) => {
      'id': id,
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'stage',
        'stage': 'details',
        'source': 'O',
        'bookUrl': oBookUrl,
        'counterAfter': counter,
      },
      'evidence': {
        'carrier': {
          'declared': mode,
          'actual': mode,
          'pipelineIdentity': mode == 'same' ? 101 : 102,
          'cachedPipelineIdentity': 101,
          'reusedPipeline': mode == 'same',
          'transportIdentity': mode == 'same' ? 201 : 202,
          'cachedTransportIdentity': 201,
          'distinctTransport': mode != 'same',
          'sourceObjectIdentity': 301,
          'cachedSourceObjectIdentity': 301,
          'hostStateIdentity': 401,
          'sourceKey': 'http://127.0.0.1:18771/o',
        },
        'hitReference': {
          'identity': 501,
          'storedIdentity': 501,
          'sameObject': true,
          'bookId': 'o-book-1',
          'rawAddress': oBookUrl,
          'preOptionUrl': 'http://127.0.0.1:18771/o/book',
          'sourceKey': 'http://127.0.0.1:18771/o',
          'counterAfter': counter,
        },
      },
    };
    Map<String, Object?> counterRow() => {
      'id': 'n1.toc',
      'outcome': 'ok',
      'category': null,
      'value': {
        'kind': 'stage',
        'stage': 'toc',
        'source': 'N',
        'chapters': [
          {'index': 0, 'title': 'x', 'url': 'u', 'tag': ''},
        ],
      },
    };
    for (final report in [golden, product]) {
      (report['observations'] as List).addAll(<Map<String, Object?>>[
        probeRow(),
        nativeRow(),
        carrierRow('o1.details-same', 'same', '1'),
        carrierRow('o1.details-fresh', 'fresh', '2'),
        counterRow(),
      ]);
      (report['requests'] as List).addAll(<Map<String, Object?>>[
        _request(
          owner: 'o1.details-same',
          selector: 'GET /o/book/1?',
          path: '/o/book/1',
          declaredResponse: 'o-book-1',
        ),
        _request(
          owner: 'o1.details-fresh',
          selector: 'GET /o/book/2?',
          path: '/o/book/2',
          declaredResponse: 'o-book-2',
        ),
      ]);
    }
    final baseline = compareHttpBoundaryRecords(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: corpus,
      goldenId: 'synthetic',
    );
    final controls = runHttpBoundaryControls(
      golden: golden.cast<String, dynamic>(),
      product: product.cast<String, dynamic>(),
      corpus: corpus,
      goldenId: 'synthetic',
      baseline: baseline,
    );
    Map<String, Object?> control(String id) =>
        controls.firstWhere((control) => control.id == id).toJson();
    expect(
      control('product-script-probe-value')['newMismatchKeys'],
      contains(
        'observation|helper.script-probe-hg1|value.result.lookup.returned|type-or-value',
      ),
    );
    expect(
      control('product-native-return-presence')['newMismatchKeys'],
      contains(
        'observation|v1.details|value.latestChapterTitle|missing-observed-field',
      ),
    );
    expect(
      control('product-fresh-binding')['newMismatchKeys'],
      contains('observation|o1.details-same|value.bookUrl|type-or-value'),
    );
    expect(
      control('product-fresh-substituted-hit')['relationFailure'],
      contains('hit address'),
    );
    expect(
      control('product-fresh-reused-pipeline')['relationFailure'],
      contains('did not use a fresh pipeline'),
    );
    expect(
      control('product-fresh-reused-transport')['relationFailure'],
      contains('did not use a fresh pipeline'),
    );
    expect(
      control('product-fresh-wrong-source-object')['relationFailure'],
      contains('source object is not the cached one'),
    );
    expect(
      control('product-fresh-wrong-stored-hit')['relationFailure'],
      contains('actual hit differs from stored hit'),
    );
    expect(
      control('golden-fresh-retained-book')['relationFailure'],
      contains('retained book identity'),
    );
    expect(
      control('product-same-extra-execution')['newMismatchKeys'],
      contains('observation|o1.details-same|value.counterAfter|type-or-value'),
    );
    expect(
      control('product-fresh-missing-execution')['newMismatchKeys'],
      contains('observation|o1.details-fresh|value.counterAfter|type-or-value'),
    );
    expect(
      control('product-option-counter')['newMismatchKeys'],
      contains('observation|n1.toc|value.chapters.0.title|type-or-value'),
    );
    for (final id in const [
      'product-script-probe-value',
      'product-native-return-presence',
      'product-fresh-binding',
      'product-fresh-substituted-hit',
      'product-fresh-reused-pipeline',
      'product-fresh-reused-transport',
      'product-fresh-wrong-source-object',
      'product-fresh-wrong-stored-hit',
      'golden-fresh-retained-book',
      'product-same-extra-execution',
      'product-fresh-missing-execution',
      'product-option-counter',
    ]) {
      expect(control(id)['passed'], isTrue, reason: '$id must pass');
    }
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

    Map<String, dynamic> goldenRecord() {
      final record = fresh();
      final identity = record['identity'] as Map;
      identity['corpusAssetSha256'] = 'a' * 64;
      identity['targetPackage'] = (corpus['target'] as Map)['package'];
      identity['targetApkSha256'] = (corpus['target'] as Map)['apkSha256'];
      identity['targetBaselineCommit'] =
          (corpus['target'] as Map)['baselineCommit'];
      record['status'] = 'ok';
      record['promotable'] = true;
      record['terminalIntegrityOk'] = true;
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

    Map firstResult(Map<String, dynamic> record, String id) =>
        ((observation(record, id)['value'] as Map)['results'] as List).first
            as Map;

    test('a legitimate record passes the exported gate', () {
      expect(() => gate(fresh()), returnsNormally);
    });

    test('missing or malformed v3 probe facts are refused', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (record) {
          (observation(record, 'helper.script-probe-hg0')['value'] as Map)
              .remove('result');
        },
        (record) {
          (observation(record, 'helper.script-probe-hg0')['value']
                  as Map)['result'] =
              <String, Object?>{};
        },
        (record) {
          final value =
              observation(record, 'helper.script-probe-hg0')['value'] as Map;
          ((value['result'] as Map)['lookup'] as Map)['returned'] = 'yes';
        },
        (record) {
          (observation(record, 'helper.script-probe-hg0')['evidence'] as Map)
              .remove('scriptProbe');
        },
      ]) {
        final record = fresh();
        mutate(record);
        expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
      }
    });

    test(
      'malformed paired hit, pipeline, transport or counter proof is refused',
      () {
        for (final mutate in <void Function(Map<String, dynamic>)>[
          (record) {
            (observation(record, 'o1.details-fresh')['evidence'] as Map).remove(
              'hitReference',
            );
          },
          (record) {
            final hit =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['hitReference']
                    as Map;
            hit['rawAddress'] = 'http://127.0.0.1:18771/o/book/SUBSTITUTED';
          },
          (record) {
            for (final id in const ['o1.details-same', 'o1.details-fresh']) {
              final carrier =
                  (observation(record, id)['evidence'] as Map)['carrier']
                      as Map;
              carrier.remove('sourceObjectIdentity');
              carrier.remove('cachedSourceObjectIdentity');
              carrier.remove('hostStateIdentity');
            }
          },
          (record) {
            final hit =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['hitReference']
                    as Map;
            hit['storedIdentity'] = 999;
          },
          (record) {
            final carrier =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['carrier']
                    as Map;
            carrier['sourceKey'] = 'http://127.0.0.1:18771/other';
          },
          (record) {
            final carrier =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['carrier']
                    as Map;
            carrier['reusedPipeline'] = true;
          },
          (record) {
            final carrier =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['carrier']
                    as Map;
            final same =
                (observation(record, 'o1.details-same')['evidence']
                        as Map)['carrier']
                    as Map;
            carrier['pipelineIdentity'] = same['cachedPipelineIdentity'];
            carrier['reusedPipeline'] = true;
          },
          (record) {
            final carrier =
                (observation(record, 'o1.details-fresh')['evidence']
                        as Map)['carrier']
                    as Map;
            carrier['transportIdentity'] =
                ((observation(record, 'o1.details-same')['evidence']
                        as Map)['carrier']
                    as Map)['transportIdentity'];
            carrier['distinctTransport'] = false;
          },
          (record) {
            (observation(record, 'o1.details-fresh')['value']
                    as Map)['counterAfter'] =
                '1';
          },
        ]) {
          final record = fresh();
          mutate(record);
          expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
        }
      },
    );

    test('a complete v3 record passes the frozen-capture gate', () {
      final record = fresh();
      final identity = record['identity'] as Map;
      identity['corpusAssetSha256'] = 'a' * 64;
      identity['targetPackage'] = (corpus['target'] as Map)['package'];
      identity['targetApkSha256'] = (corpus['target'] as Map)['apkSha256'];
      identity['targetBaselineCommit'] =
          (corpus['target'] as Map)['baselineCommit'];
      record['status'] = 'ok';
      record['promotable'] = true;
      record['terminalIntegrityOk'] = true;
      final file = File('${work.path}${Platform.pathSeparator}positive.json')
        ..writeAsStringSync(jsonEncode(record));
      expect(
        () => validateFrozenCapture(
          record,
          corpus: corpus,
          corpusLf: corpusLf,
          goldenId: 'synthetic-v3',
          expectedReportSha256: sha256File(file),
          reportPath: file.path,
        ),
        returnsNormally,
      );
    });

    test('frozen hit identity must be a present integer per row', () {
      for (final variant in const ['missing', 'null', 'string', 'double']) {
        Map<String, dynamic> mutant() {
          final record = goldenRecord();
          for (final id in const ['o1.details-same', 'o1.details-fresh']) {
            final hit =
                (observation(record, id)['evidence'] as Map)['hitReference']
                    as Map;
            switch (variant) {
              case 'missing':
                hit.remove('identity');
              case 'null':
                hit['identity'] = null;
              case 'string':
                hit['identity'] = '501';
              case 'double':
                hit['identity'] = 501.0;
            }
          }
          return record;
        }

        expect(
          () => validateFrozenCarrierRelations(mutant(), corpus),
          throwsFormatException,
          reason: 'shared frozen rule accepted $variant identity',
        );
        final record = mutant();
        final file = File('${work.path}/frozen-$variant.json')
          ..writeAsStringSync(jsonEncode(record));
        expect(
          () => validateFrozenCapture(
            record,
            corpus: corpus,
            corpusLf: corpusLf,
            goldenId: 'synthetic-$variant',
            expectedReportSha256: sha256File(file),
            reportPath: file.path,
          ),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason: 'exported frozen gate accepted $variant identity',
        );
      }
    });

    test('source and stored identity controls survive 0, 1 and 999', () {
      Map<String, dynamic> carrierOf(Map<String, dynamic> record, String id) =>
          (observation(record, id)['evidence'] as Map)['carrier']
              as Map<String, dynamic>;
      Map<String, dynamic> hitOf(Map<String, dynamic> record, String id) =>
          (observation(record, id)['evidence'] as Map)['hitReference']
              as Map<String, dynamic>;
      for (final value in const [0, 1, 999]) {
        final source = fresh();
        for (final id in const ['o1.details-same', 'o1.details-fresh']) {
          carrierOf(source, id)['sourceObjectIdentity'] = value;
          carrierOf(source, id)['cachedSourceObjectIdentity'] = value;
        }
        expect(() => gate(source), returnsNormally);
        final sourceGolden = fresh();
        final sourceBaseline = compareHttpBoundaryRecords(
          golden: sourceGolden,
          product: source,
          corpus: corpus,
          goldenId: 'synthetic-source-$value',
        );
        final sourceControls = runHttpBoundaryControls(
          golden: sourceGolden,
          product: source,
          corpus: corpus,
          goldenId: 'synthetic-source-$value',
          baseline: sourceBaseline,
        );
        final sourceControl = sourceControls.firstWhere(
          (control) => control.id == 'product-fresh-wrong-source-object',
        );
        expect(
          sourceControl.passed,
          isTrue,
          reason: 'source identity $value control did not mutate',
        );

        final stored = fresh();
        for (final id in const ['o1.details-same', 'o1.details-fresh']) {
          hitOf(stored, id)['identity'] = value;
          hitOf(stored, id)['storedIdentity'] = value;
        }
        expect(() => gate(stored), returnsNormally);
        final storedGolden = fresh();
        final storedBaseline = compareHttpBoundaryRecords(
          golden: storedGolden,
          product: stored,
          corpus: corpus,
          goldenId: 'synthetic-stored-$value',
        );
        final storedControls = runHttpBoundaryControls(
          golden: storedGolden,
          product: stored,
          corpus: corpus,
          goldenId: 'synthetic-stored-$value',
          baseline: storedBaseline,
        );
        final storedControl = storedControls.firstWhere(
          (control) => control.id == 'product-fresh-wrong-stored-hit',
        );
        expect(
          storedControl.passed,
          isTrue,
          reason: 'stored identity $value control did not mutate',
        );
      }
    });

    test('a missing frozen probe replaced by a duplicate is refused', () {
      final record = fresh();
      final observations = record['observations'] as List;
      observations.removeWhere(
        (raw) => (raw as Map)['id'] == 'helper.script-probe-hg0',
      );
      observations.add(
        jsonDecode(jsonEncode(observation(record, 'helper.script-probe-hg1'))),
      );
      final identity = record['identity'] as Map;
      identity['corpusAssetSha256'] = 'a' * 64;
      identity['targetPackage'] = (corpus['target'] as Map)['package'];
      identity['targetApkSha256'] = (corpus['target'] as Map)['apkSha256'];
      identity['targetBaselineCommit'] =
          (corpus['target'] as Map)['baselineCommit'];
      record['status'] = 'ok';
      record['promotable'] = true;
      record['terminalIntegrityOk'] = true;
      final file = File('${work.path}/duplicate-probe.json')
        ..writeAsStringSync(jsonEncode(record));
      expect(
        () => validateFrozenCapture(
          record,
          corpus: corpus,
          corpusLf: corpusLf,
          goldenId: 'synthetic-duplicate',
          expectedReportSha256: sha256File(file),
          reportPath: file.path,
        ),
        throwsA(isA<HttpBoundaryRefusal>()),
      );
    });

    test('an already-invalid relation baseline is refused by controls', () {
      final golden = fresh();
      final record = fresh();
      final carrier =
          (observation(record, 'o1.details-fresh')['evidence']
                  as Map)['carrier']
              as Map;
      carrier['pipelineIdentity'] = carrier['cachedPipelineIdentity'];
      carrier['reusedPipeline'] = true;
      final baseline = compareHttpBoundaryRecords(
        golden: golden,
        product: record,
        corpus: corpus,
        goldenId: 'synthetic-invalid',
      );
      expect(
        () => runHttpBoundaryControls(
          golden: golden,
          product: record,
          corpus: corpus,
          goldenId: 'synthetic-invalid',
          baseline: baseline,
        ),
        throwsA(isA<HttpBoundaryRefusal>()),
      );
    });

    test('the retained book identity is not the analyzed request target', () {
      final record = fresh();
      (observation(record, 'o1.details-fresh')['value'] as Map)['bookUrl'] =
          'http://127.0.0.1:18771/o/book/1';
      expect(() => gate(record), throwsA(isA<HttpBoundaryRefusal>()));
    });

    test('the published carrier type is a required integer, not a double', () {
      // The comparer's numeric equality accepts 8 and 8.0; the product-record
      // schema is what keeps the newly published type an actual integer.
      for (final id in const ['s1.search', 's6.search-after-cancel']) {
        final record = fresh();
        firstResult(record, id)['type'] = 8.0;
        expect(
          () => gate(record),
          throwsA(isA<HttpBoundaryRefusal>()),
          reason: '$id accepted a double carrier type',
        );
      }
      // The same decoded JSON number with the declared integer type still
      // passes: this is a type gate, not a second value-mapping validator.
      expect(() => gate(fresh()), returnsNormally);
    });

    test(
      'the published carrier fields are present with their declared types',
      () {
        for (final field in const ['origin', 'originName', 'type']) {
          final missing = fresh();
          firstResult(missing, 's1.search').remove(field);
          expect(
            () => gate(missing),
            throwsA(isA<HttpBoundaryRefusal>()),
            reason: 'search $field absence was accepted',
          );
        }
        for (final entry in const [
          ('origin', 7),
          ('originName', false),
          ('type', '8'),
        ]) {
          final wrong = fresh();
          firstResult(wrong, 's1.search')[entry.$1] = entry.$2;
          expect(
            () => gate(wrong),
            throwsA(isA<HttpBoundaryRefusal>()),
            reason: 'search ${entry.$1} wrong type was accepted',
          );
        }
        final missingDetails = fresh();
        (observation(missingDetails, 's1.details')['value'] as Map).remove(
          'origin',
        );
        expect(() => gate(missingDetails), throwsA(isA<HttpBoundaryRefusal>()));

        final wrongDetails = fresh();
        (observation(wrongDetails, 's1.details')['value'] as Map)['origin'] = 7;
        expect(() => gate(wrongDetails), throwsA(isA<HttpBoundaryRefusal>()));

        // Failed, cancelled and non-carrier stages keep their existing shape:
        // the legitimate record itself carries s3.toc-empty.toc, s4 and s5.
        expect(() => gate(fresh()), returnsNormally);
      },
    );

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

    test('the engine typed deadline is an incomplete measurement', () async {
      final work = Directory.systemTemp.createTempSync(
        'http-boundary-deadline-',
      );
      addTearDown(() => work.deleteSync(recursive: true));
      final corpus = loadHttpBoundaryCorpus();
      final typed = await probeHeaderMapEvaluationError(
        error: const SourceScriptError('timeout'),
        corpus: corpus,
        root: work,
      );
      expect(typed['thrownType'], 'HttpBoundaryIncomplete');
      final typedObservation = typed['observation'] as Map;
      expect(typedObservation['outcome'], 'incomplete');
      final provenance =
          (typedObservation['evidence'] as Map)['arityProvenance'] as Map;
      expect((provenance['zero'] as Map)['outcome'], 'deadline');

      final wall = await probeHeaderMapEvaluationError(
        error: TimeoutException('wall-clock deadline'),
        corpus: corpus,
        root: work,
      );
      expect(wall['thrownType'], 'HttpBoundaryIncomplete');
      expect((wall['observation'] as Map)['outcome'], 'incomplete');

      // An ordinary typed binding refusal stays a measured outcome.
      final binding = await probeHeaderMapEvaluationError(
        error: const SourceScriptError('js', 'no such member'),
        corpus: corpus,
        root: work,
      );
      expect(binding['thrownType'], isNull);
      final bindingObservation = binding['observation'] as Map;
      expect(bindingObservation['outcome'], 'ok');
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
        'attempted': (record) =>
            (record['ownedTeardown'] as Map)['stepsAttempted'] = <Object?>[],
        'errors': (record) => (record['ownedTeardown'] as Map)['errors'] = [
          {'step': 'closeDatabase', 'errorType': 'StateError', 'error': 'x'},
        ],
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
      'the owned teardown attempts every safe step once the worker settled',
      () async {
        Future<HttpBoundaryTeardownReceipt> run({
          bool failSnapshot = false,
          bool failClose = false,
          bool failDispose = false,
          Future<void>? worker,
        }) {
          final steps = <String>[];
          return settleOwnedTeardown(
            workers: [?worker],
            deadline: const Duration(milliseconds: 50),
            snapshotDatabase: () async {
              steps.add('snapshotDatabase');
              if (failSnapshot) throw StateError('injected snapshot failure');
            },
            closeDatabase: () async {
              steps.add('closeDatabase');
              if (failClose) throw StateError('injected close failure');
            },
            disposeNative: () async {
              steps.add('disposeNative');
              if (failDispose) throw StateError('injected native failure');
            },
          ).then((receipt) {
            expect(steps, receipt.stepsAttempted);
            return receipt;
          });
        }

        final settled = await run();
        expect(settled.workerSettled, isTrue);
        expect(settled.stepsAttempted, [
          'snapshotDatabase',
          'closeDatabase',
          'disposeNative',
        ]);
        expect(settled.stepsRun, settled.stepsAttempted);
        expect(settled.errors, isEmpty);
        expect(settled.residueRetained, isFalse);

        // A failing snapshot still attempts the database close and the native
        // disposal; the failure is recorded, not hidden.
        final snapshot = await run(failSnapshot: true);
        expect(snapshot.stepsAttempted, [
          'snapshotDatabase',
          'closeDatabase',
          'disposeNative',
        ]);
        expect(snapshot.stepsRun, ['closeDatabase', 'disposeNative']);
        expect(snapshot.errors.single['step'], 'snapshotDatabase');
        expect(snapshot.errors.single['errorType'], 'StateError');
        expect(snapshot.residueRetained, isTrue);

        final close = await run(failClose: true);
        expect(close.stepsRun, ['snapshotDatabase', 'disposeNative']);
        expect(close.errors.single['step'], 'closeDatabase');

        final dispose = await run(failDispose: true);
        expect(dispose.stepsRun, ['snapshotDatabase', 'closeDatabase']);
        expect(dispose.errors.single['step'], 'disposeNative');

        // An unresolved worker performs none of them.
        final never = Completer<void>();
        addTearDown(() => never.complete());
        final busy = await run(worker: never.future);
        expect(busy.workerSettled, isFalse);
        expect(busy.stepsAttempted, isEmpty);
        expect(busy.stepsRun, isEmpty);
        expect(busy.errors, isEmpty);
        expect(busy.residueRetained, isTrue);
      },
    );
  });

  test('the committed corpus derives the declared structural model', () {
    final corpus = loadHttpBoundaryCorpus();
    final derived = httpBoundaryStructuralOf(corpus);
    expect(derived['observations'], 44);
    expect(derived['requests'], 51);
    expect(derived['responses'], 49);
    expect(derived['helperSelectors'], 12);
    expect(derived['rateSelectors'], 3);
    expect(derived['stageSelectors'], 34);
    expect(derived['stageRequests'], 36);
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

  test('the committed corpus declares the v3 interop observation rows', () {
    final corpus = loadHttpBoundaryCorpus();
    expect(corpus['corpusVersion'], 3);
    final steps = httpBoundarySteps(corpus);
    // Four real installed-app `source.getHeaderMap(false)` probes cover no
    // collision, a data key `get`, a data key `keySet` and both.
    final probes = [
      for (final step in steps)
        if (step['action'] == 'scriptProbe') step,
    ];
    expect(probes, hasLength(4));
    for (final id in const [
      'helper.script-probe-hg0',
      'helper.script-probe-hg1',
      'helper.script-probe-hg2',
      'helper.script-probe-hg3',
    ]) {
      final probe = probes.firstWhere((step) => step['id'] == id);
      expect('${probe['script']}', contains('source.getHeaderMap(false)'));
      final declared = httpBoundaryDeclaredRequests(probe);
      expect(declared.ordered, isEmpty);
      expect(declared.members, isEmpty);
    }
    // One details row declares the narrow fresh-pipeline carrier: a genuinely
    // different product pipeline over the same source object/key and stored hit.
    final fresh = [
      for (final step in steps)
        if (step['carrier'] == 'fresh') step,
    ];
    expect(fresh, hasLength(1));
    expect(fresh.single['stage'], 'details');
    expect(fresh.single['id'], 'o1.details-fresh');
    // The native-return rows route through real book-info and content fields.
    final latest = httpBoundarySteps(
      corpus,
    ).firstWhere((step) => step['id'] == 'v1.details');
    expect(latest['stage'], 'details');
    final content = httpBoundarySteps(
      corpus,
    ).firstWhere((step) => step['id'] == 'v1.content');
    expect(content['stage'], 'content');
    // No declared step lost the original v2 ids or their order prefix.
    expect(
      [for (final step in steps.take(22)) step['id']],
      [
        'helper.ajax',
        'helper.ajax-list-first',
        'helper.ajaxAll-order',
        'helper.ajaxAll-width',
        'helper.connect-header-string',
        'helper.connect-source-header',
        'helper.header-map-js',
        'helper.header-map-ltjs',
        'rate.record.1',
        'rate.record.2',
        'rate.record.3',
        's1.search',
        's1.details',
        's1.toc',
        's1.content',
        's2.retry-non2xx',
        's3.toc-empty.search',
        's3.toc-empty.details',
        's3.toc-empty.toc',
        's4.search-connection-failure',
        's5.search-cancelled',
        's6.search-after-cancel',
      ],
    );
  });

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

  test('the v3 action and carrier declarations are gated', () {
    Map<String, dynamic> copy() =>
        (jsonDecode(jsonEncode(loadHttpBoundaryCorpus())) as Map)
            .cast<String, dynamic>();
    FormatException? refusal(Map<String, dynamic> corpus) {
      try {
        validateHttpBoundaryCorpus(corpus);
        return null;
      } on FormatException catch (error) {
        return error;
      }
    }

    final unknownAction = copy();
    for (final raw in unknownAction['steps'] as List) {
      final step = raw as Map;
      if (step['id'] == 'helper.script-probe-hg0') step['action'] = 'probe';
    }
    expect(refusal(unknownAction), isNotNull);

    final probeWithRequest = copy();
    for (final raw in probeWithRequest['steps'] as List) {
      final step = raw as Map;
      if (step['id'] == 'helper.script-probe-hg0') {
        step['requests'] = {
          'ordered': ['h1-single'],
        };
      }
    }
    expect(refusal(probeWithRequest), isNotNull);

    final carrierOutsideDetails = copy();
    for (final raw in carrierOutsideDetails['steps'] as List) {
      final step = raw as Map;
      if (step['id'] == 'o1.search') step['carrier'] = 'fresh';
    }
    expect(refusal(carrierOutsideDetails), isNotNull);

    final unknownCarrier = copy();
    for (final raw in unknownCarrier['steps'] as List) {
      final step = raw as Map;
      if (step['id'] == 'o1.details-fresh') step['carrier'] = 'stored';
    }
    expect(refusal(unknownCarrier), isNotNull);
  });
}
