import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:liber/domain/store_message.dart';
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart' show ReplaceRule;
import 'package:pointycastle/digests/sha256.dart';

const selectedReaderFingerprint =
    'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys';

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
          !selectedReaderSourcePaths
              .where(
                (path) =>
                    !path.endsWith('/compare.dart') &&
                    !path.endsWith('/capture.py') &&
                    !path.endsWith('/build.ps1'),
              )
              .every(
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
    if (cleanup?['databaseClosed'] != true ||
        cleanup?['scratchRemoved'] != true ||
        (fixture['corpusVersion'] == 2 &&
            (cleanup?['terminalProved'] != true ||
                cleanup?['activityLaunchAttempts'] != 0 ||
                cleanup?['scratchRetained'] != false ||
                cleanup?['preferencesRemoved'] is! List ||
                (cleanup!['preferencesRemoved'] as List).isEmpty ||
                !(cleanup['preferencesRemoved'] as List).every(
                  (row) =>
                      row is Map &&
                      row['ok'] == true &&
                      row['name'] is String &&
                      (row['name'] as String).startsWith(
                        'liber_replace_selected_',
                      ),
                )))) {
      throw const FormatException('Frozen cleanup is unverified');
    }
    frozen = (golden['rows'] as List).cast<Map>();
    checkIds(frozen, 'frozen');
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
    final expected = frozen?[i];
    final differences = <Map<String, Object?>>[];
    final observations = <String, Object?>{};
    final policy = switch (input['id']) {
      'timeout' =>
        'ADR 0011: per-rule disable/preserve text; frozen stack trace '
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
      'frozenStatus': expected?['status'] ?? 'not-run',
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
        'timeoutObserved': expected?['timeoutObserved'],
        'restartObservation': expected?['restartObservation'] ?? 'not-run',
        'timeoutCoverage': expected?['timeoutObserved'] == true
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
      args.length == 5 &&
      args[0] == '--corpus' &&
      File(args[1]).absolute.path ==
          File('tool/replace_rule_oracle/fixtures-selected.json').absolute.path;
  if ((!selected && args.length != 3) ||
      (args.length == 3 && args[0] == '--corpus')) {
    stderr.writeln(
      'Usage: dart run tool/replace_rule_oracle/compare.dart '
      '[--corpus tool/replace_rule_oracle/fixtures-selected.json] '
      '<library> <golden.json|-> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final positional = selected ? args.sublist(2) : args;
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
    );
    report.addAll({
      'product': product,
      'librarySha256': sha256File(File(positional[0])),
      'goldenSha256': goldenFile == null ? null : sha256File(goldenFile),
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
