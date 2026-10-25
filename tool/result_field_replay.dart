import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:liber/source/native_library.dart';
import 'package:pointycastle/export.dart';

import 'result_field_runner.dart';

/// Runs the remaining-result-field corpus (FIELDS-01) through the product
/// pipeline and records what it observed.
///
/// Usage: `dart run tool/result_field_replay.dart <fjs library> [--out <path>]`
///        `[--fixture <path>]`
///
/// FIELDS-02 requires an explicit `--out`; its raw product record is external
/// evidence, never a committed golden.
///
/// The recorded observations are the Liber side of the corpus. The frozen side
/// is the same corpus driven through the frozen four-stage entry by
/// `tool/result_field_oracle/FieldOracle.java`; the comparison is
/// `tool/result_field_compare.dart`.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError('Usage: <library> [--out <path>]');
  }
  final libraryPath = args.first;
  final output = _argument(args, '--out');
  final fixturePath = _argument(args, '--fixture') ?? resultFieldFixturePath;
  final fixture = loadResultFieldFixture(fixturePath);

  final fields02 = fixture['fixtureId'] == 'FIELDS-02';
  if (fields02) {
    if (output == null) {
      throw ArgumentError('--out is required for FIELDS-02');
    }
    if (File(output).existsSync()) {
      throw StateError('Refusing to overwrite an existing FIELDS-02 report');
    }
  }

  await NativeLibrary.initialize(libraryPath: libraryPath);
  try {
    if (fields02) {
      final result = await runBookUrlMarkersCorpus(fixture: fixture);
      final library = File(libraryPath);
      final fixtureBytes = File(fixturePath).readAsBytesSync();
      final report = <String, Object?>{
        'fixtureId': fixture['fixtureId'],
        'corpusVersion': fixture['corpusVersion'],
        'baselineCommit': fixture['baselineCommit'],
        'entryPoint': fixture['entryPoint'],
        'platform': Platform.operatingSystem,
        'recordedAt': DateTime.now().toIso8601String(),
        'origin': fixture['origin'],
        'fixturesPath': fixturePath,
        'fixturesBytes': fixtureBytes.length,
        'fixturesSha256': _sha256(fixtureBytes),
        'fixturesSha256Lf': _sha256(_lf(fixtureBytes)),
        'productSources': measureProductSources(),
        'libraryPath': libraryPath,
        'librarySha256': library.existsSync()
            ? _sha256(library.readAsBytesSync())
            : 'missing',
        'oracle': 'not-run',
        'status': result.scenarioPassed ? 'pass' : 'fail',
        'analysisFailure': null,
        'scenario': {
          'status': result.scenarioPassed ? 'pass' : 'fail',
          'invariants': [
            for (final invariant in result.invariants)
              {
                'id': invariant.id,
                'ok': invariant.ok,
                'detail': invariant.detail,
              },
          ],
        },
        'requests': result.requests,
        'unmatchedRequests': result.unmatched,
        'serverErrors': result.serverErrors,
        'stageTrace': result.stageTrace,
        'caseRecords': result.caseRecords,
        'caseFailures': result.caseFailures,
        'cleanup': {'serverClosed': true},
      };
      final outputPath = output!;
      final target = File(outputPath);
      target.parent.createSync(recursive: true);
      target.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
      for (final invariant in result.invariants) {
        stdout.writeln(
          '${invariant.ok ? 'ok  ' : 'FAIL'} ${invariant.id}: ${invariant.detail}',
        );
      }
      stdout.writeln(
        'result fields ${fixture['fixtureId']}: scenario '
        '${result.scenarioPassed ? 'pass' : 'fail'} '
        '(${result.requests.length} requests, ${result.caseRecords.length} cases) -> $outputPath',
      );
      if (!result.scenarioPassed) exitCode = 1;
      return;
    }
    final result = await runResultFieldCorpus(fixture: fixture);

    final library = File(libraryPath);
    final report = <String, Object?>{
      'fixtureId': fixture['fixtureId'],
      'corpusVersion': fixture['corpusVersion'],
      'baselineCommit': fixture['baselineCommit'],
      'entryPoint': fixture['entryPoint'],
      'checkKeywordEntryPoint': fixture['checkKeywordEntryPoint'],
      'platform': Platform.operatingSystem,
      'recordedAt': DateTime.now().toIso8601String(),
      'origin': fixture['origin'],
      'fixturesPath': fixturePath,
      'fixturesSha256': _sha256(File(fixturePath).readAsBytesSync()),
      'libraryPath': libraryPath,
      'librarySha256': library.existsSync()
          ? _sha256(library.readAsBytesSync())
          : 'unknown',
      'oracle': 'not-run',
      'scenario': {
        'status': result.scenarioPassed ? 'pass' : 'fail',
        'invariants': [
          for (final invariant in result.invariants)
            {
              'id': invariant.id,
              'ok': invariant.ok,
              'detail': invariant.detail,
            },
        ],
      },
      'requests': result.requests,
      'unmatchedRequests': result.unmatched,
      'stageTrace': result.stageTrace,
      'cases': result.cases,
      'caseFailures': result.caseFailures,
      'checkKeyword': result.checkKeyword,
    };
    final target =
        output ??
        'tool/result_field_oracle/evidence/'
            '${Platform.operatingSystem}-fields-01.liber.json';
    File(target).parent.createSync(recursive: true);
    File(target).writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(report)}\n',
    );
    for (final invariant in result.invariants) {
      stdout.writeln(
        '${invariant.ok ? 'ok  ' : 'FAIL'} ${invariant.id}: ${invariant.detail}',
      );
    }
    stdout.writeln(
      'result fields ${fixture['fixtureId']}: scenario '
      '${result.scenarioPassed ? 'pass' : 'fail'} '
      '(${result.requests.length} requests, ${result.cases.length} cases) -> $target',
    );
    if (!result.scenarioPassed) exitCode = 1;
  } finally {
    NativeLibrary.dispose();
  }
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0) return null;
  if (index + 1 >= args.length) throw ArgumentError('$name needs a value');
  return args[index + 1];
}

List<int> _lf(List<int> bytes) {
  final out = <int>[];
  for (var index = 0; index < bytes.length; index++) {
    if (bytes[index] == 13 &&
        index + 1 < bytes.length &&
        bytes[index + 1] == 10) {
      continue;
    }
    out.add(bytes[index]);
  }
  return out;
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
