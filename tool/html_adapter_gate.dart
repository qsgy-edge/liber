import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:liber/source/html4_unescape.dart';
import 'package:liber/source/html_rule_adapter.dart';
import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/rule_field.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:pointycastle/export.dart';

/// Runs the extraction corpus against the Rust adapter and, when a frozen
/// golden is supplied, compares it with the values the frozen APK produced.
///
/// Usage:
///   dart run tool/html_adapter_gate.dart `<fjs library>` `[<frozen golden>]`
///                                       `[<observations>]` `[<corpus>]`
///
/// The first three positional arguments keep their meaning: `-` as the golden
/// means destination-only, and the third argument is the report path the run
/// refuses to overwrite. The fourth selects a corpus; it defaults to the
/// unchanged `tool/html_oracle/fixtures.json`, whose 45-case invocation and
/// committed goldens stay verbatim.
///
/// `HTML-LIST-01` (`tool/html_oracle/list-fixtures.json`) is the independent
/// nonempty-list family. Its metadata is at the corpus root and its frozen
/// record is the collector's nested `corpus` block (`asset`, byte length, raw
/// SHA-256, fixture/version/schema) plus a nonempty device fingerprint. The gate
/// validates that measured binding before comparing, refuses an empty corpus or
/// an unknown non-legacy corpus, and accepts only the byte-identical legacy
/// corpus without those fields. Frozen rows must carry exactly one typed
/// value/error outcome per declared unique id; row order is not a fact, explicit
/// null is a value, and an outcome's kind is compared as well as its payload.
/// The `getStringListUrl` form is a named product refusal when nonempty, so a
/// corpus row of that shape is refused rather than rendered as a list.
///
/// A case whose `path` is `rule` runs through the product's **rule-field path**
/// (`lib/source/rule_field.dart` in front of the adapter), because its frozen
/// entry point is `AnalyzeRule.getString` over a rule that carries an `@js:`
/// segment, and the bare adapter deliberately refuses those (ticket #11).
const legacyHtmlCorpusPath = 'tool/html_oracle/fixtures.json';
const htmlListCorpusPath = 'tool/html_oracle/list-fixtures.json';

/// The one immutable legacy corpus identity. A byte-identical copy is the same
/// corpus wherever it is selected; any other corpus without family metadata is
/// unknown, not a legacy downgrade.
const legacyHtmlCorpusSha256 =
    'e4853a8d5653db658608d5cbc4db6907015e894731fa90ac911f7283cbb20342';

/// The harness packages the selected corpus under this one fixed asset name.
const htmlOracleCorpusAsset = 'html-fixtures.json';

/// The selected nonempty-list family this gate admits.
const htmlListFixtureId = 'HTML-LIST-01';
const htmlListCorpusVersion = 1;
const selectedHtmlFixtureId = 'HTML-SELECTED-01';
const selectedHtmlListFixtureId = 'HTML-LIST-SELECTED-01';
const selectedHtmlCorpusSha256 =
    '5b5bca0204fba6e1da4abdb8fd64fb7b0017dab5bf560098ef4b97f36117c266';
const selectedHtmlListCorpusSha256 =
    '837228894594decc6dcf195cd565365ef461c760f02cbb6b02e32f0fa7f6eb01';
const htmlOracleSchemaVersion = 1;
const htmlOracleBaselineCommit = '14dd24945b2914ce2708b8abaa4ee67ceef892af';
const htmlOracleEntryPoint =
    'AnalyzeRule.getString/getStringList (default and URL modes)';

const _htmlOracleMethods = {
  'getString',
  'getStringUrl',
  'getStringList',
  'getStringListUrl',
};

/// One corpus read once: the path, the exact bytes that were parsed, the
/// decoded object and, for a metadata-bearing family, its declared identity.
class _HtmlCorpus {
  _HtmlCorpus({
    required this.path,
    required this.bytes,
    required this.json,
    required this.family,
  });

  final String path;
  final List<int> bytes;
  final Map<String, dynamic> json;

