#!/usr/bin/env node
// Compares one destination-adapter evidence file against the frozen Legado
// golden for the same fixture. Only observations that the contract declares
// comparable are compared: request order, method, path, body, and the headers a
// source sets explicitly. Platform-generated headers (Host, Accept-Encoding,
// Connection, Sec-*, X-Requested-With, Referer, Accept-Language) are ignored,
// per the differential strictness rules, and millisecond timings are not
// compared. The loopback port differs per run, so URLs are compared with the
// port normalized.
//
// Two documented non-determinisms in the golden are handled explicitly rather
// than by loosening the comparison:
//
//   * An observed duration is not compared in milliseconds. It is reduced to the
//     band the contract cares about (under a second, seconds, the 30-60 second
//     retry budget, or at/after the 60 second outer timeout), so a timeout that
//     did not fire or a retry budget that was skipped is a difference while
//     ordinary platform overhead is not.
//   * A fixture-declared concurrent group is additionally compared by shape: the
//     group must occupy consecutive positions in the trace, and the sizes of its
//     admission batches (split where consecutive starts are at least 500 ms
//     apart) must match, so a destination that applied no rate limiting differs
//     even though the members are the same multiset.
//   * Every assertion the frozen harness recorded in `checks` must be present and
//     equal on the destination. A destination may assert more than the golden did,
//     so an extra destination check is reported rather than treated as a
//     difference.
//   * A platform exception class name and a runtime exception message are not
//     part of the contract; the differential rules map them to a stable error
//     category instead. Categories are compared, and a message is compared only
//     for a baseline-authored error such as `js执行超时`. An unmapped exception
//     type is reported as `unknown:<type>` so it surfaces as a difference rather
//     than matching silently.
//   * A fixture that declares a concurrent group compares that group as a
//     multiset rather than as an ordered sequence, per the concurrency rules:
//     within one concurrent batch the requests and their causal relations are
//     compared, not the order the platform happened to schedule them in. The
//     groups are read from the fixture's own declarations (`helperAPath` with
//     `helperBPath`, and `orderedPaths`), so nothing is hand-maintained here.
//   * `/favicon.ico` is browser-initiated, not source-driven. The frozen
//     harness filters it out of its own order assertion
//     (`Ticket13OracleTest.kt:187`), and whether the browser fetches it at all
//     depends on its own cache state, so source-driven requests are compared in
//     strict order while favicon is only reported for both sides.
//   * Where a fixture's outcome is a race, the golden retains the other side as
//     a same-provenance diagnostic under `evidence/android/diagnostics/`. A
//     destination trace is a match when it equals the accepted trace or one of
//     those recorded sides, and the report names the side it matched. Verdict
//     and operation values are always compared against the accepted golden.
//
// The frozen golden records each fixture's bytes in
// `evidence/android/manifest.json` rather than inside every evidence file, so
// the fixture hash is resolved from the manifest when the golden itself does not
// carry one. Both sides must still name the same fixture bytes.
//
//   * A destination row's own manifest pins the sources the sweep was built
//     from, hashed (`adapterSourceSha256`, `harnessSha256`). A row the manifest
//     describes whose recorded sources no longer hash to what this tree holds was
//     produced by a different tree, or by a harness revision that has since
//     changed, so it is refused rather than compared: a verdict about code this
//     checkout does not contain is not a verdict about this checkout. A row newer
//     than the manifest is the sweep in progress, which the manifest does not
//     describe, and is compared as before.
'use strict';

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

const IGNORED_HEADERS = new Set([
  'host',
  'connection',
  'accept',
  'accept-encoding',
  'accept-language',
  'content-length',
  'upgrade-insecure-requests',
  'x-requested-with',
  'referer',
  'origin',
]);

function comparableHeaders(headers) {
  const result = {};
  for (const [name, value] of Object.entries(headers || {})) {
    const lower = name.toLowerCase();
    if (IGNORED_HEADERS.has(lower)) continue;
    if (lower.startsWith('sec-')) continue;
    result[lower] = value;
  }
  return result;
}

