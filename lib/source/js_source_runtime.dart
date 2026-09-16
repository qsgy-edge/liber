import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart';

import '../domain/contracts.dart';
import '../local/text_engine.dart';
import 'native_library.dart';
import 'source_host_dispatcher.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';

typedef SourceHostCall =
    Future<Object?> Function(
      String method,
      Object? payload,
      SourceCancellation cancellation,
    );

abstract interface class SourceScriptRuntime {
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,

    /// Rule state (`java.put`/`java.get`) shared by one source analysis. The
    /// frozen runtime scopes it to the rule data of the book being analysed.
    Map<String, Object?>? state,
  });
}

/// One `java.toast`/`java.log` message a source produced.
class SourceHostMessage {
  const SourceHostMessage(this.kind, this.message);
  final String kind;
  final String message;
}

class SourceScriptError implements Exception {
  const SourceScriptError(this.category, [this.message = '']);
  final String category;
  final String message;
  @override
  String toString() => message.isEmpty ? category : '$category: $message';
}

/// Shared libraries keep their engine and closures; each eval gets fresh bindings.
class InProcessSourceScriptRuntime implements SourceScriptRuntime {
  InProcessSourceScriptRuntime({
    this.maxScriptBytes = 64 * 1024,
    this.maxHostBytes = 8 * 1024 * 1024,
    this.maxOutputBytes = 8 * 1024 * 1024,
    this.memoryLimitBytes = 64 * 1024 * 1024,
    this.hostCall,
    this.dispatcher,
    this.jsLib = '',
  });
  final String jsLib;
  final int maxScriptBytes;
  final int maxHostBytes;
  final int maxOutputBytes;
  final int memoryLimitBytes;
  final SourceHostCall? hostCall;
  final SourceHostDispatcher? dispatcher;

  /// Messages a source logged or toasted during this runtime's lifetime.
  final messages = <SourceHostMessage>[];

  /// Cookies when no transport is attached; the dispatcher owns them otherwise.
  final SourceCookieJar fallbackCookies = SourceCookieJar();

  /// Frozen `CacheManager` storage, for this process only.
  static final Map<String, (Object?, int)> _cache = {};
  static int _active = 0;
  static Future<void> initialize({String? libraryPath}) =>
      NativeLibrary.initialize(libraryPath: libraryPath);
  static final _sessions = <(String, int), Future<_ScriptSession>>{};
  static Future<_ScriptSession> _shared(String library, int limit) {
    final key = (library, limit);
    final existing = _sessions.remove(key);
    if (existing != null) return _sessions[key] = existing;
    final evicted = _sessions.length >= 16
        ? _sessions.remove(_sessions.keys.first)
        : null;
    return _sessions[key] = () async {
      if (evicted != null) {
        final old = await evicted;
        await old.tail;
        await old.engine.close();
      }
      return _ScriptSession.create(library, limit);
    }();
  }

  static Future<void> dispose() async {
    if (_active != 0) throw StateError('Source executions are still active');
    for (final session in _sessions.values.toList()) {
      await (await session).engine.closeGracefully();
    }
    _sessions.clear();
    NativeLibrary.dispose();
  }

