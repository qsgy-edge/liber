import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart'
    show InProcessSourceScriptRuntime, variableMapOf;
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_host_state.dart' show SourceCacheEntry;
import 'package:liber/store/host_state.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';
import 'package:liber/store/workspace.dart';
import 'package:pointycastle/digests/sha256.dart';

import '../first_slice/runner.dart' show SliceReplayServer;

/// Runs one phase of the frozen `STATE-SESSION-01` corpus through the product:
/// `openBookSourcePipeline` over the corpus' real replay origin, the shelf's
/// own publication, and a space database in a scratch root.
///
/// Usage:
///   `dart run tool/state_session/runner.dart seed <fjs.dll> <root> <report.json>`
///   `dart run tool/state_session/runner.dart restart <fjs.dll> <root> <report.json>`
///
/// `seed` requires a root that does not exist yet, retains it with an
/// `owner.json`, and `restart` is a second, terminated Dart process that
/// validates that owner before opening the database, refreshes A1/B1 and
/// removes the whole root. `/state-session` reuses the corpus server the
/// first-slice lane already runs, filtered to the phase's active responses.
const stateSessionCorpusPath = 'tool/state_session/fixtures.json';

const stateSessionJavaPolicyKeys = <String>['policyJava.A', 'policyJava.B'];

