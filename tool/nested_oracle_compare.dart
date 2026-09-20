import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/domain/contracts.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/source_host_dispatcher.dart';
import 'package:liber/source/source_url_rules.dart';

/// Compares a frozen-oracle golden against the same run on this platform.
///
/// Two modes:
///
/// - the JS oracle (default): `<fjs.dll> <golden.json> <new-result.json>`
/// - the request-semantics oracle:
///   `--requests <fjs.dll> <golden.json> <new-report.json>`. The library is
///   needed for the response-body decode the transport performs, not for a
///   JavaScript rule: the request corpus declares none.
Future<void> main(List<String> args) async {
  if (args.isNotEmpty && args.first == '--requests') {
    await _runRequestOracle(args.sublist(1));
    return;
  }
  await _runScriptOracle(args);
}

/// Runs the exact Android oracle corpus against the desktop destination.
Future<void> _runScriptOracle(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError('Usage: <fjs.dll> <golden.json> <new-result.json>');
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus =
      jsonDecode(File('tool/nested_oracle/fixtures.json').readAsStringSync())
          as Map<String, dynamic>;
  final golden =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  if (golden['baselineCommit'] != corpus['baselineCommit'] ||
      golden['entryPoint'] != corpus['entryPoint']) {
    throw StateError('Oracle identity mismatch');
  }
  final requests = <String>[];
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 18763);
  const origin = 'http://127.0.0.1:18763';
  final clients = <Socket>{};
  server.listen((socket) {
    clients.add(socket);
    var header = '';
    var sent = false;
    socket.listen(
      (bytes) {
        if (sent) return;
        header += ascii.decode(bytes);
        if (!header.contains('\r\n\r\n')) return;
        sent = true;
        final first = header.split('\r\n').first.split(' ');
        final rawPath = first[1];
        requests.add('${first[0]} $rawPath');
        final path = Uri.decodeComponent(rawPath);
        final body = utf8.encode(
          path.startsWith('/value/') ? path.substring(7) : '',
        );
        socket.add(
          ascii.encode(
            'HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: ${body.length}\r\nConnection: close\r\n\r\n',
          ),
        );
        socket.add(body);
        unawaited(socket.close());
      },
      onDone: () {
        clients.remove(socket);
      },
    );
  });
  await InProcessSourceScriptRuntime.initialize(libraryPath: args[0]);
  final observations = <Map<String, Object?>>[];
  final host = SourceHostDispatcher(transport: HttpSourceTransport());
  try {
    for (final step in corpus['steps'] as List) {
      final runtime = InProcessSourceScriptRuntime(
        dispatcher: host,
        jsLib: corpus['jsLib'] as String,
      );
      final result = <String, Object?>{'id': step['id']};
      try {
        result['value'] = await runtime.evaluate(
          source: (step['script'] as String).replaceAll(r'$ORIGIN', origin),
          input: {
            'sourceKey': '$origin/source/${step['sourceKey'] ?? 'first'}',
            'key': 'outer-key',
            'page': 7,
          },
          timeout: const Duration(seconds: 5),
        );
      } on SourceScriptError catch (error) {
        result['error'] = error.category;
      }
      observations.add(result);
    }
  } finally {
    await InProcessSourceScriptRuntime.dispose();
    await server.close();
    for (final socket in clients.toList()) {
      socket.destroy();
    }
  }
  final expected = golden['observations'] as List;
  final mismatches = <Map<String, Object?>>[];
  for (var i = 0; i < observations.length; i++) {
    if (i >= expected.length ||
        jsonEncode(observations[i]) != jsonEncode(expected[i])) {
      mismatches.add({
        'index': i,
        'expected': i < expected.length ? expected[i] : null,
        'actual': observations[i],
      });
    }
  }
  final countMatches = observations.length == expected.length;
  final requestsMatch = jsonEncode(requests) == jsonEncode(golden['requests']);
  final pass = countMatches && requestsMatch && mismatches.isEmpty;
  final report = {
    'platform': Platform.operatingSystem,
    'baselineCommit': corpus['baselineCommit'],
    'golden': args[1],
    'status': pass ? 'pass' : 'fail',
    'observations': observations,
    'requests': requests,
    'countMatches': countMatches,
    'requestsMatch': requestsMatch,
    'mismatches': mismatches,
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  stdout.writeln(jsonEncode(report));
  if (!pass) exitCode = 1;
}

