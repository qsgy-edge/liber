import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../store/ids.dart';
import 'filesystem_library_access.dart';
import 'library_access.dart';

/// Flutter's SDK-granted document boundary plus ordinary desktop selection.
/// Book identity, conflict choices and store publication stay in LocalLibrary.
class PlatformLibraryAccess implements LibraryAccess {
  PlatformLibraryAccess({
    MethodChannel? channel,
    FileSystemLibraryAccess? filesystem,
  }) : _channel = channel ?? const MethodChannel('liber/local_library'),
       _filesystem = filesystem ?? const FileSystemLibraryAccess();

  final MethodChannel _channel;
  final FileSystemLibraryAccess _filesystem;

  bool get _nativePicker =>
      Platform.isAndroid || Platform.isIOS || Platform.isMacOS;

  Future<LibraryLocation?> pickDirectory() async {
    if (_nativePicker) {
      final result = await _invoke('pickDirectory');
      return result == null ? null : LibraryLocation.fromJson(_map(result));
    }
    final selected = await FilePicker.getDirectoryPath();
    if (selected == null) return null;
    return _filesystem.inspectRoot(
      LibraryLocation(
        kind: LibraryLocationKind.filesystem,
        locator: selected,
        identity: selected,
        displayName: selected,
      ),
      writable: true,
    );
  }

