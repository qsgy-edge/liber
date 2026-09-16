import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';

/// The controlled four-stage corpus of the first end-to-end compatibility
/// slice. See `tool/first_slice/README.md` and
/// `docs/compatibility/first-slice.md`.
const sliceFixturePath = 'tool/first_slice/fixtures.json';

/// Loads the corpus. The caller passes the path explicitly so a re-recorded
/// copy can be compared without editing the repository copy.
Map<String, dynamic> loadSliceFixture([String path = sliceFixturePath]) =>
    (jsonDecode(File(path).readAsStringSync()) as Map).cast<String, dynamic>();

/// The replay server the corpus declares: every response comes from
/// `responses`, an undeclared request is answered 404 and recorded, and the
/// port is the one the fixture's `bookSourceUrl` names, because the source
/// object is part of the compared inputs.
class SliceReplayServer {
  SliceReplayServer._(this._server, this._fixture);

  static Future<SliceReplayServer> start(Map<String, dynamic> fixture) async {
    final origin = Uri.parse(fixture['origin'] as String);
    final HttpServer server;
    try {
      server = await HttpServer.bind(origin.host, origin.port);
    } on SocketException catch (error) {
      throw StateError(
        'the corpus origin ${fixture['origin']} is busy: ${error.message}. '
        'The port is fixed because the source object is a compared input; '
        'stop whatever holds it instead of moving the corpus.',
      );
    }
    final instance = SliceReplayServer._(server, fixture);
    server.listen(instance._handle);
    return instance;
  }

  final HttpServer _server;
  final Map<String, dynamic> _fixture;

  /// Every request the server received, in order, as observed.
  final requests = <Map<String, Object?>>[];

  /// Requests the corpus declares no response for.
  final unmatched = <Map<String, Object?>>[];

  Uri get origin => Uri.parse('http://${_server.address.address}:${_server.port}');

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
    final observed = <String, Object?>{
      'method': request.method,
      'path': request.uri.path,
      'query': request.uri.queryParameters,
      'rawQuery': request.uri.query,
      'headers': headers,
      'body': body,
    };
    requests.add(observed);
    final declared = _match(request.method, request.uri.path, request.uri.queryParameters);
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
    final declaredCookies =
        (declared['setCookies'] as List?)?.cast<Map>() ?? const <Map>[];
    for (final cookie in declaredCookies) {
      request.response.cookies.add(
        Cookie('${cookie['name']}', '${cookie['value']}')
          ..path = cookie['path'] as String? ?? '/',
      );
    }
    request.response.add(utf8.encode(declared['body'] as String? ?? ''));
    await request.response.close();
  }

  /// The declared response for one request.
  ///
  /// A response that declares a `query` wins over one that does not, and a
  /// declared query must match the decoded request query exactly; a response
  /// without a `query` serves whatever query arrives. The frozen oracle
  /// implements the same rule, so both sides answer a request identically.
  Map<String, dynamic>? _match(
    String method,
    String path,
    Map<String, String> query,
  ) {
    final candidates = [
      for (final response in (_fixture['responses'] as List).cast<Map>())
        if (response['method'] == method && response['path'] == path)
          response.cast<String, dynamic>(),
    ];
    for (final candidate in candidates) {
      final declared = (candidate['query'] as Map?)?.cast<String, String>();
      if (declared == null) continue;
      if (declared.length == query.length &&
          declared.entries.every((entry) => query[entry.key] == entry.value)) {
        return candidate;
      }
    }
    for (final candidate in candidates) {
      if (candidate['query'] == null) return candidate;
    }
    return null;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }
}

/// One scenario-shape check: the fixture ran as the corpus declares it.
///
/// These are not compatibility claims. They say the corpus is healthy and the
/// product reached the stages the slice names; the frozen side of every row
/// stays `not-run` until the oracle golden exists.
class SliceInvariant {
  const SliceInvariant(this.id, this.ok, this.detail);

