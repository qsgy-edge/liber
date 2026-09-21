#!/usr/bin/env node
// Folds a restart-phase evidence file into its fixture's main evidence file, in
// the same shape the frozen oracle produces: the restart observations land under
// `restart`, its checks are re-keyed with a `restart_` prefix and merged into the
// fixture's checks, and the verdict is recomputed over the merged set.
'use strict';

const fs = require('fs');

function main() {
  const [mainPath, restartPath] = process.argv.slice(2);
  if (!mainPath || !restartPath) {
    console.error('usage: merge_restart_evidence.js <main.json> <restart.json>');
    process.exit(2);
  }
  const evidence = JSON.parse(fs.readFileSync(mainPath, 'utf8'));
  const restart = JSON.parse(fs.readFileSync(restartPath, 'utf8'));
  if (evidence.fixtureId !== restart.fixtureId) {
    console.error(
      `fixture mismatch: ${evidence.fixtureId} vs ${restart.fixtureId}`,
    );
    process.exit(2);
  }
  if (evidence.fixtureSha256 !== restart.fixtureSha256) {
    console.error('restart phase used different fixture bytes');
    process.exit(2);
  }
  if (restart.device?.fingerprint !== evidence.device?.fingerprint) {
    console.error('restart phase ran on a different device fingerprint');
    process.exit(2);
  }
  if (restart.runtime?.webViewVersion !== evidence.runtime?.webViewVersion) {
    console.error('restart phase ran on a different WebView version');
    process.exit(2);
  }
  if (restart.baselineCommit !== evidence.baselineCommit) {
    console.error('restart phase names a different baseline commit');
    process.exit(2);
  }
  if (restart.failure) {
    console.error(`restart phase failed: ${restart.failure}`);
    process.exit(1);
  }

  const restartBlock = restart.restart ?? {};
  const checks = { ...evidence.checks };
  for (const [name, value] of Object.entries(restartBlock.checks ?? {})) {
    checks[`restart_${name}`] = value;
  }
  evidence.restart = restartBlock;
  evidence.checks = checks;
  evidence.restartCompletedAtUtc = restart.completedAtUtc;
  evidence.restartProvenance = {
    device: restart.device,
    runtime: restart.runtime,
    startedAtUtc: restart.startedAtUtc,
  };
  evidence.executionVerdict = Object.values(checks).every((value) => value === true)
    ? 'pass'
    : 'fail';
  fs.writeFileSync(
    mainPath,
    `${JSON.stringify(evidence, null, 2)}\n`,
  );
  if (evidence.executionVerdict !== 'pass') {
    const failed = Object.entries(checks)
      .filter(([, value]) => value !== true)
      .map(([name]) => name);
    console.error(`merged verdict is fail; failed checks: ${failed.join(', ')}`);
    process.exit(1);
  }
  console.log(`merged restart evidence into ${mainPath}`);
}

main();
