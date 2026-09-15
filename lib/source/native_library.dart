import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

/// The one native library behind both the JavaScript runtime and the HTML rule
/// adapter.
///
/// `LibFjs.init` wires the process-wide bridge, so it has to run exactly once;
/// both consumers therefore share this initializer instead of each opening the
/// library themselves. [libraryPath] is for hosts that load the library from an
/// explicit path (the desktop gates and `flutter test`); the product app leaves
/// it null and lets the platform loader find the bundled library.
class NativeLibrary {
  NativeLibrary._();

  static Future<void>? _init;

  static Future<void> initialize({String? libraryPath}) =>
      _init ??= LibFjs.init(
        externalLibrary: libraryPath == null
            ? null
            : ExternalLibrary.open(libraryPath),
      );

  static Future<void> get ready => initialize();
}
