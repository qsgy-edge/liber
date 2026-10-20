import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/state_session/compare.dart';
import '../tool/state_session/runner.dart';

/// Focused checks for the STATE-SESSION-01 observation and comparator boundary.
///
/// The corpus is the committed shared fixture. The golden and product reports
/// below are synthetic records that exercise the comparator's mechanics; they
/// are never labelled a frozen capture and the real comparison uses the
/// controller's raw reports from `state-capture-03`.
void main() {
  late Map<String, dynamic> corpus;
  late String corpusLf;
  late Map<String, dynamic> seedGolden;
  late Map<String, dynamic> restartGolden;
  late Map<String, dynamic> seedProduct;
  late Map<String, dynamic> restartProduct;

  Map<String, dynamic> copy(Map<String, dynamic> value) =>
      jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

  void resetGoldens() {
    seedGolden = _golden(corpus, 'seed', pid: 101, runId: 'seed-run');
    restartGolden = _golden(
      corpus,
      'restart',
      pid: 202,
      runId: 'restart-run',
      recordedAt: '2026-10-20T10:12:48.666Z',
    );
  }

  void resetProducts() {
    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    restartProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'restart',
      pid: 404,
      runId: 'product-restart',
      startedAt: '2026-10-20T10:20:02.000Z',
      completedAt: '2026-10-20T10:20:03.000Z',
      seedPid: seedProduct['pid'] as int,
      seedRunId: seedProduct['runId'] as String,
    );
  }

  setUp(() {
    corpus = loadStateSessionCorpus();
    corpusLf = stateSessionCorpusSha256Lf(File(stateSessionCorpusPath));
    resetGoldens();
    resetProducts();
  });

  Map<String, Object?> compare() => compareStateSessionPhases(
    corpus: corpus,
    corpusSha256Lf: corpusLf,
    seedGolden: seedGolden,
    restartGolden: restartGolden,
    seedProduct: seedProduct,
    restartProduct: restartProduct,
    librarySha256: _librarySha,
    seedExitCode: 0,
    restartExitCode: 0,
  );

  test('the committed corpus is a complete STATE-SESSION-01 case graph', () {
    expect(corpus['fixtureId'], 'STATE-SESSION-01');
    expect(corpus['corpusVersion'], 2);
    expect(stateSessionTargetOf(corpus)['package'], 'io.legado.app.debug');
    final seedSteps = stateSessionSteps(corpus, 'seed');
    final restartSteps = stateSessionSteps(corpus, 'restart');
    expect(seedSteps.length, 16);
    expect(restartSteps.length, 10);
    expect(stateSessionExpectedRequests(corpus, 'seed').length, 13);
    expect(stateSessionExpectedRequests(corpus, 'restart').length, 4);
    expect(activeStateSessionResponses(corpus, 'seed').length, 13);
    expect(activeStateSessionResponses(corpus, 'restart').length, 13);
    for (final phase in ['seed', 'restart']) {
      final steps = stateSessionSteps(corpus, phase);
      for (var index = 0; index < steps.length; index++) {
        if (steps[index]['kind'] != 'details') continue;
        expect(
          steps[index + 1]['kind'],
          'toc',
          reason: '${steps[index]['id']}',
        );
        expect(steps[index + 1]['book'], steps[index]['book']);
      }
    }
    expect(corpusLf, matches(RegExp(r'^[0-9a-f]{64}$')));
  });

  test(
    'the corpus pin ignores CRLF and a duplicate active response is refused',
    () {
      final directory = Directory.systemTemp.createTempSync('state-corpus-');
      try {
        final lfText = File(
          stateSessionCorpusPath,
        ).readAsStringSync().replaceAll('\r\n', '\n');
        final lf = File('${directory.path}/lf.json')..writeAsStringSync(lfText);
        final crlf = File('${directory.path}/crlf.json')
          ..writeAsStringSync(lfText.replaceAll('\n', '\r\n'));
        expect(
          stateSessionCorpusSha256Lf(crlf),
          stateSessionCorpusSha256Lf(lf),
        );
      } finally {
        directory.deleteSync(recursive: true);
      }

      final duplicated = copy(corpus);
      final responses = duplicated['responses'] as List;
      responses.add(
        copy(
          (responses.firstWhere((raw) => (raw as Map)['id'] == 'a-book-1-info')
              as Map<String, dynamic>),
        ),
      );
      expect(
        () => stateSessionCorpusForPhase(duplicated, 'seed'),
        throwsFormatException,
        reason: 'two active responses for one selector',
      );
    },
  );

  test('a genuine matching pair passes', () {
    final report = compare();
    expect(report['status'], 'pass');
    expect(report['mismatches'], isEmpty);
    expect(report['rawTextDifferences'], isEmpty);
    expect(
      (report['checks'] as Map).keys.where(
        (key) => (report['checks'] as Map)[key]['ok'] != true,
      ),
      isEmpty,
    );
  });

  test('variableRaw member order is reported, not a failure', () {
    final observation = (seedProduct['observations'] as List).first as Map;
    observation['value'] = <String, Object?>{
      'variable': {'bkV': 'A1', 'obs': 'value'},
      'variableRaw': '{\n  "bkV": "A1",\n  "obs": "value"\n}',
    };
    final goldenObservation = (seedGolden['observations'] as List).first as Map;
    goldenObservation['value'] = <String, Object?>{
      'variable': {'obs': 'value', 'bkV': 'A1'},
      'variableRaw': '{\n  "obs": "value",\n  "bkV": "A1"\n}',
    };
    final report = compare();
    expect(report['status'], 'pass');
    expect(report['rawTextDifferences'], isNotEmpty);
  });

  test('a changed or reordered observation value fails', () {
    final observations = seedProduct['observations'] as List;
    (observations.first as Map)['value'] = 'changed-actual-value';
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    final seeded = (seedProduct['observations'] as List).first as Map;
    seeded['value'] = <Object?>['first', 'second'];
    final expected = (seedGolden['observations'] as List).first as Map;
    expected['value'] = <Object?>['second', 'first'];
    expect(compare()['status'], 'fail');
  });

  test('an invalid raw variable text is exact text and a change fails', () {
    final observation = (seedProduct['observations'] as List).first as Map;
    observation['value'] = <String, Object?>{'variableRaw': 'not-json-product'};
    final goldenObservation = (seedGolden['observations'] as List).first as Map;
    goldenObservation['value'] = <String, Object?>{
      'variableRaw': 'not-json-golden',
    };
    expect(compare()['status'], 'fail');
  });

  test('an extra, missing or reordered request fails', () {
    (seedProduct['requests'] as List).add({
      'method': 'GET',
      'path': '/unexpected',
      'query': <String, String>{},
      'headers': <String, String>{},
      'body': '',
    });
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    (seedProduct['requests'] as List).removeAt(0);
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    final requests = seedProduct['requests'] as List;
    final first = requests[0];
    requests[0] = requests[1];
    requests[1] = first;
    expect(compare()['status'], 'fail');
  });

  test('the seed and restart must be different terminated processes', () {
    restartProduct['pid'] = seedProduct['pid'];
    expect(compare()['status'], 'fail');

    restartProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'restart',
      pid: 404,
      runId: 'product-restart',
      startedAt: '2026-10-20T10:20:02.000Z',
      completedAt: '2026-10-20T10:20:03.000Z',
      seedPid: seedProduct['pid'] as int,
      seedRunId: seedProduct['runId'] as String,
    );
    (restartProduct['owner'] as Map)['seedRunId'] = 'another-seed';
    expect(compare()['status'], 'fail');

    restartProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'restart',
      pid: 404,
      runId: 'product-restart',
      startedAt: '2026-10-20T10:20:00.500Z',
      completedAt: '2026-10-20T10:20:03.000Z',
      seedPid: seedProduct['pid'] as int,
      seedRunId: seedProduct['runId'] as String,
    );
    expect(compare()['status'], 'fail');
  });

  test('incomplete setup and cleanup receipts fail', () {
    (seedProduct['cleanup'] as Map)['scratchRetained'] = false;
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    (restartProduct['cleanup'] as Map)['scratchRemoved'] = false;
    expect(compare()['status'], 'fail');

    restartProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'restart',
      pid: 404,
      runId: 'product-restart',
      startedAt: '2026-10-20T10:20:02.000Z',
      completedAt: '2026-10-20T10:20:03.000Z',
      seedPid: seedProduct['pid'] as int,
      seedRunId: seedProduct['runId'] as String,
    );
    (seedProduct['owner'] as Map).remove('sha256');
    expect(compare()['status'], 'fail');
  });

  test('the java policy must survive the restart and stay per source', () {
    final seedPolicy = seedProduct['javaPolicy'] as Map;
    final seedSources = seedPolicy['sources'] as Map;
    final sourceA = seedSources.values.first as Map;
    (sourceA['java'] as Map)['policyJava.B'] = 'leaked';

    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    final restartPolicy = restartProduct['javaPolicy'] as Map;
    ((restartPolicy['rows'] as List).first as Map)['value'] = 'other';
    expect(compare()['status'], 'fail');
  });

  test('empty or unknown product cases cannot pass', () {
    seedProduct['observations'] = <Object?>[];
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    final firstObservation = (seedProduct['observations'] as List).first as Map;
    firstObservation['id'] = 'unknown';
    expect(compare()['status'], 'fail');
  });

  test('a golden with another identity is refused', () {
    for (final entry in <String, Object?>{
      'fixtureId': 'OTHER-01',
      'corpusVersion': 99,
      'baselineCommit': '0' * 40,
      'entryPoint': 'Another.entry',
      'phase': 'restart',
    }.entries) {
      final golden = copy(seedGolden);
      golden[entry.key] = entry.value;
      expect(
        () => checkStateSessionGolden(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          golden: golden,
          phase: 'seed',
        ),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test(
    'a golden with another target, corpus or harness identity is refused',
    () {
      for (final entry in <String, Object?>{
        'targetPackage': 'io.legado.app.release',
        'targetApkSha256': '0' * 64,
        'targetBaselineCommit': '0' * 40,
        'corpusAssetSha256': '0' * 64,
        'corpusSha256Lf': '0' * 64,
        'harnessApkSha256': 'not-a-hash',
        'targetPinManifest': 'another/manifest.json',
      }.entries) {
        final golden = copy(seedGolden);
        (golden['identity'] as Map)[entry.key] = entry.value;
        expect(
          () => checkStateSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: golden,
            phase: 'seed',
          ),
          throwsFormatException,
          reason: entry.key,
        );
      }
    },
  );

  test(
    'a golden with a changed request trace or missing receipts is refused',
    () {
      final swapped = copy(seedGolden);
      final requests = swapped['requests'] as List;
      final first = requests[0];
      requests[0] = requests[1];
      requests[1] = first;
      expect(
        () => checkStateSessionGolden(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          golden: swapped,
          phase: 'seed',
        ),
        throwsFormatException,
      );

      final noCleanup = copy(seedGolden)..remove('cleanup');
      expect(
        () => checkStateSessionGolden(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          golden: noCleanup,
          phase: 'seed',
        ),
        throwsFormatException,
      );

      final noPrefs = copy(seedGolden);
      (noPrefs['cleanup'] as Map)['preferencesFenced'] = <Object?>[];
      expect(
        () => checkStateSessionGolden(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          golden: noPrefs,
          phase: 'seed',
        ),
        throwsFormatException,
      );
    },
  );

  test('an empty golden capture is refused', () {
    final empty = copy(seedGolden)..['observations'] = <Object?>[];
    expect(
      () => checkStateSessionGolden(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        golden: empty,
        phase: 'seed',
      ),
      throwsFormatException,
    );
    final noRequests = copy(seedGolden)..['requests'] = <Object?>[];
    expect(
      () => checkStateSessionGolden(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        golden: noRequests,
        phase: 'seed',
      ),
      throwsFormatException,
    );
  });

  test('the seed and restart captures must be different and ordered', () {
    final samePid = copy(restartGolden)..['pid'] = seedGolden['pid'];
    expect(
      () => checkStateSessionGoldenPair(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        seed: seedGolden,
        restart: samePid,
      ),
      throwsFormatException,
    );
    final earlier = copy(restartGolden)
      ..['recordedAt'] = '2026-10-20T09:00:00.000Z';
    expect(
      () => checkStateSessionGoldenPair(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        seed: seedGolden,
        restart: earlier,
      ),
      throwsFormatException,
    );
  });

  test('the controller handoff must name exactly these capture files', () {
    final handoff = _handoff(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restart: restartGolden,
    );
    checkStateSessionGoldenPair(
      corpus: corpus,
      corpusSha256Lf: corpusLf,
      seed: seedGolden,
      restart: restartGolden,
      handoff: handoff,
      seedSha256: 'a' * 64,
      restartSha256: 'b' * 64,
    );
    for (final entry in <String, Object?>{
      'seed-sha': null,
      'status': 'blocked',
      'corpus': 'stale',
      'harness': 'other',
      'seed-pid': -1,
    }.entries) {
      final changed = copy(handoff);
      switch (entry.key) {
        case 'seed-sha':
          (changed['seed'] as Map)['sha256'] = 'c' * 64;
        case 'status':
          changed['status'] = 'blocked';
        case 'corpus':
          (changed['corpus'] as Map)['sha256Lf'] = '0' * 64;
        case 'harness':
          (changed['harness'] as Map)['sha256'] = '0' * 64;
        case 'seed-pid':
          (changed['seed'] as Map)['pid'] = 1;
      }
      expect(
        () => checkStateSessionGoldenPair(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          seed: seedGolden,
          restart: restartGolden,
          handoff: changed,
          seedSha256: 'a' * 64,
          restartSha256: 'b' * 64,
        ),
        throwsFormatException,
        reason: entry.key,
      );
    }
  });

  test('a product report naming another corpus or target fails', () {
    (seedProduct['identity'] as Map)['corpusSha256Lf'] = '0' * 64;
    expect(compare()['status'], 'fail');

    seedProduct = _product(
      corpus: corpus,
      corpusLf: corpusLf,
      seed: seedGolden,
      restartGolden: restartGolden,
      phase: 'seed',
      pid: 303,
      runId: 'product-seed',
      startedAt: '2026-10-20T10:20:00.000Z',
      completedAt: '2026-10-20T10:20:01.000Z',
    );
    ((seedProduct['identity'] as Map)['target'] as Map)['apkSha256'] = '0' * 64;
    expect(compare()['status'], 'fail');
  });

  test('an explicitly failed or unknown product status cannot pass', () {
    for (final status in <String?>['failed', 'refused', 'unknown', null]) {
      resetProducts();
      if (status == null) {
        seedProduct.remove('status');
      } else {
        seedProduct['status'] = status;
      }
      expect(compare()['status'], 'fail', reason: 'status $status');
    }
  });

  test('the restart must name the exact retained root the seed created', () {
    expect(compare()['status'], 'pass');

    (restartProduct['isolation'] as Map)['root'] =
        'C:/liber-unowned-counterexample/same-root-name';
    expect(compare()['status'], 'fail');

    resetProducts();
    (restartProduct['isolation'] as Map)['database'] =
        'C:/liber-unowned-counterexample/same-root-name/spaces/default/data.db';
    expect(compare()['status'], 'fail');

    resetProducts();
    (restartProduct['owner'] as Map)['rootName'] = 'another-root';
    expect(compare()['status'], 'fail');

    resetProducts();
    (restartProduct['isolation'] as Map)['validatedOwnerSha256'] = '4' * 64;
    expect(compare()['status'], 'fail');

    resetProducts();
    (seedProduct['isolation'] as Map)['root'] = 'C:/another-seed-root';
    expect(compare()['status'], 'fail');
  });

  test('a raw null column is not the JSON text null', () {
    (seedProduct['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'bookUrl': 'http://127.0.0.1:18741/a/book/1',
      'name': 'A1',
      'variable': null,
      'variableRaw': null,
    };
    (seedGolden['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'bookUrl': 'http://127.0.0.1:18741/a/book/1',
      'name': 'A1',
      'variable': null,
      'variableRaw': 'null',
    };
    expect(
      compare()['status'],
      'fail',
      reason: 'null column vs JSON null text',
    );

    resetGoldens();
    resetProducts();
    (seedProduct['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variable': null,
      'variableRaw': 'null',
    };
    (seedGolden['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variable': null,
      'variableRaw': null,
    };
    expect(
      compare()['status'],
      'fail',
      reason: 'JSON null text vs null column',
    );

    resetGoldens();
    resetProducts();
    (seedProduct['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variableRaw': '',
    };
    (seedGolden['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variableRaw': '""',
    };
    expect(
      compare()['status'],
      'fail',
      reason: 'empty text vs JSON empty string',
    );

    resetGoldens();
    resetProducts();
    (seedProduct['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variable': null,
    };
    (seedGolden['observations'] as List).firstWhere(
      (raw) => (raw as Map)['id'] == 'seed.details.A1',
    )['value'] = <String, Object?>{
      'variable': null,
      'variableRaw': null,
    };
    expect(
      compare()['status'],
      'fail',
      reason: 'missing raw key vs present null',
    );
  });

  test('a detected policy leak cannot keep a pass verdict on that phase', () {
    final seedSources = (seedProduct['javaPolicy'] as Map)['sources'] as Map;
    final seedSourceA = seedSources.values.first as Map;
    (seedSourceA['java'] as Map)['policyJava.B'] = 'leaked';
    final seedLeak = compare();
    expect(seedLeak['status'], 'fail');
    expect((seedLeak['javaPolicy'] as Map)['seed']['verdict'], 'fail');
    expect((seedLeak['javaPolicy'] as Map)['restart']['verdict'], 'pass');

    resetProducts();
    final restartSources =
        (restartProduct['javaPolicy'] as Map)['sources'] as Map;
    final restartSourceA = restartSources.values.first as Map;
    (restartSourceA['java'] as Map)['policyJava.B'] = 'leaked';
    final restartLeak = compare();
    expect(restartLeak['status'], 'fail');
    expect((restartLeak['javaPolicy'] as Map)['seed']['verdict'], 'pass');
    expect((restartLeak['javaPolicy'] as Map)['restart']['verdict'], 'fail');

    resetProducts();
    (seedProduct['javaPolicy'] as Map).remove('rows');
    final malformed = compare();
    expect(malformed['status'], 'fail');
    expect((malformed['javaPolicy'] as Map)['seed']['verdict'], 'fail');
    expect(
      ((malformed['javaPolicy'] as Map)['seed'] as Map)['errors'],
      isNotEmpty,
    );
  });

  test('raw query order, encoding and presence are compared exactly', () {
    Map firstRequest() => (seedProduct['requests'] as List).first as Map;

    firstRequest()['rawQuery'] = 'page=1&keyword=state';
    var report = compare();
    expect(report['status'], 'fail');
    expect(
      ((report['checks'] as Map)['product-raw-query-seed'] as Map)['ok'],
      false,
    );
    expect(
      ((report['checks'] as Map)['product-requests-seed'] as Map)['ok'],
      true,
      reason: 'the decoded query members stay equal',
    );

    resetProducts();
    firstRequest()['rawQuery'] = 'keyword=%73tate&page=1';
    report = compare();
    expect(report['status'], 'fail');
    expect(
      ((report['checks'] as Map)['product-raw-query-seed'] as Map)['ok'],
      false,
    );
    expect(
      ((report['checks'] as Map)['product-requests-seed'] as Map)['ok'],
      true,
      reason: 'the decoded query members stay equal',
    );

    resetProducts();
    firstRequest().remove('rawQuery');
    report = compare();
    expect(report['status'], 'fail');
    expect(
      ((report['checks'] as Map)['product-raw-query-seed'] as Map)['ok'],
      false,
    );
    final mismatch =
        (report['mismatches'] as List).firstWhere(
              (raw) => (raw as Map)['surface'] == 'product-raw-query-seed',
            )
            as Map;
    expect('${mismatch['detail']}', contains('missing'));
  });

  test('the golden raw query carrier is required and bound to its request', () {
    final noTrace = copy(seedGolden)..remove('stageTrace');
    expect(
      () => checkStateSessionGolden(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        golden: noTrace,
        phase: 'seed',
      ),
      throwsFormatException,
    );

    final wrongPath = copy(seedGolden);
    ((wrongPath['stageTrace'] as List).first as Map)['path'] =
        'http://127.0.0.1:18741/a/other?keyword=state&page=1';
    expect(
      () => checkStateSessionGolden(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        golden: wrongPath,
        phase: 'seed',
      ),
      throwsFormatException,
    );

    final wrongStage = copy(seedGolden);
    ((wrongStage['stageTrace'] as List).first as Map)['stage'] =
        'seed.search.B';
    expect(
      () => checkStateSessionGolden(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        golden: wrongStage,
        phase: 'seed',
      ),
      throwsFormatException,
    );

    final reorderedGolden = copy(seedGolden);
    ((reorderedGolden['stageTrace'] as List).first as Map)['path'] =
        'http://127.0.0.1:18741/a/search?page=1&keyword=state';
    final report = compareStateSessionPhases(
      corpus: corpus,
      corpusSha256Lf: corpusLf,
      seedGolden: reorderedGolden,
      restartGolden: restartGolden,
      seedProduct: seedProduct,
      restartProduct: restartProduct,
      librarySha256: _librarySha,
      seedExitCode: 0,
      restartExitCode: 0,
    );
    expect(report['status'], 'fail');
    expect(
      ((report['checks'] as Map)['product-raw-query-seed'] as Map)['ok'],
      false,
      reason: 'the golden raw carrier, not the decoded map, is compared',
    );
  });
}

const _librarySha =
    '1111111111111111111111111111111111111111111111111111111111111111';
const _ownerSha =
    '3333333333333333333333333333333333333333333333333333333333333333';
const _syntheticRoot = 'C:/synthetic/state-repair-root';
const _syntheticRootName = 'state-repair-root';
const _harnessSha =
    '2222222222222222222222222222222222222222222222222222222222222222';

String _syntheticRawQuery(Map<dynamic, dynamic> request) {
  final query =
      (request['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  return [
    for (final entry in query.entries) '${entry.key}=${entry.value}',
  ].join('&');
}

Map<String, dynamic> _golden(
  Map<String, dynamic> corpus,
  String phase, {
  required int pid,
  required String runId,
  String recordedAt = '2026-10-20T10:12:07.462Z',
}) {
  final target = stateSessionTargetOf(corpus);
  final steps = stateSessionSteps(corpus, phase);
  final expected = stateSessionExpectedRequests(corpus, phase);
  final requestStages = [
    for (final step in steps)
      if (const {'search', 'details', 'toc', 'content'}.contains(step['kind']))
        '${step['id']}',
  ];
  if (requestStages.length != expected.length) {
    throw StateError('synthetic fixture stages do not match its requests');
  }
  // The synthetic fixture writes its own raw carrier once; the production
  // comparator only ever reads retained raw bytes and never derives them.
  final requests = <Map<String, Object?>>[
    for (var index = 0; index < expected.length; index++)
      {
        ...expected[index],
        'stage': requestStages[index],
        'rawQuery': _syntheticRawQuery(expected[index]),
      },
  ];
  final stageTrace = [
    for (var index = 0; index < requests.length; index++)
      {
        'stage': requests[index]['stage'],
        'path':
            '${corpus['origin']}${requests[index]['path']}'
            '${(requests[index]['rawQuery'] as String).isEmpty ? '' : '?${requests[index]['rawQuery']}'}',
      },
  ];
  final ids = [for (final step in steps) step['id']];
  return {
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'phase': phase,
    'pid': pid,
    'runId': runId,
    'recordedAt': recordedAt,
    'fingerprint': 'synthetic-test-fingerprint',
    'identity': {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'targetPackage': target['package'],
      'targetApkSha256': target['apkSha256'],
      'targetBaselineCommit': corpus['baselineCommit'],
      'corpusAssetSha256': stateSessionCorpusSha256Lf(
        File(stateSessionCorpusPath),
      ),
      'corpusSha256Lf': stateSessionCorpusSha256Lf(
        File(stateSessionCorpusPath),
      ),
      'harnessPackage': 'io.liber.oracle.nested',
      'harnessApkSha256': _harnessSha,
      'targetPinManifest': target['manifest'],
    },
    'requests': requests,
    'stageTrace': stageTrace,
    'unmatchedRequests': <Object?>[],
    'serverErrors': <Object?>[],
    'observations': [
      for (final step in steps)
        {'id': step['id'], 'value': 'observed-${step['id']}'},
    ],
    'requestCheck': {
      'declared': requests,
      'declaredCount': requests.length,
      'actualCount': requests.length,
      'match': true,
      'mismatchIndex': null,
    },
    'observationCheck': {
      'declared': ids,
      'actual': ids,
      'missing': <Object?>[],
      'extra': <Object?>[],
      'duplicates': <Object?>[],
      'ordered': true,
      'match': true,
    },
    'cleanup': phase == 'seed'
        ? {
            'databaseClosed': true,
            'serverClosed': true,
            'scratchRetained': true,
            'scratchRemoved': false,
            'ownership': 'created-fresh-root',
            'preferencesFenced': [
              {'name': 'liber_state_session_01_probe', 'ok': true},
            ],
          }
        : {
            'databaseClosed': true,
            'serverClosed': true,
            'scratchRetained': false,
            'scratchRemoved': true,
            'ownership': 'validated-seed-owner',
            'preferencesRemoved': [
              {'name': 'liber_state_session_01_probe', 'ok': true},
            ],
          },
    'isolation': phase == 'seed'
        ? {'scratchRootExistedAtStart': false, 'scratchCreatedByThisRun': true}
        : {
            'scratchRootExistedAtStart': true,
            'scratchCreatedByThisRun': false,
            'scratchRetainedFromSeed': true,
          },
    'analysisFailure': null,
  };
}

Map<String, dynamic> _product({
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required Map<String, dynamic> seed,
  required Map<String, dynamic> restartGolden,
  required String phase,
  required int pid,
  required String runId,
  required String startedAt,
  required String completedAt,
  int? seedPid,
  String? seedRunId,
}) {
  final target = stateSessionTargetOf(corpus);
  final golden = phase == 'seed' ? seed : restartGolden;
  final requests = jsonDecode(jsonEncode(golden['requests'])) as List;
  final observations = jsonDecode(jsonEncode(golden['observations'])) as List;
  final ids = [for (final raw in observations) '${(raw as Map)['id']}'];
  return {
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'phase': phase,
    'status': 'completed',
    'pid': pid,
    'runId': runId,
    'startedAt': startedAt,
    'completedAt': completedAt,
    'identity': {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'corpusPath': stateSessionCorpusPath,
      'corpusRawSha256': 'a' * 64,
      'corpusSha256Lf': corpusLf,
      'target': {
        'package': target['package'],
        'apkSha256': target['apkSha256'],
        'baselineCommit': target['baselineCommit'],
        'manifest': target['manifest'],
      },
      'library': {'path': 'synthetic-fjs.dll', 'sha256': _librarySha},
    },
    'requests': requests,
    'unmatchedRequests': <Object?>[],
    'observations': observations,
    'requestCheck': {
      'match': true,
      'declaredCount': requests.length,
      'actualCount': requests.length,
      'mismatch': null,
    },
    'observationCheck': {'match': true, 'missing': <Object?>[]},
    'isolation': {
      'root': _syntheticRoot,
      'rootName': _syntheticRootName,
      'database': '$_syntheticRoot/spaces/default/data.db',
      'workspaceManifest': '$_syntheticRoot/manifest.json',
      'ownerFile': '$_syntheticRoot/owner.json',
      'rootExistedAtStart': phase == 'restart',
      'createdByThisRun': phase == 'seed',
      'validatedOwner': phase == 'restart',
      'validatedOwnerSha256': phase == 'seed' ? null : _ownerSha,
      'preferenceFilesOutsideRoot': <Object?>[],
      'preferenceBoundary': 'synthetic: all product state is inside this root',
    },
    'cleanup': {
      'databaseClosed': true,
      'serverClosed': true,
      'nativeLibraryDisposed': true,
      'ownerWritten': phase == 'seed',
      'ownerSha256': _ownerSha,
      'scratchRetained': phase == 'seed',
      'scratchRemoved': phase == 'restart',
      'rootAbsentAfter': phase == 'restart',
    },
    'owner': {
      'written': phase == 'seed',
      'validated': phase == 'restart',
      'sha256': _ownerSha,
      'seedPid': phase == 'seed' ? pid : seedPid,
      'seedRunId': phase == 'seed' ? runId : seedRunId,
      'rootName': _syntheticRootName,
      'complete': true,
    },
    'javaPolicy': _javaPolicy(corpus, phase),
    'analysisFailure': null,
    'steps': ids,
  };
}

Map<String, dynamic> _javaPolicy(Map<String, dynamic> corpus, String phase) {
  final urls = [
    for (final raw in (corpus['sources'] as List))
      '${((raw as Map)['bookSource'] as Map)['bookSourceUrl']}',
  ];
  final expected = {urls[0]: 'java-A-seed', urls[1]: 'java-B-seed'};
  final sources = <String, Object?>{};
  final rows = <Map<String, Object?>>[];
  for (var index = 0; index < urls.length; index++) {
    final url = urls[index];
    final own = stateSessionJavaPolicyKeys[index];
    final other = stateSessionJavaPolicyKeys[1 - index];
    sources[url] = {
      'java': {own: expected[url], other: ''},
      'source': {own: expected[url], other: ''},
    };
    rows.add({
      'source': url,
      'key': 'v_${url}_$own',
      'present': true,
      'value': expected[url],
      'deadline': 0,
    });
    rows.add({
      'source': url,
      'key': 'v_${url}_$other',
      'present': false,
      'value': null,
      'deadline': null,
    });
  }
  return {
    'phase': phase,
    'policy': 'synthetic ADR 0011 per-source java policy receipt; product-only',
    'keys': stateSessionJavaPolicyKeys,
    'expected': expected,
    'sources': sources,
    'rows': rows,
    'verdict': 'pass',
  };
}

Map<String, dynamic> _handoff({
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required Map<String, dynamic> seed,
  required Map<String, dynamic> restart,
}) {
  final target = stateSessionTargetOf(corpus);
  return {
    'status': 'captured',
    'corpus': {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'sha256Lf': corpusLf,
    },
    'target': {
      'package': target['package'],
      'apkSha256': target['apkSha256'],
      'baselineCommit': target['baselineCommit'],
    },
    'harness': {'sha256': _harnessSha},
    'seed': {'sha256': 'a' * 64, 'pid': seed['pid'], 'runId': seed['runId']},
    'restart': {
      'sha256': 'b' * 64,
      'pid': restart['pid'],
      'runId': restart['runId'],
    },
  };
}
