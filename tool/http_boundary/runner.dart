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
    show InProcessSourceScriptRuntime, SourceScriptError;
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

/// The corpus versions this consumer accepts: the historical `14dd2494` v3 and the
/// selected-reference v4. The identity a comparison uses lives inside the file.
const httpBoundaryCorpusVersions = {3, 4};
const httpBoundaryFixtureId = 'HTTP-BOUNDARY-01';

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

/// The stage pagination tails' real configuration: `walkSourcePages` fetches the
/// declared next pages one at a time (`source_page_results.dart:21-27,161-165`).
const httpBoundarySerialWalkWidth = 1;

/// The frozen `BookSource.getBookType()` mapping at
/// `14dd24945b2914ce2708b8abaa4ee67ceef892af`
/// (`BookSourceExtensions.kt:107-113`): `bookSourceType` 1/2/3 answer
/// `BookType.audio` 32, `BookType.image` 64 and `text|webFile` 136; the default
/// and every other value answer `BookType.text` 8.
int httpBoundaryBookTypeOf(Object? bookSourceType) => switch (bookSourceType) {
  1 => 32,
  2 => 64,
  3 => 136,
  _ => 8,
};

/// The frozen `SearchBook`/`Book` carrier's source-derived fields, read from the
/// actual source object this run hands to the pipeline: `origin` is that
/// source's `bookSourceUrl`, `originName` its `bookSourceName`, and `type` the
/// frozen `getBookType()` of its `bookSourceType`. No value is read from a
/// golden capture and the book's own stored type is not mutated.
Map<String, Object?> httpBoundaryBookCarrierOf(Map<String, dynamic> source) => {
  'origin': '${source['bookSourceUrl']}',
  'originName': '${source['bookSourceName']}',
  'type': httpBoundaryBookTypeOf(source['bookSourceType']),
};

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

/// The helper actions the two lanes actually implement. `scriptProbe` is one
/// fixture-authored script through the real evaluation binding; its result is
/// the script's own JSON projection, never a relabelled arity or a converted
/// diagnostic string.
const httpBoundaryHelperActions = {
  'ajax',
  'ajaxList',
  'ajaxAll',
  'connectHeader',
  'connectSource',
  'headerMap',
  'scriptProbe',
};

/// One small shared rule for the script-probe portable projection. The runner,
/// the product record gate and the canonical comparer use this exact function,
/// so an empty object, a missing member or a wrong type is refused at every
/// boundary; no frozen typeof/equality answer is prescribed.
Map<String, Object?> validateHttpBoundaryScriptProbeProjection(
  Object? raw, {
  required String where,
}) {
  if (raw is! Map) {
    throw FormatException('$where portable projection is not an object');
  }
  final projection = raw.cast<String, Object?>();
  for (final name in const [
    'getDot',
    'getBracket',
    'keySetDot',
    'keySetBracket',
    'lookup',
    'enumeration',
  ]) {
    if (!projection.containsKey(name)) {
      throw FormatException('$where portable projection has no $name');
    }
  }
  void access(String name) {
    final value = projection[name];
    if (value is! Map) {
      throw FormatException('$where.$name is not an object');
    }
    final member = value.cast<String, Object?>();
    final type = member['type'];
    if (type is! String || type.isEmpty) {
      throw FormatException('$where.$name.type is not a non-empty string');
    }
    if (!member.containsKey('text')) {
      throw FormatException('$where.$name.text is absent');
    }
    final text = member['text'];
    if (type == 'function') {
      if (text != null) {
        throw FormatException('$where.$name.text is not null for a function');
      }
    } else if (text is! String) {
      throw FormatException('$where.$name.text is not a string');
    }
  }

  access('getDot');
  access('getBracket');
  access('keySetDot');
  access('keySetBracket');
  final lookup = projection['lookup'];
  if (lookup is! Map) {
    throw FormatException('$where.lookup is not an object');
  }
  final lookupMember = lookup.cast<String, Object?>();
  final lookupReturned = lookupMember['returned'];
  if (lookupReturned is! bool) {
    throw FormatException('$where.lookup.returned is not a boolean');
  }
  if (lookupReturned) {
    if (lookupMember['type'] is! String ||
        (lookupMember['type'] as String).isEmpty ||
        lookupMember['strictLiteral'] is! bool ||
        lookupMember['looseLiteral'] is! bool ||
        lookupMember['text'] is! String) {
      throw FormatException('$where.lookup returned result is not typed');
    }
  } else {
    if (lookupMember['errorName'] != 'TypeError') {
      throw FormatException(
        '$where.lookup refusal is not the expected TypeError',
      );
    }
    final getDot = projection['getDot'] as Map;
    final getType = getDot['type'];
    if (getType == 'function' || getType == 'undefined') {
      throw FormatException(
        '$where.lookup refusal has no noncallable own-data context',
      );
    }
    if (getDot['text'] is! String) {
      throw FormatException('$where.lookup refusal has no data text');
    }
  }
  final enumeration = projection['enumeration'];
  if (enumeration is! Map) {
    throw FormatException('$where.enumeration is not an object');
  }
  final enumerationMember = enumeration.cast<String, Object?>();
  final enumerationReturned = enumerationMember['returned'];
  if (enumerationReturned is! bool) {
    throw FormatException('$where.enumeration.returned is not a boolean');
  }
  if (enumerationReturned) {
    final keys = enumerationMember['keys'];
    if (keys is! List || keys.any((key) => key is! String)) {
      throw FormatException('$where.enumeration.keys is not a string list');
    }
  } else {
    if (enumerationMember['errorName'] != 'TypeError') {
      throw FormatException(
        '$where.enumeration refusal is not the expected TypeError',
      );
    }
    final keySetDot = projection['keySetDot'] as Map;
    final keySetType = keySetDot['type'];
    if (keySetType == 'function' || keySetType == 'undefined') {
      throw FormatException(
        '$where.enumeration refusal has no noncallable own-data context',
      );
    }
    if (keySetDot['text'] is! String) {
      throw FormatException('$where.enumeration refusal has no data text');
    }
  }
  return projection;
}

/// The bounded probe envelope: the portable projection is the compared result;
/// the caught diagnostics are real provenance and are never compared.
Map<String, Object?> validateHttpBoundaryScriptProbeEnvelope(
  Object? raw, {
  required String where,
}) {
  if (raw is! Map) {
    throw FormatException('$where script probe envelope is not an object');
  }
  final envelope = raw.cast<String, Object?>();
  if (!envelope.containsKey('portable') ||
      !envelope.containsKey('diagnostics')) {
    throw FormatException(
      '$where script probe envelope has no portable/diagnostics',
    );
  }
  final portable = validateHttpBoundaryScriptProbeProjection(
    envelope['portable'],
    where: '$where.portable',
  );
  final diagnostics = envelope['diagnostics'];
  if (diagnostics is! Map) {
    throw FormatException('$where diagnostics is not an object');
  }
  final diagnosticMap = diagnostics.cast<String, Object?>();
  for (final name in const ['lookup', 'enumeration']) {
    final entry = diagnosticMap[name];
    if (entry is! Map) {
      throw FormatException('$where.diagnostics.$name is not an object');
    }
    final member = entry.cast<String, Object?>();
    final caught = member['caught'];
    if (caught is! bool) {
      throw FormatException('$where.diagnostics.$name.caught is not a boolean');
    }
    if (caught) {
      if (member['name'] is! String ||
          member['message'] is! String ||
          member['text'] is! String ||
          !member.containsKey('stack') ||
          (member['stack'] != null && member['stack'] is! String)) {
        throw FormatException(
          '$where.diagnostics.$name caught fields are not typed',
        );
      }
    }
    final portableEntry = (portable[name] as Map).cast<String, Object?>();
    final returned = portableEntry['returned'] == true;
    if (returned) {
      if (caught) {
        throw FormatException(
          '$where.diagnostics.$name caught contradicts a returned value',
        );
      }
    } else {
      if (!caught) {
        throw FormatException(
          '$where.diagnostics.$name has no caught provenance for a refusal',
        );
      }
      if (member['name'] != 'TypeError' ||
          portableEntry['errorName'] != 'TypeError') {
        throw FormatException(
          '$where.diagnostics.$name is not the expected TypeError',
        );
      }
    }
  }
  return {'portable': portable, 'diagnostics': diagnosticMap};
}

