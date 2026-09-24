// Static readiness audit: does this product's own rule reading accept each of
// the operator's book sources, or refuse it — and by what name?
//
// The trial of the real library found its refusals one book at a time (#80, #81):
// each is a validation in this tree stricter than the frozen app, so a source is
// refused before it is read. This mode measures the whole library once, so the
// refusals become a list instead of the next click.
//
// What it does: for one Legado backup (or bare export), it selects the pipeline
// the product would run the record with and replays the *rule reads* that
// pipeline's stages perform — the required fields per stage, the rule-group
// shapes, the shared rule-field split, the JSON adapter's per-group validation
// and its declared-field vocabulary. Every read it can is the product's own call
// (`isJsonRuleSource`, `RuleField.extractionText`/`parseRuleField`,
// `JsonSourceRules.validate`, `splitSourceUrlOptions`, `SourceHttpUri.parse`);
// a rule the product keeps private is restated under its call site in the
// reason's own entry, which is the one place the two can drift apart.
//
// What it does not do: no request, no transport, no script runtime and no
// native library — this mode initialises no `fjs` and reads no page. It sends
// nothing, so a page's own content (an extracted address, an empty TOC, a login
// wall) is not an answer here; and a value the JavaScript runtime produces (a
// `@js:`/`<js>` header rule, a `loginCheckJs`, a `{{…}}` address expression) is
// not read. The gap list the report prints says which.
//
// It reports counts only: the ready/refused split over the used set and the
// whole collection, and per refusal reason the count and one example. It never
// prints a rule body, a URL, a host, a source name or any other record content.
// The one example per reason is the record's *position* in `bookSource.json`,
// not an identity: the origin name the brief allows (`bookSourceUrl`) is itself a
// URL, which the leak rule forbids, and a position leaks nothing.
import 'dart:convert';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/json_source_rules.dart';
import 'package:liber/source/rule_field.dart';
import 'package:liber/source/source_http_uri.dart';
import 'package:liber/source/source_url_rules.dart';

import 'source_usage.dart';

/// The pipeline a record's rules select, as `isJsonRuleSource` answers.
enum SourcePipeline { html, json }

/// One validation this product performs on a record's declared rules as it
/// reads a stage, as this audit names it.
///
/// [id] is the report's name for the reason and carries no rule text. [reads]
/// says what the product refuses; [productCode] names the call site, so a
/// reader can keep the restated rule in step with it. [pipeline] is the pipeline
/// the read belongs to, or null when both read it. [refuses] answers whether one
/// record meets the refusal, and never throws: a product validator that refuses
/// a rule does it by throwing.
class ReadinessCheck {
  const ReadinessCheck({
    required this.id,
    required this.reads,
    required this.productCode,
    required this.refuses,
    this.pipeline,
  });

  final String id;
  final String reads;
  final String productCode;
  final SourcePipeline? pipeline;
  final bool Function(Map<String, dynamic> source) refuses;
}

