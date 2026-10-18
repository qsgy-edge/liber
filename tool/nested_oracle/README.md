# Nested / frozen oracle harness

Calls the installed, hash-pinned frozen `io.legado.app.debug` APK by reflection
from an instrumentation entry. No Legado production class is rebuilt. The
harness builds the corpora into its assets and serves each request from an
in-process replay server, so a run is deterministic and offline.

## Build

```powershell
pwsh tool/nested_oracle/build.ps1 `
  -OutputDirectory <fresh-dir> `
  -JavaHome <jdk-17> `
  -AndroidSdk C:/Users/17945/AppData/Local/Android/Sdk
```

A JDK 17 is required (`InputStream.readAllBytes`); the repository's default
`JAVA_HOME` is a JDK 8 and cannot compile the harness. On this machine an
already-installed Temurin 17 lives at
`C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8` (the Android Studio
JBR, `C:/Users/17945/AppData/Local/Programs/Android Studio/jbr`, is JDK 21 and
also works). `apksigner` output is not byte-stable between builds, so the APK
hash is pinned per build in the accompanying manifest.

## Desktop comparators (`tool/nested_oracle_compare.dart`)

| Mode | Command | What it does |
|---|---|---|
| default JS oracle | `<fjs.dll> <golden.json> <new-result.json>` | Runs `tool/nested_oracle/fixtures.json` against the product and compares with a frozen golden. Unchanged. |
| request semantics | `--requests <fjs.dll> <golden.json> <new-report.json>` | Runs `request-fixtures.json`. Unchanged. |
| local jsLib record | `--jslib-record <fjs.dll> <new-capture.json>` | Runs `jslib-fixtures.json` against the product and writes a **product-only** capture labelled `comparison: not-run`. No golden exists on this machine, so none is claimed. |
| local jsLib compare | `--jslib <fjs.dll> <golden.json> <new-report.json>` | Runs the same corpus and compares with a **frozen device golden**. |

The default JS oracle, the request oracle and the jsLib modes all observe
through the same replay server and evaluation loop, so a corpus is the only
difference between them.

### Fail-closed rules for `--jslib`

`--jslib` refuses to compare (a `FormatException`, non-zero exit, no report
written) when any of these is not a genuine match:

- the corpus is missing, malformed or has no rows;
- the golden names another `fixtureId`, `corpusVersion`, `baselineCommit` or
  `entryPoint`;
- the golden's `corpusSha256` is not the SHA-256 of the corpus bytes with CRLF
  normalized to LF (so a stale or edited corpus is rejected);
- the golden has no `provenance` block of `kind: frozen-device-capture` with a
  non-empty device fingerprint and capture time (a product-only record capture
  is rejected by its `mode`/`comparison` marker);
- the golden's row count or row identity does not match the corpus, or the
  golden holds no observations or no request trace;
- the product records a different number of rows.

A value or request-trace difference is reported as `status: fail` with both
sides, never as a pass. There is no empty or vacuous pass: an empty golden and a
short product run are both hard refusals.

## Local `jsLib` shared scope (corpus `JSLIB-01`)

`tool/nested_oracle/jslib-fixtures.json` is the dedicated corpus for the local
`jsLib` shared-scope family (#74, the P5 gap "Local `jsLib` shared scope"). It
uses the same `AnalyzeUrl.evalJS` entry point and the same corpus shape as the
default JS oracle, so it is served by the same harness.

The expectations in its `sourceDerivedNotes` are **read from the frozen source
at `14dd24945b2914ce2708b8abaa4ee67ceef892af`**, not an executed golden:

- `SharedJsScope.kt` caches one scope per `MD5(jsLib)`, seals it, and reuses it
  for every source carrying that `jsLib`;
- `AnalyzeUrl.evalJS` gives each evaluation fresh bindings and sets
  `bindings.prototype = sharedScope`, so an evaluation can shadow a library name
  without mutating it, while a function defined in `jsLib` resolves names
  through the shared scope only (never the per-eval bindings).

The corpus covers shared state across repeated evaluations, nested evaluations
and a second source, plus binding/local isolation. `--jslib-record` was run on
Windows against the read-only `fjs.dll`; it is product-only evidence and its
comparison is explicitly `not-run`.

## Device resume runbook (not run by the preparation lane)

A phone is required for the frozen golden. With the handset attached:

```bash
adb -s <serial> install -r -t <fresh-dir>/nested-oracle.apk
adb -s <serial> shell am instrument -w -r \
  -e corpus jslib \
  io.liber.oracle.nested/io.liber.oracle.nested.NestedOracle
adb -s <serial> pull \
  /sdcard/Android/data/io.legado.app.debug/files/jslib-oracle.json <golden.json>
```

The `-e corpus jslib` extra is the explicitly named jsLib selection; without it
`NestedOracle` reads `fixtures.json` and writes `nested-oracle.json`, exactly as
before. The pulled `jslib-oracle.json` already carries `fixtureId`,
`corpusVersion`, `corpusSha256` and a `provenance` block, so it is a valid golden
for `--jslib` as-is. Then compare on the host:

```bash
dart run tool/nested_oracle_compare.dart --jslib \
  build/windows/x64/runner/Debug/fjs.dll <golden.json> <report.json>
```

The device fingerprint, APK hash and corpus hash the run must collect are the
ones the comparator checks; record them in the accompanying manifest.
