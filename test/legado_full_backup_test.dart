import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/domain/store_message.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

import 'temp_directory.dart';

/// A `config.xml` with two preferences, the shape the Android `SharedPreferences`
/// backup writer produces.
const String defaultConfig =
    '<map><int name="a" value="1"/><string name="b">x</string></map>';

/// A Legado full backup, built the way the frozen baseline writes one: root-level
/// entity arrays plus `config.xml`, and an entity member absent when its list was
/// empty (`Backup.kt:120`).
///
/// The fixture families are the contract's
/// (`docs/compatibility/legado-data-migration-contract.md`, "Required Fixtures
/// and Tests"), and every test names the family it covers.
Uint8List backupZip({
  List<Object?>? sources,
  List<Object?>? groups,
  List<Object?>? books,
  String? config = defaultConfig,
  Map<String, Object?> extraMembers = const <String, Object?>{},
}) {
  final members = <String, Object?>{
    'bookSource.json': ?sources,
    'bookGroup.json': ?groups,
    'bookshelf.json': ?books,
    'config.xml': ?config,
    ...extraMembers,
  };
  return zipOf(members);
}

/// A ZIP of [members], values encoded as JSON unless they are already text.
Uint8List zipOf(Map<String, Object?> members) {
  final archive = Archive();
  for (final entry in members.entries) {
    final text = entry.value is String
        ? entry.value as String
        : jsonEncode(entry.value);
    final bytes = utf8.encode(text);
    archive.addFile(ArchiveFile(entry.key, bytes.length, bytes));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

/// Rewrites the local and central-directory uncompressed-size fields of the
/// first member. The compressed bytes remain unchanged, so the decoder must
/// rely on the output sink rather than trusting the header.
Uint8List _rewriteZipUncompressedSize(
  Uint8List input, {
  required int declared,
}) {
  final bytes = Uint8List.fromList(input);
  var found = 0;
  for (var index = 0; index + 4 <= bytes.length; index++) {
    final signature =
        bytes[index] |
        (bytes[index + 1] << 8) |
        (bytes[index + 2] << 16) |
        (bytes[index + 3] << 24);
    final offset = switch (signature) {
      0x04034b50 => index + 22,
      0x02014b50 => index + 24,
      _ => -1,
    };
    if (offset < 0) continue;
    for (var byte = 0; byte < 4; byte++) {
      bytes[offset + byte] = (declared >> (byte * 8)) & 0xff;
    }
    found++;
  }
  if (found < 2) {
    throw StateError('ZIP test fixture has no local and central headers');
  }
  return bytes;
}

Map<String, Object?> sourceRow(
  String url,
  String name, {
  int type = 0,
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{
  'bookSourceUrl': url,
  'bookSourceName': name,
  'bookSourceType': type,
  'enabled': true,
  'customOrder': 0,
  'lastUpdateTime': 1,
  ...extra,
};

/// A network book as `bookshelf.json` writes one.
Map<String, Object?> networkBook(
  String url, {
  String origin = 'https://source.example',
  String name = '书名',
  String author = '作者',
  int type = 8,
  int group = 0,
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{
  'bookUrl': url,
  'name': name,
  'author': author,
  'origin': origin,
  'originName': '书源',
  'type': type,
  'group': group,
  'canUpdate': true,
  'order': 0,
  'totalChapterNum': 0,
  'latestChapterTime': 0,
  'lastCheckTime': 0,
  'lastCheckCount': 0,
  'syncTime': 0,
  'durChapterIndex': 0,
  'durChapterPos': 0,
  'durChapterTime': 0,
  ...extra,
};

/// A local book as `bookshelf.json` writes one: `BookType.local` (264 = 256 | 8)
/// and an Android document URI (`BookType.kt:38`).
Map<String, Object?> localBook(
  String uri, {
  String name = '本地书',
  String origin = 'loc_book',
  String? originName,
  int type = 264,
  int group = 0,
  Map<String, Object?> extra = const <String, Object?>{},
}) => <String, Object?>{
  'bookUrl': uri,
  'name': name,
  'author': '',
  'origin': origin,
  'originName': originName ?? name,
  'type': type,
  'group': group,
  'canUpdate': true,
  'order': 0,
  'durChapterIndex': 0,
  'durChapterPos': 0,
  'durChapterTime': 0,
  ...extra,
};

void main() {
  late TestSpace space;
  late Directory fixtures;

  setUp(() async {
    space = await TestSpace.create();
    fixtures = await Directory.systemTemp.createTemp('liber-backup-');
  });

  tearDown(() async {
    await space.delete();
    await deleteTempDirectory(fixtures);
  });

  /// The one book on the shelf, or the one whose title is [titles].
  Future<String> bookIdOf({String? titles}) async {
    final shelf = await space.store.shelf();
    if (titles == null) return shelf.single.id;
    return shelf.firstWhere((book) => book.title == titles).id;
  }

  /// The migration page's own entry point: a path in, the record out.
  Future<MigrationImportRecord> importBytes(
    Uint8List bytes, {
    String name = 'backup.zip',
  }) async {
    final file = File('${fixtures.path}/$name');
    await file.writeAsBytes(bytes);
    return importLegadoBackupFile(space.store, file.path);
  }

  Future<MigrationImportRecord> importBackup({
    List<Object?>? sources,
    List<Object?>? groups,
    List<Object?>? books,
    String? config = defaultConfig,
    Map<String, Object?> extraMembers = const <String, Object?>{},
  }) => importBytes(
    backupZip(
      sources: sources,
      groups: groups,
      books: books,
      config: config,
      extraMembers: extraMembers,
    ),
  );

  group('ZIP 容器（契约家族 3）', () {
    test('四类根成员都读得到：书源、分组、书架与进度入库', () async {
      final record = await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        groups: [
          {'groupId': 64, 'groupName': '藏经阁', 'order': 3, 'show': true},
        ],
        books: [
          networkBook(
            'https://source.example/book/1',
            group: 64,
            extra: {
              'durChapterIndex': 12,
              'durChapterPos': 345,
              'durChapterTime': 1700000000000,
            },
          ),
        ],
      );

      expect(record.sourceCount, 1);
      expect(record.bookCount, 1);
      expect(record.progressCount, 1);
      expect(
        (await space.store.sourceByUrl('https://source.example'))!.name,
        '示例源',
      );
      final book = (await space.store.shelf()).single;
      expect(book.title, '书名');
      expect(book.sourceRef, 'https://source.example');
      expect(book.sourceBookUrl, 'https://source.example/book/1');
      expect((await space.store.groupsOf(book.id)).map((g) => g.name), ['藏经阁']);
      final progress = (await space.store.progressOf(book.id))!;
      expect(progress.chapterIndex, 12);
      expect(progress.textOffset, 345);
      expect(progress.updatedAt, 1700000000000);
    });

    test('成员缺席是正常的空列表：只带 bookSource.json 的备份也能导入', () async {
      final record = await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
      );

      expect(record.sourceCount, 1);
      expect(record.bookCount, 0);
      expect(await space.store.shelf(), isEmpty);
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupAbsentMember, <Object?>[
            'bookshelf.json',
          ]),
        ),
        reason: '缺席的成员按空列表报告',
      );
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupAbsentMember, <Object?>[
            'bookGroup.json',
          ]),
        ),
      );
      expect(
        record.losses,
        isNot(
          contains(
            const StoreMessage(StoreMessageCode.backupAbsentMember, <Object?>[
              'bookSource.json',
            ]),
          ),
        ),
        reason: '在场的成员不报缺失',
      );
    });

    test('路径穿越条目被整体拒绝，一个字节都不写', () async {
      for (final evil in [
        '../evil.json',
        'a/../../evil.json',
        '/absolute.json',
        r'C:\windows\evil.json',
        r'..\evil.json',
      ]) {
        final record = importBackup(
          sources: [sourceRow('https://source.example', '示例源')],
          books: [networkBook('https://source.example/book/1')],
          extraMembers: {evil: '{}'},
        );
        await expectLater(
          record,
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              contains('路径穿越'),
            ),
          ),
          reason: '$evil 必须被拒绝',
        );
      }
      expect(await space.store.allSources(), isEmpty);
      expect(await space.store.shelf(), isEmpty);
      expect(await space.store.allGroups(), isEmpty);
    });

    test('不是 Legado 备份的 ZIP 被拒绝', () async {
      await expectLater(
        importBytes(zipOf({'readme.txt': 'hello'})),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('没有 Legado 备份的根成员'),
          ),
        ),
      );
      expect(await space.store.allSources(), isEmpty);
    });

    test('声明尺寸过大的条目被拒绝', () async {
      final archive = Archive()
        ..addFile(ArchiveFile('bookshelf.json', 2, utf8.encode('[]')))
        ..addFile(
          // A declared size no backup has: refused before it is decoded.
          ArchiveFile('huge.json', 600 * 1024 * 1024, utf8.encode('{}')),
        );
      await expectLater(
        importBytes(Uint8List.fromList(ZipEncoder().encode(archive))),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('条目过大'),
          ),
        ),
      );
      expect(await space.store.shelf(), isEmpty);
    });

    test('声明值被篡改的 ZIP 仍在解压时受上限保护', () async {
      final zip = backupZip(
        sources: [sourceRow('https://source.example', '示例源')],
        config: null,
      );
      final lying = _rewriteZipUncompressedSize(zip, declared: 4);
      await expectLater(
        () => LegadoBackupArchive.decode(lying, memberSizeLimit: 4),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('解压后过大'),
          ),
        ),
      );
    });

    test('读不了的 ZIP 与不是数组的成员给出命名错误', () async {
      await expectLater(
        importBytes(Uint8List.fromList(utf8.encode('PK\u0003\u0004not a zip'))),
        throwsA(isA<FormatException>()),
      );
      await expectLater(
        importBackup(books: [], extraMembers: {'bookGroup.json': '{"a":1}'}),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('bookGroup.json 不是 JSON 数组'),
          ),
        ),
      );
    });

    test('ZIP 里的书架 UI 导出按有损导出拒绝（契约家族 11）', () async {
      final record = importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          {'name': '只有名字的书', 'author': '作者', 'intro': '简介'},
        ],
      );
      await expectLater(
        record,
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('UI 导出'),
          ),
        ),
      );
      // The transaction rolled back: the sources that were already merged are not
      // left behind either.
      expect(await space.store.allSources(), isEmpty);
      expect(await space.store.shelf(), isEmpty);
    });
  });

  group('存档容器', () {
    test('looksLikeZip 只认 ZIP 头，成员表按根名归一化', () {
      expect(LegadoBackupArchive.looksLikeZip(utf8.encode('{}')), isFalse);
      expect(LegadoBackupArchive.looksLikeZip(Uint8List(0)), isFalse);
      expect(
        LegadoBackupArchive.looksLikeZip(
          Uint8List.fromList(utf8.encode('PK\u0005\u0006')),
        ),
        isTrue,
      );
      final archive = LegadoBackupArchive.decode(
        zipOf({
          r'BookSource.JSON': '[]',
          'config.xml': defaultConfig,
          'replaceRule.json': '[]',
        }),
      );
      expect(archive.names, contains('BookSource.JSON'));
      expect(
        archive.has('bookSource.json'),
        isFalse,
        reason: '名字区分大小写，只有分隔符归一化',
      );
      expect(archive.has('config.xml'), isTrue);
      expect(archive.absentMembers, [
        'bookSource.json',
        'bookGroup.json',
        'bookshelf.json',
      ]);
      expect(archive.unreadMembers, ['replaceRule.json']);
      expect(archive.preferenceCount, 2);
    });
  });

  group('身份与合并（契约规则 3–7）', () {
    test('网络书按 (sourceRef, sourceBookUrl) 入库，未知字段留在 raw', () async {
      final row = networkBook(
        'https://source.example/book/1',
        extra: {
          'customTag': '标签',
          'intro': '简介',
          'customIntro': '自定义简介',
          'coverUrl': 'https://img.example/cover.jpg',
          'customCoverUrl': 'https://img.example/custom.jpg',
          'charset': 'GBK',
          'latestChapterTitle': '最新章',
          'latestChapterTime': 42,
          'totalChapterNum': 7,
          'variable': '{"k":1}',
          'order': -960,
          'unknownField': {
            'nested': [1, 2, null],
          },
          'wordCount': '12万字',
        },
      );
      await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [row],
      );

      final book = await space.store.bookByNaturalKey(
        'https://source.example',
        'https://source.example/book/1',
      );
      expect(book, isNotNull);
      expect(book!.kind, 'network');
      expect(book.author, '作者');
      expect(book.originName, '书源');
      expect(book.customTag, '标签');
      expect(book.intro, '简介');
      expect(book.customIntro, '自定义简介');
      expect(book.coverUrl, 'https://img.example/cover.jpg');
      expect(book.charset, 'GBK');
      expect(book.latestChapterTitle, '最新章');
      expect(book.latestChapterTime, 42);
      expect(book.totalChapterNum, 7);
      expect(book.variable, '{"k":1}');
      expect(book.bookOrder, -960, reason: '冻结书架的排序原样保留');
      expect(book.shelved, isTrue);
      expect(book.needsRelink, isFalse);
      final raw = jsonDecode(book.raw!) as Map<String, dynamic>;
      expect(raw, row, reason: '未知字段、null、布尔、大整数与非 ASCII 都原样留在 raw');
    });

    test('空 origin 的网络书重复导入仍保持幂等', () async {
      final row = networkBook(
        'https://source.example/book/no-origin',
        origin: '',
      );
      await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [row],
      );
      await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [row],
      );
      expect(await space.store.shelf(), hasLength(1));
      expect(
        (await space.store.shelf()).single.sourceRef,
        isNull,
        reason: '空 origin 仍是不带书源的自然键，但按 URL 合并',
      );
    });

    test('同名同作者、不同 bookUrl 的书各自成书（不按名字合并）', () async {
      await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          networkBook(
            'https://source.example/book/1',
            name: '同名书',
            author: '同一作者',
          ),
          networkBook(
            'https://source.example/book/2',
            name: '同名书',
            author: '同一作者',
          ),
        ],
      );

      final shelf = await space.store.shelf();
      expect(shelf, hasLength(2));
      expect(shelf.map((book) => book.sourceBookUrl).toSet(), {
        'https://source.example/book/1',
        'https://source.example/book/2',
      });
      expect(
        shelf.map((book) => book.id).toSet(),
        hasLength(2),
        reason: '身份是各自铸造的 id，绝不给 (name, author) 合并',
      );
    });

    test('同一 bookUrl 重复出现只落一本', () async {
      final record = await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          networkBook('https://source.example/book/1'),
          networkBook('https://source.example/book/1', name: '重复的书'),
        ],
      );

      expect(record.bookCount, 2, reason: '两次写入都算作处理过的记录');
      expect(await space.store.shelf(), hasLength(1));
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupDuplicateBooks, <Object?>[
            1,
          ]),
        ),
      );
    });

    test('本地书不带 Android 路径：相关键与文件名入库、标记重新链接', () async {
      const uri =
          'content://com.android.externalstorage.documents/tree/primary%3ABook/'
          'document/primary%3ABook%2Fsoushu%40%E4%BB%99%E5%87%A1%E9%97%B4.txt';
      await importBackup(
        books: [
          localBook(
            uri,
            name: '仙凡间',
            originName: 'soushu@仙凡间.txt',
            extra: {
              'coverUrl':
                  '/storage/emulated/0/Android/data/io.legado.app.debug/files/cover.png',
              'customCoverUrl': 'file:///storage/emulated/0/custom.png',
              'tocUrl':
                  'content://com.android.externalstorage.documents/tree/primary',
              'durChapterIndex': 3,
              'durChapterPos': 120,
              'durChapterTime': 1650000000000,
            },
          ),
        ],
      );

      final book = (await space.store.localBooks()).single;
      expect(book.kind, 'local');
      expect(book.sourceRef, isNull);
      expect(book.sourceBookUrl, isNull);
      expect(book.needsRelink, isTrue, reason: '备份里没有书文件');
      expect(book.rootId, startsWith('sha256:'), reason: 'Android URI 换成相关键');
      expect(book.relativePath, 'soushu@仙凡间.txt', reason: '原始文件名保留');
      expect(book.coverUrl, isEmpty, reason: '本地路径封面不导入');
      expect(book.customCoverUrl, isEmpty);
      expect(book.format, 'txt');
      final progress = (await space.store.progressOf(book.id))!;
      expect(progress.chapterIndex, 3);
      expect(progress.textOffset, 120);
      expect(progress.updatedAt, 1650000000000);

      // No Android path or URI survives anywhere in the row.
      final everything = [
        book.raw!,
        book.rootId!,
        book.relativePath!,
        book.coverUrl,
        book.title,
      ].join('\n');
      for (final forbidden in [
        'content://',
        'file://',
        '/storage/',
        'primary%3A',
      ]) {
        expect(
          everything.contains(forbidden),
          isFalse,
          reason: '$forbidden 不得进入 Liber（规则 4）',
        );
      }
      final raw = jsonDecode(book.raw!) as Map<String, dynamic>;
      expect(raw['legacyKey'], book.rootId, reason: 'raw 里也留着同一个相关键');
      expect(raw['localFileName'], 'soushu@仙凡间.txt');
      expect(raw.containsKey('tocUrl'), isFalse);
      expect(raw.containsKey('coverUrl'), isFalse);
      expect(raw['unknownField'], isNull);
    });

    test('本地书的 originName 也是文件名，只保留末段', () async {
      await importBackup(
        books: [
          localBook(
            'content://provider/tree/primary',
            originName: r'C:\Users\operator\secret.txt',
          ),
        ],
      );
      final book = (await space.store.localBooks()).single;
      expect(book.relativePath, 'secret.txt');
      expect(book.relativePath, isNot(contains(r'\')));
      expect(book.relativePath, isNot(startsWith('/')));
    });

    test('file:// 与 content:// 按本地书处理；相对 URL 与 data: 仍是网络书', () async {
      await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          // The frozen bit says local, the scheme says nothing.
          localBook('/storage/emulated/0/Book/书.txt', name: '路径本地书'),
          // A pre-upType row: origin tag makes it local even without bit 256.
          localBook(
            '/storage/emulated/0/Book/legacy.txt',
            name: '旧类型本地书',
            type: 1,
          ),
          // The scheme says local, the bit does not.
          localBook(
            'file:///storage/emulated/0/Book/另一本.txt',
            name: 'file 本地书',
            type: 8,
          ),
          // Neither: relative and data URLs are network keys, not device paths.
          networkBook(
            '/modules/article/search.php?searchkey=x',
            name: '相对 URL 书',
            origin: 'http://www.example.net',
          ),
          networkBook('data:;base64,ZnFfaWQ9MQ==,{"type":"x"}', name: 'data 书'),
        ],
      );

      final local = await space.store.localBooks();
      expect(local.map((book) => book.title).toSet(), {
        '路径本地书',
        '旧类型本地书',
        'file 本地书',
      });
      expect(local.map((book) => book.relativePath).toSet(), {
        '书.txt',
        'legacy.txt',
        '另一本.txt',
      });
      final network = await space.store.shelf(kind: 'network');
      expect(network.map((book) => book.title).toSet(), {'相对 URL 书', 'data 书'});
      expect(network.map((book) => book.sourceBookUrl).toSet(), {
        '/modules/article/search.php?searchkey=x',
        'data:;base64,ZnFfaWQ9MQ==,{"type":"x"}',
      });
    });

    test('本地书名缺 originName 时退回 URL 尾段或标题', () async {
      await importBackup(
        books: [
          localBook(
            'content://provider/document/primary%3ABook%2F%E4%B9%A6%E5%90%8D.md',
            name: '标题',
            originName: '',
          ),
          localBook(
            'content://provider/tree/primary',
            name: '只有标题',
            originName: '',
          ),
        ],
      );

      final names = (await space.store.localBooks())
          .map((b) => b.relativePath)
          .toSet();
      expect(names, contains('书名.md'));
      expect(names, contains('只有标题'), reason: 'tree-only URI 没有文件名，退回标题');
    });

    test('64 个分组位都能解析，含第 64 位 Long.MIN_VALUE（契约家族 6）', () async {
      final groups = <Map<String, Object?>>[
        for (var bit = 0; bit < 63; bit++)
          {
            'groupId': 1 << bit,
            'groupName': '组$bit',
            'order': bit,
            'show': true,
          },
        {'groupId': 1 << 63, 'groupName': '第64位', 'order': 63, 'show': true},
      ];
      await importBackup(
        groups: groups,
        books: [
          networkBook('https://source.example/a', name: '低位', group: 1),
          networkBook('https://source.example/b', name: '高位', group: 1 << 62),
          networkBook('https://source.example/c', name: '第64位', group: 1 << 63),
          networkBook(
            'https://source.example/d',
            name: '低位加第64位',
            group: 1 | (1 << 63),
          ),
        ],
      );

      expect(await space.store.allGroups(), hasLength(64));
      Future<List<String>> namesOf(String title) async {
        final book = (await space.store.shelf()).firstWhere(
          (b) => b.title == title,
        );
        final names = (await space.store.groupsOf(
          book.id,
        )).map((g) => g.name).toList()..sort();
        return names;
      }

      expect(await namesOf('低位'), ['组0']);
      expect(await namesOf('高位'), ['组62']);
      expect(await namesOf('第64位'), ['第64位']);
      expect(await namesOf('低位加第64位'), ['第64位', '组0']);
    });

    test('系统负分组不导入，也不参与掩码解析（契约家族 6）', () async {
      final record = await importBackup(
        groups: [
          {'groupId': -1, 'groupName': '全部', 'order': 0},
          {'groupId': -2, 'groupName': '本地', 'order': 1},
          {'groupId': -3, 'groupName': '音频', 'order': 2},
          {'groupId': -4, 'groupName': '未分组', 'order': 3},
          {'groupId': -5, 'groupName': '本地未分组', 'order': 4},
          {'groupId': -11, 'groupName': '更新失败', 'order': 5},
          {'groupId': -6, 'groupName': '视频', 'order': 6},
          {'groupId': 64, 'groupName': '藏经阁', 'order': 7},
        ],
        books: [networkBook('https://source.example/a', group: 64)],
      );

      expect(
        (await space.store.allGroups()).map((group) => group.name),
        ['藏经阁'],
        reason: '负 id 是货架视图，不是用户建的分组',
      );
      final book = (await space.store.shelf()).single;
      expect((await space.store.groupsOf(book.id)).map((g) => g.name), ['藏经阁']);
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupSystemGroups, <Object?>[7]),
        ),
      );
    });

    test('分组带顺序与显示开关一起入库', () async {
      await importBackup(
        groups: [
          {
            'groupId': 4,
            'groupName': '第二',
            'order': 9,
            'show': false,
            'bookSort': 3,
          },
          {'groupId': 2, 'groupName': '第一', 'order': 2, 'show': true},
        ],
        books: [networkBook('https://source.example/a', group: 6)],
      );

      final groups = await space.store.allGroups();
      expect(groups.map((g) => g.name), ['第一', '第二'], reason: '按冻结顺序，不按铸造 id');
      expect(groups[1].show, isFalse);
      expect(groups[1].bookSort, 3);
      final book = (await space.store.shelf()).single;
      expect(
        (await space.store.groupsOf(book.id)).map((g) => g.name).toSet(),
        {'第一', '第二'},
        reason: '掩码 6 = 位 2 与位 4',
      );
    });

    test('进度按 (chapterIndex, textOffset, updatedAt) 只前进（契约规则 6/7）', () async {
      Future<void> importAt(int index, int position, int time) => importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          networkBook(
            'https://source.example/book/1',
            extra: {
              'durChapterIndex': index,
              'durChapterPos': position,
              'durChapterTime': time,
            },
          ),
        ],
      );

      await importAt(5, 100, 1000);
      var progress = (await space.store.progressOf(await bookIdOf()))!;
      expect(
        [progress.chapterIndex, progress.textOffset, progress.updatedAt],
        [5, 100, 1000],
      );

      await importAt(3, 900, 2000);
      progress = (await space.store.progressOf(await bookIdOf()))!;
      expect(
        [progress.chapterIndex, progress.textOffset, progress.updatedAt],
        [5, 100, 1000],
        reason: '更早的章节不覆盖',
      );

      await importAt(5, 100, 3000);
      progress = (await space.store.progressOf(await bookIdOf()))!;
      expect(progress.updatedAt, 3000, reason: '同一位置由时间戳分胜负');

      await importAt(6, 0, 4000);
      progress = (await space.store.progressOf(await bookIdOf()))!;
      expect(progress.chapterIndex, 6, reason: '更后面的章节前进');
    });

    test('进度字段缺失或全为 0 的书不写进度行（契约家族 10）', () async {
      final record = await importBackup(
        books: [
          networkBook('https://source.example/a', name: '没有进度字段'),
          networkBook(
            'https://source.example/b',
            name: '零进度',
            extra: {'durChapterTitle': null},
          ),
          networkBook(
            'https://source.example/c',
            name: '64 位毫秒',
            extra: {
              'durChapterIndex': 1,
              'durChapterPos': 2,
              'durChapterTime': 9223372036854775807,
              'durChapterTitle': null,
            },
          ),
        ],
      );

      final shelf = await space.store.shelf();
      expect(shelf, hasLength(3));
      for (final book in shelf.where((b) => b.title != '64 位毫秒')) {
        expect(await space.store.progressOf(book.id), isNull);
      }
      final read = shelf.firstWhere((book) => book.title == '64 位毫秒');
      final progress = (await space.store.progressOf(read.id))!;
      expect(progress.updatedAt, 9223372036854775807, reason: '64 位毫秒原样落库');
      expect(record.progressCount, 1);
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupUnreadBooks, <Object?>[2]),
        ),
      );
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupProgressChapterNameDropped),
        ),
      );
    });

    test('分组按名字合并，成员关系取并集（契约家族 8）', () async {
      Future<void> importWithGroups(List<int> bits) => importBackup(
        groups: [
          {'groupId': 1, 'groupName': '甲', 'order': 1},
          {'groupId': 2, 'groupName': '乙', 'order': 2},
          {'groupId': 4, 'groupName': '丙', 'order': 3},
        ],
        books: [
          networkBook(
            'https://source.example/a',
            group: bits.fold(0, (a, b) => a | b),
          ),
        ],
      );

      await importWithGroups([1]);
      final bookId = await bookIdOf();
      // A local edit the way the shelf page does it: read the memberships, add
      // one, write them back.
      final local = await space.store.ensureGroup('本地加的分组');
      await space.store.setBookGroups(bookId, [
        for (final group in await space.store.groupsOf(bookId)) group.id,
        local.id,
      ]);

      await importWithGroups([2]);

      final groups = await space.store.groupsOf(bookId);
      expect(groups.map((group) => group.name).toSet(), {
        '甲',
        '乙',
        '本地加的分组',
      }, reason: '导入只加不减；本地新建的分组留下');
      expect(
        await space.store.allGroups(),
        hasLength(4),
        reason: '按名字合并，不重复建组',
      );
    });

    test('书源已存在且内容不同时不替换，并计入报告（契约规则 7）', () async {
      final first = await importBackup(
        sources: [
          sourceRow(
            'https://source.example',
            '示例源',
            extra: {
              'ruleSearch': {'bookList': '旧规则'},
            },
          ),
        ],
      );
      expect(first.sourceCount, 1);

      final second = await importBackup(
        sources: [
          sourceRow(
            'https://source.example',
            '示例源',
            extra: {
              'ruleSearch': {'bookList': '新规则'},
            },
          ),
        ],
      );

      expect(second.sourceCount, 0);
      final source = (await space.store.sourceByUrl('https://source.example'))!;
      expect(source.raw, contains('旧规则'), reason: '替换需要显式确认，导入不会自己替换');
      expect(
        second.losses,
        contains(
          const StoreMessage(
            StoreMessageCode.backupConflictingSources,
            <Object?>[1],
          ),
        ),
      );
    });
  });

  group('重复导入与规范输出（契约规则 7、家族 8/12）', () {
    Uint8List fullBackup() => backupZip(
      sources: [
        sourceRow('https://source.example', '示例源'),
        sourceRow('https://other.example', '另一个源'),
      ],
      groups: [
        {'groupId': 64, 'groupName': '藏经阁', 'order': 1},
        {'groupId': 2, 'groupName': '本地小说', 'order': 2},
      ],
      books: [
        networkBook(
          'https://source.example/book/1',
          name: '网络书',
          group: 64,
          extra: {
            'durChapterIndex': 4,
            'durChapterPos': 50,
            'durChapterTime': 1650000000000,
            'intro': '简介',
          },
        ),
        localBook(
          'content://provider/document/primary%3ABook%2F%E6%9C%AC%E5%9C%B0.txt',
          name: '本地书',
          group: 2,
          extra: {
            'durChapterIndex': 1,
            'durChapterPos': 9,
            'durChapterTime': 1,
          },
        ),
      ],
    );

    test('同一个 ZIP 导入两次不新增书源、书籍与分组', () async {
      final bytes = fullBackup();
      final first = await importBytes(bytes);
      final sources = (await space.store.allSources()).length;
      final books = (await space.store.shelf()).length;
      final groups = (await space.store.allGroups()).length;
      expect([first.sourceCount, first.bookCount], [2, 2]);
      expect([sources, books, groups], [2, 2, 2]);

      final second = await importBytes(bytes);
      expect([second.sourceCount, second.bookCount], [0, 2]);
      expect((await space.store.allSources()).length, sources);
      expect((await space.store.shelf()).length, books);
      expect((await space.store.allGroups()).length, groups);
      expect(
        (await space.store.progressOf(
          await bookIdOf(titles: '网络书'),
        ))!.textOffset,
        50,
      );
    });

    test('再次导入不把隐藏的书放回书架之外的地方，成员关系仍是并集', () async {
      final bytes = fullBackup();
      await importBytes(bytes);
      final bookId = await bookIdOf(titles: '网络书');
      await space.store.setShelved(bookId, false);
      expect(await space.store.shelf(), hasLength(1));

      await importBytes(bytes);

      // 规则 7 的词是"书架成员取并集"：备份里的书是在架的，并集就是在架。
      expect(await space.store.shelf(), hasLength(2));
    });

    test('再次导入填空而不覆盖本地编辑（契约家族 8）', () async {
      final withIntro = backupZip(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [
          networkBook(
            'https://source.example/book/1',
            name: '书名',
            extra: {'intro': '备份的简介', 'customTag': '备份的标签'},
          ),
        ],
      );
      await importBytes(withIntro);
      final bookId = await bookIdOf();
      final stored = (await space.store.bookById(bookId))!;

      // A local edit: a new name and tag, and a blanked intro.
      await space.store.putBook(
        stored
            .toCompanion(false)
            .copyWith(
              title: const Value('本地改的名字'),
              customTag: const Value('本地标签'),
              intro: const Value(''),
            ),
      );

      await importBytes(withIntro);

      final again = (await space.store.bookById(bookId))!;
      expect(again.title, '本地改的名字', reason: '导入不抹掉本地的名字');
      expect(again.customTag, '本地标签');
      expect(again.intro, '备份的简介', reason: '空的字段由备份填空');
    });

    test('同样的备份产生同样的规范输出（契约家族 12）', () async {
      final bytes = fullBackup();
      final other = await TestSpace.create();
      try {
        await importBytes(bytes);
        final otherFile = File('${fixtures.path}/other.zip');
        await otherFile.writeAsBytes(bytes);
        await importLegadoBackupFile(other.store, otherFile.path);

        expect(
          await canonical(space.store),
          await canonical(other.store),
          reason: '分组名、相关键与进度都不依赖铸造 id 或本次运行的时间',
        );
      } finally {
        await other.delete();
      }
    });
  });

  group('损失报告与入口（契约规则 2/9、家族 9/11）', () {
    test('损失报告逐条点名被排除的家族', () async {
      final record = await importBackup(
        sources: [sourceRow('https://source.example', '示例源')],
        books: [networkBook('https://source.example/book/1')],
        extraMembers: {'replaceRule.json': const [], 'bookmark.json': const []},
      );

      for (final family in const [
        StoreMessageCode.backupExcludedCookies,
        StoreMessageCode.backupExcludedCache,
        StoreMessageCode.backupExcludedChapters,
        StoreMessageCode.backupExcludedDownloads,
        StoreMessageCode.backupExcludedLocalBytes,
        StoreMessageCode.backupAndroidPreferences,
      ]) {
        expect(
          record.losses.map((loss) => loss.code),
          contains(family),
          reason: '$family 必须在损失报告里点名',
        );
      }
      expect(
        record.losses,
        contains(
          const StoreMessage(
            StoreMessageCode.backupAndroidPreferences,
            <Object?>[2],
          ),
        ),
        reason: 'config.xml 被读过：报告给出它的偏好条数',
      );
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupUnreadMembers, <Object?>[
            2,
            'replaceRule.json, bookmark.json',
          ]),
        ),
        reason: '没读的成员在报告里点名',
      );
    });

    test('书源缺 URL 或名字时跳过并报告；空数组成员不报错（契约家族 2）', () async {
      final record = await importBackup(
        sources: [
          sourceRow('https://source.example', '示例源'),
          sourceRow('', '没有 URL 的源'),
          sourceRow('https://no-name.example', ''),
        ],
        books: [],
        groups: [],
      );

      expect(record.sourceCount, 1);
      expect(await space.store.allSources(), hasLength(1));
      expect(
        record.losses,
        contains(
          const StoreMessage(StoreMessageCode.backupInvalidSources, <Object?>[
            2,
          ]),
        ),
      );
      expect(await space.store.shelf(), isEmpty);
    });

    test('JSON 文本入口仍是旧的 envelope；书架 UI 导出被点名拒绝（家族 11）', () async {
      final json = File('${fixtures.path}/legacy.json');
      await json.writeAsString(
        '{"bookSources":[{"bookSourceUrl":"x","bookSourceName":"X"}]}',
      );
      final record = await importLegadoBackupFile(space.store, json.path);
      expect(record.sourceCount, 1);
      expect(await space.store.allSources(), hasLength(1));

      final uiExport = File('${fixtures.path}/books.json');
      await uiExport.writeAsString(
        jsonEncode([
          {'name': '书', 'author': '人', 'intro': '简介'},
        ]),
      );
      await expectLater(
        importLegadoBackupFile(space.store, uiExport.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('UI 导出'),
          ),
        ),
      );
    });

    test('既不是 ZIP 也不是 UTF-8 JSON 的文件给出命名错误', () async {
      final file = File('${fixtures.path}/binary.bin');
      await file.writeAsBytes([0xff, 0xfe, 0x00, 0x01]);
      await expectLater(
        importLegadoBackupFile(space.store, file.path),
        throwsA(
          isA<FormatException>().having(
            (error) => error.message,
            'message',
            contains('既不是 ZIP 备份'),
          ),
        ),
      );
    });
  });
}

/// The store's rows projected to a canonical form: everything the migration
/// promises to carry, and nothing a minted id or a run's own clock decides.
Future<String> canonical(SpaceStore store) async {
  final groups = await store.allGroups();
  final books = await store.shelf();
  final rows = <Map<String, Object?>>[];
  for (final book in books) {
    final memberships = (await store.groupsOf(
      book.id,
    )).map((g) => g.name).toList()..sort();
    final progress = await store.progressOf(book.id);
    rows.add({
      'kind': book.kind,
      'title': book.title,
      'author': book.author,
      'sourceRef': book.sourceRef,
      'sourceBookUrl': book.sourceBookUrl,
      'rootId': book.rootId,
      'relativePath': book.relativePath,
      'format': book.format,
      'needsRelink': book.needsRelink,
      'groups': memberships,
      'progress': progress == null
          ? null
          : [progress.chapterIndex, progress.textOffset, progress.updatedAt],
    });
  }
  rows.sort(
    (a, b) => '${a['title']}/${a['sourceBookUrl']}'.compareTo(
      '${b['title']}/${b['sourceBookUrl']}',
    ),
  );
  return jsonEncode({
    'groups': [
      for (final group in groups) [group.name, group.groupOrder],
    ],
    'books': rows,
  });
}
