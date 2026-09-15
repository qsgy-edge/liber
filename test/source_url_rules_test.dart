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
}
