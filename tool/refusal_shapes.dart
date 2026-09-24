// Shape probe for the readiness audit's refusal classes (#82, batch 17).
//
// The audit (`tool/source_readiness.dart`) answers *which* rule reads refused a
// record and how many records meet each reason. It does not answer *what shape*
// each refusal saw, which is what a triage needs before a reason becomes a
// ticket. This mode replays the same reads over one backup (or bare export) and
// prints, per refused record of the used set, the shape label of every field
// the reason's read rejected.
//
// Like the audit it is static and network-free (no request, no script, no
// native library), it reuses the audit's own public constants and predicates so
// the two cannot drift, and it prints no rule text, URL, host or source name:
// every label is derived from the field's *shape* by pattern, never by quoting
// it. The position in `bookSource.json` is the only identity it prints, which is
// the audit's own convention.
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/rule_field.dart';

import 'source_readiness.dart';
import 'source_usage.dart';

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/refusal_shapes.dart <backup.zip|'
        'bookSource.json>');
    return;
  }
  final backup = readSourceBackup(args.first);
  final origins = backup.shelf == null ? null : shelfOrigins(backup.shelf!);
  final used = <int, Map<String, dynamic>>{};
  for (var index = 0; index < backup.sources.length; index++) {
    final source = backup.sources[index];
    if (origins == null || origins.contains(source['bookSourceUrl'])) {
      used[index] = source;
    }
  }
  final refused = <int, SourceReadiness>{};
  for (final entry in used.entries) {
    final readiness = auditSource(entry.value);
    if (!readiness.ready) refused[entry.key] = readiness;
  }

  final out = <String>[
    'static refusal shapes — network-free, no rule text, URL, host or source '
        'name is read out',
    ...sourceBackupLines(backup),
    'used: ${used.length}   refused: ${refused.length}',
    '',
    'reason sets over the refused used records:',
  ];
  final sets = <String, List<int>>{};
  for (final entry in refused.entries) {
    final key = ([...entry.value.reasons]..sort()).join(' + ');
    sets.putIfAbsent(key, () => <int>[]).add(entry.key);
  }
  final ordered = sets.entries.toList()
    ..sort((a, b) => b.value.length.compareTo(a.value.length));
  for (final entry in ordered) {
    out.add('  ${entry.value.length}  ${entry.key}   ${entry.value}');
  }
  out.add('');
  out.add('per reason, over the refused used records:');
  for (final check in readinessChecks) {
    final records = <int>[
      for (final entry in refused.entries)
        if (entry.value.reasons.contains(check.id)) entry.key,
    ];
    if (records.isEmpty) continue;
    out.add('');
    out.add('[${check.id}]  used refused ${records.length}   $records');
    for (final position in records) {
      final labels = _shapes(check.id, used[position]!);
      out.add('  [$position] ${labels.isEmpty ? 'no shape read' : labels.join('; ')}');
      final only = sets.entries
          .firstWhere((entry) => entry.value.contains(position))
          .key;
      out.add('      reasons: $only');
    }
  }
  out.add('');
  stdout.write('${out.join('\n')}\n');
}

/// The shape labels of every field [reason] refused on this record.
List<String> _shapes(String reason, Map<String, dynamic> source) {
  switch (reason) {
    case 'header-rule':
      return <String>[_headerShape(source)];
    case 'html-list-rule-script':
      return _slotShapes(source, HtmlRuleRead.elementList);
    case 'html-script-only-element-field':
      return _slotShapes(source, HtmlRuleRead.elementValue);
    case 'html-rule-field-syntax':
      return _slotShapes(source, null);
    case 'html-missing-required-field':
      return <String>[
        for (final slot in htmlRuleSlots)
          if (slot.required && _text(source, slot.group, slot.field) == null)
            '${slot.group}.${slot.field} absent/blank',
      ];
    case 'html-content-replace-rule':
      return _contentReplaceShapes(source);
    case 'json-rule-unreadable':
      return _jsonUnreadableShapes(source);
    case 'json-unsupported-field':
      return <String>[
        for (final field in _declaredJsonFields(source))
          if (_outsideVocabulary(field)) '${field.group}.${field.field}',
      ];
    case 'json-list-rule-script':
      return <String>[
        for (final field in _declaredJsonFields(source))
          if (_listRule(field.group, field.field) &&
              (parseOrNull(field.value)?.scripts.isNotEmpty ?? false))
            '${field.group}.${field.field}: extraction${parseOrNull(field.value)!.extractionRule == null ? '-only' : ' + script'}',
      ];
    case 'source-url':
      return const <String>['`bookSourceUrl` is not an http(s) identity '
          '(no value read out)'];
    default:
      return const <String>['(no shape probe)'];
  }
}

