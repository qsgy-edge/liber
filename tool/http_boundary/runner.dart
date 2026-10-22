import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/html_source_pipeline.dart' as html_boundary;
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime;
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_rate_limiter.dart';
import 'package:liber/source/source_stage_diagnostic.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Runs the frozen HTTP-BOUNDARY-01 corpus through the product's own ordinary
/// HTTP surface: `java.ajax`/`ajaxAll`/`connect`, the three
/// `source.getHeaderMap` arities, the source-keyed rate limiter, the four
/// pipeline stages (search, book information, table of contents, content), the
/// task-owned connection-failure row and the pipeline's own cancellation.
///
/// Usage:
///   `dart run tool/http_boundary/runner.dart <fjs.dll> <root> <report.json>`
///     `[--expected-corpus-sha256=<sha256>]`
///
/// The corpus and the controller's captures are read-only inputs: this entry
/// point never writes a golden. `<root>` must not exist yet, so the run owns
/// every byte it creates; the report keeps the ownership manifest and the
/// cleanup receipts, and the root is removed again when the run is clean.
const httpBoundaryCorpusPath = 'tool/http_boundary/fixtures.json';
const httpBoundaryFixtureId = 'HTTP-BOUNDARY-01';
const httpBoundaryCorpusVersion = 2;

/// The user agent every corpus source declares (`fixtures.json` `sources`).
/// The corpus tests header arity and replacement with it, so a source without
/// it is a corpus error rather than a default user agent.
const httpBoundaryUserAgent = 'HTTP-BOUNDARY-01/1.0';

/// The one declared fixture binding: the failure source's book source URL.
const httpBoundaryFailPortToken = r'$FAILPORT';

/// The product's configured batch width: `SourceHostDispatcher.ajaxAll`'s own
/// default. Recorded as this run's runtime configuration, because the frozen
/// collector reads the same capability from `AppConfig.threadCount`.
const httpBoundaryBatchWidth = 4;

/// A corpus, library or ownership problem: nothing ran, so the target capture
/// is left exactly as it was.
class HttpBoundaryRefusal implements Exception {
  const HttpBoundaryRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A corpus step whose declared outcome was reached but could not be finished,
/// or a measurement whose own preconditions did not hold. The row keeps what
/// happened and the report stays non-promotable.
class HttpBoundaryIncomplete implements Exception {
  const HttpBoundaryIncomplete(this.message);
  final String message;
  @override
  String toString() => message;
}

// --- hashing and small helpers ------------------------------------------------

String sha256Bytes(List<int> bytes) => SHA256Digest()
    .process(Uint8List.fromList(bytes))
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String sha256Text(String text) => sha256Bytes(utf8.encode(text));

String sha256File(File file) => sha256Bytes(file.readAsBytesSync());

/// The corpus pin both lanes record: CRLF-normalised bytes, so one pin names
/// the same corpus on an LF and a Windows checkout.
String httpBoundaryCorpusSha256Lf(File file) =>
    sha256Text(file.readAsStringSync().replaceAll('\r\n', '\n'));

final _clock = Stopwatch()..start();

int _nowNanos() => _clock.elapsedMicroseconds * 1000;

int _nowMillis() => DateTime.now().millisecondsSinceEpoch;

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('$what is not a JSON object');
}

List<dynamic> _array(Object? value, String what) {
  if (value is List) return value;
  throw FormatException('$what is not a JSON array');
}

String _text(Object? value, String what) {
  final text = value is String ? value.trim() : '';
  if (text.isEmpty) throw FormatException('$what is empty');
  return text;
}

int _integer(Object? value, String what) {
  if (value is int) return value;
  throw FormatException('$what is not an integer');
}

/// The target pin the corpus declares; without it the corpus cannot name the
/// compatibility baseline this run measures.
Map<String, dynamic> httpBoundaryTargetOf(Map<String, dynamic> corpus) {
  final target = _object(corpus['target'], 'target');
  _text(target['package'], 'target.package');
  final apk = _text(target['apkSha256'], 'target.apkSha256');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(apk)) {
    throw const FormatException('target.apkSha256 is not a SHA-256');
  }
  _text(target['baselineCommit'], 'target.baselineCommit');
  _text(target['manifest'], 'target.manifest');
  return target;
}

Map<String, dynamic> httpBoundarySourceOf(
  Map<String, dynamic> corpus,
  String id,
) {
  for (final raw in _array(corpus['sources'], 'sources')) {
    final source = _object(raw, 'source');
    if ('${source['id']}' == id) {
      return _object(source['bookSource'], 'source $id bookSource');
    }
  }
  throw FormatException('the corpus declares no source $id');
}

List<Map<String, dynamic>> httpBoundarySteps(Map<String, dynamic> corpus) => [
  for (final raw in _array(corpus['steps'], 'steps')) _object(raw, 'step'),
];

List<Map<String, dynamic>> httpBoundaryResponses(Map<String, dynamic> corpus) =>
    [
      for (final raw in _array(corpus['responses'], 'responses'))
        _object(raw, 'response'),
    ];

/// The corpus step ids (`observations`) in declared order.
List<String> httpBoundaryObservationIds(Map<String, dynamic> corpus) => [
  for (final step in httpBoundarySteps(corpus)) '${step['id']}',
];

/// One response id's declared wire identity.
String httpBoundarySelectorOf(Map<String, dynamic> response) =>
    '${response['method']} ${response['path']}?${response['rawQuery'] ?? ''}';

/// Every request declaration one step owns: the ordered prefix, then the
/// declared concurrent members, in declared order.
({List<String> ordered, String? cohort, List<String> members})
httpBoundaryDeclaredRequests(Map<String, dynamic> step) {
  final declared = _object(step['requests'], 'step ${step['id']} requests');
  final ordered = [
    for (final raw in (declared['ordered'] as List? ?? const <Object?>[]))
      '$raw',
  ];
  final batch = declared['batch'] == null
      ? null
      : _object(declared['batch'], 'step ${step['id']} batch');
  return (
    ordered: ordered,
    cohort: batch == null ? null : _text(batch['cohort'], 'batch.cohort'),
    members: [
      for (final raw in (batch?['members'] as List? ?? const <Object?>[]))
        '$raw',
    ],
  );
}

/// The step a declared response id belongs to. A selector belongs to exactly
/// one causal owner, so a late request keeps its owner instead of the mutable
/// step a replay is currently on.
Map<String, ({String step, String family, String? cohort})>
httpBoundaryResponseOwners(Map<String, dynamic> corpus) {
  final owners = <String, ({String step, String family, String? cohort})>{};
  for (final step in httpBoundarySteps(corpus)) {
    final declared = httpBoundaryDeclaredRequests(step);
    for (final id in declared.ordered) {
      owners[id] = (
        step: '${step['id']}',
        family: '${step['family']}',
        cohort: null,
      );
    }
    for (final id in declared.members) {
      owners[id] = (
        step: '${step['id']}',
        family: '${step['family']}',
        cohort: declared.cohort,
      );
    }
  }
  return owners;
}

/// The structural model the corpus declares, derived from the step and response
/// declarations. The native collector derives the same numbers from the same
/// bytes; a prose count is never an input.
Map<String, Object?> httpBoundaryStructuralOf(Map<String, dynamic> corpus) {
  final steps = httpBoundarySteps(corpus);
  final responses = httpBoundaryResponses(corpus);
  final familyObservations = <String, int>{};
  var requests = 0;
  var helperSingleton = 0;
  var helperBatch = 0;
  final helperBatchSizes = <int>[];
  var rateSelectors = 0;
  var stageRequests = 0;
  final stageSelectors = <String>{};
  for (final step in steps) {
    final family = '${step['family']}';
    familyObservations[family] = (familyObservations[family] ?? 0) + 1;
    final declared = httpBoundaryDeclaredRequests(step);
    requests += declared.ordered.length + declared.members.length;
    switch (family) {
      case 'helper':
        helperSingleton += declared.ordered.length;
        helperBatch += declared.members.length;
        if (declared.members.isNotEmpty) {
          helperBatchSizes.add(declared.members.length);
        }
      case 'rate':
        rateSelectors += declared.ordered.length;
      default:
        stageRequests += declared.ordered.length + declared.members.length;
        stageSelectors.addAll(declared.ordered);
        stageSelectors.addAll(declared.members);
    }
  }
  return {
    'observations': steps.length,
    'requests': requests,
    'responses': responses.length,
    'helperSelectors': helperSingleton + helperBatch,
    'helperSingletonSelectors': helperSingleton,
    'helperBatchSelectors': helperBatch,
    'helperBatchSizes': helperBatchSizes,
    'rateSelectors': rateSelectors,
    'stageSelectors': stageSelectors.length,
    'stageRequests': stageRequests,
    'familyObservations': {
      for (final family in const ['helper', 'rate', 'stage'])
        family: familyObservations[family] ?? 0,
    },
    'requestsExceedingSelectors': requests - responses.length,
    'requestsExceedingSelectorsReason':
        's2.retry-non2xx repeats one declared selector three times (retry=2)',
  };
}

/// Whether one declared `header` rule names [httpBoundaryUserAgent] as its user
/// agent. A static rule is parsed; the two script forms' declared
/// `JSON.stringify` object literal is read without executing the script.
bool httpBoundaryHeaderDeclaresUserAgent(String header) {
  final text = header.trim();
  String? script;
  if (text.toLowerCase().startsWith('@js:')) {
    script = text.substring(4);
  } else if (text.toLowerCase().startsWith('<js>')) {
    final end = text.lastIndexOf('<');
    if (end > 4) script = text.substring(4, end);
  }
  if (script == null) {
    Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return false;
    }
    if (decoded is! Map) return false;
    for (final entry in decoded.entries) {
      if ('${entry.key}'.toLowerCase() != 'user-agent') continue;
      return entry.value == httpBoundaryUserAgent;
    }
    return false;
  }
  for (final match in RegExp(
    r'''["']User-Agent["']\s*:\s*["']([^"']*)["']''',
    caseSensitive: false,
  ).allMatches(script)) {
    if (match.group(1) == httpBoundaryUserAgent) return true;
  }
  return false;
}

Map<String, dynamic> loadHttpBoundaryCorpus([
  String path = httpBoundaryCorpusPath,
]) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('HTTP-BOUNDARY-01 corpus missing: $path');
  }
  final corpus = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  validateHttpBoundaryCorpus(corpus);
  return corpus;
}