// --------------------------------------------------------------------------
// Request-semantics oracle
// --------------------------------------------------------------------------

/// The corpus' port on this side. The device run serves the same corpus on
/// 18731; the host keeps the port the JS oracle already uses, so a replay
/// server of another lane cannot collide with either side.
const _requestPort = 18763;

/// Headers the differential contract calls platform-generated: they are
/// ignored unless the row's own declared header map sets the name
/// (`book-source-differential-contract.md` -> Matching Rules -> Requests).
const _ignoredHeaders = {'host', 'content-length', 'accept-encoding'};

/// Observations that a recorded divergence covers: an approved product
/// decision makes the frozen bytes unreproducible, so the row is reported as
/// `notCompared` (never as a pass) and the disagreement is quoted in full.
///
/// Both entries mirror rows in the differential contract's known-divergence
/// table.
const _declaredDivergences = <String, Map<String, String>>{
  'defaults-user-agent-null': {
    'observation': 'requests[0].headers.user-agent',
    'reason':
        'The frozen client removes the declared `null` header and then sends '
        'OkHttp BridgeInterceptor\'s own default (`okhttp/4.12.0`). The '
        'product\'s transport is Dart\'s HttpClient, whose own default stands '
        'when the source declares `User-Agent: null` '
        '(lib/source/http_source_transport.dart, `withSourceRequestDefaults`).',
  },
  'redirect-cross-origin': {
    'observation': 'requests[1].headers.cookie',
    'reason':
        'The frozen client drops `Authorization` on a hop to another origin '
        'and forwards a declared `Cookie`; the product\'s transport drops both, '
        'the recorded credentials-policy divergence '
        '(lib/source/http_source_transport.dart, `_readOnce`).',
  },
  'query-exact-bytes': {
    'observation': 'requests[0].rawQuery',
    'reason':
        'The frozen client keeps the URL as text and hands its query to '
        '`HttpUrl.encodedQuery` (AnalyzeUrl.kt:265-278, OkHttpUtils.kt:105-109), '
        'which writes `{`, `}`, `|`, `^`, the backtick and the backslash as '
        'they are. The product\'s request URL is a Dart `Uri`, which '
        'percent-encodes those six characters while it resolves '
        '(lib/source/source_http_uri.dart), the platform seam the capability '
        'matrix already records for the query re-encoding row.',
  },
};

