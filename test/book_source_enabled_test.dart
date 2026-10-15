import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/html_source_pipeline.dart';
import 'package:liber/source/json_source_pipeline.dart' show SourceChapter;
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';

import 'space_test_support.dart';

void main() {
  late TestSpace space;
  late ShelfService shelf;
  const url = 'https://managed.test';

  setUp(() async {
    space = await TestSpace.create();
    shelf = ShelfService(space.store);
  });
  tearDown(() => space.delete());

  test(
    'enabled write keeps raw and typed flags consistent across reopen',
    () async {
      final raw = <String, dynamic>{
        'bookSourceUrl': url,
        'bookSourceName': 'Managed',
        'enabled': true,
        'unknown': {
          'list': [1, 'kept'],
        },
        'ruleSearch': {'bookList': '.book'},
      };
      final before = await space.store.putSource(
        SourcesCompanion.insert(
          bookSourceUrl: url,
          name: 'Typed name',
          groupNames: const Value('["typed group"]'),
          type: const Value(2),
          customOrder: const Value(19),
          enabledExplore: const Value(false),
          lastUpdateTime: const Value(123),
          raw: Value(jsonEncode(raw)),
        ),
      );
      await space.store.putSetting('searchGroup', 'typed group');
      await shelf.hostState.putEntry(url, 'key', 'host value');
      await shelf.setSourceEnabled(url, false);
      var after = (await space.store.sourceByUrl(url))!;
      expect(after.enabled, isFalse);
      expect(bookSourceJson(after), {...raw, 'enabled': false});
      expect(
        after.copyWith(enabled: before.enabled, raw: Value(before.raw)),
        before,
      );
      expect(await space.store.setting('searchGroup'), 'typed group');
      expect(await shelf.hostState.entry(url, 'key'), 'host value');

      shelf = ShelfService(await space.reopen());
      after = (await space.store.sourceByUrl(url))!;
      expect(after.enabled, isFalse);
      expect((await shelf.sources()).single.data['enabled'], isFalse);
      await shelf.setSourceEnabled(url, true);
      shelf = ShelfService(await space.reopen());
      after = (await space.store.sourceByUrl(url))!;
      expect(after, before);
      expect((await shelf.sources()).single.data['enabled'], isTrue);
      expect(await shelf.hostState.entry(url, 'key'), 'host value');
    },
  );

  test('enabled write uses typed fallback without inventing raw', () async {
    final before = await space.store.putSource(
      SourcesCompanion.insert(
        bookSourceUrl: url,
        name: 'No raw',
        groupNames: const Value('["group"]'),
        customOrder: const Value(7),
        enabledExplore: const Value(false),
      ),
    );
    await shelf.setSourceEnabled(url, false);
    final after = (await space.store.sourceByUrl(url))!;
    expect(after.raw, isNull);
    expect(after.copyWith(enabled: true), before);
    expect(bookSourceJson(after)['enabled'], isFalse);
    shelf = ShelfService(await space.reopen());
    expect((await shelf.sources()).single.data['enabled'], isFalse);
    await shelf.setSourceEnabled(url, true);
    expect(await space.store.sourceByUrl(url), before);
  });

  test(
    'enabled write repairs disagreement without reimporting typed fields',
    () async {
      await space.store.putSource(
        SourcesCompanion.insert(
          bookSourceUrl: url,
          name: 'Typed',
          enabled: const Value(false),
          raw: const Value('{"enabled":true,"unknown":42}'),
        ),
      );
      expect((await shelf.sources()).single.data['enabled'], isTrue);
      await shelf.setSourceEnabled(url, false);
      final row = (await space.store.sourceByUrl(url))!;
      expect(row.enabled, isFalse);
      expect(bookSourceJson(row), {'enabled': false, 'unknown': 42});
      expect(row.name, 'Typed');
      expect(row.bookSourceUrl, url);
    },
  );

  test(
    'disabling keeps existing shelf resolution, chapters and progress',
    () async {
      final source = {
        'bookSourceUrl': url,
        'bookSourceName': 'Managed',
        'enabled': true,
      };
      await space.store.putSourceJson(source);
      await shelf.add(
        source,
        HtmlBook(url: Uri.parse('$url/book'), title: 'Kept book'),
        [SourceChapter('Chapter', Uri.parse('$url/chapter'))],
      );
      final entry = (await shelf.onlineShelf()).single;
      await shelf.saveProgress(
        entry.id,
        chapterKey: '$url/chapter',
        chapterIndex: 0,
        textOffset: 42,
      );
      final before = (await shelf.onlineShelf()).single;
      await shelf.setSourceEnabled(url, false);
      shelf = ShelfService(await space.reopen());
      final after = (await shelf.onlineShelf()).single;
      expect(after.book, before.book);
      expect(after.chapters, before.chapters);
      expect(after.progress, before.progress);
      expect(after.sourceMissing, isFalse);
      expect(after.sourceJson['enabled'], isFalse);
    },
  );

  test(
    'database refusal leaves both flags and unrelated state unchanged',
    () async {
      final row = await space.store.putSourceJson({
        'bookSourceUrl': url,
        'bookSourceName': 'Managed',
        'enabled': true,
        'unknown': 42,
      });
      await space.store.db.customStatement(
        'CREATE TRIGGER refuse_source_enable BEFORE UPDATE ON sources '
        "BEGIN SELECT RAISE(ABORT, 'refused by test'); END",
      );
      await expectLater(shelf.setSourceEnabled(url, false), throwsA(anything));
      expect(await space.store.sourceByUrl(url), row);
      await space.store.db.customStatement('DROP TRIGGER refuse_source_enable');
      await shelf.setSourceEnabled(url, false);
      final updated = (await space.store.sourceByUrl(url))!;
      expect(updated.enabled, isFalse);
      expect(bookSourceJson(updated)['enabled'], isFalse);
    },
  );

  test(
    'non-object raw keeps the existing typed fallback and raw bytes',
    () async {
      final row = await space.store.putSource(
        SourcesCompanion.insert(
          bookSourceUrl: url,
          name: 'Fallback',
          raw: const Value('["preserved"]'),
        ),
      );
      await shelf.setSourceEnabled(url, false);
      final updated = (await space.store.sourceByUrl(url))!;
      expect(updated.copyWith(enabled: true), row);
      expect(bookSourceJson(updated)['enabled'], isFalse);
    },
  );

  test(
    'failed enabled write does not create a source or partly change it',
    () async {
      await expectLater(shelf.setSourceEnabled(url, false), throwsStateError);
      expect(await space.store.allSources(), isEmpty);
      final row = await space.store.putSource(
        SourcesCompanion.insert(
          bookSourceUrl: url,
          name: 'Invalid raw',
          raw: const Value('{invalid'),
        ),
      );
      await expectLater(
        shelf.setSourceEnabled(url, false),
        throwsFormatException,
      );
      expect(await space.store.sourceByUrl(url), row);
    },
  );
}
