import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

Future<Object?> observed(Future<JsValue> future) =>
    future.then<Object?>((v) => v, onError: (Object e, StackTrace s) => e);

Future<void> nestedProbe(String mode) async {
  final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
  final entered = Completer<void>();
  final callbackFinished = Completer<void>();
  Future<Object?>? nested;
  Object? completionError;
  BigInt? requestId;
  var cancels = 0;
  await engine.initBroker(
    start: (request) async {
      requestId = request.id;
      nested = observed(
        mode == 'same-runtime-queued-release'
            ? engine.eval(source: const JsCode.code('shared.increment()'))
            : evalBridgeRequestGlobal(
                id: request.id,
                source: mode == 'same-runtime-cancel'
                    ? 'while(true);'
                    : 'shared.increment()',
              ),
      );
      entered.complete();
      try {
        if (mode == 'same-runtime-queued-release') {
          await completeBridgeRequestGlobal(
            id: request.id,
            result: const JsResult.ok(JsValue.integer(41)),
          );
          await nested!;
          return;
        }
        final result = await nested!;
        try {
          await completeBridgeRequestGlobal(
            id: request.id,
            result: result is JsValue
                ? JsResult.ok(result)
                : JsResult.err(result as JsError),
          );
        } catch (error) {
          completionError = error;
        }
      } finally {
        callbackFinished.complete();
      }
    },
    cancel: (_) {
      cancels++;
    },
  );
  try {
    // A closure and object identity must survive in this exact engine.
    await engine.eval(
      source: const JsCode.code(
        'globalThis.shared = (() => { let n = 40; '
        'return { increment: () => ++n }; })();',
      ),
    );
    final sequential = await engine.eval(
      source: const JsCode.code('shared.increment()'),
    );
    final outer = observed(
      engine.eval(source: const JsCode.code("fjs.bridge_call('nested')")),
    );
    await entered.future.timeout(const Duration(seconds: 3));
    final beforeClose = await outer.timeout(
      const Duration(seconds: 1),
      onTimeout: () => 'pending',
    );
    if (mode == 'same-runtime-queued-release') {
      await callbackFinished.future.timeout(const Duration(seconds: 3));
    }
    final closeError = await engine.close().then<Object?>(
      (_) => null,
      onError: (Object error, StackTrace stack) => error,
    );
    final nestedResult = await nested!.timeout(const Duration(seconds: 3));
    final outerResult = await outer.timeout(const Duration(seconds: 3));
    await callbackFinished.future.timeout(const Duration(seconds: 3));
    final works = mode == 'same-runtime-queued-release'
        ? beforeClose is JsValue &&
              beforeClose.value == 41 &&
              nestedResult is JsValue &&
              nestedResult.value == 42
        : beforeClose is JsValue && beforeClose.value == 42;
    final cleanup =
        closeError == null &&
        engine.closed &&
        (works ||
            (nestedResult is JsError_Cancelled &&
                outerResult is JsError_Cancelled &&
                cancels == 1 &&
                completionError is JsError_Bridge));
    final stale = await observed(
      evalBridgeRequestGlobal(id: requestId!, source: '1'),
    );
    final expected = mode == 'same-runtime-cancel'
        ? !works && cleanup
        : works && cleanup;
    stdout.writeln(
      jsonEncode({
        'case': mode,
        'pass': sequential.value == 41 && expected && stale is JsError_Bridge,
        'staleRequestRefused': stale is JsError_Bridge,
        'sequentialSharedClosure': sequential.value == 41,
        'nestedCompletedBeforeClose': works,
        'outerBeforeClose': beforeClose is JsValue
            ? beforeClose.value
            : '$beforeClose',
        'nestedAfterClose': nestedResult is JsValue
            ? nestedResult.value
            : '$nestedResult',
        'outerAfterClose': outerResult is JsValue
            ? outerResult.value
            : '$outerResult',
        'lateCompletionRejected': completionError is JsError_Bridge,
        'callbackFinished': callbackFinished.isCompleted,
        'cancelCalls': cancels,
        'cleanup': cleanup,
      }),
    );
    if (sequential.value != 41 || !expected || stale is! JsError_Bridge) {
      exitCode = 1;
    }
  } finally {
    if (!engine.closed) await engine.close();
  }
}

