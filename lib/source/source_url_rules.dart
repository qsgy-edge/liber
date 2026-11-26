import 'dart:convert';

import 'source_encoding.dart';

typedef UrlScriptEvaluator =
    Future<Object?> Function(String script, Object? result);

/// Legado URL options (`<url>, {json}`) that the request path supports.
class SourceUrlOptions {
  const SourceUrlOptions({
    this.method = 'GET',
    this.headers = const {},
    this.body,
    this.jsonBody = false,
    this.retry = 0,
    this.js,
    this.charset,
    this.webView = false,
    this.webJs,
    this.webViewDelayTime = 0,
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

  /// Frozen `UrlOption.useWebView()`: the option `webView` is true for every
  /// value but null, `""`, `false` and `"false"`, so this stage is rendered by
  /// the platform WebView instead of being fetched over HTTP.
  final bool webView;

  /// Frozen `UrlOption.getWebJs()`: the page JavaScript the WebView path runs,
  /// null when the option was absent or blank. It replaces the frozen default
  /// (`document.documentElement.outerHTML`).
  final String? webJs;

  /// Frozen `UrlOption.getWebViewDelayTime()`, floored at 0: milliseconds added
  /// to the frozen 1000 ms delay before the page script runs.
  final int webViewDelayTime;

  bool get isPost => method == 'POST';
}

/// Options that need a request path this product does not have.
const _unsupportedUrlOptions = <String, String>{
  'type': 'type 选项属于 WebView/表单上传路径',
  'serverID': 'serverID 选项需要多服务器书源支持',
};

/// Kotlin's `String.trim()`, which is `trim(Char::isWhitespace)`.
String sourceKotlinTrim(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && sourceIsKotlinWhitespace(value.codeUnitAt(start))) {
    start++;
  }
  while (end > start && sourceIsKotlinWhitespace(value.codeUnitAt(end - 1))) {
    end--;
  }
  return value.substring(start, end);
}

/// Kotlin's `isBlank()`: every code unit is `Char.isWhitespace()`.
bool sourceKotlinIsBlank(String value) =>
    value.codeUnits.every(sourceIsKotlinWhitespace);

/// `Character.isWhitespace(c) || Character.isSpaceChar(c)`, the Kotlin
/// `Char.isWhitespace()` predicate. The `isSpaceChar` half is the full Zs/Zl/Zp
/// set, so the non-breaking spaces (`0xA0`, `0x2007` — inside `0x2000`–`0x200A`
/// — and `0x202F`) are members, where Java's `isWhitespace` alone excludes them.
/// The ASCII controls Java counts (`0x09`–`0x0D`, `0x1C`–`0x1F`) are members and
/// `0x85` is not, which is what the frozen blank tests see; Dart's own `trim()`
/// is the other way round on both. The Unicode version behind the table is the
/// runtime's, so a code point that changed category between versions (U+180E) is
/// not covered by a claim here.
bool sourceIsKotlinWhitespace(int unit) =>
    (unit >= 0x09 && unit <= 0x0D) ||
    (unit >= 0x1C && unit <= 0x1F) ||
    unit == 0x20 ||
    unit == 0xA0 ||
    unit == 0x1680 ||
    (unit >= 0x2000 && unit <= 0x200A) ||
    unit == 0x2028 ||
    unit == 0x2029 ||
    unit == 0x202F ||
    unit == 0x205F ||
    unit == 0x3000;

/// Java's `String.trim()`, the edge trim the pinned `java.net.URL` constructor
/// applies to the text it receives: every leading and trailing code unit
/// `<= U+0020`. It is not the Kotlin `trim()` of [sourceKotlinTrim]: a Unicode
/// space such as U+2000 stays in the URL text, which is what the frozen relative
/// branch relies on because it hands `URL(baseURL, relativePath)` the original
/// relative text (and the String-base overload builds its base the same way).
String _javaUrlEdgeText(String value) {
  var start = 0;
  var end = value.length;
  while (start < end && value.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && value.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  return value.substring(start, end);
}

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
      final safe =
          _isAsciiLetterOrDigit(byte) ||
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
    return (method: 'GET', body: null, headers: const <String, String>{});
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
  return (method: 'POST', body: raw, headers: const <String, String>{});
}

/// Locates the raw option boundary without parsing or validating its contents.
/// Book identity also needs this boundary: imported addresses can carry option
/// types the request parser refuses, and their stored identity must still work.
int? sourceUrlOptionBoundaryOf(String address) =>
    RegExp(r'\s*,\s*(?=\{)').firstMatch(address)?.start;

/// Splits an expanded rule into its URL text and its supported options.
///
/// The frozen `AnalyzeUrl` expands `@js:`/`<js>` and `{{ }}` first, then splits
/// on `\s*,\s*(?=\{)` and reads the remainder as a `UrlOption` JSON object.
/// `origin` is parsed by the frozen runtime and never read on the HTTP path;
/// the WebView and upload options are rejected here instead of being applied
/// differently from the baseline.
///
/// A tail the reader cannot read is **not** an error: the frozen
/// `AnalyzeUrl.kt:222` calls `GSON.fromJsonObject<UrlOption>(…)` and applies the
/// result only when it is non-null (`?.let { … }`), so the URL stays bare and no
/// option is applied. Only a tail that decodes into an object can refuse a
/// family by name.
({String path, String tail, SourceUrlOptions options}) splitSourceUrlOptions(
  String expanded,
) {
  final boundary = sourceUrlOptionBoundaryOf(expanded);
  if (boundary == null) {
    return (path: expanded.trim(), tail: '', options: const SourceUrlOptions());
  }
  final path = expanded.substring(0, boundary).trim();
  // The tail verbatim, comma included: a caller that has to persist an address
  // text keeps it exactly as the rule wrote it.
  final tail = expanded.substring(boundary);
  final start = expanded.indexOf('{', boundary);
  final Object? decoded = _decodeUrlOptionTail(expanded.substring(start));
  if (decoded is! Map) {
    return (path: path, tail: tail, options: const SourceUrlOptions());
  }
  for (final entry in decoded.entries) {
    final key = entry.key;
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
      'webView',
      'webJs',
      'webViewDelayTime',
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
  // Frozen `UrlOption.setWebJs`: a null or blank value is null, any other value
  // is kept verbatim.
  final rawWebJs = decoded['webJs'];
  if (rawWebJs != null && rawWebJs is! String) {
    throw const FormatException('webJs 选项必须是字符串');
  }
  // Frozen `UrlOption.setWebViewViewDelayTime` plus `AnalyzeUrl`'s
  // `max(0, option.getWebViewDelayTime() ?: 0)`: a malformed value disables the
  // delay instead of failing the request.
  final rawDelay = decoded['webViewDelayTime'];
  final int webViewDelayTime;
  switch (rawDelay) {
    case null:
      webViewDelayTime = 0;
    case final int value:
      webViewDelayTime = value < 0 ? 0 : value;
    case final num value:
      final truncated = value.toInt();
      webViewDelayTime = truncated < 0 ? 0 : truncated;
    case final String value:
      final parsed = int.tryParse(value);
      webViewDelayTime = parsed == null || parsed < 0 ? 0 : parsed;
    default:
      webViewDelayTime = 0;
  }
  return (
    path: path,
    tail: tail,
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
      webView: _useWebView(decoded['webView']),
      webJs: rawWebJs == null || rawWebJs.trim().isEmpty ? null : rawWebJs,
      webViewDelayTime: webViewDelayTime,
    ),
  );
}

/// The request target inside an address text: everything before its `,{…}`
/// option tail.
///
/// The frozen `AnalyzeUrl.analyzeUrl` computes its `urlNoOption` the same way
/// for every stage. The catalog only locates the target; a request validates
/// the option tail when it analyzes the complete address.
String sourceUrlTargetOf(String address) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  return (boundary == null ? address : address.substring(0, boundary)).trim();
}

