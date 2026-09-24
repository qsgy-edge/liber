import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_dispatcher.dart';

import 'native_library.dart';

/// The frozen comparison for `java.toNumChapter` (the Chinese-numeral row).
///
/// The golden is executed evidence from the frozen `AppPattern.kt` and
/// `StringUtils.kt` at `14dd2494` on a host JVM (`tool/tonum_chapter_oracle/`):
/// the frozen bytes hold the pattern and the numeral conversion, and the member
/// that composes them is a transcription the harness verifies against
/// `JsExtensions.kt` on every run. This test runs the product's own
/// `java.toNumChapter` member — through the script-runtime entry a Book Source
/// reaches, not a Dart helper — over the same corpus and compares the two.
///
/// The corpus holds no declared divergence and no `notCompared` row: every case
/// in `fixtures.json` has one golden value here, and the first test is what
/// keeps that true if the corpus grows. The device row stays `not-run`
/// (`evidence/jvm-host/manifest.json`), so this is a host-JVM source execution,
/// not the four-stage device golden.
void main() {
  const fixturesPath = 'tool/tonum_chapter_oracle/fixtures.json';
  const goldenPath =
      'tool/tonum_chapter_oracle/evidence/jvm-host/golden.json';

  final fixtures = (jsonDecode(File(fixturesPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();
  final cases = (fixtures['cases'] as List).cast<Map>();
  final golden = (jsonDecode(File(goldenPath).readAsStringSync()) as Map)
      .cast<String, dynamic>();

  late InProcessSourceScriptRuntime runtime;

  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);
  setUp(
    () => runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: _NoHostCalls()),
    ),
  );

  Future<Object?> run(String script) => runtime.evaluate(
    source: script,
    input: const {'sourceKey': 'http://to.num.chapter'},
    timeout: const Duration(seconds: 5),
  );

  test('every case in the corpus has a golden row', () {
    expect(golden.keys.toSet(), {
      for (final c in cases) c['name'] as String,
    });
  });

  test('the frozen corpus names its own provenance', () {
    expect(fixtures['baseline'], '14dd24945b2914ce2708b8abaa4ee67ceef892af');
    final sources = (fixtures['frozenSources'] as List).cast<Map>();
    expect(
      sources.map((s) => s['path']).whereType<String>(),
      containsAll(<String>[
        'app/src/main/java/io/legado/app/help/JsExtensions.kt',
        'app/src/main/java/io/legado/app/constant/AppPattern.kt',
        'app/src/main/java/io/legado/app/utils/StringUtils.kt',
      ]),
    );
  });

  test('the product member matches the frozen member for every case', () async {
    for (final c in cases) {
      final name = c['name'] as String;
      final input = c['input'];
      final actual = await run('java.toNumChapter(${jsonEncode(input)})');
      expect(actual, golden[name], reason: '$name ($input): ${c['note']}');
    }
  });
}

/// The member reads no network, cache or cookie state, so any host call is a
/// fixture defect rather than a compared observation.
class _NoHostCalls implements SourceHttpTransport, BookSourceTransport {
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) => throw StateError(
    'java.toNumChapter reached the HTTP transport: ${request.url}',
  );

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) => throw StateError(
    'java.toNumChapter reached the book-source transport: $path',
  );
}
