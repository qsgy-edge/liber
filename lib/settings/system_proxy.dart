import '../store/space_store.dart';

/// The product's system-proxy switch (#87): one space-global `settings` row,
/// `network.system_proxy`, off by default.
///
/// Off is the direct connection this application has always used: every Book
/// Source request goes out with `findProxy = (_) => 'DIRECT'`, as it has since
/// the transport's client was first built, so an installation that never opens
/// this page behaves exactly as it did before the switch existed. On hands the
/// question to Dart's own default, `HttpClient.findProxyFromEnvironment`: the
/// request follows the machine's proxy variables, and a machine with none
/// answers `DIRECT` there anyway.
///
/// The row is the operator's answer to #87's measured failure — a source's
/// detail URL 301-redirects, and a system proxy hung on the redirect target
/// while the same request with `findProxy` `DIRECT` answered 200 — and they
/// confirmed the polarity: the switch is how an installation *asks* to go
/// through its proxy, and off keeps the product behaving the way it always
/// has.
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
class SystemProxySetting {
  const SystemProxySetting._();

  /// The one key the space store holds, beside `interface.language`,
  /// `reader.script` and `source.auto_change`.
  static const String key = 'network.system_proxy';

  /// Off: the installation keeps the direct connection it has always had.
  static const bool defaultEnabled = false;

  /// Whether the switch is on for the row the store holds.
  ///
  /// A `settings.value` is free text, so the only value that turns the switch
  /// *on* is the one [putGlobal] writes: no row, or a hand-edited one, keeps
  /// the default instead of quietly moving the installation's requests onto a
  /// proxy it did not ask for.
  static bool fromStored(String? stored) => stored == 'true';

  /// The installation's switch, read by the transport before it builds a
  /// request's client.
  static Future<bool> resolve(SpaceStore store) async =>
      fromStored(await store.setting(key));

  /// Persists the installation's switch.
  static Future<void> putGlobal(SpaceStore store, {required bool enabled}) =>
      store.putSetting(key, enabled ? 'true' : 'false');
}
