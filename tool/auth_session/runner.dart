import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime;
import 'package:liber/source/native_library.dart';
import 'package:liber/source/registrable_domain.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/source/source_login.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';
import 'package:pointycastle/digests/sha256.dart';

/// Runs one phase of the frozen `AUTH-SESSION-01` corpus through the product:
/// the two sources' real login scripts and stages over the corpus' own replay
/// origins, the product's session jar and its space store in a scratch root.
///
/// Usage:
///   `dart run tool/auth_session/runner.dart seed <fjs.dll> <root> <report.json>`
///   `dart run tool/auth_session/runner.dart restart <fjs.dll> <root> <report.json>`
///
/// `seed` requires a root that does not exist yet, retains it with an
/// `owner.json`, and `restart` is a second, terminated Dart process that
/// validates that owner before opening the space, reads the cookie/login state
/// before any request, and removes the whole root.
const authSessionCorpusPath = 'tool/auth_session/fixtures.json';

/// The corpus paths of `enabledCookieJar` on and off: the phase must exercise
/// both, as the frozen corpus declares.
const authSessionJarOnSourceId = 'A';
const authSessionJarOffSourceId = 'B';

/// A corpus, library or ownership problem: nothing was run, so the target
/// capture is left exactly as it was.
class AuthSessionRefusal implements Exception {
  const AuthSessionRefusal(this.message);
  final String message;
  @override
  String toString() => message;
}

class _Options {
  String? expectedCorpusSha256;
}

String sha256Bytes(List<int> bytes) => SHA256Digest()
    .process(Uint8List.fromList(bytes))
    .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
    .join();

String sha256Text(String text) => sha256Bytes(utf8.encode(text));

String sha256File(File file) => sha256Bytes(file.readAsBytesSync());

/// The corpus pin both lanes record: CRLF-normalised bytes, so one pin names
/// the same corpus on an LF and a Windows checkout.
String authSessionCorpusSha256Lf(File file) =>
    sha256Text(file.readAsStringSync().replaceAll('\r\n', '\n'));

Map<String, dynamic> _object(Object? value, String what) {
  if (value is Map) return value.cast<String, dynamic>();
  throw FormatException('$what is not a JSON object');
}

List<dynamic> _array(Object? value, String what) {
  if (value is List) return value;
  throw FormatException('$what is not a JSON array');
}

String _text(Object? value, String what) {
  final text = value is String ? value.trim() : '';
  if (text.isEmpty) throw FormatException('$what is empty');
  return text;
}

int _integer(Object? value, String what) {
  if (value is int) return value;
  throw FormatException('$what is not an integer');
}

Map<String, dynamic> loadAuthSessionCorpus([
  String path = authSessionCorpusPath,
]) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('auth-session corpus missing: $path');
  }
  final corpus = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  validateAuthSessionCorpus(corpus);
  return corpus;
}