  /// `null` for the unchanged legacy corpus, which carries no fixture id.
  final ({String fixtureId, int corpusVersion})? family;

  Map<String, String> get documents =>
      (json['documents'] as Map).cast<String, String>();

  List<Map<String, dynamic>> get cases =>
      (json['cases'] as List).cast<Map<String, dynamic>>();

  /// The declared method of every case, used to type a frozen outcome.
  Map<String, String> get caseMethods => {
    for (final entry in cases)
      entry['id'] as String: entry['method'] as String? ?? 'getString',
  };
}

/// Runs one corpus and returns its report. The caller owns [NativeLibrary]:
/// this function initializes it when needed but never disposes it.
Future<Map<String, Object?>> runHtmlAdapterGate({
  required String libraryPath,
  String? goldenPath,
  File? output,
  String corpusPath = legacyHtmlCorpusPath,
}) async {
  if (output != null && output.existsSync()) {
    throw StateError('Refusing to overwrite evidence: ${output.path}');
  }
  final corpus = _readHtmlCorpus(corpusPath);
  final selected =
      corpus.family?.fixtureId == selectedHtmlFixtureId ||
      corpus.family?.fixtureId == selectedHtmlListFixtureId;
  final caseMethods = corpus.caseMethods;
  final declaredIds = [for (final entry in corpus.cases) entry['id'] as String];
  final golden = goldenPath == null
      ? null
      : jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  if (golden != null) {
    if (selected) {
      _validateSelectedCapture(File(goldenPath!), corpus);
    }
    _validateGoldenIdentity(golden, corpus);
    final goldenObservations = golden['observations'];
    if (goldenObservations is! List) {
      throw StateError('Frozen golden observations missing');
    }
    _validateFrozenObservations(
      goldenObservations.cast<Map>(),
      caseMethods,
      declaredIds,
    );
  }

  await NativeLibrary.initialize(libraryPath: libraryPath);
  final baseUrl = corpus.json['baseUrl'] as String? ?? '';
  final documents = corpus.documents;
  final cases = corpus.cases;
  final observations = <Map<String, Object?>>[];
  var failed = false;
  for (final entry in cases) {
    final id = entry['id'] as String;
    final rule = entry['rule'] as String;
    final method = entry['method'] as String? ?? 'getString';
    final document = documents[entry['document']] ?? '';
    final observation = <String, Object?>{'id': id, 'rule': rule};
    try {
      if (entry['path'] == 'rule') {
        observation['value'] = await htmlAdapterRuleFieldValue(
          document,
          rule,
          baseUrl: baseUrl,
        );
      } else if (entry['path'] == 'json') {
        final jsonDocument = jsonDecode(document);
        if (method == 'getStringList' || method == 'getStringListUrl') {
          observation['value'] = _jsonListValues(jsonDocument, rule, method);
        } else if (method == 'getString' || method == 'getStringUrl') {
          observation['value'] = JsonSourceRules.extract(jsonDocument, rule);
        } else {
          throw UnsupportedError('Unknown oracle method: $method');
        }
      } else {
        final batch = HtmlRuleBatch(document);
        if (method == 'getStringList' || method == 'getStringListUrl') {
          final job = batch.documentTextList(id, rule);
          await batch.run();
          observation['value'] = _htmlListValues(job.values, method);
        } else if (method == 'getStringUrl') {
          final job = batch.documentText(id, rule);
          await batch.run();
          observation['value'] = job.hasMatch
              ? job.value
              : applyRuleReplacement('', splitRuleFields(rule), label: 'HTML');
        } else if (method == 'getString') {
          final job = batch.documentText(id, rule);
          await batch.run();
          observation['value'] = job.value;
        } else {
          throw UnsupportedError('Unknown oracle method: $method');
        }
      }
    } catch (error) {
      observation['error'] = '$error';
    }
    observations.add(observation);
  }

  final family = corpus.family;
  if (family != null) {
    final observedIds = [for (final item in observations) item['id'] as String];
    if (declaredIds.toSet().length != declaredIds.length ||
        observedIds.length != declaredIds.length ||
        observedIds.toSet().length != observedIds.length ||
        !observedIds.toSet().containsAll(declaredIds)) {
      throw StateError(
        'Observation ids differ from the declared corpus ids: '
        'expected ${declaredIds.length} unique ids',
      );
    }
  }

  final expectedFailures = <String>[];
  for (final entry in cases) {
    if (!entry.containsKey('expected')) continue;
    final id = entry['id'] as String;
    final expected = entry['expected'];
    final observed = observations.firstWhere((item) => item['id'] == id);
    final outcome = _outcomeOf(observed, 'Observation $id');
    if (outcome.kind != 'value' ||
        jsonEncode(outcome.payload) != jsonEncode(expected)) {
      if (!selected) failed = true;
      expectedFailures.add(
        '$id\n  expected: ${jsonEncode(expected)}\n  observed: '
        '${jsonEncode(outcome.payload)} (${outcome.kind})',
      );
    }
  }
  if (expectedFailures.isNotEmpty) {
    stderr.writeln(
      '${selected ? 'Historical corpus annotations' : 'Corpus expectations'} '
      'differ:\n${expectedFailures.join('\n')}',
    );
  }

  final mismatches = <String>[];
  if (golden != null) {
    final goldenRows = <String, Map>{
      for (final item in (golden['observations'] as List).cast<Map>())
        item['id'] as String: item,
    };
    for (final item in observations) {
      final id = item['id'] as String;
      final frozenRow = goldenRows[id];
      if (frozenRow == null) {
        mismatches.add('$id: no frozen observation');
        continue;
      }
      final frozenOutcome = _outcomeOf(frozenRow, 'Frozen observation $id');
      final observedOutcome = _outcomeOf(item, 'Observation $id');
      if (frozenOutcome.kind != observedOutcome.kind ||
          jsonEncode(frozenOutcome.payload) !=
              jsonEncode(observedOutcome.payload)) {
        mismatches.add(
          '$id: frozen=${jsonEncode(frozenOutcome.payload)} '
          '(${frozenOutcome.kind}) windows='
          '${jsonEncode(observedOutcome.payload)} '
          '(${observedOutcome.kind})',
        );
      }
    }
    if (mismatches.isNotEmpty) failed = true;
  }

  final library = File(libraryPath);
  final corpusSha256 = _sha256(corpus.bytes);
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'corpusPath': corpus.path,
    'corpusFixtureId': family?.fixtureId,
    'corpusVersion': family?.corpusVersion,
    'corpusSha256': corpusSha256,
    'baselineCommit': corpus.json['baselineCommit'],
    'entryPoint': corpus.json['entryPoint'],
    'status': selected && golden == null
        ? 'not-run'
        : (failed ? 'fail' : 'pass'),
    'frozenGolden': goldenPath ?? 'not-run',
    'librarySha256': library.existsSync()
        ? _sha256(library.readAsBytesSync())
        : 'unknown',
    // The selected corpus' raw bytes, not a hash copied from the corpus.
    'fixturesSha256': corpusSha256,
    'cases': cases.length,
    'observations': observations,
    'expectationMismatches': expectedFailures,
    'frozenMismatches': mismatches,
  };
  if (output != null) {
    output.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    stdout.writeln('Wrote ${output.path}');
  }
  return report;
}

Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 4) {
    throw ArgumentError(
      'Usage: <library> [<frozen golden.json>] [<observations.json>] '
      '[<corpus.json>]',
    );
  }
  final output = args.length > 2 ? File(args[2]) : null;
  if (output != null && output.existsSync()) {
    throw StateError('Refusing to overwrite evidence: ${output.path}');
  }
  await NativeLibrary.initialize(libraryPath: args[0]);
  try {
    final report = await runHtmlAdapterGate(
      libraryPath: args[0],
      goldenPath: args.length > 1 && args[1] != '-' ? args[1] : null,
      output: output,
      corpusPath: args.length > 3 ? args[3] : legacyHtmlCorpusPath,
    );
    if (output == null) {
      stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    }
    final failed = report['status'] == 'fail';
    final notRun = report['status'] == 'not-run';
    stdout.writeln(
      'adapter corpus: ${notRun ? 'not-run' : (failed ? 'fail' : 'pass')} '
      '(${report['cases']} cases, frozen golden '
      '${report['frozenGolden'] == 'not-run' ? 'not-run' : 'compared'})',
    );
    if (failed) exitCode = 1;
    if (notRun) exitCode = 2;
  } finally {
    NativeLibrary.dispose();
  }
}