Future<void> main(List<String> args) async {
  await LibFjs.init(externalLibrary: ExternalLibrary.open(args[0]));
  final mode = args.length > 1 ? args[1] : 'queued-close';
  if (mode == 'same-runtime-nested' ||
      mode == 'same-runtime-queued-release' ||
      mode == 'same-runtime-cancel') {
    try {
      await nestedProbe(mode);
    } finally {
      LibFjs.dispose();
    }
    return;
  }
  final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
  final entered = Completer<void>();
  final releaseCancel = Completer<void>();
  var starts = 0;
  var cancels = 0;
  await engine.initBroker(
    start: (_) {
      starts++;
      if (!entered.isCompleted) entered.complete();
      if (mode == 'throw-start') throw StateError('test-start-failure');
    },
    cancel: (_) async {
      cancels++;
      if (mode == 'throw-cancel') throw StateError('test-cancel-failure');
      if (mode == 'queued-close') await releaseCancel.future;
    },
  );
  final outer = observed(
    engine.eval(source: const JsCode.code("fjs.bridge_call('outer')")),
  );
  await entered.future.timeout(const Duration(seconds: 3));
  if (mode == 'queued-close') {
    final queued = observed(engine.eval(source: const JsCode.code('41 + 1')));
    // Give the call time to enter the native executor queue while outer owns JS.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    final closing = engine.close().then<Object?>(
      (_) => null,
      onError: (Object e, StackTrace s) => e,
    );
    final beforeRelease = await queued.timeout(
      const Duration(milliseconds: 250),
      onTimeout: () => 'pending',
    );
    releaseCancel.complete();
    final closeError = await closing;
    final outerResult = await outer;
    final queuedResult = await queued;
    final pass =
        queuedResult is JsError &&
        outerResult is JsError &&
        closeError == null &&
        cancels == 1 &&
        starts == 1;
    stdout.writeln(
      jsonEncode({
        'case': mode,
        'pass': pass,
        'queuedDuringCancel': beforeRelease is JsValue
            ? beforeRelease.value
            : '$beforeRelease',
        'queuedResult': '$queuedResult',
        'outerResult': '$outerResult',
        'closeError': '$closeError',
        'starts': starts,
        'cancels': cancels,
      }),
    );
    if (!pass) exitCode = 1;
  } else if (mode == 'throw-start') {
    // The host start callback throws through FRB's non-failable ABI; the JS
    // caller must receive the failure as an error instead of hanging or
    // requiring close() first.
    var result = await outer.timeout(
      const Duration(seconds: 3),
      onTimeout: () => 'pending',
    );
    var settledOnlyAfterClose = false;
    if (result == 'pending') {
      await engine.close();
      result = await outer.timeout(
        const Duration(seconds: 3),
        onTimeout: () => 'pending',
      );
      settledOnlyAfterClose = true;
    }
    final pass = result is JsError;
    stdout.writeln(
      jsonEncode({
        'case': mode,
        'pass': pass,
        'result': '$result',
        'settledOnlyAfterClose': settledOnlyAfterClose,
      }),
    );
    if (!engine.closed) await engine.close();
    await outer.timeout(const Duration(seconds: 3), onTimeout: () => 'pending');
    if (!pass) exitCode = 1;
  } else {
    final closeResult = await engine.close().then<Object?>(
      (_) => null,
      onError: (Object e, StackTrace s) => e,
    );
    final result = await outer.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () => 'pending',
    );
    final pass =
        result is JsError && (closeResult == null || closeResult is JsError);
    stdout.writeln(
      jsonEncode({
        'case': mode,
        'pass': pass,
        'result': '$result',
        'closeError': '$closeResult',
      }),
    );
    if (!pass) exitCode = 1;
  }
  LibFjs.dispose();
}