/// The `,{…}` option tail verbatim, without validating a saved chapter's options.
String sourceUrlOptionTailOf(String address) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  return boundary == null ? '' : address.substring(boundary);
}

/// Resolves the chapter target without reading its options. Keep the exact
/// tail for storage; title analysis uses the delimiter from `getAbsoluteURL`.
String sourceAbsoluteRequestText(
  Uri base,
  String address, {
  bool normalizeOptionSeparator = false,
  String? inheritAuthorityFrom,
}) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  final target = boundary == null ? address : address.substring(0, boundary);
  final resolvedTarget = sourceUrlTextResolved(base, target);
  final path = inheritAuthorityFrom == null
      ? resolvedTarget
      : _withInheritedAuthority(
          base,
          target,
          resolvedTarget,
          inheritAuthorityFrom,
        );
  if (boundary == null) return path;
  final tail = normalizeOptionSeparator
      ? ',${address.substring(address.indexOf('{', boundary))}'
      : address.substring(boundary);
  return '$path$tail';
}

// A retained TOC has the original authority. Leave the existing resolved path
// and query alone: the original base path may have escaped dot segments.
String _withInheritedAuthority(
  Uri base,
  String target,
  String resolved,
  String baseText,
) {
  if (_javaUrlEdgeText(target).startsWith('//') ||
      Uri.tryParse(sourceKotlinTrim(target))?.hasScheme == true) {
    return resolved;
  }
  final literalOrigin = sourceRequestOrigin(base, baseText);
  final canonicalOrigin = '${base.scheme}://${base.authority}';
  if (literalOrigin == null ||
      !resolved.startsWith(canonicalOrigin) ||
      Uri.tryParse(literalOrigin) != Uri.tryParse(canonicalOrigin)) {
    return resolved;
  }
  final authority = literalOrigin.substring(literalOrigin.indexOf('://') + 3);
  return '${base.scheme}://$authority${resolved.substring(canonicalOrigin.length)}';
}

