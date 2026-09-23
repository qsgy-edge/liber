import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/http_source_transport.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/source/precise_search.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/workspace.dart';

/// The driven run's seed for #40: one scratch installation whose shelf holds a
/// book, and a local fixture site whose three Book Sources search for it — two
/// of them returning something other than the exact name-and-author match, and
/// one returning it.
///
/// The run this serves is `README.md` → Verification and evidence → Driving the
/// UI; the sequence and what to read back are in the review note beside this
/// ticket's handoff (the controller drives, not this lane).
///
/// ```
/// # 1. seed a scratch installation (no server needed)
/// dart run tool/precise_search_seed.dart --seed C:/scratch/liber-40
///
/// # 2. check the fixture against the real rule adapter, headless
/// dart run tool/precise_search_seed.dart --check
///
/// # 3. serve the fixture site, printing the three sources to a directory
/// dart run tool/precise_search_seed.dart --serve --out C:/scratch/liber-40-sources
///
/// # (or just write the source files: --emit C:/scratch/liber-40-sources)
///
/// # 4. drive the app against the scratch installation
/// flutter run -d windows --target tool/driver_main.dart \
///   --dart-define=LIBER_WORKSPACE_ROOT=C:/scratch/liber-40
///
/// # 5. stop the server when the run is done (Ctrl-C in its console)
/// ```
///
/// `--check` is this lane's own reproduction of the flow the controller drives:
/// it runs the three sources through the product's real pipelines, takes the
/// exact hit, reads its table of contents, switches a scratch book onto it and
/// prints the rows it read back. It needs the native library (the same one the
/// app loads; `--library <path>` overrides the search for it).
///
/// The port is fixed, because the seeded source rows carry URLs that name it and
/// the invocations have to agree; a busy port is refused by name instead of
/// moved.
Future<void> main(List<String> args) async {
  final out = _argument(args, '--out');
  if (args.contains('--serve')) {
    await _serve(out);
    return;
  }
  if (args.contains('--check')) {
    await _check(_argument(args, '--library'));
    return;
  }
  final emit = _argument(args, '--emit');
  if (emit != null) {
    await _emitSources(Directory(emit));
    return;
  }
  final seedIndex = args.indexOf('--seed');
  if (seedIndex >= 0 && seedIndex + 1 < args.length) {
    await _seed(Directory(args[seedIndex + 1]));
    return;
  }
  throw ArgumentError(
    'Usage: --seed <workspace directory> | --serve [--out <directory>] | '
    '--emit <directory> | --check [--library <fjs library>]',
  );
}

String? _argument(List<String> args, String name) {
  final index = args.indexOf(name);
  if (index < 0 || index + 1 >= args.length) return null;
  return args[index + 1];
}

/// The fixture site's origin. Every seeded source resolves inside it.
const seedPort = 18840;
const seedOrigin = 'http://127.0.0.1:$seedPort';

/// The book the scratch shelf holds: the name and author every source is
/// searched for.
const seedBookTitle = '凡人修仙传';
const seedBookAuthor = '忘语';

/// The source the scratch book came from. Its own search answers a *different*
/// author, so it is only ever a near candidate.
const currentSourceRef = '$seedOrigin/current';

/// The source whose search answers the exact name and author: the one the run
/// picks.
const exactSourceRef = '$seedOrigin/exact';

/// The source whose search answers a name equal and an author that contains the
/// searched one without equalling it.
const nearSourceRef = '$seedOrigin/near';

/// The three Book Sources, as the scratch installation stores them and as the
/// fixture site serves them.
///
/// Each is a complete source over the fixture's own HTML: `ruleSearch` over
/// `.result li`, the detail page's `ruleBookInfo`, and `ruleToc` over
/// `.chapters li a`. Nothing here is a new source-rule semantic — the four
/// stages are the product's own — and no compatibility row is claimed from it.
List<Map<String, dynamic>> seedSources() => [
  _source(exactSourceRef, '回放精确源'),
  _source(nearSourceRef, '回放近似源'),
  _source(currentSourceRef, '回放当前源'),
  _pagedSource(),
];

/// The fixture's fourth source, added by the batch-13 controller for the driven
/// reviews of #27 (a chapter body to convert) and #66 (a page-chained TOC whose
/// `nextTocUrl` matches two items at once and carries a `##` field, which the
/// frozen list read applies **per item**). Its book is a different one, so the
/// #40 candidate flow's four rows are unchanged.
const pagedSourceRef = '$seedOrigin/pages';

