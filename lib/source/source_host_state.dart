import 'dart:async';
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
  /// `Book.kt:115`): null when the space holds no such row, and otherwise the
  /// row with the text it carries, which may itself be null (#132). The two
  /// cases are different: a row that carries no text is authoritative, where a
  /// missing row leaves the in-process unwritten value as the only one.
  Future<SourceEntityVariableRow?> loadBookVariable(
    String sourceRef,
    String bookUrl,
  );

  /// Writes that column and answers whether the space holds the row: a write
  /// for a book the space has no row for is kept by [SourceHostState] alone.
  Future<bool> saveBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  );

  /// The chapter row's own variable text (the frozen `BookChapter.variable`
  /// column, `BookChapter.kt:58`), read like [loadBookVariable]. [chapterKey] is
  /// the row identity a script's `chapter.url` names.
  Future<SourceEntityVariableRow?> loadChapterVariable(
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

  /// Stored TOC chapters for index-and-title restoration.
  Future<List<({int index, String title, String? variable})>>
  loadChapterRestorationRows(String sourceRef, String bookUrl);

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

/// One stored book or chapter row's own variable text as
/// [SourceHostStatePersistence] answers it (#132).
///
/// A non-null value is the row: [variable] is authoritative, and a null
/// [variable] is a row that carries no text rather than a missing row. A null
/// value is the missing row, where the in-process unwritten-value cache is the
/// only value a read has.
class SourceEntityVariableRow {
  const SourceEntityVariableRow(this.variable);
  final String? variable;
}

/// The book and chapter rows' own variable text a rule script reads and writes
/// (`book.getVariable`/`putVariable`/`variable` and the chapter pair, #76),
/// separated from the wider host surface.
///
/// A run reads and writes the space's own rows through [SourceHostState]; a
/// candidate analysis that must not touch them yet carries the same four
/// operations over a private [SourceEntityVariableDraft] instead, so a preview
/// of a row that already exists leaves it alone.
abstract interface class SourceEntityVariableStore {
  Future<String?> bookVariable(String sourceRef, String bookUrl);
  Future<void> putBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  );
  Future<String?> chapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  );
  Future<void> putChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  );
}

/// The candidate-scoped book and chapter variable text one deferred analysis
/// carries (#132).
///
/// The maps are private to the analysis that owns the draft: nothing here
/// reaches the space's store or the shared unwritten-value caches on
/// [SourceHostState], so an analysis of a candidate that turns out to be
/// rejected — a failed or cancelled details/TOC draft — leaves every stored row
/// exactly as it was. The draft is seeded from the carriers the analysis is
/// handed ([seedBook]/[seedChapter]) and read back into the carriers it
/// returns through [bookVariable]/[chapterVariable].
class SourceEntityVariableDraft implements SourceEntityVariableStore {
  final Map<(String, String), String?> _books = {};
  final Map<(String, String, String), String?> _chapters = {};

  /// Seeds the candidate book's variable text under the identity the script
  /// binds as `book.bookUrl`. An entity the draft already carries is left as it
  /// is, so a later request on the same analysis cannot reseed an older
  /// carrier over a write an earlier stage made.
  void seedBook(String sourceRef, String bookUrl, String? variable) {
    _books.putIfAbsent((sourceRef, bookUrl), () => variable);
  }

  /// Seeds one candidate chapter's variable text under the row key the script
  /// binds as `chapter.url`. Left as it is when the draft already carries that
  /// chapter, like [seedBook].
  void seedChapter(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  ) {
    _chapters.putIfAbsent((sourceRef, bookUrl, chapterKey), () => variable);
  }

  /// Starts a fresh candidate for one book identity: the book's own entry and
  /// every chapter entry under it are dropped, so a rebuilt TOC cannot see a
  /// variable written by a previous TOC. [details] calls this before it seeds
  /// the new carrier.
  void resetBook(String sourceRef, String bookUrl) {
    _books.remove((sourceRef, bookUrl));
    _chapters.removeWhere((key, _) => key.$1 == sourceRef && key.$2 == bookUrl);
  }

