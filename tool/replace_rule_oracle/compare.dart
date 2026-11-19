import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:liber/domain/store_message.dart';
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart' show ReplaceRule;
import 'package:pointycastle/digests/sha256.dart';

const selectedReaderFingerprint =
    'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys';

const selectedReaderInventoryComplete =
    '__LIBER_READER_PRIVATE_INVENTORY_COMPLETE__';
const selectedReaderInventoryScript =
    r"""set -e; find databases shared_prefs files -type f -exec sh -c 'for f do sha256sum "$f" || exit 20; done' sh {} +; printf '%s\n' '__LIBER_READER_PRIVATE_INVENTORY_COMPLETE__'""";

/// Quote the fixed POSIX script as one argument to the device shell's `sh -c`.
final selectedReaderInventoryCommand =
    "'${selectedReaderInventoryScript.replaceAll("'", "'\"'\"'")}'";

/// Parse completed selected-success inventories. The failed timeout witness
/// retains its separately pinned historical producer and raw protocol.
List<String> parseSelectedReaderPrivateInventory(String data) {
  if (!data.endsWith('\n')) {
    throw const FormatException(
      'Selected private inventory completion missing or truncated',
    );
  }
  final lines = data
      .substring(0, data.length - 1)
      .split('\n')
      .map(
        (line) =>
            line.endsWith('\r') ? line.substring(0, line.length - 1) : line,
      )
      .toList();
  if (lines.last != selectedReaderInventoryComplete ||
      lines.take(lines.length - 1).contains(selectedReaderInventoryComplete)) {
    throw const FormatException(
      'Selected private inventory completion missing or misplaced',
    );
  }
  final records = lines.sublist(0, lines.length - 1);
  final paths = <String>{};
  for (final line in records) {
    if (!RegExp(r'^[0-9a-f]{64}  [^\r\n]+$').hasMatch(line)) {
      throw const FormatException(
        'Selected private inventory record malformed',
      );
    }
    if (!paths.add(line.substring(66))) {
      throw const FormatException('Selected private inventory repeats a path');
    }
  }
  return records..sort();
}

const selectedTimeoutWitness = <String, String>{
  'role': 'timeout-policy-witness',
  'caseId': 'timeout',
  'producerHead': '577d52d9eff6db0cf4d56a283b50ae17523c4d77',
  'harnessApkSha256':
      '44787a1b5120dc2f1108c0be402064282a1e9beed612008920d3fb3f0250bd7a',
  'observationSha256':
      '984e62228e19010cdc050ad103ca8395ce6281e383ce0c430ecd0b9015e7ec67',
  'archiveSha256':
      '10146336bb37893c40a8db71582aa383b4f72787f9bb75f030c72b7e91cd2c31',
};

const selectedReaderSourcePaths = [
  'tool/replace_rule_oracle/ReaderOracle.java',
  'tool/replace_rule_oracle/SelectedReaderOracle.java',
  'tool/replace_rule_oracle/GuardedReaderApplication.java',
  'tool/replace_rule_oracle/AndroidManifest-selected.xml',
  'tool/replace_rule_oracle/build.ps1',
  'tool/replace_rule_oracle/capture.py',
  'tool/replace_rule_oracle/compare.dart',
  'tool/nested_oracle/StateSessionOracle.java',
  'tool/nested_oracle/HostRuntimeInit.java',
  'tool/nested_oracle/ShortcutStartupGuard.java',
];

String sha256Bytes(Uint8List bytes) => SHA256Digest()
    .process(bytes)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String sha256File(File file) => sha256Bytes(file.readAsBytesSync());

/// Canonical selected-corpus and source identity, independent of checkout line endings.
String sha256LfFile(File file) =>
    sha256Bytes(utf8.encode(file.readAsStringSync().replaceAll('\r\n', '\n')));

