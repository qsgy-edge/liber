# FIELDS-01 — the remaining result-field frozen oracle (ticket #41)

One controlled corpus for the seven rule fields that ticket #41 implemented but
never executed on the frozen side: `ruleSearch.intro`, `ruleSearch.lastChapter`,
`ruleSearch.wordCount`, `ruleSearch.checkKeyWord`, `ruleBookInfo.wordCount`,
`ruleBookInfo.canReName` and `ruleContent.title`.

It is deliberately **separate** from SLICE-01 (`tool/first_slice/`): its own
fixture, its own replay port, its own disposable harness package id
(`io.liber.oracle.fields`) and its own evidence directory. Nothing here reads or
rewrites SLICE-01's corpus, golden or comparison, and `tool/nested_oracle/`,
`tool/replace_rule_oracle/`, `tool/html_oracle/` and `tool/first_slice/fixtures.json`
are untouched.

## Files

- `fixtures.json` — the corpus (`FIELDS-01`): five four-stage cases with their
  own Book Source and replay responses, five `checkKeyWord` cases, the global
  response table, the declared request sequence, and the frozen-source blob
  pins. Its bytes are the compared input; changing them needs a new corpus
  version and a new golden.
- `FieldOracle.java` — the frozen side: drives the real
  `io.legado.app.model.webBook.WebBook.searchBookAwait/getBookInfoAwait/getChapterListAwait/getContentAwait`
  by reflection against the installed, hash-pinned `io.legado.app.debug`, serves
  the corpus inside the device process, and observes
  `io.legado.app.data.entities.BookSource.getCheckKeyword`. It writes its report
  after every case, so a host that freezes the process keeps the finished cases.
- `AndroidManifest.xml`, `build.ps1` — the disposable APK, package
  `io.liber.oracle.fields` (instrumentation entry
  `io.liber.oracle.fields.FieldOracle`).
- `capture.py` — installs the APK once, instruments it, pulls the report, and
  writes `golden.json` + `manifest.json`. `--finalize` re-runs only the
  validation over a report a device run already produced.
- `evidence/` — the executed golden, its manifest, and the raw device logs.

## The corpus

Four-stage cases (`cases`), each one search → book information → table of
contents → content:

| Case | What it observes |
|---|---|
| `html-rename-permitted` | `ruleBookInfo.canReName` non-blank, so the detail page replaces the search title and author; two search results, the second exercising the non-numeric `wordCount` passthrough |
| `html-rename-absent` | `canReName` absent: the search title and author survive, while a nonempty detail `wordCount` still replaces the search one |
| `html-blank-rename-empty-author` | `canReName` blank (`"   "`) and an empty search author: the title survives and the empty author is filled from the detail page |
| `html-content-title-blank` | a blank `ruleContent.title` rule leaves the chapter title as the table of contents gave it |
| `json-fields` | the same rows through JSON rules (`$.…` against a JSON response body) |

