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
          'notices': <String>[],
        },
    ];
    for (final id in ['js-error', 'js-timeout']) {
      product.singleWhere((row) => row['id'] == id)['notices'] = [
        'synthetic notice for comparator mechanics',
      ];
    }
    synthetic = {
      for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit'])
        key: fixture[key],
      'fixtureSha256': 'synthetic-test-hash',
      'boundary': fixture['comparisonBoundary'],
      'cleanup': {'databaseClosed': true, 'scratchRemoved': true},
      'rows': jsonDecode(jsonEncode(product)),
    };
    (synthetic['rows'] as List).last['timeoutObserved'] = true;
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
    for (final id in ['js-error', 'js-timeout']) {
      product[indexOf(id)].remove('notices');
    }
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

  test('rejects incomplete cleanup and a wrong boundary', () {
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': false};
    expect(() => compare(synthetic), throwsFormatException);
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': true};
    synthetic['boundary'] = 'intermediate content';
    expect(() => compare(synthetic), throwsFormatException);
  });

  test(
    'selection order, title and disabled rules stay strict observations',
    () {
      product[indexOf('js-ordering-with-literal')]['selection'] = {
        'title': <String>[],
        'content': ['stable-tie', 'later'],
      };
      product[indexOf('js-title-scope')]['title'] = 'wrong';
      product[indexOf('js-error')]['rulesDisabledByRun'] = ['js-error'];
      final result = compare(synthetic);
      expect((result['counts'] as Map)['fail'], 3);
    },
  );

  test('an exact match on a policy row is still notCompared, never pass', () {
    final result = compare(synthetic);
    final row = (result['rows'] as List)[indexOf('js-binding-surface')] as Map;
    expect(row['status'], 'pass');
    // The declaration stays, so a divergence that stops differing is visible
    // rather than silently promoted.
    final declared = (result['acceptedDivergences'] as List).cast<Map>();
    expect(
      declared.singleWhere(
        (entry) => entry['id'] == 'js-binding-surface',
      )['status'],
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
    synthetic['rows'][indexOf('js-timeout')]['rulesDisabledByRun'] = [
      'js-timeout',
    ];
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

  for (final id in ['js-error', 'js-timeout']) {
    for (final invalid in <Object?>[
      null,
      <String>[],
      'not a list',
      <Object?>[42],
      <String>[''],
      <String>[' \t\n'],
      <String>['synthetic notice', ' '],
    ]) {
      test(
        '$id rejects invalid product notice capture ${jsonEncode(invalid)}',
        () {
          product[indexOf(id)]['notices'] = invalid;
          final row = (compare(synthetic)['rows'] as List)[indexOf(id)] as Map;
          expect(row['status'], 'fail');
          expect(row['noticeCaptureIntegrity']['status'], 'fail');
          expect(row['noticeChannelComparison'], 'notCompared');
        },
      );
    }
    test('$id rejects a missing product notice capture', () {
      product[indexOf(id)].remove('notices');
      final row = (compare(synthetic)['rows'] as List)[indexOf(id)] as Map;
      expect(row['status'], 'fail');
    });
  }

  test(
    'timeout capture requires an observed frozen deadline before policy',
    () {
      for (final value in <Object?>[null, false, 'true']) {
        synthetic['rows'][indexOf('js-timeout')]['timeoutObserved'] = value;
        final row =
            (compare(synthetic)['rows'] as List)[indexOf('js-timeout')] as Map;
        expect(row['status'], 'fail');
        expect(row['noticeCaptureIntegrity']['status'], 'fail');
      }
    },
  );

  test('notice capture does not claim frozen channel or text equality', () {
    synthetic['rows'][indexOf('js-error')].remove('notices');
    final row =
        (compare(synthetic)['rows'] as List)[indexOf('js-error')] as Map;
    expect(row['status'], 'pass');
    expect(row['noticeCaptureIntegrity']['status'], 'pass');
    expect(row['noticeChannelComparison'], 'notCompared');
  });

  test('empty notices remain valid on ordinary and disabled rows', () {
    final result = compare(synthetic);
    for (final id in ['js-returned-text', 'js-disabled', 'backup-rule-1']) {
      final row = (result['rows'] as List)[indexOf(id)] as Map;
      expect(row['status'], 'pass');
      expect(row['productNotices'], isEmpty);
      expect(row['noticeCaptureIntegrity']['status'], 'notCompared');
    }
  });

  test(
    'unobserved frozen rows do not authorize a notice integrity verdict',
    () {
      for (final id in ['js-error', 'js-timeout']) {
        synthetic['rows'][indexOf(id)]['status'] = 'not-run';
        product[indexOf(id)].remove('notices');
        final row = (compare(synthetic)['rows'] as List)[indexOf(id)] as Map;
        expect(row['status'], 'not-run');
        expect(row['noticeCaptureIntegrity']['status'], 'not-run');
      }
    },
  );

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
