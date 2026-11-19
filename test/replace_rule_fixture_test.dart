import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The #17 corpus is an input contract for the frozen Android instrumentation entry.
///
/// It intentionally has no expected values: a host reimplementation would not
/// be independent frozen evidence; device execution remains blocked on harness installation.
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

  test(
    'selected corpus preserves historical inputs under its own identity',
    () {
      final selected =
          jsonDecode(
                File(
                  'tool/replace_rule_oracle/fixtures-selected.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      expect(selected['fixtureId'], 'REPLACE-17');
      expect(selected['corpusVersion'], 2);
      expect(
        selected['baselineCommit'],
        'a7d37f1707a70a459ad708f4fe79341d1e42d716',
      );
      expect((selected['target'] as Map)['package'], 'com.legado.app.debug');
      expect((selected['deviceOracle'] as Map)['status'], 'not-run');
      expect(selected['comparisonBoundary'], fixture['comparisonBoundary']);
      expect(selected['cases'], fixture['cases']);
    },
  );

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
    expect(
      boundary,
      contains('includeTitle=false, including its paragraph shaping loop'),
    );
    expect((fixture['deviceOracle'] as Map)['status'], 'not-run');
    expect((fixture['deviceOracle'] as Map)['owner'], '#17');
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
