# toNumChapter oracle (host JVM)

The frozen rule-script member `java.toNumChapter` is
`JsExtensions.kt:905-913`: `AppPattern.titleNumPattern` = `(第)(.+?)(章)` over
the script's own string, then `StringUtils.stringToInt` on the captured numeral
(`StringUtils.kt:209-218`, which folds full-width characters, strips whitespace,
tries `Integer.parseInt` and otherwise runs `chineseNumToInt`).

`JsExtensions.kt` names Rhino, `AppConfig` and Android types, so it cannot be
compiled on a desktop JVM; `AppPattern.kt` and `StringUtils.kt` can, and are
compiled from the frozen bytes by `run_golden.sh`. The member's eight-line body
is **transcribed** into `ToNumChapterOracle.kt` and the run refuses to write a
golden unless the frozen file still contains that body
(`requireTranscription`), so the transcription cannot drift silently.

This is **not** the four-stage device oracle. The frozen side of the contract is
a golden produced by the hash-pinned frozen APK on a device. Here the frozen
bytes are executed in the host JVM instead, which is enough for a pure member
but is recorded as a host-JVM source execution, not a device golden. The Android
row stays `not-run`; `evidence/jvm-host/manifest.json` states the same.

Files:

- `fixtures.json` — the corpus. Each case names one input and the frozen branch
  it reaches; the golden holds the answer, not the note.
- `ToNumChapterOracle.kt` — the harness: calls the frozen
  `AppPattern.titleNumPattern` and `StringUtils.stringToInt` for every case,
  runs each case twice and refuses a case whose two runs differ, verifies the
  transcribed body against the frozen file, and writes `golden.json`.
- `FrozenDebugStub.kt` — the frozen `Throwable.printOnDebug` (`LogUtils.kt:139`)
  is `if (BuildConfig.DEBUG) printStackTrace()`, and `BuildConfig` is generated
  by the Android build. The stub supplies the release behaviour: no output.
  Debug logs and stack traces are not compatibility surfaces.
- `run_golden.sh` — resolves the Kotlin compiler, `kotlin-stdlib`,
  `kotlin-reflect` and Gson from the Gradle cache (no `kotlinc` is on `PATH`),
  and the SDK's stub `android.jar` for the **compile** classpath only — the
  frozen `StringUtils.kt` imports `android.text.TextUtils` and
  `android.util.Base64` for functions this corpus never calls, and the stub jar
  makes such a call fail loudly at run time instead of being satisfied by a
  hand-written shim. The script prefers `android-35`
  (`compile_sdk_version = 35` at the frozen revision) and falls back to the
  newest installed platform.
- `evidence/jvm-host/golden.json` and `manifest.json` — the result and its
  provenance (frozen revision, source sha1s, toolchain versions).

Reproduce:

```
bash tool/tonum_chapter_oracle/run_golden.sh
```

`test/to_num_chapter_differential_test.dart` compares the product's
`java.toNumChapter` member against this golden in `flutter test test`, through
the same script-runtime entry a Book Source reaches.

## What this fixture does not cover

- The device golden: the frozen APK's own `java.toNumChapter` in a rule script
  (`not-run`, owned by #38).
- The member's host bindings around it — the `java` object's argument coercion
  and the `null`/`undefined` guard are the product's
  (`lib/source/js_source_runtime.dart`), and the corpus's `null` row pins only
  the frozen side of that pair.
- `StringUtils`'s other members, including the ones whose Android imports the
  stub jar satisfies (`compress`, `decompress`, `wordCountFormat`).
