/// Java `java.util.regex` patterns, translated into the syntax Dart's [RegExp]
/// accepts — the frozen user replace rules are Java patterns, and Dart's engine
/// is an ECMAScript engine with different syntax and different character
/// classes.
///
/// Measured against the operator's 129 real rules (`replaceRule.json` in the
/// 2026-09-17 backup): 46 are regexes and they use Java-only syntax — unscoped
/// inline flags `(?i)`/`(?m)`/`(?mi)` (12+6 rules; Dart throws
/// `FormatException: Invalid group`), `\h` (7 rules; Dart reads it as a literal
/// `h`), `\s`/`\S`/`.` whose Java character sets are narrower than ECMAScript's
/// (silent differences), lookbehind and `\uXXXX` (both supported), atomic
/// groups, possessive quantifiers and character-class intersection (not
/// expressible).
///
/// The rule here is the one the product already applies to a member it cannot
/// run: translate what is faithfully translatable, and otherwise **refuse by
/// name** rather than mis-apply it — a wrongly-applied replacement would change
/// a reader's text silently, which is worse than a rule that reports itself as
/// unsupported.
///
/// An escape is copied through only when Java and ECMAScript give it the same
/// meaning: quoting a non-alphanumeric ASCII character (`\.`, `\\`, `\ `), the
/// four C escapes `\t \n \r \f`, the class escapes `\d \D \w \W`, `\b` (`\B`
/// only outside a character class, where both engines read a word boundary),
/// and a `\uHHHH` or `\xHH` code unit. Every other escape is refused by name:
/// `\a`, `\N{...}`, `\x{...}`, `\k<...>`, a digit escape (`\0nn` octal and the
/// numbered back-reference `\1`), a lone `\p`/`\P`, `\E`, `\X`, and any other
/// letter. Java reserves or rejects several of those, and Dart reads the rest
/// as a different escape or as a literal, so neither engine's meaning may stand
/// in for the other's.
library;

/// One Java pattern as the Dart engine can run it, or the reason it cannot be.
class JavaPattern {
  const JavaPattern._({
    required this.source,
    required this.refusal,
    required this.caseSensitive,
    required this.multiLine,
    required this.dotAll,
    required this.unicode,
    required this.translations,
  });

  /// The translated Dart pattern, or null when [refusal] says why there is none.
  final String? source;

  /// Why this pattern is not runnable, or null when it is.
  final String? refusal;

  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;

  /// Unicode mode, turned on only for a pattern that uses `\p{...}`/`\P{...}`,
  /// which ECMAScript expresses only in that mode.
  final bool unicode;

  /// The translations that were applied, for the ticket's record and the
  /// reader's log. Empty when the pattern needed none.
  final List<String> translations;

  bool get isRunnable => source != null;

  /// The compiled expression. Only call it when [isRunnable].
  RegExp compile() => RegExp(
    source!,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
    unicode: unicode,
  );
}

/// Translates one Java pattern, or reports why it cannot be translated.
JavaPattern translateJavaPattern(String pattern) {
  final translations = <String>[];
  var caseSensitive = true;
  var multiLine = false;
  var dotAll = false;
  var unicode = false;

  // 1. Leading unscoped flag groups become the Dart RegExp's own flags: at the
  //    start of a pattern they cover the whole pattern in Java too.
  var body = pattern;
  var offset = 0;
  while (true) {
    final group = _flagGroupAt(body, offset);
    if (group == null || group.scoped) break;
    final applied = _fold(
      group,
      caseSensitive: caseSensitive,
      multiLine: multiLine,
      dotAll: dotAll,
    );
    if (applied.refusal != null) {
      return _refused(translations, applied.refusal!);
    }
    caseSensitive = applied.caseSensitive;
    multiLine = applied.multiLine;
    dotAll = applied.dotAll;
    offset = group.end;
    translations.add('leading `${group.text}` became the expression flag');
  }
  if (offset > 0) body = body.substring(offset);

  // 2. Any remaining unscoped flag group applies to the rest of its enclosing
  //    group in Java; a scoped group expresses exactly that. This runs before
  //    the escape pass so every `s` flag is already a scoped `(?s:…)` group
  //    when the dots are translated (a later `(?s)` widens the dots it covers).
  final mid = _scopeRemainingFlags(body, translations);
  if (mid.refusal != null) return _refused(translations, mid.refusal!);
  body = mid.text;

  // 3. Escapes and character sets whose Java meaning differs from ECMAScript's.
  final translated = _translateEscapes(
    body,
    dotAll: dotAll,
    translations: translations,
  );
  if (translated.refusal != null) {
    return _refused(translations, translated.refusal!);
  }
  body = translated.text;
  unicode = translated.unicode;

  // The translation notes are recorded once per pattern, not per occurrence.
  final unique = <String>[];
  for (final entry in translations) {
    if (!unique.contains(entry)) unique.add(entry);
  }
  translations
    ..clear()
    ..addAll(unique);

  // 4. A pattern Dart still refuses is refused here, by the engine's own words.
  try {
    RegExp(
      body,
      caseSensitive: caseSensitive,
      multiLine: multiLine,
      dotAll: dotAll,
      unicode: unicode,
    );
  } on FormatException catch (error) {
    return _refused(
      translations,
      'Dart\'s regular-expression engine rejects the translated pattern: ${error.message}',
    );
  }

  return JavaPattern._(
    source: body,
    refusal: null,
    caseSensitive: caseSensitive,
    multiLine: multiLine,
    dotAll: dotAll,
    unicode: unicode,
    translations: translations,
  );
}

