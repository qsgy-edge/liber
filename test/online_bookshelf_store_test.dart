import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/online_reading_store.dart';

void main() {
  late Directory directory;
  late File file;
  final source = <String, dynamic>{'bookSourceUrl': 'https://example.test'};
  HtmlBook book(String id) =>
      HtmlBook(url: Uri.parse('https://example.test/$id'), title: id);
  List<SourceChapter> chapters(String id) => [
    SourceChapter('第一章', Uri.parse('https://example.test/$id/1')),
    SourceChapter('第二章', Uri.parse('https://example.test/$id/2')),
  ];
  Map<String, dynamic> position(String id, int offset) => {
    'source': source,
    'book': book(id).toJson(),
    'chapterUrl': 'https://example.test/$id/2',
    'textOffset': offset,
  };
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('liber-shelf-test-');
    file = File('${directory.path}/reading.json');
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'two books, duplicate adds and a new store preserve independent positions',
    () async {
      final store = OnlineReadingStore(file: file);
      await store.addBook(source, book('A'), chapters('A'));
      await store.addBook(source, book('B'), chapters('B'));
      await Future.wait([
        store.save(position('A', 48)),
        OnlineReadingStore(file: file).save(position('B', 92)),
      ]);
      await store.addBook(source, book('A'), chapters('A'));
      final reopened = OnlineReadingStore(file: file);
      expect(await reopened.loadBooks(), hasLength(2));
      expect(
        (await reopened.find(source, '${book('A').url}'))!['textOffset'],
        48,
      );
      expect(
        (await reopened.find(source, '${book('B').url}'))!['textOffset'],
        92,
      );
      final before = await reopened.find(source, '${book('A').url}');
      await reopened.updateCatalog(source, book('A'), [
        SourceChapter('新章', Uri.parse('https://example.test/A/new')),
      ]);
      final after = await reopened.find(source, '${book('A').url}');
      expect(after!['chapterUrl'], before!['chapterUrl']);
      expect(after['textOffset'], 48);
    },
  );

  test(
    'removal stays removed after a pending reader save; explicit re-add restores progress',
    () async {
      final store = OnlineReadingStore(file: file);
      await store.addBook(source, book('A'), chapters('A'));
      await store.save(position('A', 30));
      await store.removeBook((await store.loadBooks()).single);
      await store.save(position('A', 45));
      expect(await store.loadBooks(), isEmpty);
      expect((await store.load())!['textOffset'], 45);
      await store.addBook(source, book('A'));
      expect((await store.loadBooks()).single['textOffset'], 45);
    },
  );

  test(
    'old single reading history upgrades without automatic bookshelf admission',
    () async {
      await file.writeAsString(jsonEncode(position('A', 78)));
      final store = OnlineReadingStore(file: file);
      expect((await store.load())!['textOffset'], 78);
      expect(await store.loadBooks(), isEmpty);
      await store.addBook(source, book('B'), chapters('B'));
      expect((await store.find(source, '${book('A').url}'))!['textOffset'], 78);
      expect((await store.loadBooks()).single['book']['title'], 'B');
    },
  );

  test('corrupt state is not overwritten by a new bookshelf add', () async {
    await file.writeAsString('broken-json');
    await expectLater(
      OnlineReadingStore(file: file).addBook(source, book('A')),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'broken-json');
  });
}