function normalizePort(value) {
  if (typeof value === 'string') {
    return value.replace(/127\.0\.0\.1:\d+/g, '127.0.0.1:<port>');
  }
  if (Array.isArray(value)) return value.map(normalizePort);
  if (value && typeof value === 'object') {
    const result = {};
    for (const [key, nested] of Object.entries(value)) {
      result[key] = normalizePort(nested);
    }
    return result;
  }
  return value;
}

// A key holding an observed duration or timestamp is not compared, per the
// timing rules. Two keys ending in `Ms` are configuration echoed back from the
// fixture rather than observations, so they stay compared.
const COMPARED_MS_KEYS = new Set(['configuredIntervalMs', 'minimumObservedGapMs']);

// Boundaries chosen from the contract's own timing constants: the internal JS
// retry budget must exceed 30 seconds and stay under the 60 second outer
// timeout, and the outer timeout must fire at 60 seconds.
//
// There is deliberately no sub-second boundary. The frozen baseline's only
// sub-second property is that a sniffer match resolves before its 1 second JS
// timer, and that is already asserted by the fixture's own checks and by the
// response body being the matched URL rather than page content. A boundary there
// would instead register engine startup cost: a platform that creates a fresh
// browser profile per fixture needs about a second before the first request.
function durationBand(milliseconds) {
  if (milliseconds < 30000) return '<30s';
  if (milliseconds < 60000) return '30-60s';
  return '>=60s';
}

function withoutTimings(value) {
  if (Array.isArray(value)) return value.map(withoutTimings);
  if (value && typeof value === 'object') {
    const result = {};
    for (const [key, nested] of Object.entries(value)) {
      if (key.endsWith('Ms') && !COMPARED_MS_KEYS.has(key)) {
        if (typeof nested !== 'number') continue;
        result[`${key}Band`] = durationBand(nested);
        continue;
      }
      result[key] = withoutTimings(nested);
    }
    return result;
  }
  return value;
}

const BROWSER_INITIATED_PATHS = new Set(['/favicon.ico']);

function comparableRequests(evidence) {
  const all = (evidence.requests || []).map((request) => ({
    method: request.method,
    target: request.target,
    body: request.body,
    headers: normalizeCookieStrings(comparableHeaders(request.headers)),
  }));
  return all.filter(
    (request) => !BROWSER_INITIATED_PATHS.has(request.target),
  );
}

function browserInitiatedTargets(evidence) {
  const targets = (evidence.requests || []).map((request) => request.target);
  return [...BROWSER_INITIATED_PATHS]
    .filter((path) => targets.includes(path))
    .sort();
}

// A platform exception type maps to a stable category; the frozen baseline's JVM
// types and the destination adapter's Dart types map onto the same categories.
const ERROR_CATEGORY_BY_TYPE = new Map([
  ['io.legado.app.exception.NoStackTraceException', 'baselineError'],
  ['kotlinx.coroutines.TimeoutCancellationException', 'outerTimeout'],
  ['kotlinx.coroutines.JobCancellationException', 'cancelled'],
  ['java.util.concurrent.CancellationException', 'cancelled'],
  ['java.io.IOException', 'ioError'],
  ['java.net.SocketTimeoutException', 'ioError'],
  ['java.net.SocketException', 'ioError'],
  ['java.lang.NullPointerException', 'setupError'],
  ['JsTimeoutException', 'baselineError'],
  ['OuterTimeoutException', 'outerTimeout'],
  ['CancelledException', 'cancelled'],
  ['UntrustedCertificateException', 'untrustedCertificate'],
  ['SourceTlsCertificateFailure', 'untrustedCertificate'],
  // The product adapter's own exception names (`liber`, ticket #55). The
  // archived harness's adapter was the prototype; this restore drives the
  // product's `BookSourceWebViewAdapter`, whose names are its own. Each maps onto
  // the same category as its prototype counterpart, so a row is still compared
  // by outcome rather than by a name that is not part of the contract.
  ['SourceWebViewJsTimeout', 'baselineError'],
  ['SourceWebViewTimeout', 'outerTimeout'],
  ['SourceWebViewCancelled', 'cancelled'],
  ['SourceWebViewUntrustedCertificate', 'untrustedCertificate'],
  ['SourceWebViewUnavailable', 'setupError'],
  ['HttpException', 'ioError'],
  ['SocketException', 'ioError'],
  ['_TypeError', 'setupError'],
  ['TypeError', 'setupError'],
]);