`checkKeyWord` cases are observed without any request, through the frozen
`BookSource.getCheckKeyword(default)`: `declared` (non-blank wins), `blank` and
`absent` (the caller's fallback wins), and the two non-string values `number`
and `object`.

Observed per case: the search results' `name`/`author`/`intro`/`lastChapter`/
`wordCount`, the detail `name`/`author`/`wordCount`, and the chapter's effective
`title` (the content title replaced it, or the table of contents' own name
stayed) plus its text.

## FIELDS-02 selected corpus (preparation, not native acceptance)

`book-url-markers-fixtures.json` selects a separate `FIELDS-02` corpus with
`--fixture`/`-CorpusPath`. It covers the HTML `bookUrlPattern` match after a
redirect, a JSON nonmatching pattern through a real list, the no-pattern
empty-list information fallback, and a declared nonmatching-pattern empty-search
terminal. The default build and every FIELDS-01 command remain the original
corpus and comparison shape.

The selected native report is a `cases` ARRAY. The product report is a
`caseRecords` ARRAY. `capture.py` and `result_field_compare.dart` reject missing,
duplicate, extra, wrong-type or incomplete observations independently on each
side. Native `chapter.url` is compared with product `address`; native
`chapter.absoluteUrl` with product `url`; provenance fields stay separate. The
product's legacy `infoHtml` claim is not compared.

Selected builds embed `assets/field-provenance.json` alongside the fixed
`field-fixtures.json`: actual corpus raw/LF/byte measurements and hashes of the
seven same-build inputs (`FieldOracle.java`, `StateSessionOracle.java`,
`HostRuntimeInit.java`, `ShortcutStartupGuard.java`, `AndroidManifest.xml`,
`build.ps1`, `capture.py`). New captures require all seven measured hashes.
`capture.py` inspects the
actual `--apk` zip before installation and binds the embedded fixture/provenance
to the selected fixture and measured source bytes; a matching loose `--asset` is
not enough. The Dart comparator inspects the same APK with `archive`, and joins
the embedded provenance to the capture manifest. Re-finalization requires the original selected APK (`--apk`), independently
inspects its unique embedded assets, and joins the source map recorded with that
APK. Historical five-input artifacts remain admissible only with their original
APK and recorded map; partial inventories and unrelated names are rejected.
Finalization never substitutes today's source hashes. The build source-consistency
check runs again after packaging/signing and verifies the embedded corpus and
provenance bytes. The Dart comparator also counts raw ZIP central-directory
entries before using the archive decoder.

Selection validates the supported family, strict integer version, case array,
unique nonempty IDs, keyword/source/terminal types before installation and
native scratch Application creation. Selected capture adds a storage-only Application over the existing
`StateSessionOracle.ScratchContext`. It refuses a preexisting scratch root,
field preference inventory, harness package or target process; it never
pre-cleans or wildcard-removes. The report and owner are read while the owned
process is alive, then routing/package/artifact/family/version, typed positive
`seedPid`, nonempty attempt and equal safe preference inventories containing the
probe are checked before any stop. A failed case after a genuinely bound/fenced
scratch still publishes its owner facts so cleanup can remove that known run;
golden promotion still refuses it. PID queries distinguish proven empty absence,
one matching owned PID and failed/ambiguous transport. Only the exact verified paths plus the owned scratch root are removed with
quoted single remote scripts; absence is verified before the harness uninstall.
A different, unreadable or ambiguous process/owner and every failed command
leave state in place. The preference caller passes the unscoped helper suffix
`probe`, so the helper's actual scoped name is `liber_fields_02_probe`.

FIELDS-02 records actual per-case operation facts (`search`, `bookInfo`,
`tableOfContents`, `content`; empty search records only `search`) with the
completed/error outcome and request/trace spans around each awaited call. Native
TOC semantic `Result` decoding completes inside the observed operation; a
returned failure is an error operation, not a completed one. Trace stages inside
each operation span must agree with that operation; cached/zero-request and
nested product diagnostics remain valid. Both
consumers require the declared terminal, contiguous case/global request and
trace ranges, typed indices and legal producer stage labels; cached zero-request
operations and real redirects/nested diagnostics are admitted. The native
report's `cases` and the product report's `caseRecords` remain separate shapes.

FIELDS-02 snapshots the complete target data directory as typed `F`/`D`/`U`
records whose paths are UTF-8 hex-encoded, so LF/TAB-bearing names cannot forge
records; the parser decodes the hex framing, requires the producer's `./` root,
and refuses noncanonical/control-bearing paths. Every enumeration/hash/format
failure propagates, digests and paths are unique, unsupported nodes are refused,
and only the verified owned removal may change the private tree. The artifact/provenance admission checks
every integer carrier and preservation fact, the approved harness package, and
the exact duplicate-free preference inventory containing the probe.

FIELDS-02 golden/report/manifest bytes are immutable once present: a conflicting
report is refused before work; a failed finalize writes `finalize-failure.json`
without rewriting the accepted artifacts; byte-identical validated reuse does
not rewrite them. The legacy FIELDS-01 finalize/regeneration scope is unchanged.

```
pwsh tool/result_field_oracle/build.ps1 -OutputDirectory <fresh dir> \
  -JavaHome <jdk 17> -CorpusPath tool/result_field_oracle/book-url-markers-fixtures.json
python tool/result_field_oracle/capture.py --serial <serial> \
  --apk <fresh dir>/field-oracle.apk --frozen-source <legado checkout> \
  --fixture tool/result_field_oracle/book-url-markers-fixtures.json \
  --asset <fresh dir>/assets/field-fixtures.json --output <fresh dir in evidence/>
dart run tool/result_field_replay.dart <matching fjs.dll> \
  --fixture tool/result_field_oracle/book-url-markers-fixtures.json --out <fresh report>
dart run tool/result_field_compare.dart --fixture tool/result_field_oracle/book-url-markers-fixtures.json \
  --library <matching fjs.dll> --harness-apk <fresh dir>/field-oracle.apk \
  --product-source-root . <golden.json> <liber.json> <comparison.json>
```

The historical FIELDS-02 product preparation emitted **14** requests against the
**12** declared requests (A and C each fetched information twice). That was a
product result, not a native execution or rewritten declaration. It is not a
claim about a later product revision.

### Fixed selected reference for #138

`book-url-markers-fixtures-selected.json` is a separate new-reference copy of
the same four inputs and twelve requests. It pins Legado commit `a7d37f1`,
package `com.legado.app.debug`, APK `593cc00c…`, and the approved OS4.0.6.0
handset fingerprint. The historical FIELDS-02 corpus, five/seven-source maps,
original APK bindings and FIELDS-01 defaults retain their old identities. The
selected APK additionally measures the guarded Application, selected host
bridge and selected manifest; its source map has exactly ten entries.

Build and inspect off-device without contacting a handset (use fresh output
paths; JDK 17.0.20+8 and Android SDK build-tools 35.0.1/android-35):

```text
pwsh -NoProfile -File tool/result_field_oracle/build.ps1 -OutputDirectory <build> \
  -JavaHome <jdk17> -CorpusPath tool/result_field_oracle/book-url-markers-fixtures-selected.json
python tool/result_field_oracle/capture.py --preflight-only \
  --fixture tool/result_field_oracle/book-url-markers-fixtures-selected.json \
  --apk <build>/field-oracle.apk --target-apk <approved-reference-apk> \
  --frozen-source <a7-checkout> --java-home <jdk17> --android-sdk <sdk> --output <fresh-preflight>
```

The preflight joins the raw corpus, source/tree, target and harness APKs,
manifest, signer, DEX and current public four-stage ABI; it does not create a
golden.

The WebView environment is profile-exact. Both the live capture and the retained
command admission require exactly one `Current WebView package (name, version)`
line naming `com.google.android.webview` with the version that profile runs on:
`159.0.8154.4` for the title-lifecycle corpus and `158.0.8127.2` for every other
selected corpus, whose retained evidence was captured on it. The version comes
from the fixture's own profile, never from a request flag or from a packet's
self-declared value. An available-provider mention is not a current-provider
line; a missing, duplicated, other-provider or other-version current line is
refused, so neither version is admitted for the other profile.

Capture additionally requires the approved serial `5615f742`, the same
preflight arguments and `--asset <build>/assets/field-fixtures.json`; it refuses
preexisting state and binds the typed snapshots, exact owned cleanup and raw
commands. Selected offline-finalize failure receipts are append-only: the first
uses `finalize-failure.json`; later failures use distinct UUID-suffixed names and
the chosen path is reported on stderr. A selected comparison delegates physical
admission to this collector's read-only `--verify-bundle` mode, which reruns the
off-device preflight and reconciles its inputs with the retained command ledger,
owner-derived cleanup and typed snapshots. Verification writes only to a fresh
separate output directory; it never writes a golden or contacts a handset.
Timed-out and nonzero preflight commands retain their attempted command, status
and available raw streams in derived failure evidence without retry. A selected comparison requires
the actual native bundle and its raw receipts: a prepared APK or synthetic
mechanics result is not native evidence.

**The selected four-case native capture and native comparison remain NOT-RUN.**
The controller alone owns the handset capture and any evidence-backed product
repairs.

### Opt-in root installation

Use `--root-install` only for live selected title capture on handset `5615f742`
with existing root access. The flag is refused before any device action in
`--preflight-only`, `--finalize`, and `--verify-bundle` modes, for legacy and
ordinary selected corpora, and for every other serial.

The switch keeps the whole default path unchanged: the same preflight (signed
artifact, source/target/WebView identity, package absence, scratch/preference
absence, private snapshot) runs first, and only the one install command differs.

| Shape | Command | Byte binding |
|---|---|---|
| default | `adb -s 5615f742 install -r <built apk>` | the APK path |
| root | `adb -s 5615f742 shell -T "su -c 'pm install --user 0 -r -S <length>'"` | the APK bytes on stdin |

The root transport sends the exact built APK bytes from Python on the child's
stdin, with no TTY and no text pipe, and asks the device only for
`pm install --user 0 -r`. The command carries no other text, name or path, and
`su` is never asked for another helper, package, setting or shell.

A live opt-in invocation authorizes and sends one owned **checked snapshot**: the
built harness is read once, the copy is created exclusively at
`<capture>/harness-snapshot.apk`, and that copy is what the preflight's ZIP,
manifest, signer and DEX reads inspect (the raw records name that path). The
in-memory buffer is bound to the digest that successful signed preflight
measured, the snapshot is compared with the buffer and digest again immediately
before launch, and a missing, malformed or changed binding fails closed with
zero sends. The external build path is never re-read after the snapshot. The
default install keeps its byte-for-byte path, and the installed readback is
still required.

The recorded `install` receipt for the root shape adds the `stdin` byte length
and SHA-256, an explicit completion, an outcome, and the SHA-256 of each raw
stream; the default receipt keeps exactly its original
`{command, exitCode, log}` shape, so every retained bundle stays valid.

A returned root result is classified only from its own exit and streams: a zero
exit with the exact success streams is a confirmed success; a nonzero exit whose
single terminal `Failure [REASON]` line is the only output on one stream is a
determinate Package Manager refusal, and only that case may take the existing
read-only package state check. Every other returned outcome, including a
transport failure and contradictory zero output, keeps its actual integer exit
and both streams with completion unknown and sends no later device command (no
retry, fallback, probe, instrumentation or cleanup). Timeout and host
interruption keep the known command, the supplied stdin binding and whatever
streams exist, with no fabricated exit or transfer length. The default path is
unchanged.

Admission accepts exactly one of the two shapes and never a hybrid: the default
command with a stdin record, the root command without one, an edited command, a
different `-S` length, a stdin length that differs from the pulled APK, a stdin
digest that differs from the measured artifact, or a root receipt without
`installCompletion: complete` and `outcome: success` is refused. The root shape
is admitted only for the selected title
profile, and the exact size and digest join the preflight artifact to the pulled
`installed-harness.apk` byte identity, the bundle's own
`harness-snapshot.apk` copy, the original owner-only cleanup and the private
before/after equality. Retained root evidence keeps the combined `install.log`
and the two raw `install.stdout.log`/`install.stderr.log` streams: admission
requires the recorded stream digests to match those files and the combined log
to equal their composition, and it applies the root-only success check (exactly
one `Success` stdout line and no stderr output) to the raw streams. The six
root-only auxiliary rows are pinned to their one real invocation and to exactly
the producer's `{command, exitCode, log}` keys, so a second install, another
privileged command or a mixed receipt cannot masquerade there. For selected title
bundles with root artifacts, `--finalize` rejects duplicate manifest keys just
as `--verify-bundle` does. The default finalization parser is unchanged. Neither
an unknown-completion nor a refused receipt can qualify a bundle. The root transport
is non-incremental and does not pass the `idsig` to the installer; offline
artifact verification still includes the `idsig`.

### Reader follow-through selected corpus

`reader-followthrough-fixtures-selected.json` is a separate FIELDS-02/version 1
corpus for ordinary title/body ordering and plain introductions. It has exactly
three cases and fourteen declared GETs:

| Case | What it observes |
|---|---|
| `html-body-replace-title-order` | Two serial HTML content pages. The body script writes `seenHtml`, the joined-content replacement rewrites it, and the title reads it plus the first-page `.chapter-title` marker; the second page has a distinct marker. Search declares a normal markup intro; information declares a blank intro rule so the incoming search intro is retained. |
| `json-body-title-order` | Two serial JSON content pages through simple ASCII root-property reads. The body writes `seenJson` and the title reads it plus the first-page `$.title`; the second page has a distinct title. Search declares a plain intro; information declares a blank intro rule so the incoming search intro is retained. No `replaceRegex` is declared. |
| `html-order-control` | One static HTML content page whose body, replacement and title are independent of source state. Content and both introductions carry literal escaped line breaks. |

The corpus pins the reached selected `BookList.kt`, `BookInfo.kt`,
`BookContent.kt` and `HtmlFormatter.kt` Git blobs in addition to the existing
reached dependencies. Its target APK, package, fingerprint and initialization
are the fixed selected-reference values above. The source map distinguishes Git
blob SHA-1 from the CRLF checkout bytes the preflight hashes separately.

A source rule map that declares `ruleSearch.intro` or `ruleBookInfo.intro`
(including an empty rule) requires a correctly typed `intro` string at that
stage on both the native and product records. The comparator rejects a missing
or wrong-typed field on either side and compares present values strictly. A
corpus that does not declare the key keeps its old record shape and comparison;
the admission rejects an undeclared `intro` field rather than treating it as an
optional observation. Search-empty terminals remain governed by their actual
empty result list.

```text
pwsh -NoProfile -File tool/result_field_oracle/build.ps1 -OutputDirectory <build> \
  -JavaHome <jdk17> -CorpusPath tool/result_field_oracle/reader-followthrough-fixtures-selected.json
python tool/result_field_oracle/capture.py --preflight-only \
  --fixture tool/result_field_oracle/reader-followthrough-fixtures-selected.json \
  --apk <build>/field-oracle.apk --target-apk <approved-reference-apk> \
  --frozen-source <a7-checkout> --java-home <jdk17> --android-sdk <sdk> --output <fresh-preflight>
dart run tool/result_field_replay.dart <matching fjs.dll> \
  --fixture tool/result_field_oracle/reader-followthrough-fixtures-selected.json --out <fresh report>
```

The selected corpus hash is part of the existing fixed selected-corpus identity
gates in `capture.py` and `result_field_compare.dart`; the four earlier selected
corpora keep their exact hashes. The corpus and its `.gitattributes` LF entry
are the only new input. Native capture and the Windows reader remain
controller-owned and not-run.

### Title lifecycle selected corpus

`reader-title-lifecycle-fixtures-selected.json` is a separate FIELDS-02/version 1
corpus for the approved ordinary title-error disposition and the saved chapter
name. It has exactly four cases and eighteen declared GETs:

| Case | Terminal | What it observes |
|---|---|---|
| `html-title-error-body-retained` | `four-stage` | One HTML content page whose `ruleContent.title` script throws. The selected content stage catches the title error and completes with the incoming TOC chapter name and the readable body. |
| `json-title-error-body-retained` | `four-stage` | The same throwing title script over a JSON source using simple ASCII property reads. |
| `html-title-saved-refresh` | `four-stage-refresh` | Two non-volume chapters seeded with distinct raw variable text through the reference DAO; the first chapter's content is saved with `needSave=true`, then a real `getChapterListAwait` refresh runs and the refreshed list is published through the reference DAO insert `BookInfoViewModel` uses. |
| `json-title-saved-refresh` | `four-stage-refresh` | The same saved-row and refresh sequence over a JSON source using simple ASCII property reads. |

The `four-stage-refresh` terminal is the only one that carries
`titleLifecycle`, and it is the only one whose operation span has five entries
(`search`, `bookInfo`, `tableOfContents`, `content`, `tableOfContents` again).
The old `four-stage` terminal keeps exactly four operations, and a record that
carries `titleLifecycle` under any other terminal is refused.

`titleLifecycle` is the shared observation only: the four ordered phases
`beforeContent`, `storedAfterContent`, `refreshedChapters` and
`storedAfterRefresh`, each an ordered list of
`{index:int, title:string, variable:string|null}` rows read from the real
chapter objects or the reference chapter DAO — never copied from the seed or
from an in-memory title assignment. A missing field is named before the
extra-field check, so a missing `variable` is never reported as a shape error,
and null stays distinct from missing. The shared object is exactly those four
phases; containment, files, preference and guard facts are not shared product
requirements and are refused there.

The native-only `titleLifecycleProof` carries the actual producer evidence for
the saved case:

| Field | Actual relationship |
|---|---|
| `bookParent` | `{bookUrl, stored, readBack}`; the URL is this case's `bookInfo.bookUrl`. |
| `chapterSeed` | `{rows, inserted}`; two seeded rows, consistent with the case's chapter observations. |
| `saveObserver` | `{tag, interface, declaringClass, onMain, registered}`; the public `Observable` registration acknowledged on MAIN. |
| `tocCountWordsApplied` | `{name, applied, committed, observed}`; the real `tocCountWords=true` application. |
| `saveEvent` | The counted first-end terminal: exactly one correlated event, every invalid counter zero, the actual MAIN removal acknowledgement and the case's book/first-chapter raw URL. |
| `saveObserverClose` | The cached repeat of that terminal with `alreadyClosed:true` and `removed:true`; it must agree with the first close. |
| `contentFiles` | Sorted unique safe basenames enumerated under the proven `BookHelp` cache root; never absolute paths or traversal text. |
| `tocCountWords` | The restoration receipt including the actual prior Boolean; `observedAfter` must equal that prior value. A present-false prior stays false; an absent prior must read back the real `getBoolean(KEY, true)` default `true`, never `false`. |

The process guard is a report cleanup fact, not a per-case receipt. The corpus
requires `cleanup.savedContentGuard = {release, fence, receipt}` once: the
release removes every owned receiver and lifecycle callback, leaves no pending
work or removal failure, and reports `closed:true` while `armed:true`; the MAIN
fence is posted and completed; the receipt carries the actual
`LebIpcReceiver`/`ACTION_LEB_IPC`/3-arg/flags-2 and
`AppUtils$ActivityLifecycleImpl` registration and removal observations, empty
inbound/failure arrays, zero blocked/foreign/callback/error counts, and a closed
observer. `saveEvents` is the latest per-case count, not a run total, and the
final `lastEvent` joins the last saved case. The successful selected profile
requires the final `release.observerClose` map to be empty because both case
observers already closed; a nonempty cached terminal is refused.

The title startup is contained by two report facts. `startupContainment` is the
shared ReaderProvider shortcut containment every selected corpus carries.
`firebaseStartupIsolation` is the title corpus' own fact: the frozen target
starts `FirebaseInitProvider` before the harness binds its scratch, and that
provider's synchronous options read (`FirebaseInitProvider.onCreate` →
`FirebaseApp.initializeApp` → `FirebaseOptions.fromResource` →
`StringResourceValueReader.<init>` → `Context.getResources`) is the only resource
read the title scratch refuses, because resolving it there is what queues the
Play Services measurement registration this harness rejects. The fact is exactly
`{provider: com.google.firebase.provider.FirebaseInitProvider, intercepted: 1,
handled: true, beforeBinding: true}`: one owned marker issued on the MAIN thread
before the binding, consumed once by the instrumentation exception seam. It is
taken immediately after the scratch binds and emitted from that same receipt, so
it is required before the application guard, `BookHelp` and the writable Room
open, and before host initialisation, the database and the replay server. An
absent, malformed or non-exact fact is refused by both live finalization and
offline verification. Every other resource read, every other Firebase caller,
and a non-title selected corpus' report, exception handling and public output
are unchanged; a corpus without the lifecycle observation may not carry the
fact. The focused controls run the production scratch/bridge bytes against
android-35: the exact read, a plain resource read, an unrelated caller, the
ordinary scratch, a genuine foreign-owner marker, forged/wrapped/unknown/duplicate
acknowledgements and the later, second, off-main and late/off-main acknowledgement
phases (`FirebaseStartupIsolationHostTest`), plus the real admission for a valid
proof, each absent/malformed/non-exact variant and an ordinary corpus that cannot
claim it (`FirebaseStartupIsolationAdmissionTest`). `TitleBindingOrderTest` drives
the real `bindScratch` over a bound scratch and proves the missing proof fails
before the guard arm, `BookHelp` or the Room open, while the positive emits the
one receipt taken at that boundary.

