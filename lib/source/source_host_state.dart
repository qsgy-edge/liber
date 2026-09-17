import 'dart:convert';

import 'registrable_domain.dart';

/// A cookie pair as the space keeps it: keyed by the registrable domain of the
/// site it was set for, with the source that wrote it, when a source wrote it.
///
/// A pair no source wrote (nobody but the site is recorded) is visible to every
/// source of that site; a pair under another site's key is visible only to the
/// source that wrote it (ADR 0011 §3).
class SourceCookiePair {
  const SourceCookiePair({
    required this.domain,
    required this.name,
    required this.value,
    this.writerRef,
  });

  final String domain;
  final String name;
  final String value;
  final String? writerRef;
}

/// A cache entry, or one of the per-source variables `java.put`/`java.get`
/// share with `source.put`/`source.get`, as the space keeps them: the value as
/// JSON text (a `cache.put` value is any JSON value), the source it belongs to,
/// and the instant it expires at — 0 means permanent, which is how the frozen
/// `CacheManager` reads a `saveTime` of 0 (`CacheManager.kt:32-40`).
class SourceCacheEntry {
  const SourceCacheEntry({
    required this.sourceRef,
    required this.key,
    this.value,
    this.expiresAt = 0,
  });

  final String sourceRef;
  final String key;
  final String? value;
  final int expiresAt;
}

/// An accepted TLS exception (ADR 0011 §5): the source and the host whose
/// invalid certificate the user confirmed continuing with. Keyed by both, so
/// the exception is the pair and never one of them alone.
class SourceTlsException {
  const SourceTlsException({required this.sourceRef, required this.host});

  final String sourceRef;
  final String host;
}

/// Where the host surface's state is read and written.
///
/// `lib/store/host_state.dart` implements this over the space's `data.db`; the
/// gates and the tools run without one, and then [SourceHostState] holds the
/// state for the process.
abstract interface class SourceHostStatePersistence {
  Future<List<SourceCookiePair>> loadCookies();
  Future<void> saveCookie(SourceCookiePair cookie);
  Future<void> deleteCookie(String domain, String name);

  Future<List<SourceCacheEntry>> loadCache();
  Future<void> saveCacheEntry(SourceCacheEntry entry);
  Future<void> deleteCacheEntry(String sourceRef, String key);

  Future<List<SourceTlsException>> loadTlsExceptions();
  Future<void> saveTlsException(SourceTlsException exception);
}

/// The host surface's state one space's sources share (ADR 0011 §3): the cookie
/// jar the frozen `CookieStore` keeps, the cache entries and per-source
/// variables whose owner is the source that wrote them, and the per-source,
/// per-host TLS exceptions the user confirmed (ADR 0011 §5).
///
/// The live copy is in memory — a script reads a cookie inside one synchronous
/// JavaScript call — and every mutation is also written through
/// [SourceHostStatePersistence], so a restart finds what the last run wrote. One
/// state belongs to one space: a second space has its own rows and therefore its
/// own jar and cache.
class SourceHostState {
  factory SourceHostState({
    SourceHostStatePersistence? persistence,
    int Function()? clock,
  }) => SourceHostState._(persistence, clock ?? _systemMillis);

  SourceHostState._(this._persistence, this._clock);

  final SourceHostStatePersistence? _persistence;
  final int Function() _clock;

  /// Pairs per registrable domain, and the source that wrote each pair.
  final Map<String, Map<String, String>> _cookies = {};
  final Map<String, Map<String, String>> _writers = {};

  /// Entries per source, then per key.
  final Map<String, Map<String, _Entry>> _cache = {};

  /// Accepted TLS exceptions, as `(sourceRef, host)` pairs (ADR 0011 §5).
  final Set<(String, String)> _tlsExceptions = {};

  Future<void>? _reading;
  bool _loaded = false;

