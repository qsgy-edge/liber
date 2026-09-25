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

/// The key, transformation and iv a 猫眼 `java.aesBase64DecodeToString` chapter
/// rule names, read from the rule text itself.
///
/// The rule's shape is
/// `$.path@js:java.aesBase64DecodeToString(result,"<key>","AES/CBC/PKCS5Padding","<iv>")`
/// (`JsEncodeUtils.aesBase64DecodeToString(str, key, transformation, iv)`, the
/// frozen's `analyzeRule` binding). The pipeline answers that call in Dart
/// because the member is outside this product's approved host surface (#10, ADR
/// 0011), so the arguments have to be read from the rule; a constant cannot work,
/// because the two 猫眼 sources in the operator's library carry different keys
/// (#94).
///
/// Null when the rule is not that call, or names a transformation this decoder
/// does not implement — the caller then answers the field the ordinary way and
/// the refusal names the field.
({String key, String iv})? catEyeAesArguments(String rule) {
  final match = RegExp(
    r'aesBase64DecodeToString\(\s*[^,]+,\s*"([^"]*)"\s*,\s*"([^"]*)"\s*,\s*"([^"]*)"',
  ).firstMatch(rule);
  if (match == null) return null;
  final transformation = match.group(2)!.toUpperCase();
  if (transformation != 'AES/CBC/PKCS5PADDING') return null;
  final key = match.group(1)!;
  final iv = match.group(3)!;
  if (key.isEmpty || iv.isEmpty) return null;
  return (key: key, iv: iv);
}

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
///
/// The grammar is the frozen `AnalyzeByJSonPath.kt`'s library, json-path 2.9.0
/// (`com.jayway.jsonpath.internal.path.PathCompiler` and its tokens): the same
/// token forms, the same refusals and the same quirks, each with the frozen code
/// that produces it named where it is reproduced. `tool/jsonpath_probe/` ran
/// every form below against the real jar and its transcript is the record; the
/// forms this adapter refuses are named in the capability matrix.
class JsonSourceRules {
  /// The matches of [rule] against [root], in the order json-path's
  /// `EvaluationContextImpl.addResult` collects them: a definite path names one
  /// value, an indefinite one every match under the document's own order.
  static List<Object?> values(Object? root, String rule) =>
      _matches(root, rule).results;

  /// The matches, and whether the path names one value — the frozen
  /// `Path.isDefinite()`, which decides the *text* a rule field carries
  /// ([_fieldText]).
  static ({List<Object?> results, bool definite}) _matches(
    Object? root,
    String rule,
  ) {
    final path = _parseRule(rule);
    return (
      results: _walk(root, path.steps, 0, true, root, rule),
      definite: path.isDefinite,
    );
  }

  /// Refuses a JSON extraction rule the reader cannot run.
  ///
  /// The caller passes the field's extraction text (`RuleField.extractionText`),
  /// so a `@js:`/`<js>` segment is already split off by the shared rule-field
  /// path instead of being truncated here, and its `##`/`###` fields and its
  /// `@put:`/`@get:` tokens belong to that path too. What is left of the
  /// extraction is what gets validated as JSONPath: a source rule that carries
  /// a script either runs it or refuses it, and never loses it.
  ///
  /// The gate is the parse, not a probe against an empty document: a rule whose
  /// *shape* a document's own types could reject (a slice at the root of a
  /// document that is a map, say) is a rule this reader can run, and the shape
  /// refusal belongs to the document it meets.
  static void validate(String rule, {bool forList = false}) {
    final text = _withoutJsonMode(
      splitRuleFields(rule).rule.replaceAll(_ruleFieldToken, '').trim(),
    );
    // A field whose text has nothing left to parse is read by this tree's own
    // runtime, not an unreadable rule: a `##…`-only field carries only a
    // replacement and a `@get:`-only field is supplied by its substitution
    // (`RuleField.resolve`), so the parse gate belongs to what is left to
    // parse, not to such a field. The frozen reads the same shape as the blank
    // rule branch (`AnalyzeRule.kt:259-300`).
    if (text.isEmpty || text.contains('{{')) return;
    _validateParts(text, forList: forList);
  }

  static void _validateParts(String rule, {required bool forList}) {
    final parts = _splitMerge(rule, includeInterleave: forList);
    if (parts == null) {
      _parseRule(rule);
    } else {
      for (final part in parts.rules) {
        if (part.isNotEmpty) _validateParts(part, forList: forList);
      }
    }
  }

  static Object? read(Object? value, String rule) =>
      values(value, rule).firstOrNull;

  /// One field's extraction text through the JSON reader: the `##`/`###` fields
  /// first, then the JSONPath — or the literal template the field already
  /// interpolated — the field carries.
  ///
  /// A dot-leading rule is a path too. json-path's `PathCompiler.compile`
  /// prefixes `$.` to a path that starts with neither `$` nor `@`, and the
  /// frozen reader decides a rule's mode from the *content* it was given
  /// (`AnalyzeRule.setContent`: `isJSON = content.toString().isJson()`), not
  /// from the rule, so a rule a JSON body sees is a path whatever its first
  /// character is; `.[?(@.title)]` is `$..[?(@.title)]` there and in the used
  /// sources. A dot-leading rule that is *not* a path is refused by name, where
  /// the frozen reader answers with the library's swallowed exception (a null).
  static Object? extract(Object? value, String rule) {
    final fields = splitRuleFields(rule);
    final part = fields.rule;
    final trimmed = _withoutJsonMode(part.trim());
    final String? result;
    if (trimmed.isEmpty) {
      result = value?.toString() ?? '';
    } else if (trimmed.startsWith(r'$') || trimmed.startsWith('.')) {
      result = _mergedText(value, trimmed);
    } else {
      result = part;
    }
    return applyRuleReplacement(result ?? '', fields);
  }

  static String? _mergedText(Object? value, String rule) {
    final parts = _splitMerge(rule);
    if (parts == null) return _fieldText(value, rule);
    final results = <String>[];
    var matched = false;
    for (final part in parts.rules) {
      final text = part.isEmpty ? null : _mergedText(value, part);
      if (text != null) matched = true;
      if (text != null && text.isNotEmpty) {
        results.add(text);
        if (parts.operator == '||') break;
      }
    }
    return matched ? results.join('\n') : null;
  }

  /// The text one path rule carries, the frozen `AnalyzeByJSonPath.getString`:
  /// `result = if (ob is List<*>) ob.joinToString("\n") else ob.toString()`. The
  /// transcript line `$.data[?(@.hasContent==1)].content ok List[String(A),
  /// String(C)]` is the list that line joins.
  ///
  /// json-path answers a definite path with the value it names and an indefinite
  /// one with its list of matches, so the two are joined apart: a definite
  /// *array* joins its elements (`$.plain` over three strings), an indefinite
  /// path joins its matches (`$.data[?(@.hasContent==1)].content` over the rows
  /// it kept). This is what makes a multi-match filter rule carry every match
  /// instead of the first one; it changes every multi-match rule the same way,
  /// which is the frozen behaviour. A rule that matches nothing is the null the
  /// frozen reader's swallowed exception leaves.
  ///
  /// A value that is not a string is rendered by the frozen `toString`
  /// ([_matchedText]) rather than by Dart's, so a rule whose matches are
  /// objects or arrays — a slice or a filter with no scalar leaf — carries the
  /// frozen container text.
  static String? _fieldText(Object? value, String rule) {
    final matches = _matches(value, rule);
    if (matches.results.isEmpty) return null;
    final joined = matches.definite ? matches.results.single : matches.results;
    if (joined == null) return null;
    if (joined is List) return joined.map(_matchedText).join('\n');
    return _matchedText(joined);
  }

