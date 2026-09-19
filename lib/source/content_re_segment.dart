/// The frozen `ContentHelp.reSegment` paragraph re-segmentation, ported as one
/// unit with its helpers.
///
/// The frozen site is `ContentHelp.kt:17-79` (`reSegment`) plus the helpers it
/// is inseparable from: `reduceLength` (`:79-108`), `splitQuote` (`:110-135`),
/// `forceSplit` (`:137-164`), `findNewLines` (`:166-473`), `makeDict`
/// (`:475-505`), `seekIndexs` (`:507-538`), `seekLast` (`:540-565`),
/// `seekIndex` (`:567-592`), and the marker constants (`:600-615`). The frozen
/// reader calls it from `ContentProcessor.getContent` (`ContentProcessor.kt:131-133`)
/// between the duplicated-leading-title removal and the Chinese conversion, once
/// per chapter, only when `reSegment && book.getReSegment()`.
///
/// The output is what the frozen reader then converts and runs its replace rules
/// over; the reader's own paragraph shaping happens later and is not this
/// transform's job (see `content_processing.dart`).
///
/// Porting notes, where Kotlin and Dart do not line up:
///
/// - **Java's `\s` is the ASCII set**, and ECMAScript's is not: ECMAScript also
///   matches `\u00A0`, `\u3000` and friends. Every `\s` in the frozen patterns is
///   spelled as the explicit class `[ \t\n\x0B\f\r]` so a Chinese ideographic
///   space is not silently folded into a paragraph the frozen reader keeps. The
///   frozen code adds `\u3000` deliberately where it wants it (`[\u3000\s]`).
/// - **Kotlin's `Regex.split` does not follow Java's `Pattern.split`**: it keeps
///   trailing empty strings and always appends the remainder, so a body that is
///   a single newline splits to `["", ""]`, not to an empty list. [_kotlinSplit]
///   reproduces Kotlin's own algorithm (measured against the frozen compiler),
///   which Dart's `String.split` does not.
/// - `forceSplit` inserts its breaks under `Math.random()` (`ContentHelp.kt:160`).
///   [random] is the seam for that: the default is an unseeded generator, exactly
///   as the frozen reader runs it, and a test can pass a seeded one to pin a
///   path that the frozen side cannot pin. The random branch is the one part of
///   this transform that cannot be compared byte for byte against an unseeded
///   frozen run.
library;

import 'dart:math' as math;