/// The corpus gate both entry points run before anything else: the declared
/// fixture identity, the one loopback replay origin, every source's user agent,
/// the six sources, the rate/failure/cancellation bindings, unique declared
/// selectors with exactly one causal owner each, and the structural model
/// derived from the declarations. No response body or source-derived note is an
/// expected value here.
void validateHttpBoundaryCorpus(Map<String, dynamic> corpus) {
  if (corpus['schemaVersion'] != 1) {
    throw const FormatException('the corpus schemaVersion is not 1');
  }
  if (corpus['fixtureId'] != httpBoundaryFixtureId) {
    throw const FormatException(
      'the corpus fixtureId is not $httpBoundaryFixtureId',
    );
  }
  if (corpus['corpusVersion'] != httpBoundaryCorpusVersion) {
    throw const FormatException(
      'the corpus corpusVersion is not $httpBoundaryCorpusVersion',
    );
  }
  _text(corpus['baselineCommit'], 'baselineCommit');
  _text(corpus['entryPoint'], 'entryPoint');
  httpBoundaryTargetOf(corpus);
  final origins = _object(corpus['origins'], 'origins');
  if (origins.length != 1) {
    throw const FormatException('the corpus declares exactly one origin');
  }
  final origin = Uri.parse(_text(origins['replay'], 'origins.replay'));
  if (origin.scheme != 'http' ||
      origin.host != '127.0.0.1' ||
      origin.port == 0) {
    throw const FormatException(
      'the replay origin is not one explicit loopback host:port',
    );
  }
  final sources = _array(corpus['sources'], 'sources');
  if (sources.length != 6) {
    throw const FormatException('the corpus declares six sources');
  }
  for (final raw in sources) {
    final entry = _object(raw, 'source');
    final id = _text(entry['id'], 'source id');
    final source = _object(entry['bookSource'], 'source $id bookSource');
    _text(source['bookSourceUrl'], 'source $id bookSourceUrl');
    if (source['enabledCookieJar'] != false) {
      throw FormatException(
        'source $id does not declare enabledCookieJar false',
      );
    }
    if (!httpBoundaryHeaderDeclaresUserAgent('${source['header'] ?? ''}')) {
      throw FormatException(
        'source $id does not declare the corpus user agent in its header rule',
      );
    }
  }
  if (!'${httpBoundarySourceOf(corpus, 'F')['bookSourceUrl']}'.contains(
    httpBoundaryFailPortToken,
  )) {
    throw const FormatException('source F does not carry the \$FAILPORT token');
  }
  for (final raw in sources) {
    final id = '${(raw as Map)['id']}';
    if (id == 'F') continue;
    if ('${httpBoundarySourceOf(corpus, id)['bookSourceUrl']}'.contains(
      httpBoundaryFailPortToken,
    )) {
      throw FormatException('source $id carries the \$FAILPORT token');
    }
  }
  // Every declared selector is unique and every response id belongs to exactly
  // one causal step.
  final responses = httpBoundaryResponses(corpus);
  final selectors = <String>{};
  final responseIds = <String>{};
  for (final response in responses) {
    final id = _text(response['id'], 'response id');
    if (!responseIds.add(id)) {
      throw FormatException('response $id is declared twice');
    }
    _text(response['method'], 'response $id method');
    _text(response['path'], 'response $id path');
    if (!selectors.add(httpBoundarySelectorOf(response))) {
      throw FormatException(
        'response selector ${httpBoundarySelectorOf(response)} is declared twice',
      );
    }
    _integer(response['status'], 'response $id status');
    if (response['body'] is! String) {
      throw FormatException('response $id body is not a string');
    }
    if (response['hold'] == true) {
      _integer(response['holdTimeoutMs'], 'response $id holdTimeoutMs');
    }
  }
  final steps = httpBoundarySteps(corpus);
  final stepIds = <String>{};
  final ownerCount = <String, int>{};
  for (final step in steps) {
    final id = _text(step['id'], 'step id');
    if (!stepIds.add(id)) throw FormatException('step $id is declared twice');
    final kind = _text(step['kind'], 'step $id kind');
    if (!const {
      'helper',
      'rate',
      'stage',
      'failure',
      'cancel',
    }.contains(kind)) {
      throw FormatException('step $id has unknown kind $kind');
    }
    httpBoundarySourceOf(corpus, _text(step['source'], 'step $id source'));
    final declared = httpBoundaryDeclaredRequests(step);
    for (final responseId in [...declared.ordered, ...declared.members]) {
      if (!responseIds.contains(responseId)) {
        throw FormatException('step $id declares missing response $responseId');
      }
      ownerCount[responseId] = (ownerCount[responseId] ?? 0) + 1;
    }
    final headers = step['requiredHeaders'];
    if (headers != null) {
      final map = _object(headers, 'step $id requiredHeaders');
      for (final entry in map.entries) {
        if (entry.value is! String) {
          throw FormatException(
            'step $id required header ${entry.key} is not a string',
          );
        }
      }
      // A helper/rate row requires the source-controlled user agent it expects;
      // the header-string row deliberately requires the replacement value.
      if (kind != 'stage' && map['user-agent'] is! String) {
        throw FormatException('step $id does not require a user agent');
      }
    }
  }
  for (final responseId in responseIds) {
    if ((ownerCount[responseId] ?? 0) == 0) {
      throw FormatException('response $responseId has no declared owner');
    }
  }
  // The rate binding.
  final rate = _object(corpus['rate'], 'rate');
  final rateSource = _text(rate['source'], 'rate.source');
  final rateSteps = [
    for (final raw in _array(rate['steps'], 'rate.steps')) '$raw',
  ];
  if (rateSteps.isEmpty) throw const FormatException('rate.steps is empty');
  for (final id in rateSteps) {
    final step = steps.firstWhere(
      (candidate) => '${candidate['id']}' == id,
      orElse: () => throw FormatException('rate step $id is not declared'),
    );
    if ('${step['source']}' != rateSource) {
      throw FormatException('rate step $id does not use source $rateSource');
    }
  }
  final concurrentRate = _text(rate['concurrentRate'], 'rate.concurrentRate');
  final rateSourceValue =
      '${httpBoundarySourceOf(corpus, rateSource)['concurrentRate'] ?? ''}';
  if (rateSourceValue != concurrentRate) {
    throw FormatException(
      'source $rateSource declares concurrentRate $rateSourceValue, the rate '
      'block declares $concurrentRate',
    );
  }
  final parts = concurrentRate.split('/');
  if (parts.length != 2 ||
      int.tryParse(parts[1]) !=
          _integer(rate['windowMillis'], 'rate.windowMillis')) {
    throw const FormatException(
      'rate.windowMillis does not read the declared concurrentRate',
    );
  }
  if (rate['initialSnapshotRequirement'] != 'empty') {
    throw const FormatException('rate.initialSnapshotRequirement is not empty');
  }
  // The task-owned failure endpoint.
  final failure = _object(corpus['failureEndpoint'], 'failureEndpoint');
  if (failure['host'] != '127.0.0.1' || failure['port'] != 0) {
    throw const FormatException(
      'the failure endpoint is not one owned ephemeral loopback listener',
    );
  }
  if (failure['token'] != httpBoundaryFailPortToken) {
    throw const FormatException(
      'the failure endpoint token is not the declared fixture binding',
    );
  }
  final failureStep = steps.firstWhere(
    (candidate) => '${candidate['id']}' == '${failure['step']}',
    orElse: () =>
        throw const FormatException('the failure step is not declared'),
  );
  if ('${failureStep['source']}' != '${failure['source']}') {
    throw const FormatException(
      'the failure step does not use the failure source',
    );
  }
  // The cancellation and its bound follow-up.
  final cancellation = _object(corpus['cancellation'], 'cancellation');
  final cancelStep = steps.firstWhere(
    (candidate) => '${candidate['id']}' == '${cancellation['step']}',
    orElse: () =>
        throw const FormatException('the cancellation step is not declared'),
  );
  if ('${cancelStep['kind']}' != 'cancel') {
    throw const FormatException('the cancellation step is not a cancel row');
  }
  _integer(cancellation['holdTimeoutMs'], 'cancellation.holdTimeoutMs');
  _integer(cancellation['quietWindowMs'], 'cancellation.quietWindowMs');
  final followUpStep = _text(
    cancellation['followUpStep'],
    'cancellation.followUpStep',
  );
  final followUp = steps.firstWhere(
    (candidate) => '${candidate['id']}' == followUpStep,
    orElse: () =>
        throw const FormatException('the follow-up step is not declared'),
  );
  if ('${followUp['followUpOf']}' != '${cancellation['step']}') {
    throw const FormatException(
      'the follow-up step names another row as its origin',
    );
  }
  if (_array(cancellation['stateProbes'], 'cancellation.stateProbes').isEmpty) {
    throw const FormatException(
      'the cancellation block declares no state probe',
    );
  }
  // The native negative declaration: an executed control, never a golden.
  final negative = _object(corpus['negative'], 'negative');
  if ('${negative['mode']}' != 'replay-omission') {
    throw const FormatException('the negative mode is not replay-omission');
  }
  final dropped = responses.where(
    (response) => '${response['id']}' == '${negative['drop']}',
  );
  if (dropped.length != 1) {
    throw const FormatException(
      'the negative drop is not one declared response',
    );
  }
  if (httpBoundarySelectorOf(dropped.first) != '${negative['selector']}') {
    throw const FormatException(
      'the negative selector does not name the dropped response',
    );
  }
  // Cohorts: one declaration per declared batch, with the batch's own size.
  final cohortSizes = <String, int>{};
  for (final raw in _array(corpus['cohorts'], 'cohorts')) {
    final cohort = _object(raw, 'cohort');
    final id = _text(cohort['id'], 'cohort id');
    if (cohortSizes.containsKey(id)) {
      throw FormatException('cohort $id is declared twice');
    }
    cohortSizes[id] = _integer(cohort['size'], 'cohort $id size');
    if (_integer(cohort['timeoutMs'], 'cohort $id timeoutMs') <= 0) {
      throw FormatException('cohort $id declares no window');
    }
  }
  for (final step in steps) {
    final declared = httpBoundaryDeclaredRequests(step);
    if (declared.members.isEmpty) continue;
    final cohort = declared.cohort;
    if (cohort == null) {
      throw FormatException(
        'step ${step['id']} declares members without a cohort',
      );
    }
    if (cohortSizes[cohort] != declared.members.length) {
      throw FormatException(
        'cohort $cohort declares size ${cohortSizes[cohort]}, step '
        '${step['id']} declares ${declared.members.length} members',
      );
    }
    for (final response in responses) {
      if (!declared.members.contains('${response['id']}')) continue;
      if ('${response['cohort'] ?? ''}' != cohort) {
        throw FormatException(
          'response ${response['id']} does not declare cohort $cohort',
        );
      }
    }
  }
  // The derivation the collector refuses a corpus over.
  final declaredStructural = _object(corpus['structural'], 'structural');
  final derived = httpBoundaryStructuralOf(corpus);
  for (final entry in derived.entries) {
    if (entry.key == 'requestsExceedingSelectorsReason') continue;
    if (jsonEncode(declaredStructural[entry.key]) != jsonEncode(entry.value)) {
      throw FormatException(
        'structural.${entry.key} is ${jsonEncode(declaredStructural[entry.key])}, '
        'the declarations derive ${jsonEncode(entry.value)}',
      );
    }
  }
  final forbidden = _array(
    _object(corpus['requestChecks'], 'requestChecks')['forbiddenHeaders'],
    'requestChecks.forbiddenHeaders',
  );
  if (!forbidden.contains('cookie')) {
    throw const FormatException('the corpus does not forbid the cookie header');
  }
}

// --- entry point -------------------------------------------------------------

