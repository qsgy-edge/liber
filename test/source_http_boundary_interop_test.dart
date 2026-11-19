import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime;
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';

import '../tool/http_boundary/runner.dart'
    show
        httpBoundarySourceOf,
        loadHttpBoundaryCorpus,
        validateHttpBoundaryScriptProbeEnvelope;
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
    return validateHttpBoundaryScriptProbeEnvelope(
      jsonDecode('$raw'),
      where: 'interop $sourceId',
    );
  }

  Map<String, dynamic> portable(Map<String, dynamic> envelope) =>
      (envelope['portable'] as Map).cast<String, dynamic>();
  Map<String, dynamic> diagnostics(Map<String, dynamic> envelope) =>
      (envelope['diagnostics'] as Map).cast<String, dynamic>();
  Map<String, dynamic> member(Map<String, dynamic> value, String name) =>
      (value[name] as Map).cast<String, dynamic>();

  Future<Object?> evaluateInjected(String errorType) async {
    final corpus = loadHttpBoundaryCorpus();
    final source = httpBoundarySourceOf(corpus, 'HG0');
    final step = [
      for (final raw in corpus['steps'] as List)
        (raw as Map).cast<String, dynamic>(),
    ].firstWhere((step) => step['id'] == 'helper.script-probe-hg0');
    final script = '${step['script']}'.replaceFirst(
      'try{var v=m.get(',
      'try{throw new $errorType("controller-injected");var v=m.get(',
    );
    final runtime = InProcessSourceScriptRuntime(
      androidId: 'interop-fault',
      hostState: SourceHostState(),
    );
    return runtime.evaluate(
      source: script,
      input: {'sourceKey': '${source['bookSourceUrl']}', 'source': source},
      timeout: const Duration(seconds: 30),
    );
  }

  test('unexpected RangeError and callable-method TypeError escape', () async {
    for (final type in const ['RangeError', 'TypeError']) {
      await expectLater(
        evaluateInjected(type),
        throwsA(
          predicate<Object>(
            (error) => '$error'.contains('controller-injected'),
          ),
        ),
      );
    }
  });

  test('no collision: both Java Map access forms are callable', () async {
    final envelope = await probe('HG0');
    final value = portable(envelope);
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
    expect(diagnostics(envelope)['lookup'], {'caught': false});
    expect(diagnostics(envelope)['enumeration'], {'caught': false});
  });

  test('an own data key get shadows the method for dot and bracket', () async {
    final envelope = await probe('HG1');
    final value = portable(envelope);
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
    final lookupDiagnostic = (diagnostics(envelope)['lookup'] as Map)
        .cast<String, dynamic>();
    expect(lookupDiagnostic['caught'], isTrue);
    expect(lookupDiagnostic['name'], 'TypeError');
    expect('${lookupDiagnostic['message']}', isNotEmpty);
    expect('${lookupDiagnostic['text']}', isNotEmpty);
    expect(diagnostics(envelope)['enumeration'], {'caught': false});
  });

  test(
    'an own data key keySet shadows the method for dot and bracket',
    () async {
      final envelope = await probe('HG2');
      final value = portable(envelope);
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
      expect(diagnostics(envelope)['lookup'], {'caught': false});
      final enumerationDiagnostic =
          (diagnostics(envelope)['enumeration'] as Map).cast<String, dynamic>();
      expect(enumerationDiagnostic['caught'], isTrue);
      expect(enumerationDiagnostic['name'], 'TypeError');
      expect('${enumerationDiagnostic['text']}', isNotEmpty);
    },
  );

  test(
    'both own data keys shadow their methods; user data stays intact',
    () async {
      final envelope = await probe('HG3');
      final value = portable(envelope);
      expect(member(value, 'getDot')['text'], 'data-get');
      expect(member(value, 'keySetDot')['text'], 'data-keyset');
      expect(member(value, 'lookup')['returned'], isFalse);
      expect(member(value, 'lookup')['errorName'], 'TypeError');
      expect(member(value, 'enumeration')['returned'], isFalse);
      expect(member(value, 'enumeration')['errorName'], 'TypeError');
      expect((diagnostics(envelope)['lookup'] as Map)['caught'], isTrue);
      expect((diagnostics(envelope)['enumeration'] as Map)['caught'], isTrue);
    },
  );
}
