import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_hatch.dart';
import 'package:liber/source/source_login.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/workspace.dart';

import 'native_library.dart';

/// One answer of a fixture path: the body it is sent with and the headers it
/// carries.
class _Page {
  const _Page(this.body, {this.headers = const {}});
  final String body;
  final Map<String, String> headers;
}

/// One request the fixture site saw, so a test asserts the wire — the method,
/// the target, the headers and the body bytes — and not only the extracted text.
class _Seen {
  _Seen(this.method, this.target, this.headers, this.body);
  final String method;
  final String target;
  final Map<String, String> headers;
  final List<int> body;

  String get path => Uri.parse(target).path;
}

/// A fixture site: each path answers the next page of its queue and repeats the
/// last one, and every request is recorded.
class _Site {
  _Site._(this._server, this.pages);

  static Future<_Site> start(Map<String, List<_Page>> pages) async {
    final site = _Site._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
      pages,
    );
    site._server.listen(site._handle);
    return site;
  }

  final HttpServer _server;
  final Map<String, List<_Page>> pages;
  final seen = <_Seen>[];

  String get origin => 'http://127.0.0.1:${_server.port}';

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final bytes = <int>[];
    await for (final chunk in request) {
      bytes.addAll(chunk);
    }
    final recorded = <String, String>{};
    request.headers.forEach(
      (name, values) => recorded[name] = values.join(', '),
    );
    seen.add(_Seen(request.method, request.uri.toString(), recorded, bytes));
    final queue = pages[request.uri.path];
    if (queue == null || queue.isEmpty) {
      request.response.statusCode = 404;
      request.response.write('not found');
    } else {
      final page = queue.length > 1 ? queue.removeAt(0) : queue.first;
      for (final header in page.headers.entries) {
        request.response.headers.add(header.key, header.value);
      }
      request.response.write(page.body);
    }
    await request.response.close();
  }
}

/// The installation id the gates and these tests speak for: 16 lowercase hex
/// characters, the shape ADR 0011 §6 gives a real one.
const _installationId = '0123456789abcdef';

/// A login script of the shape the used sources write: it posts the stored
/// login information and stores the session header the site answered with. The
/// `login` function it defines is what the frozen wrapper requires.
String _loginScript(String origin) => '''
function login() {
  var info = JSON.parse(source.getLoginInfo() || '{}');
  var res = java.post('$origin/login', 'user=' + info.user + '&password=' + info.password);
  var sid = res.headers().get('x-session');
  source.putLoginHeader(JSON.stringify({Cookie: 'sid=' + sid, 'X-Login': 'yes'}));
}
''';

Map<String, dynamic> _source(
  String origin, {
  String loginUrl = '',
  String loginUi = '',
}) => {
  'bookSourceUrl': origin,
  'bookSourceName': '登录源',
  'searchUrl': '/search?key={{key}}',
  'ruleSearch': {
    'bookList': 'div.item',
    'name': 'h3 a@text',
    'bookUrl': 'h3 a@href',
  },
  if (loginUrl.isNotEmpty) 'loginUrl': loginUrl,
  if (loginUi.isNotEmpty) 'loginUi': loginUi,
};

