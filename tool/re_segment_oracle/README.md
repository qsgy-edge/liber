# reSegment oracle (host JVM)

The frozen paragraph re-segmentation is `ContentHelp.reSegment`
(`ContentHelp.kt:17-79`) with the helpers it is inseparable from
(`reduceLength`, `splitQuote`, `forceSplit`, `findNewLines`, `makeDict`,
`seekIndexs`, `seekLast`, `seekIndex`, `match`). Nothing in it names an Android
type, so the frozen class runs on a desktop JVM; that is how
`evidence/jvm-host/golden.json` was produced.

This is **not** the four-stage device oracle. The frozen side of the
differential contract is a golden produced by the hash-pinned frozen APK on a
device (`tool/first_slice/`, `tool/nested_oracle/`). Here the frozen bytes are
executed in the host JVM instead, which is enough for a pure transform but is
recorded as a host-JVM source execution, not a device golden. The Android
content-processing entry that would run `ContentProcessor.getContent` inside the
frozen process belongs to **#38** and the row is `not-run` until it exists.

Files:

- `fixtures.json` — the inputs. Each case names the chapter title, the body, and
  whether the book's own `reSegment` flag is on. `enabled-observed-shape` is the
  21-of-1419 shape named on #17: a book whose `readConfig.reSegment` is on;
  `disabled-observed-shape` is the same body with the flag off.
- `ReSegmentOracle.kt` — the harness: reads `fixtures.json`, calls the frozen
  `ContentHelp.reSegment` for every enabled case, and writes `golden.json`. A
  case whose two runs differ (because `forceSplit` used `Math.random()`) is
  refused, so a committed golden is deterministic.
- `run_golden.sh` — compiles the frozen `ContentHelp.kt` and the harness with the
  Gradle cache's Kotlin compiler and Gson, then runs the harness. No `kotlinc`
  is on `PATH` here, which is why the jars are resolved from
  `~/.gradle/caches/modules-2`.
- `evidence/jvm-host/golden.json` and `manifest.json` — the result and its
  provenance (frozen revision, `ContentHelp.kt` sha1, toolchain versions).

Reproduce:

```
bash tool/re_segment_oracle/run_golden.sh
```

`test/content_re_segment_differential_test.dart` compares the product's ported
transform against this golden in `flutter test test`; the random branch is out
of its scope by construction (the harness refuses those cases) and is tested
with a seeded generator instead.
