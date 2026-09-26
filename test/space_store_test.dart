import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show OrderingTerm, Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/workspace.dart';

import 'temp_directory.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-store-');
  });

  tearDown(() => deleteTempDirectory(root));

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

  test('书籍带分组、目录、进度和替换规则往返', () async {
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    final bookId = await store.putBook(
      BooksCompanion.insert(
        id: 'book-1',
        title: '斗破苍穹',
        sourceRef: const Value('https://example.test'),
        sourceBookUrl: const Value('https://example.test/book/1'),
      ),
    );

    // A group is matched by trimmed name, so a second import joins it.
    final reading = await store.ensureGroup('  在读  ');
    expect(reading.name, '在读');
    final again = await store.ensureGroup('在读');
    expect(again.id, reading.id);
    final shelf = await store.ensureGroup('书架');
    await store.setBookGroups(bookId, [reading.id, shelf.id]);

    await store.putChapters(bookId, [
      BookChapter(
        bookId: bookId,
        chapterKey: 'https://example.test/book/1/1',
        name: '第一章',
        url: 'https://example.test/book/1/1',
        chapterIndex: 0,
        isVolume: false,
        isVip: false,
        isPay: false,
      ),
      BookChapter(
        bookId: bookId,
        chapterKey: 'https://example.test/book/1/2',
        name: '第二章',
        url: 'https://example.test/book/1/2',
        chapterIndex: 1,
        isVolume: false,
        isVip: false,
        isPay: false,
      ),
    ]);

    // Progress only advances: `(chapterIndex, textOffset)` decides.
    expect(
      await store.saveProgress(
        ProgressCompanion.insert(
          bookId: bookId,
          textOffset: const Value(120),
          chapterKey: const Value('https://example.test/book/1/2'),
          chapterIndex: const Value(1),
          updatedAt: const Value(1000),
        ),
      ),
      isTrue,
    );
    expect(
      await store.saveProgress(
        ProgressCompanion.insert(
          bookId: bookId,
          textOffset: const Value(90),
          chapterIndex: const Value(1),
          updatedAt: const Value(2000),
        ),
      ),
      isFalse,
      reason: '同一章更早的位置不能倒退',
    );
    expect((await store.progressOf(bookId))!.textOffset, 120);
    expect(
      await store.saveProgress(
        ProgressCompanion.insert(
          bookId: bookId,
          textOffset: const Value(200),
          chapterIndex: const Value(1),
          updatedAt: const Value(2000),
        ),
      ),
      isTrue,
    );
    expect((await store.progressOf(bookId))!.textOffset, 200);

    await store.putSource(
      SourcesCompanion.insert(
        bookSourceUrl: 'https://example.test',
        name: 'Example',
        groupNames: const Value('["网络"]'),
        raw: const Value('{"unknownField":[1,2,3],"jsLib":""}'),
      ),
    );
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'rule-1',
        name: '目录',
        pattern: r'第(\d+)章',
        replacement: const Value(r'第$1章'),
      ),
    );
    await store.putReplaceRule(
      ReplaceRulesCompanion.insert(
        id: 'rule-2',
        name: '目录',
        pattern: r'第(\d+)章',
        replacement: const Value(r'第$1章'),
      ),
    );
    await workspace.close();

    final reopened = await Workspace.open(root: root);
    final store2 = await reopened.openSpace();
    final book = (await store2.bookById(bookId))!;
    expect(book.sourceRef, 'https://example.test');
    expect(book.sourceBookUrl, 'https://example.test/book/1');
    expect(book.kind, 'network');
    expect(book.shelved, isTrue);
    expect(
      (await store2.groupsOf(bookId)).map((g) => g.name),
      containsAll(<String>['在读', '书架']),
    );
    final chapters = await store2.chaptersOf(bookId);
    expect(chapters.map((c) => c.name), ['第一章', '第二章']);
    expect(chapters.last.chapterKey, 'https://example.test/book/1/2');
    final progress = (await store2.progressOf(bookId))!;
    expect(progress.textOffset, 200);
    expect(progress.chapterKey, 'https://example.test/book/1/2');
    expect(progress.chapterIndex, 1);
    expect(
      (await store2.sourceByUrl('https://example.test'))!.raw,
      '{"unknownField":[1,2,3],"jsLib":""}',
    );
    final rules = await store2.replaceRules();
    expect(rules, hasLength(1), reason: '(name, pattern, replacement) 是合并键');
    expect(rules.single.id, 'rule-1');
    expect(rules.single.isEnabled, isTrue);
    expect(rules.single.scopeContent, isTrue);
    expect(rules.single.scopeTitle, isFalse);
    await reopened.close();
  });

  test('本地文件索引整份替换，不碰同根下的其它文件', () async {
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();
    await store.putLocalRoot(
      LocalRootsCompanion.insert(id: 'root-1', displayName: 'D:\\Novels'),
    );
    for (final path in ['三國演義.txt', '紅樓夢.txt']) {
      await store.putLocalFile(
        LocalFilesCompanion.insert(rootId: 'root-1', relativePath: path),
      );
    }

    await store.putTextIndex('root-1', '三國演義.txt', [
      (byteOffset: 0, codeUnitOffset: 0, lineIndex: 0),
      (byteOffset: 7598, codeUnitOffset: 2544, lineIndex: 8),
    ]);
    await store.putTextIndex('root-1', '紅樓夢.txt', [
      (byteOffset: 0, codeUnitOffset: 0, lineIndex: 0),
    ]);
    // The file was edited and re-indexed: the old anchors describe bytes that
    // no longer exist, so the rebuild replaces them instead of adding to them.
    await store.putTextIndex('root-1', '三國演義.txt', [
      (byteOffset: 0, codeUnitOffset: 0, lineIndex: 0),
      (byteOffset: 9521, codeUnitOffset: 3197, lineIndex: 16),
    ]);

    final rows = await (store.db.select(store.db.textIndex)..orderBy([
          (t) => OrderingTerm(expression: t.relativePath),
          (t) => OrderingTerm(expression: t.byteOffset),
        ]))
        .get();
    expect(
      rows.map(
        (row) =>
            '${row.rootId}/${row.relativePath}'
            '@${row.byteOffset}:${row.codeUnitOffset}:${row.lineIndex}',
      ),
      [
        'root-1/三國演義.txt@0:0:0',
        'root-1/三國演義.txt@9521:3197:16',
        'root-1/紅樓夢.txt@0:0:0',
      ],
    );
    await workspace.close();
  });

  test('同一空间被另一个连接持锁时，第二条连接等锁而不是直接失败（#109）', () async {
    final workspace = await Workspace.open(root: root);
    final first = await workspace.openSpace();
    await first.putSetting('first', '1');

    // Hold the first connection's write lock for a bounded window: without
    // `PRAGMA busy_timeout` the statement below fails immediately with
    // `SqliteException(5): database is locked`, which is the failure #109
    // measured (a restart read as a dead space).
    final locked = Completer<void>();
    final holding = first.transaction(() async {
      await first.putSetting('held', 'yes');
      locked.complete();
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await locked.future;

    final second = await (await Workspace.open(root: root)).openSpace();
    await second.putSetting('second', '2');
    expect(await second.setting('second'), '2');
    expect(await first.setting('first'), '1');

    await holding;
    await second.close();
    await first.close();
  });
}
