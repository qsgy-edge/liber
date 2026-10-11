import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/filesystem_library_access.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/platform_library_access.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('liber/local_library');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test(
    'filesystem receipts prove actual containment and preserve outside files',
    () async {
      final scratch = await Directory.systemTemp.createTemp('liber-access-');
      try {
        final rootDirectory = await Directory(
          p.join(scratch.path, 'managed'),
        ).create();
        final member = await File(
          p.join(rootDirectory.path, 'same.txt'),
        ).writeAsString('managed');
        final outside = await File(
          p.join(scratch.path, 'same.txt'),
        ).writeAsString('original');
        const access = FileSystemLibraryAccess();
        final root = await access.inspectRoot(
          _filesystemRoot(rootDirectory.path),
        );
        final outsideReceipt = await access.source(outside.path);
        expect(await access.fileInRoot(root, outsideReceipt), isNull);
        expect(await outside.readAsString(), 'original');
        final memberReceipt = await access.fileInRoot(
          root,
          await access.source(member.path),
        );
        expect(memberReceipt!.key, 'same.txt');
        expect(memberReceipt.root!.locator, root.locator);
        final lease = await access.acquireRead(memberReceipt);
        try {
          // macOS temp roots and Windows short names can be aliases. The
          // authorized reader path is the actual file's canonical path.
          expect(lease.path, await member.resolveSymbolicLinks());
        } finally {
          await lease.release();
        }
      } finally {
        await scratch.delete(recursive: true);
      }
    },
  );

  test(
    'missing rooted file is absent while unrelated same-name file is rejected',
    () async {
      final scratch = await Directory.systemTemp.createTemp('liber-access-');
      try {
        final managed = await Directory(
          p.join(scratch.path, 'managed'),
        ).create();
        final outside = await File(
          p.join(scratch.path, 'book.txt'),
        ).writeAsString('keep');
        const access = FileSystemLibraryAccess();
        final root = await access.inspectRoot(_filesystemRoot(managed.path));
        expect(
          await access.stat(
            LibraryFileReference(
              kind: LibraryLocationKind.filesystem,
              locator: p.join(managed.path, 'gone.txt'),
              key: 'gone.txt',
              name: 'gone.txt',
              root: root,
            ),
          ),
          isNull,
        );
        final wrong = LibraryFileReference(
          kind: LibraryLocationKind.filesystem,
          locator: outside.path,
          key: 'book.txt',
          name: 'book.txt',
          root: root,
        );
        await expectLater(
          access.stat(wrong),
          throwsA(_failure(LibraryAccessError.permission)),
        );
        await expectLater(
          access.deleteFile(wrong),
          throwsA(_failure(LibraryAccessError.permission)),
        );
        expect(await outside.readAsString(), 'keep');
      } finally {
        await scratch.delete(recursive: true);
      }
    },
  );

  test('relative unresolved sources never resolve against CWD', () async {
    const access = FileSystemLibraryAccess();
    await expectLater(
      access.source('book.txt'),
      throwsA(_failure(LibraryAccessError.permission)),
    );
    await expectLater(
      access.stat(
        const LibraryFileReference(
          kind: LibraryLocationKind.filesystem,
          locator: 'book.txt',
          key: 'book.txt',
          name: 'book.txt',
        ),
      ),
      throwsA(_failure(LibraryAccessError.permission)),
    );
  });

  test('writable filesystem root leaves no probe behind', () async {
    final scratch = await Directory.systemTemp.createTemp('liber-access-');
    try {
      const access = FileSystemLibraryAccess();
      await access.inspectRoot(_filesystemRoot(scratch.path), writable: true);
      expect(await scratch.list().toList(), isEmpty);
    } finally {
      await scratch.delete(recursive: true);
    }
  });

  test(
    'provider-renamed copy preserves actual locator and opaque key',
    () async {
      final root = _androidRoot;
      final source = _androidSource;
      Map<Object?, Object?>? sent;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'copyFile');
        sent = call.arguments as Map<Object?, Object?>;
        return {
          'file': {
            'locator': 'content://provider/tree/root/document/ID:AbC',
            'key': 'ID:AbC',
            'name': 'book (provider).txt',
            'directory': false,
            'size': 3,
          },
          'bytesCopied': 3,
          'sha256': 'a' * 64,
          'verified': true,
        };
      });
      final access = PlatformLibraryAccess(channel: channel);
      final receipt = await access.copyFile(
        source,
        root,
        'book.txt',
        transfer: LibraryTransfer(id: 'copy-one'),
      );
      expect(receipt.file.key, 'ID:AbC');
      expect(receipt.file.name, 'book (provider).txt');
      expect(receipt.file.locator, endsWith('ID:AbC'));
      expect(receipt.file.root!.locator, root.locator);
      expect(receipt.fingerprint.bytes, 3);
      expect((sent!['source'] as Map)['locator'], source.locator);
      expect(sent!['name'], 'book.txt');
    },
  );

  test('unverified native copy cannot return a success receipt', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => {
        'file': {
          'locator': 'content://provider/copied',
          'key': 'id',
          'name': 'book.txt',
          'directory': false,
        },
        'bytesCopied': 3,
        'sha256': 'a' * 64,
        'verified': false,
      },
    );
    final access = PlatformLibraryAccess(channel: channel);
    await expectLater(
      access.copyFile(
        _androidSource,
        _androidRoot,
        'book.txt',
        transfer: LibraryTransfer(id: 'copy-two'),
      ),
      throwsA(_failure(LibraryAccessError.verification)),
    );
  });

  test(
    'revoked provider permission remains an error rather than missing',
    () async {
      messenger.setMockMethodCallHandler(channel, (_) async {
        throw PlatformException(code: 'permission', message: 'Grant revoked');
      });
      final access = PlatformLibraryAccess(channel: channel);
      await expectLater(
        access.stat(_androidSource),
        throwsA(_failure(LibraryAccessError.permission)),
      );
    },
  );

  test(
    'native read token is released exactly once even with concurrent closes',
    () async {
      var releases = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acquireRead') {
          return {'token': 'lease-one', 'fd': 42};
        }
        expect(call.method, 'releaseRead');
        expect((call.arguments as Map)['token'], 'lease-one');
        releases += 1;
        return null;
      });
      final lease = await PlatformLibraryAccess(
        channel: channel,
      ).acquireRead(_androidSource);
      expect(lease.fd, 42);
      await Future.wait([lease.release(), lease.release()]);
      expect(releases, 1);
    },
  );

  test(
    'malformed native read representation still releases the granted token',
    () async {
      var releases = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'acquireRead') {
          return {
            'token': 'bad-lease',
            'fd': 42,
            'path': p.join(Directory.systemTemp.path, 'book.txt'),
          };
        }
        expect(call.method, 'releaseRead');
        releases += 1;
        return null;
      });
      await expectLater(
        PlatformLibraryAccess(channel: channel).acquireRead(_androidSource),
        throwsFormatException,
      );
      expect(releases, 1);
    },
  );

  test(
    'native deletion requires a rooted receipt before sending an operation',
    () async {
      var calls = 0;
      messenger.setMockMethodCallHandler(channel, (_) async {
        calls += 1;
        return null;
      });
      await expectLater(
        PlatformLibraryAccess(channel: channel).deleteFile(_androidSource),
        throwsA(_failure(LibraryAccessError.permission)),
      );
      expect(calls, 0);
    },
  );
}

Matcher _failure(LibraryAccessError code) =>
    isA<LibraryAccessFailure>().having((error) => error.code, 'code', code);

LibraryLocation _filesystemRoot(String path) => LibraryLocation(
  kind: LibraryLocationKind.filesystem,
  locator: path,
  identity: path,
  displayName: path,
);

const _androidRoot = LibraryLocation(
  kind: LibraryLocationKind.android,
  locator: 'content://provider/tree/root',
  identity: 'root',
  displayName: 'Library',
);

const _androidSource = LibraryFileReference(
  kind: LibraryLocationKind.android,
  locator: 'content://provider/document/External:AbC',
  key: 'External:AbC',
  name: 'book.txt',
  directory: false,
  size: 3,
);
