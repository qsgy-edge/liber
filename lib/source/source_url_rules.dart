import 'dart:convert';

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

  bool get isPost => method == 'POST';
}

/// Options that need the WebView path, upload path or charset support.
const _unsupportedUrlOptions = <String, String>{
  'charset': 'charset 选项需要字符集编码/解码支持',
  'type': 'type 选项属于 WebView/表单上传路径',
  'webView': 'webView 选项需要 WebView 请求路径',
  'webJs': 'webJs 选项需要 WebView 请求路径',
  'webViewDelayTime': 'webViewDelayTime 选项需要 WebView 请求路径',
  'serverID': 'serverID 选项需要多服务器书源支持',
};

/// Frozen `analyzeFields` form encoding for POST bodies: already-encoded
/// values pass through, everything else is UTF-8 percent encoded with `+`
/// for spaces.
String encodeSourceForm(String body) => body
    .split('&')
    .map((pair) {
      final equals = pair.indexOf('=');
      String encode(String value) {
        if (RegExp(r'^(?:[A-Za-z0-9*._-]|%[0-9A-Fa-f]{2})*$').hasMatch(value)) {
          return value;
        }
        return utf8.encode(value).map((byte) {
          if (byte == 32) return '+';
          final character = String.fromCharCode(byte);
          if (RegExp(r'^[A-Za-z0-9*._-]$').hasMatch(character)) {
            return character;
          }
          return '%${byte.toRadixString(16).padLeft(2, '0').toUpperCase()}';
        }).join();
      }

      return equals < 0
          ? encode(pair)
          : '${encode(pair.substring(0, equals))}=${encode(pair.substring(equals + 1))}';
    })
    .join('&');

/// Frozen POST body selection (`analyzeFields` plus `getResponseAwait`): form
/// encoding only for non JSON/XML bodies without a declared content type,
/// otherwise the raw body with the JSON content type.
({String method, String? body, Map<String, String> headers}) sourceRequestShape(
  SourceUrlOptions options,
  Map<String, String> headers,
) {
  if (!options.isPost) return (method: 'GET', body: null, headers: const {});
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
      body: encodeSourceForm(raw),
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
  return (method: 'POST', body: raw, headers: const {});
}

/// Splits an expanded rule into its URL text and its supported options.
///
/// The frozen `AnalyzeUrl` expands `@js:`/`<js>` and `{{ }}` first, then splits
/// on `\s*,\s*(?=\{)` and reads the remainder as a `UrlOption` JSON object.
/// `origin` is parsed by the frozen runtime and never read on the HTTP path;
/// the WebView, upload and charset options are rejected here instead of being
/// applied differently from the baseline.
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
String encodeSourceQuery(String url) {
  final start = url.indexOf('?');
  if (start < 0) return url;
  final query = url.substring(start + 1);
  if (sourceQueryLooksEncoded(query)) return url;
  return '${url.substring(0, start)}?${_encodeSourceQueryValue(query)}';
}

String _encodeSourceQueryValue(String query) {
  final output = StringBuffer();
  for (final rune in query.runes) {
    final character = rune < 0x80 ? String.fromCharCode(rune) : null;
    if (character != null &&
        (_isAsciiLetterOrDigit(rune) ||
            character == '-' ||
            character == '.' ||
            character == '_' ||
            character == '~' ||
            _sourceQueryEncoderMask.contains(character))) {
      output.write(character);
      continue;
    }
    for (final byte in utf8.encode(String.fromCharCode(rune))) {
      output.write('%${byte.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
  }
  return output.toString();
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