/// Structural validation shared by the runner and the comparator: the declared
/// case graph, the pinned target, the two origins and the per-phase request and
/// response sets. A response body or a source-derived note is never an
/// expected value here.
void validateAuthSessionCorpus(Map<String, dynamic> corpus) {
  if (corpus['schemaVersion'] != 1) {
    throw const FormatException('auth-session corpus schemaVersion is not 1');
  }
  _text(corpus['fixtureId'], 'fixtureId');
  _integer(corpus['corpusVersion'], 'corpusVersion');
  _text(corpus['baselineCommit'], 'baselineCommit');
  _text(corpus['entryPoint'], 'entryPoint');
  authSessionTargetOf(corpus);
  final origins = _object(corpus['origins'], 'origins');
  if (origins.length != 2) {
    throw const FormatException('the corpus declares exactly two origins');
  }
  for (final entry in origins.entries) {
    final origin = Uri.tryParse(_text(entry.value, 'origin ${entry.key}'));
    if (origin == null || origin.scheme != 'http' || origin.host.isEmpty) {
      throw FormatException('origin ${entry.key} is not an http origin');
    }
    if (origin.path.isEmpty || origin.path == '/') {
      throw FormatException('origin ${entry.key} has no source path');
    }
  }
  final scratch = _object(corpus['scratch'], 'scratch');
  _text(scratch['rootName'], 'scratch.rootName');

  final sources = _array(corpus['sources'], 'sources').cast<Map>();
  if (sources.isEmpty) throw const FormatException('corpus has no sources');
  final sourceIds = <String>{};
  final jarFlags = <bool>{};
  for (final raw in sources) {
    final source = raw.cast<String, dynamic>();
    final id = _text(source['id'], 'source.id');
    if (!sourceIds.add(id)) throw FormatException('duplicate source id: $id');
    final object = _object(source['bookSource'], 'source $id bookSource');
    final url = _text(object['bookSourceUrl'], 'source $id bookSourceUrl');
    if (Uri.tryParse(url)?.hasScheme != true) {
      throw FormatException('source $id bookSourceUrl is not absolute');
    }
    final flag = object['enabledCookieJar'];
    if (flag is! bool) {
      throw FormatException('source $id has no enabledCookieJar flag');
    }
    jarFlags.add(flag);
    if (source['jsLib'] is! String) {
      throw FormatException('source $id has no jsLib text');
    }
    for (final rule in [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      _object(object[rule], 'source $id $rule');
    }
    if (_text(object['loginUrl'], 'source $id loginUrl').isEmpty) {
      throw FormatException('source $id has no loginUrl');
    }
  }
  if (jarFlags.length != 2) {
    throw const FormatException(
      'the corpus must cover enabledCookieJar on and off',
    );
  }

  final books = _array(corpus['books'], 'books').cast<Map>();
  if (books.isEmpty) throw const FormatException('corpus has no books');
  final bookIds = <String>{};
  final bookUrls = <String>{};
  for (final raw in books) {
    final book = raw.cast<String, dynamic>();
    final id = _text(book['id'], 'book.id');
    if (!bookIds.add(id)) throw FormatException('duplicate book id: $id');
    if (!sourceIds.contains('${book['source']}')) {
      throw FormatException('book $id names an unknown source');
    }
    final bookUrl = _text(book['bookUrl'], 'book $id bookUrl');
    if (Uri.tryParse(bookUrl)?.hasScheme != true || !bookUrls.add(bookUrl)) {
      throw FormatException('book $id has no unique absolute bookUrl');
    }
  }

  final responses = _array(corpus['responses'], 'responses').cast<Map>();
  if (responses.isEmpty) throw const FormatException('corpus has no responses');
  final responseIds = <String>{};
  for (final raw in responses) {
    final response = raw.cast<String, dynamic>();
    if (!responseIds.add(_text(response['id'], 'response.id'))) {
      throw const FormatException('duplicate response id');
    }
    _text(response['method'], 'response.method');
    final path = _text(response['path'], 'response.path');
    if (!path.startsWith('/')) {
      throw FormatException('response ${response['id']} path is not absolute');
    }
    if (response['rawQuery'] is! String) {
      throw FormatException(
        'response ${response['id']} declares no raw query bytes',
      );
    }
    if (response['body'] is! String) {
      throw FormatException('response ${response['id']} has no body');
    }
  }

  final phases = _object(corpus['phases'], 'phases');
  for (final phase in ['seed', 'restart']) {
    final section = _object(phases[phase], 'phases.$phase');
    final steps = _array(section['steps'], 'phases.$phase.steps').cast<Map>();
    if (steps.isEmpty) throw FormatException('phase $phase has no steps');
    final expected = _array(
      section['expectedRequests'],
      'phases.$phase.expectedRequests',
    ).cast<Map>();
    if (expected.isEmpty) {
      throw FormatException('phase $phase has no declared requests');
    }
    for (final request in expected) {
      _text(request['method'], 'expected request method');
      final path = _text(request['path'], 'expected request path');
      if (!path.startsWith('/')) {
        throw const FormatException('expected request path is not absolute');
      }
      if (request['rawQuery'] is! String) {
        throw const FormatException('expected request has no raw query bytes');
      }
    }
    final ids = <String>{};
    for (final step in steps) {
      final id = _text(step['id'], 'step.id');
      if (!ids.add(id)) throw FormatException('duplicate step id: $id');
      authSessionStepValidation(corpus, phase, step.cast<String, dynamic>());
    }
    final declared = _text(section['cleanup'], 'phases.$phase.cleanup');
    if (declared != (phase == 'seed' ? 'retain' : 'remove')) {
      throw FormatException('phase $phase declares another cleanup');
    }
    authSessionResponsesForPhase(corpus, phase);
  }
}

/// One step's own shape: every referenced source, book and stage exists, and a
/// step that reads a cookie probe names a source the probe can read.
void authSessionStepValidation(
  Map<String, dynamic> corpus,
  String phase,
  Map<String, dynamic> step,
) {
  final id = '${step['id']}';
  final kind = _text(step['kind'], 'step $id kind');
  final sourceIds = {
    for (final raw in _array(corpus['sources'], 'sources'))
      '${(raw as Map)['id']}',
  };
  final bookIds = {
    for (final raw in _array(corpus['books'], 'books')) '${(raw as Map)['id']}',
  };
  List<String> sourcesOf(Map<String, dynamic> step) {
    if (step['sources'] != null) {
      final ids = [
        for (final raw in _array(step['sources'], 'step $id sources')) '$raw',
      ];
      if (ids.isEmpty || ids.any((id) => !sourceIds.contains(id))) {
        throw FormatException('step $id names an unknown source');
      }
      return ids;
    }
    final single = _text(step['source'], 'step $id source');
    if (!sourceIds.contains(single)) {
      throw FormatException('step $id names an unknown source');
    }
    return [single];
  }

  switch (kind) {
    case 'login':
      sourcesOf(step);
      _text(step['probeKey'], 'step $id probeKey');
      final info = _text(step['loginInfo'], 'step $id loginInfo');
      if (jsonDecode(info) is! Map) {
        throw FormatException('step $id loginInfo is not a JSON object');
      }
    case 'headerMap':
      sourcesOf(step);
    case 'stage':
      sourcesOf(step);
      final stage = _text(step['stage'], 'step $id stage');
      _text(step['checkKey'], 'step $id checkKey');
      if (!const {
        'search',
        'details',
        'toc',
        'content',
      }.contains(stage)) {
        throw FormatException('step $id has an unknown stage: $stage');
      }
      if (stage == 'search') {
        final declared = _array(step['books'], 'step $id books');
        if (declared.isEmpty || declared.any((book) => !bookIds.contains(book))) {
          throw FormatException('step $id names an unknown book');
        }
      } else if (!bookIds.contains('${step['book']}')) {
        throw FormatException('step $id names an unknown book');
      }
      if (stage == 'content') {
        _text(step['chapter'], 'step $id chapter');
      }
    case 'cookieState':
      sourcesOf(step);
    case 'cookieKeyRemoval':
      sourcesOf(step);
      final keys = _array(step['keys'], 'step $id keys');
      if (keys.isEmpty || keys.any((key) => key is! String || key.isEmpty)) {
        throw FormatException('step $id declares no cookie keys');
      }
    case 'removeLoginHeader':
      sourcesOf(step);
    case 'loginHeaderPut':
      sourcesOf(step);
      final header = _text(step['header'], 'step $id header');
      if (jsonDecode(header) is! Map) {
        throw FormatException('step $id header is not a JSON object');
      }
    case 'state':
      sourcesOf(step);
    default:
      throw FormatException('step $id has an unknown kind: $kind');
  }
}

/// The declared stage each request belongs to. A phase makes its requests in
/// step order, so every request names a declared step id and the stages never go
/// backwards; anything else is a trace that does not belong to this phase.
List<String> authSessionRequestStages(
  Map<String, dynamic> corpus,
  String phase,
  List<dynamic> requests,
  String path,
) {
  final steps = [for (final step in authSessionSteps(corpus, phase)) '${step['id']}'];
  final stages = <String>[];
  var index = 0;
  for (final raw in requests) {
    final request = _object(raw, '$path request');
    final stage = request['stage'];
    if (stage is! String || stage.isEmpty) {
      throw FormatException('$path request names no stage');
    }
    var found = index;
    while (found < steps.length && steps[found] != stage) {
      found++;
    }
    if (found >= steps.length) {
      throw FormatException('$path request names an undeclared stage $stage');
    }
    index = found;
    stages.add(stage);
  }
  return stages;
}

/// The frozen target pin, checked against the corpus' own baseline.
Map<String, dynamic> authSessionTargetOf(Map<String, dynamic> corpus) {
  final target = _object(corpus['target'], 'target');
  _text(target['package'], 'target.package');
  final apk = _text(target['apkSha256'], 'target.apkSha256');
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(apk)) {
    throw const FormatException('target.apkSha256 is not a SHA-256');
  }
  if (_text(target['baselineCommit'], 'target.baselineCommit') !=
      _text(corpus['baselineCommit'], 'baselineCommit')) {
    throw const FormatException('target pin names another baseline');
  }
  _text(target['manifest'], 'target.manifest');
  return target;
}

Map<String, dynamic> authSessionPhaseSection(
  Map<String, dynamic> corpus,
  String phase,
) {
  if (phase != 'seed' && phase != 'restart') {
    throw FormatException('unknown phase $phase');
  }
  return _object(
    _object(corpus['phases'], 'phases')[phase],
    'phases.$phase',
  );
}

List<Map<String, dynamic>> authSessionSteps(
  Map<String, dynamic> corpus,
  String phase,
) => [
  for (final step in _array(
    authSessionPhaseSection(corpus, phase)['steps'],
    'phases.$phase.steps',
  ))
    (step as Map).cast<String, dynamic>(),
];

List<Map<String, dynamic>> authSessionExpectedRequests(
  Map<String, dynamic> corpus,
  String phase,
) => [
  for (final request in _array(
    authSessionPhaseSection(corpus, phase)['expectedRequests'],
    'phases.$phase.expectedRequests',
  ))
    (request as Map).cast<String, dynamic>(),
];

/// The corpus' responses this phase serves.
///
/// The corpus declares no phase-scoped response: both phases read one table,
/// and a response is selected by its method, its path and the exact raw query
/// bytes the client sent. Two identical selectors are a refusal — there is no
/// precedence.
List<Map<String, dynamic>> authSessionResponsesForPhase(
  Map<String, dynamic> corpus,
  String phase,
) {
  final responses = [
    for (final raw in _array(corpus['responses'], 'responses').cast<Map>())
      raw.cast<String, dynamic>(),
  ];
  final seen = <String>{};
  for (final response in responses) {
    final selector =
        '${response['method']} ${response['path']}?${response['rawQuery']}';
    if (!seen.add(selector)) {
      throw FormatException('phase $phase has two responses for $selector');
    }
  }
  for (final request in authSessionExpectedRequests(corpus, phase)) {
    final selector =
        '${request['method']} ${request['path']}?${request['rawQuery']}';
    if (!seen.contains(selector)) {
      throw FormatException('phase $phase declares no response for $selector');
    }
  }
  return responses;
}

