# Delivery phases and acceptance gates

Ticket: #8. Decided 2026-09-17; when this decision is published, the resolution
comment on #8 becomes the record of the session and this document the durable
copy future batches cite. An independent read-only review of the draft ran twice
on the same day; its findings and their fixes go into that comment with the
decision.

Inputs: [first-slice.md](first-slice.md) (#6),
[book-source-differential-contract.md](book-source-differential-contract.md),
[book-source-capability-matrix.md](book-source-capability-matrix.md),
[legado-data-migration-contract.md](legado-data-migration-contract.md),
[legado-compatibility-baseline.md](legado-compatibility-baseline.md),
[five-platform-runtime-components.md](five-platform-runtime-components.md),
[../../docs/user-data-contract.md](../user-data-contract.md), ADRs 0001–0012,
`tool/ci_runtime.py` (the runnable gate rows), `README.md` → Status,
Verification and evidence.

## Verdict

1. **Six phases, Windows-first.** The proven vertical slice, the local library
   and the migration land as the Windows product's claim, then the five-platform
   product shell, then v1-scope Book Source compatibility, and finally the
   product-completion slice (multi-source search and switch-source). The phase
   table below is both the order and the claim ladder.
2. **A phase gates claims, not work.** A phase's *claim* requires its own gate to
   be green and every earlier phase's claim to hold. Work on a later phase may
   start before an earlier gate is green, as long as it cannot invalidate an
   earlier gate's evidence; if it can, that gate is re-run before its claim
   stands. This is what the practice so far has actually been doing.
3. **Gates are runnable today, or blocked with a name.** Every gate below names
   an existing command, gate row, harness or driven run, and distinguishes what
   exists from what the phase must add. No gate name is invented, and a green CI
   workflow promotes nothing by itself (README, "Verification and evidence").
4. **Every claim is per platform.** ADR 0002 and ADR 0009: a source is compatible
   on a platform only when every stage it reaches passes there, and a platform
   may not claim compatibility without, on that platform: the shared runtime
   gates, the limits rows, and #2's WebView rows for its adapter.
5. **v1's capability scope is anchored to the sources the operator actually
   uses**, plus the rows existing tickets already commit to, except where this
   decision ratifies a narrower scope. Everything else is a named deferral with
   an owner; a required row without an owner is "in scope, blocked on owner
   creation", not silently dropped. The method, the counts and the row-by-row
   split are in the v1 scope section below.
6. **P6 is a phase.** Multi-source search (including the frozen "precise search"
   flow) and switch-source are product work built on the already-committed
   search/information/TOC stages; they produce no compatibility rows and close
   after the compatibility claim.
7. **No P4 work now.** The five-platform shell is defined and sequenced; it is
   not started in this session, and its build rows are not claimed as existing.

## Phase table

| # | Phase | Delivers | Exit criteria (runnable evidence) | Stays `not-run` (named blocker) |
|---|---|---|---|---|
| P1 | **Proven vertical slice** (Windows) | SLICE-01 measured end to end: four stages, page chaining, session state, shelf and reader | **P1a — destination rows (done):** `dart run tool/first_slice_replay.dart <debug fjs.dll>` green against the recorded checks (evidence `tool/first_slice/evidence/windows-slice-01.liber.json`), and `flutter test test` including `test/first_slice_fixture_test.dart`; R1–R9 (Liber side), R10 and R11 = `run` on the driven run of 2026-09-17 (recorded in #6's resolution comment), which is qualified as **store-seeded**: the controller seeded the `sources` row and drove 书架 → 书源试读 → search → information → both TOC pages → 加入书架 → reader over both content pages, reading `books`, `chapters`, `progress` and `source_cookies` back from the scratch `data.db`; the 选择书源 JSON dialog step of that flow is **not** driven; R12 promoted by CI run `35125476388` (head `5232038`, all five jobs green). **P1b — frozen rows:** #38's four-stage oracle entry produces `tool/first_slice/evidence/android-<fingerprint>/golden.json`; the comparator reports R2–R9 row by row with every `notCompared` entry named. | R13/R14 (device rows) — no Android device or AVD is attached today (#38); iOS needs a Mac + simulator. P1a green means the slice runs; only P1b green permits the compatibility claim for the capabilities SLICE-01 reaches. |
| P2 | **Local library** (Windows) | folder selection, scanning, explicit adds, TXT/Markdown reading in bounded windows, progress anchors, relinking | `flutter test test` with the named files `test/local_library_test.dart`, `test/local_reader_page_test.dart`, `test/local_reader_progress_test.dart`, `test/local_reader_restore_test.dart`, `test/local_reader_native_test.dart`, `test/space_store_test.dart` (these exist and cover selection/scanning, explicit adds, bounded reads, progress, restore and relinking); one driven run on a scratch installation (the operator picks the folder — the driver cannot open a folder dialog; the run adds a book, reads it, restarts and restores by anchor, and exercises the relink report) recorded with the commands, the strings the app showed and the store rows. | Other platforms are P4. There is no frozen side: the local library is fixed by ADR 0006/0007, not by the Legado baseline. |
| P3 | **Migration** (Windows) — **implemented and driven, two residuals** | two distinct migrations: (a) Liber's own retired JSON stores (`online_reading.json`, `local_books.json`, `migration_state.json`) into a space, done and driven (#24); (b) a Legado export — source JSON or the full-backup ZIP — into a space, with a loss report, idempotent merge, progress that only advances, and local files flagged for relinking | **Exists:** `LegacyImport` (a, evidenced in #24) and, for (b), `lib/store/legado_full_backup.dart` (`LegadoBackupArchive` + `LegadoFullBackupImport`) with the file-level entry `importLegadoBackupFile` (`lib/store/legacy_import.dart`), the traversal guard and the member size bound; the picker accepts `.zip` and `.json` (`lib/main.dart:843`). `test/legado_full_backup_test.dart` (32 tests) covers families 1 and 3–12 (`test/legacy_import_test.dart`, `test/legado_backup_import_test.dart` and `test/migration_test.dart` stay green). **Driven (#46):** the operator's real backup imported in a scratch Windows app — 8 786 sources, 1 419 books (34 local), 9 groups, 1 419 progress rows, loss report read back, a second import wrote nothing new. **Residuals:** family 2's domain-policy half has no counterpart (the product has no import-time domain policy, #46); an imported unresolved local book has no relink path yet — its root/file rows do not exist, so re-adding the file makes a second book (#46). | Other platforms are P4. No frozen golden: the migration contract is its own specification. Cookies, caches, chapter data and book bytes stay excluded by the contract. |
| P4 | **Five-platform product shell** | Android, iOS, macOS and Linux project scaffolding, native glue, an app that builds and launches, the per-platform gate rows, and the WebView adapters (#2) | **Exists:** Windows is the only integrated application (`windows/` is the only platform directory; `linux/`, `macos/`, `android/`, `ios/` do not exist); the shared gate list runs on Windows, Linux and macOS through CI (e.g. run `35053007809` for the Linux/macOS gate rows, per ADR 0009's provenance). **P4 work, Tier A:** add the app-build steps to the existing platform CI jobs using valid commands — `flutter build windows`, `flutter build linux`, `flutter build macos`, `flutter build apk`, `flutter build ios --simulator --no-codesign` — and run the limits harness on each desktop platform: the harness is already platform-neutral (`tool/runtime_limits_prototype/verify.py` selects Windows/macOS/Linux, resolves `.dll`/`.dylib`/`.so`, uses per-platform probe flags and writes `<platform>-*.json`), so what is missing is execution and validation on Linux and macOS, where the probes' POSIX clock branch has never been compiled from this host. **Tier B (machine-dependent):** a launch smoke and, where a machine exists, a driven run — Windows now, macOS on the operator's Mac, Linux on a real machine or WSL (recording WSL and its distribution when used), Android on a device or AVD, iOS in the Mac's simulator. | No device-side runtime row set exists for Android/iOS (CI cross-builds the native library only), so a mobile platform cannot claim compatibility from build/device rows alone: ADR 0009 also requires that platform's limits rows and #2 WebView rows. Linux rendered-document path stays `not-run` until #2 proves WebKitGTK. Non-Windows limits rows stay `not-run` until the harness is executed and validated on those platforms (the harness itself is already platform-neutral), and the Android/iOS limits rows need their own binding and a device. |
| P5 | **v1-scope Book Source compatibility** | the v1-scope capability rows closed with fixtures and per-platform comparisons, with the named deferrals and accepted divergences kept visible | For every in-v1 row: a differential fixture and a passing comparison on every **claimed** platform; the aggregate stays honest — no coverage gap inside the v1 scope, every `not-run` row named, every `policy-rejected` row named, every accepted divergence named; the operator's used-source set is re-triaged with `dart run tool/source_triage.dart <fjs.dll> <exported sources>` as a supplemental observation (never a gate). | Everything in the deferral table below, with its owner; the frozen goldens of #15/#23/#38 are recorded on the handset, so what remains of those rows is their Android *destination* half, which waits on P4 (the product has no Android application). **P5 does not deliver the differential contract's "frozen-baseline complete" verdict:** that verdict needs no matrix gap, every required fixture on all five platforms, and no baseline-supported source policy-rejected (`book-source-differential-contract.md`, Verdict Aggregation); P5's claim is narrower and must be stated as v1-scope compatibility on named platforms. |
| P6 | **Product completion** (v1's last slice) | multi-source search, the frozen precise-search flow, and switch-source with progress remapping; the settings field set lands here too (#27, #28) | New product ticket(s): the flows are driven on a scratch installation (search across the selected sources, pick an exact name+author match, switch the book's source and show the reading position surviving the switch), with store rows read back. Plus the existing tickets' own acceptance: #27 (locale-driven conversion with a manual and per-book override, both readers re-rendered without reopening, `java.t2s` still characters only, chapter-sized conversion measured or moved off the UI thread) and #28 (independent interface/content settings that apply immediately and survive a restart, every ARB file carrying the template's key set). | Nothing frozen: these flows are product work over search/information/TOC, recorded as observations rather than compatibility rows. |

Where the route is today: P1a is done, P1b blocked; P2 is implemented with its
evidence to assemble into the named list; P3 is implemented and driven, with the
two residuals named in its row (#46); P4 has not started (no non-Windows platform
projects exist); P5
has capability slices landed but no v1-scope claim; P6 has not started.

### P3 — the migration contract's coverage, family by family

The 12 fixture families the contract requires
([legado-data-migration-contract.md](legado-data-migration-contract.md),
"Required Fixtures and Tests"). `test/migration_test.dart` verifies drift schema
upgrades, so it is not counted as Legado-import coverage. The states below are
#46's own family table (the lane's evidence comment), against
`test/legado_full_backup_test.dart`; the two rows that stay partial name their
reason, and no family is silently claimed.

| # | Contract family | Coverage | Status |
|---|---|---|---|
| 1 | Source object/array shapes: nested rules, nulls, booleans, large integers, unknown fields, non-ASCII | the raw round trip is asserted field for field (`未知字段、null、布尔、大整数与非 ASCII 都原样留在 raw`) | covered |
| 2 | Invalid sources: blank URL/name, empty arrays, null members, malformed values, domain-policy rejection distinct from JSON validation | blank URL/name are skipped and reported, empty arrays and malformed members are covered; **no domain policy exists at import**, so that half of the row has no counterpart | partial (named) |
| 3 | Full backup ZIP: `bookshelf.json`, `bookSource.json`, `bookGroup.json`, `config.xml`, absent optional files, path-traversal rejection | five traversal spellings, all four members, absent members, the size bound, a non-Legado ZIP and an unparseable ZIP | covered |
| 4 | Network and local books preserving custom metadata, order, opaque variables, nonzero progress | asserted per book through import and re-import | covered |
| 5 | `file://` and `content://` cases: no Android path/URI in the contract, unresolved locals keep metadata/progress | the stored row is scanned for `content://`, `file://`, `/storage/`, `%3A`; unresolved locals are flagged for relinking | covered |
| 6 | All 64 custom group bits including `Long.MIN_VALUE`; synthetic negative group ids excluded | 64 groups, four masks, the seven system ids | covered |
| 7 | Restore conflicts: same `bookUrl`; different `bookUrl` with the same `(name, author)` | the conflict family is asserted (the same URL stays one row; same name+author different URL stays two) | covered |
| 8 | Repeated imports, progress ordering, source-replacement approval, group union, non-destructive metadata merge | repetition, forward-only progress, the union rule and the fill-blanks merge | covered |
| 9 | Loss reporting for cookies, caches, chapters, downloads and local bytes | each excluded family is asserted by name | covered |
| 10 | `BookProgress`: missing fields, nullable title, 64-bit millisecond time, deterministic round trips | missing/zero fields write no row, 64-bit milliseconds land verbatim, `null` title is reported — one recorded gap: the frozen chapter **title** has no column, so it is reported rather than carried | covered (one named gap) |
| 11 | Legacy UI `books.json` detected as lossy, never accepted as a full package | refused by name in both containers (bare JSON text and a member named `bookshelf.json`) | covered |
| 12 | Deterministic canonical output including group names and local correlation hashes | the same ZIP into two spaces produces the same canonical projection (minted ids and the run clock excluded) | covered |

## Phase rules

- **What closes a phase** is a recorded gate: the controller runs the repo's
  verification matrix on the integrated tree, records the commands and their
  results on the ticket, and updates the map. A lane's numbers are claims until
  the controller reproduces them.
- **Evidence is branch-scoped.** A row recorded on an unmerged branch stays
  that branch's until it is reviewed and integrated; a change to a shared
  adapter requires re-running the affected platform rows.
- **Vocabulary.** Rows are recorded with the differential contract's words:
  `run`, `pass`, `fail`, `not-run`, `notCompared`, `policy-rejected`, plus
  `deferral` with an owner for capabilities deliberately outside v1. A green
  workflow promotes nothing on its own.
- **Parallel work.** The batch loop runs lanes beside a phase. A lane may
  prepare a later phase's work; it may not claim it, and it must not make an
  earlier gate's recorded evidence stale.

## v1 capability scope

### The rule

v1 = the rows the operator's used sources reach ∪ the rows existing tickets
already commit to, **minus the deferrals this decision ratifies**. A deferral
here overrides an earlier ticket's scope for v1 (for example, #22's XPath and
#33's fonts stay open but their rows are not v1 requirements). A row is "in v1"
when it has an owner (an existing ticket, or a ticket proposed by this decision
and created at batch close); a required row without an owner stays **in scope,
blocked on owner creation** — it is not dropped.

### Counting predicates

The counts below are defined, because presence is not use:

- **present**: the key exists, whatever its value. **empty** means present with
  a blank string; **non-empty** is the default predicate a cell uses unless the
  cell says otherwise. Present-without-non-empty is recorded because several
  rule fields are shipped empty by many sources, and an empty field is not a use.
- **literal token**: the string occurs in the record's string values. Cells
  report how many records contain it and, where useful, how many occurrences.
  Token counts describe call sites, not demonstrated reliance.
- **boolean field**: reported as the count of records whose value is `true`
  (for example `enabledCookieJar`).
- **request-option keys**: a key written inside a rule's `,{...}` options (for
  example `charset`) is observed as a token; the option is not parsed, so the
  count is a token observation unless a row says a key was parsed.

### The used-source set, and its caveats

The set is derived from the operator's Legado backups: the `origin` values of
`bookshelf.json`, resolved against `bookSource.json`. The 2026-09-17 backup
gives 8787 sources, a 1419-book shelf, 192 distinct origins, and **150 origins
that resolve to a source record**; all 150 are text sources
(`bookSourceType` 0), 145 are enabled, 125 carry a group. The counts below are
among those 150.

Caveats, recorded so no later batch treats the list as more than it is:

- the exporting Legado version may differ from the frozen baseline, so the
  export is a **scope and usage input**, never a compatibility oracle;
- the operator has not curated the sources for years, so some of the 150 are
  dead: the set is an **upper bound** of the capabilities in use, not a promise
  that each source works;
- live triage is an observation; the differential contract's frozen goldens
  remain the only compatibility evidence;
- the export itself is private and uncommitted. Both backups live outside this
  public repository, in `D:\GithubRepositories\Android\legado-backups\`:
  `legado-backup-2026-09-17.zip`
  (sha256 `e46452c9b824d41c1333bb58965a7709041c0b46b3fa2ff11372d7b3e4c1abb8`,
  the count input for this section) and `legado-backup-2025-02.zip`
  (sha256 `3d3eec69dd4aa3badf4aa639f4e439a578f682af115f16a9264f7ab87333e17e`).
  The method is written down so the counts can be recomputed from a fresh
  backup.

### In v1 (rows the used sources reach, with their owner)

| Capability row | Owner | Evidence among the 150 (predicate noted in the cell) |
|---|---|---|
| Rule-level JavaScript and templates (`@js:`, `<js>`, `{{js}}`, `@get:`, inline put, `$1`) | #11 | `@js:` 64 records (127 occurrences), `<js>` 66 (134) |
| Search result fields (`ruleSearch.intro`, `lastChapter`, `wordCount`, `checkKeyWord`); content title rule (`ruleContent.title`); `ruleBookInfo.canReName` | **landed (#41)** — every field is extracted and was compared against the frozen golden (`FIELDS-01`: 8 pass / 0 fail / 6 named `notCompared`; the corpus' coverage list names the residual gaps) | non-empty: 59 / 98 / 54 / 45; 2; 2 |
| Book information fields (`ruleBookInfo.wordCount`; `downloadUrls` parsing) | `wordCount` **landed (#41)**, compared through the frozen formatter; `downloadUrls` stays #14 (deferred with the file family, ADR 0011 §2) | non-empty: 52 / 3 |
| Login flow (`loginUrl`, `loginUi`, `loginCheckJs`) | **#59** (the `loginCheckJs` hook, the response surface, the variable members) and **#60** (the `login()` script, the `loginUi` form, the login headers), split from #13 in batch 11 | `loginUrl` 32 non-empty / 79 present (47 empty) — 28 of the 32 are a bare URL/path that defines no `login()`; `loginUi` 5 / 17; `loginCheckJs` 9 / 20 |
| TOC formatting and markers (`ruleToc.updateTime`, `isVolume`, `isVip`, `isPay`) | #13 (what remains after the batch-11 split) | non-empty: 12 / 9 / 3 / 1 (`preUpdateJs`/`formatJs` are empty in every source that has them — deferrals) |
| `bookUrlPattern` | **#61** (split from #13 in batch 11) | 36 non-empty / 82 present (46 empty) |
| Source variables (`getVariable`/`setVariable`; the `variable` field is unused) | **#59** for the members (the check scripts use them); the `variable` field itself has 0 non-empty among the 150 — recorded as not required, not a v1 row | `getVariable` 5 records (9 occurrences), `setVariable` 3 (5) |
| Local `jsLib` shared scope; remote `jsLib` stays with the ticket | #13 | 3 non-empty |
| User replace rules on TOC titles and content | #17 | 129 rules in the backup: 13 enabled, 46 regex, 1 title-only |
| `charset` in request options; non-UTF-8 response decoding | **landed (#42)** — the option, `escape`, and the frozen decode order over `liber_text`; the corpus does not establish universal charset parity and one `escape` platform seam is recorded | 42 records contain the `charset` token (a token observation — the option is written inside the request rule and is not parsed; `escape` appears in none) |
| Per-source concurrency and `concurrentRate` | **landed (#42)** — the frozen source-keyed limiter around every source request; the product's pagination is sequential, so the frozen multi-URL `nextTocUrl` branch stays unexercised (recorded) | `concurrentRate` 2 non-empty / 15 present; `java.ajax(` 39 records (61 occurrences) |
| `enabledCookieJar` parity (storage is ADR 0011 §3) | **landed (#42)** — the flag decides whether a response's `Set-Cookie` reaches the jar; one recorded divergence: the frozen session/persistent split does not survive a restart | 76 records declare `true` (boolean) |
| `java` multi-URL `ajax`/`ajaxAll`, header-string `connect`, `source.getHeaderMap` | **landed (#43)** — source-derived Windows tests plus the host gate, not a frozen-device result; `source.getHeaderMap(true)` belongs to #60 | 1 record each (token) |
| `book` binding and chapter variables | `book`/`chapter` read-only snapshots and named refusals **landed (#43)**; the `*Variable` members still refuse by name and have no used-source call site — **no owner, a re-triage candidate** | — (no source-visible count) |
| `toNumChapter` Chinese numerals | **landed (#43)** (fullwidth and Chinese numerals, the frozen shorthand, invalid `-1`, signed-Int overflow) | 3 records (token) |
| JSONPath filters and slices | **#44** (batch 11) | not counted separately |
| The JSON pipeline reaching the shelf and the reader (not merely `ruleBookInfo.init`) | #29 | — |
| Multi-URL page results and image styling (`imageStyle`) | #14 | `imageStyle` 28 non-empty / 35 present; multi-URL results not independently counted |
| WebView request path (`webView`, `webViewDelayTime`) | **landed on Windows and Android (#55)** — the Windows destination rows and the Android oracle/adapter sweep; the five-platform aggregate and Linux/macOS/iOS stay `not-run` (#56) | 18 records mention `webView` (token); `ruleContent.webJs` is present in 12 and empty in all of them |
| User-confirmed browser and captcha hatches (`startBrowser*`, `getVerificationCode`, `openUrl`) | #32 — its WebView dependency (#55) is satisfied; the members still refuse by name | 3 / 2 |
| TLS per-source exception on certificate failure | #30 | (policy row: validation default, one confirmation per source and host, the stored exception read by the transport) |
| Named refusals, emulated `androidId`/`getWebViewUA`, bounded logs and toasts | #31 | — |
| Host-surface cleanup on source delete/re-point; a bound on persisted growth | #36 / #37 | — |
| HTML extraction device corpus; request-semantics oracle; four-stage oracle | #23 / #15 / #38 | #15's frozen rows are recorded (`tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json`); the Android destination half waits on P4 |
| libfjs's flaky runtime tests (they protect the CI row every phase cites) | #35 | — |

`explore` (111 of the 150 declare a non-empty `exploreUrl`) stays with #13 but is
**not a v1 gate**: the operator rarely uses the 发现 screen, and a declared field
is not a use.

### Accepted divergences carried with the claim

These do not disappear when a v1 row is claimed; they are recorded against the
affected capability:

- `java.t2s`/`java.s2t` share the audited HanLP/OpenCC tables. ADR 0010's
  table measures the difference from the frozen reader per direction and corpus
  (t2s 0.055 %–0.798 %, s2t 0.021 %–0.078 %), and its revision states the
  reader's conversion deliberately differs while the character-only path Book
  Source rules call stays as it was; 2 of the 150 sources call `java.t2s`
  (13 occurrences). Parity is not claimed.
- **Cookie visibility** (ADR 0011 §3): a source may read, send or delete a cookie
  only for its own site group or one it wrote, so a source that relies on a
  pre-existing cookie another source wrote to a foreign domain stops working.
  The corpus is single-source, so no fixture observes the filter.
- **Cache and `java.put`/`java.get` ownership** (ADR 0011 §3): entries belong to
  the writing source, so the baseline's global key space is not reproduced and a
  source that deliberately shares a cache key with another source breaks.
- **Cross-origin declared `Cookie`** (`lib/source/http_source_transport.dart`,
  the redirect branch): the frozen client forwards a declared `Cookie` to
  another origin; this transport drops it with `Authorization`. #15's corpus
  carries the row.
- The frozen 4 096-character cookie trim and the 600-entry cache LRU are not
  reproduced (ADR 0011 §3).
- `firstCompletesWhileSecondHeld` is `notCompared` for the execution-model
  reason in the differential contract's divergences table.
- TLS trust stays validated by default with a per-source, per-host user exception
  (ADR 0011 §5; #30): a fixture needing the baseline's unconditional trust is
  `policy-rejected` until the user grants the exception for the source under
  test, and no fixture grants one.

Naming a divergence is not a pass: the affected observation stays in the
harness's `notCompared` list and the platform cannot claim the capability it
belongs to (differential contract, Known divergences).

### Deferrals (v1-external, each with an owner)

| Row | Evidence (used set / whole collection; predicate in the cell) | Owner / disposition |
|---|---|---|
| jsoup `:matchText` (a DOM-mutating selector returning pseudo text elements; rejected by name today) | 0 / 0 | #45 (post-v1; the map's follow-up ticket) |
| `@XPath:` rules | 0 / 4 | #22 stays open, not a v1 gate |
| `getQueryTTF` / `replaceFont` font de-obfuscation | 0 / 6 | #33 stays open, v1-external |
| `ruleContent.sourceRegex` | 150: 11 present, **all empty**; 8787: 641 present / 597 empty / 44 non-empty | v1-external inside #14 |
| `ruleToc.preUpdateJs` / `formatJs` | 150: 8 / 1 present, **all empty**; 8787: 162 / 45 present, 29 / 4 non-empty | v1-external inside #13 |
| `coverDecodeJs` | 150: 1 present, **all empty**; 8787: 157 present / 156 empty / 1 non-empty | v1-external inside #13 |
| `ruleContent.imageDecode` | 0 — the key is absent from every used source | v1-external inside #14 |
| `payAction` | 0 among the 150; 29 present across the 8787 | v1-external inside #14 |
| File family (`getFile`, `readFile`, `unzip*`, …) and the file-download machinery | `getFile` 0 / 7; ADR 0011 §2 defers the family | #13/#14; `downloadUrls` parsing itself is in v1 |
| Review rules (`ruleReview`) | 0 / 0 | v1-external; propose moving the review half of #14 out of the v1 claim |
| Non-text sources (`bookSourceType` 1/2/3/4) | 0 used / 361 in the collection | #14 (its scope names non-text source types); ADR 0012 keeps them a separate module after v1 |
| Private shelf and encryption at rest | — | beyond the destination; the data-model seam is #16; encryption stays undecided (ADR 0011) |
| TTS, image/audio sources, review UI, cloud sync, pixel-level UI reproduction, a bundled browser engine, store distribution for the Windows-first phase, bookmarks, reading history, search history and Book Source subscriptions | — | the map's declared deferrals, unchanged |

## Per-platform claims

A platform is claimed only with its own rows (ADR 0002/0009): the shared runtime
gates, the limits rows, and #2's WebView rows for its adapter. This table
separates what exists from what P4 adds:

| Platform | App build row | Shared gates | Limits rows | WebView rows | Device/driven row |
|---|---|---|---|---|---|
| Windows | exists (`flutter build windows --debug`, CI) | exists (`python tool/ci_runtime.py windows x86_64-pc-windows-msvc`, 16 rows) | exists for Windows (`tool/runtime_limits_prototype/verify.py`) | archived pre-split evidence: Windows WebView2 adapter, 14 rows (13 pass, 1 policy-rejected) in `liber-archive`; #2 owns re-establishing the contract | driven runs exist (P1a, P2; P3 proposed) |
| Linux | P4 adds `flutter build linux` to the CI job | exists (CI job runs the shared gate list) | `not-run` — never executed on this platform (the harness is platform-neutral) | #2, WebKitGTK `not-run` | real Linux, or WSL with its distribution recorded |
| macOS | P4 adds `flutter build macos` to the CI job | exists (CI job runs the shared gate list) | `not-run` — never executed on this platform | #2, WKWebView `not-run` | the operator's Mac |
| Android | P4 adds `flutter build apk` to the CI job | no device-side row set today | `not-run` | archived pre-split evidence: Android WebView adapter, 14 rows (13 pass, 1 policy-rejected) in `liber-archive`; #2 owns re-establishing it, and no current-product claim follows | device or AVD |
| iOS | P4 adds `flutter build ios --simulator --no-codesign` to the CI job | no device-side row set today | `not-run` | #2, WKWebView `not-run` | simulator on the Mac |

Three desktop platforms have runtime gate rows today (Windows, Linux, macOS);
Windows is the only **integrated application**. Until a platform's four row
families exist, claims stay narrower and say so — build and launch rows alone
are a shell claim, not a compatibility claim.

## The device prerequisite

The physical device the recorded goldens came from is attached (`adb devices`
shows `5615f742`, a Redmi myron on Android 17, fingerprint
`Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys`), and
the three tickets that waited on it produced their goldens on it in 2026-09-18/19:
#38 (the four-stage golden), #23 with its 39-row refresh (#51), and #15
(`tool/nested_oracle/evidence/android-17-os4.0.0.31/` carries all of them, each
manifest pinning the device, the corpus and the harness). What remains of those
rows is their Android *destination* half, which waits on P4 (the product has no
Android application). When the handset is not attached — `adb devices` empty even
after `adb kill-server && adb start-server` — a lane asks the controller and
waits rather than improvising. The fallback of building an AVD (JDK 17, a system
image, then the frozen debug APK built from `D:\GithubRepositories\Android\legado`
at `14dd24945`, signed with the same debug keystore the oracle instrumentation
requires) was declined by the operator and stays declined: it would need the
fingerprint and WebView version recorded in the golden's manifest, and it could
not produce the other platforms' adapter rows. #2 keeps its own
acceptance and provenance requirements for all five adapters.

## Ratified from the practice so far, and what changes

Ratified, because it is what produced the current state and it still holds:
Windows-first; capability slices in the order their ADRs were settled; decision
tickets before the slices they bind; device-backed rows `not-run` with their
blocker named; a green workflow promotes nothing; evidence is branch-scoped
until integrated; the controller re-runs the headline numbers.

Changed by this decision: the claim-versus-work rule is now written down; P1
splits into destination and frozen checkpoints; the v1 scope is anchored to the
used-source evidence instead of "the matrix minus the tickets"; the device
prerequisite becomes an executable ticket rather than an absence; P6 exists;
per-platform claims name their row families; WSL is recorded as an acceptable
but weaker Linux row when a real machine is unavailable; no P4 work starts in
this session.

## Alternatives considered, with costs

| Alternative | Why not | Cost had it been chosen |
|---|---|---|
| The ticket's listed order, five-platform shell second | it multiplies the surface by five before the Windows product's non-source half is evidenced, and the mobile rows are device-blocked today | slower feedback, a stalled shell, no machine for the desktop driven rows |
| Merging P2 and P3 | the two phases answer to different specifications (ADR 0006/0007 versus the migration contract) with different fixture sets | one blurry gate, and the migration contract's 12 families lose their named home |
| P5 as the differential contract's absolute "frozen-baseline complete" | unbounded: it would require capabilities outside the operator's 150-source used set (`:matchText`, review rules, the font de-obfuscation family, non-text sources) | v1 never closes |
| Calling the P5 claim "baseline-complete" without the qualification | the contract's verdict aggregation forbids shortening a narrower result into an unqualified compatibility claim | an unfounded compatibility claim |
| Hard gating: no work on a phase before the previous gate is green | the route stalls on one device and on machine availability, and it contradicts how the slices actually landed | months of idle implementation capacity |
| AVD only, never the physical device | the recorded goldens came from a real device; a different emulator WebView version makes comparison provenance weaker, and an AVD still cannot produce the other adapters' rows | weaker provenance for the golden |
| WSL as a full Linux platform claim | WSL is Linux on Windows: acceptable for a launch smoke with the environment recorded, not for a clean-system or WebKitGTK row | a claim that would not survive a real Linux machine |
| Folding P6 into P5 | mixes product work with compatibility claims | the compatibility claim's status would depend on UI work |

## Follow-ups proposed to the controller

Bodies are in the resolution comment on #8; this document names them so the
route can reference them:

- a device-prerequisite ticket (blocking #38, #15, #23);
- the P6 product ticket (multi-source search, precise search, switch-source);
- a search/book-information result-fields ticket (`ruleSearch.intro`/
  `lastChapter`/`wordCount`/`checkKeyWord`, `ruleBookInfo.wordCount` and
  `canReName`, `ruleContent.title`);
- the v1 rows without owners: request-layer gaps (`charset`/`escape`, non-UTF-8
  decoding, per-source concurrency/rate limit, `enabledCookieJar` parity),
  host-surface gaps (`ajaxAll`, header-string `connect`, `getHeaderMap`, `book`
  binding, chapter variables, `toNumChapter` Chinese numerals), and JSONPath
  filters/slices;
- a `:matchText` ticket, v1-external;
- the migration-contract families that are still uncovered (P3's own work), and
  the move of #14's review half out of the v1 claim;
- **standing-instruction follow-ups for the controller**: `README.md`'s
  Verification and evidence section (or `AGENTS.md`'s batch loop) should cite
  this document as the phase/claim ladder, so a batch's close-out checks the
  right gate. This session does not edit those files.
