import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/auth_session/compare.dart';
import '../tool/auth_session/runner.dart';

/// The corpus the comparator is written against. It is read from the checkout,
/// so a corpus the comparator cannot load fails here first.
const corpusPath = authSessionCorpusPath;

Map<String, dynamic> readCorpus() =>
    jsonDecode(File(corpusPath).readAsStringSync()) as Map<String, dynamic>;

Map<String, dynamic> copy(Map<String, dynamic> source) =>
    jsonDecode(jsonEncode(source)) as Map<String, dynamic>;

/// The LF pin of the checkout's corpus bytes, as the runner computes it.
final String corpusLf = sha256Text(
  File(corpusPath).readAsStringSync().replaceAll('\r\n', '\n'),
);

Map<String, String> jsonMapOf(Object? text) {
  if (text is! String) return const {};
  final decoded = jsonDecode(text);
  if (decoded is! Map) return const {};
  return {
    for (final entry in decoded.entries) '${entry.key}': '${entry.value}',
  };
}

/// The login header one source holds after the corpus step at [through], read
/// from the corpus' own scripts: a login step stores it last, and a
/// `loginHeaderPut` step replaces it.
Map<String, String> loginHeaderAt(
  Map<String, dynamic> corpus,
  String phase,
  int through,
) {
  final steps = authSessionSteps(corpus, phase);
  final bySource = <String, Map<String, String>>{};
  if (through < 0) return const {};
  for (var index = 0; index <= through && index < steps.length; index++) {
    final step = steps[index];
    final kind = '${step['kind']}';
    if (kind == 'login') {
      final source = authSessionSourceOf(corpus, '${step['source']}');
      final script = '${(source['bookSource'] as Map)['loginUrl']}';
      final match = RegExp(r"putLoginHeader\('([^']+)'\)").firstMatch(script);
      if (match != null) {
        bySource['${step['source']}'] = jsonMapOf(match.group(1));
      }
    } else if (kind == 'loginHeaderPut') {
      bySource['${step['source']}'] = jsonMapOf(step['header']);
    } else if (kind == 'removeLoginHeader') {
      bySource.remove('${step['source']}');
    }
  }
  return bySource['${steps[through]['source']}'] ?? const {};
}

/// The step one declared request belongs to, by the address the step itself
/// declares. The corpus declares its requests in step order; this recovers the
/// same attribution the device capture records, without assuming a count.
List<String> stagePerRequest(Map<String, dynamic> corpus, String phase) {
  final steps = authSessionSteps(corpus, phase);
  final requests = authSessionExpectedRequests(corpus, phase);
  final stages = <String>[];
  var stepIndex = 0;
  for (final request in requests) {
    final path = '${request['path']}';
    final rawQuery = '${request['rawQuery']}';
    var found = -1;
    for (var index = stepIndex; index < steps.length; index++) {
      if (_stepMatches(corpus, steps[index], path, rawQuery)) {
        found = index;
        break;
      }
    }
    if (found < 0) {
      throw StateError('no step declares $path?$rawQuery');
    }
    stepIndex = found;
    stages.add('${steps[found]['id']}');
  }
  return stages;
}

bool _stepMatches(
  Map<String, dynamic> corpus,
  Map<String, dynamic> step,
  String path,
  String rawQuery,
) {
  final kind = '${step['kind']}';
  if (kind == 'login') {
    final source = authSessionSourceOf(corpus, '${step['source']}');
    final origin = Uri.parse(authSessionSourceUrl(source));
    return path == '${origin.path}/login';
  }
  if (kind != 'stage') return false;
  final source = authSessionSourceOf(corpus, '${step['source']}');
  final origin = Uri.parse(authSessionSourceUrl(source));
  switch ('${step['stage']}') {
    case 'search':
      return path == '${origin.path}/search' &&
          rawQuery.contains('keyword=${step['keyword']}');
    case 'details':
      final book = authSessionBookOf(corpus, '${step['book']}');
      return path == Uri.parse('${book['bookUrl']}').path;
    case 'toc':
      final book = authSessionBookOf(corpus, '${step['book']}');
      return path == '${Uri.parse('${book['bookUrl']}').path}/toc';
    case 'content':
      return path == Uri.parse('${step['chapter']}').path;
  }
  return false;
}

/// One cookie probe as the frozen capture records it: the two storage tiers and
/// the effective value the frozen `CookieStore.getCookie` merges from them.
Map<String, Object?> nativeProbe({
  required String url,
  required String persistent,
  required String? session,
  required String? loginHeader,
}) {
  final effective = [
    persistent,
    session ?? '',
  ].where((part) => part.isNotEmpty).join('; ');
  return {
    'url': url,
    'domain': Uri.parse(url).host,
    'persistent': persistent,
    'session': session,
    'effective': effective,
    'keys': authSessionCookiePairs(effective),
    'loginHeader': loginHeader,
    'loginHeaderMap': loginHeader == null
        ? null
        : authSessionMapPairs(jsonMapOf(loginHeader)),
  };
}

/// The product's own cookie probe: one storage shape, so its persistent map is
/// the effective value and it has no session map.
Map<String, Object?> productProbe(Map<dynamic, dynamic> native) {
  final effective = '${native['effective']}';
  return {
    'url': native['url'],
    'domain': native['domain'],
    'persistent': effective,
    'session': null,
    'effective': effective,
    'keys': authSessionCookiePairs(effective),
    'loginHeader': native['loginHeader'],
    'loginHeaderMap': native['loginHeaderMap'],
  };
}

/// The same pairs with the last one moved to the front, so a value that is
/// already its own reverse still changes.
String rotateCookie(String value) {
  final pairs = [
    for (final part in value.split('; '))
      if (part.isNotEmpty) part,
  ];
  if (pairs.length < 2) return value;
  return [...pairs.skip(1), pairs.first].join('; ');
}

const ownerSha =
    '2b7e151628aed2a6abf7158809cf4f3c2b7e151628aed2a6abf7158809cf4f3c';

/// The frozen cookie value each source's requests carry in this fixture. The
/// product's jar keeps the same pairs; only their order can differ.
String cookieFor(String path) {
  if (path.startsWith('/a/')) {
    if (path == '/a/login') return 'scriptA=one';
    return 'scriptA=one; loginRespA=p1; sidA=two; extraA=e1; '
        'loginSessA=t1; ssA=s2; ss2=sx';
  }
  if (path == '/b/login') return 'scriptB=one';
  return 'scriptB=loginOverride; loginCookieB=abc';
}

/// The same pairs in the product jar's own insertion order.
String jarOrderCookie(String path) {
  if (path == '/a/login') return 'scriptA=one';
  return 'scriptA=one; loginRespA=p1; loginSessA=t1; sidA=two; extraA=e1; '
      'ssA=s2; ss2=sx';
}

/// A synthetic but complete pair of frozen captures and product reports for one
/// corpus: the golden is shaped the way the device harness records it, and the
/// product report the way the runner does.
class Fixture {
  Fixture(this.corpus, {this.jarOrder = false, this.probeOrder = false});

  final Map<String, dynamic> corpus;

  /// When set, the product's outbound cookie carries the jar's own insertion
  /// order, which is the real single-tier behaviour this corpus observes.
  final bool jarOrder;

  /// When set, a product cookie probe's effective value is in jar order too.
  final bool probeOrder;

  late final Map<String, dynamic> seedGolden = golden('seed');
  late final Map<String, dynamic> restartGolden = golden('restart');
  late final Map<String, dynamic> seedProduct = product('seed');
  late final Map<String, dynamic> restartProduct = product('restart');

