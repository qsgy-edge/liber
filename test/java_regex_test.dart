import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/java_regex.dart';

/// The Java-pattern translation the user replace rules need: the frozen rules are
/// `java.util.regex` patterns, and Dart's engine differs in syntax (unscoped
/// inline flags, `\h`, `\A`) and in character sets (`\s`, `\S`, `.`).
void main() {
  group('flags', () {
    test('a leading (?i) becomes the expression flag', () {
      final translated = translateJavaPattern('(?i)abc');
      expect(translated.isRunnable, isTrue);
      expect(translated.caseSensitive, isFalse);
      expect(translated.compile().hasMatch('ABC'), isTrue);
    });

    test('a leading (?mi) folds both flags', () {
      final translated = translateJavaPattern('(?mi)^a');
      expect(translated.multiLine, isTrue);
      expect(translated.caseSensitive, isFalse);
      expect(translated.compile().hasMatch('x\nA'), isTrue);
    });

    test('a mid-pattern (?m) scopes to the rest of its group', () {
      final translated = translateJavaPattern(r'x|(?m)^y');
      expect(translated.isRunnable, isTrue);
      final match = translated.compile().firstMatch('a\ny');
      expect(match, isNotNull, reason: 'Java applies (?m) from that point on');
      expect(match!.start, 2);
      // The control: without the translation Dart rejects the pattern outright.
      // (Built at run time so the analyzer's own regexp check stays quiet about a
      // pattern written this way on purpose.)
      final unscoped = ['x|', '(?m)', r'^y'].join();
      expect(() => RegExp(unscoped), throwsFormatException);
    });

    test('a mid-pattern (?i) scopes to the rest of its group', () {
      final translated = translateJavaPattern(r'a(?i)bc');
      final match = translated.compile().firstMatch('aBC');
      expect(match, isNotNull);
      expect(match!.start, 0);
    });

    test('a scoped group keeps its own flags and is left alone', () {
      final translated = translateJavaPattern(r'(?i:a)b');
      final regex = translated.compile();
      expect(regex.hasMatch('Ab'), isTrue);
      expect(regex.hasMatch('AB'), isFalse);
    });

    test('the flags ECMAScript has no equivalent for are refused', () {
      for (final pattern in ['(?u)abc', '(?d)^a', '(?U)a', '(?x)a b', '(?u:a)']) {
        final translated = translateJavaPattern(pattern);
        expect(translated.isRunnable, isFalse, reason: pattern);
        expect(translated.refusal, contains('no ECMAScript equivalent'));
      }
    });
  });

  group('character sets', () {
    test(r'\h is Java horizontal whitespace, not a literal h', () {
      final translated = translateJavaPattern(r'a\hb');
      final regex = translated.compile();
      expect(regex.hasMatch('a\tb'), isTrue);
      expect(regex.hasMatch('a b'), isTrue);
      expect(regex.hasMatch('ahb'), isFalse, reason: 'Dart alone reads \\h as h');
      expect(RegExp(r'a\hb').hasMatch('ahb'), isTrue);
    });

    test(r'\s and \S are Java ASCII sets, not ECMAScript Unicode sets', () {
      final translated = translateJavaPattern(r'\S');
      expect(translated.compile().hasMatch('\u00A0'), isTrue);
      expect(RegExp(r'\S').hasMatch('\u00A0'), isFalse);
      expect(translateJavaPattern(r'\s').compile().hasMatch('\u00A0'), isFalse);
    });

    test('the dot excludes Java line terminators, including U+0085', () {
      final translated = translateJavaPattern('a.b');
      final regex = translated.compile();
      expect(regex.hasMatch('a\u0085b'), isFalse);
      expect(RegExp('a.b').hasMatch('a\u0085b'), isTrue);
      expect(regex.hasMatch('a\nb'), isFalse);
      expect(regex.hasMatch('axb'), isTrue);
    });

    test(r'a dot under (?s) keeps matching everything', () {
      final translated = translateJavaPattern('(?s)a.b');
      expect(translated.dotAll, isTrue);
      expect(translated.compile().hasMatch('a\nb'), isTrue);
    });

    test(r'\A and \z are input anchors, and \R a line break', () {
      final anchor = translateJavaPattern(r'\Aab');
      expect(anchor.compile().hasMatch('ab'), isTrue);
      expect(RegExp(r'\Aab').hasMatch('Aab'), isTrue, reason: 'Dart alone reads \\A as A');
      expect(translateJavaPattern(r'ab\z').compile().hasMatch('xab'), isTrue);
      expect(
        translateJavaPattern(r'a\Rb').compile().hasMatch('a\r\nb'),
        isTrue,
      );
    });

    test(r'\p{P} turns Unicode mode on, which ECMAScript needs for it', () {
      final translated = translateJavaPattern(r'a\p{P}b');
      expect(translated.unicode, isTrue);
      expect(translated.compile().hasMatch('a，b'), isTrue);
      expect(
        RegExp(r'a\p{P}b').hasMatch('a，b'),
        isFalse,
        reason: 'without Unicode mode Dart reads \\p as a literal p',
      );
    });
  });

  group('refusals, never mis-applied', () {
    test('atomic groups and possessive quantifiers are refused by the engine', () {
      expect(
        translateJavaPattern(r'(?>a)').refusal,
        contains('rejects the translated pattern'),
      );
      expect(
        translateJavaPattern(r'a*+').refusal,
        contains('rejects the translated pattern'),
      );
    });

    test('class intersection is refused rather than silently re-read', () {
      final translated = translateJavaPattern(r'[a-z&&[^aeiou]]');
      expect(translated.isRunnable, isFalse);
      expect(translated.refusal, contains('intersection'));
      // The control: Dart compiles it and matches a different set — Java's
      // `[a-z&&[^aeiou]]` matches `b`, Dart's reading of the same source does not.
      expect(RegExp(r'[a-z&&[^aeiou]]').hasMatch('b'), isFalse);
    });

    test(r'\Q quoting, \Z, \G and control escapes are refused by name', () {
      expect(translateJavaPattern(r'\Qa.b\E').refusal, contains(r'\Q'));
      expect(translateJavaPattern(r'a\Z').refusal, contains(r'\Z'));
      expect(translateJavaPattern(r'a\G').refusal, contains(r'\G'));
      expect(translateJavaPattern(r'\cA').refusal, contains(r'\cX'));
    });

    test('a pattern that translates but cannot compile is refused too', () {
      // A quantifier with nothing to repeat is a Java error as well; the point is
      // that the refusal comes from the engine and not from the reader crashing.
      final translated = translateJavaPattern(r'*a');
      expect(translated.isRunnable, isFalse);
      expect(translated.refusal, contains('rejects the translated pattern'));
    });

    test('an ordinary Java pattern needs no translation at all', () {
      final translated = translateJavaPattern(r'第[一二三四五六七八九十]{1,3}[章节]');
      expect(translated.isRunnable, isTrue);
      expect(translated.refusal, isNull);
      expect(translated.translations, isEmpty);
      expect(translated.compile().hasMatch('第1章'), isFalse);
      expect(translated.compile().hasMatch('第一章'), isTrue);
    });
  });

  group('replacement expansion (Java Matcher.appendReplacement)', () {
    RegExpMatch match(RegExp regex, String text) => regex.firstMatch(text)!;

    test('group references, named groups and escapes', () {
      final m = match(RegExp(r'(\w+)@(\w+)'), 'user@host');
      expect(expandJavaReplacement(r'$2/$1', m), 'host/user');
      expect(expandJavaReplacement(r'literal', m), 'literal');
      final named = match(RegExp(r'(?<left>a)(?<right>b)'), 'ab');
      expect(expandJavaReplacement(r'${right}${left}', named), 'ba');
      expect(expandJavaReplacement(r'\$1', m), r'$1');
      expect(expandJavaReplacement(r'\\', m), r'\');
    });

    test('an illegal reference is refused, never expanded to nothing', () {
      final m = match(RegExp(r'(a)'), 'a');
      expect(expandJavaReplacement(r'$2', m), isNull);
      expect(expandJavaReplacement(r'${missing}', m), isNull);
      expect(expandJavaReplacement(r'$', m), isNull);
      expect(expandJavaReplacement(r'${', m), isNull);
    });
  });
}
