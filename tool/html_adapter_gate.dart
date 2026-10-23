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
/// nonempty-list family. It carries `fixtureId`/`corpusVersion` metadata, and
/// this gate refuses an unknown or damaged family, a duplicate/missing case id
/// and a declared expected value of the wrong type for its method. Its report
/// names the selected corpus and the measured raw SHA-256 of the bytes it read.
/// The `getStringListUrl` form is a named product refusal when nonempty, so a
/// corpus row of that shape is refused rather than rendered as a list.
///
/// A case whose `path` is `rule` runs through the product's **rule-field path**
/// (`lib/source/rule_field.dart` in front of the adapter), because its frozen
/// entry point is `AnalyzeRule.getString` over a rule that carries an `@js:`
/// segment, and the bare adapter deliberately refuses those (ticket #11).
const legacyHtmlCorpusPath = 'tool/html_oracle/fixtures.json';
const htmlListCorpusPath = 'tool/html_oracle/list-fixtures.json';

/// The selected nonempty-list family this gate admits.
const htmlListFixtureId = 'HTML-LIST-01';
const htmlListCorpusVersion = 1;
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
  final golden = goldenPath == null
      ? null
      : jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  if (golden != null) {
    if (golden['baselineCommit'] != corpus.json['baselineCommit'] ||
        golden['entryPoint'] != corpus.json['entryPoint']) {
      throw StateError('Oracle identity mismatch');
    }
    final family = corpus.family;
    if (family != null &&
        (golden['fixtureId'] != family.fixtureId ||
            golden['corpusVersion'] != family.corpusVersion)) {
      throw StateError('Oracle corpus identity mismatch');
    }
    if (family != null) {
      _validateGoldenObservationIds(
        (golden['observations'] as List).cast<Map>(),
        [for (final entry in corpus.cases) entry['id'] as String],
      );
    }
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
    final declaredIds = [for (final entry in cases) entry['id'] as String];
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
    final actual = observed.containsKey('value')
        ? observed['value']
        : observed['error'];
    if (!observed.containsKey('value') ||
        jsonEncode(actual) != jsonEncode(expected)) {
      failed = true;
      expectedFailures.add(
        '$id\n  expected: ${jsonEncode(expected)}\n  observed: '
        '${jsonEncode(actual)}',
      );
    }
  }
  if (expectedFailures.isNotEmpty) {
    stderr.writeln(
      'Corpus expectations differ:\n${expectedFailures.join('\n')}',
    );
  }

  final mismatches = <String>[];
  if (golden != null) {
    final goldenValues = <String, Object?>{
      for (final item in (golden['observations'] as List).cast<Map>())
        item['id'] as String: item.containsKey('value')
            ? item['value']
            : item['error'],
    };
    for (final item in observations) {
      final id = item['id'] as String;
      if (!goldenValues.containsKey(id)) {
        mismatches.add('$id: no frozen observation');
        continue;
      }
      final frozen = goldenValues[id];
      final observed = item.containsKey('value')
          ? item['value']
          : item['error'];
      if (jsonEncode(observed) != jsonEncode(frozen)) {
        mismatches.add(
          '$id: frozen=${jsonEncode(frozen)} windows=${jsonEncode(observed)}',
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
    'status': failed ? 'fail' : 'pass',
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
    stdout.writeln(
      'adapter corpus: ${failed ? 'fail' : 'pass'} '
      '(${report['cases']} cases, frozen golden '
      '${report['frozenGolden'] == 'not-run' ? 'not-run' : 'compared'})',
    );
    if (failed) exitCode = 1;
  } finally {
    NativeLibrary.dispose();
  }
}

/// Reads and validates one corpus before any rule runs. The legacy corpus is
/// admitted exactly as before (no fixture metadata); a metadata-bearing corpus
/// must name the one family this gate implements, and every row must be usable.
_HtmlCorpus _readHtmlCorpus(String path) {
  final bytes = File(path).readAsBytesSync();
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('HTML oracle corpus must be a JSON object');
  }
  final json = decoded;
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
    if (fixtureId != htmlListFixtureId ||
        corpusVersion != htmlListCorpusVersion) {
      throw FormatException(
        'Unknown HTML oracle corpus family: $fixtureId v$corpusVersion',
      );
    }
    if (json['schemaVersion'] != htmlOracleSchemaVersion) {
      throw const FormatException('Unsupported HTML-LIST-01 schemaVersion');
    }
    if (json['baselineCommit'] != htmlOracleBaselineCommit ||
        json['entryPoint'] != htmlOracleEntryPoint) {
      throw const FormatException(
        'HTML-LIST-01 baseline/entryPoint metadata does not match the oracle',
      );
    }
    family = (fixtureId: fixtureId, corpusVersion: corpusVersion);
    _validateHtmlListRows(json);
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
void _validateHtmlListRows(Map<String, dynamic> json) {
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
    final rule = entry['rule'];
    if (rule is! String || rule.isEmpty) {
      throw FormatException('HTML-LIST-01 case $id has no rule');
    }
    final method = entry['method'] ?? 'getString';
    if (!_htmlOracleMethods.contains(method)) {
      throw FormatException('HTML-LIST-01 case $id has unknown method');
    }
    final path = entry['path'];
    if (path != null && path != 'json') {
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

/// One metadata-bearing family's frozen rows: exactly one observation for each
/// declared unique id, with no missing, extra or duplicate id. Order is not a
/// fact, and an explicit null value is a value, not an absence.
void _validateGoldenObservationIds(
  List<Map> observations,
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
  }
  final declared = declaredIds.toSet();
  if (ids.length != declared.length || !ids.containsAll(declared)) {
    throw StateError(
      'Frozen golden observation ids differ from the declared corpus ids',
    );
  }
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
