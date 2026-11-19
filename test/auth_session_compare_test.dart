import 'package:flutter_test/flutter_test.dart';

import '../tool/auth_session/runner.dart';

bool _stepMatches(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  String path,
  String rawQuery,
) {
  final kind = '${step['kind']}';
  if (kind == 'login') {
    final source = authSessionSourceOf(corpus, '${step['source']}');
    final origin = Uri.parse(authSessionSourceUrl(source));
    return path == '${origin.path}/login';
  }
  if (kind != 'stage') return false;
  final source = authSessionSourceOf(corpus, '${step['source']}');
  final origin = Uri.parse(authSessionSourceUrl(source));
  switch ('${step['stage']}') {
    case 'search':
      return path == '${origin.path}/search' &&
          rawQuery.contains('keyword=${step['keyword']}');
    case 'details':
      final book = authSessionBookOf(corpus, '${step['book']}');
      return path == Uri.parse('${book['bookUrl']}').path;
    case 'toc':
      final book = authSessionBookOf(corpus, '${step['book']}');
      return path == '${Uri.parse('${book['bookUrl']}').path}/toc';
    case 'content':
      return path == Uri.parse('${step['chapter']}').path;
  }
  return false;
}

List<String> _stagePerRequest(Map<String, dynamic> corpus, String phase) {
  final steps = authSessionSteps(corpus, phase);
  final requests = authSessionExpectedRequests(corpus, phase);
  final stages = <String>[];
  var stepIndex = 0;
  for (final request in requests) {
    final path = '${request['path']}';
    final rawQuery = '${request['rawQuery']}';
    var found = -1;
    for (var index = stepIndex; index < steps.length; index++) {
      if (_stepMatches(corpus, steps[index], path, rawQuery)) {
        found = index;
        break;
      }
    }
    if (found < 0) {
      throw StateError('no step declares $path?$rawQuery');
    }
    stepIndex = found;
    stages.add('${steps[found]['id']}');
  }
  return stages;
}

void main() {
  test('the committed AUTH-SESSION-01 corpora validate and name both jar states', () {
    for (final path in [
      authSessionCorpusPath,
      'tool/auth_session/fixtures-selected.json',
    ]) {
      final corpus = loadAuthSessionCorpus(path);
      final flags = [
        for (final source in corpus['sources'] as List)
          ((source as Map)['bookSource'] as Map)['enabledCookieJar'],
      ];
      expect(flags, [true, false], reason: path);
      for (final phase in ['seed', 'restart']) {
        final stages = _stagePerRequest(corpus, phase);
        final requests = authSessionExpectedRequests(corpus, phase);
        expect(stages.length, requests.length);
        expect(
          () => authSessionRequestStages(corpus, phase, [
            for (var index = 0; index < requests.length; index++)
              {...requests[index], 'stage': stages[index]},
          ], 'requests'),
          returnsNormally,
        );
      }
    }
  });
}