JavaPattern _refused(List<String> translations, String refusal) =>
    JavaPattern._(
      source: null,
      refusal: refusal,
      caseSensitive: true,
      multiLine: false,
      dotAll: false,
      unicode: false,
      translations: translations,
    );

/// Java's `String.matches` (`Matcher.matches`) over one value: the whole of
/// [value] must match Java pattern [pattern], or the pattern a Dart engine
/// cannot run is refused by name.
///
/// Dart's `RegExp.hasMatch` accepts a *partial* match, so the anchored form is
/// spelled out here rather than written as `^(?:…)$`: the port's `multiLine`
/// flag keeps Java's meaning for `^`/`$` inside the pattern, and the match's
/// own start and end carry the anchoring `String.matches` adds.
///
/// The frozen readers are the `bookUrlPattern` checks — the search stage
/// (`BookList.kt:53`) and the shelf's pasted-URL match. [label] names the
/// source field the pattern came from, so a refusal points at it.
bool javaMatchesWhole(String pattern, String value, {required String label}) {
  final translated = translateJavaPattern(pattern);
  if (!translated.isRunnable) {
    throw UnsupportedError('$label 不可用：${translated.refusal}');
  }
  final match = translated.compile().firstMatch(value);
  return match != null && match.start == 0 && match.end == value.length;
}

/// Java's replacement-string syntax (`Matcher.appendReplacement`), expanded
/// against [match]; null when the replacement refers to a group that does not
/// exist, which Java raises on and the frozen `runCatching` turns into a
/// skipped rule.
String? expandJavaReplacement(String replacement, RegExpMatch match) {
  final out = StringBuffer();
  var index = 0;
  while (index < replacement.length) {
    final char = replacement[index];
    if (char == r'\') {
      // Java drops the backslash and keeps the next character literally.
      if (index + 1 >= replacement.length) return null;
      out.write(replacement[index + 1]);
      index += 2;
      continue;
    }
    if (char != r'$') {
      out.write(char);
      index++;
      continue;
    }
    var look = index + 1;
    if (look < replacement.length && replacement[look] == '{') {
      final close = replacement.indexOf('}', look);
      if (close < 0) return null;
      final name = replacement.substring(look + 1, close);
      // Java's `${1}` is the same group reference as `$1`.
      if (name.isNotEmpty && int.tryParse(name) != null) {
        final group = int.parse(name);
        if (group > match.groupCount) return null;
        out.write(match.group(group) ?? '');
      } else {
        if (!match.groupNames.contains(name)) return null;
        out.write(match.namedGroup(name) ?? '');
      }
      index = close + 1;
      continue;
    }
    final digits = StringBuffer();
    while (look < replacement.length &&
        _isDigit(replacement.codeUnitAt(look))) {
      digits.write(replacement[look]);
      look++;
    }
    if (digits.isEmpty) return null;
    final group = int.parse(digits.toString());
    if (group > match.groupCount) return null;
    out.write(match.group(group) ?? '');
    index = look;
  }
  return out.toString();
}

bool _isDigit(int codeUnit) => codeUnit >= 0x30 && codeUnit <= 0x39;

