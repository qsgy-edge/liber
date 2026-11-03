"""Capture the real frozen APK's reader return boundary; never manufacture a golden.

Requires exclusive approved handset access and permission for the disposable APK.
One install attempt only. Device rejection is recorded as blocked, not retried.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import zipfile

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
SELECTED_FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.5.0.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.replace'

# Selected successful runs retain the original three-root file-only scope.
SELECTED_INVENTORY_COMPLETE = b'__LIBER_READER_PRIVATE_INVENTORY_COMPLETE__'
SELECTED_INVENTORY_SCRIPT = (
    'set -e; find databases shared_prefs files -type f -exec sh -c '
    "'for f do sha256sum \"$f\" || exit 20; done' sh {} +; "
    "printf '%s\\n' '__LIBER_READER_PRIVATE_INVENTORY_COMPLETE__'"
)
SELECTED_INVENTORY_COMMAND = shlex.quote(SELECTED_INVENTORY_SCRIPT)


def parse_selected_private_inventory(data):
    """Validate complete selected file hashes, including a proven empty walk."""
    if not data.endswith(b'\n'):
        raise ValueError('selected private inventory completion missing or truncated')
    lines = [line.removesuffix(b'\r') for line in data[:-1].split(b'\n')]
    if lines[-1] != SELECTED_INVENTORY_COMPLETE or SELECTED_INVENTORY_COMPLETE in lines[:-1]:
        raise ValueError('selected private inventory completion missing or misplaced')
    records = lines[:-1]
    if any(not re.fullmatch(rb'[0-9a-f]{64}  [^\r\n]+', line) for line in records):
        raise ValueError('selected private inventory record malformed')
    paths = [line[66:] for line in records]
    if len(set(paths)) != len(paths):
        raise ValueError('selected private inventory repeats a path')
    return sorted(records)


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def sha_lf(path):
    return hashlib.sha256(path.read_bytes().replace(b'\r\n', b'\n')).hexdigest()


def check_device_fingerprint(selected, fingerprint):
    if fingerprint != (SELECTED_FINGERPRINT if selected else FINGERPRINT):
        raise ValueError('device fingerprint differs; requires new capture approval')


def classify_selected_preservation(before, after, owner, identity):
    """Classify failed-run residue only after exact owner and original-file checks."""
    def snapshot(data):
        result = {}
        for record in parse_selected_private_inventory(data):
            digest, path = record[:64].decode('ascii'), record[66:].decode('utf-8', errors='strict')
            result[path] = digest
        return result
    original, current = snapshot(before), snapshot(after)
    if any(current.get(path) != digest for path, digest in original.items()):
        raise ValueError('original private file changed or disappeared')
    keys = ('fixtureId', 'corpusVersion', 'corpusSha256Lf', 'targetPackage',
            'targetApkSha256', 'harnessPackage', 'harnessApkSha256')
    if any(owner.get(key) != identity.get(key) for key in keys) or type(owner.get('createdAt')) is not int:
        raise ValueError('failed lifetime owner identity differs')
    prefs = owner.get('preferences')
    if (not isinstance(prefs, list) or
            any(not isinstance(name, str) or not name.startswith('liber_replace_selected_') or
                '/' in name or '\\' in name for name in prefs) or len(prefs) != len(set(prefs))):
        raise ValueError('invalid registered preference names')
    registered = {'shared_prefs/' + name + '.xml' for name in prefs}
    additions = set(current) - set(original)
    if not additions <= registered:
        raise ValueError('unregistered private-file addition')
    return {'equal': original == current, 'originalsUnchanged': True,
            'registeredAdditions': sorted(additions)}


def check_selected_assets(apk, corpus_bytes, provenance_bytes):
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        for name, expected in [('assets/fixtures-selected.json', corpus_bytes),
                               ('assets/provenance.json', provenance_bytes)]:
            if names.count(name) != 1 or archive.read(name) != expected:
                raise ValueError('selected APK asset differs: ' + name)


def check_selected_manifest(text):
    """Read only the root and instrumentation identities from aapt's xmltree."""
    stack = []
    roots = []
    instrumentations = []
    for line in text.splitlines():
        element = re.fullmatch(r'( *)E: ([\w.-]+) \(line=\d+\)', line)
        if element:
            indent, name = len(element.group(1)), element.group(2)
            while stack and stack[-1]['indent'] >= indent:
                stack.pop()
            node = {'indent': indent, 'name': name, 'parent': stack[-1] if stack else None,
                    'attributes': {}}
            if node['parent'] is None:
                roots.append(node)
            if name == 'instrumentation':
                instrumentations.append(node)
            stack.append(node)
            continue
        if re.match(r'^ *E:', line):
            raise ValueError('malformed selected APK manifest element')
        attr = re.match(r'^( *)A: ([^\s=(]+)', line)
        if not attr:
            continue
        if not stack or len(attr.group(1)) <= stack[-1]['indent']:
            raise ValueError('malformed selected APK manifest attribute location')
        node, key = stack[-1], attr.group(2)
        if not ((node['parent'] is None and node['name'] == 'manifest' and key == 'package') or
                (node['name'] == 'instrumentation' and key in ('android:name', 'android:targetPackage'))):
            continue
        match = re.fullmatch(r' *A: [^\s=(]+(?:\((0x[0-9a-fA-F]+)\))?="([^"]*)"(?: \(Raw: "([^"]*)"\))?', line)
        expected_id = {'package': None, 'android:name': '0x01010003',
                       'android:targetPackage': '0x01010021'}[key]
        if (match is None or match.group(1) != expected_id or
                (match.group(3) is not None and match.group(2) != match.group(3))):
            raise ValueError('malformed selected APK manifest identity attribute: ' + key)
        node['attributes'].setdefault(key, []).append(match.group(2))
    if len(roots) != 1 or roots[0]['name'] != 'manifest' or len(instrumentations) != 1:
        raise ValueError('selected APK must contain one manifest root and instrumentation entry')
    root, entry = roots[0], instrumentations[0]
    if (entry['parent'] is not root or
            root['attributes'].get('package') != ['io.liber.oracle.replace.selected'] or
            entry['attributes'].get('android:name') != ['io.liber.oracle.nested.SelectedReaderOracle'] or
            entry['attributes'].get('android:targetPackage') != ['com.legado.app.debug']):
        raise ValueError('selected APK manifest package, instrumentation name or target differs')