  final String id;
  final bool ok;
  final String detail;
}

/// What one run of the corpus observed.
class SliceRunResult {
  const SliceRunResult({
    required this.requests,
    required this.unmatched,
    required this.stageTrace,
    required this.stages,
    required this.invariants,
    required this.failure,
  });

  final List<Map<String, Object?>> requests;
  final List<Map<String, Object?>> unmatched;
  final List<Map<String, String>> stageTrace;
  final Map<String, Object?> stages;
  final List<SliceInvariant> invariants;

  /// The analysis error, when a stage threw; null on a completed run.
  final String? failure;

  bool get scenarioPassed =>
      failure == null && invariants.every((invariant) => invariant.ok);
}

/// Runs the corpus through the product pipeline on the host platform.
///
/// The native library must already be initialized (`NativeLibrary.initialize`).
Future<SliceRunResult> runSliceFixture({
  required Map<String, dynamic> fixture,
}) async {
  final server = await SliceReplayServer.start(fixture);
  var pipeline = HtmlSourcePipeline(
    (fixture['source'] as Map).cast<String, dynamic>(),
    HttpSourceTransport(),
  );
  final stages = <String, Object?>{};
  String? failure;
  try {
    final hits = await pipeline.search(fixture['keyword'] as String);
    stages['search'] = {
      'results': [
        for (final hit in hits)
          {
            'name': hit.title,
            'author': hit.author,
            'kind': hit.kind,
            'bookUrl': '${hit.url}',
          },
      ],
    };
    final (book, chapters) = await pipeline.details(hits.first);
    stages['bookInfo'] = {
      'name': book.title,
      'author': book.author,
      'kind': book.kind,
      'lastChapter': book.lastChapter,
      'cover': book.cover,
      'intro': book.intro,
    };
    stages['toc'] = {
      'pages': pipeline.tocPages,
      'chapters': [
        for (final chapter in chapters) {'name': chapter.name, 'url': '${chapter.url}'},
      ],
    };
    final body = await pipeline.chapter(chapters.first);
    stages['content'] = {
      'chapter': chapters.first.name,
      'pages': body.pages,
      'text': body.text,
    };
  } on Object catch (error) {
    failure = '$error';
  } finally {
    pipeline.cancel();
    await server.close();
  }
  final trace = [
    for (final entry in pipeline.trace)
      {'stage': entry.stage.name, 'path': entry.path},
  ];
  return SliceRunResult(
    requests: List<Map<String, Object?>>.unmodifiable(server.requests),
    unmatched: List<Map<String, Object?>>.unmodifiable(server.unmatched),
    stageTrace: trace,
    stages: stages,
    invariants: _invariants(
      fixture: fixture,
      requests: server.requests,
      unmatched: server.unmatched,
      trace: trace,
      stages: stages,
      failure: failure,
    ),
    failure: failure,
  );
}

