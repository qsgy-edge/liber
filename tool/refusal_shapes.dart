// Shape probe for the readiness audit's refusal classes (#82, batch 17).
//
// The audit (`tool/source_readiness.dart`) answers *which* rule reads refused a
// record and how many records meet each reason. It does not answer *what shape*
// each refusal saw, which is what a triage needs before a reason becomes a
// ticket. This mode replays the same reads over one backup (or bare export) and
// prints, per refused record of the used set, the shape label of every field
// the reason's read rejected.
//
// `--content-replace <backup.zip|bookSource.json>` is the deeper probe of the
// class #106 retired: `html-content-replace-rule`, the two forms the content
// stage refused before that ticket — a `{{…}}` expression beyond
// `{{chapter.title}}` on the replacement, and a replacement beside a `##` field
// on the content rule. The product reads both now (the frozen corpus that
// decides them is `tool/html_content_oracle/replace_fixtures.json`), so the
// class left the `ReadinessCheck` list and this mode is where its measurement
// stays reproducible. As in the audit it prints the used set's counts and the
// shape label of every field the retired predicate named: never a rule text,
// URL, host, header value or source name.
//
// Like the audit it is static and network-free (no request, no script, no
// native library), it reuses the audit's own public constants and predicates so
// the two cannot drift, and it prints no rule text, URL, host or source name:
// every label is derived from the field's *shape* by pattern, never by quoting
// it. The position in `bookSource.json` is the only identity it prints, which is
// the audit's own convention.
//
// `--script-surface <backup.zip|bookSource.json>` is the deeper probe of the two
// script classes (#98): an element-list rule carrying a script and a per-element
// value rule that is a script only — the *script element family* #11 deferred
// and #100 implemented with the surface this probe measured. The measured
// classes are named by the `ReadinessCheck`s #100 retired
// (`html-list-rule-script`, `html-script-only-element-field`). The
// frozen hands such a script the current analysis value and reads its JavaScript
// result (`AnalyzeRule.getElement(s)`/`getString` on `Mode.Js`,
// AnalyzeRule.kt:363, 265) — the list script gets the response *body* string
// (`BookList.kt:50` `setContent(body)`), and a per-element field script gets
// whatever the element-list rule produced (`BookList.kt:208`
// `setContent(item)`), a jsoup `Element` only when that rule was a selector.
// This mode measures which Jsoup/DOM calls the scripts of the operator's own
// library actually reach, and what shape each hands back; #98's numbers sized
// the façade #100 implemented. It reuses the audit's own classification
// (`htmlRuleSlots`, `HtmlRuleRead`, `auditSource`, `parseRuleField`), so its two
// classes are exactly the fields the family names, and it prints counts, call
// names and shapes only: never a rule text, URL, host, header value or source
// name. It is a reading of the script's call tokens, not an evaluation (see
// `scriptSurfaceGaps`).
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/rule_field.dart';
import 'package:liber/source/book_source_pipeline.dart';

import 'source_readiness.dart';
import 'source_usage.dart';