/// Re-segments one chapter body the way the frozen `ContentHelp.reSegment` does.
///
/// [content] is the body after the duplicated-leading-title removal, [chapterName]
/// the raw chapter title (`chapter.title`, not the replaced display title), which
/// the frozen code uses only to decide whether the first paragraph is the title.
String reSegment(String content, String chapterName, {math.Random? random}) {
  final rng = random ?? math.Random();
  final dict = _makeDict(content);
  final firstSplit = _kotlinSplit(
    content
        .replaceAll(RegExp('&quot;'), '“')
        .replaceAll(RegExp('[:：][\'"‘”“]+'), '：“')
        .replaceAll(
          RegExp('["”“]+$_javaSpaceStar["”“][$_javaSpaceMembers"”“]*'),
          '”\n“',
        ),
    RegExp('\n$_javaSpaceStar'),
  );

  // The frozen StringBuilder's bump is irrelevant to the result.
  final buffer = _Units('');
  // The chapter's own text is title / blank line / first paragraph, so the
  // first line is skipped when it is the title.
  buffer.append(' ');
  final first = firstSplit.first;
  if (_trimLowControl(chapterName) != _trimLowControl(first)) {
    // Intra-paragraph spaces are removed; `\u3000` is not in Java's `\s`, so the
    // frozen class adds it.
    buffer.append(_removeAll(first, RegExp(r'[\u3000 \t\n\x0B\f\r]+')));
  }
  for (var i = 1; i < firstSplit.length; i++) {
    if (_matchUnit(_markSentencesEnd, buffer.charAt(buffer.length - 1))) {
      buffer.append('\n');
    }
    buffer.append(_removeAll(firstSplit[i], RegExp(r'[\u3000 \t\n\x0B\f\r]')));
  }

  // Pre-segmentation: `”“` becomes `”\n“`, and a talk marker followed by a
  // sentence-final period becomes a paragraph break.
  final reSplit = _kotlinSplit(
    buffer
        .toString()
        .replaceAll(RegExp('["”“]+$_javaSpaceStar["”“]+'), '”\n“')
        .replaceAllMapped(
          // The frozen group is `(？。！?!~)`, a literal sequence with `！?`
          // optional — not a character class — so it never breaks normal prose.
          // Reproduced as written (`ContentHelp.kt:60`).
          RegExp('["”“]+(？。！?!~)["”“]+'),
          (m) => '”${m.group(1)}\n“',
        )
        .replaceAllMapped(
          // Same frozen group mistake as above (`ContentHelp.kt:61`).
          RegExp('["”“]+(？。！?!~)([^"”“])'),
          (m) => '”${m.group(1)}\n${m.group(2)}',
        )
        .replaceAllMapped(
          RegExp('([问说喊唱叫骂道着答])[.。]'),
          (m) => '${m.group(1)}。\n',
        ),
    RegExp('\n'),
  );

  final joined = StringBuffer();
  for (final part in reSplit) {
    joined.write('\n');
    joined.write(_findNewLines(part, dict, rng));
  }

  final reduced = _reduceLength(joined.toString());
  return reduced
      .replaceFirst(RegExp('^$_javaSpaceClass+'), '')
      .replaceAll(
        RegExp(
          '$_javaSpaceStar["”“]+$_javaSpaceStar["”“][$_javaSpaceMembers"”“]*',
        ),
        '”\n“',
      )
      .replaceAll(RegExp('[:：][”“"$_javaSpaceMembers]+'), '：“')
      .replaceAllMapped(
        RegExp('\n["“”]([^\n"“”]+)([,:，：]["”“])([^\n"“”]+)'),
        (m) => '\n${m.group(1)}：“${m.group(3)}',
      )
      .replaceAll(RegExp('\n$_javaSpaceStar'), '\n');
}

/// The frozen `reduceLength` (`ContentHelp.kt:79`): joins the forced dialogue
/// splits. Its input is the `findNewLines` output with a newline prepended per
/// pre-split paragraph.
String _reduceLength(String source) {
  final p = _kotlinSplit(source, RegExp('\n'));
  final l = p.length;
  final b = List<bool>.filled(l, false);
  for (var i = 0; i < l; i++) {
    b[i] = _isDialogueParagraph(p[i]);
  }
  var dialogue = 0;
  for (var i = 0; i < l; i++) {
    if (b[i]) {
      if (dialogue < 0) {
        dialogue = 1;
      } else if (dialogue < 2) {
        dialogue++;
      }
    } else {
      if (dialogue > 1) {
        p[i] = _splitQuote(p[i]);
        dialogue--;
      } else if (dialogue > 0 && i < l - 2) {
        if (b[i + 1]) p[i] = _splitQuote(p[i]);
      }
    }
  }
  final string = StringBuffer();
  for (var i = 0; i < l; i++) {
    string.write('\n');
    string.write(p[i]);
  }
  return string.toString();
}

