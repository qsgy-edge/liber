// Diagnostic-only #111 probe. Run inside a real Flutter mobile process: a
// cross-built native library or a desktop `dart` invocation is not this row.
import 'dart:ffi';

import 'package:fjs/fjs.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liber/source/native_library.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('mobile QuickJS OOM report and engine survival', (tester) async {
    await NativeLibrary.ready;
    final engine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
      runtimeOptions: JsEngineRuntimeOptions(
        memoryLimit: BigInt.from(16 * 1024 * 1024),
        gcThreshold: BigInt.one,
      ),
    );
    try {
      await engine.initBroker(start: (_) {}, cancel: (_) async {});
      Future<Object?> run(String source) async {
        final id = await engine.createScopedExecution();
        return engine
            .evalScoped(id: id, source: source)
            .then<Object?>(
              (result) => result.value,
              onError: (Object error) => error,
            );
      }

      const singleRequest =
          '(()=>{const blocks=[]; while(true) { blocks.push(new Array(4000000).fill(123)); }})()';
      for (var i = 0; i < 200; i++) {
        final result = await run(
          singleRequest,
        ).timeout(const Duration(seconds: 15));
        expect(
          result,
          isA<JsError_MemoryLimit>(),
          reason: 'iteration $i: $result',
        );
        expect('$result', contains('InternalError: out of memory'));
        expect(await run('21*2'), 42, reason: 'engine unusable at $i');
      }
      debugPrintSynchronously(
        'FJS_MOBILE_SINGLE_REQUEST passed=200 lost=0 usable=200',
      );

      final accumulating = await run(
        '(()=>{const blocks=[]; while(true) { blocks.push(new Array(100).fill(123)); }})()',
      ).timeout(const Duration(seconds: 15));
      expect(accumulating, isA<JsError_MemoryLimit>());
      expect('$accumulating', contains('InternalError: out of memory'));
      expect(await run('21*2'), 42);
      debugPrintSynchronously('FJS_MOBILE_ACCUMULATING passed=1 usable=1');

      if (sizeOf<IntPtr>() == 4) {
        expect(await run('globalThis.__probe=new ArrayBuffer(8);true'), true);
        for (final size in [4294967295, 4294967281, 4294967280]) {
          final result = await run('globalThis.__probe.transfer($size)');
          expect(result, isA<JsError_MemoryLimit>(), reason: 'size $size');
          expect('$result', contains('InternalError: out of memory'));
          expect(
            await run('globalThis.__probe.byteLength'),
            8,
            reason: 'detached after refused transfer($size)',
          );
        }
        expect(await run('21*2'), 42);
        debugPrintSynchronously(
          'FJS_MOBILE_POINTER_WIDTH bits=32 passed=3 usable=1',
        );
      } else {
        debugPrintSynchronously(
          'FJS_MOBILE_POINTER_WIDTH bits=64 not-applicable',
        );
      }
    } finally {
      if (!engine.closed) await engine.close();
      NativeLibrary.dispose();
    }
  });
}
