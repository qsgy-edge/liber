"""Selected HTML capture and off-device preflight; never manufacture a golden."""
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
import tempfile
import zipfile

BASELINE = 'a7d37f1707a70a459ad708f4fe79341d1e42d716'
TARGET = 'com.legado.app.debug'
TARGET_SHA = '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5'
PACKAGE = 'io.liber.oracle.html.selected'
ENTRY = 'io.liber.oracle.nested.SelectedHtmlOracle'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys'
SIGNER = '954abf2c4e9528b2226457d598e2ff9d1b608f83ac00c52ad66e023d61b2f2ad'
CORPORA = {'fixtures-selected.json': '5b5bca0204fba6e1da4abdb8fd64fb7b0017dab5bf560098ef4b97f36117c266',
           'list-fixtures-selected.json': '837228894594decc6dcf195cd565365ef461c760f02cbb6b02e32f0fa7f6eb01'}
SOURCES = ['tool/html_oracle/SelectedHtmlOracle.java', 'tool/html_oracle/AndroidManifest-selected.xml',
           'tool/html_oracle/build.ps1', 'tool/html_oracle/capture.py', 'tool/html_adapter_gate.dart',
           'tool/replace_rule_oracle/GuardedReaderApplication.java', 'tool/nested_oracle/StateSessionOracle.java',
           'tool/nested_oracle/HostRuntimeInit.java', 'tool/nested_oracle/ShortcutStartupGuard.java']
EXTRA_REFERENCES = ['app/src/main/java/io/legado/app/model/analyzeRule/SourceHtmlParser.kt',
                    'app/src/main/java/io/legado/app/model/SharedJsScope.kt',
                    'app/src/main/java/io/legado/app/help/coroutine/Coroutine.kt',
                    'app/src/main/java/io/legado/app/App.kt']


# The completion line is emitted only after find and every batched hash succeeds.
PRIVATE_INVENTORY_COMPLETE = b'__LIBER_HTML_PRIVATE_INVENTORY_COMPLETE__'
PRIVATE_INVENTORY_SCRIPT = (
    'set -e; find . -type f -exec sh -c '
    "'for f do sha256sum \"$f\" || exit 20; done' sh {} +; "
    "printf '%s\\n' '__LIBER_HTML_PRIVATE_INVENTORY_COMPLETE__'"
)
PRIVATE_INVENTORY_COMMAND = shlex.quote(PRIVATE_INVENTORY_SCRIPT)


def parse_private_inventory(data):
    """Accept only a complete file-hash inventory, including a proven empty walk."""
    if not data.endswith(b'\n'):
        raise ValueError('private inventory completion missing or truncated')
    lines = [line.removesuffix(b'\r') for line in data[:-1].split(b'\n')]
    if lines[-1] != PRIVATE_INVENTORY_COMPLETE or PRIVATE_INVENTORY_COMPLETE in lines[:-1]:
        raise ValueError('private inventory completion missing or misplaced')
    records = lines[:-1]
    if any(not re.fullmatch(rb'[0-9a-f]{64}  [^\r\n]+', line) for line in records):
        raise ValueError('private inventory record malformed')
    paths = [line[66:] for line in records]
    if len(set(paths)) != len(paths):
        raise ValueError('private inventory repeats a path')
    return sorted(records)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_hash(path):
    return digest(path.read_bytes())


def strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def require_success(data):
    if re.search(rb'(?im)(?:Failure\s*\[|^\s*TIMED OUT\b)', data) or len(re.findall(rb'(?m)^Success\s*$', data)) != 1:
        raise ValueError('success receipt missing or contradicted')


def instrumentation_payload(data):
    if (re.search(rb'(?im)(?:Failure\s*\[|^\s*(?:TIMED OUT\b|INSTRUMENTATION_FAILED|INSTRUMENTATION_ABORTED)|shortMsg=)', data)
            or re.search(rb'(?m)^INSTRUMENTATION_STATUS_CODE:\s*-[12]\s*$', data)):
        raise ValueError('instrumentation failure or timeout')
    payloads = re.findall(rb'HTML_ORACLE_BASE64=([A-Za-z0-9+/=]+)', data)
    codes = re.findall(rb'(?m)^INSTRUMENTATION_CODE:\s*(-?\d+)\s*$', data)
    if len(payloads) != 1 or codes != [b'-1']:
        raise ValueError('instrumentation payload or result code is not unique success')
    return strict_json(base64.b64decode(payloads[0], validate=True).decode('utf-8'))


