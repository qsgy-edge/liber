// Live triage: runs each exported source through the product
// pipelines and reports only stage outcomes. Never logs headers, tokens, URLs
// or response bodies. Not a golden and not a compatibility verdict.
//
// `--usage <backup.zip|bookSource.json>` is the static half (source_usage.dart):
// it counts the p5-windows-audit.md §3 capability families over the used set
// and the whole collection, is network-free, never initialises `fjs`, and
// prints counts only — no source record, URL, host, name or rule text.
//
// `--readiness <backup.zip|bookSource.json>` is the static audit
// (source_readiness.dart): it replays this product's own rule reads per record
// and reports ready-versus-refused counts by reason, network-free and with no
// `fjs` either. Counts and reason names only, as above.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';

import 'source_readiness.dart';
import 'source_usage.dart';

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
  final isJson = isJsonRuleSource(source);
  final stages = <String>[];
  final failures = <String, String>{};
  var stage = 'search';
  try {
    final transport = HttpSourceTransport();
    if (isJson) {
      final pipeline = JsonSourcePipeline(source, transport);
      await pipeline.run(keyword, (_) {});
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
  if (args.isNotEmpty && args.first == '--usage') {
    if (args.length != 2) {
      stderr.writeln(_usage);
      exitCode = 2;
      return;
    }
    stdout.write(renderUsageReport(readUsageReport(args[1])));
    return;
  }
  if (args.isNotEmpty && args.first == '--readiness') {
    if (args.length != 2) {
      stderr.writeln(_usage);
      exitCode = 2;
      return;
    }
    stdout.write(renderReadinessReport(readReadinessReport(args[1])));
    return;
  }
  if (args.length < 2) {
    stderr.writeln(_usage);
    exitCode = 2;
    return;
  }
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

const String _usage =
    'usage: dart run tool/source_triage.dart <fjs.dll> <exported sources>\n'
    '       dart run tool/source_triage.dart --usage '
    '<backup.zip|bookSource.json>\n'
    '       dart run tool/source_triage.dart --readiness '
    '<backup.zip|bookSource.json>';