Map<String, dynamic> authSessionSourceOf(
  Map<String, dynamic> corpus,
  String id,
) {
  for (final raw in _array(corpus['sources'], 'sources')) {
    if ((raw as Map)['id'] == id) return raw.cast<String, dynamic>();
  }
  throw StateError('the corpus has no source $id');
}

Map<String, dynamic> authSessionBookOf(
  Map<String, dynamic> corpus,
  String id,
) {
  for (final raw in _array(corpus['books'], 'books')) {
    if ((raw as Map)['id'] == id) return raw.cast<String, dynamic>();
  }
  throw StateError('the corpus has no book $id');
}

/// The imported source object: the corpus keeps `jsLib` beside the Book Source
/// object, and the product's import carries it as the object's own field.
Map<String, dynamic> authSessionSourceObject(Map<String, dynamic> source) => {
  ...(source['bookSource'] as Map).cast<String, dynamic>(),
  'jsLib': source['jsLib'],
};

String authSessionSourceUrl(Map<String, dynamic> source) =>
    '${(source['bookSource'] as Map)['bookSourceUrl']}';

/// The frozen `JSONObject`/sorted-pairs view the device harness records for a
/// map observation: keys ascending, values stringified, a null value kept.
List<List<Object?>> authSessionMapPairs(Map<String, String?>? map) {
  if (map == null) return const [];
  final keys = map.keys.toList()..sort();
  return [
    for (final key in keys) [key, map[key]],
  ];
}

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/auth_session/runner.dart '
      '<seed|restart> <fjs.dll> <root> <report.json> '
      '[--expected-corpus-sha256=<sha256>]',
    );
    exitCode = 64;
    return;
  }
  final phase = args.first;
  if (phase != 'seed' && phase != 'restart') {
    stderr.writeln('unknown phase: $phase');
    exitCode = 64;
    return;
  }
  if (args.length < 4) {
    stderr.writeln('phase, library, root and report are required');
    exitCode = 64;
    return;
  }
  final libraryPath = args[1];
  final root = Directory(args[2]);
  final reportPath = args[3];
  final _Options options;
  try {
    options = _parseOptions(args.sublist(4));
  } on AuthSessionRefusal catch (error) {
    _writeReport(reportPath, {
      'schemaVersion': 1,
      'product': 'liber-auth-session-runner',
      'phase': phase,
      'status': 'refused',
      'analysisFailure': '$error',
    });
    exitCode = 2;
    return;
  }

  final evidence = _PhaseEvidence();
  final report = <String, Object?>{
    'schemaVersion': 1,
    'fixtureId': '',
    'corpusVersion': null,
    'baselineCommit': '',
    'entryPoint': '',
    'product': 'liber-auth-session-runner',
    'platform': Platform.operatingSystem,
    'phase': phase,
    'pid': pid,
    'runId': _newRunId(),
    'startedAt': DateTime.now().toUtc().toIso8601String(),
  };
  var result = 0;
  try {
    final corpusFile = File(authSessionCorpusPath);
    final corpus = loadAuthSessionCorpus(authSessionCorpusPath);
    final corpusLf = authSessionCorpusSha256Lf(corpusFile);
    if (options.expectedCorpusSha256 != null &&
        options.expectedCorpusSha256 != corpusLf) {
      throw const AuthSessionRefusal(
        'the working corpus bytes are not the pinned corpus',
      );
    }
    final target = authSessionTargetOf(corpus);
    final library = File(libraryPath);
    if (!library.existsSync()) {
      throw const AuthSessionRefusal('the native library does not exist');
    }
    final librarySha = sha256File(library);
    report.addAll({
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'identity': {
        'fixtureId': corpus['fixtureId'],
        'corpusVersion': corpus['corpusVersion'],
        'baselineCommit': corpus['baselineCommit'],
        'entryPoint': corpus['entryPoint'],
        'corpusPath': authSessionCorpusPath,
        'corpusRawSha256': sha256File(corpusFile),
        'corpusSha256Lf': corpusLf,
        'target': {
          'package': target['package'],
          'apkSha256': target['apkSha256'],
          'baselineCommit': target['baselineCommit'],
          'manifest': target['manifest'],
        },
        'library': {'path': libraryPath, 'sha256': librarySha},
        'runner': {
          'path': 'tool/auth_session/runner.dart',
          'sha256': sha256File(File('tool/auth_session/runner.dart')),
        },
      },
      'steps': [
        for (final step in authSessionSteps(corpus, phase)) step['id'],
      ],
      'measurement': {
        'application': 'SourceHostState over a Workspace space store',
        'login':
            'SourceLoginSession.submit (putSourceLoginInfo + the real '
            'loginUrl script) and its own header/loginInfo reads',
        'headers': 'the source.getHeaderMap binding over the real getHeaderMap',
        'stages': const [
          'openBookSourcePipeline.search',
          'openBookSourcePipeline.bookInfo',
          'openBookSourcePipeline.tableOfContents',
          'openBookSourcePipeline.chapter',
        ],
        'tocUrl':
            'the declared ruleBookInfo.tocUrl value the information stage '
            'carried (the frozen Book.tocUrl, BookInfo.kt:150-152 fallback), '
            'never a request of a later stage',
        'replay':
            'authSessionReplayServer, one listener per declared origin, '
            'selected by method, path and the exact raw query bytes',
        'cookieKeyRemoval':
            'SourceCookieJar.set with the remaining pairs: the frozen '
            'CookieManager.removeCookie(url, key) removes one key of the same '
            "site's jar, and the product's jar exposes replace, not per-key "
            'removal',
        'stateSurfaces': const [
          'source_cookies',
          'source_entries',
          'manifest.json (installation androidId)',
        ],
      },
    });
    await _runPhase(
      corpus: corpus,
      corpusLf: corpusLf,
      phase: phase,
      root: root,
      libraryPath: libraryPath,
      librarySha256: librarySha,
      report: report,
      evidence: evidence,
    );
    report['status'] = 'completed';
  } on AuthSessionRefusal catch (error) {
    report['status'] = 'refused';
    report['analysisFailure'] = '$error';
    result = 2;
  } on Object catch (error, stack) {
    report['status'] = 'failed';
    report['analysisFailure'] = '$error';
    report['analysisStack'] = '$stack';
    result = 1;
  }
  report.addAll(evidence.intoReport());
  report.putIfAbsent('analysisFailure', () => null);
  report['completedAt'] = DateTime.now().toUtc().toIso8601String();
  _writeReport(reportPath, report);
  if (result != 0) stderr.writeln(report['analysisFailure']);
  exitCode = result;
}

_Options _parseOptions(List<String> args) {
  final options = _Options();
  for (final arg in args) {
    const prefix = '--expected-corpus-sha256=';
    if (arg.startsWith(prefix)) {
      final value = arg.substring(prefix.length);
      if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
        throw const AuthSessionRefusal(
          '--expected-corpus-sha256 is not a SHA-256',
        );
      }
      options.expectedCorpusSha256 = value;
      continue;
    }
    throw AuthSessionRefusal('unknown runner argument: $arg');
  }
  return options;
}

