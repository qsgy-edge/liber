# #54 — REQUEST-01 v2 executed device evidence

The restored handset run resolves the device block recorded by the earlier version of this document. The filename is retained for existing links. REQUEST-01 v2 now has a real frozen golden and a strict Windows comparison: **20 pass / 0 fail / 3 existing named notCompared**, including passes for all three new body-charset rows. Evidence remains scoped to `wayfinder/54` until controller review and integration; this is not an all-platform or universal-charset claim.

The resume started from clean `cdf4ae7db03a084ad6caf508dc5baf695e2337aa` in `D:/GithubRepositories/Flutter/liber-54`, after the controller merged validated master. No product, parser, Rust, harness or comparator code was changed during this device continuation. Corpus metadata was updated before building to remove the obsolete device-block wording; all 23 declared requests and 25 replay responses are unchanged from the prepared v2 inputs.

## Device and provenance

On 2026-09-20, `adb devices` returned `5615f742 device`. At capture time, `getprop ro.build.fingerprint` returned:

```text
Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys
```

`pm path io.legado.app.debug` identified the installed base APK, which was pulled and verified as SHA256 `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6`. No frozen app was rebuilt, cleared or uninstalled. The only installation was the existing reflection-only oracle instrumentation, built in a fresh directory:

```text
pwsh tool/nested_oracle/build.ps1 -OutputDirectory C:/Users/17945/.cache/wayfinder/liber-54/device-resume/harness -JavaHome C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8
MSYS_NO_PATHCONV=1 adb -s 5615f742 install -r -t <that directory>/nested-oracle.apk
```

Build and install exited 0 (one javac source-8/bootstrap-path warning). Built and pulled installed harness APKs both hash to `c01874414c27c46afd86f155ac68ab913436161ece9b2a28fed0bd2a4de92c28`. The committed corpus and built asset both hash to `d59b1d2c49cc63d6fbc84c1a830a2de5a5f17c08e5ef925aa7a9765a8546bd17`.

Each of two sequential runs used force-stop, the existing instrumentation entry and the existing output path, with `MSYS_NO_PATHCONV=1` in every adb command's environment:

```text
adb -s 5615f742 shell am force-stop io.legado.app.debug
adb -s 5615f742 shell am instrument -w -r io.liber.oracle.nested/io.liber.oracle.nested.RequestOracle
INSTRUMENTATION_RESULT: stream=Request oracle recorded 23 rows and 51 requests
INSTRUMENTATION_CODE: -1
adb -s 5615f742 pull /sdcard/Android/data/io.legado.app.debug/files/request-oracle.json <capture-N.json>
```

Both runs exited 0, with `analysisFailure: null`, `serverErrors: []`, and `cleanup: {openConnections: 2, serverClosed: true}`. `openConnections` is sampled before `Replay.close`; it is not a post-close leak count. The captures are identical after removing only `recordedAt`. The committed golden is the second capture, copied verbatim, recorded at `2026-09-20T12:12:35.074Z`.

After capture, the target app was force-stopped; `adb shell pidof io.legado.app.debug` returned exit 1 with no output, confirming the instrumentation and in-process replay were stopped. No shell input events or operator content operations occurred. The desktop comparator exited normally, releasing its server; no competing device/replay work remains owned by this lane.

## Frozen basis and observed new rows

Frozen commit: `14dd24945b2914ce2708b8abaa4ee67ceef892af`.

- `AnalyzeUrl.kt:257-260,271-272,279-334` applies the option charset to form/query percent-encoding. `:435-446` passes a declared raw body's Content-Type to `toRequestBody`; the option does not override it. Source blob SHA256 `3cf214316ed79271739467ba47572bd4f64f86130fab929d733bedd467e7dd56`.
- `OkHttpUtils.kt:139-142` writes the encoded form with the form media type. Source blob SHA256 `1a5436e708f66f1d9b67193ef042cf47c6cb2e52ab37bfec7f199b2b0abe0894`.
- okhttp-4.12.0 `RequestBody.kt:106-118` resolves the media charset and calls `String.getBytes(charset)` (`javap` bytecode offset 70, source line 117). `MediaType.kt:51-55` supplies the fallback on an unknown charset. Inspected JAR SHA256 `b1050081b14bb7a3a7e55a4d3ef01b5dcfabc453b4573a4fc019767191d5f4e0`.

