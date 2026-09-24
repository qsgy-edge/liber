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
/// the instant it expires at — 0 means permanent, which is how the frozen
/// `CacheManager` reads a `saveTime` of 0 (`CacheManager.kt:32-40`) — and the
/// instant it was last written, which is the order the store evicts a source's
/// rows in once it is at its cap (#37).
class SourceCacheEntry {
  const SourceCacheEntry({
    required this.sourceRef,
    required this.key,
    this.value,
    this.expiresAt = 0,
    this.writtenAt = 0,
  });

  final String sourceRef;
  final String key;
  final String? value;
  final int expiresAt;
  final int writtenAt;
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
///
/// The book and chapter members are not the host surface's own state: they are
/// the `books.variable`/`chapters.variable` columns a rule script reads and
/// writes through the same state object, because a script reaches space state
/// through it (the nearest existing mechanism, ADR 0011 §3); they are read and
/// written per row rather than loaded whole at startup.
abstract interface class SourceHostStatePersistence {
  Future<List<SourceCookiePair>> loadCookies();
  Future<void> saveCookie(SourceCookiePair cookie);
  Future<void> deleteCookie(String domain, String name);

  Future<List<SourceCacheEntry>> loadCache();

  /// Stores [entry] and returns the keys the store evicted to keep the entry's
  /// source within its per-source caps (#37), oldest first. A persistence that
  /// does not bound its rows returns nothing.
  Future<List<String>> saveCacheEntry(SourceCacheEntry entry);

  Future<void> deleteCacheEntry(String sourceRef, String key);

  /// The book row's own variable text (the frozen `Book.variable` column,
  /// `Book.kt:115`), or null when the space holds no such row or the row
  /// carries none.
  Future<String?> loadBookVariable(String sourceRef, String bookUrl);

  /// Writes that column and answers whether the space holds the row: a write
  /// for a book the space has no row for is kept by [SourceHostState] alone.
  Future<bool> saveBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  );

  /// The chapter row's own variable text (the frozen `BookChapter.variable`
  /// column, `BookChapter.kt:58`). [chapterKey] is the row identity a script's
  /// `chapter.url` names.
  Future<String?> loadChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  );

  /// Writes that column and answers whether the space holds the row, as
  /// [saveBookVariable] does for the book half.
  Future<bool> saveChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  );

  /// Removes every host-surface row one source owns (#36): its `source_entries`
  /// rows, the `source_cookies` rows it wrote, and the `source_tls_exceptions`
  /// rows the user confirmed for it (#53). A pair another source of the same
  /// site wrote belongs to that source, so it stays (ADR 0011 §3).
  ///
  /// A source delete and a `bookSourceUrl` change both reclaim the rows this
  /// way; the source row itself is not this interface's to remove. A TLS
  /// exception is keyed by the pair (source, host) and never one of them alone
  /// (ADR 0011 §5), so the URL is the only handle that finds it again: a row
  /// nothing can consult any more goes with the URL it was confirmed for.
  Future<void> deleteSource(String sourceRef);

  Future<List<SourceTlsException>> loadTlsExceptions();
  Future<void> saveTlsException(SourceTlsException exception);
}

