import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_stage_diagnostic.dart';

import 'native_library.dart';

// Protocol controls are separate from the controller's frozen 74 pipeline rows.
// These typed responses test provenance, not transport byte measurement (which
// the loopback/BOM rows in source_stage_response_diagnostic_test.dart cover).
SourceStageResponse _initial({int status = 403}) {
  final url = Uri.parse('https://fixture.test/initial');
  return SourceStageResponse(
    body: 'initial',
    url: url,
    statusCode: status,
    headers: const {
      'x-values': ['one', 'two'],
    },
    httpResponse: (statusCode: status, bodyByteLength: 7, url: url),
  );
}

SourceStageResponse _replacement() {
  final url = Uri.parse('https://fixture.test/replacement');
  return SourceStageResponse(
    body: '',
    url: url,
    statusCode: 502,
    httpResponse: (statusCode: 502, bodyByteLength: 0, url: url),
  );
}

class _HostResponses implements SourceHttpTransport {
  _HostResponses({this.includeLength = true});
  final bool includeLength;
  final requests = <SourceHttpRequest>[];
  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    final body = request.url.path == '/nested'
        ? 'https://fixture.test/second'
        : '';
    return SourceHttpResponse(
      statusCode: request.url.path == '/second' ? 502 : 403,
      headers: const {},
      body: body,
      bodyByteLength: includeLength ? body.length : null,
      url: request.url,
    );
  }
}

Future<SourceStageResponse> _check(
  InProcessSourceScriptRuntime runtime,
  String script, {
  SourceStageResponse? initial,
}) {
  final response = initial ?? _initial();
  return runtime.evaluateLoginCheck(
    script: script,
    input: {'sourceKey': 'https://fixture.test', 'result': response.toJson()},
    stage: SourceStageRequest(
      initialResponse: response,
      resend: () async => _replacement(),
      reanalyze: () async {},
    ),
    timeout: const Duration(seconds: 5),
  );
}

