import 'package:flutter/widgets.dart' show Locale, WidgetsBinding;

import '../store/space_store.dart';

/// The interface's own language: which of the interfaces `lib/l10n/` carries the
/// widgets read (#28).
///
/// The frozen reader's `PreferKey.language` is the same three-way plus a
/// symbolic default — `"zh"` Simplified, `"tw"` Traditional, `"en"` English,
/// anything else the system locale — with the Traditional half split into the
/// two regions the ticket names. The slugs are ASCII and independent of the
/// labels, the way `ReaderScriptChoice`'s are, so a stored row does not have to
/// be translated.
enum InterfaceLanguageChoice {
  /// The installation default: the system locale decides.
  followLocale,

  /// English.
  english,

  /// 简体中文.
  simplified,

  /// 繁體中文（台灣）.
  traditionalTaiwan,

  /// 繁體中文（香港）.
  traditionalHongKong;

  /// The value the store holds for this choice.
  String get slug => switch (this) {
    followLocale => 'follow_locale',
    english => 'english',
    simplified => 'simplified',
    traditionalTaiwan => 'traditional_taiwan',
    traditionalHongKong => 'traditional_hongkong',
  };

  /// The choice a stored slug names, or null when the row holds something else.
  /// A `settings.value` is free text, so an older or hand-edited row must not
  /// silently become a language.
  static InterfaceLanguageChoice? fromSlug(String? slug) {
    for (final choice in values) {
      if (choice.slug == slug) return choice;
    }
    return null;
  }
}

/// The interface language: one setting, `interface.language`, in the space
/// store's `settings` table, and the one function that turns a choice and the
/// running locale into the `Locale` the widgets read.
///
/// The setting is logically installation-level — switching spaces should not
/// switch the interface's language — but the settings table is space-scoped, so
/// it starts there (the ticket's note); for a single-space installation the two
/// are indistinguishable. The interface language stays independent of the
/// content's script (`ReaderScriptSetting`, #27): an English interface with
/// Simplified books is a state both settings can be put into, and neither reads
/// the other's row.
///
/// The resolution is applied by rebuilding `MaterialApp` with the resolved
/// `Locale`, so a change is visible on the next frame — deliberately without
/// the frozen reader's restart prompt (its Android resources are fixed at
/// context creation; Flutter re-resolves them on rebuild).
class InterfaceLanguageSetting {
  const InterfaceLanguageSetting._();

  /// The one key the space store holds.
  static const String key = 'interface.language';

  /// 简体中文: the template `lib/l10n/app_zh.arb`. A `zh` locale that names no
  /// region is Simplified, which is what the frozen reader's `values-zh`
  /// answered.
  static const Locale simplified = Locale('zh');

  /// English: `lib/l10n/app_en.arb`.
  static const Locale english = Locale('en');

  /// 繁體中文（台灣）: `lib/l10n/app_zh_Hant_TW.arb`.
  static const Locale traditionalTaiwan = Locale.fromSubtags(
    languageCode: 'zh',
    scriptCode: 'Hant',
    countryCode: 'TW',
  );

  /// 繁體中文（香港）: `lib/l10n/app_zh_Hant_HK.arb`.
  static const Locale traditionalHongKong = Locale.fromSubtags(
    languageCode: 'zh',
    scriptCode: 'Hant',
    countryCode: 'HK',
  );

  /// The four interfaces, in the order `AppLocalizations.supportedLocales`
  /// lists them. `MaterialApp` gets this list and never Flutter's own matching:
  /// the resolution below is the only one, and it answers with one of these
  /// four for every input.
  static const List<Locale> supportedLocales = [
    simplified,
    english,
    traditionalTaiwan,
    traditionalHongKong,
  ];

  /// The setting's choices, in the settings screen's order.
  static const List<InterfaceLanguageChoice> choices = [
    InterfaceLanguageChoice.followLocale,
    InterfaceLanguageChoice.english,
    InterfaceLanguageChoice.simplified,
    InterfaceLanguageChoice.traditionalTaiwan,
    InterfaceLanguageChoice.traditionalHongKong,
  ];

  /// The interface a system locale asks for, the way the frozen reader's
  /// `getSetLocale` falls through: `zh-CN` and an unqualified `zh` →
  /// Simplified, `zh-TW` → Taiwan, `zh-HK` → Hong Kong, English → English, and
  /// every other language → English (the frozen reader's unmatched locale falls
  /// back to its default `values`, which are English).
  static Locale followSystem(Locale systemLocale) =>
      switch (systemLocale.languageCode) {
        'zh' => switch (systemLocale.countryCode) {
          'TW' => traditionalTaiwan,
          'HK' => traditionalHongKong,
          _ => simplified,
        },
        _ => english,
      };

  /// The interface a choice asks for.
  static Locale localeFor(
    InterfaceLanguageChoice choice,
    Locale systemLocale,
  ) => switch (choice) {
    InterfaceLanguageChoice.followLocale => followSystem(systemLocale),
    InterfaceLanguageChoice.english => english,
    InterfaceLanguageChoice.simplified => simplified,
    InterfaceLanguageChoice.traditionalTaiwan => traditionalTaiwan,
    InterfaceLanguageChoice.traditionalHongKong => traditionalHongKong,
  };

  /// The installation's choice: its stored row, or [followLocale] when none
  /// exists. A row that names no choice falls back to the same default.
  static InterfaceLanguageChoice globalChoice(String? stored) =>
      InterfaceLanguageChoice.fromSlug(stored) ??
      InterfaceLanguageChoice.followLocale;

  /// The running locale — the one place the platform dispatcher's locale is
  /// read, for the interface and for the content's script alike
  /// ([ReaderScriptSetting.systemLocale] answers with this).
  ///
  /// It is the *platform's* locale, not the interface `MaterialApp` was given:
  /// an interface language the user chose never moves it, which is what keeps
  /// "English interface, books following the system locale" a state that stays
  /// put (a test pins that combination).
  static Locale systemLocale() =>
      WidgetsBinding.instance.platformDispatcher.locale;

  /// The interface locale the store's row asks for.
  ///
  /// [systemLocale] overrides the platform dispatcher, which is what a test
  /// whose machine locale is not the one it means to exercise hands in.
  static Future<Locale> resolve(
    SpaceStore store, {
    Locale? systemLocale,
  }) async => localeFor(
    globalChoice(await store.setting(key)),
    systemLocale ?? InterfaceLanguageSetting.systemLocale(),
  );

  /// Persists the installation's choice.
  static Future<void> putGlobal(
    SpaceStore store,
    InterfaceLanguageChoice choice,
  ) => store.putSetting(key, choice.slug);
}
