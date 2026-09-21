"""Capture the real frozen APK's `@js:` replacement boundary; never manufacture a golden.

Requires exclusive approved handset access and permission for the disposable APK.
One install attempt only. A device rejection is recorded as blocked, not retried.
`--finalize` re-runs only the validation over a report the device already produced.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import zipfile

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.replacejs'
DEFAULT_BACKUP = Path('D:/GithubRepositories/Android/legado-backups/legado-backup-2026-09-17.zip')
# The frozen application's own store; the harness must not touch it. `cache` is
# listed too, to prove the harness scratch directory was removed.
PRIVATE_PATHS = 'databases shared_prefs files cache'


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def write_lf(path, text):
    """Write text with LF endings whatever the host's newline convention is.

    The evidence files are pinned by byte hash and `.gitattributes` keeps them
    at `eol=lf`, so a Windows capture must not turn them into CRLF: the pin and
    the committed blob have to be the same bytes (#41 hit this).
    """
    Path(path).write_bytes(text.encode('utf-8'))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--apk', type=Path)
    parser.add_argument('--frozen-source', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--backup', type=Path, default=DEFAULT_BACKUP)
    parser.add_argument('--finalize', action='store_true',
                        help='validate an existing report instead of installing anything')
    args = parser.parse_args()
    if not args.finalize and (args.serial is None or args.apk is None or args.frozen_source is None):
        print('--serial/--apk/--frozen-source are required unless --finalize', file=sys.stderr)
        return 64
    tool = Path(__file__).parent
    fixture_path = tool / 'fixtures.json'
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    manifest = {'status': 'not-run', 'commands': [], 'fixture': fixture['fixtureId'],
                'fixtureSha256': sha(fixture_path), 'serial': args.serial,
                'harnessSources': {p.name: sha(p) for p in [
                    Path(__file__), tool / 'ReplaceJsOracle.java',
                    tool / 'AndroidManifest.xml', tool / 'build.ps1']}}
    if not args.finalize:
        args.output.mkdir(parents=True, exist_ok=False)
        manifest['harnessApkSha256'] = sha(args.apk)
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

    def check_backup():
        """The four operator rows must be the backup's own bytes, not a paraphrase."""
        source = fixture['backupSource']
        if sha(args.backup) != source['sha256']:
            raise ValueError('the operator backup bytes differ from the corpus pin')
        entry = zipfile.ZipFile(args.backup).read(source['entry'])
        if hashlib.sha256(entry).hexdigest() != source['entrySha256']:
            raise ValueError('the backup replace rule entry differs from the corpus pin')
        rules = json.loads(entry.decode('utf-8'))
        manifest['backupRuleCount'] = len(rules)
        by_id = {rule['id']: rule for rule in rules}
        for case in fixture['cases']:
            if 'backupRule' not in case:
                continue
            original = case['backupRule']
            if by_id.get(original['id']) != original:
                raise ValueError('corpus row %s is not the backup rule verbatim' % case['id'])
            if original.get('isEnabled') is not False:
                raise ValueError('corpus row %s is not the disabled backup state' % case['id'])
        js_rules = [r for r in rules if str(r.get('replacement', '')).startswith('@js:')]
        if [r['id'] for r in js_rules] != source['jsRuleIds']:
            raise ValueError('the backup @js: rule identity changed')
        manifest['backupJsRuleIds'] = source['jsRuleIds']

    def check_report(report):
        if report.get('fixtureId') != fixture['fixtureId']:
            raise ValueError('frozen report is not this corpus')
        if report.get('fixtureSha256') != manifest['fixtureSha256']:
            raise ValueError('installed harness contains different fixture bytes')
        if report.get('baselineCommit') != fixture['baselineCommit']:
            raise ValueError('frozen baseline commit differs')
        if report.get('boundary') != fixture['comparisonBoundary']:
            raise ValueError('frozen comparison boundary differs')
        if report.get('failure') or report.get('cleanupFailure'):
            raise ValueError('instrumentation reported a failure')
        if report.get('cleanup', {}).get('scratchRemoved') is not True:
            raise ValueError('scratch cleanup not confirmed')
        if report.get('cleanup', {}).get('databaseClosed') is not True:
            raise ValueError('scratch database was not closed')
        ids = [row['id'] for row in report['rows']]
        if ids != [row['id'] for row in fixture['cases']]:
            raise ValueError('missing/reordered frozen rows')
        if any(row['status'] != 'observed' for row in report['rows']):
            raise ValueError('frozen row failed')

    def finalize():
        """Validate the pulled report and manifest of an already-executed run."""
        report = json.loads((args.output / 'observation.json').read_text(encoding='utf-8'))
        check_backup()
        check_report(report)
        before = (args.output / 'private-before.log').read_text(encoding='utf-8').splitlines()
        after = (args.output / 'private-after.log').read_text(encoding='utf-8').splitlines()
        changed = sorted(set(before) ^ set(after))
        manifest['privateFileChanges'] = changed
        if any('liber-replace-js-49' not in line for line in changed):
            raise ValueError('the frozen application private files changed: %s' % changed)
        manifest['existingDataHashesUnchanged'] = True
        scratch = (args.output / 'scratch-after.log').read_text(encoding='utf-8')
        manifest['scratchRemoved'] = 'liber-replace-js-49' not in scratch
        if not manifest['scratchRemoved']:
            raise ValueError('harness scratch directory survived the run')
        (args.output / 'golden.json').write_bytes((args.output / 'observation.json').read_bytes())
        manifest['goldenSha256'] = sha(args.output / 'golden.json')
        manifest['status'] = 'observed'

    try:
        if args.finalize:
            finalize()
            return 0
        # Host-side provenance first: a wrong corpus must not reach the device.
        check_backup()
        head = run(['git', '-C', str(args.frozen_source), 'rev-parse', 'HEAD'], 'source-head')
        if head.stdout.decode().strip() != fixture['baselineCommit']:
            raise ValueError('frozen source HEAD differs')
        manifest['frozenSources'] = {}
        for source in fixture['frozenSources']:
            path = args.frozen_source / source['path']
            if hashlib.sha1(path.read_bytes()).hexdigest() != source['sha1']:
                raise ValueError('frozen source bytes differ: ' + source['path'])
            manifest['frozenSources'][source['path']] = sha(path)
        manifest['fingerprint'] = adb('fingerprint', 'shell', 'getprop', 'ro.build.fingerprint').stdout.decode().strip()
        if manifest['fingerprint'] != FINGERPRINT:
            raise ValueError('device fingerprint differs; requires new capture approval')
        baseline = adb('baseline-path', 'shell', 'pm', 'path', 'io.legado.app.debug').stdout.decode().strip()
        adb('pull-baseline', 'pull', baseline.removeprefix('package:'), str(args.output / 'frozen.apk'))
        manifest['baselineApkSha256'] = sha(args.output / 'frozen.apk')
        if manifest['baselineApkSha256'] != BASELINE_APK:
            raise ValueError('installed baseline APK differs')
        existing = adb('harness-existing', 'shell', 'pm', 'path', PACKAGE, checked=False)
        if b'package:' in existing.stdout:
            raise ValueError('harness package already exists; do not replace unowned install')
        # Only hash lists leave the device; no user content is copied.
        snapshot = "'find %s -type f -exec sha256sum {} \\; 2>/dev/null'" % PRIVATE_PATHS
        before = adb('private-before', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot)
        adb('scratch-before', 'shell', 'run-as', 'io.legado.app.debug', 'ls', 'cache', checked=False)
        # `-r` is adb's incremental install, the only form MIUI accepts on this
        # handset; the streamed `--no-incremental` install is rejected as
        # INSTALL_FAILED_USER_RESTRICTED even with USB installation enabled.
        installed_result = adb('install', 'install', '-r', str(args.apk), checked=False)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            return 2
        installed = True
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     PACKAGE + '/' + PACKAGE + '.ReplaceJsOracle', timeout=180)
        match = re.search(rb'REPLACE_JS_ORACLE_BASE64=([A-Za-z0-9+/=]+)', result.stdout)
        if match is None:
            raise ValueError('instrumentation produced no returned report')
        report = json.loads(base64.b64decode(match[1]))
        write_lf(args.output / 'observation.json',
                 json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        after = adb('private-after', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot)
        changed = sorted(set(before.stdout.decode().splitlines()) ^ set(after.stdout.decode().splitlines()))
        manifest['privateFileChanges'] = changed
        preserved = all('liber-replace-js-49' in line for line in changed)
        manifest['existingDataHashesUnchanged'] = preserved
        if not preserved:
            raise ValueError('existing private file hash list changed; inspect before promotion')
        scratch_after = adb('scratch-after', 'shell', 'run-as', 'io.legado.app.debug', 'ls', 'cache',
                            checked=False)
        manifest['scratchRemoved'] = b'liber-replace-js-49' not in scratch_after.stdout
        if not manifest['scratchRemoved']:
            raise ValueError('harness scratch directory survived the run')
        check_report(report)
        (args.output / 'golden.json').write_bytes((args.output / 'observation.json').read_bytes())
        manifest['goldenSha256'] = sha(args.output / 'golden.json')
        manifest['status'] = 'observed'
        return 0
    except Exception as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        return 1
    finally:
        if installed:
            # Only our installed harness and its owned target process; no baseline uninstall.
            adb('stop-owned-run', 'shell', 'am', 'force-stop', 'io.legado.app.debug', checked=False)
            adb('remove-harness', 'uninstall', PACKAGE, checked=False)
            manifest['harnessUninstalled'] = True
        write_lf(args.output / 'manifest.json', json.dumps(manifest, indent=2) + '\n')
        print(json.dumps({'status': manifest['status'], 'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
