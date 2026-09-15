import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/workspace.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-store-');
  });

  tearDown(() => root.delete(recursive: true));

  test('工作区创建 manifest 与默认空间，重开后数据仍在', () async {
    final workspace = await Workspace.open(root: root);
    expect(File('${root.path}/manifest.json').existsSync(), isTrue);
    final store = await workspace.openSpace();
    await store.putBook(
      BooksCompanion.insert(id: 'book-1', title: '斗破苍穹', author: Value('天蚕土豆')),
    );
    await workspace.close();

    final reopened = await Workspace.open(root: root);
    expect(reopened.manifest.activeSpace, 'default');
    final store2 = await reopened.openSpace();
    expect(
      File('${root.path}/spaces/default/data.db').existsSync(),
      isTrue,
      reason: '空间数据库应落在 spaces\\<spaceId>\\data.db',
    );

    final book = await store2.bookById('book-1');
    expect(book!.title, '斗破苍穹');
    expect(book.author, '天蚕土豆');
    await reopened.close();
  });
}
