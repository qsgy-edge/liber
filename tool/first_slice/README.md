# First-slice controlled corpus (SLICE-01)

One fixture for the first end-to-end compatibility slice: a synthetic Book
Source, the replay responses a local server answers it with, the scenario, and
the request sequence the scenario declares. The definition it serves is
`docs/compatibility/first-slice.md`; the contract its rows must satisfy is
`docs/compatibility/book-source-differential-contract.md`.

Files:

- `fixtures.json` — the corpus. Its `source` object is a complete Book Source,
  its `responses` are the only bytes the fixture may receive, and its
  `expectedRequests` are the scenario's declared request sequence.
- `runner.dart` — the replay server plus the four-stage run through the product
  pipeline (`HtmlSourcePipeline` over `HttpSourceTransport`).
- `../first_slice_replay.dart` — the command-line entry: record observations,
  or serve the corpus for a driven product run.
- `evidence/` — recorded observations, one file per platform.

## Destination side

```
dart run tool/first_slice_replay.dart packages/fjs/libfjs/target/debug/fjs.dll
```

The run binds `127.0.0.1:18731` (the corpus' own `origin`, because the source
object is a compared input), drives search → book information → table of
contents → content, and writes
`tool/first_slice/evidence/<platform>-slice-01.liber.json`. It fails when the
scenario shape is broken: an undeclared request, a request sequence other than
the declared one, a missing stage, the session cookie not reaching the wire, or
a page-chained stage that did not follow its next link.

`test/first_slice_fixture_test.dart` runs the same corpus through
`flutter test test`, so every desktop platform whose CI job builds the native
library executes it.

To hand the page the running corpus instead:

```
dart run tool/first_slice_replay.dart - --serve --source-out build/slice-01.source.json
```

then drive the app (`README.md` → Verification and evidence → Driving the UI)
with 书源试读 → 选择书源 JSON → `build/slice-01.source.json` and keyword `回放`.

## What a green destination run does *not* say

A pass means the corpus is healthy and the product reached the stages the slice
names. The frozen side and the committed golden are now executed evidence;
platform, source and capability claims still follow the differential contract's
row and coverage rules.

## Frozen side (executed 2026-09-18)

The golden was produced by the hash-pinned frozen APK against the same corpus,
without rebuilding a Legado class. The instrumentation APK targets the installed
`io.legado.app.debug` package and reaches its classes through
`getTargetContext().getClassLoader()`.

- `tool/nested_oracle/SliceOracle.java` drives the four suspend entry points and
  serves the six declared responses inside the device process on
  `127.0.0.1:18731`.
- The golden and its provenance are committed under
  `tool/first_slice/evidence/android-17-os4.0.0.31/`; the manifest pins the APK,
  corpus, harness sources, device fingerprint and curated run transcript.
- The comparator applies the contract's platform-generated-header ignore rule.
  R2–R7 and R9 pass; R8 remains a named paragraph-indent divergence. The
  comparator report names every observation it does not compare.

The recorded comparison command first removes an old report because the
comparator refuses to overwrite evidence:

```text
rm -f tool/first_slice/evidence/android-17-os4.0.0.31/comparison.json
 dart run tool/first_slice_compare.dart tool/first_slice/evidence/android-17-os4.0.0.31/golden.json tool/first_slice/evidence/windows-slice-01.liber.json tool/first_slice/evidence/android-17-os4.0.0.31/comparison.json
```

The corpus and golden remain versioned together: changing the source, responses,
scenario or declared requests requires a new corpus version and a new golden.
