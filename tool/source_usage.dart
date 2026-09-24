// Static usage counter for the P5 audit's declared coverage gaps.
//
// `docs/compatibility/p5-windows-audit.md` §3 lists 16 in-v1 capability rows
// that have no differential fixture. What decides each row's disposition is
// whether the operator's **used** sources reach the capability at all, so this
// counter reports, per row, a count over the used set and a count over the
// whole collection. It is #71's method: the used set is the `bookshelf.json`
// `origin` values resolved against `bookSourceUrl`
// (`docs/compatibility/delivery-phases.md`, "The used-source set, and its
// caveats"); the collection is every `bookSource.json` record.
//
// Read-only and network-free: no request, no pipeline, no script, and no `fjs`
// library loaded or initialised (the mode never calls the runtime's
// `initialize`, so no native library and no `fjs.dll` is involved). It
// reads a Legado full backup (or a bare `bookSource.json` export) and reports
// counts only — never a source record, URL, host, name or rule text.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:pointycastle/export.dart';

/// One named predicate inside a family row. The predicates of a row are the
/// fields and tokens the row's capability is written with; the row itself
/// counts a record when any of them matches.
class UsagePredicate {
  const UsagePredicate(this.label, this.matches);

  /// What the predicate looks at, as it is reported.
  final String label;

  /// Whether [source] reaches the capability through this predicate.
  final bool Function(Map<String, dynamic> source) matches;
}

/// One row of `docs/compatibility/p5-windows-audit.md` §3.
class UsageFamily {
  UsageFamily(this.row, this.predicates, {this.note});

  /// The audit's own row name.
  final String row;

  /// The predicates counted for the row, in reporting order.
  final List<UsagePredicate> predicates;

  /// A limit of the static predicate, when the row's capability is not fully
  /// visible in an exported record. Reported verbatim.
  final String? note;

  /// Whether [source] reaches the row's capability.
  bool matches(Map<String, dynamic> source) =>
      predicates.any((predicate) => predicate.matches(source));
}

