#!/usr/bin/env bash
# Re-runs the frozen Legado Android oracle on the device's current OS to produce
# a second pinned golden, without touching the existing Android 16 golden.
#
# The device was updated from Android 16 to Android 17, and the comparison
# refuses to compare an Android destination whose fingerprint differs from its
# golden's. Rather than loosen that gate, this produces a golden pinned to the
# new fingerprint. `evidence/android/` stays as the Android 16 golden because the
# committed Windows destination row is compared against it.
#
# No rebuild: the APKs installed on the device are byte identical to the hashes
# the Android 16 manifest recorded, so the same binaries produce both goldens.
# They are verified here rather than assumed.
#
# Android 17 no longer reports `mInputRestricted`, so the unlock gate reads the
# user's own lock state and the keyguard instead.
set -uo pipefail

ROOT='D:/GithubRepositories/Flutter/liber-ticket-13/.scratch/flutter-legado-reader/prototypes/ticket_13_native_webview_contract'
APP='C:/Users/17945/.cache/wayfinder/oracle-apks-verified/app.apk'
TEST='C:/Users/17945/.cache/wayfinder/oracle-apks-verified/test.apk'
APP_EXPECTED='cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
TEST_EXPECTED='10d382a75cbb98dd6d4f9f3b49e35777cbbc53c8809426e2aa5148465642afa6'
HARNESS_EXPECTED='3d8e4ff81096ef6fa2b05e4ea1b201a90fbb0eb4ec1d438afc7ed35fade08f05'
STAGE='C:/Users/17945/.cache/wayfinder/ticket13-android17-golden'
REMOTE='/sdcard/Android/data/io.legado.app.debug/files/ticket13-oracle'
CLASS='io.legado.app.ticket13.Ticket13OracleTest'
RUNNER='io.legado.app.debug.test/androidx.test.runner.AndroidJUnitRunner'
BASELINE='14dd24945b2914ce2708b8abaa4ee67ceef892af'
FINGERPRINT='Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.19.XPMCNXM:user/release-keys'
WEBVIEW='152.0.7977.42'

rm -rf "$STAGE"
mkdir -p "$STAGE"
LOG="$STAGE/run.log"
: > "$LOG"
log() { printf '%s\n' "$*" | tee -a "$LOG"; }
command_log() { "$@" 2>&1 | tr -d '\r' | tee -a "$LOG"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }

require_hash() {
  local file="$1" expected="$2" actual
  actual="$(sha "$file")"
  [[ "$actual" == "$expected" ]] || {
    echo "hash mismatch for $file: $actual != $expected" >&2
    exit 1
  }
}

device_unlocked() {
  local user_state keyguard
  user_state="$(adb shell dumpsys user 2>/dev/null | tr -d '\r')"
  keyguard="$(adb shell dumpsys window 2>/dev/null | tr -d '\r')"
  [[ "$user_state" == *'0=RUNNING_UNLOCKED'* ]] &&
    [[ "$keyguard" == *'isKeyguardShowing=false'* ]]
}

run_method() {
  local id="$1" method="$2" limit="$3" phase="${4:-main}" attempt output status
  for attempt in 1 2 3; do
    adb wait-for-device
    log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RUN $id $method attempt=$attempt limit=${limit}s"
    set +e
    output="$(timeout "$limit" adb shell am instrument -w -r -e class "$CLASS#$method" "$RUNNER" 2>&1 | tr -d '\r')"
    status=$?
    set -e
    printf '%s\n' "$output" | tee -a "$LOG"
    if [[ $status -eq 0 ]] && grep -Fq 'OK (1 test)' <<<"$output"; then
      return 0
    fi
    log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ENVIRONMENT-INTERRUPTION $id $method attempt=$attempt status=$status (result not accepted)"
    adb shell am force-stop io.legado.app.debug >/dev/null 2>&1 || true
    # Only a main phase may discard its evidence before retrying. A restart phase
    # reads the main phase's JSON as its input and rewrites it, so deleting the
    # file would destroy the input and make every retry fail with ENOENT.
    if [[ "$phase" == 'main' ]]; then
      MSYS_NO_PATHCONV=1 adb shell rm -f "$REMOTE/$id.json" >/dev/null 2>&1 || true
    fi
    sleep 3
  done
  log "FAIL $id $method: no accepted OK (1 test)"
  return 1
}