/// Drives `tool/nested_oracle/request-fixtures.json` through the product's
/// request layer and compares the rows with the frozen golden.
///
/// The row's declared input is the same on both sides: the rule text (with its
/// optional `,{...}` object), the `{{key}}`/`{{page}}` bindings and the
/// declared header map. The product side resolves the rule with the same public
/// functions `HtmlSourcePipeline._request` uses (`expandSourceUrl`,
/// `splitSourceUrlOptions`, `encodeSourceQuery`, `sourceUrlTextWithRawQuery`),
/// then sends it through `HttpSourceTransport`, which is the transport under
/// test. The corpus declares no `js` option and no relative rule text, so the
/// pipeline's `js` branch and its URL validation are outside this corpus.
Future<void> _runRequestOracle(List<String> args) async {
  if (args.length != 3) {
    throw ArgumentError(
      'Usage: --requests <fjs.dll> <golden.json> <new-report.json>',
    );
  }
  final output = File(args[2]);
  if (output.existsSync()) throw StateError('Refusing to overwrite evidence');
  final corpus =
      jsonDecode(
            File('tool/nested_oracle/request-fixtures.json').readAsStringSync(),
          )
          as Map<String, dynamic>;
  final golden =
      jsonDecode(File(args[1]).readAsStringSync()) as Map<String, dynamic>;
  if (golden['fixtureId'] != corpus['fixtureId'] ||
      golden['corpusVersion'] != corpus['corpusVersion'] ||
      golden['baselineCommit'] != corpus['baselineCommit']) {
    throw StateError('Oracle identity mismatch');
  }
  final origin = 'http://127.0.0.2:$_requestPort';
  final otherOrigin = 'http://127.0.0.3:$_requestPort';
  // The transport decodes each response body the frozen way, which reaches the
  // engine for the `EncodingDetect` fallback; the corpus declares no charset.
  await NativeLibrary.initialize(libraryPath: args[0]);
  final replay = await _ReplayServer(
    corpus,
    origin: origin,
    otherOrigin: otherOrigin,
  ).start();
  final transport = HttpSourceTransport();
  final rows = <Map<String, Object?>>[];
  try {
    for (final entry in corpus['rows'] as List) {
      final row = entry as Map<String, dynamic>;
      final id = row['id'] as String;
      final frozen = (golden['rows'] as List).firstWhere(
        (goldenRow) => (goldenRow as Map)['id'] == id,
        orElse: () => throw StateError('the golden has no row $id'),
      ) as Map<String, dynamic>;
      final offset = replay.requests.length;
      final observed = await _liberRow(
        row,
        transport,
        origin: origin,
        otherOrigin: otherOrigin,
      );
      rows.add(_compareRow(id, frozen, observed, replay.since(offset)));
    }
  } finally {
    await replay.close();
    NativeLibrary.dispose();
  }
  final failed = rows.where((row) => row['status'] == 'fail').toList();
  final notCompared = rows
      .where((row) => row['status'] == 'notCompared')
      .toList();
  final report = <String, Object?>{
    'platform': Platform.operatingSystem,
    'mode': 'requests',
    'fixtureId': corpus['fixtureId'],
    'corpusVersion': corpus['corpusVersion'],
    'baselineCommit': corpus['baselineCommit'],
    'golden': args[1],
    'status': failed.isEmpty ? 'pass' : 'fail',
    'origins': {'origin': origin, 'otherOrigin': otherOrigin},
    'library': args[0],
    'ignoredHeaders': _ignoredHeaders.toList(),
    'declaredDivergences': _declaredDivergences.map(
      (row, entry) => MapEntry(row, entry['reason']!),
    ),
    'rows': rows,
    'passedRows': [
      for (final row in rows)
        if (row['status'] == 'pass') row['id'],
    ],
    'failedRows': [for (final row in failed) row['id']],
    'notComparedRows': [for (final row in notCompared) row['id']],
  };
  output.writeAsStringSync(
    '${const JsonEncoder.withIndent('  ').convert(report)}\n',
  );
  for (final row in rows) {
    stdout.writeln('${row['status']}\t${row['id']}');
  }
  stdout.writeln(
    'request corpus: ${report['status']} (${rows.length} rows, '
    '${(report['passedRows'] as List).length} pass, '
    '${failed.length} fail, ${notCompared.length} notCompared)',
  );
  if (failed.isNotEmpty) exitCode = 1;
}