Future<void> main(List<String> args) async {
  if (args.length < 3) {
    stderr.writeln(
      'Usage: dart run tool/http_boundary/runner.dart <fjs.dll> <root> '
      '<report.json> [--expected-corpus-sha256=<sha256>]',
    );
    exitCode = 64;
    return;
  }
  final libraryPath = args[0];
  final root = Directory(args[1]);
  final reportPath = args[2];
  String? expectedCorpusSha256;
  for (final arg in args.sublist(3)) {
    const prefix = '--expected-corpus-sha256=';
    if (arg.startsWith(prefix)) {
      final value = arg.substring(prefix.length);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        stderr.writeln('--expected-corpus-sha256 is not a SHA-256');
        exitCode = 64;
        return;
      }
      expectedCorpusSha256 = value;
      continue;
    }
    stderr.writeln('unknown runner argument: $arg');
    exitCode = 64;
    return;
  }
  final report = <String, Object?>{
    'schemaVersion': 1,
    'product': 'liber-http-boundary-runner',
    'platform': Platform.operatingSystem,
    'pid': pid,
    'runId': _newRunId(),
    'recordedAt': DateTime.now().toUtc().toIso8601String(),
    'captureKind': 'product',
    'negativeMode': false,
    'negative': null,
    'fixtureId': '',
    'corpusVersion': null,
    'baselineCommit': '',
    'entryPoint': '',
    'status': 'failed',
    'observations': <Map<String, Object?>>[],
    'requests': <Map<String, Object?>>[],
    'unmatchedRequests': <Map<String, Object?>>[],
    'serverErrors': <Map<String, Object?>>[],
    'stageTrace': <Map<String, Object?>>[],
    'analysisFailure': null,
  };
  var result = 1;
  try {
    final corpusFile = File(httpBoundaryCorpusPath);
    final corpus = loadHttpBoundaryCorpus(httpBoundaryCorpusPath);
    final corpusLf = httpBoundaryCorpusSha256Lf(corpusFile);
    if (expectedCorpusSha256 != null && expectedCorpusSha256 != corpusLf) {
      throw const HttpBoundaryRefusal(
        'the working corpus bytes are not the pinned corpus',
      );
    }
    final library = File(libraryPath);
    if (!library.existsSync()) {
      throw const HttpBoundaryRefusal('the native library does not exist');
    }
    if (root.existsSync()) {
      throw const HttpBoundaryRefusal(
        'the scratch root already exists; only a fresh root is measured',
      );
    }
    final target = httpBoundaryTargetOf(corpus);
    report.addAll({
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'identity': {
        'fixtureId': corpus['fixtureId'],
        'corpusVersion': corpus['corpusVersion'],
        'baselineCommit': corpus['baselineCommit'],
        'entryPoint': corpus['entryPoint'],
        'corpusPath': httpBoundaryCorpusPath,
        'corpusRawSha256': sha256File(corpusFile),
        'corpusSha256Lf': corpusLf,
        'corpusRawLineEndings': corpusFile.readAsStringSync().contains('\r\n')
            ? 'crlf'
            : 'lf',
        'target': {
          'package': target['package'],
          'apkSha256': target['apkSha256'],
          'baselineCommit': target['baselineCommit'],
          'manifest': target['manifest'],
        },
        'library': {'path': libraryPath, 'sha256': sha256File(library)},
        'runner': {
          'path': 'tool/http_boundary/runner.dart',
          'sha256': sha256File(File('tool/http_boundary/runner.dart')),
        },
      },
      'structural': {
        'declared': corpus['structural'],
        'derived': httpBoundaryStructuralOf(corpus),
        'match': true,
      },
    });
    final run = _HttpBoundaryRun(
      corpus: corpus,
      corpusLf: corpusLf,
      root: root,
      libraryPath: libraryPath,
      librarySha256: sha256File(library),
      report: report,
    );
    await run.execute();
    result = run.exitCode;
  } on HttpBoundaryRefusal catch (error) {
    report['status'] = 'refused';
    report['analysisFailure'] = '$error';
    result = 2;
  } on Object catch (error, stack) {
    report['status'] = 'failed';
    report['analysisFailure'] = '$error';
    report['analysisStack'] = '$stack';
    result = 1;
  }
  report.putIfAbsent('analysisFailure', () => null);
  report['completedAt'] = DateTime.now().toUtc().toIso8601String();
  _writeReport(reportPath, report);
  if (result != 0) stderr.writeln('${report['analysisFailure'] ?? ''}');
  exitCode = result;
}

String _newRunId() {
  final random = Random.secure();
  final token = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${DateTime.now().toUtc().toIso8601String()}-$token';
}

void _writeReport(String path, Map<String, Object?> report) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}

// --- one run -----------------------------------------------------------------

/// One corpus run's live objects: the replay listener, the task-owned failure
/// endpoint, the space's host surface, one runtime and dispatcher per helper
/// source, one pipeline per stage source, and the records they produced.
class _HttpBoundaryRun {
  _HttpBoundaryRun({
    required this.corpus,
    required this.corpusLf,
    required this.root,
    required this.libraryPath,
    required this.librarySha256,
    required this.report,
  });

  final Map<String, dynamic> corpus;
  final String corpusLf;
  final Directory root;
  final String libraryPath;
  final String librarySha256;
  final Map<String, Object?> report;

  final observations = <Map<String, Object?>>[];
  final requests = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final serverErrors = <Map<String, Object?>>[];
  final stageTrace = <Map<String, Object?>>[];
  final rateLimiter = SourceRateLimiter();

  _ReplayServer? replay;
  _FailEndpoint? failEndpoint;
  Workspace? workspace;
  SpaceStore? store;
  SourceHostState? hostState;
  String androidId = '';
  String failureSourceUrl = '';

  /// One runtime and dispatcher per source, so a helper row keeps its own
  /// source's headers and, for `R`, its own rate.
  final _runtimes = <String, InProcessSourceScriptRuntime>{};
  final _dispatchers = <String, SourceHostDispatcher>{};
  final _tokens = <String, SourceCancellation>{};

  /// One pipeline per stage source for the ordinary stages; the cancellation
  /// row opens its own, so cancelling it cannot poison a later step.
  final _pipelines = <String, BookSourcePipeline>{};
  BookSourcePipeline? _cancelledPipeline;

  final _outcomes = <String, ({String outcome, String? category})>{};
  final _hits = <String, HtmlBook>{};
  final _infos = <String, SourceBookInfo>{};
  final _chapters = <String, (HtmlBook, List<SourceChapter>)>{};
  Map<String, Object?>? _cancelExecution;
  int? _rateWindowStart;
  int exitCode = 1;

  Uri get origin =>
      Uri.parse('${_object(corpus['origins'], 'origins')['replay']}');

  String get _databasePath =>
      '${root.path}${Platform.pathSeparator}spaces'
      '${Platform.pathSeparator}default${Platform.pathSeparator}data.db';

  final _sourceObjects = <String, Map<String, dynamic>>{};

  /// One source's real object for this run, one instance per source so an
  /// identity comparison names the same object. The failure source's book
  /// source URL carries the declared `$FAILPORT` token, which the bound endpoint
  /// resolves.
  Map<String, dynamic> sourceObject(String id) =>
      _sourceObjects.putIfAbsent(id, () {
        final source = sourceObjectOf(id);
        if (id == 'F') source['bookSourceUrl'] = failureSourceUrl;
        return source;
      });

  Map<String, dynamic> sourceObjectOf(String id) =>
      Map<String, dynamic>.from(httpBoundarySourceOf(corpus, id));

  String sourceUrl(String id) => '${sourceObject(id)['bookSourceUrl']}';

  Future<void> execute() async {
    final startedAt = DateTime.now().toUtc();
    final ownerFile = File('${root.path}${Platform.pathSeparator}owner.json');
    var ownerWritten = false;
    var ownerSha = '';
    var databaseOpened = false;
    var databaseClosed = false;
    var listenerClosed = false;
    var failEndpointClosed = false;
    var libraryDisposed = false;
    var rootRemoved = false;
    var rootAbsentAfter = false;
    var removalSkipped = '';
    var initialCounts = <String, int>{};
    var finalCounts = <String, int>{};
    Object? failure;

    try {
      root.createSync(recursive: true);
      final opened = workspace = await Workspace.open(root: root);
      final space = store = await opened.openSpace();
      hostState = SourceHostState(
        persistence: SpaceHostStatePersistence(space),
      );
      androidId = await opened.androidId();
      databaseOpened = true;
      initialCounts = await _databaseCounts();
      final endpoint = failEndpoint = await _FailEndpoint.start(
        onError: (error) =>
            serverErrors.add({'endpoint': 'failure', 'error': '$error'}),
      );
      failureSourceUrl = '${httpBoundarySourceOf(corpus, 'F')['bookSourceUrl']}'
          .replaceAll(httpBoundaryFailPortToken, '${endpoint.port}');
      final cohortSizes = <String, int>{};
      final cohortTimeouts = <String, int>{};
      for (final raw in _array(corpus['cohorts'], 'cohorts')) {
        final cohort = _object(raw, 'cohort');
        cohortSizes['${cohort['id']}'] = _integer(
          cohort['size'],
          'cohort size',
        );
        cohortTimeouts['${cohort['id']}'] = _integer(
          cohort['timeoutMs'],
          'cohort timeoutMs',
        );
      }
      replay = await _ReplayServer.start(
        origin: origin,
        responses: httpBoundaryResponses(corpus),
        owners: httpBoundaryResponseOwners(corpus),
        cohortSizes: cohortSizes,
        cohortTimeouts: cohortTimeouts,
        onServerError: (error) => serverErrors.add({'replay': '$error'}),
      );
      await NativeLibrary.initialize(libraryPath: libraryPath);
      report['isolation'] = {
        'application': 'dart:io process over Workspace/SpaceStore',
        'root': root.path,
        'database': _databasePath,
        'workspaceManifest':
            '${root.path}${Platform.pathSeparator}manifest.json',
        'ownerFile': ownerFile.path,
        'rootExistedAtStart': false,
        'createdByThisRun': true,
        'preferenceFilesOutsideRoot': const <String>[],
        'preferenceBoundary':
            'the product keeps cookies, source entries and source variables in '
            'this one space database and the installation id in its manifest, '
            'both inside this root; the frozen capture names task-prefixed '
            'SharedPreferences outside its root, which the product has no '
            'counterpart for',
      };
      report['runtimeConfiguration'] = {
        'threadCount': httpBoundaryBatchWidth,
        'threadCountSource':
            'SourceHostDispatcher.ajaxAll concurrency default, '
            'lib/source/source_host_dispatcher.dart:186: the product has no '
            'AppConfig.threadCount, so its configured batch width is the '
            'compared runtime configuration',
        'threadCountPreference': null,
        'declaredNativeDefault': _object(
          corpus['runtime'],
          'runtime',
        )['threadCountDefault'],
        'resolved': true,
      };
      report['rateLimiter'] = {
        'instance': 'SourceRateLimiter()',
        'reason':
            'one SourceRateLimiter over the real clock, injected into the rate '
            "source's dispatcher; the product's shared instance is not used, so "
            'the corpus initial snapshot can be empty',
        'concurrentRate': _object(corpus['rate'], 'rate')['concurrentRate'],
        'windowMillis': _object(corpus['rate'], 'rate')['windowMillis'],
        'initialSnapshot':
            _rateRecord(rateLimiter.recordOf(sourceUrl('R'))) == null
            ? 'empty'
            : 'not-empty',
      };
      await _measure();
    } on Object catch (error, stack) {
      failure = error;
      report['analysisStack'] = '$stack';
    }

    // Cleanup: stop admission, free the holds, close everything this run owns,
    // then remove only the proven root.
    replay?.releaseAllGates();
    try {
      await replay?.close();
      listenerClosed = replay?.closed ?? false;
    } on Object catch (error) {
      failure ??= error;
    }
    try {
      await failEndpoint?.close();
      failEndpointClosed = failEndpoint?.closed ?? false;
    } on Object catch (error) {
      failure ??= error;
    }
    try {
      if (store != null) finalCounts = await _databaseCounts();
    } on Object catch (error) {
      failure ??= error;
    }
    try {
      await workspace?.close();
      databaseClosed = workspace != null;
    } on Object catch (error) {
      failure ??= error;
    }
    try {
      await InProcessSourceScriptRuntime.dispose();
      NativeLibrary.dispose();
      libraryDisposed = true;
    } on Object catch (error) {
      failure ??= error;
    }

    requests
      ..clear()
      ..addAll(replay?.requests ?? const <Map<String, Object?>>[]);
    unmatched
      ..clear()
      ..addAll(replay?.unmatched ?? const <Map<String, Object?>>[]);
    stageTrace
      ..clear()
      ..addAll(replay?.stageTrace ?? const <Map<String, Object?>>[]);
    // Each observation owns the requests whose declared selector belongs to
    // it, in arrival order; a late request keeps that owner.
    for (final observation in observations) {
      observation['requests'] = [
        for (final request in requests)
          if ('${request['owner']}' == '${observation['id']}') request,
      ];
    }
    final requestCheck = _requestCheck();
    final observationCheck = _observationCheck();
    report['requests'] = requests;
    report['unmatchedRequests'] = unmatched;
    report['serverErrors'] = serverErrors;
    report['stageTrace'] = stageTrace;
    report['requestCheck'] = requestCheck;
    report['observationCheck'] = observationCheck;
    report['observations'] = observations;
    report['inventory'] = {
      'databaseOpened': databaseOpened,
      'initial': initialCounts,
      'final': finalCounts,
    };
    report['failEndpoint'] =
        failEndpoint?.receipt() ?? const <String, Object?>{};

    if (failure == null) {
      try {
        final identity = report['identity'];
        final owner = {
          'product': 'liber-http-boundary-runner',
          'runId': report['runId'],
          'pid': pid,
          'fixtureId': corpus['fixtureId'],
          'corpusSha256Lf': corpusLf,
          'corpusRawSha256': identity is Map
              ? identity['corpusRawSha256']
              : null,
          'librarySha256': librarySha256,
          'libraryPath': libraryPath,
          'rootName': root.absolute.path
              .split(Platform.pathSeparator)
              .where((segment) => segment.isNotEmpty)
              .last,
          'createdAt': DateTime.now().toUtc().toIso8601String(),
          'complete': true,
        };
        ownerFile.writeAsStringSync(
          '${const JsonEncoder.withIndent('  ').convert(owner)}\n',
        );
        ownerWritten = true;
        ownerSha = sha256File(ownerFile);
      } on Object catch (error) {
        failure = error;
      }
    }
    if (ownerWritten) {
      try {
        root.deleteSync(recursive: true);
        rootRemoved = !root.existsSync();
        rootAbsentAfter = rootRemoved;
        if (!rootRemoved) {
          throw StateError('the scratch root could not be removed');
        }
      } on Object catch (error) {
        failure = error;
      }
    } else if (root.existsSync()) {
      removalSkipped = 'the owned root is preserved for inspection';
    }
    final integrityOk =
        listenerClosed &&
        failEndpointClosed &&
        libraryDisposed &&
        databaseClosed &&
        rootRemoved &&
        serverErrors.isEmpty &&
        failure == null;
    report['cleanup'] = {
      'admission': 'stopped before teardown',
      'listenerClosed': listenerClosed,
      'failEndpointClosed': failEndpointClosed,
      'failEndpointConnections': failEndpoint?.connections.length ?? 0,
      'nativeLibraryDisposed': libraryDisposed,
      'databaseClosed': databaseClosed,
      'ownerWritten': ownerWritten,
      'ownerSha256': ownerSha,
      'scratchRetained': root.existsSync(),
      'scratchRemoved': rootRemoved,
      'rootAbsentAfter': rootAbsentAfter,
      'removalSkipped': removalSkipped,
      'lateErrorCount': serverErrors.length,
      'terminal': {
        'listeners': {
          'replayClosed': listenerClosed,
          'failEndpointClosed': failEndpointClosed,
        },
        'bridge': {'nativeDisposed': libraryDisposed},
        'database': {'closed': databaseClosed},
        'scratch': {'removed': rootRemoved, 'absentAfter': rootAbsentAfter},
        'integrityOk': integrityOk,
      },
      'ownerManifest': {
        'path': ownerFile.path,
        'createdAt': DateTime.now().toUtc().toIso8601String(),
        'written': ownerWritten,
      },
      'startedAt': startedAt.toIso8601String(),
    };
    report['sourceDerivedNotes'] = _object(
      corpus['sourceDerivedNotes'],
      'sourceDerivedNotes',
    );
    report['coverageGaps'] = _array(corpus['coverageGaps'], 'coverageGaps');
    report['nondeterministic'] = _array(
      corpus['nondeterministic'],
      'nondeterministic',
    );
    final checksOk =
        requestCheck['match'] == true && observationCheck['match'] == true;
    if (failure != null) {
      report['status'] = 'failed';
      report['analysisFailure'] = '$failure';
      exitCode = 1;
    } else if (!integrityOk || !checksOk) {
      report['status'] = 'incomplete';
      report['analysisFailure'] =
          'the run finished but its own requests/observations/cleanup checks '
          'did not pass';
      exitCode = 3;
    } else {
      report['status'] = 'completed';
      exitCode = 0;
    }
  }