  Map<String, dynamic> golden(String phase) {
    final requests = authSessionExpectedRequests(corpus, phase);
    final stages = stagePerRequest(corpus, phase);
    final steps = authSessionSteps(corpus, phase);
    final stepIndex = {
      for (var index = 0; index < steps.length; index++)
        '${steps[index]['id']}': index,
    };
    final rows = <Map<String, Object?>>[];
    for (var index = 0; index < requests.length; index++) {
      final declared = requests[index];
      final stage = stages[index];
      final step = steps[stepIndex[stage]!];
      final source = authSessionSourceOf(corpus, '${step['source']}');
      final staticHeaders = jsonMapOf((source['bookSource'] as Map)['header']);
      // A request of the login step itself runs before that step's script
      // stores the header, so it sees the state the step before it left.
      final login = loginHeaderAt(
        corpus,
        phase,
        '${step['kind']}' == 'login'
            ? stepIndex[stage]! - 1
            : stepIndex[stage]!,
      );
      final path = '${declared['path']}';
      final headers = <String, Object?>{};
      for (final entry in staticHeaders.entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }
      headers['user-agent'] = 'Liber-AUTH-SESSION-01/1.0';
      // The frozen `getHeaderMap(true)` merges the stored login header last.
      for (final entry in login.entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }
      final cookie = cookieFor(path);
      if (cookie.isNotEmpty) headers['cookie'] = cookie;
      headers['keep-alive'] = '300';
      headers['cache-control'] = 'no-cache';
      headers['accept-encoding'] = 'gzip, deflate';
      headers['host'] = Uri.parse(authSessionSourceUrl(source)).authority;
      rows.add({
        'listener': Uri.parse(authSessionSourceUrl(source)).host,
        'method': declared['method'],
        'target': '${declared['path']}?${declared['rawQuery']}',
        'path': declared['path'],
        'rawQuery': declared['rawQuery'],
        'query': <String, Object?>{},
        'headers': headers,
        'headerLines': [
          for (final entry in headers.entries) '${entry.key}: ${entry.value}',
        ],
        'body': '',
        'bodyLength': 0,
        'bodySha256':
            'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
        'stage': stage,
      });
    }
    final observations = <Map<String, Object?>>[
      for (var index = 0; index < steps.length; index++)
        {
          'id': steps[index]['id'],
          'value': observation(phase, steps[index], index),
        },
    ];
    final target = corpus['target'] as Map;
    return {
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'schemaVersion': 1,
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'platform': 'android',
      'fingerprint': 'Redmi/myron/myron:17/CP2A.260605.016',
      'recordedAt': phase == 'seed'
          ? '2026-10-21T06:44:56.171Z'
          : '2026-10-21T06:46:56.171Z',
      'phase': phase,
      'runId': 'golden-$phase',
      'pid': phase == 'seed' ? 20071 : 23718,
      'identity': {
        'fixtureId': corpus['fixtureId'],
        'corpusVersion': corpus['corpusVersion'],
        'targetPackage': target['package'],
        'targetApkSha256': target['apkSha256'],
        'targetBaselineCommit': target['baselineCommit'],
        'targetPinManifest': target['manifest'],
        'harnessPackage': 'io.liber.oracle.nested',
        'harnessApkSha256':
            '54695a2bee29ba7ae69ab08b79276e3cf548ff526c20eea2b76a5a53c8ddce0f',
        'corpusAsset': 'auth-session-fixtures.json',
        'corpusAssetSha256': corpusLf,
        'corpusSha256Lf': corpusLf,
      },
      'isolation': {
        'application': 'android.app.Application',
        'scratchRoot':
            '/data/user/0/io.legado.app.debug/cache/liber-auth-session-01',
        'scratchRootExistedAtStart': phase != 'seed',
        'scratchCreatedByThisRun': phase == 'seed',
        'scratchRetainedFromSeed': phase != 'seed',
        'deviceProtected': false,
        'webViewPathPrecheck': {'insideRoot': true},
      },
      'stageTrace': [
        for (final row in rows)
          {
            'stage': row['stage'],
            'listener': row['listener'],
            'target': row['target'],
          },
      ],
      'requests': rows,
      'unmatchedRequests': <Object?>[],
      'serverErrors': <Object?>[],
      'requestCheck': {
        'declared': [
          for (final row in rows)
            {
              'method': row['method'],
              'path': row['path'],
              'rawQuery': row['rawQuery'],
            },
        ],
        'actual': [
          for (final row in rows)
            {
              'method': row['method'],
              'path': row['path'],
              'rawQuery': row['rawQuery'],
            },
        ],
        'mismatches': <Object?>[],
        'orderMatch': true,
        'bodyMatch': true,
        'unmatched': 0,
        'serverErrors': 0,
        'forbiddenHeaders': <Object?>[],
        'match': true,
      },
      'observations': observations,
      'observationCheck': {
        'declared': [for (final step in steps) step['id']],
        'actual': [for (final step in steps) step['id']],
        'missing': <Object?>[],
        'extra': <Object?>[],
        'duplicates': <Object?>[],
        'ordered': true,
        'match': true,
      },
      'inventory': const <String, Object?>{},
      'webView': {
        'suffix': 'liber-auth-session-01',
        'suffixStatus': 'set-in-Instrumentation.newApplication',
        'suffixFailure': null,
        'preflightFailure': null,
        'preflight': {
          'provider': {
            'package': 'com.google.android.webview',
            'versionName': '157.0.8103.5',
            'versionCode': 810300513,
          },
          'computed': {
            'data': '/data/data/x/dir-webview_liber-auth-session-01',
            'cache': '/data/data/x/cache/webview_liber-auth-session-01',
            'textures': '/data/data/x/dir-textures',
          },
          'actual': {
            'data': '/data/data/x/dir-webview_liber-auth-session-01',
            'cache': '/data/data/x/cache/webview_liber-auth-session-01',
            'textures': '/data/data/x/dir-textures',
          },
          'androidxProcessGlobalConfig': {
            'classPresent': true,
            'configSet': false,
            'dataDirectoryBasePath': null,
            'cacheDirectoryBasePath': null,
            'dataDirectorySuffixKey': false,
          },
          'deviceProtected': false,
        },
      },
      'cleanup': {
        'databaseClosed': true,
        'replay': {
          'openConnectionsBeforeClose': 2,
          'openConnectionsAfterClose': 0,
          'listenersClosed': true,
          'listenerClosure': [
            {
              'host': '127.0.0.1',
              'port': 18751,
              'created': true,
              'closed': true,
            },
            {
              'host': '127.0.0.2',
              'port': 18751,
              'created': true,
              'closed': true,
            },
          ],
          'listenerCloseErrors': <Object?>[],
          'workersStopped': true,
          'executorTerminated': true,
          'serverErrors': <Object?>[],
          'failures': <Object?>[],
          'ok': true,
        },
        'terminal': {
          'requests': rows.length,
          'unmatched': 0,
          'serverErrors': 0,
          'requestMatch': true,
          'observationMatch': true,
          'ok': true,
        },
        'ownership': phase == 'seed'
            ? 'created-fresh-root'
            : 'validated-seed-owner',
        'scratchRoot':
            '/data/user/0/io.legado.app.debug/cache/liber-auth-session-01',
        'preferencesFenced': phase == 'seed'
            ? [
                {'name': 'liber_auth_session_01_probe', 'ok': true},
              ]
            : <Object?>[],
        'preferencesRemoved': phase == 'seed'
            ? <Object?>[]
            : [
                {'name': 'liber_auth_session_01_probe', 'ok': true},
              ],
        'scratchRetained': phase == 'seed',
        'scratchRemoved': phase != 'seed',
        'ownerFile':
            '/data/user/0/io.legado.app.debug/cache/liber-auth-session-01/owner.json',
      },
      'analysisFailure': null,
    };
  }

  Map<String, Object?> observation(
    String phase,
    Map<String, dynamic> step,
    int index,
  ) {
    final kind = '${step['kind']}';
    final sourceId = step['source'];
    final loginHeader = sourceId == null
        ? null
        : (loginHeaderAt(corpus, phase, index).isEmpty
              ? null
              : jsonEncode(loginHeaderAt(corpus, phase, index)));
    Map<String, Object?> probe(String id) {
      final url = authSessionSourceUrl(authSessionSourceOf(corpus, id));
      return nativeProbe(
        url: url,
        persistent: id == 'A'
            ? 'sidA=after; extraA=e2'
            : 'scriptB=loginOverride; loginCookieB=abc',
        session: null,
        loginHeader: loginHeader,
      );
    }

    switch (kind) {
      case 'login':
        return {
          'kind': 'login',
          'source': sourceId,
          'loginUi': [
            {'name': 'user', 'type': 'text', 'action': null},
            {'name': 'pass', 'type': 'password', 'action': null},
            {'name': 'Login', 'type': 'button', 'action': 'login'},
          ],
          'putLoginInfo': true,
          'loginInfo': [
            ['pass', 'synthetic-a-pass'],
            ['user', 'synthetic-a-user'],
          ],
          'loginOutcome': 'code=200|body={}|user=synthetic-a-user',
          'loginHeader': loginHeader,
          'loginHeaderMap': loginHeader == null
              ? null
              : authSessionMapPairs(jsonMapOf(loginHeader)),
        };
      case 'headerMap':
        return {
          'kind': 'headerMap',
          'source': sourceId,
          'noLogin': [
            ['User-Agent', 'Liber-AUTH-SESSION-01/1.0'],
          ],
          'withLogin': [
            ['User-Agent', 'Liber-AUTH-SESSION-01/1.0'],
            ['X-Login', 'A-login'],
          ],
          'loginHeader': loginHeader,
          'loginHeaderMap': loginHeader == null
              ? null
              : authSessionMapPairs(jsonMapOf(loginHeader)),
        };
      case 'stage':
        final stage = '${step['stage']}';
        final book = step['book'] == null
            ? null
            : authSessionBookOf(corpus, '${step['book']}');
        return {
          'kind': 'stage',
          'stage': stage,
          'source': sourceId,
          if (stage == 'search')
            'results': [
              {
                'id': (step['books'] as List).first,
                'name': 'x',
                'author': 'y',
                'kind': '',
                'bookUrl': 'z',
              },
            ],
          if (stage == 'details') 'book': step['book'],
          if (stage == 'details') 'bookUrl': book!['bookUrl'],
          if (stage == 'details') 'name': 'n',
          if (stage == 'details') 'author': 'a',
          if (stage == 'details') 'intro': 'i',
          if (stage == 'details') 'latestChapterTitle': '',
          if (stage == 'details') 'tocUrl': '${book!['bookUrl']}/toc',
          if (stage == 'toc')
            'chapters': [
              {'url': 'c1', 'title': 't1', 'tag': 'tag|c1'},
            ],
          if (stage == 'content') 'book': step['book'],
          if (stage == 'content') 'chapter': step['chapter'],
          if (stage == 'content') 'text': 'PageA1Ch1',
          'check': 'code=200|mark=pass',
        };
      case 'cookieState':
        return {
          'kind': 'cookieState',
          for (final raw in step['sources'] as List) '$raw': probe('$raw'),
        };
      case 'cookieKeyRemoval':
        return {
          'kind': 'cookieKeyRemoval',
          'source': sourceId,
          'removed': step['keys'],
          'before': probe('$sourceId'),
          'after': probe('$sourceId'),
        };
      case 'removeLoginHeader':
        return {
          'kind': 'removeLoginHeader',
          'source': sourceId,
          'before': probe('$sourceId'),
          'after': {
            ...probe('$sourceId'),
            'persistent': '',
            'effective': '',
            'keys': <Object?>[],
            'loginHeader': null,
            'loginHeaderMap': null,
          },
          'webViewInitialized': true,
        };
      case 'loginHeaderPut':
        return {
          'kind': 'loginHeaderPut',
          'source': sourceId,
          'before': probe('$sourceId'),
          'after': probe('$sourceId'),
          'withLogin': [
            ['User-Agent', 'Liber-AUTH-SESSION-01/1.0'],
            ['X-Login', 'B-login'],
            ['X-Over', 'login'],
          ],
        };
      case 'state':
        return {
          'kind': 'state',
          'sessions': {
            for (final raw in step['sources'] as List)
              '$raw': raw == 'A'
                  ? (phase == 'seed' ? 'ssA=after; ss2=sx2' : '')
                  : null,
          },
          'loginHeaders': {
            for (final raw in step['sources'] as List) '$raw': null,
          },
          'loginInfo': {
            for (final raw in step['sources'] as List) '$raw': <Object?>[],
          },
          'cookies': {
            for (final raw in step['sources'] as List) '$raw': probe('$raw'),
          },
        };
      default:
        throw StateError('unknown step kind $kind');
    }
  }

