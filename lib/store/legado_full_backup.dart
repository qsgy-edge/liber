import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:pointycastle/export.dart';

import '../domain/contracts.dart';
import 'database.dart';
import 'ids.dart';
import 'space_store.dart';

/// The members of a Legado full backup this importer reads, in the order it
/// reads them: the sources and the groups are in the space before the books that
/// refer to them.
///
/// The names are the frozen baseline's own (`Backup.kt:47`, `backupFileNames`;
/// `Backup.kt:120`, what each holds), and a member is absent whenever the entity
/// list behind it was empty — which is why "absent" is a normal backup, not a
/// broken one.
const List<String> legadoBackupEntityMembers = <String>[
  'bookSource.json',
  'bookGroup.json',
  'bookshelf.json',
];

/// The Android preferences the baseline writes beside them.
const String legadoBackupConfigMember = 'config.xml';

/// Everything a full backup may carry (`Backup.kt:47`), so a member this build
/// does not read is named in the report instead of disappearing quietly.
const List<String> legadoBackupKnownMembers = <String>[
  'bookshelf.json',
  'bookmark.json',
  'bookGroup.json',
  'bookSource.json',
  'rssSources.json',
  'rssStar.json',
  'replaceRule.json',
  'readRecord.json',
  'searchHistory.json',
  'sourceSub.json',
  'txtTocRule.json',
  'httpTTS.json',
  'keyboardAssists.json',
  'dictRule.json',
  'servers.json',
  'directLinkUploadRule.json',
  'readConfig.json',
  'shareReadConfig.json',
  'themeConfig.json',
  'config.xml',
];

/// A Legado full backup, read as an archive.
///
/// The specification is `docs/compatibility/legado-data-migration-contract.md`
/// ("Full Backup and Restore", the normative rules, "Required Fixtures and
/// Tests"); [LegadoFullBackupImport] owns what each member means, and this class
/// owns the container and the two things an archive may not do — both checked
/// before a single member's bytes reach the importer:
///
/// - an entry whose name would escape the archive root (a path-traversal entry),
/// - an entry whose declared size is beyond anything a backup holds.
///
/// Nothing is ever written to disk. The guard is enforced here, at the boundary,
/// rather than left to a reader that happens not to extract: the archive is
/// user-supplied and untrusted (ADR 0011).
class LegadoBackupArchive {
  LegadoBackupArchive._(this._members, this.names, this.preferenceCount);

  /// A member's declared uncompressed size beyond this is refused instead of
  /// decoded: the operator's own backup needs 41 MB for its largest member, and
  /// a declared size this far above that is a decompression bomb, not a backup.
  static const int maxMemberBytes = 512 * 1024 * 1024;

  /// Whether [bytes] start with a ZIP signature: the local-file header, an empty
  /// archive's end-of-central-directory record, or a spanned marker. This is
  /// what tells the two accepted containers apart when the picker hands over a
  /// file.
  static bool looksLikeZip(Uint8List bytes) {
    if (bytes.length < 4 || bytes[0] != 0x50 || bytes[1] != 0x4b) return false;
    final marker = bytes[2];
    return marker == 0x03 || marker == 0x05 || marker == 0x07;
  }