/// The request facts a target conversion reads from an address text's own
/// `,{…}` option tail: the method the frozen request would use, the charset its
/// GET query encoder would consume, and whether that tail declares an option
/// script.
///
/// This is the same first-object read [splitSourceUrlOptions] performs, with the
/// same decoder, but it reads only the three facts a target conversion consumes:
/// no option family is validated, no unsupported option is refused and no
/// charset is resolved. A tail the reader cannot read is "no options", exactly
/// as it is there.
///
/// [scripted] is the presence of the `js` option alone. That option replaces the
/// request URL when a request runs it, so text that already was a request's own
/// address must take its query-consumption fact from that request instead of
/// reading the script again.
({String method, String? charset, bool scripted}) sourceUrlTargetOptionFacts(
  String address,
) {
  final boundary = sourceUrlOptionBoundaryOf(address);
  final Object? decoded = boundary == null
      ? null
      : _decodeUrlOptionTail(address.substring(address.indexOf('{', boundary)));
  if (decoded is! Map) {
    return (method: 'GET', charset: null, scripted: false);
  }
  final rawCharset = decoded['charset'];
  return (
    // Frozen `UrlOption.setMethod`'s branch: only `POST` leaves the GET path.
    method: '${decoded['method'] ?? ''}'.toUpperCase() == 'POST'
        ? 'POST'
        : 'GET',
    // Frozen `UrlOption.setCharset`: a null or blank value is the default
    // branch, and a non-blank one is the name the encoder resolves.
    charset: rawCharset is String && rawCharset.trim().isNotEmpty
        ? rawCharset
        : null,
    scripted: decoded['js'] != null,
  );
}

/// Decodes a URL option tail the way the frozen Gson reader does, or null when
/// it is not an object.
///
/// [optionText] is the tail from its `{` to the end of the address text. Strict
/// JSON is tried first on the object [_jsonObjectEnd] finds, so a well-formed
/// tail costs one `jsonDecode`. Gson's reader is lenient and imported sources
/// use those leniencies: `{webView:true}` and `{'webView': true}` are both common
/// (255 of the operator's 8787 sources write single-quoted option text) and
/// strict JSON rejects both, so a tail strict JSON refuses falls back to
/// [_LenientJson] over the whole remainder — the reader consumes exactly one
/// value, so it does not need the object's end to be found first, and a value
/// holding an unbalanced brace cannot cost the options after it.
///
/// Null means "no options": the frozen `AnalyzeUrl.kt:222` applies a
/// `UrlOption` only when Gson returned one, so a tail that does not decode
/// leaves the URL bare and is not an error.
Map<String, Object?>? _decodeUrlOptionTail(String optionText) {
  final end = _jsonObjectEnd(optionText, 0);
  if (end > 0) {
    try {
      final strict = jsonDecode(optionText.substring(0, end));
      if (strict is Map) {
        return {
          for (final entry in strict.entries) '${entry.key}': entry.value,
        };
      }
    } on FormatException {
      // The reader below is what decides.
    }
  }
  final Object? lenient;
  try {
    lenient = _LenientJson(optionText).readDocument();
  } on _LenientJsonError {
    return null;
  }
  return lenient is Map<String, Object?> ? lenient : null;
}