  /// Runs every declared step in corpus order. A step that cannot be finished
  /// keeps its row as `incomplete` and the run continues, so one unresolved row
  /// never hides the rest of the trace.
  Future<void> _measure() async {
    for (final step in httpBoundarySteps(corpus)) {
      final id = '${step['id']}';
      replay?.stage = id;
      final observation = <String, Object?>{
        'id': id,
        'outcome': 'incomplete',
        'category': null,
        'value': <String, Object?>{},
        'evidence': <String, Object?>{},
        'requests': <Map<String, Object?>>[],
      };
      observations.add(observation);
      try {
        switch ('${step['kind']}') {
          case 'helper':
            await _runHelper(step, observation);
          case 'rate':
            await _runRate(step, observation);
          case 'stage':
            if (id ==
                '${_object(corpus['cancellation'], 'cancellation')['followUpStep']}') {
              await _runFollowUp(step, observation);
            } else {
              await _runStage(step, observation);
            }
          case 'failure':
            await _runFailure(step, observation);
          case 'cancel':
            await _runCancel(step, observation);
          default:
            throw HttpBoundaryIncomplete('unknown step kind ${step['kind']}');
        }
      } on HttpBoundaryIncomplete catch (error) {
        observation['outcome'] = 'incomplete';
        (observation['evidence'] as Map)['incomplete'] = '$error';
      } on Object catch (error, stack) {
        observation['outcome'] = 'incomplete';
        (observation['evidence'] as Map)['error'] = '$error';
        (observation['evidence'] as Map)['stack'] = '$stack';
      }
      _outcomes[id] = (
        outcome: '${observation['outcome']}',
        category: observation['category'] as String?,
      );
    }
  }

  Map<String, dynamic> responseById(String id) => httpBoundaryResponses(
    corpus,
  ).firstWhere((response) => '${response['id']}' == id);

  SourceCancellation _tokenOf(String sourceId) =>
      _tokens.putIfAbsent(sourceId, SourceCancellation.new);

  SourceHostDispatcher _dispatcherOf(String sourceId) {
    return _dispatchers.putIfAbsent(sourceId, () {
      final source = sourceObject(sourceId);
      return SourceHostDispatcher(
        transport: HttpSourceTransport(),
        hostState: hostState,
        sourceRef: '${source['bookSourceUrl']}',
        concurrentRate: '${source['concurrentRate'] ?? ''}',
        enabledCookieJar: source['enabledCookieJar'] == true,
        cancellation: _tokenOf(sourceId),
        rateLimiter: rateLimiter,
      );
    });
  }

  InProcessSourceScriptRuntime _runtimeOf(String sourceId) =>
      _runtimes.putIfAbsent(
        sourceId,
        () => InProcessSourceScriptRuntime(
          androidId: androidId,
          hostState: hostState,
          dispatcher: _dispatcherOf(sourceId),
        ),
      );

  BookSourcePipeline _pipelineOf(String sourceId) => _pipelines.putIfAbsent(
    sourceId,
    () => openBookSourcePipeline(
      sourceObject(sourceId),
      HttpSourceTransport(),
      hostState: hostState,
      androidId: androidId,
    ),
  );

  Future<Object?> _evaluate(String sourceId, String script) =>
      _runtimeOf(sourceId)
          .evaluate(
            source: script,
            input: {
              'sourceKey': sourceUrl(sourceId),
              'source': sourceObject(sourceId),
            },
            timeout: const Duration(seconds: 60),
          )
          .timeout(const Duration(seconds: 90));

  // --- helper rows -----------------------------------------------------------

  Future<void> _runHelper(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final sourceId = '${step['source']}';
    final action = '${step['action']}';
    final value = <String, Object?>{
      'kind': 'helper',
      'action': action,
      'source': sourceId,
    };
    switch (action) {
      case 'ajax':
      case 'ajaxList':
      case 'ajaxAll':
      case 'connectHeader':
      case 'connectSource':
        final result = await _evaluate(sourceId, '${step['script']}');
        value['result'] = result is String ? result : '$result';
        final declared = httpBoundaryDeclaredRequests(step);
        if (declared.cohort != null) {
          value['batch'] = replay!.cohortBlock(declared.cohort!);
          (observation['evidence'] as Map)['batch'] = replay!.cohortEvidence(
            declared.cohort!,
          );
        }
      case 'headerMap':
        value.addAll(await _headerMapValue(observation, step));
      default:
        throw HttpBoundaryIncomplete('unknown helper action $action');
    }
    observation['value'] = value;
    observation['outcome'] = 'ok';
    observation['category'] = null;
  }

  /// The three real `source.getHeaderMap` arities, each one fixture-authored
  /// script through the product's own `source.getHeaderMap` binding. An arity
  /// that throws keeps its measured outcome; nothing is retried or repaired.
  Future<Map<String, Object?>> _headerMapValue(
    Map<String, Object?> observation,
    Map<String, dynamic> step,
  ) async {
    final scripts = _object(step['scripts'], 'headerMap scripts');
    final arities = <String, Object?>{};
    final provenance = <String, Object?>{};
    for (final arity in const ['zero', 'falseArity', 'trueArity']) {
      final script = _text(scripts[arity], 'headerMap script $arity');
      try {
        final raw = await _evaluate('${step['source']}', script);
        final decoded = jsonDecode('$raw');
        final pairs = decoded is Map ? decoded['value'] : null;
        if (pairs is! List) {
          arities[arity] = {'returned': false};
          provenance[arity] = {
            'outcome': 'refused',
            'reason': 'the script did not answer a {value:[[k,v]]} object',
            'raw': '$raw',
          };
          continue;
        }
        arities[arity] = {
          'returned': true,
          'value': [
            for (final pair in pairs)
              if (pair is List && pair.length == 2)
                ['${pair[0]}', '${pair[1]}'],
          ],
        };
        provenance[arity] = {'outcome': 'returned'};
      } on Object catch (error) {
        arities[arity] = {'returned': false};
        provenance[arity] = {
          'outcome': 'threw',
          'errorType': '${error.runtimeType}',
          'error': '$error',
        };
      }
    }
    (observation['evidence'] as Map)['arityProvenance'] = provenance;
    return {
      'kind': 'headerMap',
      'action': 'headerMap',
      'source': '${step['source']}',
      'arities': arities,
    };
  }

  // --- rate rows -------------------------------------------------------------

  /// One source-keyed real record before and after a call, with the corpus' own
  /// window relations rather than a cross-host epoch comparison.
  Future<void> _runRate(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final rate = _object(corpus['rate'], 'rate');
    final sourceId = '${step['source']}';
    final sourceKey = sourceUrl(sourceId);
    final window = _integer(rate['windowMillis'], 'rate.windowMillis');
    final index = _integer(step['index'], 'rate index');
    final before = _rateRecord(rateLimiter.recordOf(sourceKey));
    if (index == 1 && before != null) {
      throw const HttpBoundaryIncomplete(
        'the rate record existed before the first rate row',
      );
    }
    final callStart = _nowMillis();
    final watch = Stopwatch()..start();
    final result = await _evaluate(sourceId, '${step['script']}');
    watch.stop();
    final callFinish = _nowMillis();
    final after = _rateRecord(rateLimiter.recordOf(sourceKey));
    final afterTime = after?['time'] as int?;
    final value = <String, Object?>{
      'kind': 'rate',
      'index': index,
      'result': result is String ? result : '$result',
      'recordBefore': before,
      'recordAfter': after,
      'sameWindowAsPrevious': null,
      'scheduleComplete': true,
      'scheduleReason': null,
    };
    final evidence = <String, Object?>{
      'callStartMillis': callStart,
      'callFinishMillis': callFinish,
      'durationNanos': watch.elapsedMicroseconds * 1000,
      'sourceKey': sourceKey,
      'windowMillis': window,
      'recordAfterIsProvenance': true,
    };
    switch (index) {
      case 1:
        _rateWindowStart = afterTime;
        evidence['windowStartMillis'] = _rateWindowStart;
      case 2:
        final start = _rateWindowStart;
        final sameWindow = start != null && afterTime == start;
        value['sameWindowAsPrevious'] = sameWindow;
        final complete = sameWindow && callFinish - start < window;
        value['scheduleComplete'] = complete;
        value['scheduleReason'] = complete ? null : 'incomplete-schedule';
        evidence['windowStartMillis'] = start;
      case 3:
        final start = _rateWindowStart;
        final advanced = start == null || afterTime == null
            ? null
            : afterTime - start;
        value['sameWindowAsPrevious'] = advanced == 0;
        final complete = advanced != null && advanced >= window;
        value['scheduleComplete'] = complete;
        value['scheduleReason'] = complete ? null : 'incomplete-schedule';
        evidence['windowAdvanceMillis'] = advanced;
      default:
        throw const HttpBoundaryIncomplete(
          'the corpus declares three rate rows',
        );
    }
    observation['value'] = value;
    observation['evidence'] = evidence;
    observation['outcome'] = 'ok';
    observation['category'] = null;
  }