  /// Whether a read sees everything the store holds without waiting: true when
  /// there is nothing to load, and again once the one load has finished. A
  /// caller on a synchronous path (the outbound cookie header, a jar read
  /// inside one JavaScript call) awaits [ready] only when this is false.
  bool get isLoaded => _persistence == null || _loaded;

  /// Reads what the space already holds, once. Every read and write below awaits
  /// it, so no caller can observe half a store.
  Future<void> ready() => _reading ??= _read();

  Future<void> _read() async {
    final persistence = _persistence;
    if (persistence == null) return;
    for (final cookie in await persistence.loadCookies()) {
      _cookies.putIfAbsent(cookie.domain, () => {})[cookie.name] = cookie.value;
      final writer = cookie.writerRef;
      if (writer != null && writer.isNotEmpty) {
        _writers.putIfAbsent(cookie.domain, () => {})[cookie.name] = writer;
      }
    }
    final now = _clock();
    for (final entry in await persistence.loadCache()) {
      // A deadline that passed while the app was closed is a deadline that
      // passed; the row goes as it is noticed.
      if (isExpired(entry.expiresAt, now)) {
        await persistence.deleteCacheEntry(entry.sourceRef, entry.key);
        continue;
      }
      _cache.putIfAbsent(entry.sourceRef, () => {})[entry.key] = _Entry(
        _decode(entry.value),
        entry.expiresAt,
      );
    }
    for (final exception in await persistence.loadTlsExceptions()) {
      _tlsExceptions.add((exception.sourceRef, exception.host));
    }
    _loaded = true;
  }

  /// The jar one source speaks through: the same session, seen with the
  /// visibility rule below.
  SourceCookieJar cookiesFor(String sourceRef) =>
      SourceCookieJar._view(this, sourceRef);

  /// The instant an entry written now with `saveTime` seconds expires at, or 0
  /// for one that does not.
  ///
  /// The write path stores what this says and the read path compares against
  /// [isExpired] of the same value, so the two cannot drift apart:
  /// `saveTime = 0` is permanent and any other value is a deadline that far
  /// ahead, exactly as the frozen `CacheManager` reads it.
  static int expiryOf(int saveTime, int now) =>
      saveTime <= 0 ? 0 : now + saveTime * 1000;

  /// Whether an entry that expires at [expiresAt] is past its deadline.
  static bool isExpired(int expiresAt, int now) =>
      expiresAt != 0 && now >= expiresAt;

  /// The value one source wrote under [key], or null when it wrote none, or the
  /// one it wrote is past its deadline — an expired entry is deleted as it is
  /// noticed, so it is never read again.
  Future<Object?> entry(String sourceRef, String key) async {
    await ready();
    final stored = _cache[sourceRef]?[key];
    if (stored == null) return null;
    if (isExpired(stored.expiresAt, _clock())) {
      await deleteEntry(sourceRef, key);
      return null;
    }
    return stored.value;
  }

  /// Stores [value] for one source, JSON-encoded so any JSON value round-trips
  /// through the store unchanged. [saveTime] is the frozen `cache.put`
  /// parameter, read by [expiryOf].
  Future<void> putEntry(
    String sourceRef,
    String key,
    Object? value, {
    int saveTime = 0,
  }) async {
    await ready();
    final expiresAt = expiryOf(saveTime, _clock());
    _cache.putIfAbsent(sourceRef, () => {})[key] = _Entry(value, expiresAt);
    await _persistence?.saveCacheEntry(
      SourceCacheEntry(
        sourceRef: sourceRef,
        key: key,
        value: jsonEncode(value),
        expiresAt: expiresAt,
      ),
    );
  }

  /// Removes one source's entry, if it has one.
  Future<void> deleteEntry(String sourceRef, String key) async {
    await ready();
    if (_cache[sourceRef]?.remove(key) == null) return;
    await _persistence?.deleteCacheEntry(sourceRef, key);
  }

  static Object? _decode(String? value) =>
      value == null ? null : jsonDecode(value);

