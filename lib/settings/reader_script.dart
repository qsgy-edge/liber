import 'package:fjs/fjs.dart' show ConvertTarget;
import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;

import '../store/space_store.dart';

/// The reader's conversion choice, as the settings screen presents it.
///
/// The ticket's options are 简体 / 繁體（台灣）/ 繁體（香港）/ 繁體（通用）/ 不转换,
/// with the installation's default being *follow the system locale*. Two
/// follow modes exist because there are two settings scopes (ADR 0007: a global
/// value plus a per-book override): [followLocale] is the installation's
/// default, and a book's [followGlobal] means "no override".
enum ReaderScriptChoice {
  /// The installation default: the system locale decides.
  followLocale,

  /// A book's default: the installation's choice decides.
  followGlobal,

  /// 简体, mainland wording included.
  simplified,

  /// 繁體（台灣）.
  traditionalTaiwan,

  /// 繁體（香港）.
  traditionalHongKong,

  /// 繁體（通用）, traditional characters without a regional norm.
  traditionalGeneric,

  /// 不转换: the text as the book has it.
  none;

  /// The value the store holds for this choice.
  ///
  /// The slugs are ASCII and independent of the UI labels, so a later settings
  /// surface (#28) reads the same rows without translating them.
  String get slug => switch (this) {
    followLocale => 'follow_locale',
    followGlobal => 'follow_global',
    simplified => 'simplified',
    traditionalTaiwan => 'traditional_taiwan',
    traditionalHongKong => 'traditional_hongkong',
    traditionalGeneric => 'traditional_generic',
    none => 'none',
  };

  /// The label the settings screen shows.
  String get label => switch (this) {
    followLocale => '跟随系统语言',
    followGlobal => '跟随全局设置',
    simplified => '简体',
    traditionalTaiwan => '繁體（台灣）',
    traditionalHongKong => '繁體（香港）',
    traditionalGeneric => '繁體（通用）',
    none => '不转换',
  };

  /// The choice a stored slug names, or null when the row holds something else.
  /// A `settings.value` is free text, so an older or hand-edited row is
  /// possible and it must not silently become a target.
  static ReaderScriptChoice? fromSlug(String? slug) {
    for (final choice in values) {
      if (choice.slug == slug) return choice;
    }
    return null;
  }
}

/// Where the reader's script comes from: one stored choice per scope and the
/// system locale, resolved once for chapter text and TOC titles alike.
///
/// The setting is one key, `reader.script`, in the space store's `settings`
/// table; its scope is the row's `bookId`, which is empty for the installation
/// and the book's id for that book's override (`SpaceStore.putSetting` /
/// `SpaceStore.setting`, `lib/store/database.dart`'s `Settings` table). Both
/// readers call [resolve] and hand the answer to `ContentProcessing.script`,
/// which converts the chapter body and the display title through
/// `TextEngine.convertTo` (ADR 0010's reader target, as opposed to the
/// character-only `java.t2s` the Book Source host surface keeps).
class ReaderScriptSetting {
  const ReaderScriptSetting._();

  /// The one key both scopes use. Ticket #28 reads it through this class.
  static const String key = 'reader.script';

  /// The manual choices the settings screen offers, in the ticket's order. The
  /// installation's list adds [ReaderScriptChoice.followLocale] in front, and a
  /// book's adds [ReaderScriptChoice.followGlobal].
  static const List<ReaderScriptChoice> manualChoices = [
    ReaderScriptChoice.simplified,
    ReaderScriptChoice.traditionalTaiwan,
    ReaderScriptChoice.traditionalHongKong,
    ReaderScriptChoice.traditionalGeneric,
    ReaderScriptChoice.none,
  ];

  /// The system locale's target: `zh-CN` → Simplified with mainland wording,
  /// `zh-TW` → Traditional (Taiwan), `zh-HK` → Traditional (Hong Kong),
  /// anything else → no conversion.
  ///
  /// Only the three regions the ticket names are mapped; a `zh` locale that
  /// names no country, or another script tag, is one of the "anything else"
  /// cases and converts nothing.
  static ConvertTarget? targetForLocale(Locale locale) {
    if (locale.languageCode != 'zh') return null;
    return switch (locale.countryCode) {
      'CN' => ConvertTarget.simplifiedMainland,
      'TW' => ConvertTarget.traditionalTaiwan,
      'HK' => ConvertTarget.traditionalHongKong,
      _ => null,
    };
  }

