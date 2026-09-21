#!/usr/bin/env node
// Writes a destination-adapter provenance manifest: the adapter sources,
// fixtures, evidence, comparison reports, run log, and the single application
// binary that produced them, each with its SHA-256. Everything it records is
// recomputable from the committed tree plus the recorded binary hash.
//
// Usage: write_destination_manifest.js [android|windows]
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');

const PLATFORMS = {
  android: {
    row: 'android-destination',
    target: 'android-destination-adapter',
    binaryKey: 'applicationApkSha256',
    sampleKey: 'applicationApkHashSamples',
    unchangedKey: 'applicationApkUnchangedAcrossSweep',
    hashPattern: /APK_SHA256(?:_BEFORE|_AFTER)?=([0-9a-f]{64})/g,
    runner: ['tools/run_fixture.sh', 'tools/run_all_destination.sh'],
  },
  windows: {
    row: 'windows-destination',
    target: 'windows-destination-adapter',
    binaryKey: 'applicationExecutableSha256',
    sampleKey: 'applicationExecutableHashSamples',
    unchangedKey: 'applicationExecutableUnchangedAcrossSweep',
    hashPattern: /EXE_SHA256(?:_BEFORE|_AFTER)?=([0-9a-f]{64})/g,
    runner: [
      'tools/run_fixture_windows.sh',
      'tools/run_all_destination_windows.sh',
      'tools/build_windows_harness.sh',
    ],
  },
};

const platformName = process.argv[2] ?? 'android';
const platform = PLATFORMS[platformName];
if (!platform) {
  console.error(`unknown platform "${platformName}"`);
  process.exit(2);
}
const evidenceDirectory = path.join(root, 'evidence', platform.row);

