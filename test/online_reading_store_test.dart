import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/online_reading_store.dart';

void main() {
  test(
    'reading state survives a new store and serializes rapid position writes',
    () async {
      final dir = await Directory.systemTemp.createTemp('liber-online-test-');
      addTearDown(() => dir.delete(recursive: true));
      final file = File('${dir.path}/state.json');
      final store = OnlineReadingStore(file: file);
      Map<String, dynamic> record(int offset) => {
        'source': {'bookSourceUrl': 'https://example.test'},
        'book': {'title': '书', 'url': 'https://example.test/book'},
        'chapterUrl': 'https://example.test/c2',
        'textOffset': offset,
      };
      await Future.wait([
        store.save(record(30)),
        store.save(record(100)),
        store.save(record(60)),
      ]);
      expect((await OnlineReadingStore(file: file).load())!['textOffset'], 60);
      expect(await File('${file.path}.tmp').exists(), isFalse);
    },
  );
}
