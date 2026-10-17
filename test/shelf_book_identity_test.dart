import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/legado_full_backup.dart';
import 'package:liber/store/legacy_import.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'space_test_support.dart';

void main() {
  late TestSpace space;
  late SpaceStore store;
  late ShelfService shelf;
  const sourceUrl = 'https://identity.test';
  const source = {'bookSourceUrl': sourceUrl, 'bookSourceName': 'Identity'};
  const address = '$sourceUrl/book?isSearch=1,{"js":"result"}';
  final encoded = Uri.parse(address).toString();
  final chapters = [SourceChapter('Chapter', Uri.parse('$sourceUrl/chapter'))];
  HtmlBook book(String raw, {String title = 'Book'}) => HtmlBook(
    // Search hits carry the bare request target separately from their address.
    url: Uri.parse(raw.split(',').first),
    rawAddress: raw,
    title: title,
  );

  setUp(() async {
    space = await TestSpace.create();
    store = space.store;
    shelf = ShelfService(store);
  });
  tearDown(() => space.delete());

  test(
    'book identity preserves absolute text and raw tail while resolving relative carriers',
    () async {
      const tail = ''' ,{
  "js": "result"
}''';
      final resolved = Uri.parse('$sourceUrl/book');
      expect(
        HtmlBook(url: resolved, title: 'No carrier').identityAddress,
        '$resolved',
      );
      final relative = HtmlBook(
        url: resolved,
        preOptionUrl: resolved,
        rawAddress: '/book$tail',
        title: 'Relative',
      );
      expect(relative.identityAddress, '$resolved$tail');
      expect(
        HtmlBook(
          url: resolved,
          rawAddress: '/book$tail',
          title: 'No recorded base',
        ).identityAddress,
        '/book$tail',
        reason:
            'An absolute request target does not establish the identity base',
      );
      expect(
        relative.address,
        '/book$tail',
        reason: 'Fetch carrier stays unchanged',
      );
      expect(
        HtmlBook(
          url: resolved,
          preOptionUrl: resolved,
          rawAddress: '/book',
          title: 'No tail',
        ).identityAddress,
        '$resolved',
      );
      const absolute = 'HTTPS://IDENTITY.TEST/book$tail';
      final imported = HtmlBook.fromJson({
        'url': absolute,
        'title': 'Absolute',
      });
      expect(imported.identityAddress, absolute);
      expect(imported.address, absolute);
      expect(
        HtmlBook.fromJson({
          'url': imported.identityAddress,
          'title': 'Round trip',
        }).identityAddress,
        absolute,
      );
      await shelf.add(source, imported);
      final stored = (await shelf.find(sourceUrl, absolute))!;
      await shelf.add(source, stored.htmlBook);
      expect((await store.bookById(stored.id))!.sourceBookUrl, absolute);
      expect(await store.shelf(), hasLength(1));
    },
  );

  for (final raw in [address, '$sourceUrl/plain']) {
    test('search add stores and finds its address: $raw', () async {
      await shelf.add(source, book(raw), chapters);
      final entry = (await shelf.find(sourceUrl, raw))!;
      expect(entry.book.sourceBookUrl, raw);
      await shelf.saveProgress(entry.id, textOffset: 37);
      await shelf.add(source, book(raw, title: 'Re-added'));
      expect((await shelf.find(sourceUrl, raw))!.id, entry.id);
      expect(await store.shelf(), hasLength(1));
      await shelf.updateCatalog(
        sourceUrl,
        book(raw, title: 'Refreshed'),
        chapters,
      );
      final refreshed = (await shelf.find(sourceUrl, raw))!;
      expect(refreshed.title, 'Refreshed');
      expect(refreshed.textOffset, 37);
      store = await space.reopen();
      expect((await ShelfService(store).find(sourceUrl, raw))!.id, entry.id);
    });

    test('paste/reading ensureBook stores its raw address: $raw', () async {
      final pasted = HtmlBook(
        url: Uri.parse(raw),
        rawAddress: raw,
        title: 'Paste',
      );
      final id = await shelf.ensureBook(source, pasted);
      expect((await shelf.find(sourceUrl, raw))!.id, id);
      expect((await store.bookById(id))!.sourceBookUrl, raw);
      expect((await store.bookById(id))!.shelved, isFalse);
      await shelf.add(source, pasted);
      expect((await shelf.find(sourceUrl, raw))!.id, id);
    });

    test(
      'legacy online import keeps address and reuses identity: $raw',
      () async {
        final home = Directory('${space.directory.path}/legacy-input');
        await home.create();
        await File('${home.path}/online_reading.json').writeAsString(
          jsonEncode({
            'version': 2,
            'records': [
              {
                'source': source,
                'book': {'url': raw, 'title': 'Imported'},
                'chapterUrl': '$sourceUrl/chapter',
                'textOffset': 37,
                'shelved': true,
              },
            ],
          }),
        );
        await LegacyImport(home: home).run(store);
        final entry = (await shelf.find(sourceUrl, raw))!;
        expect(entry.book.sourceBookUrl, raw);
        expect(entry.textOffset, 37);
        await LegacyImport(home: home).run(store, force: true);
        expect((await shelf.find(sourceUrl, raw))!.id, entry.id);
        expect(await store.shelf(), hasLength(1));
      },
    );

    test('full backup import keeps the raw address: $raw', () async {
      final archive = Archive();
      final bytes = utf8.encode(
        jsonEncode([
          {'origin': sourceUrl, 'bookUrl': raw, 'name': 'Imported', 'type': 8},
        ]),
      );
      archive.addFile(ArchiveFile('bookshelf.json', bytes.length, bytes));
      final backup = LegadoBackupArchive.decode(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      );
      await LegadoFullBackupImport(store).importArchive(backup);
      final entry = (await shelf.find(sourceUrl, raw))!;
      expect(entry.book.sourceBookUrl, raw);
      await LegadoFullBackupImport(store).importArchive(backup);
      expect((await shelf.find(sourceUrl, raw))!.id, entry.id);
      expect(await store.shelf(), hasLength(1));
    });

    test(
      'switch/relink writes raw identity and preserves progress: $raw',
      () async {
        await shelf.add(source, book('$sourceUrl/original'), chapters);
        final old = (await shelf.find(sourceUrl, '$sourceUrl/original'))!;
        await shelf.saveProgress(old.id, chapterIndex: 0, textOffset: 37);
        await shelf.deleteSource(sourceUrl);
        expect(
          (await shelf.find(sourceUrl, '$sourceUrl/original'))!.sourceMissing,
          isTrue,
        );
        final switched = await shelf.switchSource(
          old.id,
          source,
          book(raw),
          chapters,
        );
        expect(switched.id, old.id);
        expect(switched.book.sourceBookUrl, raw);
        expect(switched.sourceMissing, isFalse);
        expect(switched.textOffset, 37);
        expect((await shelf.find(sourceUrl, raw))!.id, old.id);
      },
    );
  }

  for (final stored in [address, encoded, address.split(',').first]) {
    test('every lookup accepts raw input for stored form: $stored', () async {
      await store.putBook(
        BooksCompanion.insert(
          id: 'existing',
          title: 'Existing',
          sourceRef: const Value(sourceUrl),
          sourceBookUrl: Value(stored),
          variable: const Value('book-before'),
        ),
      );
      await store.putChapters('existing', [
        BookChapter(
          bookId: 'existing',
          chapterKey: '$sourceUrl/chapter',
          name: 'Chapter',
          chapterIndex: 0,
          isVolume: false,
          isVip: false,
          isPay: false,
          variable: 'chapter-before',
        ),
      ]);
      expect((await shelf.find(sourceUrl, address))!.id, 'existing');
      expect(
        (await store.bookByNaturalKey(sourceUrl, address))!.id,
        'existing',
      );
      expect(await store.bookVariable(sourceUrl, address), 'book-before');
      expect(
        await store.putBookVariable(sourceUrl, address, 'book-after'),
        isTrue,
      );
      expect(await store.bookVariable(sourceUrl, address), 'book-after');
      expect(
        await store.chapterVariable(sourceUrl, address, '$sourceUrl/chapter'),
        'chapter-before',
      );
      expect(
        await store.putChapterVariable(
          sourceUrl,
          address,
          '$sourceUrl/chapter',
          'chapter-after',
        ),
        isTrue,
      );
      expect(
        await store.chapterVariable(sourceUrl, address, '$sourceUrl/chapter'),
        'chapter-after',
      );
      await shelf.add(source, book(address));
      expect(await store.shelf(), hasLength(1));
      expect(
        (await store.bookById('existing'))!.sourceBookUrl,
        stored,
        reason: 'Existing rows are not rewritten',
      );
      await shelf.updateCatalog(
        sourceUrl,
        book(address, title: 'Refreshed'),
        chapters,
      );
      expect((await store.bookById('existing'))!.title, 'Refreshed');
      await store.putBook(
        BooksCompanion.insert(
          id: 'orphan',
          title: 'Orphan',
          sourceBookUrl: Value(stored),
        ),
      );
      expect((await store.bookWithoutSource(address))!.id, 'orphan');
    });
  }

  Future<void> importOnline(String incoming) async {
    final home = Directory('${space.directory.path}/legacy-reimport');
    await home.create();
    await File('${home.path}/online_reading.json').writeAsString(
      jsonEncode({
        'version': 2,
        'records': [
          {
            'source': source,
            'book': {'url': incoming, 'title': 'Reimported'},
            'chapterUrl': '$sourceUrl/chapter',
            'textOffset': 52,
            'shelved': true,
          },
        ],
      }),
    );
    await LegacyImport(home: home).run(store, force: true);
  }

  test(
    'historical relative identity remains verbatim through each write path',
    () async {
      const relative = '/book?isSearch=1,{"js":"result"}';
      final historical = HtmlBook.fromJson({
        'url': relative,
        'title': 'Historical',
      });
      expect(historical.identityAddress, relative);
      final id = await shelf.ensureBook(source, historical);
      await shelf.add(source, historical, chapters);
      await shelf.updateCatalog(sourceUrl, historical, chapters);
      await shelf.switchSource(id, source, historical, chapters);
      await importOnline(relative);
      final entry = (await shelf.find(sourceUrl, relative))!;
      expect(entry.id, id);
      expect(entry.book.sourceBookUrl, relative);
      expect(entry.htmlBook.identityAddress, relative);
      expect(await store.shelf(), hasLength(1));
      expect(
        await shelf.find(sourceUrl, address),
        isNull,
        reason: 'No invented base or suffix matching',
      );
    },
  );

  test('raw legacy reimport publishes raw onto its encoded row', () async {
    await store.putBook(
      BooksCompanion.insert(
        id: 'encoded',
        title: 'Existing',
        sourceRef: const Value(sourceUrl),
        sourceBookUrl: Value(encoded),
      ),
    );
    await importOnline(address);
    expect((await shelf.find(sourceUrl, address))!.id, 'encoded');
    expect((await store.bookById('encoded'))!.sourceBookUrl, address);
    expect(await store.shelf(), hasLength(1));
  });

  test('raw full-backup reimport publishes raw onto its encoded row', () async {
    await store.putBook(
      BooksCompanion.insert(
        id: 'encoded',
        title: 'Existing',
        sourceRef: const Value(sourceUrl),
        sourceBookUrl: Value(encoded),
      ),
    );
    final archive = Archive();
    final bytes = utf8.encode(
      jsonEncode([
        {
          'origin': sourceUrl,
          'bookUrl': address,
          'name': 'Imported',
          'type': 8,
        },
      ]),
    );
    archive.addFile(ArchiveFile('bookshelf.json', bytes.length, bytes));
    await LegadoFullBackupImport(store).importArchive(
      LegadoBackupArchive.decode(
        Uint8List.fromList(ZipEncoder().encode(archive)),
      ),
    );
    expect((await shelf.find(sourceUrl, address))!.id, 'encoded');
    expect((await store.bookById('encoded'))!.sourceBookUrl, address);
    expect(await store.shelf(), hasLength(1));
  });

  test(
    'encoded legacy reimport preserves raw row within a source of 256 books',
    () async {
      await shelf.add(source, book(address));
      final original = (await shelf.find(sourceUrl, address))!;
      await store.transaction(() async {
        for (var i = 0; i < 255; i++) {
          await store.putBook(
            BooksCompanion.insert(
              id: 'unrelated-$i',
              title: 'Unrelated',
              sourceRef: const Value(sourceUrl),
              sourceBookUrl: Value('$sourceUrl/unrelated/$i'),
            ),
          );
        }
        await store.putBook(
          BooksCompanion.insert(
            id: 'other-source',
            title: 'Other source',
            sourceRef: const Value('https://other.test'),
            sourceBookUrl: const Value(address),
          ),
        );
      });
      await importOnline(encoded);
      expect((await shelf.find(sourceUrl, address))!.id, original.id);
      final kept = (await store.bookById(original.id))!;
      expect(kept.sourceBookUrl, address);
      expect(kept.title, 'Reimported');
      expect((await store.progressOf(original.id))!.textOffset, 52);
      expect((await store.bookById('other-source'))!.title, 'Other source');
      expect(
        await store.shelf(),
        hasLength(257),
        reason: '256 same-source rows scanned, no duplicate',
      );
      await importOnline(encoded);
      expect(await store.shelf(), hasLength(257));
    },
  );

  test(
    'legacy mirror probe keeps legitimate percent-encoded paths distinct',
    () async {
      await shelf.add(source, book('$sourceUrl/a/b'));
      await importOnline('$sourceUrl/a%2Fb');
      expect(await store.shelf(), hasLength(2));
      expect((await shelf.find(sourceUrl, '$sourceUrl/a/b'))!.title, 'Book');
      expect(
        (await shelf.find(sourceUrl, '$sourceUrl/a%2Fb'))!.title,
        'Reimported',
      );
    },
  );

  test('exact raw match wins when both stored forms exist', () async {
    for (final (id, stored) in [('encoded', encoded), ('raw', address)]) {
      await store.putBook(
        BooksCompanion.insert(
          id: id,
          title: id,
          sourceRef: const Value(sourceUrl),
          sourceBookUrl: Value(stored),
        ),
      );
    }
    expect((await store.bookByNaturalKey(sourceUrl, address))!.id, 'raw');
    await store.putBookVariable(sourceUrl, address, 'raw-only');
    expect((await store.bookById('raw'))!.variable, 'raw-only');
    expect((await store.bookById('encoded'))!.variable, isNull);
  });

  test(
    'switch clash probe finds an encoded legacy row without changing either book',
    () async {
      await shelf.add(source, book('$sourceUrl/original'), chapters);
      final old = (await shelf.find(sourceUrl, '$sourceUrl/original'))!;
      await store.putBook(
        BooksCompanion.insert(
          id: 'encoded',
          title: 'Encoded',
          sourceRef: const Value(sourceUrl),
          sourceBookUrl: Value(encoded),
        ),
      );
      await expectLater(
        shelf.switchSource(old.id, source, book(address), chapters),
        throwsStateError,
      );
      expect(
        (await store.bookById(old.id))!.sourceBookUrl,
        '$sourceUrl/original',
      );
      expect((await store.bookById('encoded'))!.sourceBookUrl, encoded);
    },
  );

  test(
    'legitimate percent-encoded components are not decoded into another identity',
    () async {
      const escaped = '$sourceUrl/a%2Fb';
      await shelf.add(source, book(escaped));
      expect(
        (await shelf.find(sourceUrl, escaped))!.book.sourceBookUrl,
        escaped,
      );
      expect(await shelf.find(sourceUrl, '$sourceUrl/a/b'), isNull);
      expect(await shelf.find('https://other.test', escaped), isNull);
    },
  );
}
