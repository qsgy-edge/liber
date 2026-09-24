import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/js_source_runtime.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/source_host_state.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/host_state.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'native_library.dart';

/// The frozen `Book`/`BookChapter` own variable members (#76):
/// `book.getVariable`/`putVariable`/`variable` and the chapter pair, over the
/// row's own `books.variable`/`chapters.variable` column (`Book.kt:115,137`,
/// `BookChapter.kt:58,72`). Until this slice the family refused by name (#43).
void main() {
  setUpAll(
    () => InProcessSourceScriptRuntime.initialize(
      libraryPath: nativeLibraryPath(),
    ),
  );
  tearDownAll(InProcessSourceScriptRuntime.dispose);

  late SpaceStore store;
  const sourceRef = 'http://a.test';
  const bookUrl = '$sourceRef/book';
  const chapterUrl = '$sourceRef/chapter/1';

  setUp(() {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
  });
  tearDown(() => store.close());

  /// The space's host surface over this store, which is what a pipeline page
  /// hands its analysis (`ShelfService.hostState`).
  SourceHostState hostState() =>
      SourceHostState(persistence: SpaceHostStatePersistence(store));

  /// The text a write stores: the frozen `GSON.toJson(variableMap)` shape,
  /// two-space pretty printing with null-valued entries omitted
  /// (`utils/GsonExtensions.kt:26-41`).
  String variableText(Map<String, String?> map) =>
      JsonEncoder.withIndent('  ').convert({
        for (final entry in map.entries)
          if (entry.value != null) entry.key: entry.value,
      });

  Future<void> seedBook({String? variable}) => store.putBook(
    BooksCompanion.insert(
      id: 'b1',
      title: '书',
      kind: const Value('network'),
      sourceRef: const Value(sourceRef),
      sourceBookUrl: const Value(bookUrl),
      variable: Value(variable),
    ),
  );

  Future<void> seedChapter({String? variable}) => store.putChapters('b1', [
    BookChapter(
      bookId: 'b1',
      chapterKey: chapterUrl,
      name: '第一章',
      url: chapterUrl,
      chapterIndex: 0,
      isVolume: false,
      isVip: false,
      isPay: false,
      variable: variable,
    ),
  ]);

  Future<Object?> run(
    String script, {
    InProcessSourceScriptRuntime? using,
    Map<String, Object?>? chapter,
  }) {
    final runtime =
        using ?? InProcessSourceScriptRuntime(hostState: hostState());
    return runtime.evaluate(
      source: script,
      input: {
        'sourceKey': sourceRef,
        'source': {'bookSourceUrl': sourceRef, 'bookSourceName': '契约源'},
        'book': const {'name': '书', 'bookUrl': bookUrl},
        'chapter': ?chapter,
      },
      timeout: const Duration(seconds: 5),
    );
  }

  test('the book members read and write the row\'s own column', () async {
    await seedBook();
    final runtime = InProcessSourceScriptRuntime(hostState: hostState());
    Future<Object?> on(String script) => run(script, using: runtime);

    expect(await on('book.variable'), null, reason: 'no write yet');
    expect(await on('book.getVariable("missing")'), '');
    expect(await on('book.putVariable("k", "v1")'), true);
    expect(await on('book.getVariable("k")'), 'v1');
    expect(await on('book.variable'), variableText({'k': 'v1'}));
    expect(
      await store.bookVariable(sourceRef, bookUrl),
      variableText({'k': 'v1'}),
      reason: 'the write reaches the space\'s store immediately',
    );

    // An empty value is stored, and reads back as the empty string the frozen
    // `getVariable` answers for every empty value.
    expect(await on('book.putVariable("e", "")'), true);
    expect(await on('book.getVariable("e")'), '');
    expect(
      await store.bookVariable(sourceRef, bookUrl),
      variableText({'k': 'v1', 'e': ''}),
    );

    // `putVariable(key, null)` deletes the key and always answers true
    // (`BaseBook.kt:19-31`).
    expect(await on('book.putVariable("k", null)'), true);
    expect(await on('book.getVariable("k")'), '');
    expect(
      await store.bookVariable(sourceRef, bookUrl),
      variableText({'e': ''}),
    );

    // A delete of a key that was not there leaves the stored text alone: the
    // frozen write-back only runs when its map changed.
    final kept = await store.bookVariable(sourceRef, bookUrl);
    expect(await on('book.putVariable("other", null)'), true);
    expect(await store.bookVariable(sourceRef, bookUrl), kept);

    // The frozen member declares a String, so a script's own value coerces.
    expect(await on('book.putVariable("n", 42)'), true);
    expect(await on('book.getVariable("n")'), '42');

    // A value of 10000 characters or more is where the frozen
    // `RuleDataInterface` moves the key out of the map into
    // `RuleBigDataHelp`'s file store; this column carries it inline instead
    // (recorded divergence #76), and the read sees it back.
    final long = 'x' * 10000;
    expect(await on('book.putVariable("long", "$long")'), true);
    expect(await on('book.getVariable("long")'), long);
    expect(await store.bookVariable(sourceRef, bookUrl), contains('"long"'));
  });

  test('the chapter members read and write the chapter row', () async {
    await seedBook();
    await seedChapter();
    final runtime = InProcessSourceScriptRuntime(hostState: hostState());
    Future<Object?> on(String script) => run(
      script,
      using: runtime,
      chapter: const {'title': '第一章', 'url': chapterUrl},
    );

    expect(await on('chapter.variable'), null);
    expect(await on('chapter.getVariable("missing")'), '');
    expect(await on('chapter.putVariable("c", "v2")'), true);
    expect(await on('chapter.getVariable("c")'), 'v2');
    expect(await on('chapter.variable'), variableText({'c': 'v2'}));
    expect(
      await store.chapterVariable(sourceRef, bookUrl, chapterUrl),
      variableText({'c': 'v2'}),
    );
    expect(await on('chapter.putVariable("c", null)'), true);
    expect(
      await store.chapterVariable(sourceRef, bookUrl, chapterUrl),
      variableText(const <String, String?>{}),
    );
  });

  test('a write is visible to a later analysis through the store', () async {
    await seedBook();
    await run(
      'book.putVariable("token", "T1")',
      using: InProcessSourceScriptRuntime(hostState: hostState()),
    );

    // A fresh state and runtime over the same space: what the next analysis
    // sees, rather than what this process remembers.
    final later = InProcessSourceScriptRuntime(hostState: hostState());
    expect(await run('book.getVariable("token")', using: later), 'T1');
    expect(
      await run('book.variable', using: later),
      variableText({'token': 'T1'}),
    );
  });

  test('a write for a book the space has no row for stays in the process',
      () async {
    // The frozen entity a script holds exists before its row does. Nothing
    // invents a book row here, so the value has no column to reach; it stays
    // readable for this process, which is the recorded divergence (#76).
    final runtime = InProcessSourceScriptRuntime(hostState: hostState());
    expect(await run('book.putVariable("k", "v")', using: runtime), true);
    expect(await run('book.getVariable("k")', using: runtime), 'v');
    expect(await store.bookVariable(sourceRef, bookUrl), null);
  });

  test(
    'a backup-imported Book.variable is readable by a rule',
    () async {
      // The one existing writer of the column (`legado_full_backup.dart`): a
      // `bookshelf.json` entry's own `variable`, which a `ruleBookInfo.init`
      // script then reads.
      const variable =
          '{"doc":"{\\"title\\":\\"来自变量\\",\\"toc\\":\\"/toc\\"}"}';
      await LegadoFullBackupImport(store).importArchive(
        LegadoBackupArchive.decode(
          zipOf({
            'bookSource.json': [
              {
                'bookSourceUrl': sourceRef,
                'bookSourceName': '契约源',
                'bookSourceType': 0,
              },
            ],
            'bookshelf.json': [
              {
                'bookUrl': bookUrl,
                'name': '书',
                'author': '作者',
                'origin': sourceRef,
                'originName': '契约源',
                'type': 8,
                'group': 0,
                'canUpdate': true,
                'order': 0,
                'durChapterIndex': 0,
                'durChapterPos': 0,
                'durChapterTime': 0,
                'variable': variable,
              },
            ],
            'config.xml': '<map></map>',
          }),
        ),
      );
      final row = await store.bookByNaturalKey(sourceRef, bookUrl);
      expect(row?.variable, variable, reason: 'the importer copied the column');

      final pipeline = JsonSourcePipeline(
        {
          'bookSourceUrl': sourceRef,
          'searchUrl': '/search?key={{key}}',
          'ruleSearch': {
            'bookList': r'$.items',
            'name': r'$.name',
            'bookUrl': r'$.url',
          },
          // The rule the one used source that reads a book variable declares
          // (`ruleBookInfo.init`): it parses the variable's document and the
          // stage's remaining rules read that page.
          'ruleBookInfo': {
            'init': '@js:JSON.parse(book.getVariable("doc"))',
            'canReName': '1',
            'name': r'$.title',
            'tocUrl': r'$.toc',
          },
          'ruleToc': {
            'chapterList': r'$.chapters',
            'chapterName': r'$.name',
            'chapterUrl': r'$.url',
          },
          'ruleContent': {'content': r'$.text'},
        },
        _Pages({
          '/search': jsonEncode({
            'items': [
              {'name': '书', 'url': bookUrl},
            ],
          }),
          bookUrl: jsonEncode({'name': '详情'}),
          '/toc': jsonEncode({
            'chapters': [
              {'name': '第一章', 'url': '/chapter/1'},
            ],
          }),
        }),
        hostState: hostState(),
      );

      final hits = await pipeline.search('书');
      final (book, _) = await pipeline.details(hits.single);

      expect(book.title, '来自变量');
    },
  );

  test('a chapter row the shelf wrote is found through the url a script sees',
      () async {
    // #58's shape: a chapter address with an option tail is stored as the bare
    // target in `chapter_key` and as the address text in `url`, and the reader
    // rebuilds the chapter from the row, so the script sees the bare target as
    // `chapter.url` — which is what the members key the row by.
    const address = '$chapterUrl,{"webView":true}';
    await ShelfService(store).add(
      const {'bookSourceUrl': sourceRef, 'bookSourceName': '契约源'},
      HtmlBook(url: Uri.parse(bookUrl), title: '书'),
      [
        SourceChapter.fromAddress(
          '第一章',
          address,
          bookUrl: Uri.parse(bookUrl),
        ),
      ],
    );
    final row =
        (await store.chaptersOf(
          (await store.bookByNaturalKey(sourceRef, bookUrl))!.id,
        )).single;
    expect(row.chapterKey, chapterUrl);
    expect(row.url, address);
    final seen = SourceChapter.fromAddress(
      row.name,
      row.url ?? row.chapterKey,
      bookUrl: Uri.parse(bookUrl),
      chapterKey: row.chapterKey,
    );

    final runtime = InProcessSourceScriptRuntime(hostState: hostState());
    expect(
      await run(
        'chapter.putVariable("c", "v")',
        using: runtime,
        chapter: {'title': row.name, 'url': '${seen.url}'},
      ),
      true,
    );
    expect(
      await store.chapterVariable(sourceRef, bookUrl, chapterUrl),
      variableText({'c': 'v'}),
    );
  });

  test('a TOC rewrite replaces the chapter row and drops its variable',
      () async {
    await seedBook();
    await seedChapter();
    final runtime = InProcessSourceScriptRuntime(hostState: hostState());
    await run(
      'chapter.putVariable("c", "v")',
      using: runtime,
      chapter: const {'title': '第一章', 'url': chapterUrl},
    );
    expect(
      await store.chapterVariable(sourceRef, bookUrl, chapterUrl),
      variableText({'c': 'v'}),
    );

    // The shelf's TOC write replaces the chapter rows with the pipeline's fresh
    // ones (`SpaceStore.putChapters`, the frozen refresh's shape: the frozen
    // `BookChapterList.analyzeChapterList` builds a `BookChapter` with no
    // `variable` and `BookInfoViewModel.loadChapter` deletes the rows before
    // inserting it). The variables go with the row they belonged to.
    await seedChapter();
    expect(
      await store.chapterVariable(sourceRef, bookUrl, chapterUrl),
      null,
      reason: 'the rewritten row carries none',
    );
    // And the next read is the store's: the replaced row's variable is empty,
    // not the value this process wrote before the rewrite.
    expect(
      await run(
        'chapter.getVariable("c")',
        using: runtime,
        chapter: const {'title': '第一章', 'url': chapterUrl},
      ),
      '',
    );
  });
}

/// The source transport a JSON pipeline reads: the page the path names.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);

  final Map<String, String> pages;

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final page = pages[Uri.parse(path).path] ?? pages[path];
    if (page == null) throw StateError('Unexpected URL: $path');
    return page;
  }
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