/// The headers a source `header` rule's text declares, read the way the frozen
/// `BaseSource.getHeaderMap` reads it, or null when it does not declare a map.
///
/// The frozen call is `GSON.fromJsonObject` of a `Map<String,String>` over the
/// `header` text, `.getOrNull()` inside a `try { … } catch (e: Exception)`:
/// a header rule whose text is not a map of scoped strings is **not** an error,
/// and the source runs with no source headers at all. This reader is the same
/// lenient Gson-style reader the `,{…}` URL option tail uses ([_LenientJson]):
/// unquoted names and single-quoted strings parse, and a failed read is null.
///
/// The value types are the frozen `Map<String,String>` deserialisation's: a
/// number or a boolean becomes its text, and a nested object or array makes the
/// whole read the frozen `getOrNull()`'s null. One recorded divergence: a
/// `null`-valued entry is dropped here where Gson keeps a null in the map (an
/// HTTP request header cannot carry one, and no record in the operator's
/// library declares one), and [_LenientJson] accepts a trailing comma before a
/// closer where Gson refuses it.
Map<String, String>? parseSourceHeaderMap(String text) {
  final Object? parsed;
  try {
    parsed = _LenientJson(text).readDocument();
  } on _LenientJsonError {
    return null;
  }
  if (parsed is! Map) return null;
  final headers = <String, String>{};
  for (final entry in parsed.entries) {
    final key = entry.key;
    if (key is! String) return null;
    final value = entry.value;
    if (value is String) {
      headers[key] = value;
    } else if (value is num || value is bool) {
      headers[key] = '$value';
    } else if (value != null) {
      // Gson's String adapter throws for a container, which the frozen caller's
      // `catch` turns into no headers.
      return null;
    }
  }
  return headers;
}

/// Thrown inside [_LenientJson]; every caller turns it into "no options".
class _LenientJsonError implements Exception {
  const _LenientJsonError();
}

/// A JSON reader with the leniencies the frozen Gson reader has: unquoted names,
/// single-quoted strings, unquoted scalar words, and a trailing comma before a
/// closer. It exists for the one JSON a Book Source writes by hand — the `,{…}`
/// option tail — and is deliberately not a general JSON parser.
class _LenientJson {
  _LenientJson(this._text);

  final String _text;
  var _at = 0;

  /// Reads one value. Content after it is left unread, as the frozen Gson call
  /// consumes exactly one `UrlOption` and ignores what follows.
  Object? readDocument() => _readValue();

  Object? _readValue() {
    _skipSpace();
    if (_at >= _text.length) throw const _LenientJsonError();
    return switch (_text[_at]) {
      '{' => _readObject(),
      '[' => _readList(),
      '"' => _readString('"'),
      "'" => _readString("'"),
      _ => _readWord(),
    };
  }

  Map<String, Object?> _readObject() {
    _at++; // the opening brace
    final value = <String, Object?>{};
    _skipSpace();
    if (_consume('}')) return value;
    while (true) {
      _skipSpace();
      final key = _readKey();
      _skipSpace();
      if (!_consume(':')) throw const _LenientJsonError();
      value[key] = _readValue();
      _skipSpace();
      if (!_consume(',')) {
        if (_consume('}')) return value;
        throw const _LenientJsonError();
      }
      _skipSpace();
      if (_consume('}')) return value; // a trailing comma
    }
  }

  List<Object?> _readList() {
    _at++; // the opening bracket
    final value = <Object?>[];
    _skipSpace();
    if (_consume(']')) return value;
    while (true) {
      value.add(_readValue());
      _skipSpace();
      if (!_consume(',')) {
        if (_consume(']')) return value;
        throw const _LenientJsonError();
      }
      _skipSpace();
      if (_consume(']')) return value; // a trailing comma
    }
  }

  /// A name: a quoted string, or the bare word Gson's lenient reader accepts.
  String _readKey() {
    if (_at >= _text.length) throw const _LenientJsonError();
    final quote = _text[_at];
    if (quote == '"' || quote == "'") return _readString(quote);
    return '${_readWord()}';
  }