| Row | Frozen bytes | Windows bytes | Observed media type / framing | Result |
|---|---|---|---|---|
| `body-charset-gbk-307` | `CA E9` on initial and 307 requests | `CA E9` on both | `text/plain; charset=GBK`; Content-Length 2 | pass |
| `body-charset-content-type-precedence` | `E4 B9 A6` | `E4 B9 A6` | `text/plain; charset=UTF-8`; Content-Length 3, despite GBK option | pass |
| `body-charset-gbk-form` | `6B 3D 25 43 41 25 45 39` (`k=%CA%E9`) | identical | `application/x-www-form-urlencoded; charset=utf-8`; Content-Length 8 | pass |

No request above used Transfer-Encoding. The golden stores raw body bytes as a reversible Latin-1 string, not as decoded GBK text; this is the existing comparator representation. Content-Length remains a platform-generated ignored header in the strict comparator. The golden observations and focused Windows wire tests establish framing without weakening that rule. The tests additionally cover 308 preservation, default UTF-8 and unknown-label fallback.

Declared Content-Type precedence is now supported by both source inspection and a passing executed row, with no unresolved ambiguity for the fixture. Unknown-label UTF-8 fallback remains unchanged from controller correction `78e6442`; it has source-derived Windows wire evidence but no row in this device corpus. The earlier instruction to reject unknown labels was withdrawn and is not the current behavior.

## Full comparison

The existing comparator, including master's socket teardown correction, completed in **7.195 seconds**, exit 0. A printed result without process exit was not accepted.

```text
dart run tool/nested_oracle_compare.dart --requests build/windows/x64/runner/Debug/fjs.dll tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json tool/nested_oracle/evidence/android-17-os4.0.0.31/request-comparison.json
```

| Row | Status |
|---|---|
| `body-charset-gbk-307` | pass |
| `body-charset-content-type-precedence` | pass |
| `body-charset-gbk-form` | pass |
| `defaults-injected` | pass |
| `defaults-declared` | pass |
| `defaults-user-agent-null` | notCompared |
| `redirect-300-post` | pass |
| `redirect-301-post` | pass |
| `redirect-302-post` | pass |
| `redirect-303-post` | pass |
| `redirect-307-post` | pass |
| `redirect-308-post` | pass |
| `redirect-cross-origin` | notCompared |
| `redirect-limit` | pass |
| `query-key-raw` | pass |
| `query-key-separators` | pass |
| `query-key-separators-and-space` | pass |
| `query-already-encoded` | pass |
| `query-exact-bytes` | notCompared |
| `page-list-hit` | pass |
| `page-list-past-end` | pass |
| `pageless-empty-bindings` | pass |
| `pageless-page-list-literal` | pass |

The three remaining differences are unchanged and quoted exactly by the report:

