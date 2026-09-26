import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Removes a test's scratch directory, waiting for the handles Windows keeps.
///
/// A space's database file stays locked for a short while after the store that
/// opened it is released, and on this platform the lock outlives a plain
/// `delete(recursive: true)`: the tear-down then throws
/// `PathAccessException: Deletion failed … being used by another process`
/// (OS error 32) for a row whose assertions had already passed.
/// `source_host_state_quota_test` went red from exactly that, which is why every
/// scratch directory in the suite goes through here. (The `interface_language_test`
/// red this comment used to attribute here was not this failure: its delete
/// error was a consequence of the widget wait that failed first — #109, fixed by
/// the space's busy timeout.)
///
/// The retries span ten seconds; a directory that still cannot be removed is
/// reported through `printOnFailure` rather than failing the row — a lingering
/// scratch handle in a temporary directory is hygiene, not the behaviour under
/// test. Call it from a `tearDown` (where `printOnFailure` is available).
Future<void> deleteTempDirectory(Directory directory) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    try {
      await directory.delete(recursive: true);
      return;
    } on FileSystemException {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
  try {
    await directory.delete(recursive: true);
  } on FileSystemException catch (error) {
    printOnFailure('the scratch directory could not be removed: $error');
  }
}