  @override
  Future<String?> bookVariable(String sourceRef, String bookUrl) async =>
      _books[(sourceRef, bookUrl)];

  @override
  Future<void> putBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  ) async {
    _books[(sourceRef, bookUrl)] = variable;
  }

  @override
  Future<String?> chapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  ) async => _chapters[(sourceRef, bookUrl, chapterKey)];

  @override
  Future<void> putChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  ) async {
    _chapters[(sourceRef, bookUrl, chapterKey)] = variable;
  }
}

typedef _TocChapterHandoff =
    Map<
      (String, String, String),
      ({SourceEntityVariableRow? rawWrite, SourceEntityVariableRow? resolved})
    >;

/// The book and chapter variable store one pipeline's runtime reads and writes
/// (#132), composed of the analysis's [base] store and, while a TOC item is
/// being rebuilt, that item's own chapter scope.
///
/// [base] is the candidate's private [SourceEntityVariableDraft] when the
/// analysis defers entity variables and the space's rows otherwise, so the book
/// half and the chapter half outside a rebuild keep their existing path.
/// The ordinary TOC hands off item writes and final carrier values only after
/// the complete list succeeds; the deferred path never publishes either.
///
/// One TOC item is one [beginChapter] scope: its chapter variables start empty —
/// a read answers only what this item's own rules wrote, never the row a
/// previous directory left — and its last write is what the item's carrier
/// keeps ([chapterText]). The scope ends with [endChapter].
class SourceEntityVariableScope implements SourceEntityVariableStore {
  SourceEntityVariableScope(this.base, {this.through});

  /// The book half and the chapter half outside a TOC item rebuild.
  final SourceEntityVariableStore base;

  /// The row store an ordinary TOC hands its final chapter variables to.
  final SourceHostState? through;
  final List<Map<(String, String, String), String?>> _tocItems = [];
  Map<(String, String, String), String?> _itemWrites = {};

  /// Discards uncommitted item writes from any previous analysis.
  void beginToc() => _tocItems.clear();

  /// Keeps writes only for an item that made it into the generated list.
  void recordTocChapter() => _tocItems.add(_itemWrites);

  /// Prepares the handoff without publishing it. The caller checks liveness
  /// after the last await, then publishes synchronously.
  Future<void Function()> prepareTocHandoff(
    String sourceRef,
    String bookUrl,
    List<({String key, String? variable, String? restoredVariable})> chapters,
  ) async {
    final host = through;
    if (host == null) return _tocItems.clear;
    final writes = <(String, String, String), String?>{};
    final seenKeys = <String>{};
    final repeatedKeys = <String>{};
    for (var i = 0; i < chapters.length; i++) {
      final chapter = chapters[i];
      for (final entry in _tocItems[i].entries) {
        writes[entry.key] = chapter.restoredVariable ?? entry.value;
      }
      if (!seenKeys.add(chapter.key)) repeatedKeys.add(chapter.key);
    }
    // Content reads by resolved row key. A null variable for a unique key is
    // authoritative; for a repeated key there is no authoritative carrier.
    final handoff = await host._prepareTocHandoff(writes, {
      for (final chapter in chapters)
        (sourceRef, bookUrl, chapter.key): repeatedKeys.contains(chapter.key)
            ? null
            : SourceEntityVariableRow(chapter.variable),
    });
    return () {
      host._publishTocHandoff(handoff);
      _tocItems.clear();
    };
  }

  Map<String, String?>? _item;
  String? _itemText;

  /// Starts one rebuilt TOC item's chapter scope: its reads answer only this
  /// item's own writes.
  void beginChapter() {
    _item = {};
    _itemWrites = {};
    _itemText = null;
  }

  /// Ends the current item's scope, restoring the direct chapter path.
  void endChapter() => _item = null;

  /// The text the current TOC item's carrier keeps: its last rule write, or
  /// null when no rule wrote one.
  String? get chapterText => _itemText;

  @override
  Future<String?> bookVariable(String sourceRef, String bookUrl) =>
      base.bookVariable(sourceRef, bookUrl);