  Map<String, Object?>? _rateRecord(SourceRateRecord? record) => record == null
      ? null
      : {
          'isConcurrent': record.isConcurrent,
          'time': record.time,
          'frequency': record.frequency,
        };

  // --- stage rows ------------------------------------------------------------

  Future<void> _runStage(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final value = await _stageValue(
      _pipelineOf('${step['source']}'),
      step,
      observation,
    );
    observation['value'] = value;
    if (observation['outcome'] == 'ok') observation['category'] = null;
  }

  /// One stage value from the real pipeline entries. A stage the corpus declares
  /// as a failure records that outcome and the typed category instead of a
  /// value; an unresolved error is never swallowed as a result.
  Future<Map<String, Object?>> _stageValue(
    BookSourcePipeline pipeline,
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final id = '${step['id']}';
    final sourceId = '${step['source']}';
    final stage = '${step['stage']}';
    final value = <String, Object?>{
      'kind': 'stage',
      'stage': stage,
      'source': sourceId,
    };
    final expectedOutcome = '${step['expectedOutcome'] ?? 'ok'}';
    try {
      switch (stage) {
        case 'search':
          final keyword = _text(step['keyword'], 'step $id keyword');
          final expect = [
            for (final raw in (step['expectBooks'] as List? ?? const []))
              '$raw',
          ];
          final hits = await pipeline.search(keyword);
          if (hits.length != expect.length) {
            throw HttpBoundaryIncomplete(
              'search $id returned ${hits.length} results, the corpus declares '
              '${expect.length}',
            );
          }
          final results = <Map<String, Object?>>[];
          for (var index = 0; index < expect.length; index++) {
            final bookId = expect[index];
            final declared = _bookOf(bookId);
            final hit = hits[index];
            if (hit.identityAddress != '${declared['bookUrl']}') {
              throw HttpBoundaryIncomplete(
                'search $id result $index is ${hit.identityAddress}, the corpus '
                'declares ${declared['bookUrl']}',
              );
            }
            _hits[bookId] = hit;
            results.add({
              'id': bookId,
              'name': hit.title,
              'author': hit.author,
              'kind': hit.kind,
              'bookUrl': hit.identityAddress,
              'coverUrl': hit.cover.isEmpty ? null : hit.cover,
              'intro': hit.intro,
              'wordCount': hit.wordCount,
              'latestChapterTitle': hit.lastChapter,
            });
          }
          value['results'] = results;
        case 'details':
          final bookId = '${step['book']}';
          final hit = _hits[bookId];
          if (hit == null) {
            throw HttpBoundaryIncomplete(
              'details $id has no preceding search hit',
            );
          }
          final info = await pipeline.bookInfo(hit);
          _infos[bookId] = info;
          final book = info.book;
          // The frozen details row's `kind` is the book's own kind field, not the
          // `stage` marker the search/TOC/content rows carry.
          value['kind'] = book.kind;
          value['book'] = bookId;
          value['bookUrl'] = '${info.bookUrl}';
          value['name'] = book.title;
          value['author'] = book.author;
          value['intro'] = book.intro;
          value['coverUrl'] = book.cover.isEmpty ? null : book.cover;
          value['wordCount'] = book.wordCount;
          value['latestChapterTitle'] = book.lastChapter;
          value['tocUrl'] = info.tocUrl;
        case 'toc':
          final bookId = '${step['book']}';
          final info = _infos[bookId];
          if (info == null) {
            throw HttpBoundaryIncomplete(
              'toc $id has no preceding details step',
            );
          }
          final (book, chapters) = await pipeline.tableOfContents(info);
          _chapters[bookId] = (book, chapters);
          value['book'] = bookId;
          value['chapters'] = [
            for (var index = 0; index < chapters.length; index++)
              {
                'index': index,
                'title': chapters[index].name,
                'url': '${chapters[index].url}',
                'tag': chapters[index].tag ?? '',
              },
          ];
          _attachBatch(step, value, observation);
        case 'content':
          final bookId = '${step['book']}';
          final pending = _chapters[bookId];
          if (pending == null) {
            throw HttpBoundaryIncomplete(
              'content $id has no preceding toc step',
            );
          }
          final address = '${step['chapter']}';
          final chapter = pending.$2.firstWhere(
            (candidate) => '${candidate.url}' == address,
            orElse: () => throw HttpBoundaryIncomplete(
              'content $id found no chapter $address',
            ),
          );
          final body = await pipeline.chapter(chapter, book: pending.$1);
          value['book'] = bookId;
          value['chapter'] = address;
          value['text'] = body.text;
          _attachBatch(step, value, observation);
        default:
          throw HttpBoundaryIncomplete('unknown corpus stage $stage');
      }
    } on SourceStageDiagnostic catch (diagnostic) {
      (observation['evidence'] as Map)['rawError'] = '$diagnostic';
      if (expectedOutcome != 'failure') {
        observation['outcome'] = 'incomplete';
        throw HttpBoundaryIncomplete(
          'stage $id answered a stage diagnostic: $diagnostic',
        );
      }
      observation['outcome'] = 'failure';
      observation['category'] = _categoryOf(diagnostic, step);
      return value;
    }
    if (expectedOutcome == 'failure') {
      observation['outcome'] = 'incomplete';
      throw HttpBoundaryIncomplete(
        'step $id was declared to fail and answered a value',
      );
    }
    observation['outcome'] = 'ok';
    return value;
  }

  Map<String, dynamic> _bookOf(String id) => _object(
    _array(corpus['books'], 'books').firstWhere(
      (raw) => '${(raw as Map)['id']}' == id,
      orElse: () => throw FormatException('the corpus declares no book $id'),
    ),
    'book $id',
  );

  void _attachBatch(
    Map<String, dynamic> step,
    Map<String, Object?> value,
    Map<String, Object?> observation,
  ) {
    final cohort = httpBoundaryDeclaredRequests(step).cohort;
    if (cohort == null) return;
    value['batch'] = replay!.cohortBlock(cohort);
    (observation['evidence'] as Map)['batch'] = replay!.cohortEvidence(cohort);
  }

  /// The typed category of one stage diagnostic, limited to the failure kinds
  /// the corpus declares: an empty table of contents and a connection failure.
  String _categoryOf(
    SourceStageDiagnostic diagnostic,
    Map<String, dynamic> step,
  ) {
    final declared = step['expectedCategory'];
    if (declared is String && declared.isNotEmpty) return declared;
    if (diagnostic.kind == SourceStageFailureKind.connection) {
      return 'network-failure';
    }
    return 'unclassified';
  }

  // --- the task-owned connection failure -------------------------------------

  Future<void> _runFailure(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final endpoint = failEndpoint;
    if (endpoint == null) {
      throw const HttpBoundaryIncomplete('the failure endpoint is not bound');
    }
    endpoint.arm();
    final sourceId = '${step['source']}';
    Object? caught;
    try {
      await _pipelineOf(sourceId).search(_text(step['keyword'], 'keyword'));
    } on SourceStageDiagnostic catch (diagnostic) {
      if (diagnostic.kind != SourceStageFailureKind.connection) {
        endpoint.disarm();
        observation['outcome'] = 'incomplete';
        throw HttpBoundaryIncomplete(
          'the failure row answered ${diagnostic.kind}, not a connection '
          'failure',
        );
      }
      caught = diagnostic;
    } on SocketException catch (error) {
      caught = error;
    } on HttpException catch (error) {
      caught = error;
    } on TlsException catch (error) {
      caught = error;
    } finally {
      endpoint.disarm();
    }
    if (caught == null) {
      throw const HttpBoundaryIncomplete(
        'the failure row completed; no connection failure was measured',
      );
    }
    final connections = endpoint.connections;
    observation['value'] = {
      'kind': 'failure',
      'source': sourceId,
      'acceptedConnections': connections.length,
      'transportReconnects': connections
          .where(
            (connection) =>
                connection['classification'] == 'transport-reconnect',
          )
          .length,
    };
    observation['evidence'] = {'rawError': '$caught'};
    observation['outcome'] = 'failure';
    observation['category'] = 'network-failure';
  }

  // --- cancellation and its bound follow-up ----------------------------------