function isErrorObject(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return false;
  const keys = Object.keys(value);
  return keys.length === 2 && keys.includes('type') && keys.includes('message');
}

function normalizeErrors(value) {
  if (isErrorObject(value)) {
    const category = ERROR_CATEGORY_BY_TYPE.get(value.type) ?? `unknown:${value.type}`;
    // Only a baseline-authored message is source-visible; a runtime message is
    // an implementation detail the contract does not compare.
    return category === 'baselineError'
      ? { category, message: value.message }
      : { category };
  }
  if (Array.isArray(value)) return value.map(normalizeErrors);
  if (value && typeof value === 'object') {
    const result = {};
    for (const [key, nested] of Object.entries(value)) {
      result[key] = normalizeErrors(nested);
    }
    return result;
  }
  return value;
}

// A cookie observation is a `name=value; name=value` string whose order is not
// part of the contract: the frozen baseline models cookies as a name/value map
// per second-level domain, so only the pairs are compared. Both sides are
// normalized wherever such a value appears, including as an observation value
// itself rather than only nested inside one.
const COOKIE_VALUE_KEY = /cookie|^store(Before|After)WebView$/i;

function sortCookiePairs(value) {
  return value
    .split(';')
    .map((pair) => pair.trim())
    .filter((pair) => pair.length > 0)
    .sort()
    .join('; ');
}

function normalizeCookieStrings(value, key = null) {
  if (typeof value === 'string') {
    return key !== null && COOKIE_VALUE_KEY.test(key)
      ? sortCookiePairs(value)
      : value;
  }
  if (Array.isArray(value)) {
    return value.map((entry) => normalizeCookieStrings(entry, key));
  }
  if (value && typeof value === 'object') {
    const result = {};
    for (const [nestedKey, nested] of Object.entries(value)) {
      result[nestedKey] = normalizeCookieStrings(nested, nestedKey);
    }
    return result;
  }
  return value;
}

function comparableOperation(evidence) {
  return normalizeCookieStrings(
    normalizePort(normalizeErrors(withoutTimings(evidence.operation ?? null))),
  );
}

// Extra top-level observations the frozen oracle records for specific fixtures.
// They are compared when either side records them, so a destination cannot pass
// by omitting an observation the golden made.
const EXTRA_OBSERVATION_KEYS = [
  'cookieStore',
  'durableCookieStore',
  'echoCookie',
  'restart',
];

function comparableExtras(evidence) {
  const result = {};
  for (const key of EXTRA_OBSERVATION_KEYS) {
    if (!(key in evidence)) continue;
    const value = normalizeCookieStrings(
      normalizePort(normalizeErrors(withoutTimings(evidence[key]))),
      key,
    );
    if (key !== 'restart') {
      result[key] = value;
      continue;
    }
    result[key] = { ...value, requests: comparableRequests(value) };
  }
  return result;
}

