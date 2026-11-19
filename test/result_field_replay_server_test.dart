import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../tool/first_slice/runner.dart';

void main() {
  test(
    'replay server observes GBK query bytes without substituting declarations',
    () async {
      final server = await SliceReplayServer.start({
        'origin': 'http://127.0.0.1:0',
        'responses': [
          {
            'method': 'GET',
            'path': '/content',
            'query': {'q': '��'},
            'body': 'BODY',
          },
          {
            'method': 'GET',
            'path': '/ascii',
            'query': {'q': 'hello world'},
            'body': 'ASCII',
          },
        ],
      });
      final client = HttpClient();
      try {
        final request = await client.getUrl(
          Uri.parse('${server.origin}/content?q=%D6%D0'),
        );
        final response = await request.close().timeout(
          const Duration(seconds: 2),
        );
        expect(response.statusCode, 200);
        expect(await utf8.decoder.bind(response).join(), 'BODY');
        expect(server.requests.single['rawQuery'], 'q=%D6%D0');
        expect(server.requests.single['query'], {'q': '��'});
        final mismatch = await client.getUrl(
          Uri.parse('${server.origin}/content?q=%E4%B8%AD'),
        );
        final unmatched = await mismatch.close();
        expect(unmatched.statusCode, 404);
        await unmatched.drain<void>();
        expect(server.requests.last['rawQuery'], 'q=%E4%B8%AD');
        expect(server.requests.last['query'], {'q': '中'});
        final ascii = await client.getUrl(
          Uri.parse('${server.origin}/ascii?q=hello+world'),
        );
        final asciiResponse = await ascii.close();
        expect(asciiResponse.statusCode, 200);
        expect(await utf8.decoder.bind(asciiResponse).join(), 'ASCII');
        expect(server.requests.last['query'], {'q': 'hello world'});
        expect(server.unmatched, hasLength(1));
        expect(server.serverErrors, isEmpty);
      } finally {
        client.close(force: true);
        await server.close();
      }
    },
  );
}