/// The 16 rows of §3, in its order, each with the exact predicates counted.
///
/// A token predicate searches every string value of the record, so it counts
/// call sites rather than demonstrated reliance and cannot see whether a
/// script really runs (delivery-phases.md, "Counting predicates"); the label
/// names the spelling searched for, not a parsed rule.
final List<UsageFamily> usageFamilies = <UsageFamily>[
  UsageFamily('Login flow (loginUrl, loginUi, loginCheckJs)', <UsagePredicate>[
    UsagePredicate('loginUrl non-empty', (s) => _nonEmptyField(s, 'loginUrl')),
    UsagePredicate('loginUi non-empty', (s) => _nonEmptyField(s, 'loginUi')),
    UsagePredicate(
      'loginCheckJs non-empty',
      (s) => _nonEmptyField(s, 'loginCheckJs'),
    ),
  ]),
  UsageFamily(
    'TOC markers (updateTime, isVolume, isVip, isPay)',
    <UsagePredicate>[
      UsagePredicate(
        'ruleToc.updateTime non-empty',
        (s) => _nonEmptyField(s, 'ruleToc.updateTime'),
      ),
      UsagePredicate(
        'ruleToc.isVolume non-empty',
        (s) => _nonEmptyField(s, 'ruleToc.isVolume'),
      ),
      UsagePredicate(
        'ruleToc.isVip non-empty',
        (s) => _nonEmptyField(s, 'ruleToc.isVip'),
      ),
      UsagePredicate(
        'ruleToc.isPay non-empty',
        (s) => _nonEmptyField(s, 'ruleToc.isPay'),
      ),
    ],
  ),
  UsageFamily('bookUrlPattern', <UsagePredicate>[
    UsagePredicate(
      'bookUrlPattern non-empty',
      (s) => _nonEmptyField(s, 'bookUrlPattern'),
    ),
  ]),
  UsageFamily('Source variables (getVariable/setVariable)', <UsagePredicate>[
    UsagePredicate(
      "token 'source.getVariable('",
      (s) => _containsToken(s, 'source.getVariable('),
    ),
    UsagePredicate(
      "token 'source.setVariable('",
      (s) => _containsToken(s, 'source.setVariable('),
    ),
  ]),
  UsageFamily('Local jsLib shared scope', <UsagePredicate>[
    UsagePredicate('jsLib non-empty', (s) => _nonEmptyField(s, 'jsLib')),
    UsagePredicate(
      'jsLib non-empty and not an http(s) URL',
      (s) =>
          _nonEmptyField(s, 'jsLib') &&
          !_field(
            s,
            'jsLib',
          ).toString().trim().toLowerCase().startsWith('http'),
    ),
  ]),
  UsageFamily(
    'Per-source concurrency and concurrentRate',
    <UsagePredicate>[
      UsagePredicate(
        'concurrentRate non-empty',
        (s) => _nonEmptyField(s, 'concurrentRate'),
      ),
      UsagePredicate(
        'ruleToc.nextTocUrl non-empty (the frozen multi-URL pagination branch)',
        (s) => _nonEmptyField(s, 'ruleToc.nextTocUrl'),
      ),
    ],
    note:
        'whether a pagination rule really returns several URLs is the '
        'runtime result shape, not the declared field',
  ),
  UsageFamily('enabledCookieJar parity', <UsagePredicate>[
    UsagePredicate(
      'enabledCookieJar is true',
      (s) => _field(s, 'enabledCookieJar') == true,
    ),
  ]),
  UsageFamily(
    'java multi-URL ajax/ajaxAll, header-string connect, getHeaderMap',
    <UsagePredicate>[
      UsagePredicate("token 'ajaxAll'", (s) => _containsToken(s, 'ajaxAll')),
      UsagePredicate(
        "token 'getHeaderMap'",
        (s) => _containsToken(s, 'getHeaderMap'),
      ),
      UsagePredicate(
        "token 'java.connect('",
        (s) => _containsToken(s, 'java.connect('),
      ),
    ],
    note:
        'the token is the call site; whether the call passes a header string '
        'rather than a map is the argument shape, not countable statically',
  ),
  UsageFamily(
    'book/chapter snapshots and the *Variable refusals',
    <UsagePredicate>[
      UsagePredicate("token 'book.'", (s) => _containsToken(s, 'book.')),
      UsagePredicate("token 'chapter.'", (s) => _containsToken(s, 'chapter.')),
      UsagePredicate(
        "token 'book.getVariable('/'book.putVariable('/"
        "'chapter.getVariable('/'chapter.putVariable('",
        (s) => _containsAnyToken(s, const <String>[
          'book.getVariable(',
          'book.putVariable(',
          'chapter.getVariable(',
          'chapter.putVariable(',
        ]),
      ),
    ],
    note:
        'a refused member reached by a used source is a compatibility finding '
        'in its own right; the token cannot tell a member call from a '
        'script-local binding of the same name',
  ),
  UsageFamily('toNumChapter Chinese numerals', <UsagePredicate>[
    UsagePredicate(
      "token 'toNumChapter'",
      (s) => _containsToken(s, 'toNumChapter'),
    ),
  ]),
  UsageFamily(
    'JSONPath filters and slices',
    <UsagePredicate>[
      UsagePredicate(
        'ruleSearch.bookList selects the JSON pipeline '
        "(lowercased '@json:', '\$.', '\$[')",
        isJsonRuleSource,
      ),
      UsagePredicate(
        "token '@json:' (case-insensitive, outside a JSON source too)",
        (s) => _containsToken(s, '@json:', caseInsensitive: true),
      ),
      UsagePredicate(
        "token '[?(' (a JSONPath filter)",
        (s) => _containsToken(s, '[?('),
      ),
      UsagePredicate(
        'a slice bracket (RegExp ``\\[\\s*-?\\d*\\s*:\\s*-?\\d*\\s*\\]``)',
        (s) => _matchesAnyString(s, _sliceBracket),
      ),
    ],
    note:
        'the filter and slice tokens are searched in every string, not '
        'only in a JSON-pipeline source, so those two sub-counts are an upper bound',
  ),
  UsageFamily(
    'Multi-URL page results and imageStyle',
    <UsagePredicate>[
      UsagePredicate(
        'ruleContent.imageStyle non-empty',
        (s) => _nonEmptyField(s, 'ruleContent.imageStyle'),
      ),
      UsagePredicate(
        'ruleContent.nextContentUrl non-empty',
        (s) => _nonEmptyField(s, 'ruleContent.nextContentUrl'),
      ),
      UsagePredicate(
        'ruleToc.nextTocUrl non-empty',
        (s) => _nonEmptyField(s, 'ruleToc.nextTocUrl'),
      ),
      UsagePredicate(
        'a rule* field that is a JSON array literal',
        _hasJsonArrayRuleField,
      ),
    ],
    note:
        'a multi-URL page result is a rule that returns a list; the declared '
        'fields above are where such a rule is written, and the returned shape '
        'is not countable statically',
  ),
  UsageFamily(
    'User-confirmed browser and captcha hatches '
    '(startBrowser*, getVerificationCode, openUrl)',
    <UsagePredicate>[
      UsagePredicate(
        "token 'startBrowser'",
        (s) => _containsToken(s, 'startBrowser'),
      ),
      UsagePredicate(
        "token 'getVerificationCode'",
        (s) => _containsToken(s, 'getVerificationCode'),
      ),
      UsagePredicate("token 'openUrl'", (s) => _containsToken(s, 'openUrl')),
    ],
  ),
  UsageFamily(
    'TLS per-source exception',
    <UsagePredicate>[
      UsagePredicate(
        "bookSourceUrl starts with 'https://'",
        (s) => _identityScheme(s, 'https://'),
      ),
      UsagePredicate(
        "bookSourceUrl starts with 'http://'",
        (s) => _identityScheme(s, 'http://'),
      ),
    ],
    note:
        'no source field declares a certificate exception: the scheme only '
        'shows that the source makes TLS requests at all, and the exception is '
        'the user grant the product stores',
  ),
  UsageFamily(
    'Named refusals, emulated androidId/getWebViewUA, bounded logs and toasts',
    <UsagePredicate>[
      UsagePredicate(
        "token 'androidId'",
        (s) => _containsToken(s, 'androidId'),
      ),
      UsagePredicate(
        "token 'getWebViewUA'",
        (s) => _containsToken(s, 'getWebViewUA'),
      ),
      UsagePredicate("token 'java.log'", (s) => _containsToken(s, 'java.log')),
      UsagePredicate(
        "token 'java.toast'",
        (s) => _containsToken(s, 'java.toast'),
      ),
    ],
    note:
        'a named refusal is reached by a token the product would refuse; the '
        'count is the call site, not a demonstrated failure',
  ),
  UsageFamily(
    'Host-surface cleanup on delete/re-point; a bound on persisted growth',
    <UsagePredicate>[
      UsagePredicate(
        "token 'java.put('",
        (s) => _containsToken(s, 'java.put('),
      ),
      UsagePredicate(
        "token 'java.get('",
        (s) => _containsToken(s, 'java.get('),
      ),
      UsagePredicate(
        "token 'cache.put'",
        (s) => _containsToken(s, 'cache.put'),
      ),
      UsagePredicate(
        "token 'cache.get'",
        (s) => _containsToken(s, 'cache.get'),
      ),
      UsagePredicate(
        "token 'cookie.setCookie'",
        (s) => _containsToken(s, 'cookie.setCookie'),
      ),
      UsagePredicate(
        "token 'cookie.getCookie'",
        (s) => _containsToken(s, 'cookie.getCookie'),
      ),
      UsagePredicate(
        "token 'source.setVariable('",
        (s) => _containsToken(s, 'source.setVariable('),
      ),
    ],
    note:
        'no source declaration reaches delete or re-point: these predicates '
        'count the records that write source-owned state, which is the state '
        'the cleanup and the bound act on',
  ),
];

