import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_host_dispatcher.dart';

void main() {
  test('the session jar merges, replaces and removes per host', () {
    final jar = SourceCookieJar();
    jar.set('https://a.test/x', 'one=1; two=2');
    expect(jar.cookiesFor('https://a.test/y'), 'one=1; two=2');
    expect(jar.value('https://a.test/y', 'two'), '2');
    expect(jar.value('https://a.test/y', 'missing'), '');

    // `replaceCookie` merges, `setCookie` replaces, and both keep unrelated
    // pairs of a cookie string intact.
    jar.replace('https://a.test/x', 'three=3');
    expect(jar.cookiesFor('https://a.test/x'), 'one=1; two=2; three=3');
    jar.set('https://a.test/x', 'four=4');
    expect(jar.cookiesFor('https://a.test/x'), 'four=4');

    // A `Set-Cookie` header contributes only its first pair.
    jar.accept('a.test', ['sid=abc; Path=/; HttpOnly']);
    expect(jar.cookiesFor('https://a.test/x'), 'four=4; sid=abc');
    jar.accept('a.test', ['sid=; Path=/']);
    expect(jar.cookiesFor('https://a.test/x'), 'four=4');

    // Another host keeps its own jar, and removing clears just that one.
    jar.set('https://b.test/x', 'b=1');
    jar.remove('https://a.test/x');
    expect(jar.cookiesFor('https://a.test/x'), '');
    expect(jar.cookiesFor('https://b.test/x'), 'b=1');
  });
}