  /// Whether one source may continue past a certificate failure at [host]: the
  /// stored exception for exactly that pair (ADR 0011 §5).
  ///
  /// A synchronous read of the loaded state, which is what the transport's
  /// decision needs; a caller that has not awaited [ready] must await it first —
  /// a persistence-backed state that has not loaded yet reports false.
  bool allowsInvalidCertificate(String sourceRef, String host) =>
      _tlsExceptions.contains((sourceRef, host));

  /// Remembers the user's confirmation for one source and host, and writes it
  /// through so the next run reads the same answer. A pair already stored is
  /// left as it is.
  Future<void> allowInvalidCertificate(String sourceRef, String host) async {
    await ready();
    if (!_tlsExceptions.add((sourceRef, host))) return;
    await _persistence?.saveTlsException(
      SourceTlsException(sourceRef: sourceRef, host: host),
    );
  }

  static int _systemMillis() => DateTime.now().millisecondsSinceEpoch;
}

class _Entry {
  const _Entry(this.value, this.expiresAt);
  final Object? value;
  final int expiresAt;
}

/// The session cookie store the frozen baseline keeps in `CookieStore` plus its
/// platform jar, seen by one source.
///
/// Pairs are keyed by the registrable domain of the site they were set for
/// (ADR 0011 §3), which is the baseline's own key (`CookieStore.kt:27` →
/// `NetworkUtils.getSubDomain`), so two hosts of one site share a jar and the
/// recorded divergence of exact-host keys is closed. Every argument that names a
/// site takes a URL or a bare host.
///
/// [sourceRef] is the source this view speaks for. It may read, send and delete
/// a pair under its own site's key, or a pair it wrote itself; another site's
/// pairs stay out of its reach. An empty [sourceRef] is the no-identity case —
/// a gate or a tool that runs one source — and then nothing is hidden.
class SourceCookieJar {
  /// A jar with no source identity and no persistence: what a tool or a test
  /// that speaks for one source needs.
  SourceCookieJar() : this._view(SourceHostState(), '');

  SourceCookieJar._view(this._state, this._sourceRef);

  final SourceHostState _state;
  final String _sourceRef;

  /// The source this jar speaks for; empty when there is no identity.
  String get sourceRef => _sourceRef;

  /// The source's own site: the registrable domain of its `bookSourceUrl`.
  /// Empty without a source identity.
  late final String _siteGroup = _sourceRef.isEmpty
      ? ''
      : registrableDomain(_hostOf(_sourceRef));

  /// Frozen `CookieStore.getCookie`: the pairs held for the URL's site,
  /// serialized `k=v; k2=v2`. The frozen baseline drops a random pair past
  /// 4096 characters; this jar does not, a recorded divergence (ADR 0011 §3).
  String cookiesFor(String url) => header(_hostOf(url));

  /// The outbound `Cookie` header for a request to [host]: the pairs this source
  /// may send there — its own site's, and the ones it wrote (ADR 0011 §3, the
  /// rule applies to what goes on the wire and not only to what a script reads).
  String header(String host) => _serialize(registrableDomain(_hostOf(host)));

  /// Frozen `CookieStore.getKey`.
  String value(String url, String key) {
    final domain = registrableDomain(_hostOf(url));
    if (!_visible(domain, key)) return '';
    return _state._cookies[domain]?[key] ?? '';
  }

  /// Frozen `CookieStore.setCookie`: the given cookie string replaces what this
  /// site holds.
  ///
  /// A source may only clear a pair it may delete, so a foreign site's pairs
  /// survive a write that is not about them; within the source's own site the
  /// session is shared, as the baseline shares it.
  Future<void> set(String url, String cookie) =>
      _write(registrableDomain(_hostOf(url)), cookie, replace: true);

  /// Frozen `CookieStore.replaceCookie`: merge instead of replace.
  Future<void> replace(String url, String cookie) =>
      _write(registrableDomain(_hostOf(url)), cookie, replace: false);