String _newRunId() {
  final random = Random.secure();
  final token = List<int>.generate(
    16,
    (_) => random.nextInt(256),
  ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
  return '${DateTime.now().toUtc().toIso8601String()}-$token';
}

void _writeReport(String path, Map<String, Object?> report) {
  final file = File(path);
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
}

/// What one phase run collected. The phase's failure path still reports every
/// observation and request it actually reached.
class _PhaseEvidence {
  final observations = <Map<String, Object?>>[];
  final searchHits = <String, HtmlBook>{};
  final pendingInfo = <String, SourceBookInfo>{};
  final pendingChapters = <String, (HtmlBook, List<SourceChapter>)>{};
  final pipelines = <String, BookSourcePipeline>{};
  final isolation = <String, Object?>{};
  final cleanup = <String, Object?>{};
  final owner = <String, Object?>{};
  List<Map<String, Object?>> requests = const [];
  List<Map<String, Object?>> unmatched = const [];
  List<Map<String, Object?>> stageTrace = const [];
  Map<String, Object?> requestCheck = const {};
  Map<String, Object?> observationCheck = const {};
  Map<String, Object?> sessionTier = const {};

  Map<String, Object?> intoReport() => {
    'observations': observations,
    'observationCheck': observationCheck,
    'requests': requests,
    'unmatchedRequests': unmatched,
    'serverErrors': const <Object?>[],
    'stageTrace': stageTrace,
    'requestCheck': requestCheck,
    'isolation': isolation,
    'owner': owner,
    'cleanup': cleanup,
    'sessionTier': sessionTier,
  };
}

Future<void> _runPhase({
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String phase,
  required Directory root,
  required String libraryPath,
  required String librarySha256,
  required Map<String, Object?> report,
  required _PhaseEvidence evidence,
}) async {
  final seed = phase == 'seed';
  final startedAt = DateTime.now().toUtc();
  final ownerFile = File('${root.path}${Platform.pathSeparator}owner.json');
  Map<String, dynamic>? owner;
  String? ownerSha;
  if (seed) {
    if (root.existsSync()) {
      throw const AuthSessionRefusal(
        'seed root already exists; only a fresh root is seeded',
      );
    }
  } else {
    if (!root.existsSync()) {
      throw const AuthSessionRefusal('restart root does not exist');
    }
    if (!ownerFile.existsSync()) {
      throw const AuthSessionRefusal('restart root has no owner.json');
    }
    ownerSha = sha256File(ownerFile);
    owner = _validateOwner(
      jsonDecode(ownerFile.readAsStringSync()),
      corpus: corpus,
      corpusLf: corpusLf,
      librarySha256: librarySha256,
      root: root,
    );
  }

  final responses = authSessionResponsesForPhase(corpus, phase);
  final servers = <_AuthReplayServer>[];
  Workspace? workspace;
  SpaceStore? store;
  SourceHostState? hostState;
  var databaseClosed = false;
  var serversClosed = false;
  var nativeDisposed = false;
  Object? failure;
  try {
    final origins = _object(corpus['origins'], 'origins');
    for (final entry in origins.entries) {
      final origin = Uri.parse('${entry.value}');
      servers.add(
        await _AuthReplayServer.start(
          origin: origin,
          responses: [
            for (final response in responses)
              if ('${response['path']}'.startsWith(origin.path)) response,
          ],
        ),
      );
    }
    if (seed) {
      root.createSync(recursive: true);
    }
    workspace = await Workspace.open(root: root);
    if (!seed && !workspace.manifestFile.existsSync()) {
      throw const AuthSessionRefusal('restart root has no workspace manifest');
    }
    store = await workspace.openSpace();
    hostState = SourceHostState(
      persistence: SpaceHostStatePersistence(store),
    );
    final androidId = await workspace.androidId();
    if (seed) {
      final sources = await store.allSources();
      final cookies = await store.db.select(store.db.sourceCookies).get();
      if (sources.isNotEmpty || cookies.isNotEmpty) {
        throw StateError('seed root is not empty');
      }
    } else {
      await _verifyRestoredRoot(store: store, owner: owner!);
    }
    evidence.isolation.addAll({
      'root': root.path,
      'rootName': _rootName(root),
      'database':
          '${root.path}${Platform.pathSeparator}spaces'
          '${Platform.pathSeparator}default'
          '${Platform.pathSeparator}data.db',
      'workspaceManifest': '${root.path}${Platform.pathSeparator}manifest.json',
      'ownerFile': ownerFile.path,
      'rootExistedAtStart': !seed,
      'createdByThisRun': seed,
      'validatedOwner': !seed,
      'validatedOwnerSha256': ownerSha,
      'preferenceFilesOutsideRoot': const <String>[],
      'preferenceBoundary':
          'the product keeps cookies, login state and source variables in '
          'this one space database and the installation id in its manifest, '
          'both inside this root; the frozen capture names task-prefixed '
          'SharedPreferences outside its root, which the product has no '
          'counterpart for',
      'sessionTier':
          'the product jar has one storage shape; the frozen capture '
          'separates persistent cookies from process-memory session cookies '
          '(the recorded ADR 0011 §3 divergence)',
    });
    await NativeLibrary.initialize(libraryPath: libraryPath);
    final context = _PhaseContext(
      corpus: corpus,
      phase: phase,
      hostState: hostState,
      androidId: androidId,
      evidence: evidence,
      servers: servers,
    );
    for (final step in authSessionSteps(corpus, phase)) {
      await context.runStep(step, seed: seed);
    }
    evidence.sessionTier = await context.sessionTier();
  } on Object catch (error) {
    failure = error;
  }

  for (final server in servers) {
    try {
      await server.close();
    } on Object catch (error) {
      failure ??= error;
    }
  }
  serversClosed = servers.every((server) => server.closed);
  evidence.requests = List<Map<String, Object?>>.unmodifiable([
    for (final server in servers) ...server.requests,
  ]);
  evidence.unmatched = List<Map<String, Object?>>.unmodifiable([
    for (final server in servers) ...server.unmatched,
  ]);
  evidence.stageTrace = List<Map<String, Object?>>.unmodifiable([
    for (final server in servers) ...server.stageTrace,
  ]);
  try {
    await workspace?.close();
    databaseClosed = workspace != null;
  } on Object catch (error) {
    failure ??= error;
  }
  try {
    await InProcessSourceScriptRuntime.dispose();
    nativeDisposed = true;
  } on Object catch (error) {
    failure ??= error;
  }

  evidence.requestCheck = _requestCheck(corpus, phase, evidence.requests);
  evidence.observationCheck = _observationCheck(
    corpus,
    phase,
    evidence.observations,
  );

  var ownerWritten = false;
  var rootRetained = false;
  var rootRemoved = false;
  var rootAbsentAfter = false;
  var removalSkipped = '';
  if (failure == null && seed) {
    try {
      owner = _ownerManifest(
        corpus: corpus,
        corpusLf: corpusLf,
        librarySha256: librarySha256,
        root: root,
        seedRunId: '${report['runId']}',
        seedPid: pid,
      );
      _writeOwner(ownerFile, owner);
      ownerSha = sha256File(ownerFile);
      ownerWritten = true;
      rootRetained = root.existsSync();
    } on Object catch (error) {
      failure = error;
    }
  }
  if (failure == null && !seed) {
    try {
      root.deleteSync(recursive: true);
      rootRemoved = !root.existsSync();
      rootAbsentAfter = !root.existsSync();
      if (!rootRemoved) {
        throw StateError('the restart root could not be removed');
      }
    } on Object catch (error) {
      failure = error;
    }
  }
  if (failure != null) {
    if (seed && root.existsSync() && !ownerWritten) {
      try {
        root.deleteSync(recursive: true);
        rootRemoved = !root.existsSync();
        rootAbsentAfter = !root.existsSync();
      } on Object {
        removalSkipped = 'failed to remove the fresh seed root';
      }
    } else if (!seed) {
      removalSkipped = 'restart failure keeps the owned root for inspection';
      rootRetained = root.existsSync();
    } else {
      removalSkipped = 'failed seed root retained for inspection';
      rootRetained = root.existsSync();
    }
  }
  evidence.cleanup.addAll({
    'databaseClosed': databaseClosed,
    'serversClosed': serversClosed,
    'nativeLibraryDisposed': nativeDisposed,
    'ownerWritten': ownerWritten,
    'ownerSha256': ownerSha,
    'scratchRetained': rootRetained,
    'scratchRemoved': rootRemoved,
    'rootAbsentAfter': rootAbsentAfter,
    'removalSkipped': removalSkipped,
    'startedAt': startedAt.toIso8601String(),
  });
  evidence.owner.addAll({
    'validated': !seed,
    'written': ownerWritten,
    'sha256': ownerSha,
    'seedRunId': owner?['seedRunId'],
    'seedPid': owner?['seedPid'],
    'rootName': owner?['rootName'],
    'complete': owner?['complete'],
  });
  if (failure != null) throw failure;
}

/// One phase's live objects: the two replay listeners, the space's host state
/// and the pipelines one source at a time.
class _PhaseContext {
  _PhaseContext({
    required this.corpus,
    required this.phase,
    required this.hostState,
    required this.androidId,
    required this.evidence,
    required this.servers,
  });

  final Map<String, dynamic> corpus;
  final String phase;
  final SourceHostState hostState;
  final String androidId;
  final _PhaseEvidence evidence;
  final List<_AuthReplayServer> servers;

  /// The corpus step whose requests and observations are being recorded.
  String currentStage = '';

  Future<void> runStep(
    Map<String, dynamic> step, {
    required bool seed,
  }) async {
    final id = '${step['id']}';
    currentStage = id;
    for (final server in servers) {
      server.stage = id;
    }
    switch ('${step['kind']}') {
      case 'login':
        await _runLogin(step);
      case 'headerMap':
        await _runHeaderMap(step);
      case 'stage':
        await _runStage(step, seed: seed);
      case 'cookieState':
        evidence.observations.add({
          'id': id,
          'value': await _cookieState(step),
        });
      case 'cookieKeyRemoval':
        await _runCookieKeyRemoval(step);
      case 'removeLoginHeader':
        await _runRemoveLoginHeader(step);
      case 'loginHeaderPut':
        await _runLoginHeaderPut(step);
      case 'state':
        evidence.observations.add({'id': id, 'value': await _state(step)});
      default:
        throw StateError('unknown corpus step $id');
    }
  }

  Map<String, dynamic> _sourceOf(String id) =>
      authSessionSourceOf(corpus, id);

  String _sourceUrlOf(String id) => authSessionSourceUrl(_sourceOf(id));

  SourceLoginSession _loginSession(
    String sourceId, {
    required SourceHostState state,
  }) {
    final source = _sourceOf(sourceId);
    return SourceLoginSession(
      source: authSessionSourceObject(source),
      hostState: state,
      androidId: androidId,
      transport: HttpSourceTransport(),
    );
  }

  BookSourcePipeline _pipeline(String sourceId) {
    final source = _sourceOf(sourceId);
    return evidence.pipelines.putIfAbsent(
      sourceId,
      () => openBookSourcePipeline(
        authSessionSourceObject(source),
        HttpSourceTransport(),
        hostState: hostState,
        androidId: androidId,
      ),
    );
  }

  /// One source's stored `loginHeader_<key>` and its parsed map.
  Future<(String?, Map<String, String>?)> _loginHeader(String sourceRef) async {
    final header = await getSourceLoginHeader(hostState, sourceRef);
    return (header, sourceLoginMap(header));
  }

  Future<String> _probe(String sourceRef, String key) async {
    final value = await hostState.entry(sourceRef, 'v_${sourceRef}_$key');
    return value == null ? '' : '$value';
  }

  /// The frozen `BaseSource.getHeaderMap(false|true)` through the product's own
  /// `source.getHeaderMap` binding: there is no Dart-level member for the map,
  /// so the probe is the binding a rule script uses.
  Future<(Map<String, String?> noLogin, Map<String, String?> withLogin)>
  _headerMaps(String sourceId) async {
    final source = _sourceOf(sourceId);
    final runtime = InProcessSourceScriptRuntime(
      jsLib: source['jsLib'] as String? ?? '',
      androidId: androidId,
      hostState: hostState,
    );
    try {
      final value = await runtime.evaluate(
        source:
            "JSON.stringify([source.getHeaderMap(false),"
            " source.getHeaderMap(true)])",
        input: {
          'sourceKey': _sourceUrlOf(sourceId),
          'source': authSessionSourceObject(source),
        },
        timeout: const Duration(seconds: 30),
      );
      final decoded = jsonDecode('$value');
      if (decoded is! List || decoded.length != 2) {
        throw StateError('source.getHeaderMap did not answer two maps');
      }
      Map<String, String?> asMap(Object? raw) {
        final map = <String, String?>{};
        if (raw is Map) {
          for (final entry in raw.entries) {
            final value = entry.value;
            map['${entry.key}'] = value == null ? null : '$value';
          }
        }
        return map;
      }

      return (asMap(decoded[0]), asMap(decoded[1]));
    } finally {
      // The phase's own teardown disposes the engine pool; a probe that
      // disposed it here would end the runtimes the stages still hold.
    }
  }

  Future<void> _runLogin(Map<String, dynamic> step) async {
    final id = '${step['id']}';
    final sourceId = '${step['source']}';
    final sourceRef = _sourceUrlOf(sourceId);
    final session = _loginSession(sourceId, state: hostState);
    final rows = session.rows;
    final info = jsonDecode('${step['loginInfo']}') as Map;
    final put = await session.submit({
      for (final entry in info.entries) '${entry.key}': '${entry.value}',
    });
    final loginInfo = await session.loginInfo();
    final (header, headerMap) = await _loginHeader(sourceRef);
    evidence.observations.add({
      'id': id,
      'value': {
        'kind': 'login',
        'source': sourceId,
        'loginUi': [
          for (final row in rows)
            {'name': row.name, 'type': row.type, 'action': row.action},
        ],
        'putLoginInfo': put,
        // The frozen harness records a null map as JSON null and a present one
        // as its sorted pairs; an empty list is not the same observation.
        'loginInfo': loginInfo == null ? null : authSessionMapPairs(loginInfo),
        'loginOutcome': await _probe(sourceRef, '${step['probeKey']}'),
        'loginHeader': header,
        'loginHeaderMap': headerMap == null
            ? null
            : authSessionMapPairs(headerMap),
      },
    });
  }

  Future<void> _runHeaderMap(Map<String, dynamic> step) async {
    final sourceId = '${step['source']}';
    final sourceRef = _sourceUrlOf(sourceId);
    final (noLogin, withLogin) = await _headerMaps(sourceId);
    final (header, headerMap) = await _loginHeader(sourceRef);
    evidence.observations.add({
      'id': '${step['id']}',
      'value': {
        'kind': 'headerMap',
        'source': sourceId,
        'noLogin': authSessionMapPairs(noLogin),
        'withLogin': authSessionMapPairs(withLogin),
        'loginHeader': header,
        'loginHeaderMap': headerMap == null
            ? null
            : authSessionMapPairs(headerMap),
      },
    });
  }

  Future<void> _runStage(Map<String, dynamic> step, {required bool seed}) async {
    final id = '${step['id']}';
    final sourceId = '${step['source']}';
    final sourceRef = _sourceUrlOf(sourceId);
    final stage = '${step['stage']}';
    final pipeline = _pipeline(sourceId);
    final Map<String, Object?> value = {
      'kind': 'stage',
      'stage': stage,
      'source': sourceId,
    };
    switch (stage) {
      case 'search':
        final hits = await pipeline.search('${step['keyword']}');
        final declared = [for (final raw in step['books'] as List) '$raw'];
        if (hits.length != declared.length) {
          throw StateError(
            'search $id returned ${hits.length} results, corpus declares '
            '${declared.length}',
          );
        }
        final results = <Map<String, Object?>>[];
        for (var index = 0; index < declared.length; index++) {
          final bookId = declared[index];
          final book = authSessionBookOf(corpus, bookId);
          final hit = hits[index];
          if (hit.identityAddress != '${book['bookUrl']}') {
            throw StateError(
              'search $id result $index is ${hit.identityAddress}, '
              'corpus declares ${book['bookUrl']}',
            );
          }
          evidence.searchHits[bookId] = hit;
          results.add({
            'id': bookId,
            'name': hit.title,
            'author': hit.author,
            'kind': hit.kind,
            'bookUrl': hit.identityAddress,
          });
        }
        value['results'] = results;
      case 'details':
        final bookId = '${step['book']}';
        final hit = evidence.searchHits[bookId];
        if (hit == null) {
          throw StateError('details $id has no preceding search hit');
        }
        // The frozen `getBookInfoAwait` stage on its own: the information
        // request, its `loginCheckJs` and its rules. A details-only book (A3,
        // A9) stops here, exactly as the frozen scenario does, and the TOC
        // address is the value that stage carried.
        final info = await pipeline.bookInfo(hit);
        evidence.pendingInfo[bookId] = info;
        final carrier = info.book;
        value['book'] = bookId;
        value['bookUrl'] = carrier.identityAddress;
        value['name'] = carrier.title;
        value['author'] = carrier.author;
        value['intro'] = carrier.intro;
        value['latestChapterTitle'] = carrier.lastChapter;
        value['tocUrl'] = info.tocUrl;
      case 'toc':
        final bookId = '${step['book']}';
        final info = evidence.pendingInfo[bookId];
        if (info == null) {
          throw StateError('toc $id has no preceding details step');
        }
        // The frozen `getChapterListAwait` stage: its own request, its own
        // `loginCheckJs` and its own rules, continued from the information
        // result. It never repeats the information request.
        final (book, chapters) = await pipeline.tableOfContents(info);
        evidence.pendingChapters[bookId] = (book, chapters);
        value['book'] = bookId;
        value['chapters'] = [
          for (final chapter in chapters)
            {
              'url': chapter.address,
              'title': chapter.name,
              'tag': chapter.tag,
            },
        ];
      case 'content':
        final bookId = '${step['book']}';
        final pending = evidence.pendingChapters[bookId];
        if (pending == null) {
          throw StateError('content $id has no preceding toc step');
        }
        final chapterAddress = '${step['chapter']}';
        final chapter = pending.$2.firstWhere(
          (candidate) => candidate.address == chapterAddress,
          orElse: () => throw StateError(
            'content $id found no chapter $chapterAddress',
          ),
        );
        final body = await pipeline.chapter(chapter, book: pending.$1);
        value['book'] = bookId;
        value['chapter'] = chapterAddress;
        value['text'] = body.text;
      default:
        throw StateError('unknown corpus stage $stage');
    }
    value['check'] = await _probe(sourceRef, '${step['checkKey']}');
    evidence.observations.add({'id': id, 'value': value});
  }

  Future<Map<String, Object?>> _cookieProbe(String sourceId) async {
    final sourceRef = _sourceUrlOf(sourceId);
    // A fresh process reads what the store already holds first: this is the
    // restart probe's whole point, so it must happen before any request and
    // must not depend on one having loaded the state.
    await hostState.ready();
    final jar = hostState.cookiesFor(sourceRef);
    final effective = jar.cookiesFor(sourceRef);
    final (header, headerMap) = await _loginHeader(sourceRef);
    return {
      'url': sourceRef,
      'domain': registrableDomain(Uri.parse(sourceRef).host),
      'persistent': effective,
      'session': null,
      'effective': effective,
      'keys': authSessionCookiePairs(effective),
      'loginHeader': header,
      'loginHeaderMap': headerMap == null
          ? null
          : authSessionMapPairs(headerMap),
    };
  }

  Future<Map<String, Object?>> _cookieState(Map<String, dynamic> step) async {
    final value = <String, Object?>{'kind': 'cookieState'};
    for (final raw in step['sources'] as List) {
      value['$raw'] = await _cookieProbe('$raw');
    }
    return value;
  }

  Future<void> _runCookieKeyRemoval(Map<String, dynamic> step) async {
    final sourceId = '${step['source']}';
    final sourceRef = _sourceUrlOf(sourceId);
    final jar = hostState.cookiesFor(sourceRef);
    final keys = [for (final raw in step['keys'] as List) '$raw'];
    final before = await _cookieProbe(sourceId);
    // The jar's own order, kept: the remaining pairs are read from the live
    // header as it is and written back in the same order, so this declared
    // fixture action cannot reorder what it did not remove.
    final remaining = <String>[
      for (final part in jar.cookiesFor(sourceRef).split(';'))
        if (part.trim().isNotEmpty &&
            !keys.contains(part.trim().split('=').first))
          part.trim(),
    ];
    await jar.set(sourceRef, remaining.join('; '));
    final after = await _cookieProbe(sourceId);
    evidence.observations.add({
      'id': '${step['id']}',
      'value': {
        'kind': 'cookieKeyRemoval',
        'source': sourceId,
        'removed': keys,
        'before': before,
        'after': after,
      },
    });
  }

  Future<void> _runRemoveLoginHeader(Map<String, dynamic> step) async {
    final sourceId = '${step['source']}';
    final session = _loginSession(sourceId, state: hostState);
    final before = await _cookieProbe(sourceId);
    await session.removeLoginHeader();
    final after = await _cookieProbe(sourceId);
    evidence.observations.add({
      'id': '${step['id']}',
      'value': {
        'kind': 'removeLoginHeader',
        'source': sourceId,
        'before': before,
        'after': after,
      },
    });
  }

  Future<void> _runLoginHeaderPut(Map<String, dynamic> step) async {
    final sourceId = '${step['source']}';
    final sourceRef = _sourceUrlOf(sourceId);
    final before = await _cookieProbe(sourceId);
    await putSourceLoginHeader(
      hostState,
      sourceRef,
      '${step['header']}',
      hostState.cookiesFor(sourceRef),
    );
    final after = await _cookieProbe(sourceId);
    final (_, withLogin) = await _headerMaps(sourceId);
    evidence.observations.add({
      'id': '${step['id']}',
      'value': {
        'kind': 'loginHeaderPut',
        'source': sourceId,
        'before': before,
        'after': after,
        'withLogin': authSessionMapPairs(withLogin),
      },
    });
  }

  Future<Map<String, Object?>> _state(Map<String, dynamic> step) async {
    final loginHeaders = <String, Object?>{};
    final loginInfo = <String, Object?>{};
    final cookies = <String, Object?>{};
    for (final raw in step['sources'] as List) {
      final sourceId = '$raw';
      final sourceRef = _sourceUrlOf(sourceId);
      final (header, _) = await _loginHeader(sourceRef);
      loginHeaders[sourceId] = header;
      final info = await getSourceLoginInfoMap(hostState, sourceRef, androidId);
      loginInfo[sourceId] = info == null ? null : authSessionMapPairs(info);
      cookies[sourceId] = await _cookieProbe(sourceId);
    }
    return {
      'kind': 'state',
      'loginHeaders': loginHeaders,
      'loginInfo': loginInfo,
      'cookies': cookies,
    };
  }

  /// The product's own tier receipt: one storage shape per jar, so the frozen
  /// `sessions`/`persistent` split has no counterpart. Recorded once per phase
  /// beside the observations, never as a frozen value.
  Future<Map<String, Object?>> sessionTier() async {
    final sessions = <String, Object?>{};
    final persistent = <String, Object?>{};
    for (final raw in corpus['sources'] as List) {
      final sourceId = '${(raw as Map)['id']}';
      final sourceRef = _sourceUrlOf(sourceId);
      final effective = hostState.cookiesFor(sourceRef).cookiesFor(sourceRef);
      sessions[sourceId] = null;
      persistent[sourceId] = effective;
    }
    return {
      'tier': 'single',
      'sessions': sessions,
      'persistent': persistent,
      'note':
          'the product jar keeps one map (lib/source/source_host_state.dart, '
          'SourceCookieJar); the frozen capture separates persistent cookies '
          'from process-memory session cookies',
    };
  }
}

/// The sorted `name=value` pairs of one effective cookie header.
List<List<String>> authSessionCookiePairs(String cookie) {
  final pairs = <List<String>>[];
  for (final raw in cookie.split(';')) {
    final text = raw.trim();
    if (text.isEmpty) continue;
    final index = text.indexOf('=');
    if (index <= 0) continue;
    pairs.add([text.substring(0, index), text.substring(index + 1)]);
  }
  pairs.sort((left, right) => left[0].compareTo(right[0]));
  return pairs;
}

/// One declared origin's replay listener: it answers only the requests that
/// match a declared method, path and *exact* raw query, records every request
/// with the corpus step that made it, and refuses the rest.
class _AuthReplayServer {
  _AuthReplayServer._(this._server, this.origin, this._responses);

  static Future<_AuthReplayServer> start({
    required Uri origin,
    required List<Map<String, dynamic>> responses,
  }) async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(origin.host, origin.port);
    } on SocketException catch (error) {
      throw StateError(
        'the corpus origin $origin is busy: ${error.message}. The port is '
        'fixed because the source object is a compared input; stop whatever '
        'holds it instead of moving the corpus.',
      );
    }
    final instance = _AuthReplayServer._(server, origin, responses);
    server.listen(instance._handle);
    return instance;
  }

  final HttpServer _server;
  final Uri origin;
  final List<Map<String, dynamic>> _responses;

  final requests = <Map<String, Object?>>[];
  final unmatched = <Map<String, Object?>>[];
  final stageTrace = <Map<String, Object?>>[];

  /// The corpus step currently running, recorded with every request.
  String stage = '';

  bool _closed = false;

  bool get closed => _closed;

  Future<void> _handle(HttpRequest request) async {
    final body = request.method == 'POST'
        ? await utf8.decoder.bind(request).join()
        : '';
    final headers = <String, Object?>{};
    request.headers.forEach((name, values) {
      headers[name.toLowerCase()] = values.length == 1
          ? values.single
          : List<String>.from(values);
    });
    final bytes = utf8.encode(body);
    final observed = <String, Object?>{
      'listener': _server.address.address,
      'method': request.method,
      'target': request.uri.hasQuery
          ? '${request.uri.path}?${request.uri.query}'
          : request.uri.path,
      'path': request.uri.path,
      'rawQuery': request.uri.query,
      'query': request.uri.queryParameters,
      'headers': headers,
      'headerLines': _headerLines(request.headers),
      'body': body,
      'bodyLength': bytes.length,
      'bodySha256': sha256Bytes(bytes),
      'stage': stage,
    };
    requests.add(observed);
    stageTrace.add({
      'stage': stage,
      'listener': _server.address.address,
      'target': observed['target'],
    });
    final declared = _match(request.method, request.uri);
    if (declared == null) {
      unmatched.add(observed);
      request.response.statusCode = HttpStatus.notFound;
      request.response.headers.contentType = ContentType.text;
      request.response.add(utf8.encode('undeclared replay request'));
      await request.response.close();
      return;
    }
    request.response.statusCode = declared['status'] as int? ?? 200;
    final declaredHeaders =
        (declared['headers'] as Map?)?.cast<String, dynamic>() ?? const {};
    for (final entry in declaredHeaders.entries) {
      final name = entry.key.toLowerCase();
      if (name == 'content-length' || name == 'transfer-encoding') continue;
      if (name == 'content-type') {
        request.response.headers.contentType = ContentType.parse('${entry.value}');
      } else {
        request.response.headers.set(entry.key, '${entry.value}');
      }
    }
    for (final raw in (declared['setCookies'] as List?) ?? const <Object?>[]) {
      request.response.headers.add(HttpHeaders.setCookieHeader, '$raw');
    }
    request.response.add(utf8.encode(declared['body'] as String? ?? ''));
    await request.response.close();
  }

  /// The declared response for one request: the method, the path and the exact
  /// raw query bytes. The frozen harness matches the same three, so both sides
  /// answer a request identically.
  Map<String, dynamic>? _match(String method, Uri uri) {
    for (final response in _responses) {
      if (response['method'] != method) continue;
      if (response['path'] != uri.path) continue;
      if (response['rawQuery'] != uri.query) continue;
      return response;
    }
    return null;
  }

  Future<void> close() async {
    await _server.close(force: true);
    _closed = true;
  }
}

