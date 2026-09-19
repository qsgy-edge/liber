# #54 offline request-body charset preparation — device blocked

Status: **partial; not accepted as frozen compatibility evidence**. Branch `wayfinder/54`, worktree `D:/GithubRepositories/Flutter/liber-54`, base `8d4069d`. This record accompanies REQUEST-01 corpus v2 (23 rows, 25 responses); it is not a refreshed device manifest or golden.

## Device boundary and controller direction

The only approved device is `5615f742`. The actual command/result was:

```text
$ adb devices
List of devices attached

```

No devices were listed. The controller authorized offline fixture/product/test work only, with no device retry loop, substitute device or AVD. APK installation, current installed frozen APK hash verification, device fingerprint verification, RequestOracle instrumentation and golden pull are **blocked/not-run**. No device input was sent. No Windows UI driven run was performed in this lane; the controller owns the integrated driven review.

## Frozen basis (source inspection, not a new execution)

Repository `D:/GithubRepositories/Android/legado` HEAD is the frozen `14dd24945b2914ce2708b8abaa4ee67ceef892af`; the inspected text came from `git show <commit>:<path>`:

- `app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeUrl.kt:257-260,271-272,279-334`: the option charset percent-encodes a non-JSON/XML form only when `Content-Type` is absent. Source blob SHA256 `3cf214316ed79271739467ba47572bd4f64f86130fab929d733bedd467e7dd56`.
- The same file `:435-446`: the declared raw body goes to `body.toRequestBody(contentType.toMediaType())`. The option charset is not passed to it. There is no unresolved precedence ambiguity for these fixtures: Content-Type controls the raw body's bytes.
- `app/src/main/java/io/legado/app/help/http/OkHttpUtils.kt:139-142`: `postForm(encodedForm)` uses `application/x-www-form-urlencoded`, without a charset. Source blob SHA256 `1a5436e708f66f1d9b67193ef042cf47c6cb2e52ab37bfec7f199b2b0abe0894`.
- Cached `okhttp-4.12.0.jar` SHA256 `b1050081b14bb7a3a7e55a4d3ef01b5dcfabc453b4573a4fc019767191d5f4e0`, inspected with Temurin 17 `javap -c -l 'okhttp3.RequestBody$Companion' okhttp3.MediaType`: `RequestBody.kt:106-118` resolves the media charset, appends UTF-8 when it resolves none, and calls `String.getBytes(charset)` (bytecode offset 70, line 117). `MediaType.kt:51-55` catches an unknown charset and returns its fallback.

The controller explicitly required unsupported body charset errors to propagate without a UTF-8 fallback. That is recorded as a **deliberate divergence** from the last frozen behavior, rather than described as frozen parity. A Windows test checks the named `TextEngineError_UnknownEncoding` and that no request was received.

## Product and pending fixture rows

`HttpSourceTransport` now passes the body and resolved media-type charset to the existing `SourceEncoding.encode` bridge; `Content-Length` uses the resulting byte count. No Rust, bridge entry, option parser, response decoding or comparator change.

| New corpus row | Offline product result | Frozen v2 comparison |
|---|---|---|
| `body-charset-gbk-307` | `书` writes `CA E9`, length 2; wire tests also cover both 307 and 308 | blocked/not-run |
| `body-charset-content-type-precedence` | GBK option with declared UTF-8 writes `E4 B9 A6`, length 3 | blocked/not-run |
| `body-charset-gbk-form` | `k=书` becomes ASCII `k=%CA%E9`, bytes `6B 3D 25 43 41 25 45 39`, length 8; media type names UTF-8 | blocked/not-run |

The wire tests also cover an absent media charset defaulting to UTF-8. Each of the four success cases checks the initial request, 307 hop and 308 hop, Content-Type, actual bytes, method, Content-Length and no Transfer-Encoding. The regression was run before the fix and failed with actual `E4 B9 A6` on all three GBK hops versus expected `CA E9`.

## Commands and actual results

Raw local logs are in `C:/Users/17945/.cache/wayfinder/liber-54/`.

| Command | Actual result |
|---|---|
| `flutter pub get` | exit 0; generated Windows plugin noise subsequently restored |
| `flutter test test/source_request_semantics_test.dart --plain-name 'declared GBK body'` (before fix) | exit 1, expected `[202,233]`, actual `[228,185,166]` on all 3 hops (`before.log`) |
| `flutter test test/source_request_semantics_test.dart` | exit 0, 15/15 tests (`focused.log`) |
| `flutter test test` | exit 0, 312/312 tests (`flutter-test.log`) |
| `dart analyze lib test integration_test tool` | exit 0, No issues found (`analyze-complete.log`, `analyze-exit.json`) |
| `python tool/ci_runtime.py windows x86_64-pc-windows-msvc` | exit 0, 16/16 rows (`ci-runtime-complete.log`, `ci-runtime-exit.json`; worktree `.ci-results/manifest.json` and row logs) |
| `dart run tool/host_surface_gate.dart build/windows/x64/runner/Debug/fjs.dll` | exit 0, status pass, 46/46 checks (`host-surface.log`) |
| `pwsh tool/nested_oracle/build.ps1 -OutputDirectory C:/Users/17945/.cache/wayfinder/liber-54/request-oracle-v2 -JavaHome C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8` | exit 0; harness built (`harness-build.log`); one javac source-8/bootstrap-path warning |
| `dart run tool/nested_oracle_compare.dart --requests build/windows/x64/runner/Debug/fjs.dll tool/nested_oracle/evidence/android-17-os4.0.0.31/request-oracle.json C:/Users/17945/.cache/wayfinder/liber-54/request-comparison-v2.json` | exit 255: `Bad state: Oracle identity mismatch`; no report created (`comparator.log`) |
| `git diff --check` | exit 0 |