  static String text(Object? value, String rule) {
    final result = extract(value, rule);
    if (result == null || result.toString().isEmpty) {
      throw FormatException('Missing JSON value for $rule');
    }
    return result.toString();
  }

  /// The raw matches of a list rule: the objects themselves, before the page
  /// walk stringifies them (`JsonSourcePipeline._pageTexts`). That stringified
  /// read is the frozen `getStringList` boundary, and its container rendering is
  /// a named out-of-corpus limit (`tool/jsonpath_oracle/README.md`, ticket #78).
  static List<dynamic> list(Object? value, String rule) =>
      _mergedList(value, _withoutJsonMode(rule.trim()));

  static List<dynamic> _mergedList(
    Object? value,
    String rule, {
    bool mergedBranch = false,
  }) {
    final parts = _splitMerge(rule, includeInterleave: true);
    if (parts == null) {
      final matches = _matches(value, rule);
      if (!matches.definite) return matches.results;
      final result = matches.results;
      if (result.length == 1 && result.first is List) {
        return result.first as List<dynamic>;
      }
      return mergedBranch ? [] : result;
    }
    final lists = <List<dynamic>>[];
    for (final part in parts.rules) {
      final items = part.isEmpty
          ? <dynamic>[]
          : _mergedList(value, part, mergedBranch: true);
      if (items.isNotEmpty) {
        lists.add(items);
        if (parts.operator == '||') break;
      }
    }
    if (lists.isEmpty) return [];
    if (parts.operator != '%%') return lists.expand((items) => items).toList();
    return [
      for (var index = 0; index < lists.first.length; index++)
        for (final items in lists)
          if (index < items.length) items[index],
    ];
  }

  static String template(Object? value, String input) {
    final rule = input.split(',{').first.trim();
    if (rule.startsWith(r'$') || rule.toLowerCase().startsWith('@json:')) {
      return text(value, rule);
    }
    return rule.replaceAllMapped(RegExp(r'\{\{(\$[^}]+)\}\}'), (m) {
      final result = read(value, m[1]!);
      return result?.toString() ?? '';
    });
  }
}

String _withoutJsonMode(String rule) =>
    rule.toLowerCase().startsWith('@json:') ? rule.substring(6) : rule;

/// RuleAnalyzer.splitRule protects quoted text and balanced selectors. Its
/// first top-level delimiter chooses the merge; other delimiters in a part are
/// processed when that part is evaluated recursively.
({String operator, List<String> rules})? _splitMerge(
  String rule, {
  bool includeInterleave = false,
}) {
  final stack = <String>[];
  String? quote;
  String? operator;
  final rules = <String>[];
  var start = 0;
  for (var i = 0; i < rule.length; i++) {
    final char = rule[i];
    if (char == r'\' && i + 1 < rule.length) {
      i++;
      continue;
    }
    if (quote != null) {
      if (char == quote) quote = null;
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == '[' || char == '(') {
      stack.add(char);
      continue;
    }
    if (char == ']' || char == ')') {
      if (stack.isNotEmpty) stack.removeLast();
      continue;
    }
    if (stack.isNotEmpty || i + 1 == rule.length) continue;
    final pair = rule.substring(i, i + 2);
    if (pair != '&&' && pair != '||' && (!includeInterleave || pair != '%%')) {
      continue;
    }
    operator ??= pair;
    if (operator != pair) continue;
    rules.add(rule.substring(start, i));
    start = i + 2;
    i++;
  }
  if (operator == null) return null;
  rules.add(rule.substring(start));
  return (operator: operator, rules: rules);
}

extension<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}

/// The one refusal every rule shape this adapter cannot run gets.
Never _refuse(String rule) =>
    throw UnsupportedError('Unsupported JSON rule: $rule');

/// One parsed rule: the steps after the context token.
class _JsonPath {
  const _JsonPath(this.steps);

  final List<_JsonStep> steps;

  /// The frozen `Path.isDefinite()`: every token definite, so the path names one
  /// value rather than a set of them.
  bool get isDefinite => steps.every((step) => step.isDefinite);
}

/// Parses one rule, or refuses it.
///
/// A rule that starts with neither `$` nor `.` is refused here, as it is by the
/// two entry points that route a rule (`extract` reads a `$`- or `.`-leading
/// rule as a path and answers every other rule with its own text), and so is
/// every shape this adapter does not run: a quoted property name (`['a']`), a
/// name outside `[A-Za-z_][A-Za-z0-9_]*`, a bare `*`, a trailing `.`, and the
/// slice spellings json-path itself refuses.
_JsonPath _parseRule(String rule) {
  final text = rule.trim();
  if (!text.startsWith(r'$') && !text.startsWith('.')) _refuse(rule);
  // json-path's `PathCompiler.compile` prefixes `$.` to a path that starts with
  // neither `$` nor `@`, so `.[?(@.title)]` reads as `$..[?(@.title)]` — through
  // the root and a scan, which is why the used form matches nested objects.
  return _parsePath(text.startsWith(r'$') ? text : r'$.' + text, rule);
}

/// The frozen `PathCompiler` for a path that carries its own context token,
/// minus the parts this adapter refuses by name.
_JsonPath _parsePath(String source, String rule) {
  if (source.isEmpty || (source[0] != r'$' && source[0] != '@')) _refuse(rule);
  final steps = <_JsonStep>[];
  var position = 1;
  if (position == source.length) return _JsonPath(steps);
  if (source[position] != '.' && source[position] != '[') _refuse(rule);
  while (position < source.length) {
    final char = source[position];
    if (char == '[') {
      final bracket = _parseBracket(source, position, rule);
      steps.add(bracket.step);
      position = bracket.position;
      continue;
    }
    if (char != '.') _refuse(rule);
    final scan = position + 1 < source.length && source[position + 1] == '.';
    position += scan ? 2 : 1;
    if (position >= source.length) {
      // The frozen `PathCompiler`: "Path must not end with a '.' or '..'".
      _refuse(rule);
    }
    if (scan && source[position] == '.') _refuse(rule);
    if (scan) steps.add(const _ScanStep());
    final token = _parseToken(source, position, rule);
    steps.add(token.step);
    position = token.position;
  }
  _checkScanTargets(steps, rule);
  return _JsonPath(steps);
}

/// Refuses the scan forms whose frozen result is decided by
/// `ScanPathToken.walkArray`'s own guard rather than by the token's meaning.
void _checkScanTargets(List<_JsonStep> steps, String rule) {
  for (var index = 0; index < steps.length; index++) {
    if (steps[index] is! _ScanStep || index + 1 == steps.length) continue;
    if (index + 2 == steps.length) continue;
    final target = steps[index + 1];
    // `walkArray` applies the token *after* the target to every element of an
    // array the target accepts, and `PathToken.handleObjectProperty` then reports
    // a property leaf only for the one element whose index the token before the
    // leaf names. The result of `$..[0]…`, `$..[1:2]…` and `$..*…` is decided by
    // that comparison rather than by an index or a wildcard; nothing in the
    // product uses them, so they are refused by name instead of guessed.
    if (target is _IndexStep ||
        target is _SliceStep ||
        target is _WildcardStep) {
      _refuse(rule);
    }
  }
}

/// Parses the token at [position]: a property name, a `*`, or a `[…]` bracket.
({_JsonStep step, int position}) _parseToken(
  String source,
  int position,
  String rule,
) {
  if (source[position] == '[') return _parseBracket(source, position, rule);
  if (source[position] == '*') {
    return (step: const _WildcardStep(), position: position + 1);
  }
  var end = position;
  while (end < source.length && _isNameBodyChar(source[end])) {
    end++;
  }
  final name = source.substring(position, end);
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name)) _refuse(rule);
  return (step: _PropertyStep(name), position: end);
}

