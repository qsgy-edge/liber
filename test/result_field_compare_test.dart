import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import '../tool/result_field_compare.dart';

void main() {
  late Map<String, dynamic> golden;
  late Map<String, dynamic> liber;
  late Map<String, dynamic> corpus;
  late String corpusSha256;
  late String manifestCorpusSha256;

  setUpAll(() {
    golden = _read(
      'tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json',
    );
    liber = _read(
      'tool/result_field_oracle/evidence/windows-fields-01.liber.json',
    );
    corpus = _read('tool/result_field_oracle/fixtures.json');
    corpusSha256 = _sha256(
      File('tool/result_field_oracle/fixtures.json').readAsBytesSync(),
    );
    manifestCorpusSha256 =
        (_read(
                  'tool/result_field_oracle/evidence/android-17-os4.0.0.31/'
                  'manifest.json',
                )['corpus']
                as Map)['sha256']
            as String;
  });

  Map<String, Object?> compareWith({
    Map<String, dynamic>? goldenOverride,
    Map<String, dynamic>? liberOverride,
  }) => compareResultFields(
    golden: goldenOverride ?? golden,
    liber: liberOverride ?? liber,
    goldenPath: 'golden.json',
    liberPath: 'liber.json',
    corpus: corpus,
    corpusSha256: corpusSha256,
    manifestCorpusSha256: manifestCorpusSha256,
  );

  test('the corpus row and all seven field rows pass on committed evidence', () {
    final report = compareWith();
    for (final id in ['C1', 'F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7']) {
      expect(_row(report, id)['status'], 'pass', reason: id);
      expect(_row(report, id)['differences'], isEmpty, reason: id);
    }
    expect(_row(report, 'C1')['detail'], contains('20 declared requests'));
  });

  test('F4 passes on the frozen parse-layer scalar coercion', () {
    expect((golden['checkKeyword'] as Map)['number'], {
      'outcome': 'value',
      'value': '42',
    });
    expect((liber['checkKeyword'] as Map)['number'], {
      'outcome': 'value',
      'value': '42',
    });
    final row = _row(compareWith(), 'F4');
    expect(row['status'], 'pass');
    expect(row['differences'], isEmpty);
  });

  test('F4 treats the malformed object as refused on both sides', () {
    final detail = _row(compareWith(), 'F4')['detail'] as String;
    expect(
      detail,
      contains('object (frozen: com.google.gson.JsonSyntaxException'),
    );
    expect(detail, contains('product: FormatException'));
  });

  test('notCompared names the content text, the headers and the teardown', () {
    final observations = {
      for (final entry in (compareWith()['notCompared'] as List).cast<Map>())
        entry['observation'],
    };
    expect(observations, contains('cases.<id>.chapter.text'));
    expect(observations, contains('requests[].headers.*, requests[].body'));
    expect(observations, contains('state.*, cleanup.*, serverErrors'));
  });
}

Map<String, dynamic> _read(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

Map _row(Map<String, Object?> report, String id) =>
    (report['rows'] as List).cast<Map>().firstWhere((row) => row['id'] == id);

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