List<String> _headerLines(HttpHeaders headers) {
  final lines = <String>[];
  headers.forEach((name, values) {
    for (final value in values) {
      lines.add('${_headerCase(name)}: $value');
    }
  });
  return lines;
}

String _headerCase(String name) => [
  for (final part in name.split('-'))
    part.isEmpty ? part : '${part[0].toUpperCase()}${part.substring(1)}',
].join('-');

/// Restart must find the root the seed reported, not another one at the same
/// path: every pinned identity in `owner.json` is compared before the space is
/// opened.
Map<String, dynamic> _validateOwner(
  Object? decoded, {
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String librarySha256,
  required Directory root,
}) {
  final owner = _object(decoded, 'owner.json');
  final target = authSessionTargetOf(corpus);
  void same(Object? actual, Object? expected, String field) {
    if ('$actual' != '$expected') {
      throw AuthSessionRefusal('owner.json $field does not match this run');
    }
  }

  same(owner['fixtureId'], corpus['fixtureId'], 'fixtureId');
  same(owner['corpusVersion'], corpus['corpusVersion'], 'corpusVersion');
  same(owner['baselineCommit'], corpus['baselineCommit'], 'baselineCommit');
  same(owner['corpusSha256Lf'], corpusLf, 'corpusSha256Lf');
  same(owner['librarySha256'], librarySha256, 'librarySha256');
  same(owner['rootName'], _rootName(root), 'rootName');
  final pinned = _object(owner['target'], 'owner.json target');
  same(pinned['package'], target['package'], 'target.package');
  same(pinned['apkSha256'], target['apkSha256'], 'target.apkSha256');
  same(
    pinned['baselineCommit'],
    target['baselineCommit'],
    'target.baselineCommit',
  );
  if (owner['complete'] != true) {
    throw const AuthSessionRefusal('owner.json is not complete');
  }
  _text(owner['seedRunId'], 'owner.json seedRunId');
  if (_integer(owner['seedPid'], 'owner.json seedPid') <= 0) {
    throw const AuthSessionRefusal('owner.json seedPid is not a process');
  }
  final declaredSources = {
    for (final raw in _array(owner['sources'], 'owner.json sources'))
      '${(raw as Map)['id']}': '${raw['sha256']}',
  };
  final expectedSources = {
    for (final raw in _array(corpus['sources'], 'sources'))
      '${raw['id']}': sha256Text(
        jsonEncode(authSessionSourceObject((raw as Map).cast<String, dynamic>())),
      ),
  };
  if (_canonicalJson(declaredSources) != _canonicalJson(expectedSources)) {
    throw const AuthSessionRefusal(
      'owner.json names other sources than this corpus',
    );
  }
  for (final relative in ['manifest.json', 'spaces/default/data.db']) {
    if (!File(
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}',
    ).existsSync()) {
      throw AuthSessionRefusal('owned root is missing $relative');
    }
  }
  return owner;
}