  @override
  Future<void> putBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  ) => base.putBookVariable(sourceRef, bookUrl, variable);

  @override
  Future<String?> chapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  ) {
    final item = _item;
    return item == null
        ? base.chapterVariable(sourceRef, bookUrl, chapterKey)
        : Future<String?>.value(item[chapterKey]);
  }

  @override
  Future<void> putChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  ) async {
    final item = _item;
    if (item == null) {
      return base.putChapterVariable(sourceRef, bookUrl, chapterKey, variable);
    }
    item[chapterKey] = variable;
    _itemText = variable;
    if (through != null) {
      _itemWrites[(sourceRef, bookUrl, chapterKey)] = variable;
    }
  }
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
class SourceHostState implements SourceEntityVariableStore {
  factory SourceHostState({
    SourceHostStatePersistence? persistence,
    int Function()? clock,
  }) => SourceHostState._(persistence, clock ?? _systemMillis);

  SourceHostState._(this._persistence, this._clock);

  final SourceHostStatePersistence? _persistence;
  final int Function() _clock;

  /// Pairs per registrable domain, and the source that wrote each pair.
  final Map<String, Map<String, String>> _cookies = {};

  /// Per domain, the cookie names that have a persistent position, in the order
  /// of their first persistent write: a script `setCookie`/`replaceCookie`, a
  /// `Set-Cookie` whose attributes make it persistent, or a durable row loaded
  /// at start-up. It is process-only ordering metadata — no value lives here and
  /// nothing is persisted — and it reproduces the frozen `CookieStore.getCookie`
  /// order: the persistent map first, then the session map.
  final Map<String, Set<String>> _persistentNames = {};
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
  // Keep the raw TOC write behind its resolved-key override so an ambiguous
  // rebuild can drop the override without losing the explicit raw handoff.
  // A synthesized value without a raw write goes back to absence, not null.
  final Map<
    (String, String, String),
    ({String? variable, bool fromToc, SourceEntityVariableRow? rawTocVariable})
  >
  _unwrittenChapterVariables = {};

  /// Reads stored chapters only, never the unwritten chapter cache.
  Future<List<({int index, String title, String? variable})>>
  chapterRestorationRows(String sourceRef, String bookUrl) async =>
      await _persistence?.loadChapterRestorationRows(sourceRef, bookUrl) ?? [];

  /// Filters out stored chapter keys without changing the unwritten cache.
  Future<_TocChapterHandoff> _prepareTocHandoff(
    Map<(String, String, String), String?> rawWrites,
    Map<(String, String, String), SourceEntityVariableRow?> resolvedVariables,
  ) async {
    final result = _TocChapterHandoff();
    for (final key in {...rawWrites.keys, ...resolvedVariables.keys}) {
      final prior = _unwrittenChapterVariables[key];
      final priorRaw = prior?.rawTocVariable;
      final resolved = resolvedVariables[key];
      final rawWrite = rawWrites.containsKey(key)
          ? SourceEntityVariableRow(rawWrites[key])
          : null;
      if (rawWrite == null) {
        if (prior?.fromToc == false) continue;
        // Publish non-null unique carriers even without a prior entry. A reader
        // would otherwise seed an unwritten value indistinguishable from a write.
        if (prior == null && resolved?.variable == null) continue;
        // Without a fresh carrier, only a synthesized value needs clearing.
        if (resolved == null &&
            priorRaw != null &&
            prior?.variable == priorRaw.variable) {
          continue;
        }
      }
      if (await _persistence?.loadChapterVariable(key.$1, key.$2, key.$3) ==
          null) {
        result[key] = (rawWrite: rawWrite, resolved: resolved);
      }
    }
    return result;
  }

