import 'dart:convert';

import 'source_encoding.dart';

typedef UrlScriptEvaluator =
    Future<Object?> Function(String script, Object? result);

/// Legado URL options (`<url>, {json}`) that the HTTP request path supports.
class SourceUrlOptions {
  const SourceUrlOptions({
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.jsonBody = false,
    this.retry = 0,
    this.js,
    this.charset,
  });

  /// The frozen `AnalyzeUrl` only leaves GET for an explicit `POST`.
  final String method;
  final Map<String, String> headers;
  final String? body;

  /// True when the rule body was a JSON object/array re-serialized as JSON.
  final bool jsonBody;

  /// Extra non-2xx attempts, matching the frozen `newCallResponse` loop.
  final int retry;

  /// Post-resolution script whose result replaces the resolved URL.
  final String? js;

  /// The frozen `UrlOption.getCharset`: the request encoder's charset, the
  /// literal `escape` for `EncoderUtils.escape`, and null (the frozen blank)
  /// for the default UTF-8 with its already-encoded check.
  final String? charset;

  bool get isPost => method == 'POST';
}

/// Options that need the WebView path or upload path.
const _unsupportedUrlOptions = <String, String>{
  'type': 'type 选项属于 WebView/表单上传路径',
  'webView': 'webView 选项需要 WebView 请求路径',
  'webJs': 'webJs 选项需要 WebView 请求路径',
  'webViewDelayTime': 'webViewDelayTime 选项需要 WebView 请求路径',
  'serverID': 'serverID 选项需要多服务器书源支持',
};

/// Frozen `AnalyzeUrl.analyzeFields`/`analyzeQuery` (`AnalyzeUrl.kt:279-292`)
/// over `encodeParams` (`AnalyzeUrl.kt:294-334`).
///
/// [charset] is the request option: null (or blank) is the default UTF-8 branch
/// with the already-encoded check, the literal `escape` is
/// [sourceEscape], and every other name is that charset's bytes, percent-encoded
/// the way the frozen `queryEncoder`/`URLEncoder` percent-encode them.
Future<String> encodeSourceParams(
  String params, {
  String? charset,
  required bool isQuery,
}) async {
  // The frozen resolved charset: UTF-8 for no option, the named one for a
  // named option, and null only for `escape`. A query with a resolved charset
  // goes through `queryEncoder`; `escape` falls through to the field loop,
  // sharing it with every POST form body.
  final escape = charset == 'escape';
  final named = charset != null && charset.isNotEmpty && !escape;
  if (named) {
    // Frozen `encodeParams` resolves `Charset.forName(charset)` before it looks
    // at the value, so an unknown name fails even when the value would have
    // been passed through unencoded.
    await _resolveSourceCharset(charset);
  }
  if (isQuery && !escape) {
    // `queryEncoder.encode(params, charset)` (hutool, `AnalyzeUrl.kt:307-311`):
    // an already-encoded query is sent as it is, otherwise the encoder writes
    // `%XX` (upper case) for everything outside the unreserved and mask set.
    if (sourceQueryLooksEncoded(params)) return params;
    return _percentEncodeBytes(
      await _sourceCharsetBytes(params, charset ?? 'UTF-8'),
      form: false,
    );
  }
  // The frozen field loop: `key=value` pairs split on `&`, an already-encoded
  // key or value kept only in the default branch. The `&` is written when the
  // builder already has content, so a leading empty pair disappears.
  final output = StringBuffer();
  var position = 0;
  while (position <= params.length) {
    if (output.isNotEmpty) output.write('&');
    var ampersand = params.indexOf('&', position);
    if (ampersand == -1) ampersand = params.length;
    final equals = params.indexOf('=', position);
    final String key;
    final String? value;
    if (equals == -1 || equals > ampersand) {
      key = params.substring(position, ampersand);
      value = null;
    } else {
      key = params.substring(position, equals);
      value = params.substring(equals + 1, ampersand);
    }
    output.write(await _appendSourceEncoded(key, charset: charset));
    if (value != null) {
      output.write('=');
      output.write(await _appendSourceEncoded(value, charset: charset));
    }
    position = ampersand + 1;
  }
  return output.toString();
}