pull_evidence() {
  local id="$1"
  MSYS_NO_PATHCONV=1 adb pull "$REMOTE/$id.json" "$STAGE/$id.json" 2>&1 | tr -d '\r' | tee -a "$LOG"
  ID="$id" FILE="$STAGE/$id.json" BASELINE="$BASELINE" FINGERPRINT="$FINGERPRINT" WEBVIEW="$WEBVIEW" node - <<'NODE'
const fs = require('fs');
const j = JSON.parse(fs.readFileSync(process.env.FILE, 'utf8'));
const expected = process.env.ID === 'WV-14' ? 'policy-rejected' : 'pass';
if (j.fixtureId !== process.env.ID) throw Error(`fixtureId: ${j.fixtureId}`);
if (j.baselineCommit !== process.env.BASELINE) throw Error(`baseline: ${j.baselineCommit}`);
if (j.device?.fingerprint !== process.env.FINGERPRINT) throw Error(`fingerprint: ${j.device?.fingerprint}`);
if (j.runtime?.webViewVersion !== process.env.WEBVIEW) throw Error(`WebView: ${j.runtime?.webViewVersion}`);
if (j.executionVerdict !== expected) throw Error(`verdict: ${j.executionVerdict}`);
for (const [name, value] of Object.entries(j.checks || {})) {
  if (value !== true) throw Error(`false check: ${name}`);
}
NODE
  log "PULLED $id"
}

adb wait-for-device
current_fingerprint="$(adb shell getprop ro.build.fingerprint | tr -d '\r')"
[[ "$current_fingerprint" == "$FINGERPRINT" ]] || {
  echo "unexpected fingerprint: $current_fingerprint" >&2
  exit 1
}
package_state="$(adb shell dumpsys package com.google.android.webview | tr -d '\r')"
version_line="$(awk '/^[[:space:]]*versionName=/{print; exit}' <<<"$package_state")"
[[ "${version_line#*=}" == "$WEBVIEW" ]] || {
  echo "unexpected WebView: ${version_line#*=}" >&2
  exit 1
}

require_hash "$APP" "$APP_EXPECTED"
require_hash "$TEST" "$TEST_EXPECTED"
require_hash "$ROOT/oracle/android/Ticket13OracleTest.kt" "$HARNESS_EXPECTED"

old_stay="$(adb shell settings get global stay_on_while_plugged_in | tr -d '\r')"
keep_awake_pid=''
cleanup() {
  if [[ -n "$keep_awake_pid" ]]; then
    kill "$keep_awake_pid" 2>/dev/null || true
    wait "$keep_awake_pid" 2>/dev/null || true
  fi
  adb wait-for-device >/dev/null 2>&1 || true
  adb shell settings put global stay_on_while_plugged_in "$old_stay" >/dev/null 2>&1 || true
}
trap cleanup EXIT
adb shell settings put global stay_on_while_plugged_in 7
adb shell input keyevent KEYCODE_WAKEUP
adb shell input keyevent KEYCODE_HOME
unlocked=false
for _ in {1..15}; do
  if device_unlocked; then
    unlocked=true
    break
  fi
  sleep 1
done
[[ "$unlocked" == true ]] || {
  echo 'device is locked' >&2
  exit 1
}
# The device freezes a background process while a heavy foreground app runs,
# which stalls the Kotlin timers WV-09 and WV-10 depend on. Keeping the screen on
# and the launcher in front avoids that.
(
  while true; do
    sleep 20
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
    adb shell input keyevent KEYCODE_HOME >/dev/null 2>&1 || true
  done
) &
keep_awake_pid="$!"

log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ANDROID-17-GOLDEN-RUN-BEGIN"
log "BASELINE=$BASELINE"
log "FINGERPRINT=$FINGERPRINT"
log "WEBVIEW=$WEBVIEW"
log "APP_SHA256=$(sha "$APP")"
log "TEST_SHA256=$(sha "$TEST")"
log "HARNESS_SHA256=$(sha "$ROOT/oracle/android/Ticket13OracleTest.kt")"
for fixture in "$ROOT"/fixtures/WV-*.json; do
  log "FIXTURE_SHA256 $(basename "$fixture") $(sha "$fixture")"
done
log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INSTALL application"
command_log adb install -r -t "$APP"
log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] INSTALL instrumentation"
command_log adb install -r -t "$TEST"

