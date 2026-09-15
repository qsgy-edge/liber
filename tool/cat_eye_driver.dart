import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:liber/migration/migration_service.dart';
import 'package:liber/source/source_trial_page.dart';

Future<void> main() async {
  enableFlutterDriverExtension();
  WidgetsFlutterBinding.ensureInitialized();

  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    debugPrint(
      'NESTED_DRIVER ${request.uri.path} n=${request.uri.queryParameters['n'] ?? ''}',
    );
    final body = switch (request.uri.path) {
      '/token' => 7,
      '/search' => {
        'data': [
          {
            'novelId': '42',
            'novelName': '猫眼回放',
            'authorName': '作者乙',
            'summary': '简介',
          },
        ],
      },
      '/novel/42' => {
        'novelId': '42',
        'novelName': '猫眼回放',
        'authorName': '作者乙',
        'summary': '详情简介',
      },
      '/novel/42/chapters' => {
        'data': {
          'list': [
            {
              'chapterName': '第一章',
              'path': 'http://127.0.0.1:${server.port}/content/1',
            },
          ],
        },
      },
      '/content/1' => {'content': '猫眼正文'},
      _ => {'error': 'unexpected path ${request.uri.path}'},
    };
    request.response
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(body));
    await request.response.close();
  });

  final source = <String, dynamic>{
    'bookSourceName': '猫眼看书回放',
    'bookSourceUrl': 'http://127.0.0.1:${server.port}/',
    'jsLib': 'const counter={n:0}; function next(){return ++counter.n;}',
    'searchUrl':
        '/search?keyword={{key}}&page={{page}}&token={{java.ajax("http://127.0.0.1:${server.port}/token?n="+"{"+"{next()}"+"}")}}',
    'ruleSearch': {
      'bookList': r'$.data[*]',
      'name': r'$.novelName',
      'bookUrl': r'/novel/{{$.novelId}}',
    },
    'ruleBookInfo': {
      'name': r'$.novelName',
      'tocUrl': r'/novel/{{$.novelId}}/chapters',
    },
    'ruleToc': {
      'chapterList': r'$.data.list[*]',
      'chapterName': r'$.chapterName',
      'chapterUrl': r'$.path',
    },
    'ruleContent': {'content': r'$.content'},
  };

  runApp(
    MaterialApp(
      home: SourceTrialPage(
        sources: [ImportedBookSource(id: 'cat-eye', data: source)],
      ),
    ),
  );
}