bool _isNameBodyChar(String char) {
  final unit = char.codeUnitAt(0);
  return (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5a) ||
      (unit >= 0x61 && unit <= 0x7a) ||
      char == '_';
}

/// Parses one `[…]` token: the frozen `readArrayToken`, `readWildCardToken` and
/// `readFilterToken`, in the compiler's own order.
({_JsonStep step, int position}) _parseBracket(
  String source,
  int position,
  String rule,
) {
  final close = _closingBracketIndex(source, position);
  if (close == -1) _refuse(rule);
  final text = source.substring(position + 1, close).trim();
  final next = close + 1;
  if (text == '*') return (step: const _WildcardStep(), position: next);
  if (text.startsWith('?')) {
    return (
      step: _FilterStep(
        _compileFilter(source.substring(position, close + 1), rule),
        text,
      ),
      position: next,
    );
  }
  if (text.startsWith("'") || text.startsWith('"')) _refuse(rule);
  if (text.contains(':')) {
    return (step: _parseSlice(text, rule), position: next);
  }
  if (RegExp(r'^[0-9,\- ]+$').hasMatch(text)) {
    return (step: _parseIndex(text, rule), position: next);
  }
  _refuse(rule);
}

/// The frozen `ArrayIndexOperation.parse`: a comma-separated index list, inside
/// `Integer.parseInt`'s range.
_JsonStep _parseIndex(String text, String rule) {
  final indexes = <int>[];
  for (final part in text.split(',')) {
    final value = int.tryParse(part.trim());
    if (value == null || value > 0x7fffffff || value < -0x80000000) {
      _refuse(rule);
    }
    indexes.add(value);
  }
  return _IndexStep(indexes);
}

/// The frozen `ArraySliceOperation.parse`: at most two integers, at least one of
/// them written out, and nothing but digits, `-` and `:` between the brackets —
/// a space inside the brackets is refused by the library and refused here.
///
/// A third field is *ignored*, exactly as the frozen parse ignores it: the jar
/// returns the same matches for `$.data[1:3:2]` and `$.data[1:3]`. The two
/// spellings that reach the library with no bound at all — `[:]` and `[::n]` —
/// throw there, and are refused here.
_JsonStep _parseSlice(String text, String rule) {
  for (var index = 0; index < text.length; index++) {
    if (!RegExp(r'[0-9:\-]').hasMatch(text[index])) _refuse(rule);
  }
  final tokens = text.split(':');
  // Java's `String.split(":")` drops the trailing empty fields, so `[0:2:]` is
  // the frozen `[0:2]` and `[:]` leaves no field at all.
  while (tokens.isNotEmpty && tokens.last.isEmpty) {
    tokens.removeLast();
  }
  final open = tokens.isNotEmpty && tokens.first.isNotEmpty
      ? _sliceBound(tokens.first, rule)
      : null;
  final close = tokens.length > 1 && tokens[1].isNotEmpty
      ? _sliceBound(tokens[1], rule)
      : null;
  if (open != null && close == null) {
    return _SliceStep(_SliceKind.from, open, null);
  }
  if (open != null) return _SliceStep(_SliceKind.between, open, close);
  if (close != null) return _SliceStep(_SliceKind.to, null, close);
  _refuse(rule);
}

int _sliceBound(String text, String rule) {
  final value = int.tryParse(text);
  if (value == null || value > 0x7fffffff || value < -0x80000000) {
    _refuse(rule);
  }
  return value;
}

/// The index of the `]` that closes the `[` at [open], skipping quoted strings
/// the way the frozen `CharacterIndex` scans do.
int _closingBracketIndex(String source, int open) {
  var depth = 0;
  var quote = '';
  var escaped = false;
  for (var index = open; index < source.length; index++) {
    final char = source[index];
    if (quote.isNotEmpty) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        quote = '';
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
      continue;
    }
    if (char == '[') depth++;
    if (char == ']') {
      depth--;
      if (depth == 0) return index;
    }
  }
  return -1;
}

/// One path token, with the frozen `PathToken.isTokenDefinite` it carries.
sealed class _JsonStep {
  const _JsonStep();

  bool get isDefinite;
}

/// The `..` of a scan, which applies the token after it at every node.
class _ScanStep extends _JsonStep {
  const _ScanStep();

  @override
  bool get isDefinite => false;
}

class _PropertyStep extends _JsonStep {
  const _PropertyStep(this.name);

  final String name;

  @override
  bool get isDefinite => true;
}

class _WildcardStep extends _JsonStep {
  const _WildcardStep();

  @override
  bool get isDefinite => false;
}

class _IndexStep extends _JsonStep {
  _IndexStep(this.indexes) : fragment = '[${indexes.join(', ')}]';

  final List<int> indexes;

  /// The frozen `ArrayIndexOperation.toString`, which a refusal message quotes.
  final String fragment;

  @override
  bool get isDefinite => indexes.length == 1;
}

enum _SliceKind { from, to, between }

class _SliceStep extends _JsonStep {
  const _SliceStep(this.kind, this.open, this.close);

  final _SliceKind kind;
  final int? open;
  final int? close;

  /// The frozen `ArraySliceOperation.toString` — which prints the two fields it
  /// kept, so a `[1:3:2]` prints as `[1:3]` there too.
  String get fragment => '[${open ?? ''}:${close ?? ''}]';

  @override
  bool get isDefinite => false;
}

class _FilterStep extends _JsonStep {
  const _FilterStep(this.filter, this.fragment);

  final _Filter filter;

  /// The bracket text itself, which a refusal message quotes.
  final String fragment;

  @override
  bool get isDefinite => false;
}

