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

Version 2 converts every compared value with `String(...)` before any `===`
comparison: the frozen document, attribute and `getVariable` results reach a script
as Java-backed Strings, so `x === ''` does not hold on them until they are explicit
JS primitives. The corpus therefore measures the variable lifecycle *after* that
conversion — the declared writes and reads of `source.*`, `book.*` and `chapter.*`.
Interop between native-returned values and strict equality is not measured here; it
stays with #137, and nothing here accepts or rejects a difference on it. Version 1
had a real device capture whose comparison rows are preserved; its own observation
ids, requests and responses are unchanged in version 2.

## Corpus shape

| Item | Value |
|---|---|
| fixture id | `STATE-SESSION-01`, corpus version 2 |
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

The preference probe is how that routing is proved, not assumed: the seed requires
the probe name to be absent on both sides, writes it once through the application
context, keeps it in the owned set and never deletes it there; the restart only
reads the namespace the seed recorded. A pre-existing probe is refused rather than
overwritten or removed.

One start-up path reaches storage before the binding, and only on a background
thread: the frozen application's own providers ask for preferences before
`Instrumentation.onCreate`, and Firebase performance's `DeviceCacheManager` makes
that call from its thread pool. Such a callback waits, bounded, for the binding and
then uses the same scoped store; it is never handed an unverified handle and it is
never silently allowed. A callback on the main thread refuses immediately instead of
waiting, because the binder itself starts from a main-looper post and waiting there
would deadlock start-up. A binding failure releases every waiter with that failure,
and a timeout refuses with a visible message; nothing is retried. Every other storage
callback that would write — a database create or delete — is refused before the phase
binds the root. The owned-name manifest is published atomically under the same lock,
so two registrations that arrive at once cannot drop each other's name.

The phase's own cleanup receipt is not a claim about the process's exit. The frozen
provider can still write into the retained root after the restart's removal and
before it is torn down, so the final cleanliness check belongs to the controller and
runs after the target is force-stopped and confirmed to have no PID: it inspects the
already-authorized scratch root, removes the authorized residue it finds there, and
independently verifies that the root and every owner-listed preference file and
`.xml.bak` are gone. Those receipts are recorded beside the capture
(`<capture>/device-cleanup-verification.json` and `<capture>/post-stop-scratch-residue.txt`),
and the native report only states what the phase itself measured.

## What counts as a complete phase

A phase passes only when the actual request trace and the actual observation ids are
exactly the declared ones, in order, without duplicates, with no request that
matched no declared response and no replay-server error; and when the cleanup
receipt verifies what it claims: the database and the replay server both confirmed
closed, and either every owned preference fenced and the root retained (seed) or
every owned preference and the root removed (restart). A cleanup that cannot verify
those keeps the run a failure even when the stages themselves succeeded. A timeout
still uses the same BASE64 report channel and names the stage it stalled in.

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

## Product side (consumer)

`runner.dart` runs one phase through the product and `compare.dart` drives the two
terminated Dart processes, compares their actual reports with the controller's raw
captures and runs the negative controls:

```bash
dart run tool/state_session/compare.dart \
  --capture=<controller/state-capture-03> \
  --evidence=<state-product> \
  --library=<this worktree's cargo-built fjs.dll> \
  [--handoff=<controller/state-session-handoff.json>]
```

The seed is a fresh `Workspace` root: two real searches through
`openBookSourcePipeline`, then each corpus book's `details` (info plus TOC) and its
publication through `ShelfService.add` in the corpus order, then the five content
reads through carriers rebuilt from the stored rows. It records books, chapters and
`source_entries`, writes `owner.json` and retains the root. The restart is a second
process over that root: it validates `owner.json` before opening the database, reads
the persisted state, refreshes A1/B1 with the revision-2 responses through
`ShelfService.updateCatalog`, reads the state after the refresh and removes the whole
root. The product's isolation surface is the workspace root (`manifest.json` and
`spaces/default/data.db`); unlike the frozen capture it has no task-prefixed
preference files outside that root, and the report says so instead of implying one.

`java.put`/`java.get` stay outside the 26 frozen observation ids. The runner checks
the approved per-source `v_<sourceKey>_<key>` rows with declared policy-only keys: a
source reads only its own key, `source.get` sees the same row, and the restart reads
what the seed wrote. That receipt is `javaPolicy` in each phase report.