Map<String, dynamic> _pagedSource() => <String, dynamic>{
  ..._source(pagedSourceRef, '回放分页源'),
  'ruleToc': {
    'chapterList': '.chapters li a',
    'chapterName': 'text',
    'chapterUrl': 'href',
    // Two matches, and an anchored replacement that prefixes each: page 3 is
    // only reachable when the `##` field runs on every item (ticket #66).
    'nextTocUrl': '.pages a@href##^##/pages/book/1/toc/',
  },
};

Map<String, dynamic> _source(String sourceRef, String name) {
  final slug = sourceRef.substring(seedOrigin.length + 1);
  return <String, dynamic>{
    'bookSourceName': name,
    'bookSourceUrl': sourceRef,
    'bookSourceGroup': 'Liber #40 seed',
    'bookSourceComment':
        'Local fixture site on 127.0.0.1:$seedPort for ticket #40; never a live site.',
    'bookSourceType': 0,
    'enabled': true,
    'searchUrl': '/$slug/search?keyword={{key}}&page={{page}}',
    'ruleSearch': {
      'bookList': '.result li',
      'name': 'a.0@text',
      'author': 'span.author@text',
      'bookUrl': 'a.0@href',
    },
    'ruleBookInfo': {
      'name': 'h1@text',
      'author': '.info span.author@text',
      'intro': '.intro@text',
      'lastChapter': '.info span.last@text',
      'coverUrl': 'img.cover@src',
      'tocUrl': '.toc a@href',
    },
    'ruleToc': {
      'chapterList': '.chapters li a',
      'chapterName': 'text',
      'chapterUrl': 'href',
    },
    'ruleContent': {'content': '.content@textNodes'},
  };
}

/// The chapters the seeded book has under [currentSourceRef]: the five the
/// reader was in, with the third one where the run's reading position sits.
const currentChapterNames = <String>[
  '第一章 离家',
  '第二章 拜师',
  '第三章 初入宗门',
  '第四章 试炼',
  '第五章 结丹',
];

/// The position the run moves onto another source: the third chapter, 42
/// characters in.
const seedChapterIndex = 2;
const seedTextOffset = 42;

/// The chapters the exact source's page carries.
///
/// It is deliberately not the same list: a `楔子` is prepended and the middle
/// chapters are reordered, so the old ordinal (2) points at another chapter and
/// only the frozen name-and-number mapping can find `第三章 初入宗门` — at index 3
/// here. A run that reads `progress.chapter_key` back sees which one the reader
/// landed on.
const exactChapterNames = <String>[
  '楔子',
  '第四章 试炼',
  '第五章 结丹',
  '第三章 初入宗门',
  '第一章 离家',
  '第二章 拜师',
];

const _nearChapterNames = <String>['第一章', '第二章', '第三章'];

/// The exact source's search page carries three same-name items: a near one
/// *before* the exact one, and one *after* it that the early stop must keep out
/// of the reader's list altogether.
const _exactSearchItems = <(String, String)>[
  ('凡人修仙传', '别人的笔名'),
  ('凡人修仙传', '忘语'),
  ('凡人修仙传', '这本书不该出现在候选里'),
];

const _nearSearchItems = <(String, String)>[('凡人修仙传', '忘语著')];

const _currentSearchItems = <(String, String)>[('凡人修仙传', '其他作者')];

/// The chapters the paged fixture source reaches over its three TOC pages.
const _pagedChapterNames = <String>[
  '第一章 分页一',
  '第二章 分页一',
  '第三章 分页二',
  '第四章 分页二',
  '第五章 分页三',
];

List<String> _chapterNames(String slug) => switch (slug) {
  'exact' => exactChapterNames,
  'near' => _nearChapterNames,
  'pages' => _pagedChapterNames,
  _ => currentChapterNames,
};

List<(String, String)> _searchItems(String slug) => switch (slug) {
  'exact' => _exactSearchItems,
  'near' => _nearSearchItems,
  'pages' => _pagedSearchItems,
  _ => _currentSearchItems,
};

/// The paged source's own book: never the shelf's, so the #40 flow's candidate
/// list is exactly the four rows it was.
const _pagedSearchItems = <(String, String)>[('分页测试书', '测试作者')];

String _searchPage(String slug) {
  final items = [
    for (final (name, author) in _searchItems(slug))
      '<li><a href="book/1">$name</a><span class="author">$author</span></li>',
  ].join('\n');
  return '<html><body><ul class="result">\n$items\n</ul></body></html>';
}

