import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/filesystem_library_access.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/source/native_library.dart';

import 'native_library.dart';
import 'temp_directory.dart';

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test(
    'filesystem adapter copies and verifies actual bytes without replacing an existing file',
    () async {
      final scratch = await Directory.systemTemp.createTemp(
        'liber-native-copy-',
      );
      try {
        const access = FileSystemLibraryAccess();
        final destination = await Directory('${scratch.path}/library').create();
        final bytes = Uint8List.fromList(List.generate(700003, (i) => i % 251));
        final original = await File(
          '${scratch.path}/source.txt',
        ).writeAsBytes(bytes);
        final source = await access.source(original.path);
        final root = await access.inspectRoot(
          LibraryLocation(
            kind: LibraryLocationKind.filesystem,
            locator: destination.path,
            identity: destination.path,
            displayName: destination.path,
          ),
          writable: true,
        );
        final progress = <int>[];
        final receipt = await access.copyFile(
          source,
          root,
          'book.txt',
          transfer: LibraryTransfer(
            id: 'native-adapter-copy',
            onProgress: (bytes, total) => progress.add(bytes),
          ),
        );
        expect(receipt.file.root, isNotNull);
        expect(receipt.file.key, 'book.txt');
        expect(receipt.fingerprint.bytes, bytes.length);
        expect(await File(receipt.file.locator).readAsBytes(), bytes);
        expect(await original.readAsBytes(), bytes);
        final actualFingerprint = await access.fingerprint(receipt.file);
        expect(actualFingerprint.bytes, receipt.fingerprint.bytes);
        expect(actualFingerprint.sha256, receipt.fingerprint.sha256);
        expect(progress.last, bytes.length);
        await expectLater(
          access.copyFile(
            source,
            root,
            'book.txt',
            transfer: LibraryTransfer(id: 'native-adapter-collision'),
          ),
          throwsA(
            isA<LibraryAccessFailure>().having(
              (e) => e.code,
              'code',
              LibraryAccessError.collision,
            ),
          ),
        );
        expect(await File(receipt.file.locator).readAsBytes(), bytes);
        expect(await original.readAsBytes(), bytes);
        expect(await destination.list().toList(), hasLength(1));
        await access.deleteFile(receipt.file);
        expect(await destination.list().toList(), isEmpty);
        expect(await original.readAsBytes(), bytes);
      } finally {
        await deleteTempDirectory(scratch);
      }
    },
  );
}
