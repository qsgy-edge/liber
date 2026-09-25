import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/native_library.dart';

import '../tool/source_smoke.dart';
import '../tool/source_usage.dart';
import 'native_library.dart';

/// The smoke tool's own rules (#95), over a loopback site walking a
/// two-chapter JSON source: the summary each stage produces, and the redaction
/// that keeps a URL's query token, the source's `header` values and the session
/// cookie out of the output.
///
/// The fixture is built here, in the repository, and carries no private data;
/// the token and the header value exist only so the output can be checked for
/// them.
void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  late Directory directory;
  late HttpServer server;
  late String origin;

  /// The addresses the site saw, so the header pin is not vacuous: the source's
  /// `header` really reached the wire, and still never reached the output.
  late List<({String path, String? query, String? apiKey})> requests;

  setUpAll(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    origin = 'http://127.0.0.1:${server.port}';
    requests = <({String path, String? query, String? apiKey})>[];
    server.listen((request) async {
      requests.add((
        path: request.uri.path,
        query: request.uri.hasQuery ? request.uri.query : null,
        apiKey: request.headers.value('x-api-key'),
      ));
      if (request.uri.path == '/bad/1') {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html><body>不是 JSON 的错误页</body></html>');
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.headers.set('set-cookie', 'session=COOKIESECRET');
        request.response.write(
          jsonEncode(switch (request.uri.path) {
            '/book/1' => <String, dynamic>{
              'title': '真实解析标题',
              'author': '作者甲',
              'toc': '/toc/95',
            },
            '/toc/95' => <String, dynamic>{
              'list': <Map<String, dynamic>>[
                {'label': '首章', 'href': '/text/108'},
                {'label': '次章', 'href': '/text/109'},
              ],
            },
            '/text/108' => <String, dynamic>{'body': '正文第一行\n第二行'},
            _ => <String, dynamic>{'error': 'unexpected path'},
          }),
        );
      }
      await request.response.close();
    });

    directory = Directory.systemTemp.createTempSync('liber_source_smoke');
    File('${directory.path}/bookSource.json').writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'bookSourceName': 'smoke fixture',
        'bookSourceUrl': origin,
        'header': '{"X-Api-Key":"HEADERSECRETVALUE"}',
        'enabledCookieJar': true,
        'ruleSearch': <String, dynamic>{
          'bookList': r'$.items',
          'name': r'$.name',
          'bookUrl': r'$.url',
        },
        'ruleBookInfo': <String, dynamic>{
          'name': r'$.title',
          'author': r'$.author',
          'tocUrl': r'$.toc',
        },
        'ruleToc': <String, dynamic>{
          'chapterList': r'$.list',
          'chapterName': r'$.label',
          'chapterUrl': r'$.href',
        },
        'ruleContent': <String, dynamic>{'content': r'$.body'},
      }),
    );
  });

  tearDownAll(() async {
    await server.close(force: true);
    directory.deleteSync(recursive: true);
  });

  test(
    'the smoke walks details, toc and the first chapter into a summary',
    () async {
      final backup = readSourceBackup('${directory.path}/bookSource.json');
      final report = await runSourceSmoke(
        backup: backup,
        source: findSmokeSource(backup, origin),
        bookUrl: '$origin/book/1?token=SECRETTOKEN',
      );

      expect(report.json, isTrue);
      expect(report.detailsRequests, ['$origin/book/1?token=$redactedValue']);
      expect(report.detailsTitle, '真实解析标题');
      expect(report.detailsAuthor, '作者甲');
      expect(report.tocRequests, ['$origin/toc/95']);
      expect(report.chapters, 2);
      expect(report.firstChapterName, '首章');
      expect(report.firstChapterUrl, '$origin/text/108');
      expect(report.chapterRequests, ['$origin/text/108']);
      expect(report.chapterLength, '正文第一行\n第二行'.length);
      expect(report.chapterFirstLine, '正文第一行');

      final text = renderSmokeReport(report);
      expect(text, contains('pipeline: json'));
      expect(text, contains('collection: 1 records from'));
      expect(text, contains('title: 真实解析标题'));
      expect(text, contains('author: 作者甲'));
      expect(text, contains('chapters: 2'));
      expect(text, contains('first chapter: 首章'));
      expect(text, contains('first chapter url: $origin/text/108'));
      expect(text, contains('length: ${'正文第一行\n第二行'.length} characters'));
      expect(text, contains('first line: 正文第一行'));
    },
  );

  test(
    'the output redacts query values and never reads out headers or cookies',
    () async {
      final backup = readSourceBackup('${directory.path}/bookSource.json');
      final report = await runSourceSmoke(
        backup: backup,
        source: findSmokeSource(backup, origin),
        bookUrl: '$origin/book/1?token=SECRETTOKEN',
      );
      final text = renderSmokeReport(report);

      expect(text, contains('token=$redactedValue'));
      expect(text, isNot(contains('SECRETTOKEN')));
      expect(text, isNot(contains('HEADERSECRETVALUE')));
      expect(text, isNot(contains('COOKIESECRET')));
      // The source's header really was sent on every request, so its absence from
      // the output is the tool's doing and not an unused field.
      expect(requests, isNotEmpty);
      expect(requests.map((request) => request.apiKey).toSet(), {
        'HEADERSECRETVALUE',
      });
    },
  );

  test(
    'a failed stage names itself with the address and the message',
    () async {
      final backup = readSourceBackup('${directory.path}/bookSource.json');
      SourceSmokeFailure? failure;
      try {
        await runSourceSmoke(
          backup: backup,
          source: findSmokeSource(backup, origin),
          bookUrl: '$origin/bad/1?token=SECRETTOKEN',
        );
      } on SourceSmokeFailure catch (error) {
        failure = error;
      }

      expect(failure, isNotNull);
      expect(failure!.reason, 'details-failed');
      expect(failure.stage, 'details');
      expect(failure.address, '$origin/bad/1?token=$redactedValue');
      expect(failure.message, contains('不是 JSON'));
      final text = renderSmokeFailure(failure);
      expect(text, contains('source smoke failed: details-failed'));
      expect(text, contains('stage: details'));
      expect(text, contains('address: $origin/bad/1?token=$redactedValue'));
      expect(text, isNot(contains('SECRETTOKEN')));
    },
  );

  test(
    'a missing flag is a usage error and a missing record is a named failure',
    () async {
      expect(
        () => parseSmokeArguments(['--backup', 'a.zip']),
        throwsA(isA<FormatException>()),
      );

      final usageError = StringBuffer();
      expect(await runSmokeCli(<String>[], err: usageError), 2);
      expect(usageError.toString(), contains('usage: $smokeUsage'));

      final notFound = StringBuffer();
      expect(
        await runSmokeCli(<String>[
          '--backup',
          '${directory.path}/bookSource.json',
          '--source',
          'https://missing.example',
          '--book',
          '$origin/book/1',
        ], err: notFound),
        1,
      );
      expect(notFound.toString(), contains('source-not-found'));
    },
  );
}
