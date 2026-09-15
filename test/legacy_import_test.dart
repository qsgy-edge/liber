import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/workspace.dart';

/// The three JSON stores as the product wrote them, in a home directory of
/// their own.
class LegacyHome {
  LegacyHome(this.directory);

  final Directory directory;

  static Future<LegacyHome> create(Directory directory) async {
    final home = LegacyHome(directory);
    await directory.create(recursive: true);
    return home;
  }

  static const source = <String, dynamic>{
    'bookSourceUrl': 'https://example.test',
    'bookSourceName': 'Example',
    'bookSourceGroup': '网络, 精选 ',
    'customOrder': 3,
    'unknownSourceField': {
      'nested': [1, 2],
    },
  };

  /// The pointer at the record the reader had open. It is deliberately the
  /// *shelved* record: the history record that is not the pointer still has to
  /// be imported.
  String get _lastKey =>
      jsonEncode(['https://example.test', 'https://example.test/book/1']);

  Future<File> writeOnlineReading() async {
    final file = File('${directory.path}/online_reading.json');
    await file.writeAsString(
      jsonEncode({
        'version': 2,
        'last': _lastKey,
        'records': [
          {
            'source': source,
            'book': {
              'url': 'https://example.test/book/1',
              'title': '斗破苍穹',
              'author': '天蚕土豆',
              'intro': '简介',
              'cover': 'https://example.test/cover.png',
              'kind': 'text',
              'unknownBookField': 42,
            },
            'chapterUrl': 'https://example.test/book/1/2',
            'chapterName': '第二章',
            'textOffset': 120,
            'chapters': [
              {'name': '第一章', 'url': 'https://example.test/book/1/1'},
              {'name': '第二章', 'url': 'https://example.test/book/1/2'},
            ],
            'shelved': true,
          },
          {
            'source': source,
            'book': {
              'url': 'https://example.test/book/2',
              'title': '未上架的书',
              'author': '',
              'intro': '',
              'cover': '',
              'kind': '',
            },
            'chapterUrl': 'https://example.test/book/2/1',
            'chapterName': '第一章',
            'textOffset': 7,
            'chapters': [
              {'name': '第一章', 'url': 'https://example.test/book/2/1'},
            ],
            'shelved': false,
          },
        ],
      }),
    );
    return file;
  }

  Future<File> writeLocalBooks({required String rootPath}) async {
    final file = File('${directory.path}/local_books.json');
    final rootId = rootPath.toLowerCase();
    await file.writeAsString(
      jsonEncode({
        'root': {'id': rootId, 'displayName': rootPath, 'needsRelink': false},
        'books': [
          {
            'id': '$rootId::kept.txt',
            'rootId': rootId,
            'path': '$rootPath${Platform.pathSeparator}kept.txt',
            'title': 'kept.txt',
            'textOffset': 42,
            'relativePath': 'kept.txt',
            'format': 'txt',
            'updatedAt': '2026-09-09T12:46:01.808043',
          },
          {
            'id': '$rootId::gone.txt',
            'rootId': rootId,
            'path': '$rootPath${Platform.pathSeparator}gone.txt',
            'title': 'gone.txt',
            'textOffset': 9,
            'relativePath': 'gone.txt',
            'format': 'txt',
            'updatedAt': '2026-09-09T12:46:01.808043',
          },
        ],
      }),
    );
    return file;
  }

  Future<File> writeMigrationState() async {
    final file = File('${directory.path}/migration_state.json');
    await file.writeAsString(
      jsonEncode({
        'sources': [
          {
            'id': 'fixture',
            'data': {'bookSourceUrl': 'fixture', 'bookSourceName': 'Fixture'},
          },
        ],
        'books': [
          {
            'id': 'book',
            'title': 'Book',
            'progressOffset': 10,
            'needsRelink': false,
          },
        ],
      }),
    );
    return file;
  }
}