/// The host surface's state one space's sources share (ADR 0011 §3): the cookie
/// jar the frozen `CookieStore` keeps, the cache entries and per-source
/// variables whose owner is the source that wrote them, and the per-source,
/// per-host TLS exceptions the user confirmed (ADR 0011 §5) — plus the book and
/// chapter rows' own variables, which a script reaches through this object
/// because it is the space state a run already carries (`book.getVariable`,
/// #76).
///
/// The live copy is in memory — a script reads a cookie inside one synchronous
/// JavaScript call — and every mutation is also written through
/// [SourceHostStatePersistence], so a restart finds what the last run wrote. One
/// state belongs to one space: a second space has its own rows and therefore its
/// own jar and cache.
///
/// The persistent store bounds what one source may keep (#37): each write is
/// checked against a per-source `cache.*` cap and a per-source
/// `java.put`/`java.get` cap, and the store evicts the least recently written
/// rows of a bucket a write overflows. It returns the evicted keys and
/// [putEntry] removes them from the in-memory copy as well, so a read in this
/// process cannot see a row the store no longer holds. A state with no
/// persistence (a gate, a tool, a test that speaks for one source) has no
/// durable store to bound.
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

  /// The book and chapter rows' own variable text (the frozen
  /// `Book.variable`/`BookChapter.variable` columns, #76): a write the space's
  /// store had no row for, kept so the analysis that made it — and every later
  /// one in this process — still reads what it wrote. A write the store took
  /// leaves no entry here, and a read prefers the store, so a row the shelf
  /// rewrote (a TOC refresh replaces the chapter rows) is read as it now is.
  /// Without a persistence (a gate, a tool, a test that speaks for no space)
  /// this map is the whole store.
  final Map<(String, String), String?> _unwrittenBookVariables = {};
  final Map<(String, String, String), String?> _unwrittenChapterVariables =
      {};

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

  /// The value one source wrote under [key] — an expired one reported as none —
  /// read synchronously from what is already loaded.
  ///
  /// This is the read a caller on a path that cannot afford a microtask needs:
  /// the outbound header of a request, which [SourceHostDispatcher] builds, and
  /// a jar read inside one synchronous JavaScript call. It never loads the store
  /// and never deletes the expired row it refuses to serve; a caller whose state
  /// is not [isLoaded] awaits [ready] first, and the asynchronous [entry] is the
  /// read that collects an expired row.
  Object? entryIfLoaded(String sourceRef, String key) {
    final stored = _cache[sourceRef]?[key];
    if (stored == null) return null;
    return isExpired(stored.expiresAt, _clock()) ? null : stored.value;
  }

  /// Stores [value] for one source, JSON-encoded so any JSON value round-trips
  /// through the store unchanged. [saveTime] is the frozen `cache.put`
  /// parameter, read by [expiryOf].
  ///
  /// The write is the source's most recently written entry; if the store had to
  /// evict rows to stay within the source's caps (#37), the keys it returns
  /// leave the in-memory copy too.
  Future<void> putEntry(
    String sourceRef,
    String key,
    Object? value, {
    int saveTime = 0,
  }) async {
    await ready();
    final now = _clock();
    final expiresAt = expiryOf(saveTime, now);
    _cache.putIfAbsent(sourceRef, () => {})[key] = _Entry(value, expiresAt);
    final evicted = await _persistence?.saveCacheEntry(
      SourceCacheEntry(
        sourceRef: sourceRef,
        key: key,
        value: jsonEncode(value),
        expiresAt: expiresAt,
        writtenAt: now,
      ),
    );
    for (final evictedKey in evicted ?? const <String>[]) {
      _cache[sourceRef]?.remove(evictedKey);
    }
  }

  /// Removes one source's entry, if it has one.
  Future<void> deleteEntry(String sourceRef, String key) async {
    await ready();
    if (_cache[sourceRef]?.remove(key) == null) return;
    await _persistence?.deleteCacheEntry(sourceRef, key);
  }

  /// The book row's own variable text (the frozen `Book.variable` column,
  /// `Book.kt:115`), or null when the space holds no such row or it carries
  /// none.
  ///
  /// The store is the read: a row the shelf rewrote is read as it now is, and a
  /// value no row took is served from [_unwrittenBookVariables].
  Future<String?> bookVariable(String sourceRef, String bookUrl) async {
    final key = (sourceRef, bookUrl);
    final stored = await _persistence?.loadBookVariable(sourceRef, bookUrl);
    if (stored != null) return stored;
    return _unwrittenBookVariables[key];
  }

  /// Writes the book row's own variable text.
  ///
  /// A write the store took is the row's now and drops any unwritten value for
  /// it; a write for a book the space has no row for stays readable in this
  /// process — the frozen entity a script holds exists before its row does
  /// (`BookInfoViewModel` runs the rules and then saves the entity), while
  /// carrying such a value into the row the shelf later writes is not
  /// implemented (#76, recorded divergence).
  Future<void> putBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  ) async {
    final key = (sourceRef, bookUrl);
    if (await _persistence?.saveBookVariable(sourceRef, bookUrl, variable) ==
        true) {
      _unwrittenBookVariables.remove(key);
      return;
    }
    _unwrittenBookVariables[key] = variable;
  }

  /// The chapter row's own variable text (the frozen `BookChapter.variable`
  /// column, `BookChapter.kt:58`); [chapterKey] is the identity a script's
  /// `chapter.url` names. Read like [bookVariable].
  Future<String?> chapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  ) async {
    final key = (sourceRef, bookUrl, chapterKey);
    final stored = await _persistence?.loadChapterVariable(
      sourceRef,
      bookUrl,
      chapterKey,
    );
    if (stored != null) return stored;
    return _unwrittenChapterVariables[key];
  }

  /// Writes the chapter row's own variable text, under the same rule as
  /// [putBookVariable].
  Future<void> putChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  ) async {
    final key = (sourceRef, bookUrl, chapterKey);
    if (await _persistence?.saveChapterVariable(
          sourceRef,
          bookUrl,
          chapterKey,
          variable,
        ) ==
        true) {
      _unwrittenChapterVariables.remove(key);
      return;
    }
    _unwrittenChapterVariables[key] = variable;
  }

  /// Drops everything one source holds (#36): its cache entries and variables,
  /// the cookies it wrote, and the TLS exceptions the user confirmed for it
  /// (ADR 0011 §5, #53). What another source of the same site wrote — the
  /// shared session (ADR 0011 §3) — and a pair no source wrote stay.
  ///
  /// The store is written first and the in-memory copy is dropped once it
  /// accepted the change, so a store write that fails leaves this process with
  /// the rows the store still holds. It does not remove the source row itself: a
  /// delete and a re-point both call this before the source is written again,
  /// and a re-point's new URL starts with no host surface of its own.
  ///
  /// A caller that runs this inside a wider transaction which is then rolled
  /// back accepts the one case the order above cannot cover: the in-process copy
  /// has already forgotten the source's rows while the store kept them.
  Future<void> deleteSource(String sourceRef) async {
    await ready();
    await _persistence?.deleteSource(sourceRef);
    _cache.remove(sourceRef);
    _tlsExceptions.removeWhere((exception) => exception.$1 == sourceRef);
    for (final domain in _writers.keys.toList()) {
      final writers = _writers[domain]!;
      for (final name in writers.keys.toList()) {
        if (writers[name] != sourceRef) continue;
        writers.remove(name);
        final pairs = _cookies[domain];
        pairs?.remove(name);
        if (pairs != null && pairs.isEmpty) _cookies.remove(domain);
      }
      if (writers.isEmpty) _writers.remove(domain);
    }
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
