import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/nested_oracle_compare.dart';

void main() {
  test('the committed JSLIB corpora have valid structure and unique row ids', () {
    for (final path in [jsLibCorpusPath, jsLibSelectedCorpusPath]) {
      final corpus = loadJsLibCorpus(path);
      final target = (corpus['target'] as Map).cast<String, dynamic>();
      final corpusSha256 = jsLibCorpusSha256(File(path));

      expect(corpus['schemaVersion'], 1);
      expect(corpus['fixtureId'], 'JSLIB-01');
      expect(corpus['baselineCommit'], isNotEmpty);
      expect(corpus['entryPoint'], isNotEmpty);
      expect(corpus['jsLib'], isNotEmpty);
      expect(target['apkSha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(target['baselineCommit'], corpus['baselineCommit']);
      final steps = corpus['steps'] as List;
      expect(steps, isNotEmpty);
      final ids = [for (final step in steps) (step as Map)['id']];
      expect(ids.toSet().length, ids.length);
      expect(corpusSha256, matches(RegExp(r'^[0-9a-f]{64}$')));
    }
  });
}