String _detailPage(String slug) {
  final chapters = _chapterNames(slug);
  return '''
<html><body>
<h1>$seedBookTitle</h1>
<img class="cover" src="/$slug/cover.png">
<div class="info"><span class="author">$seedBookAuthor</span>'
<span class="last">${chapters.last}</span></div>
<p class="intro">本地回放站点，用于 #40 的自动换源驱动运行。</p>
<div class="toc"><a href="/$slug/book/1/toc">目录</a></div>
</body></html>
''';
}

String _tocPage(String slug) {
  if (slug == 'pages') return _pagedTocPage(1);
  final items = [
    for (var i = 0; i < _chapterNames(slug).length; i++)
      '<li><a href="/$slug/book/1/chapter/$i">${_chapterNames(slug)[i]}</a></li>',
  ].join('\n');
  return '<html><body><ul class="chapters">\n$items\n</ul></body></html>';
}

/// One TOC page of the paged source. Page 1 declares the next two pages as a
/// list of relative addresses; only pages 1 and 2 carry a `.pages` block, so the
/// walk stops after page 3.
String _pagedTocPage(int page) {
  final indexes = switch (page) {
    1 => const <int>[0, 1],
    2 => const <int>[2, 3],
    _ => const <int>[4],
  };
  final items = [
    for (final index in indexes)
      '<li><a href="/pages/book/1/chapter/$index">'
          '${_pagedChapterNames[index]}</a></li>',
  ].join('\n');
  final more = page == 1
      ? '<div class="pages"><a href="2">下一批</a><a href="3">再下一批</a></div>'
      : '';
  return '<html><body><ul class="chapters">\n$items\n</ul>$more</body></html>';
}

/// One chapter's body. The text is Simplified on purpose: the conversion
/// setting is what a driven run watches it change to Traditional with.
String _chapterPage(String slug, int index) {
  final name = _chapterNames(slug)[index];
  return '<html><body><div class="content">$name 的正文。他说这门功法很难练，'
      '练成之后就能御剑飞行，飞剑会随着心念变化。故事继续：他从山下走来，'
      '看见远处有一条大河，河水很冷，鱼也很多。</div></body></html>';
}

/// The one response for one path, or null when the fixture declares none.
String? _pageFor(Uri uri) {
  final segments = uri.pathSegments;
  if (segments.isEmpty) return null;
  final slug = segments.first;
  if (!const ['exact', 'near', 'current', 'pages'].contains(slug)) {
    return null;
  }
  if (segments.length == 2 && segments[1] == 'search') {
    return _searchPage(slug);
  }
  if (segments.length == 3 && segments[1] == 'book' && segments[2] == '1') {
    return _detailPage(slug);
  }
  if (segments.length == 4 &&
      segments[1] == 'book' &&
      segments[2] == '1' &&
      segments[3] == 'toc') {
    return _tocPage(slug);
  }
  if (segments.length == 5 &&
      segments[1] == 'book' &&
      segments[2] == '1' &&
      segments[3] == 'toc') {
    final page = int.tryParse(segments[4]);
    return page == null ? null : _pagedTocPage(page);
  }
  if (segments.length == 5 &&
      segments[1] == 'book' &&
      segments[2] == '1' &&
      segments[3] == 'chapter') {
    final index = int.tryParse(segments[4]);
    if (index == null || index < 0 || index >= _chapterNames(slug).length) {
      return null;
    }
    return _chapterPage(slug, index);
  }
  return null;
}

/// Writes one JSON file per fixture source, so the sources that are seeded and
/// served can be read and re-imported by hand.
Future<void> _emitSources(Directory directory) async {
  await directory.create(recursive: true);
  final written = <String>[];
  for (final source in seedSources()) {
    final slug = '${source['bookSourceUrl']}'.substring(seedOrigin.length + 1);
    final file = File('${directory.path}/$slug.source.json');
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(source)}\n',
    );
    written.add(file.path);
  }
  stdout.writeln(
    jsonEncode({'emitted': true, 'origin': seedOrigin, 'files': written}),
  );
}

/// Serves the fixture site until the process is stopped, and writes the three
/// sources to [out] when a directory was given.
Future<void> _serve(String? out) async {
  final site = await FixtureSite.start();
  if (out != null && out.isNotEmpty) {
    await _emitSources(Directory(out));
  }
  stdout.writeln(
    jsonEncode({
      'ready': true,
      'origin': site.origin,
      'sources': [for (final source in seedSources()) source['bookSourceUrl']],
      'sourceFiles': out,
    }),
  );
  // The listening socket keeps the process alive; a driven run stops it.
  await Completer<void>().future;
}

