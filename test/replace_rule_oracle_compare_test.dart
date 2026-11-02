import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/replace_rule_oracle/compare.dart';

void main() {
  late Map<String, dynamic> fixture;
  late Map<String, dynamic> committedReport;
  late List<Map<String, Object?>> product;
  late Map<String, dynamic> synthetic;
  setUp(() {
    fixture =
        jsonDecode(
              File('tool/replace_rule_oracle/fixtures.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    committedReport =
        jsonDecode(
              File(
                'tool/replace_rule_oracle/evidence/comparison.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    // Synthetic values test verdict mechanics only; never frozen evidence.
    product = [
      for (final row in fixture['cases'] as List)
        {
          'id': row['id'],
          'status': 'observed',
          'title': 'title',
          'content': '　　body',
          'selection': {'title': <String>[], 'content': <String>[]},
          'disabledRules': <String>[],
        },
    ];
    synthetic = {
      for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit'])
        key: fixture[key],
      'fixtureSha256': 'synthetic-test-hash',
      'boundary': fixture['comparisonBoundary'],
      'cleanup': {'databaseClosed': true, 'scratchRemoved': true},
      'rows': jsonDecode(jsonEncode(product)),
    };
  });
  Map<String, Object?> compare(Map<String, dynamic>? golden) => compareRows(
    fixture,
    product,
    golden,
    fixtureSha256: 'synthetic-test-hash',
  );

  test('selected corpus cannot admit a legacy-only golden envelope', () {
    fixture =
        jsonDecode(
              File(
                'tool/replace_rule_oracle/fixtures-selected.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    synthetic.addAll({
      'corpusVersion': fixture['corpusVersion'],
      'baselineCommit': fixture['baselineCommit'],
    });
    expect(() => compare(synthetic), throwsFormatException);
    expect((compare(null)['counts'] as Map)['not-run'], 15);
    synthetic['identity'] = {
      'targetPackage': 'com.legado.app.debug',
      'targetApkSha256': (fixture['target'] as Map)['apkSha256'],
      'harnessPackage': 'io.liber.oracle.replace.selected',
      'corpusSha256Lf': 'synthetic-test-hash',
      'harnessApkSha256': 'a' * 64,
      'corpusAssetSha256': 'b' * 64,
      'provenanceAssetSha256': 'd' * 64,
    };
    synthetic['provenance'] = {
      'baselineCommit': fixture['baselineCommit'],
      'corpusAssetSha256': 'b' * 64,
      'corpusSha256Lf': 'synthetic-test-hash',
      'dexSha256': 'e' * 64,
      'sourceHashes': {
        for (final name in selectedReaderSourcePaths) name: 'f' * 64,
      },
      'sourceHashesLf': {
        for (final name in selectedReaderSourcePaths)
          name: sha256LfFile(File(name)),
      },
      'referenceHashes': {
        for (final r in fixture['frozenSources'] as List)
          r['path']: r['sha256'],
      },
    };
    synthetic['hostCapture'] = {
      'existingDataHashesUnchanged': true,
      'harnessRemoved': true,
      'installedHarnessSha256': 'a' * 64,
      'preflight': {
        'harnessApkSha256': 'a' * 64,
        'provenanceAssetSha256': 'd' * 64,
        for (final entry in (synthetic['provenance'] as Map).entries)
          if (entry.key != 'baselineCommit') entry.key: entry.value,
      },
    };
    synthetic['hostInitialization'] = {
      'verified': true,
      'applicationAttached': false,
      'method': (fixture['hostInitialization'] as Map)['method'],
      'registeredWrappers': {
        for (final r
            in (fixture['hostInitialization'] as Map)['registrations'] as List)
          r['type']: r['factory'],
      },
    };
    synthetic['isolation'] = {
      'verified': true,
      'application': 'io.liber.oracle.nested.GuardedReaderApplication',
      'preferenceProbe': {
        'registered': true,
        'committed': true,
        'scopedFile': true,
        'installationFile': false,
      },
    };
    synthetic['startupContainment'] = {
      'intercepted': 1,
      'handled': 1,
      'beforeBinding': true,
    };
    synthetic['entryPoints'] = {
      'getContentArity': 10,
      'getDisplayTitleArity': 4,
      'getDisplayTitle':
          'synthetic getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)',
      'getContent':
          'synthetic getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)',
    };
    synthetic['terminalOwner'] = {
      'scope': 'Coroutine.DEFAULT',
      'rootActive': true,
      'rootCompleted': false,
      'baselineChildren': 0,
      'childrenMethod':
          'kotlin.sequences.Sequence kotlinx.coroutines.Job.getChildren()',
      'completionMethod': 'boolean kotlinx.coroutines.Job.isCompleted()',
    };
    synthetic['settingsBefore'] = {
      'backupPath': null,
      'paragraphIndent': '　　',
      'adaptSpecialStyle': true,
      'chineseConverterType': 0,
      'replaceEnableDefault': true,
    };
    synthetic['paragraphIndent'] = '　　';
    synthetic['fingerprint'] = selectedReaderFingerprint;
    synthetic['cleanup'] = {
      'databaseClosed': true,
      'scratchRemoved': true,
      'terminalProved': true,
      'activityLaunchAttempts': 0,
      'scratchRetained': false,
      'preferencesRemoved': [
        {'name': 'liber_replace_selected_probe', 'ok': true},
      ],
    };
    for (final row in synthetic['rows'] as List) {
      row['terminal'] = {
        'allCompleted': true,
        'rootEmpty': true,
        'launchAttempts': 0,
      };
      row['readerCalls'] = [
        {
          'method': 'getDisplayTitle',
          'allCompleted': true,
          'rootEmpty': true,
          'launchAttempts': 0,
        },
        {
          'method': 'getContent',
          'allCompleted': true,
          'rootEmpty': true,
          'launchAttempts': 0,
        },
      ];
      row['textList'] = <String>['　　body'];
      row['sameTitleRemoved'] = false;
      row['effectiveRules'] = <String>[];
      row['disabledRules'] = <String>[];
      if (row['id'] == 'timeout') {
        row['timeoutObserved'] = false;
        row['restartObservation'] = 'notCompared: synthetic';
      }
    }
    expect((compare(synthetic)['counts'] as Map)['fail'], 0);
    final firstFrozenRow = (synthetic['rows'] as List).first as Map;
    for (final valid in [
      null,
      <String>[],
      <String>['rule'],
    ]) {
      firstFrozenRow['effectiveRules'] = valid;
      expect((compare(synthetic)['counts'] as Map)['fail'], 0);
    }
    for (final invalid in [
      42,
      {'name': 'rule'},
      ['rule', 42],
    ]) {
      firstFrozenRow['effectiveRules'] = invalid;
      expect(
        () => compare(synthetic),
        throwsFormatException,
        reason: '$invalid',
      );
    }
    firstFrozenRow['effectiveRules'] = <String>[];
    product.first['disabledRules'] = ['wrong'];
    expect((compare(synthetic)['counts'] as Map)['fail'], 1);
    product.first['disabledRules'] = <String>[];
    final corruptions = <void Function(Map<String, dynamic>)>[
      (x) => (x['hostCapture'] as Map)['existingDataHashesUnchanged'] = false,
      (x) => (x['hostCapture'] as Map)['installedHarnessSha256'] = 'bad',
      (x) => (x['identity'] as Map)['targetApkSha256'] = 'wrong',
      (x) => (x['identity'] as Map)['corpusSha256Lf'] = 'wrong',
      (x) => (x['identity'] as Map)['harnessApkSha256'] = 'bad',
      (x) => (x['provenance'] as Map)['dexSha256'] = 'bad',
      (x) =>
          (x['provenance']
                  as Map)['sourceHashesLf'][selectedReaderSourcePaths.first] =
              'a' * 64,
      (x) => (x['hostInitialization'] as Map)['registeredWrappers'] = {},
      (x) =>
          (x['isolation'] as Map)['preferenceProbe']['installationFile'] = true,
      (x) => (x['hostInitialization'] as Map)['verified'] = false,
      (x) => (x['isolation'] as Map)['application'] = 'android.app.Application',
      (x) => (x['startupContainment'] as Map)['handled'] = 0,
      (x) => (x['entryPoints'] as Map)['getContentArity'] = 7,
      (x) => (x['settingsBefore'] as Map)['backupPath'] = 'occupied',
      (x) => x['fingerprint'] = 'wrong',
      (x) => x['paragraphIndent'] = ' ',
      (x) => (x['terminalOwner'] as Map)['baselineChildren'] = 1,
      (x) => (x['cleanup'] as Map)['activityLaunchAttempts'] = 1,
      (x) => ((x['rows'] as List)[0] as Map)['terminal']['rootEmpty'] = false,
      (x) => ((x['rows'] as List)[0] as Map).remove('textList'),
      (x) => ((x['rows'] as List)[0] as Map)['textList'] = [
        'not the returned content',
      ],
    ];
    for (final corrupt in corruptions) {
      final copy = jsonDecode(jsonEncode(synthetic)) as Map<String, dynamic>;
      corrupt(copy);
      expect(() => compare(copy), throwsFormatException);
    }
  });

  test('missing frozen evidence leaves every row not-run', () {
    final result = compare(null);
    expect(result['counts'], {
      'pass': 0,
      'fail': 0,
      'notCompared': 0,
      'not-run': 15,
    });
    expect(result['complete'], false);
    final timeout = (result['rows'] as List).cast<Map>().singleWhere(
      (row) => row['id'] == 'timeout',
    );
    expect(timeout['comparison'], 'notCompared');
    expect(timeout['timeoutCoverage'], startsWith('not-run'));
  });
  test('does not trim indent or drop blank lines to hide a mismatch', () {
    product.first['content'] = 'body\n\n';
    final result = compare(synthetic);
    final row = (result['rows'] as List).first as Map;
    expect(row['status'], 'fail');
    expect(row['differences'], [
      {'field': 'content', 'frozen': '　　body', 'product': 'body\n\n'},
    ]);
  });
  test(
    'rejects stale fixture hashes, missing, duplicate and reordered rows',
    () {
      synthetic['fixtureSha256'] = 'stale';
      expect(() => compare(synthetic), throwsFormatException);
      synthetic['fixtureSha256'] = 'synthetic-test-hash';
      final rows = synthetic['rows'] as List;
      final first = rows.removeAt(0);
      expect(() => compare(synthetic), throwsFormatException);
      rows.insert(0, rows.first);
      expect(() => compare(synthetic), throwsFormatException);
      rows[0] = first;
      final second = rows[1];
      rows[1] = rows[0];
      rows[0] = second;
      expect(() => compare(synthetic), throwsFormatException);
    },
  );
  test('rejects incomplete cleanup and wrong boundary', () {
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': false};
    expect(() => compare(synthetic), throwsFormatException);
    synthetic['cleanup'] = {'databaseClosed': true, 'scratchRemoved': true};
    synthetic['boundary'] = 'intermediate content';
    expect(() => compare(synthetic), throwsFormatException);
  });
  test('selection order and title remain strict observations', () {
    product[8]['selection'] = {
      'title': <String>[],
      'content': ['stable-tie', 'later'],
    };
    product[2]['title'] = 'wrong';
    final result = compare(synthetic);
    expect((result['counts'] as Map)['fail'], 2);
  });
  test('conversion policy does not silently accept arbitrary differences', () {
    product[11]['content'] = 'different';
    final result = compare(synthetic);
    expect(((result['rows'] as List)[11] as Map)['status'], 'fail');
  });
  test('policy rows preserve both exact outputs and timeout coverage gap', () {
    product.last['content'] = 'unsupported-pattern-retained';
    final result = compare(synthetic);
    final row = (result['rows'] as List).last as Map;
    expect(row['status'], 'notCompared');
    expect((row['differences'] as List).single['frozen'], '　　body');
    expect(result['complete'], false);
  });
  test('product errors cannot be promoted by equal fields', () {
    product.first['status'] = 'error';
    expect(
      ((compare(synthetic)['rows'] as List).first as Map)['status'],
      'fail',
    );
  });
  test('the committed report still describes the committed corpus', () {
    // The committed evidence is a result record, not a golden (#70): it is
    // evidence *for the corpus it names*. Every branch of the guard is
    // exercised — a corpus edit that changes the row set, the row order, the
    // identity or the boundary, a stale pin, and a report that stops naming this
    // corpus — so none of them can silently leave the recorded run describing a
    // corpus that no longer exists.
    final corpusSha256 = sha256CrlfFile(
      File('tool/replace_rule_oracle/fixtures.json'),
    );
    checkReportMatchesFixture(
      fixture,
      committedReport,
      fixtureSha256: corpusSha256,
    );
    expect(committedReport['fixtureSha256'], corpusSha256);
    Map<String, dynamic> fixtureCopy(void Function(Map<String, dynamic>) edit) {
      final copy = jsonDecode(jsonEncode(fixture)) as Map<String, dynamic>;
      edit(copy);
      return copy;
    }

    Map<String, dynamic> reportCopy(void Function(Map<String, dynamic>) edit) {
      final copy =
          jsonDecode(jsonEncode(committedReport)) as Map<String, dynamic>;
      edit(copy);
      return copy;
    }

    final corpusEdits = <String, Map<String, dynamic>>{
      'a case removed': fixtureCopy(
        (copy) => (copy['cases'] as List).removeLast(),
      ),
      'two cases reordered': fixtureCopy((copy) {
        final cases = copy['cases'] as List;
        cases.insert(0, cases.removeAt(1));
      }),
      'another fixtureId': fixtureCopy(
        (copy) => copy['fixtureId'] = 'REPLACE-18',
      ),
      'another comparisonBoundary': fixtureCopy(
        (copy) => copy['comparisonBoundary'] = 'intermediate content',
      ),
    };
    for (final entry in corpusEdits.entries) {
      expect(
        () => checkReportMatchesFixture(
          entry.value,
          committedReport,
          fixtureSha256: corpusSha256,
        ),
        throwsFormatException,
        reason: entry.key,
      );
    }
    expect(
      () => checkReportMatchesFixture(
        fixture,
        committedReport,
        fixtureSha256: 'stale',
      ),
      throwsFormatException,
      reason: 'a stale corpus pin',
    );
    expect(
      () => checkReportMatchesFixture(
        fixture,
        reportCopy(
          (copy) => ((copy['rows'] as List).first as Map)['id'] = 'other',
        ),
        fixtureSha256: corpusSha256,
      ),
      throwsFormatException,
      reason: 'a report row that no longer names a corpus case',
    );
  });
  test('the committed report is refused as an input, not blamed on the corpus', () {
    // The ticket's repro fed evidence/comparison.json in as a golden. The
    // refusal has to name what the input is missing, not misattribute it to the
    // fixture.
    expect(
      () => compare(committedReport),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          allOf(contains('Not a frozen golden'), contains('corpusVersion')),
        ),
      ),
      reason: 'no capture envelope at all',
    );
    Map<String, dynamic> withEnvelope([
      void Function(Map<String, dynamic>)? edit,
    ]) {
      final copy =
          jsonDecode(jsonEncode(committedReport)) as Map<String, dynamic>;
      copy.addAll({
        for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit'])
          key: fixture[key],
        'fixtureSha256': 'synthetic-test-hash',
        'boundary': fixture['comparisonBoundary'],
        'cleanup': {'databaseClosed': true, 'scratchRemoved': true},
      });
      edit?.call(copy);
      return copy;
    }

    // An envelope that is present but names another corpus is its own refusal.
    expect(
      () => compare(withEnvelope((copy) => copy['corpusVersion'] = 2)),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('captured against another corpus'),
        ),
      ),
      reason: 'an envelope from another corpus',
    );
    // With the envelope repaired the rows still hold verdicts, and that gap is
    // named too instead of turning every frozen row into a silent not-run.
    expect(
      () => compare(withEnvelope()),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('status is `pass`'),
        ),
      ),
      reason: 'verdict rows where a golden holds observations',
    );
  });
}
