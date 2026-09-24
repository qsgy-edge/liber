import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replace_rule_oracle/compare.dart';

void main() {
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> committedReport;
  late List<Map<String, Object?>> product;
  late Map<String, dynamic> synthetic;
  setUp(() {
    fixture =
        jsonDecode(
              File('tool/replace_rule_oracle/fixtures.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    committedReport =
        jsonDecode(
              File(
                'tool/replace_rule_oracle/evidence/comparison.json',
              ).readAsStringSync(),
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
  test('the committed report still describes the committed corpus', () {
    // The committed evidence is a result record, not a golden (#70): it is
    // evidence *for the corpus it names*. Every branch of the guard is
    // exercised — a corpus edit that changes the row set, the row order, the
    // identity or the boundary, a stale pin, and a report that stops naming this
    // corpus — so none of them can silently leave the recorded run describing a
    // corpus that no longer exists.
    final corpusSha256 = sha256CrlfFile(
      File('tool/replace_rule_oracle/fixtures.json'),
    );
    checkReportMatchesFixture(
      fixture,
      committedReport,
      fixtureSha256: corpusSha256,
    );
    expect(committedReport['fixtureSha256'], corpusSha256);
    Map<String, dynamic> fixtureCopy(void Function(Map<String, dynamic>) edit) {
      final copy = jsonDecode(jsonEncode(fixture)) as Map<String, dynamic>;
      edit(copy);
      return copy;
    }

    Map<String, dynamic> reportCopy(void Function(Map<String, dynamic>) edit) {
      final copy =
          jsonDecode(jsonEncode(committedReport)) as Map<String, dynamic>;
      edit(copy);
      return copy;
    }

    final corpusEdits = <String, Map<String, dynamic>>{
      'a case removed': fixtureCopy(
        (copy) => (copy['cases'] as List).removeLast(),
      ),
      'two cases reordered': fixtureCopy((copy) {
        final cases = copy['cases'] as List;
        cases.insert(0, cases.removeAt(1));
      }),
      'another fixtureId': fixtureCopy(
        (copy) => copy['fixtureId'] = 'REPLACE-18',
      ),
      'another comparisonBoundary': fixtureCopy(
        (copy) => copy['comparisonBoundary'] = 'intermediate content',
      ),
    };
    for (final entry in corpusEdits.entries) {
      expect(
        () => checkReportMatchesFixture(
          entry.value,
          committedReport,
          fixtureSha256: corpusSha256,
        ),
        throwsFormatException,
        reason: entry.key,
      );
    }
    expect(
      () => checkReportMatchesFixture(
        fixture,
        committedReport,
        fixtureSha256: 'stale',
      ),
      throwsFormatException,
      reason: 'a stale corpus pin',
    );
    expect(
      () => checkReportMatchesFixture(
        fixture,
        reportCopy(
          (copy) => ((copy['rows'] as List).first as Map)['id'] = 'other',
        ),
        fixtureSha256: corpusSha256,
      ),
      throwsFormatException,
      reason: 'a report row that no longer names a corpus case',
    );
  });
  test('the committed report is refused as an input, not blamed on the corpus', () {
    // The ticket's repro fed evidence/comparison.json in as a golden. The
    // refusal has to name what the input is missing, not misattribute it to the
    // fixture.
    expect(
      () => compare(committedReport),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('Not a frozen golden'), contains('corpusVersion')),
        ),
      ),
      reason: 'no capture envelope at all',
    );
    Map<String, dynamic> withEnvelope([
      void Function(Map<String, dynamic>)? edit,
    ]) {
      final copy =
          jsonDecode(jsonEncode(committedReport)) as Map<String, dynamic>;
      copy.addAll({
        for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit'])
          key: fixture[key],
        'fixtureSha256': 'synthetic-test-hash',
        'boundary': fixture['comparisonBoundary'],
        'cleanup': {'databaseClosed': true, 'scratchRemoved': true},
      });
      edit?.call(copy);
      return copy;
    }

    // An envelope that is present but names another corpus is its own refusal.
    expect(
      () => compare(withEnvelope((copy) => copy['corpusVersion'] = 2)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('captured against another corpus'),
        ),
      ),
      reason: 'an envelope from another corpus',
    );
    // With the envelope repaired the rows still hold verdicts, and that gap is
    // named too instead of turning every frozen row into a silent not-run.
    expect(
      () => compare(withEnvelope()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('status is `pass`'),
        ),
      ),
      reason: 'verdict rows where a golden holds observations',
    );
  });
}
