// Supplemental live check. Reads a user-supplied source without logging headers,
// raw definitions, response bodies or URLs. This does not generate a golden.
import 'dart:convert';
import 'dart:io';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';

class ObservedLiveTransport extends HttpSourceTransport {
  int _sequence = 0;

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    final id = ++_sequence;
    final watch = Stopwatch()..start();
    stdout.writeln(
      jsonEncode({'request': id, 'event': 'start', 'method': request.method}),
    );
    try {
      final response = await super.send(request);
      stdout.writeln(
        jsonEncode({
          'request': id,
          'event': 'response',
          'elapsedMs': watch.elapsedMilliseconds,
          'statusCode': response.statusCode,
          'bodyBytes': utf8.encode(response.body).length,
        }),
      );
      return response;
    } catch (error) {
      stdout.writeln(
        jsonEncode({
          'request': id,
          'event': 'failed',
          'elapsedMs': watch.elapsedMilliseconds,
          'errorType': error.runtimeType.toString(),
        }),
      );
      rethrow;
    }
  }
}

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError('Expected native library and private source file');
  }
  final input = jsonDecode(await File(args[1]).readAsString());
  final definitions = input is List ? input : [input];
  final source = Map<String, dynamic>.from(
    definitions.whereType<Map>().singleWhere(
      (s) => '${s['bookSourceName']}'.contains('就爱文学'),
    ),
  );
  await InProcessSourceScriptRuntime.initialize(libraryPath: args[0]);
  final pipeline = HtmlSourcePipeline(
    source,
    // Use the product's default 30-second request budget.
    ObservedLiveTransport(),
  );
  final stages = <String>[];
  var stage = 'search';
  try {
    final hits = await pipeline.search(
      '${(source['ruleSearch'] as Map)['checkKeyWord'] ?? '剑来'}',
    );
    if (hits.isEmpty) throw StateError('No search results');
    stages.add(stage);
    stdout.writeln(jsonEncode({'stage': stage, 'bookCount': hits.length}));
    stage = 'info+toc';
    final (_, toc) = await pipeline.details(hits.first);
    if (toc.isEmpty) throw StateError('No chapters');
    stages.addAll(['info', 'toc']);
    stdout.writeln(jsonEncode({'stage': stage, 'chapterCount': toc.length}));
    stage = 'content';
    final body = await pipeline.chapter(toc.first);
    if (body.text.isEmpty) throw StateError('No content');
    stages.add(stage);
    stdout.writeln(
      jsonEncode({
        'status': 'pass',
        'stages': stages,
        'contentChars': body.text.length,
        'contentPages': body.pages,
        'oracle': 'not-run',
      }),
    );
  } catch (error) {
    stdout.writeln(
      jsonEncode({
        'status': 'fail',
        'stages': stages,
        'failedStage': stage,
        'errorType': error.runtimeType.toString(),
        if (error is SourceScriptError) 'category': error.category,
        'oracle': 'not-run',
      }),
    );
    exitCode = 1;
  } finally {
    pipeline.cancel();
    await InProcessSourceScriptRuntime.dispose();
  }
}
