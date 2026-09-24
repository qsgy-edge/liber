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
  const manifestPath =
      'tool/jsonpath_oracle/evidence/jvm-host/manifest.json';

  final fixtures = (jsonDecode(File(fixturesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final documents = (fixtures['documents'] as Map).cast<String, dynamic>();
  final cases = (fixtures['cases'] as List).cast<Map>();
  final golden = (jsonDecode(File(goldenPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final manifest =
      (jsonDecode(File(manifestPath).readAsStringSync()) as Map)
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

  test('the manifest copies the golden, and the corpus, without drifting', () {
    // The committed comparator report is a copy of two other files, so it is
    // checked rather than trusted: a later corpus edit that forgets the manifest
    // fails here instead of leaving stale evidence on the ticket.
    final declared = cases.where((c) => c['declared'] != null).toList();
    final reported = (manifest['notCompared'] as List).cast<Map>();
    expect(
      reported.map((r) => r['name']).toList(),
      declared.map((c) => c['name']).toList(),
      reason: 'manifest.notCompared must list the corpus\'s declared rows',
    );
    for (final c in declared) {
      final entry = reported.singleWhere((r) => r['name'] == c['name']);
      final row = (golden[c['name']] as Map).cast<String, dynamic>();
      final declaration = (c['declared'] as Map).cast<String, dynamic>();
      expect(entry['rule'], c['rule'], reason: c['name'] as String);
      expect(entry['kind'], declaration['kind'], reason: c['name'] as String);
      expect(entry['reason'], declaration['reason'], reason: c['name'] as String);
      expect(entry['frozenText'], row['text'], reason: c['name'] as String);
      expect(entry['frozenRead'], row['read'], reason: c['name'] as String);
    }
    expect(manifest['compared'], cases.length - declared.length);
    expect(manifest['baseline'], fixtures['baseline']);
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
      final expectedRefusal = _refusalFor[declared['kind']];
      if (refusal == null) {
        failures.add(
          '$name ($rule): declared ${declared['kind']} but the product now '
          'compares it (${jsonEncode(observed)})',
        );
      } else if (expectedRefusal == null) {
        failures.add(
          '$name ($rule): declared kind ${declared['kind']} has no refusal '
          'type in _refusalFor',
        );
      } else if (!expectedRefusal.matches(refusal, {})) {
        failures.add(
          '$name ($rule): declared ${declared['kind']} refused with '
          '${refusal.runtimeType}, expected $expectedRefusal',
        );
      }
      notCompared.add(
        '$name (${declared['kind']}): expected ${jsonEncode(expected)}, '
        'observed ${jsonEncode(observed)} — ${declared['reason']}',
      );
    }

    // The report is the comparator's own verdict list: the rows it compared, the
    // rows it could not, and, by name and value, anything that differs. It goes
    // to stdout because a `notCompared` row is the harness's observation, not a
    // hidden skip (the contract's wording), and to failures so a red run names
    // the values.
    stdout.writeln('jsonpath compared: ${compared.length}');
    for (final line in notCompared) {
      stdout.writeln('jsonpath notCompared: $line');
    }
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

/// The refusal each declared kind must produce, so a row that starts failing a
/// different way is not quietly accepted into `notCompared`.
///
/// `failed-read-shape` is the matrix's recorded divergence — a definite slice
/// over a non-array or a null is a named `FormatException` where the frozen
/// reader's swallowed exception leaves an empty text. Every other kind is one of
/// the forms this reader refuses by name, which is an `UnsupportedError`.
const _refusalFor = <String, Matcher>{
  'failed-read-shape': TypeMatcher<FormatException>(),
  'scan-element-index': TypeMatcher<UnsupportedError>(),
  'operator-not-run': TypeMatcher<UnsupportedError>(),
  'unsupported-path-form': TypeMatcher<UnsupportedError>(),
  'refused-by-both': TypeMatcher<UnsupportedError>(),
};
