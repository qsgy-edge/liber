/// The frozen reader's chapter-position mapping, ported from
/// `io.legado.app.help.book.BookHelp.getDurChapter` (frozen baseline
/// `14dd24945`, `help/book/BookHelp.kt:493-540`) with the helpers it reads:
/// `getChapterNum` (`:556-573`), `getPureChapterName` (`:592-599`),
/// `StringUtils.stringToInt`/`chineseNumToInt`/`fullToHalf`
/// (`utils/StringUtils.kt:133-218`) and Apache Commons Text's
/// `JaccardSimilarity`.
///
/// The frozen reader uses this when a book moves onto another source: the old
/// position is an index and a chapter title, the new source's table of contents
/// is a different list, and this decides which of its chapters the reader is
/// in. `Book.migrateTo` (`data/entities/Book.kt:341-358`) is the caller, from
/// `ReadBookViewModel.changeTo`, `BookInfoViewModel.changeTo` and
/// `BookshelfViewModel.addBook`'s same-name/author branch.
///
/// Java and Kotlin regexes are translated field for field; where a pattern's
/// meaning differs between the JVM and Dart's ECMAScript engine the frozen
/// meaning is what the port keeps, and the one place that cannot be carried is
/// named at its use.
library;

/// The numerals the frozen `chnMap` reads (`utils/StringUtils.kt:29-53`):
/// `零一二三四五六七八九十`, the financial `〇壹贰叁肆伍陆柒捌玖拾`, `两`, and the
/// scale words `百/佰`, `千/仟`, `万`, `亿`.
const Map<String, int> _chineseNumerals = {
  '零': 0,
  '〇': 0,
  '一': 1,
  '壹': 1,
  '二': 2,
  '贰': 2,
  '两': 2,
  '三': 3,
  '叁': 3,
  '四': 4,
  '肆': 4,
  '五': 5,
  '伍': 5,
  '六': 6,
  '陆': 6,
  '七': 7,
  '柒': 7,
  '八': 8,
  '捌': 8,
  '九': 9,
  '玖': 9,
  '十': 10,
  '拾': 10,
  '百': 100,
  '佰': 100,
  '千': 1000,
  '仟': 1000,
  '万': 10000,
  '亿': 100000000,
};

/// The numeral characters the frozen chapter-name patterns accept.
const String _numeralClass = r'[\d零〇一二两三四五六七八九十百千万壹贰叁肆伍陆柒捌玖拾佰仟]';

/// Kotlin `Regex("\\s")` under Java's default flags: the ASCII whitespace set,
/// narrower than Dart's `\s`. The frozen reads it through `StringUtils`'
/// whitespace stripping and as `regexA` from the pure-name strip.
final RegExp _javaWhitespace = RegExp(r'[ \t\n\x0b\f\r]+');

/// The frozen `chapterNamePattern1` (`BookHelp.kt:558-560`), read with `find`.
final RegExp _chapterNamePattern1 = RegExp('.*?第($_numeralClass+)[章节篇回集话]');

/// The frozen `chapterNamePattern2` (`BookHelp.kt:562-565`), read with `find`.
final RegExp _chapterNamePattern2 = RegExp(
  '^(?:$_numeralClass+[,:、])*($_numeralClass+)(?:[,:、]|\\.[^\\d])',
);

/// The frozen `regexB` (`BookHelp.kt:601-604`): a leading chapter number, kept
/// when it would empty the title.
final RegExp _pureNumberPrefix = RegExp(
  '^.*?第(?:$_numeralClass+)[章节篇回集话](?!\$)|'
  '^(?:$_numeralClass+[,:、])*(?:$_numeralClass+)(?:[,:、](?!\$)|'
  r'\.(?=[^\d]))',
);

/// The frozen `regexC` (`BookHelp.kt:606-610`): the brackets a title is wrapped
/// or suffixed with, kept when the whole title is inside them.
final RegExp _pureBrackets = RegExp(
  r'(?!^)(?:[〖【《〔\[{(][^〖【《〔\[{()〕》】〗\]}]+)?[)〕》】〗\]}]$|'
  r'^[〖【《〔\[{(](?:[^〖【《〔\[{()〕》】〗\]}]+[〕》】〗\]})])?(?!$)',
);

