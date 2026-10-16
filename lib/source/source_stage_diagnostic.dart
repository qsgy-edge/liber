import 'dart:async';
import 'dart:io';

import '../domain/contracts.dart';

/// Actual HTTP facts, kept outside the source-visible StrResponse payload.
typedef SourceStageHttpDetails = ({
  int statusCode,
  int? bodyByteLength,
  Uri url,
});

/// A stage whose response body is not the JSON that stage's rules read: the
/// source got an HTML error page, a challenge page or an empty body where it
/// expected its document.
///
/// The frozen reader fails inside Gson and its exception names a character
/// offset, and this product's raw `FormatException` did the same, so the
/// operator saw `读取失败：FormatException: Unexpected character (at character 1)`
/// with the body pasted on and nothing about which stage, which request or
/// which body produced it. This error carries what the caller can act on.
class SourceStageFormatError implements Exception {
  const SourceStageFormatError({
    required this.stage,
    required this.address,
    required this.prefix,
    this.httpResponse,
  });

  /// The stage whose response could not be read.
  final BookSourceStage stage;

  /// The response's address, without the parts a source's credentials travel in
  /// (see [sourceStageAddress]).
  final String address;

  /// A bounded, single-line prefix of the body (see [sourceStageBodyPrefix]).
  final String prefix;

  final SourceStageHttpDetails? httpResponse;

  /// The stage's word as this product's copy uses it (`详情` for the book
  /// information stage, the word `readingDetailsAndToc` already shows). No stage
  /// outside the four that read a body decodes one, so the remaining stages keep
  /// their identifier rather than inventing a word.
  static String stageWord(BookSourceStage stage) => switch (stage) {
    BookSourceStage.search => '搜索',
    BookSourceStage.bookInfo => '详情',
    BookSourceStage.tableOfContents => '目录',
    BookSourceStage.content => '正文',
    BookSourceStage.idle ||
    BookSourceStage.completed ||
    BookSourceStage.failed => stage.name,
  };

  @override
  String toString() {
    final details = sourceStageHttpDescription(httpResponse);
    return '${stageWord(stage)}响应不是 JSON（可能是错误页）：$prefix'
        '${details.isEmpty ? '' : '，$details'}（$address）';
  }
}

/// How much of a body [SourceStageFormatError] keeps: enough to recognize an
/// error page, not a body to read. A whole body belongs in the source's own log
/// and in nothing the interface shows.
const sourceStageBodyPrefixLimit = 40;

/// A body's first [sourceStageBodyPrefixLimit] characters as one line, the last
/// of them an ellipsis when the body continues. A newline in the body would put
/// the rest of the page on its own line in a status message, so whitespace runs
/// collapse first.
String sourceStageBodyPrefix(String body) {
  final text = body.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (text.length <= sourceStageBodyPrefixLimit) return text;
  return '${text.substring(0, sourceStageBodyPrefixLimit - 1)}…';
}

/// The response's address as a diagnostic may show it: the scheme, host, port
/// and path, without the query or any user info. A source's key, token or
/// credential commonly travels in the query, and a message the operator can
/// paste or screenshot must not carry it.
String sourceStageAddress(Uri url) => Uri(
  scheme: url.scheme,
  host: url.host,
  port: url.hasPort ? url.port : null,
  path: url.path,
).toString();

/// The safe HTTP detail; a missing count is not an empty response.
String sourceStageHttpDescription(SourceStageHttpDetails? response) {
  if (response == null) return '';
  final bytes = response.bodyByteLength;
  return 'HTTP ${response.statusCode}${bytes == null ? '' : '（$bytes 字节）'}';
}

enum SourceStageFailureKind {
  emptyResponse,
  extractionFailed,
  timeout,
  connection,
}

/// A diagnostic at an existing stage failure, containing only safe facts.
class SourceStageDiagnostic implements Exception {
  const SourceStageDiagnostic({
    required this.stage,
    required this.address,
    required this.kind,
    this.httpResponse,
  });

  factory SourceStageDiagnostic.response({
    required BookSourceStage stage,
    required Uri url,
    required String body,
    SourceStageHttpDetails? httpResponse,
  }) => SourceStageDiagnostic(
    stage: stage,
    address: sourceStageAddress(httpResponse?.url ?? url),
    kind: body.isEmpty
        ? SourceStageFailureKind.emptyResponse
        : SourceStageFailureKind.extractionFailed,
    httpResponse: httpResponse,
  );

  final BookSourceStage stage;
  final String address;
  final SourceStageFailureKind kind;
  final SourceStageHttpDetails? httpResponse;

  @override
  String toString() {
    final reason = switch (kind) {
      SourceStageFailureKind.emptyResponse => '响应为空',
      SourceStageFailureKind.extractionFailed => '响应未匹配到内容',
      SourceStageFailureKind.timeout => '请求超时',
      SourceStageFailureKind.connection => '连接失败',
    };
    final details = sourceStageHttpDescription(httpResponse);
    return '${SourceStageFormatError.stageWord(stage)}$reason'
        '${details.isEmpty ? '' : '：$details'}（$address）';
  }
}

/// Only the actual request await belongs here. Rule/header/script failures
/// and the explicit cancellation/TLS/limit types retain their own lifecycle.
Future<T> sourceStageRequest<T>({
  required BookSourceStage stage,
  required Uri url,
  required Future<T> Function() request,
  bool diagnose = true,
}) async {
  if (!diagnose) return request();
  try {
    return await request();
  } on TimeoutException {
    throw SourceStageDiagnostic(
      stage: stage,
      address: sourceStageAddress(url),
      kind: SourceStageFailureKind.timeout,
    );
  } on SocketException {
    throw SourceStageDiagnostic(
      stage: stage,
      address: sourceStageAddress(url),
      kind: SourceStageFailureKind.connection,
    );
  } on HttpException {
    throw SourceStageDiagnostic(
      stage: stage,
      address: sourceStageAddress(url),
      kind: SourceStageFailureKind.connection,
    );
  }
}
