import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/js_source_runtime.dart';

Future<void> main(List<String> args) async {
  await InProcessSourceScriptRuntime.initialize(libraryPath: args.single);
  final checks = <String, bool>{};
  const library = 'var state={n:0}; // scoped isolation gate';
  final waiting = <String, Completer<void>>{};
  final releases = <String, Completer<void>>{};
  final cancelledHost = <String>{};
  Future<Object?> host(
    String method,
    Object? payload,
    SourceCancellation cancellation,
  ) async {
    final key = payload as String;
    final done = releases[key]!;
    final aborted = Completer<void>();
    final unlisten = cancellation.listen(() {
      cancelledHost.add(key);
      if (!aborted.isCompleted) aborted.complete();
    });
    waiting[key]!.complete();
    try {
      await Future.any([done.future, aborted.future]);
      cancellation.throwIfCancelled();
      return key;
    } finally {
      unlisten();
    }
  }

  final runtime = InProcessSourceScriptRuntime(jsLib: library, hostCall: host);
  Future<Object?> run(String script, {SourceCancellation? token}) async {
    try {
      return await runtime.evaluate(
        source: script,
        input: {},
        timeout: const Duration(seconds: 5),
        cancellation: token,
      );
    } on SourceScriptError catch (error) {
      return 'error:${error.category}';
    }
  }

  String call(String key) =>
      'fjs.bridge_call(${jsonEncode(jsonEncode({'method': 'echo', 'payload': key}))})';
  void prepare(String key) {
    waiting[key] = Completer<void>();
    releases[key] = Completer<void>();
  }

  try {
    await run('state.n=0');
    prepare('parent');
    final parentCancel = SourceCancellation();
    final parent = run(
      'state.n=10;${call('parent')};state.n',
      token: parentCancel,
    );
    await waiting['parent']!.future.timeout(const Duration(seconds: 2));
    final childCancel = SourceCancellation();
    prepare('child');
    final child = run(
      'state.n=20;${call('child')};state.n',
      token: childCancel,
    );
    await waiting['child']!.future.timeout(const Duration(seconds: 2));
    childCancel.cancel();
    checks['childCancels'] = await child == 'error:cancelled';
    checks['parentIoNotCancelled'] = !cancelledHost.contains('parent');
    releases['parent']!.complete();
    checks['parentResumesWithSharedState'] = await parent == 20;
    checks['dartHostObservesChildCancellation'] = cancelledHost.contains(
      'child',
    );
    checks['stateSurvivesChildCancel'] = await run('state.n') == 20;

    prepare('parent2');
    prepare('child2');
    final outerToken = SourceCancellation();
    final outer = run(
      'state.n=30;${call('parent2')};state.n',
      token: outerToken,
    );
    await waiting['parent2']!.future.timeout(const Duration(seconds: 2));
    final inner = run('state.n=40;${call('child2')};state.n');
    await waiting['child2']!.future.timeout(const Duration(seconds: 2));
    outerToken.cancel();
    checks['childIoNotCancelled'] = !cancelledHost.contains('child2');
    releases['child2']!.complete();
    checks['childCompletesDespiteParentCancel'] = await inner == 40;
    checks['parentCancels'] = await outer == 'error:cancelled';
    checks['stateSurvivesParentCancel'] = await run('state.n') == 40;
    // A completion that arrives while a nested execution owns the thread is
    // delivered when the outer wait resumes instead of being lost. The frozen
    // reader could also complete the *outer* execution first, because it resumes
    // two independently parked scopes in any order; the one execution model
    // cannot, so `firstCompletesWhileSecondHeld` is deleted here (it is not a
    // gate-detectable behavior any more) and that single observation is recorded
    // as `notCompared` by tool/state_oracle_compare.dart on every desktop
    // platform. ADR 0009 removed the per-execution stacks that made it possible.
    prepare('early');
    prepare('late');
    final early = run('${call('early')};state.n');
    await waiting['early']!.future.timeout(const Duration(seconds: 2));
    final late = run('${call('late')};state.n');
    await waiting['late']!.future.timeout(const Duration(seconds: 2));
    releases['early']!.complete();
    releases['late']!.complete();
    final nestedResults = await Future.wait([early, late]);
    checks['deferredCompletionDelivered'] =
        nestedResults[0] == 40 && nestedResults[1] == 40;

    // Raw scoped-execution battery: host cancel callbacks, queued submission and
    // reservation/discard/close interleavings that the product-level checks
    // above cannot observe. A dedicated engine keeps its own queue, request
    // table and cancel counters so every scenario stays independent.
    final scopedEngine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
    );
    final scopedEntered = <String, Completer<BigInt>>{};
    final nativeCancels = <BigInt>[];
    Future<BigInt> reserveScoped() => scopedEngine.createScopedExecution();
    Future<Object?> runScoped(BigInt id, String source) => scopedEngine
        .evalScoped(id: id, source: source)
        .then<Object?>(
          (value) => value.value,
          onError: (Object error) => error,
        );
    Future<BigInt> enterScoped(String key) {
      final completer = Completer<BigInt>();
      scopedEntered[key] = completer;
      return completer.future.timeout(const Duration(seconds: 3));
    }

    Future<void> completeScoped(BigInt id, String answer) =>
        completeBridgeRequestGlobal(
          id: id,
          result: JsResult.ok(JsValue.string(answer)),
        );
    Future<void> settleNativeCancels(int expected) async {
      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (nativeCancels.length < expected &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    try {
      await scopedEngine.initBroker(
        start: (request) {
          final completer = scopedEntered[request.value.value as String];
          if (completer != null && !completer.isCompleted) {
            completer.complete(request.id);
          }
        },
        cancel: (id) async {
          nativeCancels.add(id);
        },
      );

      // Cancelling a parked scope releases its own host request only. The
      // nested scope is parked inside the outer one, so the one execution model
      // fixes the completion order: the outer scope settles when the nested one
      // returns. Two independently parked root scopes were the fiber path's, are
      // gone with it (ADR 0009), and `firstCompletesWhileSecondHeld` is the only
      // observation the differential contract recorded for them — it stays visible
      // as `notCompared` in tool/state_oracle_compare.dart.
      final alphaId = await reserveScoped();
      final alphaCall = runScoped(alphaId, 'fjs.bridge_call("alpha")');
      final alphaRequest = await enterScoped('alpha');
      final betaId = await reserveScoped();
      final betaCall = runScoped(betaId, 'fjs.bridge_call("beta")');
      final betaRequest = await enterScoped('beta');
      checks['scopedCancelAccepted'] = await cancelScopedExecutionGlobal(
        id: alphaId,
      );
      await completeScoped(betaRequest, 'beta');
      final betaResult = await betaCall.timeout(const Duration(seconds: 3));
      final alphaResult = await alphaCall.timeout(const Duration(seconds: 3));
      await settleNativeCancels(1);
      checks['scopedCancelReturnsCancelled'] = alphaResult is JsError_Cancelled;
      checks['scopedCancelInvokesHostCancelOnce'] = nativeCancels.length == 1;
      checks['scopedCancelTargetsOwnRequest'] =
          nativeCancels.contains(alphaRequest) &&
          !nativeCancels.contains(betaRequest);
      checks['nestedKeepsRunningWhileOuterCancelled'] = betaResult == 'beta';

      // A scope submitted while another one owns the JS thread is queued;
      // cancelling it before it starts must skip its script entirely.
      final busyId = await reserveScoped();
      final busy = runScoped(
        busyId,
        'const until=Date.now()+2000; while(Date.now()<until){}; "busy"',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final queuedId = await reserveScoped();
      final queued = runScoped(
        queuedId,
        'globalThis.queuedRan = true; "queued"',
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      checks['queuedScopedCancelAccepted'] = await cancelScopedExecutionGlobal(
        id: queuedId,
      );
      final queuedResult = await queued.timeout(const Duration(seconds: 6));
      checks['queuedScopedCancelReturnsCancelled'] =
          queuedResult is JsError_Cancelled;
      checks['queuedScopedCancelKeepsRunningScope'] = await busy == 'busy';
      checks['queuedScopedCancelSkipsHostCancel'] = nativeCancels.length == 1;
      checks['queuedScopedCancelNeverRan'] =
          (await scopedEngine.eval(
            source: const JsCode.code('globalThis.queuedRan === undefined'),
          )).value ==
          true;

      // A never-submitted reservation is released by discard; the same discard
      // after submission must keep the live execution.
      final discardedId = await reserveScoped();
      discardScopedExecutionGlobal(id: discardedId);
      final discarded = await runScoped(discardedId, '"discarded"');
      checks['discardedReservationRefused'] = discarded is JsError_Bridge;
      final keptId = await reserveScoped();
      final kept = runScoped(keptId, 'fjs.bridge_call("kept")');
      final keptRequest = await enterScoped('kept');
      discardScopedExecutionGlobal(id: keptId);
      await completeScoped(keptRequest, 'kept');
      checks['discardAfterSubmitKeepsExecution'] = await kept == 'kept';

      // close() owns an in-flight host call: it cancels the request through the
      // host callback, unwinds the scope, and refuses new reservations.
      final closingId = await reserveScoped();
      final closing = runScoped(closingId, 'fjs.bridge_call("closing")');
      final closingRequest = await enterScoped('closing');
      final closeError = await scopedEngine
          .close()
          .then<Object?>((_) => null, onError: (Object error) => error);
      final closingResult = await closing.timeout(const Duration(seconds: 3));
      await settleNativeCancels(2);
      checks['closeUnwindsInflightScope'] = closingResult is JsError_Cancelled;
      checks['closeInvokesHostCancelForInflight'] =
          closeError == null && nativeCancels.contains(closingRequest);
      // Re-derived from the deleted fiber gate's `lateCompletionRejected`
      // against a single in-flight scope: after close() unwound it, the host
      // completion that arrives afterwards is refused.
      try {
        await completeScoped(closingRequest, 'late');
        checks['lateCompletionRejected'] = false;
      } on JsError_Bridge {
        checks['lateCompletionRejected'] = true;
      }
      final reservationAfterClose = await scopedEngine
          .createScopedExecution()
          .then<Object?>((id) => id, onError: (Object error) => error);
      checks['scopedReservationAfterCloseRefused'] =
          reservationAfterClose is JsError_Engine;
    } finally {
      if (!scopedEngine.closed) await scopedEngine.close();
    }

    // cancel -> discard -> close delivers exactly one host cancellation.
    final interleavedEngine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
    );
    final interleavedEntered = Completer<BigInt>();
    final interleavedCancels = <BigInt>[];
    try {
      await interleavedEngine.initBroker(
        start: (request) {
          if (!interleavedEntered.isCompleted) {
            interleavedEntered.complete(request.id);
          }
        },
        cancel: (id) async {
          interleavedCancels.add(id);
        },
      );
      final interleavedId = await interleavedEngine.createScopedExecution();
      final interleaved = interleavedEngine
          .evalScoped(
            id: interleavedId,
            source: 'fjs.bridge_call("interleaved")',
          )
          .then<Object?>(
            (value) => value.value,
            onError: (Object error) => error,
          );
      final interleavedRequest = await interleavedEntered.future.timeout(
        const Duration(seconds: 3),
      );
      checks['interleavedCancelAccepted'] = await cancelScopedExecutionGlobal(
        id: interleavedId,
      );
      discardScopedExecutionGlobal(id: interleavedId);
      final interleavedResult = await interleaved.timeout(
        const Duration(seconds: 3),
      );
      final interleavedClose = await interleavedEngine
          .close()
          .then<Object?>((_) => null, onError: (Object error) => error);
      final interleavedDeadline = DateTime.now().add(
        const Duration(seconds: 2),
      );
      while (interleavedCancels.isEmpty &&
          DateTime.now().isBefore(interleavedDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      checks['interleavedCancelReturnsCancelled'] =
          interleavedResult is JsError_Cancelled;
      checks['interleavedCancelDeliveredOnce'] =
          interleavedCancels.length == 1 &&
          interleavedCancels.contains(interleavedRequest);
      checks['interleavedCloseSucceeds'] = interleavedClose == null;
    } finally {
      if (!interleavedEngine.closed) await interleavedEngine.close();
    }

    // Kept and re-derived from the deleted Windows fiber gate. `heapLimitEnforced`
    // and `afterGcUsable` only ever needed one scope, and the "both stacks"
    // pressure row becomes the nested form: a queued execution runs while
    // another scope is parked in a host call, and the parked scope's Rust and JS
    // values survive it. `firstNativeExceptionStack`,
    // `secondNativeExceptionStack` and `closeUnwindsBothStacks` are deleted —
    // two simultaneously suspended stacks are impossible on the one execution
    // path, single-scope exception-stack coverage stays with `runtime_gate`, and
    // `closeUnwindsInflightScope`/`closeInvokesHostCancelForInflight` above cover
    // the one-scope close form.
    final nestedEngine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
      runtimeOptions: JsEngineRuntimeOptions(
        memoryLimit: BigInt.from(16 * 1024 * 1024),
        gcThreshold: BigInt.one,
      ),
    );
    final nestedEntered = <String, Completer<BigInt>>{};
    Future<Object?> runNested(String source) async {
      final id = await nestedEngine.createScopedExecution();
      return nestedEngine
          .evalScoped(id: id, source: source)
          .then<Object?>(
            (value) => value.value,
            onError: (Object error) => error,
          );
    }

    Future<BigInt> enterNested(String key) {
      final completer = Completer<BigInt>();
      nestedEntered[key] = completer;
      return completer.future.timeout(const Duration(seconds: 3));
    }

    Future<void> releaseNested(BigInt id, String answer) =>
        completeBridgeRequestGlobal(
          id: id,
          result: JsResult.ok(JsValue.string(answer)),
        );
    try {
      await nestedEngine.initBroker(
        start: (request) {
          final completer = nestedEntered[request.value.value as String];
          if (completer != null && !completer.isCompleted) {
            completer.complete(request.id);
          }
        },
        cancel: (id) async {},
      );
      final cycle = runNested(
        '(()=>{let x={tag:73};x.self=x;fjs.bridge_call("cycle");return x.self===x&&x.tag===73})()',
      );
      final cycleRequest = await enterNested('cycle');
      // Unreachable self-cycles cannot be reclaimed by reference counting
      // alone. The allocated array slots exceed the entire 16 MiB heap budget,
      // so this only completes if the queued execution really runs nested
      // inside the parked one.
      final pressure = await runNested(
        '(()=>{for(let i=0;i<20000;i++){let x={data:new Array(256).fill(i)};x.self=x;}return 42})()',
      );
      checks['nestedAllocationPressureCompletes'] = pressure == 42;
      await releaseNested(cycleRequest, 'ok');
      checks['nestedScopeValuesSurvive'] = await cycle == true;
      final heapLimit = await runNested(
        'const blocks=[]; while(true) { blocks.push(new Array(10000).fill(123)); }',
      );
      checks['heapLimitEnforced'] = heapLimit is JsError_MemoryLimit;
      await nestedEngine.runGc();
      checks['afterGcUsable'] = await runNested('21*2') == 42;
    } finally {
      if (!nestedEngine.closed) await nestedEngine.close();
    }

    // The Rust deadline clock: the budget goes in with the scope, is compared
    // inside the interrupt closure, and bounds a parked host wait. No Dart timer
    // participates in any of these rows, so the parked row can only pass from
    // Rust.
    final deadlineEngine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
    );
    final deadlineEntered = Completer<BigInt>();
    final deadlineCancels = <BigInt>[];
    Future<Object?> runScopedWithBudget(String source, BigInt? budgetMs) async {
      final id = await deadlineEngine.createScopedExecution(
        deadlineMs: budgetMs,
      );
      return deadlineEngine
          .evalScoped(id: id, source: source)
          .then<Object?>(
            (value) => value.value,
            onError: (Object error) => error,
          );
    }

    try {
      await deadlineEngine.initBroker(
        start: (request) {
          if (!deadlineEntered.isCompleted) deadlineEntered.complete(request.id);
        },
        cancel: (id) async {
          deadlineCancels.add(id);
        },
      );
      checks['deadlineStopsTightLoop'] =
          await runScopedWithBudget('while(true){}', BigInt.from(150))
              is JsError_Timeout;
      checks['deadlineStopsRegexBacktrack'] =
          await runScopedWithBudget(
                r"/(a+)+$/.test('a'.repeat(64) + '!')",
                BigInt.from(150),
              )
              is JsError_Timeout;
      final parked = runScopedWithBudget(
        'fjs.bridge_call("parked")',
        BigInt.from(150),
      );
      final parkedRequest = await deadlineEntered.future.timeout(
        const Duration(seconds: 3),
      );
      final parkedResult = await parked.timeout(const Duration(seconds: 3));
      final deadlineCancelWait = DateTime.now().add(const Duration(seconds: 2));
      while (deadlineCancels.isEmpty &&
          DateTime.now().isBefore(deadlineCancelWait)) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      checks['deadlineTearsDownParkedHostWait'] = parkedResult is JsError_Timeout;
      checks['deadlineTearsDownParkedHostRequest'] =
          deadlineCancels.contains(parkedRequest);
      checks['deadlineEngineUsableAfterwards'] =
          await runScopedWithBudget('6*7', BigInt.from(2000)) == 42;
      checks['executionWithoutBudgetRuns'] =
          await runScopedWithBudget('7*6', null) == 42;
    } finally {
      if (!deadlineEngine.closed) await deadlineEngine.close();
    }

    final pass = checks.values.every((value) => value);
    stdout.writeln(
      jsonEncode({'status': pass ? 'pass' : 'fail', 'checks': checks}),
    );
    if (!pass) exitCode = 1;
  } finally {
    for (final release in releases.values) {
      if (!release.isCompleted) release.complete();
    }
    await InProcessSourceScriptRuntime.dispose();
  }
}