  @override
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
    Map<String, Object?>? state,
  }) async {
    final ruleState = state ?? <String, Object?>{};
    final cookies = dispatcher?.cookies ?? fallbackCookies;
    final encodedInput = jsonEncode(input);
    if (utf8.encode(source).length +
            utf8.encode(encodedInput).length +
            utf8.encode(jsLib).length >
        maxScriptBytes) {
      throw const SourceScriptError('input-cap');
    }
    if (timeout <= Duration.zero) throw const SourceScriptError('timeout');
    final token = SourceCancellation();
    final unsubscribe = cancellation?.listen(token.cancel);
    final host = dispatcher?.forExecution(token);
    final pending = <BigInt, Future<void>>{};
    SourceScriptError? hostFailure;
    Object? closeError;
    JsEngine? engine;
    _ScriptSession? session;
    Completer<void>? release;
    final sessionKey = (jsLib, memoryLimitBytes);
    Future<_ScriptSession>? sessionFuture;
    Future<void>? closing;
    BigInt? executionId;
    Future<void>? interrupting;
    void interruptExecution() {
      final id = executionId;
      if (id != null) {
        interrupting ??= cancelScopedExecutionGlobal(id: id).then<void>((_) {});
      }
    }

    Future<void> close() => closing ??= engine!.close().then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {
        closeError = e;
      },
    );
    final unlisten = token.listen(interruptExecution);
    _active++;
    try {
      token.throwIfCancelled();
      await initialize();
      sessionFuture = jsLib.isEmpty
          ? _ScriptSession.create(jsLib, memoryLimitBytes)
          : _shared(jsLib, memoryLimitBytes);
      session = await sessionFuture;
      final previous = session.tail;
      release = Completer<void>();
      session.tail = Future.wait([previous, release.future]).then<void>((_) {});
      engine = session.engine;
      token.throwIfCancelled();
      if (engine.closed) {
        throw const SourceScriptError('cancelled', 'shared runtime closed');
      }
      Future<void> perform(BridgeRequest request) async {
        JsResult result;
        try {
          token.throwIfCancelled();
          final value = request.value;
          if (value is! JsValue_String) {
            throw const SourceScriptError('host-input');
          }
          final encoded = value.field0;
          if (utf8.encode(encoded).length > maxHostBytes) {
            throw const SourceScriptError('host-input-cap');
          }
          final decoded = jsonDecode(encoded);
          if (decoded is! Map<String, dynamic>) {
            throw const SourceScriptError('host-input');
          }
          final method = decoded['method'];
          final payload = decoded['payload'];
          final Object? answer;
          if (method == 'getInput' && payload == null) {
            answer = input;
          } else if (method == 'echo') {
            answer = hostCall == null
                ? payload
                : await hostCall!(method, payload, token);
          } else if (method == 'state') {
            answer = _handleState(payload, ruleState);
          } else if (method == 'cache') {
            answer = _handleCache(payload);
          } else if (method == 'cookie') {
            answer = _handleCookie(payload, cookies);
          } else if (method == 'log') {
            answer = _handleLog(payload);
          } else if (method == 'url') {
            answer = _handleUrl(payload);
          } else if (method == 'convert') {
            answer = _handleConvert(payload);
          } else if (method == 'request') {
            answer = await _dispatch(host, payload, request.id, input, token);
          } else if (method == 'ajax') {
            answer = await _dispatch(
              host,
              {
                'method': 'GET',
                'url': payload,
                'headers': input['headers'] ?? const <String, String>{},
              },
              request.id,
              input,
              token,
            );
          } else {
            throw const SourceScriptError('host-method', 'method refused');
          }
          token.throwIfCancelled();
          final response = jsonEncode({'ok': true, 'value': answer});
          if (utf8.encode(response).length > maxHostBytes) {
            throw const SourceScriptError('host-output-cap');
          }
          result = JsResult.ok(JsValue.string(response));
        } catch (error) {
          if (error is JsError) {
            // Script failures remain catchable by the outer script. Policy and
            // I/O boundary failures below still terminate the execution.
            result = JsResult.err(error);
          } else {
            hostFailure = _classify(error);
            result = JsResult.err(JsError.bridge(hostFailure!.category));
          }
        }
        // Cancellation can win between encoding and native completion.
        try {
          if (!token.isCancelled) {
            await completeBridgeRequestGlobal(id: request.id, result: result);
          }
        } catch (error) {
          if (!token.isCancelled) hostFailure ??= _classify(error);
        }
      }

      // The deadline clock is Rust's (ADR 0009): the budget goes in with the
      // scope, Rust compares it inside the interrupt closure and on the parked
      // host wait, and it ends the execution whether or not this isolate gets
      // back to its event loop. `cancellation` still stops an execution early.
      executionId = await engine.createScopedExecution(
        deadlineMs: BigInt.from(timeout.inMilliseconds),
      );
      if (token.isCancelled) interruptExecution();
      session.starts[executionId] = (request) {
        // Never throw through FRB's non-fallible callback ABI.
        if (token.isCancelled) return;
        final work = perform(request);
        pending[request.id] = work;
        unawaited(
          work.then<void>((_) {
            pending.remove(request.id);
            session?.requestOwners.remove(request.id);
          }),
        );
      };
      session.cancels[executionId] = (id) async {
        token.cancel();
        await pending[id];
      };
      token.throwIfCancelled();
      final wrapped = _wrap(source, input);
      final result = (await engine.evalScoped(
        id: executionId,
        source: wrapped,
      )).value;
      token.throwIfCancelled();
      if (hostFailure != null) throw hostFailure!;
      if (utf8.encode(jsonEncode(result)).length > maxOutputBytes) {
        throw const SourceScriptError('output-cap');
      }
      return result;
    } catch (error) {
      // The Rust clock reports its own deadline as `JsError_Timeout`; this is
      // the category the pipeline saw when a Dart `Timer` held the clock.
      if (error is JsError_Timeout) throw const SourceScriptError('timeout');
      if (token.isCancelled) throw const SourceScriptError('cancelled');
      throw hostFailure ?? _classify(error);
    } finally {
      unsubscribe?.call();
      unlisten();
      final keepSession = jsLib.isNotEmpty && engine != null && !engine.closed;
      try {
        if (!keepSession) {
          if (identical(_sessions[sessionKey], sessionFuture)) {
            _sessions.remove(sessionKey);
          }
          if (engine != null) await close();
        }
        token.cancel();
        await interrupting;
        await Future.wait(pending.values.toList());
        if (executionId != null) {
          await discardScopedExecutionGlobal(id: executionId);
        }
        if (closeError != null) {
          throw const SourceScriptError('cleanup', 'engine cleanup failed');
        }
      } finally {
        if (executionId != null) {
          session?.starts.remove(executionId);
          session?.cancels.remove(executionId);
        }
        release?.complete();
        _active--;
      }
    }
  }

  /// Frozen `AnalyzeRule.put`/`get`, scoped to the rule data of one analysis.
  Object? _handleState(Object? payload, Map<String, Object?> state) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid state call');
    }
    final key = payload['key'];
    if (key is! String) {
      throw const SourceScriptError('host-input', 'invalid state key');
    }
    switch (payload['op']) {
      case 'get':
        final value = state[key];
        return value is String ? value : '';
      case 'put':
        final value = '${payload['value']}';
        state[key] = value;
        return value;
      default:
        throw const SourceScriptError('host-method', 'state op refused');
    }
  }

  /// Frozen `JsExtensions.t2s`/`s2t`, which call `ChineseUtils`. Both go through
  /// the same tables the reader converts with (ADR 0010), so a Book Source rule
  /// and the reader never disagree about a character.
  ///
  /// Synchronous on purpose: the frozen `java.t2s` returns a string a rule uses
  /// on the spot, and the bridge's conversion call is synchronous too.
  Object? _handleConvert(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid convert call');
    }
    final text = payload['text'];
    if (text is! String) {
      throw const SourceScriptError('host-input', 'invalid convert text');
    }
    switch (payload['direction']) {
      case 't2s':
        return TextEngine.t2s(text);
      case 's2t':
        return TextEngine.s2t(text);
      default:
        throw const SourceScriptError('host-method', 'convert direction refused');
    }
  }

  /// Frozen `CacheManager`. Values live for this process only: the baseline
  /// persists them, which this destination does not do yet.
  Object? _handleCache(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid cache call');
    }
    final key = payload['key'];
    if (key is! String) {
      throw const SourceScriptError('host-input', 'invalid cache key');
    }
    final entry = _cache[key];
    switch (payload['op']) {
      case 'put':
      case 'putMemory':
        final saveTime = payload['saveTime'];
        final seconds = saveTime is num ? saveTime.toInt() : 0;
        _cache[key] = (
          payload['value'],
          seconds <= 0
              ? 0
              : DateTime.now().millisecondsSinceEpoch + seconds * 1000,
        );
        return null;
      case 'get':
      case 'getFromMemory':
        if (entry == null) return null;
        final (value, expires) = entry;
        if (expires != 0 &&
            DateTime.now().millisecondsSinceEpoch > expires) {
          _cache.remove(key);
          return null;
        }
        return value;
      case 'getInt':
      case 'getLong':
      case 'getDouble':
        return entry?.$1;
      case 'delete':
      case 'deleteMemory':
        _cache.remove(key);
        return null;
      default:
        throw const SourceScriptError('host-method', 'cache op refused');
    }
  }

  /// Frozen `CookieStore`, over this session's jar.
  Object? _handleCookie(Object? payload, SourceCookieJar jar) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid cookie call');
    }
    final url = payload['url'];
    if (url is! String) {
      throw const SourceScriptError('host-input', 'invalid cookie url');
    }
    switch (payload['op']) {
      case 'getCookie':
        return jar.cookiesFor(url);
      case 'getKey':
        final key = payload['key'];
        if (key is! String) {
          throw const SourceScriptError('host-input', 'invalid cookie key');
        }
        return jar.value(url, key);
      case 'setCookie':
        jar.set(url, '${payload['cookie'] ?? ''}');
        return null;
      case 'replaceCookie':
        jar.replace(url, '${payload['cookie'] ?? ''}');
        return null;
      case 'removeCookie':
        jar.remove(url);
        return null;
      default:
        throw const SourceScriptError('host-method', 'cookie op refused');
    }
  }

  /// Frozen `JsURL`: the frozen `java.toURL` parses with `java.net.URL`. QuickJS
  /// has no `URL` global, so the parse happens here. Query values are decoded
  /// like the frozen constructor does; keys are not, and a pair without `=`
  /// yields an empty value instead of failing.
  Object? _handleUrl(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid url call');
    }
    final raw = payload['url'];
    if (raw is! String) {
      throw const SourceScriptError('host-input', 'invalid url');
    }
    final base = payload['baseUrl'];
    final Uri resolved;
    try {
      final parsed = SourceHttpUri.parse(raw);
      resolved = base is String && base.isNotEmpty
          ? SourceHttpUri.parse(base).resolve(raw)
          : parsed;
    } on FormatException {
      throw SourceScriptError('host-input', 'invalid url: $raw');
    }
    if (resolved.host.isEmpty) {
      throw SourceScriptError('host-input', 'invalid url: $raw');
    }
    final searchParams = <String, String>{};
    if (resolved.hasQuery) {
      for (final pair in resolved.query.split('&')) {
        final equals = pair.indexOf('=');
        final name = equals < 0 ? pair : pair.substring(0, equals);
        final value = equals < 0 ? '' : pair.substring(equals + 1);
        searchParams[name] = Uri.decodeComponent(value);
      }
    }
    final port = resolved.hasPort ? ':${resolved.port}' : '';
    return {
      'host': resolved.host,
      'origin': '${resolved.scheme}://${resolved.host}$port',
      'pathname': resolved.path,
      'searchParams': searchParams,
    };
  }

  /// Frozen `java.log`/`toast`/`longToast`/`logType`. This product has no source
  /// debug console, so the messages are recorded for the caller instead.
  Object? _handleLog(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid log call');
    }
    final message = payload['message'];
    messages.add(
      SourceHostMessage('${payload['kind'] ?? 'log'}', '$message'),
    );
    return message;
  }

  static SourceScriptError _classify(Object error) {
    if (error is SourceScriptError) return error;
    if (error is SourceRequestCancelled) {
      return const SourceScriptError('cancelled');
    }
    if (error is SourceIoLimitExceeded) {
      return SourceScriptError('${error.direction}-cap');
    }
    if (error is TimeoutException) return const SourceScriptError('timeout');
    if (error is FormatException || error is ArgumentError) {
      return const SourceScriptError('host-input');
    }
    if (error is IOException) return const SourceScriptError('network');
    if (error is JsError_Cancelled) return const SourceScriptError('cancelled');
    if (error is JsError) return const SourceScriptError('js');
    return const SourceScriptError('host');
  }

  static String _wrap(String source, Map<String, Object?> input) =>
      '__liberRun(($_facade)(${jsonEncode(input)}), ${jsonEncode(source)})';

  Future<Object?> _dispatch(
    SourceHostDispatcher? host,
    Object? payload,
    BigInt requestId,
    Map<String, Object?> outerInput,
    SourceCancellation token,
  ) async {
    if (host == null || payload is! Map) {
      throw const SourceScriptError('host-method', 'request unavailable');
    }
    final method = payload['method'];
    final rawUrl = payload['url'];
    if (method is! String || rawUrl is! String) {
      throw const SourceScriptError('host-input', 'invalid request');
    }
    final url = await expandSourceUrl(rawUrl, (script, result) async {
      token.throwIfCancelled();
      final value = await evalBridgeRequestGlobal(
        id: requestId,
        source: _wrap(script, {
          'sourceKey': outerInput['sourceKey'],
          'source': outerInput['source'],
          'headers': outerInput['headers'],
          'key': null,
          'page': null,
          'baseUrl': '',
          'result': result,
        }),
      );
      token.throwIfCancelled();
      final decoded = value.value;
      if (utf8.encode(jsonEncode(decoded)).length > maxHostBytes) {
        throw const SourceScriptError('host-output-cap');
      }
      return decoded;
    });
    if (url.contains(',{') || url.contains(', {')) {
      throw const SourceScriptError(
        'host-input',
        'nested URL options unsupported',
      );
    }
    final rawHeaders = payload['headers'] ?? const <String, String>{};
    if (rawHeaders is! Map ||
        rawHeaders.entries.any((e) => e.key is! String || e.value is! String)) {
      throw const SourceScriptError('host-input', 'invalid headers');
    }
    final headers = Map<String, String>.from(rawHeaders);
    final body = payload['body'];
    if (body != null && body is! String) {
      throw const SourceScriptError('host-input');
    }
    final response = switch (method) {
      'GET' => await host.get(url, headers: headers),
      'HEAD' => await host.head(url, headers: headers),
      'POST' => await host.post(url, body as String? ?? '', headers: headers),
      'connect' => await host.connect(url, headers: headers),
      _ => throw const SourceScriptError('host-method', 'HTTP method refused'),
    };
    return {
      'statusCode': response.statusCode,
      'headers': response.headers,
      'body': response.body,
      'url': response.url.toString(),
    };
  }

  /// The JavaScript surface one source sees: the frozen runtime's bindings
  /// (`AnalyzeUrl.buildScriptBindings` plus `JsExtensions`), with the host
  /// half bridged into Dart.
  static const _facade = r'''
(input) => {
  const bridge = fjs.bridge_call;
  const call = (method, payload) =>
    JSON.parse(bridge(JSON.stringify({method: method, payload: payload}))).value;
  function request(method, url, body, headers) {
    const result = JSON.parse(bridge(JSON.stringify({method:'request', payload:{
      method, url:String(url), body, headers:headers || input.headers || {}
    }}))).value;
    return Object.freeze({
      body: () => result.body,
      code: () => result.statusCode,
      url: () => result.url,
      headers: () => result.headers,
      raw: () => Object.freeze({request: () => Object.freeze({url: () => result.url})})
    });
  }

  const utf8Encode = text => {
    const out = [];
    for (const ch of text) {
      const code = ch.codePointAt(0);
      if (code < 0x80) out.push(code);
      else if (code < 0x800) out.push(0xc0 | (code >> 6), 0x80 | (code & 63));
      else if (code < 0x10000) out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
      else out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 63), 0x80 | ((code >> 6) & 63), 0x80 | (code & 63));
    }
    return out;
  };
  const utf8Decode = bytes => {
    let out = '';
    let index = 0;
    while (index < bytes.length) {
      const first = bytes[index] & 0xff;
      let code = first;
      let extra = 0;
      if (first >= 0xf0) { code = first & 7; extra = 3; }
      else if (first >= 0xe0) { code = first & 15; extra = 2; }
      else if (first >= 0xc0) { code = first & 31; extra = 1; }
      let valid = true;
      if (index + extra >= bytes.length) valid = false;
      else {
        for (let k = 1; k <= extra; k++) {
          const next = bytes[index + k] & 0xff;
          if ((next & 0xc0) !== 0x80) { valid = false; break; }
          code = (code << 6) | (next & 63);
        }
      }
      if (!valid) { out += '\ufffd'; index += 1; continue; }
      out += String.fromCodePoint(code);
      index += extra + 1;
    }
    return out;
  };
  const base64Encode = (bytes, flags) => {
    const standard = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const urlSafe = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    const alphabet = (flags & 8) ? urlSafe : standard;
    let out = '';
    for (let index = 0; index < bytes.length; index += 3) {
      const a = bytes[index] & 0xff;
      const b = index + 1 < bytes.length ? bytes[index + 1] & 0xff : null;
      const c = index + 2 < bytes.length ? bytes[index + 2] & 0xff : null;
      out += alphabet[a >> 2];
      out += alphabet[((a & 3) << 4) | (b === null ? 0 : b >> 4)];
      out += b === null ? '=' : alphabet[((b & 15) << 2) | (c === null ? 0 : c >> 6)];
      out += c === null ? '=' : alphabet[c & 63];
    }
    if (flags & 1) out = out.replace(/=+$/, '');
    if (!(flags & 2)) {
      const breakLine = (flags & 4) ? '\r\n' : '\n';
      let wrapped = '';
      for (let index = 0; index < out.length; index += 76) {
        wrapped += (index === 0 ? '' : breakLine) + out.substring(index, index + 76);
      }
      out = wrapped;
    }
    return out;
  };
  const base64Decode = (text, flags) => {
    const standard = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
    const cleaned = String(text).replace(/\s+/g, '');
    const out = [];
    let buffer = 0;
    let bits = 0;
    for (const ch of cleaned) {
      if (ch === '=') break;
      let value = standard.indexOf(ch);
      if (value < 0 && ch === '-') value = 62;
      if (value < 0 && ch === '_') value = 63;
      if (value < 0) throw new Error('invalid base64');
      buffer = (buffer << 6) | value;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xff);
      }
    }
    return out;
  };
  const hexDecode = hex => {
    const text = String(hex).replace(/\s+/g, '');
    if (text.length % 2 !== 0) throw new Error('invalid hex');
    const out = [];
    for (let index = 0; index < text.length; index += 2) {
      const byte = parseInt(text.substring(index, index + 2), 16);
      if (Number.isNaN(byte)) throw new Error('invalid hex');
      out.push(byte);
    }
    return out;
  };

  const sourceFields = input.source || {};
  const source = Object.freeze({
    ...sourceFields,
    getKey: () => input.sourceKey,
    getName: () => sourceFields.bookSourceName || '',
    getTag: () => sourceFields.bookSourceName || '',
    getVariable: () => call('cache', {op:'get', key:'sourceVariable_' + input.sourceKey}) || '',
    put: (key, value) => call('cache', {op:'put', key:'v_' + input.sourceKey + '_' + key, value:String(value)}),
    get: key => call('cache', {op:'get', key:'v_' + input.sourceKey + '_' + key}) || ''
  });

  const pad = (value, size) => String(value).padStart(size, '0');
  const numeric = value => {
    if (value === null || value === undefined) return null;
    const parsed = Number(value);
    return Number.isNaN(parsed) ? null : parsed;
  };
  const formatPattern = (format, values) => {
    let out = format;
    for (const key of ['yyyy', 'MM', 'dd', 'HH', 'mm', 'ss']) {
      out = out.split(key).join(values[key]);
    }
    return out;
  };
  const formatTime = (date, format, offsetHours) => {
    if (!offsetHours) {
      return formatPattern(format, {
        yyyy: String(date.getFullYear()), MM: pad(date.getMonth() + 1, 2),
        dd: pad(date.getDate(), 2), HH: pad(date.getHours(), 2),
        mm: pad(date.getMinutes(), 2), ss: pad(date.getSeconds(), 2)
      });
    }
    const shifted = new Date(date.getTime() + offsetHours * 3600000);
    return formatPattern(format, {
      yyyy: String(shifted.getUTCFullYear()), MM: pad(shifted.getUTCMonth() + 1, 2),
      dd: pad(shifted.getUTCDate(), 2), HH: pad(shifted.getUTCHours(), 2),
      mm: pad(shifted.getUTCMinutes(), 2), ss: pad(shifted.getUTCSeconds(), 2)
    });
  };
  const uuid = () => {
    const hex = '0123456789abcdef';
    let out = '';
    for (let index = 0; index < 32; index++) {
      out += hex[Math.floor(Math.random() * 16)];
      if (index === 7 || index === 11 || index === 15 || index === 19) out += '-';
    }
    return out;
  };
  const toUrl = (url, baseUrl) => {
    const parsed = call('url', {url: url, baseUrl: baseUrl});
    if (parsed === null || parsed === undefined) throw new Error('invalid url: ' + url);
    return Object.freeze({
      host: parsed.host,
      origin: parsed.origin,
      pathname: parsed.pathname,
      searchParams: parsed.searchParams
    });
  };
  const toNumChapter = text => {
    const match = /(第)(.+?)(章)/.exec(text);
    if (!match) return text;
    let digits = '';
    for (const ch of match[2]) {
      const code = ch.charCodeAt(0);
      digits += (code >= 0xff10 && code <= 0xff19)
        ? String.fromCharCode(code - 0xfee0)
        : ch;
    }
    return match[1] + digits + match[3];
  };
  const encodeUriJava = text => {
    let out = '';
    for (const byte of utf8Encode(text)) {
      const ch = String.fromCharCode(byte);
      if ((byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
          (byte >= 97 && byte <= 122) ||
          ch === '.' || ch === '-' || ch === '*' || ch === '_') {
        out += ch;
      } else if (ch === ' ') {
        out += '+';
      } else {
        out += '%' + byte.toString(16).toUpperCase().padStart(2, '0');
      }
    }
    return out;
  };
  const htmlFormat = html => {
    const stripped = html
      .replace(/(&nbsp;)+/g, ' ')
      .replace(/(&ensp;|&emsp;)/g, ' ')
      .replace(/(&thinsp;|&zwnj;|&zwj;|\u2009|\u200C|\u200D)/g, '')
      .replace(/<\/?(?:div|p|br|hr|h\d|article|dd|dl)[^>]*>/g, '\n')
      .replace(/<!--[^>]*-->/g, '')
      .replace(/<\/?(?!img)[a-zA-Z]+(?=[ >])[^<>]*>/g, '');
    const formatted = stripped
      .replace(/\s*\n+\s*/g, '\n\u3000\u3000')
      .replace(/^[\n\s]+/, '\u3000\u3000')
      .replace(/[\n\s]+$/, '');
    return formatted.replace(
      /<img[^>]*\ssrc\s*=\s*"([^"{>]*\{(?:[^{}]|\{[^}>]+\})+\})"[^>]*>|<img[^>]*\sdata-[^=>]*=\s*"([^">]*)"[^>]*>|<img[^>]*\ssrc\s*=\s*"([^">]*)"[^>]*>/gi,
      (match, templated, dataAttr, plain) => {
        const raw = templated || dataAttr || plain || '';
        const split = /\s*,\s*(?=\{)/.exec(raw);
        const src = split ? raw.substring(0, split.index) : raw;
        const option = split ? ',' + raw.substring(split.index + split[0].length) : '';
        return '<img src="' + src + option + '">';
      });
  };

  const java = Object.freeze({
    connect: (url, headers) => request('connect', url, null, headers),
    ajax: url => call('ajax', String(url)).body,
    get: (urlOrKey, headers) => headers === undefined
      ? call('state', {op:'get', key:String(urlOrKey)})
      : request('GET', urlOrKey, null, headers),
    head: (url, headers) => request('HEAD', url, null, headers),
    post: (url, body, headers) => request('POST', url, body, headers),
    put: (key, value) => call('state', {op:'put', key:String(key), value:String(value)}),
    toast: message => { call('log', {kind:'toast', message:String(message)}); },
    longToast: message => { call('log', {kind:'longToast', message:String(message)}); },
    log: message => call('log', {kind:'log', message: message === undefined ? 'undefined' : String(message)}),
    logType: value => call('log', {kind:'logType', message: value === null ? 'null' : typeof value}),
    strToBytes: (text, charset) => {
      if (charset && String(charset).toUpperCase() !== 'UTF-8') throw new Error('unsupported charset: ' + charset);
      return utf8Encode(String(text)).map(byte => (byte > 127 ? byte - 256 : byte));
    },
    bytesToStr: (bytes, charset) => {
      if (charset && String(charset).toUpperCase() !== 'UTF-8') throw new Error('unsupported charset: ' + charset);
      const unsigned = [];
      for (const byte of bytes) unsigned.push(byte & 0xff);
      return utf8Decode(unsigned);
    },
    base64Encode: (text, flags) => base64Encode(utf8Encode(String(text)), flags === undefined ? 2 : flags),
    base64Decode: (text, arg) => typeof arg === 'string'
      ? utf8Decode(base64Decode(String(text), 0))
      : utf8Decode(base64Decode(String(text), arg === undefined ? 0 : arg)),
    base64DecodeToByteArray: (text, flags) =>
      (text === null || text === undefined || String(text) === '')
        ? null
        : base64Decode(String(text), flags === undefined ? 0 : flags).map(byte => (byte > 127 ? byte - 256 : byte)),
    hexEncodeToString: text => utf8Encode(String(text)).map(byte => byte.toString(16).padStart(2, '0')).join(''),
    hexDecodeToString: hex => utf8Decode(hexDecode(String(hex))),
    hexDecodeToByteArray: hex => hexDecode(String(hex)).map(byte => (byte > 127 ? byte - 256 : byte)),
    encodeURI: (text, enc) => {
      if (enc && String(enc).toUpperCase() !== 'UTF-8') return '';
      return encodeUriJava(String(text));
    },
    t2s: text => call('convert', {direction:'t2s', text:String(text)}),
    s2t: text => call('convert', {direction:'s2t', text:String(text)}),
    htmlFormat: html => htmlFormat(String(html)),
    timeFormat: time => formatTime(new Date(Number(time)), 'yyyy-MM-dd HH:mm:ss', 0),
    timeFormatUTC: (time, format, sh) => formatTime(new Date(Number(time)), String(format), Number(sh) || 0),
    randomUUID: () => uuid(),
    toNumChapter: text => (text === null || text === undefined) ? null : toNumChapter(String(text)),
    toURL: (url, baseUrl) => toUrl(String(url), (baseUrl === undefined || baseUrl === null) ? null : String(baseUrl))
  });

  const cookie = Object.freeze({
    setCookie: (url, value) => { call('cookie', {op:'setCookie', url:String(url), cookie:String(value)}); },
    replaceCookie: (url, value) => { call('cookie', {op:'replaceCookie', url:String(url), cookie:String(value)}); },
    getCookie: url => call('cookie', {op:'getCookie', url:String(url)}),
    getKey: (url, key) => call('cookie', {op:'getKey', url:String(url), key:String(key)}),
    removeCookie: url => { call('cookie', {op:'removeCookie', url:String(url)}); }
  });

  const cache = Object.freeze({
    put: (key, value, saveTime) => {
      call('cache', {op:'put', key:String(key), value:value, saveTime: saveTime === undefined ? 0 : saveTime});
    },
    putMemory: (key, value) => { call('cache', {op:'putMemory', key:String(key), value:value}); },
    get: key => call('cache', {op:'get', key:String(key)}),
    getFromMemory: key => call('cache', {op:'getFromMemory', key:String(key)}),
    getInt: key => numeric(call('cache', {op:'getInt', key:String(key)})),
    getLong: key => numeric(call('cache', {op:'getLong', key:String(key)})),
    getDouble: key => numeric(call('cache', {op:'getDouble', key:String(key)})),
    delete: key => { call('cache', {op:'delete', key:String(key)}); },
    deleteMemory: key => { call('cache', {op:'deleteMemory', key:String(key)}); }
  });

  return {key:null, page:null, book:null, result:null, speakText:null, speakSpeed:null,
    ...input, __LIBER_INPUT__: input, source, java, cookie, cache};
}
''';
}

