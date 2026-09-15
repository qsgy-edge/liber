import 'dart:convert';
import 'dart:io';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';

/// Synthetic local responses; this is a regression fixture, not an oracle golden.
Future<void> main(List<String> args) async {
  final serve = args.contains('--serve');
  final source =
      jsonDecode(
            await File.fromUri(
              Platform.script.resolve('../test/fixtures/jiuai_replay.json'),
            ).readAsString(),
          )
          as Map<String, dynamic>;
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  source['bookSourceUrl'] = 'http://127.0.0.1:${server.port}/start';
  final requests = <Map<String, Object?>>[];
  final pages = <String, String>{
    '/landing/': '<html><body>本地站点入口</body></html>',
    '/landing/s.php':
        '<ul class="result"><li><a>[玄幻]</a><a href="/book/1">回放之书</a><span>/作者甲</span></li><li><a>[历史]</a><a href="/book/2">另一本书</a><span>/作者乙</span></li></ul>',
    '/book/1':
        '<dl><dd><h2>回放之书</h2></dd></dl><div class="info"><span>时间：今天</span><span>分类：玄幻</span><span>作者甲</span><span>状态：连载</span><a>第二章</a></div><div class="content">本地回放的书籍简介。</div><p class="p2"><a href="/toc/1">目录</a></p>',
    '/book/2':
        '<dl><dd><h2>另一本书</h2></dd></dl><div class="content">第二本书。</div><p class="p2"><a href="/toc/1">目录</a></p>',
    '/toc/1':
        '<ul class="chapters"><li><a href="/ignored">列表标题</a></li><li><a href="/chapter/1">第一章</a></li><li><a href="/chapter/2">第二章</a></li></ul>',
    '/chapter/1':
        '<div class="chapter_content">第一页正文。<br>第二段。<span>不应提取的嵌套广告</span><br>（本章未完，请继续阅读）</div><a href="/chapter/1-2">下一页</a>',
    '/chapter/1-2':
        '<div class="chapter_content">第二页正文。<br>本章结束。</div><a href="/chapter/2">下一章</a>',
    '/chapter/2': '<div class="chapter_content">第二章正文。</div>',
  };
  final subscription = server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    requests.add({
      'method': request.method,
      'path': request.uri.path,
      'body': body,
      'userAgent': request.headers.value('user-agent'),
      'contentType': request.headers.contentType?.mimeType,
    });
    if (request.uri.path == '/start') {
      request.response.statusCode = 302;
      request.response.headers.set('location', '/landing/');
    } else {
      request.response.headers.contentType = ContentType.html;
      final page = pages[request.uri.path];
      if (page == null) request.response.statusCode = 404;
      request.response.write(page ?? 'Unexpected replay path');
    }
    await request.response.close();
  });
  if (serve) {
    final outputArgument = args.firstWhere(
      (v) => v.startsWith('--source-out='),
    );
    final file = File(outputArgument.substring('--source-out='.length));
    await file.writeAsString(jsonEncode(source));
    stdout.writeln(
      jsonEncode({'ready': true, 'sourceFile': file.path, 'port': server.port}),
    );
    return; // The server subscription keeps this optional manual-review process alive.
  }
  final library = args.isEmpty ? null : args.single;
  await InProcessSourceScriptRuntime.initialize(libraryPath: library);
  try {
    final pipeline = HtmlSourcePipeline(source, HttpSourceTransport());
    final hits = await pipeline.search('回放');
    final (book, toc) = await pipeline.details(hits.first);
    final body = await pipeline.chapter(toc.first);
    final checks = <String, bool>{
      'twoSearchHits': hits.map((b) => b.title).join('|') == '回放之书|另一本书',
      'searchAuthor': hits.first.author == '作者甲',
      'sourceMetadata':
          hits.first.kind == '玄幻' &&
          book.kind == '玄幻\n连载\n今天' &&
          book.lastChapter == '第二章',
      'bookInfo':
          book.title == '回放之书' &&
          book.author == '作者甲' &&
          book.intro == '本地回放的书籍简介。',
      'tocOrderAndExclusion': toc.map((c) => c.name).join('|') == '第一章|第二章',
      'twoContentPages': body.pages == 2,
      'exactTextNodesAndReplacement':
          body.text == '第一页正文。\n第二段。\n第二页正文。\n本章结束。',
      'allFourStages':
          pipeline.trace.map((e) => e.stage.name).toSet().length == 4,
      'exactRequestOrder':
          requests.map((r) => '${r['method']} ${r['path']}').join('|') ==
          'GET /start|GET /landing/|POST /landing/s.php|GET /book/1|GET /toc/1|GET /chapter/1|GET /chapter/1-2',
      'exactFormBody':
          requests[2]['body'] ==
          'submit=%E6%90%9C%E7%B4%A2&type=articlename&s=%E5%9B%9E%E6%94%BE',
      'formContentType':
          requests[2]['contentType'] == 'application/x-www-form-urlencoded',
      'sourceHeaderOnEveryRequest': requests.every(
        (r) => r['userAgent'] == 'Liber local replay',
      ),
    };
    pipeline.cancel();
    final pass = checks.values.every((v) => v);
    stdout.writeln(
      jsonEncode({
        'status': pass ? 'pass' : 'fail',
        'checks': checks,
        'requests': requests,
        'content': body.text,
        'oracle': 'not-run',
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    await subscription.cancel();
    await server.close(force: true);
    await InProcessSourceScriptRuntime.dispose();
  }
}
