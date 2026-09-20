# Frozen reader-processing oracle (#17)

`ReaderOracle.java` is a disposable instrumentation entry into the installed,
hash-pinned frozen APK. It calls the actual `ContentProcessor.getContent` with
`includeTitle=false`, `BookChapter.getDisplayTitle`, and the processor's real Room
`ReplaceRuleDao` selection path. No Legado class is copied or rebuilt.

**Current evidence: blocked, not completed.** On serial `5615f742`, both the initial
installation and the controller-authorized single retry returned
`INSTALL_FAILED_USER_RESTRICTED: Install canceled by user`. Device operations then
stopped. There is no frozen golden, no executed harness isolation claim, and no
frozen compatibility pass. The APK builds; its runtime remains unverified.
`evidence/comparison.json` contains 15 fresh product observations and 15 explicit
frozen `not-run` verdicts, with timeout's separate `notCompared` policy retained.

## Boundary and isolation

The comparison observes the **entire returned** `BookContent`: the frozen
`toString()` joins its `textList` with newlines. The harness records both, along
with `sameTitleRemoved` and effective rules. The product side invokes its actual
`ContentProcessing.content` and `displayTitle`. It does not add indentation, trim,
drop blank lines or compare an inaccessible intermediate value. Selection lists
and titles are compared for every case, including single-scope cases.

The harness supplies a plain `Application` to avoid the frozen `App.onCreate`
background cache maintenance, backup and network jobs. A `ContextWrapper` directs
files and the real Room database to `cache/liber-replace-17/`, and preferences to a
task-prefixed namespace. It verifies the frozen `splitties.appCtx` resolves to the
scratch files/database before opening Room. It creates real frozen entities and
refreshes `ContentProcessor.upReplaceRules` after inserting each row. The original
book names, origins and rules are unchanged. The known paragraph indent is two
ideographic spaces; conversion settings live in the scoped preferences. Cleanup
closes Room and removes only scratch storage/preferences. The result is returned
through instrumentation stdout, without writing a report into user storage.

This design **has not executed on Android**. `capture.py` compares existing private
file hash lists before/after execution and rejects changed data or incomplete
cleanup. A runtime isolation failure is a blocker, not permission to manipulate
baseline data. No server, port forwarding, baseline uninstall, `pm clear`, shell
key events or operator input is used. The separately installed task harness alone
is removed after capture.

## Reproduction

Use a fresh output directory, the approved JDK and Android SDK, and an exclusively
approved handset. The debug certificate must match the baseline APK. Build follows
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
once and records a rejected installation as blocked (exit 2). It is ready for a
future authorized run; it was **not run against the device in this blocked stage**.
The two recorded install attempts predate this capture script and are documented
separately in `evidence/manifest.json`.

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

All product rows below executed successfully. All frozen rows remain `not-run` for
the same installation blocker; none is a differential pass.

| Case | Frozen | Differential | Residual observation |
|---|---|---|---|
| `no-rules` | not-run | not-run | Title/content at final boundary |
| `content-only` | not-run | not-run | Content gating and untouched title |
| `title-only` | not-run | not-run | Title gating and untouched content |
| `both` | not-run | not-run | Both processing paths |
| `regex` | not-run | not-run | Java replacement expansion |
| `literal` | not-run | not-run | Literal branch |
| `scope-name-origin` | not-run | not-run | Real DAO name/origin selection |
| `exclude-scope-name-origin` | not-run | not-run | Real DAO exclusion |
| `ordering` | not-run | not-run | Order and duplicate sortOrder |
| `duplicated-title` | not-run | not-run | Duplicate title removal |
| `re-segment-interaction` | not-run | not-run | Re-segmentation before rules |
| `conversion-t2s` | not-run | not-run | ADR 0010 remains explicit |
| `conversion-s2t` | not-run | not-run | ADR 0010 remains explicit |
| `timeout` | not-run | not-run; side effects notCompared | Product disabled `slow`; frozen timeout/restart unobserved |
| `refusal` | not-run | not-run | Possessive quantifier refusal; integrated JS executes |

The unchanged 33-`a` timeout input may complete within the frozen 200 ms deadline.
A successful return without a disabled rule does not demonstrate a timeout. The
harness records that gap; it never amplifies the input or claims a restart. Frozen
stack-trace injection/restart and the product's disable/preserve-text policy remain
an ADR 0011 divergence. The refusal row retains the unsupported `a*+` pattern and
`@js:result` replacement; #49's implementation is integrated, so the old blanket
JS-refusal claim was removed. #49's broader frozen JS acceptance is separate.

ADR 0010 conversion dictionaries have accepted measured differences. New exact
string differences still fail pending attribution; the comparator applies no
blanket conversion exception. Product code currently documents omission of the
reader's final paragraph shaping. Only an actual frozen comparison can establish
this corpus's mismatches; product changes require controller approval.

`evidence/manifest.json` pins the current fixture, harness source/build APK,
installed baseline APK, frozen source and native library bytes. It links raw local
validation logs and records limitations. #17 remains open; #47, settings, local
offset mapping, #49's separate oracle, #54 and WebView gates are outside this work.