  /// Publishes the successful analysis's no-row handoff synchronously.
  void _publishTocHandoff(_TocChapterHandoff handoff) {
    for (final entry in handoff.entries) {
      final prior = _unwrittenChapterVariables[entry.key];
      final (rawWrite: rawWrite, resolved: resolved) = entry.value;
      // An explicit reader write is not a TOC override. Only a fresh raw write
      // at exactly this key may replace it, as before.
      final canOverride = prior?.fromToc != false;
      if (!canOverride && rawWrite == null) continue;
      final raw = rawWrite ?? prior?.rawTocVariable;
      final useResolved = resolved != null && canOverride;
      if (!useResolved && raw == null) {
        _unwrittenChapterVariables.remove(entry.key);
        continue;
      }
      _unwrittenChapterVariables[entry.key] = (
        variable: useResolved ? resolved.variable : raw!.variable,
        fromToc: true,
        rawTocVariable: raw,
      );
    }
  }

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
      // A stored row is durable, so it holds a persistent position in the order
      // the store returns it.
      _persistentNames.putIfAbsent(cookie.domain, () => {}).add(cookie.name);
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

  SourceEntityVariableDraft? get _readerVariables =>
      Zone.current[this] as SourceEntityVariableDraft?;

  /// A pending reader chapter sees its own entity writes, while other host
  /// operations and reads of unstaged fields retain their ordinary behavior.
  Future<(T, SourceEntityVariableDraft)> stageReaderVariables<T>(
    Future<T> Function() read,
  ) async {
    final draft = SourceEntityVariableDraft();
    final result = await runZoned(read, zoneValues: {this: draft});
    return (result, draft);
  }

  /// Writes accepted entity changes inside the reader's store transaction.
  /// The returned handoff updates the in-process cache only after commit.
  Future<void Function()> saveReaderVariables(
    SourceEntityVariableDraft draft,
  ) async {
    final storedBooks = <(String, String)>{};
    final storedChapters = <(String, String, String)>{};
    for (final entry in draft._books.entries) {
      final (source, book) = entry.key;
      if (await _persistence?.saveBookVariable(source, book, entry.value) ==
          true) {
        storedBooks.add(entry.key);
      }
    }
    for (final entry in draft._chapters.entries) {
      final (source, book, chapter) = entry.key;
      if (await _persistence?.saveChapterVariable(
            source,
            book,
            chapter,
            entry.value,
          ) ==
          true) {
        storedChapters.add(entry.key);
      }
    }
    return () {
      for (final entry in draft._books.entries) {
        if (storedBooks.contains(entry.key)) {
          _unwrittenBookVariables.remove(entry.key);
        } else {
          _unwrittenBookVariables[entry.key] = entry.value;
        }
      }
      for (final entry in draft._chapters.entries) {
        if (storedChapters.contains(entry.key)) {
          _unwrittenChapterVariables.remove(entry.key);
        } else {
          _unwrittenChapterVariables[entry.key] = (
            variable: entry.value,
            fromToc: false,
            rawTocVariable: null,
          );
        }
      }
    };
  }

  /// The book row's own variable text (the frozen `Book.variable` column,
  /// `Book.kt:115`), or null when the space holds no such row or it carries
  /// none.
  ///
  /// The store is the read: a row the shelf rewrote is read as it now is, and a
  /// value no row took is served from [_unwrittenBookVariables]. A row that
  /// carries no text is authoritative — the unwritten cache does not resurrect
  /// a value the row replaced with an empty one (#132).
  @override
  Future<String?> bookVariable(String sourceRef, String bookUrl) async {
    final key = (sourceRef, bookUrl);
    final staged = _readerVariables?._books;
    if (staged != null && staged.containsKey(key)) return staged[key];
    final stored = await _persistence?.loadBookVariable(sourceRef, bookUrl);
    if (stored != null) return stored.variable;
    return _unwrittenBookVariables[key];
  }

  /// Writes the book row's own variable text.
  ///
  /// A write the store took is the row's now and drops any unwritten value for
  /// it; a write for a book the space has no row for stays readable in this
  /// process — the frozen entity a script holds exists before its row does
  /// (`BookInfoViewModel` runs the rules and then saves the entity). The carrier
  /// a details/TOC stage returns takes the final text with the same identity, so
  /// the row the shelf later writes receives it (#132).
  @override
  Future<void> putBookVariable(
    String sourceRef,
    String bookUrl,
    String? variable,
  ) async {
    final key = (sourceRef, bookUrl);
    final draft = _readerVariables;
    if (draft != null) {
      return draft.putBookVariable(sourceRef, bookUrl, variable);
    }
    if (await _persistence?.saveBookVariable(sourceRef, bookUrl, variable) ==
        true) {
      _unwrittenBookVariables.remove(key);
      return;
    }
    _unwrittenBookVariables[key] = variable;
  }