/// The unchanged legacy corpus is the only corpus without family metadata, and
/// only its pinned raw bytes are that corpus. A metadata-bearing corpus must
/// name the one family this gate implements, carry typed integers, and have a
/// nonempty row set. Every corpus is rejected before a rule runs when it is
/// empty or unknown; a same-byte legacy copy remains the legacy corpus.
_HtmlCorpus _readHtmlCorpus(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('HTML oracle corpus must be a JSON object');
  }
  final json = decoded;
  final cases = json['cases'];
  if (cases is! List || cases.isEmpty) {
    throw const FormatException('HTML oracle corpus declares no cases');
  }
  final fixtureId = json['fixtureId'];
  final corpusVersion = json['corpusVersion'];
  ({String fixtureId, int corpusVersion})? family;
  if (fixtureId != null || corpusVersion != null) {
    if (fixtureId is! String || corpusVersion is! int) {
      throw const FormatException(
        'Corpus fixtureId/corpusVersion must both be present with their '
        'declared types',
      );
    }
    final selected =
        fixtureId == selectedHtmlFixtureId ||
        fixtureId == selectedHtmlListFixtureId;
    if ((!selected && fixtureId != htmlListFixtureId) ||
        corpusVersion != htmlListCorpusVersion) {
      throw FormatException(
        'Unknown HTML oracle corpus family: $fixtureId v$corpusVersion',
      );
    }
    final schemaVersion = json['schemaVersion'];
    if (schemaVersion is! int || schemaVersion != htmlOracleSchemaVersion) {
      throw const FormatException('Unsupported HTML-LIST-01 schemaVersion');
    }
    if (selected) {
      final expectedHash = fixtureId == selectedHtmlFixtureId
          ? selectedHtmlCorpusSha256
          : selectedHtmlListCorpusSha256;
      if (_sha256(bytes) != expectedHash ||
          json['baselineCommit'] !=
              'a7d37f1707a70a459ad708f4fe79341d1e42d716') {
        throw const FormatException('Selected HTML corpus bytes differ');
      }
    } else if (json['baselineCommit'] != htmlOracleBaselineCommit ||
        json['entryPoint'] != htmlOracleEntryPoint) {
      throw const FormatException(
        'HTML-LIST-01 baseline/entryPoint metadata does not match the oracle',
      );
    }
    family = (fixtureId: fixtureId, corpusVersion: corpusVersion);
    _validateHtmlListRows(json, allowRulePath: selected);
  } else if (_sha256(bytes) != legacyHtmlCorpusSha256) {
    throw const FormatException(
      'Unknown HTML oracle corpus: not the pinned legacy bytes',
    );
  }
  final corpus = _HtmlCorpus(
    path: path,
    bytes: bytes,
    json: json,
    family: family,
  );
  // Read the two shapes once so a malformed legacy corpus still fails before
  // any rule runs, exactly as the previous casts did.
  corpus.documents;
  corpus.cases;
  return corpus;
}