/// The frozen `regexOther` (`BookHelp.kt:612-615`): every character that is not
/// a word character or a CJK ideograph.
///
/// The pattern text is carried verbatim, `\u20000`-style escapes included: Java
/// reads `\u` as exactly four hex digits, so `\u20000` is `\u2000` followed by
/// `0`, and Dart's engine reads it the same way. Copying the text therefore
/// copies the meaning, quirk and all.
final RegExp _pureNonText = RegExp(
  r'[^\w\u4E00-\u9FEF〇\u3400-\u4DBF\u20000-\u2A6DF\u2A700-\u2EBEF]',
);

/// `StringUtils.fullToHalf`: the ideographic space becomes a space, and the
/// fullwidth block `0xFF01`-`0xFF5E` becomes its ASCII offset.
String sourceFullToHalf(String input) {
  final out = StringBuffer();
  for (final unit in input.codeUnits) {
    if (unit == 0x3000) {
      out.writeCharCode(0x20);
    } else if (unit >= 0xFF01 && unit <= 0xFF5E) {
      out.writeCharCode(unit - 0xFEE0);
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// `StringUtils.stringToInt` (`:209-219`): the JVM `Integer.parseInt` of a
/// normalised string, and the Chinese-numeral reading when that fails.
///
/// `null` answers `-1` without reading anything, as the frozen's early return
/// does. Java's `parseInt` accepts a signed ASCII integer and nothing else —
/// Dart's `int.parse` would also take `0x` and `0b` prefixes — so the ASCII
/// spelling is checked before the value is read.
int sourceStringToInt(String? value) {
  if (value == null) return -1;
  final normalised = sourceFullToHalf(value).replaceAll(_javaWhitespace, '');
  if (RegExp(r'^[+-]?[0-9]+$').hasMatch(normalised)) {
    final parsed = int.tryParse(normalised);
    if (parsed != null && parsed >= -2147483648 && parsed <= 2147483647) {
      return parsed;
    }
  }
  return _chineseNumToInt(normalised);
}

/// `StringUtils.chineseNumToInt` (`:153-202`): `一千零二十五` and `一千二` forms,
/// `-1` for a character the map does not know.
///
/// The frozen's first branch — `cn.size > 1 && chNum.matches("^[single]$")` —
/// can never be taken, because a one-character pattern matches only a
/// one-character string; it is not ported. Arithmetic wraps at 32 bits, as
/// Kotlin `Int` arithmetic does on the JVM and on ART.
int _chineseNumToInt(String value) {
  var result = 0;
  var tmp = 0;
  var billion = 0;
  final characters = value.split('');
  for (var i = 0; i < characters.length; i++) {
    final number = _chineseNumerals[characters[i]];
    if (number == null) return -1;
    if (number == 100000000) {
      result = _int32(result + tmp);
      result = _int32(result * number);
      billion = _int32(_int32(billion * 100000000) + result);
      result = 0;
      tmp = 0;
    } else if (number == 10000) {
      result = _int32(result + tmp);
      result = _int32(result * number);
      tmp = 0;
    } else if (number >= 10) {
      if (tmp == 0) tmp = 1;
      result = _int32(result + _int32(number * tmp));
      tmp = 0;
    } else {
      final previous = i >= 2 ? _chineseNumerals[characters[i - 1]] ?? -1 : -1;
      tmp = i >= 2 && i == characters.length - 1 && previous > 10
          ? (number * previous) ~/ 10
          : _int32(_int32(tmp * 10) + number);
    }
  }
  return _int32(result + tmp + billion);
}

/// Kotlin/Java 32-bit `Int` arithmetic on a Dart `int`.
int _int32(int value) => value.toSigned(32);

/// The frozen `BookHelp.getChapterNum` (`:556-573`): the chapter number a title
/// carries, or `-1` when it carries none.
///
/// The first pattern that matches wins, and its first capture group is read
/// through [sourceStringToInt]: `第12章` answers 12 and `第三章` answers 3.
int chapterNumberOf(String? chapterName) {
  if (chapterName == null) return -1;
  final normalised = sourceFullToHalf(
    chapterName,
  ).replaceAll(_javaWhitespace, '');
  final match =
      _chapterNamePattern1.firstMatch(normalised) ??
      _chapterNamePattern2.firstMatch(normalised);
  return sourceStringToInt(match?.group(1) ?? '-1');
}

/// The frozen `BookHelp.getPureChapterName` (`:592-599`): the title with its
/// numbering, blank runs, wrapping brackets and punctuation taken out, so two
/// sources' spellings of one chapter compare on the words alone.
String pureChapterName(String? chapterName) {
  if (chapterName == null) return '';
  return sourceFullToHalf(chapterName)
      .replaceAll(_javaWhitespace, '')
      .replaceAll(_pureNumberPrefix, '')
      .replaceAll(_pureBrackets, '')
      .replaceAll(_pureNonText, '');
}

/// Apache Commons Text's `JaccardSimilarity`: the size of the two strings'
/// character-set intersection over the size of their union.
///
/// The frozen `BookHelp.getDurChapter` reads it as a threshold that is tested
/// strictly on both sides — `< 0.96` to fall through to the chapter number and
/// `> 0.96` to decide the answer (`BookHelp.kt:517`, `:537`; see
/// [mapChapterIndex]). Two empty strings have an empty union and answer 0, which
/// the frozen's caller never reaches because it guards on a non-empty name.
double chapterNameSimilarity(String left, String right) {
  if (left.isEmpty && right.isEmpty) return 0;
  final leftSet = left.split('').toSet();
  final rightSet = right.split('').toSet();
  var intersection = 0;
  for (final character in leftSet) {
    if (rightSet.contains(character)) intersection++;
  }
  final union = leftSet.length + rightSet.length - intersection;
  return union == 0 ? 0 : intersection / union;
}

/// The frozen `BookHelp.getDurChapter` (`:493-540`): which chapter of
/// [newTitles] the reader is in, given where it was in the old table of
/// contents.
///
/// [oldIndex] is the old ordinal and [oldTitle] the chapter's name there (the
/// frozen `Book.durChapterTitle`, nullable and empty when the reader never had
/// one); [oldChapterCount] is the old table of contents' size — the frozen
/// `Book.totalChapterNum`, which `BookChapterList.kt:160` keeps equal to the
/// list it holds. The answer is an index into [newTitles].
///
/// The order of the frozen's decisions is kept: index 0 answers 0 without
/// looking at the new list, an empty list answers the old ordinal, a chapter
/// whose name matches **more than** 0.96 wins outright, and otherwise the
/// chapter number decides — falling back to the old ordinal when neither does.
///
/// The 0.96 threshold is read twice and strictly, as the frozen does at
/// `BookHelp.kt:517` and `:537`: `nameSim < 0.96` guards the number search and
/// `nameSim > 0.96` decides the answer, so a similarity of *exactly* 0.96 takes
/// neither side of the name rule — the number search is skipped, `newNum` stays
/// 0, and the answer is the clamped old ordinal unless the old title's own
/// chapter number is 0, when the `abs(newNum - oldChapterNum) < 1` arm answers
/// the matched index instead.
int mapChapterIndex({
  required int oldIndex,
  required String? oldTitle,
  required List<String> newTitles,
  required int oldChapterCount,
}) {
  if (oldIndex <= 0) return 0;
  if (newTitles.isEmpty) return oldIndex;
  final oldNumber = chapterNumberOf(oldTitle);
  final oldName = pureChapterName(oldTitle);
  final newSize = newTitles.length;
  // An old book with no recorded chapter count answers the old ordinal, the
  // frozen's `if (oldChapterListSize == 0) oldDurChapterIndex` branch.
  final projected = oldChapterCount == 0
      ? oldIndex
      : (oldIndex * oldChapterCount) ~/ newSize;
  final windowStart = _max(0, _min(oldIndex, projected) - 10);
  final windowEnd = _min(newSize - 1, _max(oldIndex, projected) + 10);
  var nameSimilarity = 0.0;
  var newIndex = 0;
  if (oldName.isNotEmpty) {
    for (var i = windowStart; i <= windowEnd; i++) {
      final similarity = chapterNameSimilarity(
        oldName,
        pureChapterName(newTitles[i]),
      );
      if (similarity > nameSimilarity) {
        nameSimilarity = similarity;
        newIndex = i;
      }
    }
  }
  var newNumber = 0;
  if (nameSimilarity < 0.96 && oldNumber > 0) {
    for (var i = windowStart; i <= windowEnd; i++) {
      final candidate = chapterNumberOf(newTitles[i]);
      if (candidate == oldNumber) {
        newNumber = candidate;
        newIndex = i;
        break;
      }
      if ((candidate - oldNumber).abs() < (newNumber - oldNumber).abs()) {
        newNumber = candidate;
        newIndex = i;
      }
    }
  }
  if (nameSimilarity > 0.96 || (newNumber - oldNumber).abs() < 1) {
    return newIndex;
  }
  return _min(_max(0, newTitles.length - 1), oldIndex);
}

int _min(int a, int b) => a < b ? a : b;

int _max(int a, int b) => a > b ? a : b;