  /// Reads and validates [bytes].
  ///
  /// Throws [FormatException] with a named reason when an entry would escape the
  /// archive root, when an entry declares an impossible size, when the archive
  /// cannot be decoded, or when it holds none of the members a Legado backup is
  /// made of.
  factory LegadoBackupArchive.decode(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes, verify: true);
    } catch (error) {
      throw FormatException('备份 ZIP 无法解析：$error');
    }
    final names = <String>[];
    for (final file in archive.files) {
      final name = file.name;
      if (!_isSafeMemberName(name)) {
        throw FormatException('备份包含越界条目（路径穿越），已拒绝导入：$name');
      }
      if (file.size > maxMemberBytes) {
        throw FormatException('备份条目过大，已拒绝导入：$name（${file.size} 字节）');
      }
      names.add(_normalize(name));
    }
    if (!names.any(legadoBackupEntityMembers.contains) &&
        !names.contains(legadoBackupConfigMember)) {
      throw FormatException(
        '这个 ZIP 里没有 Legado 备份的根成员'
        '（${legadoBackupEntityMembers.join(' / ')} / $legadoBackupConfigMember）',
      );
    }
    final members = <String, Uint8List>{};
    for (final member in <String>[
      ...legadoBackupEntityMembers,
      legadoBackupConfigMember,
    ]) {
      for (final file in archive.files) {
        if (_normalize(file.name) != member) continue;
        members[member] = file.readBytes() ?? Uint8List(0);
        break;
      }
    }
    return LegadoBackupArchive._(
      members,
      List.unmodifiable(names),
      _preferenceCount(members[legadoBackupConfigMember]),
    );
  }

  final Map<String, Uint8List> _members;

  /// Every entry name the archive held, normalized to forward slashes.
  final List<String> names;

  /// How many preferences `config.xml` carries. The file is counted, never
  /// imported: those settings are the Android app's, not this product's.
  final int preferenceCount;

  bool has(String member) => _members.containsKey(member);

  Uint8List? member(String member) => _members[member];

  /// The entity members the backup does not carry: the baseline omits an entity
  /// file whose list was empty.
  List<String> get absentMembers => <String>[
    for (final member in legadoBackupEntityMembers)
      if (!has(member)) member,
  ];

  /// The known members the backup carries that this build does not read.
  List<String> get unreadMembers => <String>[
    for (final name in names)
      if (legadoBackupKnownMembers.contains(name) &&
          !legadoBackupEntityMembers.contains(name) &&
          name != legadoBackupConfigMember)
        name,
  ];

  static String _normalize(String name) => name.replaceAll('\\', '/');

  /// A name that cannot leave the archive root: no leading slash, no drive
  /// letter, and no `..` segment. Names are compared as forward slashes, because
  /// an archive produced on Windows may spell them with backslashes.
  static bool _isSafeMemberName(String name) {
    if (name.isEmpty) return false;
    final normalized = _normalize(name);
    if (normalized.startsWith('/')) return false;
    if (RegExp(r'^[A-Za-z]:').hasMatch(normalized)) return false;
    return !normalized.split('/').contains('..');
  }

  static int _preferenceCount(Uint8List? config) {
    if (config == null || config.isEmpty) return 0;
    final text = utf8.decode(config, allowMalformed: true);
    return RegExp('name="').allMatches(text).length;
  }
}

/// Imports a real Legado full backup into one space.
///
/// This is the adapter `docs/compatibility/legado-data-migration-contract.md`
/// specifies. The retired hand-made JSON envelope is
/// `LegadoBackupImport.importJson`'s, in `legacy_import.dart`, and the two do not
/// share an identity model: that shape carries no source reference, no group
/// mask and no local-book key to implement these rules against.
///
/// The rules, in the contract's own words:
///
/// - **rule 3** — a network book matches on `(sourceRef, sourceBookUrl)`, its id
///   is minted, and `(name, author)` is never merged silently: two books with the
///   same name and author but different URLs stay two books.
/// - **rule 4** — a local book never carries the Android path or URI into the
///   space. The original URL becomes a `sha256:` correlation key, kept as the
///   book's synthetic root, with the file name it ended in beside it; the row is
///   marked `needsRelink`, because the backup holds no book bytes.
/// - **rule 5** — a book's `group` mask resolves against `bookGroup.json` for
///   every bit, the 64th (`Long.MIN_VALUE`) included; Legado's synthetic negative
///   group ids are shelf views, not groups, and are not persisted.
/// - **rule 6** — the reading position survives as `chapter_index` and
///   `text_offset`, with the position's own millisecond time as `updatedAt`. The
///   chapter table is not in a backup, so there is no chapter key to write.
/// - **rule 7** — the import is idempotent, membership unions, imported metadata
///   fills blanks instead of erasing newer edits, and progress only advances
///   (through [SpaceStore.saveProgress], the same forward-only merge a reader's
///   own write goes through).
/// - **rules 8 and 9** — nothing imported is executed, and the families a backup
///   cannot carry are named in the report rather than implied to survive.
class LegadoFullBackupImport {
  LegadoFullBackupImport(this.store);

  final SpaceStore store;

