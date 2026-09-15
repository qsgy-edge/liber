import 'dart:io';

/// The native library that holds both the JavaScript runtime and the HTML rule
/// adapter.
///
/// The desktop gates take the library path as an argument; the Dart tests
/// resolve the build output instead, so `flutter test` exercises the same
/// library the app loads. CI builds it before running the tests; a local
/// checkout needs
/// `cargo build --locked --manifest-path packages/fjs/libfjs/Cargo.toml` once.
String nativeLibraryPath() {
  final fromEnvironment = Platform.environment['LIBER_FJS_LIBRARY'];
  if (fromEnvironment != null && fromEnvironment.isNotEmpty) {
    return fromEnvironment;
  }
  final stem = Platform.isWindows
      ? 'fjs.dll'
      : Platform.isMacOS
      ? 'libfjs.dylib'
      : 'libfjs.so';
  final bundle = Platform.isWindows
      ? 'build/windows/x64/runner/Debug'
      : Platform.isLinux
      ? 'build/linux/x64/debug/bundle/lib'
      : 'build/macos/Build/Products/Debug';
  final targets = Platform.isWindows
      ? ['x86_64-pc-windows-msvc', 'aarch64-pc-windows-msvc']
      : Platform.isMacOS
      ? ['aarch64-apple-darwin', 'x86_64-apple-darwin']
      : ['x86_64-unknown-linux-gnu', 'aarch64-unknown-linux-gnu'];
  final candidates = [
    '$bundle/$stem',
    for (final target in targets) 'packages/fjs/libfjs/target/$target/debug/$stem',
    'packages/fjs/libfjs/target/debug/$stem',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError(
    '未找到原生库。先构建：\n'
    '  cargo build --locked --manifest-path packages/fjs/libfjs/Cargo.toml\n'
    '查找过：${candidates.join(', ')}',
  );
}
