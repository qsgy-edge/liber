import 'dart:convert';
import 'dart:io';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/json_source_pipeline.dart';

Future<void> main(List<String> args) async {
  final data = jsonDecode(await File(args.single).readAsString());
  final source = Map<String, dynamic>.from(
    (data as List).singleWhere(
      (s) => '${s['bookSourceName']}'.contains('猫眼看书'),
    ),
  );
  final keyword = (source['ruleSearch'] as Map)['checkKeyWord'] as String;
  final trace = <BookSourceStage>[];
  try {
    final result = await JsonSourcePipeline(source, HttpSourceTransport()).run(
      keyword,
      (s) {
        trace.add(s.stage);
      },
    );
    stdout.writeln(
      jsonEncode({
        'status': 'pass',
        'stages': trace.map((x) => x.name).toList(),
        'title': result.title,
        'chapters': result.chapters.length,
        'contentChars': result.content.length,
        'oracle': 'not-run',
      }),
    );
  } catch (e, stack) {
    stdout.writeln(
      jsonEncode({
        'status': 'fail',
        'stages': trace.map((x) => x.name).toList(),
        'errorType': e.runtimeType.toString(),
        'error': '$e',
        'stack': '$stack',
        'oracle': 'not-run',
      }),
    );
    exitCode = 1;
  }
}
