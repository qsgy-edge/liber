import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart';

import '../domain/contracts.dart';
import '../local/text_engine.dart';
import 'book_source_webview_adapter.dart';
import 'http_source_transport.dart' show sourceDefaultUserAgent;
import 'native_library.dart';
import 'source_host_dispatcher.dart';
import 'source_host_state.dart';
import 'source_http_uri.dart';
import 'source_url_rules.dart';

typedef SourceHostCall =
    Future<Object?> Function(
      String method,
      Object? payload,
      SourceCancellation cancellation,
    );

/// One stage response as the pipeline reads it and as a source's `loginCheckJs`
/// sees it.
///
/// It is the frozen `StrResponse` (`help/http/StrResponse.kt`): the body the
/// stage's rules parse, the URL the request resolved to, and — for a script
/// that reads them — the status and headers. [toJson] is the same response as
/// the JavaScript boundary carries it, and the shape the check script's
/// `result.body()`/`result.url()`/`result.headers()` accessors read.
class SourceStageResponse {
  const SourceStageResponse({
    required this.body,
    required this.url,
    this.statusCode = 200,
    this.headers = const {},
  });

  /// The frozen `StrResponse(analyzeUrl.url, body)` a rendered document comes
  /// back as (`BackstageWebView`): status 200 and no headers, because the
  /// frozen WebView path has no HTTP response of its own to report.
  factory SourceStageResponse.webView({required String body, required Uri url}) =>
      SourceStageResponse(body: body, url: url);

  /// The response a `loginCheckJs` returned, as the script's payload crossed
  /// the boundary. A value that is not a response never reaches this — the
  /// frozen cast `as StrResponse` is what it fails — so a payload that does not
  /// carry a response's fields is a boundary error.
  factory SourceStageResponse.fromJson(Object? value) {
    if (value is! Map) {
      throw const SourceScriptError(
        'host-input',
        'loginCheckJs must return a response object',
      );
    }
    final body = value['body'];
    final url = value['url'];
    if (body is! String || url is! String) {
      throw const SourceScriptError(
        'host-input',
        'loginCheckJs must return a response object',
      );
    }
    final status = value['statusCode'];
    final headers = value['headers'];
    return SourceStageResponse(
      body: body,
      url: SourceHttpUri.parse(url),
      statusCode: status is num ? status.toInt() : 200,
      headers: headers is Map
          ? {
              for (final entry in headers.entries)
                if (entry.value is List)
                  '${entry.key}': [
                    for (final item in entry.value as List) '$item',
                  ],
            }
          : const {},
    );
  }

  final String body;
  final Uri url;
  final int statusCode;

  /// The response's header values by name, as the transport reported them.
  final Map<String, List<String>> headers;

  Map<String, Object?> toJson() => {
    'statusCode': statusCode,
    'headers': headers,
    'body': body,
    'url': '$url',
  };
}

/// The two things only the pipeline can do for a `loginCheckJs` hook.
///
/// The frozen check script's `java` is the stage's own `AnalyzeUrl`
/// (`AnalyzeUrl.kt:139,465-526`): `java.getStrResponse()`/`java.getResponse()`
/// repeat the request the stage made, and `java.initUrl()` re-runs its address
/// analysis. The runtime owns the `java` surface and the pipeline owns the
/// request, so the pipeline hands both operations over for the duration of one
/// check.
class SourceStageRequest {
  const SourceStageRequest({required this.resend, required this.reanalyze});

  /// Sends the stage's current request again and answers its response.
  final Future<SourceStageResponse> Function() resend;

  /// Re-runs the address analysis of the stage's own address text.
  final Future<void> Function() reanalyze;
}

abstract interface class SourceScriptRuntime {
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  });

  /// Evaluates one source's `loginCheckJs` against one stage response — the
  /// frozen `res = analyzeUrl.evalJS(checkJs, res) as StrResponse`
  /// (`WebBook.kt:71,121,178,253,336`).
  ///
  /// [input] is the same binding set a rule script of that stage gets, with the
  /// stage response as `result`; [stage] is what `java.getStrResponse()`,
  /// `java.getResponse()` and `java.initUrl()` reach. A script that throws, or
  /// whose value is not a response, fails the stage.
  Future<SourceStageResponse> evaluateLoginCheck({
    required String script,
    required Map<String, Object?> input,
    required SourceStageRequest stage,
    required Duration timeout,
    SourceCancellation? cancellation,
  });
}

/// One `java.toast`/`java.log` message a source produced, one refusal it
/// asked for, or one `loginCheckJs` failure the source log has to keep.
class SourceHostMessage {
  const SourceHostMessage(this.kind, this.message);
  final String kind;
  final String message;
}

/// The bound on one source's message log. ADR 0011 §6 says the log is
/// "bounded" and does not fix a number: 200 is this product's choice. The
/// newest entries are kept and the oldest dropped, so a runaway `java.log`
/// loop cannot grow the process's memory; the log is in memory only and
/// persisted growth is #37's.
const sourceMessageLogLimit = 200;

/// The minimum interval between the two *displayed* notices of one source
/// (ADR 0011 §6: `toast`/`longToast` are "shown rate-limited"). Every notice is
/// recorded in the log; only the user-facing delivery is limited.
const sourceNoticeWindowMillis = 3000;

