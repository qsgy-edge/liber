/// The frozen `AnalyzeRule` rule-field grammar, in one place and without an
/// engine of its own: the `@js:`/`<js>` split and `{{...}}`/`@get:`/`@put:`
/// substitution of `AnalyzeRule.splitSourceRule` (`AnalyzeRule.kt:471-520`) and
/// `SourceRule.makeUpRule` (`:575-620`), plus the `##`/`###` field split
/// (`:650-665`).
///
/// The product has two rule engines — the Rust HTML adapter and the bounded
/// JSONPath reader — and the frozen grammar above sits *in front of* both: a
/// rule field is split and substituted here, the extraction part goes to the
/// adapter's engine, and the `@js:`/`<js>` segments run on the engine's value
/// through the approved JavaScript boundary (ADR 0011). Before this file the
/// JSON adapter truncated a trailing ` @js:` (`JsonSourceRules.validate/text`)
/// and the HTML adapter refused the whole field, so a source that carried a
/// script either lost it silently or never ran at all.
///
/// What this path deliberately does not do: a second JavaScript evaluator (the
/// scripts go through [RuleFieldContext.evaluateScript], which is the runtime
/// the pipeline already owns), the request-time `{{key}}`/`{{page}}`
/// substitution (`source_url_rules.dart` owns that), and the frozen `$n`
/// capture references, which are refused by name.
library;

import 'dart:convert';

/// One `@js:`/`<js>` script segment, evaluated through the same JavaScript
/// boundary the source's other scripts use. The value the previous segment
/// produced is bound as `result`, exactly as the frozen `evalJS(rule, result)`
/// does.
typedef RuleScriptEvaluator =
    Future<Object?> Function(String script, Object? result);

/// One rule evaluated immediately against [value] by the adapter's extraction
/// engine. The frozen `makeUpRule` reaches it for a `{{$.x}}` expression and
/// for every `@put:` value, both *before* the field's own rule runs; an adapter
/// whose engine declares a whole page's rules up front (the HTML batch) owes a
/// one-rule call here.
typedef RuleExtraction = Future<Object?> Function(Object? value, String rule);

/// Reads one rule variable: the frozen `AnalyzeRule.get` (`AnalyzeRule.kt:697`)
/// reaching `BaseSource`'s variables.
typedef RuleVariableReader = Future<String> Function(String key);

/// Writes one rule variable: the frozen `AnalyzeRule.put` (`AnalyzeRule.kt:686`).
typedef RuleVariableWriter = Future<void> Function(String key, String value);

/// The adapter's edges of [RuleField]: how a script runs, how a value rule is
/// extracted, and where `@get:`/`@put:` read and write.
class RuleFieldContext {
  const RuleFieldContext({
    required this.evaluateScript,
    required this.extract,
    required this.readVariable,
    required this.writeVariable,
  });

  final RuleScriptEvaluator evaluateScript;
  final RuleExtraction extract;
  final RuleVariableReader readVariable;
  final RuleVariableWriter writeVariable;
}

/// The `##`/`###` fields of one rule segment (`AnalyzeRule.kt:650-665`).
class RuleReplaceFields {
  const RuleReplaceFields(
    this.rule, {
    this.regex,
    this.replacement = '',
    this.replaceFirst = false,
  });

  /// The extraction rule, without its replacement fields.
  final String rule;

  /// The frozen `replaceRegex`, or null when the field carries no replacement.
  final String? regex;
  final String replacement;

  /// The frozen fourth field (`###`): replace the first match only.
  final bool replaceFirst;

  bool get hasReplacement => regex != null;
}

/// Kotlin's `split("##")` drops trailing empty fields, so `a##b##` is the
/// three-field replacement with an empty replacement text and `a##b##c###`
/// keeps its fourth field, which means replace the first match only.
RuleReplaceFields splitRuleFields(String text) {
  final parts = text.split('##');
  while (parts.length > 1 && parts.last.isEmpty) {
    parts.removeLast();
  }
  final rule = parts.first.trim();
  if (parts.length < 2) return RuleReplaceFields(rule);
  return RuleReplaceFields(
    rule,
    regex: parts[1],
    replacement: parts.length > 2 ? parts[2] : '',
    replaceFirst: parts.length > 3,
  );
}

/// One rule field split into its extraction text and its script segments,
/// before any value is substituted. Synchronous, so a pipeline can refuse a
/// broken field before it sends a request.
class RuleFieldText {
  const RuleFieldText(this.extractionRule, this.scripts);