/// Applies `steps[index..]` to [model]: the frozen `PathToken` chain, whose
/// tokens hand each other what they matched and let the last one collect it.
///
/// [prefixDefinite] is the frozen `PathToken.isUpstreamDefinite()` of the token
/// at [index] — `isRoot() || prev.isTokenDefinite() && prev.isUpstreamDefinite()`
/// — which the array and filter tokens use to choose between skipping a value
/// their rule cannot be applied to and failing on it.
List<Object?> _walk(
  Object? model,
  List<_JsonStep> steps,
  int index,
  bool prefixDefinite,
  Object? root,
  String rule,
) {
  if (index == steps.length) return <Object?>[model];
  final step = steps[index];
  final definite = prefixDefinite && step.isDefinite;
  switch (step) {
    case _ScanStep():
      // The frozen `ScanPathToken`: the token after `..` is applied at the model
      // itself and at every node below it, a node before its children, which is
      // the order the matches come out in.
      final target = steps[index + 1];
      final matches = <Object?>[];
      void visit(Object? node) {
        if (node is Map) {
          if (_scanTargetMatches(target, node, root)) {
            matches.addAll(_walk(node, steps, index + 1, false, root, rule));
          }
          for (final value in node.values) {
            visit(value);
          }
          return;
        }
        if (node is List) {
          if (_scanTargetMatches(target, node, root)) {
            matches.addAll(_walk(node, steps, index + 1, false, root, rule));
          }
          for (final value in node) {
            visit(value);
          }
        }
      }

      visit(model);
      return matches;
    case _PropertyStep(:final name):
      if (model is! Map || !model.containsKey(name)) return const <Object?>[];
      return _walk(model[name], steps, index + 1, definite, root, rule);
    case _WildcardStep():
      if (model is List) {
        return [
          for (final value in model)
            ..._walk(value, steps, index + 1, definite, root, rule),
        ];
      }
      if (model is Map) {
        return [
          for (final value in model.values)
            ..._walk(value, steps, index + 1, definite, root, rule),
        ];
      }
      return const <Object?>[];
    case _IndexStep(:final indexes, :final fragment):
      if (!_isArrayFor(model, prefixDefinite, fragment, rule)) {
        return const <Object?>[];
      }
      final list = model as List;
      final matches = <Object?>[];
      for (final offset in indexes) {
        // The frozen `handleArrayIndex`: a negative index counts from the end,
        // and an index the array does not have matches nothing at all — its
        // `IndexOutOfBoundsException` is caught and the token moves on.
        final at = offset < 0 ? list.length + offset : offset;
        if (at < 0 || at >= list.length) continue;
        matches.addAll(_walk(list[at], steps, index + 1, definite, root, rule));
      }
      return matches;
    case _SliceStep(:final kind, :final open, :final close, :final fragment):
      if (!_isArrayFor(model, prefixDefinite, fragment, rule)) {
        return const <Object?>[];
      }
      final list = model as List;
      if (list.isEmpty) return const <Object?>[];
      final matches = <Object?>[];
      for (final offset in _sliceOffsets(kind, open, close, list.length)) {
        // A `SLICE_BETWEEN` bound is not resolved against the length, so a
        // negative one arrives here and `handleArrayIndex` resolves it in turn.
        final at = offset < 0 ? list.length + offset : offset;
        if (at < 0 || at >= list.length) continue;
        matches.addAll(_walk(list[at], steps, index + 1, definite, root, rule));
      }
      return matches;
    case _FilterStep(:final filter, :final fragment):
      if (model is Map) {
        // The frozen `PredicatePathToken`: a filter applies to a map itself, so
        // a matched map is the result rather than its values.
        if (!filter.accepts(model, root)) return const <Object?>[];
        return _walk(model, steps, index + 1, definite, root, rule);
      }
      if (model is List) {
        final matches = <Object?>[];
        for (final value in model) {
          if (filter.accepts(value, root)) {
            matches.addAll(
              _walk(value, steps, index + 1, definite, root, rule),
            );
          }
        }
        return matches;
      }
      if (prefixDefinite) {
        throw FormatException(
          'Filter: $fragment can not be applied to primitives. '
          'Current context is: $model',
        );
      }
      return const <Object?>[];
  }
}

/// The frozen `ScanPathToken.createScanPredicate`: whether the token after `..`
/// is applied at [node].
bool _scanTargetMatches(_JsonStep target, Object? node, Object? root) {
  switch (target) {
    case _PropertyStep(:final name):
      // `PropertyPathTokenPredicate`: a map that carries the property the token
      // names.
      return node is Map && node.containsKey(name);
    case _WildcardStep():
      return true;
    case _IndexStep():
    case _SliceStep():
      // `ArrayPathTokenPredicate`.
      return node is List;
    case _FilterStep(:final filter):
      return filter.accepts(node, root);
    case _ScanStep():
      // Unreachable: the parser pairs every scan with a token.
      return false;
  }
}

/// The frozen `ArrayPathToken.checkArrayModel`: false when the value is not an
/// array the token can be applied to *and* the frozen evaluation would skip it
/// (an upstream that is already indefinite), true when the caller may read the
/// array, and a named error when the upstream is definite — the case the frozen
/// one raises `PathNotFoundException` for and the frozen *reader* swallows into
/// a null. That difference in the failure's shape is recorded rather than
/// smoothed over: what is accepted and what is refused is the same either way.
bool _isArrayFor(
  Object? model,
  bool prefixDefinite,
  String fragment,
  String rule,
) {
  if (model is List) return true;
  if (!prefixDefinite) return false;
  if (model == null) {
    throw FormatException('The path of $rule is null');
  }
  throw FormatException(
    'Filter: $fragment can only be applied to arrays. '
    'Current context is: $model',
  );
}

/// The offsets the frozen `ArraySliceToken` walks for one slice.
///
/// `SLICE_FROM` and `SLICE_TO` resolve a negative bound against the length;
/// `SLICE_BETWEEN` does not, so `[1:-1]` selects nothing where `[:-2]` gives all
/// but the last two — the jar's own asymmetry.
Iterable<int> _sliceOffsets(
  _SliceKind kind,
  int? open,
  int? close,
  int length,
) {
  switch (kind) {
    case _SliceKind.from:
      var start = open!;
      if (start < 0) start = length + start;
      if (start < 0) start = 0;
      return start >= length
          ? const <int>[]
          : [for (var index = start; index < length; index++) index];
    case _SliceKind.to:
      var end = close!;
      if (end < 0) end = length + end;
      if (end > length) end = length;
      return [for (var index = 0; index < end; index++) index];
    case _SliceKind.between:
      var end = close!;
      if (end > length) end = length;
      return [for (var index = open!; index < end; index++) index];
  }
}

/// json-path's `ValueNodes.UNDEFINED`: a path operand that resolved to nothing.
///
/// It is not a JSON `null`: `@.missing == null` is false there and here, and an
/// existence check answers `false` for it.
class _Undefined {
  const _Undefined();

  @override
  String toString() => 'undefined';
}

const _undefined = _Undefined();

/// One compiled filter, the frozen `FilterCompiler`'s expression tree.
sealed class _Filter {
  const _Filter();

  /// The frozen `Predicate.apply`: whether one item — an array's element, or a
  /// map the filter was pointed at — passes.
  bool accepts(Object? item, Object? root);
}

/// The frozen `LogicalExpressionNode`: the operands of one `&&` or `||` run, in
/// the order they were read.
class _LogicalFilter extends _Filter {
  const _LogicalFilter.and(this.operands) : isAnd = true;
  const _LogicalFilter.or(this.operands) : isAnd = false;

  final bool isAnd;
  final List<_Filter> operands;

  @override
  bool accepts(Object? item, Object? root) => isAnd
      ? operands.every((filter) => filter.accepts(item, root))
      : operands.any((filter) => filter.accepts(item, root));
}

/// The frozen `LogicalExpressionNode.createLogicalNot`.
class _NotFilter extends _Filter {
  const _NotFilter(this.operand);

  final _Filter operand;

  @override
  bool accepts(Object? item, Object? root) => !operand.accepts(item, root);
}

/// The operators this adapter runs, in the frozen `RelationalOperator`'s
/// spelling. The rest of the frozen set — `===`, `!==`, `contains`, `type`,
/// `all`, `subsetof`, `anyof`, `noneof`, `matches` — is refused by name.
enum _JsonOperator {
  equal,
  notEqual,
  lessThan,
  lessThanOrEqual,
  greaterThan,
  greaterThanOrEqual,
  regex,
  inList,
  notInList,
  size,
  empty,
  exists,
}

/// The frozen `RelationalExpressionNode`: both operands are resolved, then the
/// operator's own evaluator sees them.
class _RelationalFilter extends _Filter {
  const _RelationalFilter(this.left, this.operator, this.right);

  final _FilterOperand left;
  final _JsonOperator operator;
  final _FilterOperand right;

  @override
  bool accepts(Object? item, Object? root) {
    final left = this.left.resolve(item, root);
    final right = this.right.resolve(item, root);
    return switch (operator) {
      _JsonOperator.equal => _nodeEquals(left, right),
      _JsonOperator.notEqual => !_nodeEquals(left, right),
      _JsonOperator.lessThan => _ordered(left, right, (order) => order < 0),
      _JsonOperator.lessThanOrEqual => _ordered(
        left,
        right,
        (order) => order <= 0,
      ),
      _JsonOperator.greaterThan => _ordered(left, right, (order) => order > 0),
      _JsonOperator.greaterThanOrEqual => _ordered(
        left,
        right,
        (order) => order >= 0,
      ),
      _JsonOperator.regex => _regexMatches(left, right),
      _JsonOperator.inList => _inList(left, right),
      _JsonOperator.notInList => !_inList(left, right),
      _JsonOperator.size => _sizeMatches(left, right),
      _JsonOperator.empty => _emptyMatches(left, right),
      _JsonOperator.exists => _existsMatches(left, right),
    };
  }
}