/// Frozen `StringBuilder.appendEncoded` (`AnalyzeUrl.kt:317-328`).
Future<String> _appendSourceEncoded(String value, {String? charset}) async {
  if (charset == null || charset.isEmpty) {
    // The default branch is UTF-8 with the already-encoded check; a value that
    // already looks form-encoded is passed through.
    if (sourceFormLooksEncoded(value)) return value;
    return _urlEncode(value, 'UTF-8');
  }
  // The frozen local charset is null only for the `escape` option.
  if (charset == 'escape') return sourceEscape(value);
  return _urlEncode(value, charset);
}

/// Frozen `URLEncoder.encode(value, charset)`: spaces become `+`, letters,
/// digits and `-`, `*`, `_`, `.` stay, and every other character is the
/// charset's bytes as upper-case `%XX`.
Future<String> _urlEncode(String value, String charset) async =>
    _percentEncodeBytes(await _sourceCharsetBytes(value, charset), form: true);

/// Whether a form value already looks `URLEncoder`-encoded: the frozen
/// `NetworkUtils.encodedForm` character set, `%XX` stops included.
bool sourceFormLooksEncoded(String value) =>
    RegExp(r'^(?:[A-Za-z0-9*._-]|%[0-9A-Fa-f]{2})*$').hasMatch(value);

/// Frozen `EncoderUtils.escape` (`EncoderUtils.kt:11-28`): letters and digits
/// stay, and everything else is `%` plus the UTF-16 code unit's lower-case hex,
/// with `%0` before a unit under 16 and `%u` before one above 255.
String sourceEscape(String value) {
  final output = StringBuffer();
  for (final unit in value.codeUnits) {
    if (_isAsciiLetterOrDigit(unit)) {
      output.writeCharCode(unit);
      continue;
    }
    final prefix = unit < 16
        ? '%0'
        : unit < 256
        ? '%'
        : '%u';
    output.write('$prefix${unit.toRadixString(16)}');
  }
  return output.toString();
}

/// The bytes one named charset writes, from the Rust `liber_text` engine. UTF-8
/// is the one encoding `dart:convert` writes exactly as
/// the engine does, so it stays in process; every other name crosses the bridge.
Future<List<int>> _sourceCharsetBytes(String text, String charset) async {
  if (_isUtf8Label(charset)) return utf8.encode(text);
  return _bridgeEncode(text, charset);
}

/// Frozen `Charset.forName(charset)`: resolving the name is what fails for an
/// unknown one, before the value matters.
Future<void> _resolveSourceCharset(String charset) async {
  if (_isUtf8Label(charset)) return;
  await _bridgeEncode('', charset);
}

Future<List<int>> _bridgeEncode(String text, String charset) async {
  try {
    return await SourceEncoding.encode(text, charset);
  } catch (error) {
    if (SourceEncoding.isUnknownEncoding(error)) {
      throw UnsupportedError('charset 选项的字符集不受支持：$charset');
    }
    rethrow;
  }
}

bool _isUtf8Label(String charset) =>
    charset == 'UTF-8' || charset == 'utf-8' || charset == 'utf8';

/// `%XX` (upper case) for every byte outside the mask, and either `+` (form) or
/// the literal byte (query) for the rest.
String _percentEncodeBytes(List<int> bytes, {required bool form}) {
  final output = StringBuffer();
  for (final byte in bytes) {
    if (byte < 0x80) {
      if (form && byte == 0x20) {
        output.write('+');
        continue;
      }
      final character = String.fromCharCode(byte);
      final safe = _isAsciiLetterOrDigit(byte) ||
          (form
              ? '*-._'.contains(character)
              : '-._~'.contains(character) ||
                    _sourceQueryEncoderMask.contains(character));
      if (safe) {
        output.write(character);
        continue;
      }
    }
    output.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
  }
  return output.toString();
}