  /// Merges [archive] into the space in one transaction, so a refusal or a
  /// failure leaves the space exactly as it was.
  Future<MigrationImportRecord> importArchive(
    LegadoBackupArchive archive,
  ) async {
    final losses = <String>[];
    final totals = _Totals();
    // The shelf is small and its shape decides whether this is a backup at all,
    // so it is decoded before the transaction opens. The sources — 41 MB in the
    // operator's own backup — are decoded and released inside it.
    final books = archive.has('bookshelf.json')
        ? _entityArray(archive.member('bookshelf.json')!, 'bookshelf.json')
        : const <Map<String, dynamic>>[];
    final lossy = lossyBooksJsonReason(books);
    if (lossy != null) throw FormatException(lossy);
    await store.db.transaction(() async {
      final sourceNames = await _importSources(archive, totals, losses);
      final groupIds = await _importGroups(archive, totals, losses);
      await _importBooks(books, sourceNames, groupIds, totals, losses);
    });
    losses.addAll(_excludedFamilies(archive, totals));
    return MigrationImportRecord(
      sourceCount: totals.sources,
      bookCount: totals.books,
      progressCount: totals.progress,
      losses: losses,
    );
  }

  /// Stores the backup's sources and returns `bookSourceUrl -> name` for the
  /// books that refer to them.
  ///
  /// A source that already exists with different content is left alone and
  /// counted: rule 7 requires explicit approval before a replacement, and an
  /// import has no user in front of it to give one. What the space already holds
  /// is read once, not once per source — the operator's own backup carries
  /// 8 787 of them.
  Future<Map<String, String>> _importSources(
    LegadoBackupArchive archive,
    _Totals totals,
    List<String> losses,
  ) async {
    final names = <String, String>{};
    final bytes = archive.member('bookSource.json');
    if (bytes == null) {
      losses.add('备份没有 bookSource.json：没有书源导入');
      return names;
    }
    final existing = <String, BookSource>{
      for (final source in await store.allSources())
        source.bookSourceUrl: source,
    };
    final incoming = <Map<String, dynamic>>[];
    for (final source in _entityArray(bytes, 'bookSource.json')) {
      final url = _string(source['bookSourceUrl']);
      final name = _string(source['bookSourceName']);
      // Rule 2: v1 requires both, where the frozen UI parser required the URL
      // only.
      if (url.isEmpty || name.isEmpty) {
        totals.invalidSources++;
        continue;
      }
      if (_legacyInt(source['bookSourceType']) != 0) totals.nonTextSources++;
      final stored = existing[url];
      if (stored == null) {
        incoming.add(source);
        totals.sources++;
      } else if (stored.raw != jsonEncode(source)) {
        totals.conflictingSources++;
      }
      names[url] = stored?.name ?? name;
    }
    await store.putSourceJsons(incoming);
    return names;
  }

  /// Stores the backup's groups and returns `legado groupId -> space group id`.
  ///
  /// The map is keyed by the frozen row's own `groupId`, because rule 5 selects
  /// with it. Only a selectable id is persisted: a positive id, which is a bit,
  /// and `Long.MIN_VALUE`, the 64th. Legado's synthetic negative ids
  /// (`BookGroup.IdAll`, `IdLocal`, `IdAudio`, `IdNetNone`, `IdLocalNone`,
  /// `IdError`) are views a shelf computes from `type` and the mask, not groups
  /// a user made.
  Future<Map<int, String>> _importGroups(
    LegadoBackupArchive archive,
    _Totals totals,
    List<String> losses,
  ) async {
    final groupIds = <int, String>{};
    final bytes = archive.member('bookGroup.json');
    if (bytes == null) {
      losses.add('备份没有 bookGroup.json：分组不导入');
      return groupIds;
    }
    for (final group in _entityArray(bytes, 'bookGroup.json')) {
      final legadoId = _legacyInt(group['groupId']);
      final name = _string(group['groupName']).trim();
      if (name.isEmpty) {
        totals.invalidGroups++;
        continue;
      }
      if (!_isSelectableGroupId(legadoId)) {
        totals.systemGroups++;
        continue;
      }
      final stored = await store.putGroup(
        GroupsCompanion(
          id: Value(mintId('group')),
          name: Value(name),
          cover: Value(_httpUrl(group['cover'])),
          groupOrder: Value(_legacyInt(group['order'])),
          enableRefresh: Value(group['enableRefresh'] as bool? ?? true),
          show: Value(group['show'] as bool? ?? true),
          bookSort: Value(_legacyInt(group['bookSort'], fallback: -1)),
        ),
      );
      groupIds[legadoId] = stored.id;
      totals.groups++;
    }
    return groupIds;
  }

