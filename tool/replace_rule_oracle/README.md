# Frozen reader-processing oracle (#17)

`ReaderOracle.java` is a disposable instrumentation entry into the installed,
hash-pinned frozen APK. It calls the actual `ContentProcessor.getContent` with
`includeTitle=false`, `BookChapter.getDisplayTitle`, and the processor's real Room
`ReplaceRuleDao` selection path. No Legado class is copied or rebuilt.

**Recorded run (2026-09-21): executed and compared.** On serial `5615f742` the
disposable harness installed as `io.liber.oracle.replace`, ran once, and returned
all 15 rows from the real frozen reader; storage isolation held
(`cache/liber-replace-17` removed, the installed app's private hash list
unchanged) and the harness was uninstalled. That run's strict comparator result
against the product is **13 pass / 0 fail / 2 notCompared** (`timeout`,
`refusal`), with every other observed field — title, selection, effective rules,
disabled rules, duplicate-title flag — equal on every row. The counts belong to
that run; no command in this repository re-derives them today.

**Reproducible from this repository today: no part of that comparison.** The
frozen golden is not committed. `capture.py` wrote it (`554bfade…`) into the temp
output directory the manifest names
(`C:/Users/17945/AppData/Local/Temp/liber-17-reader-evidence/device-capture-17-run3/golden.json`);
that directory and the harness APK under `liber-17-reader-build-4/` are gone, and
no golden exists anywhere in this repository. `evidence/comparison.json` is the
comparator's **report** of that run, not a golden: its rows carry that run's
verdicts (`status: pass|notCompared`) where a golden carries the frozen reader's
raw `status: observed` rows, it has no `corpusVersion`/`baselineCommit`/`cleanup`
capture envelope, and its `observations` fields are verdicts, not frozen values.
Passing it as the golden argument is refused by name — the refusal reads *not a
frozen golden: no `corpusVersion` envelope*, because a comparison report is a
result and not an input — instead of being misreported as a fixture mismatch.

`fixtures.json` still carries its pre-run `deviceOracle` block (`status:
not-run`, `owner: #17`, "No golden exists"). It is stale —
`evidence/manifest.json` records the executed comparison on the same handset —
and it stays as it is deliberately: the corpus bytes are bound to the committed
report (see "Committed evidence versus this corpus"), so correcting that prose
needs a new capture, not an edit.

## Boundary and isolation

The comparison observes the **entire returned** `BookContent`: the frozen
`toString()` joins its `textList` with newlines. The harness records both, along
with `sameTitleRemoved` and effective rules. The product side invokes its actual
`ContentProcessing.content` and `displayTitle`. It does not trim, drop blank lines
or compare an inaccessible intermediate value. Selection lists and titles are
compared for every case, including single-scope cases.

The harness supplies a plain `Application` to avoid the frozen `App.onCreate`
background cache maintenance, backup and network jobs. A `ContextWrapper` directs
files and the real Room database to `cache/liber-replace-17/`, and preferences to a
task-prefixed namespace. It verifies the frozen `splitties.appCtx` resolves to the
scratch files/database before opening Room. It creates real frozen entities and
refreshes `ContentProcessor.upReplaceRules` after inserting each row. The original
book names, origins and rules are unchanged. The known paragraph indent is two
ideographic spaces; the harness sets the frozen `ReadBookConfig.paragraphIndent` to
that default before capture. Cleanup closes Room and removes only scratch
storage/preferences. The result is returned through instrumentation stdout,
without writing a report into user storage.

The executed run returned `cleanup {databaseClosed: true, scratchRemoved: true}`,
`failure`/`cleanupFailure` null, and `existingDataHashesUnchanged: true`
(`private-before`/`private-after` hash lists identical). No server, port
forwarding, baseline uninstall, `pm clear`, shell key events or operator input was
used by the harness. The separately installed task harness alone is removed after
capture. `install` uses adb's incremental form (`adb install -r`); this MIUI
handset rejects the streamed `--no-incremental` form as
`INSTALL_FAILED_USER_RESTRICTED` even with USB installation enabled, and it
requires the operator to confirm the on-device install prompt.