def check_selected_report(fixture, report, binding):
    """Fail closed on selected capture identity, observations and terminal cleanup."""
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    require(report.get('failure') is None and report.get('cleanupFailure') is None,
            'selected instrumentation failed')
    for key in ('fixtureId', 'corpusVersion', 'baselineCommit'):
        require(report.get(key) == fixture[key], 'selected report identity differs: ' + key)
    require(report.get('fixtureSha256') == binding['corpusSha256Lf'] and
            report.get('boundary') == fixture['comparisonBoundary'] and
            report.get('fingerprint') == SELECTED_FINGERPRINT and report.get('paragraphIndent') == '　　',
            'selected corpus/boundary/runtime differs')
    identity = report.get('identity') or {}
    for key in ('corpusAssetSha256', 'corpusSha256Lf', 'harnessApkSha256', 'provenanceAssetSha256'):
        require(identity.get(key) == binding[key], 'selected measured identity differs: ' + key)
    require(identity.get('fixtureId') == 'REPLACE-17' and identity.get('corpusVersion') == 2 and
            identity.get('targetPackage') == 'com.legado.app.debug' and
            identity.get('targetApkSha256') == fixture['target']['apkSha256'] and
            identity.get('harnessPackage') == 'io.liber.oracle.replace.selected', 'selected packages differ')
    provenance = report.get('provenance') or {}
    require(binding['referenceHashes'] == {s['path']: s['sha256'] for s in fixture['frozenSources']},
            'selected reference source binding differs')
    require(provenance.get('baselineCommit') == fixture['baselineCommit'], 'selected provenance baseline differs')
    for key in ('sourceHashes', 'sourceHashesLf', 'referenceHashes', 'corpusAssetSha256', 'corpusSha256Lf', 'dexSha256'):
        require(provenance.get(key) == binding[key], 'selected provenance differs: ' + key)
    host = report.get('hostInitialization') or {}
    wrappers = {r['type']: r['factory'] for r in fixture['hostInitialization']['registrations']}
    require(host.get('verified') is True and host.get('applicationAttached') is False and
            host.get('method') == fixture['hostInitialization']['method'] and
            host.get('registeredWrappers') == wrappers, 'selected host initialization unverified')
    startup = report.get('startupContainment') or {}
    require(startup.get('intercepted') == 1 and startup.get('handled') == 1 and
            startup.get('beforeBinding') is True, 'selected shortcut containment unverified')
    isolation = report.get('isolation') or {}
    probe = isolation.get('preferenceProbe') or {}
    require(isolation.get('verified') is True and
            isolation.get('application') == 'io.liber.oracle.nested.GuardedReaderApplication' and
            probe.get('registered') is True and probe.get('committed') is True and
            probe.get('scopedFile') is True and probe.get('installationFile') is False,
            'selected scratch routing unverified')
    settings = report.get('settingsBefore') or {}
    require(settings.get('backupPath', 'missing') is None and
            isinstance(settings.get('paragraphIndent'), str) and
            type(settings.get('adaptSpecialStyle')) is bool and
            type(settings.get('replaceEnableDefault')) is bool and
            type(settings.get('chineseConverterType')) is int,
            'selected initial settings or backup path unverified')
    entry = report.get('entryPoints') or {}
    title_signature = 'getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)'
    content_signature = ('getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,'
                         'java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)')
    require(entry.get('getDisplayTitleArity') == 4 and entry.get('getContentArity') == 10 and
            title_signature in entry.get('getDisplayTitle', '') and
            content_signature in entry.get('getContent', ''), 'selected method signatures differ')
    owner = report.get('terminalOwner') or {}
    require(owner.get('scope') == 'Coroutine.DEFAULT' and owner.get('rootActive') is True and
            owner.get('rootCompleted') is False and owner.get('baselineChildren') == 0 and
            'kotlinx.coroutines.Job.getChildren()' in owner.get('childrenMethod', '') and
            'kotlinx.coroutines.Job.isCompleted()' in owner.get('completionMethod', ''),
            'selected coroutine owner baseline unverified')
    cleanup = report.get('cleanup') or {}
    removed = cleanup.get('preferencesRemoved')
    registered = cleanup.get('registeredPreferences')
    require(cleanup.get('databaseClosed') is True and cleanup.get('terminalProved') is True and
            cleanup.get('activityLaunchAttempts') == 0 and cleanup.get('scratchRemoved') is True and
            cleanup.get('scratchRetained') is False and isinstance(removed, list) and removed and
            isinstance(registered, list) and all(isinstance(x, str) for x in registered) and
            len(set(registered)) == len(registered) and
            all(isinstance(r, dict) and r.get('ok') is True and
                isinstance(r.get('name'), str) and r['name'].startswith('liber_replace_selected_') for r in removed) and
            sorted(r['name'] for r in removed) == sorted(registered),
            'selected cleanup unverified')
    rows = report.get('rows')
    ids = [r['id'] for r in fixture['cases'] if r['id'] != 'timeout']
    require(report.get('partition') == {'role': 'reader-non-timeout', 'caseIds': ids} and
            isinstance(rows, list) and [r.get('id') for r in rows] == ids,
            'selected partition or rows missing or reordered')
    def terminal(value):
        return isinstance(value, dict) and value.get('allCompleted') is True and \
            value.get('rootEmpty') is True and value.get('launchAttempts') == 0
    def strings(value):
        return isinstance(value, list) and all(isinstance(item, str) for item in value)
    for row in rows:
        calls = row.get('readerCalls')
        selection = row.get('selection')
        require(row.get('status') == 'observed' and isinstance(row.get('title'), str) and
                isinstance(row.get('content'), str) and isinstance(selection, dict) and
                strings(selection.get('title')) and strings(selection.get('content')) and
                strings(row.get('textList')) and '\n'.join(row['textList']) == row['content'] and
                type(row.get('sameTitleRemoved')) is bool and
                'effectiveRules' in row and (row['effectiveRules'] is None or strings(row['effectiveRules'])) and
                strings(row.get('disabledRules')) and terminal(row.get('terminal')) and
                isinstance(calls, list) and len(calls) == 2 and
                all(terminal(c) for c in calls) and
                [c.get('method') for c in calls] == ['getDisplayTitle', 'getContent'],
                'selected row incomplete: ' + str(row.get('id')))
        if row['id'] == 'timeout':
            require(type(row.get('timeoutObserved')) is bool and
                    isinstance(row.get('restartObservation'), str), 'timeout observation missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--frozen-source', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--corpus', type=Path, default=Path(__file__).with_name('fixtures.json'))
    parser.add_argument('--android-sdk', type=Path,
                        default=Path(os.environ.get('LOCALAPPDATA', '')) / 'Android/Sdk')
    parser.add_argument('--java-home', type=Path)
    parser.add_argument('--preflight-only', action='store_true', help='inspect selected APK and sources without device commands')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    fixture_path = args.corpus.resolve()
    legacy = Path(__file__).with_name('fixtures.json').resolve()
    selected_path = Path(__file__).with_name('fixtures-selected.json').resolve()
    selected = fixture_path == selected_path
    package = 'io.liber.oracle.replace.selected' if selected else PACKAGE
    target_package = 'com.legado.app.debug' if selected else 'io.legado.app.debug'
    baseline_apk = '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5' if selected else BASELINE_APK
    manifest = {'status': 'not-run', 'commands': [], 'serial': args.serial}
    installed = False

    def run(command, name, timeout=60, checked=True):
        try:
            result = subprocess.run(command, capture_output=True, timeout=timeout)
        except subprocess.TimeoutExpired as error:
            (args.output / (name + '.log')).write_bytes((error.stdout or b'') + (error.stderr or b'') + b'\nTIMED OUT\n')
            manifest['commands'].append({'command': command, 'exitCode': None,
                                         'timeoutSeconds': timeout, 'log': name + '.log'})
            raise
        (args.output / (name + '.log')).write_bytes(result.stdout + result.stderr)
        manifest['commands'].append({'command': command, 'exitCode': result.returncode,
                                     'log': name + '.log'})
        if checked and result.returncode:
            raise RuntimeError(f'{name} exited {result.returncode}; see raw log')
        return result

    def adb(name, *command, **kwargs):
        return run(['adb', '-s', args.serial, *command], name, **kwargs)

    try:
        if fixture_path not in (legacy, selected_path):
            raise ValueError('unsupported corpus path')
        if args.preflight_only and not selected:
            raise ValueError('--preflight-only requires the selected corpus')
        if selected and not args.preflight_only and args.serial != '5615f742':
            raise ValueError('selected capture requires the approved handset serial')
        fixture = json.loads(fixture_path.read_text(encoding='utf-8'))
        manifest.update({'fixtureSha256': sha(fixture_path), 'harnessApkSha256': sha(args.apk),
                         'harnessSources': {p.name: sha(p) for p in [
                             Path(__file__), Path(__file__).with_name('ReaderOracle.java'),
                             Path(__file__).with_name('AndroidManifest.xml'),
                             Path(__file__).with_name('build.ps1')]}})
        corpus_bytes = fixture_path.read_bytes()
        if selected:
            if (fixture.get('fixtureId') != 'REPLACE-17' or fixture.get('corpusVersion') != 2 or
                fixture.get('baselineCommit') != 'a7d37f1707a70a459ad708f4fe79341d1e42d716' or
                fixture.get('target', {}).get('package') != target_package or
                fixture.get('target', {}).get('apkSha256') != baseline_apk):
                raise ValueError('selected corpus identity differs')
            corpus_lf = hashlib.sha256(corpus_bytes.replace(b'\r\n', b'\n')).hexdigest()
            if corpus_lf != '6d73f51c2a03a93b728075a2d2acb4b8a4c8e31f454961b6a4eb7c3e318a1548':
                raise ValueError('selected corpus content differs')
        else:
            corpus_crlf = corpus_bytes.replace(b'\r\n', b'\n').replace(b'\n', b'\r\n')
            if hashlib.sha256(corpus_crlf).hexdigest() != '61983626e9af6a9095dafd474e91bf5994e437f08e0aa373261bf73179cd7968':
                raise ValueError('historical corpus content differs')
        head = run(['git', '-C', str(args.frozen_source), 'rev-parse', 'HEAD'], 'source-head')
        if head.stdout.decode().strip() != fixture['baselineCommit']:
            raise ValueError('frozen source HEAD differs')
        if selected:
            status = run(['git', '-C', str(args.frozen_source), 'status', '--porcelain=v1'], 'source-status')
            if status.stdout.strip():
                raise ValueError('selected frozen source checkout is not clean')
        manifest['frozenSources'] = {}
        for source in fixture['frozenSources']:
            path = args.frozen_source / source['path']
            if hashlib.sha1(path.read_bytes()).hexdigest() != source['sha1']:
                raise ValueError('frozen source bytes differ: ' + source['path'])
            manifest['frozenSources'][source['path']] = sha(path)
            if selected and manifest['frozenSources'][source['path']] != source['sha256']:
                raise ValueError('selected reference SHA-256 differs: ' + source['path'])
        binding = None
        if selected:
            with zipfile.ZipFile(args.apk) as archive:
                if archive.namelist().count('classes.dex') != 1:
                    raise ValueError('selected APK must contain exactly one primary dex')
                packaged_corpus = archive.read('assets/fixtures-selected.json')
                provenance_bytes = archive.read('assets/provenance.json')
                dex_bytes = archive.read('classes.dex')
            # Checkout and asset raw bytes may have different line endings; bind both.
            if packaged_corpus.replace(b'\r\n', b'\n') != corpus_bytes.replace(b'\r\n', b'\n'):
                raise ValueError('selected packaged corpus content differs')
            check_selected_assets(args.apk, packaged_corpus, provenance_bytes)
            provenance = json.loads(provenance_bytes.decode('utf-8-sig'))
            root = Path(__file__).resolve().parents[2]
            source_names = ['tool/replace_rule_oracle/ReaderOracle.java',
                            'tool/replace_rule_oracle/SelectedReaderOracle.java',
                            'tool/replace_rule_oracle/GuardedReaderApplication.java',
                            'tool/replace_rule_oracle/AndroidManifest-selected.xml',
                            'tool/replace_rule_oracle/build.ps1', 'tool/replace_rule_oracle/capture.py',
                            'tool/replace_rule_oracle/compare.dart', 'tool/nested_oracle/StateSessionOracle.java',
                            'tool/nested_oracle/HostRuntimeInit.java', 'tool/nested_oracle/ShortcutStartupGuard.java']
            source_hashes = {name: sha(root / name) for name in source_names}
            source_hashes_lf = {name: sha_lf(root / name) for name in source_names}
            reference_hashes = {s['path']: sha(args.frozen_source / s['path']) for s in fixture['frozenSources']}
            binding = {'corpusAssetSha256': hashlib.sha256(packaged_corpus).hexdigest(),
                       'corpusSha256Lf': corpus_lf, 'harnessApkSha256': sha(args.apk),
                       'provenanceAssetSha256': hashlib.sha256(provenance_bytes).hexdigest(),
                       'dexSha256': hashlib.sha256(dex_bytes).hexdigest(),
                       'sourceHashes': source_hashes, 'sourceHashesLf': source_hashes_lf,
                       'referenceHashes': reference_hashes}
            for key in ('corpusAssetSha256', 'corpusSha256Lf', 'dexSha256', 'sourceHashes', 'sourceHashesLf', 'referenceHashes'):
                if provenance.get(key) != binding[key]:
                    raise ValueError('packaged selected provenance differs: ' + key)
            if provenance.get('baselineCommit') != fixture['baselineCommit']:
                raise ValueError('packaged selected provenance baseline differs')
            if args.java_home is None:
                raise ValueError('selected preflight requires --java-home')
            tools = args.android_sdk / 'build-tools/35.0.1'
            aapt = str(tools / 'aapt.exe')
            xml = run([aapt, 'dump', 'xmltree', str(args.apk), 'AndroidManifest.xml'], 'apk-manifest')
            text = xml.stdout.decode(errors='replace')
            check_selected_manifest(text)
            sig = run([str(args.java_home / 'bin/java.exe'), '-jar', str(tools / 'lib/apksigner.jar'),
                       'verify', '--print-certs', str(args.apk)], 'apk-signature')
            signer_digests = re.findall(r'Signer #(\d+) certificate SHA-256 digest: ([0-9a-f]{64})',
                                        sig.stdout.decode(errors='replace'), re.IGNORECASE)
            if [(n, digest.lower()) for n, digest in signer_digests] != [
                    ('1', '954abf2c4e9528b2226457d598e2ff9d1b608f83ac00c52ad66e023d61b2f2ad')]:
                raise ValueError('selected harness signer differs or has multiple signers')
            manifest['selectedPreflight'] = binding
            if args.preflight_only:
                manifest['status'] = 'preflight-only'
                return 0
        manifest['fingerprint'] = adb('fingerprint', 'shell', 'getprop', 'ro.build.fingerprint').stdout.decode().strip()
        check_device_fingerprint(selected, manifest['fingerprint'])
        baseline = adb('baseline-path', 'shell', 'pm', 'path', target_package).stdout.decode().strip()
        adb('pull-baseline', 'pull', baseline.removeprefix('package:'), str(args.output / 'frozen.apk'))
        manifest['baselineApkSha256'] = sha(args.output / 'frozen.apk')
        if manifest['baselineApkSha256'] != baseline_apk:
            raise ValueError('installed baseline APK differs')
        if selected:
            existing = adb('harness-existing', 'shell', 'pm', 'list', 'packages', package)
            lines = existing.stdout.decode(errors='strict').splitlines()
            if any(line.strip() == 'package:' + package for line in lines):
                raise ValueError('harness package already exists; do not replace unowned install')
            if any(not line.startswith('package:') for line in lines):
                raise ValueError('harness inventory response is not a package list')
        else:
            existing = adb('harness-existing', 'shell', 'pm', 'path', package, checked=False)
            if b'package:' in existing.stdout:
                raise ValueError('harness package already exists; do not replace unowned install')
        # Only hash lists leave the device; no user content is copied.
        snapshot = SELECTED_INVENTORY_COMMAND if selected else "'find databases shared_prefs files -type f -exec sha256sum {} \\; 2>/dev/null'"
        before = adb('private-before', 'shell', 'run-as', target_package, 'sh', '-c', snapshot)
        if selected:
            original_inventory = parse_selected_private_inventory(before.stdout + before.stderr)
        # `-r` is adb's incremental install, the only form MIUI accepts on this
        # handset; the streamed `--no-incremental` install is rejected as
        # INSTALL_FAILED_USER_RESTRICTED even with USB installation enabled.
        installed_result = adb('install', 'install', '-r', str(args.apk), checked=False)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            if selected:
                manifest['recovery'] = 'not-run: failed install may have left a partial harness; inspect before retry'
            return 2
        installed = True
        if selected:
            if b'Success' not in installed_result.stdout:
                raise ValueError('selected harness install success not confirmed')
            installed_path = adb('harness-installed-path', 'shell', 'pm', 'path', package).stdout.decode().strip()
            if not installed_path.startswith('package:') or '\n' in installed_path:
                raise ValueError('selected harness installed path is ambiguous')
            installed_apk = args.output / 'installed-harness.apk'
            adb('pull-harness', 'pull', installed_path.removeprefix('package:'), str(installed_apk))
            manifest['installedHarnessSha256'] = sha(installed_apk)
            if manifest['installedHarnessSha256'] != binding['harnessApkSha256']:
                raise ValueError('installed selected harness differs from preflight APK')
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     package + '/' + ('io.liber.oracle.nested.SelectedReaderOracle' if selected else PACKAGE + '.ReaderOracle'), timeout=90)
        match = re.search(rb'READER_ORACLE_BASE64=([A-Za-z0-9+/=]+)', result.stdout)
        if match is None:
            raise ValueError('instrumentation produced no returned report')
        report = json.loads(base64.b64decode(match[1]))
        (args.output / 'observation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        after = adb('private-after', 'shell', 'run-as', target_package, 'sh', '-c', snapshot)
        preserved = (original_inventory == parse_selected_private_inventory(after.stdout + after.stderr)
                     if selected else sorted(before.stdout.splitlines()) == sorted(after.stdout.splitlines()))
        manifest['existingDataHashesUnchanged'] = preserved
        native_failure = report.get('failure') or report.get('cleanupFailure')
        if native_failure:
            manifest['nativeFailure'] = native_failure
        if selected and native_failure and not preserved:
            try:
                owner = adb('failed-owner', 'shell', 'run-as', target_package, 'cat',
                            'cache/liber-replace-selected/owner.json')
                manifest['preservationClassification'] = classify_selected_preservation(
                    before.stdout + before.stderr, after.stdout + after.stderr, json.loads(owner.stdout), report['identity'])
            except Exception as error:
                manifest['preservationFailure'] = str(error)
        if not preserved:
            manifest.setdefault('preservationFailure', 'private file hash list differs')
            raise ValueError('existing private file hash list changed; inspect before promotion')
        if native_failure:
            raise ValueError('instrumentation reported a failure')
        if selected:
            check_selected_report(fixture, report, binding)
        elif report.get('fixtureSha256') != manifest['fixtureSha256']:
            raise ValueError('installed harness contains different fixture bytes')
        if report.get('cleanup', {}).get('scratchRemoved') is not True:
            raise ValueError('scratch cleanup not confirmed')
        if not selected and [row['id'] for row in report['rows']] != [row['id'] for row in fixture['cases']]:
            raise ValueError('missing/reordered frozen rows')
        if any(row['status'] != 'observed' for row in report['rows']):
            raise ValueError('frozen row failed')
        if selected:
            adb('stop-owned-run', 'shell', 'am', 'force-stop', target_package)
            removed = adb('remove-harness', 'uninstall', package)
            if b'Success' not in removed.stdout:
                raise ValueError('selected harness uninstall not confirmed')
            remaining = adb('harness-removed-check', 'shell', 'pm', 'list', 'packages', package)
            remaining_lines = remaining.stdout.decode(errors='strict').splitlines()
            if any(not line.startswith('package:') for line in remaining_lines) or any(
                    line.strip() == 'package:' + package for line in remaining_lines):
                raise ValueError('selected harness removal inventory is not clean')
            installed = False
            manifest['harnessRemoved'] = True
        if selected:
            golden = dict(report)
            golden['hostCapture'] = {'existingDataHashesUnchanged': preserved,
                                     'harnessRemoved': manifest['harnessRemoved'],
                                     'installedHarnessSha256': manifest['installedHarnessSha256'],
                                     'preflight': binding}
            (args.output / 'golden.json').write_text(
                json.dumps(golden, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        else:
            (args.output / 'golden.json').write_bytes((args.output / 'observation.json').read_bytes())
        manifest['goldenSha256'] = sha(args.output / 'golden.json')
        manifest['status'] = 'observed'
        return 0
    except Exception as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        return 1
    finally:
        if installed and (not selected or manifest['status'] == 'observed'):
            # A failed selected lifetime and its owned residue remain for controller recovery.
            adb('stop-owned-run', 'shell', 'am', 'force-stop', target_package, checked=False)
            adb('remove-harness', 'uninstall', package, checked=False)
        elif installed:
            manifest['recovery'] = 'not-run: failed selected lifetime and owned residue retained for controller'
        (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'], 'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