/// The frozen `splitQuote`: forces a break after an opening quote that closes
/// somewhere later, or before a closing quote that opens somewhere earlier.
String _splitQuote(String str) {
  final length = str.length;
  if (length < 3) return str;
  if (_matchUnit(_markQuotation, str.codeUnitAt(0))) {
    final i = _seekIndex(str, _markQuotation, 1, length - 2, true) + 1;
    if (i > 1) {
      if (!_matchUnit(_markQuotationBefore, str.codeUnitAt(i - 1))) {
        return '${str.substring(0, i)}\n${str.substring(i)}';
      }
    }
  } else if (_matchUnit(_markQuotation, str.codeUnitAt(length - 1))) {
    final i =
        length - 1 - _seekIndex(str, _markQuotation, 1, length - 2, false);
    if (i > 1) {
      if (!_matchUnit(_markQuotationBefore, str.codeUnitAt(i - 1))) {
        return '${str.substring(0, i)}\n${str.substring(i)}';
      }
    }
  }
  return str;
}

/// The frozen `forceSplit`: the sentence ends at which a long run gets a break,
/// each chosen under [rng] (`ContentHelp.kt:160`).
List<int> _forceSplit(
  String str,
  int offset,
  int min,
  int gain,
  int trigger,
  math.Random rng,
) {
  final result = <int>[];
  final arrayEnd = _seekIndexs(
    str,
    _markSentencesEndP,
    0,
    str.length - 2,
    true,
  );
  final arrayMid = _seekIndexs(str, _markSentencesMid, 0, str.length - 2, true);
  if (arrayEnd.length < trigger && arrayMid.length < trigger * 3) return result;
  var j = 0;
  var i = min;
  while (i < arrayEnd.length) {
    var k = 0;
    while (j < arrayMid.length) {
      if (arrayMid[j] < arrayEnd[i]) k++;
      j++;
    }
    if (rng.nextDouble() * gain < 0.8 + k / 2.5) {
      result.add(arrayEnd[i] + offset);
      i = math.max(i + min, i);
    }
    i++;
  }
  return result;
}