## Reproduction

Nothing here re-verifies the recorded comparison: there is no committed golden.
What this repository can run today is the product side and the two test files:

```powershell
# A dash explicitly requests product-only capture; all frozen rows stay not-run.
dart run tool/replace_rule_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll `
  - C:/Temp/replace-17-product-only.json
flutter test test/replace_rule_fixture_test.dart test/replace_rule_oracle_compare_test.dart
```

Re-verification against the frozen reader is a **device re-capture**: build the
harness, capture a fresh golden from the current corpus (`corpusVersion: 1`), and
compare that golden. Use a fresh output directory, the approved JDK and Android
SDK, and an exclusively approved handset with the operator available to confirm
the install prompt. The debug certificate must match the baseline APK. Build
follows `tool/nested_oracle/build.ps1` without changing that harness:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tool/replace_rule_oracle/build.ps1 `
  -OutputDirectory C:/Temp/replace-17-build `
  -JavaHome C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8
python tool/replace_rule_oracle/capture.py --serial 5615f742 `
  --apk C:/Temp/replace-17-build/reader-oracle.apk `
  --frozen-source D:/GithubRepositories/Android/legado `
  --output C:/Temp/replace-17-capture
```

The capture command pins source, fixture, harness APK, installed baseline APK and
fingerprint, saves raw commands/logs, and produces `golden.json` only after every
row is observed and preservation/cleanup checks succeed. It attempts installation
once and records a rejected installation as blocked (exit 2). A device that
returns `INSTALL_FAILED_USER_RESTRICTED` is reported, not retried automatically.
A later re-verification is only re-runnable from the repository if that fresh
`golden.json` is committed with the corpus (the REPLACE-JS-01 oracle commits its
golden under `evidence/`); this corpus has none.

```powershell
dart run tool/replace_rule_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll `
  C:/Temp/replace-17-capture/golden.json C:/Temp/replace-17-comparison.json
```

Comparator exits: 0 = compared with no undeclared failures (declared policy gaps
can remain); 1 = a mismatch/error; 2 = missing frozen evidence; 64 = usage error.
`complete` requires all rows to pass; a timeout policy gap prevents promotion.
Invalid identities, row order/count, hashes, boundaries or cleanup are rejected.
An input that is not a golden — no capture envelope, or rows whose `status` is a
verdict rather than `observed` — is refused with that reason instead of being
attributed to the fixture (the refusal is a thrown `FormatException`, so Dart
exits 255). Synthetic test values verify comparator mechanics only and never
form a golden.

## Committed evidence versus this corpus

The committed report is evidence *for the corpus it names*, and
`test/replace_rule_oracle_compare_test.dart` enforces that: the report's
`fixtureId`, `comparisonBoundary`, `fixtureSha256` and row ids/order must equal
the current `fixtures.json`, so a corpus edit that no report accompanies fails
the suite. It is a **drift guard, not tamper evidence**: a corpus edit plus
a lock-step re-pin of the report's `fixtureSha256` and rows passes it, so the
recorded verdicts still have to be read. That bound is why the stale
`deviceOracle` prose above is not edited in place.

The corpus, golden and product pins this tool compares — `fixtureSha256`
`61983626…`, `goldenSha256` `554bfade…` and the four `lib/source` entries of the
report's `sourceHashes` — are hashes of the CRLF form of their bytes: this tool
directory is not in `.gitattributes`'s `text eol=lf` list the way the other
oracle corpora are, so the same content has two hashes depending on the
checkout. The drift check and `compare.dart`'s own corpus pin hash the corpus
that way, so one pin means the same corpus on an LF checkout and on the Windows
one that produced the evidence.