  Future<List<LibraryFileReference>?> pickFiles() async {
    if (_nativePicker) {
      final result = await _invoke('pickFiles');
      if (result == null) return null;
      if (result is! List<Object?>) {
        throw const FormatException('Invalid native file selection');
      }
      final kind = Platform.isAndroid
          ? LibraryLocationKind.android
          : LibraryLocationKind.apple;
      return [for (final value in result) _file(value, kind: kind)];
    }
    final selected = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt', 'md'],
    );
    if (selected.isEmpty) return null;
    final files = <LibraryFileReference>[];
    for (final selection in selected) {
      final path = selection.path;
      if (path == null) {
        throw const LibraryAccessFailure(
          LibraryAccessError.unsupported,
          'Selected file has no filesystem path',
        );
      }
      files.add(await _filesystem.source(path));
    }
    return files;
  }

  Future<LibraryFileReference> sourcePath(String path) =>
      _filesystem.source(path);

  @override
  Future<LibraryLocation> inspectRoot(
    LibraryLocation root, {
    bool writable = false,
  }) async {
    if (root.kind == LibraryLocationKind.filesystem) {
      return _filesystem.inspectRoot(root, writable: writable);
    }
    return LibraryLocation.fromJson(
      _map(
        await _invoke('inspectRoot', {
          'root': root.toJson(),
          'writable': writable,
        }),
      ),
    );
  }

  @override
  Future<List<LibraryFileReference>> list(
    LibraryLocation root, {
    LibraryFileReference? directory,
  }) async {
    if (root.kind == LibraryLocationKind.filesystem) {
      return _filesystem.list(root, directory: directory);
    }
    final result = await _invoke('list', {
      'root': root.toJson(),
      if (directory != null) 'directory': directory.toJson(),
    });
    if (result is! List<Object?>) {
      throw const FormatException('Invalid native directory listing');
    }
    return [
      for (final value in result) _file(value, kind: root.kind, root: root),
    ];
  }

  @override
  Future<LibraryFileReference?> stat(LibraryFileReference file) async {
    if (file.kind == LibraryLocationKind.filesystem) {
      return _filesystem.stat(file);
    }
    final result = await _invoke('stat', _arguments(file));
    return result == null
        ? null
        : _file(result, kind: file.kind, root: file.root);
  }

  @override
  Future<LibraryFileReference?> fileInRoot(
    LibraryLocation root,
    LibraryFileReference file,
  ) async {
    if (root.kind == LibraryLocationKind.filesystem) {
      return _filesystem.fileInRoot(root, file);
    }
    final result = await _invoke('fileInRoot', {
      'root': root.toJson(),
      'file': file.toJson(),
    });
    return result == null ? null : _file(result, kind: root.kind, root: root);
  }

  @override
  Future<LibraryFingerprint> fingerprint(LibraryFileReference file) async {
    if (file.kind == LibraryLocationKind.filesystem) {
      return _filesystem.fingerprint(file);
    }
    final result = _map(await _invoke('fingerprint', _arguments(file)));
    return _fingerprint(result, 'bytes');
  }

  @override
  Future<LibraryCopyReceipt> copyFile(
    LibraryFileReference source,
    LibraryLocation destination,
    String name, {
    required LibraryTransfer transfer,
  }) async {
    if (destination.kind == LibraryLocationKind.filesystem) {
      return _filesystem.copyFile(
        source,
        destination,
        name,
        transfer: transfer,
      );
    }
    transfer.checkCancelled();
    final operationId = mintId('copy');
    final stopped = Completer<void>();
    final failures = <String, (Object, StackTrace)>{};
    var copying = false;
    Future<void>? cancellation;
    Future<void>? polling;
    LibraryCopyReceipt? receipt;

    Future<void> requestCancellation() async {
      if (!copying) return;
      await (cancellation ??= _copyControl('cancel', operationId).then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          failures['cancellation'] = (error, stack);
        },
      ));
    }

    Future<void> pollProgress() async {
      try {
        while (copying) {
          final tick = Completer<void>();
          final timer = Timer(const Duration(milliseconds: 100), tick.complete);
          try {
            await Future.any([tick.future, stopped.future]);
          } finally {
            timer.cancel();
          }
          if (!copying) return;
          final progress = _map(await _copyControl('progress', operationId));
          final bytes = progress['bytesCopied'];
          final total = progress['totalBytes'];
          if (bytes is! int ||
              bytes < 0 ||
              (total != null &&
                  (total is! int || total < 0 || bytes > total))) {
            throw const FormatException('Invalid native copy progress');
          }
          // A reply can arrive after the copy's terminal response. Validate it,
          // but never let it report progress into a completed/next copy.
          if (copying) transfer.report(bytes, total as int?);
        }
      } catch (error, stack) {
        failures['progress'] = (error, stack);
        await requestCancellation();
      }
    }

    await transfer.bindCancellation(() async {
      await requestCancellation();
      final failure = failures['cancellation'];
      if (failure != null) {
        Error.throwWithStackTrace(failure.$1, failure.$2);
      }
    });
    try {
      transfer.checkCancelled();
      transfer.report(0, source.size);
      transfer.checkCancelled();
      copying = true;
      final request = _invoke('copyFile', {
        'source': source.toJson(),
        'destinationRoot': destination.toJson(),
        'name': name,
        'operationId': operationId,
      });
      polling = pollProgress();
      final result = _map(await request);
      if (result['verified'] != true) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Native copy has no verified receipt',
        );
      }
      receipt = LibraryCopyReceipt(
        file: _file(result['file'], kind: destination.kind, root: destination),
        fingerprint: _fingerprint(result, 'bytesCopied'),
      );
    } catch (error, stack) {
      failures['copy'] = (error, stack);
    } finally {
      copying = false;
      stopped.complete();
      await transfer.bindCancellation(null);
      await polling;
      await cancellation;
    }
    if (failures.isEmpty) {
      try {
        transfer.report(receipt!.fingerprint.bytes, source.size);
        return receipt;
      } catch (error, stack) {
        failures['progress'] = (error, stack);
      }
    }
    // Once native verification succeeds, this adapter owns the receipt until
    // it reaches the caller. A control/reporting failure cannot orphan it.
    if (receipt != null) {
      try {
        await _cleanupCopy(receipt, source, destination);
      } catch (error, stack) {
        failures['cleanup'] = (error, stack);
      }
    }
    final first = failures.values.first;
    if (failures.length == 1) {
      Error.throwWithStackTrace(first.$1, first.$2);
    }
    throw LibraryAccessFailure(
      failures.containsKey('cleanup')
          ? LibraryAccessError.io
          : first.$1 is LibraryAccessFailure
          ? (first.$1 as LibraryAccessFailure).code
          : LibraryAccessError.io,
      failures.containsKey('cleanup')
          ? 'Native copy failed and its owned file could not be cleaned'
          : 'Native copy failed with multiple operation errors',
      details: {
        for (final entry in failures.entries) entry.key: entry.value.$1,
        if (receipt != null) 'file': receipt.file.toJson(),
      },
    );
  }

  // These SDK methods only inspect/set job state; they never wait for file IO.
  // Reject a stalled control reply without letting its eventual response
  // mutate this operation. The copy itself still owns native IO completion.
  Future<Object?> _copyControl(String method, String operationId) =>
      _invoke(method, {'operationId': operationId}).timeout(
        const Duration(seconds: 5),
        onTimeout: () => throw LibraryAccessFailure(
          LibraryAccessError.io,
          'Native copy $method did not respond',
        ),
      );

  Future<void> _cleanupCopy(
    LibraryCopyReceipt receipt,
    LibraryFileReference source,
    LibraryLocation destination,
  ) async {
    final file = receipt.file;
    if (file.directory ||
        file.locator == source.locator ||
        (file.identity != null && file.identity == source.identity)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Copy cleanup requires a fresh owned file',
      );
    }
    final actual = await fileInRoot(destination, file);
    if (actual == null ||
        actual.directory ||
        actual.locator != file.locator ||
        actual.key != file.key ||
        !(await fingerprint(actual)).sameBytes(receipt.fingerprint)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.verification,
        'Unpublished native copy changed; cleanup refused',
      );
    }
    await deleteFile(actual);
    if (await stat(actual) != null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.io,
        'Unpublished native copy still exists after cleanup',
      );
    }
  }

  @override
  Future<void> deleteFile(LibraryFileReference file) async {
    if (file.kind == LibraryLocationKind.filesystem) {
      return _filesystem.deleteFile(file);
    }
    if (file.root == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'Deletion requires a canonical rooted file',
      );
    }
    await _invoke('deleteFile', _arguments(file));
  }

  @override
  Future<LibraryReadLease> acquireRead(LibraryFileReference file) async {
    if (file.kind == LibraryLocationKind.filesystem) {
      return _filesystem.acquireRead(file);
    }
    final result = _map(await _invoke('acquireRead', _arguments(file)));
    final token = result['token'];
    final path = result['path'];
    final fd = result['fd'];
    if (token is! String ||
        token.isEmpty ||
        !((path is String &&
                path.isNotEmpty &&
                p.isAbsolute(path) &&
                fd == null) ||
            (fd is int && fd >= 0 && path == null))) {
      // Release a granted token even when the representation violates the DTO.
      if (token is String && token.isNotEmpty) {
        await _invoke('releaseRead', {'token': token});
      }
      throw const FormatException('Invalid native read lease');
    }
    return LibraryReadLease(
      path: path as String?,
      fd: fd as int?,
      onRelease: () async {
        await _invoke('releaseRead', {'token': token});
      },
    );
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMethod<Object?>(method, arguments);
    } on PlatformException catch (error) {
      final code = LibraryAccessError.values
          .where((code) => code.name == error.code)
          .firstOrNull;
      throw LibraryAccessFailure(
        code ?? LibraryAccessError.io,
        error.message ?? error.code,
        details: error.details,
      );
    } on MissingPluginException catch (error) {
      throw LibraryAccessFailure(
        LibraryAccessError.unsupported,
        error.message ?? 'Document access is unavailable',
      );
    }
  }

  static Map<String, Object?> _arguments(LibraryFileReference file) => {
    'file': file.toJson(),
    if (file.root != null) 'root': file.root!.toJson(),
  };

  static Map<Object?, Object?> _map(Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const FormatException('Invalid native library result');
    }
    return value;
  }

  static LibraryFileReference _file(
    Object? value, {
    required LibraryLocationKind kind,
    LibraryLocation? root,
  }) {
    final json = _map(value);
    final embedded = json['root'];
    return LibraryFileReference.fromJson(
      json,
      kind: kind,
      root:
          root ??
          (embedded == null ? null : LibraryLocation.fromJson(_map(embedded))),
    );
  }

  static LibraryFingerprint _fingerprint(
    Map<Object?, Object?> result,
    String byteKey,
  ) {
    final bytes = result[byteKey];
    final hash = result['sha256'];
    if (bytes is! int ||
        bytes < 0 ||
        hash is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid native file fingerprint');
    }
    return LibraryFingerprint(bytes, hash);
  }
}
