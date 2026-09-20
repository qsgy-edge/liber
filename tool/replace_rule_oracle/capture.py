"""Capture the real frozen APK's reader return boundary; never manufacture a golden.

Requires exclusive approved handset access and permission for the disposable APK.
One install attempt only. Device rejection is recorded as blocked, not retried.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.replace'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--frozen-source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixture_path = Path(__file__).with_name('fixtures.json')
    fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
    manifest = {'status': 'not-run', 'commands': [], 'fixtureSha256': sha(fixture_path),
                'harnessApkSha256': sha(args.apk), 'serial': args.serial,
                'harnessSources': {p.name: sha(p) for p in [
                    Path(__file__), Path(__file__).with_name('ReaderOracle.java'),
                    Path(__file__).with_name('AndroidManifest.xml'),
                    Path(__file__).with_name('build.ps1')]}}
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

    try:
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
        snapshot = "'find databases shared_prefs files -type f -exec sha256sum {} \\; 2>/dev/null'"
        before = adb('private-before', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot)
        installed_result = adb('install', 'install', '--no-incremental', str(args.apk), checked=False)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            return 2
        installed = True
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     PACKAGE + '/' + PACKAGE + '.ReaderOracle', timeout=90)
        match = re.search(rb'READER_ORACLE_BASE64=([A-Za-z0-9+/=]+)', result.stdout)
        if match is None:
            raise ValueError('instrumentation produced no returned report')
        report = json.loads(base64.b64decode(match[1]))
        (args.output / 'observation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        after = adb('private-after', 'shell', 'run-as', 'io.legado.app.debug', 'sh', '-c', snapshot)
        preserved = sorted(before.stdout.splitlines()) == sorted(after.stdout.splitlines())
        manifest['existingDataHashesUnchanged'] = preserved
        if not preserved:
            raise ValueError('existing private file hash list changed; inspect before promotion')
        if report.get('failure') or report.get('cleanupFailure'):
            raise ValueError('instrumentation reported a failure')
        if report.get('fixtureSha256') != manifest['fixtureSha256']:
            raise ValueError('installed harness contains different fixture bytes')
        if report.get('cleanup', {}).get('scratchRemoved') is not True:
            raise ValueError('scratch cleanup not confirmed')
        if [row['id'] for row in report['rows']] != [row['id'] for row in fixture['cases']]:
            raise ValueError('missing/reordered frozen rows')
        if any(row['status'] != 'observed' for row in report['rows']):
            raise ValueError('frozen row failed')
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
        (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'], 'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
