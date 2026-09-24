import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_hatch.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_http_uri.dart';

// Exercises the JavaScript host surface a Book Source sees: source accessors,
// rule state, cookies, cache, logging, and the encoding/utility family. Every
// member is named in [expectedMembers], so the gate fails when one disappears.

/// The members this slice defers: each refuses by name (ADR 0011 §2/§6)
/// instead of failing as an undefined JavaScript function. The file and archive
/// family follows the frozen `JsExtensions.kt` names, including `unArchiveFile`
/// and the `*ByteArrayContent` forms; the font family follows the ADR's
/// `:791-903` row (`queryBase64TTF`, `queryTTF`, `replaceFont`).
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
];

/// The user-confirmed hatches (ADR 0011 §4, ticket #32): they exist, and they
/// show nothing before the user's confirmation. A process with no confirmation
/// surface refuses each by name, which is what this gate's own rows assert.
const hatchMembers = <String>[
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
  'source.setVariable',
  'source.put',
  'source.get',
  'source.bookSourceUrl',
  'source.bookSourceName',
  'source.getHeaderMap',
  'source.getLoginHeader',
  'source.getLoginHeaderMap',
  'source.putLoginHeader',
  'source.removeLoginHeader',
  'source.getLoginInfo',
  'source.getLoginInfoMap',
  'source.putLoginInfo',
  'source.removeLoginInfo',
  'java.connect',
  'java.ajax',
  'java.ajaxAll',
  'java.getResponse',
  'java.getStrResponse',
  'java.initUrl',
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
  'book.getVariable',
  'book.putVariable',
  'book.variable',
  'chapter.getVariable',
  'chapter.putVariable',
  'chapter.variable',
  'java.androidId',
  'java.getWebViewUA',
  'java.webView',
  'java.webViewGetSource',
  'java.webViewGetOverrideUrl',
  ...hatchMembers,
  ...deferredMembers,
];