/// Validates the independent list family's rows: unique nonempty ids, declared
/// documents/rules/methods, a supported HTML or JSON path, a present `expected`
/// (an explicit null is legitimate) and the type that `expected` must have for
/// its method.
void _validateHtmlListRows(
  Map<String, dynamic> json, {
  bool allowRulePath = false,
}) {
  final documents = json['documents'];
  final cases = json['cases'];
  if (documents is! Map || cases is! List) {
    throw const FormatException('HTML-LIST-01 documents/cases are malformed');
  }
  final ids = <String>{};
  for (final raw in cases) {
    if (raw is! Map) {
      throw const FormatException('HTML-LIST-01 case is not an object');
    }
    final entry = raw.cast<String, dynamic>();
    final id = entry['id'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('HTML-LIST-01 case id must be nonempty');
    }
    if (!ids.add(id)) {
      throw FormatException('Duplicate HTML-LIST-01 case id: $id');
    }
    final document = entry['document'];
    if (document is! String || !documents.containsKey(document)) {
      throw FormatException('HTML-LIST-01 case $id names an absent document');
    }
    final body = documents[document];
    if (body is! String) {
      throw FormatException(
        'HTML-LIST-01 case $id references a non-string document: $document',
      );
    }
    final rule = entry['rule'];
    if (rule is! String || rule.isEmpty) {
      throw FormatException('HTML-LIST-01 case $id has no rule');
    }
    final method = entry['method'] ?? 'getString';
    if (!_htmlOracleMethods.contains(method)) {
      throw FormatException('HTML-LIST-01 case $id has unknown method');
    }
    final path = entry['path'];
    if (path != null && path != 'json' && !(allowRulePath && path == 'rule')) {
      throw FormatException(
        'HTML-LIST-01 case $id uses an unsupported path: $path',
      );
    }
    if (!entry.containsKey('expected')) {
      throw FormatException('HTML-LIST-01 case $id has no expected field');
    }
    final expected = entry['expected'];
    if (method == 'getStringList' || method == 'getStringListUrl') {
      if (expected != null &&
          (expected is! List || expected.any((item) => item is! String))) {
        throw FormatException(
          'HTML-LIST-01 list case $id expected value must be a list of '
          'strings or null',
        );
      }
    } else if (expected != null && expected is! String) {
      throw FormatException(
        'HTML-LIST-01 scalar case $id expected value must be a string or null',
      );
    }
  }
}

