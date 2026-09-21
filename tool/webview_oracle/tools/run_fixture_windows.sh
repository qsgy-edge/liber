#!/usr/bin/env bash
# Runs one destination fixture on Windows WebView2, writes its evidence to the
# committed destination evidence directory, and compares it against the frozen
# Legado golden. One fixture per invocation so a failure stops before the next
# fixture and cannot be masked by an aggregate exit code.
#
# Two pieces of state are cleared before the main phase, because the frozen
# oracle cleared app data between fixtures: the app support directory, which
# holds the durable cookie store, and the WebView2 user data folder, which holds
# native cookies and DOM storage. Neither is cleared before a restart phase,
# which exists to observe what survives a real process restart.
set -uo pipefail

id="${1:-}"
if [[ -z "$id" ]]; then
  echo 'usage: run_fixture_windows.sh WV-0n' >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"
adapter="$root/adapter"
support="${APPDATA:-C:/Users/$USERNAME/AppData/Roaming}/io.legado.ticket13/ticket13_adapter"
support="$(cygpath -m "$support" 2>/dev/null || printf '%s' "$support")"
profile="$adapter/build/windows/x64/runner/Debug/ticket13_adapter.exe.WebView2"

# WV-07 and WV-08 observe state across a real process restart, so they run a
# second phase in a new process without clearing state in between.
restart_phase=false
case "$id" in
  WV-07 | WV-08) restart_phase=true ;;
esac

evidence="$root/evidence/windows-destination/$id.json"
restart_evidence="$root/evidence/windows-destination/$id.restart.json"
mkdir -p "$root/evidence/windows-destination"
rm -f "$evidence" "$restart_evidence"

write_selector() {
  mkdir -p "$support"
  printf '%s' "$1" > "$support/selector.json"
}

drive() {
  # Desktop targets do not support `--use-application-binary`, so the driver
  # builds. With no source change the build is a no-op and the executable stays
  # byte identical, which the sweep verifies by sampling its hash around every
  # fixture rather than assuming it.
  (
    cd "$adapter" &&
      TICKET13_EVIDENCE_ROOT="$root/evidence" \
        fvm flutter drive \
          --driver=test_driver/integration_test.dart \
          --target=integration_test/destination_test.dart \
          -d windows --no-pub 2>&1 | tr -d '\r' | grep -vE '^\[' | tail -12
  )
}

rm -rf "$support" "$profile"
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
  # A new process, without clearing state: the durable store and DOM storage must
  # survive while in-process state must not.
  write_selector "{\"fixture\":\"$id\",\"phase\":\"restart\",\"port\":$port}"
  drive
  if [[ ! -f "$restart_evidence" ]]; then
    echo "FAIL $id: no restart evidence written" >&2
    exit 1
  fi
  node "$root/tools/merge_restart_evidence.js" "$evidence" "$restart_evidence"
  rm -f "$restart_evidence"
fi

node "$root/tools/compare_to_golden.js" \
  "$root/evidence/android/$id.json" \
  "$evidence"
