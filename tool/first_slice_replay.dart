import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:liber/source/native_library.dart';
import 'package:pointycastle/export.dart';

import 'first_slice/runner.dart';

/// Runs the controlled four-stage corpus of the first slice through the product
/// pipeline and records what it observed.
///
/// Usage:
///   dart run tool/first_slice_replay.dart `<fjs library>` [--out `<path>`]
///   dart run tool/first_slice_replay.dart - --serve [--source-out `<path>`]
///
/// `--serve` starts the corpus' replay server and writes the fixture's Book
/// Source as a standalone JSON file, so the driven product run
/// (`README.md` -> Verification and evidence -> Driving the UI) can load it with
/// 书源试读 -> 选择书源 JSON while nothing is analysed here.
///
/// The recorded observations are the Liber side of the slice. The frozen side
/// is `not-run`: see `tool/first_slice/README.md`.
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    throw ArgumentError(
      'Usage: <library> [--out <path>] | - --serve [--source-out <path>]',
    );
  }
  final libraryPath = args.first;
  final output = _argument(args, '--out');
  final serve = args.contains('--serve');
  final sourceOut = _argument(args, '--source-out');
  final fixture = loadSliceFixture();
  final fixturePath = sliceFixturePath;

  if (serve) {
    final server = await SliceReplayServer.start(fixture);
    if (sourceOut != null) {
      File(sourceOut).writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(fixture['source'])}\n',
      );
    }
    stdout.writeln(
      jsonEncode({
        'ready': true,
        'origin': '${server.origin}',
        'fixtureId': fixture['fixtureId'],
        'sourceFile': ?sourceOut,
      }),
    );
    // The listening socket keeps this process alive; a driven run stops it.
    await Completer<void>().future;
    return;
  }

  await NativeLibrary.initialize(libraryPath: libraryPath);
  final result = await runSliceFixture(fixture: fixture);

  final library = File(libraryPath);
  final report = <String, Object?>{
    'fixtureId': fixture['fixtureId'],
    'corpusVersion': fixture['corpusVersion'],
    'baselineCommit': fixture['baselineCommit'],
    'entryPoint': fixture['entryPoint'],
    'platform': Platform.operatingSystem,
    'recordedAt': DateTime.now().toIso8601String(),
    'origin': fixture['origin'],
    'keyword': fixture['keyword'],
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
    'analysisFailure': result.failure,
    'requests': result.requests,
    'unmatchedRequests': result.unmatched,
    'stageTrace': result.stageTrace,
    'stages': result.stages,
  };
  final target = output ??
      'tool/first_slice/evidence/'
          '${Platform.operatingSystem}-'
          '${'${fixture['fixtureId']}'.toLowerCase()}.liber.json';
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
    'first slice ${fixture['fixtureId']}: scenario '
    '${result.scenarioPassed ? 'pass' : 'fail'} '
    '(${result.requests.length} requests, ${result.stageTrace.length} stages, '
    'frozen golden not-run) -> $target',
  );
  NativeLibrary.dispose();
  if (!result.scenarioPassed) exitCode = 1;
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0) return null;
  if (index + 1 >= args.length) throw ArgumentError('$name needs a value');
  return args[index + 1];
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}