def check_manifest(text):
    stack, roots, entries = [], [], []
    for line in text.splitlines():
        node = re.fullmatch(r'( *)E: ([\w.-]+) \(line=\d+\)', line)
        if node:
            depth, name = len(node.group(1)), node.group(2)
            while stack and stack[-1]['depth'] >= depth:
                stack.pop()
            item = {'depth': depth, 'name': name, 'parent': stack[-1] if stack else None, 'attrs': {}}
            if not stack:
                roots.append(item)
            if name == 'instrumentation':
                entries.append(item)
            stack.append(item)
            continue
        if re.match(r'^ *E:', line):
            raise ValueError('malformed manifest element')
        attr = re.match(r'^( *)A: ([^\s=(]+)', line)
        if not attr:
            continue
        if not stack or len(attr.group(1)) <= stack[-1]['depth']:
            raise ValueError('malformed manifest attribute')
        key = attr.group(2)
        if key not in ('package', 'android:name', 'android:targetPackage'):
            continue
        if not ((not stack[-1]['parent'] and key == 'package') or
                (stack[-1]['name'] == 'instrumentation' and key != 'package')):
            continue
        match = re.fullmatch(r' *A: [^\s=(]+(?:\((0x[0-9a-fA-F]+)\))?="([^"]*)"(?: \(Raw: "([^"]*)"\))?', line)
        expected = {'package': None, 'android:name': '0x01010003', 'android:targetPackage': '0x01010021'}[key]
        if not match or match.group(1) != expected or (match.group(3) is not None and match.group(2) != match.group(3)):
            raise ValueError('malformed manifest identity')
        stack[-1]['attrs'].setdefault(key, []).append(match.group(2))
    if (len(roots) != 1 or roots[0]['name'] != 'manifest' or len(entries) != 1 or entries[0]['parent'] is not roots[0]
            or roots[0]['attrs'].get('package') != [PACKAGE]
            or entries[0]['attrs'].get('android:name') != [ENTRY]
            or entries[0]['attrs'].get('android:targetPackage') != [TARGET]):
        raise ValueError('manifest package, entry or target differs')


def source_binding(root, source, fixture):
    hashes = {p: file_hash(root / p) for p in SOURCES}
    lf = {p: digest((root / p).read_bytes().replace(b'\r\n', b'\n')) for p in SOURCES}
    refs = {s['path']: file_hash(source / s['path']) for s in fixture['frozenSources']}
    for row in fixture['frozenSources']:
        b = (source / row['path']).read_bytes()
        if hashlib.sha1(b).hexdigest() != row['sha1'] or digest(b) != row['sha256']:
            raise ValueError('reference source differs: ' + row['path'])
    refs.update({p: file_hash(source / p) for p in EXTRA_REFERENCES})
    return hashes, lf, refs


