# STATE-SESSION-01 — frozen state/session corpus (Spec A #136)

One controlled corpus that compares the frozen `io.legado.app.debug` application's
per-source variables, book and chapter variables, selected entity context, TOC
refresh and genuinely fresh-process restart against the Liber product. It is served
by `tool/nested_oracle/StateSessionOracle.java` on the device and, on the product
side, by the companion consumer lane. This file and `fixtures.json` are the shared
boundary; everything else here is producer evidence.

`fixtures.json` is data, not a golden. Every value the comparison reads is produced
by a rule script the corpus declares and travels a real frozen persistence path;
the notes in `sourceDerivedNotes` are read from the frozen source at
`14dd24945b2914ce2708b8abaa4ee67ceef892af` and are never an expected value.

## Corpus shape

| Item | Value |
|---|---|
| fixture id | `STATE-SESSION-01`, corpus version 1 |
| target pin | `io.legado.app.debug`, APK SHA-256 `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6` |
| baseline | `14dd24945b2914ce2708b8abaa4ee67ceef892af` |
| origin | `http://127.0.0.1:18741` (a busy declared port is a blocker, not an invitation to move it) |
| source A | HTML, two books (`/a/book/1`, `/a/book/2`), jsLib `stateLibA` |
| source B | JSON, one book (`/b/book/1`), jsLib `stateLibB` |
| chapters | A1 two, A2 one, B1 two; every TOC address is absolute, so the raw address and the row key are one string |
| TOC revision 2 | declared only for A1 and B1: `/ch/1` retained, `/ch/2` replaced by `/ch/9`; A2 has no revision 2 |
| responses | 15: 13 seed endpoints plus the two phase-scoped replacement TOCs |

A response is common to both phases unless it carries `"phase": "seed"` or
`"phase": "restart"`. The active set is common plus the current phase, and two
active responses for one selector (method, path, declared query) are a refusal —
there is no precedence between a phase-scoped and a common response.

## Phases

`seed` — one process lifetime: search A, search B, then for each book its details
stage followed by its TOC stage, each published at once, then the five content
reads. 13 requests, 16 observations. The database and replay server are closed, the
owned preference files are fenced, and the scratch root is **retained**.

`restart` — a second process lifetime over the same retained root: the persisted
books, chapters and source cache rows are read back through the frozen DAOs, A1 and
B1 are refreshed through their revision-2 TOC (A2 is never touched), and the
post-refresh rows are read again. 4 requests, 10 observations. The scratch root and
the preference files the seed owned are removed.

Publication is the frozen detail page's own sequence, never a direct row write:
`Book.save()` (`Book.kt:367-373`, call sites `BookInfoViewModel.kt:400,438`) after
details, and `Book.save(); bookChapterDao.delByBook(bookUrl); bookChapterDao.insert(*chapters)`
(`BookInfoViewModel.kt:238,245-246`, `BookChapterDao.kt:35,41`) after the TOC.
`chapters` has a foreign key to `books` (`BookChapter.kt:28-40`), so the order is
not optional.

## What each observation carries

- `search` — the rule results (`name`, `author`, `kind`, `bookUrl`). `kind` is the
  script's own string: it calls the idempotent library initialiser, writes
  `sourceVariable_<key>` and `v_<key>_sTag`, and reads them back.
- `details` — the book's `variable` payload (parsed) and its raw text. The script
  reads `book.getVariable('bkV')` before writing it, so a restart shows the value
  the seed persisted, and writes the observation string under `obs`.
- `toc` — per chapter `url`, `title`, `tag` (the `ruleToc.updateTime` result) and the
  `variable` payload/raw text. Each item's chapter variable starts empty, the
  script records the pre-write read, and only the retained key gets `c`.
- `content` — the content text, a read-only script over book, chapter, source and
  library values. `needSave=false` and no `ruleContent.title`, so no entity is
  mutated by this stage.
- `state` — books, chapters and source cache rows read back through
  `BookDao.getBook`, `BookChapterDao.getChapterList`, `CacheDao.get` and
  `CacheManager`'s own keys. A whole-table key inventory through the frozen Room
  instance is reported beside it as an isolation receipt; it is never a compared
  value.

## Isolation

The harness installs a storage-only `android.app.Application` whose base context
redirects files, cache, databases and preferences into
`<target cacheDir>/liber-state-session-01` plus the preference name prefix
`liber_state_session_01_`. Preference files stay *outside* the scratch root — only
their name is namespaced — which is why the seed records its complete owned name set
in `owner.json` and the restart removes that union. The frozen `App.onCreate` does
not run, so its crash handler, file logging, cronet pre-download, default-data
seeding, freeze monitor and `LiveEventBus` configuration are skipped; the splitties
`AppCtxInitProvider` does run and is what the isolation check measures.

Ordering is part of the protocol: the installed target, the corpus asset and the
harness APK are measured and compared with the corpus pin first, then the phase is
bound (a fresh root for the seed, the validated `owner.json` for the restart), then
`appCtx`'s files/database/preference routing is checked, and only then is the Room
database opened. A seed over an existing root, a restart over an unknown or
mismatched root, and a duplicate or unvalidated marker all refuse and leave what is
there for inspection.

## Capturing it

The controller owns the handset. Build the harness with the repository's portable
JDK 17 and build-tools 35.0.1 (`tool/nested_oracle/build.ps1`), install only the
instrumentation APK, and run two instrumentations separated by a forced stop:

```bash
adb -s <serial> install -r -t <fresh-dir>/nested-oracle.apk
adb -s <serial> shell am instrument -w -r -e phase seed \
  io.liber.oracle.nested/io.liber.oracle.nested.StateSessionOracle
adb -s <serial> shell am force-stop io.legado.app.debug
adb -s <serial> shell am instrument -w -r -e phase restart \
  io.liber.oracle.nested/io.liber.oracle.nested.StateSessionOracle
adb -s <serial> shell am force-stop io.legado.app.debug
```

Each run returns its whole report as `STATE_SESSION_ORACLE_BASE64=<base64 JSON>` on
the instrumentation stream, so no report file can be lost to a cleanup. The report
carries `phase`, `pid`, `runId`, the measured corpus/target/harness hashes, the
actual request trace with the declared one beside it, the ordered observation ids
with the declared list beside them, the phase's isolation receipt and its cleanup
receipt. A seed reports `scratchRetained: true`; only a successful restart reports
`scratchRemoved: true` and the removed preference names.

The corpus is frozen at the controller's handoff. A change to a source, a response,
a script, a step or a declared request needs a new corpus version.