/// One operand of a filter, as the frozen `ValueNode` family gives it.
sealed class _FilterOperand {
  const _FilterOperand();

  /// The operand's value for one item: a JSON scalar, container or `null`, the
  /// [_undefined] the library answers a path with, a [_JsonPattern], or a
  /// boolean for the existence check the compiler builds itself.
  Object? resolve(Object? item, Object? root);
}

/// A path operand: `$…` reads the whole document, `@…` the item the filter is
/// looking at.
class _PathOperand extends _FilterOperand {
  const _PathOperand(
    this.path, {
    required this.fromRoot,
    required this.rule,
    this.negated = false,
    this.existsCheck = false,
  });

  final _JsonPath path;
  final bool fromRoot;
  final String rule;

  /// The `!` in front of the path, which the frozen reader keeps for the
  /// existence check it builds and otherwise ignores.
  final bool negated;

  /// The frozen `PathNode.asExistsCheck`: the operand is a boolean rather than
  /// the path's own value.
  final bool existsCheck;

  _PathOperand asExistsCheck() => _PathOperand(
    path,
    fromRoot: fromRoot,
    rule: rule,
    negated: negated,
    existsCheck: true,
  );

  @override
  Object? resolve(Object? item, Object? root) {
    final List<Object?> matches;
    try {
      matches = _walk(fromRoot ? root : item, path.steps, 0, true, root, rule);
    } on FormatException {
      // A path a document's own shape refuses is the frozen
      // `PathNotFoundException`, which `PathNode.evaluate` catches itself and
      // answers with UNDEFINED.
      return existsCheck ? false : _undefined;
    }
    if (existsCheck) return matches.isNotEmpty;
    if (matches.isEmpty) return _undefined;
    return path.isDefinite ? matches.last : matches;
  }
}

class _NumberOperand extends _FilterOperand {
  const _NumberOperand(this.value);

  final num value;

  @override
  Object? resolve(Object? item, Object? root) => value;
}

class _StringOperand extends _FilterOperand {
  const _StringOperand(this.value);

  final String value;

  @override
  Object? resolve(Object? item, Object? root) => value;
}

class _BooleanOperand extends _FilterOperand {
  const _BooleanOperand(this.value);

  final bool value;

  @override
  Object? resolve(Object? item, Object? root) => value;
}

class _NullOperand extends _FilterOperand {
  const _NullOperand();

  @override
  Object? resolve(Object? item, Object? root) => null;
}

class _JsonOperand extends _FilterOperand {
  const _JsonOperand(this.value);

  /// The `{…}`/`[…]` literal, read by this adapter's own permissive reader.
  final Object? value;

  @override
  Object? resolve(Object? item, Object? root) => value;
}

class _PatternOperand extends _FilterOperand {
  const _PatternOperand(this.pattern);

  final _JsonPattern pattern;

  @override
  Object? resolve(Object? item, Object? root) => pattern;
}

/// One `=~` pattern: the frozen `PatternNode`, whose pattern is translated from
/// Java by the same port the content replace rules already run on.
class _JsonPattern {
  const _JsonPattern(this.expression);

  final RegExp expression;

  /// The frozen `Matcher.matches()`: the whole input. The translation wraps the
  /// pattern in an anchoring non-capturing group, so a match can only span the
  /// input.
  bool matchesWhole(String input) => expression.hasMatch(input);
}

/// Compiles one `[?(…)]` bracket text, or refuses it.
_Filter _compileFilter(String text, String rule) =>
    _FilterParser(text, rule).parse();

/// The frozen `FilterCompiler` for one filter bracket.
class _FilterParser {
  _FilterParser(String bracketText, this.rule)
    : expression = _innerExpression(bracketText, rule);

  final String rule;

  /// The filter's own text, between `?(` and the closing `)`.
  final String expression;

  int position = 0;

  /// The frozen `FilterCompiler`'s constructor: the text must be `[?(…)]`.
  static String _innerExpression(String text, String rule) {
    final trimmed = text.trim();
    if (!trimmed.startsWith('[') || !trimmed.endsWith(']')) _refuse(rule);
    var inner = trimmed.substring(1, trimmed.length - 1).trim();
    if (!inner.startsWith('?')) _refuse(rule);
    inner = inner.substring(1).trim();
    if (!inner.startsWith('(') || !inner.endsWith(')')) _refuse(rule);
    return inner.substring(1, inner.length - 1);
  }

  /// The frozen `FilterCompiler.compile`: the expression, then the end of the
  /// text.
  _Filter parse() {
    final filter = _logicalOr();
    _skipBlanks();
    if (position != expression.length) _refuse(rule);
    return filter;
  }

  _Filter _logicalOr() {
    final operands = <_Filter>[_logicalAnd()];
    while (true) {
      final savepoint = position;
      if (!_consumeLogicalOperator('||')) {
        position = savepoint;
        break;
      }
      operands.add(_logicalAnd());
    }
    return operands.length == 1 ? operands.first : _LogicalFilter.or(operands);
  }

  _Filter _logicalAnd() {
    final operands = <_Filter>[_operand()];
    while (true) {
      final savepoint = position;
      if (!_consumeLogicalOperator('&&')) {
        position = savepoint;
        break;
      }
      operands.add(_operand());
    }
    return operands.length == 1 ? operands.first : _LogicalFilter.and(operands);
  }

  /// The frozen `hasSignificantSubSequence`: the blanks go, then the operator
  /// text, and nothing moves when the operator is not there.
  bool _consumeLogicalOperator(String operator) {
    _skipBlanks();
    if (!expression.startsWith(operator, position)) return false;
    position += operator.length;
    return true;
  }

  /// The frozen `readLogicalANDOperand`: `!` and `(…)` bind here, and a `!`
  /// directly in front of a path belongs to that path's existence check.
  _Filter _operand() {
    final savepoint = position;
    _skipBlanks();
    if (_peek() == '!') {
      position++;
      _skipBlanks();
      if (_peek() != '@' && _peek() != r'$') return _NotFilter(_operand());
      position = savepoint;
    }
    _skipBlanks();
    if (_peek() == '(') {
      position++;
      final filter = _logicalOr();
      _skipBlanks();
      if (_peek() != ')') _refuse(rule);
      position++;
      return filter;
    }
    return _relational();
  }

  /// The frozen `readExpression`: a comparison, or — when no operator follows —
  /// the existence check the compiler builds itself, which compares the path's
  /// existence with a boolean.
  _Filter _relational() {
    final left = _value();
    final savepoint = position;
    final operator = _operator();
    if (operator != null) {
      final right = _value();
      _checkOperand(operator, right);
      return _RelationalFilter(left, operator, right);
    }
    position = savepoint;
    if (left is! _PathOperand) {
      // The frozen `left.asPathNode()` throws for a literal that has no
      // operator: the filter is refused.
      _refuse(rule);
    }
    return _RelationalFilter(
      left.asExistsCheck(),
      _JsonOperator.exists,
      _BooleanOperand(!left.negated),
    );
  }