  /// The target a stored choice asks for. [ReaderScriptChoice.followLocale] is
  /// the only follow mode that reaches here — [resolve] collapses
  /// [ReaderScriptChoice.followGlobal] into the installation's choice first —
  /// and it is treated as "follow the locale" rather than as no conversion.
  static ConvertTarget? targetFor(
    ReaderScriptChoice choice,
    Locale locale,
  ) => switch (choice) {
    ReaderScriptChoice.followLocale ||
    ReaderScriptChoice.followGlobal => targetForLocale(locale),
    ReaderScriptChoice.simplified => ConvertTarget.simplifiedMainland,
    ReaderScriptChoice.traditionalTaiwan => ConvertTarget.traditionalTaiwan,
    ReaderScriptChoice.traditionalHongKong => ConvertTarget.traditionalHongKong,
    ReaderScriptChoice.traditionalGeneric => ConvertTarget.traditionalGeneric,
    ReaderScriptChoice.none => null,
  };

  /// The installation's choice: its stored row, or [followLocale] when none
  /// exists. A row that names no installation-scope choice (an unreadable slug,
  /// or a stray `follow_global`) falls back to the same default.
  static ReaderScriptChoice globalChoice(String? stored) {
    final choice = ReaderScriptChoice.fromSlug(stored);
    return choice == null || choice == ReaderScriptChoice.followGlobal
        ? ReaderScriptChoice.followLocale
        : choice;
  }

  /// A book's choice: its stored row, or [followGlobal] when none exists. A row
  /// that names no book-scope choice falls back to the installation's.
  static ReaderScriptChoice bookChoice(String? stored) {
    final choice = ReaderScriptChoice.fromSlug(stored);
    return choice == null || choice == ReaderScriptChoice.followLocale
        ? ReaderScriptChoice.followGlobal
        : choice;
  }

  /// The one resolution both readers use: the book's override when it has one,
  /// else the installation's choice, else the system locale.
  ///
  /// [locale] defaults to the platform dispatcher's locale, which is the one
  /// the running app and a test's `localeTestValue` both set.
  static Future<ConvertTarget?> resolve(
    SpaceStore store, {
    String bookId = '',
    Locale? locale,
  }) async {
    final override = bookId.isEmpty
        ? ReaderScriptChoice.followGlobal
        : bookChoice(await store.setting(key, bookId: bookId));
    final effective = override == ReaderScriptChoice.followGlobal
        ? globalChoice(await store.setting(key))
        : override;
    return targetFor(effective, locale ?? systemLocale());
  }

  /// The locale a resolution follows: the widget tree's dispatcher, so a test's
  /// `tester.binding.platformDispatcher.localeTestValue` is what the product
  /// reads.
  static Locale systemLocale() =>
      WidgetsBinding.instance.platformDispatcher.locale;

  /// Persists the installation's choice.
  static Future<void> putGlobal(SpaceStore store, ReaderScriptChoice choice) =>
      store.putSetting(key, choice.slug);

  /// Persists one book's override.
  static Future<void> putBook(
    SpaceStore store,
    String bookId,
    ReaderScriptChoice choice,
  ) => store.putSetting(key, choice.slug, bookId: bookId);
}

/// What a resolved target renders, in words: the settings screen shows it so a
/// reader can see what a choice and a locale together produce.
String describeReaderScript(ConvertTarget? target) => switch (target) {
  null => '不转换',
  ConvertTarget.simplifiedMainland => '简体（大陆用词）',
  ConvertTarget.traditionalTaiwan => '繁體（台灣）',
  ConvertTarget.traditionalHongKong => '繁體（香港）',
  ConvertTarget.traditionalGeneric => '繁體（通用）',
};
