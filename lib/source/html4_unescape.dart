import 'html4_entities.dart';

/// One plain-text HTML4 pass, after a literal scalar's scripts. The named data
/// is exported from the frozen commons-text JAR; lists and chapter-content
/// callers omit this tail. Numeric behavior follows NumericEntityUnescaper's
/// required-semicolon and signed-32-bit parse, preserving UTF-16 code units.
String unescapeHtml4(String text) => text.replaceAllMapped(
  RegExp(r'&(?:#[xX]?[0-9A-Fa-f]+|[A-Za-z0-9]+);'),
  (match) {
    final token = match[0]!;
    final named = html4Entities[token];
    if (named != null) return named;
    if (!token.startsWith('&#')) return token;
    final hex = token.length > 3 && (token[2] == 'x' || token[2] == 'X');
    final number = int.tryParse(
      token.substring(hex ? 3 : 2, token.length - 1),
      radix: hex ? 16 : 10,
    );
    // Integer.parseInt rejects overflow and the translator leaves it untouched.
    if (number == null || number > 0x7fffffff) return token;
    if (number > 0x10ffff) {
      throw RangeError.range(number, 0, 0x10ffff, 'HTML4 code point');
    }
    return String.fromCharCode(number);
  },
);
