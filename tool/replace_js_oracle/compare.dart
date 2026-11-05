import 'dart:convert';
import 'dart:io';

import 'package:liber/domain/store_message.dart';
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
  if (fixture['baselineCommit'] == 'a7d37f1707a70a459ad708f4fe79341d1e42d716') {
    throw const FormatException(
      'Selected native evidence requires physical bundle verification',
    );
  }
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
    final frozenObserved = expected?['status'] == 'observed';
    final declaredObservations = input['observations'] as List;
    final requiresErrorNotice = declaredObservations.contains(
      'error-reporting',
    );
    final requiresTimeoutNotice = declaredObservations.contains(
      'timeout-observation',
    );
    final requiresNotice = requiresErrorNotice || requiresTimeoutNotice;
    final notices = actual['notices'];
    final validNotices =
        notices is List &&
        notices.isNotEmpty &&
        notices.every((notice) => notice is String && notice.trim().isNotEmpty);
    // This checks the product capture only. The frozen harness cannot observe
    // its notice channel, so neither notice text nor channel equality is proved.
    final noticeCaptureStatus = !frozenObserved
        ? 'not-run'
        : !requiresNotice
        ? 'notCompared'
        : !validNotices ||
              (requiresTimeoutNotice && expected?['timeoutObserved'] != true)
        ? 'fail'
        : 'pass';
    // Every call records title, content, selection and the rules the run itself
    // disabled, so a cross-scope replacement or a disabled rule cannot hide in
    // an unobserved field.
    for (final field in [
      'title',
      'content',
      'selection',
      'rulesDisabledByRun',
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
        : noticeCaptureStatus == 'fail'
        ? 'fail'
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
      'noticeCaptureIntegrity': {
        'status': noticeCaptureStatus,
        'reason': !frozenObserved
            ? 'No observed frozen row authorizes the product integrity check.'
            : !requiresNotice
            ? 'The corpus does not require a product notice on this row.'
            : !validNotices
            ? 'The product run must capture a nonempty list of nonblank notices.'
            : requiresTimeoutNotice && expected?['timeoutObserved'] != true
            ? 'The frozen row must have timeoutObserved == true.'
            : 'The product run captured the corpus-required notice.',
      },
      'noticeChannelComparison': 'notCompared',
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
  Map<String, dynamic> fixture, {
  bool typedNotices = false,
}) async {
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
      onNotice: notices.add,
      onRuleDisabled: (rule) async => disabled.add(rule.name),
    );
    final row = <String, Object?>{
      'id': input['id'],
      'selection': {
        'title': selected.titleRules.map((rule) => rule.name).toList(),
        'content': selected.contentRules.map((rule) => rule.name).toList(),
      },
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
    } finally {
      // Capture after both processors, including notices emitted before a
      // later error. The code and arguments (#72) remain locale independent.
      row['notices'] = [for (final notice in notices) notice.toString()];
      if (typedNotices) {
        row['noticeRecords'] = [for (final notice in notices) notice.toJson()];
      }
    }
  }
  return rows;
}

Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--selected') {
    await _selectedMain(args.skip(1).toList());
    return;
  }
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
      'productWorkingTreeStatus': (await Process.run('git', [
        'status',
        '--porcelain=v1',
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

/// Selected comparisons can only obtain rows from the physical verifier. A
/// product-only capture and failed or absent role never become native rows.
Future<void> _selectedMain(List<String> args) async {
  if (args.length != 10) {
    stderr.writeln(
      'Usage: compare.dart --selected <library> <harness.apk> '
      '<reference.apk> <frozen-source> <sdk> <java-home> <backup.zip> '
      '<main12-bundle|-> <timeout-bundle|-> <output.json>',
    );
    exitCode = 64;
    return;
  }
  final verifierOutput = '${args[9]}.verification';
  final command = <String>[
    'tool/replace_js_oracle/capture.py',
    '--selected',
    '--verify-only',
    '--apk',
    args[1],
    '--reference-apk',
    args[2],
    '--frozen-source',
    args[3],
    '--android-sdk',
    args[4],
    '--java-home',
    args[5],
    '--backup',
    args[6],
    '--output',
    verifierOutput,
    if (args[7] != '-') ...['--main12-bundle', args[7]],
    if (args[8] != '-') ...['--timeout-bundle', args[8]],
  ];
  final verified = await Process.run('python', command);
  if (verified.exitCode != 0) {
    stderr.writeln('Selected physical verifier refused: ${verified.stderr}');
    exitCode = 1;
    return;
  }
  final admitted =
      jsonDecode(File('$verifierOutput/admitted.json').readAsStringSync())
          as Map<String, dynamic>;
  final fixtureFile = File('tool/replace_js_oracle/fixtures-selected.json');
  final fixture =
      jsonDecode(fixtureFile.readAsStringSync()) as Map<String, dynamic>;
  await NativeLibrary.initialize(libraryPath: args[0]);
  try {
    final product = await observeProduct(fixture, typedNotices: true);
    final timeout = (fixture['cases'] as List).cast<Map>().singleWhere(
      (row) => row['id'] == 'js-timeout',
    );
    final unmodified = <String, dynamic>{
      ...fixture,
      'cases': [
        <String, dynamic>{
          ...Map<String, dynamic>.from(timeout),
          'rules': <Object>[],
        },
      ],
    };
    final preserved = (await observeProduct(
      unmodified,
      typedNotices: true,
    )).single;
    if (preserved['status'] != 'observed' || preserved['content'] is! String) {
      throw const FormatException('Product preserved-text control failed');
    }
    final rows = _compareSelected(
      fixture,
      product,
      admitted,
      preserved['content'] as String,
    );
    final counts = <String, int>{
      for (final state in ['pass', 'fail', 'notCompared', 'not-run'])
        state: rows.where((row) => row['status'] == state).length,
    };
    final report = <String, Object?>{
      'fixtureId': fixture['fixtureId'],
      'fixtureSha256': sha256File(fixtureFile),
      'baselineCommit': fixture['baselineCommit'],
      'roles': admitted['states'],
      'recovery': admitted['recovery'],
      'rows': rows,
      'counts': counts,
      'complete': rows.every((row) => row['status'] == 'pass'),
      'product': product,
      'librarySha256': sha256File(File(args[0])),
      'recordedAt': DateTime.now().toUtc().toIso8601String(),
      'productCommit': (await Process.run('git', [
        'rev-parse',
        'HEAD',
      ])).stdout.toString().trim(),
      'productWorkingTreeStatus': (await Process.run('git', [
        'status',
        '--porcelain=v1',
      ])).stdout.toString().trim(),
      'verifierCommand': command,
      'verifierStdout': verified.stdout.toString(),
    };
    File(args[9])
      ..parent.createSync(recursive: true)
      ..writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(report)}\n',
      );
    stdout.writeln(jsonEncode(counts));
    exitCode = counts['fail']! > 0
        ? 1
        : counts['not-run']! > 0
        ? 2
        : 0;
  } finally {
    await InProcessSourceScriptRuntime.dispose();
  }
}

/// Product notice integrity only; this does not admit any native evidence.
bool selectedNoticeIntegrity(String id, Object? notices) {
  if (notices is! List ||
      !notices.every(
        (n) =>
            n is Map &&
            n.length == 2 &&
            n.containsKey('code') &&
            n.containsKey('arguments') &&
            n['code'] is String &&
            (n['code'] as String).isNotEmpty &&
            n['arguments'] is List &&
            (n['arguments'] as List).every((a) => a is String || a is int),
      )) {
    return false;
  }
  final requiredCode = id == 'js-error'
      ? 'replaceRuleFailed'
      : id == 'js-timeout'
      ? 'replaceRuleTimedOut'
      : null;
  final relevant = notices
      .where(
        (n) =>
            n is Map &&
            (n['code'] == 'replaceRuleFailed' ||
                n['code'] == 'replaceRuleTimedOut'),
      )
      .toList();
  if (requiredCode == null) return relevant.isEmpty;
  if (notices.any(
    (n) =>
        n is Map &&
        n['code'] == 'replaceRuleUnusable' &&
        n['arguments'] is List &&
        (n['arguments'] as List).isNotEmpty &&
        (n['arguments'] as List).first == id,
  )) {
    return false;
  }
  if (relevant.length != 1) return false;
  final n = relevant.single as Map;
  if (n['code'] != requiredCode || n['arguments'] is! List) return false;
  final args = n['arguments'] as List;
  if (args.length != 2 || args[0] != id) return false;
  return id == 'js-timeout'
      ? args[1] == 200
      : args[1] is String && (args[1] as String).trim().isNotEmpty;
}

/// The selected timeout's returned diagnostic, not a manufactured expected result.
bool selectedTimeoutDiagnostic(String text) {
  return text ==
      '　　js-timeoutio.legado.app.exception.RegexTimeoutException: 替换超时,3秒后还未结束将重启应用\n　　规则名称:js-timeout\n　　替换规则:广告\n　　替换内容:正文广告。';
}

/// Product timeout policy retains the exact separately processed source text.
bool selectedTimeoutPreservesText(Object? actual, String preserved) =>
    actual is String && actual == preserved;

/// Only differences inside the fixed binding diagnostic qualify for that policy.
bool selectedBindingDifference(String product, String native) {
  final shape = RegExp(
    r'^　　result=string \$1=undefined \$name=undefined book=(object|undefined) source=(object|undefined) java=(object|undefined) sourceKey=(string|undefined)$',
  );
  return shape.hasMatch(product) && shape.hasMatch(native);
}

List<Map<String, Object?>> _compareSelected(
  Map<String, dynamic> fixture,
  List<Map<String, Object?>> product,
  Map<String, dynamic> admitted,
  String timeoutPreservedText,
) {
  final cases = (fixture['cases'] as List).cast<Map>();
  if (product.length != cases.length ||
      !_equal(
        product.map((r) => r['id']).toList(),
        cases.map((r) => r['id']).toList(),
      )) {
    throw const FormatException('Selected product row identity/order differs');
  }
  final native = <String, Map>{};
  for (final role in ['main12', 'timeout']) {
    final report = admitted[role];
    if (report == null) continue;
    for (final row in (report['rows'] as List).cast<Map>()) {
      if (native.containsKey(row['id'])) {
        throw const FormatException('Duplicate selected row');
      }
      native[row['id'] as String] = row;
    }
  }
  final rows = <Map<String, Object?>>[];
  for (var i = 0; i < cases.length; i++) {
    final input = cases[i];
    final actual = product[i];
    final id = input['id'] as String;
    final expected = native[id];
    final differences = <Map<String, Object?>>[];
    final observations = <String, Object?>{};
    for (final field in [
      'title',
      'content',
      'selection',
      'rulesDisabledByRun',
    ]) {
      if (expected == null) {
        observations[field] = 'not-run';
        continue;
      }
      if (!actual.containsKey(field) || !expected.containsKey(field)) {
        throw FormatException('$id missing $field');
      }
      final equal = _equal(actual[field], expected[field]);
      observations[field] = equal ? 'pass' : 'fail';
      if (!equal) {
        differences.add({
          'field': field,
          'native': expected[field],
          'product': actual[field],
        });
      }
    }
    final validNotices = selectedNoticeIntegrity(id, actual['noticeRecords']);
    final timeoutObserved =
        id == 'js-timeout' &&
        expected != null &&
        (expected['rulesDisabledByRun'] as List).contains('js-timeout') &&
        selectedTimeoutDiagnostic(expected['content'] as String);
    final onlyContent = differences.every((d) => d['field'] == 'content');
    final String status;
    if (actual['status'] != 'observed' ||
        !validNotices ||
        (id == 'js-timeout' &&
            !selectedTimeoutPreservesText(
              actual['content'],
              timeoutPreservedText,
            ))) {
      status = 'fail';
    } else if (expected == null) {
      status = 'not-run';
    } else if (differences.isNotEmpty &&
        !(onlyContent &&
            ((id == 'js-binding-surface' &&
                    selectedBindingDifference(
                      actual['content'] as String,
                      expected['content'] as String,
                    )) ||
                (id == 'js-timeout' && timeoutObserved)))) {
      status = 'fail';
    } else if (id == 'js-timeout' && !timeoutObserved) {
      status = 'not-run';
    } else if (differences.isNotEmpty || id == 'js-timeout') {
      status = 'notCompared';
    } else {
      status = 'pass';
    }
    rows.add({
      'id': id,
      'status': status,
      'nativeStatus': expected == null ? 'not-run' : 'observed',
      'productStatus': actual['status'],
      'observations': observations,
      'differences': differences,
      'native': expected,
      'productNotices': actual['noticeRecords'],
      'noticeCaptureIntegrity': validNotices ? 'pass' : 'fail',
      'noticeChannelComparison': 'notCompared',
      if (id == 'js-binding-surface') 'policy': 'js-binding-surface',
      if (id == 'js-error') 'policy': 'js-error',
      if (id == 'js-timeout') ...{
        'policy': 'js-timeout',
        'timeoutCoverage': timeoutObserved
            ? 'observed in native returned fields'
            : 'not-run: no admitted timeout observation',
      },
    });
  }
  return rows;
}
