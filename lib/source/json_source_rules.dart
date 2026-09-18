import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'java_regex.dart';
import 'rule_field.dart';

/// The rule-field tokens the shared rule-field path resolves before the JSON
/// reader sees an extraction rule: `@put:{...}` and `@get:...`.
final _ruleFieldToken = RegExp(
  r'@put:\{[^}]+?\}|@get:\{[^}]*\}|@get:[A-Za-z_][A-Za-z0-9_]*',
  caseSensitive: false,
);

/// Decode the AES/CBC/PKCS5Padding chapter URLs used by the 猫眼 source.
String aesBase64DecodeToString(String encoded, String key, String iv) {
  final cipher = CBCBlockCipher(AESEngine())
    ..init(
      false,
      ParametersWithIV(KeyParameter(utf8.encode(key)), utf8.encode(iv)),
    );
  final input = base64.decode(encoded);
  final output = Uint8List(input.length);
  for (var offset = 0; offset < input.length; offset += cipher.blockSize) {
    cipher.processBlock(input, offset, output, offset);
  }
  final padding = output.last;
  if (padding < 1 ||
      padding > cipher.blockSize ||
      output.skip(output.length - padding).any((byte) => byte != padding)) {
    throw const FormatException('Invalid AES-CBC padding');
  }
  return utf8.decode(output.sublist(0, output.length - padding));
}

/// Bounded JSONPath adapter for the current Windows source slice.
class JsonSourceRules {
  static List<Object?> values(Object? root, String rule) {
    final expression = rule.trim();
    if (!expression.startsWith(r'$')) {
      throw UnsupportedError('Unsupported JSON rule: $rule');
    }
    final recursive = expression.startsWith(r'$..');
    final tail = expression.substring(recursive ? 3 : 2);
    final tokens = tail.isEmpty
        ? <String>[]
        : tail.split(RegExp(r'\.|\[|\]')).where((e) => e.isNotEmpty).toList();
    if (tokens.any(
      (token) =>
          token != '*' &&
          !RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(token) &&
          !RegExp(r'^\d+$').hasMatch(token),
    )) {
      throw UnsupportedError('Unsupported JSON rule: $rule');
    }
    var current = <Object?>[root];
    if (recursive) {
      final matches = <Object?>[];
      void walk(Object? value) {
        if (value is Map) {
          for (final entry in value.entries) {
            if (tokens.isEmpty || entry.key == tokens.first) {
              matches.add(entry.value);
            }
            walk(entry.value);
          }
        } else if (value is List) {
          for (final item in value) {
            walk(item);
          }
        }
      }

      walk(root);
      return matches;
    }
    for (final token in tokens) {
      final next = <Object?>[];
      for (final value in current) {
        if (token == '*') {
          if (value is List) next.addAll(value);
          if (value is Map) next.addAll(value.values);
        } else if (RegExp(r'^\d+$').hasMatch(token) && value is List) {
          final index = int.parse(token);
          if (index < value.length) next.add(value[index]);
        } else if (value is Map && value.containsKey(token)) {
          next.add(value[token]);
        }
      }
      current = next;
    }
    return current;
  }

  /// Refuses a JSON extraction rule the reader cannot run.
  ///
  /// The caller passes the field's extraction text (`RuleField.extractionText`),
  /// so a `@js:`/`<js>` segment is already split off by the shared rule-field
  /// path instead of being truncated here, and its `##`/`###` fields and its
  /// `@put:`/`@get:` tokens belong to that path too. What is left of the
  /// extraction is what gets validated as JSONPath: a source rule that carries
  /// a script either runs it or refuses it, and never loses it.
  static void validate(String rule) {
    final text = splitRuleFields(rule).rule
        .replaceAll(_ruleFieldToken, '')
        .trim();
    if (text.contains('{{')) return;
    values(const <String, Object?>{}, text);
  }

  static Object? read(Object? value, String rule) =>
      values(value, rule).firstOrNull;

  /// One field's extraction text through the JSON reader: the `##`/`###` fields
  /// first, then the JSONPath — or the literal template the field already
  /// interpolated — the field carries.
  static Object? extract(Object? value, String rule) {
    final fields = splitRuleFields(rule);
    final part = fields.rule;
    final trimmed = part.trim();
    final Object? result;
    if (trimmed.isEmpty) {
      result = value;
    } else if (trimmed.startsWith(r'$')) {
      result = read(value, trimmed);
    } else {
      result = part;
    }
    return applyRuleReplacement(result?.toString() ?? '', fields);
  }

  static String text(Object? value, String rule) {
    final result = extract(value, rule);
    if (result == null || result.toString().isEmpty) {
      throw FormatException('Missing JSON value for $rule');
    }
    return result.toString();
  }

  static List<dynamic> list(Object? value, String rule) {
    final result = values(value, rule);
    if (result.length == 1 && result.first is List) {
      return result.first as List<dynamic>;
    }
    return result;
  }

  static String template(Object? value, String input) {
    final rule = input.split(',{').first.trim();
    if (rule.startsWith(r'$')) return text(value, rule);
    return rule.replaceAllMapped(RegExp(r'\{\{(\$[^}]+)\}\}'), (m) {
      final result = read(value, m[1]!);
      return result?.toString() ?? '';
    });
  }
}

/// The frozen `AnalyzeRule.replaceRegex` (`AnalyzeRule.kt:650-665`) for a JSON
/// rule field's `##`/`###` fields. The HTML adapter's Rust layer implements the
/// same semantics for its own engine (and the oracle corpus exercises them
/// there); this copy reuses the Java-pattern port the content replace rules
/// already run on, and refuses a pattern it cannot express faithfully instead of
/// mis-applying it.
String applyRuleReplacement(String value, RuleReplaceFields fields) {
  final regex = fields.regex;
  if (regex == null) return value;
  final translated = translateJavaPattern(regex);
  if (!translated.isRunnable) {
    throw UnsupportedError('JSON 规则字段的 ## 替换不可用：${translated.refusal}');
  }
  final pattern = translated.compile();
  if (fields.replaceFirst) {
    // `##match##replace###`: the frozen `AnalyzeRule.replaceRegex` takes the
    // first match's own text and replaces the first match *inside it*, so a
    // zero-width pattern leaves the value as it is instead of inserting at the
    // match position.
    final match = pattern.firstMatch(value);
    if (match == null) return '';
    final matched = match.group(0)!;
    final inner = pattern.firstMatch(matched);
    if (inner == null) return matched;
    final expanded = expandJavaReplacement(fields.replacement, inner);
    // A replacement that names a group the pattern lacks makes Java throw; the
    // frozen `runCatching` then answers with the raw replacement.
    if (expanded == null) return fields.replacement;
    return matched.replaceRange(inner.start, inner.end, expanded);
  }
  final output = StringBuffer();
  var cursor = 0;
  for (final match in pattern.allMatches(value)) {
    final expanded = expandJavaReplacement(fields.replacement, match);
    if (expanded == null) {
      // The frozen fallback is a literal `String.replace` of the pattern text.
      return value.replaceAll(regex, fields.replacement);
    }
    output.write(value.substring(cursor, match.start));
    output.write(expanded);
    cursor = match.end;
  }
  output.write(value.substring(cursor));
  return output.toString();
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
