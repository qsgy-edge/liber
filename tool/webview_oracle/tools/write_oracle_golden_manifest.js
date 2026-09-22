#!/usr/bin/env node
// Writes a frozen-oracle golden manifest from the evidence an oracle run pulled.
//
// The destination comparison reads a golden's `manifest.json` for the device
// fingerprint it must match and for the WebView version it records, and the
// destination manifest writer reads it to attribute an Android row to the golden
// of its own fingerprint. The archived goldens' manifests were written by a
// script that was not part of the archived prototype, so this restore carries
// one: it derives every field from the run's own artifacts rather than from
// anything typed by hand.
//
// Usage: write_oracle_golden_manifest.js <golden-directory-name>
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const name = process.argv[2];
if (!name) {
  console.error('usage: write_oracle_golden_manifest.js <golden-directory-name>');
  process.exit(2);
}
const directory = path.join(root, 'evidence', name);
if (!fs.existsSync(directory)) {
  console.error(`no such golden directory: ${path.relative(root, directory)}`);
  process.exit(2);
}

const sha256 = (file) =>
  crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');

const hashTree = (directory, filter) => {
  const result = {};
  for (const entry of fs.readdirSync(directory).sort()) {
    const full = path.join(directory, entry);
    if (!fs.statSync(full).isFile() || !filter(entry)) continue;
    result[entry] = sha256(full);
  }
  return result;
};

/** The `KEY=VALUE` lines an oracle run logs before it starts. */
function provenance(log) {
  const result = {};
  for (const match of log.matchAll(/^([A-Z0-9_]+)=(.*)$/gm)) {
    result[match[1]] = match[2];
  }
  for (const match of log.matchAll(/^FIXTURE_SHA256 (\S+) ([0-9a-f]{64})$/gm)) {
    result[`FIXTURE ${match[1]}`] = match[2];
  }
  return result;
}

const required = [
  'BASELINE',
  'FINGERPRINT',
  'WEBVIEW',
  'APP_SHA256',
  'TEST_SHA256',
  'HARNESS_SHA256',
  'DEVICE_APP_SHA256',
  'DEVICE_TEST_SHA256',
];

const logPath = path.join(directory, 'run.log');
const log = fs.readFileSync(logPath, 'utf8');
const run = provenance(log);
const missing = required.filter((key) => !run[key]);
if (missing.length > 0) {
  throw Error(`run log does not record: ${missing.join(', ')}`);
}

const names = fs
  .readdirSync(directory)
  .filter((entry) => /^WV-\d\d\.json$/.test(entry))
  .sort();
if (names.length !== 14) {
  throw Error(`expected 14 evidence files, got ${names.length}`);
}
const evidence = names.map((entry) =>
  JSON.parse(fs.readFileSync(path.join(directory, entry), 'utf8')),
);
const first = evidence[0];
for (const record of evidence) {
  if (record.baselineCommit !== first.baselineCommit) {
    throw Error(`${record.fixtureId}: baseline commit differs`);
  }
  if (record.device?.fingerprint !== first.device?.fingerprint) {
    throw Error(`${record.fixtureId}: fingerprint differs`);
  }
  if (record.runtime?.webViewVersion !== first.runtime?.webViewVersion) {
    throw Error(`${record.fixtureId}: WebView version differs`);
  }
  if (record.executionVerdict !== 'pass' && record.executionVerdict !== 'policy-rejected') {
    throw Error(`${record.fixtureId}: verdict ${record.executionVerdict}`);
  }
  if (Object.values(record.checks || {}).some((value) => value !== true)) {
    throw Error(`${record.fixtureId}: a recorded check is false`);
  }
}
// The run's own provenance must agree with the evidence it produced: a golden
// whose log names another device or another WebView than its rows do is not
// attributable to what it claims to describe.
if (run.FINGERPRINT !== first.device?.fingerprint) {
  throw Error(`run log fingerprint ${run.FINGERPRINT} != evidence ${first.device?.fingerprint}`);
}
if (run.WEBVIEW !== first.runtime?.webViewVersion) {
  throw Error(`run log WebView ${run.WEBVIEW} != evidence ${first.runtime?.webViewVersion}`);
}
if (run.BASELINE !== first.baselineCommit) {
  throw Error(`run log baseline ${run.BASELINE} != evidence ${first.baselineCommit}`);
}

const fixtureSha256 = hashTree(path.join(root, 'fixtures'), (entry) =>
  /^WV-\d\d\.json$/.test(entry),
);
for (const [entry, hash] of Object.entries(fixtureSha256)) {
  if (run[`FIXTURE ${entry}`] !== hash) {
    throw Error(`${entry}: the run recorded ${run[`FIXTURE ${entry}`]}, the file is ${hash}`);
  }
}

const manifest = {
  schemaVersion: 1,
  target: 'frozen-legado-android-oracle',
  baselineCommit: first.baselineCommit,
  device: first.device,
  runtime: first.runtime,
  applicationApkSha256: run.APP_SHA256,
  instrumentationApkSha256: run.TEST_SHA256,
  installedApplicationApkSha256: run.DEVICE_APP_SHA256,
  installedInstrumentationApkSha256: run.DEVICE_TEST_SHA256,
  harnessSha256: {
    'oracle/android/Ticket13OracleTest.kt': run.HARNESS_SHA256,
  },
  fixtureSha256,
  evidenceSha256: hashTree(directory, (entry) => /^WV-\d\d\.json$/.test(entry)),
  run: {
    startedAtUtc: evidence.map((record) => record.startedAtUtc).sort()[0],
    completedAtUtc: evidence
      .map((record) => record.completedAtUtc ?? record.startedAtUtc)
      .sort()
      .slice(-1)[0],
    logSha256: sha256(logPath),
  },
  verdicts: Object.fromEntries(
    evidence.map((record) => [record.fixtureId, record.executionVerdict]),
  ),
};

// Declared race diagnostics are the only part of this manifest that is not
// derived from the run: the comparator widens a permitted trace only for a file
// the manifest declares, so the declaration is carried over from the manifest
// being rewritten while its bytes are re-hashed here. A declaration whose file
// is missing or whose bytes changed fails instead of silently disappearing.
const manifestPath = path.join(directory, 'manifest.json');
if (fs.existsSync(manifestPath)) {
  const declared = JSON.parse(fs.readFileSync(manifestPath, 'utf8')).diagnosticEvidence;
  if (declared) {
    for (const [name, entry] of Object.entries(declared)) {
      const file = path.join(directory, 'diagnostics', name);
      if (!fs.existsSync(file)) {
        throw Error(`declared diagnostic ${name} is missing`);
      }
      const actual = sha256(file);
      if (actual !== entry.sha256) {
        throw Error(`declared diagnostic ${name} changed: ${actual}`);
      }
    }
    manifest.diagnosticEvidence = declared;
  }
}

const output = path.join(directory, 'manifest.json');
fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(`wrote ${path.relative(root, output)}`);
