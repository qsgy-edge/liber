import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/source_host_dispatcher.dart';

/// Runs the exact Android oracle corpus against the Windows destination.
Future<void> main(List<String> args) async {
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