/// Frozen POST body selection (`analyzeFields` plus `getResponseAwait`): form
/// encoding only for non JSON/XML bodies without a declared content type,
/// otherwise the raw body with the JSON content type. The `charset` option only
/// reaches the form branch, as the frozen `analyzeFields` is only called there.
Future<({String method, String? body, Map<String, String> headers})>
sourceRequestShape(
  SourceUrlOptions options,
  Map<String, String> headers,
) async {
  if (!options.isPost) {
    return (
      method: 'GET',
      body: null,
      headers: const <String, String>{},
    );
  }
  final raw = options.body ?? '';
  final declared = headers.keys.any(
    (key) => key.toLowerCase() == 'content-type',
  );
  if (raw.trim().isEmpty) {
    return (
      method: 'POST',
      body: '',
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
    );
  }
  final leading = raw.trimLeft();
  final structured =
      options.jsonBody ||
      leading.startsWith('{') ||
      leading.startsWith('[') ||
      leading.startsWith('<');
  if (!structured && !declared) {
    return (
      method: 'POST',
      body: await encodeSourceParams(
        raw,
        charset: options.charset,
        isQuery: false,
      ),
      headers: const {'Content-Type': 'application/x-www-form-urlencoded'},
    );
  }
  if (!declared) {
    return (
      method: 'POST',
      body: raw,
      headers: const {'Content-Type': 'application/json; charset=UTF-8'},
    );
  }
  return (
    method: 'POST',
    body: raw,
    headers: const <String, String>{},
  );
}

/// Splits an expanded rule into its URL text and its supported options.
///
/// The frozen `AnalyzeUrl` expands `@js:`/`<js>` and `{{ }}` first, then splits
/// on `\s*,\s*(?=\{)` and reads the remainder as a `UrlOption` JSON object.
/// `origin` is parsed by the frozen runtime and never read on the HTTP path;
/// the WebView and upload options are rejected here instead of being applied
/// differently from the baseline.
({String path, SourceUrlOptions options}) splitSourceUrlOptions(
  String expanded,
) {
  final match = RegExp(r'\s*,\s*(?=\{)').firstMatch(expanded);
  if (match == null) {
    return (path: expanded.trim(), options: const SourceUrlOptions());
  }
  final start = expanded.indexOf('{', match.start);
  final end = _jsonObjectEnd(expanded, start);
  if (end < 0) throw const FormatException('请求选项不是合法的 JSON 对象');
  final Object? decoded;
  try {
    decoded = jsonDecode(expanded.substring(start, end));
  } on FormatException catch (error) {
    throw FormatException('请求选项不是合法 JSON：${error.message}');
  }
  if (decoded is! Map) throw const FormatException('请求选项必须是 JSON 对象');
  for (final entry in decoded.entries) {
    final key = '${entry.key}';
    final unsupported = _unsupportedUrlOptions[key];
    if (unsupported != null) throw UnsupportedError(unsupported);
    if (!const {
      'method',
      'headers',
      'body',
      'js',
      'retry',
      'charset',
      'origin',
    }.contains(key)) {
      throw UnsupportedError('暂不支持该请求选项：$key');
    }
  }
  final rawHeaders = decoded['headers'];
  final Map<String, String> headers;
  if (rawHeaders == null) {
    headers = const {};
  } else if (rawHeaders is Map) {
    headers = {
      for (final entry in rawHeaders.entries) '${entry.key}': '${entry.value}',
    };
  } else if (rawHeaders is String && rawHeaders.trim().isNotEmpty) {
    final parsed = jsonDecode(rawHeaders);
    if (parsed is! Map) throw const FormatException('headers 选项必须是 JSON 对象');
    headers = {
      for (final entry in parsed.entries) '${entry.key}': '${entry.value}',
    };
  } else {
    throw const FormatException('headers 选项必须是 JSON 对象');
  }
  final rawBody = decoded['body'];
  final String? body;
  var jsonBody = false;
  if (rawBody == null) {
    body = null;
  } else if (rawBody is Map || rawBody is List) {
    body = jsonEncode(rawBody);
    jsonBody = true;
  } else {
    body = '$rawBody';
  }
  final rawRetry = decoded['retry'];
  final int retry;
  switch (rawRetry) {
    case null:
      retry = 0;
    case final int value:
      retry = value;
    case final num value:
      retry = value.toInt();
    case final String value:
      retry = int.tryParse(value) ?? -1;
    default:
      retry = -1;
  }
  if (retry < 0) throw const FormatException('retry 选项必须是非负整数');
  final rawJs = decoded['js'];
  if (rawJs != null && rawJs is! String) {
    throw const FormatException('js 选项必须是字符串');
  }
  final rawCharset = decoded['charset'];
  if (rawCharset != null && rawCharset is! String) {
    throw const FormatException('charset 选项必须是字符串');
  }
  final rawMethod = '${decoded['method'] ?? ''}';
  return (
    path: expanded.substring(0, match.start).trim(),
    options: SourceUrlOptions(
      method: rawMethod.toUpperCase() == 'POST' ? 'POST' : 'GET',
      headers: headers,
      body: body,
      jsonBody: jsonBody,
      retry: retry,
      js: rawJs as String?,
      // Frozen `UrlOption.setCharset`: a null or blank value is the default
      // branch, and a non-blank one is kept verbatim.
      charset: rawCharset == null || rawCharset.trim().isEmpty
          ? null
          : rawCharset,
    ),
  );
}