  /// The operand each evaluator can actually read: the frozen `size` takes a
  /// number and `empty`/`exists` a boolean, an `in` list holds scalars (the
  /// frozen `toValueNode` refuses a nested container with "Could not determine
  /// value type"). The library finds all of that out while it evaluates and
  /// answers false or throws; this adapter refuses the rule by name instead.
  void _checkOperand(_JsonOperator operator, _FilterOperand operand) {
    switch (operator) {
      case _JsonOperator.size:
        if (operand is! _NumberOperand) _refuse(rule);
      case _JsonOperator.empty:
      case _JsonOperator.exists:
        if (operand is! _BooleanOperand) _refuse(rule);
      case _JsonOperator.inList:
      case _JsonOperator.notInList:
        if (operand is! _JsonOperand || operand.value is! List) _refuse(rule);
        for (final element in operand.value! as List) {
          if (element is List || element is Map) _refuse(rule);
        }
      default:
        break;
    }
  }

  /// The frozen `readRelationalOperator`, narrowed to the operators this adapter
  /// runs.
  _JsonOperator? _operator() {
    _skipBlanks();
    final start = position;
    final first = _peek();
    if (first == null || first == ')' || first == '&' || first == '|') {
      return null;
    }
    if (_isOperatorChar(first)) {
      while (_isOperatorChar(_peek())) {
        position++;
      }
    } else {
      // The frozen scan for a spelled-out operator stops at a space only, so
      // `in`, `nin`, `size`, `empty` and `exists` arrive here whole.
      while (_peek() != null && _peek() != ' ') {
        position++;
      }
    }
    return _operatorOf(expression.substring(start, position));
  }

  _JsonOperator _operatorOf(String text) => switch (text) {
    '==' => _JsonOperator.equal,
    '!=' => _JsonOperator.notEqual,
    '<' => _JsonOperator.lessThan,
    '<=' => _JsonOperator.lessThanOrEqual,
    '>' => _JsonOperator.greaterThan,
    '>=' => _JsonOperator.greaterThanOrEqual,
    '=~' => _JsonOperator.regex,
    'in' || 'IN' || 'In' => _JsonOperator.inList,
    'nin' || 'NIN' || 'Nin' => _JsonOperator.notInList,
    'size' || 'SIZE' || 'Size' => _JsonOperator.size,
    'empty' || 'EMPTY' || 'Empty' => _JsonOperator.empty,
    'exists' || 'EXISTS' || 'Exists' => _JsonOperator.exists,
    // The frozen `fromString` uppercases before it compares; every operator the
    // library knows and this adapter does not run is refused here.
    _ => _refuse(rule),
  };

  /// The frozen `readValueNode` and `readLiteral`.
  _FilterOperand _value() {
    _skipBlanks();
    final char = _peek();
    switch (char) {
      case '@':
      case r'$':
        return _path(negated: false);
      case '!':
        position++;
        _skipBlanks();
        final next = _peek();
        if (next != '@' && next != r'$') _refuse(rule);
        return _path(negated: true);
      case "'":
      case '"':
        return _StringOperand(_stringLiteral(char!));
      case '/':
        return _PatternOperand(_patternLiteral());
      case 't':
      case 'f':
        return _BooleanOperand(_booleanLiteral());
      case 'n':
        return _nullLiteral();
      case '{':
      case '[':
        return _JsonOperand(_jsonLiteral());
      case null:
        _refuse(rule);
      default:
        return _NumberOperand(_numberLiteral());
    }
  }

  /// The frozen `readPath`: the path text runs to a blank, one of the relational
  /// operators' own characters, or the `)` that closes the expression.
  _FilterOperand _path({required bool negated}) {
    final fromRoot = expression[position] == r'$';
    final start = position;
    position++;
    while (true) {
      final char = _peek();
      if (char == null) break;
      if (char == '[') {
        final close = _closingBracketIndex(expression, position);
        if (close == -1) _refuse(rule);
        position = close + 1;
        continue;
      }
      if (char == ' ' || char == ')' || _isOperatorChar(char)) break;
      position++;
    }
    return _PathOperand(
      _parsePath(expression.substring(start, position), rule),
      fromRoot: fromRoot,
      rule: rule,
      negated: negated,
    );
  }

  /// The frozen `readStringLiteral` and `StringNode`: the quotes go and the text
  /// is unescaped with `Utils.unescape`.
  String _stringLiteral(String quote) {
    final start = position;
    position++;
    var escaped = false;
    while (true) {
      final char = _peek();
      if (char == null) _refuse(rule);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        break;
      }
      position++;
    }
    final text = expression.substring(start + 1, position);
    position++;
    return _unescape(text);
  }

  /// The frozen `readBooleanLiteral`.
  bool _booleanLiteral() {
    final start = position;
    while (position < expression.length &&
        _isNameBodyChar(expression[position])) {
      position++;
    }
    return switch (expression.substring(start, position)) {
      'true' => true,
      'false' => false,
      _ => _refuse(rule),
    };
  }

  _FilterOperand _nullLiteral() {
    final start = position;
    while (position < expression.length &&
        _isNameBodyChar(expression[position])) {
      position++;
    }
    if (expression.substring(start, position) != 'null') _refuse(rule);
    return const _NullOperand();
  }

  /// The frozen `readNumberLiteral`: json-path reads a run of its own number
  /// characters and hands the text to `BigDecimal`, so a run that is not a number
  /// at all refuses the rule rather than becoming a value.
  num _numberLiteral() {
    final start = position;
    while (position < expression.length &&
        _isNumberChar(expression[position])) {
      position++;
    }
    final value = _numberFrom(expression.substring(start, position));
    if (value == null) _refuse(rule);
    return value;
  }

  /// The frozen `readPattern` and `PatternNode`: `/pattern/flags`, with the
  /// pattern translated from Java and only the flags a Dart `RegExp` carries
  /// exactly.
  _JsonPattern _patternLiteral() {
    final start = position;
    position++;
    var close = -1;
    var escaped = false;
    for (var index = position; index < expression.length; index++) {
      final char = expression[index];
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '/') {
        close = index;
        break;
      }
    }
    if (close == -1) _refuse(rule);
    final source = expression.substring(start + 1, close);
    position = close + 1;
    var flags = '';
    while (position < expression.length &&
        'dixmsuU'.contains(expression[position])) {
      flags += expression[position];
      position++;
    }
    // Java's flag set is `d i x m s u U`. Of them, `i` and `s` are the two whose
    // meaning for a Dart `RegExp` is the frozen `Matcher.matches()`'s meaning;
    // `m` is refused rather than matched wrongly, because a Dart `MULTILINE`
    // `^`/`$` would stand in for the anchoring the full match needs, and the
    // rest (`d`, `x`, `u`, `U`) have no Dart equivalent at all.
    for (final flag in flags.split('')) {
      if (flag != 'i' && flag != 's') _refuse(rule);
    }
    final translated = translateJavaPattern('${_flagPrefix(flags)}$source');
    if (!translated.isRunnable || translated.multiLine) _refuse(rule);
    return _JsonPattern(
      RegExp(
        '^(?:${translated.source!})\$',
        caseSensitive: translated.caseSensitive,
        dotAll: translated.dotAll,
        unicode: translated.unicode,
      ),
    );
  }

  /// A JSON literal — the frozen `readJsonLiteral` and `JsonNode`. json-smart
  /// parses the text permissively (single quotes, bare keys), so this adapter
  /// reads it itself and refuses what its reader cannot follow.
  Object? _jsonLiteral() {
    final reader = _JsonLiteralReader(expression, position, rule);
    final value = reader.read();
    position = reader.position;
    return value;
  }

  void _skipBlanks() {
    while (position < expression.length && expression[position] == ' ') {
      position++;
    }
  }

  String? _peek() => position < expression.length ? expression[position] : null;
}

