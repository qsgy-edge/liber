# Frozen reader-processing oracle (#17)

`ReaderOracle.java` is a disposable instrumentation entry into the installed,
hash-pinned frozen APK. It calls the actual `ContentProcessor.getContent` with
`includeTitle=false`, `BookChapter.getDisplayTitle`, and the processor's real Room
`ReplaceRuleDao` selection path. No Legado class is copied or rebuilt.

**Current evidence: executed and compared.** On serial `5615f742` the disposable
harness installed as `io.liber.oracle.replace`, ran once, and returned all 15
rows from the real frozen reader; storage isolation held (`cache/liber-replace-17`
removed, the installed app's private hash list unchanged) and the harness was
uninstalled. The frozen golden is `554bfade…`. The strict comparator against the
product reports **13 pass / 0 fail / 2 notCompared** (`timeout`, `refusal`), with
every other observed field — title, selection, effective rules, disabled rules,
duplicate-title flag — equal on every row.

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

Use a fresh output directory, the approved JDK and Android SDK, and an exclusively
approved handset with the operator available to confirm the install prompt. The
debug certificate must match the baseline APK. Build follows
`tool/nested_oracle/build.ps1` without changing that harness:

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

```powershell
dart run tool/replace_rule_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll `
  C:/Temp/replace-17-capture/golden.json C:/Temp/replace-17-comparison.json
# A dash explicitly requests product-only capture; all frozen rows stay not-run.
dart run tool/replace_rule_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll `
  - C:/Temp/replace-17-product-only.json
flutter test test/replace_rule_fixture_test.dart test/replace_rule_oracle_compare_test.dart
```

Comparator exits: 0 = compared with no undeclared failures (declared policy gaps
can remain); 1 = a mismatch/error; 2 = missing frozen evidence; 64 = usage error.
`complete` requires all rows to pass; a timeout policy gap prevents promotion.
Invalid identities, row order/count, hashes, boundaries or cleanup are rejected.
Synthetic test values verify comparator mechanics only and never form a golden.

## Per-row evidence

The committed `evidence/comparison.json` is the strict result of this run:

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
#17 remains open; #47, settings, local offset mapping, #49's separate oracle, #54
and WebView gates are outside this work.