/// The root's own host-surface rows must be the seed's run, not a leftover
/// another run left at this path.
///
/// The AUTH scenario opens its two sources as objects the corpus declares; it
/// imports no source into the space, so the root holds the seed's cookies and
/// cache entries keyed by those two source references and no `sources` row. The
/// check is that every persisted row belongs to one of the declared sources and
/// that each declared source left its own state behind.
Future<void> _verifyRestoredRoot({
  required SpaceStore store,
  required Map<String, dynamic> owner,
}) async {
  final declared = {
    for (final raw in owner['sources'] as List)
      '${(raw as Map)['bookSourceUrl']}',
  };
  final persistence = SpaceHostStatePersistence(store);
  final entries = await persistence.loadCache();
  final cookies = await persistence.loadCookies();
  final refs = <String>{
    for (final entry in entries) entry.sourceRef,
    for (final cookie in cookies)
      if (cookie.writerRef != null && cookie.writerRef!.isNotEmpty)
        cookie.writerRef!,
  };
  if (refs.isEmpty) {
    throw const AuthSessionRefusal(
      'the owned root holds no host-surface rows to continue from',
    );
  }
  final foreign = refs.difference(declared).toList()..sort();
  if (foreign.isNotEmpty) {
    throw AuthSessionRefusal(
      'the owned root holds rows of other sources than its owner.json names: '
      '${foreign.join(', ')}',
    );
  }
  final missing = declared.difference(refs).toList()..sort();
  if (missing.isNotEmpty) {
    throw AuthSessionRefusal(
      'the owned root has no host-surface rows for ${missing.join(', ')}',
    );
  }
}