/// One row's product-side run: the resolved rule text, the transport call and
/// the request/outcome evidence the replay server saw.
Future<Map<String, Object?>> _liberRow(
  Map<String, dynamic> row,
  HttpSourceTransport transport, {
  required String origin,
  required String otherOrigin,
}) async {
  final declared = row['request'] as Map<String, dynamic>;
  final page = declared['page'] as int?;
  final key = declared['key'] as String?;
  final ruleText = (declared['rule'] as String)
      .replaceAll(r'$OTHER_ORIGIN', otherOrigin)
      .replaceAll(r'$ORIGIN', origin);
  final declaredHeaders = <String, String>{
    for (final entry
        in (declared['headers'] as Map<String, dynamic>? ?? const {})
            .entries)
      entry.key: '${entry.value}',
  };
  final expanded = await expandSourceUrl(
    ruleText,
    (expression, result) {
      switch (expression.trim()) {
        case 'key':
          return Future<Object?>.value(key);
        case 'page':
          return Future<Object?>.value(page);
        default:
          throw UnsupportedError(
            'the request corpus declares no JavaScript in a request rule: '
            '$expression',
          );
      }
    },
    page: page,
  );
  final split = splitSourceUrlOptions(expanded);
  final base = Uri.parse(origin);
  var url = base.resolve(split.path);
  if (!split.options.isPost) {
    url = base.resolve(
      await encodeSourceQuery(
        sourceUrlTextWithRawQuery(url, split.path),
        charset: split.options.charset,
      ),
    );
  }
  final merged = {...declaredHeaders, ...split.options.headers};
  final shape = await sourceRequestShape(split.options, merged);
  final observed = <String, Object?>{
    'ruleText': ruleText,
    'resolvedUrl': '$url',
    'method': shape.method,
    // The names the source itself declared: the contract compares a
    // platform-generated name (`Connection`) when the source sets it.
    'declaredHeaders': [
      for (final name in {...declaredHeaders.keys, ...merged.keys})
        name.toLowerCase(),
    ],
  };
  try {
    final result = await transport.send(
      SourceHttpRequest(
        method: shape.method,
        url: url,
        headers: {...merged, ...shape.headers},
        body: shape.body,
        followRedirects: true,
      ),
    );
    observed['outcome'] = 'ok';
    observed['status'] = result.statusCode;
    observed['finalUrl'] = '${result.url}';
    observed['body'] = result.body;
  } catch (error) {
    observed['outcome'] = 'error';
    observed['error'] = '$error';
  }
  return observed;
}

/// Compares one row's frozen golden with the product's own observation.
Map<String, Object?> _compareRow(
  String id,
  Map<String, dynamic> frozen,
  Map<String, Object?> observed,
  List<Map<String, dynamic>> liberRequests,
) {
  final liber = <String, Object?>{
    'requests': liberRequests,
    'outcome': observed['outcome'],
    if (observed['status'] != null) 'status': observed['status'],
    if (observed['body'] != null) 'body': observed['body'],
    if (observed['error'] != null) 'error': observed['error'],
  };
  final mismatches = <Map<String, Object?>>[];
  final divergences = <Map<String, Object?>>[];
  final declaredNames = {
    for (final name in (observed['declaredHeaders'] as List)) '$name',
  };
  final frozenRequests = (frozen['requests'] as List)
      .cast<Map<String, dynamic>>();
  if (frozenRequests.length != liberRequests.length) {
    _record(
      id,
      'requests.length',
      frozenRequests.length,
      liberRequests.length,
      mismatches,
      divergences,
    );
  }
  for (var index = 0; index < frozenRequests.length; index++) {
    final expected = frozenRequests[index];
    if (index >= liberRequests.length) {
      _record(id, 'requests[$index]', expected, null, mismatches, divergences);
      continue;
    }
    final actual = liberRequests[index];
    for (final field in ['method', 'path', 'rawQuery', 'body']) {
      if (expected[field] != actual[field]) {
        _record(
          id,
          'requests[$index].$field',
          expected[field],
          actual[field],
          mismatches,
          divergences,
        );
      }
    }
    final frozenHeaders = (expected['headers'] as Map).cast<String, Object?>();
    final liberHeaders = (actual['headers'] as Map).cast<String, Object?>();
    final names = {...frozenHeaders.keys, ...liberHeaders.keys}.toList()..sort();
    for (final name in names) {
      if (_ignoredHeaders.contains(name) && !declaredNames.contains(name)) {
        continue;
      }
      final expectedValue = frozenHeaders[name];
      final actualValue = liberHeaders[name];
      if (jsonEncode(expectedValue) != jsonEncode(actualValue)) {
        _record(
          id,
          'requests[$index].headers.$name',
          expectedValue,
          actualValue,
          mismatches,
          divergences,
        );
      }
    }
  }
  // The outcome is compared as its two shapes (a completed call with a status
  // and body, or a failed call); the platform's exception class is not part of
  // the comparison. `finalUrl` stays out of it as well: the two sides serve
  // the same corpus on their own port, so only the request-target bytes are
  // comparable.
  if (frozen['outcome'] != liber['outcome']) {
    _record(
      id,
      'outcome',
      frozen['outcome'],
      liber['outcome'],
      mismatches,
      divergences,
    );
  } else if (frozen['outcome'] == 'ok') {
    for (final field in ['status', 'body']) {
      if (frozen[field] != liber[field]) {
        _record(id, field, frozen[field], liber[field], mismatches, divergences);
      }
    }
  }
  final status = mismatches.isNotEmpty
      ? 'fail'
      : (divergences.isNotEmpty ? 'notCompared' : 'pass');
  return {
    'id': id,
    'status': status,
    'frozen': {'requests': frozenRequests, 'outcome': frozen['outcome']},
    'liber': liber,
    'liberRule': {
      'ruleText': observed['ruleText'],
      'resolvedUrl': observed['resolvedUrl'],
      'method': observed['method'],
    },
    'mismatches': mismatches,
    'divergences': divergences,
  };
}