/// The count of one predicate over one set.
class PredicateUsage {
  const PredicateUsage({
    required this.label,
    required this.used,
    required this.collection,
  });

  final String label;

  /// How many used sources match, or null when the input carries no shelf.
  final int? used;

  final int collection;
}

/// The count of one §3 row and of each predicate inside it.
class FamilyUsage {
  const FamilyUsage({
    required this.row,
    required this.note,
    required this.predicates,
    required this.used,
    required this.collection,
  });

  final String row;
  final String? note;
  final List<PredicateUsage> predicates;
  final int? used;
  final int collection;
}

/// Everything the report line and the table need.
class UsageReport {
  const UsageReport({
    required this.backup,
    required this.collectionCount,
    required this.shelfEntryCount,
    required this.originCount,
    required this.usedCount,
    required this.families,
  });

  /// The input the counts were read from, with its digest and its members.
  final SourceBackup backup;

  /// The report's provenance lines, as the input names them.
  List<String> get backupLines => sourceBackupLines(backup);

  final int collectionCount;
  final int shelfEntryCount;
  final int originCount;

  /// How many records the used set resolved to, or null without a shelf.
  final int? usedCount;

  final List<FamilyUsage> families;
}

/// The `bookshelf.json` `origin` values, as a set: an origin is matched to
/// `bookSourceUrl`, and a shelf row with no origin matches nothing.
Set<String> shelfOrigins(List<Map<String, dynamic>> shelf) => <String>{
  for (final row in shelf)
    if (row['origin'] is String && (row['origin']! as String).isNotEmpty)
      row['origin']! as String,
};