String? _text(Map<String, dynamic> source, String group, String field) {
  final rules = source[group];
  final value = rules is Map ? rules[field] : null;
  return value is String && value.isNotEmpty ? value : null;
}

/// [parseRuleField], or null when the split refuses the field.
RuleFieldText? parseOrNull(String field) {
  try {
    return parseRuleField(field);
  } on Object {
    return null;
  }
}

List<String> _slotShapes(Map<String, dynamic> source, HtmlRuleRead? read) {
  final labels = <String>[];
  for (final slot in htmlRuleSlots) {
    if (read != null && slot.read != read) continue;
    final text = _text(source, slot.group, slot.field);
    if (text == null) continue;
    final label = '${slot.group}.${slot.field}';
    final parts = parseOrNull(text);
    if (read == null) {
      if (parts == null) labels.add('$label: ${_splitShape(text)}');
      continue;
    }
    if (parts == null) {
      labels.add('$label: ${_splitShape(text)}');
      continue;
    }
    if (read == HtmlRuleRead.elementList && parts.scripts.isEmpty) continue;
    if (read == HtmlRuleRead.elementValue && parts.extractionRule != null) {
      continue;
    }
    final segments = '${parts.scripts.length} script segment(s)';
    final kind = text.toLowerCase().contains('@js:') ? '@js:' : '<js>';
    labels.add(
      parts.extractionRule == null
          ? '$label: script-only $kind ($segments)'
              '${slot.required ? ' — required field' : ' — optional field'}'
          : '$label: extraction + $kind ($segments)'
              '${slot.required ? ' — required field' : ' — optional field'}',
    );
  }
  return labels;
}

/// The shape of a rule-field split refusal, without quoting the field.
String _splitShape(String text) {
  final message = parseRuleFieldRefusal(text);
  if (message.contains('缺少 </js>')) return '<js> with no </js>';
  if (message.contains(r'\$n')) return r'$n capture reference';
  if (message.contains('之后的规则片段')) return 'segment after </js>';
  return 'rule-field split refusal';
}

/// The refusal text of [parseRuleField] for [text], used only to classify the
/// split family. Never printed.
String parseRuleFieldRefusal(String text) {
  try {
    parseRuleField(text);
    return '';
  } on Object catch (error) {
    return '$error';
  }
}

List<String> _contentReplaceShapes(Map<String, dynamic> source) {
  final content = _text(source, 'ruleContent', 'content') ?? '';
  final replacement = (_text(source, 'ruleContent', 'replaceRegex') ?? '')
      .replaceAll('{{chapter.title}}', '');
  final labels = <String>[];
  if (replacement.contains('{{')) {
    labels.add('`replaceRegex` carries a {{…}} expression other than '
        '{{chapter.title}}');
  }
  if (replacement.isNotEmpty && content.contains('##')) {
    labels.add('`content` carries its own ## fields '
        '(${content.split('##').length - 1} delimiter(s)) while `replaceRegex` '
        'is non-empty');
  }
  return labels;
}

class _JsonField {
  const _JsonField(this.group, this.field, this.value);

  final String group;
  final String field;
  final String value;
}

/// Every declared field of the four JSON groups, as `_rules` walks them (a null
/// or empty value is skipped there).
List<_JsonField> _declaredJsonFields(Map<String, dynamic> source) {
  final fields = <_JsonField>[];
  for (final group in jsonRequiredFields.keys) {
    final rules = source[group];
    if (rules is! Map) continue;
    for (final entry in rules.entries) {
      final value = entry.value;
      if (value == null || value == '' || value is! String) continue;
      fields.add(_JsonField(group, '${entry.key}', value));
    }
  }
  return fields;
}

bool _listRule(String group, String field) =>
    field == 'bookList' ||
    field == 'chapterList' ||
    jsonChainedFields[group] == field;

/// A declared field whose value is data rather than a rule (the frozen reads it
/// into a model field; the JSON adapter reads `imageStyle` through
/// `sourceImageStyle`, not as an extraction).
const _valueFields = <String>{
  'imageStyle',
  'checkKeyWord',
  'canReName',
  'downloadUrls',
};

bool _outsideVocabulary(_JsonField entry) =>
    !jsonRequiredFields[entry.group]!.contains(entry.field) &&
    jsonChainedFields[entry.group] != entry.field &&
    !jsonAcceptedFields.contains(entry.field);

