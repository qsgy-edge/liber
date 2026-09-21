#!/usr/bin/env bash
# Runs every destination fixture once, in order, against the frozen golden and
# stops at the first fixture that neither matches nor is policy-rejected.
#
# Accepted destination evidence must come from one build, so the APK is built
# once up front, hashed, and then reused for every fixture through
# `--use-application-binary`; every recorded hash must be identical. Letting the
# driver rebuild per fixture would change the APK between fixtures and make the
# evidence unattributable to one build.
#
# The build target must be the integration test entrypoint. An APK built from
# `lib/main.dart` runs the host app instead of the test, so the driver connects,
# finds no test, and no evidence is written.
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
root="$(cygpath -m "$root" 2>/dev/null || printf '%s' "$root")"
apk="$root/adapter/build/app/outputs/flutter-apk/app-debug.apk"
reports="$root/evidence/android-destination/reports"
log="$root/evidence/android-destination/run.log"
mkdir -p "$reports"
: > "$log"

sha() { sha256sum "$1" | cut -d' ' -f1; }
say() { printf '%s\n' "$*" | tee -a "$log"; }

say "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] DESTINATION-RUN-BEGIN"
(cd "$root/adapter" && fvm flutter build apk --debug --no-pub --target=integration_test/destination_test.dart 2>&1 | tr -d '
' | tail -2) | tee -a "$log"
say "APK_SHA256_BEFORE=$(sha "$apk")"

ids=(WV-01 WV-02 WV-03 WV-04 WV-05 WV-06 WV-07 WV-08 WV-09 WV-10 WV-11 WV-12 WV-13 WV-14)
for id in "${ids[@]}"; do
  say "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] RUN $id APK_SHA256=$(sha "$apk")"
  output="$(bash "$root/tools/run_fixture.sh" "$id" 2>&1)"
  status=$?
  report="$(printf '%s\n' "$output" | sed -n '/^{$/,$p')"
  if [[ -z "$report" ]]; then
    say "FAIL $id: no comparison report"
    printf '%s\n' "$output" | tail -20 | tee -a "$log"
    exit 1
  fi
  printf '%s\n' "$report" > "$reports/$id.json"
  verdict="$(printf '%s' "$report" | node -p 'JSON.parse(require("fs").readFileSync(0,"utf8")).comparisonVerdict')"
  say "  verdict=$verdict status=$status APK_SHA256=$(sha "$apk")"
  if [[ $status -ne 0 ]]; then
    say "FAIL $id: comparison exited $status"
    printf '%s\n' "$report" | tee -a "$log"
    exit 1
  fi
done

say "APK_SHA256_AFTER=$(sha "$apk")"
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
