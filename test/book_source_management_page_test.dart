import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/source/book_source_management_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/shelf.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

class _PendingShelf extends ShelfService {
  _PendingShelf(super.store);
  final gate = Completer<void>();
  int writes = 0;

  @override
  Future<void> setSourceEnabled(String sourceRef, bool enabled) async {
    writes++;
    await gate.future;
    await super.setSourceEnabled(sourceRef, enabled);
  }
}

void main() {
  late SpaceStore store;
  late ShelfService shelf;
  const first = 'https://alpha.test';
  const second = 'https://beta.test';
  final firstToggle = find.byKey(const ValueKey('book-source-enabled-$first'));
  final secondToggle = find.byKey(
    const ValueKey('book-source-enabled-$second'),
  );

  setUp(() async {
    store = SpaceStore(SpaceDatabase(NativeDatabase.memory()));
    shelf = ShelfService(store);
    await store.putSourceJson({
      'bookSourceUrl': first,
      'bookSourceName': 'Alpha 书源',
      'customOrder': 1,
    });
    await store.putSourceJson({
      'bookSourceUrl': second,
      'bookSourceName': 'Beta 书源',
      'enabled': false,
      'customOrder': 2,
    });
  });
  tearDown(() => store.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    Locale locale = testLocale,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        locale: locale,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff315c72)),
          useMaterial3: true,
          visualDensity: VisualDensity.compact,
        ),
        home: BookSourceManagementPage(service: shelf),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists disabled sources, filters name or URL and clears search', (
    tester,
  ) async {
    await pumpPage(tester);
    expect(tester.widget<SwitchListTile>(firstToggle).value, isTrue);
    expect(tester.widget<SwitchListTile>(secondToggle).value, isFalse);
    final filter = find.byKey(const ValueKey('book-source-filter'));
    await tester.enterText(filter, '  ALPHA  ');
    await tester.pump();
    expect(firstToggle, findsOneWidget);
    expect(secondToggle, findsNothing);
    await tester.enterText(filter, 'beta.test');
    await tester.pump();
    expect(firstToggle, findsNothing);
    expect(secondToggle, findsOneWidget);
    await tester.enterText(filter, 'missing');
    await tester.pump();
    expect(find.text('没有匹配的书源'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('book-source-clear-filter')));
    await tester.pump();
    expect(firstToggle, findsOneWidget);
    expect(secondToggle, findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'toggle persists both authorities and failure keeps the old state for retry',
    (tester) async {
      await pumpPage(tester);
      await store.db.customStatement(
        'CREATE TRIGGER refuse_source_enable BEFORE UPDATE ON sources '
        "BEGIN SELECT RAISE(ABORT, 'refused by test'); END",
      );
      await tester.tap(secondToggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(secondToggle).value, isFalse);
      expect(
        find.byKey(const ValueKey('book-source-error-$second')),
        findsOneWidget,
      );
      expect((await store.sourceByUrl(second))!.enabled, isFalse);
      await store.db.customStatement('DROP TRIGGER refuse_source_enable');
      await tester.tap(secondToggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(secondToggle).value, isTrue);
      expect(
        find.byKey(const ValueKey('book-source-error-$second')),
        findsNothing,
      );
      expect(
        bookSourceJson((await store.sourceByUrl(second))!)['enabled'],
        isTrue,
      );
      await tester.tap(firstToggle);
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(firstToggle).value, isFalse);
      expect(
        bookSourceJson((await store.sourceByUrl(first))!)['enabled'],
        isFalse,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'pending toggle prevents duplicate writes while other rows stay usable',
    (tester) async {
      final pendingShelf = _PendingShelf(store);
      shelf = pendingShelf;
      await pumpPage(tester);
      await tester.tap(firstToggle);
      await tester.pump();
      expect(tester.widget<SwitchListTile>(firstToggle).onChanged, isNull);
      expect(tester.widget<SwitchListTile>(firstToggle).value, isTrue);
      expect(
        find.byKey(const ValueKey('book-source-pending-$first')),
        findsOneWidget,
      );
      expect(tester.widget<SwitchListTile>(secondToggle).onChanged, isNotNull);
      await tester.tap(firstToggle);
      await tester.pump();
      expect(pendingShelf.writes, 1);
      pendingShelf.gate.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(firstToggle).value, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard focus can toggle a source', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(const ValueKey('book-source-filter')));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(firstToggle).value, isFalse);
    expect((await store.sourceByUrl(first))!.enabled, isFalse);
  });

  testWidgets(
    'thousands of sources build only visible rows, including after filtering',
    (tester) async {
      await store.putSourceJsons([
        for (var index = 0; index < 2000; index++)
          {
            'bookSourceUrl': 'https://large-$index.test',
            'bookSourceName': 'Large $index',
            'customOrder': index + 3,
            'enabled': false,
          },
      ]);
      await pumpPage(tester);
      expect(find.byType(SwitchListTile).evaluate().length, lessThan(30));
      await tester.enterText(
        find.byKey(const ValueKey('book-source-filter')),
        'large-1999.test',
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(
          const ValueKey('book-source-enabled-https://large-1999.test'),
        ),
        findsOneWidget,
      );
      expect(find.byType(SwitchListTile), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'empty space and failed load show recovery without exposing failure details',
    (tester) async {
      await store.deleteSource(first);
      await store.deleteSource(second);
      await pumpPage(tester);
      expect(find.byKey(const ValueKey('book-source-empty')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await store.putSource(
        SourcesCompanion.insert(
          bookSourceUrl: first,
          name: 'Invalid raw',
          raw: const Value('{invalid'),
        ),
      );
      await pumpPage(tester);
      expect(find.text('无法读取书源，请重试。'), findsOneWidget);
      expect(find.byKey(const ValueKey('book-source-retry')), findsOneWidget);
      await store.deleteSource(first);
      await store.putSourceJson({
        'bookSourceUrl': first,
        'bookSourceName': 'Recovered',
      });
      await tester.tap(find.byKey(const ValueKey('book-source-retry')));
      await tester.pumpAndSettle();
      expect(firstToggle, findsOneWidget);
      expect(find.text('无法读取书源，请重试。'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final locale in testSupportedLocales) {
    testWidgets('management copy renders in $locale without layout errors', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await pumpPage(tester, locale: locale);
      expect(firstToggle, findsOneWidget);
      expect(secondToggle, findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
