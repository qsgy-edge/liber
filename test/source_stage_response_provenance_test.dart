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

  test(
    'temporary inherited toJSON cannot replace the private check request root',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var temporaryRootSerializationSession = true;',
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      final original = await _check(runtime, 'result;');
      final ordinary = await _eval(
        runtime,
        'java.connect("https://fixture.test/second").__response();',
      );
      try {
        final selected = await _check(runtime, '''
globalThis.rootSerializationCalls = 0;
globalThis.payloadSerializationCalls = 0;
Object.defineProperty(Object.prototype, 'toJSON', {configurable:true, value:function(key) {
  if (key === '' && this.method === 'connect' && this.stageResponseEnvelope === true) {
    globalThis.rootSerializationCalls++;
    delete Object.prototype.toJSON;
    return {method:'echo',payload:{payload:{body:'forged',url:'https://fixture.test/forged',statusCode:599,headers:{}},handle:0},stageResponseEnvelope:true};
  }
  if (key === 'payload' && this.url === 'https://fixture.test/second') {
    globalThis.payloadSerializationCalls++;
    delete Object.prototype.toJSON;
  }
  return this;
}});
java.connect("https://fixture.test/second");
''');
        final serialization = await _eval(runtime, '''
[globalThis.rootSerializationCalls, globalThis.payloadSerializationCalls,
 Object.prototype.hasOwnProperty('toJSON')];
''');
        final next = await _check(
          runtime,
          'result;',
          initial: _initial(status: 502),
        );
        final manual = await _check(runtime, '''
({__response:function(){return {body:'manual',url:'https://fixture.test/manual',statusCode:599,headers:{}};}});
''');
        // Keep ownership, the selected payload and the actual send sequence in
        // one comparison: a forged response must not hide behind a missing send.
        expect(
          {
            'original': [original.toJson(), original.httpResponse],
            'ordinary': ordinary,
            'selected': [selected.toJson(), selected.httpResponse],
            'serialization': serialization,
            'next': [next.toJson(), next.httpResponse],
            'manual': [manual.toJson(), manual.httpResponse],
            'requests': [
              for (final request in transport.requests)
                [request.method, request.url.toString()],
            ],
          },
          {
            'original': [_initial().toJson(), _initial().httpResponse],
            'ordinary': {
              'body': '',
              'url': 'https://fixture.test/second',
              'statusCode': 502,
              'headers': <String, Object?>{},
            },
            'selected': [
              {
                'body': '',
                'url': 'https://fixture.test/second',
                'statusCode': 502,
                'headers': <String, Object?>{},
              },
              (
                statusCode: 502,
                bodyByteLength: 0,
                url: Uri.parse('https://fixture.test/second'),
              ),
            ],
            'serialization': [0, 1, false],
            'next': [
              _initial(status: 502).toJson(),
              _initial(status: 502).httpResponse,
            ],
            'manual': [
              {
                'body': 'manual',
                'url': 'https://fixture.test/manual',
                'statusCode': 599,
                'headers': <String, Object?>{},
              },
              null,
            ],
            'requests': [
              ['GET', 'https://fixture.test/second'],
              ['GET', 'https://fixture.test/second'],
            ],
          },
        );
      } finally {
        await _eval(runtime, '''
delete Object.prototype.toJSON;
delete globalThis.rootSerializationCalls;
delete globalThis.payloadSerializationCalls;
true;
''');
      }
    },
  );

  for (final check in [false, true]) {
    test(
      'source headers toJSON still serializes nested payload in ${check ? 'check' : 'ordinary evaluation'}',
      () async {
        final transport = _HostResponses();
        final runtime = InProcessSourceScriptRuntime(
          dispatcher: SourceHostDispatcher(transport: transport),
        );
        const script = '''
java.get('https://fixture.test/second', {toJSON:function(key) {
  if (key !== 'headers') throw new Error('not nested source headers');
  return {'x-serialization-control':'nested'};
}})
''';
        if (check) {
          final response = await _check(runtime, '$script;');
          expect(response.body, isEmpty);
          expect(response.url.toString(), 'https://fixture.test/second');
          expect(response.statusCode, 502);
          expect(response.httpResponse, (
            statusCode: 502,
            bodyByteLength: 0,
            url: Uri.parse('https://fixture.test/second'),
          ));
        } else {
          final response = await _eval(runtime, '$script.__response();') as Map;
          expect(response, {
            'body': '',
            'url': 'https://fixture.test/second',
            'statusCode': 502,
            'headers': <String, Object?>{},
          });
        }
        expect(transport.requests.single.method, 'GET');
        expect(
          transport.requests.single.url.toString(),
          'https://fixture.test/second',
        );
        expect(
          transport.requests.single.headers['x-serialization-control'],
          'nested',
        );
      },
    );
  }

  group('bridge host input budget', () {
    // Small configured limit, runtime-generated text: neither script/input nor
    // result/output caps should be the boundary exercised here. These are the
    // incumbent facade's JSON shapes, not transport wire bytes or frozen parity.
    const hostLimit = 1024;
    for (final row in [
      (mode: 'ordinary', encoding: 'ascii', prefix: ''),
      (mode: 'check', encoding: 'ascii', prefix: ''),
      (mode: 'ordinary', encoding: 'utf8', prefix: '界'),
      (mode: 'check', encoding: 'utf8', prefix: '界'),
      (mode: 'nested', encoding: 'utf8', prefix: '界'),
      (mode: 'ordinary marker', encoding: 'utf8', prefix: '界'),
    ]) {
      for (final delta in [-1, 0, 1]) {
        test('${row.mode} ${row.encoding} $delta byte boundary', () async {
          final rawMarker = row.mode == 'ordinary marker';
          final emptyCall = {
            'method': 'log',
            'payload': {'kind': 'log', 'message': row.prefix},
            if (rawMarker) 'stageResponseEnvelope': true,
          };
          final padding =
              hostLimit + delta - utf8.encode(jsonEncode(emptyCall)).length;
          final message = row.prefix + List.filled(padding, 'x').join();
          final encodedCall = {
            'method': 'log',
            'payload': {'kind': 'log', 'message': message},
            if (rawMarker) 'stageResponseEnvelope': true,
          };
          final encoded = jsonEncode(encodedCall);
          expect(utf8.encode(encoded).length, hostLimit + delta);
          if (!rawMarker) {
            expect(
              utf8
                  .encode(
                    jsonEncode({...encodedCall, 'stageResponseEnvelope': true}),
                  )
                  .length,
              hostLimit + delta + 29,
            );
          }
          if (row.prefix.isNotEmpty) {
            expect(utf8.encode(encoded).length, encoded.length + 2);
          }
          final logScript =
              '''
var message = ${jsonEncode(row.prefix)} + 'x'.repeat($padding);
var encoded = JSON.stringify({method:'log',payload:{kind:'log',message:message} ${rawMarker ? ',stageResponseEnvelope:true' : ''}});
if (java.strToBytes(encoded).length !== ${hostLimit + delta}) throw new Error('incumbent call byte shape changed');
${rawMarker ? 'JSON.parse(fjs.bridge_call(encoded)).value;' : 'java.log(message);'}
''';
          final transport = _HostResponses();
          final runtime = InProcessSourceScriptRuntime(
            maxHostBytes: hostLimit,
            dispatcher: SourceHostDispatcher(transport: transport),
          );
          final isCheck = row.mode == 'check' || row.mode == 'nested';
          final script = row.mode == 'nested'
              ? 'java.connect(${jsonEncode("{{(function(){${logScript}return 'https://fixture.test/second';})()}}")});'
              : '$logScript${isCheck ? 'result;' : '"logged";'}';
          final evaluation = isCheck
              ? _check(runtime, script)
              : _eval(runtime, script);
          if (delta > 0) {
            await expectLater(
              evaluation,
              throwsA(
                isA<SourceScriptError>().having(
                  (error) => error.category,
                  'category',
                  'host-input-cap',
                ),
              ),
            );
            expect(
              runtime.messages.where((message) => message.kind == 'log'),
              isEmpty,
            );
            expect(transport.requests, isEmpty);
          } else {
            final value = await evaluation;
            expect(
              runtime.messages
                  .where((message) => message.kind == 'log')
                  .map((message) => message.message),
              [message],
            );
            if (isCheck) {
              final response = value as SourceStageResponse;
              if (row.mode == 'nested') {
                expect(response.body, isEmpty);
                expect(response.url.toString(), 'https://fixture.test/second');
                expect(response.statusCode, 502);
                expect(response.httpResponse, (
                  statusCode: 502,
                  bodyByteLength: 0,
                  url: Uri.parse('https://fixture.test/second'),
                ));
                expect(transport.requests.single.method, 'GET');
                expect(
                  transport.requests.single.url.toString(),
                  'https://fixture.test/second',
                );
              } else {
                expect(response.toJson(), _initial().toJson());
                expect(response.httpResponse, _initial().httpResponse);
                expect(transport.requests, isEmpty);
              }
            } else {
              expect(value, 'logged');
              expect(transport.requests, isEmpty);
            }
          }
        });
      }
    }
  });

  test(
    'inherited descriptor accessor cannot change the selected response after authentication',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var descriptorAccessorSession = true;',
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      try {
        final selected = await _check(runtime, '''
var wrapper = java.getStrResponse();
globalThis.decodedLeak = wrapper.__response();
globalThis.inheritedReads = 0;
Object.defineProperty(Object.prototype, 'writable', {configurable:true, get:function() {
  globalThis.inheritedReads++;
  globalThis.decodedLeak.body = 'changed-after-authentication';
  delete Object.prototype.writable;
  return true;
}});
wrapper;
''');
        final state = await _eval(runtime, '''
[globalThis.inheritedReads, globalThis.decodedLeak.body, Object.prototype.hasOwnProperty('writable')];
''');
        // The envelope is built from the authenticated snapshot with own data
        // descriptors: nothing the source left on Object.prototype runs while
        // it is built, and the reported fields stay what the transport sent.
        // The accessor was never invoked, so it stays installed until the
        // test removes it.
        expect(selected.toJson(), _replacement().toJson());
        expect(selected.httpResponse, _replacement().httpResponse);
        expect(state, [0, '', true]);
      } finally {
        await _eval(
          runtime,
          "delete Object.prototype.writable; delete globalThis.decodedLeak; "
          "delete globalThis.inheritedReads; true;",
        );
      }
    },
  );

  test(
    'native conversion cannot change the selected response after authentication',
    () async {
      final transport = _HostResponses();
      final runtime = InProcessSourceScriptRuntime(
        jsLib: 'var conversionProbeSession = true;',
        dispatcher: SourceHostDispatcher(transport: transport),
      );
      try {
        final selected = await _check(runtime, '''
var leaked = result.__response();
globalThis.decodedLeak = leaked;
globalThis.probeCalls = 0;
Object.defineProperty(ArrayBuffer, Symbol.hasInstance, {configurable:true, value:function(candidate) {
  globalThis.probeCalls++;
  globalThis.decodedLeak.body = 'changed-during-conversion';
  return false;
}});
result;
''');
        final probeCalls = await _eval(runtime, 'globalThis.probeCalls;');
        final leakedBody = await _eval(runtime, 'globalThis.decodedLeak.body;');
        // Dart receives a fresh record, so code that runs while the returned
        // value is converted changes only the source's own object.
        expect(probeCalls, greaterThan(0));
        expect(selected.toJson(), _initial().toJson());
        expect(selected.httpResponse, _initial().httpResponse);
        expect(leakedBody, 'changed-during-conversion');
      } finally {
        await _eval(
          runtime,
          "delete ArrayBuffer[Symbol.hasInstance]; delete globalThis.decodedLeak; "
          "delete globalThis.probeCalls; true;",
        );
      }
    },
  );
}