/// Validate the one failed timeout lifetime, independently of the new producer.
Map<String, dynamic> readSelectedTimeoutWitness(File descriptor) {
  final data = jsonDecode(descriptor.readAsStringSync());
  if (data is! Map ||
      data.length != 2 ||
      data['role'] != 'timeout-policy-witness' ||
      data['attemptDirectory'] is! String) {
    throw const FormatException('Invalid selected timeout witness descriptor');
  }
  final root = Directory(data['attemptDirectory'] as String);
  File artifact(String path) => File('${root.path}/$path');
  const pins = <String, String>{
    'command.json':
        'becf2f0c09c8eaf818b41557d8288c65ab91d11c63a49c7622d23d945628ce00',
    'producer-source-binding.json':
        'e9d9ebf81386fa5a4305a50fd8d4f6f42f0af4aa8727c0f06a27260ff87da06a',
    'device-owner-before-stop.json':
        '43068aa9a07daca13f5c1c70813fce3d733a5cac2f9e8442f0a369985406d4ac',
    'raw-capture/manifest.json':
        'ae615bbf867dd868681b4513f1b49d04255ce6bd6f172b0bee8d932e8eb21303',
    'raw-capture/observation.json':
        '984e62228e19010cdc050ad103ca8395ce6281e383ce0c430ecd0b9015e7ec67',
    'raw-capture/instrumentation.log':
        '1061efde9725c73a96b622d8b6977c63d1cad91bfaf6f7d22f3f5f2b66797c1e',
    'raw-capture/private-before.log':
        'c9e85933f906216dc9db93330dd75b60516a1f2b37e5637a34fb42a39417cd57',
    'raw-capture/private-after.log':
        'ab601c5d56a9df0ff2f5e7dfa4031210355e6b07ed78d4bb196508603f544f10',
    'raw-capture/installed-harness.apk':
        '44787a1b5120dc2f1108c0be402064282a1e9beed612008920d3fb3f0250bd7a',
    'raw-capture/frozen.apk':
        '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
    'controller-recovery/result.json':
        '3222f3549e15c22c8d5e0ba7c728ec85cf0c4becb1daf3ec6bce6581977672ff',
    'controller-recovery/verified-plan.json':
        '849cc6002166a5bee9bf6db9f7bcc962a416ffc7982b56fa5fd40432f2c63e95',
    'controller-recovery/commands.json':
        'c909fc7a8673c50ca8d40857d94365005efb5feca798e3892b44fbf94208d79e',
    'controller-recovery/owned-scratch-before-removal.tar':
        '10146336bb37893c40a8db71582aa383b4f72787f9bb75f030c72b7e91cd2c31',
    'controller-recovery/private-after-recovery.log':
        'c9e85933f906216dc9db93330dd75b60516a1f2b37e5637a34fb42a39417cd57',
  };
  for (final entry in pins.entries) {
    if (sha256File(artifact(entry.key)) != entry.value) {
      throw FormatException('Timeout witness artifact differs: ${entry.key}');
    }
  }
  final binding =
      jsonDecode(artifact('producer-source-binding.json').readAsStringSync())
          as Map;
  if (binding['producerHead'] != selectedTimeoutWitness['producerHead'] ||
      binding['observationSha256'] !=
          selectedTimeoutWitness['observationSha256'] ||
      binding['packagedProvenanceSha256'] !=
          'b89d3089392bd1d54e82741e43c208dae9a07bfa8fa3a8df49be96d2b280b34a') {
    throw const FormatException('Timeout producer binding differs');
  }
  final files = (binding['files'] as List).cast<Map>();
  final names = files.map((row) => row['path'] as String).toList()..sort();
  final expected = selectedReaderSourcePaths.toList()..sort();
  if (!_equal(names, expected)) {
    throw const FormatException('Timeout producer sources differ');
  }
  for (final row in files) {
    final path = row['path'] as String;
    final source = artifact('producer-sources/$path');
    if (sha256File(source) != row['rawSha256'] ||
        sha256LfFile(source) != row['lfSha256']) {
      throw FormatException('Timeout producer source differs: $path');
    }
    final git = Process.runSync('git', [
      'show',
      '${selectedTimeoutWitness['producerHead']}:$path',
    ], stdoutEncoding: null);
    if (git.exitCode != 0 ||
        sha256Bytes(Uint8List.fromList((git.stdout as List).cast<int>())) !=
            row['lfSha256']) {
      throw FormatException('Timeout producer Git blob differs: $path');
    }
  }
  final observation =
      jsonDecode(artifact('raw-capture/observation.json').readAsStringSync())
          as Map;
  final rows = (observation['rows'] as List).cast<Map>();
  final last = rows.last;
  final cleanup = observation['cleanup'] as Map;
  final recovery =
      jsonDecode(artifact('controller-recovery/result.json').readAsStringSync())
          as Map;
  if (rows.length != 14 ||
      last['id'] != 'timeout' ||
      last['status'] != 'error' ||
      last.containsKey('content') ||
      last.containsKey('terminal') ||
      last.containsKey('disabledRules') ||
      observation['failure'] !=
          'java.lang.IllegalStateException: reader attempted an activity launch' ||
      cleanup['databaseClosed'] != false ||
      cleanup['terminalProved'] != false ||
      cleanup['activityLaunchAttempts'] != 1 ||
      cleanup['scratchRemoved'] != false ||
      cleanup['scratchRetained'] != true ||
      recovery['originalAttempt'] != 'failed; not promoted; no golden' ||
      recovery['originalFilesUnchangedAfterRecovery'] != true ||
      recovery['harnessRemoved'] != true ||
      recovery['scratchRemoved'] != true ||
      recovery['captureRetried'] != false) {
    throw const FormatException('Timeout failure or recovery differs');
  }
  final archive = artifact(
    'controller-recovery/owned-scratch-before-removal.tar',
  ).readAsBytesSync();
  var offset = 0;
  var found = false;
  while (offset + 512 <= archive.length && archive[offset] != 0) {
    String field(int start, int length) => ascii
        .decode(archive.sublist(start, start + length), allowInvalid: true)
        .split('\u0000')
        .first
        .trim();
    final name = field(offset, 100);
    final size = int.parse(field(offset + 124, 12), radix: 8);
    final start = offset + 512;
    if (start + size > archive.length) {
      throw const FormatException('Truncated timeout archive');
    }
    if (name ==
        'cache/liber-replace-selected/external-cache/crash/crash-2026-11-03-13-41-20-1793684480633.log') {
      final crash = Uint8List.sublistView(archive, start, start + size);
      if (found ||
          sha256Bytes(crash) !=
              '43d114c47d204a1117a8972125a942e8209c8e533ea196ac89526e652f03e1aa' ||
          !utf8.decode(crash).contains('RegexTimeoutException')) {
        throw const FormatException('Timeout crash artifact differs');
      }
      found = true;
    }
    offset = start + ((size + 511) ~/ 512) * 512;
  }
  if (!found) throw const FormatException('Timeout crash artifact missing');
  return Map<String, dynamic>.from(selectedTimeoutWitness);
}

