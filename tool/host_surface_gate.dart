import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_dispatcher.dart';

// Exercises the JavaScript host surface a Book Source sees: source accessors,
// rule state, cookies, cache, logging, and the encoding/utility family. Every
// member is named in [expectedMembers], so the gate fails when one disappears.
const expectedMembers = <String>[
  'source.getKey',
  'source.getName',
  'source.getTag',
  'source.getVariable',
  'source.put',
  'source.get',
  'source.bookSourceUrl',
  'source.bookSourceName',
  'java.connect',
  'java.ajax',
  'java.get',
  'java.head',
  'java.post',
  'java.put',
  'java.toast',
  'java.longToast',
  'java.log',
  'java.logType',
  'java.strToBytes',
  'java.bytesToStr',
  'java.base64Encode',
  'java.base64Decode',
  'java.base64DecodeToByteArray',
  'java.hexEncodeToString',
  'java.hexDecodeToString',
  'java.hexDecodeToByteArray',
  'java.encodeURI',
  'java.htmlFormat',
  'java.timeFormat',
  'java.timeFormatUTC',
  'java.randomUUID',
  'java.toNumChapter',
  'java.toURL',
  'cookie.setCookie',
  'cookie.replaceCookie',
  'cookie.getCookie',
  'cookie.getKey',
  'cookie.removeCookie',
  'cache.put',
  'cache.putMemory',
  'cache.get',
  'cache.getFromMemory',
  'cache.getInt',
  'cache.getLong',
  'cache.getDouble',
  'cache.delete',
  'cache.deleteMemory',
];