/// The used set: the records whose `bookSourceUrl` is a shelf origin.
///
/// The shelf rows themselves are not sources — the operator's own backup has
/// 1 419 rows over 192 origins, and 150 of those resolve to a record — so the
/// used set is the intersection, not the shelf.
List<Map<String, dynamic>> resolveUsedSources(
  List<Map<String, dynamic>> sources,
  List<Map<String, dynamic>> shelf,
) {
  final origins = shelfOrigins(shelf);
  return <Map<String, dynamic>>[
    for (final source in sources)
      if (origins.contains(source['bookSourceUrl'])) source,
  ];
}

/// Counts every family over [sources] and over [used].
///
/// [used] is null when the input carries no shelf, and every used count is
/// null with it.
List<FamilyUsage> countFamilies(
  List<Map<String, dynamic>> sources,
  List<Map<String, dynamic>>? used,
) => <FamilyUsage>[
  for (final family in usageFamilies)
    FamilyUsage(
      row: family.row,
      note: family.note,
      predicates: <PredicateUsage>[
        for (final predicate in family.predicates)
          PredicateUsage(
            label: predicate.label,
            used: used?.where(predicate.matches).length,
            collection: sources.where(predicate.matches).length,
          ),
      ],
      used: used?.where(family.matches).length,
      collection: sources.where(family.matches).length,
    ),
];

/// One static mode's input, as the reader below resolves it: the collection,
/// the shelf when the input carries one, and the digest of the bytes they were
/// read from.
class SourceBackup {
  const SourceBackup({
    required this.input,
    required this.sha256,
    required this.collectionMember,
    required this.shelfMember,
    required this.sources,
    required this.shelf,
  });

  /// The file the records were read from.
  final String input;

  /// The digest of that file, so a recorded count names the bytes it came from.
  final String sha256;

  /// Where the collection was read from: the archive member, or the input file
  /// itself when it is a bare export.
  final String collectionMember;

  /// Where the shelf was read from, or null when the input has none.
  final String? shelfMember;

  final List<Map<String, dynamic>> sources;

  /// The `bookshelf.json` rows, or null when the input carries no shelf.
  final List<Map<String, dynamic>>? shelf;
}

/// Reads [path] into its collection, its shelf and its digest.
///
/// A `.zip` is a Legado full backup, read through the product's own guarded
/// reader ([LegadoBackupArchive]): `bookSource.json` is the collection and
/// `bookshelf.json`, when the member exists, is the shelf. Any other file is a
/// bare `bookSource.json` export — a list of records, or a single record — and
/// carries no shelf, so the used counts are not available.
SourceBackup readSourceBackup(String path) {
  final bytes = File(path).readAsBytesSync();
  final sha256 = _sha256(bytes);
  if (LegadoBackupArchive.looksLikeZip(bytes)) {
    final archive = LegadoBackupArchive.decode(bytes);
    final collection = archive.member('bookSource.json');
    if (collection == null) {
      throw const FormatException('the backup carries no bookSource.json');
    }
    final sources = _records(utf8.decode(collection, allowMalformed: true));
    final shelfBytes = archive.member('bookshelf.json');
    final shelf = shelfBytes == null
        ? null
        : _records(utf8.decode(shelfBytes, allowMalformed: true));
    return SourceBackup(
      input: path,
      sha256: sha256,
      collectionMember: 'bookSource.json',
      shelfMember: shelf == null ? null : 'bookshelf.json',
      sources: sources,
      shelf: shelf,
    );
  }
  return SourceBackup(
    input: path,
    sha256: sha256,
    collectionMember: path,
    shelfMember: null,
    sources: _records(utf8.decode(bytes, allowMalformed: true)),
    shelf: null,
  );
}

/// The provenance every static mode's report opens with: the input, the digest
/// of its bytes, the member the collection came from and the shelf.
List<String> sourceBackupLines(SourceBackup backup) => <String>[
  'input: ${backup.input}',
  'sha256: ${backup.sha256}',
  'collection: ${backup.sources.length} records from '
      '${backup.collectionMember}',
  if (backup.shelf == null)
    'shelf: none — the input carries no bookshelf.json'
  else
    'shelf: ${backup.shelf!.length} entries, '
        '${shelfOrigins(backup.shelf!).length} distinct origins, '
        '${resolveUsedSources(backup.sources, backup.shelf!).length} resolved '
        'used records from ${backup.shelfMember}',
];

/// Reads [path] and counts every family.
UsageReport readUsageReport(String path) => _report(readSourceBackup(path));