/// The frozen `findNewLines`: pairs the quotes, corrects their direction, and
/// inserts the breaks that a quoted sentence pattern implies.
String _findNewLines(String str, List<String> dict, math.Random rng) {
  final string = _Units(str);
  final arrayQuote = <int>[];
  var insN = <int>[];
  final mod = List<int>.filled(str.length, 0);
  var waitClose = false;
  for (var i = 0; i < str.length; i++) {
    if (!_matchUnit(_markQuotation, str.codeUnitAt(i))) continue;
    final size = arrayQuote.length;

    // `“锅”、“碗”` is treated as `“锅、碗”`, so an enumeration is not read as a
    // sentence break.
    if (size > 0) {
      final quotePre = arrayQuote[size - 1];
      if (i - quotePre == 2) {
        var remove = false;
        if (waitClose) {
          if (_matchUnit(',，、/', str.codeUnitAt(i - 1))) remove = true;
        } else if (_matchUnit(',，、/和与或', str.codeUnitAt(i - 1))) {
          remove = true;
        }
        if (remove) {
          string.setCharAt(i, _u('“'));
          string.setCharAt(i - 2, _u('”'));
          arrayQuote.removeAt(size - 1);
          mod[size - 1] = 1;
          mod[size] = -1;
          continue;
        }
      }
    }
    arrayQuote.add(i);

    // Marks `xxx：“xxx”`.
    if (i > 1) {
      final charB1 = str.codeUnitAt(i - 1);
      var charB2 = 0;
      if (_matchUnit(_markQuotationBefore, charB1)) {
        // A paragraph break is placed at the previous break of the last quote.
        if (arrayQuote.length > 1) {
          final lastQuote = arrayQuote[arrayQuote.length - 2];
          var p = 0;
          if (charB1 == 0x2C || charB1 == 0xFF0C) {
            if (arrayQuote.length > 2) {
              p = arrayQuote[arrayQuote.length - 3];
              if (p > 0) charB2 = str.codeUnitAt(p - 1);
            }
          }
          if (_matchUnit(_markSentencesEndP, charB2)) {
            insN.add(p - 1);
          } else if (!_matchUnit('的', charB2)) {
            final lastEnd = _seekLast(str, _markSentencesEnd, i, lastQuote);
            if (lastEnd > 0) {
              insN.add(lastEnd);
            } else {
              insN.add(lastQuote);
            }
          }
        }
        waitClose = true;
        mod[size] = 1;
        if (size > 0) {
          mod[size - 1] = -1;
          if (size > 1) mod[size - 2] = 1;
        }
      } else if (waitClose) {
        waitClose = false;
        insN.add(i);
      }
    }
  }
  final size = arrayQuote.length;

  // Whether the quote before this position is already paired.
  var opend = false;
  if (size > 0) {
    for (var i = 0; i < size; i++) {
      if (mod[i] > 0) {
        opend = true;
      } else if (mod[i] < 0) {
        // Two closing quotes in a row conflict; the earlier one is forced open.
        if (!opend) {
          if (i > 0) mod[i] = 3;
        }
        opend = false;
      } else {
        opend = !opend;
        mod[i] = opend ? 2 : -2;
      }
    }
    // A quote left open at the end must close.
    if (opend) {
      if (arrayQuote[size - 1] - string.length > -3) {
        if (size > 1) mod[size - 2] = 4;
        mod[size - 1] = -4;
      } else if (!_matchUnit(
        _markSentencesSay,
        string.charAt(string.length - 2),
      )) {
        string.append('”');
      }
    }

    // Loop 2: a quote that follows a sentence end and now turns open gets a
    // break before it.
    var loop2Mod1 = -1;
    var i = 0;
    var j = arrayQuote[0] - 1;
    if (j < 0) {
      i = 1;
      loop2Mod1 = 0;
    }
    while (i < size) {
      j = arrayQuote[i] - 1;
      final loop2Mod2 = mod[i];
      if (loop2Mod1 < 0 && loop2Mod2 > 0) {
        if (_matchUnit(_markSentencesEnd, string.charAt(j))) insN.add(j);
      }
      loop2Mod1 = loop2Mod2;
      i++;
    }
  }

  // The dictionary confirms the breaks: a repeated quoted word is not broken
  // after.
  final insN1 = <int>[];
  for (final i in insN) {
    if (_matchUnit('"\'”“', string.charAt(i))) {
      final start = _seekLast(str, '"\'”“', i - 1, i - _wordMaxLength);
      if (start > 0) {
        final word = str.substring(start + 1, i);
        if (dict.contains(word)) continue;
        if (_matchUnit('的地得', str.codeUnitAt(start))) continue;
      }
    }
    insN1.add(i);
  }
  insN = insN1;

  // The breaks the quoted-sentence lengths imply, chosen under [rng].
  insN = insN.toSet().toList()..sort();
  final text = string.toString();
  {
    var j = 0;
    var progress = 0;
    var nextLine = -1;
    if (insN.isNotEmpty) nextLine = insN[j];
    var gain = 3;
    var min = 0;
    var trigger = 2;
    for (var i = 0; i < arrayQuote.length; i++) {
      final quote = arrayQuote[i];
      if (quote > 0) {
        gain = 4;
        min = 2;
        trigger = 4;
      } else {
        gain = 3;
        min = 0;
        trigger = 2;
      }
      while (j < insN.length) {
        if (nextLine >= quote) break;
        nextLine = insN[j];
        if (progress < nextLine) {
          insN.addAll(
            _forceSplit(
              text.substring(progress, nextLine),
              progress,
              min,
              gain,
              trigger,
              rng,
            ),
          );
          progress = nextLine + 1;
        }
        j++;
      }
      if (progress < quote) {
        insN.addAll(
          _forceSplit(
            text.substring(progress, quote + 1),
            progress,
            min,
            gain,
            trigger,
            rng,
          ),
        );
        progress = quote + 1;
      }
    }
    while (j < insN.length) {
      nextLine = insN[j];
      if (progress < nextLine) {
        insN.addAll(
          _forceSplit(
            text.substring(progress, nextLine),
            progress,
            min,
            gain,
            trigger,
            rng,
          ),
        );
        progress = nextLine + 1;
      }
      j++;
    }
    if (progress < text.length) {
      insN.addAll(
        _forceSplit(
          text.substring(progress, text.length),
          progress,
          min,
          gain,
          trigger,
          rng,
        ),
      );
    }
  }

  // Correct the quote direction and record where an extra quote is inserted.
  final insQuote = List<bool>.filled(size, false);
  opend = false;
  for (var i = 0; i < size; i++) {
    final p = arrayQuote[i];
    if (mod[i] > 0) {
      string.setCharAt(p, _u('“'));
      if (opend) insQuote[i] = true;
      opend = true;
    } else if (mod[i] < 0) {
      string.setCharAt(p, _u('”'));
      opend = false;
    } else {
      opend = !opend;
      string.setCharAt(p, opend ? _u('“') : _u('”'));
    }
  }
  insN = insN.toSet().toList()..sort();

  final buffer = _Units('');
  var j = 0;
  var progress = 0;
  var nextLine = -1;
  if (insN.isNotEmpty) nextLine = insN[j];
  for (var i = 0; i < arrayQuote.length; i++) {
    final quote = arrayQuote[i];
    while (j < insN.length) {
      if (nextLine >= quote) break;
      nextLine = insN[j];
      buffer.appendRange(string.units, progress, nextLine + 1);
      buffer.append('\n');
      progress = nextLine + 1;
      j++;
    }
    if (progress < quote) {
      buffer.appendRange(string.units, progress, quote + 1);
      progress = quote + 1;
    }
    if (insQuote[i] && buffer.length > 2) {
      if (buffer.charAt(buffer.length - 1) == 0x0A) {
        buffer.append('“');
      } else {
        buffer.insert(buffer.length - 1, '”\n');
      }
    }
  }
  while (j < insN.length) {
    nextLine = insN[j];
    if (progress <= nextLine) {
      buffer.appendRange(string.units, progress, nextLine + 1);
      buffer.append('\n');
      progress = nextLine + 1;
    }
    j++;
  }
  if (progress < string.length) {
    buffer.appendRange(string.units, progress, string.length);
  }
  return buffer.toString();
}