/// Index just past the JSON object starting at [start], or -1 when unbalanced.
int _jsonObjectEnd(String text, int start) {
  if (start < 0 || start >= text.length || text[start] != '{') return -1;
  var depth = 0;
  var inString = false;
  var escaped = false;
  for (var i = start; i < text.length; i++) {
    final character = text[i];
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (character == r'\') {
        escaped = true;
      } else if (character == '"') {
        inString = false;
      }
      continue;
    }
    switch (character) {
      case '"':
        inString = true;
      case '{':
        depth++;
      case '}':
        depth--;
        if (depth == 0) return i + 1;
    }
  }
  return -1;
}

/// The frozen URL order: `@js`/`<js>`, then `{{ }}`, then the `<a,b,c>` page
/// list. Each call gets fresh bindings.
///
/// [page] is the `AnalyzeUrl` page: `1..n` for a search, and `null` for the
/// stages the frozen runtime builds without one. The page list is only
/// substituted when a page exists.
Future<String> expandSourceUrl(
  String template,
  UrlScriptEvaluator evaluate, {
  int? page,
}) async {
  var result = template;
  var end = 0;
  final blocks = RegExp(
    r'<js>([\s\S]*?)</js>|@js:([\s\S]*)',
    caseSensitive: false,
  );
  for (final match in blocks.allMatches(template)) {
    final prefix = template.substring(end, match.start).trim();
    if (prefix.isNotEmpty) result = prefix.replaceAll('@result', result);
    result = '${await evaluate(match[1] ?? match[2]!, result)}';
    end = match.end;
  }
  final tail = template.substring(end).trim();
  if (tail.isNotEmpty) result = tail.replaceAll('@result', result);
  final output = StringBuffer();
  end = 0;
  for (final match in RegExp(r'\{\{([\s\S]*?)\}\}').allMatches(result)) {
    output.write(result.substring(end, match.start));
    final value = await evaluate(match[1]!, null);
    output.write(
      value is double && value.isFinite && value == value.truncateToDouble()
          ? value.toInt()
          : value ?? '',
    );
    end = match.end;
  }
  output.write(result.substring(end));
  final expanded = output.toString();
  return substituteSourcePageList(expanded.isEmpty ? result : expanded, page);
}