  /// The text the adapter's extraction engine must run, or null when the field
  /// is a script only (the frozen `@js:`-only rule).
  final String? extractionRule;

  /// The `@js:`/`<js>` script bodies, in order.
  final List<String> scripts;
}

final _scriptPattern = RegExp(
  r'<js>([\s\S]*?)</js>|@js:([\s\S]*)',
  caseSensitive: false,
);
final _jsOpenPattern = RegExp(r'<js>', caseSensitive: false);
final _evalPattern = RegExp(
  r'@get:\{[^}]*\}|@get:[A-Za-z_][A-Za-z0-9_]*|\{\{[\s\S]*?\}\}',
  caseSensitive: false,
);
final _putPattern = RegExp(r'@put:(\{[^}]+?\})', caseSensitive: false);
final _capturePattern = RegExp(r'\$\d{1,2}');

/// Splits one rule field the way the frozen `AnalyzeRule.splitSourceRule` does.
///
/// The frozen `@js:` pattern consumes the rest of the field, so a script can
/// only be the last segment; a `<js>...</js>` block is the one form that can
/// stand in the middle, and a rule that continues after it is refused by name
/// because the frozen reader re-parses the script's value as a document and
/// neither adapter does that yet.
RuleFieldText parseRuleField(String field) {
  final extraction = <String>[];
  final scripts = <String>[];
  var start = 0;
  for (final match in _scriptPattern.allMatches(field)) {
    final text = field.substring(start, match.start).trim();
    if (text.isNotEmpty) extraction.add(text);
    scripts.add(match[1] ?? match[2] ?? '');
    start = match.end;
  }
  final tail = field.substring(start).trim();
  if (tail.isNotEmpty) extraction.add(tail);
  for (final text in extraction) {
    if (_jsOpenPattern.hasMatch(text)) {
      throw FormatException('规则字段的 <js> 缺少 </js>：$field');
    }
    // `$1` in the rule part is the frozen regex-capture family
    // (`AnalyzeRule.kt:600-616`), which this path does not implement; the Rust
    // adapter refuses it too, and the JSON adapter refused it only as an
    // unreadable rule.
    if (_capturePattern.hasMatch(text.split('##').first)) {
      throw UnsupportedError('暂不支持规则字段的 \$n 捕获引用：$text');
    }
  }
  if (extraction.length > 1) {
    throw UnsupportedError('暂不支持 <js> 之后的规则片段（提取引擎无法就地重解析脚本结果）：$field');
  }
  return RuleFieldText(
    extraction.isEmpty ? (scripts.isEmpty ? '' : null) : extraction.first,
    scripts,
  );
}

/// One rule field resolved for one adapter: the extraction text its engine must
/// run, and the script segments that run on the engine's value afterwards.
class RuleField {
  RuleField._(this._context, this.extractionRule, this._scripts);

  final RuleFieldContext _context;

  /// The text the adapter's extraction engine runs, or null when the field is a
  /// script only.
  final String? extractionRule;

  final List<String> _scripts;

  /// The `@js:`/`<js>` script bodies, in order.
  List<String> get scripts => List.unmodifiable(_scripts);

  bool get isScriptOnly => extractionRule == null;

  /// The extraction text of [field] without resolving anything, or null when it
  /// is a script only.
  static String? extractionText(String field) =>
      parseRuleField(field).extractionRule;

  /// Splits [field] and resolves everything that runs **before** the adapter's
  /// extraction: the `@put:{...}` values and the `@get:`/`{{...}}`
  /// substitution. The `##`/`###` fields stay in [extractionRule]: the HTML
  /// engine's Rust adapter implements the frozen split, replacement and entity
  /// unescape in the frozen order, and the JSON adapter splits the same text
  /// with [splitRuleFields].
  static Future<RuleField> resolve(
    String field,
    RuleFieldContext context, {
    required Object? content,
    bool allowPut = true,
  }) async {
    final parts = parseRuleField(field);
    final extraction = parts.extractionRule == null
        ? null
        : await _substitute(parts.extractionRule!, content, context, allowPut);
    return RuleField._(context, extraction, parts.scripts);
  }