Map<String, Object?> _ownerManifest({
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String librarySha256,
  required Directory root,
  required String seedRunId,
  required int seedPid,
}) {
  final target = authSessionTargetOf(corpus);
  return {
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'corpusPath': authSessionCorpusPath,
    'corpusSha256Lf': corpusLf,
    'corpusRawSha256': sha256File(File(authSessionCorpusPath)),
    'target': {
      'package': target['package'],
      'apkSha256': target['apkSha256'],
      'baselineCommit': target['baselineCommit'],
      'manifest': target['manifest'],
    },
    'librarySha256': librarySha256,
    'rootName': _rootName(root),
    'database': 'spaces/default/data.db',
    'workspaceManifest': 'manifest.json',
    'sources': [
      for (final raw in corpus['sources'] as List)
        {
          'id': raw['id'],
          'bookSourceUrl': authSessionSourceUrl(
            raw.cast<String, dynamic>(),
          ),
          'sha256': sha256Text(
            jsonEncode(authSessionSourceObject(raw.cast<String, dynamic>())),
          ),
        },
    ],
    'seedRunId': seedRunId,
    'seedPid': seedPid,
    'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    'complete': true,
  };
}

void _writeOwner(File file, Map<String, Object?> owner) {
  final temporary = File('${file.path}.tmp');
  temporary.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(owner)}\n',
    flush: true,
  );
  temporary.renameSync(file.path);
}