/// Bind the successful selected report to its actual installed APK and assets.
void checkSelectedHarnessArtifact(
  File goldenFile,
  Map<String, dynamic> golden,
) {
  final identity = golden['identity'];
  final provenance = golden['provenance'];
  if (identity is! Map || provenance is! Map) {
    throw const FormatException('Selected harness identity is absent');
  }
  final apk = File('${goldenFile.parent.path}/installed-harness.apk');
  final bytes = apk.readAsBytesSync();
  if (sha256Bytes(bytes) != identity['harnessApkSha256']) {
    throw const FormatException('Selected installed harness APK differs');
  }
  final archive = ZipDecoder().decodeBytes(bytes, verify: true);
  Uint8List asset(String name) {
    final found = archive.files.where((entry) => entry.name == name).toList();
    if (found.length != 1 || !found.single.isFile) {
      throw FormatException('Selected APK asset missing or duplicated: $name');
    }
    return Uint8List.fromList((found.single.content as List).cast<int>());
  }

  final corpus = asset('assets/fixtures-selected.json');
  final metadata = asset('assets/provenance.json');
  final dex = asset('classes.dex');
  final sourceCorpus = File(
    'tool/replace_rule_oracle/fixtures-selected.json',
  ).readAsBytesSync();
  if (sha256Bytes(corpus) != identity['corpusAssetSha256'] ||
      sha256Bytes(metadata) != identity['provenanceAssetSha256'] ||
      sha256Bytes(dex) != provenance['dexSha256'] ||
      !_equal(
        jsonDecode(utf8.decode(metadata).replaceFirst('\uFEFF', '')),
        provenance,
      ) ||
      utf8.decode(corpus).replaceAll('\r\n', '\n') !=
          utf8.decode(sourceCorpus).replaceAll('\r\n', '\n')) {
    throw const FormatException(
      'Selected installed harness asset or provenance differs',
    );
  }
}