  /// Runs the script segments on the value the extraction produced, each one
  /// substituted first and bound as the next one's `result`.
  Future<Object?> apply(Object? value) async {
    var result = value;
    for (final script in _scripts) {
      final code = await _substitute(script, result, _context, true);
      if (code.trim().isEmpty) {
        // The frozen `evalJS("")` is `undefined`; skipping the call keeps an
        // empty trailing `@js:` from costing a bridge round trip.
        result = null;
        continue;
      }
      result = await _context.evaluateScript(code, result);
    }
    return result;
  }

  /// The frozen `SourceRule.makeUpRule`: `@put:` first, then `@get:` and
  /// `{{...}}` substituted into the rule text.
  static Future<String> _substitute(
    String text,
    Object? result,
    RuleFieldContext context,
    bool allowPut,
  ) async {
    var value = text;
    if (_putPattern.hasMatch(value)) {
      if (!allowPut) {
        throw UnsupportedError('@put: 不能嵌套在另一个 @put: 里：$text');
      }
      value = await _applyPuts(value, result, context);
    }
    if (!_evalPattern.hasMatch(value)) return value;
    final output = StringBuffer();
    var cursor = 0;
    for (final match in _evalPattern.allMatches(value)) {
      output.write(value.substring(cursor, match.start));
      final token = match[0]!;
      if (token.toLowerCase().startsWith('@get:')) {
        // The frozen `evalPattern` matches `@get:{key}`; the bare `@get:key`
        // the ticket names is accepted too and reads the same variable (the
        // frozen reader leaves that spelling in the rule as literal text, so
        // this is a deliberate, recorded extension).
        final key = token.startsWith('@get:{')
            ? token.substring(6, token.length - 1)
            : token.substring(5);
        output.write(await context.readVariable(key));
      } else {
        final expression = token.substring(2, token.length - 2);
        output.write(
          _format(await _evalExpression(expression, result, context)),
        );
      }
      cursor = match.end;
    }
    output.write(value.substring(cursor));
    return output.toString();
  }

  /// One `{{...}}` expression: a `$.`/`$[` expression is a nested rule against
  /// the current value (the frozen `SourceRule.isRule` branch); everything else
  /// is JavaScript, which is how `{{baseUrl}}`, `{{title}}` and
  /// `{{cookie.getKey(source.key)}}` reach the frozen bindings.
  static Future<Object?> _evalExpression(
    String expression,
    Object? result,
    RuleFieldContext context,
  ) {
    final trimmed = expression.trim();
    if (trimmed.startsWith(r'$.') || trimmed.startsWith(r'$[')) {
      return context.extract(result, trimmed);
    }
    if (trimmed.startsWith('@') || trimmed.startsWith('//')) {
      throw UnsupportedError('暂不支持 {{ }} 里的规则表达式：$expression');
    }
    return context.evaluateScript(expression, result);
  }

  /// The frozen `splitPutRule` (`AnalyzeRule.kt:404-416`) plus `putRule`
  /// (`:400-404`): each `@put:{json}` entry is a rule evaluated against the
  /// current value and stored as a rule variable.
  static Future<String> _applyPuts(
    String text,
    Object? result,
    RuleFieldContext context,
  ) async {
    var value = text;
    final puts = <(String, String)>[];
    for (final match in _putPattern.allMatches(text)) {
      value = value.replaceAll(match[0]!, '');
      final Object? decoded;
      try {
        decoded = jsonDecode(match[1]!);
      } on FormatException catch (error) {
        throw FormatException('@put: 不是合法 JSON：${error.message}');
      }
      if (decoded is! Map) throw const FormatException('@put: 参数必须是 JSON 对象');
      for (final entry in decoded.entries) {
        if (entry.value is! String) {
          throw FormatException('@put: 的值必须是规则字符串：${entry.key}');
        }
        puts.add(('${entry.key}', entry.value as String));
      }
    }
    for (final (key, rule) in puts) {
      final nested = await resolve(
        rule,
        context,
        content: result,
        allowPut: false,
      );
      final extracted = nested.extractionRule == null
          ? result
          : await context.extract(result, nested.extractionRule!);
      await context.writeVariable(key, _format(await nested.apply(extracted)));
    }
    return value;
  }

  /// The frozen `makeUpRule` value rules: null inserts nothing, an integral
  /// double is formatted without its fraction, everything else is its string.
  static String _format(Object? value) {
    if (value == null) return '';
    if (value is double &&
        value.isFinite &&
        value == value.truncateToDouble()) {
      return value.toInt().toString();
    }
    return '$value';
  }
}
