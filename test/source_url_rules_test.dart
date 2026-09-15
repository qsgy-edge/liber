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

  test('query encoding follows the frozen encoder and its skip rule', () {
    // A legal query is never re-encoded, escapes included.
    expect(
      encodeSourceQuery('http://a/b?q=%E4%B9%A6&p=2'),
      'http://a/b?q=%E4%B9%A6&p=2',
    );
    expect(encodeSourceQuery('http://a/b'), 'http://a/b');
    // A raw query is encoded once: UTF-8, uppercase hex, and the frozen
    // character set keeps `!$&()*+,/:;=?@[\]^`{|}` as it is.
    expect(
      encodeSourceQuery('http://a/b?q=我的 书'),
      'http://a/b?q=%E6%88%91%E7%9A%84%20%E4%B9%A6',
    );
    expect(
      encodeSourceQuery('http://a/b?j={"k":1}&e=[1]&s=a|b'),
      'http://a/b?j={%22k%22:1}&e=[1]&s=a|b',
    );
    // Everything from the first `?` is the query, a `#` included, and the
    // apostrophe is the one the frozen encoder escapes while Dart keeps it.
    expect(
      encodeSourceQuery("http://a/b?q=it's#top"),
      'http://a/b?q=it%27s%23top',
    );
  });

  test('query skip rule accepts a trailing escape but not a broken one', () {
    expect(sourceQueryLooksEncoded(r'a=%2B'), isTrue);
    expect(sourceQueryLooksEncoded(r'a=%2'), isFalse);
    expect(sourceQueryLooksEncoded(r'a=%zz'), isFalse);
    expect(sourceQueryLooksEncoded('a=~b!c'), isTrue);
    expect(sourceQueryLooksEncoded('a=书'), isFalse);
  });
}