/// Bind a selected golden to the raw outputs of its successful capture lifetime.
void checkSelectedCaptureBundle(File goldenFile, Map<String, dynamic> golden) {
  final directory = goldenFile.parent;
  File artifact(String name) {
    final file = File('${directory.path}/$name');
    if (!FileSystemEntity.isFileSync(file.path)) {
      throw FormatException('Selected capture bundle missing: $name');
    }
    return file;
  }

  Map<String, dynamic> jsonArtifact(String name) {
    final value = jsonDecode(artifact(name).readAsStringSync());
    if (value is! Map<String, dynamic>) {
      throw FormatException(
        'Selected capture bundle invalid JSON object: $name',
      );
    }
    return value;
  }

  final manifest = jsonArtifact('manifest.json');
  final observation = jsonArtifact('observation.json');
  final identity = golden['identity'];
  final host = golden['hostCapture'];
  final preflight = manifest['selectedPreflight'];
  if (identity is! Map ||
      host is! Map ||
      preflight is! Map ||
      !_equal(jsonDecode(goldenFile.readAsStringSync()), golden) ||
      manifest['status'] != 'observed' ||
      manifest['serial'] != '5615f742' ||
      manifest['fingerprint'] != selectedReaderFingerprint ||
      manifest['error'] != null ||
      manifest['nativeFailure'] != null ||
      manifest['preservationFailure'] != null ||
      manifest['goldenSha256'] != sha256File(goldenFile) ||
      ![
        sha256LfFile(File('tool/replace_rule_oracle/fixtures-selected.json')),
        sha256CrlfFile(File('tool/replace_rule_oracle/fixtures-selected.json')),
      ].contains(manifest['fixtureSha256']) ||
      preflight['corpusSha256Lf'] != golden['fixtureSha256'] ||
      manifest['harnessApkSha256'] != identity['harnessApkSha256'] ||
      manifest['installedHarnessSha256'] != identity['harnessApkSha256'] ||
      manifest['baselineApkSha256'] != identity['targetApkSha256'] ||
      sha256File(artifact('installed-harness.apk')) !=
          identity['harnessApkSha256'] ||
      sha256File(artifact('frozen.apk')) != identity['targetApkSha256'] ||
      !_equal(manifest['frozenSources'], preflight['referenceHashes']) ||
      manifest['existingDataHashesUnchanged'] != true ||
      manifest['harnessRemoved'] != true ||
      !_equal(host, {
        'existingDataHashesUnchanged': true,
        'harnessRemoved': true,
        'installedHarnessSha256': manifest['installedHarnessSha256'],
        'preflight': preflight,
      }) ||
      !_equal(
        observation,
        Map<String, dynamic>.from(golden)..remove('hostCapture'),
      )) {
    throw const FormatException(
      'Selected capture bundle identity or observation differs',
    );
  }

  final instrumentation = artifact('instrumentation.log').readAsStringSync();
  final payloads = RegExp(
    r'READER_ORACLE_BASE64=([A-Za-z0-9+/=]+)',
  ).allMatches(instrumentation).toList();
  final codes = RegExp(
    r'^INSTRUMENTATION_CODE: (-?\d+)\r?$',
    multiLine: true,
  ).allMatches(instrumentation).toList();
  if (payloads.length != 1 ||
      codes.length != 1 ||
      codes.single.group(1) != '-1' ||
      instrumentation.contains('INSTRUMENTATION_FAILED') ||
      instrumentation.contains('INSTRUMENTATION_ABORTED') ||
      RegExp(r'^TIMED OUT\r?$', multiLine: true).hasMatch(instrumentation) ||
      !_equal(
        jsonDecode(utf8.decode(base64Decode(payloads.single.group(1)!))),
        observation,
      )) {
    throw const FormatException(
      'Selected instrumentation payload or result differs',
    );
  }

  final before = parseSelectedReaderPrivateInventory(
    artifact('private-before.log').readAsStringSync(),
  );
  final after = parseSelectedReaderPrivateInventory(
    artifact('private-after.log').readAsStringSync(),
  );
  if (!_equal(before, after)) {
    throw const FormatException('Selected private snapshots differ');
  }

  const package = 'io.liber.oracle.replace.selected';
  const target = 'com.legado.app.debug';
  const prefix = ['adb', '-s', '5615f742'];
  final commands = manifest['commands'];
  if (commands is! List) {
    throw const FormatException('Selected command receipts missing');
  }
  int actionCount(List<String> action) => commands.where((row) {
    if (row is! Map || row['command'] is! List) return false;
    final command = row['command'] as List;
    return command.length >= prefix.length + action.length &&
        _equal(command.sublist(0, prefix.length), prefix) &&
        _equal(
          command.sublist(prefix.length, prefix.length + action.length),
          action,
        );
  }).length;
  if (actionCount(['install']) != 1 ||
      actionCount(['shell', 'am', 'instrument']) != 1 ||
      actionCount(['uninstall']) != 1) {
    throw const FormatException(
      'Selected install, instrumentation or removal count differs',
    );
  }
  var previous = -1;
  void receipt(String name, bool Function(List<dynamic>) matches) {
    final found = <int>[
      for (var i = 0; i < commands.length; i++)
        if (commands[i] is Map && (commands[i] as Map)['log'] == '$name.log') i,
    ];
    if (found.length != 1 || found.single <= previous) {
      throw FormatException(
        'Selected command receipt missing, duplicated or reordered: $name',
      );
    }
    previous = found.single;
    artifact('$name.log');
    final row = commands[previous] as Map;
    final command = row['command'];
    if (row['exitCode'] != 0 ||
        command is! List ||
        command.length < 3 ||
        !_equal(command.sublist(0, 3), prefix) ||
        !matches(command.sublist(3))) {
      throw FormatException(
        'Selected command receipt failed or differs: $name',
      );
    }
  }

  bool equals(List<dynamic> command, List<String> expected) =>
      _equal(command, expected);
  String packagePath(String log) {
    final text = artifact('$log.log').readAsStringSync().trim();
    if (!text.startsWith('package:') ||
        text.contains('\n') ||
        text.length <= 8) {
      throw FormatException('Selected package path differs: $log');
    }
    return text.substring(8);
  }

  final baselinePath = packagePath('baseline-path');
  final harnessPath = packagePath('harness-installed-path');
  bool pull(List<dynamic> args, String source, String filename) =>
      args.length == 3 &&
      args[0] == 'pull' &&
      args[1] == source &&
      args[2] is String &&
      (args[2] as String).replaceAll('\\', '/').endsWith('/$filename');
  receipt(
    'baseline-path',
    (args) => equals(args, ['shell', 'pm', 'path', target]),
  );
  receipt('pull-baseline', (args) => pull(args, baselinePath, 'frozen.apk'));
  receipt(
    'harness-existing',
    (args) => equals(args, ['shell', 'pm', 'list', 'packages', package]),
  );
  receipt(
    'private-before',
    (args) => equals(args, [
      'shell',
      'run-as',
      target,
      'sh',
      '-c',
      selectedReaderInventoryCommand,
    ]),
  );
  receipt(
    'install',
    (args) =>
        args.length == 3 &&
        args[0] == 'install' &&
        args[1] == '-r' &&
        args[2] is String,
  );
  receipt(
    'harness-installed-path',
    (args) => equals(args, ['shell', 'pm', 'path', package]),
  );
  receipt(
    'pull-harness',
    (args) => pull(args, harnessPath, 'installed-harness.apk'),
  );
  receipt(
    'instrumentation',
    (args) => equals(args, [
      'shell',
      'am',
      'instrument',
      '-w',
      '-r',
      '$package/io.liber.oracle.nested.SelectedReaderOracle',
    ]),
  );
  receipt(
    'private-after',
    (args) => equals(args, [
      'shell',
      'run-as',
      target,
      'sh',
      '-c',
      selectedReaderInventoryCommand,
    ]),
  );
  receipt(
    'stop-owned-run',
    (args) => equals(args, ['shell', 'am', 'force-stop', target]),
  );
  receipt('remove-harness', (args) => equals(args, ['uninstall', package]));
  receipt(
    'harness-removed-check',
    (args) => equals(args, ['shell', 'pm', 'list', 'packages', package]),
  );

  bool packageAbsent(String name) => const LineSplitter()
      .convert(artifact('$name.log').readAsStringSync())
      .every(
        (line) =>
            line.startsWith('package:') && line.trim() != 'package:$package',
      );
  bool success(String name) {
    final output = artifact('$name.log').readAsStringSync();
    return RegExp(r'^Success\r?$', multiLine: true).hasMatch(output) &&
        !RegExp(r'Failure \[[^\]\r\n]*\]').hasMatch(output) &&
        !RegExp(r'^TIMED OUT\r?$', multiLine: true).hasMatch(output);
  }

  if (!packageAbsent('harness-existing') ||
      !success('install') ||
      !success('remove-harness') ||
      !packageAbsent('harness-removed-check')) {
    throw const FormatException(
      'Selected harness install or removal receipt differs',
    );
  }
}

/// The historical committed evidence pins the corpus's CRLF working-tree form.
String sha256CrlfFile(File file) => sha256Bytes(
  utf8.encode(
    file.readAsStringSync().replaceAll('\r\n', '\n').replaceAll('\n', '\r\n'),
  ),
);

/// The committed report is evidence *for the corpus it names*; it is not a
/// golden (only `capture.py` on the frozen handset produces one). Refuse a
/// report that no longer describes this fixture, so a corpus edit cannot
/// silently leave the recorded run describing a corpus that no longer exists.
void checkReportMatchesFixture(
  Map<String, dynamic> fixture,
  Map<String, dynamic> report, {
  required String fixtureSha256,
}) {
  for (final key in ['fixtureId', 'comparisonBoundary']) {
    if (report[key] != fixture[key]) {
      throw FormatException(
        'Committed report `$key` does not match the fixture',
      );
    }
  }
  if (report['fixtureSha256'] != fixtureSha256) {
    throw const FormatException(
      'Committed report `fixtureSha256` does not match the fixture bytes',
    );
  }
  final cases = jsonEncode([
    for (final row in fixture['cases'] as List) (row as Map)['id'],
  ]);
  final rows = jsonEncode([
    for (final row in report['rows'] as List) (row as Map)['id'],
  ]);
  if (rows != cases) {
    throw const FormatException(
      'Committed report row identity/order differs from the fixture cases',
    );
  }
}

