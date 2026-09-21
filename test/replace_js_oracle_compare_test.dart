import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replace_js_oracle/compare.dart';

void main() {
  late Map<String, dynamic> fixture;
  late List<Map<String, Object?>> product;
  late Map<String, dynamic> synthetic;
  setUp(() {
    fixture =
        jsonDecode(
              File('tool/replace_js_oracle/fixtures.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    // Synthetic values test verdict mechanics only; never frozen evidence.
    product = [
      for (final row in fixture['cases'] as List)
        {
          'id': row['id'],
          'status': 'observed',
          'title': 'title',
          'content': '　　body',
          'selection': {'title': <String>[], 'content': <String>[]},
          'rulesDisabledByRun': <String>[],
        },
    ];
    synthetic = {
      for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit'])
        key: fixture[key],
      'fixtureSha256': 'synthetic-test-hash',
      'boundary': fixture['comparisonBoundary'],
      'cleanup': {'databaseClosed': true, 'scratchRemoved': true},
      'rows': jsonDecode(jsonEncode(product)),
    };
  });
  Map<String, Object?> compare(Map<String, dynamic>? golden) => compareRows(
    fixture,
    product,
    golden,
    fixtureSha256: 'synthetic-test-hash',
  );
  int indexOf(String id) =>
      (fixture['cases'] as List).indexWhere((row) => row['id'] == id);

  test('missing frozen evidence leaves every row not-run', () {
    final result = compare(null);
    expect(result['counts'], {
      'pass': 0,
      'fail': 0,
      'notCompared': 0,
      'not-run': 13,
    });
    expect(result['complete'], false);
    final timeout = (result['rows'] as List).cast<Map>().singleWhere(
      (row) => row['id'] == 'js-timeout',
    );
    expect(timeout['timeoutCoverage'], startsWith('not-run'));
  });

  test('does not trim indent or drop blank lines to hide a mismatch', () {
    product.first['content'] = 'body\n\n';
    final result = compare(synthetic);
    final row = (result['rows'] as List).first as Map;
    expect(row['status'], 'fail');
    expect(row['differences'], [
      {'field': 'content', 'frozen': '　　body', 'product': 'body\n\n'},
    ]);
  });

  test('rejects stale fixture hashes, missing, duplicate and reordered rows', () {
    synthetic['fixtureSha256'] = 'stale';
    expect(() => compare(synthetic), throwsFormatException);
    synthetic['fixtureSha256'] = 'synthetic-test-hash';
    final rows = synthetic['rows'] as List;
    final first = rows.removeAt(0);
    expect(() => compare(synthetic), throwsFormatException);
    rows.insert(0, rows.first);
    expect(() => compare(synthetic), throwsFormatException);
    rows[0] = first;
    final second = rows[1];
    rows[1] = rows[0];
    rows[0] = second;
    expect(() => compare(synthetic), throwsFormatException);
  });

  test('rejects incomplete cleanup and a wrong boundary', () {
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': false};
    expect(() => compare(synthetic), throwsFormatException);
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': true};
    synthetic['boundary'] = 'intermediate content';
    expect(() => compare(synthetic), throwsFormatException);
  });

  test('selection order, title and disabled rules stay strict observations', () {
    product[indexOf('js-ordering-with-literal')]['selection'] = {
      'title': <String>[],
      'content': ['stable-tie', 'later'],
    };
    product[indexOf('js-title-scope')]['title'] = 'wrong';
    product[indexOf('js-error')]['rulesDisabledByRun'] = ['js-error'];
    final result = compare(synthetic);
    expect((result['counts'] as Map)['fail'], 3);
  });

  test('an exact match on a policy row is still notCompared, never pass', () {
    final result = compare(synthetic);
    final row = (result['rows'] as List)[indexOf('js-binding-surface')] as Map;
    expect(row['status'], 'pass');
    // The declaration stays, so a divergence that stops differing is visible
    // rather than silently promoted.
    final declared = (result['acceptedDivergences'] as List).cast<Map>();
    expect(
      declared.singleWhere((entry) => entry['id'] == 'js-binding-surface')['status'],
      'pass',
    );
    final timeout = (result['rows'] as List)[indexOf('js-timeout')] as Map;
    expect(timeout['status'], 'notCompared');
  });

  test('policy rows preserve both exact outputs and the timeout gap', () {
    product[indexOf('js-binding-surface')]['content'] = 'frozen-only';
    final result = compare(synthetic);
    final row = (result['rows'] as List)[indexOf('js-binding-surface')] as Map;
    expect(row['status'], 'notCompared');
    expect((row['differences'] as List).single['frozen'], '　　body');
    expect(row['policy'], contains('approved source script facade'));
    expect(result['complete'], false);
  });

  test('the timeout row carries both sides and reports its coverage', () {
    product[indexOf('js-timeout')]['content'] = 'product-keeps-text';
    product[indexOf('js-timeout')]['rulesDisabledByRun'] = ['js-timeout'];
    synthetic['rows'][indexOf('js-timeout')]['content'] = 'js-timeoutException';
    synthetic['rows'][indexOf('js-timeout')]['rulesDisabledByRun'] = ['js-timeout'];
    synthetic['rows'][indexOf('js-timeout')]['timeoutObserved'] = true;
    final result = compare(synthetic);
    final row = (result['rows'] as List)[indexOf('js-timeout')] as Map;
    expect(row['status'], 'notCompared');
    expect(row['differences'], [
      {
        'field': 'content',
        'frozen': 'js-timeoutException',
        'product': 'product-keeps-text',
      },
    ]);
    expect(row['timeoutObserved'], true);
    expect(row['timeoutCoverage'], startsWith('observed'));
    expect(row['restartObservation'], 'not-run');
  });

  test('a timed-out row still records both rule-state values', () {
    product[indexOf('js-timeout')]['rulesDisabledByRun'] = <String>[];
    synthetic['rows'][indexOf('js-timeout')]['rulesDisabledByRun'] = [
      'js-timeout',
    ];
    final row =
        (compare(synthetic)['rows'] as List)[indexOf('js-timeout')] as Map;
    expect(row['status'], 'notCompared');
    expect(row['differences'], [
      {
        'field': 'rulesDisabledByRun',
        'frozen': ['js-timeout'],
        'product': <String>[],
      },
    ]);
  });

  test('a product error cannot be promoted by equal fields', () {
    product.first['status'] = 'error';
    expect(
      ((compare(synthetic)['rows'] as List).first as Map)['status'],
      'fail',
    );
  });

  test('an unreviewed difference on a non-policy row fails', () {
    product[indexOf('js-match-and-capture')]['content'] = 'other';
    final result = compare(synthetic);
    final row =
        (result['rows'] as List)[indexOf('js-match-and-capture')] as Map;
    expect(row['status'], 'fail');
    expect(row['policy'], isNull);
    expect((result['counts'] as Map)['fail'], 1);
  });
}