/// Every rule read this audit replays, in the order the product's stages reach
/// them: the record's address, its header rule, the search stage's fields, then
/// the details, TOC and content stages.
///
/// A record is counted under every reason it meets, not only under the first
/// refusal the product would raise, because one ticket per reason is what the
/// audit is for.
final List<ReadinessCheck> readinessChecks = <ReadinessCheck>[
  ReadinessCheck(
    id: 'source-url',
    reads:
        'the record declares no string `bookSourceUrl`, or it is not an '
        'http(s) address with a host and no user info',
    productCode:
        'SourceHttpUri.parse and HtmlSourcePipeline._resolve '
        '(lib/source/html_source_pipeline.dart:601-609), JsonSourcePipeline'
        '._base/_url (lib/source/json_source_pipeline.dart:70,575-586)',
    refuses: _sourceUrlRefused,
  ),
  ReadinessCheck(
    id: 'search-url',
    reads: 'the record declares no `searchUrl` string to search with',
    productCode:
        "the stage's own read of `source['searchUrl'] as String`: "
        'HtmlSourcePipeline.search (lib/source/html_source_pipeline.dart:713) '
        'and JsonSourcePipeline.search '
        '(lib/source/json_source_pipeline.dart:601)',
    refuses: _searchUrlRefused,
  ),
  ReadinessCheck(
    id: 'header-rule',
    reads:
        'the `header` rule is not a string, is a `<js>` rule with no closing '
        'marker, or is a plain string that is not a JSON map of strings (a '
        '`proxy` key included)',
    productCode:
        'HtmlSourcePipeline._headers '
        '(lib/source/html_source_pipeline.dart:266-301), '
        'JsonSourcePipeline._readHeaders/_validate '
        '(lib/source/json_source_pipeline.dart:165-171,358-384)',
    refuses: _headerRuleRefused,
  ),
  ReadinessCheck(
    id: 'html-missing-required-field',
    reads:
        'a `ruleSearch`/`ruleToc`/`ruleContent` field a stage reads without an '
        'optional fallback is absent or blank',
    productCode:
        'HtmlSourcePipeline._rule (lib/source/html_source_pipeline.dart:575-590) '
        'at its call sites: search (744-751), the TOC builder (910-925) and the '
        'content stage (1236)',
    pipeline: SourcePipeline.html,
    refuses: _htmlMissingRequiredField,
  ),
  ReadinessCheck(
    id: 'html-field-not-string',
    reads:
        'a rule field a stage reads is declared as something other than a '
        'string rule',
    productCode:
        'HtmlSourcePipeline._rule (lib/source/html_source_pipeline.dart:582-584)',
    pipeline: SourcePipeline.html,
    refuses: _htmlFieldNotString,
  ),
  ReadinessCheck(
    id: 'html-rule-field-syntax',
    reads:
        'the shared rule-field split refuses the declared field: a `<js>` block '
        'with no `</js>`, a `\$n` capture reference, or a rule segment after '
        '`<js>`',
    productCode:
        'RuleField.parseRuleField/extractionText '
        '(lib/source/rule_field.dart:181-241), reached through '
        'HtmlSourcePipeline._field (lib/source/html_source_pipeline.dart:423-438)',
    pipeline: SourcePipeline.html,
    refuses: _htmlRuleFieldSyntax,
  ),
  ReadinessCheck(
    id: 'html-list-rule-script',
    reads:
        'an element-list rule (`ruleSearch.bookList`, `ruleToc.chapterList`) '
        'carries an `@js:`/`<js>` script',
    productCode:
        'HtmlSourcePipeline._field(allowScripts: false) '
        '(lib/source/html_source_pipeline.dart:423-438) at both stages',
    pipeline: SourcePipeline.html,
    refuses: _htmlListRuleScript,
  ),
  ReadinessCheck(
    id: 'html-script-only-element-field',
    reads: 'a per-element value rule is only a script, with no extraction text',
    productCode:
        'HtmlSourcePipeline._elementField '
        '(lib/source/html_source_pipeline.dart:439-447)',
    pipeline: SourcePipeline.html,
    refuses: _htmlScriptOnlyElementField,
  ),
  ReadinessCheck(
    id: 'html-content-replace-rule',
    reads:
        'the content stage cannot express the declared `replaceRegex`: a '
        '`{{…}}` expression other than the chapter title one, or a replacement '
        'beside a `##` field on the content rule',
    productCode:
        'HtmlSourcePipeline._contentRule '
        '(lib/source/html_source_pipeline.dart:1202-1217)',
    pipeline: SourcePipeline.html,
    refuses: _htmlContentReplaceRefused,
  ),
  ReadinessCheck(
    id: 'html-toc-chapter-options',
    reads:
        'the TOC builder refuses the chapter address options: a POST, a body or '
        'a post-resolution script (headers, a retry count and a WebView ask are '
        'applied instead)',
    productCode:
        'the chapter-address guard in HtmlSourcePipeline.details '
        '(lib/source/html_source_pipeline.dart:1026-1031) over '
        'splitSourceUrlOptions (lib/source/source_url_rules.dart:291-330)',
    pipeline: SourcePipeline.html,
    refuses: _htmlTocChapterOptionsRefused,
  ),
  ReadinessCheck(
    id: 'json-missing-group',
    reads:
        'a group a JSON stage reads (`ruleSearch`/`ruleBookInfo`/`ruleToc`/'
        '`ruleContent`) is absent or is not an object',
    productCode:
        'JsonSourcePipeline._rules (lib/source/json_source_pipeline.dart:497-500)',
    pipeline: SourcePipeline.json,
    refuses: _jsonMissingGroup,
  ),
  ReadinessCheck(
    id: 'json-invalid-field',
    reads:
        'a declared field of one of those groups is neither a string nor '
        'empty',
    productCode:
        'JsonSourcePipeline._rules (lib/source/json_source_pipeline.dart:501-504)',
    pipeline: SourcePipeline.json,
    refuses: _jsonInvalidField,
  ),
  ReadinessCheck(
    id: 'json-rule-unreadable',
    reads:
        "the field's extraction text is refused: the shared rule-field split "
        'rejects it, or the bounded JSONPath reader cannot run it',
    productCode:
        'JsonSourcePipeline._rules (lib/source/json_source_pipeline.dart:519-531) '
        'over RuleField.extractionText (lib/source/rule_field.dart:234-241) and '
        'JsonSourceRules.validate (lib/source/json_source_rules.dart:79-100)',
    pipeline: SourcePipeline.json,
    refuses: _jsonRuleUnreadable,
  ),
  ReadinessCheck(
    id: 'json-unsupported-field',
    reads:
        'the field is not one the stages read: the declared-field vocabulary '
        'refuses it',
    productCode:
        'JsonSourcePipeline._rules (lib/source/json_source_pipeline.dart:533-557)',
    pipeline: SourcePipeline.json,
    refuses: _jsonUnsupportedField,
  ),
  ReadinessCheck(
    id: 'json-missing-required-field',
    reads: 'a required field of a group is not declared as a non-empty string',
    productCode:
        'JsonSourcePipeline._rules (lib/source/json_source_pipeline.dart:558-560)',
    pipeline: SourcePipeline.json,
    refuses: _jsonMissingRequiredField,
  ),
  ReadinessCheck(
    id: 'json-list-rule-script',
    reads:
        'a list rule (`ruleSearch.bookList`, `ruleToc.chapterList`) carries an '
        '`@js:`/`<js>` script',
    productCode:
        'JsonSourcePipeline._elementList '
        '(lib/source/json_source_pipeline.dart:318-326)',
    pipeline: SourcePipeline.json,
    refuses: _jsonListRuleScript,
  ),
];