  /// The measured cancellation: the pipeline is cancelled only after the replay
  /// confirms its held request was entered, and the row keeps the peer abort,
  /// the termination, the quiet window, the declared state probes and the
  /// database snapshot.
  Future<void> _runCancel(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final cancellation = _object(corpus['cancellation'], 'cancellation');
    final sourceId = '${step['source']}';
    final keys = [
      for (final raw in _array(cancellation['stateProbes'], 'stateProbes'))
        '$raw',
    ];
    final before = await _stateProbe(sourceId, keys);
    // The corpus' cancel source runs the HTML adapter, whose own `cancelled`
    // getter is the execution's real cancellation state. Measuring it is what
    // the row records; no unrelated token stands in for it.
    final pipeline = html_boundary.HtmlSourcePipeline(
      sourceObject(sourceId),
      HttpSourceTransport(),
      hostState: hostState,
      androidId: androidId,
    );
    _cancelledPipeline = pipeline;
    final cancelledBeforeRequest = pipeline.cancelled;
    if (cancelledBeforeRequest) {
      throw const HttpBoundaryIncomplete(
        'the cancellation execution was already cancelled before it started',
      );
    }
    final hold = replay!.hold;
    final worker = pipeline.search(_text(step['keyword'], 'cancel keyword'));
    Object? workerFailure;
    var terminated = false;
    final settled = worker.then<void>(
      (_) => terminated = true,
      onError: (Object error) {
        workerFailure = error;
        terminated = true;
      },
    );
    final holdWindow = _integer(cancellation['holdTimeoutMs'], 'holdTimeoutMs');
    final entered = await hold.entered.timeout(
      Duration(milliseconds: holdWindow),
      onTimeout: () => false,
    );
    final value = <String, Object?>{
      'kind': 'cancel',
      'source': sourceId,
      'holdEntered': entered,
      'cancelRequested': false,
    };
    if (!entered) {
      replay!.releaseHold();
      await settled;
      throw const HttpBoundaryIncomplete(
        'the held request was not entered inside the declared hold window',
      );
    }
    pipeline.cancel();
    final cancelledAtRequest = pipeline.cancelled;
    hold.cancelNanos = _nowNanos();
    value['cancelRequested'] = true;
    // The peer's own close is what the held response reports while nothing has
    // been written; a release before it is never named an abort.
    final peerClosed = await hold.peerClosed
        .then<Object?>((error) => error)
        .timeout(const Duration(seconds: 10), onTimeout: () => null);
    replay!.releaseHold();
    await settled.timeout(
      const Duration(seconds: 20),
      onTimeout: () {
        throw const HttpBoundaryIncomplete(
          'the cancelled search did not finish inside 20s',
        );
      },
    );
    final writeFailed = await hold.abortObserved.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () => false,
    );
    final aborted = peerClosed != null || writeFailed;
    await Future<void>.delayed(
      Duration(milliseconds: _integer(cancellation['quietWindowMs'], 'quiet')),
    );
    final workerOutcome = workerFailure == null
        ? 'completed-normally'
        : workerFailure is SourceRequestCancelled
        ? 'cancelled'
        : 'failure';
    final cancelledAt = hold.cancelNanos;
    final late = [
      for (final request in replay!.requests)
        if ('${request['owner']}' == '${step['id']}' &&
            (request['receivedAtNanos'] as int? ?? 0) > cancelledAt)
          {
            'selector': request['selector'],
            'receivedAtNanos': request['receivedAtNanos'],
          },
    ];
    final after = await _stateProbe(sourceId, keys);
    final valuesUnchanged =
        jsonEncode(before['sourceValues']) ==
            jsonEncode(after['sourceValues']) &&
        jsonEncode(before['variable']) == jsonEncode(after['variable']);
    final databaseUnchanged =
        jsonEncode(before['database']) == jsonEncode(after['database']);
    // The measured state of the execution this run cancelled: the HTML
    // pipeline's own cancellation, read on the same object that ran the search.
    final jobInactive = cancelledAtRequest && pipeline.cancelled;
    final jobDone = jobInactive && terminated;
    final derived = _deriveCancelOutcome(
      workerOutcome: workerOutcome,
      aborted: aborted,
      terminated: terminated,
      jobDone: jobDone,
      lateCount: late.length,
      valuesUnchanged: valuesUnchanged,
      databaseUnchanged: databaseUnchanged,
    );
    value.addAll({
      'clientAborted': aborted,
      'workerTerminated': terminated,
      'jobInactive': jobInactive,
      'jobCompleted': terminated,
      'jobDone': jobDone,
      'workerOutcome': workerOutcome,
      'lateRequests': late,
      'stateProbes': {
        'sourceValues': {
          'before': before['sourceValues'],
          'after': after['sourceValues'],
        },
        'variable': {'before': before['variable'], 'after': after['variable']},
        'unchanged': valuesUnchanged,
        'databaseUnchanged': databaseUnchanged,
      },
      'execution': {
        'sourceKey': sourceUrl(sourceId),
        'jobLevel': 'pipeline-cancellation',
        'tokenPresent': true,
        'jobInactive': jobInactive,
        'jobCompleted': terminated,
      },
      'derivedOutcome': derived,
    });
    _cancelExecution = {
      'pipelineIdentity': identityHashCode(pipeline),
      'transportIdentity': identityHashCode(pipeline.transport),
      'sourceObjectIdentity': identityHashCode(sourceObject(sourceId)),
      'sourceKey': sourceUrl(sourceId),
    };
    observation['value'] = value;
    observation['evidence'] = {
      'execution': {
        ..._cancelExecution!,
        'jobLevel': 'pipeline-cancellation',
        'boundBeforeInvocation': true,
        'tokenPresent': true,
        'keyword': '${step['keyword']}',
      },
      'workerFailure': workerFailure == null ? null : '$workerFailure',
      'peerClosed': peerClosed == null ? null : '$peerClosed',
      'cancellationState': {
        'cancelledBeforeRequest': cancelledBeforeRequest,
        'cancelledAtRequest': cancelledAtRequest,
        'cancelledAfterSettle': pipeline.cancelled,
        'workerSettled': terminated,
        'quietWindowMs': _integer(
          cancellation['quietWindowMs'],
          'quietWindowMs',
        ),
        'lateRequestCount': late.length,
      },
      'dbProvenance': {
        'before': before['database'],
        'after': after['database'],
        'productTableSnapshotIsProvenance': true,
      },
    };
    final outcome = '${derived['outcome']}';
    if (outcome == 'cancelled') {
      observation['outcome'] = 'cancelled';
      observation['category'] = '${derived['category']}';
      return;
    }
    observation['outcome'] = 'incomplete';
    throw HttpBoundaryIncomplete(
      'cancellation outcome is $outcome: $derived'
      '${workerFailure == null ? '' : ' ($workerFailure)'}',
    );
  }

  /// The corpus' own cancellation verdict, mirroring the native producer's:
  /// a cancellation whose receipts all hold is the cancellation outcome, a
  /// failed or normally-completed worker is a failure, anything else is
  /// incomplete.
  Map<String, Object?> _deriveCancelOutcome({
    required String workerOutcome,
    required bool aborted,
    required bool terminated,
    required bool jobDone,
    required int lateCount,
    required bool valuesUnchanged,
    required bool databaseUnchanged,
  }) {
    final receipts =
        aborted &&
        terminated &&
        jobDone &&
        lateCount == 0 &&
        valuesUnchanged &&
        databaseUnchanged;
    if (workerOutcome == 'cancelled' && receipts) {
      return {
        'outcome': 'cancelled',
        'category': 'cancellation',
        'receiptsComplete': receipts,
      };
    }
    if (workerOutcome == 'failure' || workerOutcome == 'completed-normally') {
      return {
        'outcome': 'failure',
        'category': 'unknown',
        'receiptsComplete': receipts,
      };
    }
    return {
      'outcome': 'incomplete',
      'category': 'unresolved-entry',
      'receiptsComplete': receipts,
    };
  }

  /// One portable state probe through the product's own `source.get` and
  /// `source.getVariable` bindings, plus this space's own table counts.
  Future<Map<String, Object?>> _stateProbe(
    String sourceId,
    List<String> keys,
  ) async {
    final raw = await _evaluate(
      sourceId,
      'JSON.stringify({'
      '"variable":source.getVariable(),'
      '"values":[${[for (final key in keys) 'source.get(${jsonEncode(key)})'].join(',')}]'
      '})',
    );
    final decoded = jsonDecode('$raw');
    if (decoded is! Map) {
      throw const HttpBoundaryIncomplete('the state probe answered no object');
    }
    final values = decoded['values'];
    if (values is! List || values.length != keys.length) {
      throw const HttpBoundaryIncomplete(
        'the state probe answered no value for every declared key',
      );
    }
    final sourceValues = <String, Object?>{};
    for (var index = 0; index < keys.length; index++) {
      sourceValues[keys[index]] = _typedValue(values[index]);
    }
    return {
      'sourceValues': sourceValues,
      'variable': _typedValue(decoded['variable']),
      'database': await _databaseCounts(),
    };
  }

  Map<String, Object?> _typedValue(Object? raw) {
    if (raw == null) return {'present': false};
    return {'present': true, 'value': '$raw'};
  }

  /// This space's own tables. The table names are this runtime's schema; the
  /// compared fact is that the snapshot is unchanged across the cancellation.
  Future<Map<String, int>> _databaseCounts() async {
    final space = store;
    if (space == null) {
      throw const HttpBoundaryIncomplete('the database is not open');
    }
    final counts = <String, int>{};
    for (final table in const [
      'books',
      'chapters',
      'source_entries',
      'source_cookies',
    ]) {
      final row = await space.db
          .customSelect('select count(*) as n from $table')
          .getSingle();
      final value = row.data['n'];
      if (value is! int) {
        throw HttpBoundaryIncomplete('the $table count is not an integer');
      }
      counts[table] = value;
    }
    return counts;
  }

  /// The post-cancellation search: bound before invocation to its own fresh
  /// execution (a new pipeline's own cancellation and transport) over the same
  /// source object and key.
  Future<void> _runFollowUp(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final cancellation = _object(corpus['cancellation'], 'cancellation');
    final sourceId = '${step['source']}';
    final cancelled = _cancelledPipeline;
    final cancelExecution = _cancelExecution;
    if (cancelled == null || cancelExecution == null) {
      throw const HttpBoundaryIncomplete(
        'the follow-up has no cancelled execution to compare with',
      );
    }
    final source = sourceObject(sourceId);
    final pipeline = openBookSourcePipeline(
      source,
      HttpSourceTransport(),
      hostState: hostState,
      androidId: androidId,
    );
    final execution = <String, Object?>{
      'pipelineIdentity': identityHashCode(pipeline),
      'transportIdentity': identityHashCode(pipeline.transport),
      'sourceObjectIdentity': identityHashCode(source),
      'sourceKey': sourceUrl(sourceId),
      'jobLevel': 'pipeline-cancellation',
      'boundBeforeInvocation': true,
    };
    final value = await _stageValue(pipeline, step, observation);
    final followUpCompleted = observation['outcome'] == 'ok';
    final jobIdentityFresh =
        execution['pipelineIdentity'] != cancelExecution['pipelineIdentity'];
    final contextIdentityFresh =
        execution['transportIdentity'] != cancelExecution['transportIdentity'];
    final sameSourceObject =
        execution['sourceObjectIdentity'] ==
        cancelExecution['sourceObjectIdentity'];
    final sameSourceKey =
        '${cancelExecution['sourceKey']}' == sourceUrl(sourceId);
    value['followUp'] = {
      'jobIdentityFresh': jobIdentityFresh,
      'contextIdentityFresh': contextIdentityFresh,
      'sameSourceObject': sameSourceObject,
      'sameSourceKey': sameSourceKey,
      'jobLevel': 'pipeline-cancellation',
      'jobClosed': followUpCompleted,
      'sourceKey': sourceUrl(sourceId),
      'tokenPresent': true,
    };
    (observation['evidence'] as Map)['followUpExecution'] = {
      ...execution,
      'sourceKeyAfter': sourceUrl(sourceId),
      'cancelledPipelineIdentity': cancelExecution['pipelineIdentity'],
      'derivedFreshness': {
        'jobIdentityFresh': jobIdentityFresh,
        'contextIdentityFresh': contextIdentityFresh,
        'sameSourceObject': sameSourceObject,
        'sameSourceKey': sameSourceKey,
        'proven':
            jobIdentityFresh &&
            contextIdentityFresh &&
            sameSourceObject &&
            sameSourceKey,
      },
      'declaredStep': '${cancellation['followUpStep']}',
    };
    observation['value'] = value;
  }

  // --- the corpus' own structural checks over the measured trace -------------

  Map<String, Object?> _requestCheck() {
    final steps = httpBoundarySteps(corpus);
    final stepIds = {for (final step in steps) '${step['id']}'};
    final owners = httpBoundaryResponseOwners(corpus);
    final responseById = {
      for (final response in httpBoundaryResponses(corpus))
        '${response['id']}': response,
    };
    final forbidden = [
      for (final raw in _array(
        _object(corpus['requestChecks'], 'requestChecks')['forbiddenHeaders'],
        'requestCheck.forbiddenHeaders',
      ))
        '$raw'.toLowerCase(),
    ];
    final fieldProblems = <String>[];
    final terminalProblems = <String>[];
    final indices = <int>{};
    final ownerless = <String>[];
    final unknownOwners = <String>[];
    for (final request in requests) {
      final index = request['index'];
      if (index is! int || !indices.add(index)) {
        fieldProblems.add('request index $index is not unique');
      }
      final owner = '${request['owner'] ?? ''}';
      if (owner.isEmpty) {
        ownerless.add('$index');
        continue;
      }
      if (!stepIds.contains(owner)) unknownOwners.add('$index:$owner');
      final method = '${request['method']}';
      final path = '${request['path']}';
      final rawQuery = '${request['rawQuery']}';
      if ('${request['selector']}' != '$method $path?$rawQuery') {
        fieldProblems.add(
          'request $index selector does not match its method, path and raw '
          'query',
        );
      }
      final target = rawQuery.isEmpty ? path : '$path?$rawQuery';
      if ('${request['target']}' != target) {
        fieldProblems.add('request $index target does not match path/rawQuery');
      }
      final decoded = Uri.splitQueryString(rawQuery);
      if (jsonEncode(request['query']) != jsonEncode(decoded)) {
        fieldProblems.add('request $index query does not decode its raw query');
      }
      final declaredResponse = request['declaredResponse'];
      if (declaredResponse is! String ||
          !responseById.containsKey(declaredResponse)) {
        fieldProblems.add('request $index does not name a declared response');
      } else {
        final declaredOwner = owners[declaredResponse]!;
        if (declaredOwner.step != owner) {
          fieldProblems.add(
            'request $index is owned by $owner, its declaration belongs to '
            '${declaredOwner.step}',
          );
        }
      }
      for (final field in const [
        'listener',
        'owner',
        'family',
        'stage',
        'selector',
        'method',
        'path',
        'rawQuery',
        'target',
        'headerLines',
        'body',
        'headers',
        'outcome',
        'terminal',
        'attemptKind',
      ]) {
        if (!request.containsKey(field)) {
          fieldProblems.add('request $index has no $field');
        }
      }
      for (final field in const [
        'attempt',
        'receivedAtNanos',
        'sentAtNanos',
        'respondedAtNanos',
        'sendSequence',
        'status',
        'bodyLength',
      ]) {
        if (request[field] is! int) {
          fieldProblems.add('request $index $field is not an integer');
        }
      }
      final terminal = '${request['terminal']}';
      if (!const {
        'responded',
        'client-aborted',
        'hold-window-expired',
      }.contains(terminal)) {
        terminalProblems.add('request $index terminal $terminal is not honest');
      } else if (terminal == 'responded' && request['status'] is! int) {
        terminalProblems.add('request $index responded without a status');
      } else if (terminal != 'responded' && request['status'] != -1) {
        terminalProblems.add(
          'request $index is $terminal but carries a status',
        );
      }
      final headers = request['headers'];
      if (headers is! Map) {
        fieldProblems.add('request $index headers is not an object');
        continue;
      }
      for (final name in forbidden) {
        if (headers.keys.any((key) => '$key'.toLowerCase() == name)) {
          fieldProblems.add(
            'request $index carries the forbidden header $name',
          );
        }
      }
      final step = steps.firstWhere(
        (candidate) => '${candidate['id']}' == owner,
      );
      final required = step['requiredHeaders'];
      if (required is Map) {
        for (final entry in required.entries) {
          final name = '${entry.key}'.toLowerCase();
          Object? actual;
          for (final key in headers.keys) {
            if ('$key'.toLowerCase() == name) actual = headers[key];
          }
          if (actual != entry.value) {
            fieldProblems.add(
              'request $index required header $name is $actual, the corpus '
              'declares ${entry.value}',
            );
          }
        }
      }
      final stepForbidden = step['forbiddenHeaders'];
      if (stepForbidden is List) {
        for (final raw in stepForbidden) {
          final name = '$raw'.toLowerCase();
          if (headers.keys.any((key) => '$key'.toLowerCase() == name)) {
            fieldProblems.add(
              'request $index carries the forbidden header $name',
            );
          }
        }
      }
    }
    final perStep = <Map<String, Object?>>[];
    for (final step in steps) {
      final id = '${step['id']}';
      final declared = httpBoundaryDeclaredRequests(step);
      final actual = [
        for (final request in requests)
          if ('${request['owner']}' == id) '${request['selector']}',
      ];
      final expectedOrdered = [
        for (final responseId in declared.ordered)
          httpBoundarySelectorOf(responseById[responseId]!),
      ];
      final expectedBatch = [
        for (final responseId in declared.members)
          httpBoundarySelectorOf(responseById[responseId]!),
      ];
      final countMatch =
          actual.length == expectedOrdered.length + expectedBatch.length;
      final orderMatch = expectedOrdered.isEmpty
          ? true
          : _isPrefix(expectedOrdered, actual);
      final batchActual = expectedOrdered.isEmpty
          ? actual
          : actual.skip(expectedOrdered.length).toList();
      final batchMatch = _multisetEquals(expectedBatch, batchActual);
      perStep.add({
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
    final declaredTotal = _integer(
      _object(corpus['structural'], 'structural')['requests'],
      'structural.requests',
    );
    final totalMatch = requests.length == declaredTotal;
    final stepsMatch = perStep.every((row) => row['match'] == true);
    return {
      'steps': perStep,
      'declaredTotal': declaredTotal,
      'actualTotal': requests.length,
      'totalMatch': totalMatch,
      'ownerless': ownerless,
      'unknownOwners': unknownOwners,
      'duplicateIndices': requests.length - indices.length,
      'fieldProblems': fieldProblems,
      'terminalProblems': terminalProblems,
      'unmatchedRequests': unmatched.length,
      'serverErrors': serverErrors.length,
      'match':
          totalMatch &&
          stepsMatch &&
          fieldProblems.isEmpty &&
          terminalProblems.isEmpty &&
          ownerless.isEmpty &&
          unknownOwners.isEmpty &&
          requests.length == indices.length &&
          unmatched.isEmpty,
    };
  }

  Map<String, Object?> _observationCheck() {
    final declared = httpBoundaryObservationIds(corpus);
    final actual = [
      for (final observation in observations) '${observation['id']}',
    ];
    final missing = [
      for (final id in declared)
        if (!actual.contains(id)) id,
    ];
    final extra = [
      for (final id in actual)
        if (!declared.contains(id)) id,
    ];
    final duplicates = <String>[];
    final seen = <String>{};
    for (final id in actual) {
      if (!seen.add(id)) duplicates.add(id);
    }
    final outcomeMismatches = <String>[];
    final requestCountMismatches = <String>[];
    final shapeMismatches = <String>[];
    for (final step in httpBoundarySteps(corpus)) {
      final id = '${step['id']}';
      final observation = _observationsById(id);
      if (observation == null) continue;
      final outcome = _outcomes[id];
      final expectedOutcome = '${step['expectedOutcome'] ?? 'ok'}';
      if (outcome == null || outcome.outcome != expectedOutcome) {
        outcomeMismatches.add('$id: ${outcome?.outcome}');
      }
      final expectedCategory = step['expectedCategory'];
      if (expectedCategory != null &&
          outcome != null &&
          outcome.category != '$expectedCategory') {
        outcomeMismatches.add('$id category: ${outcome.category}');
      }
      final declaredRequests = httpBoundaryDeclaredRequests(step);
      final expectedCount =
          declaredRequests.ordered.length + declaredRequests.members.length;
      final owned = [
        for (final request in requests)
          if ('${request['owner']}' == id) request,
      ];
      if ('${step['kind']}' == 'failure') {
        if (owned.isNotEmpty) {
          requestCountMismatches.add(
            '$id: the failed row made ${owned.length} ordinary requests',
          );
        }
      } else if (owned.length != expectedCount) {
        requestCountMismatches.add('$id: ${owned.length} != $expectedCount');
      }
      final value = observation['value'];
      if (value is! Map || value.isEmpty) {
        shapeMismatches.add('$id has no value');
      }
    }
    return {
      'declared': declared,
      'actual': actual,
      'missing': missing,
      'extra': extra,
      'duplicates': duplicates,
      'ordered': jsonEncode(declared) == jsonEncode(actual),
      'outcomeMismatches': outcomeMismatches,
      'requestCountMismatches': requestCountMismatches,
      'shapeMismatches': shapeMismatches,
      'match':
          missing.isEmpty &&
          extra.isEmpty &&
          duplicates.isEmpty &&
          jsonEncode(declared) == jsonEncode(actual) &&
          outcomeMismatches.isEmpty &&
          requestCountMismatches.isEmpty &&
          shapeMismatches.isEmpty,
    };
  }

  Map<String, Object?>? _observationsById(String id) {
    for (final observation in observations) {
      if ('${observation['id']}' == id) return observation;
    }
    return null;
  }
}

bool _isPrefix(List<String> expected, List<String> actual) {
  if (actual.length < expected.length) return false;
  for (var index = 0; index < expected.length; index++) {
    if (actual[index] != expected[index]) return false;
  }
  return true;
}

bool _multisetEquals(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  final counts = <String, int>{};
  for (final value in left) {
    counts[value] = (counts[value] ?? 0) + 1;
  }
  for (final value in right) {
    final remaining = counts[value];
    if (remaining == null || remaining == 0) return false;
    counts[value] = remaining - 1;
  }
  return counts.values.every((count) => count == 0);
}

// --- the corpus replay listener ----------------------------------------------

/// The corpus' one replay listener. A request is matched by method, path and
/// the exact raw query bytes; the declared concurrent members of one cohort are
/// held until the cohort is complete or its own window expires, and every row
/// keeps what actually happened.
class _ReplayServer {
  _ReplayServer._(
    this._server,
    this.origin,
    this._responses,
    this._owners,
    this._cohortSizes,
    this._cohortTimeouts,
    this._onServerError,
  );

  static Future<_ReplayServer> start({
    required Uri origin,
    required List<Map<String, dynamic>> responses,
    required Map<String, ({String step, String family, String? cohort})> owners,
    required Map<String, int> cohortSizes,
    required Map<String, int> cohortTimeouts,
    required void Function(Object error) onServerError,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(origin.host, origin.port);
    } on SocketException catch (error) {
      throw HttpBoundaryRefusal(
        'the corpus origin $origin is busy: ${error.message}. The port is '
        'fixed because the source objects are compared inputs; stop whatever '
        'holds it instead of moving the corpus.',
      );
    }
    final instance = _ReplayServer._(
      server,
      origin,
      responses,
      owners,
      cohortSizes,
      cohortTimeouts,
      onServerError,
    );
    server.listen(instance._handle, onError: onServerError);
    return instance;
  }

  final HttpServer _server;
  final Uri origin;
  final List<Map<String, dynamic>> _responses;
  final Map<String, ({String step, String family, String? cohort})> _owners;
  final Map<String, int> _cohortSizes;
  final Map<String, int> _cohortTimeouts;
  final void Function(Object error) _onServerError;

  final requests = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final stageTrace = <Map<String, Object?>>[];
  final _gates = <String, _CohortGate>{};
  final _attempts = <String, int>{};
  final _lastTerminal = <String, String>{};
  final hold = _HoldGate();

  /// The corpus step currently running, recorded with every request as
  /// provenance only.
  String stage = '';

  bool _closed = false;
  bool get closed => _closed;

  Map<String, Object?> cohortBlock(String cohort) => _gates[cohort]!.block();

  Map<String, Object?> cohortEvidence(String cohort) =>
      _gates[cohort]!.evidence();

  void releaseHold() => hold.release();

  void releaseAllGates() {
    hold.release();
    for (final gate in _gates.values) {
      gate.release('cohort-window');
    }
  }

  Future<void> _handle(HttpRequest request) async {
    final receivedAt = _nowNanos();
    final body = request.method == 'POST'
        ? await utf8.decoder.bind(request).join()
        : '';
    final headers = <String, Object?>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.length == 1
          ? values.single
          : values.join(', ');
    });
    final headerLines = <String>[];
    request.headers.forEach((name, values) {
      for (final value in values) {
        headerLines.add('${_headerCase(name)}: $value');
      }
    });
    final bytes = utf8.encode(body);
    final declared = _match(request.method, request.uri);
    final declaredId = declared == null ? null : '${declared['id']}';
    final owner = declaredId == null ? null : _owners[declaredId];
    final selector =
        '${request.method} ${request.uri.path}?${request.uri.query}';
    final attempt = _attempts.update(
      selector,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    final previous = _lastTerminal[selector];
    final index = requests.length + 1;
    final record = <String, Object?>{
      'listener': _server.address.address,
      'owner': owner?.step ?? '',
      'family': owner?.family ?? '',
      'cohort': owner?.cohort,
      'attempt': attempt,
      'attemptKind': attempt == 1
          ? 'initial'
          : previous == 'responded'
          ? 'source-status-retry'
          : 'transport-reconnect',
      'selector': selector,
      'method': request.method,
      'target': _target(request.uri),
      'path': request.uri.path,
      'rawQuery': request.uri.query,
      'query': request.uri.queryParameters,
      'headers': headers,
      'headerLines': headerLines,
      'body': body,
      'bodyLength': bytes.length,
      'bodySha256': sha256Bytes(bytes),
      'receivedAtNanos': receivedAt,
      'respondedAtNanos': receivedAt,
      'sentAtNanos': receivedAt,
      'sendSequence': index,
      'status': -1,
      'terminal': 'received',
      'declaredResponse': declaredId,
      'outcome': 'received',
      'stage': stage,
      'index': index,
    };
    requests.add(record);
    stageTrace.add({
      'stage': stage,
      'listener': _server.address.address,
      'target': record['target'],
      'owner': record['owner'],
    });
    if (declared == null || owner == null) {
      record['terminal'] = 'omitted-unmatched';
      record['outcome'] = 'omitted-unmatched';
      _lastTerminal[selector] = 'omitted-unmatched';
      unmatched.add(record);
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.text;
      request.response.add(utf8.encode('undeclared replay request'));
      await request.response.close();
      return;
    }
    _CohortGate? gate;
    final cohort = owner.cohort;
    if (cohort != null) {
      gate = _gates.putIfAbsent(
        cohort,
        () => _CohortGate(
          cohort,
          _cohortSizes[cohort]!,
          _cohortTimeouts[cohort]!,
        ),
      );
      final arrival = await gate.arrive(selector);
      record['cohortComplete'] = arrival.cohortComplete;
      record['releaseReason'] = arrival.releaseReason;
      record['sentAtNanos'] = _nowNanos();
    }
    if (declared['hold'] == true) {
      await _handleHeld(request, record, declared, selector);
      gate?.finish();
      return;
    }
    try {
      request.response.statusCode = _integer(declared['status'], 'status');
      final declaredHeaders =
          (declared['headers'] as Map?)?.cast<String, dynamic>() ?? const {};
      for (final entry in declaredHeaders.entries) {
        final name = entry.key.toLowerCase();
        if (name == 'content-length' || name == 'transfer-encoding') continue;
        if (name == 'content-type') {
          request.response.headers.contentType = ContentType.parse(
            '${entry.value}',
          );
        } else {
          request.response.headers.set(entry.key, '${entry.value}');
        }
      }
      request.response.add(utf8.encode('${declared['body'] ?? ''}'));
      await request.response.close();
      record['respondedAtNanos'] = _nowNanos();
      record['sentAtNanos'] = _nowNanos();
      record['status'] = declared['status'];
      record['terminal'] = 'responded';
      record['outcome'] = 'responded';
      _lastTerminal[selector] = 'responded';
    } on Object catch (error) {
      record['terminal'] = 'write-failed';
      record['outcome'] = 'write-failed';
      _lastTerminal[selector] = 'write-failed';
      _onServerError(error);
    } finally {
      gate?.finish();
    }
  }

  /// One held response: the socket is detached so the peer's own close is
  /// observable while nothing has been written, then the declared response is
  /// written once the hold is released. A write or flush that fails, or a peer
  /// that closed first, is the measured client abort; nothing is assumed.
  Future<void> _handleHeld(
    HttpRequest request,
    Map<String, Object?> record,
    Map<String, dynamic> declared,
    String selector,
  ) async {
    final body = utf8.encode('${declared['body'] ?? ''}');
    final status = _integer(declared['status'], 'status');
    Socket socket;
    try {
      socket = await request.response.detachSocket(writeHeaders: false);
    } on Object catch (error) {
      record['terminal'] = 'write-failed';
      record['outcome'] = 'write-failed';
      _lastTerminal[selector] = 'write-failed';
      _onServerError(error);
      hold.finish(aborted: false);
      return;
    }
    final subscription = socket.listen(
      (_) {},
      onDone: () => hold.notePeerClosed('peer-closed'),
      onError: (Object error) => hold.notePeerClosed(error),
    );
    // The detached socket belongs to this handler now, not to the server: every
    // path below has to close it, or the process keeps a live handle after the
    // report is written.
    try {
      hold.enter(selector);
      await hold.released.future;
      if (hold.peerClosedObserved) {
        // The peer closed while the response was held: this row's honest
        // terminal is the abort it measured, whichever way a later write would
        // behave.
        record['terminal'] = 'client-aborted';
        record['outcome'] = 'client-aborted';
        _lastTerminal[selector] = 'client-aborted';
        hold.finish(aborted: true);
        return;
      }
      try {
        socket.write(
          'HTTP/1.1 $status OK\r\n'
          'Content-Type: text/plain\r\n'
          'Content-Length: ${body.length}\r\n'
          'Connection: close\r\n\r\n',
        );
        socket.add(body);
        await socket.flush();
        await socket.close();
        record['respondedAtNanos'] = _nowNanos();
        record['sentAtNanos'] = _nowNanos();
        record['status'] = status;
        record['terminal'] = 'responded';
        record['outcome'] = 'responded';
        _lastTerminal[selector] = 'responded';
        hold.finish(aborted: false);
      } on Object catch (error) {
        record['terminal'] = 'client-aborted';
        record['outcome'] = 'client-aborted';
        record['abortError'] = '$error';
        _lastTerminal[selector] = 'client-aborted';
        hold.notePeerClosed(error);
        hold.finish(aborted: true);
      }
    } finally {
      await subscription.cancel();
      socket.destroy();
    }
  }

  Map<String, dynamic>? _match(String method, Uri uri) {
    for (final response in _responses) {
      if (response['method'] != method) continue;
      if (response['path'] != uri.path) continue;
      if ('${response['rawQuery'] ?? ''}' != uri.query) continue;
      return response;
    }
    return null;
  }

  String _target(Uri uri) =>
      uri.hasQuery ? '${uri.path}?${uri.query}' : uri.path;

  Future<void> close() async {
    releaseAllGates();
    await _server.close(force: true);
    _closed = true;
  }
}

/// One declared concurrent batch: its members are held until every member is in
/// flight or the cohort's own window expires, and the block keeps the measured
/// peak, membership and release reason.
class _CohortGate {
  _CohortGate(this.id, this.size, this.timeoutMs);

  final String id;
  final int size;
  final int timeoutMs;
  final membership = <String>[];
  final _waiting = <Completer<void>>[];
  int inFlight = 0;
  int peak = 0;
  bool complete = false;
  bool released = false;
  String releaseReason = '';

  Future<_CohortArrival> arrive(String selector) async {
    membership.add(selector);
    inFlight++;
    if (inFlight > peak) peak = inFlight;
    if (!released) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      if (membership.length == 1) {
        Timer(Duration(milliseconds: timeoutMs), releaseWindow);
      }
      if (membership.length >= size) {
        complete = true;
        release('complete');
      }
      await waiter.future;
    }
    return _CohortArrival(
      cohortComplete: complete,
      releaseReason: released
          ? releaseReason
          : (complete ? 'complete' : 'cohort-window'),
    );
  }

  void releaseWindow() {
    if (released) return;
    release(complete ? 'complete' : 'cohort-window');
  }

  void release(String reason) {
    if (released) return;
    released = true;
    releaseReason = reason;
    for (final waiter in _waiting) {
      if (!waiter.isCompleted) waiter.complete();
    }
    _waiting.clear();
  }

  void finish() {
    if (inFlight > 0) inFlight--;
  }

  Map<String, Object?> block() => {
    'cohort': id,
    'cohortSize': size,
    'cohortTimeoutMs': timeoutMs,
    'entered': true,
    'cohortComplete': complete,
    'releaseReason': released ? releaseReason : 'cohort-window',
    'inFlightPeak': peak,
    'membership': membership.toSet().toList()..sort(),
    'threadCount': httpBoundaryBatchWidth,
  };

  Map<String, Object?> evidence() => {
    'cohort': id,
    'memberCount': membership.length,
    'memberArrivalOrder': membership,
    'releaseReason': released ? releaseReason : 'cohort-window',
    'note':
        'the product has no gate of its own: this block records the corpus '
        "replay listener's own hold decision",
  };
}

