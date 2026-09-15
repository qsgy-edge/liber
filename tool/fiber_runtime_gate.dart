import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

// Exercise the production DLL through its actual FRB entry points.
Future<void> main(List<String> args) async {
  await LibFjs.init(externalLibrary: ExternalLibrary.open(args.single));
  final engine = await JsEngine.create(
    builtins: JsBuiltinOptions.none(),
    runtimeOptions: JsEngineRuntimeOptions(
      memoryLimit: BigInt.from(16 * 1024 * 1024),
      gcThreshold: BigInt.one,
    ),
  );
  final entered = <String, Completer<BigInt>>{};
  final checks = <String, bool>{};
  await engine.initBroker(
    start: (request) {
      entered[request.value.value as String]!.complete(request.id);
    },
    cancel: (id) async {},
  );
  Future<Object?> run(String source) async {
    final id = await engine.createScopedExecution();
    return engine
        .evalScoped(id: id, source: source)
        .then<Object?>(
          (value) => value.value,
          onError: (Object error) => error,
        );
  }

  Future<void> wait(String key) async {
    await entered[key]!.future.timeout(const Duration(seconds: 3));
  }

  Future<void> release(String key, {bool error = false}) async {
    final id = await entered[key]!.future;
    await completeBridgeRequestGlobal(
      id: id,
      result: error
          ? const JsResult.err(JsError.bridge('native-marker'))
          : const JsResult.ok(JsValue.string('ok')),
    );
  }

  void prepare(String key) {
    entered[key] = Completer<BigInt>();
  }

  try {
    prepare('A');
    prepare('B');
    final a = run(
      '(function alpha(){try{fjs.bridge_call("A")}catch(e){return e.stack}})()',
    );
    await wait('A');
    final b = run(
      '(function beta(){try{fjs.bridge_call("B")}catch(e){return e.stack}})()',
    );
    await wait('B');
    await release('A', error: true);
    final traceA = await a.timeout(const Duration(seconds: 2));
    checks['firstNativeExceptionStack'] =
        traceA is String &&
        traceA.contains('alpha') &&
        !traceA.contains('beta');
    await release('B', error: true);
    final traceB = await b;
    checks['secondNativeExceptionStack'] =
        traceB is String &&
        traceB.contains('beta') &&
        !traceB.contains('alpha');

    prepare('cycle');
    final cycle = run(
      '(()=>{let x={tag:73};x.self=x;fjs.bridge_call("cycle");return x.self===x&&x.tag===73})()',
    );
    await wait('cycle');
    // Unreachable self-cycles cannot be reclaimed by reference counting alone.
    // The allocated array slots exceed the entire 16 MiB heap budget.
    final pressure = await run(
      '(()=>{for(let i=0;i<20000;i++){let x={data:new Array(256).fill(i)};x.self=x;}return 42})()',
    );
    checks['cyclicAllocationPressureCompletes'] = pressure == 42;
    await release('cycle');
    checks['suspendedRustAndJsValuesSurvive'] = await cycle == true;
    final heapLimit = await run(
      'const blocks=[]; while(true) { blocks.push(new Array(10000).fill(123)); }',
    );
    checks['heapLimitEnforced'] = heapLimit is JsError_MemoryLimit;
    await engine.runGc();
    checks['afterGcUsable'] = await run('21*2') == 42;

    prepare('close-A');
    prepare('close-B');
    final closeA = run('fjs.bridge_call("close-A")');
    await wait('close-A');
    final closeB = run('fjs.bridge_call("close-B")');
    await wait('close-B');
    await engine.close().timeout(const Duration(seconds: 5));
    checks['closeUnwindsBothStacks'] =
        await closeA is JsError_Cancelled && await closeB is JsError_Cancelled;
    try {
      await release('close-A');
      checks['lateCompletionRejected'] = false;
    } on JsError_Bridge {
      checks['lateCompletionRejected'] = true;
    }
    final pass = checks.values.every((v) => v);
    stdout.writeln(
      jsonEncode({
        'status': pass ? 'pass' : 'fail',
        'checks': checks,
        'traceA': traceA,
        'traceB': traceB,
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    await engine.closeGracefully();
    LibFjs.dispose();
  }
}