  /// Merges the shelf: one row per book, its groups unioned, its position
  /// written forward-only.
  Future<void> _importBooks(
    List<Map<String, dynamic>> books,
    Map<String, String> sourceNames,
    Map<int, String> groupIds,
    _Totals totals,
    List<String> losses,
  ) async {
    final seen = <String>{};
    for (final book in books) {
      final bookUrl = _string(book['bookUrl']);
      if (bookUrl.isEmpty) {
        totals.invalidBooks++;
        continue;
      }
      final local = _isLocalBook(book, bookUrl);
      final correlationKey = 'sha256:${_sha256(utf8.encode(bookUrl))}';
      final fileName = local ? _localFileName(book, bookUrl) : null;
      final sourceRef = local ? '' : _string(book['origin']);
      final existing = local
          ? await store.localBook(correlationKey, fileName!)
          : await store.bookByNaturalKey(sourceRef, bookUrl);
      final id = existing?.id ?? mintId('book');
      final naturalKey = local
          ? '$correlationKey\u0000$fileName'
          : '$sourceRef\u0000$bookUrl';
      if (!seen.add(naturalKey) && !local) totals.duplicateBooks++;
      await store.putBook(
        BooksCompanion(
          id: Value(id),
          kind: Value(local ? 'local' : 'network'),
          sourceRef: Value(sourceRef.isEmpty ? null : sourceRef),
          sourceBookUrl: Value(local ? null : bookUrl),
          title: Value(
            _fill(
              _string(book['name'], fallback: local ? fileName! : bookUrl),
              existing?.title,
            ),
          ),
          author: Value(_fill(_string(book['author']), existing?.author)),
          originName: Value(
            _fill(
              _string(
                book['originName'],
                fallback: sourceNames[sourceRef] ?? sourceRef,
              ),
              existing?.originName,
            ),
          ),
          type: Value(_legacyInt(book['type'])),
          customTag: Value(
            _fill(_string(book['customTag']), existing?.customTag),
          ),
          coverUrl: Value(
            _fill(_httpUrl(book['coverUrl'], totals: totals), existing?.coverUrl),
          ),
          customCoverUrl: Value(
            _fill(
              _httpUrl(book['customCoverUrl'], totals: totals),
              existing?.customCoverUrl,
            ),
          ),
          intro: Value(_fill(_string(book['intro']), existing?.intro)),
          customIntro: Value(
            _fill(_string(book['customIntro']), existing?.customIntro),
          ),
          charset: Value(_fill(_string(book['charset']), existing?.charset)),
          latestChapterTitle: Value(
            _fill(
              _string(book['latestChapterTitle']),
              existing?.latestChapterTitle,
            ),
          ),
          latestChapterTime: Value(_legacyInt(book['latestChapterTime'])),
          totalChapterNum: Value(_legacyInt(book['totalChapterNum'])),
          canUpdate: Value(book['canUpdate'] as bool? ?? true),
          lastCheckTime: Value(_legacyInt(book['lastCheckTime'])),
          lastCheckCount: Value(_legacyInt(book['lastCheckCount'])),
          // The frozen shelf's own order, verbatim: it is a ranking, and a shelf
          // re-imported into a minted order is not the shelf the user had. A book
          // the space already placed keeps its place.
          bookOrder: Value(
            existing != null && existing.bookOrder != 0
                ? existing.bookOrder
                : _legacyInt(book['order']),
          ),
          variable: Value(_variable(book['variable']) ?? existing?.variable),
          // Rule 7: membership unions, so a re-import never takes a book off the
          // shelf.
          shelved: const Value(true),
          // Rule 4: the correlation key stands where the Android path was, and
          // the original file name is the relative path inside that synthetic
          // root.
          rootId: Value(local ? correlationKey : null),
          relativePath: Value(fileName),
          format: Value(local ? _fileFormat(fileName!) : existing?.format),
          // A relink the user already did stays done; a book that is new to the
          // space has no file to read.
          needsRelink: Value(
            local ? (existing?.needsRelink ?? true) : false,
          ),
          raw: Value(
            jsonEncode(
              local ? _localRaw(book, correlationKey, fileName!) : book,
            ),
          ),
        ),
      );
      totals.books++;
      if (local) totals.localBooks++;
      await _writeProgress(id, book, totals);
      await _writeMembership(id, book, groupIds, totals);
    }
  }

