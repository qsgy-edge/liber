import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The REPLACE-JS-01 corpus is an input contract for the frozen Android
/// instrumentation entry (`tool/replace_js_oracle/ReplaceJsOracle.java`).
///
/// It intentionally has no expected output values: a host reimplementation
/// would not be independent frozen evidence. This test protects row coverage,
/// the executed provenance pins of the operator backup, and the declaration of
/// the two accepted divergences — without turning fixture prose into a
/// compatibility verdict.
void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture =
        (jsonDecode(
                  File(
                    'tool/replace_js_oracle/fixtures.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, dynamic>();
  });

  test('pins the frozen identity and the compared boundary', () {
    expect(fixture['fixtureId'], 'REPLACE-JS-01');
    expect(fixture['corpusVersion'], 1);
    expect(
      fixture['baselineCommit'],
      '14dd24945b2914ce2708b8abaa4ee67ceef892af',
    );
    expect(
      fixture['entryPoint'],
      'ContentProcessor.getContent + BookChapter.getDisplayTitle',
    );
    expect(fixture['comparisonBoundary'], contains('paragraph shaping loop'));
    expect(
      fixture['comparisonBoundary'],
      contains('Matcher.quoteReplacement'),
    );
    final sources = (fixture['frozenSources'] as List).cast<Map>();
    expect(
      sources.singleWhere(
        (source) => (source['path'] as String).endsWith('RegexExtensions.kt'),
      )['sha1'],
      '065ae15a1ef3d38492b9fed4d89edd9c635ded81',
    );
    expect(
      sources.singleWhere(
        (source) => (source['path'] as String).endsWith('ContentProcessor.kt'),
      )['sha1'],
      '71be4ab155eac68a1a4ea72d49c2efdca6cebe1d',
    );
  });

  test('contains each requested @js: row without an expected output', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final ids = [for (final row in cases) row['id'] as String];
    expect(ids, [
      'js-returned-text',
      'js-title-scope',
      'js-match-and-capture',
      'js-binding-surface',
      'js-ordering-with-literal',
      'js-literal-branch-prefix',
      'js-disabled',
      'js-error',
      'backup-rule-1',
      'backup-rule-2',
      'backup-rule-3',
      'backup-rule-4',
      'js-timeout',
    ]);
    for (final row in cases) {
      expect(row['status'], 'not-run', reason: row['id'] as String);
      expect(row.containsKey('expected'), isFalse, reason: row['id'] as String);
      expect(row.containsKey('golden'), isFalse, reason: row['id'] as String);
      expect(row['rules'], isA<List>(), reason: row['id'] as String);
      expect(row['observations'], isA<List>(), reason: row['id'] as String);
      for (final rule in (row['rules'] as List).cast<Map>()) {
        expect(rule['pattern'], isNotNull, reason: row['id'] as String);
        expect(rule['replacement'], isNotNull, reason: row['id'] as String);
        expect(rule['isRegex'], isA<bool>(), reason: row['id'] as String);
      }
    }
  });

  test('the capture row declares the bindings and the insertion it observes', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final capture = cases.singleWhere((row) => row['id'] == 'js-match-and-capture');
    expect(capture['observations'], contains('complete-match-as-result'));
    expect(capture['observations'], contains('dollar-expansion-refused'));
    expect(capture['observations'], contains('backslash-inserted-literally'));
    final replacement =
        ((capture['rules'] as List).single as Map)['replacement'] as String;
    expect(replacement, startsWith('@js:'));
    expect(replacement, contains(r'result.match'));
    // The script returns the literal dollar and backslash sequences; nothing in
    // the corpus asks the host to expand them.
    expect(replacement, contains(r'$1'));
    expect(replacement, contains(r'${name}'));
  });

  test('the literal rows stay on both branches of the @js: check', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final ordering = cases.singleWhere(
      (row) => row['id'] == 'js-ordering-with-literal',
    );
    final orderingRules = (ordering['rules'] as List).cast<Map>();
    expect(
      [for (final rule in orderingRules) rule['isRegex']],
      [false, true, false],
      reason: 'a literal rule, an @js: rule and a literal rule in sortOrder',
    );
    expect(
      [for (final rule in orderingRules) rule['sortOrder']],
      [1, 2, 3],
    );
    final prefix = cases.singleWhere(
      (row) => row['id'] == 'js-literal-branch-prefix',
    );
    final prefixRule = (prefix['rules'] as List).single as Map;
    expect(prefixRule['isRegex'], false);
    expect(prefixRule['replacement'], '@js:"X"');
  });

  test('the disabled, error and timeout rows are declared', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final disabled = cases.singleWhere((row) => row['id'] == 'js-disabled');
    expect(
      ((disabled['rules'] as List).single as Map)['isEnabled'],
      false,
    );
    final error = cases.singleWhere((row) => row['id'] == 'js-error');
    expect(
      ((error['rules'] as List).single as Map)['replacement'],
      '@js:throw new Error("boom")',
    );
    // The timeout row runs last: the frozen worker may outlive its deadline.
    expect(cases.last['id'], 'js-timeout');
    expect(cases.last['comparison'], 'notCompared');
    expect(cases.last['policy'], contains('restart'));
    expect(
      ((cases.last['rules'] as List).single as Map)['timeoutMillisecond'],
      200,
    );
  });

  test('the four operator backup rules are carried verbatim and disabled', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final backup = cases
        .where((row) => (row['id'] as String).startsWith('backup-rule-'))
        .toList();
    expect(backup, hasLength(4));
    expect(
      [for (final row in backup) (row['backupRule'] as Map)['id']],
      [1, 2, 3, 4],
    );
    for (final row in backup) {
      final original = row['backupRule'] as Map;
      final seeded = (row['rules'] as List).single as Map;
      expect(original['isEnabled'], false, reason: row['id'] as String);
      expect(row['recordedOutcome'], 'disabled; replacement not executed');
      expect(seeded['isEnabled'], false);
      expect(seeded['pattern'], original['pattern']);
      expect(seeded['replacement'], original['replacement']);
      expect(seeded['name'], original['name']);
      expect(seeded['scopeTitle'], original['scopeTitle']);
      expect(seeded['scopeContent'], original['scopeContent']);
      expect(
        (seeded['replacement'] as String),
        startsWith('@js:'),
      );
    }
    expect((backup.first['backupRule'] as Map)['scopeTitle'], true);
    expect((backup.first['backupRule'] as Map)['scopeContent'], false);
  });

  test('pins the operator backup bytes the four rules came from', () {
    final source = fixture['backupSource'] as Map;
    expect(source['name'], 'legado-backup-2026-09-17.zip');
    expect(
      source['sha256'],
      'e46452c9b824d41c1333bb58965a7709041c0b46b3fa2ff11372d7b3e4c1abb8',
    );
    expect(source['entry'], 'replaceRule.json');
    expect(
      source['entrySha256'],
      '19bb7f6e2b82d810f345e099ccee2121560d9eb57f17b7191614b0ae80158dbc',
    );
    expect(source['ruleCount'], 129);
    expect(source['jsRuleIds'], [1, 2, 3, 4]);
    expect(
      source['jsRuleRecordedOutcome'],
      'disabled; replacement not executed',
    );
  });

  test('declares its accepted divergences against real rows', () {
    final ids = {
      for (final row in (fixture['cases'] as List).cast<Map>())
        row['id'] as String,
    };
    final divergences = (fixture['acceptedDivergences'] as List).cast<Map>();
    expect(
      [for (final row in divergences) row['id']],
      ['js-timeout', 'js-binding-surface', 'js-error'],
    );
    for (final row in divergences) {
      expect(ids, contains(row['id']));
      expect(row['summary'], isNotEmpty);
    }
    expect(
      (fixture['cases'] as List).cast<Map>().singleWhere(
        (row) => row['id'] == 'js-binding-surface',
      )['comparison'],
      'notCompared',
    );
  });
}
