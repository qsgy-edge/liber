import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replace_rule_oracle/compare.dart';

void main() {
  test('the committed report still describes the committed corpus', () {
    final fixture =
        jsonDecode(
              File('tool/replace_rule_oracle/fixtures.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final committedReport =
        jsonDecode(
              File(
                'tool/replace_rule_oracle/evidence/comparison.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final corpusSha256 = sha256CrlfFile(
      File('tool/replace_rule_oracle/fixtures.json'),
    );
    checkReportMatchesFixture(
      fixture,
      committedReport,
      fixtureSha256: corpusSha256,
    );
    expect(committedReport['fixtureSha256'], corpusSha256);
  });
}
