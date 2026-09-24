import 'package:integration_test/integration_test_driver.dart';

/// The host-side driver for the product's instrumented rows under
/// `integration_test/`, which are otherwise run with `flutter test -d`.
///
/// `flutter test` has no `--android-project-arg`, and this host's Kotlin
/// compiler cannot close its incremental caches — `:android_file_picker:
/// compileDebugKotlin` fails with "Could not close incremental caches" unless
/// `kotlin.incremental=false` is passed — so the row is driven with an APK built
/// with that property and `flutter drive` runs it:
///
/// ```text
/// flutter build apk --debug --target=integration_test/<row>.dart \
///   -Pkotlin.incremental=false
/// flutter drive --driver=test_driver/integration_test.dart \
///   --target=integration_test/<row>.dart \
///   --use-application-binary=build/app/outputs/flutter-apk/app-debug.apk \
///   -d <device> --no-pub
/// ```
///
/// The driver adds nothing: a row prints its own observations and the
/// integration test binding reports its verdict, so the run's real output is the
/// tool's console.
Future<void> main() => integrationDriver();
