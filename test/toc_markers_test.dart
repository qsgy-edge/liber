import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/domain/contracts.dart';
import 'package:liber/source/book_source_pipeline.dart';
import 'package:liber/source/book_source_service.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/source/native_library.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'native_library.dart';

/// One scripted site, keyed by path. Every request is recorded, so a test can
/// prove that a volume chapter never asks for one.
class _Pages implements BookSourceTransport {
  _Pages(this.pages);
  final Map<String, String> pages;
  final requests = <Uri>[];

  @override
  Future<String> request({
    required BookSourceStage stage,
    required String path,
  }) async {
    final url = Uri.parse(path);
    requests.add(url);
    final page = pages[url.path];
    if (page == null) throw StateError('unexpected request: $path');
    return page;
  }
}

const _base = 'http://example.test';
final _bookUrl = Uri.parse('$_base/book/1');
final _tocUrl = Uri.parse('$_base/toc/1');

Map<String, dynamic> _htmlSource() => {
  'bookSourceUrl': _base,
  'ruleBookInfo': {'name': 'h1@text', 'tocUrl': '#dir@a@href'},
  'ruleToc': {
    'chapterList': '#list@li',
    'chapterName': 'a@text',
    'chapterUrl': 'a@href',
    'updateTime': 'em@text',
    'isVolume': 'class.vol@text',
    'isVip': 'class.vip@text',
    'isPay': 'class.pay@text',
  },
  'ruleContent': {'content': '#con@text'},
};

Map<String, dynamic> _jsonSource() => {
  'bookSourceUrl': _base,
  'ruleBookInfo': {'name': r'$.title', 'tocUrl': r'$.toc'},
  'ruleToc': {
    'chapterList': r'$.list',
    'chapterName': r'$.label',
    'chapterUrl': r'$.href',
    'updateTime': r'$.time',
    'isVolume': r'$.volume',
    'isVip': r'$.vip',
    'isPay': r'$.pay',
  },
  'ruleContent': {'content': r'$.body'},
};

/// The fictional site's pages: a book page, one TOC page and two chapters.
_Pages _site() => _Pages({
  '/book/1': '<h1>书</h1><h2 id="dir"><a href="/toc/1">目录</a></h2>',
  '/toc/1':
      '<div id="list">'
      '<li class="vol"><a>第一卷</a><em>卷首</em></li>'
      '<li class="vip"><a href="/c/1">第一章</a><em>2026-01-01</em></li>'
      '<li><a href="">第二章</a></li>'
      '<li><a></a></li>'
      '</div>',
  '/c/1': '<div id="con">正文一</div>',
  '/v/1': '<div id="con">卷正文</div>',
});

/// The same site behind a JSON source's rules.
_Pages _jsonSite() => _Pages({
  '/book/1': jsonEncode({'title': '书', 'toc': '/toc/1'}),
  '/toc/1': jsonEncode({
    'list': [
      {'label': '第一卷', 'volume': true, 'time': '卷首'},
      {
        'label': '第一章',
        'href': '/c/1',
        'time': '2026-01-01',
        'vip': '1',
        'pay': 'false',
      },
      {'label': '第二章'},
      {'label': '', 'href': '/c/9'},
    ],
  }),
  '/c/1': jsonEncode({'body': '正文一'}),
});

HtmlBook _hit() => HtmlBook(url: _bookUrl, title: '');