Future<void> main(List<String> args) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final requests = <String>[];
  // The one verification-code image this gate serves, with the headers the
  // image request carried: the hatches must fetch it through the source's own
  // request path (its header rule and its cookie jar).
  final captchaHeaders = <String>[];
  final sub = server.listen((request) async {
    requests.add(
      '${request.method} ${request.uri}'
      '${request.headers.value('cookie') == null ? '' : ' cookie=${request.headers.value('cookie')}'}',
    );
    switch (request.uri.path) {
      case '/captcha':
        captchaHeaders.add(
          '${request.headers.value('x-contract')}|'
          '${request.headers.value('cookie')}',
        );
        request.response.add(const [137, 80, 78, 71, 13, 10, 26, 10]);
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

    // 1. Every allowlisted member exists. The book/chapter snapshots are built
    //    from the stage's own binding maps, so the probe carries one of each.
    final missing = await run(
      'JSON.stringify(${jsonEncode(expectedMembers)}.filter(path => {'
      'let current = {source: source, java: java, cookie: cookie, cache: cache, book: book, chapter: chapter};'
      'for (const part of path.split(".")) {'
      'if (current === null || current === undefined || !(part in current)) return true;'
      'current = current[part]; } return false;}))',
      book: {'name': '契约书', 'bookUrl': '$origin/book'},
      chapter: {'title': '第一章', 'url': '$origin/chapter'},
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
    // `source.getVariable`/`setVariable` are the frozen per-source variable
    // (`BaseSource.kt:200-212`): the `sourceVariable_<sourceKey>` entry, which a
    // null deletes.
    final variableProbe = await run(
      'source.setVariable(JSON.stringify({token: "T1"})); '
      'const set = source.getVariable(); source.setVariable(null); '
      'JSON.stringify([set, source.getVariable()])',
    );
    checks['sourceVariableRoundTrip'] =
        variableProbe == jsonEncode([jsonEncode({'token': 'T1'}), '']);
    // The stage request surface belongs to a `loginCheckJs` hook (#59): a rule
    // script has no stage request, so each member refuses by name instead of
    // failing as a `TypeError`.
    for (final member in [
      'java.getResponse',
      'java.getStrResponse',
      'java.initUrl',
    ]) {
      SourceScriptError? failure;
      try {
        await run('$member()');
      } on SourceScriptError catch (error) {
        failure = error;
      }
      checks['${member}RefusedWithoutHook'] =
          failure?.category == 'policy' && failure!.message.contains(member);
    }
    // The `getStrResponse(jsStr, …)` form drives the frozen WebView path and has
    // no used-source call site, so it refuses by name too.
    SourceScriptError? scriptForm;
    try {
      await run('java.getStrResponse("page.js")');
    } on SourceScriptError catch (error) {
      scriptForm = error;
    }
    checks['getStrResponseScriptFormRefusedByName'] =
        scriptForm?.category == 'policy' &&
        scriptForm!.message.contains('java.getStrResponse(jsStr, …)');
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
    // The frozen `Book`/`BookChapter` own variable members (#76): the row's own
    // keyed store (`Book.kt:115,137`, `BookChapter.kt:58,72`). A missing key is
    // the empty string, an empty value is stored as an empty string, a null
    // value deletes the key, `putVariable` always answers true
    // (`BaseBook.kt:19-31`), and `variable` is the raw column text — null before
    // the first write, the map's JSON after it. This gate runs without a space
    // store, so the row it addresses is the runtime's in-memory one; the store
    // write is `test/source_book_variables_test.dart`'s.
    final variableBook = {'name': '契约书', 'bookUrl': '$origin/book'};
    final variableChapter = {'title': '第一章', 'url': '$origin/chapter'};
    // The text a write stores: the frozen `GSON.toJson(variableMap)` shape,
    // two-space pretty printing with null-valued entries omitted
    // (`utils/GsonExtensions.kt:26-41`).
    String variableText(Map<String, String?> map) =>
        JsonEncoder.withIndent('  ').convert({
          for (final entry in map.entries)
            if (entry.value != null) entry.key: entry.value,
        });
    final bookVariables = await run(
      'JSON.stringify([book.variable, book.getVariable("missing"), '
      'book.putVariable("k", "v1"), book.getVariable("k"), book.variable, '
      'book.putVariable("empty", ""), book.getVariable("empty"), book.variable, '
      'book.putVariable("k", null), book.getVariable("k"), book.variable, '
      'book.putVariable("k", null), book.variable])',
      book: variableBook,
    );
    checks['bookVariableMembers'] =
        bookVariables ==
        jsonEncode([
          null,
          '',
          true,
          'v1',
          variableText({'k': 'v1'}),
          true,
          '',
          variableText({'k': 'v1', 'empty': ''}),
          true,
          '',
          variableText({'empty': ''}),
          true,
          variableText({'empty': ''}),
        ]);
    final chapterVariables = await run(
      'JSON.stringify([chapter.variable, chapter.getVariable("missing"), '
      'chapter.putVariable("c", "v2"), chapter.getVariable("c"), '
      'chapter.variable, chapter.putVariable("c", null), '
      'chapter.variable])',
      book: variableBook,
      chapter: variableChapter,
    );
    checks['chapterVariableMembers'] =
        chapterVariables ==
        jsonEncode([
          null,
          '',
          true,
          'v2',
          variableText({'c': 'v2'}),
          true,
          variableText(const <String, String?>{}),
        ]);
    // The store belongs to the runtime (and, in the product, to the space), so
    // a second evaluation over the same book reads what the first one wrote —
    // and a snapshot field that is not one of the frozen members still refuses
    // by name.
    final bookVariableReread = await run(
      'JSON.stringify([book.getVariable("empty"), book.variable])',
      book: variableBook,
    );
    checks['bookVariableReadableByTheNextEvaluation'] =
        bookVariableReread ==
        jsonEncode(['', variableText({'empty': ''})]);
    checks['absentChapterStaysNull'] = await run('chapter === null') == true;
    SourceScriptError? missingField;
    try {
      await run('book.missing', book: variableBook);
    } on SourceScriptError catch (error) {
      missingField = error;
    }
    checks['anUnknownSnapshotFieldStillRefusesByName'] =
        missingField?.category == 'policy' &&
        missingField!.message.contains('book.missing');
    SourceScriptError? loginFailure;
    try {
      await run('source.getHeaderMap(true)');
    } on SourceScriptError catch (error) {
      loginFailure = error;
    }
    checks['loginHeaderIsServedNotDeferred'] = loginFailure == null;

    // The frozen `BaseSource` login members (#60): the header a source's login
    // script stores is part of its header map and reaches the wire, its `Cookie`
    // entry replaces the jar, and `removeLoginHeader` clears both. The login
    // information is sealed with the installation id and reads back as the map
    // the form collected.
    final loginHeader = await run(
      '''source.putLoginHeader(JSON.stringify({Cookie:'sid=login','X-Login':'yes'}));
        JSON.stringify([source.getLoginHeader(), source.getLoginHeaderMap()['Cookie'],
          source.getHeaderMap(true)['X-Login'],
          cookie.getCookie(source.getKey()), source.getHeaderMap()['X-Login']])''',
    );
    checks['loginHeaderStoredAndInHeaderMap'] =
        loginHeader ==
        jsonEncode([
          '{"Cookie":"sid=login","X-Login":"yes"}',
          'sid=login',
          'yes',
          'sid=login',
          null,
        ]);
    await run('java.ajax(${jsonEncode('$origin/echo')})');
    // The header reaches the wire (the gate's `/echo` answers the cookie it was
    // sent), which is the frozen `getHeaderMap(hasLoginHeader = true)` path the
    // request layer merges.
    checks['loginHeaderReachesTheWire'] =
        requests.last.contains('GET /echo') &&
        requests.last.contains('cookie=sid=login');
    final loginInfo = await run(
      '''source.putLoginInfo('{"user":"gate"}');
        JSON.stringify([source.getLoginInfo(), source.getLoginInfoMap()['user']])''',
    );
    checks['loginInfoRoundTrip'] =
        loginInfo == jsonEncode(['{"user":"gate"}', 'gate']);
    final removedLogin = await run(
      '''source.removeLoginHeader(); source.removeLoginInfo();
        JSON.stringify([source.getLoginHeader(), source.getLoginInfo(),
          cookie.getCookie(source.getKey())])''',
    );
    checks['loginRemoved'] = removedLogin == jsonEncode([null, null, '']);
    await run('java.ajax(${jsonEncode('$origin/echo')})');
    // Nothing of the login header or its cookie reaches the next request, and
    // the jar entry `putLoginHeader` replaced went with it.
    checks['loginHeaderGoneFromTheWire'] = requests.last == 'GET /echo';

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
    // `java.ajax` builds an `AnalyzeUrl` from its URL (`JsExtensions.kt:91-105`),
    // so a `,{…}` option tail applies to the request it makes.
    checks['ajaxOptionTailReachesTheWire'] =
        await run(
              'java.ajax(${jsonEncode('$origin/echo')} + "," + '
              'JSON.stringify({method: "POST", body: "x=1"}))',
            ) ==
            'none' &&
        requests.last == 'POST /echo';

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

    // 12. The stage request surface a `loginCheckJs` hook owns: the members
    //     answer the stage's own request, and a response header is readable on
    //     the response the hook returns.
    final stageResponse = SourceStageResponse(
      body: 'stage body',
      url: SourceHttpUri.parse('$origin/stage'),
      statusCode: 201,
      headers: const {
        'x-stage': ['yes'],
      },
    );
    var resends = 0;
    final hooked = await runtime.evaluateLoginCheck(
      script:
          'cache.put("hook-stage", java.getStrResponse().headers().get("x-stage")); '
          'java.getResponse()',
      input: {
        'sourceKey': origin,
        'source': {'bookSourceUrl': origin, 'bookSourceName': '契约源'},
        'result': {
          'statusCode': 200,
          'headers': const <String, List<String>>{},
          'body': 'gate',
          'url': '$origin/search',
        },
      },
      stage: SourceStageRequest(
        resend: () async {
          resends++;
          return stageResponse;
        },
        reanalyze: () async {},
      ),
      timeout: const Duration(seconds: 15),
    );
    checks['loginCheckStageRequestSurface'] =
        resends == 2 &&
        hooked.body == 'stage body' &&
        hooked.statusCode == 201 &&
        await runtime.hostState.entry(origin, 'hook-stage') == 'yes';

    // 13. The user-confirmed hatches (ADR 0011 §4, ticket #32). Without a
    //     confirmation surface every member refuses by name: a process with no
    //     window cannot confirm, and showing nothing silently is what the
    //     policy forbids.
    final hatchRefusals = <String, bool>{};
    for (final member in hatchMembers) {
      final before = runtime.messages.length;
      SourceScriptError? failure;
      try {
        await run('$member(${jsonEncode('$origin/verify')})');
      } on SourceScriptError catch (error) {
        failure = error;
      }
      final logged = runtime.messages
          .skip(before)
          .where((message) => message.kind == 'refused')
          .toList();
      final refused =
          failure?.category == 'policy' &&
          failure!.message.contains(member) &&
          // The member exists and this process cannot serve it, so the reason
          // names the policy; a deferral would be the wrong claim and must fail
          // here rather than mislead a reader.
          !failure.message.contains('deferred') &&
          failure.message.contains('确认界面') &&
          logged.length == 1 &&
          logged.single.message.contains(member) &&
          !logged.single.message.contains('deferred');
      if (!refused) hatchRefusals[member] = true;
    }
    checks['hatchesRefuseWithoutAConfirmationSurface'] = hatchRefusals.isEmpty;
    if (hatchRefusals.isNotEmpty) {
      stdout.writeln(jsonEncode({'unrefused': hatchRefusals.keys.toList()}));
    }

    // With one, the ask names the source and the address before anything is
    // shown, the waiting members answer in the frozen member's shape, and the
    // attempt and its outcome reach the source log.
    final surface = GateHatchSurface();
    SourceHatchSurface.installed = surface;
    try {
      surface.answer = SourceHatchAnswer.answered('1234');
      final code = await run(
        'java.getVerificationCode(${jsonEncode('$origin/captcha')})',
      );
      final asked = surface.requests.last;
      checks['getVerificationCodeAnswersTheUsersText'] = code == '1234';
      checks['hatchAsksNamingTheSourceAndTheAddress'] =
          asked.member == 'java.getVerificationCode' &&
          asked.kind == SourceHatchKind.waitingImage &&
          asked.sourceRef == origin &&
          asked.sourceName == '契约源' &&
          asked.url == '$origin/captcha' &&
          asked.headers['X-Contract'] == 'yes' &&
          asked.waits;
      checks['hatchImageFetchedThroughTheSourcePath'] =
          captchaHeaders.single == 'yes|null' &&
          surface.images.single.bytes?.length == 8;
      final hatchLog = runtime.messages
          .where((message) => message.kind == 'verification')
          .map((message) => message.message)
          .toList();
      checks['hatchAttemptAndOutcomeInTheLog'] =
          hatchLog.any(
            (message) =>
                message.contains('java.getVerificationCode') &&
                message.contains('$origin/captcha'),
          ) &&
          hatchLog.any((message) => message.contains('用户已给出结果'));

      // `startBrowserAwait` refetches the address with the source's own header
      // map, which is the frozen `WebViewModel.saveVerificationResult`, and
      // answers the frozen `StrResponse(url, body)`. The page's own HTML is
      // only the answer when the source asked for the page.
      surface.answer = SourceHatchAnswer.answered('');
      final refetched = await run(
        'java.startBrowserAwait(${jsonEncode('$origin/headers')}, "标题").body()',
      );
      checks['startBrowserAwaitRefetchesWithTheSourcesHeaders'] =
          refetched == 'yes' &&
          surface.requests.last.kind == SourceHatchKind.waitingPage &&
          surface.requests.last.refetchAfterSuccess;
      final shape = await run(
        'const r = java.startBrowserAwait(${jsonEncode('$origin/headers')}, "t"); '
        'JSON.stringify([r.code(), r.url(), r.headers().get("x-path")])',
      );
      checks['startBrowserAwaitAnswersTheFrozenResponseShape'] =
          shape == jsonEncode([200, '$origin/headers', null]);

      surface.answer = SourceHatchAnswer.answered('<html>页面</html>');
      final pageBody = await run(
        'java.startBrowserAwait(${jsonEncode('$origin/page-only')}, "t", false).body()',
      );
      checks['startBrowserAwaitTakesThePageHtmlWhenNotRefetching'] =
          pageBody == '<html>页面</html>' &&
          !surface.requests.last.refetchAfterSuccess &&
          !requests.any((entry) => entry.contains('/page-only'));

      // The confirmed page's cookies are the source's session: the frozen
      // `WebViewActivity.onPageFinished` writes them into the source's store, so
      // the refetch (and every later request of that source) carries them.
      surface.answer = SourceHatchAnswer.answered('');
      surface.pageCookies = 'sid=fromPage';
      final cookieBody = await run(
        'java.startBrowserAwait(${jsonEncode('$origin/echo')}, "t").body()',
      );
      checks['theConfirmedPagesCookiesReachTheRefetch'] =
          cookieBody == 'sid=fromPage' &&
          requests.last == 'GET /echo cookie=sid=fromPage';
      surface.pageCookies = '';
      await run(
        'cookie.removeCookie(${jsonEncode(origin)})',
        sourceKey: origin,
      );

      // The address the frozen loads and names is the shaped one: before the
      // `,{…}` tail, with the tail's headers on the load.
      surface.answer = SourceHatchAnswer.presented;
      final tail =
          ',${jsonEncode({
            'headers': {'X-Tail': '1'},
          })}';
      final tailValue = await run(
        'java.startBrowser(${jsonEncode('$origin/headers')} + '
        '${jsonEncode(tail)}, "标题"); "ran"',
      );
      checks['aHatchAddressIsShapedBeforeThePageLoads'] =
          tailValue == 'ran' &&
          surface.requests.last.url == '$origin/headers' &&
          surface.requests.last.headers['X-Tail'] == '1' &&
          surface.requests.last.headers['X-Contract'] == 'yes';

      // A closed page is the frozen empty result, and a refused confirmation is
      // an explicit failure for the waiting members.
      surface.answer = SourceHatchAnswer.closed;
      SourceScriptError? closedFailure;
      try {
        await run('java.getVerificationCode(${jsonEncode('$origin/captcha')})');
      } on SourceScriptError catch (error) {
        closedFailure = error;
      }
      checks['aClosedSurfaceAnswersTheFrozenEmptyResult'] =
          closedFailure?.category == 'verification' &&
          closedFailure!.message == '验证结果为空';

      surface.answer = SourceHatchAnswer.refused;
      SourceScriptError? refusedFailure;
      try {
        await run(
          'java.startBrowserAwait(${jsonEncode('$origin/headers')}, "t")',
        );
      } on SourceScriptError catch (error) {
        refusedFailure = error;
      }
      checks['aRefusedConfirmationFailsTheWaitingMember'] =
          refusedFailure?.category == 'verification' &&
          refusedFailure!.message.contains('java.startBrowserAwait');

      // The non-waiting members show the confirmed page and the script goes on,
      // which is the frozen `startBrowser`/`openUrl` shape.
      surface.answer = SourceHatchAnswer.presented;
      final browserValue = await run(
        'java.startBrowser(${jsonEncode('$origin/browser')}, "标题"); "ran"',
      );
      checks['startBrowserShowsThePageWithoutWaiting'] =
          browserValue == 'ran' &&
          surface.requests.last.kind == SourceHatchKind.page &&
          surface.requests.last.title == '标题';
      final openValue = await run(
        'java.openUrl(${jsonEncode('$origin/open')}); "ran"',
      );
      checks['openUrlShowsThePageWithoutWaiting'] =
          openValue == 'ran' && surface.requests.last.kind == SourceHatchKind.openUrl;
      surface.answer = SourceHatchAnswer.refused;
      checks['aRefusedConfirmationOnANonWaitingMemberIsNotAFailure'] =
          await run('java.openUrl(${jsonEncode('$origin/open')}); "ran"') ==
          'ran';
    } finally {
      SourceHatchSurface.installed = null;
    }

    // The absolute cap ends a wait no one answers, and a non-http(s) address is
    // refused by name rather than loaded.
    final capped = InProcessSourceScriptRuntime(
      dispatcher: SourceHostDispatcher(transport: HttpSourceTransport()),
      hatchSurface: GateHatchSurface(neverAnswers: true),
      hatchWaitCap: const Duration(milliseconds: 120),
    );
    SourceScriptError? cappedFailure;
    try {
      await capped.evaluate(
        source: 'java.startBrowserAwait(${jsonEncode('$origin/headers')}, "t")',
        input: {
          'sourceKey': origin,
          'source': {'bookSourceUrl': origin, 'bookSourceName': '契约源'},
        },
        timeout: const Duration(seconds: 15),
      );
    } on SourceScriptError catch (error) {
      cappedFailure = error;
    }
    checks['theAbsoluteCapEndsAnUnansweredWait'] =
        cappedFailure?.category == 'verification' &&
        cappedFailure!.message.contains('java.startBrowserAwait') &&
        capped.messages.any(
          (message) =>
              message.kind == 'verification' &&
              message.message.contains('超过'),
        );
    SourceScriptError? addressFailure;
    try {
      await run('java.openUrl("file:///etc/passwd")');
    } on SourceScriptError catch (error) {
      addressFailure = error;
    }
    checks['aNonHttpHatchAddressIsRefusedByName'] =
        addressFailure?.category == 'host-input' &&
        addressFailure!.message.contains('java.openUrl');

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

/// The gate's stand-in for the confirmation surface: it answers what the check
/// programs and records what the runtime asked for, so the gate can prove that
/// the ask happens — naming the source and the address — before anything would
/// be shown, without a window (ADR 0011 §4).
class GateHatchSurface implements SourceHatchSurface {
  GateHatchSurface({this.neverAnswers = false});

  /// Whether the surface leaves the user working for ever, which is what the
  /// absolute cap exists for.
  final bool neverAnswers;

  SourceHatchAnswer answer = SourceHatchAnswer.refused;

  /// What the confirmed page hands the source's jar, as the visible page's
  /// page-finished hook does.
  String pageCookies = '';

  final requests = <SourceHatchRequest>[];
  final images = <SourceHatchImage>[];

  @override
  Future<SourceHatchAnswer> interact(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    requests.add(request);
    if (neverAnswers) return Completer<SourceHatchAnswer>().future;
    // The page's cookies and the image request happen only after the user
    // agreed, as the application's own surface does them.
    if (pageCookies.isNotEmpty && request.onPageCookies != null) {
      await request.onPageCookies!(request.url, pageCookies);
    }
    final fetch = request.fetchImage;
    if (fetch != null) images.add(await fetch());
    return answer;
  }
}
