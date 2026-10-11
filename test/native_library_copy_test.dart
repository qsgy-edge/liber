import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/library_access.dart';
import 'package:liber/local/platform_library_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('liber/local_library');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('native sequential copies share a transfer but never an operation ID', () async {
    final retainedIds = <String>{};
    final sentIds = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      final id = (call.arguments as Map)['operationId'] as String;
      if (call.method == 'progress') {
        expect(retainedIds, contains(id));
        return {'bytesCopied': 0, 'totalBytes': 3};
      }
      expect(call.method, 'copyFile');
      sentIds.add(id);
      if (!retainedIds.add(id)) {
        throw PlatformException(code: 'collision', message: 'Operation ID already used');
      }
      return _receipt('copy-${sentIds.length}');
    });
    final transfer = LibraryTransfer(id: 'shared-batch');
    final access = PlatformLibraryAccess(channel: channel);
    final receipts = <LibraryCopyReceipt>[];
    Object? secondError;
    receipts.add(await access.copyFile(_source, _root, 'one.txt', transfer: transfer));
    try {
      receipts.add(await access.copyFile(_source, _root, 'two.txt', transfer: transfer));
    } catch (error) {
      secondError = error;
    }
    expect(secondError, isNull, reason: 'A retained native ID must not collide on the second file');
    expect(receipts.map((receipt) => receipt.file.key), ['copy-1', 'copy-2']);
    expect(sentIds.toSet(), hasLength(2));
    expect(sentIds, everyElement(isNot(transfer.id)));
    expect(transfer.id, 'shared-batch');
  });

  test('native copy reports intermediate progress before completion and then stops', () async {
    final copy = Completer<Object?>();
    final events = <(int, int?)>[];
    var progressCalls = 0;
    var completed = false;
    var intermediateBeforeCompletion = false;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'copyFile') return copy.future;
      expect(call.method, 'progress');
      progressCalls += 1;
      return {'bytesCopied': 1, 'totalBytes': 3};
    });
    // The fallback makes the baseline fail an assertion, never hang waiting for
    // polling that the broken adapter does not implement.
    final fallback = Timer(const Duration(seconds: 1), () {
      completed = true;
      if (!copy.isCompleted) copy.complete(_receipt('copy-one'));
    });
    try {
      await PlatformLibraryAccess(channel: channel).copyFile(
        _source,
        _root,
        'book.txt',
        transfer: LibraryTransfer(
          id: 'progress-batch',
          onProgress: (bytes, total) {
            events.add((bytes, total));
            if (bytes == 1 && !completed) {
              intermediateBeforeCompletion = true;
              completed = true;
              copy.complete(_receipt('copy-one'));
            }
          },
        ),
      );
      expect(intermediateBeforeCompletion, isTrue);
      expect(events, contains((1, 3)));
      expect(events.last, (3, 3));
      final callsAtCompletion = progressCalls;
      final eventsAtCompletion = events.length;
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(progressCalls, callsAtCompletion);
      expect(events, hasLength(eventsAtCompletion));
    } finally {
      fallback.cancel();
    }
  });
}

Map<String, Object?> _receipt(String key) => {
  'file': {
    'locator': 'content://provider/tree/root/document/$key',
    'key': key,
    'name': '$key.txt',
    'directory': false,
    'size': 3,
  },
  'bytesCopied': 3,
  'sha256': 'a' * 64,
  'verified': true,
};

const _root = LibraryLocation(
  kind: LibraryLocationKind.android,
  locator: 'content://provider/tree/root',
  identity: 'root',
  displayName: 'Library',
);

const _source = LibraryFileReference(
  kind: LibraryLocationKind.android,
  locator: 'content://provider/document/External:AbC',
  key: 'External:AbC',
  name: 'book.txt',
  size: 3,
);