List<SliceInvariant> _invariants({
  required Map<String, dynamic> fixture,
  required List<Map<String, Object?>> requests,
  required List<Map<String, Object?>> unmatched,
  required List<Map<String, String>> trace,
  required Map<String, Object?> stages,
  required String? failure,
}) {
  final invariants = <SliceInvariant>[
    SliceInvariant(
      'analysis-completed',
      failure == null,
      failure ?? 'every stage returned',
    ),
    SliceInvariant(
      'four-stage-trace',
      {...trace.map((entry) => entry['stage'])}.length == 4,
      'stage order: ${trace.map((entry) => entry['stage']).join(' > ')}',
    ),
    SliceInvariant(
      'no-undeclared-request',
      unmatched.isEmpty,
      unmatched.isEmpty
          ? 'every request had a declared response'
          : 'undeclared: ${unmatched.map(_requestLine).join(', ')}',
    ),
  ];

  final expected = (fixture['expectedRequests'] as List).cast<Map>();
  final mismatches = <String>[];
  if (requests.length != expected.length) {
    mismatches.add('${requests.length} requests, ${expected.length} declared');
  } else {
    for (var index = 0; index < expected.length; index++) {
      if (!_requestMatches(expected[index], requests[index])) {
        mismatches.add(
          '${_requestLine(requests[index])} does not match '
          '${_requestLine(expected[index])}',
        );
      }
    }
  }
  invariants.add(
    SliceInvariant(
      'declared-requests',
      mismatches.isEmpty,
      mismatches.isEmpty
          ? expected.map(_requestLine).join(' | ')
          : mismatches.join('; '),
    ),
  );

  final cookie = (fixture['sessionCookie'] as Map).cast<String, dynamic>();
  final pair = '${cookie['name']}=${cookie['value']}';
  final carriedFrom = _requestIndex(requests, cookie['carriedFrom'] as String);
  final cookieChecks = <String>[];
  for (var index = 0; index < requests.length; index++) {
    final header = _header(requests[index], 'cookie');
    final carries = header.contains(pair);
    final expectedCarry = index >= carriedFrom;
    if (carries != expectedCarry) {
      cookieChecks.add('${_requestLine(requests[index])}: cookies='
          '${header.isEmpty ? '(none)' : header}');
    }
  }
  invariants.add(
    SliceInvariant(
      'session-cookie-carried',
      carriedFrom > 0 && cookieChecks.isEmpty,
      cookieChecks.isEmpty
          ? '$pair set on ${cookie['setOn']} and carried from $carriedFrom on'
          : cookieChecks.join('; '),
    ),
  );

  final declaredHeader = _sourceHeaderValue(fixture);
  invariants.add(
    SliceInvariant(
      'source-header-on-every-request',
      requests.isNotEmpty &&
          requests.every(
            (request) => _header(request, 'x-slice-corpus') == declaredHeader,
          ),
      'X-Slice-Corpus=$declaredHeader on ${requests.length} requests',
    ),
  );

  final toc = stages['toc'] as Map<String, Object?>?;
  final chapters = (toc?['chapters'] as List?)?.length ?? 0;
  invariants.add(
    SliceInvariant(
      'toc-pagination',
      toc?['pages'] == 2 && chapters == 3,
      'toc pages=${toc?['pages']}, chapters=$chapters',
    ),
  );

  final content = stages['content'] as Map<String, Object?>?;
  invariants.add(
    SliceInvariant(
      'content-paging',
      content?['pages'] == 2,
      'content pages=${content?['pages']}',
    ),
  );
  return invariants;
}

String _sourceHeaderValue(Map<String, dynamic> fixture) {
  final header = jsonDecode((fixture['source'] as Map)['header'] as String)
      as Map<String, dynamic>;
  return '${header['X-Slice-Corpus']}';
}

int _requestIndex(List<Map<String, Object?>> requests, String path) {
  for (var index = 0; index < requests.length; index++) {
    if (requests[index]['path'] == path) return index;
  }
  return -1;
}

String _header(Map<String, Object?> request, String name) {
  final headers = (request['headers'] as Map).cast<String, Object?>();
  final value = headers[name];
  return value is List ? value.join(', ') : '${value ?? ''}';
}

bool _requestMatches(Map expected, Map<String, Object?> observed) {
  if (expected['method'] != observed['method']) return false;
  if (expected['path'] != observed['path']) return false;
  final expectedQuery = (expected['query'] as Map?)?.cast<String, String>() ??
      const <String, String>{};
  final observedQuery = (observed['query'] as Map).cast<String, String>();
  if (expectedQuery.length != observedQuery.length) return false;
  return expectedQuery.entries
      .every((entry) => observedQuery[entry.key] == entry.value);
}

String _requestLine(Map request) {
  final line = '${request['method']} ${request['path']}';
  final query = (request['query'] as Map?)?.cast<String, String>() ?? const {};
  if (query.isEmpty) return line;
  return '$line?${query.entries.map((entry) => '${entry.key}=${entry.value}').join('&')}';
}
