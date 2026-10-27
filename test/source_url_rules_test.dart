import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/source_url_rules.dart';

void main() {
  test(
    'URL JS runs before interpolation with separate result bindings',
    () async {
      final calls = <(String, Object?)>[];
      final result = await expandSourceUrl(
        'start<js>first</js>@result/tail/{{value}}',
        (code, result) async {
          calls.add((code, result));
          return code == 'first' ? 'https://example.test' : 7.0;
        },
      );
      expect(result, 'https://example.test/tail/7');
      expect(calls, [('first', 'start'), ('value', null)]);
    },
  );
  test('@js consumes the remaining script, including newlines', () async {
    final result = await expandSourceUrl(
      'https://example.test@js:line1\nline2',
      (code, result) async {
        expect(code, 'line1\nline2');
        expect(result, 'https://example.test');
        return '/done';
      },
    );
    expect(result, '/done');
  });
  test('separate interpolation calls do not forward previous result', () async {
    final results = <Object?>[];
    expect(
      await expandSourceUrl('/{{a}}/{{b}}', (code, result) async {
        results.add(result);
        return code == 'a' ? 1 : null;
      }),
      '/1/',
    );
    expect(results, [null, null]);
  });
  test('plain URLs do not execute scripts', () async {
    expect(
      await expandSourceUrl(
        ' https://example.test/path ',
        (_, _) async => throw StateError('unexpected'),
      ),
      'https://example.test/path',
    );
  });
  test(
    'script exceptions propagate before a request can be dispatched',
    () async {
      await expectLater(
        expandSourceUrl(
          '/{{broken}}',
          (_, _) async => throw StateError('bad script'),
        ),
        throwsStateError,
      );
    },
  );

  test('page lists pick an entry and fall back to the last one', () {
    expect(
      substituteSourcePageList('http://a/b?p=<1,2,3>', 2),
      'http://a/b?p=2',
    );
    expect(
      substituteSourcePageList('http://a/b?p=<1,2,3>', 9),
      'http://a/b?p=3',
    );
    expect(
      substituteSourcePageList('http://a/<x>/b/<1, 2>', 2),
      'http://a/x/b/2',
    );
    // No page at all (a stage the frozen runtime builds without one) and no
    // list both leave the text alone.
    expect(
      substituteSourcePageList('http://a/b?p=<1,2,3>', null),
      'http://a/b?p=<1,2,3>',
    );
    expect(substituteSourcePageList('http://a/b', 3), 'http://a/b');
  });

  test('query encoding follows the frozen encoder and its skip rule', () async {
    // A legal query is never re-encoded, escapes included.
    expect(
      await encodeSourceQuery('http://a/b?q=%E4%B9%A6&p=2'),
      'http://a/b?q=%E4%B9%A6&p=2',
    );
    expect(await encodeSourceQuery('http://a/b'), 'http://a/b');
    // A raw query is encoded once: UTF-8, uppercase hex, and the frozen
    // character set keeps `!$&()*+,/:;=?@[\]^`{|}` as it is.
    expect(
      await encodeSourceQuery('http://a/b?q=我的 书'),
      'http://a/b?q=%E6%88%91%E7%9A%84%20%E4%B9%A6',
    );
    expect(
      await encodeSourceQuery('http://a/b?j={"k":1}&e=[1]&s=a|b'),
      'http://a/b?j={%22k%22:1}&e=[1]&s=a|b',
    );
    // Everything from the first `?` is the query, a `#` included, and the
    // apostrophe is the one the frozen encoder escapes while Dart keeps it.
    expect(
      await encodeSourceQuery("http://a/b?q=it's#top"),
      'http://a/b?q=it%27s%23top',
    );
  });

  test(
    'repair05 inherited empty path and query presence follow native URL text',
    () {
      for (final (base, expected) in [
        ('http://a/book?', 'http://a/book?#next'),
        ('http://a', 'http://a#next'),
        ('http://a?keep=1', 'http://a?keep=1#next'),
        ('http://a/book?keep=1', 'http://a/book?keep=1#next'),
      ]) {
        expect(
          sourceUrlTextResolved(Uri.parse(base), '#next'),
          expected,
          reason: base,
        );
      }
    },
  );

  test('query skip rule accepts a trailing escape but not a broken one', () {
    expect(sourceQueryLooksEncoded(r'a=%2B'), isTrue);
    expect(sourceQueryLooksEncoded(r'a=%2'), isFalse);
    expect(sourceQueryLooksEncoded(r'a=%zz'), isFalse);
    expect(sourceQueryLooksEncoded('a=~b!c'), isTrue);
    expect(sourceQueryLooksEncoded('a=书'), isFalse);
  });

  test('repair06 fragment question mark is not query presence', () {
    // The frozen `URL(base, "#next")` keeps the base's own query and never
    // invents an empty one from a `?` the fragment happens to hold.
    final fragmentOnly = Uri.parse('http://source.test/book#old?marker');
    expect(fragmentOnly.hasQuery, isFalse);
    expect(
      sourceUrlTextResolved(fragmentOnly, '#next'),
      'http://source.test/book#next',
    );
    // An explicit empty query stays one, as the retained positive case says.
    final explicitEmpty = Uri.parse('http://source.test/book?#old?marker');
    expect(explicitEmpty.hasQuery, isTrue);
    expect(
      sourceUrlTextResolved(explicitEmpty, '#next'),
      'http://source.test/book?#next',
    );
  });

  test('repair06 raw base inherits the native protocol', () {
    for (final (base, expected) in [
      ('HTTP://UPPER.test/catalog/book', 'http://UPPER.test/catalog/toc'),
      ('http://UPPER.test/catalog/book', 'http://UPPER.test/catalog/toc'),
    ]) {
      expect(
        sourceUrlTextResolved(Uri.parse(base), 'toc', rawBase: base),
        expected,
        reason: base,
      );
    }
    // An already absolute field stays verbatim, whatever its own scheme case.
    expect(
      sourceUrlTextResolved(
        Uri.parse('HTTP://UPPER.test/catalog/book'),
        'HTTP://UPPER.test/catalog/toc',
        rawBase: 'HTTP://UPPER.test/catalog/book',
      ),
      'HTTP://UPPER.test/catalog/toc',
    );
  });

  // The pinned `NetworkUtils.kt:173-191` URL overload trims with Kotlin only for
  // its null-base fallback and its absolute/data/javascript admission; the
  // relative branch hands the original text to `URL(base, relativePath)`, whose
  // own edge trim stops at U+0020. A Unicode space is therefore URL text, while a
  // C0 control is not.
  for (final (label, raw, expected) in [
    ('suffix', 'child\u2000', 'http://source.test/book/child\u2000'),
    ('prefix', '\u2000child', 'http://source.test/book/\u2000child'),
    ('ascii-control', '\u001cchild\u001c', 'http://source.test/book/child'),
    (
      'absolute-control',
      'http://UPPER.test/toc\u2000',
      'http://UPPER.test/toc',
    ),
  ]) {
    test('repair06whitespace URL text $label', () {
      final base = Uri.parse('http://source.test/book/1?keep=x');
      expect(
        sourceUrlTextResolved(base, raw),
        expected,
        reason: 'the URL constructor receives the original relative text',
      );
      expect(
        sourceUrlNativeText(raw, base),
        expected,
        reason: 'the frozen scalar helper follows the same exact operation',
      );
    });
  }

  for (final suffix in [false, true]) {
    test('repair06whitespace raw base suffix=$suffix', () {
      final rawBase = 'http://UPPER.test/book/1${suffix ? '\u2000' : ''}';
      expect(
        sourceUrlTextResolved(Uri.parse(rawBase), '#next', rawBase: rawBase),
        '$rawBase#next',
        reason: 'the base constructor keeps a Unicode path character',
      );
    });
  }
}
