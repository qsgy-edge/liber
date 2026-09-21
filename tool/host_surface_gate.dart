import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_dispatcher.dart';

// Exercises the JavaScript host surface a Book Source sees: source accessors,
// rule state, cookies, cache, logging, and the encoding/utility family. Every
// member is named in [expectedMembers], so the gate fails when one disappears.

/// The members this slice defers: each refuses by name (ADR 0011 §2/§4/§6)
/// instead of failing as an undefined JavaScript function. The file and archive
/// family follows the frozen `JsExtensions.kt` names, including `unArchiveFile`
/// and the `*ByteArrayContent` forms; the font family follows the ADR's
/// `:791-903` row (`queryBase64TTF`, `queryTTF`, `replaceFont`); the
/// user-confirmed browser and captcha hatches (`startBrowser*`,
/// `getVerificationCode`, `openUrl`) refuse with #32's policy (§4).
/// `speakText`/`speakSpeed` are not here: they are null value bindings in the
/// frozen runtime, not members.
const deferredMembers = <String>[
  'java.getFile',
  'java.readFile',
  'java.readTxtFile',
  'java.deleteFile',
  'java.unzipFile',
  'java.un7zFile',
  'java.unrarFile',
  'java.unArchiveFile',
  'java.getTxtInFolder',
  'java.getZipStringContent',
  'java.getRarStringContent',
  'java.get7zStringContent',
  'java.getZipByteArrayContent',
  'java.getRarByteArrayContent',
  'java.get7zByteArrayContent',
  'java.downloadFile',
  'java.cacheFile',
  'java.importScript',
  'java.queryTTF',
  'java.queryBase64TTF',
  'java.replaceFont',
  'cache.getFile',
  'cache.putFile',
  'cache.getQueryTTF',
  'java.startBrowser',
  'java.startBrowserAwait',
  'java.getVerificationCode',
  'java.openUrl',
];

