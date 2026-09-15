import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

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

  static void validate(String rule) {
    final normalized = rule.split(RegExp(r'\s+@js:')).first.trim();
    if (normalized.contains('{{')) return;
    final stripped = normalized.replaceAll(RegExp(r'\{\{[^}]+\}\}'), 'value');
    values(const <String, Object?>{}, stripped);
  }

  static Object? read(Object? value, String rule) =>
      values(value, rule).firstOrNull;
  static String text(Object? value, String rule) {
    final base = rule.split(RegExp(r'\s+@js:')).first.trim();
    final result = read(value, base);
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

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