/// The frozen `makeDict`: quoted non-punctuation runs that appear more than once,
/// up to [_wordMaxLength] characters.
List<String> _makeDict(String str) {
  final pattern = RegExp(
    '(?<=["\'”“])([^\n\\p{P}]{1,$_wordMaxLength})(?=["\'”“])',
    unicode: true,
  );
  final cache = <String>[];
  final dict = <String>[];
  for (final match in pattern.allMatches(str)) {
    final word = match.group(0)!;
    if (cache.contains(word)) {
      if (!dict.contains(word)) dict.add(word);
    } else {
      cache.add(word);
    }
  }
  return dict;
}

/// The frozen `seekIndexs`: the positions in `[from, to)` whose character is in
/// [key]. [inOrder] reads from the start; otherwise from the end (the value is
/// still the forward distance).
List<int> _seekIndexs(String str, String key, int from, int to, bool inOrder) {
  final list = <int>[];
  if (str.length - from < 1) return list;
  var i = 0;
  if (from > i) i = from;
  var t = str.length;
  if (to > 0) t = math.min(t, to);
  while (i < t) {
    final c = inOrder ? str.codeUnitAt(i) : str.codeUnitAt(str.length - i - 1);
    if (_matchUnit(key, c)) list.add(i);
    i++;
  }
  return list;
}

/// The frozen `seekLast`: the last position at or before [from] (searching down
/// to [to] + 1) whose character is in [key], or -1.
int _seekLast(String str, String key, int from, int to) {
  if (str.length - from < 1) return -1;
  var i = str.length - 1;
  if (from < i && i > 0) i = from;
  var t = 0;
  if (to > 0) t = to;
  while (i > t) {
    if (_matchUnit(key, str.codeUnitAt(i))) return i;
    i--;
  }
  return -1;
}

