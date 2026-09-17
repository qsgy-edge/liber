// A debug-only entrypoint for driving the real application through the Flutter
// Driver protocol (`flutter run --target tool/driver_main.dart`), which is how
// the UI is exercised without sending input to the operator's mouse and
// keyboard. `lib/main.dart` stays the target of a real build.
//
// `--dart-define=LIBER_WORKSPACE_ROOT=<path>` opens that installation directory
// instead of `%APPDATA%\Liber`, so a driven run cannot read or write the
// operator's own library.
//
// Stop a driven run by process, not by the launcher's exit: the debug
// `liber.exe` outlives the `flutter run` wrapper, and a `dart run` server (the
// corpus replay on 127.0.0.1:18731) keeps its port through a child process.
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:liber/main.dart';

void main() {
  enableFlutterDriverExtension();
  const workspace = String.fromEnvironment('LIBER_WORKSPACE_ROOT');
  runApp(
    LiberApp(workspaceRoot: workspace.isEmpty ? null : Directory(workspace)),
  );
}