/// What the audit cannot read, and why. Reported verbatim, so a reader is not
/// left to guess at the boundaries of the counts above.
const readinessGaps = <String>[
  'values the JavaScript runtime produces are not read: a `@js:`/`<js>` header '
      'rule, a `loginCheckJs`, and a `{{…}}` or `@js:` address expression '
      '(this mode initialises no runtime and evaluates no script)',
  'an address a stage *extracts* is not read: the TOC and content option '
      'guards read the extracted text, so a tail the page produces is not '
      'visible here (the tail a rule text itself declares is, and is reported '
      'as `html-toc-chapter-options`)',
  'a network outcome is not read: this mode sends no request, so an empty page, '
      'a login wall, an unsupported document shape and the frozen `bookUrlPattern` '
      'fallback are not readiness answers here',
  '`ruleSearch.checkKeyWord` is read only by the source check '
      '(`sourceCheckKeyword`, lib/source/book_source_pipeline.dart:29-50), not by '
      'the stages; the JSON adapter still refuses a non-string value there, as '
      '`json-invalid-field`',
  'the pipeline choice is one pipeline per record, from `ruleSearch.bookList` '
      '(`isJsonRuleSource`, lib/source/book_source_pipeline.dart:257-264): a '
      'record that mixes a JSON TOC rule with an HTML search is audited as HTML, '
      'which is how the product runs it',
  'no stage reads `ruleExplore`, so it is not audited',
];