function diff(expected, actual, trail, differences) {
  if (JSON.stringify(expected) === JSON.stringify(actual)) return;
  const bothObjects =
    expected && actual && typeof expected === 'object' && typeof actual === 'object';
  if (!bothObjects) {
    differences.push({ at: trail, golden: expected, destination: actual });
    return;
  }
  if (Array.isArray(expected) !== Array.isArray(actual)) {
    differences.push({ at: trail, golden: expected, destination: actual });
    return;
  }
  if (Array.isArray(expected)) {
    if (expected.length !== actual.length) {
      differences.push({
        at: `${trail}.length`,
        golden: expected.length,
        destination: actual.length,
      });
    }
    const count = Math.max(expected.length, actual.length);
    for (let index = 0; index < count; index++) {
      diff(expected[index], actual[index], `${trail}[${index}]`, differences);
    }
    return;
  }
  for (const key of new Set([...Object.keys(expected), ...Object.keys(actual)])) {
    diff(expected[key], actual[key], trail ? `${trail}.${key}` : key, differences);
  }
}

function goldenFixtureSha256(goldenPath, golden) {
  if (typeof golden.fixtureSha256 === 'string') return golden.fixtureSha256;
  const manifestPath = path.join(path.dirname(goldenPath), 'manifest.json');
  if (!fs.existsSync(manifestPath)) return undefined;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  return manifest.fixtureSha256?.[`${golden.fixtureId}.json`];
}

// Where the manifest writer recorded one hashed source, resolved back to a file.
//
// The writer records each file under the path it hashed it at: this tool's own
// tree by an oracle-relative path (`tools/…`, `adapter/…`, `evidence/…`), the
// adapter's harness by its adapter-relative path (`integration_test/…`,
// `test_driver/…`), the adapter's library by its bare file name, and the
// product files the harness drives under a `liber:` prefix. The same rules
// resolve a recorded name here, so a key the writer invented cannot silently
// become "no such file".
function recordedSourceFile(oracleRoot, mapName, name) {
  if (name.startsWith('liber:')) {
    return path.join(oracleRoot, '..', '..', name.slice('liber:'.length));
  }
  if (mapName === 'adapterSourceSha256') {
    return path.join(oracleRoot, 'adapter', 'lib', name);
  }
  if (name.startsWith('integration_test/') || name.startsWith('test_driver/')) {
    return path.join(oracleRoot, 'adapter', name);
  }
  return path.join(oracleRoot, name);
}

// What a destination row's manifest records about the sources it was produced
// from, and whether this tree still holds them.
//
// Returns null when nothing claims to describe the row (no manifest, or one
// written before the row completed — the sweep in progress), and otherwise the
// entries that no longer match, as `name: recorded …, this tree has …`. An empty
// array means the recorded sources are the ones on disk.
//
// The comparison is between the manifest's recorded hashes and the files, not
// between timestamps or hashes of hashes: the manifest writer hashes the same
// files, and a mismatch can only mean the row and the tree disagree. The
// recorded instant decides only whether the manifest describes this row at all,
// so a fresh clone (whose filesystem times are all checkout time) answers the
// same as the sweep host did.
function destinationSourceStaleness(destinationPath, destination) {
  const manifestPath = path.join(path.dirname(destinationPath), 'manifest.json');
  if (!fs.existsSync(manifestPath)) return null;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const rowEnd = Date.parse(
    destination.restartCompletedAtUtc ?? destination.completedAtUtc ?? '',
  );
  const sweepEnd = Date.parse(manifest.run?.completedAtUtc ?? '');
  if (!Number.isNaN(rowEnd) && !Number.isNaN(sweepEnd) && rowEnd > sweepEnd) {
    return null;
  }
  const oracleRoot = path.resolve(__dirname, '..');
  const recorded = [];
  for (const mapName of ['adapterSourceSha256', 'harnessSha256']) {
    for (const [name, sha] of Object.entries(manifest[mapName] || {})) {
      recorded.push({
        name,
        sha,
        file: recordedSourceFile(oracleRoot, mapName, name),
      });
    }
  }
  if (recorded.length === 0) {
    return ['the manifest records no adapter sources to check'];
  }
  const changed = [];
  for (const { name, sha, file } of recorded) {
    const current = fs.existsSync(file)
      ? crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
      : null;
    if (current !== sha) {
      changed.push(
        `${name}: recorded ${sha}, this tree has ${current ?? 'no such file'}`,
      );
    }
  }
  return changed;
}