List<String> _jsonUnreadableShapes(Map<String, dynamic> source) {
  final labels = <String>[];
  for (final entry in _declaredJsonFields(source)) {
    if (jsonIgnoredFields.contains(entry.field) ||
        jsonUnvalidatedFields.contains(entry.field)) {
      continue;
    }
    final label = '${entry.group}.${entry.field}';
    if (_valueFields.contains(entry.field)) {
      labels.add('$label: a value field, validated as an extraction');
      continue;
    }
    final RuleFieldText? parts;
    try {
      final extraction = RuleField.extractionText(entry.value);
      parts = extraction == null
          ? const RuleFieldText(null, <String>[])
          : RuleFieldText(extraction, const <String>[]);
    } on Object {
      labels.add('$label: ${_splitShape(entry.value)}');
      continue;
    }
    if (parts.extractionRule == null) continue;
    final extraction = parts.extractionRule!;
    try {
      JsonSourceRules.validate(extraction, forList: _listRule(
        entry.group,
        entry.field,
      ));
      continue;
    } on Object {
      labels.add('$label: ${_jsonRuleShape(extraction)}');
    }
  }
  return labels;
}

/// One JSON rule text's shape, classified by pattern only.
String _jsonRuleShape(String rule) {
  final text = rule.trim();
  final fields = splitRuleFields(rule);
  if (fields.rule.trim().isEmpty) return 'replacement-only text (##…), no path';
  if (text.startsWith('@get:') || text.startsWith('@put:') ||
      text.startsWith('{{')) {
    return 'rule-field token-only text (@get:/@put:/{{…}})';
  }
  if (text.startsWith(':')) return ':-prefixed all-in-one regex rule';
  if (text.startsWith('//')) return '//-leading rule';
  if (text.contains(r'{$.')) return r'{$...} inline rule (innerRule("{$."))';
  if (text.contains('</js>')) return 'segment after </js>';
  if (text.toLowerCase().startsWith('@css:') ||
      text.toLowerCase().startsWith('@xpath:') ||
      text.contains('@text') ||
      text.contains('@html') ||
      text.contains('@href') ||
      text.contains('@tag.') ||
      text.startsWith('class.') ||
      text.startsWith('id.') ||
      text.startsWith('tag.')) {
    return 'HTML/CSS rule shape on a JSON-piped record';
  }
  if (!text.startsWith(r'$') && !text.startsWith('.')) {
    return 'bare rule text (no \$./@ prefix)';
  }
  if (text.contains("['") || text.contains('["')) {
    return "quoted property name (['a'])";
  }
  if (text.contains('[::') || text.contains('[:]')) return 'slice spelling';
  if (text.contains('*') && RegExp(r'\[\s*\*').hasMatch(text)) {
    return 'bare * wildcard';
  }
  if (RegExp(r'===|!==').hasMatch(text)) return '=== / !== operator';
  if (RegExp(r'\b(contains|subsetof|anyof|noneof|type|all)\b').hasMatch(text)) {
    return 'spelled filter operator this adapter refuses';
  }
  if (text.contains('.length()') || text.contains('(')) {
    return 'function/arithmetic in a filter path';
  }
  return 'other bounded-JSONPath parse refusal';
}

/// The shape of a `header` rule a stage refuses, classified by pattern only.
String _headerShape(Map<String, dynamic> source) {
  final raw = source['header'];
  if (raw == null) return 'absent';
  if (raw is! String) return 'declared as ${raw.runtimeType}, not a string';
  final text = raw.trim();
  if (text.isEmpty) return 'empty';
  final lower = text.toLowerCase();
  if (lower.startsWith('@js:')) return '@js: rule';
  if (lower.startsWith('<js>')) {
    return text.lastIndexOf('<') <= 4
        ? '<js> with no closing marker'
        : '<js> rule';
  }
  if (!text.startsWith('{') && !text.startsWith('[')) {
    return 'bare text, not a JSON object at all';
  }
  final shapes = <String>[];
  if (text.contains("'")) shapes.add('single-quoted keys/values');
  if (RegExp(r'[{,]\s*[A-Za-z_][A-Za-z0-9_-]*\s*:').hasMatch(text)) {
    shapes.add('unquoted names');
  }
  if (RegExp(r',\s*[}\]]').hasMatch(text)) shapes.add('trailing comma');
  try {
    final parsed = jsonDecode(text);
    if (parsed is Map) {
      if (parsed.values.any((value) => value is! String)) {
        return 'JSON object with a non-string value';
      }
      if (parsed.keys.any((key) => '$key'.toLowerCase() == 'proxy')) {
        return 'JSON object declaring proxy';
      }
      return 'plain strict-JSON object (accepted)';
    }
    return 'JSON, not an object';
  } on FormatException {
    return 'Gson-style object strict JSON refuses'
        '${shapes.isEmpty ? '' : ' (${shapes.join(', ')})'}';
  }
}
