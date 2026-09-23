import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart';
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
///                                       `[<observations>]`
///
/// Without a frozen golden the run still checks the adapter against the corpus'
/// expectations, which were derived by reading the frozen rule layer at the
/// pinned commit. The committed device golden is
/// `tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json`; see
/// `tool/html_oracle/README.md`.
///
/// A case whose `path` is `rule` runs through the product's **rule-field path**
/// (`lib/source/rule_field.dart` in front of the adapter), because its frozen
/// entry point is `AnalyzeRule.getString` over a rule that carries an `@js:`
/// segment, and the bare adapter deliberately refuses those (ticket #11).
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 3) {
    throw ArgumentError(
      'Usage: <library> [<frozen golden.json>] [<observations.json>]',
    );
  }
  final output = args.length > 2 ? File(args[2]) : null;
  if (output != null && output.existsSync()) {
    throw StateError('Refusing to overwrite evidence: ${output.path}');
  }
  final corpus =
      jsonDecode(File('tool/html_oracle/fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final documents = (corpus['documents'] as Map).cast<String, String>();
  final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();

  final goldenPath = args.length > 1 && args[1] != '-' ? args[1] : null;
  final golden = goldenPath == null
      ? null
      : jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  if (golden != null) {
    if (golden['baselineCommit'] != corpus['baselineCommit'] ||
        golden['entryPoint'] != corpus['entryPoint']) {
      throw StateError('Oracle identity mismatch');
    }
  }

  await NativeLibrary.initialize(libraryPath: args[0]);
  final baseUrl = corpus['baseUrl'] as String? ?? '';
  final observations = <Map<String, Object?>>[];
  var failed = false;
  for (final entry in cases) {
    final id = entry['id'] as String;
    final rule = entry['rule'] as String;
    final method = entry['method'] as String? ?? 'getString';
    final html = documents[entry['document']] ?? '';
    final observation = <String, Object?>{'id': id, 'rule': rule};
    try {
      if (entry['path'] == 'rule') {
        observation['value'] = await _ruleFieldValue(
          html,
          rule,
          baseUrl: baseUrl,
        );
      } else if (entry['path'] == 'json') {
        final document = jsonDecode(html);
        if (method == 'getStringListUrl' || method == 'getStringList') {
          final values = JsonSourceRules.list(
            document,
            splitRuleFields(rule).rule,
          );
          if (values.isNotEmpty) {
            throw UnsupportedError(
              'The oracle corpus only compares empty URL lists',
            );
          }
          observation['value'] = <String>[];
        } else if (method == 'getString' || method == 'getStringUrl') {
          observation['value'] = JsonSourceRules.extract(document, rule);
        } else {
          throw UnsupportedError('Unknown oracle method: $method');
        }
      } else {
        final outcomes = htmlAnalyze(
          html: html,
          jobs: [
            HtmlRuleJob(
              id: id,
              rule: rule,
              parent: null,
              output: HtmlJobOutput.text,
            ),
          ],
        );
        final outcome = outcomes.single;
        final failure = outcome.failure;
        if (failure != null) {
          observation['error'] = '${failure.kind}: ${failure.message}';
        } else if (method == 'getStringListUrl' || method == 'getStringList') {
          if (outcome.count != 0) {
            throw UnsupportedError(
              'The oracle corpus only compares empty URL lists',
            );
          }
          observation['value'] = <String>[];
        } else if (method == 'getStringUrl' && outcome.count == 0) {
          observation['value'] = applyRuleReplacement(
            '',
            splitRuleFields(rule),
            label: 'HTML',
          );
        } else if (method == 'getString' || method == 'getStringUrl') {
          observation['value'] = outcome.values.firstOrNull ?? '';
        } else {
          throw UnsupportedError('Unknown oracle method: $method');
        }
      }
    } catch (error) {
      observation['error'] = '$error';
    }
    observations.add(observation);
  }

  final expectedFailures = <String>[];
  for (final entry in cases) {
    final id = entry['id'] as String;
    final expected = entry['expected'];
    final observed = observations.firstWhere((item) => item['id'] == id);
    if (expected == null) continue;
    if (!observed.containsKey('value') ||
        jsonEncode(observed['value']) != jsonEncode(expected)) {
      failed = true;
      expectedFailures.add(
        '$id\n  expected: ${jsonEncode(expected)}\n  observed: '
        '${jsonEncode(observed['value'] ?? observed['error'])}',
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
        item['id'] as String: item['value'] ?? item['error'],
    };
    for (final item in observations) {
      final id = item['id'] as String;
      final frozen = goldenValues[id];
      if (frozen == null) {
        mismatches.add('$id: no frozen observation');
        continue;
      }
      final observed = item['value'] ?? item['error'];
      if (jsonEncode(observed) != jsonEncode(frozen)) {
        mismatches.add(
          '$id: frozen=${jsonEncode(frozen)} windows=${jsonEncode(observed)}',
        );
      }
    }
    if (mismatches.isNotEmpty) failed = true;
  }

  final library = File(args[0]);
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'status': failed ? 'fail' : 'pass',
    'frozenGolden': goldenPath ?? 'not-run',
    'librarySha256': library.existsSync()
        ? _sha256(library.readAsBytesSync())
        : 'unknown',
    'fixturesSha256': _sha256(
      File('tool/html_oracle/fixtures.json').readAsBytesSync(),
    ),
    'cases': cases.length,
    'observations': observations,
    'expectationMismatches': expectedFailures,
    'frozenMismatches': mismatches,
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  if (output != null) {
    output.writeAsStringSync('$encoded\n');
    stdout.writeln('Wrote ${output.path}');
  } else {
    stdout.writeln(encoded);
  }
  NativeLibrary.dispose();
  stdout.writeln(
    'adapter corpus: ${failed ? 'fail' : 'pass'} '
    '(${cases.length} cases, frozen golden ${golden == null ? 'not-run' : 'compared'})',
  );
  if (failed) exitCode = 1;
}

/// One rule-field case through the product's own path: the shared
/// `@js:`/`<js>`/`{{...}}`/`@get:`/`@put:` layer in front of the Rust adapter,
/// which is what a pipeline stage runs and what the frozen `AnalyzeRule.getString`
/// answers. `@get:`/`@put:` read and write an empty source key's variables, the
/// way one analysis owns them.
Future<String> _ruleFieldValue(
  String html,
  String rule, {
  required String baseUrl,
}) async {
  const sourceRef = 'tool/html_adapter_gate';
  final state = SourceHostState();
  final runtime = InProcessSourceScriptRuntime(hostState: state);
  final context = RuleFieldContext(
    evaluateScript: (script, result) => runtime.evaluate(
      source: script,
      input: {
        'sourceKey': sourceRef,
        'baseUrl': baseUrl,
        'result': result,
        'title': null,
      },
      timeout: const Duration(seconds: 15),
    ),
    extract: (value, valueRule) async {
      final batch = HtmlRuleBatch('$value');
      final job = batch.documentText('value', valueRule);
      await batch.run();
      final extracted = job.value;
      return extracted.isEmpty ? null : extracted;
    },
    readVariable: (key) async {
      final value = await state.entry(
        sourceRef,
        sourceRuleVariableKey(sourceRef, key),
      );
      return value is String ? value : '';
    },
    writeVariable: (key, value) =>
        state.putEntry(sourceRef, sourceRuleVariableKey(sourceRef, key), value),
  );
  final field = await RuleField.resolve(rule, context, content: html);
  final Object? extracted;
  if (field.isScriptOnly) {
    extracted = html;
  } else {
    final batch = HtmlRuleBatch(html);
    final job = batch.documentText('value', field.extractionRule!);
    await batch.run();
    extracted = job.value;
  }
  return '${await field.apply(extracted) ?? ''}';
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
