import 'dart:async';
import 'dart:io';

import 'package:fjs/fjs.dart' as native;
import 'package:path/path.dart' as p;

import 'library_access.dart';

/// Ordinary path access. Only the native byte operations require an initialized
/// fjs bridge; folder browsing and legacy tools remain pure Dart.
class FileSystemLibraryAccess implements LibraryAccess {
  const FileSystemLibraryAccess();

  Future<LibraryFileReference> source(String path) async {
    if (!p.isAbsolute(path)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'A local file must have an absolute path',
      );
    }
    final file = await _describe(path);
    if (file == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.missing,
        'Local file is missing',
      );
    }
    return file;
  }

  @override
  Future<LibraryLocation> inspectRoot(
    LibraryLocation root, {
    bool writable = false,
  }) => _io(() async {
    if (root.kind != LibraryLocationKind.filesystem ||
        !p.isAbsolute(root.locator)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.unsupported,
        'Expected an absolute filesystem directory',
      );
    }
    final directory = Directory(root.locator);
    final stat = await directory.stat();
    if (stat.type != FileSystemEntityType.directory) {
      throw const LibraryAccessFailure(
        LibraryAccessError.missing,
        'Library directory is missing',
      );
    }
    final canonical = await directory.resolveSymbolicLinks();
    if (writable) {
      final probe = await Directory(canonical).createTemp('.liber-write-');
      try {
        await File(
          p.join(probe.path, 'probe'),
        ).writeAsBytes(const [0], flush: true);
      } finally {
        // This directory was created exclusively by this invocation.
        await probe.delete(recursive: true);
      }
    }
    return LibraryLocation(
      kind: LibraryLocationKind.filesystem,
      locator: canonical,
      identity: Platform.isWindows ? canonical.toLowerCase() : canonical,
      displayName: canonical,
    );
  });

  @override
  Future<List<LibraryFileReference>> list(
    LibraryLocation root, {
    LibraryFileReference? directory,
  }) => _io(() async {
    final actual = await inspectRoot(root);
    var path = actual.locator;
    if (directory != null) {
      final child = await fileInRoot(actual, directory);
      if (child == null || !child.directory) {
        throw const LibraryAccessFailure(
          LibraryAccessError.permission,
          'Directory is outside the selected library',
        );
      }
      path = child.locator;
    }
    final files = <LibraryFileReference>[];
    await for (final entry in Directory(path).list(followLinks: false)) {
      if (entry is Link) continue;
      final file = await _describe(entry.path, root: actual);
      if (file != null) files.add(file);
    }
    files.sort((a, b) {
      if (a.directory != b.directory) return a.directory ? -1 : 1;
      return a.name.compareTo(b.name);
    });
    return files;
  });

  @override
  Future<LibraryFileReference?> stat(LibraryFileReference file) =>
      _io(() async {
        _filesystem(file);
        final root = file.root;
        if (root == null) return _describe(file.locator);
        final actualRoot = await inspectRoot(root);
        final actualFile = await _describe(file.locator);
        if (actualFile == null) return null;
        final result = await fileInRoot(actualRoot, actualFile);
        if (result == null) {
          throw const LibraryAccessFailure(
            LibraryAccessError.permission,
            'File is outside its authorized root',
          );
        }
        if (result.key != file.key) {
          throw const LibraryAccessFailure(
            LibraryAccessError.verification,
            'File key no longer matches its locator',
          );
        }
        return result;
      });

  @override
  Future<LibraryFileReference?> fileInRoot(
    LibraryLocation root,
    LibraryFileReference file,
  ) => _io(() async {
    _filesystem(file);
    final actualRoot = await inspectRoot(root);
    final actual = await _describe(file.locator);
    if (actual == null) return null;
    if (!p.isWithin(actualRoot.locator, actual.locator)) return null;
    return _describe(actual.locator, root: actualRoot);
  });

  @override
  Future<LibraryFingerprint> fingerprint(LibraryFileReference file) => _native(
    () async {
      final actual = await _regular(file);
      final result = await native.libraryFileFingerprint(path: actual.locator);
      return LibraryFingerprint(result.bytesCopied.toInt(), result.sha256);
    },
  );

  @override
  Future<LibraryCopyReceipt> copyFile(
    LibraryFileReference source,
    LibraryLocation destination,
    String name, {
    required LibraryTransfer transfer,
  }) => _native(() async {
    _name(name);
    transfer.checkCancelled();
    final sourceFile = await _regular(source);
    final root = await inspectRoot(destination);
    final job = native.LibraryCopyJob();
    await transfer.bindCancellation(() async => job.cancel());
    final progress = Timer.periodic(const Duration(milliseconds: 100), (_) {
      transfer.report(job.copiedBytes().toInt(), sourceFile.size);
    });
    try {
      final target = p.join(root.locator, name);
      final result = await job.copy(
        sourcePath: sourceFile.locator,
        destinationPath: target,
      );
      // The job owns cancellation/partial cleanup through its final return.
      // A later cancel belongs to the caller's pre-publication cleanup.
      final file = await _describe(target, root: root);
      if (file == null || file.directory) {
        throw const LibraryAccessFailure(
          LibraryAccessError.verification,
          'Verified copy is no longer present',
        );
      }
      transfer.report(result.bytesCopied.toInt(), sourceFile.size);
      return LibraryCopyReceipt(
        file: file,
        fingerprint: LibraryFingerprint(
          result.bytesCopied.toInt(),
          result.sha256,
        ),
      );
    } finally {
      progress.cancel();
      await transfer.bindCancellation(null);
    }
  });

  @override
  Future<void> deleteFile(LibraryFileReference file) => _io(() async {
    if (file.root == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'Deletion requires a canonical rooted file',
      );
    }
    final actual = await _regular(file);
    await File(actual.locator).delete();
  });

  @override
  Future<LibraryReadLease> acquireRead(LibraryFileReference file) async =>
      LibraryReadLease(path: (await _regular(file)).locator);

  Future<LibraryFileReference> _regular(LibraryFileReference file) async {
    final actual = await stat(file);
    if (actual == null) {
      throw const LibraryAccessFailure(
        LibraryAccessError.missing,
        'Local file is missing',
      );
    }
    if (actual.directory) {
      throw const LibraryAccessFailure(
        LibraryAccessError.unsupported,
        'Expected an ordinary book file',
      );
    }
    return actual;
  }

  Future<LibraryFileReference?> _describe(
    String path, {
    LibraryLocation? root,
  }) async {
    if (!p.isAbsolute(path)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'Relative paths cannot resolve outside a library',
      );
    }
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file &&
        type != FileSystemEntityType.directory) {
      throw const LibraryAccessFailure(
        LibraryAccessError.unsupported,
        'Symbolic links and special files are not library documents',
      );
    }
    final canonical = await (type == FileSystemEntityType.directory
        ? Directory(path).resolveSymbolicLinks()
        : File(path).resolveSymbolicLinks());
    if (root != null && !p.isWithin(root.locator, canonical)) {
      throw const LibraryAccessFailure(
        LibraryAccessError.permission,
        'File is outside the selected library',
      );
    }
    final stat = await File(canonical).stat();
    return LibraryFileReference(
      kind: LibraryLocationKind.filesystem,
      locator: canonical,
      key: root == null
          ? p.basename(canonical)
          : p.relative(canonical, from: root.locator),
      name: p.basename(canonical),
      directory: type == FileSystemEntityType.directory,
      size: type == FileSystemEntityType.file ? stat.size : null,
      modifiedAt: stat.modified.millisecondsSinceEpoch,
      identity: Platform.isWindows ? canonical.toLowerCase() : canonical,
      root: root,
    );
  }

  static void _filesystem(LibraryFileReference file) {
    if (file.kind != LibraryLocationKind.filesystem) {
      throw const LibraryAccessFailure(
        LibraryAccessError.unsupported,
        'Expected a filesystem file',
      );
    }
  }

  static void _name(String name) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains('/') ||
        name.contains('\\') ||
        name.contains('\u0000')) {
      throw const LibraryAccessFailure(
        LibraryAccessError.io,
        'Invalid file name',
      );
    }
  }

  static Future<T> _io<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on FileSystemException catch (error) {
      final code = error.osError?.errorCode;
      throw LibraryAccessFailure(
        code == 5 || code == 13
            ? LibraryAccessError.permission
            : LibraryAccessError.io,
        error.message,
        details: error.osError,
      );
    }
  }

  static Future<T> _native<T>(Future<T> Function() operation) async {
    try {
      return await _io(operation);
    } on native.LibraryFileError catch (error) {
      throw switch (error) {
        native.LibraryFileError_Cancelled() => const LibraryAccessFailure(
          LibraryAccessError.cancelled,
          'Library transfer cancelled',
        ),
        native.LibraryFileError_AlreadyExists() => const LibraryAccessFailure(
          LibraryAccessError.collision,
          'A file already uses this name',
        ),
        native.LibraryFileError_VerificationFailed() =>
          const LibraryAccessFailure(
            LibraryAccessError.verification,
            'File verification failed',
          ),
        native.LibraryFileError_Io(:final field0) => LibraryAccessFailure(
          LibraryAccessError.io,
          field0,
        ),
      };
    }
  }
}
