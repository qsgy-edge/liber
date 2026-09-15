import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fjs/fjs.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import '../domain/contracts.dart';
import 'source_host_dispatcher.dart';
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
  });
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
  static Future<void>? _init;
  static int _active = 0;
  static Future<void> initialize({String? libraryPath}) =>
      _init ??= LibFjs.init(
        externalLibrary: libraryPath == null
            ? null
            : ExternalLibrary.open(libraryPath),
      );
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
    if (_init == null) return;
    LibFjs.dispose();
    _init = null;
  }

  @override
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async {
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

    var timedOut = false;
    Future<void> close() => closing ??= engine!.close().then<void>(
      (_) {},
      onError: (Object e, StackTrace s) {
        closeError = e;
      },
    );
    final unlisten = token.listen(interruptExecution);
    final timer = Timer(timeout, () {
      timedOut = true;
      token.cancel();
    });
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

      executionId = await engine.createScopedExecution();
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
      if (timedOut) throw const SourceScriptError('timeout');
      if (token.isCancelled) throw const SourceScriptError('cancelled');
      throw hostFailure ?? _classify(error);
    } finally {
      timer.cancel();
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

  static const _facade = r'''
(input) => {
  const bridge = fjs.bridge_call;
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
  const source = Object.freeze({getKey: () => input.sourceKey});
  const java = Object.freeze({
    connect: (url, headers) => request('connect', url, null, headers),
    ajax: url => JSON.parse(bridge(JSON.stringify({method:'ajax',payload:String(url)}))).value.body,
    get: (url, headers) => request('GET', url, null, headers),
    head: (url, headers) => request('HEAD', url, null, headers),
    post: (url, body, headers) => request('POST', url, body, headers)
  });
  return {key:null, page:null, book:null, result:null, speakText:null, speakSpeed:null,
    ...input, __LIBER_INPUT__: input, source, java};
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