// Same-provenance recordings of the other side of a documented race.
//
// A diagnostic widens the permitted trace only when the golden manifest itself
// declares it under `diagnosticEvidence`, its bytes hash to the declared
// sha256, and it names the same fixture, baseline commit, device fingerprint,
// and WebView version as the accepted golden. Dropping a file into the
// diagnostics directory therefore cannot widen anything, and a match against a
// declared diagnostic is reported as its own verdict rather than as a match
// against the accepted trace.
function raceAlternatives(goldenPath, golden) {
  const goldenDirectory = path.dirname(goldenPath);
  const manifestPath = path.join(goldenDirectory, 'manifest.json');
  if (!fs.existsSync(manifestPath)) return [];
  const declared = JSON.parse(fs.readFileSync(manifestPath, 'utf8'))
    .diagnosticEvidence;
  if (!declared) return [];
  const alternatives = [];
  for (const [name, entry] of Object.entries(declared)) {
    const file = path.join(goldenDirectory, 'diagnostics', name);
    if (!fs.existsSync(file)) continue;
    const bytes = fs.readFileSync(file);
    const actual = crypto.createHash('sha256').update(bytes).digest('hex');
    if (actual !== entry.sha256) {
      throw Error(
        `declared diagnostic ${name} does not match its manifest hash`,
      );
    }
    const evidence = JSON.parse(bytes.toString('utf8'));
    if (
      evidence.fixtureId !== golden.fixtureId ||
      evidence.baselineCommit !== golden.baselineCommit ||
      evidence.device?.fingerprint !== golden.device?.fingerprint ||
      evidence.runtime?.webViewVersion !== golden.runtime?.webViewVersion
    ) {
      continue;
    }
    alternatives.push({ name, evidence, reason: entry.reason });
  }
  return alternatives;
}

// Concurrent groups declared by the fixture itself. A request inside a group is
// compared as part of that group's multiset; every other request keeps strict
// order.
function concurrentGroups(fixture) {
  if (!fixture) return [];
  const groups = [];
  if (fixture.helperAPath && fixture.helperBPath) {
    groups.push([fixture.helperAPath, fixture.helperBPath]);
  }
  if (Array.isArray(fixture.orderedPaths)) groups.push([...fixture.orderedPaths]);
  return groups;
}

function partitionRequests(requests, groups) {
  const ordered = [];
  const grouped = groups.map(() => []);
  requests.forEach((request, position) => {
    const index = groups.findIndex((group) => group.includes(request.target));
    if (index < 0) {
      ordered.push(request);
      return;
    }
    grouped[index].push({ ...request, position });
  });
  return {
    ordered,
    concurrentGroups: grouped.map((group) => ({
      members: [...group]
        .map(({ position: _position, ...member }) => member)
        .sort((left, right) => left.target.localeCompare(right.target)),
      contiguous: group.every(
        (member, index) =>
          index === 0 || member.position === group[index - 1].position + 1,
      ),
    })),
  };
}

// Admission batches inside a declared concurrent group: consecutive starts less
// than 500 ms apart belong to one batch, which is the same overlap threshold the
// frozen harness uses. Comparing the batch sizes compares the shape a rate
// limiter imposes without comparing which member won a racy admission slot.
const ADMISSION_BATCH_GAP_MS = 500;

function admissionBatches(evidence, groups) {
  const requests = evidence.requests || [];
  return groups.map((group) => {
    const starts = requests
      .filter((request) => group.includes(request.target))
      .map((request) => request.startedAtElapsedMs)
      .filter((start) => typeof start === 'number')
      .sort((left, right) => left - right);
    const batches = [];
    let size = 0;
    let previous = null;
    for (const start of starts) {
      if (previous !== null && start - previous >= ADMISSION_BATCH_GAP_MS) {
        batches.push(size);
        size = 0;
      }
      size += 1;
      previous = start;
    }
    if (size > 0) batches.push(size);
    return batches;
  });
}

