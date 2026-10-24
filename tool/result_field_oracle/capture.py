"""Capture the frozen FIELDS-01 result-field golden; never manufacture a golden.

Drives the disposable FIELDS-01 oracle APK against the installed, hash-pinned
`io.legado.app.debug` on the approved handset. One install attempt only: a device
rejection is recorded as blocked, not retried. The harness is uninstalled in the
`finally` block and the baseline package is never touched.

Usage:
  python tool/result_field_oracle/capture.py --serial <serial> --apk <field-oracle.apk> \
      --frozen-source <legado checkout> --output <fresh directory>
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.fields'
INSTRUMENTATION = PACKAGE + '/.FieldOracle'
TARGET_PACKAGE = 'io.legado.app.debug'
REPORT_REMOTE = '/sdcard/Android/data/io.legado.app.debug/files/field-oracle.json'
FIELDS_02 = 'FIELDS-02'
SCRATCH_ROOT = '/data/data/io.legado.app.debug/cache/liber-fields-02'
REPORT_REMOTE_FIELDS_02 = SCRATCH_ROOT + '/field-oracle.json'
OWNER_REMOTE_FIELDS_02 = SCRATCH_ROOT + '/owner.json'
OWNED_PREFERENCE_GLOB = '/data/data/io.legado.app.debug/shared_prefs/liber_fields_02_*.xml'
# The frozen application's own persisted data. Starting its process writes
# third-party state (Play Services measurement, Firebase, WebView Chromium
# prefs) that this corpus cannot and need not control, so the gate is the
# application's own store staying byte-identical and every other change being
# named in the manifest rather than dropped.
FROZEN_APP_STORE = ('databases/legado.db', 'databases/legado.db-wal',
                    'databases/legado.db-shm', 'shared_prefs/local.xml')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _hash_lines(output):
    """`sha256sum` output as {relative path: digest}."""
    hashes = {}
    for line in output.decode(errors='replace').splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            hashes[parts[1].strip()] = parts[0]
    return hashes


def finalize(output, fixture, manifest, report, before, after, asset=None,
             scratch_cleanup=None):
    """Validate one pulled report and its privacy snapshot; write the golden.

    Re-runnable over an evidence directory that already holds
    `field-oracle.json`, `private-before.log` and `private-after.log`, so a
    capture whose device step was interrupted can be finalized from the raw
    report the device actually produced instead of re-running the instrument.
    """
    if fixture.get('fixtureId') == FIELDS_02:
        return _finalize_fields_02(output, fixture, manifest, report, before, after,
                                   asset=asset, scratch_cleanup=scratch_cleanup)
    if report.get('analysisFailure') is not None:
        raise ValueError('the frozen harness reported an analysis failure')
    if report.get('caseFailures'):
        raise ValueError('the frozen harness recorded a failed case: '
                         + json.dumps(report['caseFailures'], ensure_ascii=False))
    for field in ['fixtureId', 'corpusVersion', 'baselineCommit', 'entryPoint',
                  'checkKeywordEntryPoint']:
        if report.get(field) != fixture[field]:
            raise ValueError('the frozen report disagrees on ' + field)
    if len(report['cases']) != len(fixture['cases']):
        raise ValueError('missing corpus cases in the frozen report')
    if len(report.get('checkKeyword', {})) != len(fixture['checkKeywordCases']):
        raise ValueError('missing checkKeyWord cases in the frozen report')
    if report.get('unmatchedRequests'):
        raise ValueError('the frozen run issued an undeclared request')
    if report.get('cleanup', {}).get('serverClosed') is not True:
        raise ValueError('the frozen harness did not confirm its replay teardown')
    before_hashes = _hash_lines(before)
    after_hashes = _hash_lines(after)
    manifest['existingDataHashesUnchanged'] = before_hashes == after_hashes
    changed = {path: {'before': before_hashes.get(path), 'after': after_hashes.get(path)}
               for path in sorted(set(before_hashes) | set(after_hashes))
               if before_hashes.get(path) != after_hashes.get(path)}
    manifest['privateFileChanges'] = changed
    manifest['frozenAppDataUnchanged'] = all(
        path not in changed and path in after_hashes for path in FROZEN_APP_STORE)
    if not manifest['frozenAppDataUnchanged']:
        raise ValueError("the frozen application's own store changed; inspect before promotion: "
                         + json.dumps({path: changed[path] for path in FROZEN_APP_STORE
                                       if path in changed}, ensure_ascii=False))
    (output / 'golden.json').write_bytes((output / 'field-oracle.json').read_bytes())
    manifest['goldenSha256'] = sha256(output / 'golden.json')
    manifest['cases'] = {
        'frozen': [entry['id'] for entry in fixture['cases']],
        'checkKeyword': [entry['id'] for entry in fixture['checkKeywordCases']],
    }
    manifest['deviceAssets'] = report.get('cleanup')
    # The harness sources are re-pinned to the committed files so a reviewer can
    # verify what produced this evidence; the note names the one file that
    # changed after the device step.
    manifest['harnessSources'] = {
        p.name: sha256(p) for p in [
            Path(__file__), Path(__file__).with_name('FieldOracle.java'),
            Path(__file__).with_name('AndroidManifest.xml'),
            Path(__file__).with_name('build.ps1'),
            Path(__file__).with_name('..') / 'nested_oracle' / 'StateSessionOracle.java']
    }
    manifest['harnessSourcesNote'] = (
        'hashes of the committed harness sources at finalize time; the device-run '
        'APK is identified by harnessApkSha256, and later harness-source changes do '
        'not rewrite that historical execution binding.')
    if asset is not None:
        asset_sha = sha256(asset)
        manifest['corpus']['assetCopySha256'] = asset_sha
        if asset_sha != manifest['corpus']['sha256']:
            raise ValueError('the built corpus asset differs from the corpus file: '
                             + asset_sha)
    # The row-by-row comparison is produced after the golden; when it is beside
    # the golden, its verdict is folded into the manifest so one file states what
    # was compared and what did not pass.
    comparison = output / 'comparison.json'
    if comparison.exists():
        report_rows = json.loads(comparison.read_text(encoding='utf-8'))
        manifest['comparison'] = {
            'path': 'comparison.json',
            'sha256': sha256(comparison),
            'status': report_rows['status'],
            'summary': report_rows['summary'],
            'rows': {row['id']: row['status'] for row in report_rows['rows']},
            'divergences': report_rows['divergences'],
            'note': 'the comparator exits 1 when a row does not pass; the F4 '
                    'divergence here is recorded evidence, not a corpus defect.',
        }
    manifest['status'] = 'observed'



def _finalize_fields_02(output, fixture, manifest, report, before, after, asset=None,
                        scratch_cleanup=None):
    """Validate the FIELDS-02 native report and publish it as the golden."""
    golden_path = output / 'golden.json'
    if golden_path.exists():
        golden_path.unlink()
    if report.get('analysisFailure') is not None:
        raise ValueError('the frozen harness reported an analysis failure')
    if report.get('caseFailures'):
        raise ValueError('the frozen harness recorded a failed case: '
                         + json.dumps(report['caseFailures'], ensure_ascii=False))
    for field in ['fixtureId', 'corpusVersion', 'baselineCommit', 'entryPoint']:
        if report.get(field) != fixture[field]:
            raise ValueError('the frozen report disagrees on ' + field)
    if report.get('unmatchedRequests'):
        raise ValueError('the frozen run issued an undeclared request')
    if not isinstance(report.get('caseRecords'), list):
        raise ValueError('the frozen report has no case record array')
    declared = [case['id'] for case in fixture['cases']]
    observed = [case.get('id') for case in report['caseRecords']]
    if observed != declared:
        raise ValueError('the frozen case records are not the declared set/order')
    terminals = {case['id']: case.get('terminal', 'four-stage')
                 for case in fixture['cases']}
    for case in report['caseRecords']:
        if case.get('terminal') != terminals[case['id']]:
            raise ValueError('case terminal differs: ' + str(case.get('id')))
    requests = report.get('requests')
    expected = fixture['expectedRequests']
    if not isinstance(requests, list) or len(requests) != len(expected):
        raise ValueError('the frozen request sequence is not the declared sequence')
    responses = fixture['responses']
    for index, (actual, wanted) in enumerate(zip(requests, expected)):
        if actual.get('method') != wanted['method']:
            raise ValueError('request method differs at ' + str(index))
        if actual.get('path') != wanted['path']:
            raise ValueError('request path differs at ' + str(index))
        if actual.get('query') != wanted.get('query', {}):
            raise ValueError('request query differs at ' + str(index))
        receipt = actual.get('receipt') or {}
        if len(expected) != len(responses):
            raise ValueError('corpus expectedRequests/responses are not aligned')
        response = responses[index]
        if receipt.get('terminal') != 'responded':
            raise ValueError('request was not responded at ' + str(index))
        if receipt.get('responseId') != response['id']:
            raise ValueError('response id differs at ' + str(index))
        if receipt.get('status') != response.get('status', 200):
            raise ValueError('response status differs at ' + str(index))
        location = (response.get('headers') or {}).get('Location')
        if receipt.get('redirect') != location:
            raise ValueError('response redirect differs at ' + str(index))
    corpus = report.get('corpus') or {}
    if corpus.get('asset') != 'field-fixtures.json':
        raise ValueError('the frozen report corpus asset differs')
    if corpus.get('sha256') != manifest['corpus']['sha256']:
        raise ValueError('the frozen report corpus hash differs')
    if corpus.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the frozen report fixture id differs')
    if corpus.get('corpusVersion') != fixture['corpusVersion']:
        raise ValueError('the frozen report corpus version differs')
    isolation = report.get('isolation') or {}
    if isolation.get('bound') is not True:
        raise ValueError('the scratch application was not bound')
    if isolation.get('filesRouted') is not True or isolation.get('databaseRouted') is not True:
        raise ValueError('the scratch application did not route files/database')
    if isolation.get('deviceProtected') is not False:
        raise ValueError('the scratch application used device-protected storage')
    if isolation.get('rootExistedAtStart') is not False:
        raise ValueError('the scratch root already existed')
    if isolation.get('targetPackage') != TARGET_PACKAGE:
        raise ValueError('the scratch target package differs')
    if isolation.get('targetApkSha256') != manifest.get('baselineApkSha256'):
        raise ValueError('the scratch target APK binding differs')
    if isolation.get('harnessPackage') != PACKAGE:
        raise ValueError('the scratch harness package differs')
    if isolation.get('harnessApkSha256') != manifest.get('harnessApkSha256'):
        raise ValueError('the scratch harness APK binding differs')
    cleanup = report.get('cleanup') or {}
    if cleanup.get('serverClosed') is not True:
        raise ValueError('the FIELDS-02 replay server did not close')
    if cleanup.get('ownerComplete') is not True:
        raise ValueError('the scratch owner was not completed')
    if cleanup.get('rootRetained') is not True:
        raise ValueError('the scratch root was not retained for external cleanup')
    if cleanup.get('scratchRoot') != SCRATCH_ROOT:
        raise ValueError('the scratch root path differs from the measured path')
    if cleanup.get('reportPath') != REPORT_REMOTE_FIELDS_02:
        raise ValueError('the scratch report path differs from the measured path')
    owned = cleanup.get('ownedPreferences')
    if not isinstance(owned, list) or any(
            not re.fullmatch(r'liber_fields_02_[A-Za-z0-9_.-]+', str(name))
            for name in owned):
        raise ValueError('the scratch owned-preference list is malformed')
    if cleanup.get('preferencesFenced') is not True:
        raise ValueError('the scratch preferences were not fenced')
    if scratch_cleanup is None:
        raise ValueError('the external scratch cleanup receipt is missing')
    if scratch_cleanup.get('rootAbsent') is not True:
        raise ValueError('the external scratch root cleanup is not proven')
    if scratch_cleanup.get('ownedPreferencesAbsent') is not True:
        raise ValueError('the owned preferences survived cleanup')
    owner = manifest.get('scratchOwner') or {}
    if owner.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the scratch owner fixture id differs')
    if owner.get('corpusVersion') != fixture['corpusVersion']:
        raise ValueError('the scratch owner corpus version differs')
    if owner.get('targetPackage') != TARGET_PACKAGE:
        raise ValueError('the scratch owner target package differs')
    if owner.get('harnessPackage') != PACKAGE:
        raise ValueError('the scratch owner harness package differs')
    if owner.get('targetApkSha256') != isolation.get('targetApkSha256'):
        raise ValueError('the scratch owner target APK binding differs')
    if owner.get('harnessApkSha256') != isolation.get('harnessApkSha256'):
        raise ValueError('the scratch owner harness APK binding differs')
    if owner.get('corpusSha256Lf') != isolation.get('corpusSha256Lf'):
        raise ValueError('the scratch owner corpus binding differs')
    if owner.get('complete') is not True:
        raise ValueError('the scratch owner was not marked complete')
    if report.get('fingerprint') != manifest.get('fingerprint'):
        raise ValueError('the report device fingerprint differs')
    before_hashes = _hash_lines(before)
    after_hashes = _hash_lines(after)
    changed = {path: {'before': before_hashes.get(path), 'after': after_hashes.get(path)}
               for path in sorted(set(before_hashes) | set(after_hashes))
               if before_hashes.get(path) != after_hashes.get(path)}
    if any(path.startswith('shared_prefs/liber_fields_02_') for path in changed):
        raise ValueError('an owned scratch preference survived cleanup: '
                         + json.dumps({path: changed[path] for path in changed
                                       if path.startswith('shared_prefs/liber_fields_02_')},
                                      ensure_ascii=False))
    manifest['existingDataHashesUnchanged'] = before_hashes == after_hashes
    manifest['privateFileChanges'] = changed
    manifest['frozenAppDataUnchanged'] = all(
        path not in changed and path in after_hashes for path in FROZEN_APP_STORE)
    if not manifest['frozenAppDataUnchanged']:
        raise ValueError("the frozen application's own store changed; inspect before promotion: "
                         + json.dumps({path: changed[path] for path in FROZEN_APP_STORE
                                       if path in changed}, ensure_ascii=False))
    manifest['cases'] = {'frozen': declared}
    manifest['deviceAssets'] = cleanup
    manifest['isolation'] = isolation
    manifest['scratchCleanup'] = scratch_cleanup
    # The harness sources are re-pinned so a reviewer can reproduce the exact
    # native and helper bytes used by this run.
    manifest['harnessSources'] = {
        p.name: sha256(p) for p in [
            Path(__file__), Path(__file__).with_name('FieldOracle.java'),
            Path(__file__).with_name('AndroidManifest.xml'),
            Path(__file__).with_name('build.ps1'),
            Path(__file__).with_name('..') / 'nested_oracle' / 'StateSessionOracle.java']
    }
    manifest['harnessSourcesNote'] = (
        'hashes of the committed harness sources, including the shared '
        'StateSessionOracle.ScratchContext compiled into this APK; the external '
        'scratch cleanup receipt was captured after the target process was stopped.')
    if asset is not None:
        asset_sha = sha256(asset)
        manifest['corpus']['assetCopySha256'] = asset_sha
        if asset_sha != manifest['corpus']['sha256']:
            raise ValueError('the built corpus asset differs from the corpus file: '
                             + asset_sha)
    golden_path.write_bytes((output / 'field-oracle.json').read_bytes())
    manifest['goldenSha256'] = sha256(golden_path)
    manifest['status'] = 'observed'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--frozen-source', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--finalize', action='store_true',
                        help='validate an evidence directory that already holds the pulled '
                             'report and its privacy snapshots; no device step is run')
    parser.add_argument('--asset', type=Path,
                        help='the corpus asset copy inside the built harness, recorded at '
                             'finalize time and required to equal the corpus file')
    parser.add_argument('--fixture', type=Path,
                        help='select the FIELDS corpus; the default remains FIELDS-01')
    args = parser.parse_args()
    fixture_path = (args.fixture or Path(__file__).with_name('fixtures.json'))
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    fields_02 = fixture.get('fixtureId') == FIELDS_02
    if args.finalize:
        report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
        manifest = json.loads((args.output / 'manifest.json').read_text(encoding='utf-8'))
        try:
            finalize(args.output, fixture, manifest, report,
                     (args.output / 'private-before.log').read_bytes(),
                     (args.output / 'private-after.log').read_bytes(),
                     asset=args.asset,
                     scratch_cleanup=manifest.get('scratchCleanup'))
        except Exception as error:  # noqa: BLE001 - the manifest records the exact blocker
            manifest['status'] = 'failed'
            manifest['error'] = str(error)
        (args.output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'],
                          'manifest': str(args.output / 'manifest.json')}))
        return 0 if manifest['status'] == 'observed' else 1
    if args.apk is None or args.frozen_source is None:
        raise SystemExit('--apk and --frozen-source are required for a capture')
    if fields_02 and args.asset is None:
        raise SystemExit('--asset is required for a FIELDS-02 capture')
    args.output.mkdir(parents=True, exist_ok=False)
    # The pulled baseline APK is a ~50 MB copy of the installed artifact; it is
    # hashed, never committed, and stays outside the evidence directory.
    scratch = Path(tempfile.mkdtemp(prefix='fields-01-baseline-'))
    manifest = {
        'status': 'not-run',
        'ticket': ('https://github.com/qsgy-edge/liber/issues/138'
                   if fields_02 else 'https://github.com/qsgy-edge/liber/issues/41'),
        'kind': ('fields-02-book-url-markers-result-field-golden'
                 if fields_02 else 'fields-01-frozen-result-field-golden'),
        'corpus': {
            'path': str(fixture_path),
            'sha256': sha256(fixture_path),
            'assetCopySha256': None,
            'fixtureId': fixture['fixtureId'],
            'corpusVersion': fixture['corpusVersion'],
            'origin': fixture['origin'],
            'note': 'the harness serves an asset copy of the corpus taken from the '
                    'worktree; a Windows checkout that rewrote it to CRLF has to be '
                    'normalised back to the committed LF blob before the build, so the '
                    'served bytes and the committed blob hash to the same value, which '
                    'is also the hash the Liber-side observation records (fixturesSha256).',
        },
        'harnessApkSha256': sha256(args.apk),
        'serial': args.serial,
        'commands': [],
        'harnessSources': {
            p.name: sha256(p) for p in [
                Path(__file__), Path(__file__).with_name('FieldOracle.java'),
                Path(__file__).with_name('AndroidManifest.xml'),
                Path(__file__).with_name('build.ps1'),
                Path(__file__).with_name('..') / 'nested_oracle' / 'StateSessionOracle.java']
        },
    }
    installed = False

    def run(command, name, timeout=60, checked=True):
        result = subprocess.run(command, capture_output=True, timeout=timeout)
        (args.output / (name + '.log')).write_bytes(result.stdout + result.stderr)
        manifest['commands'].append({'command': command, 'exitCode': result.returncode,
                                     'log': name + '.log'})
        if checked and result.returncode:
            raise RuntimeError(f'{name} exited {result.returncode}; see raw log')
        return result

    def adb(name, *command, **kwargs):
        return run(['adb', '-s', args.serial, *command], name, **kwargs)

    def cleanup_fields_02(report):
        """Remove only the target-owned scratch namespace and record the proof."""
        cleanup = report.get('cleanup') or {}
        owned = cleanup.get('ownedPreferences') or []
        if not isinstance(owned, list):
            raise ValueError('scratch cleanup record malformed')
        for name in owned:
            if not re.fullmatch(r'liber_fields_02_[A-Za-z0-9_.-]+', str(name)):
                raise ValueError('unexpected owned preference name: ' + str(name))
        removed = adb('scratch-remove', 'shell', 'run-as', TARGET_PACKAGE, 'sh', '-c',
                      'rm -f ' + OWNED_PREFERENCE_GLOB + '; rm -rf ' + SCRATCH_ROOT,
                      checked=False)
        if removed.returncode:
            raise ValueError('the outer driver could not remove the scratch namespace')
        absent = adb('scratch-absent', 'shell', 'run-as', TARGET_PACKAGE, 'sh', '-c',
                     'test ! -e ' + SCRATCH_ROOT
                     + ' && ! ls ' + OWNED_PREFERENCE_GLOB + ' >/dev/null 2>&1',
                     checked=False)
        if absent.returncode:
            raise ValueError('the scratch namespace survived external cleanup')
        return {
            'reportedOwnedPreferences': owned,
            'root': SCRATCH_ROOT,
            'rootAbsent': True,
            'ownedPreferencesAbsent': True,
            'postStop': True,
        }

    # An install is only ever attempted with `-r`, the incremental form MIUI
    # accepts on this handset; a streamed `--no-incremental` install is rejected
    # as INSTALL_FAILED_USER_RESTRICTED even with USB installation enabled.
    try:
        head = run(['git', '-C', str(args.frozen_source), 'rev-parse', 'HEAD'], 'source-head')
        if head.stdout.decode().strip() != fixture['baselineCommit']:
            raise ValueError('frozen source HEAD differs')
        # The frozen sources are pinned by the committed blob, not by the
        # working-tree bytes: a Windows checkout writes CRLF, while
        # `git hash-object <path>` applies the checkout's clean filter and
        # answers the committed LF blob's hash, which is what the corpus pins.
        paths = [source['path'] for source in fixture['frozenSources']]
        observed = run(['git', '-C', str(args.frozen_source), 'hash-object', *paths],
                       'frozen-source-hashes').stdout.decode().split()
        expected = [source['sha1'] for source in fixture['frozenSources']]
        if observed != expected:
            raise ValueError('frozen source bytes differ: '
                             + ', '.join(path for path, want, got in zip(paths, expected, observed)
                                         if want != got))
        dirty = run(['git', '-C', str(args.frozen_source), 'status', '--porcelain', '--', *paths],
                    'frozen-source-status').stdout.decode().strip()
        if dirty:
            raise ValueError('frozen source worktree is modified: ' + dirty)
        manifest['frozenSources'] = {
            path: {'blobSha1': blob, 'worktreeSha256': sha256(args.frozen_source / path)}
            for path, blob in zip(paths, observed)
        }
        expected_fingerprint = (
            fixture.get('target', {}).get('deviceFingerprint', FINGERPRINT)
            if fields_02 else FINGERPRINT)
        expected_apk = (
            fixture.get('target', {}).get('apkSha256', BASELINE_APK)
            if fields_02 else BASELINE_APK)
        manifest['fingerprint'] = adb(
            'fingerprint', 'shell', 'getprop', 'ro.build.fingerprint').stdout.decode().strip()
        if manifest['fingerprint'] != expected_fingerprint:
            raise ValueError('device fingerprint differs; requires new capture approval')
        manifest['androidRelease'] = adb(
            'android-release', 'shell', 'getprop', 'ro.build.version.release').stdout.decode().strip()
        manifest['sdk'] = adb(
            'sdk', 'shell', 'getprop', 'ro.build.version.sdk').stdout.decode().strip()
        manifest['model'] = adb(
            'model', 'shell', 'getprop', 'ro.product.model').stdout.decode().strip()
        baseline = adb(
            'baseline-path', 'shell', 'pm', 'path', 'io.legado.app.debug').stdout.decode().strip()
        adb('pull-baseline', 'pull', baseline.removeprefix('package:'),
            str(scratch / 'frozen.apk'))
        manifest['baselineApkSha256'] = sha256(scratch / 'frozen.apk')
        if manifest['baselineApkSha256'] != expected_apk:
            raise ValueError('installed baseline APK differs')
        existing = adb('harness-existing', 'shell', 'pm', 'path', PACKAGE, checked=False)
        if b'package:' in existing.stdout:
            raise ValueError('harness package already exists; do not replace unowned install')
        if fields_02:
            # A previous interrupted attempt may have left the owned namespace
            # behind; remove only that namespace before taking the fresh
            # before-snapshot, so the measured cleanup later is this run's.
            adb('scratch-preclean', 'shell', 'run-as', TARGET_PACKAGE, 'sh', '-c',
                'rm -f ' + OWNED_PREFERENCE_GLOB + '; rm -rf ' + SCRATCH_ROOT,
                checked=False)
        # Only hash lists leave the device; no user content is copied.
        snapshot = "'find databases shared_prefs files -type f -exec sha256sum {} \\; 2>/dev/null'"
        before = adb('private-before', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot)
        installed_result = adb('install', 'install', '-r', str(args.apk), checked=False,
                               timeout=180)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            return 2
        installed = True
        adb('logcat-clear', 'logcat', '-c', checked=False)
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     INSTRUMENTATION, timeout=240)
        manifest['run'] = {'result': result.stdout.decode(errors='replace').strip()}
        logcat = adb('logcat-field-oracle', 'logcat', '-d', '-s', 'FieldOracle', checked=False)
        (args.output / 'logcat.log').write_bytes(logcat.stdout)
        if fields_02:
            # The harness leaves its owned scratch root and owner manifest in the
            # target cache for this external driver. Stop the target first, then
            # read the report/owner and remove only the owned namespace.
            adb('poststop', 'shell', 'am', 'force-stop', TARGET_PACKAGE, checked=False)
            pulled = adb('pull-report', 'exec-out', 'run-as', TARGET_PACKAGE,
                         'cat', REPORT_REMOTE_FIELDS_02, checked=False)
            if pulled.returncode:
                raise ValueError('the device reported no oracle report')
            (args.output / 'field-oracle.json').write_bytes(pulled.stdout)
            owner = adb('scratch-owner', 'exec-out', 'run-as', TARGET_PACKAGE,
                        'cat', OWNER_REMOTE_FIELDS_02, checked=False)
            if owner.returncode:
                raise ValueError('the outer driver could not read the scratch owner manifest')
            manifest['scratchOwner'] = json.loads(owner.stdout)
            report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
            manifest['scratchCleanup'] = cleanup_fields_02(report)
            before = (args.output / 'private-before.log').read_bytes()
            after = adb('private-after', 'shell', 'run-as', TARGET_PACKAGE,
                        'sh', '-c', snapshot).stdout
            finalize(args.output, fixture, manifest, report, before, after,
                     asset=args.asset, scratch_cleanup=manifest['scratchCleanup'])
        else:
            pull = adb('pull-report', 'pull', REPORT_REMOTE,
                       str(args.output / 'field-oracle.json'), checked=False)
            if pull.returncode:
                raise ValueError('the device reported no oracle report')
            report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
            before = (args.output / 'private-before.log').read_bytes()
            after = adb('private-after', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot).stdout
            finalize(args.output, fixture, manifest, report, before, after)
        return 0
    except Exception as error:  # noqa: BLE001 - the manifest records the exact blocker
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        return 1
    finally:
        if installed:
            # Only our installed harness and its owned target process; no baseline uninstall.
            adb('stop-owned-run', 'shell', 'am', 'force-stop', 'io.legado.app.debug', checked=False)
            if fields_02 and manifest.get('status') != 'observed':
                # Never leave an unowned scratch root or owned preference behind,
                # even when the report could not be read.
                adb('scratch-fallback-remove', 'shell', 'run-as', TARGET_PACKAGE, 'sh', '-c',
                    'rm -f ' + OWNED_PREFERENCE_GLOB + '; rm -rf ' + SCRATCH_ROOT,
                    checked=False)
            adb('remove-harness', 'uninstall', PACKAGE, checked=False)
        (args.output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'],
                          'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
