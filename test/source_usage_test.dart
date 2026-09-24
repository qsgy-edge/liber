import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';

import '../tool/source_usage.dart';

/// The static usage counter's own rules, over a synthetic export: a record that
/// reaches every §3 family, a record that reaches none, a record that reaches
/// only `bookUrlPattern`, and a record whose only capability is an `http://`
/// identity. The shelf is four rows over two origins, one of them duplicated
/// and one resolving to no record, so the used column can only be the
/// intersection.
///
/// The fixture carries no private data: it is built here, in the repository,
/// and the counter never prints a record anyway (the last test pins that).
void main() {
  final synthetic = <Map<String, dynamic>>[
    <String, dynamic>{
      'bookSourceName': 'synthetic all-families',
      'bookSourceUrl': 'https://used.example',
      'loginUrl': 'https://used.example/login',
      'loginUi': '[{"name":"u"}]',
      'loginCheckJs': "source.setVariable('k', source.getVariable('k'))",
      'bookUrlPattern': r'https://used.example/book/\d+',
      'concurrentRate': '1/1000',
      'enabledCookieJar': true,
      'jsLib': 'var shared = 1;',
      'header': '{"X-Id":"<js>androidId</js>","UA":"<js>getWebViewUA()</js>"}',
      'ruleSearch': <String, dynamic>{
        'bookList': r'$.data[*]',
        'name': r'@Json:$.name',
        'lastChapter': "toNumChapter('一')",
      },
      'ruleBookInfo': <String, dynamic>{
        'init': "book.getVariable('x')",
        'name': 'book.name',
        'intro': "java.get('k') || cache.get('k') || cookie.getCookie('a')",
      },
      'ruleToc': <String, dynamic>{
        'chapterList': "java.ajaxAll('[\"\$.a\"]')",
        'chapterName': 'chapter.title',
        'updateTime': r'$.t',
        'isVolume': r'$.v',
        'isVip': r'$.p',
        'isPay': r'$.q',
        'nextTocUrl': r'$.next',
      },
      'ruleContent': <String, dynamic>{
        'content': r'$[?(@.x)][0:2]',
        'title': 'chapter.title',
        'imageStyle': 'FULL',
        'nextContentUrl': r'$.next',
      },
      'ruleExplore': <String, dynamic>{
        'bookList': r'["$.a", "$.b"]',
        'intro':
            "java.connect('k: v'); source.getHeaderMap(true); "
            "java.log('x'); java.toast('y'); java.put('k', 'v'); "
            "cache.put('k', 'v'); cookie.setCookie('a', 'b'); "
            'java.startBrowser(url); java.getVerificationCode(img); '
            'java.openUrl(url);',
      },
    },
    <String, dynamic>{
      'bookSourceName': 'synthetic no-family',
      // No `http(s)://` scheme: the TLS row's own predicate is the identity
      // URL, so a record that reaches nothing must not carry one either.
      'bookSourceUrl': 'plain.host/unused',
      'ruleSearch': <String, dynamic>{'bookList': 'div.book'},
    },
    <String, dynamic>{
      'bookSourceName': 'synthetic shelf-only',
      'bookSourceUrl': 'https://shelf-only.example',
      'bookUrlPattern': r'https://shelf-only\.example/book/\d+',
      'ruleSearch': <String, dynamic>{'bookList': 'div.book'},
    },
    <String, dynamic>{
      'bookSourceName': 'synthetic http-only',
      'bookSourceUrl': 'http://plain.example',
      'ruleSearch': <String, dynamic>{'bookList': 'div.book'},
    },
  ];
  final shelf = <Map<String, dynamic>>[
    <String, dynamic>{'origin': 'https://used.example', 'name': 'a'},
    // The same origin twice: a shelf of 1 419 rows over 192 origins must not
    // count a record twice.
    <String, dynamic>{'origin': 'https://used.example', 'name': 'b'},
    // An origin no source declares: a shelf row that resolves to nothing is
    // not a used source.
    <String, dynamic>{'origin': 'https://missing.example', 'name': 'c'},
    // A shelf row with no origin at all.
    <String, dynamic>{'origin': '', 'name': 'd'},
  ];

  late Directory directory;
  late UsageReport backupReport;
  late UsageReport exportReport;

  setUpAll(() {
    directory = Directory.systemTemp.createTempSync('liber_source_usage');
    File('${directory.path}/backup.zip').writeAsBytesSync(
      zipOf(<String, Object?>{
        'bookSource.json': synthetic,
        'bookshelf.json': shelf,
      }),
    );
    File(
      '${directory.path}/bookSource.json',
    ).writeAsStringSync(jsonEncode(synthetic));
    backupReport = readUsageReport('${directory.path}/backup.zip');
    exportReport = readUsageReport('${directory.path}/bookSource.json');
  });

  tearDownAll(() => directory.deleteSync(recursive: true));

  test('the used set is the intersection, not the shelf rows', () {
    expect(backupReport.collectionCount, 4, reason: 'the whole collection');
    expect(backupReport.shelfEntryCount, 4, reason: 'shelf rows');
    expect(backupReport.originCount, 2, reason: 'distinct origins');
    expect(backupReport.usedCount, 1, reason: 'origins that resolve');
  });

  test('every §3 family has a predicate hit and a predicate miss', () {
    final hitAll = synthetic.first;
    final none = synthetic[1];
    final httpOnly = synthetic.last;
    for (final family in usageFamilies) {
      expect(family.matches(hitAll), isTrue, reason: '${family.row}: no hit');
      expect(
        family.matches(none),
        isFalse,
        reason: '${family.row}: matches a record that reaches nothing',
      );
      for (final predicate in family.predicates) {
        expect(
          predicate.matches(hitAll) || predicate.matches(httpOnly),
          isTrue,
          reason: '${family.row} / ${predicate.label}: no hit',
        );
        expect(
          predicate.matches(none),
          isFalse,
          reason: '${family.row} / ${predicate.label}: no miss',
        );
      }
    }
  });

  test('each family is counted over the used set and the collection', () {
    expect(backupReport.families.length, 16);
    // The rows whose collection count is not the used record: the TLS scheme
    // covers every record with an `http(s)://` identity (the shelf-only one
    // included), and `bookUrlPattern` is reached by the shelf-only record.
    const extra = <String, int>{
      'bookUrlPattern': 2,
      'TLS per-source exception': 3,
    };
    for (final family in backupReport.families) {
      expect(family.used, 1, reason: family.row);
      expect(family.collection, extra[family.row] ?? 1, reason: family.row);
      for (final predicate in family.predicates) {
        expect(predicate.used, anyOf(0, 1), reason: predicate.label);
        expect(
          predicate.collection,
          lessThanOrEqualTo(2),
          reason: predicate.label,
        );
      }
    }
    final tls = _family(backupReport, 'TLS per-source exception');
    expect(tls.collection, 3);
    expect(tls.used, 1);
    expect(
      tls.predicates
          .firstWhere((predicate) => predicate.label.contains("'http://'"))
          .used,
      0,
    );
    expect(
      tls.predicates
          .firstWhere((predicate) => predicate.label.contains("'http://'"))
          .collection,
      1,
    );
  });

  test('a bare export carries no shelf, so the used column is n/a', () {
    expect(exportReport.backup.shelfMember, isNull);
    expect(exportReport.usedCount, isNull);
    expect(exportReport.collectionCount, 4);
    expect(
      renderUsageReport(exportReport),
      contains('used n/a (no shelf in the input)'),
    );
  });

  test('the report names the input, its digest and its members', () {
    final text = renderUsageReport(backupReport);
    expect(text, contains(backupReport.backup.sha256));
    expect(text, contains('collection: 4 records from bookSource.json'));
    expect(text, contains('4 entries, 2 distinct origins, 1 resolved'));
    expect(text, contains('bookshelf.json'));
  });

  test('the report reads out no record, URL, host, name or rule text', () {
    final text = renderUsageReport(backupReport);
    for (final secret in <String>[
      'used.example',
      'plain.host/unused',
      'shelf-only.example',
      'synthetic all-families',
      r'$.data[*]',
      "book.getVariable('x')",
      'div.book',
    ]) {
      expect(text, isNot(contains(secret)), reason: secret);
    }
  });
}

FamilyUsage _family(UsageReport report, String row) =>
    report.families.firstWhere((family) => family.row == row);

/// A ZIP of [members], values encoded as JSON unless they are already text.
Uint8List zipOf(Map<String, Object?> members) {
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