The rest of the recorded hashes are a mix, each taken from the bytes its
producing tool read: `evidence/comparison.json` (`558aeab8…`, its LF bytes),
`host_surface_gate.log`, `analysis-final.log`, `device-cleanup.log`,
`AndroidManifest.xml`, `capture.py`, `ReaderOracle.java` and the report's own
`compare.dart` entry (`771afede…`) are LF hashes, while `runtime-manifest.json`,
the install/build logs, `build.ps1`, `fixtures.json` and
`test/replace_rule_fixture_test.dart` are hashes of their CRLF form. Those pins
record the run rather than feed it; pinning this directory LF in `.gitattributes`
is what would make the whole set host-stable.

The same report pins the product bytes of its own run (`sourceHashes` and
`librarySha256`). Today's `lib/source/content_processing.dart`,
`java_regex.dart`, `js_source_runtime.dart` and the built `fjs.dll` have moved on
from those values (the report's own comparator entry moves with every edit to
it), so the report describes that revision's comparison, not a comparison of
today's product against the frozen reader.

## Per-row evidence

The committed `evidence/comparison.json` is the strict result of the recorded
2026-09-21 run:

| Case | Frozen | Differential | Residual observation |
|---|---|---|---|
| `no-rules` | observed | pass | Title/content at final boundary |
| `content-only` | observed | pass | Content gating and untouched title |
| `title-only` | observed | pass | Title gating and untouched content |
| `both` | observed | pass | Both processing paths |
| `regex` | observed | pass | Java replacement expansion |
| `literal` | observed | pass | Literal branch |
| `scope-name-origin` | observed | pass | Real DAO name/origin selection |
| `exclude-scope-name-origin` | observed | pass | Real DAO exclusion |
| `ordering` | observed | pass | Order and duplicate sortOrder |
| `duplicated-title` | observed | pass | Duplicate title removal |
| `re-segment-interaction` | observed | pass | Re-segmentation before rules |
| `conversion-t2s` | observed | pass | ADR 0010 dictionary difference attributed |
| `conversion-s2t` | observed | pass | ADR 0010 dictionary difference attributed |
| `timeout` | observed | notCompared; side effects notCompared | Frozen disabled `slow`, injected `name + stack trace`; 210 ms |
| `refusal` | observed | notCompared | Possessive `a*+` and integrated JS both execute on the frozen side |

The `timeout` row **did** trip the frozen deadline on this device and input
(`timeoutObserved: true`, 210 ms): the frozen reader disabled `slow` and put
`item.name + stackTraceStr` into the content. No input was amplified. The
product's approved behavior (disable the rule, keep the text) still differs, so the
row stays an explicit `notCompared`; the frozen restart injection and stack-trace
content remain an ADR 0011 divergence, not a normalized pass. The `refusal` row
keeps the unsupported `a*+` pattern and `@js:result` replacement: the frozen engine
applies both, while the product refuses `a*+` by name and executes the integrated
#49 JavaScript; the recorded difference is the named refusal. ADR 0010 conversion
dictionaries are now observed equal on this corpus's two rows; a new string
difference still fails pending attribution, and the comparator applies no blanket
conversion exception.

The commit for this run implements the frozen final paragraph shaping in the
product content path (`lib/source/content_processing.dart`): the frozen cutset
`code <= 0x20 || '　'`, dropped empty paragraphs, `ReadBookConfig.paragraphIndent`
(two ideographic spaces, constant until a settings ticket owns it), and the
`includeTitle` first-paragraph exception. The Android-8-only `\u00A0` rewrite is
not reproduced because the pinned capture device runs Android 17.

`evidence/manifest.json` pins the fixture, harness source/build APK, installed
baseline APK, frozen source, native library bytes and the raw capture artifacts.
#17 recorded this tool's evidence; #47, settings, local offset mapping, #49's
separate oracle, #54 and WebView gates are outside this work.
