// Live triage: runs each exported source through the product
// pipelines and reports only stage outcomes. Never logs headers, tokens, URLs
// or response bodies. Not a golden and not a compatibility verdict.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';

String describe(Object error) {
  if (error is SourceScriptError) {
    return '${error.runtimeType}/${error.category}'
        '${error.message.isEmpty ? '' : ':${error.message.split('\n').first}'}';
  }
  if (error is UnsupportedError) return 'UnsupportedError:${error.message}';
  final text = '$error'.split('\n').first;
  return '${error.runtimeType}:${text.length > 120 ? text.substring(0, 120) : text}';
}

Future<Map<String, Object?>> triage(
  Map<String, dynamic> source,
  String keyword,
) async {
  final listRule = '${(source['ruleSearch'] as Map?)?['bookList'] ?? ''}';
  final isJson =
      listRule.startsWith('@Json:') ||
      listRule.startsWith(r'$.') ||
      listRule.startsWith(r'$[');
  final stages = <String>[];
  final failures = <String, String>{};
  var stage = 'search';
  try {
    final transport = HttpSourceTransport();
    if (isJson) {
      final pipeline = JsonSourcePipeline(transport);
      await pipeline.run(source, keyword, (_) {});
      stages.addAll(['search', 'info', 'toc', 'content']);
    } else {
      final pipeline = HtmlSourcePipeline(source, transport);
      final hits = await pipeline.search(keyword);
      if (hits.isEmpty) throw StateError('No search results');
      stages.add('search');
      stage = 'info/toc';
      final (_, toc) = await pipeline.details(hits.first);
      if (toc.isEmpty) throw StateError('No chapters');
      stages.addAll(['info', 'toc']);
      stage = 'content';
      final body = await pipeline.chapter(toc.first);
      if (body.text.isEmpty) throw StateError('No content');
      stages.add('content');
      pipeline.cancel();
    }
  } catch (error) {
    failures[stage] = describe(error);
  }
  return {
    'status': failures.isEmpty ? 'pass' : 'fail',
    'pipeline': isJson ? 'json' : 'html',
    'stages': stages,
    'failures': failures,
  };
}

Future<void> main(List<String> args) async {
  final library = args[0];
  final export = jsonDecode(await File(args[1]).readAsString(encoding: utf8));
  final definitions = (export is List ? export : [export]).whereType<Map>();
  await InProcessSourceScriptRuntime.initialize(libraryPath: library);
  try {
    for (final entry in definitions) {
      final source = Map<String, dynamic>.from(entry);
      final name = '${source['bookSourceName']}';
      final keyword =
          '${(source['ruleSearch'] as Map?)?['checkKeyWord'] ?? '剑来'}';
      final watch = Stopwatch()..start();
      final result = await triage(source, keyword).timeout(
        const Duration(seconds: 90),
        onTimeout: () => <String, Object?>{
          'status': 'timeout',
          'failures': {'stage': 'budget'},
        },
      );
      stdout.writeln(
        jsonEncode({
          'source': name,
          'elapsedMs': watch.elapsedMilliseconds,
          ...result,
        }),
      );
    }
  } finally {
    await InProcessSourceScriptRuntime.dispose();
  }
}
