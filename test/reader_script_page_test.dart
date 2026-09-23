import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/settings/reader_script.dart';
import 'package:liber/settings/reader_script_page.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';

import 'l10n_support.dart';

/// The conversion screen (#27): the five manual choices plus the default, the
/// installation's row and the open book's override, and what the two together
/// resolve to.
void main() {
  late SpaceStore store;

  setUp(() => store = SpaceStore(SpaceDatabase(NativeDatabase.memory())));
  tearDown(() => store.close());

  Future<void> pumpPage(
    WidgetTester tester, {
    String bookId = '',
    String? bookTitle,
  }) async {
    await tester.pumpWidget(
      localizedApp(
        home: ReaderScriptPage(
          store: store,
          bookId: bookId,
          bookTitle: bookTitle,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Taps a choice; the screen scrolls, so a row below the fold is brought into
  /// the viewport before the tap.
  Future<void> tapChoice(WidgetTester tester, String key) async {
    await tester.scrollUntilVisible(find.byKey(ValueKey(key)), 200);
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('安装设置写全局行，本书覆盖写本书行', (tester) async {
    await pumpPage(tester, bookId: 'book-1', bookTitle: '测试书');
    expect(find.text('本书覆盖：测试书'), findsOneWidget);

    await tapChoice(tester, 'reader-script-global-traditional_taiwan');
    expect(await store.setting(ReaderScriptSetting.key), 'traditional_taiwan');

    await tapChoice(tester, 'reader-script-book-traditional_hongkong');
    expect(
      await store.setting(ReaderScriptSetting.key, bookId: 'book-1'),
      'traditional_hongkong',
    );
    expect(
      await store.setting(ReaderScriptSetting.key),
      'traditional_taiwan',
      reason: '改本书的覆盖不能动安装的选择',
    );
    // The effective line reports the override, not the installation's choice.
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reader-script-effective')),
      -200,
    );
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('reader-script-effective')))
          .data,
      '当前生效：繁體（香港）',
    );
  });

  testWidgets('没有打开书时只有安装设置', (tester) async {
    await pumpPage(tester);
    expect(find.text('安装设置'), findsOneWidget);
    expect(find.textContaining('本书覆盖'), findsNothing);
    for (final choice in ReaderScriptSetting.manualChoices) {
      await tester.scrollUntilVisible(
        find.byKey(ValueKey('reader-script-global-${choice.slug}')),
        200,
      );
      expect(
        find.byKey(ValueKey('reader-script-global-${choice.slug}')),
        findsOneWidget,
      );
    }
    expect(
      find.byKey(const ValueKey('reader-script-global-follow_locale')),
      findsOneWidget,
    );
  });

  testWidgets('已存的两种行读回来就是选中的那一项', (tester) async {
    await ReaderScriptSetting.putGlobal(
      store,
      ReaderScriptChoice.traditionalGeneric,
    );
    await ReaderScriptSetting.putBook(store, 'book-1', ReaderScriptChoice.none);
    await pumpPage(tester, bookId: 'book-1', bookTitle: '测试书');

    // The book's row wins, so the line reports it rather than 繁體（通用）.
    expect(find.text('当前生效：不转换'), findsOneWidget);
    final global = tester
        .widgetList<RadioGroup<ReaderScriptChoice>>(
          find.byType(RadioGroup<ReaderScriptChoice>),
        )
        .first;
    expect(global.groupValue, ReaderScriptChoice.traditionalGeneric);

    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('reader-script-book-none')),
      200,
    );
    final book = tester.widget<RadioGroup<ReaderScriptChoice>>(
      find.ancestor(
        of: find.byKey(const ValueKey('reader-script-book-none')),
        matching: find.byType(RadioGroup<ReaderScriptChoice>),
      ),
    );
    expect(book.groupValue, ReaderScriptChoice.none);
  });
}
