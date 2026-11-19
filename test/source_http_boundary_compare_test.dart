import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tool/http_boundary/runner.dart'
    show
        httpBoundaryDeclaredRequests,
        httpBoundarySteps,
        httpBoundaryStructuralOf,
        loadHttpBoundaryCorpus;

void main() {
  test('the committed corpus derives the declared structural model', () {
    final corpus = loadHttpBoundaryCorpus();
    final derived = httpBoundaryStructuralOf(corpus);
    expect(derived['observations'], 44);
    expect(derived['requests'], 51);
    expect(derived['responses'], 49);
    expect(derived['helperSelectors'], 12);
    expect(derived['rateSelectors'], 3);
    expect(derived['stageSelectors'], 34);
    expect(derived['stageRequests'], 36);
    expect(derived['requestsExceedingSelectors'], 2);
    final declared = (corpus['structural'] as Map).cast<String, dynamic>();
    for (final entry in derived.entries) {
      if (entry.key == 'requestsExceedingSelectorsReason') continue;
      expect(jsonEncode(entry.value), jsonEncode(declared[entry.key]));
    }
    final steps = (corpus['steps'] as List).cast<Map>();
    final repeated = [
      for (final step in steps)
        if (httpBoundaryDeclaredRequests(
              step.cast<String, dynamic>(),
            ).ordered.toSet().length !=
            httpBoundaryDeclaredRequests(
              step.cast<String, dynamic>(),
            ).ordered.length)
          '${step['id']}',
    ];
    expect(repeated, ['s2.retry-non2xx']);
  });

  test('the committed corpus declares the v3 interop observation rows', () {
    final corpus = loadHttpBoundaryCorpus();
    expect(corpus['corpusVersion'], 3);
    final steps = httpBoundarySteps(corpus);
    final probes = [
      for (final step in steps)
        if (step['action'] == 'scriptProbe') step,
    ];
    expect(probes, hasLength(4));
    for (final id in const [
      'helper.script-probe-hg0',
      'helper.script-probe-hg1',
      'helper.script-probe-hg2',
      'helper.script-probe-hg3',
    ]) {
      final probe = probes.firstWhere((step) => step['id'] == id);
      expect('${probe['script']}', contains('source.getHeaderMap(false)'));
      final declared = httpBoundaryDeclaredRequests(probe);
      expect(declared.ordered, isEmpty);
      expect(declared.members, isEmpty);
    }
    final fresh = [
      for (final step in steps)
        if (step['carrier'] == 'fresh') step,
    ];
    expect(fresh, hasLength(1));
    expect(fresh.single['stage'], 'details');
    expect(fresh.single['id'], 'o1.details-fresh');
  });

  test('the selected-reference corpus loads with its declared rate schedule', () {
    final selected = loadHttpBoundaryCorpus(
      'tool/http_boundary/fixtures-selected.json',
    );
    expect(selected['corpusVersion'], 4);
    expect((selected['target'] as Map)['package'], 'com.legado.app.debug');
    final rate = selected['rate'] as Map;
    expect(rate['recordFields'], ['time', 'frequency']);
    final schedule = (rate['schedule'] as List).cast<Map>();
    expect(
      [for (final row in schedule) row['window']],
      ['opens', 'rolls', 'rolls'],
    );
    expect((selected['runtime'] as Map)['threadCountDefault'], 32);
    expect(selected['hostInitialization'], isA<Map>());
  });
}