/// The fixture site itself, over the local socket.
class FixtureSite {
  FixtureSite._(this._server);

  static Future<FixtureSite> start() async {
    final HttpServer server;
    try {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, seedPort);
    } on SocketException catch (error) {
      throw StateError(
        'the fixture origin $seedOrigin is busy: ${error.message}. The seeded '
        'source rows name this port, so stop whatever holds it instead of '
        'moving the port (or re-seed the installation for another port).',
      );
    }
    final site = FixtureSite._(server);
    server.listen(site._handle);
    return site;
  }

  final HttpServer _server;

  /// Every request the site answered, in order.
  final requests = <String>[];

  String get origin => seedOrigin;

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final page = request.method == 'GET' ? _pageFor(request.uri) : null;
    requests.add('${request.method} ${request.uri}');
    if (page == null) {
      request.response.statusCode = HttpStatus.notFound;
      request.response.write('undeclared fixture request');
    } else {
      request.response.headers.contentType = ContentType.html;
      request.response.write(page);
    }
    await request.response.close();
  }
}

/// Runs the flow the driven run performs, headless: the three sources' searches
/// through the product's own pipelines, the exact hit, its table of contents,
/// and a scratch book switched onto it — with the rows read back from the store
/// afterwards.
///
/// This is the lane's own reproduction (the controller's driven run is the
/// ticket's acceptance); it leaves the scratch installation under the system
/// temp directory in place only for as long as it runs.
Future<void> _check(String? libraryPath) async {
  await NativeLibrary.initialize(libraryPath: libraryPath ?? _nativeLibrary());
  final site = await FixtureSite.start();
  final directory = await Directory.systemTemp.createTemp('liber-40-check-');
  final report = <String, Object?>{'origin': site.origin};
  try {
    final workspace = await Workspace.open(root: directory);
    final store = await workspace.openSpace(Workspace.defaultSpaceId);
    final shelf = ShelfService(store, androidId: await workspace.androidId());
    try {
      for (final source in seedSources()) {
        await store.putSourceJson(source);
      }
      // The search the entry runs: every source in turn, through the real
      // pipeline over a real HTTP request to the fixture.
      final search = PreciseSearch(
        name: seedBookTitle,
        author: seedBookAuthor,
        openPipeline: (source) => openBookSourcePipeline(
          source,
          HttpSourceTransport(),
          hostState: shelf.hostState,
        ),
      );
      final imported = [
        for (final source in seedSources())
          ImportedBookSource(id: '${source['bookSourceUrl']}', data: source),
      ];
      final outcomes = await search.searchAll(imported);
      report['outcomes'] = [
        for (final outcome in outcomes)
          {
            'source': outcome.sourceRef,
            'failure': outcome.failure,
            'hits': [
              for (final hit in outcome.hits)
                {
                  'title': hit.book.title,
                  'author': hit.book.author,
                  'exact': hit.exact,
                  'url': '${hit.book.url}',
                },
            ],
          },
      ];
      final exact = outcomes
          .expand((outcome) => outcome.hits)
          .where((hit) => hit.exact)
          .firstOrNull;
      if (exact == null) {
        report['error'] = '没有精确命中，fixture 或搜索语义有误';
        return;
      }
      report['picked'] = {
        'source': exact.sourceRef,
        'title': exact.book.title,
        'author': exact.book.author,
      };

      // What the switch reads: the candidate's own detail page and table of
      // contents, through the same pipeline the page uses.
      final pipeline = openBookSourcePipeline(
        exact.source,
        HttpSourceTransport(),
        hostState: shelf.hostState,
      );
      final (details, chapters) = await pipeline.details(exact.book);
      pipeline.cancel();
      report['candidateChapters'] = [
        for (final chapter in chapters) chapter.name,
      ];

      // A scratch shelf with the seeded book and the seeded position, then the
      // switch itself.
      final book = HtmlBook(
        url: Uri.parse('$currentSourceRef/book/1'),
        title: seedBookTitle,
        author: seedBookAuthor,
      );
      await shelf.add(
        seedSources().firstWhere(
          (source) => source['bookSourceUrl'] == currentSourceRef,
        ),
        book,
        [
          for (var i = 0; i < currentChapterNames.length; i++)
            SourceChapter(
              currentChapterNames[i],
              Uri.parse('$currentSourceRef/book/1/chapter/$i'),
            ),
        ],
      );
      final before = (await shelf.find(
        currentSourceRef,
        '$currentSourceRef/book/1',
      ))!;
      await shelf.saveProgress(
        before.id,
        chapterKey: '$currentSourceRef/book/1/chapter/$seedChapterIndex',
        chapterIndex: seedChapterIndex,
        textOffset: seedTextOffset,
      );
      final positioned = (await shelf.find(
        currentSourceRef,
        '$currentSourceRef/book/1',
      ))!;
      final switched = await shelf.switchSource(
        before.id,
        exact.source,
        details,
        chapters,
      );
      report['switchedFrom'] = {
        'bookId': positioned.id,
        'sourceRef': positioned.sourceRef,
        'chapterKey': positioned.chapterKey,
        'chapterName': positioned.chapterName,
        'textOffset': positioned.textOffset,
      };
      report['switchedTo'] = {
        'bookId': switched.id,
        'sourceRef': switched.sourceRef,
        'sourceBookUrl': switched.book.sourceBookUrl,
        'chapterKey': switched.chapterKey,
        'chapterName': switched.chapterName,
        'textOffset': switched.textOffset,
        'shelfRows': (await shelf.onlineShelf()).length,
      };
      report['requests'] = site.requests;
    } finally {
      await shelf.close();
    }
  } finally {
    await site.stop();
    await directory.delete(recursive: true);
  }
  stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
}

