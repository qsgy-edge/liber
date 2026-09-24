import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/json_source_rules.dart';

/// The frozen comparison for the JSONPath row (filters and slices).
///
/// The golden is executed evidence from the frozen `AnalyzeByJSonPath.kt` and
/// `RuleAnalyzer.kt` at `14dd2494` on a host JVM (`tool/jsonpath_oracle/`),
/// running the frozen bytes against the same json-path 2.9.0 the file wraps
/// (pinned by `tool/jsonpath_probe/jars.sha256`). This test runs the product's
/// own field-text entry, `JsonSourceRules.extract`, over the same documents and
/// rules and compares the two.
///
/// The compared boundary is the frozen `getString`: the field text a JSON rule
/// carries into the stage output, including the `\n` join over the matches and
/// the container rendering (`tool/jsonpath_oracle/README.md` states both).
///
/// A corpus row with a `declared` block is one the capability matrix already
/// names — a refused operator, a refused path form, or the recorded divergence
/// where a definite slice over a non-array is a named `FormatException` and the
/// frozen reader's swallowed exception leaves an empty text. Those rows are
/// reported in `notCompared` with their expected and observed values; a declared
/// row that starts comparing is a failure here, so the declaration cannot rot.
///
/// Out of this corpus by definition, and named in the manifest: the frozen
/// *device* row (this is a host-JVM source execution), the failure shapes of the
/// declared rows themselves (only the refused text is frozen), and a number at
/// or above 1e7, where the JVM writes scientific notation and Dart a decimal.
void main() {
  const fixturesPath = 'tool/jsonpath_oracle/fixtures.json';
  const goldenPath = 'tool/jsonpath_oracle/evidence/jvm-host/golden.json';

  final fixtures = (jsonDecode(File(fixturesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final documents = (fixtures['documents'] as Map).cast<String, dynamic>();
  final cases = (fixtures['cases'] as List).cast<Map>();
  final golden = (jsonDecode(File(goldenPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();

  test('every case in the corpus has a golden row with a text and a read', () {
    expect(golden.keys.toSet(), {
      for (final c in cases) c['name'] as String,
    });
    for (final name in golden.keys) {
      expect(
        (golden[name] as Map).keys.toSet(),
        {'text', 'read'},
        reason: name,
      );
    }
  });

  test('the frozen corpus names its own provenance', () {
    expect(fixtures['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
    expect(
      (fixtures['library'] as Map)['artifact'],
      'com.jayway.jsonpath:json-path:2.9.0',
    );
    final sources = (fixtures['frozenSources'] as List).cast<Map>();
    expect(
      sources.map((s) => s['path']).whereType<String>(),
      containsAll(<String>[
        'app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt',
        'app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt',
      ]),
    );
  });

  test('the product matches the frozen field text, declared rows reported', () {
    final compared = <String>[];
    final notCompared = <String>[];
    final failures = <String>[];
    for (final c in cases) {
      final name = c['name'] as String;
      final rule = c['rule'] as String;
      final declared = c['declared'] as Map?;
      final row = (golden[name] as Map).cast<String, dynamic>();
      final expected = row['text'];
      final document = jsonDecode(documents[c['document']] as String);

      Object? actual;
      Object? refusal;
      try {
        actual = JsonSourceRules.extract(document, rule);
      } catch (error) {
        refusal = error;
      }
      final observed = refusal?.toString() ?? actual;

      if (declared == null) {
        if (refusal != null || observed != expected) {
          failures.add(
            '$name ($rule): expected ${jsonEncode(expected)}, '
            'observed ${jsonEncode(observed)}',
          );
        } else {
          compared.add(name);
        }
        continue;
      }
      if (refusal == null) {
        failures.add(
          '$name ($rule): declared ${declared['kind']} but the product now '
          'compares it (${jsonEncode(observed)})',
        );
      }
      notCompared.add(
        '$name (${declared['kind']}): expected ${jsonEncode(expected)}, '
        'observed ${jsonEncode(observed)} — ${declared['reason']}',
      );
    }

    // The report is the comparator's own verdict list: the rows it compared, the
    // rows it could not, and, by name and value, anything that differs.
    expect(failures, isEmpty, reason: failures.join('\n'));
    expect(
      notCompared,
      hasLength(
        cases.where((c) => c['declared'] != null).length,
      ),
      reason: notCompared.join('\n'),
    );
    expect(compared, hasLength(cases.length - notCompared.length));
    printOnFailure('notCompared:\n${notCompared.join('\n')}');
  });
}
