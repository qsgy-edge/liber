import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/export.dart';

import '../tool/first_slice_compare.dart';

/// The SLICE-01 row comparator's own rules: the contract's platform-generated
/// header ignore, the JSON-key-order rule, the corpus-hash pin, and the named
/// `notCompared` observations. The committed golden and Liber observation are the
/// inputs, so a rule that stops holding against real evidence fails here too.
void main() {
  late Map<String, dynamic> golden;
  late Map<String, dynamic> liber;
  late Map<String, dynamic> corpus;
  late String corpusSha256;
  late String manifestCorpusSha256;

  setUpAll(() {
    golden = _read('tool/first_slice/evidence/android-17-os4.0.0.31/golden.json');
    liber = _read('tool/first_slice/evidence/windows-slice-01.liber.json');
    corpus = _read('tool/first_slice/fixtures.json');
    corpusSha256 = _sha256(File('tool/first_slice/fixtures.json').readAsBytesSync());
    manifestCorpusSha256 =
        (_read('tool/first_slice/evidence/android-17-os4.0.0.31/manifest.json')['corpus']
            as Map)['sha256'] as String;
  });

  Map<String, Object?> compareWith({
    Map<String, dynamic>? corpusOverride,
    Map<String, dynamic>? liberOverride,
    String? shaOverride,
    String? manifestShaOverride,
  }) => compareSlice(
    golden: golden,
    liber: liberOverride ?? liber,
    goldenPath: 'golden.json',
    liberPath: 'liber.json',
    corpus: corpusOverride ?? corpus,
    corpusSha256: shaOverride ?? corpusSha256,
    manifestCorpusSha256: manifestShaOverride ?? manifestCorpusSha256,
  );

  test('R3 ignores the platform-generated headers the source does not set', () {
    // The frozen client sends `gzip, deflate` and the product sends `gzip`;
    // neither is source-set, so the contract discounts the difference and the
    // row passes. Without the ignore rule this row failed on six observations.
    final report = compareWith();
    expect(_row(report, 'R3')['status'], 'pass');
    expect(_row(report, 'R3')['differences'], isEmpty);
    final observations = _observations(report);
    expect(observations, contains('requests[].headers.accept-encoding'));
    expect(observations, contains('requests[].headers.host'));
    expect(observations, contains('requests[].headers.connection'));
  });

  test('R3 still compares a platform-generated header the source sets', () {
    // `Accept-Encoding` is only ignored because SLICE-01 leaves it to the
    // platform. A source that sets it owns its value and the row must fail on
    // the real frozen-vs-product difference.
    final modified = _deepCopy(corpus);
    final source = modified['source'] as Map<String, dynamic>;
    source['header'] = jsonEncode({
      ...(jsonDecode(source['header'] as String) as Map),
      'Accept-Encoding': 'identity',
    });
    final report = compareWith(corpusOverride: modified);
    expect(_row(report, 'R3')['status'], 'fail');
    expect(
      (_row(report, 'R3')['differences'] as List)
          .map((entry) => (entry as Map)['observation']),
      contains('requests[0].headers.accept-encoding'),
    );
  });

  test('R5 ignores JSON object key order inside a result object', () {
    final reordered = _deepCopy(liber);
    final results =
        ((reordered['stages'] as Map)['search'] as Map)['results'] as List;
    for (var index = 0; index < results.length; index++) {
      final result = (results[index] as Map).cast<String, dynamic>();
      results[index] = {
        for (final key in result.keys.toList().reversed) key: result[key],
      };
    }
    expect(
      jsonEncode(((reordered['stages'] as Map)['search'] as Map)['results']),
      isNot(jsonEncode(((liber['stages'] as Map)['search'] as Map)['results'])),
      reason: 'the key order has to actually differ for this to prove anything',
    );
    expect(_row(compareWith(liberOverride: reordered), 'R5')['status'], 'pass');
  });

  test('R5 still fails on a changed result value', () {
    final changed = _deepCopy(liber);
    final first = (((changed['stages'] as Map)['search'] as Map)['results'] as List)
        .first as Map;
    first['name'] = 'not the frozen name';
    final report = compareWith(liberOverride: changed);
    expect(_row(report, 'R5')['status'], 'fail');
  });

  test('the corpus bytes are pinned to the manifest and the observation', () {
    expect(() => compareWith(shaOverride: 'not-the-corpus'), throwsStateError);
    expect(
      () => compareWith(manifestShaOverride: 'not-the-pinned-corpus'),
      throwsStateError,
    );
  });

  test('notCompared names the Liber fields, the bodies and the teardown', () {
    final observations = _observations(compareWith());
    expect(observations, contains('requests[].body'));
    expect(
      observations,
      contains(
        'liber.scenario, liber.oracle, liber.fixturesPath/fixturesSha256, '
        'liber.libraryPath/librarySha256',
      ),
    );
    expect(observations, contains('state.*, cleanup.*, serverErrors'));
  });
}

Map<String, dynamic> _read(String path) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

Map<String, dynamic> _deepCopy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

Map _row(Map<String, Object?> report, String id) => (report['rows'] as List)
    .cast<Map>()
    .firstWhere((row) => row['id'] == id);

Set<Object?> _observations(Map<String, Object?> report) => {
  for (final entry in (report['notCompared'] as List).cast<Map>())
    entry['observation'],
};

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