  /// A `Set-Cookie` response's pairs. The source that received the response
  /// wrote them (ADR 0011 §3 names that as its own write), so it can read,
  /// send and delete them even when the response came from another site.
  Future<void> accept(String host, Iterable<String> values) async {
    final domain = registrableDomain(_hostOf(host));
    for (final raw in values) {
      final pair = _pairOf(raw);
      if (pair == null) continue;
      await _put(domain, pair.$1, pair.$2);
    }
  }

  /// Frozen `CookieStore.removeCookie`: forgets what this source may forget for
  /// the URL's site.
  Future<void> remove(String url) async {
    final domain = registrableDomain(_hostOf(url));
    for (final name in _clearable(domain)) {
      await _delete(domain, name);
    }
  }

  /// Clears what this source may clear, everywhere.
  Future<void> clear() async {
    for (final domain in _state._cookies.keys.toList()) {
      for (final name in _clearable(domain)) {
        await _delete(domain, name);
      }
    }
  }

  /// Whether this source may read, send and delete the pair [name] under
  /// [domain]: the site is its own, or it wrote that pair itself.
  bool _visible(String domain, String name) {
    if (_sourceRef.isEmpty) return true;
    return domain == _siteGroup ||
        _state._writers[domain]?[name] == _sourceRef;
  }

  /// The names this source may delete under [domain]: all of its own site's
  /// pairs, and under another site only the ones it wrote.
  List<String> _clearable(String domain) => [
    for (final name in _state._cookies[domain]?.keys.toList() ?? const <String>[])
      if (_visible(domain, name)) name,
  ];

  String _serialize(String domain) {
    final pairs = _state._cookies[domain];
    if (pairs == null) return '';
    return [
      for (final entry in pairs.entries)
        if (_visible(domain, entry.key)) '${entry.key}=${entry.value}',
    ].join('; ');
  }

  Future<void> _write(
    String domain,
    String cookie, {
    required bool replace,
  }) async {
    if (replace) {
      for (final name in _clearable(domain)) {
        await _delete(domain, name);
      }
    }
    for (final pair in _pairsOf(cookie)) {
      await _put(domain, pair.$1, pair.$2);
    }
  }

  /// The `name=value` pairs of a cookie string; a pair with no `=` is ignored,
  /// as the frozen jar ignores it.
  Iterable<(String, String)> _pairsOf(String cookie) sync* {
    for (final raw in cookie.split(';')) {
      final pair = _pairOf(raw);
      if (pair != null) yield pair;
    }
  }

  (String, String)? _pairOf(String raw) {
    final parts = raw.split(';').first.split('=');
    if (parts.length < 2) return null;
    return (parts.first.trim(), parts.sublist(1).join('=').trim());
  }

  Future<void> _put(String domain, String name, String value) async {
    if (name.isEmpty) return;
    final pairs = _state._cookies.putIfAbsent(domain, () => {});
    if (value.isEmpty) {
      // An empty value is a deletion, as the frozen jar and its `Set-Cookie`
      // handling both read it — and only of a pair this source may delete.
      if (!_visible(domain, name)) return;
      await _delete(domain, name);
      return;
    }
    pairs[name] = value;
    final writer = _sourceRef.isEmpty ? null : _sourceRef;
    if (writer == null) {
      _state._writers[domain]?.remove(name);
    } else {
      _state._writers.putIfAbsent(domain, () => {})[name] = writer;
    }
    await _state._persistence?.saveCookie(
      SourceCookiePair(
        domain: domain,
        name: name,
        value: value,
        writerRef: writer,
      ),
    );
  }

  Future<void> _delete(String domain, String name) async {
    final pairs = _state._cookies[domain];
    if (pairs == null) return;
    pairs.remove(name);
    _state._writers[domain]?.remove(name);
    if (pairs.isEmpty) _state._cookies.remove(domain);
    await _state._persistence?.deleteCookie(domain, name);
  }
}

/// The host a URL or a host argument names: a URL's host, or the argument itself
/// when it is already a host (`a.test`, `127.0.0.1`, `::1`).
String _hostOf(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
  return url;
}