void main() {
  setUpAll(() => NativeLibrary.initialize(libraryPath: nativeLibraryPath()));
  tearDownAll(NativeLibrary.dispose);

  group('the frozen String.isTrue (StringExtensions.kt:74-79)', () {
    test('is false only for the frozen false set', () {
      for (final value in ['true', 'TRUE', '1', '是', 'yes', 'x']) {
        expect(sourceIsTrue(value), isTrue, reason: value);
      }
      for (final value in ['false', 'FALSE', 'no', 'not', '0', 'No', 'NOT']) {
        expect(sourceIsTrue(value), isFalse, reason: value);
      }
    });

    test('is false for null, blank and the literal null', () {
      // Kotlin's `isNullOrBlank()`: every code unit of a blank value is
      // `Char.isWhitespace()`, which counts the non-breaking and the ideographic
      // spaces too.
      for (final value in [
        null,
        '',
        ' ',
        '\t',
        '\n',
        '\u00A0',
        '\u1680',
        '\u2007',
        '\u2028',
        '\u202F',
        '\u205F',
        '\u3000',
      ]) {
        expect(sourceIsTrue(value), isFalse, reason: '$value');
      }
      expect(sourceIsTrue('null'), isFalse);
      // The frozen compares the *untrimmed* value with `null`, so spaces around
      // the literal make it ordinary text rather than the literal `null`.
      expect(sourceIsTrue(' null '), isTrue);
    });

    test('trims the Kotlin whitespace set before the false-set match', () {
      for (final value in [
        ' false ',
        '\tfalse\n',
        '0 ',
        '\u3000false',
        '\u00A0false',
        '\u2007false',
        '\u202Ffalse',
        '\u00A0not',
        '\u3000 0',
      ]) {
        expect(sourceIsTrue(value), isFalse, reason: value);
      }
      // The predicate is Kotlin's `Char.isWhitespace()`, not Dart's `trim()`:
      // the Kotlin set trims the Java controls and leaves U+0085, where Dart's
      // set does the opposite.
      expect(sourceIsTrue('\u001Cfalse'), isFalse);
      expect(sourceIsTrue('\u0085false'), isTrue);
    });
  });

  test('the HTML TOC reads the markers with the frozen fallbacks', () async {
    final transport = _site();
    final pipeline = HtmlSourcePipeline(_htmlSource(), transport);
    final (book, chapters) = await pipeline.details(_hit());

    expect(book.title, '书');
    // The empty-title element is skipped (`BookChapterList.kt:244`), not an
    // error for the whole TOC.
    expect(chapters.map((chapter) => chapter.name), ['第一卷', '第一章', '第二章']);

    // A volume the URL rule matched nothing on: the frozen identity text is the
    // chapter's key and its address, and the TOC page is its (unused) URL.
    final volume = chapters[0];
    expect(volume.isVolume, isTrue);
    expect(volume.tag, '卷首');
    expect(volume.url, _tocUrl);
    expect(volume.storeKey, '第一卷0');
    expect(volume.persistedAddress, '第一卷0');
    expect(volume.rendersTagAsContent, isTrue);

    final first = chapters[1];
    expect(first.url, Uri.parse('$_base/c/1'));
    expect(first.tag, '2026-01-01');
    expect(first.isVolume, isFalse);
    expect(first.isVip, isTrue);
    expect(first.isPay, isFalse);
    expect(first.storeKey, '$_base/c/1');
    expect(first.rendersTagAsContent, isFalse);

    // A chapter the URL rule matched nothing on falls back to the address of the
    // TOC page it was read from (`BookChapterList.kt:237`).
    final second = chapters[2];
    expect(second.url, _tocUrl);
    expect(second.rawAddress, '/toc/1');
    expect(second.isVolume, isFalse);
    expect(second.isVip, isFalse);

    // A volume's content is its `tag`: no request is made for it.
    final requests = transport.requests.length;
    final body = await pipeline.chapter(volume);
    expect(body.text, '卷首');
    expect(body.pages, 0);
    expect(transport.requests, hasLength(requests));

    // A volume the rule *did* give a URL keeps the normal content path.
    final withUrl = await pipeline.chapter(
      SourceChapter(
        '第一卷',
        Uri.parse('$_base/v/1'),
        rawAddress: '/v/1',
        tag: '卷首',
        isVolume: true,
      ),
    );
    expect(withUrl.text, '卷正文');
    expect(transport.requests.last.path, '/v/1');
  });

  test('the JSON TOC reads the markers with the frozen fallbacks', () async {
    final transport = _jsonSite();
    final pipeline = JsonSourcePipeline(_jsonSource(), transport);
    final (book, chapters) = await pipeline.details(_hit());

    expect(book.title, '书');
    expect(chapters.map((chapter) => chapter.name), ['第一卷', '第一章', '第二章']);

    final volume = chapters[0];
    expect(volume.isVolume, isTrue);
    expect(volume.tag, '卷首');
    expect(volume.url, _tocUrl);
    expect(volume.storeKey, '第一卷0');
    expect(volume.persistedAddress, '第一卷0');

    // `"1"` and `"false"` are the frozen `String.isTrue()` answers for the two
    // marker rules.
    final first = chapters[1];
    expect(first.url, Uri.parse('$_base/c/1'));
    expect(first.tag, '2026-01-01');
    expect(first.isVip, isTrue);
    expect(first.isPay, isFalse);

    final second = chapters[2];
    expect(second.url, _tocUrl);
    expect(second.rawAddress, '/toc/1');

    final requests = transport.requests.length;
    final body = await pipeline.chapter(volume);
    expect(body.text, '卷首');
    expect(body.pages, 0);
    expect(transport.requests, hasLength(requests));
  });

  test('the store keeps the four markers across a write and a read', () async {
    final store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    addTearDown(store.close);
    final shelf = ShelfService(store);
    const source = {'bookSourceUrl': _base};
    final book = HtmlBook(url: _bookUrl, title: '书');
    final volume = SourceChapter.volume('第一卷', 0, tocUrl: _tocUrl, tag: '卷首');
    final first = SourceChapter(
      '第一章',
      Uri.parse('$_base/c/1'),
      rawAddress: '/c/1',
      tag: '2026-01-01',
      isVip: true,
    );
    await shelf.add(source, book, [volume, first]);

    final bookId = (await shelf.find(_base, '$_bookUrl'))!.id;
    final rows = await store.chaptersOf(bookId);
    expect(rows.map((row) => row.chapterKey), ['第一卷0', '$_base/c/1']);
    expect(rows.first.name, '第一卷');
    expect(rows.first.url, '第一卷0');
    expect(rows.first.tag, '卷首');
    expect(rows.first.isVolume, isTrue);
    expect(rows.first.isVip, isFalse);
    expect(rows.first.isPay, isFalse);
    expect(rows[1].tag, '2026-01-01');
    expect(rows[1].isVolume, isFalse);
    expect(rows[1].isVip, isTrue);
    expect(rows[1].isPay, isFalse);
  });
}