The first analyzer and runtime-matrix attempts were terminated by the tool's 60-second timeout (matrix reached six successful rows); the complete reruns used detached subprocesses with exit-code files and finished as reported above. The headline counts come from the complete runs, not the interrupted ones. Only test whitespace/comments changed after those runs.

The controller approved read-only reuse of its native library because the lane had none. The initially suggested controller bundle path did not exist; the approved replacement was `D:/GithubRepositories/Flutter/liber/packages/fjs/libfjs/target/debug/fjs.dll`, copied to this worktree's ignored `build/windows/x64/runner/Debug/fjs.dll`. `sha256sum` before and after gave **`e5bade176f54d786d0225dbcd9c133707335d1caf0b4d661eeae3f122a6a2bf6`** for both. No Rust build ran; no FRB mismatch occurred.

## Pins and evidence grades

- Pending corpus and built `assets/request-fixtures.json`: both SHA256 `67a03ae60a126200ccd5b7ecb74280ca32965d8d3fd542d0799db19630ee2d33` — versioned input, not a golden.
- Built harness APK: SHA256 `d99f4cc59aa3be735efab8d0f41ff2aa3d23091790a2480aeafadd830e7e08b9` — build-only, never installed.
- `RequestOracle.java`: working-copy SHA256 `f221184449faad551d7309c190790cfb40907d661811221061ce8e67971c416e`; unchanged Git blob SHA256 `584ae5952a82fafee35f56be1abb88fb241d3ea36d45614e62919e0ec88a646d` (checkout CRLF versus LF).
- `AndroidManifest.xml`: `edd75d6cc7c789f1f53db9187a3627729bbeefca601fb3c7376baf8efd737f58`; `build.ps1`: `bdf3a9b86e307fb419fa006788f2f1893bcaeddf7549861f00b086a41543691f`.
- Historical v1 `android-17-os4.0.0.31/request-oracle.json`: SHA256 `16d42622ea09f1b86388b6043e8f755542e382c39e6fadab2debfd384fce0222`; `request-manifest.json`: `d06d5ca79d0792b5e3752e05caab65831bebb096e1274deecce8deb7272f4242`; `request-comparison.json`: `3340789d9857e51763e1a0d75dcbe038d562691727df9a7598679854116f985b`. All unchanged.
- That historical manifest pins frozen APK `cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6` and fingerprint `Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys`. **Neither was verified on the currently unavailable device in this lane.**
- Product wire tests/runtime gates: executed Windows evidence against the copied DLL; source precedence: static frozen source/bytecode evidence; new device equality: not-run. No row or aggregate status was promoted.

## Remaining divergences and gaps

The historical v1 comparison's 17 passes and 3 `notCompared` rows were not rerun against v2. Their existing divergence values remain:

- `defaults-user-agent-null`: frozen `"okhttp/4.12.0"`, product `"Dart/3.12 (dart:io)"`.
- `redirect-cross-origin`: frozen declared cookie `"test=value"`, product `null` (header absent).
- `query-exact-bytes`: frozen ``q={a}|b^c`\d%27e%20f%20%E4%B9%A6&p=1``; product `q=%7Ba%7D%7Cb%5Ec%60%5Cd%27e%20f%20%E4%B9%A6&p=1`.

The existing encoding engine's unrepresentable-character difference also applies to raw legacy bodies: for GBK emoji, Java's replacement is `?` (`3F`), while encoding_rs uses `&#128512;` (`26 23 31 32 38 35 31 32 3B`). It is not a new device observation. UTF-16 output and other labels remain uncovered; no universal charset parity claim is made. Unknown labels follow the approved rejection: frozen fallback would encode `书` as `E4 B9 A6`; this product sends no bytes and reports the named error.

The parser's existing media-type label handling, form selection, response decode order, all historical evidence and comparator ignore/divergence rules are deliberately unchanged. The corpus still drives AnalyzeUrl directly, not the four WebBook stages; the v1 manifest's other coverage gaps continue to apply.

## Acceptance checklist

- [x] Prepare the new versioned fixtures and corpus hash, and build a matching harness asset.
- [ ] Execute RequestOracle on handset `5615f742`, verify installed frozen bytes/fingerprint, and refresh golden/manifest: blocked.
- [x] Implement body encoding through the existing bridge with Content-Type and Content-Length behavior preserved for supported labels; named-error divergence is explicit.
- [ ] New rows compare pass against a refreshed golden: blocked; strict identity failure retained.
- [x] Matrix/contract distinguish executed offline checks, static evidence, divergences and blocked device rows.
- [x] `flutter test test` 312/312; analyze clean; runtime 16/16; host surface 46/46.
- [ ] Overall #54 completion and compatibility promotion: not met. Resume on the approved handset, refresh the evidence pair, compare every row, and review before integration/closure.