void _validateHelperAction(Map<String, dynamic> step, String id) {
  final action = _text(step['action'], 'step $id action');
  if (!httpBoundaryHelperActions.contains(action)) {
    throw FormatException('step $id has unknown helper action $action');
  }
  if (action == 'scriptProbe') {
    _text(step['script'], 'step $id script');
    if (step['scripts'] != null) {
      throw FormatException('step $id script probe declares headerMap scripts');
    }
    final declared = httpBoundaryDeclaredRequests(step);
    if (declared.ordered.isNotEmpty || declared.members.isNotEmpty) {
      throw FormatException('step $id script probe declares requests');
    }
  }
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
  if (!httpBoundaryCorpusVersions.contains(corpus['corpusVersion'])) {
    throw FormatException(
      'the corpus corpusVersion is not one of $httpBoundaryCorpusVersions',
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
  if (sources.length != 16) {
    throw const FormatException('the corpus declares sixteen sources');
  }
  final sourceIds = <String>{};
  for (final raw in sources) {
    final entry = _object(raw, 'source');
    final id = _text(entry['id'], 'source id');
    if (!sourceIds.add(id)) {
      throw FormatException('source $id is declared twice');
    }
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
  for (final id in const ['H1', 'H2', 'H3', 'S', 'R', 'F']) {
    if (!sourceIds.contains(id)) {
      throw FormatException('the corpus dropped the v2 source $id');
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
    if (kind == 'helper') {
      _validateHelperAction(step, id);
    }
    final carrier = step['carrier'];
    if (carrier != null) {
      if (kind != 'stage' || '${step['stage']}' != 'details') {
        throw FormatException(
          'step $id declares a carrier outside a details stage',
        );
      }
      if (carrier != 'same' && carrier != 'fresh') {
        throw FormatException('step $id declares unknown carrier $carrier');
      }
    }
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
      '<report.json> [--expected-corpus-sha256=<sha256>] [--corpus=<path>]',
    );
    exitCode = 64;
    return;
  }
  final libraryPath = args[0];
  final root = Directory(args[1]);
  final reportPath = args[2];
  String? expectedCorpusSha256;
  var corpusPath = httpBoundaryCorpusPath;
  for (final arg in args.sublist(3)) {
    const prefix = '--expected-corpus-sha256=';
    const corpusPrefix = '--corpus=';
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
    if (arg.startsWith(corpusPrefix)) {
      final value = arg.substring(corpusPrefix.length).trim();
      if (value.isEmpty) {
        stderr.writeln('--corpus is empty');
        exitCode = 64;
        return;
      }
      corpusPath = value;
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
    final corpusFile = File(corpusPath);
    final corpus = loadHttpBoundaryCorpus(corpusPath);
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
        'corpusPath': corpusPath,
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

  /// The cancellation row's owned worker (the search future's settlement). It is
  /// kept so the teardown can join it before the database and the native runtime
  /// are touched; a merely local future was the review finding.
  Future<void>? _ownedCancelWorker;

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
      // The concurrency configuration of the family that actually runs the
      // cohort: the helper batch's `ajaxAll` default, or the serial page walk
      // that the stage tails really execute. A peak is not a configuration.
      final cohortThreadCounts = <String, int>{};
      final cohortThreadSources = <String, String>{};
      for (final step in httpBoundarySteps(corpus)) {
        final declared = httpBoundaryDeclaredRequests(step);
        final cohort = declared.cohort;
        if (cohort == null) continue;
        if ('${step['family']}' == 'helper') {
          cohortThreadCounts[cohort] = httpBoundaryBatchWidth;
          cohortThreadSources[cohort] =
              'SourceHostDispatcher.ajaxAll concurrency default '
              '(lib/source/source_host_dispatcher.dart:186)';
        } else {
          cohortThreadCounts[cohort] = httpBoundarySerialWalkWidth;
          cohortThreadSources[cohort] =
              'walkSourcePages serial page walk '
              '(lib/source/source_page_results.dart:21-27,161-165)';
        }
      }
      replay = await _ReplayServer.start(
        origin: origin,
        responses: httpBoundaryResponses(corpus),
        owners: httpBoundaryResponseOwners(corpus),
        cohortSizes: cohortSizes,
        cohortTimeouts: cohortTimeouts,
        cohortThreadCounts: cohortThreadCounts,
        cohortThreadSources: cohortThreadSources,
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
        'initialSnapshot': rateLimiter.recordOf(sourceUrl('R')) == null
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
    // An owned worker may still be writing: settle it before the database is
    // queried or closed and before the native runtime is disposed. A worker that
    // cannot settle keeps the owned residue instead of a clean exit.
    final owned = _ownedCancelWorker;
    // One teardown composition for every caller: the owned worker settles first,
    // then the snapshot, the database close and the native disposal are each
    // attempted independently, and the collected evidence is published whatever
    // happens here.
    final teardown = await settleOwnedTeardown(
      workers: [?owned],
      deadline: const Duration(seconds: 20),
      snapshotDatabase: () async {
        if (store != null) finalCounts = await _databaseCounts();
      },
      closeDatabase: () async {
        await workspace?.close();
        databaseClosed = workspace != null;
      },
      disposeNative: () async {
        await InProcessSourceScriptRuntime.dispose();
        NativeLibrary.dispose();
        libraryDisposed = true;
      },
    );
    report['ownedTeardown'] = teardown.toJson();
    final ownedWorkSettled = teardown.workerSettled;
    if (!ownedWorkSettled) {
      failure ??= StateError(
        'an owned cancellation worker did not settle before teardown; the '
        'owned residue is retained',
      );
      removalSkipped =
          'an owned worker did not settle; the owned root and preferences are '
          'retained for the controller';
    } else if (teardown.errors.isNotEmpty) {
      final first = teardown.errors.first;
      failure ??= StateError(
        'cleanup did not complete: ${first['step']} failed with '
        '${first['errorType']}: ${first['error']}',
      );
      removalSkipped =
          'cleanup did not complete (${teardown.errors.map((error) => error['step']).join(', ')}); '
          'the owned root and preferences are retained';
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
    } else if (root.existsSync() && removalSkipped.isEmpty) {
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
    final id = '${step['id']}';
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
      case 'scriptProbe':
        final result = await _evaluate(
          sourceId,
          _text(step['script'], 'script'),
        );
        final text = result is String ? result : '$result';
        final Map<String, Object?> envelope;
        try {
          envelope = validateHttpBoundaryScriptProbeEnvelope(
            jsonDecode(text),
            where: 'helper $id',
          );
        } on FormatException catch (error) {
          throw HttpBoundaryIncomplete(
            'the script probe did not answer a valid envelope: $error',
          );
        }
        value['result'] = envelope['portable'];
        (observation['evidence'] as Map)['scriptProbe'] = {
          'diagnostics': envelope['diagnostics'],
        };
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
      } on TimeoutException catch (error) {
        // A step/evaluation deadline is not a script outcome: the row is an
        // incomplete measurement, never three `returned:false` arities in an ok
        // row.
        (observation['evidence'] as Map)['arityProvenance'] = {
          ...provenance,
          arity: {
            'outcome': 'deadline',
            'errorType': '${error.runtimeType}',
            'error': '$error',
          },
        };
        observation['outcome'] = 'incomplete';
        throw HttpBoundaryIncomplete(
          'the $arity header-map evaluation hit its deadline: $error',
        );
      } on SourceScriptError catch (error) {
        // The engine reports its own bounded-deadline failure as a typed
        // `SourceScriptError('timeout')`, which is the same measurement deadline
        // as a wall-clock TimeoutException. Any other category stays the ordinary
        // measured binding refusal below.
        if (error.category == 'timeout') {
          (observation['evidence'] as Map)['arityProvenance'] = {
            ...provenance,
            arity: {
              'outcome': 'deadline',
              'errorType': '${error.runtimeType}',
              'error': '$error',
              'engineCategory': error.category,
            },
          };
          observation['outcome'] = 'incomplete';
          throw HttpBoundaryIncomplete(
            'the $arity header-map evaluation hit the engine deadline: $error',
          );
        }
        arities[arity] = {'returned': false};
        provenance[arity] = {
          'outcome': 'threw',
          'errorType': '${error.runtimeType}',
          'error': '$error',
        };
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
  /// The rate record fields this corpus compares. The historical corpus declares
  /// none, so its three original fields keep their meaning; the selected
  /// reference carries no `isConcurrent` at all, so the selected corpus declares
  /// only what it really has and the product's internal mode stays provenance.
  List<String> _rateRecordFields(Map<String, dynamic> rate) {
    final declared = rate['recordFields'];
    if (declared == null) {
      return const ['isConcurrent', 'time', 'frequency'];
    }
    final fields = [
      for (final raw in _array(declared, 'rate.recordFields')) '$raw',
    ];
    if (fields.isEmpty) {
      throw const FormatException('rate.recordFields declares no field');
    }
    const known = {'isConcurrent', 'time', 'frequency'};
    for (final field in fields) {
      if (!known.contains(field)) {
        throw FormatException(
          'rate.recordFields declares the unknown field $field',
        );
      }
    }
    return fields;
  }

  Map<String, Object?>? _rateRecord(
    SourceRateRecord? record,
    List<String> fields,
  ) => record == null
      ? null
      : {
          for (final field in fields)
            field: switch (field) {
              'isConcurrent' => record.isConcurrent,
              'time' => record.time,
              'frequency' => record.frequency,
              _ => throw FormatException('unknown rate record field $field'),
            },
        };

  /// The window relation a rate row declares. The historical corpus declares no
  /// schedule, so its three original row meanings are preserved; the selected
  /// corpus declares each row because the selected reference rolls the window on
  /// every start instead of admitting an extra same-window start.
  ({String window, int frequency}) _rateScheduleRow(
    Map<String, dynamic> rate,
    int index,
  ) {
    final declared = rate['schedule'];
    if (declared == null) {
      return switch (index) {
        1 => (window: 'opens', frequency: 1),
        2 => (window: 'same', frequency: 2),
        3 => (window: 'rolls', frequency: 1),
        _ => throw const HttpBoundaryIncomplete(
          'the corpus declares three rate rows',
        ),
      };
    }
    for (final raw in _array(declared, 'rate.schedule')) {
      final row = _object(raw, 'rate.schedule row');
      if (_integer(row['index'], 'rate.schedule index') != index) continue;
      final window = '${row['window']}';
      if (window != 'opens' && window != 'same' && window != 'rolls') {
        throw FormatException(
          'rate.schedule declares the unknown window $window',
        );
      }
      return (
        window: window,
        frequency: _integer(row['frequency'], 'frequency'),
      );
    }
    throw FormatException('rate.schedule declares no row for index $index');
  }

  Future<void> _runRate(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final rate = _object(corpus['rate'], 'rate');
    final fields = _rateRecordFields(rate);
    final sourceId = '${step['source']}';
    final sourceKey = sourceUrl(sourceId);
    final window = _integer(rate['windowMillis'], 'rate.windowMillis');
    final index = _integer(step['index'], 'rate index');
    final schedule = _rateScheduleRow(rate, index);
    final before = _rateRecord(rateLimiter.recordOf(sourceKey), fields);
    if (schedule.window == 'opens' && before != null) {
      throw const HttpBoundaryIncomplete(
        'the rate record existed before the first rate row',
      );
    }
    final callStart = _nowMillis();
    final watch = Stopwatch()..start();
    final result = await _evaluate(sourceId, '${step['script']}');
    watch.stop();
    final callFinish = _nowMillis();
    final after = _rateRecord(rateLimiter.recordOf(sourceKey), fields);
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
      // The product's own reading of the declared form stays provenance.
      'productMode': rateLimiter.recordOf(sourceKey)?.isConcurrent,
    };
    switch (schedule.window) {
      case 'opens':
        _rateWindowStart = afterTime;
        evidence['windowStartMillis'] = _rateWindowStart;
        value['scheduleComplete'] = after?['frequency'] == schedule.frequency;
        value['scheduleReason'] = value['scheduleComplete'] == true
            ? null
            : 'incomplete-schedule';
      case 'same':
        final start = _rateWindowStart;
        final sameWindow = start != null && afterTime == start;
        value['sameWindowAsPrevious'] = sameWindow;
        final complete =
            sameWindow &&
            callFinish - start < window &&
            after?['frequency'] == schedule.frequency;
        value['scheduleComplete'] = complete;
        value['scheduleReason'] = complete ? null : 'incomplete-schedule';
        evidence['windowStartMillis'] = start;
      case 'rolls':
        final start = _rateWindowStart;
        final advanced = start == null || afterTime == null
            ? null
            : afterTime - start;
        value['sameWindowAsPrevious'] = advanced == 0;
        final complete =
            advanced != null &&
            advanced >= window &&
            after?['frequency'] == schedule.frequency;
        value['scheduleComplete'] = complete;
        value['scheduleReason'] = complete ? null : 'incomplete-schedule';
        evidence['windowAdvanceMillis'] = advanced;
      default:
        throw FormatException('unknown rate window ${schedule.window}');
    }
    observation['value'] = value;
    observation['evidence'] = evidence;
    // Every record this call creates or resets belongs to its own operation
    // interval; a same-window admission keeps the shared window start.
    final createdHere =
        schedule.window == 'opens' || value['sameWindowAsPrevious'] == false;
    final recordTime = after?['time'];
    if (createdHere &&
        recordTime is int &&
        (recordTime < callStart || recordTime > callFinish)) {
      observation['outcome'] = 'incomplete';
      throw HttpBoundaryIncomplete(
        'the rate record of row $index lies outside its own operation interval',
      );
    }
    if (value['scheduleComplete'] != true) {
      // An incomplete schedule is an incomplete measurement, never an ok row.
      observation['outcome'] = 'incomplete';
      throw const HttpBoundaryIncomplete(
        'the rate schedule did not complete inside its declared window',
      );
    }
    observation['outcome'] = 'ok';
    observation['category'] = null;
  }

  // --- stage rows ------------------------------------------------------------

  Future<void> _runStage(
    Map<String, dynamic> step,
    Map<String, Object?> observation,
  ) async {
    final sourceId = '${step['source']}';
    final carrier = step['carrier'];
    final fresh = '${carrier ?? ''}' == 'fresh';
    final cached = _pipelines[sourceId];
    late final BookSourcePipeline pipeline;
    if (carrier == null) {
      pipeline = _pipelineOf(sourceId);
    } else {
      if (cached == null) {
        throw const HttpBoundaryIncomplete(
          'the carrier has no preceding search pipeline',
        );
      }
      pipeline = fresh
          ? openBookSourcePipeline(
              sourceObject(sourceId),
              HttpSourceTransport(),
              hostState: hostState,
              androidId: androidId,
            )
          : cached;
      if (fresh) {
        if (identical(pipeline, cached) ||
            identical(pipeline.transport, cached.transport)) {
          throw const HttpBoundaryIncomplete(
            'the fresh carrier did not create a distinct pipeline and '
            'transport',
          );
        }
      } else if (!identical(pipeline, cached)) {
        throw const HttpBoundaryIncomplete(
          'the same carrier did not reuse the search pipeline',
        );
      }
      (observation['evidence'] as Map)['carrier'] = {
        'declared': '$carrier',
        'actual': fresh ? 'fresh' : 'same',
        'pipelineIdentity': identityHashCode(pipeline),
        'cachedPipelineIdentity': identityHashCode(cached),
        'reusedPipeline': identical(pipeline, cached),
        'transportIdentity': identityHashCode(pipeline.transport),
        'cachedTransportIdentity': identityHashCode(cached.transport),
        'distinctTransport': !identical(pipeline.transport, cached.transport),
        'sourceObjectIdentity': identityHashCode(sourceObject(sourceId)),
        'cachedSourceObjectIdentity': identityHashCode(sourceObject(sourceId)),
        'hostStateIdentity': identityHashCode(hostState),
        'sourceKey': sourceUrl(sourceId),
      };
    }
    final value = await _stageValue(pipeline, step, observation);
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
          final carrier = httpBoundaryBookCarrierOf(sourceObject(sourceId));
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
              'origin': carrier['origin'],
              'originName': carrier['originName'],
              'coverUrl': hit.cover.isEmpty ? null : hit.cover,
              'intro': hit.intro,
              'wordCount': hit.wordCount,
              'latestChapterTitle': hit.lastChapter,
              'type': carrier['type'],
            });
          }
          value['results'] = results;
          (observation['evidence']
              as Map)['bookCarrier'] = _bookCarrierProvenance(
            sourceId,
            published: const ['origin', 'originName', 'type'],
          );
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
          value['bookUrl'] = book.identityAddress;
          value['name'] = book.title;
          value['author'] = book.author;
          value['intro'] = book.intro;
          value['coverUrl'] = book.cover.isEmpty ? null : book.cover;
          value['wordCount'] = book.wordCount;
          value['latestChapterTitle'] = book.lastChapter;
          value['tocUrl'] = info.tocUrl;
          // The frozen details row publishes only `origin`; the search result
          // carrier has the three portable fields.
          value['origin'] = httpBoundaryBookCarrierOf(
            sourceObject(sourceId),
          )['origin'];
          (observation['evidence'] as Map)['bookCarrier'] =
              _bookCarrierProvenance(sourceId, published: const ['origin']);
          if (step['carrier'] != null) {
            // The paired same/fresh rows must consume the identical stored
            // search hit: the fresh pipeline is different, the hit is not
            // re-searched and its raw absolute address/tail is unchanged.
            final stored = _hits[bookId]!;
            if (!identical(hit, stored)) {
              throw HttpBoundaryIncomplete(
                'details $id did not consume the stored hit $bookId',
              );
            }
            final String counter;
            try {
              final raw = await _evaluate(
                sourceId,
                "String(source.get('oRuns'))",
              );
              counter = '$raw';
            } on Object catch (error) {
              throw HttpBoundaryIncomplete(
                'the O-source counter read is unresolved: $error',
              );
            }
            final declaredBook = _bookOf(bookId);
            if (hit.identityAddress != '${declaredBook['bookUrl']}') {
              throw HttpBoundaryIncomplete(
                'details $id retained ${hit.identityAddress}, the corpus '
                'declares ${declaredBook['bookUrl']}',
              );
            }
            value['counterAfter'] = counter;
            (observation['evidence'] as Map)['hitReference'] = {
              'identity': identityHashCode(hit),
              'storedIdentity': identityHashCode(stored),
              'sameObject': identical(hit, stored),
              'bookId': bookId,
              'rawAddress': hit.identityAddress,
              'preOptionUrl': '${hit.preOptionUrl}',
              'sourceKey': sourceUrl(sourceId),
              'counterAfter': counter,
            };
          }
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

  /// The actual source context behind the published carrier fields: the object
  /// this run handed to the pipeline, the field each value came from, and which
  /// fields this stage publishes. It is evidence, never a compared value.
  Map<String, Object?> _bookCarrierProvenance(
    String sourceId, {
    required List<String> published,
  }) {
    final source = sourceObject(sourceId);
    return {
      'source': sourceId,
      'bookSourceUrl': '${source['bookSourceUrl']}',
      'bookSourceName': '${source['bookSourceName']}',
      'bookSourceType': source['bookSourceType'],
      'published': published,
      'derivation': {
        'origin': 'source.bookSourceUrl',
        'originName': 'source.bookSourceName',
        'type':
            'getBookType(source.bookSourceType) at frozen '
            '14dd24945b2914ce2708b8abaa4ee67ceef892af, '
            'BookSourceExtensions.kt:107-113',
      },
    };
  }

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
  /// The category of the *observed* diagnostic: an expectation never relabels a
  /// real timeout or connection failure, and the corpus' declared category is
  /// compared after this derivation, not instead of it.
  String _categoryOf(
    SourceStageDiagnostic diagnostic,
    Map<String, dynamic> step,
  ) {
    if (diagnostic.stage == BookSourceStage.tableOfContents &&
        const {
          SourceStageFailureKind.emptyResponse,
          SourceStageFailureKind.extractionFailed,
        }.contains(diagnostic.kind)) {
      return 'empty-required-result';
    }
    return switch (diagnostic.kind) {
      SourceStageFailureKind.connection => 'network-failure',
      SourceStageFailureKind.timeout => 'timeout',
      SourceStageFailureKind.emptyResponse ||
      SourceStageFailureKind.extractionFailed => 'empty-required-result',
    };
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
    // The owned worker is tracked beyond this row: a timeout here must not let
    // the teardown close the database or dispose the runtime under it.
    _ownedCancelWorker = settled;
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
/// The frozen collector's status reasons (`HttpBoundaryOracle.java:4994+`), used
/// for the controlled responses this listener writes.
String _statusReason(int status) => switch (status) {
  200 => 'OK',
  404 => 'Not Found',
  502 => 'Bad Gateway',
  503 => 'Service Unavailable',
  _ => 'Status',
};

/// One request as the socket actually carried it: the literal request line and
/// header lines are recorded before any semantic parsing, and the body is the
/// exact number of bytes the framing declared.
class _RawRequest {
  _RawRequest({
    required this.method,
    required this.rawTarget,
    required this.version,
    required this.headerLines,
    required this.headers,
    required this.bodyBytes,
    required this.wantsClose,
  });

  final String method;
  final String rawTarget;
  final String version;
  final List<String> headerLines;
  final Map<String, String> headers;
  final List<int> bodyBytes;
  final bool wantsClose;

  String get path {
    final boundary = rawTarget.indexOf('?');
    return boundary < 0 ? rawTarget : rawTarget.substring(0, boundary);
  }

  String get rawQuery {
    final boundary = rawTarget.indexOf('?');
    return boundary < 0 ? '' : rawTarget.substring(boundary + 1);
  }
}

/// The corpus' one replay listener.
///
/// It reads the request itself on an owned [ServerSocket] instead of letting
/// `HttpServer` parse it, because the compared facts are the bytes on the wire:
/// the literal request target keeps its percent-encoding, a GET body is read when
/// its framing declares one, and header lines keep their order and case. A
/// request is matched by literal method + raw path + raw query. The declared
/// concurrent members of one cohort are held until the cohort is complete or its
/// own window expires, and every row keeps what actually happened.
class _ReplayServer {
  _ReplayServer._(
    this._server,
    this.origin,
    this._responses,
    this._owners,
    this._cohortSizes,
    this._cohortTimeouts,
    this._cohortThreadCounts,
    this._cohortThreadSources,
    this._onServerError,
  );

  static Future<_ReplayServer> start({
    required Uri origin,
    required List<Map<String, dynamic>> responses,
    required Map<String, ({String step, String family, String? cohort})> owners,
    required Map<String, int> cohortSizes,
    required Map<String, int> cohortTimeouts,
    Map<String, int> cohortThreadCounts = const {},
    Map<String, String> cohortThreadSources = const {},
    required void Function(Object error) onServerError,
  }) async {
    final ServerSocket server;
    try {
      server = await ServerSocket.bind(origin.host, origin.port);
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
      cohortThreadCounts,
      cohortThreadSources,
      onServerError,
    );
    instance._accept();
    return instance;
  }

  final ServerSocket _server;
  final Uri origin;
  final List<Map<String, dynamic>> _responses;
  final Map<String, ({String step, String family, String? cohort})> _owners;
  final Map<String, int> _cohortSizes;
  final Map<String, int> _cohortTimeouts;
  final Map<String, int> _cohortThreadCounts;
  final Map<String, String> _cohortThreadSources;
  final void Function(Object error) _onServerError;

  final requests = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final stageTrace = <Map<String, Object?>>[];
  final _gates = <String, _CohortGate>{};
  final _attempts = <String, int>{};
  final _lastTerminal = <String, String>{};
  final _connections = <_ReplayConnection>{};
  final _handlers = <Future<void>>{};
  int _nextSendSequence = 1;
  final hold = _HoldGate();

  /// The corpus step currently running, recorded with every request as
  /// provenance only.
  String stage = '';

  bool _closed = false;
  bool get closed => _closed;

  int get port => _server.port;

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

  void _accept() {
    _server.listen((socket) {
      final connection = _ReplayConnection(this, socket);
      _connections.add(connection);
      final handler = connection.run().whenComplete(() {
        _connections.remove(connection);
        connection.dispose();
      });
      _handlers.add(handler);
      handler.whenComplete(() => _handlers.remove(handler));
    }, onError: _onServerError);
  }

  /// The named refusal of one owned connection's framing: a recorded server error
  /// makes the measurement non-promotable instead of guessing a body.
  void refuseFraming(_ReplayConnection connection, String reason) {
    _onServerError('replay connection refused: $reason');
    connection.closeSocket();
  }

  Future<void> _handleRequest(
    _RawRequest request,
    _ReplayConnection connection,
  ) async {
    final receivedAt = _nowNanos();
    final bodyBytes = request.bodyBytes;
    final body = utf8.decode(bodyBytes, allowMalformed: false);
    final headers = <String, Object?>{
      for (final e in request.headers.entries) e.key: e.value,
    };
    final declared = _match(request.method, request.path, request.rawQuery);
    final declaredId = declared == null ? null : '${declared['id']}';
    final owner = declaredId == null ? null : _owners[declaredId];
    final selector = '${request.method} ${request.path}?${request.rawQuery}';
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
      'target': request.rawTarget,
      'path': request.path,
      'rawQuery': request.rawQuery,
      'query': _decodedQuery(request.rawQuery),
      'headers': headers,
      'headerLines': request.headerLines,
      // The bytes the framing declared, never a decode/re-encode of them.
      'body': body,
      'bodyLength': bodyBytes.length,
      'bodySha256': sha256Bytes(bodyBytes),
      'receivedAtNanos': receivedAt,
      // Unsent facts: nothing has been written yet, so a peer abort before the
      // first response byte can never report a send or a completion.
      'respondedAtNanos': 0,
      'sentAtNanos': 0,
      'sendSequence': 0,
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
      await _send(
        connection,
        record,
        status: 404,
        headers: const {'Content-Type': 'text/plain'},
        body: utf8.encode('undeclared replay request'),
      );
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
          _cohortThreadCounts[cohort] ?? httpBoundaryBatchWidth,
          _cohortThreadSources[cohort] ?? 'unrecorded configuration',
        ),
      );
      final arrival = await gate.arrive(selector);
      record['cohortComplete'] = arrival.cohortComplete;
      record['releaseReason'] = arrival.releaseReason;
    }
    if (declared['hold'] == true) {
      await _handleHeldRequest(connection, record, declared, selector);
      gate?.finish();
      return;
    }
    final status = _integer(declared['status'], 'status');
    final declaredHeaders =
        (declared['headers'] as Map?)?.cast<String, dynamic>() ?? const {};
    final wrote = await _send(
      connection,
      record,
      status: status,
      headers: {
        for (final entry in declaredHeaders.entries)
          if (!const {
            'content-length',
            'transfer-encoding',
            'connection',
          }.contains(entry.key.toLowerCase()))
            entry.key: '${entry.value}',
      },
      body: utf8.encode('${declared['body'] ?? ''}'),
    );
    if (wrote) {
      record['status'] = status;
      record['terminal'] = 'responded';
      record['outcome'] = 'responded';
      _lastTerminal[selector] = 'responded';
    }
    gate?.finish();
  }

  /// One held response: nothing is written until the hold is released, and a
  /// peer that closed first keeps the row unsent with the abort terminal.
  Future<void> _handleHeldRequest(
    _ReplayConnection connection,
    Map<String, Object?> record,
    Map<String, dynamic> declared,
    String selector,
  ) async {
    final status = _integer(declared['status'], 'status');
    hold.enter(selector, connection);
    await hold.released.future;
    if (hold.peerClosedObserved) {
      record['terminal'] = 'client-aborted';
      record['outcome'] = 'client-aborted';
      _lastTerminal[selector] = 'client-aborted';
      hold.finish(aborted: true);
      connection.closeSocket();
      return;
    }
    final wrote = await _send(
      connection,
      record,
      status: status,
      headers: const {'Content-Type': 'text/plain'},
      body: utf8.encode('${declared['body'] ?? ''}'),
      onWriteFailed: (error) {
        record['abortError'] = '$error';
        hold.notePeerClosed(error);
        hold.finish(aborted: true);
        _lastTerminal[selector] = 'client-aborted';
      },
    );
    if (wrote) {
      record['status'] = status;
      record['terminal'] = 'responded';
      record['outcome'] = 'responded';
      _lastTerminal[selector] = 'responded';
      hold.finish(aborted: false);
    }
  }

  /// Writes one declared response with real HTTP/1.1 framing and records the send
  /// facts only around the actual write and flush.
  Future<bool> _send(
    _ReplayConnection connection,
    Map<String, Object?> record, {
    required int status,
    required Map<String, String> headers,
    required List<int> body,
    void Function(Object error)? onWriteFailed,
  }) async {
    // The frozen controlled-response recipe (`HttpBoundaryOracle.java:4557-4584`):
    // the declared status with its standard reason, the declared headers, the
    // actual body length and the keep-alive marker.
    final head = StringBuffer('HTTP/1.1 $status ${_statusReason(status)}\r\n');
    for (final entry in headers.entries) {
      head.write('${entry.key}: ${entry.value}\r\n');
    }
    head.write('Content-Length: ${body.length}\r\n');
    head.write('Connection: keep-alive\r\n\r\n');
    record['sentAtNanos'] = _nowNanos();
    record['sendSequence'] = _nextSendSequence++;
    try {
      connection.socket.add(ascii.encode(head.toString()));
      connection.socket.add(body);
      await connection.socket.flush();
      record['respondedAtNanos'] = _nowNanos();
      return true;
    } on Object catch (error) {
      record['terminal'] = 'write-failed';
      record['outcome'] = 'write-failed';
      record['sentAtNanos'] = 0;
      record['respondedAtNanos'] = 0;
      _lastTerminal['${record['selector']}'] = 'write-failed';
      _onServerError(error);
      onWriteFailed?.call(error);
      connection.closeSocket();
      return false;
    }
  }

  Map<String, Object?> _decodedQuery(String rawQuery) {
    if (rawQuery.isEmpty) return const <String, Object?>{};
    try {
      return Uri.splitQueryString(rawQuery);
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  /// The declared response for one request: literal method, path and raw query
  /// bytes. A semantically equivalent but differently encoded target is a
  /// different request.
  Map<String, dynamic>? _match(String method, String path, String rawQuery) {
    for (final response in _responses) {
      if (response['method'] != method) continue;
      if (response['path'] != path) continue;
      if ('${response['rawQuery'] ?? ''}' != rawQuery) continue;
      return response;
    }
    return null;
  }

  Future<void> close() async {
    // Stop admission, free every gate so an idle reader wakes, close the
    // listener, and settle the owned handlers instead of only forgetting them.
    releaseAllGates();
    await _server.close();
    final handlers = _handlers.toList();
    for (final connection in _connections.toList()) {
      connection.closeSocket();
    }
    if (handlers.isNotEmpty) {
      try {
        await Future.wait(handlers).timeout(const Duration(seconds: 5));
      } on TimeoutException {
        _onServerError('an owned replay handler did not settle on close');
      }
    }
    _connections.clear();
    _handlers.clear();
    _closed = true;
  }
}

/// One owned connection: a single stream subscription over the socket, the bytes
/// it has not consumed yet, and the sequential keep-alive request loop.
class _ReplayConnection {
  _ReplayConnection(this.server, this.socket);

  final _ReplayServer server;
  final Socket socket;

  static const _maxRequestBytes = 1024 * 1024;

  final _buffered = <int>[];
  StreamSubscription<List<int>>? _subscription;
  Completer<void>? _more;
  bool _peerClosed = false;
  bool _disposed = false;
  Object? _streamError;
  bool wantsClose = false;

  Future<void> run() async {
    _subscription = socket.listen(
      (data) {
        _buffered.addAll(data);
        _wake();
      },
      onDone: () {
        _peerClosed = true;
        // Only this connection's own close, while it still owns the hold, is the
        // measured peer abort.
        if (server.hold.awaitingRelease && server.hold.owns(this)) {
          server.hold.notePeerClosed('peer-closed');
        }
        _wake();
      },
      onError: (Object error) {
        _streamError ??= error;
        _peerClosed = true;
        if (server.hold.awaitingRelease && server.hold.owns(this)) {
          server.hold.notePeerClosed(error);
        }
        _wake();
      },
      cancelOnError: false,
    );
    try {
      while (!_disposed && !server.closed) {
        final request = await _readRequest();
        if (request == null) return;
        wantsClose = request.wantsClose;
        await server._handleRequest(request, this);
        if (wantsClose) return;
      }
    } on _ReplayFramingError catch (error) {
      server.refuseFraming(this, error.message);
    } on Object catch (error) {
      server._onServerError(error);
      closeSocket();
    }
  }

  void _wake() {
    final waiter = _more;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  Future<bool> _need(int count) async {
    while (_buffered.length < count) {
      if (_peerClosed) return false;
      final waiter = _more = Completer<void>();
      await waiter.future;
    }
    return true;
  }

  Future<_RawRequest?> _readRequest() async {
    // The header block ends at the first empty line; split reads are normal.
    var boundary = -1;
    while (boundary < 0) {
      if (_buffered.length > _maxRequestBytes) {
        throw const _ReplayFramingError(
          'the request header block exceeds 1 MiB',
        );
      }
      boundary = _indexOfHeaderEnd(_buffered);
      if (boundary >= 0) break;
      if (!await _need(_buffered.length + 1)) {
        if (_buffered.isEmpty) return null; // clean EOF between requests
        throw const _ReplayFramingError(
          'the connection ended inside a request header block',
        );
      }
    }
    final headerBytes = _buffered.sublist(0, boundary);
    _buffered.removeRange(0, boundary + 4);
    final headerText = latin1.decode(headerBytes);
    final lines = headerText.split('\r\n');
    if (lines.isEmpty || lines.first.isEmpty) {
      throw const _ReplayFramingError('the request line is empty');
    }
    final parts = lines.first.split(' ');
    if (parts.length != 3) {
      throw _ReplayFramingError(
        'the request line is not "METHOD target HTTP/x.y": ${lines.first}',
      );
    }
    final method = parts[0];
    final rawTarget = parts[1];
    final version = parts[2];
    if (method.isEmpty || rawTarget.isEmpty || !rawTarget.startsWith('/')) {
      throw _ReplayFramingError('the request target is not origin-form');
    }
    if (version != 'HTTP/1.1' && version != 'HTTP/1.0') {
      throw _ReplayFramingError('unsupported HTTP version $version');
    }
    final headerLines = <String>[];
    final headers = <String, String>{};
    final contentLengths = <int>[];
    var wantsClose = version == 'HTTP/1.0';
    for (final line in lines.skip(1)) {
      if (line.isEmpty) continue;
      final colon = line.indexOf(':');
      if (colon <= 0) {
        throw _ReplayFramingError('a header line has no name: $line');
      }
      final name = line.substring(0, colon);
      final value = line.substring(colon + 1).trim();
      // The literal line the peer sent, including any legal optional whitespace
      // after the colon; the semantic map below is the normalized view.
      headerLines.add(line);
      final lower = name.toLowerCase();
      if (lower == 'content-length') {
        // HTTP's Content-Length is decimal digits only: `+3`, `0x3` and any other
        // Dart-accepted spelling are not this framing.
        if (!RegExp(r'^[0-9]+$').hasMatch(value)) {
          throw _ReplayFramingError(
            'invalid Content-Length "$value": only decimal digits are accepted',
          );
        }
        contentLengths.add(int.parse(value));
      } else if (lower == 'transfer-encoding') {
        throw _ReplayFramingError(
          'unsupported framing: Transfer-Encoding "$value"',
        );
      } else if (lower == 'expect') {
        throw _ReplayFramingError('unsupported framing: Expect "$value"');
      } else if (lower == 'connection') {
        if (value
            .toLowerCase()
            .split(',')
            .map((part) => part.trim())
            .contains('close')) {
          wantsClose = true;
        }
      }
      headers[lower] = value;
    }
    if (contentLengths.toSet().length > 1) {
      throw const _ReplayFramingError('conflicting Content-Length headers');
    }
    final length = contentLengths.isEmpty ? 0 : contentLengths.single;
    if (length > _maxRequestBytes) {
      throw const _ReplayFramingError('the declared body exceeds 1 MiB');
    }
    if (length > 0 && !await _need(length)) {
      throw const _ReplayFramingError(
        'the connection ended before the declared body was read',
      );
    }
    final body = _buffered.sublist(0, length);
    _buffered.removeRange(0, length);
    if (_streamError != null && body.length < length) {
      throw _ReplayFramingError('the connection failed: $_streamError');
    }
    return _RawRequest(
      method: method,
      rawTarget: rawTarget,
      version: version,
      headerLines: headerLines,
      headers: headers,
      bodyBytes: body,
      wantsClose: wantsClose || _peerClosed,
    );
  }

  static int _indexOfHeaderEnd(List<int> bytes) {
    for (var index = 0; index + 3 < bytes.length; index++) {
      if (bytes[index] == 13 &&
          bytes[index + 1] == 10 &&
          bytes[index + 2] == 13 &&
          bytes[index + 3] == 10) {
        return index;
      }
    }
    return -1;
  }

  void closeSocket() {
    if (_disposed) return;
    _disposed = true;
    _wake();
    try {
      socket.destroy();
    } on Object {
      // The socket is already gone; its terminal was recorded by the caller.
    }
  }

  void dispose() {
    _disposed = true;
    _wake();
    final subscription = _subscription;
    _subscription = null;
    subscription?.cancel().catchError((Object _) {});
    // The handler is finished with this connection: the socket must not outlive
    // it (a keep-alive client would otherwise wait for an end that never comes).
    try {
      socket.destroy();
    } on Object {
      // Already gone.
    }
  }
}

class _ReplayFramingError implements Exception {
  const _ReplayFramingError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One declared concurrent batch: its members are held until every member is in
/// flight or the cohort's own window expires, and the block keeps the measured
/// peak, membership and release reason.
class _CohortGate {
  _CohortGate(
    this.id,
    this.size,
    this.timeoutMs, [
    this.threadCount = httpBoundaryBatchWidth,
    this.threadCountSource = 'unrecorded configuration',
  ]);

  final String id;
  final int size;
  final int timeoutMs;

  /// The configuration the owning family actually runs with.
  final int threadCount;
  final String threadCountSource;
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
    'threadCount': threadCount,
  };

  Map<String, Object?> evidence() => {
    'cohort': id,
    'memberCount': membership.length,
    'memberArrivalOrder': membership,
    'releaseReason': released ? releaseReason : 'cohort-window',
    'threadCount': threadCount,
    'threadCountSource': threadCountSource,
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

  void enter(String selector, [Object? owner]) {
    _owner ??= owner;
    if (!_entered.isCompleted) _entered.complete(true);
  }

  /// The one connection whose request entered this hold: only its own close may
  /// report the peer abort. An unrelated idle connection's EOF is not the
  /// owner's abort.
  Object? _owner;

  bool owns(Object? connection) =>
      _owner != null && identical(_owner, connection);

  /// Whether a hold is entered and not yet released: the only window in which a
  /// peer close is the measured abort.
  bool get awaitingRelease => _entered.isCompleted && !released.isCompleted;

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

/// Drives the real replay listener through a real loopback socket, so the
/// focused tests exercise the owned framing/reader itself rather than a model of
/// it. One declared response, one connection per entry in [rawRequests] unless
/// [sequential] asks for them on one connection.
Future<Map<String, Object?>> probeOwnedReplayListener({
  required Map<String, Object?> response,
  required List<String> rawRequests,
  bool sequential = false,
  bool fragment = false,
  bool abortHeld = false,
  bool closeAfterWrite = false,
  bool idlePeerClose = false,
}) async {
  final requests = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final serverErrors = <String>[];
  final responseBytes = <int>[];
  final listener = await _ReplayServer.start(
    origin: Uri.parse('http://127.0.0.1:0'),
    responses: [response.cast<String, dynamic>()],
    owners: {
      '${response['id']}': (step: 'probe.step', family: 'stage', cohort: null),
    },
    cohortSizes: const {},
    cohortTimeouts: const {},
    onServerError: (error) => serverErrors.add('$error'),
  );
  try {
    Future<List<int>> oneConnection(String raw) async {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        listener.port,
      );
      final received = <int>[];
      final done = Completer<void>();
      final answered = Completer<void>();
      final subscription = socket.listen(
        (data) {
          received.addAll(data);
          if (!answered.isCompleted) answered.complete();
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );
      try {
        final bytes = utf8.encode(raw);
        if (fragment && bytes.length > 12) {
          socket.add(bytes.sublist(0, 12));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.add(bytes.sublist(12));
        } else {
          socket.add(bytes);
        }
        await socket.flush();
        if (idlePeerClose) {
          // A second, idle connection that never sends a request: closing it must
          // not be reported as the held request's peer abort.
          final idle = await Socket.connect(
            InternetAddress.loopbackIPv4,
            listener.port,
          );
          final entered = await listener.hold.entered.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          );
          if (entered != true) {
            idle.destroy();
            throw StateError('the held response was not entered');
          }
          idle.destroy();
          await Future<void>.delayed(const Duration(milliseconds: 100));
          listener.releaseHold();
          await done.future.timeout(const Duration(seconds: 10));
        } else if (abortHeld) {
          final entered = await listener.hold.entered.timeout(
            const Duration(seconds: 5),
            onTimeout: () => false,
          );
          if (entered != true) {
            throw StateError('the held response was not entered');
          }
          socket.destroy();
          await listener.hold.peerClosed.timeout(const Duration(seconds: 5));
          listener.releaseHold();
          await listener.hold.abortObserved.future.timeout(
            const Duration(seconds: 5),
          );
        } else if (closeAfterWrite) {
          // The client ends its own request early (a truncated body, an EOF
          // between requests): the listener must refuse it visibly.
          await Future<void>.delayed(const Duration(milliseconds: 100));
          socket.destroy();
          // The client ended this connection itself, so it is done here whatever
          // the listener does next; the listener's refusal is what is measured.
          if (!done.isCompleted) done.complete();
          await done.future.timeout(const Duration(seconds: 10));
        } else if (raw.toLowerCase().contains('connection: close')) {
          // The server closes after this response, so the body arrives with it.
          await done.future.timeout(const Duration(seconds: 10));
        } else {
          // A keep-alive server answers and stays open: the response is the
          // client's completion fact, not the socket's end.
          await Future.any([
            answered.future,
            done.future,
          ]).timeout(const Duration(seconds: 10));
        }
      } finally {
        await subscription.cancel();
        socket.destroy();
      }
      return received;
    }

    if (sequential) {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        listener.port,
      );
      final received = <int>[];
      final done = Completer<void>();
      final subscription = socket.listen(
        received.addAll,
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object _) {
          if (!done.isCompleted) done.complete();
        },
      );
      try {
        for (final raw in rawRequests) {
          socket.add(utf8.encode(raw));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        socket.destroy();
        await done.future.timeout(const Duration(seconds: 10));
      } finally {
        await subscription.cancel();
      }
      responseBytes.addAll(received);
    } else {
      for (final raw in rawRequests) {
        responseBytes.addAll(await oneConnection(raw));
      }
    }
    // The listener records asynchronously; give the last handler its turn.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    requests.addAll(listener.requests);
    unmatched.addAll(listener.unmatched);
  } finally {
    await listener.close();
  }
  return {
    'requests': requests,
    'unmatched': unmatched,
    'serverErrors': serverErrors,
    'responseBytes': responseBytes.length,
    'responseText': utf8.decode(responseBytes, allowMalformed: true),
    'closed': listener.closed,
  };
}

/// Runs the real header-map helper against one injected evaluation failure, so a
/// focused test asserts the observed outcome through the helper's own code rather
/// than a model of it. Nothing is executed beyond that row.
class _ProbeFailingRuntime implements InProcessSourceScriptRuntime {
  _ProbeFailingRuntime(this.error);
  final Object error;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #evaluate) {
      return Future<Object?>.error(error);
    }
    return super.noSuchMethod(invocation);
  }
}

Future<Map<String, Object?>> probeHeaderMapEvaluationError({
  required Object error,
  required Map<String, dynamic> corpus,
  required Directory root,
}) async {
  final step = httpBoundarySteps(
    corpus,
  ).firstWhere((row) => row['action'] == 'headerMap');
  final run = _HttpBoundaryRun(
    corpus: corpus,
    corpusLf: '',
    root: root,
    libraryPath: '',
    librarySha256: '',
    report: <String, Object?>{},
  );
  run._runtimes['${step['source']}'] = _ProbeFailingRuntime(error);
  final observation = <String, Object?>{
    'id': step['id'],
    'evidence': <String, Object?>{},
    'value': <String, Object?>{},
    'outcome': 'incomplete',
    'category': null,
  };
  Object? thrown;
  try {
    await run._runHelper(step, observation);
  } on Object catch (error) {
    thrown = error;
  }
  return {
    'thrownType': thrown == null ? null : '${thrown.runtimeType}',
    'observation': observation,
  };
}

/// The order every owned resource follows after admission stops: owned workers
/// settle first, and only then are the database, the native runtime and the
/// scratch root touched. A worker that cannot settle inside [deadline] is not
/// hidden: the remaining steps do not run and the owned residue is retained.
class HttpBoundaryTeardownReceipt {
  const HttpBoundaryTeardownReceipt({
    required this.workerSettled,
    required this.stepsAttempted,
    required this.stepsRun,
    required this.errors,
    required this.residueRetained,
    required this.timeoutMillis,
  });

  final bool workerSettled;

  /// Every cleanup step the caller tried, in the order it tried them.
  final List<String> stepsAttempted;

  /// The steps that completed; an attempted step is never implied completed.
  final List<String> stepsRun;

  /// One entry per failed step: which step, the error's type and its message.
  final List<Map<String, Object?>> errors;
  final bool residueRetained;
  final int timeoutMillis;

  Map<String, Object?> toJson() => {
    'workerSettled': workerSettled,
    'stepsAttempted': stepsAttempted,
    'stepsRun': stepsRun,
    'errors': errors,
    'residueRetained': residueRetained,
    'timeoutMillis': timeoutMillis,
  };
}

/// The order every owned resource follows after admission stops: owned workers
/// settle first, and only then are the database snapshot, the database close and
/// the native runtime touched. Each step is attempted independently once the
/// worker is settled, so one failing step cannot skip the remaining safe cleanup
/// or lose the collected evidence; an unresolved worker performs none of them.
Future<HttpBoundaryTeardownReceipt> settleOwnedTeardown({
  required List<Future<void>> workers,
  required Duration deadline,
  required Future<void> Function() snapshotDatabase,
  required Future<void> Function() closeDatabase,
  required Future<void> Function() disposeNative,
}) async {
  var settled = true;
  if (workers.isNotEmpty) {
    try {
      await Future.wait(workers).timeout(deadline);
    } on TimeoutException {
      settled = false;
    }
  }
  if (!settled) {
    return HttpBoundaryTeardownReceipt(
      workerSettled: false,
      stepsAttempted: const <String>[],
      stepsRun: const <String>[],
      errors: const <Map<String, Object?>>[],
      residueRetained: true,
      timeoutMillis: deadline.inMilliseconds,
    );
  }
  final attempted = <String>[];
  final completed = <String>[];
  final errors = <Map<String, Object?>>[];
  Future<void> step(String name, Future<void> Function() action) async {
    attempted.add(name);
    try {
      await action();
      completed.add(name);
    } on Object catch (error) {
      errors.add({
        'step': name,
        'errorType': '${error.runtimeType}',
        'error': '$error',
      });
    }
  }

  await step('snapshotDatabase', snapshotDatabase);
  await step('closeDatabase', closeDatabase);
  await step('disposeNative', disposeNative);
  return HttpBoundaryTeardownReceipt(
    workerSettled: true,
    stepsAttempted: attempted,
    stepsRun: completed,
    errors: errors,
    residueRetained: errors.isNotEmpty,
    timeoutMillis: deadline.inMilliseconds,
  );
}

Map<String, Object?> _lowerHeaders(HttpHeaders headers) {
  final result = <String, Object?>{};
  headers.forEach((name, values) {
    result[name.toLowerCase()] = values.length == 1
        ? values.single
        : values.join(', ');
  });
  return result;
}