- `defaults-user-agent-null`, `requests[0].headers.user-agent`: frozen `"okhttp/4.12.0"`; Windows `"Dart/3.12 (dart:io)"`.
- `redirect-cross-origin`, `requests[1].headers.cookie`: frozen `"test=value"`; Windows `null` (header absent).
- `query-exact-bytes`, `requests[0].rawQuery`: frozen ``q={a}|b^c`\d%27e%20f%20%E4%B9%A6&p=1``; Windows `q=%7Ba%7D%7Cb%5Ec%60%5Cd%27e%20f%20%E4%B9%A6&p=1`.

Only those named observations are excepted; every other required observation in those rows matched. The comparator's identity checking, ignore list and divergence rules were not edited.

## Desktop validation and native identity

The approved native source `D:/GithubRepositories/Flutter/liber/build/windows/x64/runner/Debug/fjs.dll` was hashed before copying into this worktree's ignored `build/windows/x64/runner/Debug/fjs.dll`. Source and destination SHA256 both equal `b7d5a70874f6e3c8fa067fbf442fa158d6d2b264309c40cf4c9b995250bb31f1`. No Rust build ran, and no FRB mismatch occurred.

The worker lacks Dart MCP tools. Per the resume briefing it used bounded CLI validation; the controller owns independent reproduction and driven Windows UI review before delivery. Tests ran sequentially in a bounded subprocess with recorded exit codes.

| Command | Result |
|---|---|
| `flutter test test/source_request_semantics_test.dart` | exit 0, 15 tests passed |
| `flutter test test --reporter json` | exit 0, 347 visible tests passed, 0 skipped |
| `dart analyze lib test integration_test tool` | exit 0, No issues found |
| `python tool/ci_runtime.py windows x86_64-pc-windows-msvc` | exit 0, 16/16 rows pass, no VM crash markers |
| `dart run tool/host_surface_gate.dart build/windows/x64/runner/Debug/fjs.dll` | exit 0, 68/68 checks pass |

Exact commands, durations and raw device results are in the versioned `android-17-os4.0.0.31/request-run.log`; the manifest pins the source bytes, APKs, corpus, golden, comparison, native DLL and executed validation. Full logs and both captures remain in `C:/Users/17945/.cache/wayfinder/liber-54/device-resume/`; `.ci-results/` contains this worktree's runtime row logs and manifest. A host-side capture inspection initially used Windows' GBK default instead of UTF-8 and raised `UnicodeDecodeError` after a successful device run/pull. Re-reading the untouched capture explicitly as UTF-8 resolved that inspection error; no device evidence was altered or substituted.

Key hashes:

- Golden: `89c286d29517d815c04d881229f470271d4dc9aeb5359d1ee48f7c9b000bbd83`.
- Comparison: `12caba1fc9f59f8e59ff41b064dc378bd99a5d87eba4cabbbba139cbc7bdc164`.
- Corpus: `d59b1d2c49cc63d6fbc84c1a830a2de5a5f17c08e5ef925aa7a9765a8546bd17`.

## Coverage limits and acceptance

Only the three new body rows and existing passing rows gain current Windows differential evidence. Unknown charset labels, UTF-16 output, other legacy labels and characters not representable in a legacy charset remain outside this device corpus. The existing bridge still uses encoding_rs replacement: for a GBK emoji, Java writes `?` (`3F`) while the bridge writes `&#128512;` (`26 23 31 32 38 35 31 32 3B`). That known difference is not a newly measured device row or a pass.

The harness drives AnalyzeUrl directly rather than four WebBook entry points; finalUrl is not compared because replay ports differ. Retry, WebView/upload/type, redirect-hop Set-Cookie, relative/cross-scheme redirects and the used-source frequency of the query divergence remain outside this slice. No response decode, parser, Rust, bridge entry or unrelated host/content behavior changed.

- [x] Matching 23-row v2 corpus, fresh harness, installed frozen APK verification and fingerprint.
- [x] Two executed device captures, pinned refreshed golden/manifest and explicit cleanup.
- [x] All three new rows compare pass; remaining divergences quoted without expanding exceptions.
- [x] Existing product implementation encodes through the shared bridge and preserves media type/framing, including controller's unknown-label correction.
- [x] Matrix/contract describe actual executed status and residual limits.
- [x] Focused tests 15/15, full tests 347/347, clean analysis, runtime 16/16 and host gate 68/68.
- Controller independent reproduction and driven UI review are the delivery barrier after the candidate commit; their result is recorded in the final lane artifact and subsequent evidence comment. No merge, push or ticket closure is performed by this lane.