def run_checked(command):
    result = subprocess.run([str(x) for x in command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=120)
    if result.returncode:
        raise ValueError('command failed: ' + str(command) + '\n' + result.stderr.decode(errors='replace'))
    return result.stdout


def preflight(apk, corpus, source, sdk, java, evidence=None):
    receipts = []
    def inspect(name, command):
        output = run_checked(command)
        receipts.append({'name': name, 'command': [str(x) for x in command],
                         'exitCode': 0, 'sha256': digest(output)})
        if evidence is not None:
            (evidence / ('preflight-' + name + '.log')).write_bytes(output)
        return output
    root = Path(__file__).resolve().parents[2]
    corpus = corpus.resolve()
    if corpus.parent != Path(__file__).resolve().parent or corpus.name not in CORPORA:
        raise ValueError('unsupported selected corpus path')
    data = corpus.read_bytes()
    if digest(data) != CORPORA[corpus.name]:
        raise ValueError('selected corpus bytes differ')
    fixture = strict_json(data)
    if fixture['baselineCommit'] != BASELINE or fixture['target']['package'] != TARGET or fixture['target']['apkSha256'] != TARGET_SHA:
        raise ValueError('selected corpus identity differs')
    if inspect('source-head', ['git', '-C', source, 'rev-parse', 'HEAD']).decode().strip() != BASELINE or inspect('source-status', ['git', '-C', source, 'status', '--porcelain=v1']).strip():
        raise ValueError('reference source HEAD or cleanliness differs')
    hashes, lf, refs = source_binding(root, source, fixture)
    with zipfile.ZipFile(apk) as z:
        names = z.namelist()
        for name in ('AndroidManifest.xml', 'assets/html-fixtures.json', 'assets/provenance.json', 'classes.dex'):
            if names.count(name) != 1:
                raise ValueError('missing or duplicated selected APK member: ' + name)
        if [name for name in names if re.fullmatch(r'classes\d*\.dex', name)] != ['classes.dex']:
            raise ValueError('selected APK must have exactly one primary DEX')
        packaged = z.read('assets/html-fixtures.json')
        provenance_bytes = z.read('assets/provenance.json')
        dex = z.read('classes.dex')
    if packaged != data:
        raise ValueError('packaged selected corpus differs')
    provenance = strict_json(provenance_bytes.decode('utf-8-sig'))
    expected = {'baselineCommit': BASELINE, 'corpusAssetSha256': digest(data), 'corpusSha256Lf': digest(data.replace(b'\r\n', b'\n')),
                'sourceHashes': hashes, 'sourceHashesLf': lf, 'referenceHashes': refs, 'dexSha256': digest(dex)}
    if provenance != expected:
        raise ValueError('packaged selected provenance differs')
    tools = sdk / 'build-tools/35.0.1'
    with tempfile.TemporaryDirectory(prefix='liber-html-dex-') as temporary:
        dex_path = Path(temporary) / 'classes.dex'
        dex_path.write_bytes(dex)
        dump = inspect('dex', [tools / 'dexdump.exe', dex_path]).decode(errors='strict')
    descriptor = "Class descriptor  : 'Lio/liber/oracle/nested/SelectedHtmlOracle;'"
    if dump.count(descriptor) != 1:
        raise ValueError('selected entry definition missing or duplicated in DEX')
    check_manifest(inspect('manifest', [tools / 'aapt.exe', 'dump', 'xmltree', apk, 'AndroidManifest.xml']).decode(errors='strict'))
    signature = inspect('signature', [java / 'bin/java.exe', '-jar', tools / 'lib/apksigner.jar', 'verify', '--print-certs', apk]).decode(errors='strict')
    signers = re.findall(r'Signer #(\d+) certificate SHA-256 digest: ([0-9a-f]{64})', signature, re.I)
    if [(n, h.lower()) for n, h in signers] != [('1', SIGNER)]:
        raise ValueError('selected signer differs')
    if evidence is not None:
        (evidence / 'preflight-commands.json').write_text(json.dumps(receipts, indent=2) + '\n', encoding='utf-8')
    return {'corpusSha256': digest(data), 'corpusBytes': len(data), 'harnessApkSha256': file_hash(apk), 'provenanceSha256': digest(provenance_bytes),
            'dexSha256': digest(dex), 'provenance': provenance}


def validate_observation(fixture, report, binding):
    def require(condition, message):
        if not condition:
            raise ValueError(message)
    require(isinstance(report, dict) and set(report) == {
        'identity', 'provenance', 'baselineCommit', 'entryPoint', 'fingerprint', 'corpus',
        'startupContainment', 'isolation', 'hostInitialization', 'terminalOwner', 'entryPoints',
        'observations', 'cleanup'}, 'selected native lifetime incomplete or contradictory')
    require(report.get('baselineCommit') == BASELINE and report.get('entryPoint') == fixture['entryPoint']
            and report.get('fingerprint') == FINGERPRINT, 'native baseline, entry or fingerprint differs')
    corpus = report.get('corpus') or {}
    require(corpus == {'asset': 'html-fixtures.json', 'bytes': binding['corpusBytes'],
                       'sha256': binding['corpusSha256'], 'fixtureId': fixture['fixtureId'],
                       'corpusVersion': 1, 'schemaVersion': 1}
            and all(type(corpus.get(k)) is int for k in ('bytes', 'corpusVersion', 'schemaVersion')),
            'native corpus differs')
    identity = report.get('identity') or {}
    for key, value in {'fixtureId': fixture['fixtureId'], 'corpusVersion': 1, 'targetPackage': TARGET,
                       'targetApkSha256': TARGET_SHA, 'harnessPackage': PACKAGE,
                       'harnessApkSha256': binding['harnessApkSha256'],
                       'corpusAssetSha256': binding['corpusSha256'], 'corpusSha256Lf': binding['corpusSha256'],
                       'provenanceAssetSha256': binding['provenanceSha256']}.items():
        require(identity.get(key) == value, 'native identity differs: ' + key)
    require(type(identity.get('corpusVersion')) is int, 'native corpus version must be an integer')
    require(report.get('provenance') == binding['provenance'], 'native provenance differs')
    startup, isolation, host = report.get('startupContainment') or {}, report.get('isolation') or {}, report.get('hostInitialization') or {}
    probe = isolation.get('preferenceProbe') or {}
    require(startup.get('service') == 'shortcut' and startup.get('provider') == 'io.legado.app.api.ReaderProvider'
            and type(startup.get('intercepted')) is int and startup['intercepted'] == 1
            and type(startup.get('handled')) is int and startup['handled'] == 1 and startup.get('beforeBinding') is True,
            'startup containment unverified')
    require(isolation.get('verified') is True and isolation.get('application') == 'io.liber.oracle.nested.GuardedReaderApplication'
            and isinstance(isolation.get('scratchRoot'), str) and isolation['scratchRoot'].endswith('/cache/liber-html-selected')
            and probe.get('name') == 'liber_html_selected_html_probe'
            and probe.get('registered') is True and probe.get('committed') is True
            and probe.get('scopedFile') is True and probe.get('installationFile') is False, 'scratch routing unverified')
    wrappers = {r['type']: r['factory'] for r in fixture['hostInitialization']['registrations']}
    require(host.get('verified') is True and host.get('applicationAttached') is False
            and host.get('invokedOn') == 'unattached-instance' and isinstance(host.get('notRun'), list)
            and 'io.legado.app.App.onCreate' in host['notRun']
            and host.get('registeredWrappers') == wrappers and host.get('method') == fixture['hostInitialization']['method'],
            'host initialization unverified')
    entries = report.get('entryPoints') or {}
    for key, signature in {'constructor': 'AnalyzeRule(io.legado.app.model.analyzeRule.RuleDataInterface,io.legado.app.data.entities.BaseSource,boolean,boolean)',
                           'setContent': 'setContent(java.lang.Object,java.lang.String)',
                           'getString': 'getString(java.lang.String,java.lang.Object,boolean)',
                           'getStringList': 'getStringList(java.lang.String,java.lang.Object,boolean)'}.items():
        require(isinstance(entries.get(key), str) and signature in entries[key], 'native signature differs: ' + key)
    owner = report.get('terminalOwner') or {}
    require(owner.get('scope') == 'Coroutine.DEFAULT' and owner.get('rootActive') is True
            and owner.get('rootCompleted') is False and type(owner.get('baselineChildren')) is int and owner['baselineChildren'] == 0
            and 'kotlinx.coroutines.Job.getChildren()' in owner.get('childrenMethod', '')
            and 'kotlinx.coroutines.Job.isCompleted()' in owner.get('completionMethod', ''), 'job owner unverified')
    rows = report.get('observations')
    require(isinstance(rows, list) and len(rows) == len(fixture['cases'])
            and [r.get('id') for r in rows] == [r['id'] for r in fixture['cases']], 'native rows missing or reordered')
    for row, case in zip(rows, fixture['cases']):
        require(isinstance(row, dict) and set(row) in ({'id', 'terminal', 'value'}, {'id', 'terminal', 'error'}),
                'native row outcome ambiguous or contradictory')
        if 'error' in row:
            require(isinstance(row['error'], str) and bool(row['error'].strip()), 'native row error malformed')
        else:
            value = row['value']
            if case.get('method', 'getString') in ('getStringList', 'getStringListUrl'):
                require(value is None or isinstance(value, list) and all(isinstance(x, str) for x in value), 'native list malformed')
            else:
                require(value is None or isinstance(value, str), 'native scalar malformed')
        terminal = row.get('terminal') or {}
        require(terminal.get('owner') == 'Coroutine.DEFAULT Job' and terminal.get('allCompleted') is True
                and terminal.get('rootEmpty') is True and type(terminal.get('launchAttempts')) is int and terminal['launchAttempts'] == 0
                and type(terminal.get('observedChildren')) is int and terminal['observedChildren'] >= 0,
                'row terminal unverified')
    cleanup = report.get('cleanup') or {}
    registered, removed = cleanup.get('registeredPreferences'), cleanup.get('preferencesRemoved')
    require(cleanup.get('databaseClosed') is True and cleanup.get('terminalProved') is True
            and type(cleanup.get('activityLaunchAttempts')) is int and cleanup['activityLaunchAttempts'] == 0 and cleanup.get('scratchRemoved') is True
            and cleanup.get('scratchRetained') is False and isinstance(registered, list) and registered
            and len(set(registered)) == len(registered) and all(isinstance(x, str) and x.startswith('liber_html_selected_')
                and '/' not in x and '\\' not in x and '..' not in x and '\x00' not in x for x in registered)
            and isinstance(removed, list) and all(isinstance(x, dict) and x.get('ok') is True for x in removed)
            and sorted(x.get('name') for x in removed) == sorted(registered), 'native cleanup unverified')


def require_webview(text):
    pattern = r'(?m)^\s*Current WebView package \(name, version\): \(com\.google\.android\.webview, 158\.0\.8127\.2\)\s*$'
    if len(re.findall(pattern, text)) != 1:
        raise ValueError('current WebView provider or version differs')


def verify_bundle(directory, fixture, binding, provisional_manifest=None):
    def artifact(name):
        path = directory / name
        if not path.is_file():
            raise ValueError('Selected capture bundle missing: ' + name)
        return path.read_bytes()

    manifest = strict_json(artifact('manifest.json')) if provisional_manifest is None else provisional_manifest
    observation = strict_json(artifact('observation.json'))
    if (not isinstance(manifest, dict) or set(manifest) != {'status', 'serial', 'commands', 'preflight'}
            or manifest.get('status') != 'observed' or manifest.get('serial') != '5615f742'
            or manifest.get('error') is not None or manifest.get('recovery') is not None
            or manifest.get('preflight') != binding):
        raise ValueError('selected capture manifest differs')
    if digest(artifact('frozen.apk')) != TARGET_SHA or digest(artifact('installed-harness.apk')) != binding['harnessApkSha256']:
        raise ValueError('selected installed APK differs')
    names = ['fingerprint', 'api', 'webview', 'target-path', 'target-pull', 'harness-before',
             'private-before', 'install', 'installed-path', 'installed-pull', 'instrumentation',
             'private-after', 'stop-owned-run', 'target-stopped-check', 'scratch-removed-check',
             'remove-harness', 'harness-removed-check', 'private-final']
    commands = manifest.get('commands')
    if not isinstance(commands, list) or [r.get('name') for r in commands] != names:
        raise ValueError('selected capture command sequence differs')
    outputs = {}
    for row in commands:
        name = row['name']
        raw = artifact(name + '.log')
        if row.get('log') != name + '.log' or type(row.get('exitCode')) is not int or row['exitCode'] != 0 or row.get('sha256') != digest(raw):
            raise ValueError('selected receipt differs: ' + name)
        if re.search(rb'(?im)(?:Failure\s*\[|^\s*TIMED OUT\b)', raw):
            raise ValueError('failure or timeout in receipt: ' + name)
        outputs[name] = raw
    if outputs['fingerprint'].decode().strip() != FINGERPRINT or outputs['api'].decode().strip() != '37':
        raise ValueError('selected device fingerprint or API differs')
    require_webview(outputs['webview'].decode())
    def package_path(name):
        text = outputs[name].decode().strip()
        if not re.fullmatch(r'package:[^\r\n]+', text):
            raise ValueError('selected package path ambiguous: ' + name)
        return text[8:]
    target_path = package_path('target-path'); harness_path = package_path('installed-path')
    identity = observation.get('identity') or {}
    if identity.get('targetApkPath') != target_path or identity.get('harnessApkPath') != harness_path:
        raise ValueError('native installed APK paths differ from package receipts')
    expected = {
        'fingerprint': ['shell', 'getprop', 'ro.build.fingerprint'],
        'api': ['shell', 'getprop', 'ro.build.version.sdk'],
        'webview': ['shell', 'dumpsys', 'webviewupdate'],
        'target-path': ['shell', 'pm', 'path', TARGET],
        'harness-before': ['shell', 'pm', 'list', 'packages', PACKAGE],
        'private-before': ['shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND],
        'installed-path': ['shell', 'pm', 'path', PACKAGE],
        'instrumentation': ['shell', 'am', 'instrument', '-w', '-r', PACKAGE + '/' + ENTRY],
        'private-after': ['shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND],
        'stop-owned-run': ['shell', 'am', 'force-stop', TARGET],
        'target-stopped-check': ['shell', 'sh', '-c', "'if ! command -v pidof >/dev/null; then echo ERROR; elif pidof com.legado.app.debug >/dev/null; then echo PRESENT; else echo ABSENT; fi'"],
        'scratch-removed-check': ['shell', 'run-as', TARGET, 'sh', '-c', "'if test -e cache/liber-html-selected; then echo PRESENT; else echo ABSENT; fi'"],
        'remove-harness': ['uninstall', PACKAGE],
        'harness-removed-check': ['shell', 'pm', 'list', 'packages', PACKAGE],
        'private-final': ['shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND],
    }
    for row in commands:
        command = row.get('command')
        if not isinstance(command, list) or command[:3] != ['adb', '-s', '5615f742']:
            raise ValueError('selected adb command differs')
        args, name = command[3:], row['name']
        if name in expected and args != expected[name]:
            raise ValueError('selected command differs: ' + name)
        if name == 'install' and (len(args) != 3 or args[:2] != ['install', '-r'] or not isinstance(args[2], str)):
            raise ValueError('selected install command differs')
        if name in ('target-pull', 'installed-pull'):
            source, filename = (target_path, 'frozen.apk') if name == 'target-pull' else (harness_path, 'installed-harness.apk')
            if len(args) != 3 or args[:2] != ['pull', source] or not isinstance(args[2], str) or args[2].replace('\\', '/').split('/')[-1] != filename:
                raise ValueError('selected pull command differs')
    for name in ('harness-before', 'harness-removed-check'):
        lines = outputs[name].decode().splitlines()
        if any(not x.startswith('package:') or x == 'package:' + PACKAGE for x in lines):
            raise ValueError('selected harness inventory differs: ' + name)
    require_success(outputs['install']); require_success(outputs['remove-harness'])
    if outputs['target-stopped-check'].strip() != b'ABSENT' or outputs['scratch-removed-check'].strip() != b'ABSENT':
        raise ValueError('selected process or scratch remains')
    before = parse_private_inventory(outputs['private-before'])
    after = parse_private_inventory(outputs['private-after'])
    final = parse_private_inventory(outputs['private-final'])
    if before != after or before != final:
        raise ValueError('selected private snapshots differ')
    if instrumentation_payload(outputs['instrumentation']) != observation:
        raise ValueError('selected instrumentation payload differs from observation')
    validate_observation(fixture, observation, binding)
    return observation


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', type=Path, required=True)
    parser.add_argument('--corpus', type=Path, required=True)
    parser.add_argument('--frozen-source', type=Path, required=True)
    parser.add_argument('--java-home', type=Path, required=True)
    parser.add_argument('--android-sdk', type=Path, default=Path(os.environ.get('LOCALAPPDATA', '')) / 'Android/Sdk')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--serial', default='5615f742')
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--verify-bundle', type=Path, help='verify a completed raw capture without a device')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    manifest = {'status': 'not-run', 'commands': [], 'serial': args.serial}
    installed = False

    def run(name, command, timeout=90):
        try:
            result = subprocess.run([str(x) for x in command], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=timeout)
            output, code = result.stdout, result.returncode
        except subprocess.TimeoutExpired as error:
            output, code = (error.stdout or b'') + b'\nTIMED OUT\n', None
        (args.output / (name + '.log')).write_bytes(output)
        manifest['commands'].append({'name': name, 'command': [str(x) for x in command], 'exitCode': code, 'log': name + '.log', 'sha256': digest(output)})
        if code != 0:
            raise ValueError(name + ' failed or timed out')
        return output

    def adb(name, *command):
        return run(name, ['adb', '-s', args.serial, *command])

    try:
        binding = preflight(args.apk, args.corpus, args.frozen_source, args.android_sdk, args.java_home, args.output)
        manifest['preflight'] = binding
        if args.preflight_only and args.verify_bundle is not None:
            raise ValueError('choose preflight or bundle verification')
        if args.preflight_only:
            manifest['status'] = 'preflight-only'
            return 0
        if args.verify_bundle is not None:
            verify_bundle(args.verify_bundle, strict_json(args.corpus.read_bytes()), binding)
            manifest['status'] = 'verified-bundle'
            return 0
        if args.serial != '5615f742':
            raise ValueError('unapproved handset serial')
        if adb('fingerprint', 'shell', 'getprop', 'ro.build.fingerprint').decode().strip() != FINGERPRINT:
            raise ValueError('fingerprint differs')
        if adb('api', 'shell', 'getprop', 'ro.build.version.sdk').decode().strip() != '37':
            raise ValueError('API differs')
        webview = adb('webview', 'shell', 'dumpsys', 'webviewupdate').decode(errors='strict')
        require_webview(webview)
        path = adb('target-path', 'shell', 'pm', 'path', TARGET).decode().strip()
        if not re.fullmatch(r'package:[^\r\n]+', path):
            raise ValueError('target APK path ambiguous')
        adb('target-pull', 'pull', path[8:], str(args.output / 'frozen.apk'))
        if file_hash(args.output / 'frozen.apk') != TARGET_SHA:
            raise ValueError('installed target APK differs')
        inventory = adb('harness-before', 'shell', 'pm', 'list', 'packages', PACKAGE).decode().splitlines()
        if any(not x.startswith('package:') or x == 'package:' + PACKAGE for x in inventory):
            raise ValueError('harness already present or inventory malformed')
        before = adb('private-before', 'shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND)
        original = parse_private_inventory(before)
        installed = True  # Even an ambiguous install can leave a partial harness.
        install = adb('install', 'install', '-r', str(args.apk)); require_success(install)
        installed_path = adb('installed-path', 'shell', 'pm', 'path', PACKAGE).decode().strip()
        if not re.fullmatch(r'package:[^\r\n]+', installed_path):
            raise ValueError('installed harness path ambiguous')
        adb('installed-pull', 'pull', installed_path[8:], str(args.output / 'installed-harness.apk'))
        if file_hash(args.output / 'installed-harness.apk') != binding['harnessApkSha256']:
            raise ValueError('installed harness differs')
        report = instrumentation_payload(adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r', PACKAGE + '/' + ENTRY))
        (args.output / 'observation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        validate_observation(strict_json(args.corpus.read_bytes()), report, binding)
        after = adb('private-after', 'shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND)
        if original != parse_private_inventory(after):
            raise ValueError('private file preservation differs')
        adb('stop-owned-run', 'shell', 'am', 'force-stop', TARGET)
        process = adb('target-stopped-check', 'shell', 'sh', '-c', "'if ! command -v pidof >/dev/null; then echo ERROR; elif pidof com.legado.app.debug >/dev/null; then echo PRESENT; else echo ABSENT; fi'")
        if process.strip() != b'ABSENT':
            raise ValueError('target process remains')
        scratch = adb('scratch-removed-check', 'shell', 'run-as', TARGET, 'sh', '-c', "'if test -e cache/liber-html-selected; then echo PRESENT; else echo ABSENT; fi'")
        if scratch.strip() != b'ABSENT':
            raise ValueError('scratch root remains')
        require_success(adb('remove-harness', 'uninstall', PACKAGE))
        remaining = adb('harness-removed-check', 'shell', 'pm', 'list', 'packages', PACKAGE).decode().splitlines()
        if any(not x.startswith('package:') or x == 'package:' + PACKAGE for x in remaining):
            raise ValueError('harness removal inventory differs')
        installed = False
        final = adb('private-final', 'shell', 'run-as', TARGET, 'sh', '-c', PRIVATE_INVENTORY_COMMAND)
        if original != parse_private_inventory(final):
            raise ValueError('final private file preservation differs')
        manifest['status'] = 'observed'
        verify_bundle(args.output, strict_json(args.corpus.read_bytes()), binding, manifest)
        return 0
    except Exception as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        return 1
    finally:
        if installed:
            manifest['recovery'] = 'not-run: failed lifetime and owned residue retained for controller'
        (args.output / 'manifest.json').write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'], 'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
