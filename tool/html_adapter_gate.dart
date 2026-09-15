import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart';
import 'package:liber/source/native_library.dart';
import 'package:pointycastle/export.dart';

/// Runs the extraction corpus against the Rust adapter and, when a frozen
/// golden is supplied, compares it with the values the frozen APK produced.
///
/// Usage:
///   dart run tool/html_adapter_gate.dart `<fjs library>` `[<frozen golden>]`
///                                       `[<observations>]`
///
/// Without a frozen golden the run still checks the adapter against the corpus'
/// expectations, which were derived by reading the frozen rule layer at the
/// pinned commit. The device golden is not-run; see `tool/html_oracle/README.md`.
Future<void> main(List<String> args) async {
  if (args.isEmpty || args.length > 3) {
    throw ArgumentError(
      'Usage: <library> [<frozen golden.json>] [<observations.json>]',
    );
  }
  final output = args.length > 2 ? File(args[2]) : null;
  if (output != null && output.existsSync()) {
    throw StateError('Refusing to overwrite evidence: ${output.path}');
  }
  final corpus =
      jsonDecode(File('tool/html_oracle/fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final documents = (corpus['documents'] as Map).cast<String, String>();
  final cases = (corpus['cases'] as List).cast<Map<String, dynamic>>();

  final goldenPath = args.length > 1 && args[1] != '-' ? args[1] : null;
  final golden = goldenPath == null
      ? null
      : jsonDecode(File(goldenPath).readAsStringSync()) as Map<String, dynamic>;
  if (golden != null) {
    if (golden['baselineCommit'] != corpus['baselineCommit'] ||
        golden['entryPoint'] != corpus['entryPoint']) {
      throw StateError('Oracle identity mismatch');
    }
  }

  await NativeLibrary.initialize(libraryPath: args[0]);
  final observations = <Map<String, Object?>>[];
  var failed = false;
  for (final entry in cases) {
    final id = entry['id'] as String;
    final rule = entry['rule'] as String;
    final html = documents[entry['document']] ?? '';
    final observation = <String, Object?>{'id': id, 'rule': rule};
    try {
      final outcomes = htmlAnalyze(
        html: html,
        jobs: [
          HtmlRuleJob(
            id: id,
            rule: rule,
            parent: null,
            output: HtmlJobOutput.text,
          ),
        ],
      );
      final failure = outcomes.single.failure;
      if (failure != null) {
        observation['error'] = '${failure.kind}: ${failure.message}';
      } else {
        final values = outcomes.single.values;
        observation['value'] = values.isEmpty ? '' : values.first;
      }
    } catch (error) {
      observation['error'] = '$error';
    }
    observations.add(observation);
  }

  final expectedFailures = <String>[];
  for (final entry in cases) {
    final id = entry['id'] as String;
    final expected = entry['expected'] as String?;
    final observed = observations.firstWhere((item) => item['id'] == id);
    if (expected == null) continue;
    if (observed['value'] != expected) {
      failed = true;
      expectedFailures.add(
        '$id\n  expected: ${jsonEncode(expected)}\n  observed: '
        '${jsonEncode(observed['value'] ?? observed['error'])}',
      );
    }
  }
  if (expectedFailures.isNotEmpty) {
    stderr.writeln('Corpus expectations differ:\n${expectedFailures.join('\n')}');
  }

  final mismatches = <String>[];
  if (golden != null) {
    final goldenValues = <String, Object?>{
      for (final item in (golden['observations'] as List).cast<Map>())
        item['id'] as String: item['value'] ?? item['error'],
    };
    for (final item in observations) {
      final id = item['id'] as String;
      final frozen = goldenValues[id];
      if (frozen == null) {
        mismatches.add('$id: no frozen observation');
        continue;
      }
      final observed = item['value'] ?? item['error'];
      if ('$observed' != '$frozen') {
        mismatches.add('$id: frozen=${jsonEncode(frozen)} windows=${jsonEncode(observed)}');
      }
    }
    if (mismatches.isNotEmpty) failed = true;
  }

  final library = File(args[0]);
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'baselineCommit': corpus['baselineCommit'],
    'entryPoint': corpus['entryPoint'],
    'status': failed ? 'fail' : 'pass',
    'frozenGolden': goldenPath ?? 'not-run',
    'librarySha256': library.existsSync()
        ? _sha256(library.readAsBytesSync())
        : 'unknown',
    'fixturesSha256': _sha256(
      File('tool/html_oracle/fixtures.json').readAsBytesSync(),
    ),
    'cases': cases.length,
    'observations': observations,
    'expectationMismatches': expectedFailures,
    'frozenMismatches': mismatches,
  };
  final encoded = const JsonEncoder.withIndent('  ').convert(report);
  if (output != null) {
    output.writeAsStringSync('$encoded\n');
    stdout.writeln('Wrote ${output.path}');
  } else {
    stdout.writeln(encoded);
  }
  stdout.writeln(
    'adapter corpus: ${failed ? 'fail' : 'pass'} '
    '(${cases.length} cases, frozen golden ${golden == null ? 'not-run' : 'compared'})',
  );
  if (failed) exitCode = 1;
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