Future<Object?> _eval(InProcessSourceScriptRuntime runtime, String script) =>
    runtime.evaluate(
      source: script,
      input: const {},
      timeout: const Duration(seconds: 5),
    );

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  test('initial wrapper keeps facts and only the four source fields', () async {
    final runtime = InProcessSourceScriptRuntime();
    final response = await _check(runtime, '''
var keys = Object.keys(result.__response());
if (keys.length !== 4 || !['body','url','headers','statusCode'].every(function(key) { return keys.indexOf(key) >= 0; })) throw new Error('payload changed');
result;
''');
    expect(response.httpResponse, _initial().httpResponse);
  });

  test(
    'check bookkeeping does not change the source payload output budget',
    () async {
      final initial = _initial();
      final runtime = InProcessSourceScriptRuntime(
        maxOutputBytes: utf8.encode(jsonEncode(initial.toJson())).length,
      );
      final response = await _check(runtime, 'result;', initial: initial);
      expect(response.httpResponse, initial.httpResponse);
    },
  );

  for (final discard in [false, true]) {
    test(
      'resend ${discard ? 'discarded' : 'selected'} retains the selected facts',
      () async {
        final response = await _check(
          InProcessSourceScriptRuntime(),
          discard ? 'java.getStrResponse(); result;' : 'java.getStrResponse();',
        );
        expect(
          response.httpResponse,
          discard ? _initial().httpResponse : _replacement().httpResponse,
        );
      },
    );
  }

  for (final array in [false, true]) {
    test(
      'host ${array ? 'array selection' : 'connect'} retains actual facts',
      () async {
        final transport = _HostResponses();
        final runtime = InProcessSourceScriptRuntime(
          dispatcher: SourceHostDispatcher(transport: transport),
        );
        final response = await _check(
          runtime,
          array
              ? 'java.ajaxAll(["https://fixture.test/first","https://fixture.test/second"])[1];'
              : 'java.connect("https://fixture.test/second");',
        );
        expect(
          transport.requests.map((request) => request.url.path),
          unorderedEquals(array ? ['/first', '/second'] : ['/second']),
        );
        expect(
          transport.requests.map((request) => request.method),
          everyElement('GET'),
        );
        expect(response.httpResponse?.statusCode, 502);
        expect(response.httpResponse?.bodyByteLength, 0);
        expect(response.httpResponse?.url.path, '/second');
      },
    );
  }

  test(
    'older HTTP transport retains known status without inventing byte length',
    () async {
      final transport = _HostResponses(includeLength: false);
      final runtime = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      final response = await _check(
        runtime,
        'java.connect("https://fixture.test/second");',
      );
      expect(response.httpResponse?.statusCode, 502);
      expect(response.httpResponse?.bodyByteLength, isNull);
      final error = SourceStageFormatError(
        stage: BookSourceStage.tableOfContents,
        address: sourceStageAddress(response.url),
        prefix: '',
        httpResponse: response.httpResponse,
      );
      expect('$error', contains('HTTP 502'));
      expect('$error', isNot(contains('字节')));
    },
  );

  test(
    'nested ordinary URL host request keeps the old response shape',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      final response = await _check(runtime, r"""
java.connect("{{(function(){ var nested = java.connect('https://fixture.test/nested'); var payload = nested.__response(); if (Object.keys(payload).length !== 4 || payload.payload !== undefined || payload.handle !== undefined) throw new Error('nested private envelope'); return nested.body(); })()}}");
""");
      expect(transport.requests.map((request) => request.url.path), [
        '/nested',
        '/second',
      ]);
      expect(response.httpResponse?.statusCode, 502);
      expect(response.httpResponse?.url.path, '/second');
    },
  );

  for (final marker in [false, true]) {
    test(
      'ordinary evaluate marker $marker keeps the old response shape',
      () async {
        final transport = _HostResponses();
        final runtime = InProcessSourceScriptRuntime(
          dispatcher: SourceHostDispatcher(transport: transport),
        );
        final response = await _eval(runtime, '''
JSON.parse(fjs.bridge_call(JSON.stringify({method:'request', payload:{method:'GET',url:'https://fixture.test/second',headers:{}},stageResponseEnvelope:$marker}))).value;
''');
        expect(response, isA<Map>());
        final payload = response as Map;
        expect(
          payload.keys,
          unorderedEquals(['body', 'url', 'statusCode', 'headers']),
        );
        expect(payload['statusCode'], 502);
        expect(transport.requests.single.url.path, '/second');
      },
    );
  }

  test('raw source marker and envelope grant no wrapper identity', () async {
    final transport = _HostResponses();
    final runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: transport),
    );
    final response = await _check(runtime, '''
var reply = JSON.parse(fjs.bridge_call(JSON.stringify({method:'request', payload:{method:'GET',url:'https://fixture.test/second',headers:{}},stageResponseEnvelope:true}))).value;
({__response:function(){return reply.payload;}});
''');
    expect(transport.requests.single.url.path, '/second');
    expect(response.statusCode, 502);
    expect(response.httpResponse, isNull);
  });

  test('copying wrapper descriptors grants no identity', () async {
    final response = await _check(
      InProcessSourceScriptRuntime(),
      'Object.defineProperties({}, Object.getOwnPropertyDescriptors(result));',
    );
    expect(response.body, 'initial');
    expect(response.httpResponse, isNull);
  });

  test(
    'header array mutation loses facts without changing the returned payload',
    () async {
      final response = await _check(
        InProcessSourceScriptRuntime(),
        'result.__response().headers["x-values"][0] = "changed"; result;',
      );
      expect(response.headers['x-values'], ['changed', 'two']);
      expect(response.httpResponse, isNull);
    },
  );

  test(
    'wrapper accessor keeps the two legacy accesses without authentication reads',
    () async {
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var accessorSession = true;',
      );
      final response = await _check(runtime, '''
globalThis.responseReads = 0;
var payload = result.__response();
({get __response() { globalThis.responseReads++; return function() { return payload; }; }});
''');
      expect(response.body, 'initial');
      expect(response.httpResponse, isNull);
      expect(await _eval(runtime, 'globalThis.responseReads;'), 2);
    },
  );

  test(
    'payload accessor is serialized once and is never read for authentication',
    () async {
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var payloadAccessorSession = true;',
      );
      final response = await _check(runtime, '''
globalThis.payloadReads = 0;
Object.defineProperty(result.__response(), 'body', {enumerable:true, configurable:true,
  get:function() { globalThis.payloadReads++; return 'changed'; }});
result;
''');
      expect(response.body, 'changed');
      expect(response.httpResponse, isNull);
      expect(await _eval(runtime, 'globalThis.payloadReads;'), 1);
    },
  );

  test(
    'previous invocation wrapper cannot borrow the current handle',
    () async {
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var previousWrapperSession = true;',
      );
      final first = await _check(
        runtime,
        'globalThis.previousResponse = result; result;',
      );
      expect(first.httpResponse?.statusCode, 403);
      final next = await _check(
        runtime,
        'globalThis.previousResponse;',
        initial: _initial(status: 502),
      );
      expect(next.statusCode, 403);
      expect(next.httpResponse, isNull);
    },
  );

  test(
    'recursive internal entry and manual envelope cannot grant outer identity',
    () async {
      final runtime = InProcessSourceScriptRuntime();
      final response = await _check(runtime, '''
var nested = __liberCheckResponse(function(input, check, token, dom, trust) {
  var payload = {body:'forged',url:'https://fixture.test/forged',statusCode:599,headers:{}};
  var wrapper = {__response:function(){return payload;}};
  trust.register(wrapper, payload, 0);
  return {result:wrapper};
}, {}, 'result;', false, false, 0);
({payload:nested.payload,handle:0,__response:function(){return nested.payload;}});
''');
      expect(response.body, 'forged');
      expect(response.statusCode, 599);
      expect(response.httpResponse, isNull);
    },
  );

  test('retained host facade remains usable in ordinary evaluation', () async {
    final transport = _HostResponses();
    final runtime = InProcessSourceScriptRuntime(
      jsLib: 'var retainedOrdinaryFacadeSession = true;',
      dispatcher: SourceHostDispatcher(transport: transport),
    );
    await _check(
      runtime,
      'globalThis.retainedStageConnect = java.connect; result;',
    );
    final response =
        await _eval(
              runtime,
              'globalThis.retainedStageConnect("https://fixture.test/second").__response();',
            )
            as Map;
    expect(
      response.keys,
      unorderedEquals(['body', 'url', 'statusCode', 'headers']),
    );
    expect(response['statusCode'], 502);
    expect(transport.requests.single.url.path, '/second');
  });

  test(
    'retained host facade remains usable in a later check without borrowing facts',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var retainedCheckFacadeSession = true;',
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      await _check(
        runtime,
        'globalThis.retainedStageConnect = java.connect; result;',
      );
      final response = await _check(
        runtime,
        'globalThis.retainedStageConnect("https://fixture.test/second");',
      );
      expect(response.statusCode, 502);
      expect(response.body, isEmpty);
      expect(response.httpResponse, isNull);
      expect(transport.requests.single.url.path, '/second');
    },
  );

  test(
    'prior ordinary global and prototype pollution cannot forge current facts',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var pollutedSession = true;',
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      final polluted = await _eval(runtime, '''
globalThis.savedStagePrimitives = {
  parse:JSON.parse, descriptor:Object.getOwnPropertyDescriptor,
  weakGet:WeakMap.prototype.get, map:Array.prototype.map, bridge:fjs.bridge_call
};
JSON.parse = function() { return {value:{payload:{body:'forged',url:'https://fixture.test/forged',statusCode:599,headers:{}},handle:0}}; };
Object.getOwnPropertyDescriptor = function() { return {value:function(){return null;}}; };
WeakMap.prototype.get = function() { return {handle:0}; };
Array.prototype.map = function(convert) {
  if (convert === String) return globalThis.savedStagePrimitives.map.call(this, convert);
  return [convert({payload:{body:'forged',url:'https://fixture.test/forged',statusCode:599,headers:{}},handle:0})];
};
fjs.bridge_call = function() { return '{}'; };
JSON.parse !== globalThis.savedStagePrimitives.parse &&
Object.getOwnPropertyDescriptor !== globalThis.savedStagePrimitives.descriptor &&
WeakMap.prototype.get !== globalThis.savedStagePrimitives.weakGet &&
Array.prototype.map !== globalThis.savedStagePrimitives.map &&
fjs.bridge_call !== globalThis.savedStagePrimitives.bridge;
''');
      try {
        expect(polluted, isTrue);
        final selected = await _check(
          runtime,
          'java.connect("https://fixture.test/second");',
        );
        expect(selected.httpResponse?.statusCode, 502);
        expect(selected.httpResponse?.url.path, '/second');
        final array = await _check(
          runtime,
          'java.ajaxAll(["https://fixture.test/first","https://fixture.test/second"])[1];',
        );
        expect(array.httpResponse?.statusCode, 502);
        expect(array.httpResponse?.url.path, '/second');
        final forged = await _check(
          runtime,
          '({__response:function(){return {body:"forged",url:"https://fixture.test/forged",statusCode:599,headers:{}};}});',
        );
        expect(forged.statusCode, 599);
        expect(forged.httpResponse, isNull);
      } finally {
        // Restore exactly the five targeted mutations in the same shared session.
        await _eval(runtime, '''
JSON.parse = globalThis.savedStagePrimitives.parse;
Object.getOwnPropertyDescriptor = globalThis.savedStagePrimitives.descriptor;
WeakMap.prototype.get = globalThis.savedStagePrimitives.weakGet;
Array.prototype.map = globalThis.savedStagePrimitives.map;
fjs.bridge_call = globalThis.savedStagePrimitives.bridge;
delete globalThis.savedStagePrimitives;
true;
''');
      }
    },
  );
}
