import 'dart:typed_data';

import 'store_message.dart';

enum BookSourceStage {
  idle,
  search,
  bookInfo,
  tableOfContents,
  content,
  completed,
  failed,
}

class SourceRequestCancelled implements Exception {
  const SourceRequestCancelled();
  @override
  String toString() => 'cancelled: source request cancelled';
}

/// One execution's cancellation signal. Subscriptions are removed on completion.
class SourceCancellation {
  bool _cancelled = false;
  final _listeners = <void Function()>{};
  bool get isCancelled => _cancelled;

  void throwIfCancelled() {
    if (_cancelled) throw const SourceRequestCancelled();
  }

  void Function() listen(void Function() callback) {
    if (_cancelled) {
      callback();
    } else {
      _listeners.add(callback);
    }
    return () => _listeners.remove(callback);
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final callback in listeners) {
      callback();
    }
  }
}

class SourceIoLimitExceeded implements Exception {
  const SourceIoLimitExceeded(this.direction);
  final String direction;
  @override
  String toString() => '$direction-cap: source I/O limit exceeded';
}

/// A source request whose TLS certificate or hostname verification failed
/// (ADR 0011 §5).
///
/// It is a named outcome rather than a generic connection error, so the page
/// can offer the per-source confirmation and the source log says which source
/// and which host were rejected. [reason] states the problem in plain words and
/// [detail] is the transport's own message, kept for the log.
class SourceTlsCertificateFailure implements Exception {
  const SourceTlsCertificateFailure({
    required this.sourceRef,
    required this.host,
    required this.reason,
    this.detail = '',
  });

  /// The source the request belonged to, empty when no identity was attached.
  final String sourceRef;

  /// The host whose certificate or hostname failed verification.
  final String host;

  /// The verification problem in plain words (invalid, expired, untrusted, or
  /// a hostname mismatch), for the confirmation and the log.
  final String reason;

  /// The transport's message for the same failure, for the log.
  final String detail;

  @override
  String toString() =>
      'TLS certificate rejected for $host: $reason'
      '${detail.isEmpty ? '' : ' ($detail)'}';
}

class SourceHttpRequest {
  const SourceHttpRequest({
    required this.method,
    required this.url,
    this.headers = const {},
    this.body,
    this.followRedirects = false,
    this.cancellation,
    this.retry = 0,
    this.maxResponseBytes = 8 * 1024 * 1024,
    this.sourceRef = '',
    this.allowInvalidCertificate = false,
    this.readBytes = false,
  });
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
  final bool followRedirects;
  final SourceCancellation? cancellation;

  /// The source this request belongs to, so a certificate failure can name it.
  final String sourceRef;

  /// Whether this request may continue past a certificate-verification
  /// failure. ADR 0011 §5's exception is per source and host, resolved by the
  /// caller that holds the space's state; the default is to validate.
  final bool allowInvalidCertificate;

  /// Extra attempts allowed while the response is not 2xx, matching the
  /// frozen `newCallResponse(retry)` loop.
  final int retry;
  final int maxResponseBytes;

  /// Whether the transport must also answer the response's raw bytes.
  ///
  /// The frozen `ResponseBody.bytes()` a binary consumer needs: the
  /// verification-code image's own request reads bytes rather than the decoded
  /// text ([SourceHttpResponse.body]), which cannot carry an image back. The
  /// default keeps the decoded-only path, so no other request pays for it.
  final bool readBytes;
}

class SourceHttpResponse {
  const SourceHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.url,
    this.bodyBytes,
  });
  final int statusCode;
  final Map<String, List<String>> headers;
  final String body;

  /// The response's raw bytes, answered only when
  /// [SourceHttpRequest.readBytes] asked for them; null otherwise.
  final Uint8List? bodyBytes;
  final Uri url;
}

abstract interface class SourceHttpTransport {
  Future<SourceHttpResponse> send(SourceHttpRequest request);
}

class BookSourceRunState {
  const BookSourceRunState({required this.stage, this.message});
  final BookSourceStage stage;

  /// The line the page shows for this state, as a message the page renders in
  /// its own language (#72); null when the run has nothing to say yet.
  final StoreMessage? message;

  bool get isComplete => stage == BookSourceStage.completed;
}

/// A local book as the pages read it: the `books` row of kind `local` plus the
/// position, with the path resolved from its root. The roots themselves are the
/// `local_roots` rows ([LocalRoot] in `store/database.dart`).
class LocalBook {
  const LocalBook({
    required this.id,
    required this.rootId,
    required this.path,
    required this.title,
    required this.textOffset,
    this.relativePath,
    this.format = 'txt',
  });

  final String id;
  final String rootId;
  final String path;
  final String title;
  final int textOffset;
  final String? relativePath;
  final String format;

  LocalBook copyWith({int? textOffset}) => LocalBook(
    id: id,
    rootId: rootId,
    path: path,
    title: title,
    textOffset: textOffset ?? this.textOffset,
    relativePath: relativePath,
    format: format,
  );
}

class MigrationImportRecord {
  const MigrationImportRecord({
    required this.sourceCount,
    required this.bookCount,
    required this.progressCount,
    required this.losses,
  });
  final int sourceCount;
  final int bookCount;
  final int progressCount;

  /// What the file carried that the space has no place for, one message per
  /// line; the page renders each in its own language (#72).
  final List<StoreMessage> losses;
}
