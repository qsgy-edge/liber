import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';

import '../tool/replace_js_oracle/compare.dart';
import 'native_library.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(InProcessSourceScriptRuntime.dispose);

  Map<String, dynamic> errorFixture({bool title = false}) {
    final fixture =
        jsonDecode(
              File('tool/replace_js_oracle/fixtures.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    final row = (fixture['cases'] as List).singleWhere(
      (row) => row['id'] == 'js-error',
    );
    fixture['cases'] = [row];
    if (title) {
      row['chapterTitle'] = '广告标题';
      row['rules'][0]['scopeTitle'] = true;
      row['rules'][0]['scopeContent'] = false;
    }
    return fixture;
  }

  test(
    'real corpus capture fails closed when recorded notices are removed',
    () async {
      final fixtureFile = File('tool/replace_js_oracle/fixtures.json');
      final fixture =
          jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
      final golden =
          jsonDecode(
                File(
                  'tool/replace_js_oracle/evidence/android-17-os4.0.0.31/golden.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final product = await observeProduct(fixture);
      Map<String, Object?> compare(List<Map<String, Object?>> captured) =>
          compareRows(
            fixture,
            captured,
            golden,
            fixtureSha256: sha256File(fixtureFile),
          );
      expect(compare(product)['counts'], {
        'pass': 11,
        'fail': 0,
        'notCompared': 2,
        'not-run': 0,
      });
      for (final id in ['js-error', 'js-timeout']) {
        for (final invalid in <Object?>[
          null,
          <String>[],
          'wrong type',
          <String>[' '],
        ]) {
          final damaged = [
            for (final row in product) <String, Object?>{...row},
          ];
          final row = damaged.singleWhere((row) => row['id'] == id);
          if (invalid == null) {
            row.remove('notices');
          } else {
            row['notices'] = invalid;
          }
          final report = compare(damaged);
          final result = (report['rows'] as List).cast<Map>().singleWhere(
            (row) => row['id'] == id,
          );
          expect(
            result['status'],
            'fail',
            reason: '$id ${jsonEncode(invalid)}',
          );
          expect(result['noticeCaptureIntegrity']['status'], 'fail');
          expect(result['noticeChannelComparison'], 'notCompared');
          expect((report['counts'] as Map)['fail'], 1);
        }
      }
    },
  );

  test(
    'observeProduct snapshots notices after real content processing',
    () async {
      final row = (await observeProduct(errorFixture())).single;
      expect(row['status'], 'observed');
      expect(row['content'], '　　正文广告。');
      expect(row['rulesDisabledByRun'], isEmpty);
      expect(
        row['notices'],
        contains(
          allOf(startsWith('replaceRuleFailed('), contains('Error: boom')),
        ),
      );
    },
  );

  test('observeProduct includes real title processing notices', () async {
    final row = (await observeProduct(errorFixture(title: true))).single;
    expect(row['status'], 'observed');
    expect(row['title'], '广告标题');
    expect(row['notices'], hasLength(1));
    expect((row['notices'] as List).single, contains('Error: boom'));
  });

  test(
    'observeProduct retains title notices when content capture throws',
    () async {
      final fixture = errorFixture(title: true);
      // The malformed input throws at the content call, after the real title
      // processor has reported the script error. It is not frozen evidence.
      fixture['cases'][0]['rawContent'] = null;
      final row = (await observeProduct(fixture)).single;
      expect(row['status'], 'error');
      expect(row['error'], isNotEmpty);
      expect(row['title'], '广告标题');
      expect(row['notices'], hasLength(1));
      expect((row['notices'] as List).single, contains('Error: boom'));
    },
  );
}
