# REPLACE-JS-01 — the executed frozen `@js:` replacement oracle (ticket #49)

One controlled corpus and one disposable harness for the remaining #49 evidence:
what the installed frozen Legado reader actually does with a replacement rule
whose replacement starts with `@js:`, compared with the product's approved
JavaScript boundary.

It is deliberately **separate** from `tool/replace_rule_oracle/` (ticket #17):
its own fixture, its own package id (`io.liber.oracle.replacejs`), its own
scratch directory and its own evidence directory. Nothing here reads or rewrites
the SLICE-01, FIELDS-01, REQUEST-01, nested or replace-rule corpora, goldens or
comparisons, and none of those tool directories is modified.

## Result

**Executed on serial `5615f742` (Redmi/myron, Android 17): the harness installed
on the first attempt of each run, ran once, returned all 13 rows, and was
uninstalled. The frozen golden is `golden.json` (sha256 `3cb818c8…`, written
LF so the pin and the committed blob are the same bytes). The strict comparator
against the product reports **11 pass / 0 fail / 2 notCompared** — the two
policy rows are the accepted divergences below, not normalized passes.**

```
{"pass": 11, "fail": 0, "notCompared": 2, "not-run": 0}
```

### Two captures

Two sequential device runs were taken. Every observed field is identical except
`elapsedMillis`, which is a wall-clock sample: the runs agree on `content`,
`title`, `selection`, `effectiveRules`, `rulesDisabledByRun` and the timeout
observation (`timeoutObserved: true`) on all 13 rows, and the `js-timeout` row
tripped its 200 ms deadline in both (**208 ms** and **206 ms**). The committed
evidence is the second run, copied verbatim from `observation.json`. The first
run's raw evidence (CRLF, exactly as that run produced it, pins included) is
kept at `C:/Users/17945/.cache/wayfinder/liber-49/device-resume/run1/` — golden
`da6d6ecc…`, manifest `41ac3c94…`. The second run exists because the first
capture's JSON files were written with the host's CRLF; only the host-rendered
line endings changed in the re-run, and the raw device output (the
instrumentation base64 in `instrumentation.log`) is preserved as received.

## What the frozen side does (the inspected control flow)

`ContentProcessor.getContent` (`ContentProcessor.kt:155-176`) and
`BookChapter.getDisplayTitle` (`BookChapter.kt:100-139`) both call
`CharSequence.replace(regex, replacement, timeout)` (`RegexExtensions.kt:23-64`).
That function detects `replacement.startsWith("@js:")` **after** the regex
branch, strips the four-character prefix, and for every match runs

```kotlin
val jsResult = RhinoScriptEngine.run {
    val bindings = ScriptBindings()
    bindings["result"] = matcher.group()
    eval(replacement1, bindings)
}.toString()
matcher.appendReplacement(stringBuffer, Matcher.quoteReplacement(jsResult))
```

so (a) the script is evaluated **once per match**, (b) the complete match is the
only injected name, (c) capture groups must be derived by the script itself, and
(d) the returned text is inserted **literally** — `Matcher.quoteReplacement`
escapes `$` and `\` before `appendReplacement`, so `$1`, `${name}` and `\1` in a
script's return value never expand. The one timeout wrapper
(`handler.postDelayed(timeout)`) covers the whole replacement pass.

Captures stay available because `ScriptBindings` is a Rhino `NativeObject`
prototyped on `initStandardObjects()`: `result.match(...)`, `String.replace`,
`RegExp` and the rest of the standard library all work.

## Files

- `fixtures.json` — the corpus (`REPLACE-JS-01`): 13 rows, the frozen-source
  blob pins, the four operator backup rules carried verbatim, the accepted
  divergences and the coverage gaps. Its bytes are the compared input; changing
  them needs a new corpus version and a new golden.
- `ReplaceJsOracle.java` — the frozen side: reflection into the installed,
  hash-pinned `io.legado.app.debug`, real `ContentProcessor`/`BookChapter` calls,
  rules seeded into a disposable Room database, corpus served as a harness asset.
- `AndroidManifest.xml`, `build.ps1` — the disposable APK, package
  `io.liber.oracle.replacejs` (instrumentation entry
  `io.liber.oracle.replacejs.ReplaceJsOracle`). `build.ps1` refuses to build when
  the corpus asset copy differs from `fixtures.json`.
- `capture.py` — verifies the frozen checkout and the operator backup, installs
  the APK once, instruments it, snapshots the frozen app's private files, and
  writes `golden.json` + `manifest.json`. `--finalize` re-runs only the
  validation over an already-pulled report.
- `compare.dart` — the product side (the real `ContentProcessing` path, no second
  evaluator) and the strict row-by-row comparator.
- `evidence/android-17-os4.0.0.31/` — the executed golden, its manifest, the
  comparison and the raw device logs.

## The corpus

| Row | Rules | What it observes |
|---|---|---|
| `js-returned-text` | one enabled `@js:` rule | returned text on two matches of one content pass |
| `js-title-scope` | one enabled title-scoped `@js:` rule | the same extension on the title path and its non-blank adoption |
| `js-match-and-capture` | `(\d+)字` + a probing script | the complete match as `result`, a capture derived from `result`, and `$1`/`${name}`/`\1` inserted literally |
| `js-binding-surface` | a `typeof` probe | which names the frozen script sees, against the product's facade |
| `js-ordering-with-literal` | literal (order 1) → `@js:` (order 2) → literal (order 3) | rule order across the literal branch and the `@js:` branch |
| `js-literal-branch-prefix` | non-regex rule whose *replacement* is `@js:"X"` | the literal branch never interprets the prefix |
| `js-disabled` | disabled `@js:` rule | `isEnabled = 1` excludes it on both sides |
| `js-error` | `@js:throw new Error("boom")` | content and rule state after a thrown script |
| `backup-rule-1..4` | the four `@js:` rules of the operator backup, as the backup holds them | recorded outcome `disabled; replacement not executed` |
| `js-timeout` | `@js:` busy loop, 200 ms rule deadline | the frozen deadline side effect (runs last) |

`capture.py` re-reads the operator backup
(`D:/GithubRepositories/Android/legado-backups/legado-backup-2026-09-17.zip`,
sha256 `e46452c9…`) and refuses to capture unless the zip, its `replaceRule.json`
entry (sha256 `19bb7f6e…`) and each `backup-rule-N` row's verbatim rule object
match the corpus pins. All four backup rules are `isEnabled: false` in the
backup, so their recorded outcome is the disabled state, not an enabled run.

## Reproduction

```powershell
pwsh -NoProfile -File tool/replace_js_oracle/build.ps1 `
  -OutputDirectory C:/Temp/replace-js-49-build `
  -JavaHome C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8
python tool/replace_js_oracle/capture.py --serial 5615f742 `
  --apk C:/Temp/replace-js-49-build/replace-js-oracle.apk `
  --frozen-source D:/GithubRepositories/Android/legado `
  --output tool/replace_js_oracle/evidence/android-17-os4.0.0.31
```

MIUI asks the operator to confirm the install prompt; `capture.py` makes one
`adb install -r` attempt (the incremental form this handset accepts) and records
a rejection as blocked (exit 2) instead of retrying.

```powershell
dart run tool/replace_js_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll `
  tool/replace_js_oracle/evidence/android-17-os4.0.0.31/golden.json `
  tool/replace_js_oracle/evidence/android-17-os4.0.0.31/comparison.json
# A dash requests product-only capture; all frozen rows stay not-run.
dart run tool/replace_js_oracle/compare.dart build/windows/x64/runner/Debug/fjs.dll - product-only.json
flutter test test/replace_js_corpus_test.dart test/replace_js_oracle_compare_test.dart
```

Comparator exits: 0 = compared with no undeclared failures (declared policy rows
may remain); 1 = a mismatch/error; 2 = missing frozen evidence; 64 = usage error.
`complete` requires every row to pass, so the two policy rows keep it false.
Invalid identities, row order/count, hashes, boundary or cleanup are rejected.
Synthetic test values verify comparator mechanics only and never form a golden.

## Per-row evidence (executed)

| Case | Frozen | Differential | Residual observation |
|---|---|---|---|
| `js-returned-text` | observed | pass | `正文广告开始广告结束。` → `　　正文【已净化】开始【已净化】结束。` on both sides |
| `js-title-scope` | observed | pass | `第1章 开端` → `第[1章] 开端` on both sides; content untouched |
| `js-match-and-capture` | observed | pass | `共[20字\|20\|$1\|${name}\|\1]，另有[300字\|300\|$1\|${name}\|\1]。` on both sides — captures derived by the script, dollar and backslash sequences literal |
| `js-binding-surface` | observed | notCompared | frozen `result=string $1=undefined $name=undefined book=undefined source=undefined java=object sourceKey=undefined`; product `… book=object source=object java=object sourceKey=string` |
| `js-ordering-with-literal` | observed | pass | `甲。` → `乙丁。` on both sides, so both branches ran in `sortOrder` |
| `js-literal-branch-prefix` | observed | pass | `这里有@js:"X"。` on both sides |
| `js-disabled` | observed | pass | selection empty on both sides, content unchanged |
| `js-error` | observed | pass | content unchanged and the rule stays enabled on both sides; product notice `replaceRuleFailed(js-error, js)` (the code and its arguments, the form `compare.dart` records since #72), frozen logs and toasts |
| `backup-rule-1` | observed | pass | `#01 数字标题#JS`, title-scoped, disabled, `disabled; replacement not executed` |
| `backup-rule-2` | observed | pass | `#02 全角字符#JS`, content-scoped, disabled |
| `backup-rule-3` | observed | pass | `#03 其他字符#JS`, content-scoped, disabled |
| `backup-rule-4` | observed | pass | `#04 星号修复#JS`, content-scoped, disabled |
| `js-timeout` | observed | notCompared | the frozen run disabled the rule after **206 ms** and injected `js-timeout` + `RegexTimeoutException: 替换超时,3秒后还未结束将重启应用`; the product kept `　　正文广告。` and reported the timeout |

Every row also compares `title`, `selection` and `rulesDisabledByRun`
(the rules the run itself turned off), so a cross-scope replacement or a
disabled rule cannot hide in an unobserved field.

## Accepted divergences (recorded, not normalized)

1. **Timeout side effect** (`js-timeout`). The frozen reader disables the rule
   and replaces the content with `rule.name + stackTraceStr`
   (`ContentProcessor.kt:169-171`); its handler schedules `appCtx.restart()`
   3 s later while the worker coroutine is still active
   (`RegexExtensions.kt:51-58`). The product reports the rule, disables it for
   the caller and preserves the original text (ADR 0011 / #17). The single
   completed call observes the disable and the injected content, not the
   restart; both sides' exact values are in the comparison, and the corpus
   records the restart as `not-demonstrated`.
2. **Binding breadth** (`js-binding-surface`). The frozen script sees only
   `result` (plus Rhino's own standard globals, which include a `java` object);
   the product evaluates through the approved source script facade, whose
   documented globals also bind `book`, `source` and `sourceKey`. The row records
   both surfaces verbatim.
3. **Error reporting channel** (`js-error`, compared fields equal, status
   `pass`). The frozen reader logs to `AppLog` and toasts; the product reports a
   notice. The harness cannot read `AppLog`, so the compared value is the content
   and the rule state, which are equal.

## Isolation and cleanup

The harness supplies a plain `Application` and a `ContextWrapper` that directs
files, the real Room database and preferences to `cache/liber-replace-js-49/`
and to a `liber_replace_js_49_` preference namespace, and it fails closed unless
the frozen `splitties.appCtx` resolves to that scratch storage. The frozen
`App.onCreate` (its cache maintenance, backup and network jobs) is skipped. The
executed run reported `failure`/`cleanupFailure` null, `cleanup
{databaseClosed: true, scratchRemoved: true}`, identical private-file hash lists
before and after (including `cache/`, which no other harness snapshots) and no
surviving scratch directory. The pulled baseline APK is hashed into the manifest
(`baselineApkSha256`) and then removed before the commit, as the earlier oracles
do; the pin stays. The result is returned through instrumentation stdout; no
report is written into user storage. No server, port forwarding,
baseline uninstall, `pm clear`, shell key event or operator input was used by the
harness, and only the disposable `io.liber.oracle.replacejs` package (and a
`force-stop` of the owned target process) was removed afterwards.

## Coverage gaps

Named, not hidden:

- The four backup rules are disabled in the backup; their **enabled** execution
  is not observed. The corpus carries each rule verbatim so a later ticket can
  seed them enabled, but their long patterns use `\h`, `(?i)` and similar
  Java-only syntax that the product's engine refuses by name.
- The frozen restart is not demonstrated by a single completed call, and the
  product's ADR 0011 sampled-deadline limits still apply to the product side.
- Cancel-during-replacement and the reader's cancellation path are covered by
  `test/content_processing_test.dart`, not by this device corpus.
- No ordinary (non-`@js:`) regex-capture row and no conversion/re-segmentation
  interaction: those are #17's corpus, which this one does not duplicate.
- The corpus uses one book identity and one chapter per row; no per-book
  `useReplaceRule` switch is exercised (the frozen call and the product call both
  pass the frozen text-book default).
