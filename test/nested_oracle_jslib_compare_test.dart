import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/nested_oracle_compare.dart';

/// Focused checks for the dedicated local jsLib shared-scope fixture and its
/// offline comparator (#74). Every value here is synthetic test data that
/// exercises the verdict mechanics; none of it is a frozen golden, and the
/// committed corpus is the only real fixture this file reads.
void main() {
  late Map<String, dynamic> corpus;
  late String corpusSha256;
  late List<Map<String, Object?>> observations;
  late List<String> requests;
  late Map<String, dynamic> golden;

  setUp(() {
    corpus = loadJsLibCorpus();
    corpusSha256 = jsLibCorpusSha256(File(jsLibCorpusPath));
    // Synthetic observations for comparator mechanics only; never evidence.
    observations = [
      for (final step in corpus['steps'] as List)
        {'id': (step as Map)['id'], 'value': '"observed"'},
    ];
    requests = ['GET /value/3', 'GET /value/undefined'];
    golden = <String, dynamic>{
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'corpusSha256': corpusSha256,
      'provenance': {
        'kind': 'frozen-device-capture',
        'deviceFingerprint':
            'Redmi/synthetic/synthetic:17/CP2A/OS:user/release-keys',
        'capturedAt': '2026-10-18T00:00:00+08:00',
        'entryPoint': corpus['entryPoint'],
      },
      'observations': jsonDecode(jsonEncode(observations)),
      'requests': jsonDecode(jsonEncode(requests)),
    };
  });

  Map<String, Object?> compare() => compareJsLib(
    corpus: corpus,
    corpusSha256: corpusSha256,
    golden: golden,
    observations: observations,
    requests: requests,
    goldenPath: 'synthetic-golden.json',
    library: 'synthetic-fjs.dll',
  );

  test('the corpus is a versioned, non-empty fixture with unique row ids', () {
    expect(corpus['schemaVersion'], 1);
    expect(corpus['fixtureId'], 'JSLIB-01');
    expect(corpus['corpusVersion'], 1);
    expect(corpus['baselineCommit'], isNotEmpty);
    expect(corpus['entryPoint'], isNotEmpty);
    expect(corpus['jsLib'], isNotEmpty);
    final steps = corpus['steps'] as List;
    expect(steps, isNotEmpty);
    final ids = [for (final step in steps) (step as Map)['id']];
    expect(ids.toSet().length, ids.length);
    expect(corpusSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('a genuine matching frozen capture passes', () {
    final report = compare();
    expect(report['status'], 'pass');
    expect(report['countMatches'], true);
    expect(report['requestsMatch'], true);
    expect(report['mismatches'], isEmpty);
  });

  test('a product-only record capture is refused as a golden', () {
    golden
      ..['mode'] = 'jslib-record'
      ..['comparison'] = 'not-run';
    expect(compare, throwsFormatException);
  });

  test('a missing or forged provenance block is refused', () {
    golden.remove('provenance');
    expect(compare, throwsFormatException);
    golden['provenance'] = {
      'kind': 'product-capture',
      'deviceFingerprint': 'synthetic',
      'capturedAt': '2026-10-18T00:00:00+08:00',
    };
    expect(compare, throwsFormatException);
  });

  test('a blank device fingerprint or capture time is refused', () {
    for (final key in ['deviceFingerprint', 'capturedAt']) {
      (golden['provenance'] as Map)[key] = '  ';
      expect(compare, throwsFormatException, reason: key);
      (golden['provenance'] as Map)[key] = 'synthetic';
    }
  });

  test('a stale corpus hash is refused', () {
    golden['corpusSha256'] = 'stale';
    expect(compare, throwsFormatException);
  });

  test('another baseline, version, fixture or entry point is refused', () {
    for (final entry in <String, Object?>{
      'baselineCommit': '0000000000000000000000000000000000000000',
      'corpusVersion': 999,
      'fixtureId': 'OTHER-01',
      'entryPoint': 'Something.else',
    }.entries) {
      final previous = golden[entry.key];
      golden[entry.key] = entry.value;
      expect(compare, throwsFormatException, reason: entry.key);
      golden[entry.key] = previous;
    }
  });

  test('row count, identity and duplicate rows are refused', () {
    final rows = golden['observations'] as List;
    rows.removeLast();
    expect(compare, throwsFormatException, reason: 'a missing row');
    rows.add(jsonDecode(jsonEncode(observations.last)));
    rows[0] = <String, Object?>{
      ...(rows[0] as Map).cast<String, Object?>(),
      'id': 'not-a-corpus-row',
    };
    expect(compare, throwsFormatException, reason: 'a wrong row identity');
  });

  test('an empty golden or product run cannot pass vacuously', () {
    golden['observations'] = <Object?>[];
    expect(compare, throwsFormatException, reason: 'empty golden rows');
    golden['observations'] = jsonDecode(jsonEncode(observations));
    golden['requests'] = <Object?>[];
    expect(compare, throwsFormatException, reason: 'empty golden requests');
    golden['requests'] = jsonDecode(jsonEncode(requests));
    expect(
      () => compareJsLib(
        corpus: corpus,
        corpusSha256: corpusSha256,
        golden: golden,
        observations: observations.sublist(1),
        requests: requests,
        goldenPath: 'synthetic-golden.json',
        library: 'synthetic-fjs.dll',
      ),
      throwsFormatException,
      reason: 'a short product run',
    );
  });

  test('a value mismatch fails rather than passing', () {
    observations[0] = <String, Object?>{
      ...observations[0],
      'value': '"different"',
    };
    final report = compare();
    expect(report['status'], 'fail');
    expect(report['mismatches'], isNotEmpty);
  });

  test('a request trace mismatch fails', () {
    final report = compareJsLib(
      corpus: corpus,
      corpusSha256: corpusSha256,
      golden: golden,
      observations: observations,
      requests: const ['GET /other'],
      goldenPath: 'synthetic-golden.json',
      library: 'synthetic-fjs.dll',
    );
    expect(report['status'], 'fail');
    expect(report['requestsMatch'], false);
  });
}
