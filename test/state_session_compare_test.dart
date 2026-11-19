import 'package:flutter_test/flutter_test.dart';

import '../tool/state_session/runner.dart';

void main() {
  test('the committed corpus is a complete STATE-SESSION-01 case graph', () {
    final corpus = loadStateSessionCorpus();
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
  });

  test('the selected-reference STATE-SESSION-01 corpus loads cleanly', () {
    final selected = loadStateSessionCorpus(stateSessionSelectedCorpusPath);
    expect(selected['fixtureId'], 'STATE-SESSION-01');
    expect(stateSessionTargetOf(selected)['package'], 'com.legado.app.debug');
  });
}
