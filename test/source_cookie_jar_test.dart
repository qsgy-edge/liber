import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_host_state.dart';

void main() {
  test('the session jar merges, replaces and removes per site', () async {
    final jar = SourceCookieJar();
    await jar.set('https://a.test/x', 'one=1; two=2');
    expect(jar.cookiesFor('https://a.test/y'), 'one=1; two=2');
    expect(jar.value('https://a.test/y', 'two'), '2');
    expect(jar.value('https://a.test/y', 'missing'), '');

    // `replaceCookie` merges, `setCookie` replaces, and both keep unrelated
    // pairs of a cookie string intact.
    await jar.replace('https://a.test/x', 'three=3');
    expect(jar.cookiesFor('https://a.test/x'), 'one=1; two=2; three=3');
    await jar.set('https://a.test/x', 'four=4');
    expect(jar.cookiesFor('https://a.test/x'), 'four=4');

    // A `Set-Cookie` header contributes only its first pair.
    await jar.accept('a.test', ['sid=abc; Path=/; HttpOnly']);
    expect(jar.cookiesFor('https://a.test/x'), 'four=4; sid=abc');
    await jar.accept('a.test', ['sid=; Path=/']);
    expect(jar.cookiesFor('https://a.test/x'), 'four=4');

    // Another site keeps its own jar, and removing clears just that one.
    await jar.set('https://b.test/x', 'b=1');
    await jar.remove('https://a.test/x');
    expect(jar.cookiesFor('https://a.test/x'), '');
    expect(jar.cookiesFor('https://b.test/x'), 'b=1');
  });

  test('the jar keys by registrable domain, not by host', () async {
    final jar = SourceCookieJar();
    await jar.set('https://www.example.co.uk/x', 'sid=1');
    // Two hosts of one site share the session...
    expect(jar.cookiesFor('https://shop.example.co.uk/y'), 'sid=1');
    expect(jar.header('other.example.co.uk'), 'sid=1');
    // ...and two sites do not.
    expect(jar.cookiesFor('https://www.example.com/'), '');
  });

  test('an IP literal is its own site', () async {
    final jar = SourceCookieJar();
    await jar.set('http://127.0.0.1:8080/x', 'sid=1');
    expect(jar.cookiesFor('http://127.0.0.1:9090/y'), 'sid=1');
    expect(jar.cookiesFor('http://127.0.0.2:8080/y'), '');
  });
}
