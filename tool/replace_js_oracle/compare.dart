import 'dart:convert';
import 'dart:io';

import 'package:liber/source/content_processing.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/store/database.dart' show ReplaceRule;
import 'package:pointycastle/digests/sha256.dart';

String sha256File(File file) => SHA256Digest()
    .process(file.readAsBytesSync())
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

/// The rows whose difference is an accepted divergence rather than a defect.
///
/// `js-timeout` is the ADR 0011 policy row: the frozen reader disables the rule,
/// injects the rule name plus the timeout exception text into the content and
/// schedules a restart; the product reports, disables and keeps the original
/// text. `js-binding-surface` is the approved facade difference: the frozen
/// script sees only the complete match, the product goes through the approved
/// source script facade. Neither is normalized into a pass, and both keep their
/// exact frozen and product values.
const _policyRows = {
  'js-timeout':
      'ADR 0011 / #17: the frozen reader disables the timed-out rule, replaces '
          'the content with the rule name plus the timeout exception text and '
          'schedules appCtx.restart(); the product reports the rule, disables it '
          'for the caller and keeps the original text.',
  'js-binding-surface':
      'Approved boundary (#49): frozen binds only the complete match as `result`; '
          'the product evaluates through the approved source script facade, whose '
          'documented globals are broader.',
};

/// Only absent evidence becomes not-run. Invalid evidence fails closed. Policy
/// rows still carry exact differences; they never turn into pass.
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
    for (final key in ['fixtureId', 'corpusVersion', 'baselineCommit']) {
      if (golden[key] != fixture[key]) {
        throw FormatException('Frozen $key does not match fixture');
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
  }
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < cases.length; i++) {
    final input = cases[i];
    final actual = product[i];
    final expected = frozen?[i];
    final differences = <Map<String, Object?>>[];
    final observations = <String, Object?>{};
    final policy = _policyRows[input['id']];
    // Every call records title, content, selection and the rules the run itself
    // disabled, so a cross-scope replacement or a disabled rule cannot hide in
    // an unobserved field.
    for (final field in ['title', 'content', 'selection', 'rulesDisabledByRun']) {
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
        : input['id'] == 'js-timeout'
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
      'productNotices': actual['notices'] ?? const <String>[],
      if (input['id'] == 'js-timeout') ...{
        'timeoutObserved': expected?['timeoutObserved'],
        'restartObservation': expected?['restartObservation'] ?? 'not-run',
        'timeoutCoverage': expected?['timeoutObserved'] == true
            ? 'observed: the frozen run disabled the timed-out rule and injected '
                  'the rule name plus the exception text'
            : 'not-run: no frozen timeout observed',
      },
      if (input['backupRule'] != null)
        'backupRule': {
          'id': input['backupRule']['id'],
          'name': input['backupRule']['name'],
          'scopeTitle': input['backupRule']['scopeTitle'],
          'scopeContent': input['backupRule']['scopeContent'],
          'isEnabled': input['backupRule']['isEnabled'],
          'recordedOutcome': input['recordedOutcome'],
        },
    });
  }
  final divergences = <Map<String, Object?>>[];
  for (final declared in (fixture['acceptedDivergences'] as List).cast<Map>()) {
    final row = rows.firstWhere((row) => row['id'] == declared['id']);
    divergences.add({
      ...declared,
      'status': row['status'],
      'differences': row['differences'],
    });
  }
  return {
    'fixtureId': fixture['fixtureId'],
    'fixtureSha256': fixtureSha256,
    'comparisonBoundary': fixture['comparisonBoundary'],
    'rows': rows,
    'acceptedDivergences': divergences,
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

/// The product side of the comparison: the approved reader content path, with
/// the same rules the corpus seeds into the frozen Room database. It does not
/// reimplement the frozen evaluator; `@js:` goes through [ContentProcessing] and
/// therefore through the approved source script facade.
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
      'rulesDisabledByRun': disabled,
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
      'Usage: dart run tool/replace_js_oracle/compare.dart '
      '<library> <golden.json|-> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final file = File('tool/replace_js_oracle/fixtures.json');
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
      fixtureSha256: sha256File(file),
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
          'lib/source/java_regex.dart',
          'lib/source/js_source_runtime.dart',
          'tool/replace_js_oracle/compare.dart',
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