  /// The chapter row's own variable text (the frozen `BookChapter.variable`
  /// column, `BookChapter.kt:58`); [chapterKey] is the identity a script's
  /// `chapter.url` names. Read like [bookVariable]: an existing row is
  /// authoritative even when it carries no text.
  @override
  Future<String?> chapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  ) async =>
      (await chapterVariableRow(sourceRef, bookUrl, chapterKey))?.variable;

  /// The chapter entry's own variable text with its presence (#132): null when
  /// the space holds neither a row nor an unwritten value for exactly that key,
  /// and otherwise the entry with the text it carries, which may itself be
  /// null. A stored row wins over an unwritten cache entry, so an entry whose
  /// text is null is present and authoritative rather than absent.
  Future<SourceEntityVariableRow?> chapterVariableRow(
    String sourceRef,
    String bookUrl,
    String chapterKey,
  ) async {
    final key = (sourceRef, bookUrl, chapterKey);
    final staged = _readerVariables?._chapters;
    if (staged != null && staged.containsKey(key)) {
      return SourceEntityVariableRow(staged[key]);
    }
    final stored = await _persistence?.loadChapterVariable(
      sourceRef,
      bookUrl,
      chapterKey,
    );
    if (stored != null) return stored;
    final unwritten = _unwrittenChapterVariables[key];
    return unwritten == null
        ? null
        : SourceEntityVariableRow(unwritten.variable);
  }

  /// Writes the chapter row's own variable text, under the same rule as
  /// [putBookVariable].
  @override
  Future<void> putChapterVariable(
    String sourceRef,
    String bookUrl,
    String chapterKey,
    String? variable,
  ) async {
    final key = (sourceRef, bookUrl, chapterKey);
    final draft = _readerVariables;
    if (draft != null) {
      return draft.putChapterVariable(sourceRef, bookUrl, chapterKey, variable);
    }
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
    _unwrittenChapterVariables[key] = (
      variable: variable,
      fromToc: false,
      rawTocVariable: null,
    );
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
        final ordered = _persistentNames[domain];
        ordered?.remove(name);
        if (ordered != null && ordered.isEmpty) _persistentNames.remove(domain);
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
      await _put(
        domain,
        pair.$1,
        pair.$2,
        persistent: _responseCookieIsPersistent(raw),
      );
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
    return domain == _siteGroup || _state._writers[domain]?[name] == _sourceRef;
  }

  /// The names this source may delete under [domain]: all of its own site's
  /// pairs, and under another site only the ones it wrote.
  List<String> _clearable(String domain) => [
    for (final name
        in _state._cookies[domain]?.keys.toList() ?? const <String>[])
      if (_visible(domain, name)) name,
  ];

  /// The frozen `CookieStore.getCookie` order: the persistent names first, in
  /// the order they first became persistent, then the session names in their own
  /// insertion order. Both blocks read the one value map.
  String _serialize(String domain) {
    final pairs = _state._cookies[domain];
    if (pairs == null) return '';
    final persistent = _state._persistentNames[domain];
    final rendered = <String>[];
    if (persistent != null) {
      for (final name in persistent) {
        if (!_visible(domain, name)) continue;
        final value = pairs[name];
        if (value == null) continue;
        rendered.add('$name=$value');
      }
    }
    for (final entry in pairs.entries) {
      if (persistent != null && persistent.contains(entry.key)) continue;
      if (!_visible(domain, entry.key)) continue;
      rendered.add('${entry.key}=${entry.value}');
    }
    return rendered.join('; ');
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
      // A script `setCookie`/`replaceCookie` writes the persistent store.
      await _put(domain, pair.$1, pair.$2, persistent: true);
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

  Future<void> _put(
    String domain,
    String name,
    String value, {
    bool persistent = false,
  }) async {
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
    if (persistent) {
      // A name keeps its first persistent position; a later session write does
      // not move it out of the persistent block.
      _state._persistentNames.putIfAbsent(domain, () => {}).add(name);
    }
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
    final ordered = _state._persistentNames[domain];
    ordered?.remove(name);
    if (ordered != null && ordered.isEmpty) {
      _state._persistentNames.remove(domain);
    }
    if (pairs.isEmpty) _state._cookies.remove(domain);
    await _state._persistence?.deleteCookie(domain, name);
  }
}