  Map<String, dynamic> product(String phase) {
    final report = copy(phase == 'seed' ? seedGolden : restartGolden);
    report['product'] = 'liber-auth-session-runner';
    report['platform'] = 'windows';
    report['pid'] = phase == 'seed' ? 56176 : 22296;
    report['runId'] = 'product-$phase';
    report['startedAt'] = phase == 'seed'
        ? '2026-10-21T07:00:00.000Z'
        : '2026-10-21T07:00:20.000Z';
    report['completedAt'] = phase == 'seed'
        ? '2026-10-21T07:00:10.000Z'
        : '2026-10-21T07:00:30.000Z';
    report['status'] = 'completed';
    final identity = (report['identity'] as Map).cast<String, dynamic>();
    identity['corpusPath'] = corpusPath;
    identity['corpusRawSha256'] = corpusLf;
    for (final key in [
      'targetPackage',
      'targetApkSha256',
      'targetBaselineCommit',
      'targetPinManifest',
      'harnessPackage',
      'harnessApkSha256',
      'corpusAsset',
      'corpusAssetSha256',
    ]) {
      identity.remove(key);
    }
    identity['target'] = {
      'package': (corpus['target'] as Map)['package'],
      'apkSha256': (corpus['target'] as Map)['apkSha256'],
      'baselineCommit': (corpus['target'] as Map)['baselineCommit'],
      'manifest': (corpus['target'] as Map)['manifest'],
    };
    identity['library'] = {
      'path': 'packages/fjs/libfjs/target/debug/fjs.dll',
      'sha256':
          '51b5097c15c14f9564261df5fde12206447e29d77f79d71fe2bf9026cadd1d9b',
    };
    identity['runner'] = {
      'path': 'tool/auth_session/runner.dart',
      'sha256':
          '838cf80767c8e3d0449480022dedebde07199673a5aaf5fdf312536882d9cda8',
    };
    report['steps'] = [
      for (final step in authSessionSteps(corpus, phase)) step['id'],
    ];
    // The product merges the login header *under* the request's own headers, so
    // a key the static header rule also declares keeps the static value.
    for (final raw in report['requests'] as List) {
      final request = raw as Map;
      final headers = (request['headers'] as Map).cast<String, Object?>();
      final stage = '${request['stage']}';
      final step = authSessionSteps(
        corpus,
        phase,
      ).firstWhere((candidate) => '${candidate['id']}' == stage);
      final source = authSessionSourceOf(corpus, '${step['source']}');
      for (final entry in jsonMapOf(
        (source['bookSource'] as Map)['header'],
      ).entries) {
        headers[entry.key.toLowerCase()] = entry.value;
      }
      if (jarOrder) {
        headers['cookie'] = jarOrderCookie('${request['path']}');
        request['headerLines'] = [
          for (final entry in headers.entries) '${entry.key}: ${entry.value}',
        ];
      }
    }
    final observations = report['observations'] as List;
    for (final raw in observations) {
      final value = (raw as Map)['value'];
      if (value is! Map) continue;
      for (final key in value.keys.toList()) {
        final probe = value[key];
        if (probe is Map && probe.containsKey('effective')) {
          final replacement = productProbe(probe);
          if (probeOrder) {
            final reordered = rotateCookie('${replacement['effective']}');
            replacement['effective'] = reordered;
            replacement['persistent'] = reordered;
            replacement['keys'] = authSessionCookiePairs(reordered);
          }
          value[key] = replacement;
        }
      }
      if (value.containsKey('effective')) {
        final replacement = productProbe(value);
        value.clear();
        value.addAll(replacement);
        if (probeOrder) {
          final reordered = rotateCookie('${replacement['effective']}');
          replacement['effective'] = reordered;
          replacement['persistent'] = reordered;
          replacement['keys'] = authSessionCookiePairs(reordered);
        }
      }
      value.remove('webViewInitialized');
      value.remove('sessions');
    }
    report['sessionTier'] = {
      'tier': 'single',
      'sessions': {'A': null, 'B': null},
      'persistent': {'A': 'sidA=after; extraA=e2', 'B': ''},
      'note': 'one storage shape',
    };
    report['isolation'] = {
      'root': 'C:/evidence/a2-auth-product/scratch/run/root',
      'rootName': 'root',
      'database':
          'C:/evidence/a2-auth-product/scratch/run/root/spaces/default/data.db',
      'workspaceManifest':
          'C:/evidence/a2-auth-product/scratch/run/root/manifest.json',
      'ownerFile': 'C:/evidence/a2-auth-product/scratch/run/root/owner.json',
      'rootExistedAtStart': phase != 'seed',
      'createdByThisRun': phase == 'seed',
      'validatedOwner': phase != 'seed',
      'validatedOwnerSha256': phase == 'seed' ? null : ownerSha,
      'preferenceFilesOutsideRoot': <Object?>[],
      'preferenceBoundary': 'the product keeps its state in this one root',
      'sessionTier': 'the product jar has one storage shape',
    };
    report['owner'] = {
      'validated': phase != 'seed',
      'written': phase == 'seed',
      'sha256': ownerSha,
      'seedRunId': 'product-seed',
      'seedPid': 56176,
      'rootName': 'root',
      'complete': true,
    };
    report['cleanup'] = {
      'databaseClosed': true,
      'serversClosed': true,
      'nativeLibraryDisposed': true,
      'ownerWritten': phase == 'seed',
      'ownerSha256': ownerSha,
      'scratchRetained': phase == 'seed',
      'scratchRemoved': phase != 'seed',
      'rootAbsentAfter': phase != 'seed',
      'removalSkipped': '',
      'startedAt': report['startedAt'],
    };
    report.remove('inventory');
    report.remove('webView');
    report.remove('fingerprint');
    report['unmatchedRequests'] = <Object?>[];
    report['serverErrors'] = <Object?>[];
    report['requestCheck'] = {
      'declared': [
        for (final request in authSessionExpectedRequests(corpus, phase))
          {
            'method': request['method'],
            'path': request['path'],
            'rawQuery': request['rawQuery'],
          },
      ],
      'declaredCount': authSessionExpectedRequests(corpus, phase).length,
      'actualCount': authSessionExpectedRequests(corpus, phase).length,
      'orderMatch': true,
      'match': true,
      'mismatchIndex': null,
      'mismatch': null,
    };
    report['observationCheck'] = {
      'declared': [
        for (final step in authSessionSteps(corpus, phase)) step['id'],
      ],
      'actual': [
        for (final step in authSessionSteps(corpus, phase)) step['id'],
      ],
      'missing': <Object?>[],
      'extra': <Object?>[],
      'duplicates': <Object?>[],
      'ordered': true,
      'match': true,
    };
    report['analysisFailure'] = null;
    return report;
  }

  Map<String, Object?> compare({
    Map<String, dynamic>? seedGolden,
    Map<String, dynamic>? restartGolden,
    Map<String, dynamic>? seedProduct,
    Map<String, dynamic>? restartProduct,
    Map<String, dynamic>? handoff,
    String? librarySha256,
  }) => compareAuthSessionPhases(
    corpus: corpus,
    corpusSha256Lf: corpusLf,
    seedGolden: seedGolden ?? this.seedGolden,
    restartGolden: restartGolden ?? this.restartGolden,
    seedProduct: seedProduct ?? this.seedProduct,
    restartProduct: restartProduct ?? this.restartProduct,
    handoff: handoff,
    librarySha256: librarySha256,
    seedExitCode: 0,
    restartExitCode: 0,
  );
}