/// One record's static readiness: the pipeline the product would run it with
/// and the reason ids its declared rules meet, in catalogue order.
class SourceReadiness {
  const SourceReadiness({required this.pipeline, required this.reasons});

  final SourcePipeline pipeline;

  /// The refusal reason ids, deduplicated, in [readinessChecks] order.
  final List<String> reasons;

  bool get ready => reasons.isEmpty;
}

/// Audits one record: selects the pipeline ([isJsonRuleSource]) and replays
/// every check that pipeline reaches.
SourceReadiness auditSource(Map<String, dynamic> source) {
  final pipeline = isJsonRuleSource(source)
      ? SourcePipeline.json
      : SourcePipeline.html;
  return SourceReadiness(
    pipeline: pipeline,
    reasons: <String>[
      for (final check in readinessChecks)
        if (check.pipeline == null || check.pipeline == pipeline)
          if (check.refuses(source)) check.id,
    ],
  );
}

/// One refusal reason's counts, and the collection position of one record that
/// meets it.
class ReasonTally {
  const ReasonTally({
    required this.check,
    required this.used,
    required this.collection,
    required this.example,
  });

  final ReadinessCheck check;

  /// How many used records meet the reason, or null when the input has no shelf.
  final int? used;

  final int collection;

  /// The position in `bookSource.json` of the first record that meets the
  /// reason, or null when none does.
  final int? example;
}

/// What one set of records answers: how many are ready, how many are refused
/// (counted once each), and how many meet each reason.
class ReadinessCounts {
  const ReadinessCounts({
    required this.total,
    required this.ready,
    required this.refused,
    required this.byReason,
  });

  final int total;
  final int ready;
  final int refused;
  final Map<String, int> byReason;
}

/// Everything the report line and the table need.
class ReadinessReport {
  const ReadinessReport({
    required this.backup,
    required this.collection,
    required this.used,
    required this.jsonCollection,
    required this.jsonUsed,
    required this.reasons,
  });

  /// The input the audit ran over, with its digest and its members.
  final SourceBackup backup;

  final ReadinessCounts collection;

  /// The used set's counts, or null when the input carries no shelf.
  final ReadinessCounts? used;

  final int jsonCollection;

  /// How many used records the JSON pipeline takes, or null without a shelf.
  final int? jsonUsed;

  /// How many records the HTML pipeline takes, on both sets.
  int get htmlCollection => collection.total - jsonCollection;
  int? get htmlUsed => used == null ? null : used!.total - jsonUsed!;

  /// Every reason, in report order: by used count, then by collection count,
  /// then in catalogue order.
  final List<ReasonTally> reasons;

  /// The provenance lines every static mode's report opens with.
  List<String> get backupLines => sourceBackupLines(backup);
}