/// Whether one `Set-Cookie` value is persistent in the frozen baseline's terms.
///
/// The scanner below is adapted from OkHttp 4.12.0's `okhttp3.Cookie`
/// (`Cookie.kt:380-470,487-580` and `Util.kt`'s `trimSubstring`), copyright (C)
/// 2015 Square, Inc., licensed under the Apache License, Version 2.0: its
/// attribute scan, `Expires`/`Max-Age` validity rules, JVM integer handling and
/// ASCII-whitespace trim are translated to Dart for classification here. See
/// the repository `NOTICE`.
///
/// The frozen `okhttp3.Cookie.parse` (4.12.0, `Cookie.kt:380-470`) starts with
/// `persistent = false` and sets it only when an `Expires` attribute parses as a
/// cookie date or a `Max-Age` attribute parses as a max age; an attribute that
/// does not parse is ignored and never resets an earlier one. This is a validity
/// classification for ordering only: it reads neither the cookie's name/value
/// nor its expiry, and it rejects nothing.
bool _responseCookieIsPersistent(String setCookie) {
  var persistent = false;
  // The first `;`-segment is the cookie pair; every later one is an attribute.
  final segments = setCookie.split(';');
  for (var index = 1; index < segments.length; index++) {
    final segment = segments[index];
    final equals = segment.indexOf('=');
    final name = _cookieTrim(
      equals < 0 ? segment : segment.substring(0, equals),
    );
    final value = equals < 0 ? '' : _cookieTrim(segment.substring(equals + 1));
    if (_cookieAttributeNameEquals(name, 'expires')) {
      if (_cookieDateIsValid(value)) persistent = true;
    } else if (_cookieAttributeNameEquals(name, 'max-age')) {
      if (_cookieMaxAgeIsValid(value)) persistent = true;
    }
  }
  return persistent;
}

/// The attribute name compared the way the JVM's `String.equalsIgnoreCase`
/// compares it: equal code units, or equal simple uppercase forms, or equal
/// simple lowercase forms. The frozen parser therefore reads an attribute
/// spelled with a character whose simple case maps onto the ASCII name — `ſ`
/// uppercases to `S`, `ı` to `I`, `İ` lowercases to `i` — and neither locale
/// nor a maintained table takes part. The original name text is kept as it is.
bool _cookieAttributeNameEquals(String name, String expected) {
  if (name.length != expected.length) return false;
  for (var index = 0; index < name.length; index++) {
    final actual = name.codeUnitAt(index);
    final wanted = expected.codeUnitAt(index);
    if (actual == wanted) continue;
    final actualChar = String.fromCharCode(actual);
    final wantedChar = String.fromCharCode(wanted);
    if (actualChar.toUpperCase() == wantedChar.toUpperCase()) continue;
    if (actualChar.toLowerCase() == wantedChar.toLowerCase()) continue;
    return false;
  }
  return true;
}

/// okhttp's `trimSubstring`, whose whitespace set is exactly tab, line feed,
/// form feed, carriage return and space (`Util.kt`'s
/// `indexOfFirstNonAsciiWhitespace`: code units 9, 10, 12, 13 and 32). A
/// vertical tab, a NUL or any other control character is data here, so an
/// attribute it touches is not recognised, as in the frozen parser.
bool _isCookieTrimWhitespace(int code) =>
    code == 0x09 ||
    code == 0x0a ||
    code == 0x0c ||
    code == 0x0d ||
    code == 0x20;

String _cookieTrim(String text) {
  var start = 0;
  var end = text.length;
  while (start < end && _isCookieTrimWhitespace(text.codeUnitAt(start))) {
    start++;
  }
  while (end > start && _isCookieTrimWhitespace(text.codeUnitAt(end - 1))) {
    end--;
  }
  return text.substring(start, end);
}