The comparator refuses a capture of another fixture, corpus, baseline, target,
harness, phase or process pairing, a product report whose `status` is not
`completed`, and a restart receipt that names another retained root or owner; it
requires the exact declared request trace — including the exact raw query bytes
retained by the frozen `stageTrace[i].path` and each product request's `rawQuery`,
never re-derived from the decoded members — the exact ordered observation ids and
complete setup/cleanup receipts, and it fails on a changed value or any unexpected,
missing or reordered request. A missing or inconsistent frozen `stageTrace` carrier is
refused, and a missing or non-string product `rawQuery` fails; neither falls back to an
empty query. Valid variable JSON is compared semantically while the raw column is
retained; a null raw column, valid JSON text (member order ignored), invalid or empty
text, and a missing raw key stay distinct observations, and any member-order or
indentation difference is reported in `rawTextDifferences` rather than normalised.
The nine negative controls mutate copies of the raw captures and of the product reports
(value, request, identity, receipts and the three raw-query order/encoding/absence
cases), record each failing exit and its intended surface, and re-hash the immutable
originals after the run. Evidence lives in
`<evidence>/comparison.json`, `<evidence>/negative-controls.json` and the two phase
reports beside them. The corpus' `policyRows` and `coverageGaps` stay listed as
`notCompared`; nothing here closes a row, a ticket or a platform claim.

## Selected reference (corpus version 3, #146)

`fixtures-selected.json` is the same case graph bound to the selected
compatibility reference `a7d37f1707a70a459ad708f4fe79341d1e42d716`
(`LegadoTeam/legado` release `3.26101819`) and the same-source instrumentable
build `com.legado.app.debug` whose APK SHA-256 is
`593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5`. Every
source, response, book, step, declared request, policy row and coverage gap is
the version-2 one; only the identity fields and the two blocks below differ.
Version 2 and its goldens keep their `14dd2494`/`cc99040c` identity and are
neither relabelled nor overwritten.

Two things the selected reference needs are declared by the corpus rather than
assumed by the harness:

- `hostInitialization` — the corpus names `io.legado.app.App#initRhino()`, the
  nine host wrapper factories it registers and the scratch-only storage rule.
  After the phase binds the root and the routing check passes, the harness
  creates an unattached `io.legado.app.App`, invokes that exact private method,
  re-reads the wrapper registry and refuses unless it is exactly the declared
  set, compared by factory identity. `App.onCreate`, `attachBaseContext`,
  default-data seeding, logging, cronet pre-download, monitors and schedulers
  never run. The receipt is the report's `hostInitialization` block, and both
  comparators refuse a capture of this corpus that lacks a verified one.
- `getChapterListAwait` gained `isFromBookInfo` (`WebBook.kt:297-302`). The
  harness resolves the suspend declaration by name prefix and accepted arity,
  passes `false` — the historical value — and records what it resolved in
  `entryPoints`.

Run either phase against the selected reference with the dedicated
`SelectedStateSessionOracle` entry (which fixes the selected corpus and target);
the historical entry remains bound to the historical target and corpus. The
rest of the sequence, the forced stop between the two lifetimes and the
`STATE_SESSION_ORACLE_BASE64` report channel are unchanged:

```bash
adb -s <serial> shell am instrument -w -r -e phase seed -e corpus selected \
  io.liber.oracle.nested/io.liber.oracle.nested.SelectedStateSessionOracle
adb -s <serial> shell am force-stop com.legado.app.debug
adb -s <serial> shell am instrument -w -r -e phase restart -e corpus selected \
  io.liber.oracle.nested/io.liber.oracle.nested.SelectedStateSessionOracle
adb -s <serial> shell am force-stop com.legado.app.debug
```

The product side selects the same corpus with `--corpus=`, which is passed on to
the phase runner and to the negative controls:

```bash
dart run tool/state_session/compare.dart --corpus=tool/state_session/fixtures-selected.json \
  --capture=<controller/selected-capture> --evidence=<state-product> \
  --library=<this worktree's cargo-built fjs.dll>
```

Without `--corpus=` the product commands read `fixtures.json` exactly as before. A
prepared corpus is not runtime evidence: the selected-reference phase pair has
not been executed, and no version-3 golden exists.