The selected runtime also joins `isolation.earlyContainment` to the measured
target-private root: the guarded application identity and base-context binding;
`filesPath` is `<root>/files`; `databasePath` is
`<root>/databases/legado.db`; `externalFilesPath` is
`<root>/external-files` (the generic `ContextExtensions` files fallback cannot
produce this selected bound route because `ScratchContext` always returns a
non-null external-files directory and the producer requires
`canonicalExternal` to equal it); the BookHelp cache is
`<root>/external-files/book_cache`; and the Room path equals the admitted
scratch database path. The release receiver/lifecycle counts must
equal the admitted registration and removal inventories, not merely be equal
positive numbers. The old `four-stage` terminal keeps exactly four operations,
and a record that carries `titleLifecycle` or `titleLifecycleProof` under any
other terminal is refused.

The producer proves each of those routes before it publishes it: it queries the
actual application directories, the native BookHelp cache and the real Room
writable handle, and requires each canonical path to equal the corresponding
scratch route's canonical form. The external route always requires canonical
containment. The files and database routes keep that equality for every corpus;
the title-lifecycle corpus additionally requires them to be canonically
contained in the scratch root, so neither is accepted merely because it is equal
to its own scratch route while canonicalizing outside the root. The BookHelp
cache and the Room handle are proven against their exact scratch routes, with
canonical containment, in that same title-lifecycle corpus. The title-lifecycle
corpus then emits the proven route in the bound scratch's own absolute
coordinate — the coordinate the measured `run-as` root, the ordinary isolation,
the owner receipt and the cleanup already use — so one corpus has a single path
coordinate. A corpus without the lifecycle observation keeps its canonical
serialization and its original files/database equality checks. For the
title-lifecycle corpus, a canonical escape, an external-files fallback, a
sibling or traversal route, a different BookHelp directory and a different Room
database are all refused before any receipt is published. A title-lifecycle
refusal records the observed canonical route and, when measured, the expected
canonical scratch route for the affected storage; an out-of-root external
observation records the expected route as unmeasured. The proven absolute
values are published only in the successful receipt.

