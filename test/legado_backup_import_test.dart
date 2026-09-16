import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

/// The 迁移 page's Legado backup import writes into the space: sources, books
/// and progress, merged by the same natural keys the one-time import uses, with
/// nothing of ours left beside the database to hold it.
void main() {
  late TestSpace space;
  late SpaceStore store;

  const backup = '''
  {
    "bookSources": [
      {
        "bookSourceUrl": "fixture",
        "bookSourceName": "Fixture",
        "unknownSourceField": 1
      }
    ],
    "bookshelf": [{"bookUrl": "book", "name": "Book"}],
    "bookProgress": [{"bookId": "book", "textOffset": 10}]
  }
  ''';

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
  });

  tearDown(() => space.delete());

  test('备份的书源、书籍与进度都进空间，损失照旧报告', () async {
    final result = await LegadoBackupImport(store).importJson(backup);
    expect(result.sourceCount, 1);
    expect(result.bookCount, 1);
    expect(result.progressCount, 1);
    expect(result.losses, contains(contains('Cookie')));

    final source = (await store.sourceByUrl('fixture'))!;
    expect(source.name, 'Fixture');
    expect(source.raw, contains('unknownSourceField'), reason: '未知字段留在 raw 里');
    final book = (await store.bookById('legacy-book'))!;
    expect(book.title, 'Book');
    expect(book.sourceRef, isNull, reason: '备份里的书没有可解析的书源');
    expect((await store.progressOf('legacy-book'))!.textOffset, 10);

    // Nothing of ours is written beside the space database.
    expect(space.file('migration_state.json').existsSync(), isFalse);
    expect(space.file('online_reading.json').existsSync(), isFalse);
    expect(space.file('local_books.json').existsSync(), isFalse);
  });

  test('同一个备份导入两次不新建书源与书籍', () async {
    final first = await LegadoBackupImport(store).importJson(backup);
    final second = await LegadoBackupImport(store).importJson(backup);
    expect(second.bookCount, first.bookCount);
    expect(await store.allSources(), hasLength(1));
    expect((await store.shelf()).map((book) => book.title), ['Book']);
    expect((await store.progressOf('legacy-book'))!.textOffset, 10);
  });

  test('不是 Legado 备份的文件被拒绝，也不写任何东西', () async {
    await expectLater(
      LegadoBackupImport(store).importJson('[1, 2]'),
      throwsFormatException,
    );
    await expectLater(
      LegadoBackupImport(store).importJson('不是 JSON'),
      throwsFormatException,
    );
    expect(await store.allSources(), isEmpty);
    expect(await store.shelf(), isEmpty);
  });
}
