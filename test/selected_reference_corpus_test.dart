import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/nested_oracle_compare.dart' as jslib;
import '../tool/state_session/compare.dart' as state;
import '../tool/state_session/runner.dart' as runner;

/// Focused checks for the two selected-reference corpora (#146) and the
/// admission both comparators apply to a capture of them.
///
/// The goldens below are synthetic records that exercise the refusal paths;
/// nothing here is a frozen capture, and the committed historical corpora keep
/// their own baselines and goldens.
const _selectedCommit = 'a7d37f1707a70a459ad708f4fe79341d1e42d716';
const _selectedApk =
    '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5';
const _harnessSha =
    '1111111111111111111111111111111111111111111111111111111111111111';

/// The refusal text of a comparator call, or `''` when it accepted the input.
String _refusalOf(void Function() call) {
  try {
    call();
    return '';
  } on FormatException catch (error) {
    return error.message;
  }
}

Map<String, dynamic> _object(Object? value) =>
    (value as Map).cast<String, dynamic>();

void main() {
  test('selected JSLIB has a dedicated storage-only instrumentation entry', () {
    final manifest = File(
      'tool/nested_oracle/AndroidManifest.xml',
    ).readAsStringSync();
    final selected = File(
      'tool/nested_oracle/SelectedJsLibOracle.java',
    ).readAsStringSync();
    final collector = File(
      'tool/nested_oracle/NestedOracle.java',
    ).readAsStringSync();
    expect(manifest, contains('io.liber.oracle.nested.SelectedJsLibOracle'));
    expect(selected, contains('boolean storageOnly()'));
    expect(selected, contains('return true;'));
    expect(
      collector,
      contains('if (!storageOnly()) return super.newApplication'),
    );
    expect(collector, contains('if (scratch == null || !scratch.isBound())'));
  });
  test('fresh scratch preferences refuse existing files including backups', () {
    final scratch = File(
      'tool/nested_oracle/StateSessionOracle.java',
    ).readAsStringSync();
    expect(
      scratch,
      contains('preferenceFile.exists() || preferenceBackup.exists()'),
    );
  });

  test('selected state has a dedicated fixed-corpus instrumentation entry', () {
    final manifest = File(
      'tool/nested_oracle/AndroidManifest.xml',
    ).readAsStringSync();
    final selected = File(
      'tool/nested_oracle/SelectedStateSessionOracle.java',
    ).readAsStringSync();
    final collector = File(
      'tool/nested_oracle/StateSessionOracle.java',
    ).readAsStringSync();
    expect(
      manifest,
      contains('io.liber.oracle.nested.SelectedStateSessionOracle'),
    );
    expect(selected, contains('boolean selectedCorpus()'));
    expect(selected, contains('return true;'));
    expect(
      collector,
      contains('asset = selectedCorpus() ? ASSET_SELECTED : ASSET'),
    );
  });

  test('the JSLIB selected corpus keeps the historical rows and pins the '
      'selected reference', () {
    final historical = jslib.loadJsLibCorpus();
    final selected = jslib.loadJsLibCorpus(jslib.jsLibSelectedCorpusPath);
    expect(selected['fixtureId'], historical['fixtureId']);
    expect(selected['corpusVersion'], (historical['corpusVersion'] as int) + 1);
    expect(selected['baselineCommit'], _selectedCommit);
    expect(historical['baselineCommit'], isNot(_selectedCommit));
    final target = _object(selected['target']);
    expect(target['package'], 'com.legado.app.debug');
    expect(target['apkSha256'], _selectedApk);
    expect(target['baselineCommit'], _selectedCommit);
    // The scenario inputs are the historical ones: no row was added, removed or
    // rewritten for the new reference.
    expect(selected['jsLib'], historical['jsLib']);
    expect(selected['steps'], historical['steps']);
  });

  test(
    'the JSLIB selected corpus declares the host initialization it needs',
    () {
      final selected = jslib.loadJsLibCorpus(jslib.jsLibSelectedCorpusPath);
      expect(jslib.loadJsLibCorpus().containsKey('hostInitialization'), false);
      final init = _object(selected['hostInitialization']);
      expect(init['method'], 'io.legado.app.App#initRhino()');
      final registrations = (init['registrations'] as List).cast<Map>();
      expect(registrations.map((row) => row['type']).toSet(), {
        'io.legado.app.data.entities.BookSource',
        'io.legado.app.data.entities.RssSource',
        'io.legado.app.data.entities.HttpTTS',
        'io.legado.app.data.entities.rule.ExploreRule',
        'io.legado.app.data.entities.rule.SearchRule',
        'io.legado.app.data.entities.rule.BookInfoRule',
        'io.legado.app.data.entities.rule.ContentRule',
        'io.legado.app.data.entities.BookChapter',
        'io.legado.app.data.entities.Book\$ReadConfig',
      });
      expect(
        registrations
            .where((row) => row['factory'] == 'native-base-source')
            .map((row) => row['type'])
            .toSet(),
        {
          'io.legado.app.data.entities.BookSource',
          'io.legado.app.data.entities.RssSource',
          'io.legado.app.data.entities.HttpTTS',
        },
      );
    },
  );

  test('the state selected corpus keeps the historical case graph and pins '
      'the selected reference', () {
    final historical = runner.loadStateSessionCorpus();
    final selected = runner.loadStateSessionCorpus(
      runner.stateSessionSelectedCorpusPath,
    );
    expect(selected['fixtureId'], historical['fixtureId']);
    expect(selected['corpusVersion'], (historical['corpusVersion'] as int) + 1);
    expect(selected['baselineCommit'], _selectedCommit);
    expect(historical['baselineCommit'], isNot(_selectedCommit));
    final target = runner.stateSessionTargetOf(selected);
    expect(target['package'], 'com.legado.app.debug');
    expect(target['apkSha256'], _selectedApk);
    expect(target['baselineCommit'], _selectedCommit);
    for (final key in [
      'entryPoint',
      'origin',
      'keyword',
      'scratch',
      'sources',
      'books',
      'cacheKeys',
      'responses',
      'phases',
      'coverageGaps',
    ]) {
      expect(selected[key], historical[key], reason: key);
    }
    expect(selected['hostInitialization'], isNotNull);
    expect(historical.containsKey('hostInitialization'), false);
  });

  test('a declared host initialization needs no registration to be named', () {
    final directory = Directory.systemTemp.createTempSync('liber-corpus-');
    addTearDown(() => directory.deleteSync(recursive: true));
    final selected = File(jslib.jsLibSelectedCorpusPath).readAsStringSync();
    final withoutRegistrations = (jsonDecode(selected) as Map<String, dynamic>)
      ..['hostInitialization'] = {
        'method': 'io.legado.app.App#initRhino()',
        'registrations': <Object?>[],
      };
    File(
      '${directory.path}${Platform.pathSeparator}corpus.json',
    ).writeAsStringSync(jsonEncode(withoutRegistrations));
    expect(
      () => jslib.loadJsLibCorpus(
        '${directory.path}${Platform.pathSeparator}corpus.json',
      ),
      throwsFormatException,
    );
  });

  test('a JSLIB capture of the selected corpus must record verified host '
      'initialization', () {
    final selected = jslib.loadJsLibCorpus(jslib.jsLibSelectedCorpusPath);
    final historical = jslib.loadJsLibCorpus();
    final selectedHash = jslib.jsLibCorpusSha256(
      File(jslib.jsLibSelectedCorpusPath),
    );
    final historicalHash = jslib.jsLibCorpusSha256(File(jslib.jsLibCorpusPath));
    final target = _object(selected['target']);
    final historicalTarget = _object(historical['target']);

    Map<String, dynamic> goldenFor(
      Map<String, dynamic> corpus,
      Map<String, dynamic> pin,
      String hash,
    ) => {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'corpusSha256': hash,
      'provenance': {
        'kind': 'frozen-device-capture',
        'deviceFingerprint': 'synthetic',
        'capturedAt': '2026-10-30T00:00:00+08:00',
        'entryPoint': corpus['entryPoint'],
        'baselineCommit': corpus['baselineCommit'],
        'targetPackage': pin['package'],
        'targetApkPath': '/data/app/base.apk',
        'targetApkSha256': pin['apkSha256'],
      },
    };

    String selectedRefusal(Map<String, dynamic> golden) => _refusalOf(
      () => jslib.checkJsLibGolden(
        corpus: selected,
        corpusSha256: selectedHash,
        golden: golden,
      ),
    );

    expect(
      selectedRefusal(goldenFor(selected, target, selectedHash)),
      contains('host initialization'),
    );
    for (final broken in <Map<String, Object?>>[
      {'verified': false},
      {'verified': true, 'method': 'io.legado.app.App#somethingElse()'},
      {'verified': true, 'invokedOn': 'attached-application'},
      {'verified': true, 'applicationAttached': true},
    ]) {
      final golden = goldenFor(selected, target, selectedHash)
        ..['hostInitialization'] = {
          'method': 'io.legado.app.App#initRhino()',
          'invokedOn': 'unattached-instance',
          'applicationAttached': false,
          'verified': true,
          ...broken,
        };
      expect(selectedRefusal(golden), contains('host initialization'));
    }
    // A verified receipt passes that admission; the capture is then refused (or
    // accepted) by the checks that follow it, never by the initialization.
    final verified = goldenFor(selected, target, selectedHash)
      ..['hostInitialization'] = {
        'method': 'io.legado.app.App#initRhino()',
        'invokedOn': 'unattached-instance',
        'applicationAttached': false,
        'verified': true,
      };
    expect(selectedRefusal(verified), isNot(contains('host initialization')));
    expect(selectedRefusal(verified), contains('selected capture identity'));
    // The historical corpus declares no initialization, so its captures keep
    // the admission they were recorded under.
    expect(
      _refusalOf(
        () => jslib.checkJsLibGolden(
          corpus: historical,
          corpusSha256: historicalHash,
          golden: goldenFor(historical, historicalTarget, historicalHash),
        ),
      ),
      isNot(contains('host initialization')),
    );
  });

  test('a state-session capture of the selected corpus must record verified '
      'host initialization', () {
    final selected = runner.loadStateSessionCorpus(
      runner.stateSessionSelectedCorpusPath,
    );
    final historical = runner.loadStateSessionCorpus();
    final selectedHash = runner.stateSessionCorpusSha256Lf(
      File(runner.stateSessionSelectedCorpusPath),
    );
    final historicalHash = runner.stateSessionCorpusSha256Lf(
      File(runner.stateSessionCorpusPath),
    );
    final target = runner.stateSessionTargetOf(selected);
    final historicalTarget = runner.stateSessionTargetOf(historical);

    Map<String, dynamic> goldenFor(
      Map<String, dynamic> corpus,
      Map<String, dynamic> pin,
      String hash,
    ) => {
      'phase': 'seed',
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'identity': {
        'fixtureId': corpus['fixtureId'],
        'corpusVersion': corpus['corpusVersion'],
        'targetPackage': pin['package'],
        'targetApkSha256': pin['apkSha256'],
        'targetBaselineCommit': corpus['baselineCommit'],
        'corpusAssetSha256': hash,
        'corpusSha256Lf': hash,
        'harnessPackage': 'io.liber.oracle.nested',
        'harnessApkSha256': _harnessSha,
        'targetPinManifest': pin['manifest'],
      },
    };

    String selectedRefusal(Map<String, dynamic> golden) => _refusalOf(
      () => state.checkStateSessionGolden(
        corpus: selected,
        corpusSha256Lf: selectedHash,
        golden: golden,
        phase: 'seed',
      ),
    );

    expect(
      selectedRefusal(goldenFor(selected, target, selectedHash)),
      contains('host initialization'),
    );
    final unverified = goldenFor(selected, target, selectedHash)
      ..['hostInitialization'] = {
        'method': 'io.legado.app.App#initRhino()',
        'invokedOn': 'unattached-instance',
        'applicationAttached': false,
        'verified': false,
      };
    expect(selectedRefusal(unverified), contains('host initialization'));
    final registrations =
        (selected['hostInitialization'] as Map)['registrations'] as List;
    final verified = goldenFor(selected, target, selectedHash)
      ..['hostInitialization'] = {
        'method': 'io.legado.app.App#initRhino()',
        'invokedOn': 'unattached-instance',
        'applicationAttached': false,
        'verified': true,
        'registeredWrappers': {
          for (final raw in registrations)
            '${(raw as Map)['type']}': raw['factory'],
        },
      };
    expect(selectedRefusal(verified), isNot(contains('host initialization')));
    expect(
      _refusalOf(
        () => state.checkStateSessionGolden(
          corpus: historical,
          corpusSha256Lf: historicalHash,
          golden: goldenFor(historical, historicalTarget, historicalHash),
          phase: 'seed',
        ),
      ),
      isNot(contains('host initialization')),
    );
  });

  test(
    'the selected corpora are distinct shipped assets with their own hashes',
    () {
      for (final pair in [
        [jslib.jsLibCorpusPath, jslib.jsLibSelectedCorpusPath],
        [runner.stateSessionCorpusPath, runner.stateSessionSelectedCorpusPath],
      ]) {
        expect(File(pair[0]).existsSync(), true, reason: pair[0]);
        expect(File(pair[1]).existsSync(), true, reason: pair[1]);
        expect(
          File(pair[0]).readAsStringSync(),
          isNot(File(pair[1]).readAsStringSync()),
        );
      }
    },
  );
}
