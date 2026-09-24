import '../store/space_store.dart';

/// The reader's automatic switch-source setting (#69): the frozen
/// `AppConfig.autoChangeSource` (`AppConfig.kt:396-397`,
/// `constant/PreferKey.kt:87`), one space-global `settings` row, on by default.
///
/// The frozen reader reads it as `getPrefBoolean(PreferKey.autoChangeSource,
/// true)` and returns before its source loop when it is off
/// (`ReadBookViewModel.kt:281`), so this row is the frozen's own switch and not
/// a product invention: an installation that leaves it alone switches a book
/// whose source was deleted onto another source, and one that turns it off
/// issues no request at all.
///
/// The row is space-global (`SpaceStore.setting`'s default empty `bookId`): the
/// frozen preference is one installation-wide boolean and the automatic switch
/// has no per-book override.
class AutoChangeSourceSetting {
  const AutoChangeSourceSetting._();

  /// The one key the space store holds, beside `interface.language` and
  /// `reader.script`.
  static const String key = 'source.auto_change';

  /// The frozen `getPrefBoolean` default.
  static const bool defaultEnabled = true;

  /// Whether the switch is on for the row the store holds.
  ///
  /// A `settings.value` is free text, so the only value that turns the switch
  /// *off* is the one [putGlobal] writes: no row, or a hand-edited one, keeps
  /// the frozen default instead of silently disabling the switch.
  static bool fromStored(String? stored) =>
      stored == null ? defaultEnabled : stored != 'false';

  /// The installation's switch, read before any network work starts.
  static Future<bool> resolve(SpaceStore store) async =>
      fromStored(await store.setting(key));

  /// Persists the installation's switch.
  static Future<void> putGlobal(SpaceStore store, {required bool enabled}) =>
      store.putSetting(key, enabled ? 'true' : 'false');
}