/// Only absent evidence becomes not-run. Invalid evidence fails closed.
/// Policy rows still carry exact differences; they never turn into pass.
Map<String, Object?> compareRows(
  Map<String, dynamic> fixture,
  List<Map<String, Object?>> product,
  Map<String, dynamic>? golden, {
  required String fixtureSha256,
  Map<String, dynamic>? timeoutWitness,
}) {
  final cases = (fixture['cases'] as List).cast<Map>();
  final ids = cases.map((row) => row['id'] as String).toList();
  void checkIds(List<Map> rows, String side) {
    final actual = rows.map((row) => row['id']).toList();
    if (jsonEncode(actual) != jsonEncode(ids)) {
      throw FormatException('$side row identity/order differs from fixture');
    }
  }

  checkIds(product, 'product');
  List<Map>? frozen;
  if (golden != null) {
    // The committed `evidence/comparison.json` is this tool's own report: no
    // capture envelope, and verdicts where a golden holds observations. Name
    // what the input actually is instead of blaming the fixture for the keys
    // the input never had.
    for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit']) {
      if (!golden.containsKey(key)) {
        throw FormatException(
          'Not a frozen golden: no `$key` envelope. A golden is written by a '
          'capture.py device run; the committed evidence/comparison.json is a '
          'comparison report, which is a result, not an input.',
        );
      }
      if (golden[key] != fixture[key]) {
        throw FormatException(
          'Frozen golden was captured against another corpus: `$key` is '
          '${golden[key]}, the fixture says ${fixture[key]}',
        );
      }
    }
    if (golden['fixtureSha256'] != fixtureSha256 ||
        golden['boundary'] != fixture['comparisonBoundary']) {
      throw const FormatException('Frozen fixture hash/boundary differs');
    }
    if (golden['failure'] != null || golden['cleanupFailure'] != null) {
      throw const FormatException('Frozen run failed');
    }
    if (fixture['corpusVersion'] == 2) {
      final partitionIds = ids.where((id) => id != 'timeout').toList();
      if (!_equal(timeoutWitness, selectedTimeoutWitness) ||
          ids.length != 15 ||
          ids.where((id) => id == 'timeout').length != 1 ||
          partitionIds.length != 14 ||
          !partitionIds.contains('refusal') ||
          !_equal(golden['partition'], {
            'role': 'reader-non-timeout',
            'caseIds': partitionIds,
          })) {
        throw const FormatException(
          'Selected partition or timeout witness differs',
        );
      }
      final identity = golden['identity'];
      final initialization = golden['hostInitialization'];
      final provenance = golden['provenance'];
      final isolation = golden['isolation'];
      final startup = golden['startupContainment'];
      final entryPoints = golden['entryPoints'];
      final owner = golden['terminalOwner'];
      final hostCapture = golden['hostCapture'];
      final preflight = hostCapture is Map ? hostCapture['preflight'] : null;
      bool hashValue(Object? value) =>
          value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
      bool hashMap(Object? value, Iterable<Object?> expected) =>
          value is Map &&
          value.length == expected.length &&
          expected.every((key) => hashValue(value[key]));
      final requiredWrappers = {
        for (final row
            in (fixture['hostInitialization'] as Map)['registrations'] as List)
          row['type']: row['factory'],
      };
      final probe = isolation is Map ? isolation['preferenceProbe'] : null;
      if (fixture['fixtureId'] != 'REPLACE-17' ||
          fixture['baselineCommit'] !=
              'a7d37f1707a70a459ad708f4fe79341d1e42d716' ||
          golden['fingerprint'] != selectedReaderFingerprint ||
          golden['paragraphIndent'] != '　　' ||
          identity is! Map ||
          hostCapture is! Map ||
          hostCapture['existingDataHashesUnchanged'] != true ||
          hostCapture['harnessRemoved'] != true ||
          hostCapture['installedHarnessSha256'] !=
              identity['harnessApkSha256'] ||
          preflight is! Map ||
          ![
            'corpusAssetSha256',
            'corpusSha256Lf',
            'harnessApkSha256',
            'provenanceAssetSha256',
          ].every((key) => preflight[key] == identity[key]) ||
          !hashValue(identity['harnessApkSha256']) ||
          !hashValue(identity['corpusAssetSha256']) ||
          !hashValue(identity['provenanceAssetSha256']) ||
          provenance is! Map ||
          provenance['baselineCommit'] != fixture['baselineCommit'] ||
          provenance['corpusSha256Lf'] != fixtureSha256 ||
          provenance['corpusAssetSha256'] != identity['corpusAssetSha256'] ||
          ![
            'corpusAssetSha256',
            'corpusSha256Lf',
            'dexSha256',
            'sourceHashes',
            'sourceHashesLf',
            'referenceHashes',
          ].every((key) => _equal(preflight[key], provenance[key])) ||
          !hashValue(provenance['dexSha256']) ||
          !hashMap(provenance['sourceHashes'], selectedReaderSourcePaths) ||
          !hashMap(provenance['sourceHashesLf'], selectedReaderSourcePaths) ||
          !selectedReaderSourcePaths.every(
            (path) =>
                File(path).existsSync() &&
                (provenance['sourceHashesLf'] as Map)[path] ==
                    sha256LfFile(File(path)),
          ) ||
          !hashMap(
            provenance['referenceHashes'],
            (fixture['frozenSources'] as List).map((row) => row['path']),
          ) ||
          !(fixture['frozenSources'] as List).every(
            (row) =>
                (provenance['referenceHashes'] as Map)[row['path']] ==
                row['sha256'],
          ) ||
          identity['targetPackage'] != 'com.legado.app.debug' ||
          identity['targetApkSha256'] !=
              (fixture['target'] as Map)['apkSha256'] ||
          identity['harnessPackage'] != 'io.liber.oracle.replace.selected' ||
          identity['corpusSha256Lf'] != fixtureSha256 ||
          initialization is! Map ||
          initialization['verified'] != true ||
          initialization['applicationAttached'] != false ||
          initialization['method'] !=
              (fixture['hostInitialization'] as Map)['method'] ||
          !_equal(initialization['registeredWrappers'], requiredWrappers) ||
          isolation is! Map ||
          isolation['verified'] != true ||
          isolation['application'] !=
              'io.liber.oracle.nested.GuardedReaderApplication' ||
          probe is! Map ||
          probe['registered'] != true ||
          probe['committed'] != true ||
          probe['scopedFile'] != true ||
          probe['installationFile'] != false ||
          startup is! Map ||
          startup['intercepted'] != 1 ||
          startup['handled'] != 1 ||
          startup['beforeBinding'] != true ||
          owner is! Map ||
          owner['scope'] != 'Coroutine.DEFAULT' ||
          owner['rootActive'] != true ||
          owner['rootCompleted'] != false ||
          owner['baselineChildren'] != 0 ||
          !(owner['childrenMethod'] is String &&
              (owner['childrenMethod'] as String).contains(
                'kotlinx.coroutines.Job.getChildren()',
              )) ||
          !(owner['completionMethod'] is String &&
              (owner['completionMethod'] as String).contains(
                'kotlinx.coroutines.Job.isCompleted()',
              )) ||
          entryPoints is! Map ||
          entryPoints['getContentArity'] != 10 ||
          entryPoints['getDisplayTitleArity'] != 4 ||
          !(entryPoints['getDisplayTitle'] is String &&
              (entryPoints['getDisplayTitle'] as String).contains(
                'getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)',
              )) ||
          !(entryPoints['getContent'] is String &&
              (entryPoints['getContent'] as String).contains(
                'getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)',
              )) ||
          golden['settingsBefore'] is! Map ||
          !(golden['settingsBefore'] as Map).containsKey('backupPath') ||
          (golden['settingsBefore'] as Map)['backupPath'] != null ||
          (golden['settingsBefore'] as Map)['paragraphIndent'] is! String ||
          (golden['settingsBefore'] as Map)['adaptSpecialStyle'] is! bool ||
          (golden['settingsBefore'] as Map)['chineseConverterType'] is! int ||
          (golden['settingsBefore'] as Map)['replaceEnableDefault'] is! bool) {
        throw const FormatException(
          'Selected frozen capture identity or initialization is unverified',
        );
      }
    }
    final cleanup = golden['cleanup'] as Map?;
    bool exactPreferenceCleanup() {
      final registered = cleanup?['registeredPreferences'];
      final removed = cleanup?['preferencesRemoved'];
      if (registered is! List ||
          registered.isEmpty ||
          !registered.every((name) => name is String) ||
          registered.toSet().length != registered.length ||
          removed is! List ||
          !removed.every(
            (row) =>
                row is Map &&
                row['ok'] == true &&
                row['name'] is String &&
                (row['name'] as String).startsWith('liber_replace_selected_'),
          )) {
        return false;
      }
      final names = registered.cast<String>().toList()..sort();
      final deleted =
          removed.map((row) => (row as Map)['name'] as String).toList()..sort();
      return _equal(names, deleted);
    }

    if (cleanup?['databaseClosed'] != true ||
        cleanup?['scratchRemoved'] != true ||
        (fixture['corpusVersion'] == 2 &&
            (cleanup?['terminalProved'] != true ||
                cleanup?['activityLaunchAttempts'] != 0 ||
                cleanup?['scratchRetained'] != false ||
                !exactPreferenceCleanup()))) {
      throw const FormatException('Frozen cleanup is unverified');
    }
    frozen = (golden['rows'] as List).cast<Map>();
    if (fixture['corpusVersion'] == 2) {
      if (!_equal(
        frozen.map((row) => row['id']).toList(),
        ids.where((id) => id != 'timeout').toList(),
      )) {
        throw const FormatException(
          'selected frozen partition identity/order differs',
        );
      }
    } else {
      checkIds(frozen, 'frozen');
    }
    for (final row in frozen) {
      if (fixture['corpusVersion'] == 2) {
        bool terminal(Object? value) =>
            value is Map &&
            value['allCompleted'] == true &&
            value['rootEmpty'] == true &&
            value['launchAttempts'] == 0;
        final calls = row['readerCalls'];
        if (!terminal(row['terminal']) ||
            calls is! List ||
            calls.length != 2 ||
            !terminal(calls[0]) ||
            (calls[0] as Map)['method'] != 'getDisplayTitle' ||
            !terminal(calls[1]) ||
            (calls[1] as Map)['method'] != 'getContent' ||
            row['textList'] is! List ||
            !(row['textList'] as List).every((value) => value is String) ||
            (row['textList'] as List).join('\n') != row['content'] ||
            row['sameTitleRemoved'] is! bool ||
            !row.containsKey('effectiveRules') ||
            (row['effectiveRules'] != null &&
                (row['effectiveRules'] is! List ||
                    !(row['effectiveRules'] as List).every(
                      (value) => value is String,
                    ))) ||
            row['disabledRules'] is! List ||
            (row['id'] == 'timeout' &&
                (row['timeoutObserved'] is! bool ||
                    row['restartObservation'] is! String))) {
          throw FormatException(
            'Selected row ${row['id']} has incomplete terminal/observations',
          );
        }
      }
      if (row['status'] != 'observed') {
        throw FormatException(
          'Not a frozen golden: row ${row['id']} status is `${row['status']}`. '
          'A golden holds the frozen reader\'s raw observations; a report\'s '
          'verdicts cannot be re-derived into a comparison.',
        );
      }
    }
  }
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < cases.length; i++) {
    final input = cases[i];
    final actual = product[i];
    final selectedTimeout =
        fixture['corpusVersion'] == 2 &&
        input['id'] == 'timeout' &&
        frozen != null;
    final expected = frozen == null || selectedTimeout
        ? null
        : fixture['corpusVersion'] == 2
        ? frozen.singleWhere((row) => row['id'] == input['id'])
        : frozen[i];
    final differences = <Map<String, Object?>>[];
    final observations = <String, Object?>{};
    final policy = switch (input['id']) {
      'timeout' =>
        selectedTimeout
            ? 'ADR 0011: the archived native crash records timeout; the guarded '
                  'launch attempt was blocked, and final return and terminal state '
                  'are unproved. Product disable/preserve behavior is not compared.'
            : 'ADR 0011: per-rule disable/preserve text; frozen stack trace '
                  'and restart are not reproduced. The unchanged short input may not '
                  'trigger the frozen timeout; inspect timeoutObserved.',
      'refusal' =>
        'Named unsupported possessive-quantifier refusal; #49 JS '
            'execution is integrated, not a blanket JS refusal.',
      _ => null,
    };
    // All calls record title/content/selection, even on single-scope rows, so
    // accidental cross-scope replacement cannot hide in an unobserved field.
    for (final field in [
      'title',
      'content',
      'selection',
      if (fixture['corpusVersion'] == 2) 'disabledRules',
    ]) {
      if (expected == null || expected['status'] != 'observed') {
        observations[field] = 'not-run';
        continue;
      }
      if (!expected.containsKey(field) || !actual.containsKey(field)) {
        throw FormatException('${input['id']} missing $field');
      }
      final equal = _equal(actual[field], expected[field]);
      observations[field] = equal ? 'pass' : 'fail';
      if (!equal) {
        differences.add({
          'field': field,
          'frozen': expected[field],
          'product': actual[field],
        });
      }
    }
    final status = actual['status'] != 'observed'
        ? 'fail'
        : selectedTimeout
        ? 'notCompared'
        : expected == null || expected['status'] != 'observed'
        ? 'not-run'
        : input['id'] == 'timeout'
        ? 'notCompared'
        : differences.isEmpty
        ? 'pass'
        : policy != null &&
              differences.every((diff) => diff['field'] == 'content')
        ? 'notCompared'
        : 'fail';
    rows.add({
      'id': input['id'],
      'status': status,
      'frozenStatus': selectedTimeout
          ? 'failed-timeout-witness'
          : expected?['status'] ?? 'not-run',
      'productStatus': actual['status'],
      'observations': observations,
      'differences': differences,
      'policy': ?policy,
      if (fixture['corpusVersion'] == 2 && expected != null) ...{
        'frozenReturnFields': {
          'textList': expected['textList'],
          'sameTitleRemoved': expected['sameTitleRemoved'],
          'effectiveRules': expected['effectiveRules'],
        },
        'frozenReturnFieldsComparison':
            'notCompared: product exposes final text only',
      },
      if (input['id'] == 'timeout') ...{
        'comparison': 'notCompared',
        if (!selectedTimeout) 'timeoutObserved': expected?['timeoutObserved'],
        'restartObservation': selectedTimeout
            ? 'guarded launch attempt blocked; restart not observed'
            : expected?['restartObservation'] ?? 'not-run',
        'timeoutCoverage': selectedTimeout
            ? 'executed timeout: archived native crash; return and terminal unproved'
            : expected?['timeoutObserved'] == true
            ? 'observed'
            : 'not-run: no frozen timeout observed',
      },
      if (input['script'] != null)
        'conversionPolicy':
            'ADR 0010 accepts measured dictionary differences; '
            'this comparator preserves exact strings and fails new differences '
            'pending attribution, without blanket normalization.',
    });
  }
  return {
    'fixtureId': fixture['fixtureId'],
    'fixtureSha256': fixtureSha256,
    'comparisonBoundary': fixture['comparisonBoundary'],
    'rows': rows,
    'counts': {
      for (final state in ['pass', 'fail', 'notCompared', 'not-run'])
        state: rows.where((row) => row['status'] == state).length,
    },
    'complete': rows.every((row) => row['status'] == 'pass'),
  };
}

