import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replace_rule_oracle/compare.dart';

void main() {
  late Map<String, dynamic> fixture;
  late List<Map<String, Object?>> product;
  late Map<String, dynamic> synthetic;
  setUp(() {
    fixture =
        jsonDecode(
              File('tool/replace_rule_oracle/fixtures.json').readAsStringSync(),
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

  test('missing frozen evidence leaves every row not-run', () {
    final result = compare(null);
    expect(result['counts'], {
      'pass': 0,
      'fail': 0,
      'notCompared': 0,
      'not-run': 15,
    });
    expect(result['complete'], false);
    final timeout = (result['rows'] as List).cast<Map>().singleWhere(
      (row) => row['id'] == 'timeout',
    );
    expect(timeout['comparison'], 'notCompared');
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
  test(
    'rejects stale fixture hashes, missing, duplicate and reordered rows',
    () {
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
    },
  );
  test('rejects incomplete cleanup and wrong boundary', () {
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': false};
    expect(() => compare(synthetic), throwsFormatException);
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': true};
    synthetic['boundary'] = 'intermediate content';
    expect(() => compare(synthetic), throwsFormatException);
  });
  test('selection order and title remain strict observations', () {
    product[8]['selection'] = {
      'title': <String>[],
      'content': ['stable-tie', 'later'],
    };
    product[2]['title'] = 'wrong';
    final result = compare(synthetic);
    expect((result['counts'] as Map)['fail'], 2);
  });
  test('conversion policy does not silently accept arbitrary differences', () {
    product[11]['content'] = 'different';
    final result = compare(synthetic);
    expect(((result['rows'] as List)[11] as Map)['status'], 'fail');
  });
  test('policy rows preserve both exact outputs and timeout coverage gap', () {
    product.last['content'] = 'unsupported-pattern-retained';
    final result = compare(synthetic);
    final row = (result['rows'] as List).last as Map;
    expect(row['status'], 'notCompared');
    expect((row['differences'] as List).single['frozen'], '　　body');
    expect(result['complete'], false);
  });
  test('product errors cannot be promoted by equal fields', () {
    product.first['status'] = 'error';
    expect(
      ((compare(synthetic)['rows'] as List).first as Map)['status'],
      'fail',
    );
  });
}