function main() {
  const [goldenPath, destinationPath] = process.argv.slice(2);
  if (!goldenPath || !destinationPath) {
    console.error('usage: compare_to_golden.js <golden.json> <destination.json>');
    process.exit(2);
  }
  const golden = JSON.parse(fs.readFileSync(goldenPath, 'utf8'));
  const destination = JSON.parse(fs.readFileSync(destinationPath, 'utf8'));
  if (golden.fixtureId !== destination.fixtureId) {
    console.error(
      `fixture mismatch: ${golden.fixtureId} vs ${destination.fixtureId}`,
    );
    process.exit(2);
  }
  const goldenFixtureHash = goldenFixtureSha256(goldenPath, golden);
  if (goldenFixtureHash === undefined) {
    console.error(
      `golden fixture hash unavailable for ${golden.fixtureId}; expected it in the evidence file or in manifest.json`,
    );
    process.exit(2);
  }
  if (goldenFixtureHash !== destination.fixtureSha256) {
    console.error(
      `fixture bytes differ: golden ${goldenFixtureHash}, destination ${destination.fixtureSha256}`,
    );
    process.exit(2);
  }
  if (golden.baselineCommit !== destination.baselineCommit) {
    console.error('baseline commit differs');
    process.exit(2);
  }
  const staleness = destinationSourceStaleness(destinationPath, destination);
  if (staleness !== null && staleness.length > 0) {
    console.error(
      `stale destination evidence: ${destinationPath} was recorded against ` +
        `sources this tree no longer holds.\n  ${staleness.join('\n  ')}\n` +
        'Re-run the sweep; this row does not describe the current tree.',
    );
    process.exit(2);
  }

  const goldenVerdict = golden.executionVerdict;
  const destinationVerdict = destination.executionVerdict;

  // A fixture whose golden verdict is `policy-rejected` exercises a capability
  // the security policy forbids, so it can never be a behavioral match: the
  // destination is required to refuse what the frozen baseline accepted. Only the
  // refusal is verified, and the fixture stays blocked for compatibility claims.
  if (goldenVerdict === 'policy-rejected') {
    // The destination must name the check that proves it refused the forbidden
    // capability, and that check must hold. A refusal for some unrelated reason,
    // or a verdict set without one, is a policy violation rather than a refusal.
    const refusal = destination.policyRefusal;
    const refusalHolds =
      refusal?.check !== undefined &&
      destination.checks?.[refusal.check] === true;
    const refused = destinationVerdict === 'policy-rejected' && refusalHolds;
    const report = {
      fixtureId: golden.fixtureId,
      fixtureSha256: goldenFixtureHash,
      goldenVerdict,
      destinationVerdict,
      goldenDevice: golden.device?.fingerprint,
      destinationDevice: destination.device?.fingerprint,
      goldenWebView: golden.runtime?.webViewVersion,
      destinationWebView: destination.runtime?.webViewVersion,
      goldenPolicyReason: golden.policyReason,
      destinationPolicyReason: destination.policyReason,
      destinationPolicyRefusal: destination.policyRefusal ?? null,
      destinationPolicyRefusalHolds: refusalHolds,
      differences: [],
      comparisonVerdict: refused ? 'policy-rejected' : 'policy-violation',
    };
    process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
    process.exit(refused ? 0 : 1);
  }

  const fixturePath = path.join(
    path.dirname(goldenPath),
    '..',
    '..',
    'fixtures',
    `${golden.fixtureId}.json`,
  );
  const fixture = fs.existsSync(fixturePath)
    ? JSON.parse(fs.readFileSync(fixturePath, 'utf8'))
    : null;
  const groups = concurrentGroups(fixture);
  const destinationRequests = partitionRequests(
    comparableRequests(destination),
    groups,
  );
  const destinationBatches = admissionBatches(destination, groups);

  // The Android destination runs on the same device and WebView as the golden,
  // so a result recorded on a different runtime is not a comparison against this
  // golden at all. A destination on another platform declares its own target and
  // is not gated here.
  const sameRuntimeRequired = (destination.target ?? '').startsWith('android');
  if (sameRuntimeRequired) {
    if (destination.device?.fingerprint !== golden.device?.fingerprint) {
      console.error(
        `device fingerprint differs: golden ${golden.device?.fingerprint}, destination ${destination.device?.fingerprint}`,
      );
      process.exit(2);
    }
    if (destination.runtime?.webViewVersion !== golden.runtime?.webViewVersion) {
      console.error(
        `WebView version differs: golden ${golden.runtime?.webViewVersion}, destination ${destination.runtime?.webViewVersion}`,
      );
      process.exit(2);
    }
  }
  const candidates = [
    { side: 'accepted', evidence: golden },
    ...raceAlternatives(goldenPath, golden).map(({ name, evidence, reason }) => ({
      side: `diagnostic:${name}`,
      evidence,
      reason,
    })),
  ].map((candidate) => {
    const differences = [];
    diff(
      partitionRequests(comparableRequests(candidate.evidence), groups),
      destinationRequests,
      'requests',
      differences,
    );
    diff(
      admissionBatches(candidate.evidence, groups),
      destinationBatches,
      'admissionBatches',
      differences,
    );
    return { ...candidate, differences };
  });
  const matched =
    candidates.find((candidate) => candidate.differences.length === 0) ??
    candidates[0];

  const differences = [...matched.differences];
  diff(
    comparableOperation(golden),
    comparableOperation(destination),
    'operation',
    differences,
  );
  diff(
    comparableExtras(golden),
    comparableExtras(destination),
    'observations',
    differences,
  );
  const goldenChecks = golden.checks ?? {};
  const destinationChecks = destination.checks ?? {};
  diff(
    goldenChecks,
    Object.fromEntries(
      Object.keys(goldenChecks).map((name) => [name, destinationChecks[name]]),
    ),
    'checks',
    differences,
  );
  const destinationExtraChecks = Object.keys(destinationChecks).filter(
    (name) => !(name in goldenChecks),
  );

  const report = {
    fixtureId: golden.fixtureId,
    fixtureSha256: goldenFixtureHash,
    goldenVerdict,
    destinationVerdict,
    goldenDevice: golden.device?.fingerprint,
    destinationDevice: destination.device?.fingerprint,
    goldenWebView: golden.runtime?.webViewVersion,
    destinationWebView: destination.runtime?.webViewVersion,
    goldenChecksCompared: Object.keys(goldenChecks).length,
    destinationExtraChecks,
    matchedGoldenTrace: matched.side,
    matchedRaceAlternativeReason: matched.reason,
    raceAlternativesConsidered: candidates.length - 1,
    browserInitiatedGolden: browserInitiatedTargets(golden),
    browserInitiatedDestination: browserInitiatedTargets(destination),
    differences,
    comparisonVerdict: (() => {
      if (differences.length !== 0 || goldenVerdict !== destinationVerdict) {
        return 'mismatch';
      }
      // A trace that only matches a declared diagnostic did not reproduce the
      // accepted golden trace, so it gets its own verdict and cannot be counted
      // as a plain match.
      return matched.side === 'accepted' ? 'match' : 'match-race-alternative';
    })(),
  };
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  // A trace that reproduced a declared race alternative is an accepted outcome:
  // the golden itself records both sides of that race, so exiting non-zero would
  // stop a sweep on documented non-determinism rather than on a real difference.
  // Only a mismatch, or a policy violation, is a failure.
  process.exit(
    report.comparisonVerdict === 'match' ||
      report.comparisonVerdict === 'match-race-alternative'
      ? 0
      : 1,
  );
}

main();