/// The rate limit on a source's user-facing notices: at most one delivery per
/// [windowMillis], so a source that repeats itself cannot flood the user. Every
/// message is recorded in the log whether or not it is delivered.
class SourceNoticeLimiter {
  SourceNoticeLimiter({this.windowMillis = sourceNoticeWindowMillis});

  final int windowMillis;
  int? _lastDeliveredAt;

  /// Whether a notice that arrives at [nowMillis] may be shown.
  bool allows(int nowMillis) {
    final last = _lastDeliveredAt;
    if (last != null && nowMillis - last < windowMillis) return false;
    _lastDeliveredAt = nowMillis;
    return true;
  }
}

/// The store key one rule variable lives under: the frozen `BaseSource`
/// variables (`BaseSource.kt:220-233`) that `java.get`/`java.put`,
/// `source.get`/`source.put` and the rule-field `@get:`/`@put:` all read and
/// write. One spelling, because a source that writes a variable one way must
/// read it back the other.
String sourceRuleVariableKey(String sourceRef, String key) =>
    'v_${sourceRef}_$key';

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
    this.androidId = '',
    this.onMessage,
    SourceHostState? hostState,
    this.webViewFactory,
  }) : _providedState = hostState;
  final String jsLib;

  /// The installation's opaque `androidId` this runtime answers `java.androidId`
  /// with (ADR 0011 §6), or an empty string when the caller has no installation
  /// (a gate or a tool). It is never a platform identifier.
  final String androidId;

  /// Where a user-facing `toast`/`longToast` notice goes, when the caller wants
  /// to show it. The runtime has already rate-limited the delivery
  /// ([sourceNoticeWindowMillis]); every message is recorded in [messages]
  /// whether or not this is called. Defaults to no-op so existing callers are
  /// untouched.
  final void Function(SourceHostMessage message)? onMessage;
  final int maxScriptBytes;
  final int maxHostBytes;
  final int maxOutputBytes;
  final int memoryLimitBytes;
  final SourceHostCall? hostCall;
  final SourceHostDispatcher? dispatcher;
  final SourceHostState? _providedState;

  /// The rendered-document adapter factory the `java.webView*` helpers use. Null
  /// builds one from [dispatcher]'s source scope; a test substitutes its own,
  /// because the helpers' wiring is what it checks.
  final BookSourceWebViewAdapterFactory? webViewFactory;

  /// The host surface this runtime reads and writes (ADR 0011 §3): what the
  /// caller passed, the dispatcher's when a transport is attached — the
  /// pipelines wire one state into both — or one of its own, which is what the
  /// gates and the tools run on.
  late final SourceHostState hostState =
      _providedState ?? dispatcher?.hostState ?? SourceHostState();

  /// Messages a source logged or toasted during this runtime's lifetime, newest
  /// last, capped at [sourceMessageLogLimit] entries.
  final messages = <SourceHostMessage>[];

  final _noticeLimiter = SourceNoticeLimiter();

  /// Frozen `CacheManager` storage used to be a process-wide map here; it is
  /// the space's now ([SourceHostState]), which is what makes an entry belong to
  /// the source that wrote it.
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
  }) => _evaluate(
    source: source,
    input: input,
    timeout: timeout,
    cancellation: cancellation,
  );

  @override
  Future<SourceStageResponse> evaluateLoginCheck({
    required String script,
    required Map<String, Object?> input,
    required SourceStageRequest stage,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async {
    try {
      final value = await _evaluate(
        source: script,
        input: input,
        timeout: timeout,
        cancellation: cancellation,
        checkResponse: true,
        stage: stage,
      );
      return SourceStageResponse.fromJson(value);
    } catch (error) {
      // The frozen `evalJS` throws straight through the `as StrResponse` cast
      // and the stage fails; this product keeps the script's own message, puts
      // it in the source's log, and shows it as a source notice, so a source
      // that fails at a stage says why. A failure happens at most once per
      // stage, so the toast rate limit does not apply to it.
      final failure = error is SourceScriptError ? error : _classify(error);
      final message = SourceHostMessage('loginCheckJs', '$failure');
      _record(message);
      onMessage?.call(message);
      throw failure;
    }
  }

  Future<Object?> _evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
    bool checkResponse = false,
    SourceStageRequest? stage,
  }) async {
    final sourceRef = input['sourceKey'] is String
        ? input['sourceKey'] as String
        : '';
    // A cookie or a cache entry another run wrote is on disk until it is read
    // back, and the jar's reads inside one JavaScript call are synchronous.
    // Loading the space's state once here is what makes the synchronous reads
    // see what the last run wrote (ADR 0011 §3); a state with nothing to load
    // skips the wait.
    if (!hostState.isLoaded) await hostState.ready();
    final cookies = dispatcher?.cookies ?? hostState.cookiesFor(sourceRef);
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
            answer = await _handleState(payload, sourceRef);
          } else if (method == 'headers') {
            answer = await _headers(input, request.id, token);
          } else if (method == 'cache') {
            answer = await _handleCache(payload, sourceRef);
          } else if (method == 'cookie') {
            answer = await _handleCookie(payload, cookies);
          } else if (method == 'log') {
            answer = _handleLog(payload);
          } else if (method == 'identity') {
            answer = androidId;
          } else if (method == 'userAgent') {
            answer = sourceDefaultUserAgent;
          } else if (method == 'refuse') {
            throw _handleRefusal(payload);
          } else if (method == 'url') {
            answer = _handleUrl(payload);
          } else if (method == 'webview') {
            answer = await _handleWebView(payload, request.id, input, token);
          } else if (method == 'convert') {
            answer = _handleConvert(payload);
          } else if (method == 'request') {
            answer = await _dispatch(host, payload, request.id, input, token);
          } else if (method == 'ajax') {
            answer = await _handleAjax(host, payload, request.id, input, token);
          } else if (method == 'ajaxAll') {
            answer = await _handleAjaxAll(
              host,
              payload,
              request.id,
              input,
              token,
            );
          } else if (method == 'stageResend') {
            answer = await _handleStageResend(stage);
          } else if (method == 'stageInitUrl') {
            answer = await _handleStageInitUrl(stage);
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
            // A refusal is the source's only view of the policy, so its message
            // names the member and the policy instead of the bare category; the
            // reason is also in the source log.
            result = JsResult.err(
              hostFailure!.category == 'policy'
                  ? JsError.bridge(hostFailure!.message)
                  : JsError.bridge(hostFailure!.category),
            );
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
      final wrapped = _wrap(source, input, checkResponse: checkResponse);
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
      throw hostFailure ??
          (checkResponse ? _classifyCheck(error) : _classify(error));
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

  /// Frozen `java.put`/`java.get`: the baseline's persistent per-source
  /// variables, `v_<sourceKey>_<key>` (`BaseSource.kt:220-233`), which
  /// `source.put`/`source.get` share. They are not one analysis's rule state
  /// any more (ADR 0011 §3): a source reads them again in the next analysis and
  /// after a restart, and no other source reads them at all.
  Future<Object?> _handleState(Object? payload, String sourceRef) async {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid state call');
    }
    final key = payload['key'];
    if (key is! String) {
      throw const SourceScriptError('host-input', 'invalid state key');
    }
    final variable = sourceRuleVariableKey(sourceRef, key);
    switch (payload['op']) {
      case 'get':
        final value = await hostState.entry(sourceRef, variable);
        return value is String ? value : '';
      case 'put':
        final value = '${payload['value']}';
        await hostState.putEntry(sourceRef, variable, value);
        return value;
      default:
        throw const SourceScriptError('host-method', 'state op refused');
    }
  }

  /// Frozen `JsExtensions.webView`, `webViewGetSource` and
  /// `webViewGetOverrideUrl` (`JsExtensions.kt:161-213`): a rendered document, a
  /// matched resource URL or a matched navigation URL.
  ///
  /// Each returns the frozen `StrResponse.body`, which is what the helpers hand
  /// back. They run outside the source rate limiter, as the frozen direct
  /// helpers do (`AnalyzeUrl` is what wraps its own operation in `withLimit`),
  /// and each is its own operation with its own WebView.
  Future<Object?> _handleWebView(
    Object? payload,
    BigInt requestId,
    Map<String, Object?> outerInput,
    SourceCancellation token,
  ) async {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid webView call');
    }
    final factory = webViewFactory ?? _defaultWebViewFactory();
    if (factory == null) {
      throw const SourceScriptError(
        'host-method',
        'webView is unavailable without a source session',
      );
    }
    String? text(Object? value) => value == null ? null : '$value';
    final operation = '${payload['op']}';
    final rawHeaders = await _headers(outerInput, requestId, token);
    final headers = <String, String>{
      for (final entry in rawHeaders.entries)
        if (entry.value != null) entry.key: entry.value!,
    };
    final adapter = factory.create();
    final unsubscribe = token.listen(adapter.destroy);
    try {
      final response = await adapter.load(
        SourceWebViewRequest(
          url: text(payload['url']),
          html: text(payload['html']),
          headers: headers,
          javaScript: text(payload['js']),
          sourceRegex: operation == 'source' ? text(payload['regex']) : null,
          overrideUrlRegex: operation == 'override'
              ? text(payload['regex'])
              : null,
        ),
      );
      return response.body;
    } on SourceWebViewCancelled {
      throw const SourceRequestCancelled();
    } finally {
      unsubscribe();
      adapter.destroy();
    }
  }

  /// The factory the direct helpers derive from the session's own source scope:
  /// its key, its jar's page-cookie sink and its TLS policy (ADR 0011 §4/§5).
  BookSourceWebViewAdapterFactory? _defaultWebViewFactory() {
    final host = dispatcher;
    if (host == null) return null;
    return BookSourceWebViewAdapterFactory(
      sourceRef: host.sourceRef,
      hostState: hostState,
      onPageCookies: (pageUrl, cookies) =>
          host.cookies.set(pageUrl, cookies),
    );
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
        throw const SourceScriptError(
          'host-method',
          'convert direction refused',
        );
    }
  }

  /// Frozen `CacheManager`: an entry belongs to the source that wrote it and
  /// outlives this process (ADR 0011 §3). `saveTime` is the entry's deadline,
  /// read by [SourceHostState.expiryOf] so the write and the read cannot
  /// disagree, and a `saveTime` of 0 means permanent. Every read goes through
  /// the same deadline check, typed getters included.
  Future<Object?> _handleCache(Object? payload, String sourceRef) async {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid cache call');
    }
    final key = payload['key'];
    if (key is! String) {
      throw const SourceScriptError('host-input', 'invalid cache key');
    }
    switch (payload['op']) {
      case 'put':
      case 'putMemory':
        final saveTime = payload['saveTime'];
        await hostState.putEntry(
          sourceRef,
          key,
          payload['value'],
          saveTime: saveTime is num ? saveTime.toInt() : 0,
        );
        return null;
      case 'get':
      case 'getFromMemory':
      case 'getInt':
      case 'getLong':
      case 'getDouble':
        return hostState.entry(sourceRef, key);
      case 'delete':
      case 'deleteMemory':
        await hostState.deleteEntry(sourceRef, key);
        return null;
      default:
        throw const SourceScriptError('host-method', 'cache op refused');
    }
  }

  /// Frozen `CookieStore`, over the jar this source speaks through: pairs keyed
  /// by registrable domain, filtered by the source's site group (ADR 0011 §3).
  Future<Object?> _handleCookie(Object? payload, SourceCookieJar jar) async {
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
        await jar.set(url, '${payload['cookie'] ?? ''}');
        return null;
      case 'replaceCookie':
        await jar.replace(url, '${payload['cookie'] ?? ''}');
        return null;
      case 'removeCookie':
        await jar.remove(url);
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
  /// debug console, so the messages are recorded for the caller instead; the
  /// toasts are also shown through [onMessage], rate-limited.
  Object? _handleLog(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid log call');
    }
    final message = payload['message'];
    final kind = '${payload['kind'] ?? 'log'}';
    _record(SourceHostMessage(kind, '$message'));
    if (kind == 'toast' || kind == 'longToast') {
      if (_noticeLimiter.allows(DateTime.now().millisecondsSinceEpoch)) {
        onMessage?.call(SourceHostMessage(kind, '$message'));
      }
    }
    return message;
  }

  /// A member this slice defers refuses by name (ADR 0011 §2/§6): the reason is
  /// written into the source's log and the execution fails with a `policy`
  /// error naming the member, instead of the `TypeError` an undefined member
  /// would produce.
  SourceScriptError _handleRefusal(Object? payload) {
    if (payload is! Map) {
      throw const SourceScriptError('host-input', 'invalid refusal call');
    }
    final member = '${payload['member'] ?? 'unknown'}'.trim();
    final policy = '${payload['policy'] ?? ''}'.trim();
    final message = policy.isEmpty
        ? '$member is deferred: this product does not implement it yet '
              '(ADR 0011)'
        : '$member is deferred: $policy';
    _record(SourceHostMessage('refused', message));
    return SourceScriptError('policy', message);
  }

  /// Appends one message, dropping the oldest entries past the bound.
  void _record(SourceHostMessage message) {
    messages.add(message);
    if (messages.length > sourceMessageLogLimit) {
      messages.removeRange(0, messages.length - sourceMessageLogLimit);
    }
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

  /// The classification a `loginCheckJs` failure gets: the same category the
  /// ordinary rule path reports, with the script's own message kept so the
  /// stage that fails can name what the script threw. The frozen check's
  /// exception is what fails the stage (`WebBook.kt:71`), so nothing here is
  /// swallowed.
  static SourceScriptError _classifyCheck(Object error) {
    final failure = _classify(error);
    if (failure.category != 'js') return failure;
    final message = error is JsError ? _jsErrorText(error) : null;
    return message == null || message.isEmpty
        ? failure
        : SourceScriptError('js', message);
  }

  static String? _jsErrorText(JsError error) => switch (error) {
    JsError_Runtime(:final field0) => field0,
    JsError_Generic(:final field0) => field0,
    JsError_Type(:final field0) => field0,
    JsError_Reference(:final field0) => field0,
    JsError_Bridge(:final field0) => field0,
    JsError_Syntax(:final message) => message,
    _ => null,
  };

  static String _wrap(
    String source,
    Map<String, Object?> input, {
    bool checkResponse = false,
  }) => checkResponse
      ? '__liberCheckResponse(__liberRun('
            '($_facade)(${jsonEncode(input)}, true), ${jsonEncode(source)}))'
      : '__liberRun(($_facade)(${jsonEncode(input)}), ${jsonEncode(source)})';

  Future<String> _expandHostUrl(
    String rawUrl,
    BigInt requestId,
    Map<String, Object?> outerInput,
    SourceCancellation token, {
    bool allowUrlOptions = false,
  }) async {
    final url = await expandSourceUrl(
      rawUrl,
      (script, result) async =>
          await _evaluateNested(script, result, requestId, outerInput, token),
    );
    // Frozen `java.get`/`head`/`post`/`connect` hand the URL text to Jsoup
    // (`JsExtensions.kt:131-160`): they parse no option tail, so a URL that
    // carries one keeps refusing by name. `java.ajax`/`ajaxAll` build an
    // `AnalyzeUrl` and do parse it. (`JsExtensions.kt:91-125`.)
    if (!allowUrlOptions && (url.contains(',{') || url.contains(', {'))) {
      throw const SourceScriptError(
        'host-input',
        'nested URL options unsupported',
      );
    }
    return url;
  }

  /// One nested script evaluation on this execution's own bridge: what a
  /// `{{…}}`/`@js:` URL segment and a URL option's `js` run as.
  Future<Object?> _evaluateNested(
    String script,
    Object? result,
    BigInt requestId,
    Map<String, Object?> outerInput,
    SourceCancellation token,
  ) async {
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
  }

  /// BaseSource.kt:103-130: evaluate the header afresh, tolerate malformed
  /// JSON, and add User-Agent only if no case-insensitive slot exists.
  Future<Map<String, String?>> _headers(
    Map<String, Object?> input,
    BigInt requestId,
    SourceCancellation token,
  ) async {
    final source = input['source'];
    final raw = source is Map ? source['header'] : null;
    Object? value = raw;
    if (raw is String) {
      String? script;
      if (raw.toLowerCase().startsWith('@js:')) {
        script = raw.substring(4);
      } else if (raw.toLowerCase().startsWith('<js>')) {
        final end = raw.lastIndexOf('<');
        if (end > 4) script = raw.substring(4, end);
      }
      if (script != null) {
        token.throwIfCancelled();
        try {
          value = (await evalBridgeRequestGlobal(
            id: requestId,
            source: _wrap(script, {
              'sourceKey': input['sourceKey'],
              'source': source,
              'headers': const <String, String>{},
            }),
          )).value;
        } on JsError {
          token.throwIfCancelled();
          value = null;
        }
      }
    }
    final headers = <String, String?>{};
    try {
      final parsed = value is String ? jsonDecode(value) : null;
      if (parsed is Map &&
          parsed.values.every(
            (v) => v == null || v is String || v is num || v is bool,
          )) {
        for (final entry in parsed.entries) {
          headers['${entry.key}'] = entry.value == null
              ? null
              : '${entry.value}';
        }
      }
    } on FormatException {
      // The frozen Gson failure leaves the default header map intact.
    }
    if (!headers.keys.any((key) => key.toLowerCase() == 'user-agent')) {
      headers['User-Agent'] = sourceDefaultUserAgent;
    }
    token.throwIfCancelled();
    return headers;
  }

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
    final url = await _expandHostUrl(rawUrl, requestId, outerInput, token);
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
    return _responseJson(response);
  }

  /// Frozen `JsExtensions.ajax` (`help/JsExtensions.kt:91-105`): one
  /// `AnalyzeUrl` built from the URL — its `,{…}` option tail included — whose
  /// `getStrResponse().body` is the answer. The frozen failure fallback (a
  /// stack trace as the body, `:104-106`) is a recorded divergence: a failure
  /// here fails the execution with its own error.
  Future<Object?> _handleAjax(
    SourceHostDispatcher? host,
    Object? payload,
    BigInt requestId,
    Map<String, Object?> input,
    SourceCancellation token,
  ) async {
    if (host == null || payload is! String) {
      throw const SourceScriptError('host-input', 'invalid ajax url');
    }
    final request = await _shapeAjaxRequest(payload, requestId, input, token);
    final response = await host.request(
      request.method,
      request.url,
      headers: request.headers,
      body: request.body,
      retry: request.retry,
    );
    return _responseJson(response);
  }

  /// Frozen `JsExtensions.ajaxAll` (`help/JsExtensions.kt:111-125`): one
  /// `AnalyzeUrl` per URL, so each entry keeps its own options, sent as one
  /// ordered batch.
  Future<Object?> _handleAjaxAll(
    SourceHostDispatcher? host,
    Object? payload,
    BigInt requestId,
    Map<String, Object?> input,
    SourceCancellation token,
  ) async {
    if (host == null || payload is! Map || payload['urls'] is! List) {
      throw const SourceScriptError('host-input', 'invalid ajaxAll call');
    }
    final rawUrls = payload['urls'] as List;
    if (rawUrls.any((url) => url is! String)) {
      throw const SourceScriptError('host-input', 'invalid ajaxAll url');
    }
    final requests = <SourceBatchRequest>[];
    for (final url in rawUrls.cast<String>()) {
      final shaped = await _shapeAjaxRequest(url, requestId, input, token);
      requests.add((
        method: shaped.method,
        url: shaped.url,
        headers: shaped.headers,
        body: shaped.body,
        retry: shaped.retry,
      ));
    }
    final responses = await host.ajaxAll(requests);
    return [for (final response in responses) _responseJson(response)];
  }

  /// The shaped request one `java.ajax`/`java.ajaxAll` URL becomes: the URL
  /// text expanded (the frozen `analyzeJs`/`replaceKeyPageJs`), its `,{…}`
  /// option tail read through the same [SourceUrlOptions] model the stages use,
  /// and the same request shaping ([sourceRequestShape]) — `method`, `body`,
  /// `charset`, `headers` and `retry` apply (`AnalyzeUrl.kt:208-334`).
  Future<
    ({
      String url,
      String method,
      String? body,
      Map<String, String> headers,
      int retry,
    })
  >
  _shapeAjaxRequest(
    String rawUrl,
    BigInt requestId,
    Map<String, Object?> input,
    SourceCancellation token,
  ) async {
    final expanded = await _expandHostUrl(
      rawUrl,
      requestId,
      input,
      token,
      allowUrlOptions: true,
    );
    final ({String path, String tail, SourceUrlOptions options}) split;
    try {
      split = splitSourceUrlOptions(expanded);
    } on UnsupportedError catch (error) {
      throw _refuseAjaxOption('${error.message}');
    } on FormatException catch (error) {
      throw _refuseAjaxOption(error.message);
    }
    final options = split.options;
    if (options.webView) {
      throw _refuseAjaxOption('webView: true 需要阶段请求的 WebView 路径（ADR 0011 §4）');
    }
    final script = options.js;
    final target = script == null
        ? split.path
        : '${await _evaluateNested(script, split.path, requestId, input, token)}';
    final declared = await _headers(input, requestId, token);
    final headers = <String, String>{
      for (final entry in declared.entries)
        if (entry.value != null) entry.key: entry.value!,
      ...options.headers,
    };
    final (method: method, body: body, headers: extra) =
        await sourceRequestShape(options, headers);
    return (
      url: options.isPost
          ? target
          : await encodeSourceQuery(target, charset: options.charset),
      method: method,
      body: body,
      headers: {...headers, ...extra},
      retry: options.retry,
    );
  }

  /// A URL option a `java.ajax` tail carries but this path cannot apply refuses
  /// by name, into the source log, like every other unsupported member.
  SourceScriptError _refuseAjaxOption(String policy) => _handleRefusal({
    'member': 'java.ajax(url, {…})',
    'policy': policy,
  });

  /// Frozen `AnalyzeUrl.getStrResponse`/`getResponse` (`AnalyzeUrl.kt:465-526`):
  /// the stage's own request repeated, answered as the response object the
  /// check script reads.
  Future<Object?> _handleStageResend(SourceStageRequest? stage) async {
    if (stage == null) throw _refuseStageRequest('java.getStrResponse');
    return (await stage.resend()).toJson();
  }

  /// Frozen `AnalyzeUrl.initUrl` (`AnalyzeUrl.kt:139`): the stage's address
  /// analysis re-run, so the requests the check makes after it use the result.
  Future<Object?> _handleStageInitUrl(SourceStageRequest? stage) async {
    if (stage == null) throw _refuseStageRequest('java.initUrl');
    await stage.reanalyze();
    return null;
  }

  /// The stage request surface belongs to the `loginCheckJs` hook; a rule script
  /// that asks for it refuses by name instead of failing as a `TypeError`.
  SourceScriptError _refuseStageRequest(String member) => _handleRefusal({
    'member': member,
    'policy': '只有书源 loginCheckJs 钩子持有阶段请求（#59）',
  });

  static Map<String, Object?> _responseJson(SourceHttpResponse response) => {
    'statusCode': response.statusCode,
    'headers': response.headers,
    'body': response.body,
    'url': response.url.toString(),
  };

  /// The JavaScript surface one source sees: the frozen runtime's bindings
  /// (`AnalyzeUrl.buildScriptBindings` plus `JsExtensions`), with the host
  /// half bridged into Dart.
  static const _facade = r'''
(input, checkResponse) => {
  const bridge = fjs.bridge_call;
  const call = (method, payload) =>
    JSON.parse(bridge(JSON.stringify({method: method, payload: payload}))).value;
  // The frozen `StrResponse.headers()` is an OkHttp `Headers`: `headers().get(name)
  // is case-insensitive and answers the first value, and a script that indexes
  // the object directly (`headers()["x-path"]`) sees the same values.
  function responseHeaders(values) {
    const source = values && typeof values === 'object' ? values : {};
    const get = name => {
      const wanted = String(name).toLowerCase();
      for (const key in source) {
        if (key.toLowerCase() !== wanted) continue;
        const value = source[key];
        if (Array.isArray(value)) return value.length ? String(value[0]) : null;
        return value === null || value === undefined ? null : String(value);
      }
      return null;
    };
    return Object.freeze({...source, get: get});
  }
  // A response as a source reads it, tagged (`__response`) so the
  // `loginCheckJs` boundary can tell it from any other value the script
  // returned, the way the frozen `as StrResponse` cast does.
  function response(result) {
    return Object.freeze({
      body: () => result.body,
      code: () => result.statusCode,
      url: () => result.url,
      headers: () => responseHeaders(result.headers),
      raw: () => Object.freeze({request: () => Object.freeze({url: () => result.url})}),
      __response: () => result
    });
  }
  // The frozen check script's `java` is the stage's own `AnalyzeUrl`
  // (`AnalyzeUrl.kt:139,465-526`): these two members repeat the stage request
  // and re-run its address analysis, and they belong to the `loginCheckJs`
  // hook, which is the one evaluation the pipeline hands that request to.
  const refuseStage = member => call('refuse', {
    member: member,
    policy: 'the stage request surface belongs to a loginCheckJs hook (#59)'
  });
  const stageResponse = member => checkResponse
    ? response(call('stageResend', null))
    : refuseStage(member);
  function connectHeaders(headers) {
    if (typeof headers === 'string') {
      try {
        const parsed = JSON.parse(headers);
        if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed;
      } catch (_) {}
      return call('headers', null);
    }
    return headers == null ? call('headers', null) : headers;
  }
  function request(method, url, body, headers) {
    const result = call('request', {
      method, url:String(url), body, headers:headers || input.headers || {}
    });
    return response(result);
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
  const unavailable = member => call('refuse', {
    member, policy: 'book/chapter variables are unavailable in the current pipeline (#43)'
  });
  const snapshot = (name, value) => {
    if (value === null || value === undefined) return null;
    return new Proxy(Object.freeze({...value}), {
      get: (target, key) => {
        if (typeof key === 'symbol') return undefined;
        if (key === 'toJSON') return () => ({...target});
        if (Object.prototype.hasOwnProperty.call(target, key)) return target[key];
        return unavailable(name + '.' + String(key));
      },
      set: (_, key) => unavailable(name + '.' + String(key)),
      defineProperty: (_, key) => unavailable(name + '.' + String(key)),
      deleteProperty: (_, key) => unavailable(name + '.' + String(key))
    });
  };
  const book = snapshot('book', input.book);
  const chapter = snapshot('chapter', input.chapter);
  const source = Object.freeze({
    ...sourceFields,
    getKey: () => input.sourceKey,
    getName: () => sourceFields.bookSourceName || '',
    getTag: () => sourceFields.bookSourceName || '',
    getHeaderMap: (...args) => {
      if (args.length > 1) throw new Error('source.getHeaderMap expects zero or one argument');
      if (args[0]) return call('refuse', {member:'source.getHeaderMap(true)', policy:'login headers (#13)'});
      return call('headers', null);
    },
    getVariable: () => call('cache', {op:'get', key:'sourceVariable_' + input.sourceKey}) || '',
    // Frozen `BaseSource.setVariable` (`BaseSource.kt:200-212`): the same
    // `sourceVariable_<key>` entry `getVariable` reads, and a null deletes it.
    setVariable: value => {
      if (value === null || value === undefined) {
        call('cache', {op:'delete', key:'sourceVariable_' + input.sourceKey});
        return;
      }
      call('cache', {op:'put', key:'sourceVariable_' + input.sourceKey, value:String(value)});
    },
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
  // StringUtils.kt:133-218: retain Int overflow and the trailing shorthand.
  const toNumChapter = text => {
    const match = /(第)(.+?)(章)/.exec(text);
    if (!match) return text;
    const digits = Array.from(match[2], ch => {
      const code = ch.charCodeAt(0);
      return code === 12288 ? ' ' : code >= 65281 && code <= 65374
        ? String.fromCharCode(code - 65248) : ch;
    }).join('').replace(/[ \t\n\x0b\f\r]+/g, '');
    let value = Number(digits);
    if (!/^[+-]?[0-9]+$/.test(digits) || value < -2147483648 || value > 2147483647) {
      const numbers = {零:0, 〇:0, 一:1, 二:2, 两:2, 三:3, 四:4, 五:5,
        六:6, 七:7, 八:8, 九:9, 壹:1, 贰:2, 叁:3, 肆:4, 伍:5,
        陆:6, 柒:7, 捌:8, 玖:9, 十:10, 拾:10, 百:100, 佰:100,
        千:1000, 仟:1000, 万:10000, 亿:100000000};
      let result = 0, tmp = 0, billion = 0;
      value = 0;
      for (let i = 0; i < digits.length; i++) {
        const n = numbers[digits[i]];
        if (n === undefined) { value = -1; break; }
        if (n === 100000000) {
          result = Math.imul((result + tmp) | 0, n);
          billion = (Math.imul(billion, n) + result) | 0;
          result = 0; tmp = 0;
        } else if (n === 10000) {
          result = Math.imul((result + tmp) | 0, n); tmp = 0;
        } else if (n >= 10) {
          if (tmp === 0) tmp = 1;
          result = (result + Math.imul(n, tmp)) | 0; tmp = 0;
        } else {
          tmp = i >= 2 && i === digits.length - 1 && numbers[digits[i - 1]] > 10
            ? Math.trunc(Math.imul(n, numbers[digits[i - 1]]) / 10)
            : (Math.imul(tmp, 10) + n) | 0;
        }
        value = (result + tmp + billion) | 0;
      }
    }
    return match[1] + String(value) + match[3];
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

  const refuseFile = member => () => call('refuse', {
    member: member,
    policy: 'the file and archive family (ADR 0011 §2)'
  });
  const refuseFont = member => () => call('refuse', {
    member: member,
    policy: 'font de-obfuscation (ADR 0011 §6)'
  });
  const refuseImportScript = () => call('refuse', {
    member: 'java.importScript',
    policy: 'the local-path half comes with the file family (ADR 0011 §2) and the remote half with #13'
  });
  const refuseVerificationHatch = member => () => call('refuse', {
    member: member,
    policy: 'the user-confirmed browser and captcha hatches require the confirmation UI that #32 lands (ADR 0011 §4)'
  });
  const optionalText = value => (value === null || value === undefined) ? null : String(value);

  const java = Object.freeze({
    connect: (...args) => {
      if (args.length < 1 || args.length > 2) throw new Error('java.connect expects one or two arguments');
      return request('connect', args[0], null, connectHeaders(args[1]));
    },
    ajax: url => call('ajax', Array.isArray(url) ? String(url.length ? url[0] : null) : String(url)).body,
    ajaxAll: (...args) => {
      if (args.length !== 1 || !Array.isArray(args[0])) throw new Error('java.ajaxAll expects one URL array');
      if (args[0].length === 0) return [];
      return call('ajaxAll', {urls:args[0].map(String)}).map(response);
    },
    // Frozen `AnalyzeUrl.getResponse`/`getStrResponse` (`AnalyzeUrl.kt:478-526`):
    // the stage's current request repeated. The `jsStr`/`sourceRegex` arguments
    // only drive the frozen WebView path, and have no used-source call site, so
    // that form refuses by name.
    getResponse: () => stageResponse('java.getResponse'),
    getStrResponse: (jsStr, sourceRegex) => {
      if (jsStr !== undefined && jsStr !== null) return refuseStage('java.getStrResponse(jsStr, …)');
      if (sourceRegex !== undefined && sourceRegex !== null) return refuseStage('java.getStrResponse(jsStr, …)');
      return stageResponse('java.getStrResponse');
    },
    initUrl: () => {
      if (!checkResponse) return refuseStage('java.initUrl');
      call('stageInitUrl', null);
    },
    get: (...args) => {
      if (args.length === 1) return call('state', {op:'get', key:String(args[0])});
      if (args.length === 2) return request('GET', args[0], null, args[1]);
      throw new Error('java.get expects one or two arguments');
    },
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
    toURL: (url, baseUrl) => toUrl(String(url), (baseUrl === undefined || baseUrl === null) ? null : String(baseUrl)),
    androidId: () => call('identity', null),
    getWebViewUA: () => call('userAgent', null),
    webView: (html, url, js) => call('webview', {
      op:'render', html:optionalText(html), url:optionalText(url), js:optionalText(js)
    }),
    webViewGetSource: (html, url, js, sourceRegex) => call('webview', {
      op:'source', html:optionalText(html), url:optionalText(url), js:optionalText(js),
      regex:optionalText(sourceRegex)
    }),
    webViewGetOverrideUrl: (html, url, js, overrideUrlRegex) => call('webview', {
      op:'override', html:optionalText(html), url:optionalText(url), js:optionalText(js),
      regex:optionalText(overrideUrlRegex)
    }),
    startBrowser: refuseVerificationHatch('java.startBrowser'),
    startBrowserAwait: refuseVerificationHatch('java.startBrowserAwait'),
    getVerificationCode: refuseVerificationHatch('java.getVerificationCode'),
    openUrl: refuseVerificationHatch('java.openUrl'),
    getFile: refuseFile('java.getFile'),
    readFile: refuseFile('java.readFile'),
    readTxtFile: refuseFile('java.readTxtFile'),
    deleteFile: refuseFile('java.deleteFile'),
    unzipFile: refuseFile('java.unzipFile'),
    un7zFile: refuseFile('java.un7zFile'),
    unrarFile: refuseFile('java.unrarFile'),
    unArchiveFile: refuseFile('java.unArchiveFile'),
    getTxtInFolder: refuseFile('java.getTxtInFolder'),
    getZipStringContent: refuseFile('java.getZipStringContent'),
    getRarStringContent: refuseFile('java.getRarStringContent'),
    get7zStringContent: refuseFile('java.get7zStringContent'),
    getZipByteArrayContent: refuseFile('java.getZipByteArrayContent'),
    getRarByteArrayContent: refuseFile('java.getRarByteArrayContent'),
    get7zByteArrayContent: refuseFile('java.get7zByteArrayContent'),
    downloadFile: refuseFile('java.downloadFile'),
    cacheFile: refuseFile('java.cacheFile'),
    importScript: refuseImportScript,
    queryTTF: refuseFont('java.queryTTF'),
    queryBase64TTF: refuseFont('java.queryBase64TTF'),
    replaceFont: refuseFont('java.replaceFont')
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
    deleteMemory: key => { call('cache', {op:'deleteMemory', key:String(key)}); },
    getFile: refuseFile('cache.getFile'),
    putFile: refuseFile('cache.putFile'),
    getQueryTTF: refuseFont('cache.getQueryTTF')
  });

  return {key:null, page:null, book:book, chapter:chapter, result:null, speakText:null, speakSpeed:null,
    ...input, __LIBER_INPUT__: input, book, chapter, source, java, cookie, cache,
    // The `loginCheckJs` hook sees the stage's response as `result` through the
    // response accessors; every other evaluation keeps the raw value the rule
    // field produced.
    result: checkResponse ? (input.result === null || input.result === undefined ? null : response(input.result)) : input.result};
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
          'return function(scope,code){ if (!run) run=create(); return run.call(scope,scope,code); }; })(); '
          // The `loginCheckJs` boundary: the script's value must be a response
          // object, the way the frozen `as StrResponse` cast requires one; a
          // response crosses back as its plain payload.
          'globalThis.__liberCheckResponse = function(value){ '
          'if (value !== null && typeof value === "object" && typeof value.__response === "function") return value.__response(); '
          'throw new Error("loginCheckJs must return a response object (result, java.getStrResponse() or java.getResponse()); got " + (value === null ? "null" : typeof value)); };',
        ),
      );
      return session;
    } catch (_) {
      await engine.close();
      rethrow;
    }
  }
}