/// The native library the app would load, when `--library` is not given.
String _nativeLibrary() {
  final stem = Platform.isWindows
      ? 'fjs.dll'
      : Platform.isMacOS
      ? 'libfjs.dylib'
      : 'libfjs.so';
  final bundle = Platform.isWindows
      ? 'build/windows/x64/runner/Debug'
      : Platform.isLinux
      ? 'build/linux/x64/debug/bundle/lib'
      : 'build/macos/Build/Products/Debug';
  final candidates = [
    '$bundle/$stem',
    'packages/fjs/libfjs/target/debug/$stem',
  ];
  for (final candidate in candidates) {
    if (File(candidate).existsSync()) return candidate;
  }
  throw StateError('未找到原生库，请传 --library <path>；查找过：$candidates');
}

/// Writes a scratch installation: the three sources, the book they describe and
/// the reading position the switch has to carry.
Future<void> _seed(Directory root) async {
  final workspace = await Workspace.open(root: root);
  final store = await workspace.openSpace(Workspace.defaultSpaceId);
  final shelf = ShelfService(store, androidId: await workspace.androidId());
  try {
    for (final source in seedSources()) {
      await store.putSourceJson(source);
    }
    final book = HtmlBook(
      url: Uri.parse('$currentSourceRef/book/1'),
      title: seedBookTitle,
      author: seedBookAuthor,
      intro: '本地回放站点，用于 #40 的自动换源驱动运行。',
      lastChapter: currentChapterNames.last,
    );
    await shelf.add(
      seedSources().firstWhere(
        (source) => source['bookSourceUrl'] == currentSourceRef,
      ),
      book,
      [
        for (var i = 0; i < currentChapterNames.length; i++)
          SourceChapter(
            currentChapterNames[i],
            Uri.parse('$currentSourceRef/book/1/chapter/$i'),
          ),
      ],
    );
    final entry = (await shelf.find(
      currentSourceRef,
      '$currentSourceRef/book/1',
    ))!;
    await shelf.saveProgress(
      entry.id,
      chapterKey: '$currentSourceRef/book/1/chapter/$seedChapterIndex',
      chapterIndex: seedChapterIndex,
      textOffset: seedTextOffset,
    );
    final seeded = (await shelf.find(
      currentSourceRef,
      '$currentSourceRef/book/1',
    ))!;
    stdout.writeln(
      jsonEncode({
        'seeded': true,
        'store': workspace.databaseFile(store.spaceId).path,
        'bookId': seeded.id,
        'sourceRef': seeded.sourceRef,
        'title': seeded.title,
        'chapterKey': seeded.chapterKey,
        'chapterName': seeded.chapterName,
        'textOffset': seeded.textOffset,
        'sources': [
          for (final source in seedSources()) source['bookSourceUrl'],
        ],
      }),
    );
  } finally {
    await shelf.close();
  }
}
