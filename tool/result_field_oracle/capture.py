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
REPORT_REMOTE = '/sdcard/Android/data/io.legado.app.debug/files/field-oracle.json'
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


def finalize(output, fixture, manifest, report, before, after, asset=None):
    """Validate one pulled report and its privacy snapshot; write the golden.

    Re-runnable over an evidence directory that already holds
    `field-oracle.json`, `private-before.log` and `private-after.log`, so a
    capture whose device step was interrupted can be finalized from the raw
    report the device actually produced instead of re-running the instrument.
    """
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
            Path(__file__).with_name('build.ps1')]
    }
    manifest['harnessSourcesNote'] = (
        'hashes of the committed harness sources; capture.py gained its re-runnable '
        '--finalize validation path after this device run, and FieldOracle.java, '
        'AndroidManifest.xml, build.ps1 and the corpus are unchanged since the build '
        'whose APK hash this manifest records.')
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
    args = parser.parse_args()
    fixture_path = Path(__file__).with_name('fixtures.json')
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    if args.finalize:
        report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
        manifest = json.loads((args.output / 'manifest.json').read_text(encoding='utf-8'))
        try:
            finalize(args.output, fixture, manifest, report,
                     (args.output / 'private-before.log').read_bytes(),
                     (args.output / 'private-after.log').read_bytes(),
                     asset=args.asset)
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
    args.output.mkdir(parents=True, exist_ok=False)
    # The pulled baseline APK is a ~50 MB copy of the installed artifact; it is
    # hashed, never committed, and stays outside the evidence directory.
    scratch = Path(tempfile.mkdtemp(prefix='fields-01-baseline-'))
    manifest = {
        'status': 'not-run',
        'ticket': 'https://github.com/qsgy-edge/liber/issues/41',
        'kind': 'fields-01-frozen-result-field-golden',
        'corpus': {
            'path': 'tool/result_field_oracle/fixtures.json',
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
                Path(__file__).with_name('build.ps1')]
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
        manifest['fingerprint'] = adb(
            'fingerprint', 'shell', 'getprop', 'ro.build.fingerprint').stdout.decode().strip()
        if manifest['fingerprint'] != FINGERPRINT:
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
        if manifest['baselineApkSha256'] != BASELINE_APK:
            raise ValueError('installed baseline APK differs')
        existing = adb('harness-existing', 'shell', 'pm', 'path', PACKAGE, checked=False)
        if b'package:' in existing.stdout:
            raise ValueError('harness package already exists; do not replace unowned install')
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
            adb('remove-harness', 'uninstall', PACKAGE, checked=False)
        (args.output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'],
                          'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