  String _readString(String quote) {
    _at++; // the opening quote
    final buffer = StringBuffer();
    while (true) {
      if (_at >= _text.length) throw const _LenientJsonError();
      final character = _text[_at++];
      if (character == quote) return buffer.toString();
      if (character != r'\') {
        buffer.write(character);
        continue;
      }
      if (_at >= _text.length) throw const _LenientJsonError();
      switch (_text[_at++]) {
        case 'n':
          buffer.write('\n');
        case 't':
          buffer.write('\t');
        case 'r':
          buffer.write('\r');
        case 'b':
          buffer.write('\b');
        case 'f':
          buffer.write('\f');
        case 'u':
          if (_at + 4 > _text.length) throw const _LenientJsonError();
          final code = int.tryParse(_text.substring(_at, _at + 4), radix: 16);
          if (code == null) throw const _LenientJsonError();
          _at += 4;
          buffer.writeCharCode(code);
        case final escaped:
          buffer.write(escaped);
      }
    }
  }

  /// A number, `true`/`false`/`null`, or — the way Gson's lenient reader reads
  /// an unquoted scalar — a string.
  Object? _readWord() {
    final start = _at;
    while (_at < _text.length && !_isDelimiter(_text[_at])) {
      _at++;
    }
    if (_at == start) throw const _LenientJsonError();
    final word = _text.substring(start, _at);
    return switch (word) {
      'true' => true,
      'false' => false,
      'null' => null,
      _ => int.tryParse(word) ?? double.tryParse(word) ?? word,
    };
  }

  bool _isDelimiter(String character) =>
      character == ',' ||
      character == ':' ||
      character == '{' ||
      character == '}' ||
      character == '[' ||
      character == ']' ||
      character.trim().isEmpty;

  void _skipSpace() {
    while (_at < _text.length && _text[_at].trim().isEmpty) {
      _at++;
    }
  }

  bool _consume(String character) {
    if (_at < _text.length && _text[_at] == character) {
      _at++;
      return true;
    }
    return false;
  }
}

/// Frozen `UrlOption.useWebView()`.

/// Frozen `UrlOption.useWebView()`: `null`, `""`, `false` and `"false"` are
/// false and every other value is true.
bool _useWebView(Object? value) => switch (value) {
  null || '' || false || 'false' => false,
  _ => true,
};

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

/// The textual URL the pinned native `URL(base, relativePath).toString()`
/// publishes: an already absolute [raw] is returned verbatim, otherwise the
/// base's authority stays unless the input is protocol-relative; path/query/
/// fragment stay raw. This
/// is publication text, not a wire target; callers validate the actual request
/// separately.
String sourceUrlTextResolved(Uri base, String raw, {String? rawBase}) {
  // The Kotlin trim is the frozen admission test and absolute shortcut, not a
  // trim of the text the constructor sees: the relative branch keeps the
  // original text for the URL constructor, whose own edge trim stops at U+0020.
  final trimmed = sourceKotlinTrim(raw);
  if (Uri.tryParse(trimmed)?.hasScheme == true) return trimmed;
  final relative = _javaUrlEdgeText(raw);
  if (rawBase != null) return _resolveAgainstRawBase(rawBase, relative);
  var path = relative;
  String? query;
  String? fragment;
  final hash = path.indexOf('#');
  if (hash >= 0) {
    fragment = path.substring(hash + 1);
    path = path.substring(0, hash);
  }
  final question = path.indexOf('?');
  if (question >= 0) {
    query = path.substring(question + 1);
    path = path.substring(0, question);
  }
  String authority;
  final String resolvedPath;
  if (path.startsWith('//')) {
    final slash = path.indexOf('/', 2);
    authority = slash < 0 ? path.substring(2) : path.substring(2, slash);
    final authorityPath = slash < 0 ? '' : path.substring(slash);
    resolvedPath = authorityPath;
  } else {
    authority = base.hasAuthority ? base.authority : base.host;
    if (path.startsWith('/')) {
      // java.net.URL keeps a rooted path's dot components as written.
      resolvedPath = path;
    } else if (path.isEmpty) {
      // A query-only relative reference takes the base directory; a
      // fragment-only one keeps the base path and query.
      resolvedPath = query != null ? _baseDirectory(base.path) : base.path;
    } else {
      final basePath = _baseDirectory(base.path);
      resolvedPath = _normalizeRawPath('$basePath$path');
    }
  }
  var outputQuery = query;
  // The base's own query is a `hasQuery` fact, not a `?` character somewhere in
  // the text: a fragment may hold one without the base carrying a query.
  if (outputQuery == null &&
      path.isEmpty &&
      fragment != null &&
      base.hasQuery) {
    outputQuery = base.query;
  }
  final output = StringBuffer('${base.scheme}://$authority$resolvedPath');
  if (outputQuery != null) output.write('?$outputQuery');
  if (fragment != null) output.write('#$fragment');
  return output.toString();
}

