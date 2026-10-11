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

  test(
    'native sequential copies share a transfer but never an operation ID',
    () async {
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
          throw PlatformException(
            code: 'collision',
            message: 'Operation ID already used',
          );
        }
        return _receipt('copy-${sentIds.length}');
      });
      final transfer = LibraryTransfer(id: 'shared-batch');
      final access = PlatformLibraryAccess(channel: channel);
      final receipts = <LibraryCopyReceipt>[];
      Object? secondError;
      receipts.add(
        await access.copyFile(_source, _root, 'one.txt', transfer: transfer),
      );
      try {
        receipts.add(
          await access.copyFile(_source, _root, 'two.txt', transfer: transfer),
        );
      } catch (error) {
        secondError = error;
      }
      expect(
        secondError,
        isNull,
        reason: 'A retained native ID must not collide on the second file',
      );
      expect(receipts.map((receipt) => receipt.file.key), ['copy-1', 'copy-2']);
      expect(sentIds.toSet(), hasLength(2));
      expect(sentIds, everyElement(isNot(transfer.id)));
      expect(transfer.id, 'shared-batch');
    },
  );

  test(
    'native copy reports intermediate progress before completion and then stops',
    () async {
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
    },
  );

  for (final duringInitialReport in [false, true]) {
    test(
      'native cancellation before dispatch sends no RPC ($duringInitialReport)',
      () async {
        var calls = 0;
        messenger.setMockMethodCallHandler(channel, (_) async {
          calls += 1;
          return null;
        });
        late LibraryTransfer transfer;
        transfer = LibraryTransfer(
          id: 'cancel-before',
          onProgress: duringInitialReport
              ? (_, _) => unawaited(transfer.cancel())
              : null,
        );
        if (!duringInitialReport) await transfer.cancel();
        await expectLater(
          PlatformLibraryAccess(
            channel: channel,
          ).copyFile(_source, _root, 'book.txt', transfer: transfer),
          throwsA(_failure(LibraryAccessError.cancelled)),
        );
        expect(calls, 0);
        await transfer.cancel();
        expect(calls, 0);
      },
    );
  }

  test(
    'native in-flight cancellation targets only the active copy and detaches',
    () async {
      final copy = Completer<Object?>();
      final started = Completer<void>();
      final ids = <String>[];
      final cancelled = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        final id = (call.arguments as Map)['operationId'] as String;
        switch (call.method) {
          case 'copyFile':
            ids.add(id);
            if (ids.length == 1) return _receipt('first');
            started.complete();
            return copy.future;
          case 'cancel':
            cancelled.add(id);
            copy.completeError(
              PlatformException(code: 'cancelled', message: 'Copy cancelled'),
            );
            return null;
          case 'progress':
            return {'bytesCopied': 1, 'totalBytes': 3};
          default:
            fail('Unexpected ${call.method}');
        }
      });
      final transfer = LibraryTransfer(id: 'cancel-batch');
      final access = PlatformLibraryAccess(channel: channel);
      await access.copyFile(_source, _root, 'first.txt', transfer: transfer);
      final outcome = expectLater(
        access.copyFile(_source, _root, 'second.txt', transfer: transfer),
        throwsA(_failure(LibraryAccessError.cancelled)),
      );
      await started.future.timeout(const Duration(seconds: 2));
      await transfer.cancel();
      await outcome;
      expect(ids.toSet(), hasLength(2));
      expect(cancelled, [ids.last]);
      expect(cancelled.single, isNot(transfer.id));
      await transfer.cancel();
      expect(cancelled, hasLength(1));
    },
  );

  test(
    'native progress RPCs are serial and late progress cannot update the next copy',
    () async {
      final copy = Completer<Object?>();
      final progress = Completer<Object?>();
      final progressStarted = Completer<void>();
      final events = <(int, int?)>[];
      var copies = 0;
      var polls = 0;
      var finished = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'copyFile') {
          copies += 1;
          return copies == 1 ? copy.future : _receipt('second');
        }
        expect(call.method, 'progress');
        polls += 1;
        if (!progressStarted.isCompleted) progressStarted.complete();
        return progress.future;
      });
      final transfer = LibraryTransfer(
        id: 'late-batch',
        onProgress: (bytes, total) => events.add((bytes, total)),
      );
      final access = PlatformLibraryAccess(channel: channel);
      final first = access
          .copyFile(_source, _root, 'first.txt', transfer: transfer)
          .then((value) {
            finished = true;
            return value;
          });
      await progressStarted.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(polls, 1);
      copy.complete(_receipt('first'));
      await Future<void>.delayed(Duration.zero);
      expect(
        finished,
        isFalse,
        reason: 'Pending polling must settle before receipt handoff',
      );
      progress.complete({'bytesCopied': 1, 'totalBytes': 3});
      await first;
      await access.copyFile(_source, _root, 'second.txt', transfer: transfer);
      expect(events, [(0, 3), (3, 3), (0, 3), (3, 3)]);
      expect(polls, 1);
    },
  );

  for (final total in [null, 3]) {
    test('native progress preserves an optional total ($total)', () async {
      final copy = Completer<Object?>();
      final events = <(int, int?)>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'copyFile') return copy.future;
        expect(call.method, 'progress');
        return {'bytesCopied': 1, 'totalBytes': ?total};
      });
      await PlatformLibraryAccess(channel: channel)
          .copyFile(
            _source,
            _root,
            'book.txt',
            transfer: LibraryTransfer(
              id: 'optional-total',
              onProgress: (bytes, total) {
                events.add((bytes, total));
                if (bytes == 1 && !copy.isCompleted) {
                  copy.complete(_receipt('copied'));
                }
              },
            ),
          )
          .timeout(const Duration(seconds: 2));
      expect(events, contains((1, total)));
    });
  }

  final badProgress = <String, Object?>{
    'null payload': null,
    'missing count': <String, Object?>{},
    'negative count': {'bytesCopied': -1},
    'fractional count': {'bytesCopied': 1.5},
    'string count': {'bytesCopied': '1'},
    'negative total': {'bytesCopied': 1, 'totalBytes': -1},
    'fractional total': {'bytesCopied': 1, 'totalBytes': 3.5},
    'string total': {'bytesCopied': 1, 'totalBytes': '3'},
    'count exceeds total': {'bytesCopied': 4, 'totalBytes': 3},
  };
  for (final entry in badProgress.entries) {
    test(
      'native malformed progress ${entry.key} is visible after verified cleanup',
      () async {
        final native = _ControlledCopy(progress: () => entry.value);
        messenger.setMockMethodCallHandler(channel, native.handle);
        await expectLater(
          PlatformLibraryAccess(channel: channel).copyFile(
            _source,
            _root,
            'book.txt',
            transfer: LibraryTransfer(id: 'malformed'),
          ),
          throwsFormatException,
        );
        expect(native.cancelIds, [native.operationId]);
        expect(native.cleanupMethods, [
          'fileInRoot',
          'fingerprint',
          'deleteFile',
          'stat',
        ]);
        expect(native.deleted, isTrue);
      },
    );
  }

  for (final code in ['missing', 'permission', 'io', 'unsupported']) {
    test(
      'native progress $code remains distinct after verified cleanup',
      () async {
        final native = _ControlledCopy(
          progress: () => throw PlatformException(
            code: code,
            message: 'Progress failed',
            details: {'marker': code},
          ),
        );
        messenger.setMockMethodCallHandler(channel, native.handle);
        await expectLater(
          PlatformLibraryAccess(channel: channel).copyFile(
            _source,
            _root,
            'book.txt',
            transfer: LibraryTransfer(id: 'progress-error'),
          ),
          throwsA(
            _failure(
              LibraryAccessError.values.byName(code),
            ).having((error) => error.details, 'details', {'marker': code}),
          ),
        );
        expect(native.deleted, isTrue);
        expect(native.cancelIds, [native.operationId]);
      },
    );
  }

  test('native missing progress implementation remains unsupported', () async {
    final native = _ControlledCopy(
      progress: () => throw MissingPluginException('No progress method'),
    );
    messenger.setMockMethodCallHandler(channel, native.handle);
    await expectLater(
      PlatformLibraryAccess(channel: channel).copyFile(
        _source,
        _root,
        'book.txt',
        transfer: LibraryTransfer(id: 'missing-plugin'),
      ),
      throwsA(_failure(LibraryAccessError.unsupported)),
    );
    expect(native.deleted, isTrue);
  });

  test(
    'native progress failure retains copy cleanup failure details',
    () async {
      final native = _ControlledCopy(
        progress: () => throw PlatformException(
          code: 'permission',
          message: 'Progress revoked',
        ),
        copyError: PlatformException(
          code: 'io',
          message: 'Partial cleanup failed',
          details: {'cleanupFailed': true},
        ),
      );
      messenger.setMockMethodCallHandler(channel, native.handle);
      await expectLater(
        PlatformLibraryAccess(channel: channel).copyFile(
          _source,
          _root,
          'book.txt',
          transfer: LibraryTransfer(id: 'native-cleanup'),
        ),
        throwsA(
          _failure(LibraryAccessError.permission).having(
            (error) => (error.details as Map)['copy'],
            'native copy error',
            _failure(LibraryAccessError.io).having(
              (error) => error.details,
              'native cleanup details',
              {'cleanupFailed': true},
            ),
          ),
        ),
      );
      expect(native.cleanupMethods, isEmpty);
    },
  );

  for (final cleanupFailure in [
    'membership',
    'fingerprint',
    'delete',
    'still-present',
    'stat-permission',
  ]) {
    test(
      'native progress race exposes owned cleanup failure $cleanupFailure',
      () async {
        final native = _ControlledCopy(
          progress: () => throw PlatformException(
            code: 'permission',
            message: 'Progress failed',
          ),
          cleanupFailure: cleanupFailure,
        );
        messenger.setMockMethodCallHandler(channel, native.handle);
        await expectLater(
          PlatformLibraryAccess(channel: channel).copyFile(
            _source,
            _root,
            'book.txt',
            transfer: LibraryTransfer(id: 'cleanup-failure'),
          ),
          throwsA(
            _failure(LibraryAccessError.io)
                .having(
                  (error) => (error.details as Map)['progress'],
                  'progress failure',
                  _failure(LibraryAccessError.permission),
                )
                .having(
                  (error) => (error.details as Map)['cleanup'],
                  'cleanup failure',
                  isA<LibraryAccessFailure>(),
                )
                .having(
                  (error) => ((error.details as Map)['file'] as Map)['key'],
                  'owned key',
                  'owned',
                ),
          ),
        );
        if (cleanupFailure == 'membership' || cleanupFailure == 'fingerprint') {
          expect(native.deleted, isFalse);
        }
      },
    );
  }

  test(
    'native late progress failure after verified completion still cleans the owned copy',
    () async {
      final progress = Completer<Object?>();
      final started = Completer<void>();
      final native = _ControlledCopy(
        progress: () {
          started.complete();
          return progress.future;
        },
      );
      messenger.setMockMethodCallHandler(channel, native.handle);
      final outcome = expectLater(
        PlatformLibraryAccess(channel: channel).copyFile(
          _source,
          _root,
          'book.txt',
          transfer: LibraryTransfer(id: 'late-failure'),
        ),
        throwsA(_failure(LibraryAccessError.permission)),
      );
      await started.future.timeout(const Duration(seconds: 2));
      native.copy.complete(_receipt('owned'));
      await Future<void>.delayed(Duration.zero);
      progress.completeError(
        PlatformException(code: 'permission', message: 'Late progress failure'),
      );
      await outcome;
      expect(native.cancelIds, isEmpty);
      expect(native.deleted, isTrue);
    },
  );

  test(
    'native completed copy awaits active cancellation and returns its receipt to the owner',
    () async {
      final started = Completer<void>();
      final cancelReply = Completer<void>();
      final native = _ControlledCopy(
        progress: () => {'bytesCopied': 1},
        cancelReply: cancelReply.future,
        onCancel: started.complete,
      );
      messenger.setMockMethodCallHandler(channel, native.handle);
      final transfer = LibraryTransfer(id: 'cancel-race');
      var finished = false;
      final result = PlatformLibraryAccess(channel: channel)
          .copyFile(_source, _root, 'book.txt', transfer: transfer)
          .then((value) {
            finished = true;
            return value;
          });
      await native.started.future.timeout(const Duration(seconds: 2));
      final cancelling = transfer.cancel();
      await started.future.timeout(const Duration(seconds: 2));
      await Future<void>.delayed(Duration.zero);
      expect(finished, isFalse);
      cancelReply.complete();
      await cancelling;
      expect((await result).file.key, 'owned');
      expect(native.deleted, isFalse);
      expect(transfer.cancelled, isTrue);
      await transfer.cancel();
      expect(native.cancelIds, [native.operationId]);
    },
  );

  test(
    'native cancellation failure is observed by both cancel and copy and cleans a verified receipt',
    () async {
      final native = _ControlledCopy(
        progress: () => {'bytesCopied': 1},
        cancelError: PlatformException(
          code: 'permission',
          message: 'Cancel revoked',
        ),
      );
      messenger.setMockMethodCallHandler(channel, native.handle);
      final transfer = LibraryTransfer(id: 'cancel-error');
      final result = expectLater(
        PlatformLibraryAccess(
          channel: channel,
        ).copyFile(_source, _root, 'book.txt', transfer: transfer),
        throwsA(_failure(LibraryAccessError.permission)),
      );
      await native.started.future.timeout(const Duration(seconds: 2));
      await expectLater(
        transfer.cancel(),
        throwsA(_failure(LibraryAccessError.permission)),
      );
      await result;
      expect(native.deleted, isTrue);
    },
  );

  for (final stalledMethod in ['progress', 'cancel']) {
    testWidgets(
      'native stalled $stalledMethod reply is bounded and its late error is consumed',
      (tester) async {
        final lateReply = Completer<Object?>();
        final cancelReply = Completer<void>();
        final native = _ControlledCopy(
          progress: () => stalledMethod == 'progress'
              ? lateReply.future
              : {'bytesCopied': 1},
          cancelReply: stalledMethod == 'cancel' ? cancelReply.future : null,
        );
        messenger.setMockMethodCallHandler(channel, native.handle);
        final transfer = LibraryTransfer(id: 'stalled-$stalledMethod');
        final result = expectLater(
          PlatformLibraryAccess(
            channel: channel,
          ).copyFile(_source, _root, 'book.txt', transfer: transfer),
          throwsA(
            _failure(LibraryAccessError.io).having(
              (error) => error.message,
              'timeout',
              contains('$stalledMethod did not respond'),
            ),
          ),
        );
        await tester.pump();
        Future<void>? cancelling;
        if (stalledMethod == 'progress') {
          await tester.pump(const Duration(milliseconds: 100));
          native.copy.complete(_receipt('owned'));
        } else {
          cancelling = expectLater(
            transfer.cancel(),
            throwsA(_failure(LibraryAccessError.io)),
          );
        }
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await result;
        await cancelling;
        expect(native.deleted, isTrue);
        if (stalledMethod == 'progress') {
          lateReply.completeError(
            PlatformException(code: 'permission', message: 'Late error'),
          );
        } else {
          cancelReply.completeError(
            PlatformException(code: 'permission', message: 'Late error'),
          );
        }
        await tester.pump();
        final calls = native.cleanupMethods.length;
        await transfer.cancel();
        await tester.pump(const Duration(milliseconds: 200));
        expect(native.cleanupMethods, hasLength(calls));
      },
    );
  }

  test(
    'native copy failure drains a pending progress reply and detaches cancellation',
    () async {
      final progress = Completer<Object?>();
      final progressStarted = Completer<void>();
      final native = _ControlledCopy(
        progress: () {
          progressStarted.complete();
          return progress.future;
        },
      );
      messenger.setMockMethodCallHandler(channel, native.handle);
      final transfer = LibraryTransfer(id: 'failed-copy');
      final outcome = expectLater(
        PlatformLibraryAccess(
          channel: channel,
        ).copyFile(_source, _root, 'book.txt', transfer: transfer),
        throwsA(
          _failure(LibraryAccessError.io).having(
            (error) => error.details,
            'copy details',
            {'cleanupFailed': true},
          ),
        ),
      );
      await progressStarted.future.timeout(const Duration(seconds: 2));
      native.copy.completeError(
        PlatformException(
          code: 'io',
          message: 'Copy failed',
          details: {'cleanupFailed': true},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      progress.complete({'bytesCopied': 1, 'totalBytes': 3});
      await outcome;
      await transfer.cancel();
      expect(native.cancelIds, isEmpty);
      expect(native.cleanupMethods, isEmpty);
    },
  );

  test(
    'native progress failure never authorizes cleanup of the source receipt',
    () async {
      final copy = Completer<Object?>();
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        switch (call.method) {
          case 'copyFile':
            return copy.future;
          case 'progress':
            throw PlatformException(code: 'io', message: 'Progress failed');
          case 'cancel':
            copy.complete({..._receipt('owned'), 'file': _source.toJson()});
            return null;
          default:
            fail('Source cleanup must be rejected before ${call.method}');
        }
      });
      await expectLater(
        PlatformLibraryAccess(channel: channel).copyFile(
          _source,
          _root,
          'book.txt',
          transfer: LibraryTransfer(id: 'source-guard'),
        ),
        throwsA(
          _failure(LibraryAccessError.io).having(
            (error) => (error.details as Map)['cleanup'],
            'cleanup guard',
            _failure(LibraryAccessError.verification),
          ),
        ),
      );
      expect(methods, ['copyFile', 'progress', 'cancel']);
    },
  );

  test(
    'native terminal reporting failure cleans its verified receipt',
    () async {
      final native = _ControlledCopy(progress: () => {'bytesCopied': 1});
      messenger.setMockMethodCallHandler(channel, native.handle);
      final failure = StateError('Observer failed');
      final result = expectLater(
        PlatformLibraryAccess(channel: channel).copyFile(
          _source,
          _root,
          'book.txt',
          transfer: LibraryTransfer(
            id: 'observer',
            onProgress: (bytes, _) {
              if (bytes == 3) throw failure;
            },
          ),
        ),
        throwsA(same(failure)),
      );
      await native.started.future.timeout(const Duration(seconds: 2));
      native.copy.complete(_receipt('owned'));
      await result;
      expect(native.deleted, isTrue);
    },
  );
}

