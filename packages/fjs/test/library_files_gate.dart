// Pure Dart ABI/behavior gate. Supply this worktree's freshly built native library.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> expectError(
  Future<Object?> Function() call,
  bool Function(Object) matches,
) async {
  try {
    await call();
  } catch (error) {
    require(matches(error), 'Unexpected error: $error');
    return;
  }
  throw StateError('Expected a typed failure');
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 1) {
    throw ArgumentError('Supply the matching fjs.dll/libfjs.so path');
  }
  await LibFjs.init(externalLibrary: ExternalLibrary.open(arguments.single));
  final scratch = Directory.systemTemp.createTempSync('liber-native-files-');
  var passed = 0;
  Future<void> row(String name, Future<void> Function() body) async {
    await body();
    passed++;
    stdout.writeln('PASS $name');
  }

  try {
    final source = File('${scratch.path}/source.txt')..writeAsStringSync('abc');
    final target = File('${scratch.path}/managed.txt');
    await row('exclusive verified copy and fingerprint', () async {
      final job = LibraryCopyJob();
      final result = await job.copy(
        sourcePath: source.path,
        destinationPath: target.path,
      );
      require(result.bytesCopied == 3 && job.copiedBytes() == 3, 'Byte counts');
      require(
        result.sha256 ==
            'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        'Known SHA-256',
      );
      final fingerprint = await libraryFileFingerprint(path: target.path);
      require(fingerprint.sha256 == result.sha256, 'Fingerprint differs');
      require(source.readAsStringSync() == 'abc', 'Source modified');
    });
    await row('collision preserves destination and returns typed error',
        () async {
      source.writeAsStringSync('changed');
      await expectError(
        () => LibraryCopyJob().copy(
          sourcePath: source.path,
          destinationPath: target.path,
        ),
        (error) => error is LibraryFileError_AlreadyExists,
      );
      require(
          target.readAsStringSync() == 'abc', 'Existing target overwritten');
    });
    await row('bounded equality distinguishes content', () async {
      require(
        !await libraryFilesEqual(
          firstPath: source.path,
          secondPath: target.path,
        ),
        'Different bytes compared equal',
      );
      source.writeAsStringSync('abc');
      require(
        await libraryFilesEqual(
          firstPath: source.path,
          secondPath: target.path,
        ),
        'Identical bytes differ',
      );
    });
    await row('pre-cancelled copy creates no file', () async {
      final job = LibraryCopyJob()..cancel();
      final cancelled = File('${scratch.path}/cancelled.txt');
      await expectError(
        () => job.copy(
          sourcePath: source.path,
          destinationPath: cancelled.path,
        ),
        (error) => error is LibraryFileError_Cancelled,
      );
      require(!cancelled.existsSync(), 'Cancelled destination exists');
    });
    await row('sync progress and cancellation run during async native copy',
        () async {
      final large = File('${scratch.path}/large.txt');
      final writer = large.openSync(mode: FileMode.write);
      final chunk = Uint8List(64 * 1024);
      for (var i = 0; i < 1024; i++) {
        writer.writeFromSync(chunk);
      }
      writer.closeSync();
      final partial = File('${scratch.path}/partial.txt');
      final job = LibraryCopyJob();
      var complete = false;
      Object? failure;
      final copying = job
          .copy(
        sourcePath: large.path,
        destinationPath: partial.path,
      )
          .then<void>((_) {
        complete = true;
      }, onError: (Object error) {
        failure = error;
        complete = true;
      });
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (!complete &&
          job.copiedBytes() == 0 &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      require(!complete && job.copiedBytes() > 0,
          'Could not observe active copy progress');
      job.cancel();
      await copying;
      require(failure is LibraryFileError_Cancelled,
          'Cancellation result: $failure');
      require(!partial.existsSync(), 'Partial copy survived cancellation');
      require(large.lengthSync() == 64 * 1024 * 1024, 'Source length changed');
    });
    await row('backed-up atomic replacement', () async {
      final staged = File('${scratch.path}/staged.txt')
        ..writeAsStringSync('new');
      final backup = File('${scratch.path}/backup.txt');
      await libraryReplaceFile(
        stagedPath: staged.path,
        destinationPath: target.path,
        backupPath: backup.path,
      );
      require(target.readAsStringSync() == 'new', 'Replacement bytes');
      require(backup.readAsStringSync() == 'abc', 'Backup bytes');
      require(!staged.existsSync(), 'Staging was not renamed');
    });
    await row('path text index and deep bounded window share the matching ABI',
        () async {
      final book = File('${scratch.path}/book.txt');
      final text = List.generate(12000, (i) => 'line $i 正文\n').join();
      book.writeAsStringSync(text);
      final index =
          await textIndexFile(path: book.path, options: textDefaultOptions());
      const offset = 80000;
      final anchor = index.anchors.lastWhere((a) => a.codeUnitOffset <= offset);
      final window = await textReadWindow(
          request: TextWindowRequest(
        path: book.path,
        encoding: index.encoding,
        anchor: anchor,
        codeUnitOffset: offset,
        maxCodeUnits: 113,
        maxScanBytes: 1 << 20,
      ));
      require(window.text == text.substring(offset, offset + 113),
          'Deep text mismatch');
      require(index.codeUnitLength == text.length, 'Index units mismatch');
    });
    if (Platform.isWindows) {
      await row('all fd entrypoints report explicit unsupported on Windows',
          () async {
        bool unsupported(Object error) =>
            error is TextEngineError_Io && error.field0.contains('unsupported');
        await expectError(() => textDetectEncodingFd(fd: -1), unsupported);
        await expectError(
            () => textIndexFd(fd: -1, options: textDefaultOptions()),
            unsupported);
        await expectError(
            () => textReadWindowFd(
                    request: TextDescriptorWindowRequest(
                  fd: -1,
                  encoding: 'UTF-8',
                  codeUnitOffset: 0,
                  maxCodeUnits: 1,
                  maxScanBytes: 32,
                )),
            unsupported);
      });
    }
    require(passed >= 7, 'No meaningful cases executed');
    stdout.writeln('$passed native transport rows passed');
  } finally {
    scratch.deleteSync(recursive: true);
    LibFjs.dispose();
  }
}
