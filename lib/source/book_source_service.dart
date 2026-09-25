import 'dart:convert';
import 'dart:io';

import '../domain/contracts.dart';
import '../domain/store_message.dart';

class BookSourceTraceEntry {
  const BookSourceTraceEntry({required this.stage, required this.path});
  final BookSourceStage stage;
  final String path;
}

abstract interface class BookSourceTransport {
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  });
}

class ReplayFixture {
  const ReplayFixture({
    required this.path,
    required this.query,
    required this.body,
  });
  final String path;
  final Map<String, String> query;
  final Map<String, dynamic> body;
}

const _fixtures = <ReplayFixture>[
  ReplayFixture(
    path: '/search',
    query: {'q': 'Wayfinder'},
    body: {
      'books': [
        {'id': 'wayfinder', 'title': 'Wayfinder'},
      ],
    },
  ),
  ReplayFixture(
    path: '/book/wayfinder',
    query: {},
    body: {'id': 'wayfinder', 'title': 'Wayfinder'},
  ),
  ReplayFixture(path: '/book/wayfinder/toc', query: {}, body: {'chapters': 12}),
  ReplayFixture(
    path: '/book/wayfinder/chapter/1',
    query: {},
    body: {'chapter': 1, 'text': 'Controlled fixture content'},
  ),
];

class LocalReplayTransport implements BookSourceTransport {
  HttpServer? _server;
  final requests = <String>[];

  Future<void> _ensureServer() async {
    if (_server != null) return;
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen((request) async {
      final requestPath = request.uri.path;
      final requestQuery = request.uri.queryParameters;
      requests.add(
        requestPath + (request.uri.hasQuery ? '?${request.uri.query}' : ''),
      );
      final fixture = _fixtures.where((item) {
        return item.path == requestPath &&
            item.query.length == requestQuery.length &&
            item.query.entries.every(
              (entry) => requestQuery[entry.key] == entry.value,
            );
      }).firstOrNull;
      final body = request.method == 'GET' ? fixture?.body : null;
      if (body == null) {
        request.response.statusCode = HttpStatus.notFound;
      } else {
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode(body));
      }
      await request.response.close();
    });
  }

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    await _ensureServer();
    final server = _server!;
    // #87's system-proxy switch is not read here: this client replays fixtures
    // from the loopback server this process itself started, not from a Book
    // Source, and this service is built before a space — and so before the
    // `network.system_proxy` row — exists. It keeps `HttpClient`'s default
    // (the machine's proxy variables), exactly as it did before the switch
    // existed.
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://${server.address.address}:${server.port}$path'),
      );
      final response = await request.close();
      final body = await utf8.decoder.bind(response).join();
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'replay request failed: ${response.statusCode}',
          uri: request.uri,
        );
      }
      return body;
    } finally {
      client.close(force: true);
    }
  }

  Future<void> close() async {
    await _server?.close(force: true);
    _server = null;
  }
}

class ControlledReplayTransport implements BookSourceTransport {
  const ControlledReplayTransport();
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async => '{}';
}

class ControlledBookSourceResult {
  const ControlledBookSourceResult({required this.state, required this.trace});
  final BookSourceRunState state;
  final List<BookSourceTraceEntry> trace;
}

class BookSourceService {
  BookSourceService({BookSourceTransport? transport})
    : _transport = transport ?? LocalReplayTransport();
  final BookSourceTransport _transport;
  static const sourceId = 'liber-controlled-fixture';

  Future<ControlledBookSourceResult> run(
    void Function(BookSourceRunState state) onStage,
  ) async {
    final trace = <BookSourceTraceEntry>[];
    const stages = <(BookSourceStage, String, StoreMessage)>[
      (
        BookSourceStage.search,
        '/search?q=Wayfinder',
        StoreMessage(StoreMessageCode.runControlledSearch),
      ),
      (
        BookSourceStage.bookInfo,
        '/book/wayfinder',
        StoreMessage(StoreMessageCode.runControlledBookInfo),
      ),
      (
        BookSourceStage.tableOfContents,
        '/book/wayfinder/toc',
        StoreMessage(StoreMessageCode.runControlledToc),
      ),
      (
        BookSourceStage.content,
        '/book/wayfinder/chapter/1',
        StoreMessage(StoreMessageCode.runControlledContent),
      ),
    ];
    for (final (stage, path, message) in stages) {
      await _transport.request(stage: stage, path: path);
      trace.add(BookSourceTraceEntry(stage: stage, path: path));
      onStage(BookSourceRunState(stage: stage, message: message));
    }
    const completed = BookSourceRunState(
      stage: BookSourceStage.completed,
      message: StoreMessage(StoreMessageCode.runControlledCompleted),
    );
    onStage(completed);
    return ControlledBookSourceResult(state: completed, trace: trace);
  }
}