/// Admit selected native observations only through the collector's real raw-bundle
/// verifier. The verifier rechecks the signed installed APK, packaged assets,
/// current source/reference bindings and every ordered command receipt without
/// accessing a handset. Historical corpus admission never invokes it.
void _validateSelectedCapture(File goldenFile, _HtmlCorpus corpus) {
  final directory = goldenFile.parent;
  File artifact(String name) {
    final file = File('${directory.path}/$name');
    if (!file.existsSync()) {
      throw FormatException('Selected capture bundle missing: $name');
    }
    return file;
  }

  final observation = artifact('observation.json');
  artifact('manifest.json');
  final apk = artifact('installed-harness.apk');
  artifact('frozen.apk');
  if (!FileSystemEntity.identicalSync(goldenFile.path, observation.path)) {
    throw const FormatException('Selected golden must be raw observation.json');
  }
  final temporary = Directory.systemTemp.createTempSync('liber-html-verify-');
  try {
    final result = Process.runSync('python', [
      'tool/html_oracle/capture.py',
      '--verify-bundle',
      directory.absolute.path,
      '--apk',
      apk.absolute.path,
      '--corpus',
      File(corpus.path).absolute.path,
      '--frozen-source',
      'C:/Users/17945/AppData/Local/liber-evidence/spec133/'
          'phone-resume-20261020-01a15796/controller/team-baseline-migration-01/'
          'reference-stage/source',
      '--java-home',
      'C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8',
      '--android-sdk',
      'C:/Users/17945/AppData/Local/Android/Sdk',
      '--output',
      '${temporary.path}/verification',
    ]);
    if (result.exitCode != 0) {
      throw FormatException(
        'Selected raw-bundle verification failed: ${result.stdout} ${result.stderr}',
      );
    }
    final receipt = jsonDecode(
      File('${temporary.path}/verification/manifest.json').readAsStringSync(),
    );
    if (receipt is! Map || receipt['status'] != 'verified-bundle') {
      throw const FormatException('Selected raw-bundle verification missing');
    }
  } finally {
    temporary.deleteSync(recursive: true);
  }
}