TypeMatcher<LibraryAccessFailure> _failure(LibraryAccessError code) =>
    isA<LibraryAccessFailure>().having((error) => error.code, 'code', code);

// A verified native copy may finish just before cancel reaches the SDK. These
// responses model that ownership race; only adapter-owned cleanup is recorded.
class _ControlledCopy {
  _ControlledCopy({
    required this.progress,
    this.copyError,
    this.cleanupFailure,
    this.cancelReply,
    this.onCancel,
    this.cancelError,
  });

  final FutureOr<Object?> Function() progress;
  final PlatformException? copyError;
  final String? cleanupFailure;
  final Future<void>? cancelReply;
  final void Function()? onCancel;
  final PlatformException? cancelError;
  final copy = Completer<Object?>();
  final started = Completer<void>();
  final cancelIds = <String>[];
  final cleanupMethods = <String>[];
  String? operationId;
  bool deleted = false;

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map;
    switch (call.method) {
      case 'copyFile':
        operationId = args['operationId'] as String;
        expectSync(args['source'], _source.toJson());
        expectSync(args['destinationRoot'], _root.toJson());
        started.complete();
        return copy.future;
      case 'progress':
        expectSync(args['operationId'], operationId);
        return progress();
      case 'cancel':
        cancelIds.add(args['operationId'] as String);
        expectSync(args['operationId'], operationId);
        if (!copy.isCompleted) {
          if (copyError != null) {
            copy.completeError(copyError!);
          } else {
            copy.complete(_receipt('owned'));
          }
        }
        onCancel?.call();
        await cancelReply;
        if (cancelError != null) throw cancelError!;
        return null;
      default:
        cleanupMethods.add(call.method);
        expectSync(args['root'], _root.toJson());
        final file = args['file'] as Map;
        expectSync(
          file['locator'],
          'content://provider/tree/root/document/owned',
        );
        expectSync(file['key'], 'owned');
        switch (call.method) {
          case 'fileInRoot':
            return cleanupFailure == 'membership'
                ? null
                : _receipt('owned')['file'];
          case 'fingerprint':
            return {
              'bytes': 3,
              'sha256': (cleanupFailure == 'fingerprint' ? 'b' : 'a') * 64,
            };
          case 'deleteFile':
            if (cleanupFailure == 'delete') {
              throw PlatformException(
                code: 'permission',
                message: 'Delete revoked',
              );
            }
            deleted = true;
            return null;
          case 'stat':
            if (cleanupFailure == 'stat-permission') {
              throw PlatformException(
                code: 'permission',
                message: 'Stat revoked',
              );
            }
            return cleanupFailure == 'still-present'
                ? _receipt('owned')['file']
                : null;
          default:
            fail('Unexpected ${call.method}');
        }
    }
  }
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