class _CohortArrival {
  const _CohortArrival({
    required this.cohortComplete,
    required this.releaseReason,
  });
  final bool cohortComplete;
  final String releaseReason;
}

/// The task-owned hold a held response waits on, with the abort its own write
/// measured.
class _HoldGate {
  final _entered = Completer<bool>();
  final abortObserved = Completer<bool>();
  final _peerClosed = Completer<Object>();
  final released = Completer<void>();

  /// Completes when the held request's peer closed the connection.
  Future<Object> get peerClosed => _peerClosed.future;

  /// Whether the peer had already closed before anything was written.
  bool get peerClosedObserved => _peerClosed.isCompleted;

  void notePeerClosed(Object error) {
    if (!_peerClosed.isCompleted) _peerClosed.complete(error);
  }

  /// When the cancellation was requested, so a later request of the same owner
  /// is a late request.
  int cancelNanos = 0;

  Future<bool> get entered => _entered.future;

  void enter(String selector) {
    if (!_entered.isCompleted) _entered.complete(true);
  }

  void release() {
    if (!_entered.isCompleted) _entered.complete(false);
    if (!released.isCompleted) released.complete();
  }

  void finish({required bool aborted}) {
    if (!abortObserved.isCompleted) abortObserved.complete(aborted);
    release();
  }
}

