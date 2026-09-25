import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/source_readiness.dart';

/// The readiness audit's own rules, over a synthetic export: one record per
/// refusal reason, the ready records of both pipelines (the HTML one carrying
/// the `headers`/`retry`/`webView` chapter tail ticket #81 says must be
/// reported ready), and a shelf that resolves three of them.
///
/// The fixture is built here, in the repository, and carries no private data;
/// the audit never prints a record anyway, and the last test pins that.
void main() {
  final readyHtml = _html('ready-html.example');
  final readyJson = _json('ready-json.example');
  final readyChapterTail = _withField(
    _html('ready-tail.example'),
    'ruleToc',
    'chapterUrl',
    'href,{"headers":{"User-Agent":"x"},"retry":2,"webView":true}',
  );
  final byReason = <String, Map<String, dynamic>>{
    'source-url': _withoutTop(_html('unused.example'), 'bookSourceUrl'),
    'search-url': _withoutTop(_html('no-search.example'), 'searchUrl'),
    'header-rule': _withTop(
      _html('bad-header.example'),
      'header',
      '{"proxy":"http://127.0.0.1:1"}',
    ),
    'html-missing-required-field': _withoutField(
      _html('missing-toc-field.example'),
      'ruleToc',
      'chapterName',
    ),
    'html-field-not-string': _withField(
      _html('boolean-field.example'),
      'ruleToc',
      'isVolume',
      true,
    ),
    'html-rule-field-syntax': _withField(
      _html('capture.example'),
      'ruleContent',
      'content',
      r'div#content $1',
    ),
    'html-content-replace-rule': _withField(
      _withField(
        _html('replace.example'),
        'ruleContent',
        'content',
        'div#content##@text',
      ),
      'ruleContent',
      'replaceRegex',
      r'##$1',
    ),
    'html-toc-chapter-options': _withField(
      _html('post-chapter.example'),
      'ruleToc',
      'chapterUrl',
      'href,{"method":"POST"}',
    ),
    'json-missing-group': _withoutTop(
      _json('no-group.example'),
      'ruleBookInfo',
    ),
    'json-invalid-field': _withField(
      _json('boolean-json-field.example'),
      'ruleToc',
      'isVolume',
      true,
    ),
    'json-rule-unreadable': _withField(
      _json('unreadable-rule.example'),
      'ruleContent',
      'content',
      r'@Other:$.a',
    ),
    'json-unsupported-field': _withField(
      _json('unsupported-field.example'),
      'ruleSearch',
      'nextTocUrl',
      r'$.next',
    ),
    'json-missing-required-field': _withoutField(
      _json('no-chapter-url-json.example'),
      'ruleToc',
      'chapterUrl',
    ),
    'json-list-rule-script': _withField(
      _json('scripted-json-list.example'),
      'ruleSearch',
      'bookList',
      r'$.data[*]@js:result',
    ),
  };
  final sources = <Map<String, dynamic>>[
    ...byReason.values,
    readyHtml,
    readyJson,
    readyChapterTail,
  ];
  final shelf = <Map<String, dynamic>>[
    <String, dynamic>{'origin': 'https://ready-html.example', 'name': 'used'},
    <String, dynamic>{
      'origin': 'https://unsupported-field.example',
      'name': 'used',
    },
    <String, dynamic>{
      'origin': 'https://missing-toc-field.example',
      'name': 'used',
    },
    // An origin no record declares: a shelf row that resolves to nothing is not
    // a used source.
    <String, dynamic>{'origin': 'https://missing.example', 'name': 'unused'},
  ];

  late Directory directory;
  late ReadinessReport report;
  late ReadinessReport exportReport;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('liber_source_readiness');
    File('${directory.path}/backup.zip').writeAsBytesSync(
      _zipOf(<String, Object?>{
        'bookSource.json': sources,
        'bookshelf.json': shelf,
      }),
    );
    File(
      '${directory.path}/bookSource.json',
    ).writeAsStringSync(jsonEncode(sources));
    report = readReadinessReport('${directory.path}/backup.zip');
    exportReport = readReadinessReport('${directory.path}/bookSource.json');
  });

  tearDownAll(() => directory.deleteSync(recursive: true));

  test('the fixture covers every reason, one record each', () {
    expect(
      byReason.keys.toSet(),
      readinessChecks.map((check) => check.id).toSet(),
      reason: 'every reason the audit names has a refusing record',
    );
  });

  test('each reason names exactly the record that refuses it', () {
    for (final entry in byReason.entries) {
      final reasons = auditSource(entry.value).reasons;
      expect(reasons, <String>[entry.key], reason: entry.key);
    }
  });

  test('the ready records of both pipelines are ready', () {
    for (final source in <Map<String, dynamic>>[
      _html('ready.example'),
      _json('ready.example'),
      // #81: a chapter address whose tail carries headers, a retry count and a
      // WebView ask is applied, not refused.
      _withField(
        _html('ready.example'),
        'ruleToc',
        'chapterUrl',
        'href,{"headers":{"User-Agent":"x"},"retry":2,"webView":true}',
      ),
      // #100: the script element family is read with the frozen binding and
      // the measured node façade, so neither class refuses any longer.
      _withField(
        _html('scripted-list.example'),
        'ruleSearch',
        'bookList',
        'div.book@js:result',
      ),
      _withField(
        _html('script-only.example'),
        'ruleSearch',
        'name',
        '@js:result',
      ),
    ]) {
      expect(
        auditSource(source).reasons,
        isEmpty,
        reason: '${source['searchUrl']}',
      );
    }
  });

  test('the pipeline is the product own choice, per record', () {
    expect(auditSource(_json('a.example')).pipeline, SourcePipeline.json);
    expect(auditSource(_html('a.example')).pipeline, SourcePipeline.html);
    // `isJsonRuleSource` reads `ruleSearch.bookList` case-insensitively.
    expect(
      auditSource(
        _withField(
          _html('a.example'),
          'ruleSearch',
          'bookList',
          r'@Json:$.data[*]',
        ),
      ).pipeline,
      SourcePipeline.json,
    );
    expect(
      auditSource(
        _withField(_html('a.example'), 'ruleSearch', 'bookList', r"$['data']"),
      ).pipeline,
      SourcePipeline.json,
    );
    // A JSON TOC rule behind an HTML search is audited as HTML, which is how
    // the product runs it.
    final mixed = _withField(
      _html('a.example'),
      'ruleToc',
      'chapterList',
      r'$.chapters[*]',
    );
    expect(auditSource(mixed).pipeline, SourcePipeline.html);
    expect(auditSource(mixed).reasons, isEmpty);
  });

  test('the four product-bug fixes move the audit with the product (#83)', () {
    final html = _html('fix.example');
    final json = _json('fix.example');
    // 1. A `header` text that is not a JSON map is read as no headers (the
    // frozen `getOrNull()`), not a refusal; only `proxy` and a non-string stay.
    expect(
      auditSource(_withTop(html, 'header', 'not json')).reasons,
      isEmpty,
    );
    expect(
      auditSource(_withTop(html, 'header', "{'X-Token':'1'}")).reasons,
      isEmpty,
    );
    expect(
      auditSource(_withTop(html, 'header', 7)).reasons,
      <String>['header-rule'],
    );
    // 2. `imageStyle`/`replaceRegex` are declared fields this product does not
    // validate as an extraction.
    for (final entry in <(String, String)>[
      ('ruleContent', 'imageStyle'),
      ('ruleContent', 'replaceRegex'),
    ]) {
      expect(
        auditSource(_withField(json, entry.$1, entry.$2, 'x')).reasons,
        isEmpty,
        reason: '${entry.$1}.${entry.$2}',
      );
    }
    // 3. A field whose text has nothing left to parse validates.
    for (final text in <String>[r'##x##y', '@get:x']) {
      expect(
        auditSource(_withField(json, 'ruleContent', 'content', text)).reasons,
        isEmpty,
        reason: text,
      );
    }
    // 4. A blank `ruleToc.chapterUrl` is the frozen empty-URL fallback.
    expect(
      auditSource(_withoutField(html, 'ruleToc', 'chapterUrl')).reasons,
      isEmpty,
    );
    // 5. The identity address is a plain string in the frozen, so a label
    // identity with absolute rules is not a refusal; only a missing or
    // non-string identity is.
    expect(
      auditSource(_withTop(html, 'bookSourceUrl', 'a label, not a URL')).reasons,
      isEmpty,
    );
    expect(
      auditSource(_withoutTop(html, 'bookSourceUrl')).reasons,
      <String>['source-url'],
    );
  });

  test('every branch of the content-replacement refusal is pinned', () {
    Map<String, dynamic> withReplacement(String replacement) => _withField(
      _withField(
        _html('branch.example'),
        'ruleContent',
        'content',
        'div#content##@text',
      ),
      'ruleContent',
      'replaceRegex',
      replacement,
    );
    // The chapter-title expression is resolved by the product, so it is no
    // refusal on its own; every other `{{…}}` expression is one.
    expect(
      auditSource(withReplacement('{{chapter.title}}')).reasons,
      isEmpty,
    );
    expect(
      auditSource(withReplacement('{{key}}')).reasons,
      <String>['html-content-replace-rule'],
    );
    // A replacement beside a `##` field on the content rule is the other
    // branch; a replacement beside a plain content rule is not.
    final plain = _withField(
      _html('branch.example'),
      'ruleContent',
      'replaceRegex',
      '##@text',
    );
    expect(auditSource(plain).reasons, isEmpty);
  });

  test('every refusable chapter-address option is pinned', () {
    for (final tail in <String>[
      '{"method":"POST"}',
      '{"body":"a=1"}',
      '{"js":"result"}',
    ]) {
      final source = _withField(
        _html('option.example'),
        'ruleToc',
        'chapterUrl',
        'href,$tail',
      );
      expect(
        auditSource(source).reasons,
        <String>['html-toc-chapter-options'],
        reason: tail,
      );
    }
  });

  test('the counts are the used set and the whole collection', () {
    expect(report.collection.total, 17, reason: 'the whole collection');
    expect(report.collection.ready, 3, reason: 'the ready records');
    expect(report.collection.refused, 14, reason: 'one per reason');
    expect(report.used!.total, 3, reason: 'origins that resolve');
    expect(report.used!.ready, 1);
    expect(report.used!.refused, 2);
    expect(report.jsonCollection, 7);
    expect(report.jsonUsed, 1);
    expect(report.htmlCollection, 10);
    expect(report.htmlUsed, 2);
    for (final id in <String>[
      'json-unsupported-field',
      'html-missing-required-field',
    ]) {
      expect(_tally(report, id).used, 1, reason: id);
      expect(_tally(report, id).collection, 1, reason: id);
    }
    expect(_tally(report, 'search-url').used, 0);
    expect(_tally(report, 'search-url').collection, 1);
    expect(_tally(report, 'source-url').example, 0);
    for (final reason in report.reasons) {
      expect(
        reason.example == null,
        reason.collection == 0,
        reason: '${reason.check.id}: an example exactly when a record meets it',
      );
      expect(reason.collection, lessThanOrEqualTo(1), reason: reason.check.id);
    }
  });

  test('the reasons are ordered by used count, then by collection count', () {
    final ids = <String>[for (final reason in report.reasons) reason.check.id];
    expect(
      ids.take(2),
      <String>['html-missing-required-field', 'json-unsupported-field'],
      reason: 'the two reasons the shelf reaches come first',
    );
    var previousUsed = 4;
    var previousCollection = 4;
    for (final reason in report.reasons) {
      expect(
        reason.used!,
        lessThanOrEqualTo(previousUsed),
        reason: ids.join(','),
      );
      if (reason.used == previousUsed) {
        expect(reason.collection, lessThanOrEqualTo(previousCollection));
      }
      previousUsed = reason.used!;
      previousCollection = reason.collection;
    }
  });

  test('a bare export carries no shelf, so the used column is n/a', () {
    expect(exportReport.backup.shelfMember, isNull);
    expect(exportReport.used, isNull);
    expect(exportReport.jsonUsed, isNull);
    expect(exportReport.collection.total, 17);
    expect(
      renderReadinessReport(exportReport),
      contains('used n/a (no shelf in the input)'),
    );
  });

  test('the report names the input, its digest, its members and its gaps', () {
    final text = renderReadinessReport(report);
    expect(text, contains(report.backup.sha256));
    expect(text, contains('collection: 17 records from bookSource.json'));
    expect(text, contains('4 entries, 4 distinct origins, 3 resolved'));
    expect(text, contains('bookshelf.json'));
    for (final gap in readinessGaps) {
      expect(text, contains(gap));
    }
  });

  test('the report reads out no record, URL, host, name or rule text', () {
    final text = renderReadinessReport(report);
    for (final secret in <String>[
      'ready-html.example',
      'unsupported-field.example',
      'unused.example',
      'plain.host/unused',
      'div.book',
      'a@href',
      'h1',
      r'$.data[*]',
      r'$.chapters[*]',
      'div#content',
      r'@Other:$.a',
      'synthetic',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });
}

ReasonTally _tally(ReadinessReport report, String id) =>
    report.reasons.firstWhere((reason) => reason.check.id == id);

/// A ready HTML record: every rule read of `ruleSearch`, `ruleBookInfo`,
/// `ruleToc` and `ruleContent` declared and supported.
Map<String, dynamic> _html(String host) => <String, dynamic>{
  'bookSourceName': 'synthetic $host',
  'bookSourceUrl': 'https://$host',
  'searchUrl': 'https://$host/search?q={{key}}',
  'ruleSearch': <String, dynamic>{
    'bookList': 'div.book',
    'name': 'h3',
    'bookUrl': 'a@href',
  },
  'ruleBookInfo': <String, dynamic>{'name': 'h1'},
  'ruleToc': <String, dynamic>{
    'chapterList': 'ul li a',
    'chapterName': 'text',
    'chapterUrl': 'href',
  },
  'ruleContent': <String, dynamic>{'content': 'div#content'},
};

/// A ready JSON record: the same four stages as JSONPath rules.
Map<String, dynamic> _json(String host) => <String, dynamic>{
  'bookSourceName': 'synthetic $host',
  'bookSourceUrl': 'https://$host',
  'searchUrl': 'https://$host/api?q={{key}}',
  'ruleSearch': <String, dynamic>{
    'bookList': r'$.data[*]',
    'name': r'$.name',
    'bookUrl': r'$.url',
  },
  'ruleBookInfo': <String, dynamic>{'name': r'$.name'},
  'ruleToc': <String, dynamic>{
    'chapterList': r'$.chapters[*]',
    'chapterName': r'$.title',
    'chapterUrl': r'$.url',
  },
  'ruleContent': <String, dynamic>{'content': r'$.content'},
};

Map<String, dynamic> _withTop(
  Map<String, dynamic> source,
  String key,
  Object? value,
) => <String, dynamic>{...source, key: value};

Map<String, dynamic> _withoutTop(
  Map<String, dynamic> source,
  String key,
) => <String, dynamic>{...source}..remove(key);

Map<String, dynamic> _withField(
  Map<String, dynamic> source,
  String group,
  String field,
  Object? value,
) {
  final rules = <String, dynamic>{
    ...(source[group] as Map).cast<String, dynamic>(),
  };
  if (value == null) {
    rules.remove(field);
  } else {
    rules[field] = value;
  }
  return <String, dynamic>{...source, group: rules};
}

Map<String, dynamic> _withoutField(
  Map<String, dynamic> source,
  String group,
  String field,
) => _withField(source, group, field, null);

/// A ZIP of [members], values encoded as JSON unless they are already text.
Uint8List _zipOf(Map<String, Object?> members) {
  final archive = Archive();
  for (final entry in members.entries) {
    final text = entry.value is String
        ? entry.value! as String
        : jsonEncode(entry.value);
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
