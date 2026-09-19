import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The #17 corpus is an input contract for the future frozen Android entry.
///
/// It intentionally has no expected values: a host reimplementation would not
/// be independent frozen evidence, and the shared device entry belongs to #38.
/// This test protects row coverage and the processed-stage comparison boundary
/// without turning fixture prose into a compatibility verdict.
void main() {
  late Map<String, dynamic> fixture;

  setUpAll(() {
    fixture =
        (jsonDecode(
                  File(
                    'tool/replace_rule_oracle/fixtures.json',
                  ).readAsStringSync(),
                )
                as Map)
            .cast<String, dynamic>();
  });

  test('pins the frozen identity and leaves the Android row not-run', () {
    expect(fixture['fixtureId'], 'REPLACE-17');
    expect(
      fixture['baselineCommit'],
      '14dd24945b2914ce2708b8abaa4ee67ceef892af',
    );
    expect(
      fixture['entryPoint'],
      'ContentProcessor.getContent + BookChapter.getDisplayTitle',
    );
    final boundary = fixture['comparisonBoundary'] as String;
    expect(boundary, contains('before its final paragraph shaping loop'));
    expect((fixture['deviceOracle'] as Map)['status'], 'not-run');
    expect((fixture['deviceOracle'] as Map)['owner'], '#38');
  });

  test('contains each requested replace-rule row without expected output', () {
    final cases = (fixture['cases'] as List).cast<Map>();
    final ids = {for (final row in cases) row['id'] as String};
    expect(ids, {
      'no-rules',
      'content-only',
      'title-only',
      'both',
      'regex',
      'literal',
      'scope-name-origin',
      'exclude-scope-name-origin',
      'ordering',
      'duplicated-title',
      're-segment-interaction',
      'conversion-t2s',
      'conversion-s2t',
      'timeout',
      'refusal',
    });
    for (final row in cases) {
      expect(row['status'], 'not-run', reason: row['id'] as String);
      expect(row.containsKey('expected'), isFalse, reason: row['id'] as String);
      expect(row.containsKey('golden'), isFalse, reason: row['id'] as String);
      expect(row['rules'], isA<List>(), reason: row['id'] as String);
      expect(row['observations'], isA<List>(), reason: row['id'] as String);
    }
    final timeout = cases.singleWhere((row) => row['id'] == 'timeout');
    expect(timeout['comparison'], 'notCompared');
    expect(timeout['notComparedReason'], contains('restart'));
  });
}
