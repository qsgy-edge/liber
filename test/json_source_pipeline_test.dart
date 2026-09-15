import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/json_source_pipeline.dart';

void main() {
  test(
    'Legado JSON fields drive four HTTP stages and parsed reading result',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final paths = <String>[];
      server.listen((request) async {
        paths.add(request.uri.toString());
        final body = switch (request.uri.path) {
          '/search' => {
            'items': [
              {'name': 'Changed title', 'url': '/details/73'},
            ],
          },
          '/details/73' => {'title': '真实解析标题', 'toc': '/chapters/95'},
          '/chapters/95' => {
            'list': [
              {'label': '首章', 'href': '/text/108'},
              {'label': '次章', 'href': '/text/109'},
            ],
          },
          '/text/108' => {'body': '正文包含中文和 emoji 😀'},
          _ => {'error': 'Unexpected path'},
        };
        request.response.write(jsonEncode(body));
        await request.response.close();
      });
      final source = <String, dynamic>{
        'bookSourceUrl': 'http://127.0.0.1:${server.port}',
        'searchUrl': '/search?key={{key}}&page={{page}}',
        'ruleSearch': {
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
        },
        'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
        'ruleToc': {
          'chapterList': r'$.list',
          'chapterName': r'$.label',
          'chapterUrl': r'$.href',
        },
        'ruleContent': {'content': r'$.body'},
      };
      final states = <BookSourceStage>[];
      final pipeline = JsonSourcePipeline(HttpSourceTransport());
      final output = await pipeline.run(
        source,
        '书 & A',
        (state) => states.add(state.stage),
      );
      expect(output.title, '真实解析标题');
      expect(output.chapters.map((chapter) => chapter.name), ['首章', '次章']);
      expect(output.content, '正文包含中文和 emoji 😀');
      expect(paths.skip(1), ['/details/73', '/chapters/95', '/text/108']);
      // The frozen runtime substitutes `{{key}}` raw and only then re-encodes
      // the query, so a keyword `&` splits the query exactly as it does there:
      // the literal first pair, then an empty pair from the ` A` remainder.
      expect(Uri.parse(paths.first).queryParameters, {
        'key': '书 ',
        ' A': '',
        'page': '1',
      });
      expect(output.trace, hasLength(4));
      expect(states.last, BookSourceStage.completed);

      // Unsupported rules fail before sending any request.
      source['ruleContent'] = {'content': '@js:result'};
      await expectLater(
        pipeline.run(source, 'x', (_) {}),
        throwsUnsupportedError,
      );
      expect(paths, hasLength(4));

      // Missing response data fails, rather than announcing canned success.
      source['ruleContent'] = {'content': r'$.missing'};
      states.clear();
      await expectLater(
        pipeline.run(source, 'x', (state) => states.add(state.stage)),
        throwsFormatException,
      );
      expect(states.last, BookSourceStage.failed);
      expect(states, isNot(contains(BookSourceStage.completed)));
    },
  );
}