/// One Unicode decimal digit (`Character.digit`'s `Nd` category), by its numeric
/// value, or null for every other code point.
///
/// The SDK's Unicode regular-expression support classifies the code point and
/// the value is its offset from the start of its own contiguous ten-digit block,
/// so no maintained digit table is needed.
int? _cookieDecimalDigit(int unit) {
  // A JVM `char` is one UTF-16 code unit: a surrogate half is not a digit, so a
  // supplementary-plane digit (two surrogate code units) never parses, exactly
  // as `Character.digit(char, 10)` answers -1 for each half.
  if (unit >= 0xd800 && unit <= 0xdfff) return null;
  if (!_cookieDecimalDigitPattern.hasMatch(String.fromCharCode(unit))) {
    return null;
  }
  // `Character.digit` reads the character's own digit value; a BMP decimal
  // block is ten consecutive code units, so its offset is that value. Nine
  // steps stay inside one block (BMP digit blocks are never adjacent).
  var start = unit;
  var steps = 0;
  while (steps < 9 &&
      _cookieDecimalDigitPattern.hasMatch(String.fromCharCode(start - 1))) {
    start--;
    steps++;
  }
  return unit - start;
}

final _cookieDecimalDigitPattern = RegExp(r'^\p{Nd}$', unicode: true);
final _cookieLongMax = BigInt.parse('9223372036854775807');
final _cookieLongMinMagnitude = BigInt.parse('9223372036854775808');

/// Whether the value is a JVM `Long` (`Long.parseLong`): an optional ASCII sign,
/// then `Character.digit(char, 10)` digits in **UTF-16 code units** — an
/// Arabic-Indic `٥` or a fullwidth `５` is a five, while a supplementary-plane
/// digit is a surrogate pair and fails — whose magnitude fits a signed 64-bit
/// integer. Dart's `int.parse` reads ASCII only and must not stand in for it.
bool _cookieMaxAgeParsesAsLong(String value) {
  var index = 0;
  var negative = false;
  if (value.isNotEmpty && (value[0] == '+' || value[0] == '-')) {
    negative = value[0] == '-';
    index = 1;
  }
  if (index >= value.length) return false;
  final limit = negative ? _cookieLongMinMagnitude : _cookieLongMax;
  var magnitude = BigInt.zero;
  final ten = BigInt.from(10);
  for (final unit in value.substring(index).codeUnits) {
    final digit = _cookieDecimalDigit(unit);
    if (digit == null) return false;
    // Stop as soon as the magnitude would pass the signed 64-bit bound, as the
    // source's own scan does; the value is not a Long and there is nothing to
    // accumulate further.
    final next = BigInt.from(digit);
    if (magnitude > (limit - next) ~/ ten) return false;
    magnitude = magnitude * ten + next;
  }
  return true;
}

/// okhttp's `parseMaxAge` (`Cookie.kt:565-580`): a value that parses as a JVM
/// `Long` is a max age (whatever its sign); an integer too large for that type
/// is still one when it has the decimal form the source retries; anything else
/// is not, and its `NumberFormatException` makes the parser ignore the
/// attribute. The retry's `-?\d+` is Java's ASCII `\d`, so a `+`-prefixed or
/// non-ASCII overflowing value stays invalid.
bool _cookieMaxAgeIsValid(String value) {
  if (_cookieMaxAgeParsesAsLong(value)) return true;
  return RegExp(r'^-?[0-9]+$').hasMatch(value);
}