The saved pair re-reads its own table of contents, so the same path appears
twice in the declared sequence. The replay server serves a path's declared
responses in declaration order only when a corpus declares more than one for
that method and path; a corpus with one response per path keeps the original
single answer, so every earlier corpus is unchanged.

The corpus pins twenty reached Git blobs: the previous sixteen plus the
`BookDao.kt`, `AppDatabase.kt`, `EventBusExtensions.kt` and `EventBus.kt` sources
the saved-row and event-guard path reaches. The target APK, package, fingerprint
and initialization are the fixed selected-reference values above.

The current producer's retained preflight has an exact profile-owned plan: the
eleven base command receipts, then one `target-abi-<dex>` receipt for each
target DEX file that actually declares a reflected class in first-use order
(twenty target-ABI commands for this target, including the candidate DEX files
that were disassembled while locating a definition), then one `reflected-abi`
summary that is not a subprocess. The title corpus admits exactly that plan;
the historical eleven-row plan remains exact for its own ordinary profile, and
neither plan is converted into the other. The summary and top-level
`reflectedAbi` reconcile the same sorted DEX inventory, the thirty-eight
target descriptor/accessibility checks (including the chapter-list DAO, Room
open-helper/path chain, Pair, Observer, entity getters and CacheManager) and
the thirty harness bridge/guard/scratch-context/FieldOracle checks. Missing,
non-public or non-static required methods are refused; the required and actual
access flags are tokenized, so a declared `public static` requirement rejects an
instance-only declaration.

