import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';

Future<void> main(List<String> args) async {
  await InProcessSourceScriptRuntime.initialize(libraryPath: args.single);
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final origin = 'http://127.0.0.1:${server.port}';
  final requests = <String>[];
  server.listen((request) async {
    requests.add(request.uri.path);
    final response = switch (request.uri.path) {
      '/search' => jsonEncode({
        'books': [
          {'name': 'Nested book', 'url': '/book'},
        ],
      }),
      '/book' => jsonEncode({'name': 'Nested book', 'toc': '/toc'}),
      '/toc' => jsonEncode({
        'chapters': [
          {'name': 'Chapter 1', 'url': '/content'},
        ],
      }),
      '/content' => jsonEncode({'text': 'Nested chapter'}),
      '/address' => '$origin/final',
      _ => request.uri.path,
    };
    request.response.write(response);
    await request.response.close();
  });
  final host = SourceHostDispatcher(transport: HttpSourceTransport());
  const library =
      'var label="original"; const state = {n:0}; function bump(){return ++state.n;} function sharedBinding(){return typeof key;}';
  final runtime = InProcessSourceScriptRuntime(
    dispatcher: host,
    jsLib: library,
  );
  final checks = <String, bool>{};
  Future<Object?> run(
    String code, {
    InProcessSourceScriptRuntime? using,
    Duration timeout = const Duration(seconds: 3),
  }) => (using ?? runtime).evaluate(
    source: code,
    input: {'sourceKey': origin, 'key': 'outer-key', 'page': 7},
    timeout: timeout,
  );
  try {
    checks['nestedSharedClosure'] =
        await run(
          'var outerOnly=123; java.ajax(${jsonEncode('$origin/{{bump()}}')})',
        ) ==
        '/1';
    checks['subsequentSharedClosure'] = await run('bump()') == 2;
    checks['sameLibraryAcrossInstances'] =
        await run(
          'bump()',
          using: InProcessSourceScriptRuntime(dispatcher: host, jsLib: library),
        ) ==
        3;
    checks['freshOuterBindings'] = await run('typeof outerOnly') == 'undefined';
    checks['assignmentShadowsLibrary'] =
        await run('label="local"; label') == 'local' &&
        await run('label') == 'original';
    checks['libraryDoesNotCaptureBindings'] =
        await run('sharedBinding()') == 'undefined';
    checks['freshNestedBindings'] =
        await run(
          'java.ajax(${jsonEncode('$origin/{{key===null && page===null && typeof outerOnly==="undefined"}}')})',
        ) ==
        '/true';
    final inner = 'java.ajax(${jsonEncode('$origin/address')})';
    checks['twoLevelHostCalls'] =
        await run('java.ajax(${jsonEncode('@js:$inner')})') == '/final';
    checks['xmlJsBlock'] =
        await run(
          'java.connect(${jsonEncode('<js>"$origin/" + bump()</js>')}).body()',
        ) ==
        '/4';
    checks['outerResumes'] =
        await run('java.ajax(${jsonEncode('$origin/{{bump()}}')}); bump()') ==
        6;
    final countBeforeError = requests.length;
    try {
      await run(
        'java.ajax(${jsonEncode('$origin/{{throw new Error("nested-marker")}}')})',
      );
      checks['nestedErrorBeforeIo'] = false;
    } on SourceScriptError catch (error) {
      checks['nestedErrorBeforeIo'] =
          error.category == 'js' && requests.length == countBeforeError;
    }
    checks['caughtNestedErrorKeepsLibrary'] =
        await run(
          'try { java.ajax(${jsonEncode('$origin/{{throw new Error("caught")}}')}); } catch(e) {} state.n',
        ) ==
        6;
    try {
      await run(
        'java.ajax(${jsonEncode('$origin/{{while(true);}}')})',
        timeout: const Duration(milliseconds: 150),
      );
      checks['nestedLoopCancelled'] = false;
    } on SourceScriptError catch (error) {
      checks['nestedLoopCancelled'] = error.category == 'timeout';
    }
    // Frozen state oracle proves cancellation retains the shared scope.
    checks['afterCancellationKeepsState'] = await run('bump()') == 7;
    try {
      await run(
        '1',
        using: InProcessSourceScriptRuntime(jsLib: 'while(true) {}'),
        timeout: const Duration(milliseconds: 150),
      );
      checks['libraryInitCancelled'] = false;
    } on SourceScriptError catch (error) {
      checks['libraryInitCancelled'] = error.category == 'timeout';
    }
    checks['sequentialCounter'] = await run('bump()') == 8;
    final results = await Future.wait(List.generate(4, (_) => run('bump()')));
    final counterValues = results.cast<num>().toList()..sort();
    checks['concurrentCallsKeepState'] =
        jsonEncode(counterValues) == '[9,10,11,12]';
    final source = <String, dynamic>{
      'bookSourceUrl': origin,
      'jsLib': library,
      'searchUrl':
          '/search?count={{bump()}}&nested={{java.ajax("$origin/{{bump()}}")}}',
      'ruleSearch': {
        'bookList': r'$.books[*]',
        'name': r'$.name',
        'bookUrl': r'$.url',
      },
      'ruleBookInfo': {'name': r'$.name', 'tocUrl': r'$.toc'},
      'ruleToc': {
        'chapterList': r'$.chapters[*]',
        'chapterName': r'$.name',
        'chapterUrl': r'$.url',
      },
      'ruleContent': {'content': r'$.text'},
    };
    // Assemble the inner delimiters at runtime: frozen URL interpolation uses
    // the first closing delimiter, not a balanced JS parser.
    source['searchUrl'] =
        '/search?count={{bump()}}&nested={{java.ajax("$origin/"+"{"+"{bump()}"+"}")}}';
    final book = await JsonSourcePipeline(
      HttpSourceTransport(),
    ).run(source, 'test', (_) {});
    checks['jsonFourStagesWithNestedLibrary'] =
        book.title == 'Nested book' &&
        book.content == 'Nested chapter' &&
        requests.contains('/14');
    final pass = checks.values.every((value) => value);
    stdout.writeln(
      jsonEncode({
        'status': pass ? 'pass' : 'fail',
        'checks': checks,
        'requests': requests,
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    await server.close(force: true);
    await InProcessSourceScriptRuntime.dispose();
  }
}