Future<void> main(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String>[];
  final sub = server.listen((request) async {
    requests.add(
      '${request.method} ${request.uri}'
      '${request.headers.value('cookie') == null ? '' : ' cookie=${request.headers.value('cookie')}'}',
    );
    switch (request.uri.path) {
      case '/set-cookie':
        request.response.headers.add('set-cookie', 'sid=fromServer; Path=/');
        request.response.write('set');
      case '/search':
        request.response.write(
          '<div class="item"><h3><a href="/book/">书</a></h3></div>',
        );
      case '/echo':
        request.response.write(
          request.headers.value('cookie') ?? 'none',
        );
      default:
        request.response.write('<div>ok</div>');
    }
    await request.response.close();
  });
  var initialized = false;
  try {
    await InProcessSourceScriptRuntime.initialize(
      libraryPath: args.isEmpty ? null : args.single,
    );
    initialized = true;
    final origin = 'http://127.0.0.1:${server.port}';
    final checks = <String, bool>{};

    final runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
    );
    Future<Object?> run(String script, {Map<String, Object?>? state}) =>
        runtime.evaluate(
          source: script,
          input: {
            'sourceKey': origin,
            'source': {
              'bookSourceUrl': origin,
              'bookSourceName': '契约源',
              'bookSourceGroup': 'group',
            },
            'key': '甲',
            'page': 1,
            'result': null,
            'baseUrl': origin,
            'headers': const <String, String>{},
          },
          timeout: const Duration(seconds: 15),
          state: state,
        );

    // 1. Every allowlisted member exists.
    final missing = await run(
      'JSON.stringify(${jsonEncode(expectedMembers)}.filter(path => {'
      'let current = {source: source, java: java, cookie: cookie, cache: cache};'
      'for (const part of path.split(".")) {'
      'if (current === null || current === undefined || !(part in current)) return true;'
      'current = current[part]; } return false;}))',
    );
    checks['membersExist'] = missing is String && missing == '[]';
    if (!checks['membersExist']!) {
      stdout.writeln(
        jsonEncode({'status': 'fail', 'missing': missing, 'checks': checks}),
      );
      exitCode = 1;
      return;
    }

    // 2. Source accessors.
    final sourceInfo = await run(
      'JSON.stringify([source.getKey(), source.getName(), source.getTag(), '
      'source.bookSourceName, source.bookSourceUrl, typeof source.getVariable()])',
    );
    checks['sourceAccessors'] =
        sourceInfo ==
        jsonEncode([
          origin,
          '契约源',
          '契约源',
          '契约源',
          origin,
          'string',
        ]);

    // 3. Rule state survives evaluations that share one analysis state.
    final state = <String, Object?>{};
    await run('java.put("token", "abc"); cache.put("shared", java.get("token"))', state: state);
    final stateRead = await run('java.get("token") + "|" + cache.get("shared")', state: state);
    checks['ruleStateSharedAcrossEvaluations'] = stateRead == 'abc|abc';
    final freshState = await run('java.get("token")', state: <String, Object?>{});
    checks['ruleStateIsPerAnalysis'] = freshState == '';
    // The frozen runtime overloads `java.get`: one argument reads rule state,
    // two send an HTTP GET. Both paths stay reachable.
    final httpGet = await run('java.get(${jsonEncode('$origin/echo')}, {}).code()');
    checks['httpGetOverload'] = httpGet == 200;

    // 4. Cache round-trips, typed reads and deletion.
    final cacheProbe = await run(
      '''cache.put("n", 42); cache.putMemory("m", "mem"); JSON.stringify([
        cache.get("n"), cache.getInt("n"), cache.getLong("n"), cache.getDouble("n"),
        cache.getFromMemory("m"), cache.get("missing")])''',
    );
    checks['cacheRoundTrip'] =
        cacheProbe == jsonEncode([42, 42, 42, 42, 'mem', null]);
    final cacheDeleted = await run(
      'cache.delete("n"); cache.deleteMemory("m"); JSON.stringify([cache.get("n"), cache.get("m")])',
    );
    checks['cacheDelete'] = cacheDeleted == jsonEncode([null, null]);

    // 5. Cookies reach the wire and read back.
    final cookieProbe = await run(
      '''cookie.setCookie(${jsonEncode(origin)}, "a=1; b=2");
        cookie.replaceCookie(${jsonEncode(origin)}, "c=3");
        JSON.stringify([cookie.getCookie(${jsonEncode(origin)}), cookie.getKey(${jsonEncode(origin)}, "c")])''',
    );
    checks['cookieRoundTrip'] = cookieProbe == jsonEncode(['a=1; b=2; c=3', '3']);
    await run('java.ajax(${jsonEncode('$origin/echo')})');
    checks['cookieOnWire'] = requests.last == 'GET /echo cookie=a=1; b=2; c=3';
    final removed = await run(
      'cookie.removeCookie(${jsonEncode(origin)}); JSON.stringify(cookie.getCookie(${jsonEncode(origin)}))',
    );
    checks['cookieRemoved'] = removed == jsonEncode('');
    await run('java.ajax(${jsonEncode('$origin/set-cookie')})');
    final fromServer = await run('cookie.getCookie(${jsonEncode(origin)})');
    checks['serverCookieStored'] = fromServer == 'sid=fromServer';
    await run('cookie.removeCookie(${jsonEncode(origin)})');

    // 6. Log and toast capture, including the returned value of log().
    final before = runtime.messages.length;
    final logReturn = await run(
      'const value = java.log("hello"); java.toast("t"); java.longToast("lt"); '
      'java.logType({}); String(value)',
    );
    final messages = runtime.messages
        .skip(before)
        .map((message) => '${message.kind}:${message.message}')
        .toList();
    checks['logReturnValue'] = logReturn == 'hello';
    checks['logCaptured'] = messages.join('|') == 'log:hello|toast:t|longToast:lt|logType:object';

    // 7. Encoding and utility family against the frozen semantics.
    final utilities = await run(
      '''JSON.stringify({
        base64: java.base64Encode("书a"),
        base64Wrapped: java.base64Encode("x".repeat(60), 0),
        base64UrlSafe: java.base64Encode("\\u00ff\\u00fe", 8 | 2),
        base64Decoded: java.base64Decode("5LmmYQ=="),
        base64Bytes: java.base64DecodeToByteArray("5LmmYQ==").join(","),
        base64Null: java.base64DecodeToByteArray(""),
        hex: java.hexEncodeToString("书a"),
        hexDecoded: java.hexDecodeToString("e4b9a661"),
        hexBytes: java.hexDecodeToByteArray("00ff").join(","),
        encodeUri: java.encodeURI("我 a*b"),
        encodeUriNonAsciiCharset: java.encodeURI("a", "GBK"),
        htmlFormat: java.htmlFormat("<div>一<br>二<p>三</p><img src=\\"/i.png\\"></div>"),
        timeFormatUtc: java.timeFormatUTC(0, "yyyy-MM-dd HH:mm", 8),
        uuid: java.randomUUID().length,
        toNumChapter: java.toNumChapter("第１２3章 起点"),
        toNumChapterUntouched: java.toNumChapter("序章"),
        toUrl: JSON.stringify(java.toURL("http://a.test/b?x=1&y=2")),
        toUrlRelative: java.toURL("/c", "http://a.test/base/").pathname,
        bytes: java.bytesToStr(java.strToBytes("书"))
      })''',
    );
    final decoded = jsonDecode(utilities! as String) as Map<String, dynamic>;
    checks['base64Encode'] = decoded['base64'] == '5LmmYQ==';
    // `base64Encode(str)` encodes the UTF-8 bytes of the string, like
    // `str.toByteArray()` in the frozen runtime.
    checks['base64UrlSafe'] = decoded['base64UrlSafe'] == 'w7_Dvg==';
    checks['base64Decode'] = decoded['base64Decoded'] == '书a';
    checks['base64DecodeToBytes'] = decoded['base64Bytes'] == '-28,-71,-90,97';
    checks['base64EmptyIsNull'] = decoded['base64Null'] == null;
    checks['hexEncode'] = decoded['hex'] == 'e4b9a661';
    checks['hexDecode'] = decoded['hexDecoded'] == '书a';
    checks['hexDecodeBytes'] = decoded['hexBytes'] == '0,-1';
    checks['encodeUri'] = decoded['encodeUri'] == '%E6%88%91+a*b';
    checks['encodeUriUnknownCharset'] = decoded['encodeUriNonAsciiCharset'] == '';
    checks['htmlFormat'] =
        decoded['htmlFormat'] ==
        '\u3000\u3000\u4e00\n\u3000\u3000\u4e8c\n\u3000\u3000\u4e09\n\u3000\u3000<img src="/i.png">';
    checks['timeFormatUtc'] = decoded['timeFormatUtc'] == '1970-01-01 08:00';
    checks['randomUuid'] = decoded['uuid'] == 36;
    checks['toNumChapter'] = decoded['toNumChapter'] == '第123章';
    checks['toNumChapterUntouched'] = decoded['toNumChapterUntouched'] == '序章';
    checks['toUrl'] =
        decoded['toUrl'] ==
        '{"host":"a.test","origin":"http://a.test","pathname":"/b","searchParams":{"x":"1","y":"2"}}';
    checks['toUrlRelative'] = decoded['toUrlRelative'] == '/c';
    checks['strToBytes'] = decoded['bytes'] == '书';
    // Wrapped output: 60 characters encode to 80 base64 characters in two
    // lines of 76 and 4, separated by a newline.
    checks['base64WrapLines'] =
        '${decoded['base64Wrapped']}'.split('\n').length == 2 &&
        '${decoded['base64Wrapped']}'.split('\n').first.length == 76;

    // 8. A rule that uses the blocked sample pattern end to end.
    final pipeline = HtmlSourcePipeline(
      <String, dynamic>{
        'bookSourceUrl': origin,
        'searchUrl': '/search?q={{cookie.removeCookie(source.getKey())}}{{key}}',
        'ruleSearch': {
          'bookList': '@CSS:.item',
          'name': '@CSS:h3 a@text',
          'bookUrl': '@CSS:h3 a@href',
        },
      },
      HttpSourceTransport(),
    );
    final hits = await pipeline.search('甲');
    checks['cookieInUrlRuleRan'] = requests.last.startsWith('GET /search?q=');
    checks['cookieInUrlRuleParsed'] = hits.single.title == '书';

    final pass = checks.values.every((value) => value);
    stdout.writeln(
      jsonEncode({
        'status': pass ? 'pass' : 'fail',
        'checks': checks,
        'utilities': decoded,
        'requests': requests,
      }),
    );
    if (!pass) exitCode = 1;
  } finally {
    if (initialized) await InProcessSourceScriptRuntime.dispose();
    await sub.cancel();
    await server.close(force: true);
  }
}