void main(List<String> args) {
  if (args.length == 2 && args.first == '--script-surface') {
    stdout.write(renderScriptSurfaceReport(readScriptSurfaceReport(args[1])));
    return;
  }
  if (args.length == 2 && args.first == '--content-replace') {
    stdout.write(renderContentReplaceReport(readContentReplaceReport(args[1])));
    return;
  }
  if (args.length != 1) {
    stderr.writeln('usage: dart run tool/refusal_shapes.dart <backup.zip|'
        'bookSource.json>\n'
        '       dart run tool/refusal_shapes.dart --script-surface '
        '<backup.zip|bookSource.json>\n'
        '       dart run tool/refusal_shapes.dart --content-replace '
        '<backup.zip|bookSource.json>');
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
    case 'html-rule-field-syntax':
      return _slotShapes(source, null);
    case 'html-missing-required-field':
      return <String>[
        for (final slot in htmlRuleSlots)
          if (slot.required && _text(source, slot.group, slot.field) == null)
            '${slot.group}.${slot.field} absent/blank',
      ];
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

/// The `html-content-replace-rule` class #106 retired, measured over one backup.
///
/// The predicate is the one `tool/source_readiness.dart` carried until that
/// ticket (`_htmlContentReplaceRefused`): a `{{…}}` expression beyond the
/// chapter-title one, or a replacement beside a `##` field on the content rule.
/// The product reads both forms now, so the class is not a `ReadinessCheck` —
/// as #100's two script classes are not — and this mode is where a later reader
/// can still see what it named.
class ContentReplaceReport {
  const ContentReplaceReport({required this.backup, required this.records});

  final SourceBackup backup;

  /// One entry per used record the retired predicate named, in `bookSource.json`
  /// order, with the shape labels of the fields it named.
  final List<({int position, List<String> labels})> records;

  List<String> get backupLines => sourceBackupLines(backup);
}

/// Reads [path] and measures the retired class over the used set.
ContentReplaceReport readContentReplaceReport(String path) {
  final backup = readSourceBackup(path);
  final origins = backup.shelf == null ? null : shelfOrigins(backup.shelf!);
  final records = <({int position, List<String> labels})>[];
  for (var index = 0; index < backup.sources.length; index++) {
    final source = backup.sources[index];
    if (origins != null && !origins.contains(source['bookSourceUrl'])) continue;
    // The retired check was declared `pipeline: SourcePipeline.html`, so a
    // record the JSON adapter reads never named it.
    if (isJsonRuleSource(source)) continue;
    if (!_contentReplaceRefused(source)) continue;
    records.add((position: index, labels: _contentReplaceShapes(source)));
  }
  return ContentReplaceReport(backup: backup, records: records);
}

/// The retired `_htmlContentReplaceRefused`, character for character.
bool _contentReplaceRefused(Map<String, dynamic> source) {
  final content = _text(source, 'ruleContent', 'content');
  if (content == null) return false;
  final replacement = (_text(source, 'ruleContent', 'replaceRegex') ?? '')
      .replaceAll('{{chapter.title}}', '');
  if (replacement.contains('{{')) return true;
  return replacement.isNotEmpty && content.contains('##');
}

String renderContentReplaceReport(ContentReplaceReport report) {
  final out = <String>[
    'content-replace shapes — the `html-content-replace-rule` class #106 '
        'retired; network-free, no rule text, URL, host or source name is read '
        'out',
    ...report.backupLines,
    'used records that named it: ${report.records.length}',
    '',
  ];
  for (final record in report.records) {
    out.add(
      '  [${record.position}] '
      '${record.labels.isEmpty ? 'no shape read' : record.labels.join('; ')}',
    );
  }
  out.add('');
  return '${out.join('\n')}\n';
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

// ── the script element family's surface (#98) ───────────────────────────────
//
// The two classes #11 deferred are measured here from the operator's own
// library: `html-list-rule-script` (an element-list rule carries a script) and
// `html-script-only-element-field` (a per-element value rule is a script only).
// The classes are exactly the records `auditSource` names, so this probe cannot
// drift from the audit's counts.

/// The two classes the script element family is (#98): the element-list rule
/// carrying a script, and a per-element value rule that is a script only.
enum ScriptRuleClass { elementList, elementField }

/// The shape of the value one script hands back, as [readScriptField] reads it
/// from the script's own call tokens and its tail expression.
///
/// A reading, not an evaluation: a branch that differs at runtime, a field
/// whose value comes from several script segments, or a value whose kind no
/// token shows is reported [mixed].
enum ScriptShape { elements, string, transforming, mixed }

/// What a recognized Jsoup/DOM call does with a node.
enum DomCallKind { select, read, parse, bridge, mutate }

/// The Jsoup `Document`/`Element` call names this probe counts — the surface a
/// façade over nodes would have to carry (#98), as the brief names it (`select`,
/// `text`, `attr`, `html`, `ownText`, `children`, `parent`,
/// `nextElementSibling`, `getElementsBy…`). A name counts only where it is a
/// call (`name(`); a field or a JSON key of the same spelling is not a hit, and
/// a comment or a string body is not read ([_scriptCode]). `attr`, `text`,
/// `html` and `data` are counted by name, whether the script reads or writes.
const Map<String, DomCallKind> jsoupDomCalls = <String, DomCallKind>{
  // Selection and navigation: a new node set.
  'select': DomCallKind.select,
  'selectFirst': DomCallKind.select,
  'selectXpath': DomCallKind.select,
  'getElementById': DomCallKind.select,
  'getElementsByTag': DomCallKind.select,
  'getElementsByClass': DomCallKind.select,
  'getElementsByAttribute': DomCallKind.select,
  'getElementsByAttributeValue': DomCallKind.select,
  'getElementsByAttributeStarting': DomCallKind.select,
  'getElementsContainingText': DomCallKind.select,
  'getElementsMatchingText': DomCallKind.select,
  'getAllElements': DomCallKind.select,
  'children': DomCallKind.select,
  'child': DomCallKind.select,
  'parent': DomCallKind.select,
  'parents': DomCallKind.select,
  'root': DomCallKind.select,
  'nextElementSibling': DomCallKind.select,
  'previousElementSibling': DomCallKind.select,
  'firstElementSibling': DomCallKind.select,
  'lastElementSibling': DomCallKind.select,
  'siblingElements': DomCallKind.select,
  'nextSibling': DomCallKind.select,
  'previousSibling': DomCallKind.select,
  'childNodes': DomCallKind.select,
  'textNodes': DomCallKind.select,
  // Reads: a string/scalar off a node.
  'text': DomCallKind.read,
  'ownText': DomCallKind.read,
  'wholeText': DomCallKind.read,
  'html': DomCallKind.read,
  'outerHtml': DomCallKind.read,
  'val': DomCallKind.read,
  'data': DomCallKind.read,
  'id': DomCallKind.read,
  'className': DomCallKind.read,
  'classNames': DomCallKind.read,
  'tagName': DomCallKind.read,
  'tag': DomCallKind.read,
  'attributes': DomCallKind.read,
  'dataset': DomCallKind.read,
  'baseUri': DomCallKind.read,
  'absUrl': DomCallKind.read,
  'attr': DomCallKind.read,
  'hasAttr': DomCallKind.read,
  'hasClass': DomCallKind.read,
  'nodeName': DomCallKind.read,
  'elementSiblingIndex': DomCallKind.read,
  'childrenSize': DomCallKind.read,
  'title': DomCallKind.read,
  // Mutators: write to a node and answer the node.
  'append': DomCallKind.mutate,
  'prepend': DomCallKind.mutate,
  'before': DomCallKind.mutate,
  'after': DomCallKind.mutate,
  'wrap': DomCallKind.mutate,
  'unwrap': DomCallKind.mutate,
  'remove': DomCallKind.mutate,
  'empty': DomCallKind.mutate,
  'replaceWith': DomCallKind.mutate,
  'addClass': DomCallKind.mutate,
  'removeClass': DomCallKind.mutate,
  'toggleClass': DomCallKind.mutate,
  'removeAttr': DomCallKind.mutate,
};

/// The JS/JSON/Java-bridge calls counted as producing a string: the
/// [ScriptShape.string] signal. A call named in none of the three sets is not a
/// signal.
const Set<String> scriptStringCalls = <String>{
  'String',
  'match',
  'replace',
  'replaceAll',
  'split',
  'join',
  'trim',
  'substring',
  'substr',
  'indexOf',
  'lastIndexOf',
  'includes',
  'startsWith',
  'endsWith',
  'test',
  'toString',
  'charAt',
  'toLowerCase',
  'toUpperCase',
  'padStart',
  'padEnd',
  'decodeURIComponent',
  'encodeURIComponent',
  'encodeURI',
  'decodeURI',
  'parseInt',
  'parseFloat',
  'Number',
  'Boolean',
  'toFixed',
  'hexDecodeToString',
  'base64Decode',
  'base64Encode',
  'timeFormat',
  'md5Encode',
  'getString',
  'getStringList',
  'stringify',
};

/// The calls counted as building or walking an array: the
/// [ScriptShape.transforming] signal. `slice` answers a string or an array by
/// receiver and `parse` is a JSON path here, so both are counted here and the
/// reading is noted in [scriptSurfaceGaps].
const Set<String> scriptCollectionCalls = <String>{
  'map',
  'filter',
  'concat',
  'reduce',
  'reduceRight',
  'forEach',
  'push',
  'unshift',
  'pop',
  'shift',
  'splice',
  'slice',
  'sort',
  'reverse',
  'flat',
  'flatMap',
  'parse',
};

/// The value kind a recognized call or tail carries. Private: the report speaks
/// in [ScriptShape] names.
enum _ScriptValue { node, string, collection }

/// One recognized call in a script, with what it does and where it sits.
class _ScriptCall {
  const _ScriptCall(
    this.name,
    this.kind,
    this.value,
    this.receiver,
    this.depth,
  );

  final String name;
  final DomCallKind? kind;
  final _ScriptValue value;
  final String receiver;

  /// How many `(` enclose the call: a call inside a callback sits deeper than
  /// the call it is passed to.
  final int depth;
}

/// The calls and the value shape one script field reaches.
class ScriptFieldReading {
  const ScriptFieldReading({
    required this.shape,
    required this.bindsElement,
    required this.calls,
  });

  /// The shape of the field's value, read from the last script segment's tail.
  final ScriptShape shape;

  /// Whether the script uses the value it is handed as a node: a call on
  /// `result`/`src`, or the `java.getElement(s)` bridge. The frozen hands the
  /// element-list script the response body string and a per-element field
  /// script the element-list rule's own result (`BookList.kt:50, 208`), so this
  /// is the one input fact a static read settles per script.
  final bool bindsElement;

  /// The recognized Jsoup/DOM call names, deduplicated, in first-seen order.
  final List<String> calls;
}

/// One script field of the element family, measured.
class ScriptFieldMeasurement {
  const ScriptFieldMeasurement({
    required this.position,
    required this.ruleClass,
    required this.field,
    required this.reading,
    required this.segments,
  });

  /// The record's position in `bookSource.json` (the audit's only identity).
  final int position;

  final ScriptRuleClass ruleClass;

  /// The field name (`ruleSearch.bookList`), never its rule text.
  final String field;

  final ScriptFieldReading reading;

  /// How many `@js:`/`<js>` segments the field carries.
  final int segments;
}

/// Reads one field's script segments: the DOM calls it reaches, whether it uses
/// the bound value as a node, and the shape of the last segment's value.
ScriptFieldReading readScriptField(List<String> segments) {
  final calls = <String>[];
  var bindsElement = false;
  var shape = ScriptShape.mixed;
  for (var index = 0; index < segments.length; index++) {
    final code = _scriptCode(segments[index]);
    final recognized = _scriptCalls(code);
    for (final call in recognized) {
      if (call.kind == null) continue;
      if (!calls.contains(call.name)) calls.add(call.name);
      if (call.kind == DomCallKind.bridge ||
          ((call.receiver == 'result' || call.receiver == 'src') &&
              call.kind != DomCallKind.parse)) {
        bindsElement = true;
      }
    }
    if (index == segments.length - 1) shape = _valueShapeOf(code, recognized);
  }
  return ScriptFieldReading(
    shape: shape,
    bindsElement: bindsElement,
    calls: calls,
  );
}

/// Measures every script field of the two element-family classes [source]
/// declares, over the HTML pipeline only (the pipeline `auditSource` selects),
/// in [htmlRuleSlots] order. A field the audit refuses for another reason
/// (a split refusal) carries no reading here.
List<ScriptFieldMeasurement> measureHtmlScriptFields(
  Map<String, dynamic> source, {
  int position = 0,
}) {
  if (auditSource(source).pipeline != SourcePipeline.html) {
    return const <ScriptFieldMeasurement>[];
  }
  final measurements = <ScriptFieldMeasurement>[];
  for (final slot in htmlRuleSlots) {
    final text = _text(source, slot.group, slot.field);
    if (text == null) continue;
    final parts = parseOrNull(text);
    if (parts == null || parts.scripts.isEmpty) continue;
    final ScriptRuleClass ruleClass;
    if (slot.read == HtmlRuleRead.elementList) {
      ruleClass = ScriptRuleClass.elementList;
    } else if (slot.read == HtmlRuleRead.elementValue &&
        parts.extractionRule == null) {
      ruleClass = ScriptRuleClass.elementField;
    } else {
      continue;
    }
    measurements.add(
      ScriptFieldMeasurement(
        position: position,
        ruleClass: ruleClass,
        field: '${slot.group}.${slot.field}',
        reading: readScriptField(parts.scripts),
        segments: parts.scripts.length,
      ),
    );
  }
  return measurements;
}

/// One recognized Jsoup/DOM call's counts over one set: how many records reach
/// it and how many call sites they carry.
class ScriptCallCount {
  const ScriptCallCount({
    required this.name,
    required this.usedSources,
    required this.usedCalls,
    required this.collectionSources,
    required this.collectionCalls,
  });

  final String name;
  final int usedSources;
  final int usedCalls;
  final int collectionSources;
  final int collectionCalls;
}

/// One class's table: its counts, its value shapes and its call surface.
class ScriptFamilyTable {
  const ScriptFamilyTable({
    required this.ruleClass,
    required this.usedSources,
    required this.collectionSources,
    required this.usedFields,
    required this.collectionFields,
    required this.usedBindsElement,
    required this.collectionBindsElement,
    required this.calls,
  });

  final ScriptRuleClass ruleClass;

  /// How many used / collection records declare a field of this class.
  final int usedSources;
  final int collectionSources;

  final List<ScriptFieldMeasurement> usedFields;
  final List<ScriptFieldMeasurement> collectionFields;

  /// Script fields (used / collection) whose script uses the bound value as a
  /// node.
  final int usedBindsElement;
  final int collectionBindsElement;

  /// The call surface, ordered by used records, then by used calls, then name.
  final List<ScriptCallCount> calls;

  int usedRecordsOf(ScriptShape shape) => _distinctPositions(
    usedFields.where((field) => field.reading.shape == shape),
  );

  int collectionRecordsOf(ScriptShape shape) => _distinctPositions(
    collectionFields.where((field) => field.reading.shape == shape),
  );

  int usedFieldsOf(ScriptShape shape) =>
      usedFields.where((field) => field.reading.shape == shape).length;

  int collectionFieldsOf(ScriptShape shape) =>
      collectionFields.where((field) => field.reading.shape == shape).length;
}

/// Everything the script-surface report needs.
class ScriptSurfaceReport {
  const ScriptSurfaceReport({
    required this.backup,
    required this.usedCount,
    required this.tables,
  });

  final SourceBackup backup;

  /// How many records the used set resolved to.
  final int usedCount;

  final List<ScriptFamilyTable> tables;

  ScriptFamilyTable table(ScriptRuleClass ruleClass) =>
      tables.firstWhere((table) => table.ruleClass == ruleClass);

  List<String> get backupLines => sourceBackupLines(backup);
}

/// Reads [path] and measures both script element classes over the used set and
/// the whole collection.
ScriptSurfaceReport readScriptSurfaceReport(String path) {
  final backup = readSourceBackup(path);
  final origins = backup.shelf == null ? null : shelfOrigins(backup.shelf!);
  final used = backup.shelf == null
      ? null
      : resolveUsedSources(backup.sources, backup.shelf!);
  final collectionFields = _measure(backup.sources, include: (_) => true);
  final usedFields = origins == null
      ? const <ScriptFieldMeasurement>[]
      : _measure(
          backup.sources,
          include: (index) =>
              origins.contains(backup.sources[index]['bookSourceUrl']),
        );
  return ScriptSurfaceReport(
    backup: backup,
    usedCount: used?.length ?? 0,
    tables: <ScriptFamilyTable>[
      for (final ruleClass in ScriptRuleClass.values)
        _table(
          ruleClass,
          usedFields: usedFields
              .where((field) => field.ruleClass == ruleClass)
              .toList(growable: false),
          collectionFields: collectionFields
              .where((field) => field.ruleClass == ruleClass)
              .toList(growable: false),
        ),
    ],
  );
}

/// What the measurement cannot decide, reported verbatim beside the counts.
const scriptSurfaceGaps = <String>[
  'a script is read, not evaluated: a branch that returns the bound value in '
      'one path and a string or collection in another is reported `mixed`, the '
      'runtime type the probe cannot see',
  'a field whose value comes from several `@js:`/`<js>` segments is classified '
      'by its last segment; a segment that passes its input through inherits no '
      'type, so a field whose segments disagree is `mixed`',
  'a call is counted by name only: a local binding, a field or a JSON key with '
      'a Jsoup method spelling is not told from a call, and `slice` and `parse` '
      'answer a string or an array by receiver',
  '`attr`, `text`, `html` and `data` are counted once wherever the call '
      'appears, whether the script reads or writes, so a count is a call-site '
      'reading, not a resolved receiver',
  "the received value's runtime type is not visible: the frozen hands the "
      'element-list script the response body string, and a per-element field '
      "script the element-list rule's own result (`BookList.kt:50, 208`), a "
      'jsoup `Element` only when that rule was a selector — the probe reports '
      'which scripts call a node method on `result`/`src`, not what it is',
  'the probe reads `result`/`src` as the bound value name; an alias such as '
      '`\$ = result` is not followed, so a call through the alias is not counted',
];

/// The report as text: counts, call names and shapes, and the gap list.
String renderScriptSurfaceReport(ScriptSurfaceReport report) {
  final lines = <String>[
    'script element family — the two #11 refusal classes measured; '
        'network-free, counts, call names and shapes only: no rule text, URL, '
        'host, header value or source name is read out',
    ...report.backupLines,
    'used: ${report.usedCount}',
    '',
  ];
  for (final table in report.tables) {
    lines.add('[${_className(table.ruleClass)}]');
    lines.add(
      '  used ${table.usedSources}/${report.usedCount}   '
      'collection ${table.collectionSources}/${report.backup.sources.length}   '
      'script fields used ${table.usedFields.length}, '
      'collection ${table.collectionFields.length}',
    );
    lines.add(
      '  bound value used as a node: '
      'used ${table.usedBindsElement}/${table.usedFields.length} fields   '
      'collection ${table.collectionBindsElement}/'
      '${table.collectionFields.length} fields',
    );
    lines.add(
      '  value shape (a record with two class fields is counted once per '
      'field; the record counts overlap where they differ):',
    );
    for (final shape in ScriptShape.values) {
      lines.add(
        '    ${_shapeName(shape).padRight(13)}'
        'used ${table.usedRecordsOf(shape)}/${report.usedCount} records, '
        '${table.usedFieldsOf(shape)} fields   '
        'collection ${table.collectionRecordsOf(shape)}/'
        '${report.backup.sources.length} records, '
        '${table.collectionFieldsOf(shape)} fields',
      );
    }
    lines.add(
      '  Jsoup/DOM calls (a used record, its call sites, the collection):',
    );
    if (table.calls.isEmpty) lines.add('    (none)');
    final width = table.calls.fold<int>(
      0,
      (value, call) => call.name.length > value ? call.name.length : value,
    );
    for (final call in table.calls) {
      lines.add(
        '    ${call.name.padRight(width + 2)}'
        'used ${call.usedSources}/${report.usedCount} records, '
        '${call.usedCalls} calls   '
        'collection ${call.collectionSources}/'
        '${report.backup.sources.length} records, ${call.collectionCalls} calls',
      );
    }
    lines.add('  scripts over the used set:');
    for (final field in table.usedFields) {
      final reading = field.reading;
      lines.add(
        '    [${field.position}] ${field.field}: '
        '${_shapeName(reading.shape)}'
        '${reading.bindsElement ? ' (node bound)' : ''}'
        '${reading.calls.isEmpty ? ' — no DOM call' : ' — ${reading.calls.join(', ')}'}',
      );
    }
    lines.add('');
  }
  lines.add('what this measurement cannot decide:');
  for (final gap in scriptSurfaceGaps) {
    lines.add('  - $gap');
  }
  return '${lines.join('\n')}\n';
}

List<ScriptFieldMeasurement> _measure(
  List<Map<String, dynamic>> sources, {
  required bool Function(int index) include,
}) =>
    <ScriptFieldMeasurement>[
      for (var index = 0; index < sources.length; index++)
        if (include(index))
          ...measureHtmlScriptFields(sources[index], position: index),
    ];

ScriptFamilyTable _table(
  ScriptRuleClass ruleClass, {
  required List<ScriptFieldMeasurement> usedFields,
  required List<ScriptFieldMeasurement> collectionFields,
}) {
  final used = _callCounts(usedFields);
  final collection = _callCounts(collectionFields);
  final names =
      <String>{...used.sources.keys, ...collection.sources.keys}.toList()
        ..sort((a, b) {
          final byUsed = (used.sources[b] ?? 0).compareTo(used.sources[a] ?? 0);
          if (byUsed != 0) return byUsed;
          final byCalls = (used.calls[b] ?? 0).compareTo(used.calls[a] ?? 0);
          if (byCalls != 0) return byCalls;
          return a.compareTo(b);
        });
  return ScriptFamilyTable(
    ruleClass: ruleClass,
    usedSources: _distinctPositions(usedFields),
    collectionSources: _distinctPositions(collectionFields),
    usedFields: usedFields,
    collectionFields: collectionFields,
    usedBindsElement: usedFields
        .where((field) => field.reading.bindsElement)
        .length,
    collectionBindsElement: collectionFields
        .where((field) => field.reading.bindsElement)
        .length,
    calls: <ScriptCallCount>[
      for (final name in names)
        ScriptCallCount(
          name: name,
          usedSources: used.sources[name] ?? 0,
          usedCalls: used.calls[name] ?? 0,
          collectionSources: collection.sources[name] ?? 0,
          collectionCalls: collection.calls[name] ?? 0,
        ),
    ],
  );
}

({Map<String, int> sources, Map<String, int> calls}) _callCounts(
  List<ScriptFieldMeasurement> fields,
) {
  final sources = <String, Set<int>>{};
  final calls = <String, int>{};
  for (final field in fields) {
    for (final name in field.reading.calls) {
      calls[name] = (calls[name] ?? 0) + 1;
      sources.putIfAbsent(name, () => <int>{}).add(field.position);
    }
  }
  return (
    sources: <String, int>{
      for (final entry in sources.entries) entry.key: entry.value.length,
    },
    calls: calls,
  );
}

int _distinctPositions(Iterable<ScriptFieldMeasurement> fields) =>
    fields.map((field) => field.position).toSet().length;

String _className(ScriptRuleClass ruleClass) => switch (ruleClass) {
  ScriptRuleClass.elementList =>
    'element-list rule: `ruleSearch.bookList` / `ruleToc.chapterList` '
        'carries a script',
  ScriptRuleClass.elementField =>
    'per-element field: a `ruleSearch`/`ruleToc` value rule is a script only',
};

String _shapeName(ScriptShape shape) => switch (shape) {
  ScriptShape.elements => 'elements',
  ScriptShape.string => 'string',
  ScriptShape.transforming => 'transforming',
  ScriptShape.mixed => 'mixed',
};

final RegExp _callPattern = RegExp(
  r'(?:([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)\s*\.\s*)?'
  r'([A-Za-z_$][\w$]*)\s*\(',
);

final RegExp _identifier = RegExp(r'^[A-Za-z_$][\w$]*$');

/// Every recognized call in [code], in call order.
List<_ScriptCall> _scriptCalls(String code) {
  final calls = <_ScriptCall>[];
  for (final match in _callPattern.allMatches(code)) {
    final receiver = match.group(1) ?? '';
    final name = match.group(2)!;
    final depth = _parenDepth(code, match.start);
    if (name == 'parse' && receiver.toLowerCase().endsWith('jsoup')) {
      calls.add(
        _ScriptCall(
          'Jsoup.parse',
          DomCallKind.parse,
          _ScriptValue.node,
          receiver,
          depth,
        ),
      );
      continue;
    }
    if ((name == 'getElement' || name == 'getElements') && receiver == 'java') {
      calls.add(
        _ScriptCall(
          'java.$name',
          DomCallKind.bridge,
          _ScriptValue.node,
          receiver,
          depth,
        ),
      );
      continue;
    }
    final jsoup = jsoupDomCalls[name];
    if (jsoup != null) {
      calls.add(
        _ScriptCall(
          name,
          jsoup,
          jsoup == DomCallKind.read ? _ScriptValue.string : _ScriptValue.node,
          receiver,
          depth,
        ),
      );
      continue;
    }
    if (scriptStringCalls.contains(name)) {
      calls.add(_ScriptCall(name, null, _ScriptValue.string, receiver, depth));
      continue;
    }
    if (scriptCollectionCalls.contains(name)) {
      calls.add(
        _ScriptCall(name, null, _ScriptValue.collection, receiver, depth),
      );
    }
  }
  return calls;
}

/// The shape of one script segment's value: its tail expression's kind, with a
/// bare identifier resolved through its last assignment.
ScriptShape _valueShapeOf(String code, List<_ScriptCall> calls) {
  final tail = _tailExpression(code);
  if (_identifier.hasMatch(tail)) {
    final values = <_ScriptValue>{};
    final assignment = RegExp(
      '\\b${RegExp.escape(tail)}\\s*=(?!=)\\s*([^;\\n]*)',
    );
    for (final match in assignment.allMatches(code)) {
      final value = _expressionValue(match.group(1)!);
      if (value != null) values.add(value);
    }
    if (values.length == 1) return _shapeOfValue(values.first);
    if (values.length > 1) return ScriptShape.mixed;
    if ((tail == 'result' || tail == 'src') &&
        !RegExp(r'\b(result|src)\s*=(?!=)').hasMatch(code)) {
      return ScriptShape.elements;
    }
  }
  final dominant = _dominant(calls);
  if (dominant != null) return _shapeOfValue(dominant.value);
  if (_passesThrough(code, tail)) return ScriptShape.elements;
  // No recognized call: the script computes a scalar (a literal, a comparison,
  // an index or a property read), which is read as a string.
  return ScriptShape.string;
}

/// Whether the script hands the bound value back unchanged: an assignment from
/// it, when nothing reassigns it.
bool _passesThrough(String code, String tail) {
  if (RegExp(r'\b(result|src)\s*=(?!=)').hasMatch(code)) return false;
  if (_identifier.hasMatch(tail) && (tail == 'result' || tail == 'src')) {
    return true;
  }
  return RegExp(r'=\s*(result|src)\s*(?:[;\n}]|$)').hasMatch(code);
}

/// The value kind of one assignment's right-hand side, or null when no token
/// shows it.
_ScriptValue? _expressionValue(String rhs) {
  final text = rhs.trim();
  if (text == 'result' || text == 'src') return _ScriptValue.node;
  if (text.startsWith('[') ||
      text.startsWith('Array(') ||
      text.startsWith('new Array')) {
    return _ScriptValue.collection;
  }
  final dominant = _dominant(_scriptCalls(_scriptCode(text)));
  if (dominant != null) return dominant.value;
  if (text.startsWith('`') || text.startsWith('"') || text.startsWith("'")) {
    return _ScriptValue.string;
  }
  return null;
}

/// The call that produces a chain's value: the one with the fewest enclosing
/// parentheses, and the last of those.
_ScriptCall? _dominant(List<_ScriptCall> calls) {
  if (calls.isEmpty) return null;
  var minimum = calls.first.depth;
  for (final call in calls) {
    if (call.depth < minimum) minimum = call.depth;
  }
  _ScriptCall? chosen;
  for (final call in calls) {
    if (call.depth == minimum) chosen = call;
  }
  return chosen;
}

ScriptShape _shapeOfValue(_ScriptValue value) => switch (value) {
  _ScriptValue.node => ScriptShape.elements,
  _ScriptValue.string => ScriptShape.string,
  _ScriptValue.collection => ScriptShape.transforming,
};

/// The script's last non-blank line, with trailing semicolons removed.
String _tailExpression(String code) {
  final lines = code
      .split('\n')
      .map((line) => line.trim())
      .where((line) => line.isNotEmpty)
      .toList(growable: false);
  if (lines.isEmpty) return '';
  var tail = lines.last;
  while (tail.endsWith(';')) {
    tail = tail.substring(0, tail.length - 1).trimRight();
  }
  return tail;
}

/// The script with comments and string bodies blanked, so a call name is read
/// from code only. A template literal's `${…}` expression is kept.
String _scriptCode(String text) {
  final out = StringBuffer();
  var index = 0;
  while (index < text.length) {
    final char = text[index];
    if (char == '/' && index + 1 < text.length) {
      final next = text[index + 1];
      if (next == '/') {
        index += 2;
        while (index < text.length && text[index] != '\n') {
          index++;
        }
        continue;
      }
      if (next == '*') {
        index += 2;
        while (index + 1 < text.length &&
            !(text[index] == '*' && text[index + 1] == '/')) {
          index++;
        }
        index = index + 1 < text.length ? index + 2 : text.length;
        continue;
      }
    }
    if (char == '"' || char == "'" || char == '`') {
      index++;
      while (index < text.length) {
        final inner = text[index];
        if (inner == '\\') {
          index += 2;
          continue;
        }
        if (inner == char) {
          index++;
          break;
        }
        if (char == '`' &&
            inner == r'$' &&
            index + 1 < text.length &&
            text[index + 1] == '{') {
          index += 2;
          var depth = 1;
          while (index < text.length && depth > 0) {
            final part = text[index];
            if (part == '{') depth++;
            if (part == '}') depth--;
            if (depth > 0) out.write(part);
            index++;
          }
          continue;
        }
        index++;
      }
      out.write(' ');
      continue;
    }
    out.write(char);
    index++;
  }
  return out.toString();
}

int _parenDepth(String code, int end) {
  var depth = 0;
  for (var index = 0; index < end && index < code.length; index++) {
    final unit = code.codeUnitAt(index);
    if (unit == 0x28) {
      depth++;
    } else if (unit == 0x29 && depth > 0) {
      depth--;
    }
  }
  return depth;
}