void _record(
  String id,
  String observation,
  Object? frozen,
  Object? liber,
  List<Map<String, Object?>> mismatches,
  List<Map<String, Object?>> divergences,
) {
  final declared = _declaredDivergences[id];
  final entry = <String, Object?>{
    'observation': observation,
    'frozen': frozen,
    'liber': liber,
  };
  if (declared != null && declared['observation'] == observation) {
    entry['reason'] = declared['reason'];
    divergences.add(entry);
  } else {
    mismatches.add(entry);
  }
}

/// The corpus' replay server: every response comes from the corpus, a row is
/// sliced out of the request log by offset, and an undeclared request is
/// answered 404 (which this corpus has none of).
class _ReplayServer {
  _ReplayServer(this.corpus, {required this.origin, required this.otherOrigin});

  final Map<String, dynamic> corpus;
  final String origin;
  final String otherOrigin;
  final requests = <Map<String, Object?>>[];
  final _clients = <Socket>{};
  late final ServerSocket _server;

  Future<_ReplayServer> start() async {
    _server = await ServerSocket.bind(InternetAddress.anyIPv4, _requestPort);
    _server.listen(_accept);
    return this;
  }

  void _accept(Socket socket) {
    _clients.add(socket);
    var buffer = '';
    var served = 0;
    socket.listen(
      (bytes) {
        buffer += latin1.decode(bytes);
        while (true) {
          final end = buffer.indexOf('\r\n\r\n');
          if (end < 0) return;
          final head = buffer.substring(0, end);
          final lines = head.split('\r\n');
          // A leading CRLF is legal before a request line.
          while (lines.isNotEmpty && lines.first.isEmpty) {
            lines.removeAt(0);
          }
          if (lines.isEmpty) return;
          final requestLine = lines.first.split(' ');
          if (requestLine.length < 2) return;
          final method = requestLine[0];
          final target = requestLine[1];
          final headers = <String, Object?>{};
          for (final line in lines.skip(1)) {
            final separator = line.indexOf(':');
            if (separator <= 0) continue;
            final name = line.substring(0, separator).trim().toLowerCase();
            final value = line.substring(separator + 1).trim();
            final existing = headers[name];
            headers[name] = existing == null ? value : '$existing, $value';
          }
          final declaredLength =
              int.tryParse('${headers['content-length'] ?? ''}');
          final chunked = '${headers['transfer-encoding'] ?? ''}'
              .toLowerCase()
              .contains('chunked');
          String body;
          int consumed;
          if (chunked) {
            // The platform frames a body of unknown length with chunked
            // encoding: Dart's HttpClient does for a request whose
            // contentLength was never set, OkHttp does not for a String body.
            final parsed = _readChunked(buffer.substring(end + 4));
            if (parsed == null) return;
            body = parsed.body;
            consumed = end + 4 + parsed.consumed;
          } else {
            final length = declaredLength ?? 0;
            if (buffer.length < end + 4 + length) return;
            body = length > 0 ? buffer.substring(end + 4, end + 4 + length) : '';
            consumed = end + 4 + length;
          }
          buffer = buffer.substring(consumed);
          served++;
          final at = target.indexOf('?');
          final path = at < 0 ? target : target.substring(0, at);
          final rawQuery = at < 0 ? '' : target.substring(at + 1);
          final declared = (corpus['responses'] as List)
              .cast<Map<String, dynamic>>()
              .firstWhere(
                (entry) =>
                    entry['method'] == method && entry['path'] == path,
                orElse: () => <String, dynamic>{},
              );
          requests.add({
            'method': method,
            'path': path,
            'rawQuery': rawQuery,
            'headers': headers,
            'body': body,
          });
          final status = declared['status'] as int?;
          final responseBody = _substitute(
            declared['body'] as String? ?? 'undeclared replay request',
          );
          final responseHeaders = <String, String>{
            for (final entry
                in (declared['headers'] as Map<String, dynamic>? ??
                        const <String, dynamic>{})
                    .entries)
              entry.key: _substitute('${entry.value}'),
          };
          final bytes = utf8.encode(responseBody);
          final response = StringBuffer()
            ..writeln('HTTP/1.1 ${status ?? 404} OK')
            ..writeln('Content-Type: text/plain')
            ..writeln('Content-Length: ${bytes.length}');
          responseHeaders.forEach(
            (name, value) => response.writeln('$name: $value'),
          );
          response.write('\r\n');
          socket.add(latin1.encode(response.toString()));
          socket.add(bytes);
          unawaited(socket.flush());
          if (served > 64) {
            socket.destroy();
            return;
          }
        }
      },
      onDone: () {
        socket.destroy();
        _clients.remove(socket);
      },
      onError: (_) {
        socket.destroy();
        _clients.remove(socket);
      },
    );
  }

  String _substitute(String text) => text
      .replaceAll(r'$OTHER_ORIGIN', otherOrigin)
      .replaceAll(r'$ORIGIN', origin);

  /// One chunked body, or null while the buffer does not hold all of it yet.
  static ({String body, int consumed})? _readChunked(String rest) {
    var index = 0;
    final body = StringBuffer();
    while (true) {
      final lineEnd = rest.indexOf('\r\n', index);
      if (lineEnd < 0) return null;
      final size = int.tryParse(
        rest.substring(index, lineEnd).split(';').first.trim(),
        radix: 16,
      );
      if (size == null) return null;
      index = lineEnd + 2;
      if (size == 0) {
        final trailerEnd = rest.indexOf('\r\n', index);
        if (trailerEnd < 0) return null;
        return (body: body.toString(), consumed: trailerEnd + 2);
      }
      if (rest.length < index + size + 2) return null;
      body.write(rest.substring(index, index + size));
      index += size + 2;
    }
  }

  List<Map<String, dynamic>> since(int offset) =>
      requests.skip(offset).cast<Map<String, dynamic>>().toList();

  Future<void> close() async {
    await _server.close();
    for (final socket in _clients.toList()) {
      socket.destroy();
    }
  }
}