void main() {
  late Directory root;
  late Directory home;
  late Directory library;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('liber-import-');
    home = Directory('${root.path}${Platform.pathSeparator}home');
    library = Directory('${root.path}${Platform.pathSeparator}library');
    await library.create(recursive: true);
    await File(
      '${library.path}${Platform.pathSeparator}kept.txt',
    ).writeAsString('第一章\n正文');
  });

  tearDown(() => root.delete(recursive: true));

  Future<(LegacyImport, Workspace)> workspaceWithStores() async {
    final legacyHome = await LegacyHome.create(home);
    await legacyHome.writeOnlineReading();
    await legacyHome.writeLocalBooks(rootPath: library.path);
    await legacyHome.writeMigrationState();
    return (LegacyImport(home: home), await Workspace.open(root: root));
  }

  test('三份 JSON 存储导入一次，第二次运行是空操作', () async {
    final (legacy, workspace) = await workspaceWithStores();
    final store = await workspace.openSpace();

    final report = await legacy.run(store);
    expect(report.imported, isTrue);
    expect(report.sources, 2, reason: '在线记录的书源 + 迁移状态的书源');
    expect(report.books, 5, reason: '2 在线（含 1 条未上架）+ 2 本地 + 1 迁移');
    expect(report.chapters, 3, reason: '未上架的历史记录同样带走目录');
    expect(report.progress, 5);
    expect(report.localFiles, 2);

    // Books, chapters and progress are all reachable from the store.
    final shelf = await store.shelf();
    expect(
      shelf.map((book) => book.title),
      containsAll(<String>['斗破苍穹', 'kept.txt']),
    );
    final network = (await store.bookByNaturalKey(
      'https://example.test',
      'https://example.test/book/1',
    ))!;
    expect(network.kind, 'network');
    expect(network.shelved, isTrue);
    expect(network.originName, 'Example');
    expect(network.intro, '简介');
    expect(network.coverUrl, 'https://example.test/cover.png');
    expect(network.raw, contains('unknownBookField'));
    final history = (await store.bookByNaturalKey(
      'https://example.test',
      'https://example.test/book/2',
    ))!;
    expect(history.shelved, isFalse, reason: '未上架的阅读记录保留进度但不是书架成员');
    expect((await store.progressOf(history.id))!.textOffset, 7);
    expect(await store.chaptersOf(history.id), hasLength(1));

    final chapters = await store.chaptersOf(network.id);
    expect(chapters.map((c) => c.name), ['第一章', '第二章']);
    expect(chapters.last.chapterKey, 'https://example.test/book/1/2');
    final progress = (await store.progressOf(network.id))!;
    expect(progress.textOffset, 120);
    expect(progress.chapterKey, 'https://example.test/book/1/2');
    expect(progress.chapterIndex, 1);

    final source = (await store.sourceByUrl('https://example.test'))!;
    expect(source.name, 'Example');
    expect(source.customOrder, 3);
    expect(source.groupNames, '["网络","精选"]');
    expect(source.raw, contains('unknownSourceField'));

    final local = (await store.localBook(
      library.path.toLowerCase(),
      'gone.txt',
    ))!;
    expect(local.kind, 'local');
    expect(local.needsRelink, isTrue, reason: '文件已不在原路径');
    expect(
      (await store.localBook(
        library.path.toLowerCase(),
        'kept.txt',
      ))!.needsRelink,
      isFalse,
    );
    expect(
      (await store.localFilesOf(
        library.path.toLowerCase(),
      )).map((file) => file.relativePath),
      containsAll(<String>['kept.txt', 'gone.txt']),
    );

    // Losses are reported, not implied away.
    expect(
      report.losses.any((loss) => loss.contains('上次阅读')),
      isTrue,
      reason: '"last" 指针没有等价字段',
    );
    expect(report.losses.any((loss) => loss.contains('needsRelink')), isTrue);
    expect(report.losses.any((loss) => loss.contains('1 个本地文件')), isTrue);

    final second = await legacy.run(store);
    expect(second.imported, isFalse, reason: '导入记录在空间里，第二次不再导入');
    expect(second.sources, report.sources);
    expect(await store.shelf(), hasLength(shelf.length));
    expect(await store.chaptersOf(network.id), hasLength(2));
    await workspace.close();
  });

  test('重新导入是合并非覆盖：进度只前进，书籍不重复', () async {
    final (legacy, workspace) = await workspaceWithStores();
    final store = await workspace.openSpace();
    final first = await legacy.run(store);
    final shelfBefore = await store.shelf();

    // The user read further and the JSON store moved on; the forced re-import
    // carries the newer position without duplicating anything.
    final online = File('${home.path}/online_reading.json');
    final state =
        jsonDecode(await online.readAsString()) as Map<String, dynamic>;
    final records = (state['records'] as List).cast<Map<String, dynamic>>();
    records.first['textOffset'] = 300;
    await online.writeAsString(jsonEncode(state));

    final second = await legacy.run(store, force: true);
    expect(second.imported, isTrue);
    expect(second.books, first.books, reason: '自然键匹配，不新建书籍');
    expect(await store.shelf(), hasLength(shelfBefore.length));
    final network = (await store.bookByNaturalKey(
      'https://example.test',
      'https://example.test/book/1',
    ))!;
    expect((await store.progressOf(network.id))!.textOffset, 300);
    await workspace.close();
  });

  test('无法解析的旧文件被报告并保留原文件', () async {
    final (legacy, workspace) = await workspaceWithStores();
    await File('${home.path}/local_books.json').writeAsString('{broken');
    final store = await workspace.openSpace();

    final report = await legacy.run(store);
    expect(report.imported, isTrue);
    expect(
      report.losses.any((loss) => loss.contains('local_books.json 无法解析')),
      isTrue,
    );
    expect(await store.allLocalRoots(), isEmpty, reason: '坏文件不产生半份数据');
    expect(
      await File('${home.path}/local_books.json').readAsString(),
      '{broken',
      reason: '损坏的原文件保留',
    );
    await workspace.close();
  });

  test('没有旧文件时不写导入记录，旧文件出现了仍然会导入', () async {
    final legacy = LegacyImport(home: home);
    final workspace = await Workspace.open(root: root);
    final store = await workspace.openSpace();

    final empty = await legacy.run(store);
    expect(empty.imported, isFalse);
    expect(empty.importedAt, isEmpty);

    final legacyHome = await LegacyHome.create(home);
    await legacyHome.writeOnlineReading();
    final report = await legacy.run(store);
    expect(report.imported, isTrue, reason: '后来出现的旧文件仍然要导入');
    expect(report.books, 2);
    await workspace.close();
  });

  test('原文件移到 legacy/ 而不是删除', () async {
    final (legacy, workspace) = await workspaceWithStores();
    final store = await workspace.openSpace();
    final before = await File(
      '${home.path}/online_reading.json',
    ).readAsString();

    final report = await legacy.run(store, retireOriginals: true);
    expect(
      report.retired,
      containsAll(<String>[
        'online_reading.json',
        'local_books.json',
        'migration_state.json',
      ]),
    );
    expect(await File('${home.path}/online_reading.json').exists(), isFalse);
    final retired = File('${home.path}/legacy/online_reading.json');
    expect(await retired.exists(), isTrue);
    expect(await retired.readAsString(), before);
    expect(await legacy.hasLegacyStores(), isFalse);
    await workspace.close();
  });
}
