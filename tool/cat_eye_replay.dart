import 'dart:convert';
import 'dart:io';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/json_source_rules.dart';

class ReplayTransport implements BookSourceTransport {
  final requests = <String>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add('${stage.name} $path');
    final uri = Uri.parse(path);
    return switch (uri.path) {
      '/search' => jsonEncode({
        'data': [
          {
            'novelId': '42',
            'novelName': '猫眼回放',
            'authorName': '作者乙',
            'summary': '简介',
          },
        ],
      }),
      '/novel/42' => jsonEncode({
        'novelId': '42',
        'novelName': '猫眼回放',
        'authorName': '作者乙',
        'summary': '详情简介',
        'lastChapter': {'chapterName': '第一章', 'decTime': '今天'},
        'data': {'novelId': '42'},
      }),
      '/novel/42/chapters' => jsonEncode({
        'data': {
          'list': [
            {
              'chapterName': '第一章',
              'path': 'ZNHm0NWHUFEH+JzlOpuCYVCc7ghsK2gE2mLykwdzpcM=',
            },
          ],
        },
      }),
      '/content/1' => jsonEncode({'content': '猫眼正文'}),
      _ => throw StateError('unexpected replay path $path'),
    };
  }
}

Future<void> main() async {
  final source = <String, dynamic>{
    'bookSourceName': '猫眼看书回放',
    'bookSourceUrl': 'http://replay',
    'searchUrl': '/search?keyword=' r'{{key}}' '&page=' r'{{page}}',
    'ruleSearch': {
      'bookList': r'$.data[*]',
      'name': r'$.novelName',
      'bookUrl': '/novel/' r'{{$.novelId}}',
    },
    'ruleBookInfo': {
      'name': r'$.novelName',
      'tocUrl': '/novel/' r'{{$.novelId}}/chapters',
    },
    'ruleToc': {
      'chapterList': r'$.data.list[*]',
      'chapterName': r'$.chapterName',
      'chapterUrl': r'$.path @js:java.aesBase64DecodeToString',
    },
    'ruleContent': {'content': r'$.content'},
  };
  final transport = ReplayTransport();
  // The decrypted URL is made explicit in the fixture and checked independently;
  // the pipeline's JSON path and four request stages remain deterministic.
  final decrypted = aesBase64DecodeToString(
    'ZNHm0NWHUFEH+JzlOpuCYVCc7ghsK2gE2mLykwdzpcM=',
    'f041c49714d39908',
    '0123456789abcdef',
  );
  final result = await JsonSourcePipeline(source, transport).run('猫眼', (_) {});
  final pass =
      result.title == '猫眼回放' &&
      result.chapters.single.name == '第一章' &&
      result.content == '猫眼正文' &&
      decrypted == 'http://replay/content/1' &&
      transport.requests.length == 4;
  stdout.writeln(
    jsonEncode({
      'status': pass ? 'pass' : 'fail',
      'requests': transport.requests,
      'title': result.title,
      'chapterUrl': decrypted,
      'content': result.content,
    }),
  );
  if (!pass) exitCode = 1;
}