/// One `(?flags)` or `(?flags:` group found at [index].
class _FlagGroup {
  const _FlagGroup(
    this.text,
    this.start,
    this.end,
    this.flags, {
    required this.scoped,
  });
  final String text;
  final int start;
  final int end;
  final String flags;
  final bool scoped;
}

_FlagGroup? _flagGroupAt(String pattern, int index) {
  if (index + 2 >= pattern.length) return null;
  if (pattern[index] != '(' || pattern[index + 1] != '?') return null;
  var cursor = index + 2;
  final start = cursor;
  while (cursor < pattern.length && _isFlagChar(pattern[cursor])) {
    cursor++;
  }
  if (cursor == start) return null;
  if (cursor >= pattern.length) return null;
  final terminator = pattern[cursor];
  if (terminator == ')') {
    return _FlagGroup(
      pattern.substring(index, cursor + 1),
      index,
      cursor + 1,
      pattern.substring(start, cursor),
      scoped: false,
    );
  }
  if (terminator == ':') {
    return _FlagGroup(
      pattern.substring(index, cursor + 1),
      index,
      cursor + 1,
      pattern.substring(start, cursor),
      scoped: true,
    );
  }
  return null;
}

/// Java's flag characters. `d` (UNIX_LINES), `u` (UNICODE_CASE), `U`
/// (UNICODE_CHARACTER_CLASS) and `x` (COMMENTS) change the meaning of the whole
/// pattern and have no ECMAScript equivalent, so they are refused rather than
/// ignored.
bool _isFlagChar(String char) => 'idmsuxU-'.contains(char) && char.length == 1;

const _unsupportedFlags = 'duxU';

class _Flags {
  const _Flags(this.caseSensitive, this.multiLine, this.dotAll, this.refusal);
  final bool caseSensitive;
  final bool multiLine;
  final bool dotAll;
  final String? refusal;
}

/// Folds one unscoped flag group into the three flags Dart's engine has.
_Flags _fold(
  _FlagGroup group, {
  required bool caseSensitive,
  required bool multiLine,
  required bool dotAll,
}) {
  var sensitive = caseSensitive;
  var lines = multiLine;
  var anyDot = dotAll;
  var on = true;
  for (final char in group.flags.split('')) {
    if (char == '-') {
      on = false;
      continue;
    }
    if (_unsupportedFlags.contains(char)) {
      return _Flags(
        caseSensitive,
        multiLine,
        dotAll,
        'the Java flag `(?$char)` has no ECMAScript equivalent',
      );
    }
    switch (char) {
      case 'i':
        sensitive = !on;
      case 'm':
        lines = on;
      case 's':
        anyDot = on;
    }
  }
  return _Flags(sensitive, lines, anyDot, null);
}

class _Text {
  const _Text(this.text, {this.refusal, this.unicode = false});
  final String text;
  final String? refusal;
  final bool unicode;
}

// Java's `\h` and `\v` sets (Pattern's documented definitions), as members that
// can be inlined into an enclosing character class.
const _horizontalMembers =
    ' \\t\\u00A0\\u1680\\u180e\\u2000-\\u200a\\u202f\\u205f\\u3000';
const _verticalMembers = '\\n\\x0B\\f\\r\\x85\\u2028\\u2029';

/// Java's `\s` set, which is the ASCII one unless UNICODE_CHARACTER_CLASS is on.
const _javaSpaceMembers = ' \\t\\n\\x0B\\f\\r';

/// Java's default `.`: every character except a line terminator, and Java's
/// terminator set includes `\u0085`, which ECMAScript's does not.
const _javaAnyExceptNewline = '[^\\n\\r\\x85\\u2028\\u2029]';

