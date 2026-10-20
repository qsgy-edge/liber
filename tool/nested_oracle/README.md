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
| local jsLib record | `--jslib-record <fjs.dll> <new-capture.json>` | Runs `jslib-fixtures.json` against the product and writes a **product-only** capture labelled `comparison: not-run`; a record capture is never a golden. |
| local jsLib compare | `--jslib <fjs.dll> <golden.json> <new-report.json>` | Runs the same corpus and compares with a **frozen device golden**; the executed golden is `evidence/android-17-os4.0.4.0/jslib-oracle.json`. |

The default JS oracle, the request oracle and the jsLib modes all observe
through the same replay server and evaluation loop, so a corpus is the only
difference between them.

### Fail-closed rules for `--jslib`

`--jslib` refuses to compare (a `FormatException`, non-zero exit, no report
written) when any of these is not a genuine match:

- the corpus is missing, malformed or has no rows;
- the corpus has no valid frozen target pin (`target.package`,
  `target.apkSha256`, `target.baselineCommit`);
- the golden names another `fixtureId`, `corpusVersion`, `baselineCommit` or
  `entryPoint`;
- the golden's `corpusSha256` is not the SHA-256 of the corpus bytes with CRLF
  normalized to LF (so a stale or edited corpus is rejected);
- the golden has no `provenance` block of `kind: frozen-device-capture`, or its
  duplicated identity fields (`entryPoint`, `baselineCommit`, `targetPackage`,
  `targetApkSha256`) disagree with the corpus, or its `targetApkPath`,
  device fingerprint or capture time is blank (a product-only record capture is
  rejected by its `mode`/`comparison` marker);
- the golden's row count or row identity does not match the corpus, or the
  golden holds no observations or no request trace;
- the product records a different number of rows.

Observations are compared with **semantic JSON equality**: object member order
is ignored (the differential contract's Matching Rules -> Outputs), while array
order and every primitive/string value are exact. A value difference is
reported as `status: fail` with both sides; a request-trace difference as
`status: fail` with `requestsMatch: false` and the product trace. Neither is
ever a pass. There is no empty or vacuous pass: an empty golden and a short
product run are both hard refusals.

## Local `jsLib` shared scope (corpus `JSLIB-01` v2)

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

Shared mutation goes through the mutable object's property (`sharedState.n`)
only. A write to a jsLib **top-level binding** from inside a library function
(for example `sharedCounter += 1`) is a write to the sealed defining scope: the
pinned frozen APK's Rhino `ScriptableObject.putImpl` calls `checkNotSealed` and
throws `msg.modify.sealed`. That is recorded in the corpus'
`potentialDivergences` as a source/bytecode-derived, device-not-run divergence
and is deliberately not a compared row; the product's closure model would allow
the write, and that potential parity discrepancy is reported, not repaired.

The corpus covers shared state across repeated evaluations, nested evaluations
and a second source, plus binding/local isolation. `--jslib-record` was run on
Windows against the read-only `fjs.dll`; it is product-only evidence and its
comparison is explicitly `not-run`.

The resumed handset produced a frozen capture of this corpus on 2026-10-20 (18
observations and 7 requests, fingerprint `OS4.0.4.0.XPMCNXM`). It is committed
verbatim as `evidence/android-17-os4.0.4.0/jslib-oracle.json` and compared with
`--jslib` against the Windows product. The accompanying
`evidence/android-17-os4.0.4.0/jslib-manifest.json` records the target pin, the
harness and corpus bytes, the exact native library (SHA-256), the passing
report, the negative controls and every command receipt. That comparison is
branch-scoped pilot evidence for #136; it does not accept #136's state/session
or policy families and promotes no aggregate status.

## Device capture provenance

The jsLib capture is only a frozen golden after the instrumentation measured and
verified the installed target. The executed capture's record is
`tool/nested_oracle/evidence/android-17-os4.0.4.0/jslib-manifest.json`; a future
capture must collect and record the same:

1. **Producer (harness) APK** — the built `nested-oracle.apk` SHA-256; after
   install, `adb shell pm path io.liber.oracle.nested` and `adb pull` the
   installed APK and re-hash it, or reuse the build manifest hash.
2. **Harness source** — SHA-256 of `NestedOracle.java`, `build.ps1`,
   `AndroidManifest.xml`, `jslib-fixtures.json` and
   `tool/nested_oracle_compare.dart`.
3. **Corpus** — `sha256` and CRLF-normalized `sha256Lf` of
   `tool/nested_oracle/jslib-fixtures.json`; the bundled asset must hash to the
   same value.
4. **Target** — `provenance.targetPackage`, `provenance.targetApkPath` and
   `provenance.targetApkSha256`, measured by the instrumentation from the
   target `ApplicationInfo.sourceDir` and verified against `corpus.target`
   before the capture is labelled frozen. The pinned identity is
   `tool/nested_oracle/evidence/android-17-os4.0.0.31/request-manifest.json`
   (baseline `14dd24945b2914ce2708b8abaa4ee67ceef892af`, package
   `io.legado.app.debug`, APK SHA-256
   `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6`).
5. **Capture** — SHA-256 of the pulled `jslib-oracle.json`.
6. **Instrumentation receipt** — the `am instrument -w -r` output's
   `INSTRUMENTATION_RESULT` / `INSTRUMENTATION_CODE` and the process exit.

## Device resume runbook

A phone is required for the frozen golden. The runbook below was executed for
`JSLIB-01` v2 on 2026-10-20, controller-run against the fingerprint
`Redmi/myron/myron:17/CP2A.260605.016/OS4.0.4.0.XPMCNXM:user/release-keys`; the
preparation lane itself did not run it. With the handset attached:

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
before. In the jsLib mode the instrumentation measures the installed target's
package and APK bytes and refuses (no file, non-zero instrumentation code) when
either disagrees with the corpus pin. The pulled `jslib-oracle.json` carries
`fixtureId`, `corpusVersion`, `corpusSha256` and a verified `provenance` block,
so it is a valid golden for `--jslib` as-is. Then compare on the host:

```bash
dart run tool/nested_oracle_compare.dart --jslib \
  build/windows/x64/runner/Debug/fjs.dll <golden.json> <report.json>
```

The device fingerprint, target APK identity and corpus hash the run must
collect are the ones the comparator checks; record them in the accompanying
manifest. The `fjs.dll` path is whichever native library that run built: the
executed comparison loaded the lane's `cargo build --locked` debug artifact and
records that exact path and SHA-256 in
`evidence/android-17-os4.0.4.0/jslib-manifest.json`.