/// The new family's frozen record must carry the actual nested `corpus` block
/// the collector emits: the one asset name, the measured byte length and raw
/// SHA-256, typed fixture/version/schema identity and a nonempty device
/// fingerprint. Legacy keeps its original top-level baseline/entryPoint
/// admission and its committed golden with no fabricated nested fields.
void _validateGoldenIdentity(Map<String, dynamic> golden, _HtmlCorpus corpus) {
  if (golden['baselineCommit'] != corpus.json['baselineCommit'] ||
      golden['entryPoint'] != corpus.json['entryPoint']) {
    throw StateError('Oracle identity mismatch');
  }
  final family = corpus.family;
  if (family == null) return;
  final identity = golden['corpus'];
  if (identity is! Map) {
    throw StateError('Oracle corpus identity mismatch');
  }
  final measured = _sha256(corpus.bytes);
  if (identity['asset'] != htmlOracleCorpusAsset) {
    throw StateError('Oracle corpus identity mismatch');
  }
  final bytes = identity['bytes'];
  if (bytes is! int || bytes != corpus.bytes.length) {
    throw StateError('Oracle corpus identity mismatch');
  }
  final sha256 = identity['sha256'];
  if (sha256 is! String || sha256 != measured) {
    throw StateError('Oracle corpus identity mismatch');
  }
  final corpusVersion = identity['corpusVersion'];
  final schemaVersion = identity['schemaVersion'];
  if (identity['fixtureId'] != family.fixtureId ||
      corpusVersion is! int ||
      corpusVersion != family.corpusVersion ||
      schemaVersion is! int ||
      schemaVersion != htmlOracleSchemaVersion) {
    throw StateError('Oracle corpus identity mismatch');
  }
  final fingerprint = golden['fingerprint'];
  if (fingerprint is! String || fingerprint.trim().isEmpty) {
    throw StateError('Frozen golden device fingerprint missing');
  }
}

/// One frozen row: exactly one actual outcome, a declared id, and a value typed
/// by that case's own method. An explicit null is a value; a missing or
/// contradictory outcome is not backfilled. Row order is not a fact.
void _validateFrozenObservations(
  List<Map> observations,
  Map<String, String> methods,
  List<String> declaredIds,
) {
  final ids = <String>{};
  for (final item in observations) {
    final id = item['id'];
    if (id is! String || id.isEmpty) {
      throw StateError('Frozen golden observation id must be nonempty');
    }
    if (!ids.add(id)) {
      throw StateError('Duplicate frozen golden observation id: $id');
    }
    final method = methods[id];
    if (method == null) {
      throw StateError('Frozen golden observation id is not declared: $id');
    }
    final outcome = _outcomeOf(item, 'Frozen observation $id');
    if (outcome.kind == 'error') {
      final error = outcome.payload;
      if (error is! String || error.trim().isEmpty) {
        throw StateError(
          'Frozen observation $id error must be a nonempty string',
        );
      }
    } else {
      _validateFrozenValue(id, method, outcome.payload);
    }
  }
  final declared = declaredIds.toSet();
  if (ids.length != declared.length || !ids.containsAll(declared)) {
    throw StateError(
      'Frozen golden observation ids differ from the declared corpus ids',
    );
  }
}

void _validateFrozenValue(String id, String method, Object? value) {
  if (method == 'getStringList' || method == 'getStringListUrl') {
    if (value != null &&
        (value is! List || value.any((item) => item is! String))) {
      throw StateError(
        'Frozen list observation $id value must be a string list or null',
      );
    }
  } else if (value != null && value is! String) {
    throw StateError(
      'Frozen scalar observation $id value must be a string or null',
    );
  }
}

/// The actual outcome kind and payload. Exactly one of `value`/`error` must be
/// present; comparison uses the kind so equal text cannot hide one behind the
/// other.
typedef _Outcome = ({String kind, Object? payload});

_Outcome _outcomeOf(Map item, String context) {
  final hasValue = item.containsKey('value');
  final hasError = item.containsKey('error');
  if (hasValue == hasError) {
    throw StateError('$context must carry exactly one of value or error');
  }
  return hasValue
      ? (kind: 'value', payload: item['value'])
      : (kind: 'error', payload: item['error']);
}

