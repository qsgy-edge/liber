# Android session runbook (controller, with the handset)

**Session status: executed 2026-09-24** on the handset `5615f742` (Android 17, fingerprint
`…OS4.0.0.31.XPMCNXM…`, System WebView `155.0.8059.4`). It produced the frozen golden
`evidence/android-os4.0.0.31/` (14/14 rows) and the 14 destination rows through the product adapter
(`evidence/android-destination/`, 13 `match` + `WV-14` `policy-rejected`), each with its manifest. Keep
this file as the procedure for the next session; the WebView pin below is the value that session used.
The paragraphs below describe the session as it was run.

The Windows rows in `evidence/windows-destination/` are executed. The Android
rows are **`not-run`** and stay so until this session completes: the handset was
not attached when the lane ran (`adb devices` was empty), and no device install
or `adb` write is part of the lane.

Everything below runs from this directory
(`tool/webview_oracle/`) on the machine the handset is plugged into.

## 0. Preconditions

| Need | Value this session must confirm |
| --- | --- |
| Handset | `adb devices` shows `5615f742` |
| Device fingerprint | `adb shell getprop ro.build.fingerprint` → `Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys` |
| System WebView | `155.0.8059.4` (updated 2026-09-24; the 2026-09-22 session pinned `154.0.8037.22`, and the golden re-captured afterwards supersedes that 154-pinned one, which stays in git history) |
| Frozen oracle APKs | `C:/Users/17945/.cache/wayfinder/oracle-apks-verified/{app.apk,test.apk}`, hashes `cc99040c…` and `10d382a7…` |
| JDK | `C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8` (the scripts export it) |
| Toolchain | `fvm flutter --version` matches the fixed build the Windows sweep recorded |

Operator actions at the handset, in order:

1. Unlock the phone and leave the launcher in front for the whole session. This
   OS freezes a backgrounded app process (`cgroup.freeze=1`), which stalls the
   Kotlin timers WV-09 and WV-10 depend on; keeping the screen on and the
   launcher visible is what makes those two rows finish. The scripts set
   `stay_on_while_plugged_in` and re-wake the screen every 20 s themselves and
   restore the previous value when they exit.
2. The script additionally brings the frozen app's own window up after every
   `pm clear` and after each restart phase's `force-stop` (`wake_app`). On the
   current build (`OS4.0.0.31`) the launcher alone is no longer enough: a headless
   app process's main-looper timers are deferred within seconds, so WV-09's 1 s
   retry chain and WV-10's 60 s outer timeout never fire and both fixtures hang
   indefinitely. With the app's window up, the same probe finishes in 33.5 s
   (archived row: 32.3 s). Measured 2026-09-22 on `5615f742`; the app process is
   not frozen, and neither the battery whitelist nor an active standby bucket nor
   the `RUN_IN_BACKGROUND` app-op replaces it.
3. MIUI may show an "Android 应用兼容性" dialog (16 KB page alignment for a debug
   build) when the app comes up. It does not affect any row — WV-09 completes with
   it on screen — but dismissing it with **不再显示** keeps the screen readable.
   `pm clear` may bring it back.
4. Approve the install prompt if it appears (only the oracle run installs the
   frozen APKs; the destination sweep uses `--use-application-binary` and
   `--keep-app-running`, so it does not reinstall per fixture).
5. Do not touch the phone while a fixture runs. Do not unplug it: WV-07 and WV-08
   run a second phase in a new process and need the device to stay attached.

## 1. Frozen oracle for the current fingerprint (about 25–40 minutes)

```text
cd tool/webview_oracle
bash tools/run_oracle_android_os40031.sh
```

What it does: verifies the two frozen APKs and the oracle harness by SHA-256,
refuses to run when the fingerprint or the System WebView version differs from
the pins, installs both APKs, clears app data before every fixture, runs
WV-01..WV-14 with `am instrument -e class …#<method>` (three attempts per
fixture; WV-07/WV-08 add a `force-stop` restart phase), pulls each fixture's JSON
only after `OK (1 test)`, and copies the accepted rows plus `run.log` into
`evidence/android-os4.0.0.31/`.

Failures are recorded in `evidence/android-os4.0.0.31/run.log` as
`ENVIRONMENT-INTERRUPTION` and are not accepted; the script exits non-zero
instead of accepting a partial golden.

Then write the golden manifest the comparison reads:

```text
node tools/write_oracle_golden_manifest.js android-os4.0.0.31
```

It derives the fingerprint, the WebView version, the APK/harness/fixture/evidence
hashes and the verdicts from the pulled rows and the run log, and refuses when
the log's provenance disagrees with the rows it produced.

## 2. Android destination rows through the product adapter (about 20–30 minutes)

```text
bash tools/run_all_destination.sh
node tools/write_destination_manifest.js android
```

The sweep builds the harness once (`lib/main.dart` is not the test entrypoint;
`--target=integration_test/destination_test.dart` is), reuses that one APK
through `--use-application-binary`, and stops at the first row that is neither a
match nor a declared policy rejection. `run_fixture.sh` selects the golden by the
device's own fingerprint, so a mismatched golden is refused rather than loosened.
Expected shape, from the archived prototype's rows:

- WV-01..WV-13 `match`, or WV-05 `match-race-alternative` when the run lands on
  the other side of that race (the manifest declares the alternative; both sides
  are committed as diagnostics in the golden);
- WV-14 `policy-rejected`, with the named refusal check
  (`invalidTlsRefusedAfterCertificatePresented`) holding.

The manifest writer refuses to describe the sweep when the adapter sources (the
harness's and `../../lib/source/book_source_webview_adapter.dart` plus
`inappwebview_book_source_adapter.dart`) changed after the sweep completed, and
when the APK hash samples across the 14 fixtures are not all equal.

## 3. What to bring back and what stays open

Commit from the controller session: `evidence/android-os4.0.0.31/` (oracle
golden + `run.log` + `manifest.json`) and the refreshed
`evidence/android-destination/` (`WV-*.json`, `reports/`, `run.log`,
`manifest.json`). The archived `evidence/android-destination/` rows describe the
prototype adapter and are superseded by this run; `evidence/android` and
`evidence/android-17` stay as they are.

Still `not-run` afterwards: iOS, macOS and Linux destination rows, and therefore
the five-platform aggregate. Windows or Android results cannot be reused for
them.
