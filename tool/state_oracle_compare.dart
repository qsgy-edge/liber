import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/js_source_runtime.dart';

Future<void> main(List<String> args) async {
  if (args.length != 3) throw ArgumentError('DLL golden output');
  final fixture =
      jsonDecode(
            await File('tool/nested_oracle/state-fixtures.json').readAsString(),
          )
          as Map<String, dynamic>;
  final golden =
      jsonDecode(await File(args[1]).readAsString()) as Map<String, dynamic>;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 18764);
  final origin = 'http://127.0.0.1:${server.port}';
  final held = Completer<void>(),
      release = Completer<void>(),
      entered = Completer<void>();
  final earlyHeld = Completer<void>(),
      lateHeld = Completer<void>(),
      earlyRelease = Completer<void>(),
      lateRelease = Completer<void>();
  final expanded = (golden['values'] as Map).containsKey(
    'firstCompletesWhileSecondHeld',
  );
  final requests = <String>[];
  final handlers = <Future<void>>[];
  Future<void> serve(HttpRequest request) async {
    requests.add('${request.method} ${request.uri}');
    if (request.uri.path == '/hold') {
      held.complete();
      await release.future;
    }
    if (request.uri.path == '/early') {
      earlyHeld.complete();
      await earlyRelease.future;
    }
    if (request.uri.path == '/late') {
      lateHeld.complete();
      await lateRelease.future;
    }
    request.response.write('ok');
    await request.response.close();
    if (request.uri.path == '/entered') entered.complete();
  }

  server.listen((request) {
    handlers.add(serve(request));
  });
  final host = SourceHostDispatcher(transport: HttpSourceTransport());
  await InProcessSourceScriptRuntime.initialize(libraryPath: args[0]);
  Future<String> run(
    String lib,
    String key, {
    SourceCancellation? token,
  }) async {
    try {
      final result =
          await InProcessSourceScriptRuntime(
            jsLib: lib,
            dispatcher: host,
          ).evaluate(
            source: (fixture[key] as String).replaceAll(r'$ORIGIN', origin),
            input: {'key': 'outer-key', 'page': 7},
            timeout: Duration(
              milliseconds: fixture['operationTimeoutMilliseconds'] as int,
            ),
            cancellation: token,
          );
      return result.toString();
    } on SourceScriptError catch (error) {
      return 'error:${error.category}';
    }
  }

  final values = <String, Object?>{};
  try {
    final concurrent = '${fixture['library']}concurrent';
    await run(concurrent, 'warm');
    final first = run(concurrent, 'first');
    await held.future.timeout(const Duration(seconds: 5));
    final second = run(concurrent, 'second');
    var complete = false;
    try {
      await second.timeout(
        Duration(milliseconds: fixture['barrierWaitMilliseconds'] as int),
      );
      complete = true;
    } on TimeoutException {
      // The observed task stays pending until the held HTTP response releases.
    }
    values['secondCompletedWhileFirstHeld'] = complete;
    release.complete();
    values['firstResult'] = await first;
    values['secondResult'] = await second;
    values['concurrentFinalState'] = await run(concurrent, 'read');
    if (expanded) {
      final early = run(concurrent, 'early');
      await earlyHeld.future.timeout(const Duration(seconds: 5));
      final late = run(concurrent, 'late');
      await lateHeld.future.timeout(const Duration(seconds: 5));
      earlyRelease.complete();
      var finished = false;
      try {
        await early.timeout(const Duration(seconds: 2));
        finished = true;
      } on TimeoutException {
        /* Late request is still held. */
      }
      values['firstCompletesWhileSecondHeld'] = finished;
      lateRelease.complete();
      await Future.wait([early, late]);
    }
    final cancelled = '${fixture['library']}cancel';
    await run(cancelled, 'warm');
    final token = SourceCancellation();
    final interrupted = run(cancelled, 'cancel', token: token);
    await entered.future.timeout(const Duration(seconds: 5));
    token.cancel();
    values['cancelResult'] = await interrupted;
    values['afterCancelState'] = await run(cancelled, 'read');
    final base = '${fixture['library']}cache-';
    for (var i = 0; i < 16; i++) {
      await run('$base$i', 'seed');
    }
    values['lruTouch'] = await run('${base}0', 'read');
    await run('${base}16', 'seed');
    values['lruRetained'] = await run('${base}0', 'read');
    values['lruEvicted'] = await run('${base}1', 'read');
    final expected = golden['values'] as Map<String, dynamic>;
    // These fields are numeric observations. Rhino Number.toString emits .0;
    // compare numeric values, never normalize arbitrary JS string results.
    const numericFields = {
      'firstResult',
      'secondResult',
      'concurrentFinalState',
      'afterCancelState',
      'lruTouch',
      'lruRetained',
      'lruEvicted',
    };
    final differences = <Object>[];
    if (golden['baselineCommit'] != fixture['baselineCommit']) {
      throw StateError('Baseline mismatch');
    }
    if (expected.length != values.length ||
        !values.keys.every(expected.containsKey)) {
      throw StateError('Observation coverage mismatch');
    }
    for (final entry in expected.entries) {
      final actual = values[entry.key];
      final equal = numericFields.contains(entry.key)
          ? num.tryParse('${entry.value}') != null &&
                num.tryParse('${entry.value}') == num.tryParse('$actual')
          : actual == entry.value;
      if (!equal) {
        differences.add({
          'field': entry.key,
          'expected': entry.value,
          'actual': actual,
        });
      }
    }
    if (jsonEncode(golden['requests']) != jsonEncode(requests)) {
      differences.add({
        'field': 'requests',
        'expected': golden['requests'],
        'actual': requests,
      });
    }
    final report = {
      'platform': 'windows',
      'baselineCommit': fixture['baselineCommit'],
      'golden': args[1],
      'values': values,
      'requests': requests,
      'numericComparisonFields': numericFields.toList(),
      'status': differences.isEmpty ? 'pass' : 'fail',
      'notRun': expanded
          ? <String>[]
          : ['firstCompletesWhileSecondHeld: absent from selected golden'],
      'differences': differences,
    };
    await File(
      args[2],
    ).writeAsString('${const JsonEncoder.withIndent('  ').convert(report)}\n');
    stdout.writeln(jsonEncode(report));
    if (differences.isNotEmpty) exitCode = 1;
  } finally {
    if (!release.isCompleted) release.complete();
    if (!earlyRelease.isCompleted) earlyRelease.complete();
    if (!lateRelease.isCompleted) lateRelease.complete();
    await server.close(force: true);
    await Future.wait(handlers);
    await InProcessSourceScriptRuntime.dispose();
  }
}