/// The HTML list value: the adapter's per-match `getStringList` answer. The
/// nonempty URL form is a named product refusal, so only its empty result is
/// measurable through this product path.
List<String> _htmlListValues(List<String> values, String method) {
  if (method == 'getStringListUrl') {
    if (values.isNotEmpty) {
      throw UnsupportedError(
        'The nonempty getStringListUrl form is a named product refusal (#90)',
      );
    }
    return const <String>[];
  }
  return List<String>.of(values);
}

/// The JSON list value: the product's own raw matches (`JsonSourceRules.list`)
/// rendered by its own `contentText`, with a field's `##` applied per item as
/// `JsonSourcePipeline._resolvedStringList` does. The API is unchanged.
List<String> _jsonListValues(Object? document, String rule, String method) {
  final fields = splitRuleFields(rule);
  final values = JsonSourceRules.list(document, fields.rule);
  final texts = <String>[
    for (final item in values)
      fields.regex?.isNotEmpty == true
          ? applyRuleReplacement(JsonSourceRules.contentText(item), fields)
          : JsonSourceRules.contentText(item),
  ];
  if (method == 'getStringListUrl') {
    if (texts.isNotEmpty) {
      throw UnsupportedError(
        'The nonempty getStringListUrl form is a named product refusal (#90)',
      );
    }
    return const <String>[];
  }
  return texts;
}

/// One rule-field case through the product's own path: the shared
/// `@js:`/`<js>`/`{{...}}`/`@get:`/`@put:` layer in front of the Rust adapter,
/// which is what a pipeline stage runs and what the frozen `AnalyzeRule.getString`
/// answers. `@get:`/`@put:` read and write an empty source key's variables, the
/// way one analysis owns them. Focused regressions call this same tool entry
/// to check that nested reads retain its runtime, state and scalar tail.
Future<String> htmlAdapterRuleFieldValue(
  String html,
  String rule, {
  required String baseUrl,
}) async {
  const sourceRef = 'tool/html_adapter_gate';
  final state = SourceHostState();
  final runtime = InProcessSourceScriptRuntime(hostState: state);
  Future<String> readScalar(Object? value, String valueRule) async {
    if (valueRule.isEmpty) return '';
    final context = RuleFieldContext(
      evaluateScript: (script, result) => runtime.evaluate(
        source: script,
        input: {
          'sourceKey': sourceRef,
          'baseUrl': baseUrl,
          'src': value,
          'result': result,
          'title': null,
        },
        timeout: const Duration(seconds: 15),
      ),
      extract: (_, nestedRule) => readScalar(value, nestedRule),
      readVariable: (key) async {
        final stored = await state.entry(
          sourceRef,
          sourceRuleVariableKey(sourceRef, key),
        );
        return stored is String ? stored : '';
      },
      writeVariable: (key, stored) => state.putEntry(
        sourceRef,
        sourceRuleVariableKey(sourceRef, key),
        stored,
      ),
    );
    final field = await RuleField.resolve(valueRule, context, content: value);
    final deferTail =
        field.hasValueExtraction &&
        field.scripts.isNotEmpty &&
        splitRuleFields(field.extractionRule!).rule.isNotEmpty;
    Object? extracted = value;
    if (field.hasValueExtraction) {
      final batch = HtmlRuleBatch('$value');
      if (deferTail) {
        final fields = splitRuleFields(field.extractionRule!);
        final job = batch.documentTextList('value', fields.rule);
        await batch.run();
        extracted = job.values.isEmpty
            ? null
            : applyRuleReplacement(
                job.values.join('\n'),
                fields,
                label: 'HTML',
              );
      } else {
        final job = batch.documentText('value', field.extractionRule!);
        await batch.run();
        extracted = job.value;
      }
    }
    final result = await field.apply(
      extracted,
      forValue: true,
      contentText: '$value',
    );
    final text = '${result ?? ''}';
    return field.isLiteralValue || field.isScriptOnly || deferTail
        ? unescapeHtml4(text)
        : text;
  }

  return readScalar(html, rule);
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
