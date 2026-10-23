import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime;
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';

import '../tool/http_boundary/runner.dart'
    show httpBoundarySourceOf, loadHttpBoundaryCorpus;
import 'native_library.dart';

/// The actual product `source.getHeaderMap(false)` binding over the four
/// committed collision sources. The scripts are the corpus' own, so this proves
/// the probe rows execute through the supported source facade, not a model of
/// it; the compared report remains the controller's capture.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  Future<Map<String, dynamic>> probe(String sourceId) async {
    final corpus = loadHttpBoundaryCorpus();
    final source = httpBoundarySourceOf(corpus, sourceId);
    final step =
        [
          for (final raw in corpus['steps'] as List)
            (raw as Map).cast<String, dynamic>(),
        ].firstWhere(
          (step) =>
              step['id'] == 'helper.script-probe-${sourceId.toLowerCase()}',
        );
    final runtime = InProcessSourceScriptRuntime(
      androidId: 'interop-probe',
      hostState: SourceHostState(),
    );
    final raw = await runtime.evaluate(
      source: '${step['script']}',
      input: {'sourceKey': '${source['bookSourceUrl']}', 'source': source},
      timeout: const Duration(seconds: 60),
    );
    return (jsonDecode('$raw') as Map).cast<String, dynamic>();
  }

  Map<String, dynamic> member(Map<String, dynamic> value, String name) =>
      (value[name] as Map).cast<String, dynamic>();

  test('no collision: both Java Map access forms are callable', () async {
    final value = await probe('HG0');
    expect(member(value, 'getDot')['type'], 'function');
    expect(member(value, 'getBracket')['type'], 'function');
    expect(member(value, 'keySetDot')['type'], 'function');
    expect(member(value, 'keySetBracket')['type'], 'function');
    final lookup = member(value, 'lookup');
    expect(lookup['returned'], isTrue);
    expect(lookup['type'], 'string');
    expect(lookup['strictLiteral'], isTrue);
    expect(lookup['text'], 'hg0');
    final enumeration = member(value, 'enumeration');
    expect(enumeration['returned'], isTrue);
    expect(enumeration['keys'], containsAll(['User-Agent', 'X-Declared']));
  });

  test('an own data key get shadows the method for dot and bracket', () async {
    final value = await probe('HG1');
    expect(member(value, 'getDot')['type'], 'string');
    expect(member(value, 'getDot')['text'], 'data-get');
    expect(member(value, 'getBracket')['type'], 'string');
    expect(member(value, 'getBracket')['text'], 'data-get');
    expect(member(value, 'keySetDot')['type'], 'function');
    final lookup = member(value, 'lookup');
    expect(lookup['returned'], isFalse);
    expect(lookup['errorName'], 'TypeError');
    final enumeration = member(value, 'enumeration');
    expect(enumeration['returned'], isTrue);
    expect(enumeration['keys'], contains('get'));
  });

  test(
    'an own data key keySet shadows the method for dot and bracket',
    () async {
      final value = await probe('HG2');
      expect(member(value, 'keySetDot')['type'], 'string');
      expect(member(value, 'keySetDot')['text'], 'data-keyset');
      expect(member(value, 'keySetBracket')['type'], 'string');
      expect(member(value, 'keySetBracket')['text'], 'data-keyset');
      expect(member(value, 'getDot')['type'], 'function');
      final lookup = member(value, 'lookup');
      expect(lookup['returned'], isTrue);
      expect(lookup['strictLiteral'], isTrue);
      final enumeration = member(value, 'enumeration');
      expect(enumeration['returned'], isFalse);
      expect(enumeration['errorName'], 'TypeError');
    },
  );

  test(
    'both own data keys shadow their methods; user data stays intact',
    () async {
      final value = await probe('HG3');
      expect(member(value, 'getDot')['text'], 'data-get');
      expect(member(value, 'keySetDot')['text'], 'data-keyset');
      expect(member(value, 'lookup')['returned'], isFalse);
      expect(member(value, 'lookup')['errorName'], 'TypeError');
      expect(member(value, 'enumeration')['returned'], isFalse);
      expect(member(value, 'enumeration')['errorName'], 'TypeError');
    },
  );
}