ids=(WV-01 WV-02 WV-03 WV-04 WV-05 WV-06 WV-07 WV-08 WV-09 WV-10 WV-11 WV-12 WV-13 WV-14)
methods=(wv01HiddenDirectGet wv02HttpPostBootstrap wv03InlineHtmlWithoutBaseUrl wv04RedirectAndSyntheticResponse wv05ResourceSnifferFirstMatch wv06OverrideSnifferBlocksNavigation wv07CookiesAcrossOperationAndStore wv08StorageAcrossWebViewInstances wv09NullResultRetryTimeout wv10OuterTimeoutStopsPostTerminalActivity wv11ExplicitCancellationBeforeLoadAndInFlight wv12OverlapLimiterSiblingCancellationAndOrdering wv13HttpAndMainFrameErrors wv14InvalidTlsPolicyAndSetupCleanup)
# A fresh `pm clear` occasionally leaves the first instrumentation start hanging
# with no output on this OS; the retry above recovers in seconds. The per-fixture
# limits are therefore just above each fixture's real duration, so a hang is
# detected quickly instead of burning the long budget the slow fixtures need.
limits=(90 90 90 90 90 90 90 90 240 300 240 120 90 90)
for index in "${!ids[@]}"; do
  id="${ids[$index]}"
  log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] CLEAR $id"
  command_log adb shell pm clear io.legado.app.debug
  run_method "$id" "${methods[$index]}" "${limits[$index]}" main || exit 1
  if [[ "$id" == 'WV-07' ]]; then
    adb shell am force-stop io.legado.app.debug
    run_method "$id" wv07CookiesAfterProcessRestart 90 restart || exit 1
  fi
  if [[ "$id" == 'WV-08' ]]; then
    adb shell am force-stop io.legado.app.debug
    run_method "$id" wv08StorageAfterProcessRestart 90 restart || exit 1
  fi
  pull_evidence "$id" || exit 1
done

APP_PATH_RAW="$(adb shell pm path io.legado.app.debug | tr -d '\r')"
TEST_PATH_RAW="$(adb shell pm path io.legado.app.debug.test | tr -d '\r')"
MSYS_NO_PATHCONV=1 adb pull "${APP_PATH_RAW#package:}" "$STAGE/installed-application.apk" >/dev/null
MSYS_NO_PATHCONV=1 adb pull "${TEST_PATH_RAW#package:}" "$STAGE/installed-instrumentation.apk" >/dev/null
cmp "$APP" "$STAGE/installed-application.apk"
cmp "$TEST" "$STAGE/installed-instrumentation.apk"
log "DEVICE_APP_SHA256=$(sha "$STAGE/installed-application.apk")"
log "DEVICE_TEST_SHA256=$(sha "$STAGE/installed-instrumentation.apk")"

STAGE="$STAGE" BASELINE="$BASELINE" FINGERPRINT="$FINGERPRINT" WEBVIEW="$WEBVIEW" node - <<'NODE'
const fs = require('fs');
const path = require('path');
const files = fs.readdirSync(process.env.STAGE).filter((name) => /^WV-\d\d\.json$/.test(name)).sort();
if (files.length !== 14) throw Error(`expected 14 evidence files, got ${files.length}`);
for (const name of files) {
  const j = JSON.parse(fs.readFileSync(path.join(process.env.STAGE, name), 'utf8'));
  const expected = name === 'WV-14.json' ? 'policy-rejected' : 'pass';
  if (j.baselineCommit !== process.env.BASELINE) throw Error(`${name}: baseline`);
  if (j.device?.fingerprint !== process.env.FINGERPRINT) throw Error(`${name}: fingerprint`);
  if (j.runtime?.webViewVersion !== process.env.WEBVIEW) throw Error(`${name}: WebView`);
  if (j.executionVerdict !== expected) throw Error(`${name}: verdict`);
  if (Object.values(j.checks || {}).some((value) => value !== true)) throw Error(`${name}: false check`);
}
console.log('android 17 golden verification: 14/14');
NODE
log "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ANDROID-17-GOLDEN-RUN-COMPLETE acceptedMethods=16"

rm -f "$STAGE/installed-application.apk" "$STAGE/installed-instrumentation.apk"
sed -i 's/\r$//' "$LOG"
mkdir -p "$ROOT/evidence/android-17"
cp "$STAGE"/WV-*.json "$ROOT/evidence/android-17/"
cp "$LOG" "$ROOT/evidence/android-17/run.log"