String _rootName(Directory root) {
  final normalized = root.absolute.path.replaceAll('\\', '/');
  return normalized.split('/').where((part) => part.isNotEmpty).last;
}

Map<String, Object?> _requestCheck(
  Map<String, dynamic> corpus,
  String phase,
  List<Map<String, Object?>> requests,
) {
  final expected = authSessionExpectedRequests(corpus, phase);
  final declared = [
    for (final request in expected)
      {
        'method': '${request['method']}',
        'path': '${request['path']}',
        'rawQuery': '${request['rawQuery']}',
      },
  ];
  final actual = [
    for (final request in requests)
      {
        'method': '${request['method']}',
        'path': '${request['path']}',
        'rawQuery': '${request['rawQuery']}',
      },
  ];
  int? mismatchIndex;
  String? mismatch;
  if (actual.length != declared.length) {
    mismatch = '${actual.length} requests, ${declared.length} declared';
  } else {
    for (var index = 0; index < declared.length; index++) {
      if (_canonicalJson(declared[index]) != _canonicalJson(actual[index])) {
        mismatchIndex = index;
        mismatch =
            '${_requestLine(actual[index])} does not match '
            '${_requestLine(declared[index])}';
        break;
      }
    }
  }
  final orderMatch =
      actual.length == declared.length &&
      List.generate(
        actual.length,
        (index) =>
            actual[index]['method'] == declared[index]['method'] &&
            actual[index]['path'] == declared[index]['path'],
      ).every((matched) => matched);
  return {
    'declared': declared,
    'declaredCount': declared.length,
    'actualCount': actual.length,
    'orderMatch': orderMatch,
    'match': mismatch == null,
    'mismatchIndex': mismatchIndex,
    'mismatch': mismatch,
  };
}

String _requestLine(Map<String, Object?> request) =>
    '${request['method']} ${request['path']}?${request['rawQuery']}';

Map<String, Object?> _observationCheck(
  Map<String, dynamic> corpus,
  String phase,
  List<Map<String, Object?>> observations,
) {
  final declared = [
    for (final step in authSessionSteps(corpus, phase)) '${step['id']}',
  ];
  final actual = [
    for (final observation in observations) '${observation['id']}',
  ];
  final declaredSet = declared.toSet();
  final actualSet = actual.toSet();
  final missing = declaredSet.difference(actualSet).toList();
  final extra = actualSet.difference(declaredSet).toList();
  final duplicates = <String>[
    for (final id in actualSet)
      if (actual.where((actualId) => actualId == id).length > 1) id,
  ];
  return {
    'declared': declared,
    'actual': actual,
    'missing': missing,
    'extra': extra,
    'duplicates': duplicates,
    'ordered': _canonicalJson(declared) == _canonicalJson(actual),
    'match':
        missing.isEmpty &&
        extra.isEmpty &&
        duplicates.isEmpty &&
        _canonicalJson(declared) == _canonicalJson(actual),
  };
}

String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((key) => '$key').toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}
