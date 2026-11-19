import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

import '../tool/html_adapter_gate.dart' as gate;
import 'native_library.dart';

Map<String, Object?> _observedById(Map<String, Object?> report) => {
  for (final row in (report['observations'] as List).cast<Map>())
    row['id'] as String: row['value'],
};

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'selected corpora expose product observations without claiming parity',
    () async {
      for (final (path, count) in [
        ('tool/html_oracle/fixtures-selected.json', 45),
        ('tool/html_oracle/list-fixtures-selected.json', 11),
      ]) {
        final report = await gate.runHtmlAdapterGate(
          libraryPath: nativeLibraryPath(),
          corpusPath: path,
        );
        expect(report['status'], 'not-run');
        expect(report['frozenGolden'], 'not-run');
        expect(report['observations'], hasLength(count));
      }
    },
  );

  test(
    'the committed HTML-LIST-01 corpus measures typed list values',
    () async {
      final report = await gate.runHtmlAdapterGate(
        libraryPath: nativeLibraryPath(),
        corpusPath: gate.htmlListCorpusPath,
      );

      expect(report['status'], 'pass');
      expect(report['corpusPath'], gate.htmlListCorpusPath);
      expect(report['corpusFixtureId'], gate.htmlListFixtureId);
      expect(report['corpusVersion'], gate.htmlListCorpusVersion);
      expect(report['frozenGolden'], 'not-run');
      expect(report['cases'], 11);
      expect(report['expectationMismatches'], isEmpty);

      final observed = _observedById(report);
      expect(observed['html-list-ordered-hrefs'], ['/1', '/2', '/3']);
      expect(observed['html-scalar-twin-ordered-hrefs'], '/1\n/2\n/3');
      expect(observed['html-list-declared-order'], ['/3', '/1', '/2']);
      expect(observed['html-list-per-item-replacement'], [
        '/page/1',
        '/page/2',
        '/page/3',
      ]);
      expect(
        observed['html-scalar-joined-replacement-twin'],
        '/page/1\n/2\n/3',
      );
      expect(observed['html-list-empty'], <String>[]);
      expect(observed['html-list-url-empty'], <String>[]);
      expect(observed['html-list-entity-no-unescape'], ['A&amp;B']);
      expect(observed['html-scalar-entity-twin'], 'A&B');
      expect(observed['json-list-string-names'], ['甲', '乙']);
      expect(observed['json-scalar-string-twin'], '甲\n乙');

      for (final (listId, scalarId) in [
        ('html-list-ordered-hrefs', 'html-scalar-twin-ordered-hrefs'),
        (
          'html-list-per-item-replacement',
          'html-scalar-joined-replacement-twin',
        ),
        ('json-list-string-names', 'json-scalar-string-twin'),
      ]) {
        expect(observed[listId], isA<List<String>>());
        expect(observed[scalarId], isA<String>());
        expect(
          jsonEncode(observed[listId]),
          isNot(jsonEncode(observed[scalarId])),
        );
      }
    },
  );

  test('the unchanged default corpus keeps its 45-case identity', () async {
    final report = await gate.runHtmlAdapterGate(
      libraryPath: nativeLibraryPath(),
    );

    expect(report['status'], 'pass');
    expect(report['corpusPath'], gate.legacyHtmlCorpusPath);
    expect(report['cases'], 45);
    expect(report['expectationMismatches'], isEmpty);
  });

  test('the committed legacy golden still compares 45 cases', () async {
    final report = await gate.runHtmlAdapterGate(
      libraryPath: nativeLibraryPath(),
      corpusPath: gate.legacyHtmlCorpusPath,
      goldenPath: 'tool/html_oracle/evidence/android-17-os4.0.0.31/golden.json',
    );

    expect(report['status'], 'pass');
    expect(report['cases'], 45);
    expect(report['frozenMismatches'], isEmpty);
  });
}
