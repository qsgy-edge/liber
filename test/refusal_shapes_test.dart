import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/refusal_shapes.dart';

/// The script-surface probe's own readings (#98), over synthetic records: one
/// script per value shape and per class, plus the two input facts (the bound
/// value used as a node, and a JSON-pipeline record carrying a script that is
/// not this family). The fixture is built here and carries no private data; the
/// report's leak test pins that none of it is read out.
void main() {
  group('readScriptField', () {
    test('reads a jsoup node set out of a script', () {
      final reading = readScriptField(<String>[
        'doc = org.jsoup.Jsoup.parse(result); doc.select("a")',
      ]);
      expect(reading.shape, ScriptShape.elements);
      expect(reading.calls, <String>['Jsoup.parse', 'select']);
      expect(
        reading.bindsElement,
        isFalse,
        reason: 'the value is parsed from text, not used as a node',
      );
    });

    test('reads a string off a node as a string, and marks the node input', () {
      final reading = readScriptField(<String>[
        'result.select("span").text()',
      ]);
      expect(reading.shape, ScriptShape.string);
      expect(reading.calls, <String>['select', 'text']);
      expect(reading.bindsElement, isTrue);
    });

    test('reads an array a script builds as a transform', () {
      final reading = readScriptField(<String>[
        'list = []; result.forEach((x) => list.push(x.attr("href"))); list',
      ]);
      expect(reading.shape, ScriptShape.transforming);
      expect(reading.calls, <String>['attr']);
    });

    test('reads a scalar-only script as a string', () {
      final reading = readScriptField(<String>['result.match(/U.*/)']);
      expect(reading.shape, ScriptShape.string);
      expect(reading.calls, isEmpty);
    });

    test('reports a branch that differs at runtime as mixed', () {
      final reading = readScriptField(<String>[
        'u = result;\nif (x) { u = [{"a": 1}] }\nu',
      ]);
      expect(reading.shape, ScriptShape.mixed);
    });

    test('counts the java.getElement(s) bridge and the bound value as a '
        'node', () {
      final reading = readScriptField(<String>[
        'java.getElements("section a").forEach((x) => x.text())',
      ]);
      expect(reading.bindsElement, isTrue);
      expect(reading.calls, contains('java.getElements'));
    });

    test('reads a call name from code, not from a comment or a string', () {
      final reading = readScriptField(<String>[
        '// result.select("x")',
        'x = "result.text()"',
      ]);
      expect(reading.calls, isEmpty);
      expect(reading.shape, ScriptShape.string);
    });

    test('keeps a template literal expression as code', () {
      final reading = readScriptField(<String>['`\${result.attr("x")}`']);
      expect(reading.calls, <String>['attr']);
    });

    test('reads the last segment of a field, scanning every segment', () {
      final reading = readScriptField(<String>[
        'result.select("a")',
        'list = []; docs.forEach((x) => list.push(x.text()))',
      ]);
      expect(reading.shape, ScriptShape.transforming);
      expect(reading.calls, <String>['select', 'text']);
    });
  });

  group('measureHtmlScriptFields', () {
    test('measures both classes in htmlRuleSlots order, with the position',
        () {
      final source = _withField(
        _withField(
          _html('a.example'),
          'ruleToc',
          'isVip',
          '<js>result.attr("data-cost")</js>',
        ),
        'ruleSearch',
        'bookList',
        '@js:result',
      );
      final fields = measureHtmlScriptFields(source, position: 7);
      expect(fields.map((field) => field.field), <String>[
        'ruleSearch.bookList',
        'ruleToc.isVip',
      ]);
      expect(fields.map((field) => field.ruleClass), <ScriptRuleClass>[
        ScriptRuleClass.elementList,
        ScriptRuleClass.elementField,
      ]);
      expect(fields.first.position, 7);
    });

    test('leaves a per-element field with extraction text out of the class',
        () {
      final source = _withField(_html('a.example'), 'ruleSearch', 'name',
          'h3@js:result');
      expect(measureHtmlScriptFields(source), isEmpty);
    });

    test('an extraction-plus-script list rule is the element-list class', () {
      final source = _withField(_html('a.example'), 'ruleSearch', 'bookList',
          'div.book@js:result');
      final fields = measureHtmlScriptFields(source);
      expect(fields.single.ruleClass, ScriptRuleClass.elementList);
      expect(fields.single.segments, 1);
    });

    test('a JSON-pipeline record carries no html script family', () {
      final source = _withField(
        _json('a.example'),
        'ruleSearch',
        'bookList',
        r'$.data[*]@js:result',
      );
      expect(measureHtmlScriptFields(source), isEmpty);
    });
  });

  group('readScriptSurfaceReport', () {
    late Directory directory;
    late ScriptSurfaceReport report;

    setUpAll(() {
      directory = Directory.systemTemp.createTempSync('liber_refusal_shapes');
      final sources = <Map<String, dynamic>>[
        _withField(
          _withField(
            _html('list.example'),
            'ruleSearch',
            'bookList',
            '@js:result',
          ),
          'ruleToc',
          'isVip',
          '<js>result.attr("data-cost")</js>',
        ),
        _withField(
          _html('plain.example'),
          'ruleToc',
          'isVip',
          '<js>result.text()</js>',
        ),
        _html('ready.example'),
      ];
      final shelf = <Map<String, dynamic>>[
        <String, dynamic>{'origin': 'https://list.example'},
      ];
      File('${directory.path}/backup.zip').writeAsBytesSync(
        _zipOf(<String, Object?>{
          'bookSource.json': sources,
          'bookshelf.json': shelf,
        }),
      );
      report = readScriptSurfaceReport('${directory.path}/backup.zip');
    });

    tearDownAll(() => directory.deleteSync(recursive: true));

    test('the element-list class counts its used and collection records', () {
      final table = report.table(ScriptRuleClass.elementList);
      expect(table.usedSources, 1);
      expect(table.collectionSources, 1);
      expect(table.usedFields, hasLength(1));
      expect(table.usedFields.single.position, 0);
      expect(table.usedFields.single.reading.shape, ScriptShape.elements);
      expect(table.calls, isEmpty, reason: 'a passthrough reaches no call');
    });

    test('the per-element class counts used and collection separately', () {
      final table = report.table(ScriptRuleClass.elementField);
      expect(table.usedSources, 1);
      expect(table.collectionSources, 2);
      expect(table.usedFields, hasLength(1));
      expect(table.usedBindsElement, 1);
      expect(
        table.calls.map((call) => call.name),
        containsAll(<String>['attr', 'text']),
      );
      final attr =
          table.calls.firstWhere((call) => call.name == 'attr');
      expect(attr.usedSources, 1);
      expect(attr.collectionSources, 1);
    });

    test('the report reads out no rule text, host, script or header value', () {
      final text = renderScriptSurfaceReport(report);
      for (final secret in <String>[
        'list.example',
        'plain.example',
        'ready.example',
        'div.book',
        'result.attr',
        'result.text',
        'data-cost',
        '@js:result',
      ]) {
        expect(text, isNot(contains(secret)), reason: secret);
      }
      expect(text, contains('script element family'));
      expect(text, contains('used: 1'));
      for (final gap in scriptSurfaceGaps) {
        expect(text, contains(gap));
      }
    });
  });
}

/// A ready HTML record: every rule read of the four stages declared.
Map<String, dynamic> _html(String host) => <String, dynamic>{
  'bookSourceUrl': 'https://$host',
  'searchUrl': 'https://$host/search',
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
  'bookSourceUrl': 'https://$host',
  'searchUrl': 'https://$host/api',
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

Map<String, dynamic> _withField(
  Map<String, dynamic> source,
  String group,
  String field,
  Object? value,
) {
  final rules = <String, dynamic>{
    ...(source[group] as Map).cast<String, dynamic>(),
  };
  rules[field] = value;
  return <String, dynamic>{...source, group: rules};
}

/// A ZIP of [members], values encoded as JSON.
Uint8List _zipOf(Map<String, Object?> members) {
  final archive = Archive();
  for (final entry in members.entries) {
    final bytes = utf8.encode(jsonEncode(entry.value));
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}