/// Audits [path] and counts every reason over the used set and the collection.
///
/// The used set is `resolveUsedSources` — the same definition `source_usage.dart`
/// counts over, so the two reports speak about the same 150 records.
ReadinessReport readReadinessReport(String path) {
  final backup = readSourceBackup(path);
  final audit = <SourceReadiness>[
    for (final source in backup.sources) auditSource(source),
  ];
  final usedRecords = backup.shelf == null
      ? null
      : resolveUsedSources(backup.sources, backup.shelf!);
  final usedAudit = usedRecords
      ?.map((source) => auditSource(source))
      .toList(growable: false);
  final examples = <String, int>{};
  for (var index = 0; index < audit.length; index++) {
    for (final id in audit[index].reasons) {
      examples.putIfAbsent(id, () => index);
    }
  }
  final collection = _counts(audit);
  final used = usedAudit == null ? null : _counts(usedAudit);
  final reasons = <ReasonTally>[
    for (var index = 0; index < readinessChecks.length; index++)
      ReasonTally(
        check: readinessChecks[index],
        used: used == null
            ? null
            : (used.byReason[readinessChecks[index].id] ?? 0),
        collection: collection.byReason[readinessChecks[index].id] ?? 0,
        example: examples[readinessChecks[index].id],
      ),
  ];
  // Catalogue order is the tie-break: List.sort is not stable.
  final order = <String, int>{
    for (var index = 0; index < readinessChecks.length; index++)
      readinessChecks[index].id: index,
  };
  reasons.sort((a, b) {
    final byUsed = (b.used ?? 0).compareTo(a.used ?? 0);
    if (byUsed != 0) return byUsed;
    final byCollection = b.collection.compareTo(a.collection);
    if (byCollection != 0) return byCollection;
    return order[a.check.id]!.compareTo(order[b.check.id]!);
  });
  return ReadinessReport(
    backup: backup,
    collection: collection,
    used: used,
    jsonCollection: audit
        .where((record) => record.pipeline == SourcePipeline.json)
        .length,
    jsonUsed: usedAudit
        ?.where((record) => record.pipeline == SourcePipeline.json)
        .length,
    reasons: reasons,
  );
}

/// The report as text: counts, reason names and one position per reason, and
/// the gap list. Nothing else.
String renderReadinessReport(ReadinessReport report) {
  final lines = <String>[
    'static Book Source readiness — network-free, counts only; no rule text, '
        'URL, host, source name or other record content is read out',
    ...report.backupLines,
    '',
    'pipeline: json used ${_used(report.jsonUsed, report)}   '
        'collection ${report.jsonCollection}/${report.collection.total}',
    '   html used ${_used(report.htmlUsed, report)}   '
        'collection ${report.htmlCollection}/${report.collection.total}',
    '   one pipeline per record, selected from `ruleSearch.bookList` '
        '(isJsonRuleSource, lib/source/book_source_pipeline.dart:257-264)',
    '',
    'ready:    used ${_used(report.used?.ready, report)}   '
        'collection ${report.collection.ready}/${report.collection.total}',
    'refused:  used ${_used(report.used?.refused, report)}   '
        'collection ${report.collection.refused}/${report.collection.total}',
    '   a refused record is counted once here and once per reason below; the '
        'example is its position in ${report.backup.collectionMember} (0-based)',
    '',
    'refusal reasons, by used count:',
  ];
  for (final reason in report.reasons) {
    lines.add(
      '  [${reason.check.id}]   used ${_used(reason.used, report)}   '
      'collection ${reason.collection}/${report.collection.total}   '
      '${reason.example == null ? 'no example' : 'example [${reason.example}]'}',
    );
    lines.add('      reads: ${reason.check.reads}');
    lines.add('      from:  ${reason.check.productCode}');
  }
  lines.add('');
  lines.add('not read here:');
  for (final gap in readinessGaps) {
    lines.add('  - $gap');
  }
  return '${lines.join('\n')}\n';
}

ReadinessCounts _counts(List<SourceReadiness> audit) {
  final byReason = <String, int>{};
  var ready = 0;
  var refused = 0;
  for (final record in audit) {
    if (record.ready) {
      ready++;
      continue;
    }
    refused++;
    for (final id in record.reasons) {
      byReason[id] = (byReason[id] ?? 0) + 1;
    }
  }
  return ReadinessCounts(
    total: audit.length,
    ready: ready,
    refused: refused,
    byReason: byReason,
  );
}

String _used(int? count, ReadinessReport report) => count == null
    ? 'n/a (no shelf in the input)'
    : '$count/${report.used!.total}';