bool _equal(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equal(a[key], b[key]));
  }
  if (a is List && b is List) {
    return a.length == b.length &&
        List.generate(a.length, (i) => i).every((i) => _equal(a[i], b[i]));
  }
  return a == b;
}

Future<List<Map<String, Object?>>> observeProduct(
  Map<String, dynamic> fixture,
) async {
  final rows = <Map<String, Object?>>[];
  for (final input in (fixture['cases'] as List).cast<Map>()) {
    final rules = <ReplaceRule>[];
    for (final value in (input['rules'] as List).cast<Map>()) {
      rules.add(
        ReplaceRule(
          id: '${rules.length + 1}',
          name: value['name'] as String,
          groupName: '',
          pattern: value['pattern'] as String,
          replacement: value['replacement'] as String,
          scope: value['scope'] as String?,
          excludeScope: value['excludeScope'] as String?,
          scopeTitle: value['scopeTitle'] as bool? ?? false,
          scopeContent: value['scopeContent'] as bool? ?? true,
          isEnabled: value['isEnabled'] as bool? ?? true,
          isRegex: value['isRegex'] as bool? ?? true,
          timeoutMillisecond: value['timeoutMillisecond'] as int? ?? 3000,
          ruleOrder: value['sortOrder'] as int? ?? 0,
        ),
      );
    }
    final selected = ReplaceRuleSet.forBook(
      rules,
      bookName: input['bookName'] as String,
      bookOrigin: input['bookOrigin'] as String,
    );
    final notices = <StoreMessage>[];
    final disabled = <String>[];
    final processor = ContentProcessing(
      rules: selected,
      bookName: input['bookName'] as String,
      script: switch (input['script']) {
        't2s' => ConvertTarget.simplifiedMainland,
        's2t' => ConvertTarget.traditionalGeneric,
        _ => null,
      },
      useReSegment: input['reSegment'] as bool? ?? false,
      onNotice: notices.add,
      onRuleDisabled: (rule) async => disabled.add(rule.name),
    );
    final row = <String, Object?>{
      'id': input['id'],
      'selection': {
        'title': selected.titleRules.map((rule) => rule.name).toList(),
        'content': selected.contentRules.map((rule) => rule.name).toList(),
      },
      // The code and its arguments (#72), not the words of one interface:
      // this artifact is evidence, and it must not depend on a locale.
      'notices': [for (final notice in notices) notice.toString()],
      'disabledRules': disabled,
    };
    rows.add(row);
    try {
      row['title'] = await processor.displayTitle(
        input['chapterTitle'] as String,
      );
      row['content'] = (await processor.content(
        input['rawContent'] as String,
        chapterTitle: input['chapterTitle'] as String,
        includeTitle: false,
      )).text;
      row['status'] = 'observed';
    } catch (error) {
      row['status'] = 'error';
      row['error'] = '$error';
    }
  }
  return rows;
}