final _cookieTimePattern = RegExp(r'^(\d{1,2}):(\d{1,2}):(\d{1,2})[^\d]*$');
final _cookieDayPattern = RegExp(r'^(\d{1,2})[^\d]*$');
// Java's `(?i)(jan|feb|...|dec).*`, matched against the whole run as
// `Matcher.matches()` does. The tail is Java's default dot, which excludes every
// line terminator — `\u0085` included, unlike ECMAScript's dot — so a run such as
// `Jun\u0085` does not match the month token. `lib/source/java_regex.dart` keeps
// the same Java dot set for the rule translator.
final _cookieMonthPattern = RegExp(
  r'^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[^\n\r\u0085\u2028\u2029]*$',
  caseSensitive: false,
);
final _cookieYearPattern = RegExp(r'^(\d{2,4})[^\d]*$');
const _cookieMonths = [
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

/// okhttp's `dateCharacterOffset` (`Cookie.kt:548-563`): the first date or
/// non-date character from [pos], or [limit].
bool _isCookieDateCharacter(int code) =>
    (code < 0x20 && code != 0x09) ||
    code >= 0x7f ||
    (code >= 0x30 && code <= 0x39) ||
    (code >= 0x41 && code <= 0x5a) ||
    (code >= 0x61 && code <= 0x7a) ||
    code == 0x3a;

int _cookieDateCharacterOffset(String input, int pos, int limit, bool invert) {
  for (var index = pos; index < limit; index++) {
    if (_isCookieDateCharacter(input.codeUnitAt(index)) != invert) return index;
  }
  return limit;
}

/// okhttp's `parseExpires` (`Cookie.kt:487-538`): a token date scan that accepts
/// the RFC 1123, RFC 850 and asctime shapes (and any other order of the same
/// tokens), maps a two-digit year, requires a real calendar date, and treats an
/// impossible date as an invalid attribute. True means "the frozen parser would
/// set `persistent` for this value"; the instant itself is never used here.
bool _cookieDateIsValid(String value) {
  var hour = -1;
  var minute = -1;
  var second = -1;
  var day = -1;
  var month = -1;
  var year = -1;
  var pos = _cookieDateCharacterOffset(value, 0, value.length, false);
  while (pos < value.length) {
    final end = _cookieDateCharacterOffset(value, pos + 1, value.length, true);
    final run = value.substring(pos, end);
    if (hour == -1) {
      final match = _cookieTimePattern.firstMatch(run);
      if (match != null) {
        hour = int.parse(match[1]!);
        minute = int.parse(match[2]!);
        second = int.parse(match[3]!);
        pos = _cookieDateCharacterOffset(value, end + 1, value.length, false);
        continue;
      }
    }
    if (day == -1) {
      final match = _cookieDayPattern.firstMatch(run);
      if (match != null) {
        day = int.parse(match[1]!);
        pos = _cookieDateCharacterOffset(value, end + 1, value.length, false);
        continue;
      }
    }
    if (month == -1) {
      final match = _cookieMonthPattern.firstMatch(run);
      if (match != null) {
        month = _cookieMonths.indexOf(match[1]!.toLowerCase()) + 1;
        pos = _cookieDateCharacterOffset(value, end + 1, value.length, false);
        continue;
      }
    }
    if (year == -1) {
      final match = _cookieYearPattern.firstMatch(run);
      if (match != null) {
        year = int.parse(match[1]!);
        pos = _cookieDateCharacterOffset(value, end + 1, value.length, false);
        continue;
      }
    }
    pos = _cookieDateCharacterOffset(value, end + 1, value.length, false);
  }
  if (year >= 70 && year <= 99) year += 1900;
  if (year >= 0 && year <= 69) year += 2000;
  if (year < 1601 ||
      month == -1 ||
      day < 1 ||
      day > 31 ||
      hour < 0 ||
      hour > 23 ||
      minute < 0 ||
      minute > 59 ||
      second < 0 ||
      second > 59) {
    return false;
  }
  // The frozen parser sets a non-lenient Gregorian calendar, so an impossible
  // calendar date (31 April, 29 February in a common year) rejects the
  // attribute; a round-trip is that same check.
  final date = DateTime.utc(year, month, day, hour, minute, second);
  return date.year == year &&
      date.month == month &&
      date.day == day &&
      date.hour == hour &&
      date.minute == minute &&
      date.second == second;
}

/// The host a URL or a host argument names: a URL's host, or the argument itself
/// when it is already a host (`a.test`, `127.0.0.1`, `::1`).
String _hostOf(String url) {
  final parsed = Uri.tryParse(url);
  if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
  return url;
}
