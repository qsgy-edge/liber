#!/usr/bin/env bash
# Runs one destination fixture on the connected device, writes its evidence to
# the committed destination evidence directory, and compares it against the
# frozen Legado golden. One fixture per invocation so a failure stops before the
# next fixture and cannot be masked by an aggregate exit code.
#
# Two device behaviors are handled here rather than left to chance:
#   * App data is cleared before the main phase, because the frozen oracle
#     cleared it between fixtures and a retained native cookie or storage entry
#     from an earlier fixture would otherwise leak into this one's requests.
#   * The screen is kept on for the run, because this device freezes a
#     background process when the screen turns off, which stalls the timers
#     WV-09 and WV-10 depend on.
set -uo pipefail

id="${1:-}"
if [[ -z "$id" ]]; then
  echo 'usage: run_fixture.sh WV-0n' >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Node and adb need a Windows path; this shell reports an MSYS path.
root="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"
adapter="$root/adapter"
apk="${APK:-$adapter/build/app/outputs/flutter-apk/app-debug.apk}"
device="${DEVICE:-5615f742}"
package='io.legado.ticket13.ticket13_adapter'
selector="/sdcard/Android/data/$package/files/selector.json"
export JAVA_HOME="${JAVA_HOME:-C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8}"

# WV-07 and WV-08 observe state across a real process restart, so they run a
# second phase in a new process without clearing app data in between.
restart_phase=false
case "$id" in
  WV-07 | WV-08) restart_phase=true ;;
esac

adb wait-for-device
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
adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1
(
  while true; do
    sleep 20
    adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
  done
) &
keep_awake_pid="$!"

bash "$adapter/tool/sync_fixtures.sh"

cd "$adapter"
evidence="$root/evidence/android-destination/$id.json"
restart_evidence="$root/evidence/android-destination/$id.restart.json"
rm -f "$evidence" "$restart_evidence"

write_selector() {
  # The fixture is selected at run time through a file rather than with
  # `--dart-define`, because a compile-time define changes the APK per fixture
  # and accepted evidence must belong to one recorded build. It is written after
  # `pm clear`, which removes the app's external files directory.
  local payload="$1"
  MSYS_NO_PATHCONV=1 adb shell "mkdir -p $(dirname "$selector") && cat > $selector" <<<"$payload"
}

drive() {
  # `--use-application-binary` runs the APK the sweep already built and hashed,
  # so no fixture rebuilds the app and every fixture's evidence belongs to one
  # recorded build. `--keep-app-running` leaves the app installed, so the device
  # keeps the tool's APK sha1 marker and the next run reuses the installed build
  # instead of reinstalling it. Without it the driver uninstalls the app after
  # every run, which makes each run a first install and triggers the device's
  # install prompt.
  fvm flutter drive \
    --driver=test_driver/integration_test.dart \
    --target=integration_test/destination_test.dart \
    --use-application-binary="$apk" \
    "$@" \
    --keep-app-running \
    -d "$device" --no-pub 2>&1 | tr -d '\r' | tail -12
}

adb shell pm clear "$package" >/dev/null
write_selector "{\"fixture\":\"$id\",\"phase\":\"main\"}"
drive

if [[ ! -f "$evidence" ]]; then
  echo "FAIL $id: no evidence written" >&2
  exit 1
fi

if [[ "$restart_phase" == true ]]; then
  port="$(node -p "
    const e = require('$evidence');
    const operation = Array.isArray(e.operation) ? e.operation[0] : e.operation;
    new URL(operation.responseUrl).port;
  ")"
  # A real process restart, without clearing app data: the durable store and
  # WebView storage must survive while in-process state must not.
  adb shell am force-stop "$package"
  write_selector "{\"fixture\":\"$id\",\"phase\":\"restart\",\"port\":$port}"
  drive
  if [[ ! -f "$restart_evidence" ]]; then
    echo "FAIL $id: no restart evidence written" >&2
    exit 1
  fi
  node "$root/tools/merge_restart_evidence.js" "$evidence" "$restart_evidence"
  rm -f "$restart_evidence"
fi

# The golden a destination is compared against must match the device it ran on.
# This device was updated from Android 16 to Android 17, and both goldens exist
# (`evidence/android` and `evidence/android-17`), produced from the same frozen
# APKs. The golden directory is selected by the device's own fingerprint rather
# than hardcoded, so a run cannot be compared against another OS's golden.
golden_dir="$root/evidence/android"
fingerprint="$(adb shell getprop ro.build.fingerprint | tr -d '\r')"
for candidate in "$root"/evidence/android "$root"/evidence/android-*; do
  [[ -f "$candidate/manifest.json" ]] || continue
  if [[ "$(node -p "require('$candidate/manifest.json').device.fingerprint")" == "$fingerprint" ]]; then
    golden_dir="$candidate"
    break
  fi
done

node "$root/tools/compare_to_golden.js" \
  "$golden_dir/$id.json" \
  "$evidence"