Future<void> main(List<String> args) async {
  final selected =
      (args.length == 5 || args.length == 7) &&
      args[0] == '--corpus' &&
      File(args[1]).absolute.path ==
          File('tool/replace_rule_oracle/fixtures-selected.json').absolute.path;
  if ((!selected && args.length != 3) ||
      (args.length == 3 && args[0] == '--corpus') ||
      (selected && args.length == 7 && args[2] != '--timeout-witness')) {
    stderr.writeln(
      'Usage: dart run tool/replace_rule_oracle/compare.dart '
      '[--corpus tool/replace_rule_oracle/fixtures-selected.json '
      '[--timeout-witness <descriptor.json>]] '
      '<library> <golden.json|-> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final witnessFile = selected && args.length == 7 ? File(args[3]) : null;
  final timeoutWitness = witnessFile == null
      ? null
      : readSelectedTimeoutWitness(witnessFile);
  final positional = selected
      ? args.sublist(witnessFile == null ? 2 : 4)
      : args;
  final file = File(
    selected
        ? 'tool/replace_rule_oracle/fixtures-selected.json'
        : 'tool/replace_rule_oracle/fixtures.json',
  );
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  if (selected &&
      (fixture['fixtureId'] != 'REPLACE-17' ||
          fixture['corpusVersion'] != 2 ||
          fixture['baselineCommit'] !=
              'a7d37f1707a70a459ad708f4fe79341d1e42d716' ||
          (fixture['target'] as Map)['package'] != 'com.legado.app.debug' ||
          (fixture['target'] as Map)['apkSha256'] !=
              '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5' ||
          sha256LfFile(file) !=
              '6d73f51c2a03a93b728075a2d2acb4b8a4c8e31f454961b6a4eb7c3e318a1548')) {
    throw const FormatException('Selected corpus identity differs');
  }
  final goldenFile = positional[1] == '-' ? null : File(positional[1]);
  final golden = goldenFile == null
      ? null
      : jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  if (selected && goldenFile != null && golden != null) {
    checkSelectedHarnessArtifact(goldenFile, golden);
    checkSelectedCaptureBundle(goldenFile, golden);
  }
  await NativeLibrary.initialize(libraryPath: positional[0]);
  try {
    final product = await observeProduct(fixture);
    final report = compareRows(
      fixture,
      product,
      golden,
      // The corpus pin must mean the same corpus on every host, and must agree
      // with the committed report's own `fixtureSha256`; `sha256File` would
      // record this checkout's line endings instead.
      fixtureSha256: selected ? sha256LfFile(file) : sha256CrlfFile(file),
      timeoutWitness: timeoutWitness,
    );
    report.addAll({
      'product': product,
      'librarySha256': sha256File(File(positional[0])),
      'goldenSha256': goldenFile == null ? null : sha256File(goldenFile),
      if (witnessFile != null)
        'timeoutWitnessDescriptorSha256': sha256File(witnessFile),
      'productCommit': (await Process.run('git', [
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim(),
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'sourceHashes': {
        for (final path in [
          'lib/source/content_processing.dart',
          'lib/source/content_re_segment.dart',
          'lib/source/java_regex.dart',
          'lib/source/js_source_runtime.dart',
          'tool/replace_rule_oracle/compare.dart',
        ])
          path: sha256File(File(path)),
      },
    });
    File(positional[2])
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    stdout.writeln(jsonEncode(report['counts']));
    // A blocked run must not become a green gate merely because product ran.
    final counts = report['counts'] as Map;
    exitCode = (counts['fail'] as int) > 0
        ? 1
        : (counts['not-run'] as int) > 0
        ? 2
        : 0;
  } finally {
    await InProcessSourceScriptRuntime.dispose();
  }
}
