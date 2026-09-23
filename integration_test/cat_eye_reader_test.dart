import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liber/source/source_trial_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import '../test/l10n_support.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cat eye source trial completes four stages through UI', (
    tester,
  ) async {
    final directory = await Directory.systemTemp.createTemp('liber-cat-eye-');
    final service = ShelfService(
      SpaceStore(SpaceDatabase.file(File('${directory.path}/data.db'))),
    );
    addTearDown(() async {
      await service.close();
      await directory.delete(recursive: true);
    });
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((request) async {
      final path = request.uri.path;
      debugPrint('CAT_EYE_REQUEST $path${request.uri.query}');
      final body = switch (path) {
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
        _ => {'error': 'unexpected path $path'},
      };
      request.response
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(body));
      await request.response.close();
    });

    final source = <String, dynamic>{
      'bookSourceName': '猫眼看书回放',
      'bookSourceUrl': 'http://127.0.0.1:${server.port}/',
      'searchUrl': '/search?keyword={{key}}&page={{page}}',
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

    await tester.pumpWidget(
      localizedApp(
        home: SourceTrialPage(
          service: service,
          sources: [ImportedBookSource(id: 'cat-eye', data: source)],
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '猫眼');
    await tester.tap(find.text('搜索'));
    await tester.pumpAndSettle(const Duration(seconds: 1));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    for (final widget in tester.widgetList<SelectableText>(
      find.byType(SelectableText),
    )) {
      debugPrint('CAT_EYE_STATUS ${widget.data}');
    }
    for (final widget in tester.widgetList<Text>(find.byType(Text))) {
      debugPrint('CAT_EYE_TEXT ${widget.data}');
    }

    expect(find.text('猫眼回放'), findsOneWidget);
    expect(find.text('1 章 · 第一章'), findsOneWidget);
    expect(find.text('猫眼正文'), findsOneWidget);
    expect(tester.takeException(), isNull);
    debugPrint('CAT_EYE_UI_PASS title=猫眼回放 content=猫眼正文');
  });
}