```text
pwsh -NoProfile -File tool/result_field_oracle/build.ps1 -OutputDirectory <build>   -JavaHome <jdk17> -CorpusPath tool/result_field_oracle/reader-title-lifecycle-fixtures-selected.json
python tool/result_field_oracle/capture.py --preflight-only   --fixture tool/result_field_oracle/reader-title-lifecycle-fixtures-selected.json   --apk <build>/field-oracle.apk --target-apk <approved-reference-apk>   --frozen-source <a7-checkout> --java-home <jdk17> --android-sdk <sdk> --output <fresh-preflight>
```

The lifecycle cases invoke the reference `WebBook` entry points and the
reference chapter DAO directly. They are not a driven native reader UI and they
publish no reader screen. The product side of this corpus is not implemented
yet, so a public comparison of it is expected to stop at the missing product
`titleLifecycle` until the approved reader/shelf/store slice lands.

## Destination side

```
dart run tool/result_field_replay.dart <fjs library>
```

writes `evidence/windows-fields-01.liber.json` and fails when the corpus shape is
broken (an undeclared request, a request sequence other than the declared one, or
a case that did not reach all four stages). `test/result_field_corpus_test.dart`
runs the same corpus inside `flutter test test`, so every desktop CI job executes
it.

## Frozen side

