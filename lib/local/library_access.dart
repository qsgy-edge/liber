/// The access grant used by a selected root, not the identity of its books.
enum LibraryLocationKind { filesystem, android, apple }

class LibraryLocation {
  const LibraryLocation({
    required this.kind,
    required this.locator,
    required this.identity,
    required this.displayName,
    this.authorization,
  });

  final LibraryLocationKind kind;
  final String locator;
  final String identity;
  final String displayName;
  final String? authorization;

  bool sameLocation(LibraryLocation other) =>
      kind == other.kind && identity == other.identity;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'locator': locator,
    'identity': identity,
    'displayName': displayName,
    if (authorization != null) 'authorization': authorization,
  };

  factory LibraryLocation.fromJson(Map<Object?, Object?> json) {
    final kindName = _string(json, 'kind');
    final kind = LibraryLocationKind.values
        .where((kind) => kind.name == kindName)
        .firstOrNull;
    if (kind == null)
      throw const FormatException('Unknown library access kind');
    return LibraryLocation(
      kind: kind,
      locator: _string(json, 'locator'),
      identity: _string(json, 'identity'),
      displayName: _string(json, 'displayName'),
      authorization: _optionalString(json, 'authorization'),
    );
  }
}

/// A canonical document returned by the filesystem or the native provider.
/// [key] is root-relative on filesystems and opaque on Android.
class LibraryFileReference {
  const LibraryFileReference({
    required this.kind,
    required this.locator,
    required this.key,
    required this.name,
    this.directory = false,
    this.size,
    this.modifiedAt,
    this.identity,
    this.authorization,
    this.root,
  });

  final LibraryLocationKind kind;
  final String locator;
  final String key;
  final String name;
  final bool directory;
  final int? size;
  final int? modifiedAt;
  final String? identity;
  final String? authorization;
  final LibraryLocation? root;

  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'locator': locator,
    'key': key,
    'name': name,
    'directory': directory,
    if (size != null) 'size': size,
    if (modifiedAt != null) 'modifiedAt': modifiedAt,
    if (identity != null) 'identity': identity,
    if (authorization != null) 'authorization': authorization,
    if (root != null) 'root': root!.toJson(),
  };

  factory LibraryFileReference.fromJson(
    Map<Object?, Object?> json, {
    required LibraryLocationKind kind,
    LibraryLocation? root,
  }) {
    final directory = json['directory'];
    if (directory is! bool) {
      throw const FormatException('Invalid library directory flag');
    }
    return LibraryFileReference(
      kind: kind,
      locator: _string(json, 'locator'),
      key: _string(json, 'key'),
      name: _string(json, 'name'),
      directory: directory,
      size: _optionalInt(json, 'size'),
      modifiedAt: _optionalInt(json, 'modifiedAt'),
      identity: _optionalString(json, 'identity'),
      authorization: _optionalString(json, 'authorization'),
      root: root,
    );
  }
}

class LibraryFingerprint {
  const LibraryFingerprint(this.bytes, this.sha256);

  final int bytes;
  final String sha256;

  bool sameBytes(LibraryFingerprint other) =>
      bytes == other.bytes && sha256 == other.sha256;
}

class LibraryCopyReceipt {
  const LibraryCopyReceipt({required this.file, required this.fingerprint});

  final LibraryFileReference file;
  final LibraryFingerprint fingerprint;
}

enum LibraryAccessError {
  permission,
  missing,
  unsupported,
  collision,
  cancelled,
  io,
  verification,
}

class LibraryAccessFailure implements Exception {
  const LibraryAccessFailure(this.code, this.message, {this.details});

  final LibraryAccessError code;
  final String message;
  final Object? details;

  @override
  String toString() => message;
}

/// One operation owns its cancellation and progress. Backend callbacks are
/// awaited by the caller; a sent provider cancellation is never a success claim.
class LibraryTransfer {
  LibraryTransfer({required this.id, this.onProgress});

  final String id;
  final void Function(int bytes, int? totalBytes)? onProgress;
  bool _cancelled = false;
  Future<void> Function()? _cancel;

  bool get cancelled => _cancelled;

  Future<void> bindCancellation(Future<void> Function()? cancel) async {
    _cancel = cancel;
    if (_cancelled && cancel != null) await cancel();
  }

  Future<void> cancel() async {
    _cancelled = true;
    await _cancel?.call();
  }

  void checkCancelled() {
    if (_cancelled) {
      throw const LibraryAccessFailure(
        LibraryAccessError.cancelled,
        'Library transfer cancelled',
      );
    }
  }

  void report(int bytes, int? totalBytes) =>
      onProgress?.call(bytes, totalBytes);
}

/// The original native descriptor or Apple security scope remains live until
/// the asynchronous text operation finishes. No lease is persisted.
class LibraryReadLease {
  LibraryReadLease({this.path, this.fd, Future<void> Function()? release})
    : assert((path == null) != (fd == null)),
      _release = release;

  final String? path;
  final int? fd;
  final Future<void> Function()? _release;
  Future<void>? _closing;

  Future<void> release() =>
      _closing ??= Future<void>.sync(() => _release?.call());
}

/// The two current access boundaries: ordinary filesystem IO and SDK-granted
/// documents. Store publication and book identity belong to LocalLibrary.
abstract interface class LibraryAccess {
  Future<LibraryLocation> inspectRoot(
    LibraryLocation root, {
    bool writable = false,
  });

  Future<List<LibraryFileReference>> list(
    LibraryLocation root, {
    LibraryFileReference? directory,
  });

  Future<LibraryFileReference?> stat(LibraryFileReference file);

  Future<LibraryFileReference?> fileInRoot(
    LibraryLocation root,
    LibraryFileReference file,
  );

  Future<LibraryFingerprint> fingerprint(LibraryFileReference file);

  Future<LibraryCopyReceipt> copyFile(
    LibraryFileReference source,
    LibraryLocation destination,
    String name, {
    required LibraryTransfer transfer,
  });

  Future<void> deleteFile(LibraryFileReference file);

  Future<LibraryReadLease> acquireRead(LibraryFileReference file);
}

String _string(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value is! String || value.isEmpty) {
    throw FormatException('Invalid library $key');
  }
  return value;
}

String? _optionalString(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value == null || value is String) return value as String?;
  throw FormatException('Invalid library $key');
}

int? _optionalInt(Map<Object?, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is int && value >= 0) return value;
  throw FormatException('Invalid library $key');
}