/// The `(?i)`/`(?s)` prefix for the flags a `=~` pattern wrote, which the
/// Java-pattern port folds into the translated expression's own flags.
String _flagPrefix(String flags) {
  var prefix = '';
  if (flags.contains('i')) prefix += 'i';
  if (flags.contains('s')) prefix += 's';
  return prefix.isEmpty ? '' : '(?$prefix)';
}

/// json-smart's permissive JSON reader, for one filter literal: the frozen
/// `JsonNode` parses its text with `JSONParser.MODE_PERMISSIVE`, so a rule may
/// write `['x','y']` or `{a:1}`. A literal this reader cannot follow is refused
/// by name rather than guessed at.
class _JsonLiteralReader {
  _JsonLiteralReader(this.text, this.position, this.rule);

  final String text;
  final String rule;
  int position;

  /// The value at [position], with the position left after it.
  Object? read() {
    _skipBlanks();
    final char = _peek();
    switch (char) {
      case '[':
        return _array();
      case '{':
        return _object();
      case "'":
      case '"':
        return _string(char!);
      case 't':
      case 'f':
        return _word(const {'true': true, 'false': false});
      case 'n':
        final word = _word(const {'null': null});
        return word;
      case null:
        _refuse(rule);
      default:
        return _number();
    }
  }

  Object? _array() {
    position++;
    final values = <Object?>[];
    while (true) {
      _skipBlanks();
      if (_peek() == ']') {
        position++;
        return values;
      }
      values.add(read());
      _skipBlanks();
      if (_peek() == ',') {
        position++;
        continue;
      }
      if (_peek() != ']') _refuse(rule);
    }
  }

  Map<String, Object?> _object() {
    position++;
    final values = <String, Object?>{};
    while (true) {
      _skipBlanks();
      if (_peek() == '}') {
        position++;
        return values;
      }
      final key = switch (_peek()) {
        "'" || '"' => _string(_peek()!),
        null => _refuse(rule),
        _ => _bareKey(),
      };
      _skipBlanks();
      if (_peek() != ':') _refuse(rule);
      position++;
      values[key] = read();
      _skipBlanks();
      if (_peek() == ',') {
        position++;
        continue;
      }
      if (_peek() != '}') _refuse(rule);
    }
  }

  /// json-smart's permissive mode reads an unquoted key as its own text.
  String _bareKey() {
    final start = position;
    while (position < text.length && !' \t\r\n:,}[]'.contains(text[position])) {
      position++;
    }
    if (position == start) _refuse(rule);
    return text.substring(start, position);
  }

  String _string(String quote) {
    position++;
    final start = position;
    var escaped = false;
    while (true) {
      final char = _peek();
      if (char == null) _refuse(rule);
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == quote) {
        break;
      }
      position++;
    }
    final value = _unescape(text.substring(start, position));
    position++;
    return value;
  }

  Object? _word(Map<String, Object?> words) {
    final start = position;
    while (position < text.length && _isNameBodyChar(text[position])) {
      position++;
    }
    final word = text.substring(start, position);
    if (!words.containsKey(word)) _refuse(rule);
    return words[word];
  }

  num _number() {
    final start = position;
    while (position < text.length && _isNumberChar(text[position])) {
      position++;
    }
    final value = _numberFrom(text.substring(start, position));
    if (value == null) _refuse(rule);
    return value;
  }

  void _skipBlanks() {
    while (position < text.length && ' \t\r\n'.contains(text[position])) {
      position++;
    }
  }

  String? _peek() => position < text.length ? text[position] : null;
}

/// The frozen `EqualsEvaluator` over the `ValueNode` family, which is what `==`
/// runs.
///
/// The two directions are not symmetric there: a number compared with a numeric
/// *string* parses the string (`@.hasContent == 1` matches `1` and `"1"` — the
/// jar's `$.data[?(@.hasContent==1)]` returns both rows), while a string
/// compared with a number compares text (`'1.0' == 1` is false). A container
/// compares with a container of its own kind, a boolean only with a boolean, a
/// JSON null only with a null, and UNDEFINED with nothing at all.
bool _nodeEquals(Object? left, Object? right) {
  if (identical(left, _undefined) || identical(right, _undefined)) return false;
  if (left == null || right == null) return left == null && right == null;
  if (left is bool || right is bool) {
    return left is bool && right is bool && left == right;
  }
  if (left is num && right is num) return left == right;
  if (left is num && right is String) {
    final number = _numberFrom(right);
    return number != null && left == number;
  }
  if (left is String && right is num) return left == _numberText(right);
  if (left is String && right is String) return left == right;
  if (left is List && right is List) return _deepEquals(left, right);
  if (left is Map && right is Map) return _deepEquals(left, right);
  return false;
}

/// The frozen `JsonNode.equals(JsonNode, ctx)`, which compares the two parsed
/// documents: `@.tags == ['x','y']` matches a `tags` of exactly those strings.
bool _deepEquals(Object? left, Object? right) {
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_deepEquals(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key)) return false;
      if (!_deepEquals(entry.value, right[entry.key])) return false;
    }
    return true;
  }
  if (left is List || right is List || left is Map || right is Map) {
    return false;
  }
  return _nodeEquals(left, right);
}

/// The frozen relational evaluators: numbers compare with numbers, strings with
/// strings, and every other pairing is false — `@.s > 9` on a string matches
/// nothing rather than comparing loosely.
bool _ordered(Object? left, Object? right, bool Function(int order) test) {
  final order = _compare(left, right);
  return order != null && test(order);
}

int? _compare(Object? left, Object? right) {
  if (left is num && right is num) return left.compareTo(right);
  if (left is String && right is String) return left.compareTo(right);
  return null;
}

/// The frozen `RegexpEvaluator`: exactly one operand is the pattern, the other
/// operand's text is matched whole, and a list matches when one of its elements
/// does.
bool _regexMatches(Object? left, Object? right) {
  final _JsonPattern pattern;
  final Object? input;
  if (left is _JsonPattern) {
    pattern = left;
    input = right;
  } else if (right is _JsonPattern) {
    pattern = right;
    input = left;
  } else {
    return false;
  }
  if (input is List) {
    return input.any((element) => pattern.matchesWhole(_patternInput(element)));
  }
  return pattern.matchesWhole(_patternInput(input));
}

/// The frozen `RegexpEvaluator.getInput`: a number, a string or a boolean
/// contributes its text and every other node an empty string.
String _patternInput(Object? value) {
  if (value is num || value is String || value is bool) return '$value';
  return '';
}

/// The frozen `toString` of one value a rule matched.
///
/// Two library types meet here, and `AnalyzeByJSonPath.getString` reaches both:
/// the reader calls `toString()` on a single value and `joinToString("\n")` on a
/// definite array's elements, so a nested container is rendered by its own rule
/// instead of being flattened. json-path's default reader hands back a
/// `net.minidev.json.JSONArray` for an array and a `java.util.LinkedHashMap` for
/// an object (`JsonPath.parse` on the frozen classpath — the class names are in
/// `tool/jsonpath_oracle/README.md`). The corpus in
/// `tool/jsonpath_oracle/fixtures.json` pins every branch below:
///
/// - the **object form** is `java.util.LinkedHashMap`'s `AbstractMap.toString`:
///   `{k=v, k2=v2}`, keys unquoted, `=`, entries separated by `, ` in the
///   document's own key order, `{}` when empty. A string value is written as it
///   is — also by `AbstractMap.toString`, which calls the value's own
///   `toString` — so `{a=x, y}` carries a comma the form never quotes.
/// - the **array form** (`JSONArray.toString`) is `[a,b]`: elements separated by
///   `,` — no space — and `[]` when empty. A *string* element is quoted and
///   escaped, which is why `["a\"b"]` looks unlike the object form's values.
/// - a map directly inside an array is the **JSON object form** `{"k":v}`:
///   quoted keys and `:`, while the same map as an object-form *value* stays
///   `{k=v}`. `{c={d=null}}` and `m=[{"k":"v"}]` are the two pinned shapes.
///
/// The numbers are the ones Dart and the JVM agree on: an integer has no
/// fraction and a double keeps its `.0`. Java writes `1.0E7` and up in
/// scientific notation where Dart writes a decimal, so a magnitude at or above
/// 1e7 (or below 1e-3) is outside this corpus.
String _matchedText(Object? value) {
  if (value is Map) return _mapText(value);
  if (value is List) return _arrayText(value);
  return _scalarText(value);
}