```
pwsh tool/result_field_oracle/build.ps1 -OutputDirectory <fresh dir> -JavaHome <jdk 17>
MSYS_NO_PATHCONV=1 python tool/result_field_oracle/capture.py \
  --serial <serial> --apk <fresh dir>/field-oracle.apk \
  --frozen-source <legado checkout> --output <fresh dir in evidence/>
```

`build.ps1` refuses to build when the corpus asset copy differs from
`fixtures.json`; `capture.py` refuses to run when the frozen checkout's HEAD or
any pinned frozen-source blob differs from `fixtures.json`, when the device
fingerprint or the installed baseline APK differs from the pinned values, when
the harness package already exists, when the frozen report disagrees with the
corpus, or when the frozen application's own store (`databases/legado.db*`,
`shared_prefs/local.xml`) changed. MIUI asks the operator to confirm each
install; the first two attempts on this handset were rejected with
`INSTALL_FAILED_USER_RESTRICTED` before the operator confirmed the third.

`capture.py --finalize --apk <original build>/field-oracle.apk --asset <build
dir>/assets/field-fixtures.json` re-runs report, typed-snapshot and original-APK
validation over an evidence directory that already holds the pulled report and
its snapshots. It does not read current build-source hashes for historical
promotion; missing original APK refuses explicitly.