function sha256(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

function hashTree(directory, filter) {
  const result = {};
  for (const name of fs.readdirSync(directory).sort()) {
    const full = path.join(directory, name);
    if (!fs.statSync(full).isFile()) continue;
    if (!filter(name)) continue;
    result[name] = sha256(full);
  }
  return result;
}

function main() {
  const evidenceNames = fs
    .readdirSync(evidenceDirectory)
    .filter((name) => /^WV-\d\d\.json$/.test(name))
    .sort();
  if (evidenceNames.length !== 14) {
    throw Error(`expected 14 evidence files, got ${evidenceNames.length}`);
  }
  const evidence = evidenceNames.map((name) =>
    JSON.parse(fs.readFileSync(path.join(evidenceDirectory, name), 'utf8')),
  );
  const first = evidence[0];
  for (const record of evidence) {
    if (record.target !== platform.target) {
      throw Error(
        `${record.fixtureId}: evidence target is ${record.target}, expected ${platform.target}`,
      );
    }
    if (record.device?.fingerprint !== first.device?.fingerprint) {
      throw Error(`${record.fixtureId}: fingerprint differs`);
    }
    if (record.runtime?.webViewVersion !== first.runtime?.webViewVersion) {
      throw Error(`${record.fixtureId}: WebView version differs`);
    }
    if (record.baselineCommit !== first.baselineCommit) {
      throw Error(`${record.fixtureId}: baseline commit differs`);
    }
  }
  const reports = fs
    .readdirSync(path.join(evidenceDirectory, 'reports'))
    .filter((name) => name.endsWith('.json'))
    .sort()
    .map((name) =>
      JSON.parse(
        fs.readFileSync(path.join(evidenceDirectory, 'reports', name), 'utf8'),
      ),
    );

  const runLog = fs.readFileSync(path.join(evidenceDirectory, 'run.log'), 'utf8');
  // Every binary hash the log recorded, including one per fixture, must be the
  // same build; two endpoint samples alone would not detect a mid-sweep rebuild.
  const binaryHashes = [...runLog.matchAll(platform.hashPattern)].map(
    (match) => match[1],
  );
  if (binaryHashes.length < 16 || new Set(binaryHashes).size !== 1) {
    throw Error(
      `run log does not show one unchanged application binary across the sweep (${binaryHashes.length} samples, ${new Set(binaryHashes).size} distinct)`,
    );
  }

  // The recorded sources must be the ones that produced the evidence. A source
  // edited after the sweep would otherwise be hashed into a manifest that claims
  // to describe an older run.
  const sweepEnd = Date.parse(
    evidence
      .map((record) => record.restartCompletedAtUtc ?? record.completedAtUtc)
      .sort()
      .slice(-1)[0],
  );
  const adapterLib = path.join(root, 'adapter', 'lib');
  // The harness drives the product's adapter through a path dependency, so the
  // product files are part of what the evidence is attributable to, not only the
  // harness's own sources.
  const productAdapter = [
    path.join(root, '..', '..', 'lib', 'source', 'book_source_webview_adapter.dart'),
    path.join(root, '..', '..', 'lib', 'source', 'inappwebview_book_source_adapter.dart'),
  ];
  const edited = [
    ...fs
      .readdirSync(adapterLib)
      .filter((name) => name.endsWith('.dart'))
      .map((name) => path.join(adapterLib, name)),
    ...productAdapter,
  ].filter((file) => fs.statSync(file).mtimeMs > sweepEnd)
    .map((file) => path.relative(root, file));
  if (edited.length > 0) {
    throw Error(
      `adapter sources changed after the sweep completed, so this evidence is not attributable to them: ${edited.join(', ')}. Re-run the sweep.`,
    );
  }

  const goldenRow =
    platformName === 'android'
      ? (() => {
          // Two frozen goldens exist because the device's OS changed; a
          // destination must be attributed to the one matching its own
          // fingerprint rather than to a hardcoded directory.
          const candidates = fs
            .readdirSync(path.join(root, 'evidence'))
            .filter((name) => /^android(-\d+)?$/.test(name));
          for (const name of candidates) {
            const candidate = path.join(root, 'evidence', name, 'manifest.json');
            if (!fs.existsSync(candidate)) continue;
            const golden = JSON.parse(fs.readFileSync(candidate, 'utf8'));
            if (golden.device?.fingerprint === first.device?.fingerprint) {
              return `evidence/${name}`;
            }
          }
          throw Error(
            `no frozen golden matches the destination fingerprint ${first.device?.fingerprint}`,
          );
        })()
      : 'evidence/android';

  const manifest = {
    schemaVersion: 1,
    target: platform.target,
    baselineCommit: first.baselineCommit,
    goldenEvidence: goldenRow,
    adapter: {
      implementation: 'flutter_inappwebview',
      [platform.binaryKey]: binaryHashes[0],
      [platform.unchangedKey]: true,
      [platform.sampleKey]: binaryHashes.length,
    },
    device: first.device,
    runtime: first.runtime,
    run: {
      startedAtUtc: evidence
        .map((record) => record.startedAtUtc)
        .sort()[0],
      completedAtUtc: evidence
        .map((record) => record.restartCompletedAtUtc ?? record.completedAtUtc)
        .sort()
        .slice(-1)[0],
      logSha256: sha256(path.join(evidenceDirectory, 'run.log')),
    },
    verdicts: Object.fromEntries(
      evidence.map((record) => [record.fixtureId, record.executionVerdict]),
    ),
    comparisonVerdicts: Object.fromEntries(
      reports.map((report) => [report.fixtureId, report.comparisonVerdict]),
    ),
    matchedGoldenTrace: Object.fromEntries(
      reports
        .filter((report) => report.matchedGoldenTrace)
        .map((report) => [report.fixtureId, report.matchedGoldenTrace]),
    ),
    adapterSourceSha256: {
      ...hashTree(
        path.join(root, 'adapter', 'lib'),
        (name) => name.endsWith('.dart'),
      ),
      'liber:lib/source/book_source_webview_adapter.dart': sha256(productAdapter[0]),
      'liber:lib/source/inappwebview_book_source_adapter.dart': sha256(productAdapter[1]),
    },
    harnessSha256: {
      'integration_test/destination_test.dart': sha256(
        path.join(root, 'adapter', 'integration_test', 'destination_test.dart'),
      ),
      'test_driver/integration_test.dart': sha256(
        path.join(root, 'adapter', 'test_driver', 'integration_test.dart'),
      ),
      'tools/compare_to_golden.js': sha256(
        path.join(root, 'tools', 'compare_to_golden.js'),
      ),
      'tools/merge_restart_evidence.js': sha256(
        path.join(root, 'tools', 'merge_restart_evidence.js'),
      ),
      ...Object.fromEntries(
        platform.runner.map((relative) => [
          relative,
          sha256(path.join(root, relative)),
        ]),
      ),
      'tools/write_destination_manifest.js': sha256(__filename),
      'adapter/tool/sync_fixtures.sh': sha256(
        path.join(root, 'adapter', 'tool', 'sync_fixtures.sh'),
      ),
      'adapter/pubspec.yaml': sha256(path.join(root, 'adapter', 'pubspec.yaml')),
      'adapter/pubspec.lock': sha256(path.join(root, 'adapter', 'pubspec.lock')),
      [`${goldenRow}/manifest.json`]: sha256(
        path.join(root, goldenRow, 'manifest.json'),
      ),
    },
    toolchain: {
      flutterVersion: (() => {
        const output = require('child_process')
          .execSync('fvm flutter --version --machine', {
            cwd: path.join(root, 'adapter'),
            encoding: 'utf8',
            stdio: ['ignore', 'pipe', 'ignore'],
          })
          .trim();
        const parsed = JSON.parse(output.slice(output.indexOf('{')));
        return {
          frameworkVersion: parsed.frameworkVersion,
          dartSdkVersion: parsed.dartSdkVersion,
          frameworkRevision: parsed.frameworkRevision,
        };
      })(),
    },
    fixtureSha256: hashTree(path.join(root, 'fixtures'), (name) =>
      /^WV-\d\d\.json$/.test(name),
    ),
    evidenceSha256: hashTree(evidenceDirectory, (name) =>
      /^WV-\d\d\.json$/.test(name),
    ),
    reportSha256: hashTree(
      path.join(evidenceDirectory, 'reports'),
      (name) => name.endsWith('.json'),
    ),
  };

  const output = path.join(evidenceDirectory, 'manifest.json');
  fs.writeFileSync(output, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`wrote ${path.relative(root, output)}`);
}

main();
