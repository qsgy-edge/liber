import 'dart:convert';
import 'dart:io';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';

import 'first_slice/runner.dart' show SliceReplayServer;

/// The controlled corpus of the remaining result fields (ticket #41). See
/// `tool/result_field_oracle/README.md`.
const resultFieldFixturePath = 'tool/result_field_oracle/fixtures.json';

/// Loads the corpus. The caller passes the path explicitly so a re-recorded
/// copy can be compared without editing the repository copy.
Map<String, dynamic> loadResultFieldFixture([
  String path = resultFieldFixturePath,
]) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

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