## The comparison

```
rm -f tool/result_field_oracle/evidence/android-17-os4.0.0.31/comparison.json
dart run tool/result_field_compare.dart \
  tool/result_field_oracle/evidence/android-17-os4.0.0.31/golden.json \
  tool/result_field_oracle/evidence/windows-fields-01.liber.json \
  tool/result_field_oracle/evidence/android-17-os4.0.0.31/comparison.json
```

Rows `C1` (the corpus ran identically on both sides) and `F1`–`F7` (one per
field). A row passes only when both sides observed the same thing; an unequal
observation is a `fail` with the divergence named, and an observation one side
does not carry is named in `notCompared` with its reason.

**Executed result: 8 pass / 0 fail / 6 notCompared** (the comparator exits 0).
Every row matches; the two observations that needed a word are:

- `F4 ruleSearch.checkKeyWord`. The field is a *check* keyword: the frozen
  readers of it are the source check and the debug page's search box, and the
  search stage never reads it — the product now matches that, because
  `HtmlSourcePipeline.search()` no longer validates the field. Its frozen
  semantics are the parse layer's: `SearchRule.checkKeyWord` is a `String?` read
  by Gson, so a JSON scalar becomes its literal text while the source is parsed
  (`42` → `"42"` — the executed golden's `checkKeyword.number`) and only an
  array or object is refused. `sourceCheckKeyword` is the one reading point and
  reproduces that: a scalar is its string form, `blank`/absent still fall back
  to the caller's default (`BookSource.kt:208-215`), and a structured value is
  refused by name. The `object` case is therefore refused on both sides, and the
  row records both reasons verbatim.
- Two residuals stay named rather than normalized: the refusal happens at use
  (`FormatException` with the field name) where the frozen reader refuses while
  parsing (`JsonSyntaxException: Expected a string but was BEGIN_OBJECT`), and a
  non-canonical number literal loses its spelling — Gson keeps the source text
  (`1e3`, `1.50`), this product's `jsonDecode` sees `1000.0`, `1.5`. Reopen the
  second one only if a used source declares such a literal.
- Everything else matches byte for byte, including the frozen
  `StringUtils.wordCountFormat` rendering (`12001` → `1.2万字`, `23000` →
  `2.3万字`, `约12万字` unchanged) and the `canReName` gate in all four of its
  shapes.

The F4 fix was approved by the controller after this lane reported the frozen
line and a minimal repro; the golden and the harness evidence are unchanged by
it, and only the product side was re-run to reach 8/0/6.

## Coverage gaps

Named, not hidden:

- The `HtmlFormatter.format` entity/tag branches: the corpus' intros carry no
  entity or tag, so the formatter's replacement is a no-op on both sides. #41's
  unit fixture executes that expression; this corpus observes extraction and the
  formatter's application.
- `ruleContent.title` where a **non-blank** rule extracts a blank value: the
  corpus declares a blank rule (the frozen `titleRule.isNullOrBlank()` branch),
  not a rule that yields blank.
- 10000/10001 word-count boundaries and negative or zero values.
- The frozen chapter-persistence side effect of a non-blank `ruleContent.title`
  for the FIELDS-01 corpus (`getContentAwait` runs with `needSave=false` there).
  The separate `reader-title-lifecycle-fixtures-selected.json` corpus observes
  that side effect with `needSave=true` and reads the stored rows back.
- No cookie, pagination, redirect, non-2xx, POST, WebView, XPath, rule-level
  JavaScript or replace-rule row: those belong to #15, #2, #11, #22 and #17.