List<String> surfacesOf(Map<String, Object?> report) => [
  for (final row in (report['mismatches'] as List? ?? const []))
    '${(row as Map)['surface']}',
];

void main() {
  final corpus = readCorpus();

  group('corpus pin', () {
    test('the LF pin is the same for an LF and a CRLF checkout', () {
      final lf = File(corpusPath).readAsStringSync().replaceAll('\r\n', '\n');
      final crlf = lf.replaceAll('\n', '\r\n');
      expect(sha256Text(crlf.replaceAll('\r\n', '\n')), corpusLf);
      expect(sha256Text(lf), corpusLf);
    });

    test('a content edit, a lone CR and a BOM change the pin', () {
      final lf = File(corpusPath).readAsStringSync().replaceAll('\r\n', '\n');
      String lfHash(String text) => sha256Text(text.replaceAll('\r\n', '\n'));
      expect(
        lfHash(lf.replaceFirst('synthetic-a-user', 'synthetic-x-user')),
        isNot(corpusLf),
      );
      expect(lfHash('$lf\n'), isNot(corpusLf));
      expect(lfHash(lf.replaceFirst('\n', '\r')), isNot(corpusLf));
      expect(lfHash('\ufeff$lf'), isNot(corpusLf));
    });

    test('the corpus validates and names the two cookie-jar states', () {
      expect(() => validateAuthSessionCorpus(corpus), returnsNormally);
      final flags = [
        for (final source in corpus['sources'] as List)
          (source['bookSource'] as Map)['enabledCookieJar'],
      ];
      expect(flags, [true, false]);
    });

    test('the request stages the corpus declares are its own step order', () {
      for (final phase in ['seed', 'restart']) {
        final stages = stagePerRequest(corpus, phase);
        final requests = authSessionExpectedRequests(corpus, phase);
        expect(stages.length, requests.length);
        expect(
          () => authSessionRequestStages(corpus, phase, [
            for (var index = 0; index < requests.length; index++)
              {...requests[index], 'stage': stages[index]},
          ], 'requests'),
          returnsNormally,
        );
      }
    });
  });

  group('frozen capture validation', () {
    late Fixture fixture;
    setUpAll(() => fixture = Fixture(corpus));

    test('a well-formed pair is accepted', () {
      expect(
        () => checkAuthSessionGoldenPair(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          seed: fixture.seedGolden,
          restart: fixture.restartGolden,
        ),
        returnsNormally,
      );
    });

    test('another target APK, corpus hash, harness or phase is refused', () {
      Map<String, dynamic> withIdentity(String key, Object? value) {
        final golden = copy(fixture.seedGolden);
        ((golden['identity'] as Map) as Map<String, dynamic>)[key] = value;
        return golden;
      }

      for (final golden in [
        withIdentity('targetApkSha256', 'ff' * 32),
        withIdentity('corpusSha256Lf', 'ff' * 32),
        withIdentity('targetPinManifest', 'other.json'),
      ]) {
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: golden,
            phase: 'seed',
          ),
          throwsFormatException,
        );
      }
      expect(
        () => checkAuthSessionGolden(
          corpus: corpus,
          corpusSha256Lf: corpusLf,
          golden: fixture.restartGolden,
          phase: 'seed',
        ),
        throwsFormatException,
      );
    });

    test('a reordered, extra or re-encoded request is refused', () {
      final swapped = copy(fixture.seedGolden);
      final requests = swapped['requests'] as List;
      final first = requests[0];
      requests[0] = requests[1];
      requests[1] = first;
      final encoded = copy(fixture.seedGolden);
      ((encoded['requests'] as List).first as Map)['rawQuery'] =
          'user=synthetic-a-user&pass=synthetic-a-pass%20';
      final extra = copy(fixture.seedGolden);
      (extra['requests'] as List).add(
        copy((extra['requests'] as List).first as Map<String, dynamic>),
      );
      for (final golden in [swapped, encoded, extra]) {
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: golden,
            phase: 'seed',
          ),
          throwsFormatException,
        );
      }
    });

    test('a trace or observation set that is not the corpus is refused', () {
      final noTrace = copy(fixture.seedGolden);
      (noTrace['stageTrace'] as List).removeLast();
      final swapped = copy(fixture.seedGolden);
      final observations = swapped['observations'] as List;
      final first = observations[0];
      observations[0] = observations[1];
      observations[1] = first;
      final unmatched = copy(fixture.seedGolden);
      (unmatched['unmatchedRequests'] as List).add({'path': '/x'});
      for (final golden in [noTrace, swapped, unmatched]) {
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: golden,
            phase: 'seed',
          ),
          throwsFormatException,
        );
      }
    });

    test(
      'a capture without its listener, ownership or provider receipt is refused',
      () {
        final listener = copy(fixture.seedGolden);
        ((listener['cleanup'] as Map) as Map<String, dynamic>)['replay'] = {
          'ok': false,
          'listenersClosed': false,
        };
        final owner = copy(fixture.restartGolden);
        ((owner['cleanup'] as Map) as Map<String, dynamic>)['scratchRemoved'] =
            false;
        final provider = copy(fixture.seedGolden);
        final preflight = ((provider['webView'] as Map)['preflight'] as Map)
            .cast<String, dynamic>();
        (preflight['provider'] as Map)['versionName'] = '0.0.0.0';
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: listener,
            phase: 'seed',
          ),
          throwsFormatException,
        );
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: owner,
            phase: 'restart',
          ),
          throwsFormatException,
        );
        expect(
          () => checkAuthSessionGolden(
            corpus: corpus,
            corpusSha256Lf: corpusLf,
            golden: provider,
            phase: 'seed',
          ),
          throwsFormatException,
        );
      },
    );
  });

  group('product comparison', () {
    late Fixture fixture;
    setUpAll(() => fixture = Fixture(corpus));

    test('the product pair passes when its cookie order is the frozen one', () {
      final report = fixture.compare();
      expect(report['status'], 'pass', reason: '${report['mismatches']}');
      expect(report['mismatches'], isEmpty);
      final notCompared = (report['notCompared'] as List).cast<Map>();
      expect(
        notCompared.every((row) => row['row'] != null),
        isTrue,
        reason: 'every carried difference names its approved row',
      );
      expect(
        [
          for (final row in notCompared)
            if (row['row'] == 'login-header-precedence') row,
        ],
        isNotEmpty,
        reason: 'source B declares X-Over in both maps',
      );
      expect(
        [
          for (final row in notCompared)
            if (row['row'] == 'session-tier') row,
        ],
        isNotEmpty,
        reason: 'the frozen probes carry two storage tiers',
      );
    });

    test('a product pair in the jar order fails on the raw cookie only', () {
      final jar = Fixture(corpus, jarOrder: true);
      final report = jar.compare();
      expect(report['status'], 'fail');
      final surfaces = surfacesOf(report).toSet();
      expect(surfaces, {'product-request-headers'});
      final orderOnly = (report['cookieOrderDifferences'] as List).cast<Map>();
      expect(orderOnly, isNotEmpty);
      expect(orderOnly.every((row) => row['pairsEqual'] == true), isTrue);
      expect(
        orderOnly.first['expected'],
        contains('sidA=two; extraA=e1; loginSessA=t1'),
      );
      expect(orderOnly.first['observed'], contains('loginSessA=t1; sidA=two'));
      final notCompared = (report['notCompared'] as List).cast<Map>();
      expect(notCompared.any((row) => row['row'] == 'session-tier'), isTrue);
    });

    test('a product probe in the jar order fails on the raw value only', () {
      final jar = Fixture(corpus, probeOrder: true);
      final report = jar.compare();
      expect(report['status'], 'fail');
      expect(surfacesOf(report).toSet(), {'observation-cookie-order'});
      final orderOnly = (report['cookieOrderDifferences'] as List).cast<Map>();
      expect(orderOnly, isNotEmpty);
      expect(orderOnly.every((row) => row['pairsEqual'] == true), isTrue);
    });

    test('a changed product value, identity, request or receipt fails', () {
      final value = copy(fixture.seedProduct);
      final observations = value['observations'] as List;
      ((observations.first as Map) as Map<String, dynamic>)['value'] = {
        'kind': 'login',
        'source': 'A',
      };
      expect(
        surfacesOf(fixture.compare(seedProduct: value)),
        contains('observation'),
      );

      final identity = copy(fixture.restartProduct);
      ((identity['identity'] as Map)
              as Map<String, dynamic>)['corpusSha256Lf'] =
          'ff' * 32;
      expect(
        surfacesOf(fixture.compare(restartProduct: identity)),
        contains('product-corpus-identity-restart'),
      );

      final extra = copy(fixture.seedProduct);
      (extra['requests'] as List).add({
        'method': 'GET',
        'path': '/a/mutated',
        'rawQuery': '',
        'headers': <String, String>{},
        'body': '',
      });
      expect(
        surfacesOf(fixture.compare(seedProduct: extra)),
        contains('product-request-count-seed'),
      );

      final cleanup = copy(fixture.restartProduct);
      ((cleanup['cleanup'] as Map) as Map<String, dynamic>)['scratchRemoved'] =
          false;
      expect(
        surfacesOf(fixture.compare(restartProduct: cleanup)),
        contains('product-restart-cleanup'),
      );
    });

    test('a reordered, re-encoded or absent raw query fails', () {
      for (final rawQuery in [
        'pass=synthetic-a-pass&user=synthetic-a-user',
        'user=synthetic-a-user&pass=synthetic-a-pass%20',
      ]) {
        final report = copy(fixture.seedProduct);
        ((report['requests'] as List).first as Map)['rawQuery'] = rawQuery;
        expect(
          surfacesOf(fixture.compare(seedProduct: report)),
          contains('product-requests'),
        );
      }
      final absent = copy(fixture.seedProduct);
      ((absent['requests'] as List).first as Map).remove('rawQuery');
      expect(
        surfacesOf(fixture.compare(seedProduct: absent)),
        contains('product-requests'),
      );
    });

    test('a changed cookie value or a reordered cookie header fails', () {
      Map<String, dynamic> withCookie(String value) {
        final report = copy(fixture.seedProduct);
        for (final raw in report['requests'] as List) {
          final headers = ((raw as Map)['headers'] as Map)
              .cast<String, Object?>();
          if (headers['cookie'] is String) {
            headers['cookie'] = value;
            return report;
          }
        }
        throw StateError('no request carries a cookie');
      }

      expect(
        surfacesOf(fixture.compare(seedProduct: withCookie('scriptA=mutated'))),
        contains('product-request-headers'),
      );
      final reordered = withCookie('loginRespA=p1; scriptA=one; loginSessA=t1');
      final report = fixture.compare(seedProduct: reordered);
      expect(report['status'], 'fail');
      expect(surfacesOf(report), contains('product-request-headers'));
    });

    test('the login-header precedence row accepts only the static value', () {
      int indexOfLoginWins() {
        final rows = fixture.seedGolden['requests'] as List;
        for (var index = 0; index < rows.length; index++) {
          final headers = ((rows[index] as Map)['headers'] as Map);
          if (headers['x-over'] == 'login') return index;
        }
        throw StateError('no frozen request shows the login header winning');
      }

      Map<String, dynamic> withXOver(String value) {
        final report = copy(fixture.seedProduct);
        final headers =
            (((report['requests'] as List)[indexOfLoginWins()]
                        as Map)['headers']
                    as Map)
                .cast<String, Object?>();
        headers['x-over'] = value;
        return report;
      }

      expect(
        surfacesOf(fixture.compare(seedProduct: withXOver('other'))),
        contains('product-request-headers'),
      );
      final matched = fixture.compare();
      expect(matched['status'], 'pass', reason: '${matched['mismatches']}');
      final precedence = [
        for (final row in (matched['notCompared'] as List).cast<Map>())
          if (row['row'] == 'login-header-precedence' &&
              row['header'] == 'x-over')
            row,
      ];
      expect(precedence, isNotEmpty);
      expect(precedence.first['expected'], 'login');
      expect(precedence.first['observed'], 'declared');
    });

    test('a product cookie probe that claims a session tier fails', () {
      final report = copy(fixture.seedProduct);
      final row =
          (report['observations'] as List).firstWhere(
                (raw) => (raw as Map)['id'] == 'seed.cookies.A.afterSearch',
              )
              as Map;
      final value = (row['value'] as Map).cast<String, Object?>();
      final probe = (value['A'] as Map).cast<String, Object?>();
      probe['session'] = 'ssA=s2';
      expect(
        surfacesOf(fixture.compare(seedProduct: report)),
        contains('observation-cookie-tier'),
      );
    });

    Map<String, Object?> afterProbe(Map<String, dynamic> report, String id) {
      final row =
          (report['observations'] as List).firstWhere(
                (raw) => (raw as Map)['id'] == id,
              )
              as Map;
      return ((row['value'] as Map)['after'] as Map).cast<String, Object?>();
    }

    test('the declared keys field is compared exactly, not re-derived', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      if (afterProbe(
            fixture.seedProduct,
            'seed.cookies.A.removeLoginHeader',
          )['effective'] !=
          '') {
        throw StateError('the fixture probe is not an empty jar');
      }
      const key =
          'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.keys';
      for (final mutation in <String, void Function(Map<String, Object?>)>{
        'a fabricated pair list': (probe) => probe['keys'] = [
          ['fabricated', 'cookie'],
        ],
        'a null field': (probe) => probe['keys'] = null,
        'an absent field': (probe) => probe.remove('keys'),
      }.entries) {
        final report = copy(fixture.seedProduct);
        mutation.value(afterProbe(report, 'seed.cookies.A.removeLoginHeader'));
        final compared = fixture.compare(seedProduct: report);
        expect(
          (compared['mismatchKeys'] as List).cast<String>().toSet().difference(
            baselineKeys,
          ),
          contains(key),
          reason: mutation.key,
        );
      }
    });

    test('the effective value keeps its type, including the empty case', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      const effectiveKey =
          'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.effective';
      const keysKey =
          'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.keys';

      final nulled = copy(fixture.seedProduct);
      final nullProbe = afterProbe(nulled, 'seed.cookies.A.removeLoginHeader');
      nullProbe['effective'] = null;
      nullProbe['persistent'] = null;
      expect(
        (fixture.compare(seedProduct: nulled)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        contains(effectiveKey),
      );

      final inconsistent = copy(fixture.seedProduct);
      final staleProbe = afterProbe(
        inconsistent,
        'seed.cookies.A.removeLoginHeader',
      );
      staleProbe['effective'] = 'fabricated=value';
      staleProbe['persistent'] = 'fabricated=value';
      final stale =
          (fixture.compare(seedProduct: inconsistent)['mismatchKeys'] as List)
              .cast<String>()
              .toSet()
              .difference(baselineKeys);
      expect(stale, contains(effectiveKey));
      expect(
        stale,
        contains(keysKey),
        reason: 'the declared pairs no longer agree with the effective value',
      );
    });

    test('the session-pair allowance is restart-only', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      final seedProbe = afterProbe(
        fixture.seedProduct,
        'seed.cookies.A.removeLoginHeader',
      );
      final future = 'ssA=after; ss2=sx2';
      final mutated = copy(fixture.seedProduct);
      final probe = afterProbe(mutated, 'seed.cookies.A.removeLoginHeader');
      probe['effective'] = future;
      probe['persistent'] = future;
      probe['keys'] = authSessionCookiePairs(future);
      final compared = fixture.compare(seedProduct: mutated);
      final newKeys = (compared['mismatchKeys'] as List)
          .cast<String>()
          .toSet()
          .difference(baselineKeys);
      expect(
        newKeys,
        contains(
          'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.effective',
        ),
      );
      // The only policy row left is the ordinary persistent/session shape one;
      // the effective/pair allowance itself never reaches a seed observation.
      expect([
        for (final row in (compared['notCompared'] as List).cast<Map>())
          if ('${row['path']}'.startsWith('seed.cookies.A.removeLoginHeader'))
            '${row['path']}',
      ], isNot(contains('seed.cookies.A.removeLoginHeader.after.effective')));
      expect([
        for (final row in (compared['notCompared'] as List).cast<Map>())
          if ('${row['path']}'.startsWith('seed.cookies.A.removeLoginHeader'))
            '${row['path']}',
      ], isNot(contains('seed.cookies.A.removeLoginHeader.after.keys')));
      expect(seedProbe['effective'], '');
    });

    test('the restart keeps its bounded session-pair extension', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      final report = copy(fixture.restartProduct);
      final row =
          (report['observations'] as List).firstWhere(
                (raw) => (raw as Map)['id'] == 'restart.cookies.before',
              )
              as Map;
      final probe = ((row['value'] as Map)['A'] as Map).cast<String, Object?>();
      const extended = 'sidA=after; extraA=e2; ssA=after; ss2=sx2';
      probe['effective'] = extended;
      probe['persistent'] = extended;
      probe['keys'] = authSessionCookiePairs(extended);
      final compared = fixture.compare(restartProduct: report);
      expect(
        (compared['mismatchKeys'] as List).cast<String>().toSet().difference(
          baselineKeys,
        ),
        isEmpty,
        reason: 'the recorded seed session pairs are the authorized extension',
      );
      final policy = [
        for (final entry in (compared['notCompared'] as List).cast<Map>())
          if (entry['row'] == 'session-tier' &&
              '${entry['path']}'.startsWith('restart.cookies.before'))
            '${entry['path']}',
      ];
      expect(policy, contains('restart.cookies.before.A.keys'));
      expect(policy, contains('restart.cookies.before.A.effective'));
    });

    test('the one-tier claim requires both mandatory fields to be present', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      const direct =
          'observation-cookie-tier|seed|seed.cookies.A.removeLoginHeader.after';
      const nested = 'observation-cookie-tier|seed|seed.state.seed.cookies.A';
      Map<String, Object?> directProbe(Map<String, dynamic> report) =>
          afterProbe(report, 'seed.cookies.A.removeLoginHeader');
      Map<String, Object?> nestedProbe(Map<String, dynamic> report) {
        final row =
            (report['observations'] as List).firstWhere(
                  (raw) => (raw as Map)['id'] == 'seed.state.seed',
                )
                as Map;
        return ((row['value'] as Map)['cookies'] as Map)['A']
            as Map<String, Object?>;
      }

      // Both probe shapes route through the same guard.
      for (final entry
          in <
                String,
                (String, Map<String, Object?> Function(Map<String, dynamic>))
              >{
                'the direct probe without session': (direct, directProbe),
                'the nested probe without session': (nested, nestedProbe),
              }
              .entries) {
        final report = copy(fixture.seedProduct);
        entry.value.$2(report).remove('session');
        expect(
          (fixture.compare(seedProduct: report)['mismatchKeys'] as List)
              .cast<String>()
              .toSet()
              .difference(baselineKeys),
          contains(entry.value.$1),
          reason: entry.key,
        );
      }

      // The other two mandatory-field failures keep their key.
      final nonNull = copy(fixture.seedProduct);
      directProbe(nonNull)['session'] = 'invented=value';
      expect(
        (fixture.compare(seedProduct: nonNull)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        contains(direct),
      );
      final noPersistent = copy(fixture.seedProduct);
      directProbe(noPersistent).remove('persistent');
      expect(
        (fixture.compare(seedProduct: noPersistent)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        contains(direct),
      );

      // An explicit null session is the ordinary shape and adds nothing.
      expect(
        (baseline['mismatchKeys'] as List).cast<String>().toSet(),
        baselineKeys,
      );
      expect(
        [
          for (final row in (baseline['notCompared'] as List).cast<Map>())
            if ('${row['path']}' == 'seed.state.seed.cookies.A.keys') row,
        ],
        isEmpty,
        reason: 'the unmutated explicit-null probe is not a policy row',
      );
    });

    test('an unknown restart cookie addition still fails', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      final report = copy(fixture.restartProduct);
      final row =
          (report['observations'] as List).firstWhere(
                (raw) => (raw as Map)['id'] == 'restart.cookies.before',
              )
              as Map;
      final probe = ((row['value'] as Map)['A'] as Map).cast<String, Object?>();
      const extra = 'sidA=after; extraA=e2; ssA=after; ss2=sx2; evil=1';
      probe['effective'] = extra;
      probe['persistent'] = extra;
      probe['keys'] = authSessionCookiePairs(extra);
      expect(
        (fixture.compare(restartProduct: report)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        contains(
          'observation-cookie|restart|restart.cookies.before.A.effective',
        ),
      );
    });

    test('nullable presence is compared, not only its null value', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      Map<String, Object?> probeOf(Map<String, dynamic> report, String id) {
        final row =
            (report['observations'] as List).firstWhere(
                  (raw) => (raw as Map)['id'] == id,
                )
                as Map;
        return ((row['value'] as Map)['after'] as Map).cast<String, Object?>();
      }

      void expectNewKey(
        String name,
        String key,
        void Function(Map<String, dynamic>) mutate, {
        bool restart = false,
      }) {
        final report = restart
            ? copy(fixture.restartProduct)
            : copy(fixture.seedProduct);
        mutate(report);
        final compared = restart
            ? fixture.compare(restartProduct: report)
            : fixture.compare(seedProduct: report);
        expect(
          (compared['mismatchKeys'] as List).cast<String>().toSet().difference(
            baselineKeys,
          ),
          contains(key),
          reason: name,
        );
      }

      for (final entry in <String, String>{
        'the seed probe loses loginHeader':
            'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.loginHeader',
        'the seed probe loses loginHeaderMap':
            'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.loginHeaderMap',
      }.entries) {
        final field = entry.value.split('.').last;
        expectNewKey(entry.key, entry.value, (report) {
          probeOf(report, 'seed.cookies.A.removeLoginHeader').remove(field);
        });
      }
      for (final entry in <String, (String, String)>{
        'the ordinary restart observation loses loginHeader': (
          'loginHeader',
          'observation|restart|loginHeader|restart.headers.A',
        ),
        'the ordinary restart observation loses loginHeaderMap': (
          'loginHeaderMap',
          'observation|restart|loginHeaderMap|restart.headers.A',
        ),
      }.entries) {
        final field = entry.value.$1;
        expectNewKey(entry.key, entry.value.$2, (report) {
          final row =
              (report['observations'] as List).firstWhere(
                    (raw) => (raw as Map)['id'] == 'restart.headers.A',
                  )
                  as Map;
          (row['value'] as Map).remove(field);
        }, restart: true);
      }

      // A nested probe's nullable field, an extra null field only the product
      // carries, and a changed non-null value.
      final nested = copy(fixture.seedProduct);
      final stateRow =
          (nested['observations'] as List).firstWhere(
                (raw) => (raw as Map)['id'] == 'seed.state.seed',
              )
              as Map;
      (((stateRow['value'] as Map)['cookies'] as Map)['A'] as Map).remove(
        'loginHeaderMap',
      );
      expect(
        (fixture.compare(seedProduct: nested)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        contains(
          'observation-cookie|seed|seed.state.seed.cookies.A.loginHeaderMap',
        ),
      );
      expectNewKey(
        'an extra null field',
        'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.extraNull',
        (report) =>
            probeOf(report, 'seed.cookies.A.removeLoginHeader')['extraNull'] =
                null,
      );
      expectNewKey(
        'a changed non-null value',
        'observation-cookie|seed|seed.cookies.A.removeLoginHeader.after.loginHeader',
        (report) =>
            probeOf(report, 'seed.cookies.A.removeLoginHeader')['loginHeader'] =
                '{"X":"changed"}',
      );
    });

    test('a completed phase needs a clean terminal receipt', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      for (final entry in <String, void Function(Map<String, dynamic>)>{
        'serverErrors removed': (report) => report.remove('serverErrors'),
        'serverErrors not a list': (report) => report['serverErrors'] = 'none',
        'serverErrors carrying an error': (report) => report['serverErrors'] = [
          {'error': 'late'},
        ],
        'analysisFailure not null': (report) =>
            report['analysisFailure'] = 'boom',
        'analysisFailure removed': (report) => report.remove('analysisFailure'),
      }.entries) {
        final report = copy(fixture.seedProduct);
        entry.value(report);
        expect(
          (fixture.compare(seedProduct: report)['mismatchKeys'] as List)
              .cast<String>()
              .toSet()
              .difference(baselineKeys),
          contains('product-terminal-seed|seed'),
          reason: entry.key,
        );
      }
    });

    test(
      'each stage trace entry is the captured causal entry for its request',
      () {
        final baseline = fixture.compare();
        final baselineKeys = (baseline['mismatchKeys'] as List)
            .cast<String>()
            .toSet();
        void expectTraceFailure(
          String name,
          void Function(List<dynamic>) change,
        ) {
          final report = copy(fixture.seedProduct);
          change(report['stageTrace'] as List);
          expect(
            (fixture.compare(seedProduct: report)['mismatchKeys'] as List)
                .cast<String>()
                .toSet()
                .difference(baselineKeys),
            contains('product-stage-trace|seed|0'),
            reason: name,
          );
        }

        expectTraceFailure('stage changed', (trace) {
          (trace[0] as Map)['stage'] = 'seed.content.A';
        });
        expectTraceFailure('target changed', (trace) {
          (trace[0] as Map)['target'] = '/a/forged?x=1';
        });
        expectTraceFailure('listener changed', (trace) {
          (trace[0] as Map)['listener'] = '127.0.0.2';
        });
        expectTraceFailure('entry is not a map', (trace) {
          trace[0] = 'seed.login.A';
        });
        expectTraceFailure('entry carries an extra field', (trace) {
          (trace[0] as Map)['note'] = 'forged';
        });
        expectTraceFailure('every entry forged at the same length', (trace) {
          for (final entry in trace.cast<Map>()) {
            entry['target'] = '/a/forged';
          }
        });
      },
    );

    Map<String, dynamic> withRestartSessionPairs({
      String extra = 'ssA=after; ss2=sx2',
    }) {
      final report = copy(fixture.restartProduct);
      for (final raw in report['requests'] as List) {
        final request = raw as Map;
        if (!'${request['path']}'.startsWith('/a/')) continue;
        final headers = (request['headers'] as Map).cast<String, Object?>();
        headers['cookie'] = '${headers['cookie']}; $extra';
      }
      return report;
    }

    test('the restart session-only wire pairs are the existing divergence', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      final compared = fixture.compare(
        restartProduct: withRestartSessionPairs(),
      );
      expect(
        (compared['mismatchKeys'] as List).cast<String>().toSet().difference(
          baselineKeys,
        ),
        isEmpty,
        reason: 'the recorded seed session pairs are the existing row',
      );
      final rows = [
        for (final entry in (compared['notCompared'] as List).cast<Map>())
          if (entry['kind'] == 'restart-session-cookie-wire') entry,
      ];
      expect(rows, isNotEmpty);
      expect(
        rows.every(
          (row) => row['row'] == 'session-tier' && row['phase'] == 'restart',
        ),
        isTrue,
      );
      expect(rows.first['attributed'], [
        ['ssA', 'after'],
        ['ss2', 'sx2'],
      ]);
      expect('${rows.first['expected']}', contains('sidA='));
      expect('${rows.first['observed']}', contains('ssA=after'));
      expect('${rows.first['reason']}', contains(':132'));
    });

    test('the restart attribution rejects every other change', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      Map<String, dynamic> mutated(void Function(List<dynamic>) change) {
        final report = withRestartSessionPairs();
        change(report['requests'] as List);
        return report;
      }

      final cases = <String, Map<String, dynamic>>{
        'a wrong session value': withRestartSessionPairs(
          extra: 'ssA=after; ss2=other',
        ),
        'a missing session pair': withRestartSessionPairs(extra: 'ssA=after'),
        'an unknown extra cookie': withRestartSessionPairs(
          extra: 'ssA=after; ss2=sx2; evil=1',
        ),
        'a duplicated session pair': withRestartSessionPairs(
          extra: 'ssA=after; ss2=sx2; ssA=after',
        ),
        'reordered frozen pairs': mutated((requests) {
          for (final raw in requests) {
            final request = raw as Map;
            if (!'${request['path']}'.startsWith('/a/')) continue;
            final headers = (request['headers'] as Map).cast<String, Object?>();
            headers['cookie'] = 'extraA=e2; sidA=after; ssA=after; ss2=sx2';
          }
        }),
        'a changed frozen value': mutated((requests) {
          for (final raw in requests) {
            final request = raw as Map;
            if (!'${request['path']}'.startsWith('/a/')) continue;
            final headers = (request['headers'] as Map).cast<String, Object?>();
            headers['cookie'] = 'sidA=changed; ssA=after; ss2=sx2';
          }
        }),
      };
      for (final entry in cases.entries) {
        final added =
            (fixture.compare(restartProduct: entry.value)['mismatchKeys']
                    as List)
                .cast<String>()
                .toSet()
                .difference(baselineKeys);
        expect(
          added.any((key) => key.startsWith('product-request-headers|restart')),
          isTrue,
          reason: '${entry.key}: $added',
        );
      }

      // The seed phase never gets the restart attribution.
      final seed = copy(fixture.seedProduct);
      for (final raw in seed['requests'] as List) {
        final request = raw as Map;
        if (!'${request['path']}'.startsWith('/a/')) continue;
        final headers = (request['headers'] as Map).cast<String, Object?>();
        headers['cookie'] = '${headers['cookie']}; ssA=after; ss2=sx2';
      }
      expect(
        (fixture.compare(seedProduct: seed)['mismatchKeys'] as List)
            .cast<String>()
            .toSet()
            .difference(baselineKeys),
        isNotEmpty,
        reason: 'a seed phase keeps the wire value strict',
      );
    });

    test('the restart attribution keeps the raw wire text exact', () {
      final baseline = fixture.compare();
      final baselineKeys = (baseline['mismatchKeys'] as List)
          .cast<String>()
          .toSet();
      final valid = withRestartSessionPairs();
      Map<String, dynamic> withCookie(String cookie) {
        final report = copy(valid);
        final request = (report['requests'] as List).first as Map;
        (request['headers'] as Map).cast<String, Object?>()['cookie'] = cookie;
        return report;
      }

      String firstCookie(Map<String, dynamic> report) {
        final request = (report['requests'] as List).first as Map;
        return '${(request['headers'] as Map)['cookie']}';
      }

      final baselineCookie = firstCookie(valid);
      // The recorded session pairs, and the frozen header they were added to.
      expect(baselineCookie, endsWith('; ssA=after; ss2=sx2'));

      final cases = <String, String>{
        // The five controller counterexamples: each changes wire text outside
        // the exact permitted addition.
        'a bare fragment appended': '$baselineCookie; controller-unparsed',
        'an empty name appended': '$baselineCookie; =controller-unparsed',
        'an empty segment inserted': baselineCookie.replaceFirst('; ', ';; '),
        'a separator without its space': baselineCookie.replaceFirst('; ', ';'),
        'a trailing space on a frozen value': baselineCookie.replaceFirst(
          'sidA=two;',
          'sidA=two ;',
        ),
        // The same boundary at the head, in the middle and with other spelling
        // changes.
        'a bare fragment prepended': 'controller-unparsed; $baselineCookie',
        'a bare fragment in the middle': baselineCookie.replaceFirst(
          '; extraA=',
          '; controller-unparsed; extraA=',
        ),
        'a tab separator': baselineCookie.replaceFirst('; ', ';\t'),
        'a dropped separator': baselineCookie.replaceFirst(
          '; extraA=',
          ' extraA=',
        ),
        'a duplicated session pair': '$baselineCookie; ssA=after',
        'a changed session value': baselineCookie.replaceFirst(
          'ssA=after',
          'ssA=bad',
        ),
        'an unknown cookie pair': '$baselineCookie; evil=1',
        'a truncated trailing session pair': baselineCookie.replaceFirst(
          '; ss2=sx2',
          '; ss2',
        ),
      };
      for (final entry in cases.entries) {
        final added =
            (fixture.compare(
                      restartProduct: withCookie(entry.value),
                    )['mismatchKeys']
                    as List)
                .cast<String>()
                .toSet()
                .difference(baselineKeys);
        expect(
          added,
          contains('product-request-headers|restart|0|cookie'),
          reason: entry.key,
        );
      }

      // The permitted attribution itself adds nothing and keeps its evidence.
      final permitted = fixture.compare(restartProduct: valid);
      expect(
        (permitted['mismatchKeys'] as List).cast<String>().toSet().difference(
          baselineKeys,
        ),
        isEmpty,
      );
      final rows = [
        for (final row in (permitted['notCompared'] as List).cast<Map>())
          if (row['kind'] == 'restart-session-cookie-wire') row,
      ];
      expect(rows, isNotEmpty);
      expect(rows.first['attributedSegments'], [' ssA=after', ' ss2=sx2']);
      expect('${rows.first['frozenHeader']}', isNot(contains('ssA=after')));
    });

    test('the restart of another seed is refused', () {
      final report = copy(fixture.restartProduct);
      ((report['owner'] as Map) as Map<String, dynamic>)['seedRunId'] =
          'another-run';
      expect(
        surfacesOf(fixture.compare(restartProduct: report)),
        contains('restart-read-this-seed'),
      );
    });
  });

  group('handoff binding', () {
    late Fixture fixture;
    setUpAll(() => fixture = Fixture(corpus));

    Map<String, dynamic> handoff() => {
      'status': 'captured',
      'fixtureId': corpus['fixtureId'],
      'corpusVersion': corpus['corpusVersion'],
      'baselineCommit': corpus['baselineCommit'],
      'entryPoint': corpus['entryPoint'],
      'corpus': {'path': corpusPath, 'sha256Lf': corpusLf},
      'harness': {
        'sha256':
            '54695a2bee29ba7ae69ab08b79276e3cf548ff526c20eea2b76a5a53c8ddce0f',
        'targetPackage': (corpus['target'] as Map)['package'],
        'targetApkSha256': (corpus['target'] as Map)['apkSha256'],
      },
      'device': {
        'serial': '5615f742',
        'fingerprint': fixture.seedGolden['fingerprint'],
        'provider': {
          'package': 'com.google.android.webview',
          'version': '157.0.8103.5',
        },
      },
      'captures': [
        {
          'seed': {
            'pid': fixture.seedGolden['pid'],
            'runId': fixture.seedGolden['runId'],
            'report': {'sha256': sha256Text('seed')},
          },
          'restart': {
            'pid': fixture.restartGolden['pid'],
            'runId': fixture.restartGolden['runId'],
            'report': {'sha256': sha256Text('restart')},
          },
        },
      ],
    };

    test('a handoff that pins this corpus, harness and device is accepted', () {
      final report = compareAuthSessionPhases(
        corpus: corpus,
        corpusSha256Lf: corpusLf,
        seedGolden: fixture.seedGolden,
        restartGolden: fixture.restartGolden,
        seedProduct: fixture.seedProduct,
        restartProduct: fixture.restartProduct,
        handoff: handoff(),
        seedGoldenSha256: sha256Text('seed'),
        restartGoldenSha256: sha256Text('restart'),
      );
      expect(report['status'], 'pass', reason: '${report['mismatches']}');
    });

    test('another corpus, harness, device or captured process is refused', () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (value) => (value['corpus'] as Map)['sha256Lf'] = 'ff' * 32,
        (value) => (value['harness'] as Map)['sha256'] = 'ff' * 32,
        (value) => (value['device'] as Map)['fingerprint'] = 'other',
        (value) =>
            (((value['captures'] as List).first as Map)['seed'] as Map)['pid'] =
                1,
      ]) {
        final value = handoff();
        mutate(value);
        expect(() => fixture.compare(handoff: value), throwsFormatException);
      }
    });
  });

  test('selected AUTH login provenance rejects an altered invocation tail', () {
    // Admission prefix only, not a native capture or a complete envelope.
    final file = File('tool/auth_session/fixtures-selected.json');
    final selected = loadAuthSessionCorpus(file.path);
    final lf = authSessionCorpusSha256Lf(file);
    final target = authSessionTargetOf(selected);
    final initialization = selected['hostInitialization'] as Map;
    final loginSteps = authSessionSteps(
      selected,
      'seed',
    ).where((step) => step['kind'] == 'login');
    final receipt = <String, Object?>{
      'java': 'io.legado.app.ui.login.SourceLoginJsExtensions',
      'extensionConstructor': 'SourceLoginJsExtensions(null, source, 0, null)',
      'uiCallbacksExecuted': false,
      'result': 'loginData',
      'bindings': ['java', 'result', 'book', 'chapter', 'isLongClick'],
      'invocationTail':
          "login.apply(this); throw('Function login not implements')",
    };
    final prefix = <String, dynamic>{
      'phase': 'seed',
      'fixtureId': selected['fixtureId'],
      'corpusVersion': selected['corpusVersion'],
      'baselineCommit': selected['baselineCommit'],
      'entryPoint': selected['entryPoint'],
      'identity': {
        'fixtureId': selected['fixtureId'],
        'corpusVersion': selected['corpusVersion'],
        'targetPackage': target['package'],
        'targetApkSha256': target['apkSha256'],
        'targetBaselineCommit': selected['baselineCommit'],
        'targetPinManifest': target['manifest'],
        'corpusAssetSha256': lf,
        'corpusSha256Lf': lf,
        'harnessApkSha256': 'a' * 64,
        'harnessPackage': 'synthetic.admission.prefix',
      },
      'hostInitialization': {
        'verified': true,
        'method': initialization['method'],
        'invokedOn': 'unattached-instance',
        'applicationAttached': false,
        'registeredWrappers': {
          for (final registration
              in (initialization['registrations'] as List).cast<Map>())
            '${registration['type']}': registration['factory'],
        },
      },
      'startupContainment': {
        'service': 'shortcut',
        'provider': 'io.legado.app.api.ReaderProvider',
        'intercepted': 1,
        'handled': 1,
        'beforeBinding': true,
      },
      'loginBindings': {
        for (final step in loginSteps) '${step['id']}': receipt,
      },
    };
    void check(String phase) => checkAuthSessionGolden(
      corpus: selected,
      corpusSha256Lf: lf,
      golden: prefix,
      phase: phase,
    );
    Matcher refusal(String message) => throwsA(
      isA<FormatException>().having(
        (error) => error.message,
        'message',
        contains(message),
      ),
    );
    expect(() => check('seed'), refusal('login invocation'));
    receipt['invocationTail'] =
        "if (typeof login=='function'){ login.apply(this); } else {"
        " throw('Function login not implements!!!') }";
    // The prefix now clears the login gate, then fails the deliberately absent
    // pid. This is not evidence of admission of a complete capture.
    expect(() => check('seed'), refusal('pid is not an integer'));
    (prefix['loginBindings'] as Map).remove('${loginSteps.first['id']}');
    expect(() => check('seed'), refusal('exactly this phase'));
    prefix['phase'] = 'restart';
    prefix['loginBindings'] = <String, Object?>{};
    expect(() => check('restart'), refusal('pid is not an integer'));
    prefix['loginBindings'] = null;
    expect(() => check('restart'), refusal('login bindings'));
  });

  test(
    'selected AUTH complete synthetic seed and restart receipts are phase-bound',
    () {
      final file = File('tool/auth_session/fixtures-selected.json');
      final selected = loadAuthSessionCorpus(file.path);
      final lf = authSessionCorpusSha256Lf(file);
      final fixture = Fixture(selected);
      Map<String, dynamic> selectedEnvelope(String phase) {
        final envelope = fixture.golden(phase);
        final identity = envelope['identity'] as Map;
        identity['corpusAssetSha256'] = lf;
        identity['corpusSha256Lf'] = lf;
        final provider =
            (((envelope['webView'] as Map)['preflight'] as Map)['provider']
                as Map);
        provider['versionName'] =
            (selected['webViewProvider'] as Map)['versionName'];
        final initialization = selected['hostInitialization'] as Map;
        envelope['hostInitialization'] = {
          'verified': true,
          'method': initialization['method'],
          'invokedOn': 'unattached-instance',
          'applicationAttached': false,
          'registeredWrappers': {
            for (final registration
                in (initialization['registrations'] as List).cast<Map>())
              '${registration['type']}': registration['factory'],
          },
        };
        envelope['startupContainment'] = {
          'service': 'shortcut',
          'provider': 'io.legado.app.api.ReaderProvider',
          'intercepted': 1,
          'handled': 1,
          'beforeBinding': true,
        };
        envelope['loginBindings'] = {
          for (final step in authSessionSteps(selected, phase))
            if (step['kind'] == 'login')
              '${step['id']}': {
                'java': 'io.legado.app.ui.login.SourceLoginJsExtensions',
                'extensionConstructor':
                    'SourceLoginJsExtensions(null, source, 0, null)',
                'uiCallbacksExecuted': false,
                'result': 'loginData',
                'bindings': [
                  'java',
                  'result',
                  'book',
                  'chapter',
                  'isLongClick',
                ],
                'invocationTail':
                    "if (typeof login=='function'){ login.apply(this); } else { throw('Function login not implements!!!') }",
              },
        };
        return envelope;
      }

      final seed = selectedEnvelope('seed');
      final restart = selectedEnvelope('restart');
      void pair(Map<String, dynamic> a, Map<String, dynamic> b) =>
          checkAuthSessionGoldenPair(
            corpus: selected,
            corpusSha256Lf: lf,
            seed: a,
            restart: b,
          );
      expect(() => pair(seed, restart), returnsNormally);
      final mutationsForCli =
          <({Map<String, dynamic> seed, Map<String, dynamic> restart})>[];
      for (final mutate
          in <void Function(Map<String, dynamic>, Map<String, dynamic>)>[
            (a, b) => (a['loginBindings'] as Map).remove('seed.login.A'),
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A']
                        as Map)['invocationTail'] =
                    'other',
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A'] as Map)['result'] =
                    'other',
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A']
                    as Map)['bindings'] = [
                  'java',
                ],
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A']
                    as Map)['bindings'] = [
                  'java',
                  'result',
                  'book',
                  'chapter',
                  'isLongClick',
                  'extra',
                ],
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A']
                        as Map)['bindings'] =
                    'not-a-list',
            (a, b) =>
                ((a['loginBindings'] as Map)['seed.login.A']
                    as Map)['bindings'] = [
                  1,
                  2,
                  3,
                  4,
                  5,
                ],
            (a, b) => (a['hostInitialization'] as Map)['verified'] = false,
            (a, b) =>
                ((a['hostInitialization'] as Map)['registeredWrappers'] as Map)
                    .clear(),
            (a, b) => (b['startupContainment'] as Map)['intercepted'] = 0,
            (a, b) => (b['startupContainment'] as Map)['intercepted'] = 1.0,
            (a, b) => (b['startupContainment'] as Map)['handled'] = 1.0,
            (a, b) => (b['loginBindings'] as Map)['seed.login.A'] = {},
            (a, b) => b.remove('loginBindings'),
          ]) {
        final a = copy(seed);
        final b = copy(restart);
        mutate(a, b);
        expect(() => pair(a, b), throwsFormatException);
        mutationsForCli.add((seed: a, restart: b));
      }
      // Optional external admission fixtures for the actual controls-only CLI.
      // These are synthetic envelopes, never native captures or new goldens.
      final output = Platform.environment['LIBER_SYNTHETIC_AUTH_OUT'];
      if (output != null && output.isNotEmpty) {
        final directory = Directory(output)..createSync(recursive: true);
        final capture = Directory('${directory.path}/capture')..createSync();
        void write(String path, Map<String, dynamic> value) =>
            File(path).writeAsStringSync(jsonEncode(value));
        write('${capture.path}/seed-report.json', seed);
        write('${capture.path}/restart-report.json', restart);
        final mutationDir = Directory('${directory.path}/receipt-mutations')
          ..createSync();
        for (var index = 0; index < mutationsForCli.length; index++) {
          write(
            '${mutationDir.path}/$index-seed.json',
            mutationsForCli[index].seed,
          );
          write(
            '${mutationDir.path}/$index-restart.json',
            mutationsForCli[index].restart,
          );
        }
        for (final phase in ['seed', 'restart']) {
          final product = fixture.product(phase);
          final identity = product['identity'] as Map;
          identity['corpusSha256Lf'] = lf;
          identity['corpusRawSha256'] = sha256File(file);
          identity['corpusPath'] = file.path;
          write('${directory.path}/product-$phase.json', product);
        }
        final historical = Fixture(readCorpus());
        final historicalRoot = Directory('${directory.path}/historical')
          ..createSync();
        final historicalCapture = Directory('${historicalRoot.path}/capture')
          ..createSync();
        for (final phase in ['seed', 'restart']) {
          write(
            '${historicalCapture.path}/$phase-report.json',
            historical.golden(phase),
          );
          write(
            '${historicalRoot.path}/product-$phase.json',
            historical.product(phase),
          );
        }
      }
    },
  );

  test(
    'the selected-reference AUTH corpus names the selected target and corpus',
    () {
      final selected = loadAuthSessionCorpus(
        'tool/auth_session/fixtures-selected.json',
      );
      expect(selected['corpusVersion'], 2);
      final target = selected['target'] as Map;
      expect(target['package'], 'com.legado.app.debug');
      expect(
        target['apkSha256'],
        '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
      );
      expect(
        target['baselineCommit'],
        'a7d37f1707a70a459ad708f4fe79341d1e42d716',
      );
      expect(selected['hostInitialization'], isA<Map>());
      expect(
        (selected['hostInitialization'] as Map)['method'],
        'io.legado.app.App#initRhino()',
      );
      // The form graph, sources and request declarations are the historical ones.
      final historical = loadAuthSessionCorpus();
      expect(
        ((selected['phases'] as Map)['seed'] as Map)['expectedRequests'],
        ((historical['phases'] as Map)['seed'] as Map)['expectedRequests'],
      );
      expect(
        ((selected['phases'] as Map)['restart'] as Map)['steps'],
        ((historical['phases'] as Map)['restart'] as Map)['steps'],
      );
    },
  );
}