/// A corpus, library or ownership problem: nothing was run, so the target
/// capture is left exactly as it was. Distinct from a stage failure, which is
/// this invocation's own to clean up.
class StateSessionRefusal implements Exception {
  const StateSessionRefusal(this.message);
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

/// The corpus pin the device harness records: CRLF-normalised bytes, so one pin
/// names the same corpus on an LF and a Windows checkout.
String stateSessionCorpusSha256Lf(File file) =>
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

/// Decodes and validates the frozen corpus far enough that every later step,
/// request and response selection is complete; a malformed corpus is refused
/// before anything runs.
Map<String, dynamic> loadStateSessionCorpus([
  String path = stateSessionCorpusPath,
]) {
  final file = File(path);
  if (!file.existsSync()) {
    throw StateError('state-session corpus missing: $path');
  }
  final corpus = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  validateStateSessionCorpus(corpus);
  return corpus;
}

/// Structural validation shared by the runner and the comparator. It checks
/// the declared case graph, the pinned target and the phase response sets; it
/// never treats a response body or a source-derived note as an expected value.
void validateStateSessionCorpus(Map<String, dynamic> corpus) {
  if (corpus['schemaVersion'] != 1) {
    throw const FormatException('state-session corpus schemaVersion is not 1');
  }
  _text(corpus['fixtureId'], 'fixtureId');
  _integer(corpus['corpusVersion'], 'corpusVersion');
  _text(corpus['baselineCommit'], 'baselineCommit');
  _text(corpus['entryPoint'], 'entryPoint');
  _text(corpus['keyword'], 'keyword');
  final origin = Uri.tryParse(_text(corpus['origin'], 'origin'));
  if (origin == null || origin.scheme != 'http' || origin.host.isEmpty) {
    throw const FormatException('state-session origin is not an http origin');
  }
  stateSessionTargetOf(corpus);

  final sources = _array(corpus['sources'], 'sources').cast<Map>();
  if (sources.isEmpty) throw const FormatException('corpus has no sources');
  final sourceIds = <String>{};
  for (final raw in sources) {
    final source = raw.cast<String, dynamic>();
    final id = _text(source['id'], 'source.id');
    if (!sourceIds.add(id)) {
      throw FormatException('duplicate source id: $id');
    }
    final object = _object(source['bookSource'], 'source $id bookSource');
    final url = _text(object['bookSourceUrl'], 'source $id bookSourceUrl');
    if (Uri.tryParse(url)?.hasScheme != true) {
      throw FormatException('source $id bookSourceUrl is not absolute');
    }
    if (source['jsLib'] is! String || '${source['jsLib']}'.isEmpty) {
      throw FormatException('source $id has no jsLib');
    }
    for (final rule in [
      'ruleSearch',
      'ruleBookInfo',
      'ruleToc',
      'ruleContent',
    ]) {
      _object(object[rule], 'source $id $rule');
    }
  }

  final books = _array(corpus['books'], 'books').cast<Map>();
  if (books.isEmpty) throw const FormatException('corpus has no books');
  final bookIds = <String>{};
  final bookUrls = <String>{};
  for (final raw in books) {
    final book = raw.cast<String, dynamic>();
    final id = _text(book['id'], 'book.id');
    if (!bookIds.add(id)) throw FormatException('duplicate book id: $id');
    final sourceId = _text(book['source'], 'book $id source');
    if (!sourceIds.contains(sourceId)) {
      throw FormatException('book $id names an unknown source');
    }
    final bookUrl = _text(book['bookUrl'], 'book $id bookUrl');
    if (Uri.tryParse(bookUrl)?.hasScheme != true || !bookUrls.add(bookUrl)) {
      throw FormatException('book $id has no unique absolute bookUrl');
    }
    final index = _integer(book['searchIndex'], 'book $id searchIndex');
    if (index < 0) throw FormatException('book $id searchIndex is negative');
    if (_array(book['chapterUrls'], 'book $id chapterUrls').isEmpty) {
      throw FormatException('book $id has no chapterUrls');
    }
  }

  final cacheKeys = _array(corpus['cacheKeys'], 'cacheKeys');
  if (cacheKeys.isEmpty || cacheKeys.any((key) => key is! String)) {
    throw const FormatException('corpus cacheKeys are incomplete');
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
    _text(response['path'], 'response.path');
    final phase = response['phase'];
    if (phase != null && phase != 'seed' && phase != 'restart') {
      throw FormatException(
        'response ${response['id']} names an unknown phase',
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
      _text(request['path'], 'expected request path');
    }
    final ids = <String>{};
    for (var index = 0; index < steps.length; index++) {
      final step = steps[index];
      final id = _text(step['id'], 'step.id');
      if (!ids.add(id)) throw FormatException('duplicate step id: $id');
      final kind = _text(step['kind'], 'step $id kind');
      switch (kind) {
        case 'search':
          if (!sourceIds.contains('${step['source']}')) {
            throw FormatException('search $id names an unknown source');
          }
          final declared = _array(step['books'], 'search $id books');
          if (declared.isEmpty ||
              declared.any((book) => !bookIds.contains(book))) {
            throw FormatException('search $id names an unknown book');
          }
        case 'details':
          final bookId = _text(step['book'], 'details $id book');
          if (!bookIds.contains(bookId)) {
            throw FormatException('details $id names an unknown book');
          }
          if (step['from'] != 'search' && step['from'] != 'row') {
            throw FormatException('details $id has no valid source');
          }
          final next = index + 1 < steps.length ? steps[index + 1] : null;
          if (next == null || next['kind'] != 'toc' || next['book'] != bookId) {
            throw FormatException('details $id is not followed by its own toc');
          }
        case 'toc':
          if (!bookIds.contains('${step['book']}')) {
            throw FormatException('toc $id names an unknown book');
          }
          _integer(step['revision'], 'toc $id revision');
        case 'content':
          if (!bookIds.contains('${step['book']}')) {
            throw FormatException('content $id names an unknown book');
          }
          _text(step['chapter'], 'content $id chapter');
        case 'state':
          if (!const {
            'books',
            'chapters',
            'caches',
          }.contains(step['surface'])) {
            throw FormatException('state $id has an unknown surface');
          }
        default:
          throw FormatException('step $id has an unknown kind: $kind');
      }
    }
    stateSessionCorpusForPhase(corpus, phase);
  }
}

/// The frozen target pin, checked against the corpus' own baseline.
Map<String, dynamic> stateSessionTargetOf(Map<String, dynamic> corpus) {
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

List<Map<String, dynamic>> stateSessionSteps(
  Map<String, dynamic> corpus,
  String phase,
) {
  final section = _object(
    _object(corpus['phases'], 'phases')[phase],
    'phases.$phase',
  );
  return [
    for (final step in _array(section['steps'], 'phases.$phase.steps'))
      (step as Map).cast<String, dynamic>(),
  ];
}

List<Map<String, dynamic>> stateSessionExpectedRequests(
  Map<String, dynamic> corpus,
  String phase,
) {
  final section = _object(
    _object(corpus['phases'], 'phases')[phase],
    'phases.$phase',
  );
  return [
    for (final request in _array(
      section['expectedRequests'],
      'phases.$phase.expectedRequests',
    ))
      (request as Map).cast<String, dynamic>(),
  ];
}

/// The responses this phase may serve: the common ones plus its own.
List<Map<String, dynamic>> activeStateSessionResponses(
  Map<String, dynamic> corpus,
  String phase,
) {
  final active = <Map<String, dynamic>>[
    for (final raw in _array(corpus['responses'], 'responses').cast<Map>())
      if (raw['phase'] == null || raw['phase'] == phase)
        raw.cast<String, dynamic>(),
  ];
  if (active.isEmpty) {
    throw FormatException('phase $phase has no active responses');
  }
  // No precedence: two responses for one selector, or a wildcard beside an
  // exact query on the same path, are ambiguous and refused.
  final byPath = <String, List<Map<String, dynamic>>>{};
  for (final response in active) {
    byPath
        .putIfAbsent('${response['method']} ${response['path']}', () => [])
        .add(response);
  }
  for (final entry in byPath.entries) {
    final group = entry.value;
    for (var i = 0; i < group.length; i++) {
      for (var j = i + 1; j < group.length; j++) {
        final left = group[i]['query'];
        final right = group[j]['query'];
        if (left == null ||
            right == null ||
            _canonicalJson(left) == _canonicalJson(right)) {
          throw FormatException(
            'phase $phase has duplicate active responses for ${entry.key}',
          );
        }
      }
    }
  }
  for (final request in stateSessionExpectedRequests(corpus, phase)) {
    final matches = active.where(
      (response) =>
          response['method'] == request['method'] &&
          response['path'] == request['path'] &&
          (response['query'] == null ||
              _canonicalJson(response['query']) ==
                  _canonicalJson(request['query'] ?? const <String, String>{})),
    );
    if (matches.length != 1) {
      throw FormatException(
        'phase $phase declares no unique response for '
        '${request['method']} ${request['path']}',
      );
    }
  }
  return active;
}

/// The corpus the first-slice replay server serves for one phase. The server's
/// contract fits unchanged once the phase's inactive responses are removed.
Map<String, dynamic> stateSessionCorpusForPhase(
  Map<String, dynamic> corpus,
  String phase,
) => {...corpus, 'responses': activeStateSessionResponses(corpus, phase)};

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

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/state_session/runner.dart '
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
  } on StateSessionRefusal catch (error) {
    _writeReport(reportPath, {
      'schemaVersion': 1,
      'product': 'liber-state-session-runner',
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
    'product': 'liber-state-session-runner',
    'platform': Platform.operatingSystem,
    'phase': phase,
    'pid': pid,
    'runId': _newRunId(),
    'startedAt': DateTime.now().toUtc().toIso8601String(),
  };
  var result = 0;
  try {
    final corpusFile = File(stateSessionCorpusPath);
    final corpus = loadStateSessionCorpus(stateSessionCorpusPath);
    final corpusLf = stateSessionCorpusSha256Lf(corpusFile);
    if (options.expectedCorpusSha256 != null &&
        options.expectedCorpusSha256 != corpusLf) {
      throw const StateSessionRefusal(
        'the working corpus bytes are not the pinned corpus',
      );
    }
    final target = stateSessionTargetOf(corpus);
    final library = File(libraryPath);
    if (!library.existsSync()) {
      throw const StateSessionRefusal('the native library does not exist');
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
        'corpusPath': stateSessionCorpusPath,
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
          'path': 'tool/state_session/runner.dart',
          'sha256': sha256File(File('tool/state_session/runner.dart')),
        },
      },
      'steps': [
        for (final step in stateSessionSteps(corpus, phase)) step['id'],
      ],
      'measurement': {
        'application':
            'ShelfService + SpaceHostStatePersistence over a '
            'Workspace space',
        'publication': phase == 'seed'
            ? 'ShelfService.add after each real details/TOC pair'
            : 'ShelfService.updateCatalog after each revision-2 refresh',
        'replay':
            'SliceReplayServer (tool/first_slice/runner.dart), '
            'response set filtered to this phase',
        'stageEntrypoints': const [
          'openBookSourcePipeline.search',
          'openBookSourcePipeline.details',
          'openBookSourcePipeline.chapter',
        ],
        'stateSurfaces': const [
          'sources',
          'books',
          'chapters',
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
  } on StateSessionRefusal catch (error) {
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
        throw const StateSessionRefusal(
          '--expected-corpus-sha256 is not a SHA-256',
        );
      }
      options.expectedCorpusSha256 = value;
      continue;
    }
    throw StateSessionRefusal('unknown runner argument: $arg');
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
  final pending = <String, _DetailsResult>{};
  final pipelines = <String, BookSourcePipeline>{};
  final isolation = <String, Object?>{};
  final cleanup = <String, Object?>{};
  final owner = <String, Object?>{};
  List<Map<String, Object?>> requests = const [];
  List<Map<String, Object?>> unmatched = const [];
  Map<String, Object?> requestCheck = const {};
  Map<String, Object?> observationCheck = const {};
  Map<String, Object?> javaPolicy = const {};

  Map<String, Object?> intoReport() => {
    'observations': observations,
    'observationCheck': observationCheck,
    'requests': requests,
    'unmatchedRequests': unmatched,
    'serverErrors': const <Object?>[],
    'requestCheck': requestCheck,
    'isolation': isolation,
    'owner': owner,
    'javaPolicy': javaPolicy,
    'cleanup': cleanup,
  };
}

class _DetailsResult {
  const _DetailsResult(this.book, this.chapters);
  final HtmlBook book;
  final List<SourceChapter> chapters;
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
      throw const StateSessionRefusal(
        'seed root already exists; only a fresh root is seeded',
      );
    }
  } else {
    if (!root.existsSync()) {
      throw const StateSessionRefusal('restart root does not exist');
    }
    if (!ownerFile.existsSync()) {
      throw const StateSessionRefusal('restart root has no owner.json');
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

  final corpusForPhase = stateSessionCorpusForPhase(corpus, phase);
  Workspace? workspace;
  SpaceStore? store;
  ShelfService? shelf;
  SliceReplayServer? server;
  var databaseClosed = false;
  var serverClosed = false;
  var nativeDisposed = false;
  Object? failure;
  try {
    server = await SliceReplayServer.start(corpusForPhase);
    if (server.origin.toString() != '${corpus['origin']}') {
      throw StateError(
        'the replay server bound ${server.origin}, not ${corpus['origin']}',
      );
    }
    if (seed) {
      root.createSync(recursive: true);
    }
    workspace = await Workspace.open(root: root);
    if (!seed && !workspace.manifestFile.existsSync()) {
      throw const StateSessionRefusal('restart root has no workspace manifest');
    }
    store = await workspace.openSpace();
    shelf = ShelfService(store, androidId: await workspace.androidId());
    if (seed) {
      final sources = await store.allSources();
      final books = await store.db.select(store.db.books).get();
      if (sources.isNotEmpty || books.isNotEmpty) {
        throw StateError('seed root is not empty');
      }
    } else {
      await _verifyRestoredRoot(store: store, corpus: corpus, owner: owner!);
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
          'the product keeps the space state in its one database and the '
          'installation manifest, both inside this root; the frozen capture '
          "names task-prefixed SharedPreferences outside its root, which the "
          'product has no counterpart for',
    });
    await NativeLibrary.initialize(libraryPath: libraryPath);
    for (final step in stateSessionSteps(corpus, phase)) {
      await _runStep(
        corpus: corpus,
        phase: phase,
        step: step,
        store: store,
        shelf: shelf,
        evidence: evidence,
      );
    }
    evidence.javaPolicy = await _runJavaPolicy(
      corpus: corpus,
      store: store,
      shelf: shelf,
      seed: seed,
    );
  } on Object catch (error) {
    failure = error;
  }

  try {
    final runningServer = server;
    if (runningServer != null) {
      await runningServer.close();
      serverClosed = true;
    }
  } on Object catch (error) {
    failure ??= error;
  }
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

  evidence.requests = List<Map<String, Object?>>.unmodifiable(
    server?.requests ?? const <Map<String, Object?>>[],
  );
  evidence.unmatched = List<Map<String, Object?>>.unmodifiable(
    server?.unmatched ?? const <Map<String, Object?>>[],
  );
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
      // Only a root this invocation created is this invocation's to remove.
      try {
        root.deleteSync(recursive: true);
        rootRemoved = !root.existsSync();
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
    'serverClosed': serverClosed,
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

/// Restart must find the root the seed reported, not another one that happens
/// to sit at the same path: every pinned identity in `owner.json` is compared
/// before the database is opened.
Map<String, dynamic> _validateOwner(
  Object? decoded, {
  required Map<String, dynamic> corpus,
  required String corpusLf,
  required String librarySha256,
  required Directory root,
}) {
  final owner = _object(decoded, 'owner.json');
  final target = stateSessionTargetOf(corpus);
  void same(Object? actual, Object? expected, String field) {
    if ('$actual' != '$expected') {
      throw StateSessionRefusal('owner.json $field does not match this run');
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
    throw const StateSessionRefusal('owner.json is not complete');
  }
  _text(owner['seedRunId'], 'owner.json seedRunId');
  if (_integer(owner['seedPid'], 'owner.json seedPid') <= 0) {
    throw const StateSessionRefusal('owner.json seedPid is not a process');
  }
  final declaredSources = {
    for (final raw in _array(owner['sources'], 'owner.json sources'))
      '${(raw as Map)['id']}': '${raw['sha256']}',
  };
  final expectedSources = {
    for (final raw in _array(corpus['sources'], 'sources'))
      '${(raw as Map)['id']}': sha256Text(
        jsonEncode(_sourceObject(raw.cast<String, dynamic>())),
      ),
  };
  if (_canonicalJson(declaredSources) != _canonicalJson(expectedSources)) {
    throw const StateSessionRefusal(
      'owner.json names other sources than this corpus',
    );
  }
  for (final relative in ['manifest.json', 'spaces/default/data.db']) {
    if (!File(
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}',
    ).existsSync()) {
      throw StateSessionRefusal('owned root is missing $relative');
    }
  }
  return owner;
}

/// The root's own book/source rows must be the seed's publication, not a
/// leftover another run left at this path.
Future<void> _verifyRestoredRoot({
  required SpaceStore store,
  required Map<String, dynamic> corpus,
  required Map<String, dynamic> owner,
}) async {
  final sources = await store.allSources();
  final declared = {
    for (final raw in owner['sources'] as List)
      '${(raw as Map)['bookSourceUrl']}',
  };
  final actual = [for (final source in sources) source.bookSourceUrl]..sort();
  final expected = declared.toList()..sort();
  if (_canonicalJson(actual) != _canonicalJson(expected)) {
    throw const StateSessionRefusal(
      'the owned root holds other sources than its owner.json names',
    );
  }
  for (final raw in corpus['books'] as List) {
    final book = raw as Map;
    final source =
        (corpus['sources'] as List).firstWhere(
              (entry) => (entry as Map)['id'] == book['source'],
            )
            as Map;
    final row = await store.bookByNaturalKey(
      '${(source['bookSource'] as Map)['bookSourceUrl']}',
      '${book['bookUrl']}',
    );
    if (row == null) {
      throw StateSessionRefusal(
        'the owned root has no row for ${book['bookUrl']}',
      );
    }
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
  final target = stateSessionTargetOf(corpus);
  return {
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'corpusPath': stateSessionCorpusPath,
    'corpusSha256Lf': corpusLf,
    'corpusRawSha256': sha256File(File(stateSessionCorpusPath)),
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
          'id': (raw as Map)['id'],
          'bookSourceUrl': (raw['bookSource'] as Map)['bookSourceUrl'],
          'sha256': sha256Text(
            jsonEncode(_sourceObject(raw.cast<String, dynamic>())),
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

Future<void> _runStep({
  required Map<String, dynamic> corpus,
  required String phase,
  required Map<String, dynamic> step,
  required SpaceStore store,
  required ShelfService shelf,
  required _PhaseEvidence evidence,
}) async {
  final id = '${step['id']}';
  switch ('${step['kind']}') {
    case 'search':
      await _runSearch(corpus, step, shelf, evidence);
    case 'details':
      await _runDetails(corpus, phase, step, store, shelf, evidence);
    case 'toc':
      await _runToc(corpus, phase, step, shelf, evidence);
    case 'content':
      await _runContent(corpus, step, store, shelf, evidence);
    case 'state':
      evidence.observations.add({
        'id': id,
        'value': await _readStateSurface(corpus, store, '${step['surface']}'),
      });
    default:
      throw StateError('unknown corpus step $id');
  }
}

Future<void> _runSearch(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  ShelfService shelf,
  _PhaseEvidence evidence,
) async {
  final source = _sourceOfId(corpus, '${step['source']}');
  final pipeline = _pipelineFor(corpus, source, shelf, evidence);
  final hits = await pipeline.search('${corpus['keyword']}');
  evidence.observations.add({
    'id': step['id'],
    'value': {
      'results': [
        for (final hit in hits)
          {
            'name': hit.title,
            'author': hit.author,
            'kind': hit.kind,
            'bookUrl': '${hit.url}',
          },
      ],
    },
  });
  for (final rawBookId in step['books'] as List) {
    final book = _bookOfId(corpus, '$rawBookId');
    final index = _integer(book['searchIndex'], 'searchIndex');
    if (index >= hits.length || '${hits[index].url}' != '${book['bookUrl']}') {
      throw StateError(
        'search ${step['id']} did not produce ${book['bookUrl']} '
        'at index $index',
      );
    }
    evidence.searchHits['$rawBookId'] = hits[index];
  }
}

Future<void> _runDetails(
  Map<String, dynamic> corpus,
  String phase,
  Map<String, dynamic> step,
  SpaceStore store,
  ShelfService shelf,
  _PhaseEvidence evidence,
) async {
  final bookId = '${step['book']}';
  final book = _bookOfId(corpus, bookId);
  final source = _sourceOfId(corpus, '${book['source']}');
  final sourceUrl = '${(source['bookSource'] as Map)['bookSourceUrl']}';
  final HtmlBook hit;
  if (step['from'] == 'search') {
    final searched = evidence.searchHits[bookId];
    if (searched == null) {
      throw StateError('details ${step['id']} has no search hit');
    }
    hit = searched;
  } else if (step['from'] == 'row') {
    final entry = await shelf.find(sourceUrl, '${book['bookUrl']}');
    if (entry == null) {
      throw StateError(
        'details ${step['id']} found no stored row for ${book['bookUrl']}',
      );
    }
    hit = entry.htmlBook;
  } else {
    throw StateError('details ${step['id']} has no valid source');
  }
  final pipeline = _pipelineFor(corpus, source, shelf, evidence);
  final (carrier, chapters) = await pipeline.details(hit);
  evidence.observations.add({
    'id': step['id'],
    'value': _bookObservation(carrier),
  });
  evidence.pending[bookId] = _DetailsResult(carrier, chapters);
}

Map<String, Object?> _bookObservation(HtmlBook book) {
  final raw = book.variable;
  return {
    'bookUrl': book.identityAddress,
    'name': book.title,
    'variable': raw == null ? null : variableMapOf(raw),
    'variableRaw': raw,
  };
}

Future<void> _runToc(
  Map<String, dynamic> corpus,
  String phase,
  Map<String, dynamic> step,
  ShelfService shelf,
  _PhaseEvidence evidence,
) async {
  final bookId = '${step['book']}';
  final details = evidence.pending.remove(bookId);
  if (details == null) {
    throw StateError('toc ${step['id']} has no preceding details step');
  }
  evidence.observations.add({
    'id': step['id'],
    'value': {
      'revision': step['revision'],
      'chapters': [
        for (final chapter in details.chapters)
          {
            'url': '${chapter.url}',
            'title': chapter.name,
            'tag': chapter.tag,
            'variable': chapter.variable == null
                ? null
                : variableMapOf(chapter.variable),
            'variableRaw': chapter.variable,
          },
      ],
    },
  });
  final book = _bookOfId(corpus, bookId);
  final source = _sourceOfId(corpus, '${book['source']}');
  final sourceUrl = '${(source['bookSource'] as Map)['bookSourceUrl']}';
  if (phase == 'seed') {
    await shelf.add(_sourceObject(source), details.book, details.chapters);
    return;
  }
  final existing = await shelf.find(sourceUrl, details.book.identityAddress);
  if (existing == null) {
    throw StateError(
      'refresh of ${details.book.identityAddress} found no stored book',
    );
  }
  await shelf.updateCatalog(sourceUrl, details.book, details.chapters);
}

Future<void> _runContent(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  SpaceStore store,
  ShelfService shelf,
  _PhaseEvidence evidence,
) async {
  final book = _bookOfId(corpus, '${step['book']}');
  final source = _sourceOfId(corpus, '${book['source']}');
  final sourceUrl = '${(source['bookSource'] as Map)['bookSourceUrl']}';
  final bookUrl = '${book['bookUrl']}';
  final chapterKey = '${step['chapter']}';
  final entry = await shelf.find(sourceUrl, bookUrl);
  if (entry == null) {
    throw StateError('content ${step['id']} found no stored book $bookUrl');
  }
  final chapter = await store.chapterByNaturalKey(
    sourceUrl,
    bookUrl,
    chapterKey,
  );
  if (chapter == null) {
    throw StateError(
      'content ${step['id']} found no stored chapter $chapterKey',
    );
  }
  final pipeline = _pipelineFor(corpus, source, shelf, evidence);
  final chapterUrl = chapter.url;
  if (chapterUrl == null || chapterUrl.isEmpty) {
    throw StateError(
      'content ${step['id']} found a chapter row without an address',
    );
  }
  final body = await pipeline.chapter(
    SourceChapter.fromAddress(
      chapter.name,
      chapterUrl,
      bookUrl: entry.htmlBook.url,
      chapterKey: chapter.chapterKey,
      tag: chapter.tag,
      isVolume: chapter.isVolume,
      isVip: chapter.isVip,
      isPay: chapter.isPay,
      variable: chapter.variable,
    ),
    book: entry.htmlBook,
  );
  evidence.observations.add({'id': step['id'], 'value': body.text});
}

BookSourcePipeline _pipelineFor(
  Map<String, dynamic> corpus,
  Map<String, dynamic> source,
  ShelfService shelf,
  _PhaseEvidence evidence,
) {
  final id = '${source['id']}';
  return evidence.pipelines.putIfAbsent(
    id,
    () => openBookSourcePipeline(
      _sourceObject(source),
      HttpSourceTransport(),
      hostState: shelf.hostState,
      androidId: shelf.androidId,
    ),
  );
}

/// The imported source object: the corpus keeps `jsLib` beside the Book Source
/// object, and the product's import carries it as the object's own field.
Map<String, dynamic> _sourceObject(Map<String, dynamic> source) => {
  ...(source['bookSource'] as Map).cast<String, dynamic>(),
  'jsLib': source['jsLib'],
};

Map<String, dynamic> _sourceOfId(Map<String, dynamic> corpus, String id) {
  for (final raw in corpus['sources'] as List) {
    if ((raw as Map)['id'] == id) return raw.cast<String, dynamic>();
  }
  throw StateError('the corpus has no source $id');
}

Map<String, dynamic> _bookOfId(Map<String, dynamic> corpus, String id) {
  for (final raw in corpus['books'] as List) {
    if ((raw as Map)['id'] == id) return raw.cast<String, dynamic>();
  }
  throw StateError('the corpus has no book $id');
}

Future<Map<String, Object?>> _readStateSurface(
  Map<String, dynamic> corpus,
  SpaceStore store,
  String surface,
) async {
  switch (surface) {
    case 'books':
      return {
        for (final raw in corpus['books'] as List)
          '${(raw as Map)['bookUrl']}': await _bookState(corpus, store, raw),
      };
    case 'chapters':
      return {
        for (final raw in corpus['books'] as List)
          '${(raw as Map)['bookUrl']}': await _chapterState(corpus, store, raw),
      };
    case 'caches':
      final rows = await SpaceHostStatePersistence(store).loadCache();
      return {
        for (final key in (corpus['cacheKeys'] as List).cast<String>())
          key: _cacheState(rows, key),
      };
    default:
      throw StateError('unknown state surface $surface');
  }
}

Future<Map<String, Object?>> _bookState(
  Map<String, dynamic> corpus,
  SpaceStore store,
  Map<dynamic, dynamic> book,
) async {
  final source = _sourceOfId(corpus, '${book['source']}');
  final row = await store.bookByNaturalKey(
    '${(source['bookSource'] as Map)['bookSourceUrl']}',
    '${book['bookUrl']}',
  );
  if (row == null) return {'present': false};
  final raw = row.variable;
  return {
    'present': true,
    'name': row.title,
    'variable': raw == null ? null : variableMapOf(raw),
    'variableRaw': raw,
  };
}

Future<List<Map<String, Object?>>> _chapterState(
  Map<String, dynamic> corpus,
  SpaceStore store,
  Map<dynamic, dynamic> book,
) async {
  final source = _sourceOfId(corpus, '${book['source']}');
  final row = await store.bookByNaturalKey(
    '${(source['bookSource'] as Map)['bookSourceUrl']}',
    '${book['bookUrl']}',
  );
  if (row == null) return const [];
  final chapters = await store.chaptersOf(row.id);
  return [
    for (final chapter in chapters)
      {
        'url': chapter.url,
        'title': chapter.name,
        'index': chapter.chapterIndex,
        'tag': chapter.tag,
        'variable': chapter.variable == null
            ? null
            : variableMapOf(chapter.variable),
        'variableRaw': chapter.variable,
      },
  ];
}

Map<String, Object?> _cacheState(List<SourceCacheEntry> rows, String key) {
  final matches = [
    for (final row in rows)
      if (row.key == key) row,
  ];
  if (matches.isEmpty) return {'present': false};
  if (matches.length != 1) {
    throw StateError('cache key $key is ambiguous: ${matches.length} rows');
  }
  final row = matches.single;
  return {
    'present': true,
    'value': row.value == null ? null : jsonDecode(row.value!),
    'deadline': row.expiresAt,
  };
}

/// java.put/java.get are the product's per-source `v_<sourceKey>_<key>` rows
/// (ADR 0011 §3), which the accepted frozen entity ladder keeps outside this
/// corpus. These declared keys are product policy only, never one of the 26
/// frozen observation ids: they prove the rows survive a real process restart
/// and stay inside the source that wrote them.
Future<Map<String, Object?>> _runJavaPolicy({
  required Map<String, dynamic> corpus,
  required SpaceStore store,
  required ShelfService shelf,
  required bool seed,
}) async {
  final sources = (corpus['sources'] as List).map((raw) => raw as Map).toList();
  final urls = [
    for (final source in sources)
      '${(source['bookSource'] as Map)['bookSourceUrl']}',
  ];
  if (urls.length != 2) {
    throw StateError(
      'the java policy check declares exactly two sources, found '
      '${urls.length}',
    );
  }
  final expected = {urls[0]: 'java-A-seed', urls[1]: 'java-B-seed'};
  final reads = <String, Object?>{};
  for (final url in urls) {
    final own = stateSessionJavaPolicyKeys[urls.indexOf(url)];
    final other = stateSessionJavaPolicyKeys[1 - urls.indexOf(url)];
    final ownValue = expected[url]!;
    final script = seed
        ? "(function(){java.put('$own','$ownValue');return "
              "[String(java.get('$own')),String(java.get('$other')),"
              "String(source.get('$own')),String(source.get('$other'))]"
              ".join('|');})()"
        : "(function(){return "
              "[String(java.get('$own')),String(java.get('$other')),"
              "String(source.get('$own')),String(source.get('$other'))]"
              ".join('|');})()";
    final value = await _evaluatePolicyScript(shelf, url, script);
    final parts = value.split('|');
    if (parts.length != 4) {
      throw StateError('java policy read for $url was malformed: $value');
    }
    final observed = {
      'java': {own: parts[0], other: parts[1]},
      'source': {own: parts[2], other: parts[3]},
    };
    final expectedParts = [ownValue, '', ownValue, ''];
    for (var index = 0; index < expectedParts.length; index++) {
      if (parts[index] != expectedParts[index]) {
        throw StateError(
          'java policy mismatch for $url at ${index == 0 || index == 2 ? own : other}: '
          'expected ${jsonEncode(expectedParts[index])}, '
          'got ${jsonEncode(parts[index])}',
        );
      }
    }
    reads[url] = observed;
  }
  final cacheRows = await SpaceHostStatePersistence(store).loadCache();
  final rows = <Map<String, Object?>>[];
  for (final url in urls) {
    final own = stateSessionJavaPolicyKeys[urls.indexOf(url)];
    final other = stateSessionJavaPolicyKeys[1 - urls.indexOf(url)];
    for (final key in [own, other]) {
      final matches = [
        for (final row in cacheRows)
          if (row.sourceRef == url && row.key == 'v_${url}_$key') row,
      ];
      final row = matches.isEmpty ? null : matches.single;
      final expectedValue = key == own ? expected[url] : null;
      final actualValue = row?.value == null ? null : jsonDecode(row!.value!);
      if (actualValue != expectedValue) {
        throw StateError(
          'java policy row v_${url}_$key is ${jsonEncode(actualValue)}, '
          'expected ${jsonEncode(expectedValue)}',
        );
      }
      rows.add({
        'source': url,
        'key': 'v_${url}_$key',
        'present': row != null,
        'value': actualValue,
        'deadline': row?.expiresAt,
      });
    }
  }
  return {
    'phase': seed ? 'seed' : 'restart',
    'policy':
        'ADR 0011 §3: java.put/java.get are the per-source '
        'v_<sourceKey>_<key> rows shared with source.put/source.get. The '
        'frozen entity ladder stays outside the 26 frozen observations.',
    'keys': stateSessionJavaPolicyKeys,
    'expected': expected,
    'sources': reads,
    'rows': rows,
    'verdict': 'pass',
  };
}

Future<String> _evaluatePolicyScript(
  ShelfService shelf,
  String sourceUrl,
  String script,
) async {
  final runtime = InProcessSourceScriptRuntime(
    dispatcher: SourceHostDispatcher(
      transport: HttpSourceTransport(),
      hostState: shelf.hostState,
      sourceRef: sourceUrl,
    ),
    hostState: shelf.hostState,
  );
  final value = await runtime.evaluate(
    source: script,
    input: {'sourceKey': sourceUrl},
    timeout: const Duration(seconds: 30),
  );
  return value == null ? '' : '$value';
}

Map<String, Object?> _requestCheck(
  Map<String, dynamic> corpus,
  String phase,
  List<Map<String, Object?>> requests,
) {
  final expected = stateSessionExpectedRequests(corpus, phase);
  final actual = [for (final request in requests) _requestLine(request)];
  final declared = [for (final request in expected) _requestLine(request)];
  int? mismatchIndex;
  String? mismatch;
  if (actual.length != declared.length) {
    mismatch = '${actual.length} requests, ${declared.length} declared';
  } else {
    for (var index = 0; index < declared.length; index++) {
      if (!_sameRequest(expected[index], requests[index])) {
        mismatchIndex = index;
        mismatch = '${actual[index]} does not match ${declared[index]}';
        break;
      }
    }
  }
  return {
    'declared': declared,
    'declaredCount': declared.length,
    'actualCount': actual.length,
    'match': mismatch == null,
    'mismatchIndex': mismatchIndex,
    'mismatch': mismatch,
  };
}

bool _sameRequest(Map<String, dynamic> expected, Map<String, Object?> actual) {
  if (expected['method'] != actual['method']) return false;
  if (expected['path'] != actual['path']) return false;
  final expectedQuery =
      (expected['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  final actualQuery =
      (actual['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  return _canonicalJson(expectedQuery) == _canonicalJson(actualQuery);
}

String _requestLine(Map<dynamic, dynamic> request) {
  final line = '${request['method']} ${request['path']}';
  final query =
      (request['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  if (query.isEmpty) return line;
  final keys = query.keys.toList()..sort();
  return '$line?${keys.map((key) => '$key=${query[key]}').join('&')}';
}

Map<String, Object?> _observationCheck(
  Map<String, dynamic> corpus,
  String phase,
  List<Map<String, Object?>> observations,
) {
  final declared = [
    for (final step in stateSessionSteps(corpus, phase)) '${step['id']}',
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