/// The report as text: counts only, and the note of any family whose
/// capability the static predicate cannot capture.
String renderUsageReport(UsageReport report) {
  final lines = <String>[
    'static Book Source usage — network-free, counts only; '
        'no source record, URL, host, name or rule text is read out',
    ...report.backupLines,
    '',
  ];
  for (var index = 0; index < report.families.length; index++) {
    final family = report.families[index];
    lines.add(
      '[${index + 1}] ${family.row}   '
      'used ${_count(family.used, report)}   '
      'collection ${family.collection}/${report.collectionCount}',
    );
    final width = family.predicates.fold<int>(
      0,
      (value, predicate) =>
          predicate.label.length > value ? predicate.label.length : value,
    );
    for (final predicate in family.predicates) {
      lines.add(
        '    ${predicate.label.padRight(width)}   '
        'used ${_count(predicate.used, report)}   '
        'collection ${predicate.collection}/${report.collectionCount}',
      );
    }
    if (family.note != null) lines.add('    note: ${family.note}');
  }
  return '${lines.join('\n')}\n';
}

UsageReport _report(SourceBackup backup) {
  final used = backup.shelf == null
      ? null
      : resolveUsedSources(backup.sources, backup.shelf!);
  return UsageReport(
    backup: backup,
    collectionCount: backup.sources.length,
    shelfEntryCount: backup.shelf?.length ?? 0,
    originCount: backup.shelf == null
        ? 0
        : shelfOrigins(backup.shelf!).length,
    usedCount: used?.length,
    families: countFamilies(backup.sources, used),
  );
}

String _count(int? used, UsageReport report) =>
    used == null ? 'n/a (no shelf in the input)' : '$used/${report.usedCount}';

/// A decoded `bookSource.json` or `bookshelf.json`: an array of JSON objects.
/// A member that is not an array, or an entry that is not an object, is
/// refused by name rather than counted as something it is not.
List<Map<String, dynamic>> _records(String text) {
  final Object? decoded;
  try {
    decoded = jsonDecode(text);
  } on FormatException catch (error) {
    throw FormatException('not JSON: ${error.message}');
  }
  final entries = decoded is List ? decoded : <Object?>[decoded];
  if (entries.isEmpty || entries.any((entry) => entry is! Map)) {
    throw const FormatException('not an array of JSON objects');
  }
  return <Map<String, dynamic>>[
    for (final entry in entries) Map<String, dynamic>.from(entry! as Map),
  ];
}

/// A field at an `a.b` path, or null when a segment is missing.
Object? _field(Map<String, dynamic> source, String path) {
  Object? current = source;
  for (final segment in path.split('.')) {
    if (current is! Map) return null;
    current = current[segment];
  }
  return current;
}

/// Whether the `a.b` field is a non-blank string: presence is not use.
bool _nonEmptyField(Map<String, dynamic> source, String path) {
  final value = _field(source, path);
  return value is String && value.trim().isNotEmpty;
}

/// Whether the record's identity URL begins with [scheme].
bool _identityScheme(Map<String, dynamic> source, String scheme) =>
    '${source['bookSourceUrl'] ?? ''}'.startsWith(scheme);

/// Whether any string value of [source] contains [token].
bool _containsToken(
  Map<String, dynamic> source,
  String token, {
  bool caseInsensitive = false,
}) => _matchesAnyString(
  source,
  RegExp(RegExp.escape(token), caseSensitive: !caseInsensitive),
);

bool _containsAnyToken(Map<String, dynamic> source, List<String> tokens) =>
    tokens.any((token) => _containsToken(source, token));

bool _matchesAnyString(Object? value, RegExp pattern) {
  if (value is String) return pattern.hasMatch(value);
  if (value is Map) {
    return value.values.any((v) => _matchesAnyString(v, pattern));
  }
  if (value is Iterable) return value.any((v) => _matchesAnyString(v, pattern));
  return false;
}

/// A JSONPath slice bracket, `[1:2]` or `[:2]` or `[1:]`.
final RegExp _sliceBracket = RegExp(r'\[\s*-?\d*\s*:\s*-?\d*\s*\]');

/// Whether any `rule*` field is a string that parses as a JSON array literal.
///
/// Only the rule fields are searched: `exploreUrl` is itself a JSON array of
/// categories in many records, which is not a multi-URL page result.
bool _hasJsonArrayRuleField(Map<String, dynamic> source) {
  for (final entry in source.entries) {
    if (!entry.key.startsWith('rule')) continue;
    final rules = entry.value;
    if (rules is! Map) continue;
    for (final rule in rules.values) {
      if (rule is! String) continue;
      final text = rule.trim();
      if (!text.startsWith('[') || !text.endsWith(']')) continue;
      Object? parsed;
      try {
        parsed = jsonDecode(text);
      } on FormatException {
        continue;
      }
      if (parsed is List) return true;
    }
  }
  return false;
}

String _sha256(Uint8List bytes) => SHA256Digest()
    .process(bytes)
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();
