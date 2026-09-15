import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/source_host_dispatcher.dart';

// Exercises the synchronous product request bridge, source-session cookies,
// and the request-semantics slice (URL options plus dynamic source headers).
Future<void> main(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final observed = <String>[];
  final wire = <Map<String, Object?>>[];
  var retryHits = 0;
  const list =
      '<div class="container"><div class="item"><div class="itemtxt">'
      '<h3><a href="/book/">书</a></h3></div></div></div>';
  final sub = server.listen((request) async {
    final body = await utf8.decoder.bind(request).join();
    observed.add(
      '${request.uri.path}:${request.headers.value('cookie') ?? ''}',
    );
    wire.add({
      'path': request.uri.path,
      'query': request.uri.query,
      'method': request.method,
      'sourceHeader': request.headers.value('x-source'),
      'optionHeader': request.headers.value('x-option'),
      'contentType': request.headers.value('content-type'),
      'userAgent': request.headers.value('user-agent'),
      'keepAlive': request.headers.value('keep-alive'),
      'cacheControl': request.headers.value('cache-control'),
      'authorization': request.headers.value('authorization'),
      'cookie': request.headers.value('cookie'),
      'body': body,
    });
    if (request.uri.path == '/set') {
      request.response.headers.add('set-cookie', 'sid=one; Path=/');
      request.response.write('set');
    } else if (request.uri.path == '/echo') {
      request.response.write(request.headers.value('cookie') ?? '');
    } else if (request.uri.path == '/search') {
      request.response.write(list);
    } else if (request.uri.path == '/redirect302' ||
        request.uri.path == '/redirect307') {
      request.response.statusCode =
          request.uri.path == '/redirect302' ? 302 : 307;
      request.response.headers.set('Location', '/after');
      request.response.write('redirect');
    } else if (request.uri.path == '/after') {
      request.response.write(list);
    } else if (request.uri.path == '/retry') {
      retryHits++;
      if (retryHits == 1) {
        request.response.statusCode = 500;
        request.response.write('retry');
      } else {
        request.response.write(list);
      }
    } else if (request.uri.path == '/json-search') {
      request.response.write(
        jsonEncode({
          'items': [
            {'name': '标题', 'url': '/json-details'},
          ],
        }),
      );
    } else if (request.uri.path == '/json-details') {
      request.response.write(
        jsonEncode({'title': '标题', 'toc': '/json-chapters'}),
      );
    } else if (request.uri.path == '/json-chapters') {
      request.response.write(
        jsonEncode({
          'list': [
            {'label': '首章', 'href': '/json-text'},
          ],
        }),
      );
    } else if (request.uri.path == '/json-text') {
      request.response.write(jsonEncode({'body': '正文'}));
    } else {
      request.response.statusCode = 404;
      request.response.write('missing');
    }
    await request.response.close();
  });
  var initialized = false;
  try {
    await InProcessSourceScriptRuntime.initialize(
      libraryPath: args.isEmpty ? null : args.single,
    );
    initialized = true;
    final runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
    );
    Future<Object?> call(String path) => runtime.evaluate(
      source:
          '''JSON.stringify(JSON.parse(fjs.bridge_call(JSON.stringify({method:'request',payload:{
        method:'GET',url:${jsonEncode('http://127.0.0.1:${server.port}$path')},headers:{}}
      }))).value)''',
      input: {},
      timeout: const Duration(seconds: 10),
    );
    final first = jsonDecode(await call('/set') as String) as Map;
    final second = jsonDecode(await call('/echo') as String) as Map;
    final missing = jsonDecode(await call('/missing') as String) as Map;
    final checks = {
      'firstBody': first['body'] == 'set',
      'cookieOnWire': observed.contains('/echo:sid=one'),
      'echoBody': second['body'] == 'sid=one',
      'httpErrorStatus': missing['statusCode'] == 404,
      'httpErrorBody': missing['body'] == 'missing',
      'multiValueHeaders': first['headers']['set-cookie'] is List,
      'exactRequests':
          observed.join('|') == '/set:|/echo:sid=one|/missing:sid=one',
    };

    // URL options plus an `@js:` source header on the HTML pipeline.
    final htmlSource = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'header': '@js:JSON.stringify({"X-Source":"html"})',
      'searchUrl':
          '/search,{"method":"POST","body":"key={{key}}",'
          '"headers":{"X-Option":"1"},'
          '"js":"result + (result.includes(\'?\') ? \'&js=1\' : \'?js=1\')"}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    final hits = await HtmlSourcePipeline(
      htmlSource,
      HttpSourceTransport(),
    ).search('甲');
    final search = wire.lastWhere((entry) => entry['path'] == '/search');
    checks['htmlOptionMethodAndBody'] =
        search['method'] == 'POST' &&
        search['body'] == 'key=%E7%94%B2' &&
        search['contentType'] == 'application/x-www-form-urlencoded';
    checks['htmlDynamicHeaderOnWire'] = search['sourceHeader'] == 'html';
    checks['htmlOptionHeaderMerged'] = search['optionHeader'] == '1';
    checks['htmlJsOptionRewroteUrl'] = search['query'] == 'js=1';
    checks['htmlSearchParsed'] = hits.single.title == '书';

    // The `retry` option repeats only non-2xx responses.
    final retrySource = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'searchUrl': '/retry,{"retry":1}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    final retryHitsBefore = wire
        .where((entry) => entry['path'] == '/retry')
        .length;
    final retryResult = await HtmlSourcePipeline(
      retrySource,
      HttpSourceTransport(),
    ).search('甲');
    final retryRequests =
        wire.where((entry) => entry['path'] == '/retry').length -
        retryHitsBefore;
    checks['retryOptionRepeatsNon2xx'] =
        retryRequests == 2 && retryResult.single.title == '书';

    // The same semantics on the JSON pipeline, with a `<js>` header rule.
    final jsonSource = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'header': '<js>JSON.stringify({"X-Source":"json"})</js>',
      'searchUrl': '/json-search,{"method":"POST","body":{"key":"{{key}}"}}',
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
    final output = await JsonSourcePipeline(
      HttpSourceTransport(),
    ).run(jsonSource, '甲', (_) {});
    final jsonSearch = wire.lastWhere(
      (entry) => entry['path'] == '/json-search',
    );
    checks['jsonDynamicHeaderOnWire'] = jsonSearch['sourceHeader'] == 'json';
    checks['jsonStructuredBody'] =
        jsonSearch['method'] == 'POST' &&
        jsonSearch['contentType'] == 'application/json; charset=UTF-8' &&
        jsonSearch['body'] == '{"key":"甲"}';
    checks['jsonPipelineCompleted'] =
        output.title == '标题' && output.content == '正文';

    // Request defaults: the frozen client's user agent and connection headers.
    const frozenUserAgent =
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
        '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';
    checks['defaultUserAgentOnWire'] = search['userAgent'] == frozenUserAgent;
    checks['defaultConnectionHeadersOnWire'] =
        search['keepAlive'] == '300' && search['cacheControl'] == 'no-cache';

    final declaredAgent = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'header': '{"User-Agent":"Liber gate/1.0"}',
      'searchUrl': '/search',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    await HtmlSourcePipeline(
      declaredAgent,
      HttpSourceTransport(),
    ).search('甲');
    checks['declaredUserAgentWins'] =
        wire.lastWhere((entry) => entry['path'] == '/search')['userAgent'] ==
        'Liber gate/1.0';

    // Redirect semantics: 302 turns a POST into a bodyless GET, 307 keeps it.
    Future<void> redirect(String path) async {
      await HtmlSourcePipeline(
        <String, dynamic>{
          'bookSourceUrl': 'http://127.0.0.1:${server.port}',
          'searchUrl':
              '/$path,{"method":"POST","body":"key={{key}}",'
              '"headers":{"Content-Type":"application/x-www-form-urlencoded"}}',
          'ruleSearch': {
            'bookList': '@CSS:.item',
            'name': '@CSS:h3 a@text',
            'bookUrl': '@CSS:h3 a@href',
          },
        },
        HttpSourceTransport(),
      ).search('甲');
    }

    await redirect('redirect302');
    final getAfter302 = wire.lastWhere((entry) => entry['path'] == '/after');
    checks['redirect302DowngradesPostToGet'] =
        getAfter302['method'] == 'GET' &&
        getAfter302['body'] == '' &&
        getAfter302['contentType'] == null;

    await redirect('redirect307');
    final postAfter307 = wire.lastWhere((entry) => entry['path'] == '/after');
    checks['redirect307KeepsMethodAndBody'] =
        postAfter307['method'] == 'POST' &&
        postAfter307['body'] == 'key=甲';

    // Keyword substitution is raw and the query is re-encoded exactly once,
    // with the frozen page list picking the entry for the requested page.
    final pagedSource = <String, dynamic>{
      'bookSourceUrl': 'http://127.0.0.1:${server.port}',
      'searchUrl': '/search?q={{key}}&page=<1,2,3>',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    };
    final paged = HtmlSourcePipeline(pagedSource, HttpSourceTransport());
    await paged.search('我 的');
    checks['rawKeyEncodedOnce'] =
        wire.lastWhere((entry) => entry['path'] == '/search')['query'] ==
        'q=%E6%88%91%20%E7%9A%84&page=1';
    await paged.search('我 的', page: 2);
    checks['pageListPicksRequestedPage'] =
        wire.lastWhere((entry) => entry['path'] == '/search')['query'] ==
        'q=%E6%88%91%20%E7%9A%84&page=2';

    final pass = checks.values.every((value) => value);
    stdout.writeln(
      jsonEncode({
        'status': pass ? 'pass' : 'fail',
        'checks': checks,
        'observed': observed,
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    if (initialized) await InProcessSourceScriptRuntime.dispose();
    await sub.cancel();
    await server.close(force: true);
  }
}
