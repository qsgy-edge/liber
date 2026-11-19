import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/nested_oracle_compare.dart';

Map<String, dynamic> _firstRequest(Map<String, Object?> row) =>
    ((row['requests'] as List).first as Map).cast<String, dynamic>();

List<dynamic> _requests(Map<String, Object?> row) => row['requests'] as List;

void main() {
  test('the committed request corpus and golden compare at 20 / 0 / 3', () {
    final corpus = loadRequestCorpus();
    final manifest = loadRequestManifest();
    final corpusIdentity = requestCorpusIdentity(
      File(requestCorpusPath),
      ((manifest['corpus'] as Map)['sha256']) as String,
    );
    final manifestSha256 = sha256File(File(requestManifestPath));
    final goldenFile = File(
      'tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json',
    );
    final goldenSha256 = sha256File(goldenFile);
    final golden =
        jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
    final observations = <Map<String, Object?>>[
      for (final raw in golden['rows'] as List)
        {
          'id': (raw as Map)['id'],
          'requests': jsonDecode(jsonEncode(raw['requests'])),
          'outcome': raw['outcome'],
          if (raw['status'] != null) 'status': raw['status'],
          if (raw['body'] != null) 'body': raw['body'],
          if (raw['error'] != null) 'error': raw['error'],
        },
    ];
    for (final observation in observations) {
      switch (observation['id']) {
        case 'defaults-user-agent-null':
          _firstRequest(observation)['headers']['user-agent'] =
              'Dart/3.12 (dart:io)';
        case 'redirect-cross-origin':
          (_requests(observation)[1] as Map)['headers'].remove('cookie');
        case 'query-exact-bytes':
          _firstRequest(observation)['rawQuery'] =
              'q=%7Ba%7D%7Cb%5Ec%60%5Cd%27e%20f%20%E4%B9%A6&p=1';
      }
    }

    expect(corpus['fixtureId'], 'REQUEST-01');
    expect((corpus['rows'] as List).length, 23);
    expect(corpusIdentity.matchesManifestPin, isTrue);

    final report = compareRequestRows(
      corpus: corpus,
      corpusIdentity: corpusIdentity,
      manifest: manifest,
      manifestSha256: manifestSha256,
      golden: golden,
      goldenSha256: goldenSha256,
      goldenPath: goldenFile.path,
      observations: observations,
      serverUnmatchedRequests: const [],
      serverErrors: const [],
      analysisErrors: const [],
    );
    expect(report['status'], 'pass');
    expect(report['failedRows'], isEmpty);
    expect(report['passedRows'], hasLength(20));
    expect(report['notComparedRows'], [
      'defaults-user-agent-null',
      'redirect-cross-origin',
      'query-exact-bytes',
    ]);
  });
}
