// THROWAWAY: measure the product's JavaScript deadline and heap limit.
//
// Drives lib/source/js_source_runtime.dart against the real fjs DLL. Each case
// runs in its own process so an uninterruptible execution is recorded as a
// kill instead of hanging the harness.
//
// Usage: dart run tool/runtime_limits_prototype/product_probe.dart <fjs.dll> <case>
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/js_source_runtime.dart';

class Outcome {
  Outcome(this.category, this.milliseconds);
  final String category;
  final double milliseconds;
}

Future<Outcome> run(
  InProcessSourceScriptRuntime runtime,
  String source, {
  required Duration timeout,
  Map<String, Object?> input = const {},
}) async {
  final watch = Stopwatch()..start();
  try {
    await runtime.evaluate(source: source, input: input, timeout: timeout);
    return Outcome('success', watch.elapsedMicroseconds / 1000);
  } on SourceScriptError catch (error) {
    return Outcome(error.category, watch.elapsedMicroseconds / 1000);
  } catch (error) {
    return Outcome('unexpected:${error.runtimeType}', watch.elapsedMicroseconds / 1000);
  }
}

double overshoot(Outcome outcome, Duration timeout) =>
    outcome.milliseconds - timeout.inMicroseconds / 1000;

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('usage: product_probe.dart <fjs.dll> <case>');
    exit(2);
  }
  await InProcessSourceScriptRuntime.initialize(libraryPath: args.first);
  final checks = <String, bool>{};
  final measurements = <String, Object?>{};
  final caseName = args[1];
  const library = 'var __probe = {n: 0}; // runtime limits probe';

  switch (caseName) {
    // A pure interpreter loop under the Rust-held deadline.
    case 'deadline-basic':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        await run(runtime, '1 + 1', timeout: const Duration(seconds: 2));
        final runs = <Map<String, Object?>>[];
        for (final deadline in const [100, 200, 500]) {
          final timeout = Duration(milliseconds: deadline);
          final outcome = await run(runtime, 'while(true) {}', timeout: timeout);
          runs.add({
            'deadlineMs': deadline,
            'category': outcome.category,
            'measuredMs': outcome.milliseconds,
            'overshootMs': overshoot(outcome, timeout),
          });
        }
        measurements['runs'] = runs;
        checks['interpreterLoopTimedOut'] =
            runs.every((entry) => entry['category'] == 'timeout');
        checks['interpreterLoopOvershootUnder50Ms'] =
            runs.every((entry) => (entry['overshootMs']! as double) < 50);
        final followUp = await run(runtime, '2 + 3', timeout: const Duration(seconds: 2));
        checks['followUpWorks'] =
            followUp.category == 'success' && followUp.milliseconds < 500;
      }
      break;

    // A loop whose body is one long native call: the deadline is sampled.
    case 'deadline-heavy-loop-body':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        await run(runtime, '1 + 1', timeout: const Duration(seconds: 2));
        final timeout = const Duration(milliseconds: 200);
        final outcome =
            await run(runtime, "while(true) { 'x'.repeat(50000); }", timeout: timeout);
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'overshootMs': overshoot(outcome, timeout),
        };
        checks['heavyLoopBodyTimedOut'] = outcome.category == 'timeout';
        // The pinned 10 000 quantum measured 1 942.1 ms of overshoot on this
        // row; the shipped 1 000 quantum brings it under a tenth of a second.
        checks['heavyLoopBodyOvershootUnder100Ms'] = overshoot(outcome, timeout) < 100;
      }
      break;

    // One long C-level call contains no interrupt poll at all, so the caller
    // waits for the whole call and only then learns it exceeded the deadline. The
    // post-call loop is there so the poll happens as soon as the call returns;
    // without it the execution can end without the interpreter polling again and
    // the deadline is never reported. The payload needs a heap above the
    // runtime's default budget: the parsed array alone costs about 128 MB, and a
    // heap limit would turn this row into the memory row instead of the
    // single-call row.
    case 'deadline-single-native-call':
      {
        final runtime = InProcessSourceScriptRuntime(
          jsLib: library,
          memoryLimitBytes: 512 * 1024 * 1024,
        );
        await run(runtime, '1 + 1', timeout: const Duration(seconds: 2));
        final timeout = const Duration(milliseconds: 100);
        final outcome = await run(
          runtime,
          "var n = JSON.parse('[' + '1,'.repeat(8000000) + '1]').length; "
          'for (var i = 0; i < 2000; i++) n += 0; n',
          timeout: timeout,
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'overshootMs': overshoot(outcome, timeout),
        };
        checks['singleNativeCallReportedTimeout'] = outcome.category == 'timeout';
        checks['singleNativeCallPassedDeadline'] = outcome.milliseconds > 120;
        final followUp =
            await run(runtime, '5 + 5', timeout: const Duration(seconds: 2));
        checks['followUpWorks'] = followUp.category == 'success';
      }
      break;

    // A try/catch around the loop cannot swallow the deadline error.
    case 'deadline-uncatchable':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        final outcome = await run(
          runtime,
          'var caught = 0; try { while(true) caught++; } catch (e) { caught = 99; } caught',
          timeout: const Duration(milliseconds: 200),
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
        };
        checks['deadlineUncatchable'] = outcome.category == 'timeout';
      }
      break;

    // A catastrophically backtracking regular expression.
    case 'deadline-regex-bomb':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        final timeout = const Duration(milliseconds: 200);
        final outcome = await run(
          runtime,
          r"/(a+)+$/.test('a'.repeat(64) + '!')",
          timeout: timeout,
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'overshootMs': overshoot(outcome, timeout),
        };
        checks['regexBombTimedOut'] = outcome.category == 'timeout';
        checks['regexBombOvershootUnder500Ms'] = overshoot(outcome, timeout) < 500;
      }
      break;

    // A catch-and-retry allocation loop at the heap limit: every failed
    // allocation retries garbage collection before the next interrupt poll.
    case 'deadline-oom-retry-loop':
      {
        final runtime = InProcessSourceScriptRuntime(
          jsLib: library,
          memoryLimitBytes: 8 * 1024 * 1024,
        );
        final timeout = const Duration(milliseconds: 300);
        final outcome = await run(
          runtime,
          '(function() { var last = null; for (;;) { try { last = new Array(20000).fill(0); } catch (e) {} } })()',
          timeout: timeout,
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'overshootMs': overshoot(outcome, timeout),
        };
        checks['oomRetryReportedTimeout'] = outcome.category == 'timeout';
        // The pinned 10 000 quantum let this row run 1 367.2 ms past a 300 ms
        // deadline through the product; the shipped 1 000 quantum does not.
        checks['oomRetryOvershootUnder500Ms'] = overshoot(outcome, timeout) < 500;
        final followUp =
            await run(runtime, '4 + 4', timeout: const Duration(seconds: 5));
        checks['followUpWorks'] = followUp.category == 'success';
      }
      break;

    // A script suspended in a synchronous host call: the outer wait is parked,
    // and the deadline has to reach it through the suspension. Nothing on the
    // Dart side ends this call — the budget went in with the scope and the Rust
    // clock both ends the wait and tears the host request down.
    case 'deadline-host-call':
      {
        final held = Completer<void>();
        final observedCancel = Completer<void>();
        final runtime = InProcessSourceScriptRuntime(
          jsLib: library,
          hostCall: (method, payload, cancellation) async {
            final aborted = Completer<void>();
            final unlisten = cancellation.listen(() {
              if (!observedCancel.isCompleted) observedCancel.complete();
              if (!aborted.isCompleted) aborted.complete();
            });
            try {
              await Future.any([held.future, aborted.future]);
              cancellation.throwIfCancelled();
              return 'held';
            } finally {
              unlisten();
            }
          },
        );
        final timeout = const Duration(milliseconds: 200);
        final outcome = await run(
          runtime,
          "fjs.bridge_call(JSON.stringify({method:'echo',payload:'hold'}))",
          timeout: timeout,
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'overshootMs': overshoot(outcome, timeout),
          'hostObservedCancellation': observedCancel.isCompleted,
        };
        checks['hostCallTimedOut'] = outcome.category == 'timeout';
        checks['hostObservedCancellation'] = observedCancel.isCompleted;
        checks['hostCallOvershootUnder500Ms'] = overshoot(outcome, timeout) < 500;
        final followUp =
            await run(runtime, '7 + 8', timeout: const Duration(seconds: 2));
        checks['followUpWorks'] = followUp.category == 'success';
      }
      break;

    // The deadline is Rust's: the Dart isolate below is blocked for longer than
    // the deadline, so no Dart timer could fire during it, and the execution is
    // over before the isolate gets the event loop back.
    case 'deadline-isolate-blocked':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        await run(runtime, '1 + 1', timeout: const Duration(seconds: 2));
        const timeout = Duration(milliseconds: 100);
        final pending = run(runtime, 'while(true) {}', timeout: timeout);
        await Future<void>.delayed(const Duration(milliseconds: 30));
        final until = DateTime.now().add(const Duration(milliseconds: 400));
        while (DateTime.now().isBefore(until)) {
          // Deliberately block the isolate the old Dart timer would have needed.
        }
        final afterUnblock = Stopwatch()..start();
        final outcome = await pending;
        measurements['run'] = {
          'category': outcome.category,
          'deadlineMs': timeout.inMilliseconds,
          'blockedIsolateMs': 400,
          'clock': 'rust',
          'measuredMs': outcome.milliseconds,
          'elapsedAfterUnblockMs': afterUnblock.elapsedMicroseconds / 1000,
        };
        checks['blockedIsolateStillTimedOut'] = outcome.category == 'timeout';
        checks['dartIsolateReallyBlocked'] = outcome.milliseconds > 350;
        // The execution had already ended when the isolate came back: no Dart
        // timer had to run for it.
        checks['deadlineEnforcedWhileIsolateBlocked'] =
            (measurements['run']! as Map)['elapsedAfterUnblockMs']! as double <
            100;
      }
      break;

    // The heap limit through the product runtime, twice on one shared engine.
    case 'memory-limit-alloc-loop':
      {
        final runtime = InProcessSourceScriptRuntime(
          jsLib: library,
          memoryLimitBytes: 8 * 1024 * 1024,
        );
        final baseline = ProcessInfo.currentRss;
        final source =
            '(function() { var blocks = []; while(true) { blocks.push(new Array(1024).fill(7)); } })()';
        final first = await run(runtime, source, timeout: const Duration(seconds: 10));
        final afterFirst = ProcessInfo.currentRss;
        final second = await run(runtime, source, timeout: const Duration(seconds: 10));
        final afterSecond = ProcessInfo.currentRss;
        final followUp = await run(runtime, '21 * 2', timeout: const Duration(seconds: 5));
        measurements['runs'] = {
          'first': {'category': first.category, 'measuredMs': first.milliseconds},
          'second': {'category': second.category, 'measuredMs': second.milliseconds},
          'rssBaseline': baseline,
          'rssAfterFirst': afterFirst,
          'rssAfterSecond': afterSecond,
          'rssGrowthBytes': afterSecond - baseline,
        };
        // 'js' is the product's JavaScript-error class; 'timeout' or
        // 'cancelled' would not mean the heap limit fired.
        checks['heapLimitReported'] =
            first.category == 'js' && second.category == 'js';
        checks['bothRunsSameCategory'] = first.category == second.category;
        checks['sharedEngineStillUsable'] =
            followUp.category == 'success' && followUp.milliseconds < 2000;
        checks['memoryGrowthStayedBounded'] =
            (afterSecond - baseline) < 128 * 1024 * 1024;
      }
      break;

    // One allocation far above the budget.
    case 'memory-limit-huge-allocation':
      {
        final runtime = InProcessSourceScriptRuntime(
          jsLib: library,
          memoryLimitBytes: 8 * 1024 * 1024,
        );
        final baseline = ProcessInfo.currentRss;
        final outcome = await run(
          runtime,
          "'x'.repeat(268435456)",
          timeout: const Duration(seconds: 10),
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
          'rssGrowthBytes': ProcessInfo.currentRss - baseline,
        };
        checks['hugeAllocationRejected'] = outcome.category == 'js';
        checks['hugeAllocationReturnedFast'] = outcome.milliseconds < 5000;
        final followUp =
            await run(runtime, '3 + 4', timeout: const Duration(seconds: 5));
        checks['followUpWorks'] = followUp.category == 'success';
      }
      break;

    // Deep recursion under the runtime's stack limit.
    case 'stack-depth':
      {
        final runtime = InProcessSourceScriptRuntime(jsLib: library);
        final outcome = await run(
          runtime,
          '(function() { function f(n) { return n <= 0 ? 0 : f(n - 1); } return f(1000000); })()',
          timeout: const Duration(seconds: 10),
        );
        measurements['run'] = {
          'category': outcome.category,
          'measuredMs': outcome.milliseconds,
        };
        checks['stackOverflowReturned'] = outcome.category == 'js';
        final followUp =
            await run(runtime, '9 + 1', timeout: const Duration(seconds: 5));
        checks['followUpWorks'] = followUp.category == 'success';
      }
      break;

    default:
      stderr.writeln('unknown case: $caseName');
      exit(2);
  }

  final passed = checks.values.every((value) => value);
  stdout.writeln(jsonEncode({
    'case': caseName,
    'checks': checks,
    'measurements': measurements,
    'status': passed ? 'pass' : 'fail',
  }));
  await InProcessSourceScriptRuntime.dispose();
  if (!passed) exitCode = 1;
}