SourceLoginSession _session(
  Map<String, dynamic> source, {
  required SourceHostState state,
  String androidId = _installationId,
  SourceHttpTransport? transport,
}) => SourceLoginSession(
  source: source,
  hostState: state,
  androidId: androidId,
  transport: transport ?? HttpSourceTransport(),
);

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('the loginUrl script', () {
    test('stores the header its site answered with and the next stage sends it', () async {
      final site = await _Site.start({
        '/login': [
          const _Page('ok', headers: {'x-session': 'S1'}),
        ],
        '/search': [const _Page('<div class="item"><h3><a href="/book/">书</a></h3></div>')],
        '/book/': [const _Page('<h1>书名</h1>')],
      });
      addTearDown(site.close);
      final state = SourceHostState();
      final source = _source(site.origin, loginUrl: '@js:${_loginScript(site.origin)}');
      final session = _session(source, state: state);

      expect(await session.submit({'user': 'alice', 'password': 'pw'}), isTrue);
      // The login script's own request, with the stored login information.
      expect(site.seen, hasLength(1));
      expect(site.seen.single.method, 'POST');
      expect(site.seen.single.path, '/login');
      expect(utf8.decode(site.seen.single.body), 'user=alice&password=pw');
      // `putLoginHeader` stored the text and replaced the jar's pairs with the
      // header's `Cookie`, as `CookieStore.replaceCookie` does.
      final header = await session.loginHeader();
      expect(jsonDecode(header!), {'Cookie': 'sid=S1', 'X-Login': 'yes'});
      expect(await state.entry(site.origin, 'loginHeader_${site.origin}'), header);
      expect(state.cookiesFor(site.origin).cookiesFor(site.origin), 'sid=S1');

      // The next stage's request is a pipeline request over the same host state:
      // the header is part of the source's header map, so the wire carries both
      // entries (frozen `getHeaderMap(hasLoginHeader = true)`).
      final pipeline = openBookSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
      );
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      final search = site.seen.last;
      expect(search.path, '/search');
      expect(search.headers['x-login'], 'yes');
      expect(search.headers['cookie'], 'sid=S1');
    });

    test('removeLoginHeader clears the header and the jar entry with it', () async {
      final site = await _Site.start({
        '/search': [const _Page('<div class="item"><h3><a href="/book/">书</a></h3></div>')],
      });
      addTearDown(site.close);
      final state = SourceHostState();
      final source = _source(site.origin);
      final jar = state.cookiesFor(site.origin);
      await putSourceLoginHeader(
        state,
        site.origin,
        jsonEncode({'Cookie': 'sid=S1', 'X-Login': 'yes'}),
        jar,
      );
      expect(state.cookiesFor(site.origin).cookiesFor(site.origin), 'sid=S1');

      final session = _session(source, state: state);
      await session.removeLoginHeader();
      expect(await session.loginHeader(), isNull);
      expect(
        await state.entry(site.origin, 'loginHeader_${site.origin}'),
        isNull,
      );
      expect(state.cookiesFor(site.origin).cookiesFor(site.origin), '');
      // Nothing of it reaches the wire any more.
      final pipeline = openBookSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
      );
      await pipeline.search('书');
      expect(site.seen.single.headers['x-login'], isNull);
      expect(site.seen.single.headers['cookie'], isNull);
    });

    test('a loginUrl that defines no login fails with the frozen message', () async {
      final site = await _Site.start({
        '/search': [const _Page('<div class="item"><h3><a href="/book/">书</a></h3></div>')],
      });
      addTearDown(site.close);
      final state = SourceHostState();
      // A bare URL — 28 of the 30 used `loginUrl`s — is evaluated as the frozen
      // app evaluates it, and defines no `login` function either.
      final source = _source(site.origin, loginUrl: '${site.origin}/login');
      final session = _session(source, state: state);
      await expectLater(
        session.submit({'user': 'alice'}),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'js')
              .having(
                (error) => error.message,
                'message',
                'Function login not implements!!!',
              ),
        ),
      );
      // The failure is what the source log keeps, as the frozen dialog's
      // 登录出错 does.
      await expectLater(
        session.submit({'user': 'alice'}),
        throwsA(isA<SourceScriptError>()),
      );
      // No header and no cookie were written, and every other stage still runs
      // on this source.
      expect(await session.loginHeader(), isNull);
      expect(state.cookiesFor(site.origin).cookiesFor(site.origin), '');
      final pipeline = openBookSourcePipeline(
        source,
        HttpSourceTransport(),
        hostState: state,
      );
      final hits = await pipeline.search('书');
      expect(hits.single.title, '书');
      expect(site.seen, hasLength(1));
      expect(site.seen.single.path, '/search');
    });

    test('a login script failure is recorded in the source log', () async {
      final state = SourceHostState();
      final messages = <SourceHostMessage>[];
      final session = SourceLoginSession(
        source: _source('http://a.test', loginUrl: '@js:throw new Error("bad credentials")'),
        hostState: state,
        androidId: _installationId,
        runtime: InProcessSourceScriptRuntime(onMessage: messages.add),
      );
      await expectLater(
        session.submit({'user': 'alice'}),
        throwsA(
          isA<SourceScriptError>().having(
            (error) => error.message,
            'message',
            contains('bad credentials'),
          ),
        ),
      );
      expect(messages.single.kind, 'login');
      expect(messages.single.message, contains('bad credentials'));
    });
  });

  group('the loginUi form', () {
    const form =
        '[{"name":"user"},'
        '{"name":"password","type":"password"},'
        '{"name":"submit","type":"button","action":"cache.put(\'form\', result.user)"}]';

    test('parses the frozen RowUi rows and collects only text and password', () {
      final rows = sourceLoginRows(form);
      expect(rows.map((row) => row.name), ['user', 'password', 'submit']);
      expect(rows.map((row) => row.isField), [true, true, false]);
      expect(rows.map((row) => row.isButton), [false, false, true]);
      expect(rows.last.action, "cache.put('form', result.user)");
      // The frozen `RowUi` defaults and its `when` over anything else.
      expect(sourceLoginRows('[{"name":"a"}]').single.type, 'text');
      expect(sourceLoginRows('[{"name":"a","type":"color"}]').single.isField, isFalse);
      expect(sourceLoginRows('[{"name":"a","type":null}]').single.isField, isFalse);
      expect(sourceLoginRows('{"name":"a"}'), isEmpty);
      expect(sourceLoginRows('[{"type":"text"}]'), isEmpty);
      expect(sourceLoginRows(null), isEmpty);
    });

    test('a button action runs with the collected login data as result', () async {
      final state = SourceHostState();
      final source = _source(
        'http://a.test',
        loginUrl: '@js:var login = function(){ };',
        loginUi: form,
      );
      final session = _session(source, state: state);
      final button = session.rows.last;
      await session.runButton(button, {'user': 'alice', 'password': 'pw'});
      expect(await state.entry('http://a.test', 'form'), 'alice');
      // The frozen dialog builds the button script out of the source's own login
      // script and the action (`SourceLoginDialog.kt:133-136`).
      expect(session.loginJs, 'var login = function(){ };');
    });

    test('a button whose action is an absolute URL refuses with no surface', () async {
      final session = _session(
        _source('http://a.test', loginUi: form),
        state: SourceHostState(),
      );
      const button = SourceLoginRow(
        name: 'open',
        type: 'button',
        action: 'HTTPS://a.test/verify',
      );
      expect(isAbsoluteSourceUrl(button.action), isTrue);
      // The frozen dialog hands such an action to the system browser
      // (`SourceLoginDialog.kt:128-130`); this product has no external-opening
      // path, so the action is the user-confirmed page `java.openUrl` shows
      // (ADR 0011 §4, #32). With no confirmation surface installed — every
      // process but the application — the member refuses by name.
      await expectLater(
        session.runButton(button, const {}),
        throwsA(
          isA<SourceScriptError>()
              .having((error) => error.category, 'category', 'policy')
              .having(
                (error) => error.message,
                'message',
                contains('java.openUrl'),
              ),
        ),
      );
    });

    test('a confirmed absolute-URL button shows the page', () async {
      final surface = _RecordingSurface();
      SourceHatchSurface.installed = surface;
      addTearDown(() => SourceHatchSurface.installed = null);
      final session = _session(
        _source('http://a.test', loginUi: form),
        state: SourceHostState(),
      );
      const button = SourceLoginRow(
        name: 'open',
        type: 'button',
        action: 'https://a.test/verify',
      );
      await session.runButton(button, const {});
      final asked = surface.requests.single;
      expect(asked.member, 'java.openUrl');
      expect(asked.kind, SourceHatchKind.openUrl);
      expect(asked.url, 'https://a.test/verify');
      expect(asked.sourceRef, 'http://a.test');
      expect(asked.sourceName, '登录源');
    });

    test('empty login data removes the stored information and runs no script', () async {
      final state = SourceHostState();
      await putSourceLoginInfo(
        state,
        'http://a.test',
        '{"user":"alice"}',
        _installationId,
      );
      expect(
        await getSourceLoginInfo(state, 'http://a.test', _installationId),
        isNotNull,
      );
      var logins = 0;
      final session = SourceLoginSession(
        source: _source('http://a.test', loginUrl: '@js:var x = 1;'),
        hostState: state,
        androidId: _installationId,
        runtime: _CountingRuntime(() => logins++),
      );
      // A form with no text/password row collects nothing.
      expect(await session.submit(const {}), isTrue);
      expect(await session.loginInfo(), isNull);
      expect(logins, 0);
    });

    test('the login information cannot be stored without an installation id', () async {
      final state = SourceHostState();
      final session = _session(
        _source('http://a.test', loginUrl: '@js:var x = 1;'),
        state: state,
        androidId: '',
      );
      expect(await session.submit({'user': 'alice'}), isFalse);
      expect(
        await state.entry('http://a.test', 'userInfo_http://a.test'),
        isNull,
      );
    });
  });

  group('the stored login information', () {
    test('round-trips through a restart with the frozen AES shape', () async {
      final root = await Directory.systemTemp.createTemp('liber-60-login-');
      addTearDown(() => root.delete(recursive: true));
      final workspace = await Workspace.open(root: root);
      final store = await workspace.openSpace();
      final state = SourceHostState(
        persistence: SpaceHostStatePersistence(store),
      );
      await putSourceLoginInfo(
        state,
        'http://a.test',
        '{"user":"alice","password":"pw"}',
        _installationId,
      );
      final sealed = await state.entry('http://a.test', 'userInfo_http://a.test');
      // The sealed text is the hutool shape: AES-128-ECB/PKCS5 over the JSON,
      // base64 with the Android `NO_WRAP` flags. This vector came from an
      // independent implementation (openssl's `enc -aes-128-ecb`) with the
      // installation id's first 16 bytes as the key.
      expect(
        await state.entry('http://a.test', 'userInfo_http://a.test'),
        isNotNull,
      );
      expect(
        sealSourceLoginInfo('{"user":"a"}', _installationId),
        'GSV7iG7N44i4762hym0Uiw==',
      );
      expect(openSourceLoginInfo('GSV7iG7N44i4762hym0Uiw==', _installationId), '{"user":"a"}');
      expect(sealed, isNot(contains('alice')));
      await workspace.close();

      // The process ends here; the same space file is opened again, and the
      // login information is read with nothing in memory.
      final reopened = await Workspace.open(root: root);
      final restarted = SourceHostState(
        persistence: SpaceHostStatePersistence(
          await reopened.openSpace(),
        ),
      );
      expect(
        await getSourceLoginInfoMap(restarted, 'http://a.test', _installationId),
        {'user': 'alice', 'password': 'pw'},
      );
      // Another installation's id cannot open it: the key is the id.
      expect(
        await getSourceLoginInfo(restarted, 'http://a.test', 'ffffffffffffffff'),
        isNull,
      );
      await reopened.close();
    });

    test('a malformed header is stored and reads back as no header', () async {
      final state = SourceHostState();
      final jar = state.cookiesFor('http://a.test');
      await putSourceLoginHeader(state, 'http://a.test', 'not json', jar);
      expect(
        await state.entry('http://a.test', 'loginHeader_http://a.test'),
        'not json',
      );
      expect(await getSourceLoginHeaderMap(state, 'http://a.test'), isNull);
    });
  });

  group('the source binding', () {
    test('getHeaderMap(true) carries the login header', () async {
      final runtime = InProcessSourceScriptRuntime(androidId: _installationId);
      const input = {
        'sourceKey': 'http://a.test',
        'source': <String, Object?>{'bookSourceUrl': 'http://a.test'},
      };
      expect(
        await runtime.evaluate(
          source:
              '''
source.putLoginHeader(JSON.stringify({'X-Login':'yes'}));
JSON.stringify([source.getHeaderMap()['X-Login'], source.getHeaderMap(true)['X-Login'],
  source.getLoginHeader(), source.putLoginInfo('{"user":"alice"}'),
  source.getLoginInfo(), source.getLoginInfoMap()['user']])
''',
          input: input,
          timeout: const Duration(seconds: 15),
        ),
        jsonEncode([
          null,
          'yes',
          '{"X-Login":"yes"}',
          true,
          '{"user":"alice"}',
          'alice',
        ]),
      );
      await runtime.evaluate(
        source:
            'source.removeLoginHeader(); source.removeLoginInfo(); '
            'JSON.stringify([source.getLoginHeader(), source.getLoginInfo()])',
        input: input,
        timeout: const Duration(seconds: 15),
      );
      expect(
        await runtime.hostState.entry('http://a.test', 'loginHeader_http://a.test'),
        isNull,
      );
      expect(
        await runtime.hostState.entry('http://a.test', 'userInfo_http://a.test'),
        isNull,
      );
    });
  });
}

/// A runtime that counts the login evaluations it is asked for, so a test can
/// assert that an empty form runs none.
class _CountingRuntime implements SourceScriptRuntime {
  _CountingRuntime(this.onLogin);
  final void Function() onLogin;

  @override
  Future<void> evaluateLogin({
    required String script,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async => onLogin();

  @override
  Future<Object?> evaluate({
    required String source,
    required Map<String, Object?> input,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async => null;

  @override
  Future<SourceStageResponse> evaluateLoginCheck({
    required String script,
    required Map<String, Object?> input,
    required SourceStageRequest stage,
    required Duration timeout,
    SourceCancellation? cancellation,
  }) async => throw UnimplementedError();
}

/// The confirmation surface a session test installs: it records what the runtime
/// asked for and answers the page as presented, so no route is pushed and no
/// window is needed.
class _RecordingSurface implements SourceHatchSurface {
  final requests = <SourceHatchRequest>[];

  @override
  Future<SourceHatchAnswer> interact(
    SourceHatchRequest request,
    SourceHatchStop stop,
  ) async {
    requests.add(request);
    return SourceHatchAnswer.presented;
  }
}