/// `AnalyzeUrl` binds the site root before the request's option script runs.
/// Keep the resolved authority text, including an explicitly written port.
String? sourceRequestOrigin(Uri base, String path) {
  final text = sourceUrlTextResolved(base, path);
  final origin = RegExp(
    r'^https?://[^/?#]+',
    caseSensitive: false,
  ).firstMatch(text)?.group(0);
  if (origin == null || Uri.tryParse(origin)?.host.isNotEmpty != true) {
    return null;
  }
  return origin;
}

/// The frozen `AnalyzeRule.getString(rule, isUrl = true)` text for one finished
/// rule result (`AnalyzeRule.kt:315-323`): an absolute value stays verbatim,
/// every other value goes through the native URL operation. A blank result is
/// the analyser's own base URL there, so callers answer that before asking.
String sourceUrlNativeText(String scalar, Uri base, {String? rawBase}) {
  // Only the frozen absolute shortcut trims; a relative result reaches the URL
  // constructor as the original text, exactly as the caller's rule wrote it.
  final trimmed = sourceKotlinTrim(scalar);
  if (Uri.tryParse(trimmed)?.hasScheme == true) return trimmed;
  return sourceUrlTextResolved(base, scalar, rawBase: rawBase);
}

String _resolveAgainstRawBase(String baseText, String raw) {
  final match = RegExp(
    r'^([A-Za-z][A-Za-z0-9+.-]*):\/\/([^/?#]*)([^?#]*)(\?[^#]*)?(#.*)?$',
  ).firstMatch(_javaUrlEdgeText(baseText));
  if (match == null) return raw;
  // The native URL object lower-cases its protocol and keeps the authority,
  // path and query as they were written.
  final scheme = match.group(1)!.toLowerCase();
  final authority = match.group(2)!;
  final basePath = match.group(3) ?? '';
  final baseQuery = match.group(4);
  var path = raw;
  String? query;
  String? fragment;
  final hash = path.indexOf('#');
  if (hash >= 0) {
    fragment = path.substring(hash + 1);
    path = path.substring(0, hash);
  }
  final question = path.indexOf('?');
  if (question >= 0) {
    query = path.substring(question + 1);
    path = path.substring(0, question);
  }
  String resolvedAuthority = authority;
  String resolvedPath;
  if (path.startsWith('//')) {
    final slash = path.indexOf('/', 2);
    resolvedAuthority = slash < 0
        ? path.substring(2)
        : path.substring(2, slash);
    resolvedPath = slash < 0 ? '' : path.substring(slash);
  } else if (path.startsWith('/')) {
    resolvedPath = path;
  } else if (path.isEmpty) {
    resolvedPath = query != null ? _baseDirectory(basePath) : basePath;
  } else {
    resolvedPath = _normalizeRawPath('${_baseDirectory(basePath)}$path');
  }
  var outputQuery = query;
  if (outputQuery == null &&
      path.isEmpty &&
      fragment != null &&
      baseQuery != null) {
    outputQuery = baseQuery.substring(1);
  }
  final output = StringBuffer('$scheme://$resolvedAuthority$resolvedPath');
  if (outputQuery != null) output.write('?$outputQuery');
  if (fragment != null) output.write('#$fragment');
  return output.toString();
}

String _baseDirectory(String path) {
  if (path.isEmpty) return '/';
  return path.endsWith('/')
      ? path
      : path.substring(0, path.lastIndexOf('/') + 1);
}

String _normalizeRawPath(String path) {
  final input = path.split('/');
  final parts = <String>[];
  for (var i = 0; i < input.length; i++) {
    final part = input[i];
    final last = i == input.length - 1;
    if (part == '.') {
      if (last) parts.add('');
      continue;
    }
    if (part == '..') {
      if (parts.length > 1 && parts.last != '..') {
        parts.removeLast();
        if (last) parts.add('');
      } else {
        parts.add('..');
      }
      continue;
    }
    parts.add(part);
  }
  if (parts.isEmpty) return '/';
  if (parts.first.isNotEmpty) parts.insert(0, '');
  final result = parts.join('/');
  return result.isEmpty ? '/' : result;
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
