import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

Future<Object?> observe(Future<dynamic> future) =>
    future.then<Object?>((v) => v, onError: (Object e, StackTrace s) => e);

Future<void> main(List<String> args) async {
  await LibFjs.init(externalLibrary: ExternalLibrary.open(args.single));
  var pass = true;
  try {
    var initSucceeded = 0;
    var initCancelled = 0;
    var initRejected = 0;
    for (var i = 0; i < 64; i++) {
      final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
      var starts = 0;
      final initializing = observe(
        engine.initBroker(
          start: (_) {
            starts++;
          },
          cancel: (_) {},
        ),
      );
      final closing = observe(engine.close());
      final initResult = await initializing;
      if (initResult == null) {
        initSucceeded++;
      } else if (initResult is JsError_Cancelled) {
        initCancelled++;
      } else if (initResult is JsError_Engine) {
        initRejected++;
      }
      final error = await closing;
      final late = await observe(engine.eval(source: const JsCode.code('1')));
      final reinit = await observe(engine.initWithoutBridge());
      final secondClose = await observe(engine.close());
      pass =
          pass &&
          (initResult == null ||
              initResult is JsError_Cancelled ||
              initResult is JsError_Engine) &&
          engine.closed &&
          !engine.running &&
          error == null &&
          late is JsError_Engine &&
          reinit is JsError_Engine &&
          secondClose == null &&
          starts == 0;
    }
    stdout.writeln(
      jsonEncode({
        'case': 'init-close-64',
        'pass': pass,
        'initSucceeded': initSucceeded,
        'initCancelled': initCancelled,
        'initRejected': initRejected,
      }),
    );
    final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
    await engine.initWithoutBridge();
    final forged = await observe(
      engine.eval(
        source: const JsCode.code(
          'throw new TypeError("bridge request closed")',
        ),
      ),
    );
    final spoofPass = forged is JsError && forged.code() == 'TYPE_ERROR';
    stdout.writeln(jsonEncode({'case': 'forged-cancel', 'pass': spoofPass}));
    await engine.close();
    pass = pass && spoofPass;
    final detached = await JsEngine.create(builtins: JsBuiltinOptions.none());
    await detached.initWithoutBridge();
    final result = await observe(
      detached.eval(
        source: const JsCode.code(
          'Promise.reject(new Error("detached-marker")); 1',
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final closeResult = await observe(detached.close());
    final backgroundPass = '$result $closeResult'.contains('detached-marker');
    stdout.writeln(
      jsonEncode({
        'case': 'unrelated-background-error-retained',
        'pass': backgroundPass,
      }),
    );
    pass = pass && backgroundPass;
    final limited = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
      runtimeOptions: JsEngineRuntimeOptions(
        memoryLimit: BigInt.from(8 * 1024 * 1024),
      ),
    );
    await limited.initWithoutBridge();
    final allocation =
        await observe(
          limited.eval(
            source: const JsCode.code(
              'const blocks=[]; while(true) { blocks.push(new Array(10000).fill(123)); }',
            ),
          ),
        ).timeout(
          const Duration(seconds: 2),
          onTimeout: () async {
            await limited.close();
            return 'heap-limit-not-observed';
          },
        );
    final memoryPass = allocation is JsError_MemoryLimit;
    stdout.writeln(
      jsonEncode({
        'case': 'native-heap-limit',
        'pass': memoryPass,
        'resultType': allocation.runtimeType.toString(),
      }),
    );
    if (!limited.closed) await limited.close();
    pass = pass && memoryPass;
  } finally {
    LibFjs.dispose();
  }
  if (!pass) exitCode = 1;
}
