import 'dart:convert';
import 'dart:io';
import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

Future<void> main(List<String> args) async {
  final marker = File('${Directory.current.path}/gate-controlled-module.js');
  if (await marker.exists()) throw StateError('Marker already exists');
  await marker.writeAsString('export default "liber-controlled-marker";');
  await LibFjs.init(externalLibrary: ExternalLibrary.open(args.single));
  final engine = await JsEngine.create(builtins: JsBuiltinOptions.none());
  try {
    await engine.initWithoutBridge();
    Object? result;
    try {
      result = (await engine.eval(
        source: const JsCode.code(
          'import("./gate-controlled-module.js").then(m => m.default)',
        ),
      )).value;
    } catch (e) {
      result = e;
    }
    final pass = result is JsError;
    stdout.writeln(
      jsonEncode({
        'case': 'ambient-file-import',
        'pass': pass,
        'readControlledMarker': result == 'liber-controlled-marker',
        'errorType': result.runtimeType.toString(),
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    await engine.close();
    LibFjs.dispose();
    await marker.delete();
  }
}