_Text _translateEscapes(
  String pattern, {
  required bool dotAll,
  required List<String> translations,
}) {
  final out = StringBuffer();
  var inClass = false;
  var index = 0;
  var unicode = false;
  // The `s` flag in force where the cursor is: the expression-level flag the
  // leading `(?s)` set, changed by each scoped `(?s:…)`/`(?-s:…)` group the
  // cursor is inside. Java's DOTALL `.` matches every character, which is
  // exactly ECMAScript's `.` under `s`, so a dot under it is copied as it is.
  var dotAllHere = dotAll;
  final dotAllStack = <bool>[];
  while (index < pattern.length) {
    final char = pattern[index];
    if (char == r'\') {
      if (index + 1 >= pattern.length) {
        out.write(char);
        index++;
        continue;
      }
      final escape = pattern[index + 1];
      String? replacement;
      switch (escape) {
        case 'h':
          replacement = inClass ? _horizontalMembers : '[$_horizontalMembers]';
        case 'H':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\H` inside a character class has no ECMAScript form',
            );
          }
          replacement = '[^$_horizontalMembers]';
        case 'v':
          replacement = inClass ? _verticalMembers : '[$_verticalMembers]';
        case 'V':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\V` inside a character class has no ECMAScript form',
            );
          }
          replacement = '[^$_verticalMembers]';
        case 'R':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\R` inside a character class has no ECMAScript form',
            );
          }
          replacement = '(?:\\r\\n|[$_verticalMembers])';
        case 's':
          replacement = inClass ? _javaSpaceMembers : '[$_javaSpaceMembers]';
        case 'S':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\S` inside a character class has no ECMAScript form',
            );
          }
          replacement = '[^$_javaSpaceMembers]';
        case 'A':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\A` inside a character class has no ECMAScript form',
            );
          }
          replacement = r'(?<![\s\S])';
        case 'z':
          if (inClass) {
            return const _Text(
              '',
              refusal: r'`\z` inside a character class has no ECMAScript form',
            );
          }
          replacement = r'(?![\s\S])';
        case 'e':
          replacement = '\\x1B';
        case 'Z':
          return const _Text(
            '',
            refusal:
                r'`\Z` (end before a final terminator) has no ECMAScript form',
          );
        case 'G':
          return const _Text(
            '',
            refusal: r'`\G` (previous match end) has no ECMAScript form',
          );
        case 'Q':
          return const _Text(
            '',
            refusal: r'`\Q...\E` quoting is not translated',
          );
        case 'c':
          return const _Text(
            '',
            refusal: r'`\cX` control escapes are not translated',
          );
        case 'p':
        case 'P':
          if (pattern.length > index + 2 && pattern[index + 2] == '{') {
            unicode = true;
            out.write(pattern.substring(index, index + 3));
            index += 3;
            continue;
          }
          return _Text(
            '',
            refusal: 'Java `\\$escape` requires a braced Unicode property',
          );
        case 'u':
        case 'x':
          final width = escape == 'u' ? 4 : 2;
          final end = index + 2 + width;
          if (end <= pattern.length &&
              _isHexDigits(pattern.substring(index + 2, end))) {
            out.write(pattern.substring(index, end));
            index = end;
            continue;
          }
          return _Text(
            '',
            refusal: 'Java `\\$escape` needs exactly $width hexadecimal digits',
          );
      }
      if (replacement != null) {
        out.write(replacement);
        translations.add('Java `\\$escape` became `$replacement`');
        index += 2;
        continue;
      }
      if (_isIdenticalEscape(escape, inClass: inClass)) {
        out.write(pattern.substring(index, index + 2));
        index += 2;
        continue;
      }
      return _Text(
        '',
        refusal:
            'Java `\\$escape` is not translated and has no identical ECMAScript escape',
      );
    }
    if (inClass) {
      if (char == ']') inClass = false;
      // Java's character-class intersection and subtraction (`[a-z&&[^aeiou]]`);
      // ECMAScript reads `&` literally, which would silently match the wrong
      // characters.
      if (char == '&' &&
          pattern.length > index + 1 &&
          pattern[index + 1] == '&') {
        return const _Text(
          '',
          refusal:
              'Java character-class intersection (`&&`) has no ECMAScript form',
        );
      }
      out.write(char);
      index++;
      continue;
    }
    if (char == '[') {
      inClass = true;
      out.write(char);
      index++;
      continue;
    }
    if (char == '(') {
      final group = _flagGroupAt(pattern, index);
      if (group != null && group.scoped) {
        final applied = _fold(
          group,
          caseSensitive: true,
          multiLine: false,
          dotAll: dotAllHere,
        );
        if (applied.refusal != null) {
          return _Text('', refusal: applied.refusal!);
        }
        dotAllStack.add(dotAllHere);
        dotAllHere = applied.dotAll;
        out.write(pattern.substring(index, group.end));
        index = group.end;
        continue;
      }
      dotAllStack.add(dotAllHere);
      out.write(char);
      index++;
      continue;
    }
    if (char == ')') {
      if (dotAllStack.isNotEmpty) dotAllHere = dotAllStack.removeLast();
      out.write(char);
      index++;
      continue;
    }
    if (char == '.' && !dotAllHere) {
      out.write(_javaAnyExceptNewline);
      translations.add(
        'Java `.` became $_javaAnyExceptNewline (Java also excludes U+0085)',
      );
      index++;
      continue;
    }
    out.write(char);
    index++;
  }
  return _Text(out.toString(), unicode: unicode);
}

/// The escapes copied through unchanged because Java and ECMAScript read them
/// the same way: a quoted non-alphanumeric ASCII character (`\.`, `\\`, `\ `),
/// the four C escapes `\t \n \r \f`, the class escapes `\d \D \w \W`, and
/// `\b` (a word boundary outside a class, a backspace inside one). `\B` is a
/// word boundary only outside a class: in one, Java rejects it and ECMAScript
/// reads a literal `B`. `\uHHHH` and `\xHH` are handled by the caller.
bool _isIdenticalEscape(String escape, {required bool inClass}) {
  if (escape.length != 1) return false;
  final unit = escape.codeUnitAt(0);
  final asciiLetter =
      (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A);
  if (asciiLetter) {
    return 'tnrfdDwWb'.contains(escape) || (escape == 'B' && !inClass);
  }
  final digit = unit >= 0x30 && unit <= 0x39;
  // Java quotes a non-alphanumeric ASCII punctuation character with a
  // backslash, and ECMAScript gives those spellings the same literal meaning.
  // Digits are excluded because Java uses them for backreferences and octal.
  return unit < 0x80 && !digit;
}

bool _isHexDigits(String text) => text.codeUnits.every(
  (unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x46) ||
      (unit >= 0x61 && unit <= 0x66),
);

/// Rewrites each remaining unscoped flag group into a scoped one covering the
/// rest of its enclosing group — Java's own rule for a flag that appears after
/// the pattern start.
_Text _scopeRemainingFlags(String pattern, List<String> translations) {
  final positions = <_FlagGroup>[];
  var inClass = false;
  for (var index = 0; index < pattern.length; index++) {
    final char = pattern[index];
    if (char == r'\') {
      index++;
      continue;
    }
    if (inClass) {
      if (char == ']') inClass = false;
      continue;
    }
    if (char == '[') {
      inClass = true;
      continue;
    }
    if (char == '(') {
      final group = _flagGroupAt(pattern, index);
      if (group == null) continue;
      if (group.scoped) {
        final unsupported = group.flags
            .split('')
            .where(_unsupportedFlags.contains)
            .toList();
        if (unsupported.isNotEmpty) {
          return _Text(
            '',
            refusal:
                'the Java flag `(?${unsupported.first})` has no ECMAScript equivalent',
          );
        }
        index = group.end - 1;
        continue;
      }
      final unsupported = group.flags
          .split('')
          .where(_unsupportedFlags.contains)
          .toList();
      if (unsupported.isNotEmpty) {
        return _Text(
          '',
          refusal:
              'the Java flag `(?${unsupported.first})` has no ECMAScript equivalent',
        );
      }
      positions.add(group);
      index = group.end - 1;
    }
  }
  // From the last group backwards, so the earlier offsets stay valid.
  var text = pattern;
  for (final group in positions.reversed) {
    final end = _enclosingGroupEnd(text, group.end);
    text =
        '${text.substring(0, group.start)}(?${group.flags}:'
        '${text.substring(group.end, end)})${text.substring(end)}';
    translations.add(
      'Java `${group.text}` applies to the rest of its group, so it became `(?${group.flags}:…)`',
    );
  }
  return _Text(text);
}

/// The index where the group enclosing [from] ends: the `)` that closes it, or
/// the end of the pattern when the flag group sits at the top level.
int _enclosingGroupEnd(String pattern, int from) {
  var depth = 0;
  var inClass = false;
  for (var index = from; index < pattern.length; index++) {
    final char = pattern[index];
    if (char == r'\') {
      index++;
      continue;
    }
    if (inClass) {
      if (char == ']') inClass = false;
      continue;
    }
    if (char == '[') {
      inClass = true;
      continue;
    }
    if (char == '(') {
      depth++;
      continue;
    }
    if (char == ')') {
      if (depth == 0) return index;
      depth--;
    }
  }
  return pattern.length;
}
