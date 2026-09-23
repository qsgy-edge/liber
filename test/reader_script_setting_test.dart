import 'package:drift/native.dart';
import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:liber/settings/reader_script.dart';
import 'package:liber/store/database.dart';
import 'package:liber/store/space_store.dart';

/// The reader's conversion setting (#27): one resolution — the book's override,
/// else the installation's choice, else the system locale — that both readers
/// consume, and the rows it persists.
void main() {
  late SpaceStore store;

  setUp(() => store = SpaceStore(SpaceDatabase(NativeDatabase.memory())));
  tearDown(() => store.close());

  /// Sets the locale the product reads. `WidgetsBinding.instance`'s dispatcher is
  /// the test dispatcher, so `localeTestValue` is what
  /// [ReaderScriptSetting.systemLocale] returns.
  void systemLocale(WidgetTester tester, Locale locale) {
    tester.binding.platformDispatcher.localeTestValue = locale;
    addTearDown(tester.binding.platformDispatcher.clearLocaleTestValue);
  }

  group('the system locale', () {
    test('只映射 ticket 点名的三个地区', () {
      expect(
        ReaderScriptSetting.targetForLocale(const Locale('zh', 'CN')),
        ConvertTarget.simplifiedMainland,
      );
      expect(
        ReaderScriptSetting.targetForLocale(const Locale('zh', 'TW')),
        ConvertTarget.traditionalTaiwan,
      );
      expect(
        ReaderScriptSetting.targetForLocale(const Locale('zh', 'HK')),
        ConvertTarget.traditionalHongKong,
      );
      // Anything else converts nothing: a zh locale naming no country, a locale
      // whose script tag carries the meaning, and a non-Chinese locale.
      expect(ReaderScriptSetting.targetForLocale(const Locale('zh')), isNull);
      expect(
        ReaderScriptSetting.targetForLocale(
          const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
        ),
        isNull,
      );
      expect(
        ReaderScriptSetting.targetForLocale(const Locale('en', 'US')),
        isNull,
      );
    });

    testWidgets('zh-TW 不碰设置就看到繁體（台灣）', (tester) async {
      systemLocale(tester, const Locale('zh', 'TW'));
      expect(
        await ReaderScriptSetting.resolve(store),
        ConvertTarget.traditionalTaiwan,
      );
    });

    testWidgets('zh-CN 默认简体（大陆用词）', (tester) async {
      systemLocale(tester, const Locale('zh', 'CN'));
      expect(
        await ReaderScriptSetting.resolve(store),
        ConvertTarget.simplifiedMainland,
      );
    });

    testWidgets('zh-HK 默认繁體（香港）', (tester) async {
      systemLocale(tester, const Locale('zh', 'HK'));
      expect(
        await ReaderScriptSetting.resolve(store),
        ConvertTarget.traditionalHongKong,
      );
    });

    testWidgets('其他语言不转换', (tester) async {
      systemLocale(tester, const Locale('en', 'US'));
      expect(await ReaderScriptSetting.resolve(store), isNull);
    });
  });

  group('the manual override', () {
    testWidgets('每一项都压过系统语言', (tester) async {
      systemLocale(tester, const Locale('zh', 'TW'));
      const expected = <ReaderScriptChoice, ConvertTarget?>{
        ReaderScriptChoice.simplified: ConvertTarget.simplifiedMainland,
        ReaderScriptChoice.traditionalTaiwan: ConvertTarget.traditionalTaiwan,
        ReaderScriptChoice.traditionalHongKong:
            ConvertTarget.traditionalHongKong,
        ReaderScriptChoice.traditionalGeneric: ConvertTarget.traditionalGeneric,
        ReaderScriptChoice.none: null,
      };
      for (final entry in expected.entries) {
        await ReaderScriptSetting.putGlobal(store, entry.key);
        expect(
          await ReaderScriptSetting.resolve(store),
          entry.value,
          reason: '${entry.key.label} 应解析为 ${entry.value}',
        );
      }
    });

    testWidgets('跟随系统语言是默认值，也是可以选回来的一项', (tester) async {
      systemLocale(tester, const Locale('zh', 'CN'));
      await ReaderScriptSetting.putGlobal(
        store,
        ReaderScriptChoice.traditionalGeneric,
      );
      expect(
        await ReaderScriptSetting.resolve(store),
        ConvertTarget.traditionalGeneric,
      );
      await ReaderScriptSetting.putGlobal(
        store,
        ReaderScriptChoice.followLocale,
      );
      expect(
        await ReaderScriptSetting.resolve(store),
        ConvertTarget.simplifiedMainland,
      );
    });
  });

  group('the per-book override', () {
    testWidgets('一本书的覆盖不影响另一本', (tester) async {
      systemLocale(tester, const Locale('zh', 'CN'));
      await ReaderScriptSetting.putGlobal(store, ReaderScriptChoice.simplified);
      await ReaderScriptSetting.putBook(
        store,
        'book-1',
        ReaderScriptChoice.traditionalHongKong,
      );
      expect(
        await ReaderScriptSetting.resolve(store, bookId: 'book-1'),
        ConvertTarget.traditionalHongKong,
      );
      expect(
        await ReaderScriptSetting.resolve(store, bookId: 'book-2'),
        ConvertTarget.simplifiedMainland,
      );
    });

    testWidgets('没有覆盖的书跟随全局设置', (tester) async {
      systemLocale(tester, const Locale('zh', 'TW'));
      await ReaderScriptSetting.putGlobal(store, ReaderScriptChoice.none);
      expect(
        await ReaderScriptSetting.resolve(store, bookId: 'book-1'),
        isNull,
      );
    });

    testWidgets('书籍显式选择跟随全局时也走全局', (tester) async {
      systemLocale(tester, const Locale('zh', 'CN'));
      await ReaderScriptSetting.putGlobal(
        store,
        ReaderScriptChoice.traditionalTaiwan,
      );
      await ReaderScriptSetting.putBook(
        store,
        'book-1',
        ReaderScriptChoice.followGlobal,
      );
      expect(
        await ReaderScriptSetting.resolve(store, bookId: 'book-1'),
        ConvertTarget.traditionalTaiwan,
      );
    });
  });

  group('the stored rows', () {
    test('键名与作用域就是 ticket #28 要读的那一个', () async {
      expect(ReaderScriptSetting.key, 'reader.script');
      await ReaderScriptSetting.putGlobal(
        store,
        ReaderScriptChoice.traditionalTaiwan,
      );
      await ReaderScriptSetting.putBook(
        store,
        'book-1',
        ReaderScriptChoice.simplified,
      );
      expect(await store.setting('reader.script'), 'traditional_taiwan');
      expect(
        await store.setting('reader.script', bookId: 'book-1'),
        'simplified',
      );
      expect(
        await store.setting('reader.script', bookId: 'book-2'),
        isNull,
        reason: '另一本书没有覆盖行',
      );
    });

    test('读不懂的值回落到默认，而不是变成一个目标', () {
      expect(
        ReaderScriptSetting.globalChoice('zh-tw'),
        ReaderScriptChoice.followLocale,
      );
      expect(
        ReaderScriptSetting.globalChoice('follow_global'),
        ReaderScriptChoice.followLocale,
        reason: '安装作用域没有“跟随全局”',
      );
      expect(
        ReaderScriptSetting.bookChoice('follow_locale'),
        ReaderScriptChoice.followGlobal,
        reason: '书籍作用域没有“跟随系统语言”',
      );
      expect(
        ReaderScriptSetting.bookChoice(null),
        ReaderScriptChoice.followGlobal,
      );
      expect(
        ReaderScriptSetting.globalChoice(null),
        ReaderScriptChoice.followLocale,
      );
    });
  });
}
