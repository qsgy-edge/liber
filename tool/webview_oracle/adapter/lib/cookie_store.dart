import 'dart:convert';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Port of the frozen baseline's `CookieStore`, which is the source-visible
/// cookie surface: it stores one `name=value` map per second-level domain, reads
/// the native WebView cookie for a URL and writes it into a durable store, and
/// merges the durable value with the native value when a source asks for it.
///
/// The frozen implementation writes to a Room table plus an in-memory cache;
/// this port uses `SharedPreferences` for the durable half, because what the
/// contract compares is the source-visible cookie value across a restart, not
/// the storage engine.
class CookieStore {
  CookieStore(this._preferences);

  static Future<CookieStore> open() async =>
      CookieStore(await SharedPreferences.getInstance());

  static const String _prefix = 'cookie_';

  final SharedPreferences _preferences;

  /// The frozen `NetworkUtils.getSubDomain` reduces a host to its second-level
  /// domain; a bare host or IP literal has no second-level form and is used
  /// as-is, which is what a loopback fixture exercises.
  static String subDomain(String url) {
    final host = Uri.parse(url).host;
    final labels = host.split('.');
    if (labels.length < 3 || int.tryParse(labels.last) != null) return host;
    return labels.sublist(labels.length - 2).join('.');
  }

  static Map<String, String> cookieToMap(String cookie) {
    final map = <String, String>{};
    if (cookie.trim().isEmpty) return map;
    for (final pair in cookie.split(';')) {
      final separator = pair.indexOf('=');
      if (separator <= 0) continue;
      final name = pair.substring(0, separator).trim();
      final value = pair.substring(separator + 1).trim();
      if (value.isNotEmpty || value == 'null') map[name] = value;
    }
    return map;
  }

  static String mapToCookie(Map<String, String> map) => map.entries
      .map((entry) => '${entry.key}=${entry.value}')
      .join('; ');

  /// Mirrors `CookieStore.setCookie(url, cookie)`: the value observed in the
  /// native store is written verbatim under the URL's second-level domain, so an
  /// empty native cookie overwrites a previously stored value.
  Future<void> setCookie(String url, String? cookie) async {
    await _preferences.setString('$_prefix${subDomain(url)}', cookie ?? '');
  }

  /// The durable half only, matching what survives a process restart.
  String durableCookie(String url) =>
      _preferences.getString('$_prefix${subDomain(url)}') ?? '';

  /// Mirrors `CookieStore.getCookie(url)`: the durable value merged with the
  /// live native cookie for that URL.
  Future<String> getCookie(String url) async {
    final native = await CookieManager.instance().getCookies(url: WebUri(url));
    final merged = cookieToMap(durableCookie(url));
    for (final cookie in native) {
      merged[cookie.name] = cookie.value.toString();
    }
    return mapToCookie(merged);
  }

  /// Reads the native cookie for a URL exactly as the frozen
  /// `BackstageWebView.setCookie` does at page completion.
  static Future<String> nativeCookie(String url) async {
    final cookies = await CookieManager.instance().getCookies(url: WebUri(url));
    return cookies
        .map((cookie) => '${cookie.name}=${cookie.value}')
        .join('; ');
  }

  /// Test-visible state reset, used to isolate a fixture without relying on the
  /// device being freshly installed.
  Future<void> clear() async {
    for (final key in _preferences.getKeys().toList()) {
      if (key.startsWith(_prefix)) await _preferences.remove(key);
    }
    await CookieManager.instance().deleteAllCookies();
  }

  Map<String, String> snapshot() {
    final result = <String, String>{};
    for (final key in _preferences.getKeys()) {
      if (!key.startsWith(_prefix)) continue;
      result[key.substring(_prefix.length)] = _preferences.getString(key) ?? '';
    }
    return result;
  }

  @override
  String toString() => jsonEncode(snapshot());
}
