#!/usr/bin/env bash
# Runs every destination fixture once on Windows WebView2, in order, against the
# frozen golden and stops at the first fixture that neither matches nor is
# policy-rejected.
#
# Accepted destination evidence must come from one build. Desktop targets do not
# support `--use-application-binary`, so the sweep builds once up front and then
# samples the executable's hash around every fixture; all samples must be equal,
# which proves no fixture relinked the app. The build runs in the committed tree,
# which is short enough for MSVC here; `tools/build_windows_harness.sh` verifies
# the adapter sources it is built from first.
#
# The build target must be the integration test entrypoint. An executable built
# from `lib/main.dart` runs the host app instead of the test, so the driver
# connects, finds no test, and no evidence is written.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"
adapter="$root/adapter"
exe="$adapter/build/windows/x64/runner/Debug/ticket13_adapter.exe"
reports="$root/evidence/windows-destination/reports"
log="$root/evidence/windows-destination/run.log"
mkdir -p "$reports"
: > "$log"

sha() { sha256sum "$1" | cut -d' ' -f1; }
say() { printf '%s\n' "$*" | tee -a "$log"; }

say "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DESTINATION-RUN-BEGIN"
bash "$root/tools/build_windows_harness.sh" | tee -a "$log"
# Desktop targets have no `--use-application-binary`, so each driven run relinks
# the runner before it starts. The build the sweep records as its fixed build is
# therefore the one the driver produces, not the one an explicit `flutter build`
# leaves behind: the first fixture runs once here to establish it, and its row is
# then re-run inside the loop so the recorded evidence belongs to that binary.
rm -f "$root/evidence/windows-destination/WV-01.json"
bash "$root/tools/run_fixture_windows.sh" WV-01 >/dev/null 2>&1 || true
rm -f "$root/evidence/windows-destination/WV-01.json"
say "EXE_SHA256_BEFORE=$(sha "$exe")"

ids=(WV-01 WV-02 WV-03 WV-04 WV-05 WV-06 WV-07 WV-08 WV-09 WV-10 WV-11 WV-12 WV-13 WV-14)
for id in "${ids[@]}"; do
  say "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RUN $id EXE_SHA256=$(sha "$exe")"
  output="$(bash "$root/tools/run_fixture_windows.sh" "$id" 2>&1)"
  status=$?
  report="$(printf '%s\n' "$output" | sed -n '/^{$/,$p')"
  if [[ -z "$report" ]]; then
    say "FAIL $id: no comparison report"
    printf '%s\n' "$output" | tail -25 | tee -a "$log"
    exit 1
  fi
  printf '%s\n' "$report" > "$reports/$id.json"
  verdict="$(printf '%s' "$report" | node -p 'JSON.parse(require("fs").readFileSync(0,"utf8")).comparisonVerdict')"
  say "  verdict=$verdict status=$status EXE_SHA256=$(sha "$exe")"
  if [[ $status -ne 0 ]]; then
    say "FAIL $id: comparison exited $status"
    printf '%s\n' "$report" | tee -a "$log"
    exit 1
  fi
done

say "EXE_SHA256_AFTER=$(sha "$exe")"
say "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DESTINATION-RUN-COMPLETE"
node -e '
const fs = require("fs");
const dir = process.argv[1];
const names = fs.readdirSync(dir).filter((name) => name.endsWith(".json")).sort();
const rows = names.map((name) => JSON.parse(fs.readFileSync(`${dir}/${name}`, "utf8")));
if (rows.length !== 14) throw Error(`expected 14 reports, got ${rows.length}`);
for (const row of rows) {
  if (row.differences.length !== 0) throw Error(`${row.fixtureId}: differences`);
  if (!["match", "match-race-alternative", "policy-rejected"].includes(row.comparisonVerdict)) {
    throw Error(`${row.fixtureId}: ${row.comparisonVerdict}`);
  }
}
const count = (verdict) => rows.filter((row) => row.comparisonVerdict === verdict).length;
console.log(
  `destination verification: ${count("match")} match, ` +
    `${count("match-race-alternative")} match against a declared race alternative, ` +
    `${count("policy-rejected")} policy-rejected`,
);
' "$reports" | tee -a "$log"