  /// The book's reading position, through the store's forward-only merge.
  ///
  /// A book the frozen shelf never opened carries no position and gets no row:
  /// `SpaceStore.latestProgress` answers "continue reading", and a row of zeros
  /// would answer with a book nobody has read.
  Future<void> _writeProgress(
    String bookId,
    Map<String, dynamic> book,
    _Totals totals,
  ) async {
    final chapterIndex = _legacyInt(book['durChapterIndex']);
    final textOffset = _legacyInt(book['durChapterPos']);
    final updatedAt = _legacyInt(book['durChapterTime']);
    if (chapterIndex <= 0 && textOffset <= 0 && updatedAt <= 0) {
      totals.unreadBooks++;
      return;
    }
    final advanced = await store.saveProgress(
      ProgressCompanion.insert(
        bookId: bookId,
        textOffset: Value(textOffset),
        chapterIndex: Value(chapterIndex),
        updatedAt: Value(updatedAt),
      ),
    );
    if (advanced) totals.progress++;
  }

  /// The book's groups, unioned with what the space already had.
  Future<void> _writeMembership(
    String bookId,
    Map<String, dynamic> book,
    Map<int, String> groupIds,
    _Totals totals,
  ) async {
    final mask = _legacyInt(book['group']);
    if (mask == 0) return;
    final ids = <String>{
      for (final group in await store.groupsOf(bookId)) group.id,
    };
    var matched = 0;
    for (final entry in groupIds.entries) {
      if ((entry.key & mask) != 0) {
        ids.add(entry.value);
        matched++;
      }
    }
    if (matched == 0) {
      totals.unmatchedMasks++;
      return;
    }
    await store.setBookGroups(bookId, ids);
  }

  /// The families the backup cannot carry, named one by one (rule 9 and this
  /// ticket's acceptance): a report that says "some data was not imported"
  /// leaves the user unable to tell what.
  List<String> _excludedFamilies(LegadoBackupArchive archive, _Totals totals) {
    final lines = <String>[
      'Cookie：备份里没有 Cookie 表，登录状态不导入',
      '缓存：备份里没有 Cache 表，书源缓存不导入',
      '章节：备份里没有 BookChapter 表，目录与章节变量不导入',
      '下载内容：备份里没有已下载正文，需要重新抓取',
      '本地书籍字节：备份里没有书文件，已标记需要重新链接',
      'Android 设置：config.xml 的 ${archive.preferenceCount} 项偏好属于 Android 端，不导入',
    ];
    for (final member in archive.absentMembers) {
      lines.add('备份没有 $member：对应的数据为空');
    }
    final unread = archive.unreadMembers;
    if (unread.isNotEmpty) {
      lines.add('备份里还有 ${unread.length} 个成员没有导入：${unread.join('、')}');
    }
    if (totals.invalidSources > 0) {
      lines.add('${totals.invalidSources} 条书源缺少 URL 或名字，已跳过');
    }
    if (totals.invalidGroups > 0) {
      lines.add('${totals.invalidGroups} 个分组没有名字，已跳过');
    }
    if (totals.invalidBooks > 0) {
      lines.add('${totals.invalidBooks} 条书架记录没有 bookUrl，已跳过');
    }
    if (totals.conflictingSources > 0) {
      lines.add(
        '${totals.conflictingSources} 个书源在空间中已存在且内容不同，未替换（替换需要确认）',
      );
    }
    if (totals.duplicateBooks > 0) {
      lines.add('${totals.duplicateBooks} 条书架记录的 bookUrl 重复，合并为一条');
    }
    if (totals.systemGroups > 0) {
      lines.add('${totals.systemGroups} 个系统分组（全部/本地/音频等视图）不导入：它们由书籍类型推导');
    }
    if (totals.unmatchedMasks > 0) {
      lines.add('${totals.unmatchedMasks} 本书的分组位在 bookGroup.json 里没有对应分组');
    }
    if (totals.unreadBooks > 0) {
      lines.add('${totals.unreadBooks} 本书在备份里没有阅读进度（从未打开），未写进度行');
    }
    if (totals.nonTextSources > 0) {
      lines.add('${totals.nonTextSources} 个非文本书源已导入，v1 不执行（ADR 0012）');
    }
    if (totals.droppedCovers > 0) {
      lines.add('${totals.droppedCovers} 个封面指向本地路径，未导入（本地字节不迁移）');
    }
    lines.add('阅读进度的章节名没有等价字段，进度只保留章节序号与字符位置');
    return lines;
  }
}

