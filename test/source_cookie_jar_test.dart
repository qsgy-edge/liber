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

  test(
    'a response keeps the persistent pairs before the session ones',
    () async {
      // The frozen `CookieStore.getCookie` merges the persistent store first and
      // the memory session map second, so the header groups the two classes and
      // keeps each class in its own arrival order.
      final jar = SourceCookieJar();
      await jar.accept('a.test', [
        'sidA=one; Max-Age=3600; Path=/',
        'ssA=s1; Path=/',
        'extraA=e1; Max-Age=3600; Path=/',
        'ss2=sx; Path=/',
      ]);
      expect(
        jar.cookiesFor('https://a.test/x'),
        'sidA=one; extraA=e1; ssA=s1; ss2=sx',
      );
      // The same response in the other order keeps the same grouping.
      final swapped = SourceCookieJar();
      await swapped.accept('a.test', [
        'ssA=s1; Path=/',
        'sidA=one; Max-Age=3600; Path=/',
        'ss2=sx; Path=/',
        'extraA=e1; Max-Age=3600; Path=/',
      ]);
      expect(
        swapped.cookiesFor('https://a.test/x'),
        'sidA=one; extraA=e1; ssA=s1; ss2=sx',
      );
    },
  );

  test('a name keeps the position its first write gave it', () async {
    final jar = SourceCookieJar();
    // Persistent first, then overwritten by a session cookie: the persistent
    // position stays, with the later value.
    await jar.accept('a.test', ['m=1; Max-Age=60', 'other=o']);
    await jar.accept('a.test', ['m=2']);
    expect(jar.cookiesFor('https://a.test/x'), 'm=2; other=o');
    // Session first, then written persistently: the name joins the persistent
    // block at that later write.
    final late = SourceCookieJar();
    await late.accept('a.test', ['first=s']);
    await late.accept('a.test', ['later=p; Max-Age=60']);
    await late.accept('a.test', ['first=p; Max-Age=60']);
    expect(late.cookiesFor('https://a.test/x'), 'later=p; first=p');
    // A script write is persistent too: `replace` merges and moves a
    // session-first name into the persistent block, `set` replaces the site.
    final scripted = SourceCookieJar();
    await scripted.accept('a.test', ['sess=s']);
    await scripted.replace('https://a.test/x', 'script=p');
    expect(scripted.cookiesFor('https://a.test/x'), 'script=p; sess=s');
    await scripted.replace('https://a.test/x', 'sess=p2');
    expect(scripted.cookiesFor('https://a.test/x'), 'script=p; sess=p2');
    await scripted.set('https://a.test/x', 'only=p');
    expect(scripted.cookiesFor('https://a.test/x'), 'only=p');
  });

  test('a deleted name loses its position', () async {
    final jar = SourceCookieJar();
    await jar.accept('a.test', ['keep=k; Max-Age=60', 'gone=g; Max-Age=60']);
    await jar.accept('a.test', ['gone=; Max-Age=0']);
    expect(jar.cookiesFor('https://a.test/x'), 'keep=k');
    // Re-added as a session cookie it sorts after the persistent block.
    await jar.accept('a.test', ['gone=s']);
    expect(jar.cookiesFor('https://a.test/x'), 'keep=k; gone=s');
  });

  test('deleting a source drops the positions its pairs held', () async {
    final state = SourceHostState();
    final first = state.cookiesFor('https://one.test/');
    final second = state.cookiesFor('https://two.test/');
    await first.accept('one.test', ['one=1; Max-Age=60']);
    await second.accept('two.test', ['two=2; Max-Age=60']);
    await state.deleteSource('https://one.test/');
    expect(first.cookiesFor('https://one.test/x'), '');
    expect(second.cookiesFor('https://two.test/x'), 'two=2');
    // A session write for the removed source's name starts a fresh session
    // position, so no stale persistent metadata survived the deletion: it sorts
    // before the persistent pair only if it were still marked persistent.
    await first.accept('one.test', ['one=session']);
    expect(first.cookiesFor('https://one.test/x'), 'one=session');
    await second.accept('one.test', ['one=session']);
    expect(second.cookiesFor('https://one.test/x'), 'one=session');
  });

  test(
    'a response attribute decides persistence exactly as the frozen parser',
    () async {
      Future<bool> persistent(List<String> response) async {
        final jar = SourceCookieJar();
        await jar.accept('a.test', [
          'first=f; Max-Age=60',
          'sess=s',
          ...response,
        ]);
        final header = jar.cookiesFor('https://a.test/x');
        if (header == 'first=f; m=1; sess=s') return true;
        if (header == 'first=f; sess=s; m=1') return false;
        throw StateError('unexpected header: $header');
      }

      // Max-Age: any 64-bit integer (including +, 0 and negatives) persists; an
      // integer too large for the type still persists; anything else is ignored.
      for (final value in ['3600', '+5', '0', '-5']) {
        expect(
          await persistent(['m=1; Max-Age=$value']),
          isTrue,
          reason: value,
        );
      }
      expect(
        await persistent(['m=1; Max-Age=99999999999999999999']),
        isTrue,
        reason: 'an overflowing positive integer is still a max age',
      );
      expect(
        await persistent(['m=1; Max-Age=-99999999999999999999']),
        isTrue,
        reason: 'an overflowing negative integer is still a max age',
      );
      for (final value in ['abc', '+99999999999999999999', '0x10', '1.5', '']) {
        expect(
          await persistent(['m=1; Max-Age=$value']),
          isFalse,
          reason: 'Max-Age=$value',
        );
      }

      // Expires: the token-date forms the frozen parser accepts, including the
      // RFC 850 and asctime shapes and a date without a weekday.
      for (final value in [
        'Sun, 06 Nov 1994 08:49:37 GMT',
        'Sunday, 06-Nov-94 08:49:37 GMT',
        'Sun Nov  6 08:49:37 1994',
        '06 Nov 1994 08:49:37 GMT',
        '06 Nov 94 08:49:37 GMT',
      ]) {
        expect(
          await persistent(['m=1; Expires=$value']),
          isTrue,
          reason: value,
        );
      }
      // An unparseable or impossible date is not a persistent attribute.
      for (final value in [
        'not a date',
        '31 Apr 1994 08:49:37 GMT',
        '29 Feb 1993 08:49:37 GMT',
        '06 Nov 1500 08:49:37 GMT',
        '06 Nov 1994 25:49:37 GMT',
      ]) {
        expect(
          await persistent(['m=1; Expires=$value']),
          isFalse,
          reason: value,
        );
      }

      // A later invalid attribute never resets an earlier valid one, and other
      // attributes are not persistence.
      expect(await persistent(['m=1; Max-Age=60; Expires=not a date']), isTrue);
      expect(
        await persistent([
          'm=1; Expires=Sun, 06 Nov 1994 08:49:37 GMT; Max-Age=abc',
        ]),
        isTrue,
      );
      expect(
        await persistent(['m=1; Path=/; HttpOnly; Secure; Domain=a.test']),
        isFalse,
      );
      // Attribute names are case-insensitive, and spaces around the `=` are
      // tolerated as the frozen parser's trimming does.
      expect(await persistent(['m=1; MAX-AGE = 3600']), isTrue);
      expect(
        await persistent(['m=1; expires=Sun, 06 Nov 1994 08:49:37 GMT']),
        isTrue,
      );
    },
  );

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