/// The task-owned failure endpoint: `127.0.0.1:0`, accepting and closing each
/// connection without an HTTP response. Only this listener may be reached.
class _FailEndpoint {
  _FailEndpoint._(this._server, this._port, this._onError);

  static Future<_FailEndpoint> start({
    required void Function(Object error) onError,
  }) async {
    final server = await HttpServer.bind('127.0.0.1', 0);
    final instance = _FailEndpoint._(server, server.port, onError);
    server.listen(instance._handle, onError: onError);
    return instance;
  }

  final HttpServer _server;
  final int _port;
  final void Function(Object error) _onError;

  final connections = <Map<String, Object?>>[];
  final errors = <String>[];
  bool armed = false;
  bool armedAtLeastOnce = false;
  int _armedAtNanos = 0;
  bool _closed = false;

  int get port => _port;
  bool get closed => _closed;

  void arm() {
    armed = true;
    armedAtLeastOnce = true;
    _armedAtNanos = _nowNanos();
  }

  void disarm() => armed = false;

  Future<void> _handle(HttpRequest request) async {
    final index = connections.length + 1;
    final record = <String, Object?>{
      'index': index,
      'method': request.method,
      'target': request.uri.hasQuery
          ? '${request.uri.path}?${request.uri.query}'
          : request.uri.path,
      'path': request.uri.path,
      'rawQuery': request.uri.query,
      'headers': _lowerHeaders(request.headers),
      'armed': armed,
      'classification': index == 1 && armedAtLeastOnce
          ? 'initial'
          : 'transport-reconnect',
      'requestObserved': true,
      'acceptedAtNanos': _nowNanos(),
      'terminal': 'accepted-and-closed-without-response',
      'closedAtNanos': _nowNanos(),
    };
    connections.add(record);
    if (!armed) {
      errors.add('an unarmed connection reached the failure endpoint');
    }
    try {
      final socket = await request.response.detachSocket(writeHeaders: false);
      socket.destroy();
    } on Object catch (error) {
      errors.add('$error');
      _onError(error);
    }
  }

  Map<String, Object?> receipt() => {
    'host': '127.0.0.1',
    'requestedPort': 0,
    'assignedPort': port,
    'armedAtLeastOnce': armedAtLeastOnce,
    'armedAtNanos': _armedAtNanos,
    'acceptedConnections': connections.length,
    'transportReconnects': connections
        .where(
          (connection) => connection['classification'] == 'transport-reconnect',
        )
        .length,
    'connections': connections,
    'errors': errors,
    'closed': _closed,
    'classification': {
      'first': 'initial',
      'subsequent': 'transport-reconnect',
      'statusRetryImpossible':
          'no response is ever written, so a source-status retry cannot occur',
    },
  };

  Future<void> close() async {
    await _server.close(force: true);
    _closed = true;
  }
}

String _headerCase(String name) => [
  for (final part in name.split('-'))
    part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}',
].join('-');

Map<String, Object?> _lowerHeaders(HttpHeaders headers) {
  final result = <String, Object?>{};
  headers.forEach((name, values) {
    result[name.toLowerCase()] = values.length == 1
        ? values.single
        : values.join(', ');
  });
  return result;
}