/// Detects Legado's bookshelf **UI export** (`books.json`).
///
/// It writes `name`, `author` and `intro` only and reads them back by searching
/// every enabled source again (`BookshelfViewModel.kt:102`), so it carries no
/// book URL, no source, no groups and no position: it is lossy by construction
/// and never a migration package. Returns the refusal reason, or null when the
/// entries are not that shape.
String? lossyBooksJsonReason(Iterable<Object?> entries) {
  final rows = entries.whereType<Map>().toList();
  if (rows.isEmpty) return null;
  final carriesUrl = rows.any((row) {
    final url = row['bookUrl'];
    return url is String && url.isNotEmpty;
  });
  if (carriesUrl) return null;
  final looksLikeExport = rows.any(
    (row) =>
        row.containsKey('name') ||
        row.containsKey('author') ||
        row.containsKey('intro'),
  );
  if (!looksLikeExport) return null;
  return '这是 Legado 书架的 UI 导出（books.json，只有书名/作者/简介），不是完整备份；'
      '请在 Legado 里用「备份」导出 ZIP 再导入';
}

/// Whether a book is local: the frozen `BookType.local` bit (`BookType.kt:38`,
/// 256), or a URL scheme that can only be a device path. The operator's own
/// backup carries both spellings — a `content://` document URI in 26 rows and a
/// bare `/storage/...` path in 9.
bool isLocalBookType(int type) => (type & 256) != 0;

bool _isLocalBook(Map<String, dynamic> book, String bookUrl) =>
    isLocalBookType(_legacyInt(book['type'])) ||
    bookUrl.startsWith('content://') ||
    bookUrl.startsWith('file://');

/// The name the local file ended in.
///
/// Precedence: the last segment of the percent-decoded URL when that segment
/// names a file — a `content://.../document/primary%3ABook%2F<名>.txt` URI spells
/// it at the end — then `originName`, which the frozen shelf filled with the same
/// file name, then the book's title. Only the name survives: rule 4 forbids
/// keeping the path itself.
String _localFileName(Map<String, dynamic> book, String bookUrl) {
  final decoded = _percentDecode(bookUrl);
  final tail = decoded.split('/').last.trim();
  if (_namesAFile(decoded, tail)) return tail;
  final originName = _string(book['originName']).trim();
  if (originName.isNotEmpty) return originName;
  return _string(book['name'], fallback: '未命名文件');
}

/// Percent-decodes a URL without the URI parser.
///
/// A local book's URL is user data: it may hold raw non-ASCII characters
/// (`/storage/…/《书名》.txt`) that `Uri.decodeFull` refuses, and it may hold a
/// malformed escape. Neither may fail the import.
String _percentDecode(String text) {
  if (!text.contains('%')) return text;
  final bytes = <int>[];
  for (var index = 0; index < text.length; index++) {
    final char = text.codeUnitAt(index);
    if (char == 0x25 && index + 2 < text.length) {
      final value = int.tryParse(
        text.substring(index + 1, index + 3),
        radix: 16,
      );
      if (value != null) {
        bytes.add(value);
        index += 2;
        continue;
      }
    }
    bytes.addAll(utf8.encode(text[index]));
  }
  return utf8.decode(bytes, allowMalformed: true);
}

/// Whether a URL's last segment names a file rather than a folder: a `document/`
/// URI always does, and so does a segment with a dot in it. A tree-only URI
/// (`...tree/primary`) names a volume.
bool _namesAFile(String url, String tail) {
  if (tail.isEmpty) return false;
  return url.contains('/document/') || tail.contains('.');
}

