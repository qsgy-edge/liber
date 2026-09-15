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
  });
  final String method;
  final Uri url;
  final Map<String, String> headers;
  final String? body;
  final bool followRedirects;
  final SourceCancellation? cancellation;

  /// Extra attempts allowed while the response is not 2xx, matching the
  /// frozen `newCallResponse(retry)` loop.
  final int retry;
  final int maxResponseBytes;
}

class SourceHttpResponse {
  const SourceHttpResponse({
    required this.statusCode,
    required this.headers,
    required this.body,
    required this.url,
  });
  final int statusCode;
  final Map<String, List<String>> headers;
  final String body;
  final Uri url;
}

abstract interface class SourceHttpTransport {
  Future<SourceHttpResponse> send(SourceHttpRequest request);
}

class BookSourceRunState {
  const BookSourceRunState({required this.stage, this.message = ''});
  final BookSourceStage stage;
  final String message;
  bool get isComplete => stage == BookSourceStage.completed;
}

class LocalRoot {
  const LocalRoot({
    required this.id,
    required this.displayName,
    this.needsRelink = false,
  });
  final String id;
  final String displayName;
  final bool needsRelink;

  LocalRoot copyWith({String? displayName, bool? needsRelink}) => LocalRoot(
    id: id,
    displayName: displayName ?? this.displayName,
    needsRelink: needsRelink ?? this.needsRelink,
  );

  Map<String, Object> toJson() => {
    'id': id,
    'displayName': displayName,
    'needsRelink': needsRelink,
  };

  factory LocalRoot.fromJson(Map<String, dynamic> json) => LocalRoot(
    id: json['id'] as String,
    displayName: json['displayName'] as String,
    needsRelink: json['needsRelink'] as bool? ?? false,
  );
}

class LocalBook {
  const LocalBook({
    required this.id,
    required this.rootId,
    required this.path,
    required this.title,
    required this.textOffset,
    this.relativePath,
    this.format = 'txt',
    this.updatedAt,
  });

  final String id;
  final String rootId;
  final String path;
  final String title;
  final int textOffset;
  final String? relativePath;
  final String format;
  final DateTime? updatedAt;

  LocalBook copyWith({int? textOffset, DateTime? updatedAt}) => LocalBook(
    id: id,
    rootId: rootId,
    path: path,
    title: title,
    textOffset: textOffset ?? this.textOffset,
    relativePath: relativePath,
    format: format,
    updatedAt: updatedAt ?? this.updatedAt,
  );

  Map<String, Object?> toJson() => {
    'id': id,
    'rootId': rootId,
    'path': path,
    'title': title,
    'textOffset': textOffset,
    'relativePath': relativePath,
    'format': format,
    'updatedAt': updatedAt?.toIso8601String(),
  };

  factory LocalBook.fromJson(Map<String, dynamic> json) => LocalBook(
    id: json['id'] as String,
    rootId: json['rootId'] as String,
    path: json['path'] as String,
    title: json['title'] as String,
    textOffset: (json['textOffset'] as num?)?.toInt() ?? 0,
    relativePath: json['relativePath'] as String?,
    format: json['format'] as String? ?? 'txt',
    updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? ''),
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
  final List<String> losses;
}
