import '../store/space_store.dart';

/// The product's direct-connection switch (#87): one space-global `settings`
/// row, `network.direct`, off by default.
///
/// On means every Book Source request this product sends through `dart:io`'s
/// `HttpClient` carries `findProxy = (_) => 'DIRECT'` and so does not go
/// through the system proxy; off means Dart's own default,
/// `HttpClient.findProxyFromEnvironment`, is what answers — a machine with no
/// proxy configured answers `DIRECT` there anyway, so this row is the only
/// thing that changes a request's path.
///
/// It is one Dart code path and therefore one behaviour on all five platforms
/// (`windows`, `macos`, `linux`, `android`, `ios`); there is deliberately no
/// `Platform` check in it. Two limits it cannot lift, named here so no one
/// reads more into the switch than it does:
///
/// * a VPN-mode proxy on `android`/`ios` intercepts below the socket API, where
///   no in-app `findProxy` reaches; the proxy app's own per-app rules are the
///   only lever there;
/// * the WebView path (`webView: true` request options and the hatch pages)
///   renders through the platform engine, whose own proxy handling this row
///   does not touch.
class DirectConnectionSetting {
  const DirectConnectionSetting._();

  /// The one key the space store holds, beside `interface.language`,
  /// `reader.script` and `source.auto_change`.
  static const String key = 'network.direct';

  /// Off: the installation keeps Dart's default (the system proxy).
  static const bool defaultEnabled = false;

  /// Whether the switch is on for the row the store holds.
  ///
  /// A `settings.value` is free text, so the only value that turns the switch
  /// *on* is the one [putGlobal] writes: no row, or a hand-edited one, keeps the
  /// default instead of silently directing traffic around the user's proxy.
  static bool fromStored(String? stored) => stored == 'true';

  /// The installation's switch, read by the transport before it builds a
  /// request's client.
  static Future<bool> resolve(SpaceStore store) async =>
      fromStored(await store.setting(key));

  /// Persists the installation's switch.
  static Future<void> putGlobal(SpaceStore store, {required bool enabled}) =>
      store.putSetting(key, enabled ? 'true' : 'false');
}