const expectedMembers = <String>[
  'source.getKey',
  'source.getName',
  'source.getTag',
  'source.getVariable',
  'source.put',
  'source.get',
  'source.bookSourceUrl',
  'source.bookSourceName',
  'source.getHeaderMap',
  'java.connect',
  'java.ajax',
  'java.ajaxAll',
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
  'java.t2s',
  'java.s2t',
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
  'java.androidId',
  'java.getWebViewUA',
  'java.webView',
  'java.webViewGetSource',
  'java.webViewGetOverrideUrl',
  ...deferredMembers,
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
        request.response.write(request.headers.value('cookie') ?? 'none');
      case '/headers':
        request.response.write(request.headers.value('x-contract') ?? 'none');
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
    // A fixed installation id: the app reads the manifest's, the gate injects
    // one so the answer and its sharing across sources are checkable.
    const installationId = '0123456789abcdef';
    final checks = <String, bool>{};

    final runtime = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
      androidId: installationId,
    );
    Future<Object?> evaluateOn(
      InProcessSourceScriptRuntime target,
      String script, {
      String? sourceKey,
      Map<String, Object?>? book,
      Map<String, Object?>? chapter,
    }) => target.evaluate(
      source: script,
      input: {
        'sourceKey': sourceKey ?? origin,
        'source': {
          'bookSourceUrl': sourceKey ?? origin,
          'bookSourceName': '契约源',
          'bookSourceGroup': 'group',
          'header': '{"X-Contract":"yes"}',
        },
        'key': '甲',
        'page': 1,
        'result': null,
        'baseUrl': origin,
        'headers': const <String, String>{},
        'book': ?book,
        'chapter': ?chapter,
      },
      timeout: const Duration(seconds: 15),
    );
    Future<Object?> run(
      String script, {
      String? sourceKey,
      InProcessSourceScriptRuntime? using,
      Map<String, Object?>? book,
      Map<String, Object?>? chapter,
    }) => evaluateOn(
      using ?? runtime,
      script,
      sourceKey: sourceKey,
      book: book,
      chapter: chapter,
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
        jsonEncode([origin, '契约源', '契约源', '契约源', origin, 'string']);

    checks['sourceHeaderMap'] =
        await run('JSON.stringify(source.getHeaderMap())') ==
        jsonEncode({'X-Contract': 'yes', 'User-Agent': sourceDefaultUserAgent});
    checks['sourceHeaderMapFalseDefault'] =
        await run('JSON.stringify(source.getHeaderMap(false))') ==
        await run('JSON.stringify(source.getHeaderMap())');
    checks['connectOneArgumentSourceHeaders'] =
        await run('java.connect(${jsonEncode('$origin/headers')}).body()') ==
        'yes';
    checks['connectNullHeaderSourceFallback'] =
        await run(
          'java.connect(${jsonEncode('$origin/headers')}, null).body()',
        ) ==
        'yes';
    final connectedHeader = await run(
      'java.connect(${jsonEncode('$origin/headers')}, '
      '${jsonEncode('{"X-Contract":"yes"}')}).body()',
    );
    checks['connectHeaderString'] = connectedHeader == 'yes';
    final bookProbe = await run(
      'java.put("bookName", "stored-book"); JSON.stringify([book.name, book.bookUrl, java.get("bookName")])',
      book: {'name': '契约书', 'bookUrl': '$origin/book'},
    );
    checks['bookSnapshot'] =
        bookProbe == jsonEncode(['契约书', '$origin/book', 'stored-book']);
    checks['absentBookStaysNull'] = await run('book === null') == true;
    final chapterProbe = await run(
      'java.put("title", "stored-title"); JSON.stringify([chapter.title, chapter.url, java.get("title")])',
      chapter: {'title': '第一章', 'url': '$origin/chapter'},
    );
    checks['chapterSnapshot'] =
        chapterProbe == jsonEncode(['第一章', '$origin/chapter', 'stored-title']);
    for (final member in [
      'book.getVariable',
      'book.putVariable',
      'book.variable',
      'chapter.getVariable',
      'chapter.putVariable',
      'chapter.variable',
    ]) {
      SourceScriptError? failure;
      try {
        await run(member, book: {'name': '契约书'}, chapter: {'title': '第一章'});
      } on SourceScriptError catch (error) {
        failure = error;
      }
      checks['${member}UnavailableByName'] =
          failure?.category == 'policy' && failure!.message.contains(member);
    }
    SourceScriptError? loginFailure;
    try {
      await run('source.getHeaderMap(true)');
    } on SourceScriptError catch (error) {
      loginFailure = error;
    }
    checks['loginHeaderDeferredByName'] =
        loginFailure?.category == 'policy' &&
        loginFailure!.message.contains('source.getHeaderMap(true)') &&
        loginFailure.message.contains('#13');

    // 3. Rule state is the source's own persistent variables, not one
    //    analysis's: it survives an evaluation that shares nothing with the last
    //    one, and no other source reads it (ADR 0011 §3, #21).
    await run(
      'java.put("token", "abc"); cache.put("shared", java.get("token"))',
    );
    final stateRead = await run(
      'java.get("token") + "|" + cache.get("shared")',
    );
    checks['ruleStatePersistsForItsSource'] = stateRead == 'abc|abc';
    final otherSource = await run(
      'java.get("token")',
      sourceKey: '$origin/other-source',
    );
    checks['ruleStateIsOwnedByItsSource'] = otherSource == '';
    // The frozen runtime overloads `java.get`: one argument reads rule state,
    // two send an HTTP GET. Both paths stay reachable.
    final httpGet = await run(
      'java.get(${jsonEncode('$origin/echo')}, {}).code()',
    );
    checks['httpGetOverload'] = httpGet == 200;
    checks['httpGetUndefinedSecondArgument'] =
        await run(
          'java.get(${jsonEncode('$origin/echo')}, undefined).code()',
        ) ==
        200;
    final batch = await run(
      'JSON.stringify(java.ajaxAll(['
      '${jsonEncode('$origin/a')}, ${jsonEncode('$origin/b')}])'
      '.map(r => ({statusCode:r.code(), body:r.body(), url:r.url()})))',
    );
    final batchValues = jsonDecode(batch! as String) as List<dynamic>;
    checks['ajaxAllReturnsOrderedResponses'] =
        batchValues.length == 2 &&
        batchValues[0]['url'] == '$origin/a' &&
        batchValues[1]['url'] == '$origin/b' &&
        batchValues.every(
          (value) =>
              value is Map &&
              value['statusCode'] == 200 &&
              value['body'] == '<div>ok</div>',
        );

    checks['ajaxAllEmptyArray'] = await run('java.ajaxAll([]).length') == 0;
    checks['ajaxListUsesFirstUrl'] =
        await run(
              'java.ajax([${jsonEncode('$origin/headers')}, ${jsonEncode('$origin/unused')}])',
            ) ==
            'yes' &&
        requests.last.startsWith('GET /headers');

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
    checks['cookieRoundTrip'] =
        cookieProbe == jsonEncode(['a=1; b=2; c=3', '3']);
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
    checks['logCaptured'] =
        messages.join('|') == 'log:hello|toast:t|longToast:lt|logType:object';

    // 7. Encoding and utility family against the frozen semantics.
    final utilities = await run('''JSON.stringify({
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
        t2s: java.t2s("　　「你這是什麼意思？」他問道。"),
        t2sExcluded: java.t2s("魔戒三部曲、桌球選手、雪梨歌劇院。"),
        s2t: java.s2t("龙应台的小说在台湾很受欢迎。"),
        htmlFormat: java.htmlFormat("<div>一<br>二<p>三</p><img src=\\"/i.png\\"></div>"),
        timeFormatUtc: java.timeFormatUTC(0, "yyyy-MM-dd HH:mm", 8),
        uuid: java.randomUUID().length,
        toNumChapter: java.toNumChapter("第十二章"),
        toNumChapterFullwidth: java.toNumChapter("第１２3章 起点"),
        toNumChapterUntouched: java.toNumChapter("序章"),
        toUrl: JSON.stringify(java.toURL("http://a.test/b?x=1&y=2")),
        toUrlRelative: java.toURL("/c", "http://a.test/base/").pathname,
        bytes: java.bytesToStr(java.strToBytes("书"))
      })''');
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
    checks['encodeUriUnknownCharset'] =
        decoded['encodeUriNonAsciiCharset'] == '';
    // The conversion is the reader's conversion: the same tables, including
    // Legado's exclude list (魔戒 stays 魔戒 although the table knows 指环王).
    checks['t2s'] = decoded['t2s'] == '　　“你这是什么意思？”他问道。';
    checks['t2sExcluded'] = decoded['t2sExcluded'] == '魔戒三部曲、桌球选手、雪梨歌剧院。';
    // The character table now also carries OpenCC's variant characters, so the
    // surname 台 keeps its Simplified form while the place 台湾 becomes 臺灣
    // (the phrase table has that one word). See ADR 0009's revision.
    checks['s2t'] = decoded['s2t'] == '龍應台的小說在臺灣很受歡迎。';
    checks['htmlFormat'] =
        decoded['htmlFormat'] ==
        '\u3000\u3000\u4e00\n\u3000\u3000\u4e8c\n\u3000\u3000\u4e09\n\u3000\u3000<img src="/i.png">';
    checks['timeFormatUtc'] = decoded['timeFormatUtc'] == '1970-01-01 08:00';
    checks['randomUuid'] = decoded['uuid'] == 36;
    checks['toNumChapter'] = decoded['toNumChapter'] == '第12章';
    checks['toNumChapterFullwidth'] =
        decoded['toNumChapterFullwidth'] == '第123章';
    checks['toNumChapterChineseShorthand'] =
        await run('java.toNumChapter("第一千二章")') == '第1200章';
    checks['toNumChapterInvalid'] =
        await run('java.toNumChapter("第未知章")') == '第-1章';
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

    // 8. Deferred members refuse by name, into the source log and as a `policy`
    //    error the caller can report, instead of a `TypeError`.
    var refusedByName = true;
    var refusalInLog = true;
    for (final member in deferredMembers) {
      final before = runtime.messages.length;
      SourceScriptError? failure;
      try {
        await run('$member("probe")');
      } on SourceScriptError catch (error) {
        failure = error;
      }
      final logged = runtime.messages
          .skip(before)
          .where((message) => message.kind == 'refused')
          .toList();
      if (failure == null ||
          failure.category != 'policy' ||
          !failure.message.contains(member) ||
          !failure.message.contains('deferred')) {
        refusedByName = false;
      }
      if (logged.length != 1 || !logged.single.message.contains(member)) {
        refusalInLog = false;
      }
    }
    checks['deferredMembersRefuse'] = refusedByName;
    checks['refusalLoggedInSourceLog'] = refusalInLog;

    // 9. The emulated identity is the installation's, shared by two sources; the
    //    emulated user agent is non-empty and platform-plausible.
    checks['androidIdIsInstallationValue'] =
        await run('java.androidId()') == installationId;
    checks['androidIdSharedBySources'] =
        await run('java.androidId()', sourceKey: '$origin/other-source') ==
        installationId;
    final userAgent = await run('java.getWebViewUA()');
    checks['webViewUserAgent'] =
        userAgent is String &&
        userAgent.isNotEmpty &&
        userAgent.startsWith('Mozilla/5.0');

    // `speakText`/`speakSpeed` are the frozen `AnalyzeUrl` value bindings, not
    // members: for a book-source (non-TTS) analysis they are null, and this
    // slice keeps them null rather than making them throwing functions
    // (ADR 0011 §6/§7: reading aloud is deferred, not refused).
    final speakBindings = await run(
      'JSON.stringify([typeof speakText, speakText === null, '
      'typeof speakSpeed, speakSpeed === null])',
    );
    checks['speakTextAndSpeedStayNull'] =
        speakBindings == jsonEncode(['object', true, 'object', true]);

    // 10. The log is bounded and a toast is recorded but delivered
    //     rate-limited (one display per source per window).
    final bounded = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
    );
    await evaluateOn(
      bounded,
      'for (let i = 0; i < ${sourceMessageLogLimit + 50}; i++) '
      'java.log("m" + i);',
    );
    checks['logBounded'] =
        bounded.messages.length == sourceMessageLogLimit &&
        bounded.messages.first.message == 'm50' &&
        bounded.messages.last.message == 'm${sourceMessageLogLimit + 49}';

    final notices = <SourceHostMessage>[];
    final limited = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
      onMessage: (message) => notices.add(message),
    );
    await evaluateOn(
      limited,
      'java.toast("a"); java.longToast("b"); java.toast("c");',
    );
    checks['toastRecorded'] =
        limited.messages.where((m) => m.kind == 'toast').length == 2 &&
        limited.messages.where((m) => m.kind == 'longToast').length == 1;
    checks['toastRateLimited'] =
        notices.length == 1 && notices.single.message == 'a';

    // 11. A rule that uses the blocked sample pattern end to end.
    final pipeline = HtmlSourcePipeline(<String, dynamic>{
      'bookSourceUrl': origin,
      'searchUrl': '/search?q={{cookie.removeCookie(source.getKey())}}{{key}}',
      'ruleSearch': {
        'bookList': '@CSS:.item',
        'name': '@CSS:h3 a@text',
        'bookUrl': '@CSS:h3 a@href',
      },
    }, HttpSourceTransport());
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
