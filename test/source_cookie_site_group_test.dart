import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart';

/// A transport that answers without a network: it records every request and
/// hands back the `Set-Cookie` a path is scripted with, which is what makes the
/// site-group rule observable on the wire as well as in a script.
class ScriptedTransport implements SourceHttpTransport {
  final requests = <SourceHttpRequest>[];
  final setCookies = <String, List<String>>{};

  @override
  Future<SourceHttpResponse> send(SourceHttpRequest request) async {
    requests.add(request);
    return SourceHttpResponse(
      statusCode: 200,
      headers: {'set-cookie': setCookies[request.url.path] ?? const []},
      body: 'ok',
      url: request.url,
    );
  }

  String? cookieOfLastRequest() => requests.last.headers['Cookie'];
}

/// The site-group rule ADR 0011 §3 fixes: two sources of one site share a
/// session, a source of another site neither reads those values nor sends them
/// to that site, and a source sees what it wrote itself — a `Set-Cookie` on a
/// response it received included.
void main() {
  late SourceHostState state;
  late ScriptedTransport transport;

  SourceHostDispatcher source(String url) => SourceHostDispatcher(
    transport: transport,
    hostState: state,
    sourceRef: url,
  );

  setUp(() {
    state = SourceHostState();
    transport = ScriptedTransport();
  });

  test('two sources of one site share a session', () async {
    final first = source('https://first.example.com/book');
    final second = source('https://second.example.com/book');

    await first.setCookies('https://first.example.com/', 'sid=1');
    // The other source of the same site reads it...
    expect(second.cookiesFor('https://second.example.com/'), 'sid=1');
    // ...and sends it to its own host.
    await second.get('https://second.example.com/echo');
    expect(transport.cookieOfLastRequest(), 'sid=1');
  });

  test('another site neither reads the pair nor sends it', () async {
    final first = source('https://first.example.com/book');
    final other = source('https://other.test/book');

    await first.setCookies('https://first.example.com/', 'sid=1');
    // example.com's key is not the other source's site group, and it did not
    // write the pair.
    expect(other.cookiesFor('https://first.example.com/'), '');
    expect(other.cookieValue('https://first.example.com/', 'sid'), '');
    await other.get('https://first.example.com/echo');
    expect(transport.cookieOfLastRequest(), isNull);
    // ...and it cannot delete it either.
    await other.removeCookies('https://first.example.com/');
    expect(first.cookiesFor('https://first.example.com/'), 'sid=1');
  });

  test('a source reads and sends the cookie it wrote itself', () async {
    final other = source('https://other.test/book');
    // The pair lives under a site that is not this source's own, because
    // `setCookie` names the URL it is for — the baseline keys the jar by the
    // URL the script passes, and the filter is about who may read it back.
    await other.setCookies('https://cdn.third.org/asset', 'ad=1');
    expect(other.cookiesFor('https://cdn.third.org/asset'), 'ad=1');
    await other.get('https://cdn.third.org/echo');
    expect(transport.cookieOfLastRequest(), 'ad=1');
  });

  test('a Set-Cookie response counts as the receiving source own write', () async {
    final other = source('https://other.test/book');
    final unrelated = source('https://fourth.test/book');
    transport.setCookies['/login'] = ['token=abc; Path=/'];

    await other.get('https://cdn.third.org/login');
    // The pair is under third.org's key; the source that received it reads and
    // sends it, a source of yet another site does not.
    expect(other.cookiesFor('https://cdn.third.org/'), 'token=abc');
    await other.get('https://cdn.third.org/echo');
    expect(transport.cookieOfLastRequest(), 'token=abc');
    expect(unrelated.cookiesFor('https://cdn.third.org/'), '');
    await unrelated.get('https://cdn.third.org/echo');
    expect(transport.cookieOfLastRequest(), isNull);
  });

  test('a source of the site sees what another source of it wrote', () async {
    final first = source('https://first.example.com/book');
    final second = source('https://second.example.com/book');
    final unrelated = source('https://unrelated.test/book');

    await first.setCookies('https://first.example.com/', 'a=1');
    await second.replaceCookies('https://second.example.com/', 'b=2');
    expect(first.cookiesFor('https://first.example.com/'), 'a=1; b=2');
    expect(unrelated.cookiesFor('https://first.example.com/'), '');
    // One source removing the site's pairs removes them for the other too:
    // that is the shared session the baseline has.
    await second.removeCookies('https://second.example.com/');
    expect(first.cookiesFor('https://first.example.com/'), '');
  });
}