/// Whether [check] throws: a product validator refuses a rule by throwing.
///
/// `Object`, because the product's refusals are a mixture of `FormatException`,
/// `UnsupportedError` and `StateError`; a validator that throws is a refusal
/// either way.
bool _refused(void Function() check) {
  try {
    check();
    return false;
  } on Object {
    return true;
  }
}

/// The rule text of one declared field: the value when it is a non-empty string,
/// and null for every shape another reason already names.
String? _ruleText(Map<String, dynamic> source, String group, String field) {
  final rules = source[group];
  final value = rules is Map ? rules[field] : null;
  return value is String && value.isNotEmpty ? value : null;
}

/// The `##`/`##` split of one field, or null when the split itself refuses it
/// (which `html-rule-field-syntax` and `json-rule-unreadable` name).
RuleFieldText? _ruleFieldText(String value) {
  try {
    return parseRuleField(value);
  } on Object {
    return null;
  }
}

bool _sourceUrlRefused(Map<String, dynamic> source) {
  final identity = source['bookSourceUrl'];
  if (identity is! String || identity.isEmpty) return true;
  return _refused(() {
    final uri = SourceHttpUri.parse(identity);
    if (!const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('not a source address');
    }
  });
}

bool _searchUrlRefused(Map<String, dynamic> source) =>
    source['searchUrl'] is! String;

bool _headerRuleRefused(Map<String, dynamic> source) {
  final raw = source['header'];
  if (raw == null) return false;
  if (raw is! String) return true;
  final text = raw.trim();
  if (text.isEmpty) return false;
  final lower = text.toLowerCase();
  // A script's own value is not read (`readinessGaps`); a `<js>` rule missing
  // its closing marker is refused before the script would run.
  if (lower.startsWith('@js:')) return false;
  if (lower.startsWith('<js>')) return text.lastIndexOf('<') <= 4;
  final Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException {
    return true;
  }
  if (parsed is! Map) return true;
  if (parsed.entries.any(
    (entry) => entry.key is! String || entry.value is! String,
  )) {
    return true;
  }
  return parsed.keys.any((key) => '$key'.toLowerCase() == 'proxy');
}

/// How one of the HTML pipeline's stages reads one declared field.
enum HtmlRuleRead {
  /// `_field(allowScripts: false)`: an element list, where a script refuses.
  elementList,

  /// `_elementField`: one value per element, where a script-only rule refuses.
  elementValue,

  /// `_field`: one document value; a script-only rule is applied to the page.
  documentValue,
}

/// One field an HTML stage reads, and how it reads it. [required] marks the
/// reads the stage makes without `optional: true`.
class HtmlRuleSlot {
  const HtmlRuleSlot(
    this.group,
    this.field,
    this.read, {
    this.required = false,
  });

  final String group;
  final String field;
  final HtmlRuleRead read;
  final bool required;
}