/// Characters the frozen `NetworkUtils.encodedQuery` accepts inside a query in
/// addition to letters and digits.
const _sourceQueryMask = r'!$&()*+,-./:;=?@[\]^_`{|}~';

/// Characters the frozen query encoder leaves alone in addition to letters,
/// digits and `-._~`.
const _sourceQueryEncoderMask = r'!$%&()*+,/:;=?@[\]^`{|}';

bool _isAsciiLetterOrDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x5A) ||
    (unit >= 0x61 && unit <= 0x7A);

bool _isHexDigit(int unit) =>
    (unit >= 0x30 && unit <= 0x39) ||
    (unit >= 0x41 && unit <= 0x46) ||
    (unit >= 0x61 && unit <= 0x66);

/// Frozen `NetworkUtils.encodedQuery`: true when every character of [query] is
/// either legal in a query or part of a `%XX` escape.
bool sourceQueryLooksEncoded(String query) {
  for (var i = 0; i < query.length; i++) {
    final unit = query.codeUnitAt(i);
    if (_isAsciiLetterOrDigit(unit) ||
        _sourceQueryMask.contains(String.fromCharCode(unit))) {
      continue;
    }
    if (unit == 0x25 && i + 2 < query.length) {
      if (_isHexDigit(query.codeUnitAt(i + 1)) &&
          _isHexDigit(query.codeUnitAt(i + 2))) {
        i += 2;
        continue;
      }
    }
    return false;
  }
  return true;
}

/// Frozen `AnalyzeUrl.analyzeQuery` plus the `HttpUrl.encodedQuery` rebuild:
/// everything after the first `?` is the query, and it is percent-encoded once
/// unless it already looks encoded (an existing escape is never re-encoded).
///
/// [charset] is the same request option [encodeSourceParams] reads; on this
/// path it is `charset: "escape"`, which drops to the escape encoder, or none.
Future<String> encodeSourceQuery(String url, {String? charset}) async {
  final start = url.indexOf('?');
  if (start < 0) return url;
  final query = url.substring(start + 1);
  return '${url.substring(0, start)}?'
      '${await encodeSourceParams(query, charset: charset, isQuery: true)}';
}

/// The URL text whose query is the rule's own, not the one Dart's `Uri` wrote.
///
/// The frozen `analyzeUrl` resolves the URL to a *string* and hands its query
/// text to `analyzeQuery`; `Uri` instead percent-encodes a raw query (and
/// canonicalizes escapes of unreserved characters) while it resolves, so a rule
/// that wrote `q=书` would reach the charset encoder as `q=%E4%B9%A6`. A named
/// charset would then see nothing to encode, and the already-encoded check
/// would pass the UTF-8 form through. [raw] is the rule's own text and supplies
/// the query; [resolved] supplies the path, origin and validation.
String sourceUrlTextWithRawQuery(Uri resolved, String raw) {
  final at = raw.indexOf('?');
  if (at < 0) return '$resolved';
  final text = '$resolved';
  final encoded = text.indexOf('?');
  return '${encoded < 0 ? text : text.substring(0, encoded)}${raw.substring(at)}';
}

/// Frozen `replaceKeyPageJs` page-list step: each `<a,b,c>` becomes the page-th
/// entry, or the last entry once the page is past the end.
String substituteSourcePageList(String url, int? page) {
  if (page == null || !url.contains('<')) return url;
  var result = url;
  for (final match in RegExp(r'<(.*?)>').allMatches(url)) {
    final pages = match.group(1)!.split(',');
    final index = page.clamp(1, pages.length) - 1;
    result = result.replaceAll(match.group(0)!, pages[index].trim());
  }
  return result;
}