class _ScriptSession {
  _ScriptSession(this.engine);
  final JsEngine engine;
  Future<void> tail = Future<void>.value();
  final starts = <BigInt, void Function(BridgeRequest)>{};
  final cancels = <BigInt, Future<void> Function(BigInt)>{};
  final requestOwners = <BigInt, BigInt>{};

  static Future<_ScriptSession> create(String library, int memoryLimit) async {
    final engine = await JsEngine.create(
      builtins: JsBuiltinOptions.none(),
      runtimeOptions: JsEngineRuntimeOptions(
        memoryLimit: BigInt.from(memoryLimit),
      ),
    );
    final session = _ScriptSession(engine);
    try {
      await engine.initBroker(
        start: (request) {
          final active = session.starts[request.executionId];
          if (active != null) {
            session.requestOwners[request.id] = request.executionId!;
            active(request);
          } else {
            unawaited(
              completeBridgeRequestGlobal(
                id: request.id,
                result: const JsResult.err(
                  JsError.bridge('No active execution'),
                ),
              ).catchError((Object _) {}),
            );
          }
        },
        cancel: (id) async {
          await session.cancels[session.requestOwners[id]]?.call(id);
        },
      );
      await engine.eval(
        options: JsEvalOptions(strict: false),
        source: JsCode.code(
          'globalThis.__liberRun = (function(){ let run; const create = function(){\n$library\n'
          'const __read = __liberLookupName => eval(__liberLookupName);\n'
          'return function(__scope, __code){\n'
          'const __bindings = new Proxy(__scope, {\n'
          'has: (target, name) => { if (typeof name !== "string" || name === "eval" || name === "__code") return false; '
          'if (Reflect.has(target,name)) return true; try { __read(name); return true; } catch(e) { if (e instanceof ReferenceError) return false; throw e; } },\n'
          'get: (target,name) => typeof name === "symbol" ? undefined : Reflect.has(target,name) ? target[name] : __read(name),\n'
          'set: (target,name,value) => Reflect.set(target,name,value)\n'
          '}); with(__bindings){ return eval(__code); } };\n}; '
          'return function(scope,code){ if (!run) run=create(); return run.call(scope,scope,code); }; })();',
        ),
      );
      return session;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }
}