/// Every field the HTML pipeline's stages read
/// (lib/source/html_source_pipeline.dart:744-790, 910-961, 1109-1155, 1236-1330).
const htmlRuleSlots = <HtmlRuleSlot>[
  HtmlRuleSlot(
    'ruleSearch',
    'bookList',
    HtmlRuleRead.elementList,
    required: true,
  ),
  HtmlRuleSlot('ruleSearch', 'name', HtmlRuleRead.elementValue, required: true),
  HtmlRuleSlot(
    'ruleSearch',
    'bookUrl',
    HtmlRuleRead.elementValue,
    required: true,
  ),
  HtmlRuleSlot('ruleSearch', 'author', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleSearch', 'intro', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleSearch', 'lastChapter', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleSearch', 'wordCount', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleSearch', 'kind', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleBookInfo', 'name', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'author', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'intro', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'coverUrl', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'kind', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'lastChapter', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'wordCount', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'tocUrl', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleBookInfo', 'canReName', HtmlRuleRead.documentValue),
  HtmlRuleSlot(
    'ruleToc',
    'chapterList',
    HtmlRuleRead.elementList,
    required: true,
  ),
  HtmlRuleSlot(
    'ruleToc',
    'chapterName',
    HtmlRuleRead.elementValue,
    required: true,
  ),
  HtmlRuleSlot(
    'ruleToc',
    'chapterUrl',
    HtmlRuleRead.elementValue,
    required: true,
  ),
  HtmlRuleSlot('ruleToc', 'updateTime', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleToc', 'isVolume', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleToc', 'isVip', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleToc', 'isPay', HtmlRuleRead.elementValue),
  HtmlRuleSlot('ruleToc', 'nextTocUrl', HtmlRuleRead.documentValue),
  HtmlRuleSlot(
    'ruleContent',
    'content',
    HtmlRuleRead.documentValue,
    required: true,
  ),
  HtmlRuleSlot('ruleContent', 'replaceRegex', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleContent', 'title', HtmlRuleRead.documentValue),
  HtmlRuleSlot('ruleContent', 'nextContentUrl', HtmlRuleRead.documentValue),
];

/// The groups a JSON stage reads, and the fields each requires
/// (lib/source/json_source_pipeline.dart:597, 680-681, 862, 941).
const jsonRequiredFields = <String, List<String>>{
  'ruleSearch': ['bookList', 'name', 'bookUrl'],
  'ruleBookInfo': [],
  'ruleToc': ['chapterList', 'chapterName', 'chapterUrl'],
  'ruleContent': ['content'],
};

/// The declared fields the JSON adapter accepts besides its required ones
/// (lib/source/json_source_pipeline.dart:537-556).
const jsonAcceptedFields = <String>{
  'author',
  'coverUrl',
  'intro',
  'kind',
  'wordCount',
  'lastChapter',
  'updateTime',
  'isVolume',
  'isVip',
  'isPay',
  'canReName',
  'downloadUrls',
  'init',
  'checkKeyWord',
  'title',
  'name',
  'tocUrl',
};

/// The one page-chaining field each group may declare besides its own rules.
const jsonChainedFields = <String, String>{
  'ruleToc': 'nextTocUrl',
  'ruleContent': 'nextContentUrl',
};

/// The fields `_rules` does not validate as an extraction: a check keyword and
/// the rename flag are values, not rules.
const jsonUnvalidatedFields = <String>{'checkKeyWord', 'canReName'};

/// The field `_rules` accepts and ignores: nothing executes it, so it must not
/// fail a stage (ticket #81).
const jsonIgnoredFields = <String>{'downloadUrls'};

/// One declared field of one JSON group, as `_rules` walks the group.
class JsonField {
  const JsonField(this.group, this.field, this.value);

  final String group;
  final String field;
  final Object value;
}

/// Every declared field of the four JSON groups, in the group's own order: the
/// entries `_rules` reads (a null or empty value is skipped there).
Iterable<JsonField> _jsonDeclared(Map<String, dynamic> source) sync* {
  for (final group in jsonRequiredFields.keys) {
    final rules = source[group];
    if (rules is! Map) continue;
    for (final entry in rules.entries) {
      final value = entry.value;
      if (value == null || value == '') continue;
      yield JsonField(group, '${entry.key}', value);
    }
  }
}

/// Whether the field is read as a list rule (`_rules`' `forList`).
bool _jsonListRule(JsonField entry) =>
    entry.field == 'bookList' ||
    entry.field == 'chapterList' ||
    jsonChainedFields[entry.group] == entry.field;

bool _htmlMissingRequiredField(Map<String, dynamic> source) =>
    htmlRuleSlots.any(
      (slot) =>
          slot.required && _ruleText(source, slot.group, slot.field) == null,
    );

bool _htmlFieldNotString(Map<String, dynamic> source) {
  for (final slot in htmlRuleSlots) {
    final rules = source[slot.group];
    final value = rules is Map ? rules[slot.field] : null;
    if (value != null && value != '' && value is! String) return true;
  }
  return false;
}

bool _htmlRuleFieldSyntax(Map<String, dynamic> source) {
  for (final slot in htmlRuleSlots) {
    final text = _ruleText(source, slot.group, slot.field);
    if (text != null && _ruleFieldText(text) == null) return true;
  }
  return false;
}

bool _htmlListRuleScript(Map<String, dynamic> source) {
  for (final slot in htmlRuleSlots) {
    if (slot.read != HtmlRuleRead.elementList) continue;
    final text = _ruleText(source, slot.group, slot.field);
    final parts = text == null ? null : _ruleFieldText(text);
    if (parts != null && parts.scripts.isNotEmpty) return true;
  }
  return false;
}

bool _htmlScriptOnlyElementField(Map<String, dynamic> source) {
  for (final slot in htmlRuleSlots) {
    if (slot.read != HtmlRuleRead.elementValue) continue;
    final text = _ruleText(source, slot.group, slot.field);
    final parts = text == null ? null : _ruleFieldText(text);
    if (parts != null && parts.extractionRule == null) return true;
  }
  return false;
}

bool _htmlContentReplaceRefused(Map<String, dynamic> source) {
  final content = _ruleText(source, 'ruleContent', 'content');
  if (content == null) return false;
  final replacement = (_ruleText(source, 'ruleContent', 'replaceRegex') ?? '')
      .replaceAll('{{chapter.title}}', '');
  if (replacement.contains('{{')) return true;
  return replacement.isNotEmpty && content.contains('##');
}

bool _htmlTocChapterOptionsRefused(Map<String, dynamic> source) {
  final text = _ruleText(source, 'ruleToc', 'chapterUrl');
  if (text == null) return false;
  final parts = _ruleFieldText(text);
  // A script's value is not read here (`readinessGaps`).
  if (parts == null || parts.scripts.isNotEmpty) return false;
  final SourceUrlOptions options;
  try {
    options = splitSourceUrlOptions(text).options;
  } on Object {
    // An option tail the shared parser refuses outright is not this guard's
    // answer, and the address it guards is extracted rather than declared.
    return false;
  }
  return options.isPost || options.body != null || options.js != null;
}

bool _jsonMissingGroup(Map<String, dynamic> source) =>
    jsonRequiredFields.keys.any((group) => source[group] is! Map);

bool _jsonInvalidField(Map<String, dynamic> source) =>
    _jsonDeclared(source).any((entry) => entry.value is! String);

bool _jsonRuleUnreadable(Map<String, dynamic> source) {
  for (final entry in _jsonDeclared(source)) {
    if (jsonIgnoredFields.contains(entry.field) ||
        jsonUnvalidatedFields.contains(entry.field)) {
      continue;
    }
    final value = entry.value;
    // A non-string value is `json-invalid-field`'s answer.
    if (value is! String) continue;
    final refused = _refused(() {
      final extraction = RuleField.extractionText(value);
      if (extraction != null) {
        JsonSourceRules.validate(extraction, forList: _jsonListRule(entry));
      }
    });
    if (refused) return true;
  }
  return false;
}

bool _jsonUnsupportedField(Map<String, dynamic> source) =>
    _jsonDeclared(source).any(
      (entry) =>
          !jsonRequiredFields[entry.group]!.contains(entry.field) &&
          jsonChainedFields[entry.group] != entry.field &&
          !jsonAcceptedFields.contains(entry.field),
    );

bool _jsonMissingRequiredField(Map<String, dynamic> source) {
  for (final group in jsonRequiredFields.entries) {
    for (final field in group.value) {
      final value = _ruleText(source, group.key, field);
      if (value == null) return true;
    }
  }
  return false;
}

bool _jsonListRuleScript(Map<String, dynamic> source) {
  for (final entry in _jsonDeclared(source)) {
    if (!_jsonListRule(entry)) continue;
    final value = entry.value;
    if (value is! String) continue;
    final parts = _ruleFieldText(value);
    if (parts != null && parts.scripts.isNotEmpty) return true;
  }
  return false;
}
