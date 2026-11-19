import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_state.dart';

import 'first_slice/runner.dart' show SliceReplayServer;

/// The controlled corpus of the remaining result fields (ticket #41). See
/// `tool/result_field_oracle/README.md`.
const resultFieldFixturePath = 'tool/result_field_oracle/fixtures.json';

/// Product source files whose measured bytes are bound into a FIELDS-02
/// product observation. This is a bounded projection of the actual pipelines,
/// not a dependency registry.
const productSourcePaths = <String>[
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

/// Measures the current bounded product sources. The report stores these bytes'
/// hashes; a comparator receives the same measured map independently.
Map<String, String> measureProductSources() => {
  for (final path in productSourcePaths)
    path: _sourceSha256(File(path).readAsBytesSync()),
};

String _sourceSha256(List<int> bytes) {
  final digest = SHA256Digest().process(Uint8List.fromList(bytes));
  return digest.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// Loads the corpus. The caller passes the path explicitly so a re-recorded
/// copy can be compared without editing the repository copy.
Map<String, dynamic> loadResultFieldFixture([
  String path = resultFieldFixturePath,
]) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

/// Whether a case's source rule map declares [field]. Key presence is the
/// observation contract, including an empty rule; an absent key keeps the old
/// record shape.
bool _declaresRuleField(
  Map<String, dynamic> source,
  String ruleName,
  String field,
) {
  final rules = source[ruleName];
  return rules is Map && rules.containsKey(field);
}

/// One corpus-shape check: the corpus ran as it declares.
///
/// These are not compatibility claims. They say the corpus is healthy and the
/// product reached the stages the corpus names; every compatibility verdict
/// belongs to `tool/result_field_compare.dart`, which reads the frozen golden.
class ResultFieldInvariant {
  const ResultFieldInvariant(this.id, this.ok, this.detail);

  final String id;
  final bool ok;
  final String detail;
}

/// What one run of the corpus observed.
class ResultFieldRun {
  const ResultFieldRun({
    required this.requests,
    required this.unmatched,
    required this.stageTrace,
    required this.cases,
    required this.caseFailures,
    required this.checkKeyword,
    required this.invariants,
  });

  final List<Map<String, Object?>> requests;
  final List<Map<String, Object?>> unmatched;
  final List<Map<String, String>> stageTrace;

  /// One observation object per corpus case, keyed by the case id.
  final Map<String, Map<String, Object?>> cases;

  /// Cases whose product stages threw, keyed by the case id.
  final Map<String, String> caseFailures;

  /// The `sourceCheckKeyword` outcome per `checkKeywordCases` entry.
  final Map<String, Map<String, Object?>> checkKeyword;

  final List<ResultFieldInvariant> invariants;

  bool get scenarioPassed => invariants.every((invariant) => invariant.ok);
}

/// What one FIELDS-02 run observed: an array of actual case records, each with
/// explicit IDs and present nullable stage slots; no map overwrite.
class BookUrlMarkersRun {
  const BookUrlMarkersRun({
    required this.requests,
    required this.unmatched,
    required this.serverErrors,
    required this.stageTrace,
    required this.caseRecords,
    required this.caseFailures,
    required this.invariants,
  });

  final List<Map<String, Object?>> requests;
  final List<Map<String, Object?>> unmatched;
  final List<String> serverErrors;
  final List<Map<String, String>> stageTrace;
  final List<Map<String, Object?>> caseRecords;
  final Map<String, String> caseFailures;
  final List<ResultFieldInvariant> invariants;

  bool get scenarioPassed => invariants.every((invariant) => invariant.ok);
}

/// Runs FIELDS-02 through the product's own four-stage pipeline and the existing
/// loopback replay server. The server's optional receipt hook records the
/// actual response status/redirect/terminal; the native expected values remain
/// for a later approved capture.
Future<BookUrlMarkersRun> runBookUrlMarkersCorpus({
  required Map<String, dynamic> fixture,
}) async {
  final server = await SliceReplayServer.start(
    fixture,
    onResponse: (request, response) {
      request['receipt'] = response;
    },
  );
  final records = <Map<String, Object?>>[];
  final failures = <String, String>{};
  final trace = <Map<String, String>>[];
  try {
    for (final raw in (fixture['cases'] as List).cast<Map>()) {
      final entry = raw.cast<String, dynamic>();
      final id = entry['id'] as String;
      final terminal = entry['terminal'] as String? ?? 'four-stage';
      final source = (entry['source'] as Map).cast<String, dynamic>();
      final searchIntroDeclared = _declaresRuleField(
        source,
        'ruleSearch',
        'intro',
      );
      final infoIntroDeclared = _declaresRuleField(
        source,
        'ruleBookInfo',
        'intro',
      );
      final sourceRef = '${source['bookSourceUrl']}';
      final state = SourceHostState();
      final pipeline = openBookSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
      );
      final traceBase = trace.length;
      final operations = <Map<String, Object?>>[];
      void completedOperation(String name, int requestStart, int traceStart) {
        operations.add({
          'name': name,
          'outcome': 'completed',
          'requestStart': requestStart,
          'requestEnd': server.requests.length,
          'traceStart': traceStart,
          'traceEnd': pipeline.trace.length,
        });
      }

      Future<T> observed<T>(
        String name,
        int requestStart,
        int traceStart,
        Future<T> Function() action,
      ) async {
        try {
          final value = await action();
          completedOperation(name, requestStart, traceStart);
          return value;
        } on Object catch (error) {
          operations.add({
            'name': name,
            'outcome': 'error',
            'requestStart': requestStart,
            'requestEnd': server.requests.length,
            'traceStart': traceStart,
            'traceEnd': pipeline.trace.length,
            'error': '$error',
          });
          rethrow;
        }
      }

      late final Map<String, Object?> record;
      var failed = false;
      final requestStart = server.requests.length;
      try {
        record = <String, Object?>{
          'id': id,
          'terminal': terminal,
          'operations': operations,
          'search': null,
          'bookInfo': null,
          'tableOfContents': null,
          'chapter': null,
          'sourceProbes': {'vipProbe': null, 'payProbe': null},
        };
        final traceStart = pipeline.trace.length;
        final hits = await observed(
          'search',
          requestStart,
          traceStart,
          () => pipeline.search(entry['keyword'] as String),
        );
        record['search'] = {
          'results': [
            for (final hit in hits)
              {
                'name': hit.title,
                'author': hit.author,
                'bookUrl': hit.addressContext!.comparisonAddress,
                'identityAddress': hit.identityAddress,
                'rawAddress': hit.rawAddress,
                if (searchIntroDeclared) 'intro': hit.intro,
              },
          ],
        };
        if (hits.isEmpty) {
          if (terminal != 'search-empty') {
            throw StateError('search returned no result');
          }
          record['requests'] = List<Map<String, Object?>>.unmodifiable(
            server.requests.sublist(requestStart),
          );
          records.add(record);
          continue;
        }
        final hit = hits.first;
        final infoRequestStart = server.requests.length;
        final infoTraceStart = pipeline.trace.length;
        final info = await observed(
          'bookInfo',
          infoRequestStart,
          infoTraceStart,
          () => pipeline.bookInfo(hit),
        );
        record['bookInfo'] = {
          'name': info.book.title,
          'author': info.book.author,
          'bookUrl': info.book.addressContext!.comparisonAddress,
          'identityAddress': info.book.identityAddress,
          'rawAddress': info.book.rawAddress,
          'tocUrl': info.tocUrl,
          if (infoIntroDeclared) 'intro': info.book.intro,
        };
        final tocRequestStart = server.requests.length;
        final tocTraceStart = pipeline.trace.length;
        final (book, chapters) = await observed(
          'tableOfContents',
          tocRequestStart,
          tocTraceStart,
          () => pipeline.tableOfContents(info),
        );
        record['tableOfContents'] = {
          'tocUrl': info.tocUrl,
          'chapters': [
            for (final chapter in chapters)
              {
                'title': chapter.name,
                'url': '${chapter.url}',
                'address': chapter.address,
                'rawAddress': chapter.rawAddress,
                'storeKey': chapter.storeKey,
                'persistedAddress': chapter.persistedAddress,
                'tag': chapter.tag,
                'isVolume': chapter.isVolume,
                'isVip': chapter.isVip,
                'isPay': chapter.isPay,
              },
          ],
        };
        final vipProbe = await state.entry(
          sourceRef,
          sourceRuleVariableKey(sourceRef, 'vipProbe'),
        );
        final payProbe = await state.entry(
          sourceRef,
          sourceRuleVariableKey(sourceRef, 'payProbe'),
        );
        record['sourceProbes'] = {'vipProbe': vipProbe, 'payProbe': payProbe};
        final contentRequestStart = server.requests.length;
        final contentTraceStart = pipeline.trace.length;
        final body = await observed(
          'content',
          contentRequestStart,
          contentTraceStart,
          () => pipeline.chapter(chapters.first, book: book),
        );
        record['chapter'] = {
          'title': body.title ?? chapters.first.name,
          'text': body.text,
        };
        record['requests'] = List<Map<String, Object?>>.unmodifiable(
          server.requests.sublist(requestStart),
        );
        records.add(record);
      } on Object catch (error) {
        failures[id] = '$error';
        failed = true;
        record['failure'] = '$error';
        record['requests'] = List<Map<String, Object?>>.unmodifiable(
          server.requests.sublist(requestStart),
        );
      } finally {
        trace.addAll([
          for (final observation in pipeline.trace)
            {'stage': observation.stage.name, 'path': observation.path},
        ]);
        for (final operation in operations) {
          operation['traceStart'] =
              (operation['traceStart'] as int) + traceBase;
          operation['traceEnd'] = (operation['traceEnd'] as int) + traceBase;
        }
        if (failed) records.add(record);
        pipeline.cancel();
      }
    }
  } finally {
    await server.close();
  }
  return BookUrlMarkersRun(
    requests: List<Map<String, Object?>>.unmodifiable(server.requests),
    unmatched: List<Map<String, Object?>>.unmodifiable(server.unmatched),
    serverErrors: List<String>.unmodifiable(server.serverErrors),
    stageTrace: trace,
    caseRecords: records,
    caseFailures: failures,
    invariants: _bookUrlMarkerInvariants(
      fixture: fixture,
      requests: server.requests,
      records: records,
      failures: failures,
      unmatched: server.unmatched,
      serverErrors: server.serverErrors,
    ),
  );
}

List<ResultFieldInvariant> _bookUrlMarkerInvariants({
  required Map<String, dynamic> fixture,
  required List<Map<String, Object?>> requests,
  required List<Map<String, Object?>> records,
  required Map<String, String> failures,
  required List<Map<String, Object?>> unmatched,
  required List<String> serverErrors,
}) {
  final declared = [
    for (final entry in (fixture['cases'] as List).cast<Map>())
      entry['id'] as String,
  ];
  final observed = [for (final record in records) record['id'] as String];
  final exactIds =
      declared.toSet().length == declared.length &&
      observed.length == declared.length &&
      observed.toSet().length == observed.length &&
      observed.toSet().containsAll(declared);
  final problems = <String>[];
  for (final record in records) {
    final terminal = record['terminal'];
    if (terminal == 'search-empty') {
      final search = record['search'] as Map?;
      final results = search?['results'] as List?;
      if (results == null || results.isNotEmpty) {
        problems.add('${record['id']}: empty terminal has search results');
      }
      if (record['bookInfo'] != null ||
          record['tableOfContents'] != null ||
          record['chapter'] != null) {
        problems.add('${record['id']}: empty terminal reached later stages');
      }
    } else {
      if (record['bookInfo'] == null ||
          record['tableOfContents'] == null ||
          record['chapter'] == null) {
        problems.add('${record['id']}: four-stage case has a missing stage');
      }
      final chapters =
          (record['tableOfContents'] as Map?)?['chapters'] as List?;
      if (chapters == null || chapters.isEmpty) {
        problems.add('${record['id']}: four-stage case has no chapter');
      }
    }
  }
  if (failures.isNotEmpty) {
    problems.add('case failures: ${failures.keys.join(', ')}');
  }
  final declaredRequests = (fixture['expectedRequests'] as List).cast<Map>();
  final requestProblems = <String>[];
  if (requests.length != declaredRequests.length) {
    requestProblems.add(
      'declared ${declaredRequests.length}, observed ${requests.length}',
    );
  }
  for (
    var index = 0;
    index < requests.length && index < declaredRequests.length;
    index++
  ) {
    final observed = requests[index];
    final expected = declaredRequests[index];
    if (observed['method'] != expected['method'] ||
        observed['path'] != expected['path']) {
      requestProblems.add(
        'request $index is ${observed['method']} ${observed['path']}',
      );
      continue;
    }
    final expectedQuery =
        (expected['query'] as Map?)?.cast<String, String>() ??
        const <String, String>{};
    final observedQuery =
        (observed['query'] as Map?)?.cast<String, String>() ??
        const <String, String>{};
    if (expectedQuery.length != observedQuery.length ||
        !expectedQuery.entries.every(
          (entry) => observedQuery[entry.key] == entry.value,
        )) {
      requestProblems.add('request $index query differs');
    }
  }
  if (serverErrors.isNotEmpty) {
    requestProblems.add('server errors: ${serverErrors.length}');
  }
  return [
    ResultFieldInvariant(
      'declared-request-sequence',
      requestProblems.isEmpty,
      requestProblems.isEmpty
          ? '${declaredRequests.length} declared requests observed in order'
          : requestProblems.join('; '),
    ),
    ResultFieldInvariant(
      'no-undeclared-request',
      unmatched.isEmpty,
      unmatched.isEmpty
          ? 'every request had a declared response'
          : 'undeclared: ${unmatched.length}',
    ),
    ResultFieldInvariant(
      'exact-case-ids',
      exactIds,
      exactIds
          ? '${declared.length} declared case ids observed once'
          : 'case id mismatch',
    ),
    ResultFieldInvariant(
      'case-terminal-completion',
      problems.isEmpty,
      problems.isEmpty
          ? 'every case reached its declared terminal'
          : problems.join('; '),
    ),
  ];
}

/// Runs the corpus through the product pipeline on the host platform.
///
/// The native library must already be initialized (`NativeLibrary.initialize`).
/// Each case runs its own `BookSourcePipeline` over a real `HttpSourceTransport`
/// against the corpus' own replay server, exactly like the first-slice runner;
/// the frozen side is the same corpus driven through the frozen four-stage
/// entry by `tool/result_field_oracle/FieldOracle.java`.
Future<ResultFieldRun> runResultFieldCorpus({
  required Map<String, dynamic> fixture,
}) async {
  final server = await SliceReplayServer.start(fixture);
  final cases = <String, Map<String, Object?>>{};
  final caseFailures = <String, String>{};
  final trace = <Map<String, String>>[];
  try {
    for (final raw in (fixture['cases'] as List).cast<Map>()) {
      final entry = raw.cast<String, dynamic>();
      final id = entry['id'] as String;
      final pipeline = openBookSourcePipeline(
        (entry['source'] as Map).cast<String, dynamic>(),
        HttpSourceTransport(),
      );
      try {
        final hits = await pipeline.search(entry['keyword'] as String);
        final hit = hits.first;
        final (book, chapters) = await pipeline.details(hit);
        final chapter = chapters.first;
        final body = await pipeline.chapter(chapter);
        cases[id] = {
          'search': {
            'results': [
              for (final result in hits)
                {
                  'name': result.title,
                  'author': result.author,
                  'intro': result.intro,
                  'lastChapter': result.lastChapter,
                  'wordCount': result.wordCount,
                },
            ],
          },
          'bookInfo': {
            'name': book.title,
            'author': book.author,
            'wordCount': book.wordCount,
          },
          // The frozen stage reports the chapter title the reader ends up with:
          // `ruleContent.title` replaced it, or the table of contents' own name
          // stayed. The product carries that as the body title plus the chapter
          // it was read from, so the shared observation is the effective title.
          'chapter': {'title': body.title ?? chapter.name, 'text': body.text},
        };
      } on Object catch (error) {
        caseFailures[id] = '$error';
      } finally {
        trace.addAll([
          for (final observation in pipeline.trace)
            {'stage': observation.stage.name, 'path': observation.path},
        ]);
        pipeline.cancel();
      }
    }
  } finally {
    await server.close();
  }

  final checkKeyword = <String, Map<String, Object?>>{};
  for (final raw in (fixture['checkKeywordCases'] as List).cast<Map>()) {
    final entry = raw.cast<String, dynamic>();
    final id = entry['id'] as String;
    try {
      checkKeyword[id] = {
        'outcome': 'value',
        'value': sourceCheckKeyword(
          (entry['source'] as Map).cast<String, dynamic>(),
          entry['fallback'] as String,
        ),
      };
    } on Object catch (error) {
      checkKeyword[id] = {'outcome': 'refused', 'reason': '$error'};
    }
  }

  return ResultFieldRun(
    requests: List<Map<String, Object?>>.unmodifiable(server.requests),
    unmatched: List<Map<String, Object?>>.unmodifiable(server.unmatched),
    stageTrace: trace,
    cases: cases,
    caseFailures: caseFailures,
    checkKeyword: checkKeyword,
    invariants: _invariants(
      fixture: fixture,
      requests: server.requests,
      unmatched: server.unmatched,
      cases: cases,
      caseFailures: caseFailures,
    ),
  );
}

List<ResultFieldInvariant> _invariants({
  required Map<String, dynamic> fixture,
  required List<Map<String, Object?>> requests,
  required List<Map<String, Object?>> unmatched,
  required Map<String, Map<String, Object?>> cases,
  required Map<String, String> caseFailures,
}) {
  final declared = (fixture['expectedRequests'] as List).cast<Map>();
  final declaredCases = (fixture['cases'] as List).cast<Map>();
  final mismatches = <String>[];
  if (requests.length != declared.length) {
    mismatches.add('${requests.length} requests, ${declared.length} declared');
  } else {
    for (var index = 0; index < declared.length; index++) {
      if (!_requestMatches(declared[index], requests[index])) {
        mismatches.add(
          '${_requestLine(requests[index])} does not match '
          '${_requestLine(declared[index])}',
        );
      }
    }
  }
  final missing = [
    for (final entry in declaredCases)
      if (!cases.containsKey(entry['id'])) '${entry['id']}',
  ];
  return [
    ResultFieldInvariant(
      'no-undeclared-request',
      unmatched.isEmpty,
      unmatched.isEmpty
          ? 'every request had a declared response'
          : 'undeclared: ${unmatched.map(_requestLine).join(', ')}',
    ),
    ResultFieldInvariant(
      'declared-requests',
      mismatches.isEmpty,
      mismatches.isEmpty
          ? '${declared.length} declared requests matched: '
                '${declared.map(_requestLine).join(' | ')}'
          : mismatches.join('; '),
    ),
    ResultFieldInvariant(
      'cases-completed',
      missing.isEmpty,
      missing.isEmpty
          ? '${cases.length} cases ran; '
                '${caseFailures.isEmpty ? 'no stage threw' : 'threw: ${caseFailures.keys.join(', ')}'}'
          : 'cases that did not complete: ${missing.join(', ')}'
                '${caseFailures.isEmpty ? '' : ' (${caseFailures.entries.map((entry) => '${entry.key}: ${entry.value}').join('; ')})'}',
    ),
  ];
}

bool _requestMatches(Map expected, Map<String, Object?> observed) {
  if (expected['method'] != observed['method']) return false;
  if (expected['path'] != observed['path']) return false;
  final expectedQuery =
      (expected['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  final observedQuery = (observed['query'] as Map).cast<String, String>();
  if (expectedQuery.length != observedQuery.length) return false;
  return expectedQuery.entries.every(
    (entry) => observedQuery[entry.key] == entry.value,
  );
}

String _requestLine(Map request) {
  final line = '${request['method']} ${request['path']}';
  final query = (request['query'] as Map?)?.cast<String, String>() ?? const {};
  if (query.isEmpty) return line;
  return '$line?${query.entries.map((entry) => '${entry.key}=${entry.value}').join('&')}';
}