/// The frozen `seekIndex`: the first position in `[from, to)` whose character is
/// in [key], or -1.
int _seekIndex(String str, String key, int from, int to, bool inOrder) {
  if (str.length - from < 1) return -1;
  var i = 0;
  if (from > i) i = from;
  var t = str.length;
  if (to > 0) t = math.min(t, to);
  while (i < t) {
    final c = inOrder ? str.codeUnitAt(i) : str.codeUnitAt(str.length - i - 1);
    if (_matchUnit(key, c)) return i;
    i++;
  }
  return -1;
}

/// The frozen `match`: whether [unit] names a character of [set].
bool _matchUnit(String set, int unit) => set.codeUnits.contains(unit);

int _u(String ch) => ch.codeUnitAt(0);

/// The frozen `trim { it <= ' ' }`: trim the code units `<= 0x20`, and only
/// those (`\u3000` is not one of them).
String _trimLowControl(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && text.codeUnitAt(start) <= 0x20) {
    start++;
  }
  while (end > start && text.codeUnitAt(end - 1) <= 0x20) {
    end--;
  }
  return text.substring(start, end);
}

String _removeAll(String text, RegExp pattern) => text.replaceAll(pattern, '');

bool _isDialogueParagraph(String text) {
  final match = _paragraphDialogue.firstMatch(text);
  return match != null && match.start == 0 && match.end == text.length;
}

/// Kotlin's `Regex.split(input, limit = 0)`, measured against the frozen
/// compiler: for every match from the current offset it appends the run before
/// it, advances past it (and one further code unit for a zero-width match), and
/// finally appends the remainder — trailing empty strings included, and the
/// whole input when there is no match. Dart's `String.split` drops nothing but
/// also stops differently, so this reproduces Kotlin's own loop.
List<String> _kotlinSplit(String text, RegExp pattern) {
  final parts = <String>[];
  var lastStart = 0;
  var currentOffset = 0;
  while (currentOffset < text.length) {
    final matches = pattern.allMatches(text, currentOffset);
    if (matches.isEmpty) break;
    final match = matches.first;
    parts.add(text.substring(lastStart, match.start));
    lastStart = match.end;
    currentOffset = match.end;
    if (match.end == match.start) currentOffset++;
  }
  parts.add(text.substring(lastStart));
  return parts;
}

/// The frozen `PARAGRAPH_DIAGLOG` (`ContentHelp.kt:612`).
final _paragraphDialogue = RegExp('^["“”][^"“”]+["“”]\$');

// The marker sets (`ContentHelp.kt:600-615`).
const _markSentencesEnd = '？。！?!~';
const _markSentencesEndP = '.？。！?!~';
const _markSentencesMid = '.，、,—…';
const _markSentencesSay = '问说喊唱叫骂道着答';
const _markQuotationBefore = '，：,:';
const _markQuotation = '"“”';
const _wordMaxLength = 16;

// Java's `\s`, which ECMAScript widens; see the library note.
const _javaSpaceClass = r'[ \t\n\x0B\f\r]';
const _javaSpaceStar = '$_javaSpaceClass*';
const _javaSpaceMembers = r' \t\n\x0B\f\r';

/// A `StringBuilder` with the two operations the frozen `findNewLines` needs and
/// Dart's `StringBuffer` lacks: `setCharAt` and `insert`.
class _Units {
  _Units(String text) : units = text.codeUnits.toList();

  final List<int> units;

  int get length => units.length;

  int charAt(int index) => units[index];

  void setCharAt(int index, int unit) => units[index] = unit;

  void append(String text) => units.addAll(text.codeUnits);

  void appendRange(List<int> source, int start, int end) {
    for (var i = start; i < end; i++) {
      units.add(source[i]);
    }
  }

  void insert(int index, String text) => units.insertAll(index, text.codeUnits);

  @override
  String toString() => String.fromCharCodes(units);
}
