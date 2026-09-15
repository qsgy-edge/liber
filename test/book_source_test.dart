import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';

class RecordingTransport implements BookSourceTransport {
  final requests = <BookSourceStage>[];
  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    requests.add(stage);
    return '{}';
  }
}

void main() {
  test(
    'book source pipeline preserves stage order with a replaceable transport',
    () async {
      final transport = RecordingTransport();
      final states = <BookSourceStage>[];
      final result = await BookSourceService(
        transport: transport,
      ).run((state) => states.add(state.stage));
      expect(transport.requests, [
        BookSourceStage.search,
        BookSourceStage.bookInfo,
        BookSourceStage.tableOfContents,
        BookSourceStage.content,
      ]);
      expect(result.trace.map((entry) => entry.stage), transport.requests);
      expect(states.last, BookSourceStage.completed);
    },
  );

  test('local replay transport makes real loopback HTTP requests', () async {
    final transport = LocalReplayTransport();
    final body = await transport.request(
      stage: BookSourceStage.search,
      path: '/search?q=Wayfinder',
    );
    expect(body, contains('Wayfinder'));
    expect(transport.requests, ['/search?q=Wayfinder']);
    await transport.close();
  });

  test('local replay rejects a request with the wrong query', () async {
    final transport = LocalReplayTransport();
    await expectLater(
      transport.request(stage: BookSourceStage.search, path: '/search?q=Other'),
      throwsA(isA<HttpException>()),
    );
    await transport.close();
  });
}
