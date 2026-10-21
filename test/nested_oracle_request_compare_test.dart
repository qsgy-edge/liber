import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../tool/nested_oracle_compare.dart';

/// Focused checks for the request-semantics comparator (#137 / A2 C6).
///
/// The real committed corpus, manifest and golden are the only frozen inputs
/// this file reads. The observations below are copied from the golden's own
/// rows: they are synthetic destination data for verdict mechanics, never a
/// claim that the product was executed by this test. The live `--requests` run
/// is the only source of an actual observation.
void main() {
  late Map<String, dynamic> corpus;
  late Map<String, dynamic> manifest;
  late Map<String, dynamic> golden;
  late String corpusSha256;
  late String corpusSha256Lf;
  late String manifestSha256;
  late String goldenSha256;
  late List<Map<String, Object?>> observations;

  Map<String, dynamic> copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  Map<String, Object?> comparison({
    List<Map<String, Object?>>? observed,
    List<Map<String, Object?>>? serverUnmatched,
    List<Map<String, Object?>>? serverErrors,
    List<Map<String, Object?>>? analysisErrors,
  }) => compareRequestRows(
    corpus: corpus,
    corpusSha256: corpusSha256,
    corpusSha256Lf: corpusSha256Lf,
    manifest: manifest,
    manifestSha256: manifestSha256,
    golden: golden,
    goldenSha256: goldenSha256,
    goldenPath:
        'tool/nested_oracle/evidence/android-17-os4.0.0.31/'
        'request-oracle.json',
    observations: observed ?? observations,
    serverUnmatchedRequests: serverUnmatched ?? const [],
    serverErrors: serverErrors ?? const [],
    analysisErrors: analysisErrors ?? const [],
  );

  setUp(() {
    corpus = loadRequestCorpus();
    manifest = loadRequestManifest();
    corpusSha256 = sha256File(File(requestCorpusPath));
    corpusSha256Lf = sha256FileLf(File(requestCorpusPath));
    manifestSha256 = sha256File(File(requestManifestPath));
    final goldenFile = File(
      'tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json',
    );
    goldenSha256 = sha256File(goldenFile);
    golden = jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
    observations = [
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
    // The unchanged control applies the product's three documented divergence
    // values so the synthetic destination side has the same 20/0/3 verdict as
    // an unchanged real run. This is copied fixture data, not a product run.
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
  });

  void expectRefused(void Function() action, {String? reason}) {
    expect(action, throwsFormatException, reason: reason);
  }

  test('the committed request corpus is a complete typed selection', () {
    expect(corpus['schemaVersion'], 1);
    expect(corpus['fixtureId'], 'REQUEST-01');
    expect(corpus['corpusVersion'], 2);
    expect(corpus['baselineCommit'], isNotEmpty);
    expect(corpus['entryPoint'], isNotEmpty);
    expect((corpus['rows'] as List).length, 23);
    expect((corpus['responses'] as List).length, 25);
    expect(
      manifest['corpus']['sha256'],
      corpusSha256,
      reason: 'raw corpus bytes are the manifest pin',
    );
    expect(manifest['corpus']['bundledAsset']['sha256'], corpusSha256);
    expect(manifest['run']['rows'], 23);
    expect(manifest['run']['requests'], 51);
    expect(goldenSha256, manifest['run']['golden']['sha256']);
    expect(
      manifest['run']['captures'].map((capture) => capture['sha256']),
      contains(goldenSha256),
    );
    final ids = [for (final row in corpus['rows'] as List) (row as Map)['id']];
    expect(ids.toSet().length, ids.length);
    expect(corpusSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(corpusSha256Lf, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test('the unchanged recorded observation passes 20 / 0 / 3', () {
    final report = comparison();
    expect(report['status'], 'pass');
    expect(report['failedRows'], isEmpty);
    expect(report['passedRows'], hasLength(20));
    expect(report['notComparedRows'], [
      'defaults-user-agent-null',
      'redirect-cross-origin',
      'query-exact-bytes',
    ]);
    expect(report['counts'], {
      'corpusRows': 23,
      'goldenRows': 23,
      'observedRows': 23,
      'observedRequests': 51,
      'goldenRequests': 51,
      'unmatchedRequests': 0,
    });
    expect(report['unmatchedRequests'], isEmpty);
    expect(report['serverErrors'], isEmpty);
    expect(report['analysisErrors'], isEmpty);
  });

  test('a changed value fails at the value surface', () {
    final mutated = copy({'rows': observations})['rows'] as List;
    final row = mutated.firstWhere((row) => row['id'] == 'defaults-injected');
    (row as Map<String, Object?>)['body'] = 'mutated-defaults';
    final report = comparison(observed: mutated.cast<Map<String, Object?>>());
    expect(report['status'], 'fail');
    expect(report['failedRows'], ['defaults-injected']);
    final failed = (report['rows'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((row) => row['id'] == 'defaults-injected');
    expect(failed['mismatches'], [
      {
        'observation': 'body',
        'frozen': 'defaults',
        'liber': 'mutated-defaults',
      },
    ]);
  });

  test('a changed request fails at the raw request surface', () {
    final mutated = copy({'rows': observations})['rows'] as List;
    final row = mutated.firstWhere((row) => row['id'] == 'query-key-raw');
    final request = ((row as Map)['requests'] as List).first as Map;
    request['rawQuery'] = 'q=mutated&p=1';
    final report = comparison(observed: mutated.cast<Map<String, Object?>>());
    expect(report['status'], 'fail');
    expect(report['failedRows'], ['query-key-raw']);
    final failed = (report['rows'] as List)
        .cast<Map<String, Object?>>()
        .firstWhere((row) => row['id'] == 'query-key-raw');
    final mismatch = (failed['mismatches'] as List).first as Map;
    expect(mismatch['observation'], 'requests[0].rawQuery');
    expect(mismatch['liber'], 'q=mutated&p=1');
    expect(mismatch['frozen'], isNot('q=mutated&p=1'));
  });

  test(
    'an unmatched replay request fails even when every row value matches',
    () {
      final report = comparison(
        serverUnmatched: [
          {
            'row': 'defaults-injected',
            'index': 1,
            'method': 'GET',
            'path': '/undeclared-control',
            'rawQuery': 'x=1',
            'headers': <String, String>{},
            'body': '',
            'declared': false,
          },
        ],
      );
      expect(report['status'], 'fail');
      expect(report['failedRows'], isEmpty);
      expect(report['passedRows'], hasLength(20));
      expect(report['notComparedRows'], hasLength(3));
      expect(report['unmatchedRequests'], hasLength(1));
      expect(
        (report['unmatchedRequests'] as List).first['path'],
        '/undeclared-control',
      );
      expect(report['rows'], everyElement(isA<Map>()));
    },
  );

  test(
    'an undeclared request in the row trace is retained as row evidence',
    () {
      final mutated = copy({'rows': observations})['rows'] as List;
      final row = mutated.firstWhere((row) => row['id'] == 'defaults-injected');
      ((row as Map)['requests'] as List).add({
        'method': 'GET',
        'path': '/undeclared-control',
        'rawQuery': 'x=1',
        'headers': <String, String>{},
        'body': '',
      });
      final report = comparison(observed: mutated.cast<Map<String, Object?>>());
      expect(report['status'], 'fail');
      expect(report['failedRows'], ['defaults-injected']);
      expect(report['unmatchedRequests'], hasLength(1));
      final failed = (report['rows'] as List)
          .cast<Map<String, Object?>>()
          .firstWhere((row) => row['id'] == 'defaults-injected');
      expect(
        (failed['mismatches'] as List).map((entry) => entry['observation']),
        contains('requests[1].unmatched'),
      );
      expect((failed['unmatchedRequests'] as List), hasLength(1));
    },
  );

  test(
    'the replay server records an undeclared request and still answers 404',
    () async {
      final server = await RequestReplayServer(
        corpus,
        origin: 'http://127.0.0.1:0',
        otherOrigin: 'http://127.0.0.3:0',
        port: 0,
      ).start();
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse(
            'http://127.0.0.1:${server.port}/definitely-undeclared?x=1',
          ),
        );
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, 404);
        expect(body, 'undeclared replay request');
        expect(server.requests, hasLength(1));
        expect(server.requests.single['declared'], false);
        expect(server.unmatchedRequests, hasLength(1));
        expect(server.unmatchedRequests.single['method'], 'GET');
        expect(
          server.unmatchedRequests.single['path'],
          '/definitely-undeclared',
        );
        expect(server.unmatchedRequests.single['rawQuery'], 'x=1');
        expect(server.serverErrors, isEmpty);
      } finally {
        client.close(force: true);
        await server.close();
      }
      expect(server.closed, true);
    },
  );

  test('identity, hash, target and capture pins are refused independently', () {
    expectRefused(
      () => checkRequestGolden(
        corpus: corpus,
        corpusSha256: '0' * 64,
        manifest: manifest,
        golden: golden,
        goldenSha256: goldenSha256,
      ),
      reason: 'a stale corpus hash',
    );
    expectRefused(
      () => checkRequestGolden(
        corpus: corpus,
        corpusSha256: corpusSha256,
        manifest: manifest,
        golden: golden,
        goldenSha256: '0' * 64,
      ),
      reason: 'a stale golden hash',
    );

    for (final entry in <String, Object?>{
      'fixtureId': 'OTHER-01',
      'corpusVersion': 999,
      'baselineCommit': '0' * 40,
      'entryPoint': 'Another.entryPoint',
      'fingerprint': 'another/device',
      'recordedAt': '2000-01-01T00:00:00.000Z',
      'platform': 'ios',
    }.entries) {
      final mutated = copy(golden);
      mutated[entry.key] = entry.value;
      expectRefused(
        () => checkRequestGolden(
          corpus: corpus,
          corpusSha256: corpusSha256,
          manifest: manifest,
          golden: mutated,
          goldenSha256: goldenSha256,
        ),
        reason: 'a golden with another ${entry.key}',
      );
    }

    final failedGolden = copy(golden);
    failedGolden['analysisFailure'] = 'boom';
    expectRefused(
      () => checkRequestGolden(
        corpus: corpus,
        corpusSha256: corpusSha256,
        manifest: manifest,
        golden: failedGolden,
        goldenSha256: goldenSha256,
      ),
      reason: 'an analysis failure',
    );
    final erroredGolden = copy(golden);
    erroredGolden['serverErrors'] = [
      {'error': 'boom'},
    ];
    expectRefused(
      () => checkRequestGolden(
        corpus: corpus,
        corpusSha256: corpusSha256,
        manifest: manifest,
        golden: erroredGolden,
        goldenSha256: goldenSha256,
      ),
      reason: 'a replay-server error',
    );
    final openGolden = copy(golden);
    openGolden['cleanup'] = {'openConnections': 1, 'serverClosed': false};
    expectRefused(
      () => checkRequestGolden(
        corpus: corpus,
        corpusSha256: corpusSha256,
        manifest: manifest,
        golden: openGolden,
        goldenSha256: goldenSha256,
      ),
      reason: 'a capture that did not close its server',
    );

    final mutatedManifests = <String, void Function(Map<String, dynamic>)>{
      'baseline commit': (value) {
        (value['baseline'] as Map)['commit'] = '0' * 40;
      },
      'target APK pin': (value) {
        ((value['baseline'] as Map)['application'] as Map)['sha256'] = 'x';
      },
      'target APK verification': (value) {
        ((value['baseline'] as Map)['application']
                as Map)['installedBytesPulledAndVerified'] =
            false;
      },
      'harness APK pin': (value) {
        (value['harness'] as Map)['installedApkSha256'] = '0' * 64;
      },
      'harness entry point': (value) {
        (value['harness'] as Map)['entryPoint'] = 'Another.entryPoint';
      },
      'corpus pin': (value) {
        (value['corpus'] as Map)['sha256'] = '0' * 64;
      },
      'golden pin': (value) {
        ((value['run'] as Map)['golden'] as Map)['sha256'] = '0' * 64;
      },
      'capture pin': (value) {
        (value['run'] as Map)['captures'] = [
          {'path': 'capture.json', 'sha256': '0' * 64},
        ];
      },
      'run row count': (value) {
        (value['run'] as Map)['rows'] = 1;
      },
      'run request count': (value) {
        (value['run'] as Map)['requests'] = 1;
      },
      'analysis failure': (value) {
        (value['run'] as Map)['analysisFailure'] = 'boom';
      },
      'server error': (value) {
        (value['run'] as Map)['serverErrors'] = [
          {'error': 'boom'},
        ];
      },
      'cleanup': (value) {
        (value['run'] as Map)['cleanup'] = {'serverClosed': false};
      },
      'device fingerprint': (value) {
        (value['device'] as Map)['fingerprint'] = 'another/device';
      },
    };
    for (final entry in mutatedManifests.entries) {
      final mutated = copy(manifest);
      entry.value(mutated);
      expectRefused(
        () => checkRequestGolden(
          corpus: corpus,
          corpusSha256: corpusSha256,
          manifest: mutated,
          golden: golden,
          goldenSha256: goldenSha256,
        ),
        reason: 'a manifest with another ${entry.key}',
      );
    }
  });

  test('extra, missing, reordered and untyped golden rows are refused', () {
    // A mutated golden cannot reach the row checks under the real manifest
    // because its bytes no longer match the golden pin. Prove that hash refusal
    // first, then prove the row-shape guard itself with a manifest whose golden
    // pin names the copied bytes.
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (value) => (value['rows'] as List).add(
        copy((value['rows'] as List).first as Map<String, dynamic>),
      ),
      (value) => (value['rows'] as List).removeLast(),
      (value) => (value['rows'] as List).setAll(0, [
        (value['rows'] as List)[1],
        (value['rows'] as List)[0],
      ]),
    ]) {
      final mutated = copy(golden);
      mutation(mutated);
      expectRefused(
        () => checkRequestGolden(
          corpus: corpus,
          corpusSha256: corpusSha256,
          manifest: manifest,
          golden: mutated,
          goldenSha256: goldenSha256,
        ),
      );
      final pinnedManifest = copy(manifest);
      final mutatedSha = const JsonEncoder().convert(mutated);
      // Pin the copied bytes so only the row guard can refuse them.
      ((pinnedManifest['run'] as Map)['golden'] as Map)['sha256'] =
          _sha256OfText(mutatedSha);
      (pinnedManifest['run'] as Map)['captures'] = [
        {'path': 'copy.json', 'sha256': _sha256OfText(mutatedSha)},
      ];
      (pinnedManifest['run'] as Map)['rows'] = (mutated['rows'] as List).length;
      (pinnedManifest['run'] as Map)['requests'] =
          (mutated['requests'] as List).length;
      expectRefused(
        () => checkRequestGolden(
          corpus: corpus,
          corpusSha256: corpusSha256,
          manifest: pinnedManifest,
          golden: mutated,
          goldenSha256: _sha256OfText(mutatedSha),
        ),
      );
    }

    for (final mutation in <void Function(Map<String, dynamic>)>[
      (value) => ((value['rows'] as List).first as Map).remove('requests'),
      (value) => ((value['rows'] as List).first as Map)['outcome'] = 'other',
      (value) =>
          ((((value['rows'] as List).first as Map)['requests'] as List).first
                  as Map)
              .remove('rawQuery'),
      (value) => value['requests'] = (value['requests'] as List).sublist(1),
    ]) {
      final mutated = copy(golden);
      mutation(mutated);
      final pinnedManifest = copy(manifest);
      final mutatedSha = _sha256OfText(const JsonEncoder().convert(mutated));
      ((pinnedManifest['run'] as Map)['golden'] as Map)['sha256'] = mutatedSha;
      (pinnedManifest['run'] as Map)['captures'] = [
        {'path': 'copy.json', 'sha256': mutatedSha},
      ];
      expectRefused(
        () => checkRequestGolden(
          corpus: corpus,
          corpusSha256: corpusSha256,
          manifest: pinnedManifest,
          golden: mutated,
          goldenSha256: mutatedSha,
        ),
      );
    }
  });

  test('missing, extra, reordered or untyped actual rows are refused', () {
    expectRefused(
      () => comparison(observed: observations.sublist(1)),
      reason: 'a short product run',
    );
    expectRefused(
      () => comparison(observed: [...observations, copy(observations.first)]),
      reason: 'an extra actual row',
    );
    expectRefused(
      () => comparison(observed: [observations[1], observations[0]]),
      reason: 'reordered actual rows',
    );
    expectRefused(
      () => comparison(observed: const []),
      reason: 'an empty actual run',
    );
    final emptyCarrier = copy({'rows': observations})['rows'] as List;
    (((emptyCarrier.first as Map)['requests'] as List).first as Map).remove(
      'rawQuery',
    );
    expectRefused(
      () => comparison(observed: emptyCarrier.cast<Map<String, Object?>>()),
      reason: 'an untyped request carrier',
    );
    final unknownOutcome = copy({'rows': observations})['rows'] as List;
    (unknownOutcome.first as Map)['outcome'] = 'other';
    expectRefused(
      () => comparison(observed: unknownOutcome.cast<Map<String, Object?>>()),
      reason: 'an unknown outcome',
    );
  });

  test('server and analysis errors fail the run even with matching rows', () {
    for (final errors in <Map<String, Object?>>[
      {
        'serverErrors': [
          {'error': 'boom'},
        ],
      },
      {
        'analysisErrors': [
          {'row': 'defaults-injected', 'error': 'boom'},
        ],
      },
    ]) {
      final report = comparison(
        serverErrors: errors['serverErrors'] as List<Map<String, Object?>>?,
        analysisErrors: errors['analysisErrors'] as List<Map<String, Object?>>?,
      );
      expect(report['status'], 'fail');
      expect(report['failedRows'], isEmpty);
    }
  });
}

List<dynamic> _requests(Map<String, Object?> observation) =>
    observation['requests'] as List<dynamic>;

Map<dynamic, dynamic> _firstRequest(Map<String, Object?> observation) =>
    _requests(observation).first as Map<dynamic, dynamic>;

String _sha256OfText(String text) => SHA256Digest()
    .process(Uint8List.fromList(utf8.encode(text)))
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