/// The object form, `java.util.LinkedHashMap`'s `AbstractMap.toString`:
/// `{k=v, k2=v2}`, and its values through [_matchedText] because the JVM form
/// calls each value's own `toString`.
String _mapText(Map<Object?, Object?> map) {
  if (map.isEmpty) return '{}';
  final entries = map.entries.map(
    (entry) => '${entry.key}=${_matchedText(entry.value)}',
  );
  return '{${entries.join(', ')}}';
}

/// The array form: `[a,b]`, and its elements through [_jsonValueText].
String _arrayText(List<Object?> list) {
  if (list.isEmpty) return '[]';
  return '[${list.map(_jsonValueText).join(',')}]';
}

/// One array element: a string is quoted and escaped, a map takes the JSON
/// object form, a list the array form, and every other value its own text.
String _jsonValueText(Object? value) {
  if (value is String) return '"${_jsonEscape(value)}"';
  if (value is Map) return _jsonMapText(value);
  return _matchedText(value);
}

/// The JSON object form, reached only as an array element: `{"k":v}`.
String _jsonMapText(Map<Object?, Object?> map) {
  if (map.isEmpty) return '{}';
  final entries = map.entries.map(
    (entry) => '"${_jsonEscape('${entry.key}')}":${_jsonValueText(entry.value)}',
  );
  return '{${entries.join(',')}}';
}

/// A scalar through the frozen `toString`: a string as it is, a boolean as
/// `true`/`false`, a null as `null`, and a number as its own text.
String _scalarText(Object? value) {
  if (value == null) return 'null';
  if (value is bool) return value ? 'true' : 'false';
  return '$value';
}

/// The frozen escaper, `net.minidev.json.JStylerObj$Escape4Web.escape`: json-smart
/// selects `Escape4Web` for the style the reader's writer uses (`NO_COMPRESS` sets
/// `_protect4Web`), and only the array form and the JSON object form run it.
///
/// Its switch writes eight shorthands — `\b \t \n \f \r \" \/ \\` — and its
/// default branch escapes exactly three numeric ranges, as `\u` plus four
/// **uppercase** hex digits: the C0 controls (`<= 0x1F`), the DEL and C1 range
/// (`0x7F-0x9F`) and the U+2000-U+20FF band that carries the curly quotes,
/// dashes and ellipses Chinese titles use. Everything else — a letter, a CJK
/// character, an emoji's surrogate pair — is written raw.
///
/// The corpus's `render-escaper-classes` row pins one character per class,
/// because a model that missed a range would still pass every ASCII row.
String _jsonEscape(String value) {
  final out = StringBuffer();
  for (final unit in value.codeUnits) {
    final escaped = switch (unit) {
      0x08 => r'\b',
      0x09 => r'\t',
      0x0A => r'\n',
      0x0C => r'\f',
      0x0D => r'\r',
      0x22 => r'\"',
      0x2F => r'\/',
      0x5C => r'\\',
      _ => null,
    };
    if (escaped != null) {
      out.write(escaped);
    } else if (unit <= 0x1F ||
        (unit >= 0x7F && unit <= 0x9F) ||
        (unit >= 0x2000 && unit <= 0x20FF)) {
      out.write('\\u${unit.toRadixString(16).toUpperCase().padLeft(4, '0')}');
    } else {
      out.writeCharCode(unit);
    }
  }
  return out.toString();
}

/// The frozen `InEvaluator`: the right operand is the list a rule wrote and the
/// left operand is compared with it through `==`.
bool _inList(Object? left, Object? right) {
  if (right is! List) return false;
  return right.any((element) => _nodeEquals(left, element));
}

/// The frozen `SizeEvaluator`: a string's or an array's length against a number.
bool _sizeMatches(Object? left, Object? right) {
  if (right is! num) return false;
  final expected = right.toInt();
  if (left is String) return left.length == expected;
  if (left is List) return left.length == expected;
  return false;
}

/// The frozen `EmptyEvaluator`: a string or a JSON container against a boolean.
/// Every other value — an absent key, a number, a null — is false, so
/// `@.title empty true` matches a `title` that is present and empty and not one
/// that is missing.
bool _emptyMatches(Object? left, Object? right) {
  if (right is! bool) return false;
  if (left is String) return left.isEmpty == right;
  if (left is List) return left.isEmpty == right;
  if (left is Map) return left.isEmpty == right;
  return false;
}

/// The frozen `ExistsEvaluator`: both operands are booleans — the existence
/// check the compiler builds always is — and every other operand means the
/// predicate is false. That is the library's own `@.hasContent exists true`,
/// which matches nothing: the operand is the path's *value*, not its existence.
bool _existsMatches(Object? left, Object? right) =>
    left is bool && right is bool && left == right;

/// `BigDecimal`'s grammar, so a string is a number exactly when the frozen
/// `StringNode.asNumberNode` reads it as one.
final _bigDecimal = RegExp(r'^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$');

num? _numberFrom(String text) {
  if (!_bigDecimal.hasMatch(text)) return null;
  return num.tryParse(text);
}

/// The text `NumberNode.asStringNode` gives a number: the literal text Java's
/// `Integer`/`BigDecimal` `toString` produces for the shapes a rule compares.
/// (Java's `Double.toString` spells an extreme magnitude differently —
/// `1.0E21` against Dart's `1e+21` — which a rule would have to write that
/// number to reach.)
String _numberText(num value) => value.toString();

bool _isNumberChar(String char) =>
    char == '-' || char == '.' || char == 'e' || char == 'E' || _isDigit(char);

bool _isDigit(String char) {
  final unit = char.codeUnitAt(0);
  return unit >= 0x30 && unit <= 0x39;
}

bool _isOperatorChar(String? char) =>
    char == '<' || char == '>' || char == '=' || char == '~' || char == '!';

/// json-path's `Utils.unescape`, which the frozen `StringNode` runs over a quoted
/// literal: `\uXXXX` becomes the character, the eight common escapes their
/// control character, and any other escaped character itself.
String _unescape(String text) {
  if (!text.contains(r'\')) return text;
  final out = StringBuffer();
  var index = 0;
  while (index < text.length) {
    final char = text[index];
    if (char != r'\' || index + 1 >= text.length) {
      out.write(char);
      index++;
      continue;
    }
    final escaped = text[index + 1];
    if (escaped == 'u' && index + 5 < text.length) {
      final code = int.tryParse(
        text.substring(index + 2, index + 6),
        radix: 16,
      );
      if (code == null) {
        throw const FormatException('Unable to parse unicode value');
      }
      out.writeCharCode(code);
      index += 6;
      continue;
    }
    out.write(switch (escaped) {
      r'\' => r'\',
      "'" => "'",
      '"' => '"',
      'r' => '\r',
      'f' => '\f',
      't' => '\t',
      'n' => '\n',
      'b' => '\b',
      _ => escaped,
    });
    index += 2;
  }
  return out.toString();
}
