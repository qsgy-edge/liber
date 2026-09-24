import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:liber/source/content_processing.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart' show ReplaceRule;
import 'package:pointycastle/digests/sha256.dart';

String sha256Bytes(Uint8List bytes) => SHA256Digest()
    .process(bytes)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String sha256File(File file) => sha256Bytes(file.readAsBytesSync());

/// This tool directory is not in `.gitattributes`'s `text eol=lf` list, so the
/// committed evidence pins hash a CRLF working tree. Hash the corpus with those
/// line endings, so one pin means the same corpus content on an LF checkout and
/// on the Windows checkout that produced the evidence.
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
    final cleanup = golden['cleanup'] as Map?;
    if (cleanup?['databaseClosed'] != true ||
        cleanup?['scratchRemoved'] != true) {
      throw const FormatException('Frozen cleanup is unverified');
    }
    frozen = (golden['rows'] as List).cast<Map>();
    checkIds(frozen, 'frozen');
    for (final row in frozen) {
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
    for (final field in ['title', 'content', 'selection']) {
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
    final notices = <String>[];
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
      'notices': notices,
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
  if (args.length != 3) {
    stderr.writeln(
      'Usage: dart run tool/replace_rule_oracle/compare.dart '
      '<library> <golden.json|-> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final file = File('tool/replace_rule_oracle/fixtures.json');
  final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  final goldenFile = args[1] == '-' ? null : File(args[1]);
  final golden = goldenFile == null
      ? null
      : jsonDecode(goldenFile.readAsStringSync()) as Map<String, dynamic>;
  await NativeLibrary.initialize(libraryPath: args[0]);
  try {
    final product = await observeProduct(fixture);
    final report = compareRows(
      fixture,
      product,
      golden,
      // The corpus pin must mean the same corpus on every host, and must agree
      // with the committed report's own `fixtureSha256`; `sha256File` would
      // record this checkout's line endings instead.
      fixtureSha256: sha256CrlfFile(file),
    );
    report.addAll({
      'product': product,
      'librarySha256': sha256File(File(args[0])),
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
    File(args[2])
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
