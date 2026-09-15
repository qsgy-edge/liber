import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/local/local_library_service.dart';
import 'package:liber/migration/migration_service.dart';

void main() {
  test(
    'local library scans only TXT and Markdown and adds explicitly',
    () async {
      final directory = await Directory.systemTemp.createTemp('liber-library-');
      addTearDown(() => directory.delete(recursive: true));
      await File('${directory.path}/book.txt').writeAsString('text');
      await File('${directory.path}/cover.jpg').writeAsBytes(<int>[1]);
      final nested = await Directory('${directory.path}/nested').create();
      await File('${nested.path}/chapter.md').writeAsString('# chapter');

      final service = LocalLibraryService(
        stateFile: File('${directory.path}/state.json'),
      );
      await service.selectRoot(directory.path);
      final entries = await service.scanRecursively();
      final books = await service.addFiles(entries);

      expect(entries, hasLength(2));
      expect(
        books.map((book) => book.title),
        containsAll(<String>['book.txt', 'chapter.md']),
      );
      expect(await service.addFiles(entries), isEmpty);
      expect(books.every((book) => book.textOffset == 0), isTrue);
    },
  );

  test('migration reports counts and explicit losses', () async {
    final directory = await Directory.systemTemp.createTemp(
      'liber-migration-test-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final result =
        await MigrationService(
          stateFile: File('${directory.path}/state.json'),
        ).importJson('''
      {
        "bookSources": [{"bookSourceUrl": "fixture"}],
        "bookshelf": [{"bookUrl": "book", "name": "Book"}],
        "bookProgress": [{"bookId": "book", "textOffset": 10}]
      }
    ''');

    expect(result.sourceCount, 1);
    expect(result.bookCount, 1);
    expect(result.progressCount, 1);
    expect(result.losses, contains(contains('Cookie')));
  });
}