/// The local book's `raw`: the imported object with the Android path and URI
/// replaced by the correlation key rule 4 asks for. Unknown fields survive; the
/// path-bearing ones do not.
Map<String, dynamic> _localRaw(
  Map<String, dynamic> book,
  String correlationKey,
  String fileName,
) {
  final clean = Map<String, dynamic>.from(book);
  clean['bookUrl'] = correlationKey;
  clean['legacyKey'] = correlationKey;
  clean['localFileName'] = fileName;
  for (final key in const ['coverUrl', 'customCoverUrl', 'tocUrl']) {
    final value = clean[key];
    if (value is String && _looksLikeLocalPath(value)) clean.remove(key);
  }
  return clean;
}

bool _looksLikeLocalPath(String value) {
  if (value.isEmpty) return false;
  return value.startsWith('/') ||
      value.startsWith('content://') ||
      value.startsWith('file://') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
}

String _fileFormat(String fileName) {
  final dot = fileName.lastIndexOf('.');
  if (dot < 0 || dot + 1 >= fileName.length) return 'txt';
  final extension = fileName.substring(dot + 1).toLowerCase();
  return extension.isEmpty ? 'txt' : extension;
}

/// A cover this product can show: only an http(s) URL survives. A local path is
/// a file the backup does not carry (rule 9), and the count of dropped ones is
/// reported.
String _httpUrl(Object? value, {_Totals? totals}) {
  final text = _string(value).trim();
  if (text.startsWith('http://') || text.startsWith('https://')) return text;
  if (text.isNotEmpty && totals != null) totals.droppedCovers++;
  return '';
}

/// Whether a `bookGroup.json` row is a group a book can select through its mask.
///
/// The frozen selection is `groupId > 0 and (groupId & mask) > 0`
/// (`BookGroupDao.kt:70`), and the contract adds the 64th bit, `Long.MIN_VALUE`,
/// which that query leaves out.
bool _isSelectableGroupId(int id) => id > 0 || id == _longMinValue;

/// `Long.MIN_VALUE`, the 64th custom group bit. `1 << 63` has that bit pattern.
const int _longMinValue = 1 << 63;

/// Rule 7's metadata merge: what the space already holds wins, what it lacks is
/// filled from the backup.
String _fill(String incoming, String? current) =>
    current != null && current.isNotEmpty ? current : incoming;

/// A Legado numeric field read as an int: the frozen JSON is typed
/// inconsistently, and a value beyond int64 arrives as a double.
int _legacyInt(Object? value, {int fallback = 0}) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse('${value ?? ''}') ?? fallback;
}

String _string(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final text = '$value';
  return text.isEmpty ? fallback : text;
}

/// Legado's `Book.variable` is a string; anything else is kept as it arrived
/// rather than stringified into something a round trip cannot restore.
String? _variable(Object? value) {
  if (value == null) return null;
  return value is String ? value : jsonEncode(value);
}

String _sha256(List<int> bytes) {
  final digest = SHA256Digest();
  final value = digest.process(Uint8List.fromList(bytes));
  return value.map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
}

/// One member, decoded as the entity array the frozen baseline wrote
/// (`Backup.kt:120`).
///
/// An entry that is not a JSON object is dropped rather than trusted; the member
/// itself has to be an array.
List<Map<String, dynamic>> _entityArray(Uint8List bytes, String member) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
  } on FormatException catch (error) {
    throw FormatException('$member 不是 JSON：${error.message}');
  }
  if (decoded is! List) throw FormatException('$member 不是 JSON 数组');
  return <Map<String, dynamic>>[
    for (final entry in decoded)
      if (entry is Map) Map<String, dynamic>.from(entry),
  ];
}

class _Totals {
  int sources = 0;
  int books = 0;
  int progress = 0;
  int groups = 0;
  int localBooks = 0;
  int nonTextSources = 0;
  int conflictingSources = 0;
  int invalidSources = 0;
  int invalidGroups = 0;
  int invalidBooks = 0;
  int duplicateBooks = 0;
  int systemGroups = 0;
  int unmatchedMasks = 0;
  int unreadBooks = 0;
  int droppedCovers = 0;
}
