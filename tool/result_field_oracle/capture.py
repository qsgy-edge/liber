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
import copy
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import urllib.parse
import uuid
import zipfile

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.fields'
INSTRUMENTATION = PACKAGE + '/.FieldOracle'
TARGET_PACKAGE = 'io.legado.app.debug'
REPORT_REMOTE = '/sdcard/Android/data/io.legado.app.debug/files/field-oracle.json'
FIELDS_01 = 'FIELDS-01'
FIELDS_02 = 'FIELDS-02'
SELECTED_BASELINE = 'a7d37f1707a70a459ad708f4fe79341d1e42d716'
SELECTED_CORPUS_SHA256 = '049b46bbd98b9367516f923fc052d9d454057d99bd6875a89b88ce6fae09d500'
SELECTED_CHAPTER_CORPUS_SHA256 = (
    '0cfa3b2ddb4a43ec8e62c0b9f5396e638c6c2dde40033a27be316ee5b74055c8',
    '98934998a2c5cc702bd24888f8ed59ce595d617870c2c5a45b79e0b947d7c7d0',
    '1e8f9517a4fb12da0ddf37c74bb2a024b35620e89a32b50f531f7bc11330ba6a',
)
SELECTED_READER_CORPUS_SHA256 = '88eba883d045dcd73c187ecd6cb7508e37d5721ef550000f4b21b1312dc1e8e0'
SELECTED_JSON_REPLACE_CORPUS_SHA256 = '0f87c6c775ff54164bc11a9a30efaa48e5155def31c37e9b7eb8e721bd776be9'
SELECTED_CORPUS_SHA256S = (
    SELECTED_CORPUS_SHA256,
    *SELECTED_CHAPTER_CORPUS_SHA256,
    SELECTED_READER_CORPUS_SHA256,
    SELECTED_JSON_REPLACE_CORPUS_SHA256,
)
SELECTED_SIGNER = '954abf2c4e9528b2226457d598e2ff9d1b608f83ac00c52ad66e023d61b2f2ad'
SELECTED_TARGET = {
    'package': 'com.legado.app.debug',
    'apkSha256': '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
    'deviceFingerprint': 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys',
}
OWNED_PREFERENCE_PREFIX = 'liber_fields_02_'
HISTORICAL_SOURCE_KEYS = (
    'FieldOracle.java',
    'StateSessionOracle.java',
    'AndroidManifest.xml',
    'build.ps1',
    'capture.py',
)
HARNESS_SOURCE_KEYS = HISTORICAL_SOURCE_KEYS + (
    'HostRuntimeInit.java', 'ShortcutStartupGuard.java',
)
SELECTED_SOURCE_KEYS = HARNESS_SOURCE_KEYS + (
    'GuardedReaderApplication.java', 'SelectedFieldHostBridge.java',
    'AndroidManifest-selected.xml',
)
# The frozen application's own persisted data. Starting its process writes
# third-party state (Play Services measurement, Firebase, WebView Chromium
# prefs) that this corpus cannot and need not control, so the gate is the
# application's own store staying byte-identical and every other change being
# named in the manifest rather than dropped.
FROZEN_APP_STORE = ('databases/legado.db', 'databases/legado.db-wal',
                    'databases/legado.db-shm', 'shared_prefs/local.xml')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def lf_bytes(data):
    return data.replace(b"\r\n", b"\n")


def remote_script_arguments(package, script):
    """Return the single remote-shell argument for a run-as script."""
    return ['run-as', package, 'sh', '-c', shlex.quote(script)]


def _is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def _require_int(value, label):
    if not _is_int(value):
        raise ValueError(label + ' must be an integer')
    return value


def _source_path(name):
    here = Path(__file__).resolve().parent
    if name in ('StateSessionOracle.java', 'HostRuntimeInit.java', 'ShortcutStartupGuard.java'):
        return here.parent / 'nested_oracle' / name
    if name == 'GuardedReaderApplication.java':
        return here.parent / 'replace_rule_oracle' / name
    return here / name


def harness_source_hashes(selected=False):
    keys = SELECTED_SOURCE_KEYS if selected else HARNESS_SOURCE_KEYS
    return {name: sha256(_source_path(name)) for name in keys}


def _admit_source_hashes(sources, label, current_only=False, selected=False):
    if not isinstance(sources, dict):
        raise ValueError(label + ' source map must be an object')
    keys = set(sources)
    if selected:
        if keys != set(SELECTED_SOURCE_KEYS):
            raise ValueError(label + ' source key set differs')
    elif keys != set(HARNESS_SOURCE_KEYS) and (
            current_only or keys != set(HISTORICAL_SOURCE_KEYS)):
        raise ValueError(label + ' source key set differs')
    for name, value in sources.items():
        if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value):
            raise ValueError(label + ' source hash is malformed: ' + name)


def _admit_selected_shape(fixture, label):
    if not isinstance(fixture, dict):
        raise ValueError(label + ' must be an object')
    if fixture.get('fixtureId') != FIELDS_02:
        raise ValueError(label + ' is not FIELDS-02')
    if _require_int(fixture.get('corpusVersion'), label + '.corpusVersion') != 1:
        raise ValueError(label + '.corpusVersion must be integer 1')
    if fixture.get('baselineCommit') == SELECTED_BASELINE and fixture.get('target') != SELECTED_TARGET:
        raise ValueError(label + ' selected reference target differs')
    target = fixture.get('target')
    if (fixture.get('baselineCommit') != SELECTED_BASELINE and isinstance(target, dict)
            and (target.get('package') == SELECTED_TARGET['package']
                 or target.get('apkSha256') == SELECTED_TARGET['apkSha256'])):
        raise ValueError(label + ' selected target requires its fixed baseline')
    if fixture.get('baselineCommit') == '14dd24945b2914ce2708b8abaa4ee67ceef892af' and fixture.get('target') != {
            'package': TARGET_PACKAGE, 'apkSha256': BASELINE_APK, 'deviceFingerprint': FINGERPRINT}:
        raise ValueError(label + ' historical reference target differs')
    cases = fixture.get('cases')
    if not isinstance(cases, list) or not cases:
        raise ValueError(label + '.cases must be a nonempty list')
    ids = set()
    for index, case in enumerate(cases):
        case_label = f'{label}.cases[{index}]'
        if not isinstance(case, dict):
            raise ValueError(case_label + ' must be an object')
        case_id = _required_string(case, 'id', case_label)
        if not case_id or case_id in ids:
            raise ValueError(case_label + '.id must be nonempty and unique')
        ids.add(case_id)
        _required_string(case, 'keyword', case_label)
        if not isinstance(case.get('source'), dict):
            raise ValueError(case_label + '.source must be an object')
        terminal = case['terminal'] if 'terminal' in case else 'four-stage'
        if not isinstance(terminal, str) or terminal not in ('four-stage', 'search-empty'):
            raise ValueError(case_label + '.terminal is unsupported')
    return fixture


def _inspect_selected_apk(apk_path, fixture_bytes, fixture, expected_sources):
    """Read the actual selected APK zip and bind its corpus/provenance bytes."""
    apk_bytes = Path(apk_path).read_bytes()
    apk_sha = sha256_bytes(apk_bytes)
    fixture_sha = sha256_bytes(fixture_bytes)
    fixture_sha_lf = sha256_bytes(lf_bytes(fixture_bytes))
    if fixture.get('baselineCommit') == SELECTED_BASELINE and (
            fixture_sha not in SELECTED_CORPUS_SHA256S
            or fixture_sha_lf != fixture_sha):
        raise ValueError('selected corpus raw bytes differ')
    if fixture.get('fixtureId') != FIELDS_02:
        raise ValueError('the selected fixture is not FIELDS-02')
    if not isinstance(fixture.get('cases'), list) or not fixture['cases']:
        raise ValueError('the selected fixture has no cases')
    if _require_int(fixture.get('corpusVersion'), 'fixture.corpusVersion') != 1:
        raise ValueError('the selected fixture version is not integer 1')
    with zipfile.ZipFile(Path(apk_path)) as archive:
        names = archive.namelist()
        for required in ('assets/field-fixtures.json', 'assets/field-provenance.json'):
            if names.count(required) != 1:
                raise ValueError('selected APK must contain exactly one ' + required)
        asset_bytes = archive.read('assets/field-fixtures.json')
        provenance_bytes = archive.read('assets/field-provenance.json')
    if asset_bytes != fixture_bytes:
        raise ValueError('selected APK embedded corpus differs from the selected fixture')
    parsed_fixture = json.loads(asset_bytes.decode('utf-8'))
    _admit_selected_shape(parsed_fixture, 'embedded fixture')
    _admit_selected_shape(fixture, 'selected fixture')
    if parsed_fixture != fixture:
        raise ValueError('selected APK parsed corpus differs from the selected fixture')
    if sha256_bytes(asset_bytes) != fixture_sha or sha256_bytes(lf_bytes(asset_bytes)) != fixture_sha_lf:
        raise ValueError('selected APK embedded corpus digests differ')
    provenance = json.loads(provenance_bytes.decode('utf-8'))
    if not isinstance(provenance, dict):
        raise ValueError('embedded provenance is not an object')
    if _require_int(_required(provenance, 'schemaVersion', 'provenance'), 'provenance.schemaVersion') != 1:
        raise ValueError('unsupported provenance schemaVersion')
    if provenance.get('fixtureId') != FIELDS_02:
        raise ValueError('embedded provenance fixtureId differs')
    corpus = _required_map(provenance, 'corpus', 'provenance')
    if corpus.get('asset') != 'field-fixtures.json':
        raise ValueError('embedded provenance corpus asset differs')
    if corpus.get('fixtureId') != FIELDS_02:
        raise ValueError('embedded provenance corpus family differs')
    if _require_int(corpus.get('corpusVersion'), 'provenance.corpus.corpusVersion') != 1:
        raise ValueError('embedded provenance corpus version differs')
    if _require_int(corpus.get('bytes'), 'provenance.corpus.bytes') != len(fixture_bytes):
        raise ValueError('embedded provenance byte count differs')
    if corpus.get('sha256') != fixture_sha or corpus.get('sha256Lf') != fixture_sha_lf:
        raise ValueError('embedded provenance corpus digests differ')
    sources = _required_map(provenance, 'sources', 'provenance')
    _admit_source_hashes(sources, 'embedded provenance',
                         selected=fixture.get('baselineCommit') == SELECTED_BASELINE)
    if expected_sources is not None:
        if set(expected_sources) != set(sources):
            raise ValueError('embedded provenance source key set differs')
        for name, expected in expected_sources.items():
            if sources.get(name) != expected:
                raise ValueError('embedded provenance source hash differs: ' + name)
    return {
        'apkSha256': apk_sha,
        'selectedAssetSha256': fixture_sha,
        'selectedAssetSha256Lf': fixture_sha_lf,
        'selectedAssetBytes': len(fixture_bytes),
        'provenanceSha256': sha256_bytes(provenance_bytes),
        'provenance': provenance,
    }


def inspect_selected_apk(apk_path, fixture_path, fixture, expected_sources):
    return _inspect_selected_apk(
        apk_path, Path(fixture_path).read_bytes(), fixture, expected_sources)


def _check_selected_manifest(text):
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
            raise ValueError('selected manifest element is malformed')
        attr = re.match(r'^( *)A: ([^\s=(]+)', line)
        if not attr:
            continue
        if not stack or len(attr.group(1)) <= stack[-1]['depth']:
            raise ValueError('selected manifest attribute is malformed')
        key = attr.group(2)
        if key not in ('package', 'android:name', 'android:targetPackage'):
            continue
        if not ((not stack[-1]['parent'] and key == 'package') or
                (stack[-1]['name'] == 'instrumentation' and key != 'package')):
            continue
        match = re.fullmatch(r' *A: [^\s=(]+(?:\((0x[0-9a-fA-F]+)\))?="([^"]*)"(?: \(Raw: "([^"]*)"\))?', line)
        expected_id = {'package': None, 'android:name': '0x01010003', 'android:targetPackage': '0x01010021'}[key]
        if not match or match.group(1) != expected_id or (match.group(3) is not None and match.group(2) != match.group(3)):
            raise ValueError('selected manifest identity is malformed')
        stack[-1]['attrs'].setdefault(key, []).append(match.group(2))
    if (len(roots) != 1 or roots[0]['name'] != 'manifest' or len(entries) != 1
            or entries[0]['parent'] is not roots[0]
            or roots[0]['attrs'].get('package') != [PACKAGE]
            or entries[0]['attrs'].get('android:name') != [PACKAGE + '.FieldOracle']
            or entries[0]['attrs'].get('android:targetPackage') != [SELECTED_TARGET['package']]):
        raise ValueError('selected manifest package, entry or target differs')


def selected_preflight(apk, target_apk, fixture_path, source, sdk, java, evidence=None):
    """Inspect the selected artifact without contacting any device."""
    if not target_apk.is_file() or sha256(target_apk) != SELECTED_TARGET['apkSha256']:
        raise ValueError('selected target APK is missing or differs')
    data = fixture_path.read_bytes()
    if sha256_bytes(data) not in SELECTED_CORPUS_SHA256S or lf_bytes(data) != data:
        raise ValueError('selected corpus raw bytes differ')
    fixture = json.loads(data)
    _admit_selected_shape(fixture, 'selected fixture')
    if fixture.get('baselineCommit') != SELECTED_BASELINE:
        raise ValueError('selected baseline differs')
    receipts = []
    def run(name, command, stderr=False):
        command = [str(value) for value in command]
        try:
            result = subprocess.run(command, capture_output=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            stdout = error.stdout or b''
            partial_stderr = error.stderr or b''
            if isinstance(stdout, str):
                stdout = stdout.encode('utf-8')
            if isinstance(partial_stderr, str):
                partial_stderr = partial_stderr.encode('utf-8')
            timeout_receipt = {'name': name, 'command': command, 'status': 'timeout',
                               'timeoutSeconds': error.timeout, 'exitCode': None,
                               'stdoutSha256': sha256_bytes(stdout),
                               'stderrSha256': sha256_bytes(partial_stderr)}
            receipts.append(timeout_receipt)
            error.fields_preflight_timeout = (timeout_receipt, stdout, partial_stderr)
            if evidence is not None:
                with (evidence / ('preflight-' + name + '.stdout.log')).open('xb') as stream:
                    stream.write(stdout)
                with (evidence / ('preflight-' + name + '.stderr.log')).open('xb') as stream:
                    stream.write(partial_stderr)
                (evidence / 'preflight-commands.json').write_text(
                    json.dumps(receipts, indent=2) + '\n', encoding='utf-8')
            raise
        receipts.append({'name': name, 'command': command, 'exitCode': result.returncode,
                         'stdoutSha256': sha256_bytes(result.stdout),
                         'stderrSha256': sha256_bytes(result.stderr)})
        if evidence is not None:
            (evidence / ('preflight-' + name + '.stdout.log')).write_bytes(result.stdout)
            (evidence / ('preflight-' + name + '.stderr.log')).write_bytes(result.stderr)
            (evidence / 'preflight-commands.json').write_text(
                json.dumps(receipts, indent=2) + '\n', encoding='utf-8')
        if result.returncode:
            error = ValueError(name + ' command failed: ' + result.stderr.decode(errors='replace'))
            error.fields_preflight_failure = (receipts[-1], result.stdout, result.stderr)
            raise error
        return (result.stderr if stderr else result.stdout).decode(errors='strict')
    if 'Temurin-17.0.20+8' not in run('java-version', [java / 'bin' / 'java.exe', '-version'], stderr=True):
        raise ValueError('selected JDK version differs')
    if run('javac-version', [java / 'bin' / 'javac.exe', '-version']).strip() != 'javac 17.0.20':
        raise ValueError('selected javac version differs')
    if not (sdk / 'platforms' / 'android-35' / 'android.jar').is_file():
        raise ValueError('selected android-35 SDK platform is missing')
    if run('source-head', ['git', '-C', source, 'rev-parse', 'HEAD']).strip() != SELECTED_BASELINE:
        raise ValueError('selected source HEAD differs')
    if run('source-tree', ['git', '-C', source, 'rev-parse', 'HEAD^{tree}']).strip() != '0f69dc7004012a969551ce271dc4e11051637d32':
        raise ValueError('selected source tree differs')
    if run('source-status', ['git', '-C', source, 'status', '--porcelain=v1']).strip():
        raise ValueError('selected source worktree is dirty')
    paths = [row['path'] for row in fixture['frozenSources']]
    blobs = run('source-blobs', ['git', '-C', source, 'hash-object', *paths]).split()
    if blobs != [row['sha1'] for row in fixture['frozenSources']]:
        raise ValueError('selected source blob differs')
    artifact = inspect_selected_apk(apk, fixture_path, fixture, harness_source_hashes(selected=True))
    tools = sdk / 'build-tools' / '35.0.1'
    manifest = run('manifest', [tools / 'aapt.exe', 'dump', 'xmltree', apk, 'AndroidManifest.xml'])
    _check_selected_manifest(manifest)
    for name, signed_apk in [('harness-signature', apk), ('target-signature', target_apk)]:
        signature = run(name, [java / 'bin' / 'java.exe', '-jar', tools / 'lib' / 'apksigner.jar',
                               'verify', '--print-certs', signed_apk])
        signers = re.findall(r'Signer #(\d+) certificate SHA-256 digest: ([0-9a-f]{64})', signature, re.I)
        if [(n, h.lower()) for n, h in signers] != [('1', SELECTED_SIGNER)]:
            raise ValueError(name + ' signer differs')
    with zipfile.ZipFile(target_apk) as archive:
        if archive.namelist().count('classes19.dex') != 1:
            raise ValueError('selected reference DEX inventory differs')
        reference_dex = archive.read('classes19.dex')
    with tempfile.TemporaryDirectory(prefix='fields-reference-dex-') as temporary:
        dex_path = Path(temporary) / 'classes19.dex'
        reference_dex_path = str(dex_path)
        dex_path.write_bytes(reference_dex)
        reference_dump = run('reference-dex', [tools / 'dexdump.exe', dex_path])
    classes = re.split(r'(?=Class #\d+\s+-)', reference_dump)
    webbooks = [part for part in classes if "Class descriptor  : 'Lio/legado/app/model/webBook/WebBook;'" in part]
    if len(webbooks) != 1:
        raise ValueError('selected WebBook DEX definition differs')
    expected_methods = {
        'searchBookAwait': '(Lio/legado/app/data/entities/BookSource;Ljava/lang/String;Ljava/lang/Integer;Lkotlin/jvm/functions/Function3;Lkotlin/jvm/functions/Function1;Lkotlin/coroutines/Continuation;)Ljava/lang/Object;',
        'getBookInfoAwait': '(Lio/legado/app/data/entities/BookSource;Lio/legado/app/data/entities/Book;ZLkotlin/coroutines/Continuation;)Ljava/lang/Object;',
        'getChapterListAwait-yxL6bBk': '(Lio/legado/app/data/entities/BookSource;Lio/legado/app/data/entities/Book;ZZLkotlin/coroutines/Continuation;)Ljava/lang/Object;',
        'getContentAwait': '(Lio/legado/app/data/entities/BookSource;Lio/legado/app/data/entities/Book;Lio/legado/app/data/entities/BookChapter;Ljava/lang/String;ZLkotlin/coroutines/Continuation;)Ljava/lang/Object;',
    }
    for method, signature in expected_methods.items():
        pattern = r"name\s+: '" + re.escape(method) + r"'\s+type\s+: '" + re.escape(signature) + r"'\s+access\s+: 0x0011 \(PUBLIC FINAL\)"
        if len(re.findall(pattern, webbooks[0])) != 1:
            raise ValueError('selected native ABI differs: ' + method)
    with zipfile.ZipFile(apk) as archive:
        names = archive.namelist()
        if names.count('classes.dex') != 1 or [n for n in names if re.fullmatch(r'classes\d*\.dex', n)] != ['classes.dex']:
            raise ValueError('selected APK DEX inventory differs')
        dex = archive.read('classes.dex')
    with tempfile.TemporaryDirectory(prefix='fields-dex-') as temporary:
        dex_path = Path(temporary) / 'classes.dex'
        harness_dex_path = str(dex_path)
        dex_path.write_bytes(dex)
        dump = run('dex', [tools / 'dexdump.exe', dex_path])
    for name in ('Lio/liber/oracle/fields/FieldOracle;',
                 'Lio/liber/oracle/nested/SelectedFieldHostBridge;',
                 'Lio/liber/oracle/nested/GuardedReaderApplication;'):
        if dump.count("Class descriptor  : '" + name + "'") != 1:
            raise ValueError('selected DEX entry differs: ' + name)
    return {'artifact': artifact, 'targetApkSha256': sha256(target_apk),
            'dexSha256': sha256_bytes(dex), 'referenceDexSha256': sha256_bytes(reference_dex),
            'inputs': {'harnessApk': str(apk), 'targetApk': str(target_apk), 'source': str(source),
                       'androidSdk': str(sdk), 'javaHome': str(java),
                       'referenceDex': reference_dex_path, 'harnessDex': harness_dex_path},
            'referenceSources': {
                path: {'blobSha1': blob, 'worktreeSha256': sha256(source / path)}
                for path, blob in zip(paths, blobs)}, 'commands': receipts}


def _retain_preflight_failure(output, error):
    timed_out = isinstance(error, subprocess.TimeoutExpired)
    receipt, stdout, stderr = (error.fields_preflight_timeout if timed_out else error.fields_preflight_failure)
    kind = 'timeout' if timed_out else 'nonzero'
    directory = Path(tempfile.mkdtemp(prefix='preflight-' + kind + '-', dir=output))
    for name, data in [('stdout', stdout), ('stderr', stderr)]:
        with (directory / ('preflight-' + receipt['name'] + '.' + name + '.log')).open('xb') as stream:
            stream.write(data)
    with (directory / 'preflight-commands.json').open('x', encoding='utf-8') as stream:
        json.dump([receipt], stream, indent=2)
        stream.write('\n')
    print('preflight ' + kind + ' evidence: ' + str(directory), file=sys.stderr)


def _strict_json(data):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('duplicate JSON key: ' + key)
            result[key] = value
        return result
    return json.loads(data, object_pairs_hook=unique)


def _write_finalize_failure(output, error, *, preserve_existing=False):
    receipt = {
        'status': 'failed',
        'kind': 'fields-02-finalize-failure',
        'error': error,
    }
    data = json.dumps(receipt, ensure_ascii=False, indent=2) + '\n'
    path = output / 'finalize-failure.json'
    if not preserve_existing:
        path.write_text(data, encoding='utf-8')
        return None
    try:
        stream = path.open('x', encoding='utf-8')
    except FileExistsError:
        path = output / ('finalize-failure-' + str(uuid.uuid4()) + '.json')
        stream = path.open('x', encoding='utf-8')
    with stream:
        stream.write(data)
    print('finalize failure receipt: ' + str(path), file=sys.stderr)
    return path


def _hash_lines(output):
    """`sha256sum` output as {relative path: digest}."""
    hashes = {}
    for line in output.decode(errors='replace').splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            path = parts[1].strip()
            if path == './':
                path = '.'
            elif path.startswith('./'):
                path = path[2:]
            hashes[path] = parts[0]
    return hashes


def _snapshot_records(output, label):
    """Decode the producer's hex-framed typed private inventory."""
    if not isinstance(output, (bytes, bytearray)):
        raise ValueError(label + ' private inventory must be bytes')
    records = {}
    for line_number, line in enumerate(bytes(output).decode('utf-8').splitlines(), 1):
        parts = line.split(chr(9), 2)
        if len(parts) != 3:
            raise ValueError(f'{label} private inventory line {line_number} is not typed')
        kind, digest, encoded = parts
        if kind not in ('F', 'D', 'U'):
            raise ValueError(f'{label} private inventory line {line_number} has unknown kind')
        if not re.fullmatch(r'(?:[0-9a-fA-F]{2})+', encoded):
            raise ValueError(f'{label} private inventory path {line_number} is not hex-framed')
        try:
            raw_path = bytes.fromhex(encoded).decode('utf-8')
        except (ValueError, UnicodeDecodeError) as error:
            raise ValueError(f'{label} private inventory path {line_number} is not UTF-8 hex') from error
        if (raw_path == '.'):
            path = '.'
        elif raw_path.startswith('./'):
            path = raw_path[2:]
        else:
            raise ValueError(f'{label} private inventory path is not rooted at ./')
        if not path or chr(0) in path or chr(9) in path or chr(10) in path or chr(13) in path:
            raise ValueError(f'{label} private inventory path is malformed')
        components = path.split('/') if path != '.' else []
        if any(component in ('', '.', '..') for component in components):
            raise ValueError(f'{label} private inventory path is not canonical')
        if path in records:
            raise ValueError(f'{label} private inventory repeats {path}')
        if kind == 'U':
            raise ValueError(f'{label} private inventory contains an unsupported node {path}')
        if kind == 'F':
            if not re.fullmatch(r'[0-9a-f]{64}', digest):
                raise ValueError(f'{label} private inventory digest is malformed for {path}')
            records[path] = ('F', digest)
        else:
            if digest != '-':
                raise ValueError(f'{label} private directory digest is not empty for {path}')
            records[path] = ('D', None)
    return records


def _fields_snapshot_script(root):
    """Emit hex-framed typed records with checked existing byte primitives."""
    # Producer/od status uses fd3; encoded hex uses fd4. Both are actual
    # channels; no temporary file or non-POSIX pipe option is involved.
    encoder = 'encode_path() {\n    encoded=$(\n        exec 4>&1\n        statuses=$(\n            exec 3>&1\n            { printf "%s\\n" "$1"; status=$?; command printf "p:%s\\n" "$status" >&3; } |\n            { od -An -v -tx1; status=$?; command printf "o:%s\\n" "$status" >&3; } |\n            tr -d "[:space:]" >&4\n        ) || exit __CODE__\n        case "$statuses" in\n            "p:0\no:0") ;;\n            "o:0\np:0") ;;\n            *) exit __CODE__ ;;\n        esac\n    ) || return __CODE__\n    case "$encoded" in\n        *0a) encoded=${encoded%0a} ;;\n        *) return __EMPTY__ ;;\n    esac\n    test -n "$encoded" || return __EMPTY__\n    printf "%s" "$encoded" || return __CODE__\n}'
    def encode(code, empty):
        return encoder.replace('__CODE__', str(code)).replace('__EMPTY__', str(empty)) + '; '
    return (
        'set -e; cd ' + shlex.quote(root) + '; '
        r'''find . -type f -exec sh -c 'for f do h=$(sha256sum "$f") || exit 20; '''
        + encode(21, 24) +
        r'''hex=$(encode_path "$f") || exit 21; printf "F\t%s\t%s\n" "${h%% *}" "$hex" || exit 23; done' sh {} +; '''
        r'''find . -type d -exec sh -c 'for f do ''' + encode(31, 34) +
        r'''hex=$(encode_path "$f") || exit 31; printf "D\t-\t%s\n" "$hex" || exit 33; done' sh {} +; '''
        r'''find . ! -type f ! -type d -exec sh -c 'for f do ''' + encode(41, 44) +
        r'''hex=$(encode_path "$f") || exit 41; printf "U\t-\t%s\n" "$hex" || exit 43; done' sh {} +'''
    )


def _measured_pids(result, label):
    if result.returncode == 0:
        if result.stderr.strip():
            raise ValueError(label + ' returned success with an access error')
        pids = result.stdout.decode(errors='replace').split()
        if not pids:
            raise ValueError(label + ' returned empty output without proof of absence')
        return pids
    if (result.returncode == 1 and not result.stdout.strip()
            and not result.stderr.strip()):
        return []
    raise ValueError(label + ' failed or carried an unreadable/contradictory receipt')


def _package_is_present(result, package, label):
    """Resolve an exact package record from a reliable filtered inventory.

    An absent package is an empty successful `pm list packages <package>` receipt.
    A nonzero exit, stderr, malformed line or contradictory receipt is unknown and
    must be refused rather than interpreted as absence.
    """
    if result.returncode:
        diagnostic = result.stderr.decode(errors='replace').strip()
        raise ValueError(f'{label} query failed (exit {result.returncode}): '
                         + (diagnostic or 'no diagnostic'))
    if result.stderr.strip():
        raise ValueError(f'{label} query reported an error: '
                         + result.stderr.decode(errors='replace').strip())
    present = False
    for line in result.stdout.decode(errors='replace').splitlines():
        if not line:
            continue
        if not line.startswith('package:') or not line[len('package:'):]:
            raise ValueError(f'{label} query returned a malformed package record')
        if line == 'package:' + package:
            present = True
    return present


def _safe_owner_names(names, label):
    if not isinstance(names, list) or not names:
        raise ValueError(label + ' must be a nonempty list')
    if len(set(names)) != len(names):
        raise ValueError(label + ' contains duplicates')
    if OWNED_PREFERENCE_PREFIX + 'probe' not in names:
        raise ValueError(label + ' omits the registered probe')
    for name in names:
        if (not isinstance(name, str)
                or not re.fullmatch(r'liber_fields_02_[A-Za-z0-9][A-Za-z0-9_.:+-]*', name)
                or '/' in name or name in ('liber_fields_02_.', 'liber_fields_02_..')):
            raise ValueError(label + ' contains an unsafe preference name')
    return list(names)


def _admit_owner_inventories(owner_prefs, reported, receipt_prefs=None):
    owner = _safe_owner_names(owner_prefs, 'owner.preferences')
    report = _safe_owner_names(reported, 'cleanup.ownedPreferences')
    if owner != report:
        raise ValueError('the owner and report preference inventories differ')
    if receipt_prefs is not None:
        receipt = _safe_owner_names(receipt_prefs, 'scratchCleanup.reportedOwnedPreferences')
        if owner != receipt:
            raise ValueError('the external cleanup inventory differs from the owner')
    return owner


def finalize(output, fixture, manifest, report, before, after, asset=None,
             scratch_cleanup=None, fixture_bytes=None, report_bytes=None,
             original_apk=None):
    """Validate one pulled report and its privacy snapshot; write the golden.

    Re-runnable over an evidence directory that already holds
    `field-oracle.json`, `private-before.log` and `private-after.log`, so a
    capture whose device step was interrupted can be finalized from the raw
    report the device actually produced instead of re-running the instrument.
    """
    if fixture.get('fixtureId') not in (FIELDS_01, FIELDS_02):
        raise ValueError('unsupported FIELDS fixture family')
    if fixture.get('fixtureId') == FIELDS_02:
        _admit_selected_shape(fixture, 'fixture')
        return _finalize_fields_02(output, fixture, manifest, report, before, after,
                                   asset=asset, scratch_cleanup=scratch_cleanup,
                                   fixture_bytes=fixture_bytes,
                                   report_bytes=report_bytes,
                                   original_apk=original_apk)
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
    manifest['harnessSources'] = harness_source_hashes()
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



def _required(mapping, key, label):
    if key not in mapping:
        raise ValueError(f'{label}.{key} is missing')
    return mapping[key]


def _required_map(mapping, key, label):
    value = _required(mapping, key, label)
    if not isinstance(value, dict):
        raise ValueError(f'{label}.{key} must be an object')
    return value


def _required_list(mapping, key, label):
    value = _required(mapping, key, label)
    if not isinstance(value, list):
        raise ValueError(f'{label}.{key} must be an array')
    return value


def _required_string(mapping, key, label):
    value = _required(mapping, key, label)
    if not isinstance(value, str):
        raise ValueError(f'{label}.{key} must be a string')
    return value


def _nullable_string(mapping, key, label):
    value = _required(mapping, key, label)
    if value is not None and not isinstance(value, str):
        raise ValueError(f'{label}.{key} must be a string or null')
    return value


def _required_bool(mapping, key, label):
    value = _required(mapping, key, label)
    if not isinstance(value, bool):
        raise ValueError(f'{label}.{key} must be boolean')
    return value


def _request_identity(request, label):
    if not isinstance(request, dict):
        raise ValueError(f'{label} must be an object')
    method = _required_string(request, 'method', label)
    path = _required_string(request, 'path', label)
    query = request.get('query', {})
    if not isinstance(query, dict) or any(
            not isinstance(key, str) or not isinstance(value, str)
            for key, value in query.items()):
        raise ValueError(f'{label}.query must be a string map')
    return method, path, query


def _admit_native_request(request, label):
    _request_identity(request, label)
    _required_string(request, 'rawQuery', label)
    receipt = _required_map(request, 'receipt', label)
    if _required_string(receipt, 'terminal', label + '.receipt') != 'responded':
        raise ValueError(label + ' receipt did not complete')
    _require_int(_required(receipt, 'status', label + '.receipt'),
                 label + '.receipt.status')
    if _required_string(receipt, 'send', label + '.receipt') != 'completed':
        raise ValueError(label + '.receipt.send must record completion')
    _nullable_string(receipt, 'responseId', label + '.receipt')
    _nullable_string(receipt, 'redirect', label + '.receipt')
    if 'error' in receipt and not isinstance(receipt['error'], str):
        raise ValueError(label + '.receipt.error must be a string')


def _admit_native_case(case, declared, label):
    if not isinstance(case, dict):
        raise ValueError(label + ' must be an object')
    case_id = _required_string(case, 'id', label)
    if case_id != declared['id']:
        raise ValueError(label + '.id differs from the declaration')
    terminal = declared.get('terminal', 'four-stage')
    if _required_string(case, 'terminal', label) != terminal:
        raise ValueError(label + '.terminal differs from the declaration')
    search = _required_map(case, 'search', label)
    results = _required_list(search, 'results', label + '.search')
    for index, result_value in enumerate(results):
        item_label = f'{label}.search.results[{index}]'
        if not isinstance(result_value, dict):
            raise ValueError(item_label + ' must be an object')
        for field in ['name', 'author', 'bookUrl']:
            _required_string(result_value, field, item_label)
        if 'infoHtml' in result_value and not isinstance(result_value['infoHtml'], bool):
            raise ValueError(item_label + '.infoHtml must be boolean when present')
    if terminal == 'search-empty':
        if results:
            raise ValueError(label + ' empty terminal has search results')
        for field in ['bookInfo', 'tableOfContents', 'chapter']:
            if field not in case or case[field] is not None:
                raise ValueError(f'{label} empty terminal must carry null {field}')
    else:
        if not results:
            raise ValueError(label + ' positive case has no search result')
        info = _required_map(case, 'bookInfo', label)
        for field in ['name', 'author', 'bookUrl', 'tocUrl']:
            _required_string(info, field, label + '.bookInfo')
        toc = _required_map(case, 'tableOfContents', label)
        _required_string(toc, 'tocUrl', label + '.tableOfContents')
        chapters = _required_list(toc, 'chapters', label + '.tableOfContents')
        if not chapters:
            raise ValueError(label + ' positive case has no chapter observations')
        for index, chapter in enumerate(chapters):
            chapter_label = f'{label}.chapters[{index}]'
            if not isinstance(chapter, dict):
                raise ValueError(chapter_label + ' must be an object')
            title = _required_string(chapter, 'title', chapter_label)
            if not title:
                raise ValueError(chapter_label + '.title must not be empty')
            for field in ['url', 'absoluteUrl']:
                _required_string(chapter, field, chapter_label)
            _nullable_string(chapter, 'tag', chapter_label)
            for field in ['isVolume', 'isVip', 'isPay']:
                _required_bool(chapter, field, chapter_label)
        chapter = _required_map(case, 'chapter', label)
        _required_string(chapter, 'title', label + '.chapter')
        _required_string(chapter, 'text', label + '.chapter')
    probes = _required_map(case, 'sourceProbes', label)
    for field in ['vipProbe', 'payProbe']:
        _nullable_string(probes, field, label + '.sourceProbes')
    requests = _required_list(case, 'requests', label)
    if not requests:
        raise ValueError(label + ' has no per-case request slice')
    for index, request in enumerate(requests):
        _admit_native_request(request, f'{label}.requests[{index}]')


def _admit_provenance(manifest, fixture_bytes, fixture, isolation):
    artifact = _required_map(manifest, 'artifact', 'manifest')
    if artifact.get('apkSha256') != _required(manifest, 'harnessApkSha256', 'manifest'):
        raise ValueError('artifact APK hash differs from the manifest harness APK')
    if artifact.get('apkSha256') != isolation.get('harnessApkSha256'):
        raise ValueError('artifact APK hash differs from the report harness APK')
    raw_sha = sha256_bytes(fixture_bytes)
    lf_sha = sha256_bytes(lf_bytes(fixture_bytes))
    if artifact.get('selectedAssetSha256') != raw_sha:
        raise ValueError('artifact selected asset raw hash differs')
    if artifact.get('selectedAssetSha256Lf') != lf_sha:
        raise ValueError('artifact selected asset LF hash differs')
    if _require_int(artifact.get('selectedAssetBytes'), 'artifact.selectedAssetBytes') != len(fixture_bytes):
        raise ValueError('artifact selected asset byte count differs')
    provenance_sha = artifact.get('provenanceSha256')
    if not isinstance(provenance_sha, str) or not re.fullmatch(r'[0-9a-f]{64}', provenance_sha):
        raise ValueError('artifact provenance hash must be a sha256 digest')
    provenance = _required_map(artifact, 'provenance', 'artifact')
    if _require_int(_required(provenance, 'schemaVersion', 'artifact.provenance'), 'artifact.provenance.schemaVersion') != 1:
        raise ValueError('artifact provenance schema version differs')
    if provenance.get('fixtureId') != FIELDS_02:
        raise ValueError('artifact provenance fixture id differs')
    corpus = _required_map(provenance, 'corpus', 'artifact.provenance')
    if corpus.get('asset') != 'field-fixtures.json' or corpus.get('fixtureId') != FIELDS_02:
        raise ValueError('artifact provenance corpus identity differs')
    if _require_int(corpus.get('corpusVersion'), 'artifact.provenance.corpus.corpusVersion') != 1:
        raise ValueError('artifact provenance corpus version differs')
    if _require_int(corpus.get('bytes'), 'artifact.provenance.corpus.bytes') != len(fixture_bytes):
        raise ValueError('artifact provenance byte count differs')
    if corpus.get('sha256') != raw_sha or corpus.get('sha256Lf') != lf_sha:
        raise ValueError('artifact provenance corpus digest differs')
    sources = _required_map(provenance, 'sources', 'artifact.provenance')
    _admit_source_hashes(sources, 'artifact provenance',
                         selected=fixture.get('baselineCommit') == SELECTED_BASELINE)
    manifest_sources = _required_map(manifest, 'harnessSources', 'manifest')
    if manifest_sources != sources:
        raise ValueError('artifact provenance sources differ from the manifest sources')
    expected_root = _required_string(manifest, 'targetPrivateRoot', 'manifest')
    if isolation.get('scratchRoot') != expected_root + '/cache/liber-fields-02':
        raise ValueError('scratch root is not the measured target-private cache relation')
    if isolation.get('preferencesPrefix') != OWNED_PREFERENCE_PREFIX:
        raise ValueError('preference namespace differs from the owned namespace')


def _canonical_raw_query(request):
    query = request.get('query')
    if query is None:
        return ''
    if not isinstance(query, dict):
        raise ValueError('expected request query must be an object')
    if 'rawQuery' in request:
        return _required_string(request, 'rawQuery', 'expected request')
    return '&'.join(
        urllib.parse.quote(str(key), safe='') + '=' +
        urllib.parse.quote(str(value), safe='')
        for key, value in query.items()
    )


def _admit_native_causality(cases, requests, trace, fixture):
    flattened = []
    for case in cases:
        slices = case.get('requests')
        if not isinstance(slices, list) or not slices:
            raise ValueError('case request slice is missing or empty')
        flattened.extend(slices)
    if flattened != requests:
        raise ValueError('case request slices do not reconstruct the global sequence')


def _admit_native_operations(cases, requests, trace, fixture):
    request_cursor = 0
    trace_cursor = 0
    for case in cases:
        label = 'report.cases[' + str(case.get('id')) + ']'
        terminal = case.get('terminal')
        expected = ['search'] if terminal == 'search-empty' else [
            'search', 'bookInfo', 'tableOfContents', 'content']
        operations = _required_list(case, 'operations', label)
        if len(operations) != len(expected):
            raise ValueError(label + ' operation set differs for its terminal')
        previous_request = -1
        previous_trace = -1
        first_request = -1
        first_trace = -1
        last_request = -1
        last_trace = -1
        for index, operation in enumerate(operations):
            op_label = label + '.operations[' + str(index) + ']'
            if not isinstance(operation, dict):
                raise ValueError(op_label + ' must be an object')
            if _required_string(operation, 'name', op_label) != expected[index]:
                raise ValueError(op_label + ' name is not the declared operation')
            if _required_string(operation, 'outcome', op_label) != 'completed':
                raise ValueError(op_label + ' did not complete')
            request_start = _require_int(
                _required(operation, 'requestStart', op_label), op_label + '.requestStart')
            request_end = _require_int(
                _required(operation, 'requestEnd', op_label), op_label + '.requestEnd')
            trace_start = _require_int(
                _required(operation, 'traceStart', op_label), op_label + '.traceStart')
            trace_end = _require_int(
                _required(operation, 'traceEnd', op_label), op_label + '.traceEnd')
            if request_start < 0 or request_end < request_start or request_end > len(requests):
                raise ValueError(op_label + ' request span is outside the request sequence')
            if trace_start < 0 or trace_end < trace_start or trace_end > len(trace):
                raise ValueError(op_label + ' trace span is outside the stage trace')
            if request_end - request_start != trace_end - trace_start:
                raise ValueError(op_label + ' request/trace span count differs')
            for trace_index in range(trace_start, trace_end):
                actual_stage = _required_string(
                    trace[trace_index], 'stage', f'report.stageTrace[{trace_index}]')
                if actual_stage != expected[index]:
                    raise ValueError(op_label + ' owns an unrelated trace stage')
            for offset, request_index in enumerate(range(request_start, request_end)):
                request = requests[request_index]
                actual_stage = _required_string(
                    request, 'stage', f'report.requests[{request_index}]')
                if actual_stage != expected[index]:
                    raise ValueError(op_label + ' owns an unrelated request stage')
                trace_entry = trace[trace_start + offset]
                traced = _required_string(
                    trace_entry, 'path', f'report.stageTrace[{trace_start + offset}]')
                path = _required_string(request, 'path', f'report.requests[{request_index}]')
                raw = _required_string(request, 'rawQuery', f'report.requests[{request_index}]')
                target = fixture['origin'] + path + ('' if not raw else '?' + raw)
                if traced != target:
                    raise ValueError(op_label + ' owns an unrelated request target')
            if previous_request >= 0 and (request_start != previous_request or trace_start != previous_trace):
                raise ValueError(op_label + ' spans are not contiguous')
            if first_request < 0:
                first_request = request_start
                first_trace = trace_start
                if first_request != request_cursor or first_trace != trace_cursor:
                    raise ValueError(op_label + ' spans skip or overlap a case')
            previous_request = request_end
            previous_trace = trace_end
            last_request = request_end
            last_trace = trace_end
        slices = case.get('requests')
        if not isinstance(slices, list):
            raise ValueError(label + ' request slice is missing')
        if slices != requests[first_request:last_request]:
            raise ValueError(label + ' request slice is not its operation span')
        if last_trace < first_trace:
            raise ValueError(label + ' trace span is invalid')
        request_cursor = last_request
        trace_cursor = last_trace
    if request_cursor != len(requests) or trace_cursor != len(trace):
        raise ValueError('case operation spans do not cover the global sequences')


def _admit_selected_runtime(report, fixture):
    def require(condition, detail):
        if not condition:
            raise ValueError('selected runtime ' + detail)
    startup = report.get('startupContainment') or {}
    require(isinstance(startup, dict) and startup.get('service') == 'shortcut'
            and startup.get('provider') == 'io.legado.app.api.ReaderProvider'
            and type(startup.get('intercepted')) is int and startup['intercepted'] == 1
            and type(startup.get('handled')) is int and startup['handled'] == 1
            and startup.get('beforeBinding') is True, 'startup containment differs')
    isolation = report.get('isolation') or {}
    require(isinstance(isolation, dict) and isolation.get('appClass') ==
            'io.liber.oracle.nested.GuardedReaderApplication', 'guarded application differs')
    host = report.get('hostInitialization') or {}
    wrappers = {item['type']: item['factory'] for item in fixture['hostInitialization']['registrations']}
    require(isinstance(host, dict) and host.get('verified') is True
            and host.get('applicationAttached') is False
            and host.get('invokedOn') == 'unattached-instance'
            and isinstance(host.get('notRun'), list)
            and 'io.legado.app.App.onCreate' in host['notRun']
            and host.get('registeredWrappers') == wrappers
            and host.get('method') == fixture['hostInitialization']['method'], 'host initialization differs')
    owner = report.get('terminalOwner') or {}
    require(isinstance(owner, dict) and owner.get('scope') == 'Coroutine.DEFAULT'
            and owner.get('rootActive') is True and owner.get('rootCompleted') is False
            and type(owner.get('baselineChildren')) is int and owner['baselineChildren'] == 0
            and 'kotlinx.coroutines.Job.getChildren()' in owner.get('childrenMethod', '')
            and 'kotlinx.coroutines.Job.isCompleted()' in owner.get('completionMethod', ''),
            'job owner differs')
    entries = report.get('entryPoints') or {}
    signatures = {
        'searchBookAwait': 'searchBookAwait(io.legado.app.data.entities.BookSource,java.lang.String,java.lang.Integer,kotlin.jvm.functions.Function3,kotlin.jvm.functions.Function1,kotlin.coroutines.Continuation)',
        'getBookInfoAwait': 'getBookInfoAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,kotlin.coroutines.Continuation)',
        'getChapterListAwait': 'getChapterListAwait-yxL6bBk(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,boolean,kotlin.coroutines.Continuation)',
        'getContentAwait': 'getContentAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,kotlin.coroutines.Continuation)',
    }
    entry_prefix = 'public final java.lang.Object io.legado.app.model.webBook.WebBook.'
    require(isinstance(entries, dict) and set(entries) == set(signatures)
            and all(entries[k] == entry_prefix + v for k, v in signatures.items()),
            'native entry points differ')
    cases = report.get('cases')
    require(isinstance(cases, list) and len(cases) == len(fixture['cases']), 'case count differs')
    for case in cases:
        terminal = case.get('terminalOwner') if isinstance(case, dict) else None
        require(isinstance(terminal, dict) and terminal.get('owner') == 'Coroutine.DEFAULT Job'
                and terminal.get('allCompleted') is True and terminal.get('rootEmpty') is True
                and type(terminal.get('observedChildren')) is int and terminal['observedChildren'] >= 0
                and type(terminal.get('launchAttempts')) is int and terminal['launchAttempts'] == 0,
                'case terminal proof differs')
    cleanup = report.get('cleanup') or {}
    require(isinstance(cleanup, dict) and cleanup.get('serverClosed') is True
            and type(cleanup.get('openConnectionsAfterClose')) is int
            and cleanup['openConnectionsAfterClose'] == 0 and cleanup.get('databaseClosed') is True
            and type(cleanup.get('activityLaunchAttempts')) is int and cleanup['activityLaunchAttempts'] == 0,
            'cleanup differs')


def _require_selected_webview(text):
    pattern = r'(?m)^\s*Current WebView package \(name, version\): \(com\.google\.android\.webview, 158\.0\.8127\.2\)\s*$'
    if len(re.findall(pattern, text)) != 1:
        raise ValueError('selected WebView provider or version differs')


def _selected_private_root(path):
    if (not isinstance(path, str) or not re.fullmatch(
            r'/data/(?:data|user/[0-9]+)/' + re.escape(SELECTED_TARGET['package']), path)):
        raise ValueError('selected target private root is not canonical')
    return path


def _selected_silent(result, label):
    if result.returncode != 0 or result.stdout.strip() or result.stderr.strip():
        raise ValueError(label + ' failed or carried contradictory output')


def _require_selected_success(receipt, label):
    if (re.search(rb'(?im)(?:Failure\s*\[|^\s*TIMED OUT\b)', receipt)
            or len(re.findall(rb'(?m)^Success\s*\r?$', receipt)) != 1):
        raise ValueError('selected command receipts ' + label + ' success is missing or contradicted')


def _admit_retained_preflight(preflight, install_apk):
    names = ['java-version', 'javac-version', 'source-head', 'source-tree', 'source-status',
             'source-blobs', 'manifest', 'harness-signature', 'target-signature', 'reference-dex', 'dex']
    receipts = preflight.get('commands')
    if not isinstance(receipts, list) or [r.get('name') if isinstance(r, dict) else None for r in receipts] != names:
        raise ValueError('selected preflight command order differs')
    commands = {r['name']: r.get('command') for r in receipts}
    if any(not isinstance(c, list) or not c or any(not isinstance(x, str) or not x for x in c)
           for c in commands.values()):
        raise ValueError('selected preflight command is malformed')
    inputs = preflight.get('inputs')
    keys = {'harnessApk', 'targetApk', 'source', 'androidSdk', 'javaHome', 'referenceDex', 'harnessDex'}
    if not isinstance(inputs, dict) or set(inputs) != keys or any(not isinstance(v, str) or not v for v in inputs.values()):
        raise ValueError('selected preflight command input bindings differ')
    if inputs['harnessApk'] != install_apk:
        raise ValueError('selected preflight command harness APK binding differs')
    java = commands['java-version']
    javac = commands['javac-version']
    if (java != [str(Path(inputs['javaHome']) / 'bin' / 'java.exe'), '-version']
            or javac != [str(Path(inputs['javaHome']) / 'bin' / 'javac.exe'), '-version']):
        raise ValueError('selected preflight command JDK binding differs')
    head = commands['source-head']
    if len(head) != 5 or head[:2] != ['git', '-C'] or head[3:] != ['rev-parse', 'HEAD']:
        raise ValueError('selected preflight command source HEAD differs')
    source = head[2]
    if source != inputs['source']:
        raise ValueError('selected preflight command source input differs')
    references = preflight.get('referenceSources')
    if not isinstance(references, dict):
        raise ValueError('selected preflight command references differ')
    if (commands['source-tree'] != ['git', '-C', source, 'rev-parse', 'HEAD^{tree}']
            or commands['source-status'] != ['git', '-C', source, 'status', '--porcelain=v1']
            or commands['source-blobs'] != ['git', '-C', source, 'hash-object', *references]):
        raise ValueError('selected preflight command source binding differs')
    manifest = commands['manifest']
    if (len(manifest) != 5 or Path(manifest[0]).name.lower() != 'aapt.exe'
            or manifest[1:] != ['dump', 'xmltree', install_apk, 'AndroidManifest.xml']):
        raise ValueError('selected preflight command manifest binding differs')
    tools = Path(manifest[0]).parent
    if tools != Path(inputs['androidSdk']) / 'build-tools' / '35.0.1':
        raise ValueError('selected preflight command SDK binding differs')
    signer = str(tools / 'lib' / 'apksigner.jar')
    common = [java[0], '-jar', signer, 'verify', '--print-certs']
    target_signature = commands['target-signature']
    if (commands['harness-signature'] != common + [inputs['harnessApk']]
            or target_signature != common + [inputs['targetApk']]
            or inputs['targetApk'] == inputs['harnessApk']
            or Path(inputs['targetApk']).suffix.lower() != '.apk'):
        raise ValueError('selected preflight command signer binding differs')
    dexdump = str(tools / 'dexdump.exe')
    for name, role, filename, prefix in [('reference-dex', 'referenceDex', 'classes19.dex', 'fields-reference-dex-'),
                                         ('dex', 'harnessDex', 'classes.dex', 'fields-dex-')]:
        command = commands[name]
        if (command != [dexdump, inputs[role]] or Path(inputs[role]).name != filename
                or not Path(inputs[role]).parent.name.startswith(prefix)):
            raise ValueError('selected preflight command DEX binding differs: ' + name)


def _admit_selected_commands(output, manifest, report_bytes, before, after):
    """Join selected native promotion to the actual retained command receipts."""
    def fail(detail):
        raise ValueError('selected command receipts ' + detail)
    commands = manifest.get('commands')
    if not isinstance(commands, list) or manifest.get('serial') != '5615f742':
        fail('are missing or have the wrong serial')
    indexed = {}
    for item in commands:
        if not isinstance(item, dict) or not isinstance(item.get('log'), str):
            fail('are malformed')
        log = item['log']
        if log in indexed or Path(log).name != log:
            fail('contain duplicate or unsafe log names')
        indexed[log] = item
    required = ['fingerprint', 'sdk', 'webview', 'baseline-path', 'pull-baseline',
                'harness-existing', 'target-process', 'target-private-root',
                'scratch-root-check', 'scratch-prefs-check', 'scratch-installation-probe-check',
                'private-before', 'install', 'installed-harness-path', 'installed-harness-pull',
                'instrumentation', 'pull-report', 'scratch-owner', 'owned-pid', 'poststop',
                'poststop-check', 'scratch-remove-root', 'scratch-absent-root',
                'remove-harness', 'harness-removed-check', 'private-after']
    log_order = [item['log'] for item in commands]
    positions = [log_order.index(name + '.log') if name + '.log' in log_order else -1
                 for name in required]
    if -1 in positions or positions != sorted(positions):
        fail('are missing or out of order')
    adb_prefix = ['adb', '-s', '5615f742']
    target_root = _selected_private_root(manifest.get('targetPrivateRoot'))
    scratch_root = target_root + '/cache/liber-fields-02'
    pref_dir = target_root + '/shared_prefs'
    fixed = {
        'fingerprint': ['shell', 'getprop', 'ro.build.fingerprint'],
        'sdk': ['shell', 'getprop', 'ro.build.version.sdk'],
        'webview': ['shell', 'dumpsys', 'webviewupdate'],
        'baseline-path': ['shell', 'pm', 'path', SELECTED_TARGET['package']],
        'harness-existing': ['shell', 'pm', 'list', 'packages', PACKAGE],
        'target-process': ['shell', 'pidof', SELECTED_TARGET['package']],
        'target-private-root': ['shell', 'run-as', SELECTED_TARGET['package'], 'pwd'],
        'installed-harness-path': ['shell', 'pm', 'path', PACKAGE],
        'instrumentation': ['shell', 'am', 'instrument', '-w', '-r', INSTRUMENTATION],
        'owned-pid': ['shell', 'pidof', SELECTED_TARGET['package']],
        'poststop': ['shell', 'am', 'force-stop', SELECTED_TARGET['package']],
        'poststop-check': ['shell', 'pidof', SELECTED_TARGET['package']],
        'remove-harness': ['uninstall', PACKAGE],
        'harness-removed-check': ['shell', 'pm', 'list', 'packages', PACKAGE],
        'pull-report': ['exec-out', 'run-as', SELECTED_TARGET['package'], 'cat', scratch_root + '/field-oracle.json'],
        'scratch-owner': ['exec-out', 'run-as', SELECTED_TARGET['package'], 'cat', scratch_root + '/owner.json'],
        'private-before': ['shell', *remote_script_arguments(SELECTED_TARGET['package'], _fields_snapshot_script(target_root))],
        'private-after': ['shell', *remote_script_arguments(SELECTED_TARGET['package'], _fields_snapshot_script(target_root))],
        'scratch-root-check': ['shell', *remote_script_arguments(SELECTED_TARGET['package'],
            'if [ -e ' + shlex.quote(scratch_root) + ' ]; then echo PRESENT; else echo ABSENT; fi')],
        'scratch-prefs-check': ['shell', *remote_script_arguments(SELECTED_TARGET['package'],
            'if [ -d ' + shlex.quote(pref_dir) + ' ]; then find ' + shlex.quote(pref_dir)
            + ' -maxdepth 1 -name ' + shlex.quote(OWNED_PREFERENCE_PREFIX + '*.xml') + ' -print; fi')],
        'scratch-installation-probe-check': ['shell', *remote_script_arguments(SELECTED_TARGET['package'],
            'if [ -e ' + shlex.quote(pref_dir + '/probe.xml') + ' ]; then echo PRESENT; fi')],
        'scratch-remove-root': ['shell', *remote_script_arguments(SELECTED_TARGET['package'], 'rm -rf -- ' + shlex.quote(scratch_root))],
        'scratch-absent-root': ['shell', *remote_script_arguments(SELECTED_TARGET['package'], 'test ! -e ' + shlex.quote(scratch_root))],
    }
    for name in required:
        item = indexed.get(name + '.log')
        if item is None or not (output / (name + '.log')).is_file():
            fail('are incomplete: ' + name)
        if type(item.get('exitCode')) is not int or (item['exitCode'] != 0 and name not in ('target-process', 'owned-pid', 'poststop-check')):
            fail('record failure: ' + name)
        command = item.get('command')
        if not isinstance(command, list) or command[:3] != adb_prefix:
            fail('have a wrong device command: ' + name)
        if name in fixed and command != adb_prefix + fixed[name]:
            fail(name + ' command differs')
    instrumentation = (output / 'instrumentation.log').read_bytes()
    terminal_lines = [line.strip() for line in instrumentation.splitlines()
                      if re.match(rb'^\s*INSTRUMENTATION_CODE', line)]
    if (re.search(rb'(?im)(?:Failure\s*\[|^\s*(?:TIMED OUT\b|INSTRUMENTATION_FAILED|INSTRUMENTATION_ABORTED)|shortMsg=)', instrumentation)
            or re.search(rb'(?m)^INSTRUMENTATION_STATUS_CODE:\s*-[12]\s*\r?$', instrumentation)
            or len(terminal_lines) != 1
            or not re.fullmatch(rb'INSTRUMENTATION_CODE:\s*-1', terminal_lines[0])):
        fail('instrumentation did not finish successfully')
    target_path = (output / 'baseline-path.log').read_text(encoding='utf-8').strip()
    harness_path = (output / 'installed-harness-path.log').read_text(encoding='utf-8').strip()
    if not re.fullmatch(r'package:[^\r\n]+', target_path) or not re.fullmatch(r'package:[^\r\n]+', harness_path):
        fail('package APK path is ambiguous')
    target_pull = indexed['pull-baseline.log']['command']
    harness_pull = indexed['installed-harness-pull.log']['command']
    if (len(target_pull) != 6 or target_pull[:5] != adb_prefix + ['pull', target_path[8:]]
            or not isinstance(target_pull[5], str) or Path(target_pull[5]).name != 'frozen.apk'):
        fail('target pull command differs')
    if (len(harness_pull) != 6 or harness_pull[:5] != adb_prefix + ['pull', harness_path[8:]]
            or not isinstance(harness_pull[5], str) or Path(harness_pull[5]).name != 'installed-harness.apk'
            or Path(harness_pull[5]).parent != Path(target_pull[5]).parent):
        fail('installed harness pull command differs')
    install = indexed['install.log']['command']
    if len(install) != 6 or install[:5] != adb_prefix + ['install', '-r'] or not install[-1]:
        fail('install command differs')
    if (output / 'target-private-root.log').read_text(encoding='utf-8').strip() != target_root:
        fail('target private root differs')
    if (output / 'pull-report.log').read_bytes() != report_bytes:
        fail('raw report differs')
    try:
        if json.loads((output / 'scratch-owner.log').read_bytes()) != manifest.get('scratchOwner'):
            fail('raw owner differs')
    except (ValueError, UnicodeDecodeError):
        fail('raw owner is malformed')
    for name in ('target-process', 'poststop-check'):
        if indexed[name + '.log']['exitCode'] != 1 or (output / (name + '.log')).read_bytes().strip():
            fail(name + ' absence differs')
    if (output / 'scratch-root-check.log').read_text(encoding='utf-8').strip() != 'ABSENT':
        fail('scratch root preexistence differs')
    if (output / 'scratch-prefs-check.log').read_bytes().strip() or (output / 'scratch-installation-probe-check.log').read_bytes().strip():
        fail('scratch preference preexistence differs')
    existing = subprocess.CompletedProcess(indexed['harness-existing.log']['command'], 0,
        (output / 'harness-existing.log').read_bytes(), b'')
    if _package_is_present(existing, PACKAGE, 'harness-existing'):
        fail('harness preexistence differs')
    owner = manifest.get('scratchOwner')
    if not isinstance(owner, dict):
        fail('owner is missing')
    names = _safe_owner_names(owner.get('preferences'), 'owner.preferences')
    ordered_cleanup = (['poststop-check.log']
        + ['scratch-remove-' + str(index) + '.log' for index in range(1, len(names) + 1)]
        + ['scratch-remove-root.log']
        + ['scratch-absent-' + str(index) + '.log' for index in range(1, len(names) + 1)]
        + ['scratch-absent-root.log'])
    cleanup_positions = [log_order.index(name) if name in log_order else -1 for name in ordered_cleanup]
    if -1 in cleanup_positions or cleanup_positions != sorted(cleanup_positions):
        fail('owner-derived cleanup receipts are missing or out of order')
    for name in ('poststop', 'scratch-remove-root', 'scratch-absent-root'):
        if (output / (name + '.log')).read_bytes().strip():
            fail(name + ' carried contradictory output')
    allowed = {name + '.log' for name in required} | {
        'source-head.log', 'frozen-source-hashes.log', 'frozen-source-status.log',
        'android-release.log', 'model.log', 'logcat-field-oracle.log',
    } | {'scratch-' + operation + '-' + str(index) + '.log'
         for operation in ('remove', 'absent') for index in range(1, len(names) + 1)}
    if set(indexed) - allowed:
        fail('contain unrecognized commands')
    pid = _require_int(owner.get('seedPid'), 'owner.seedPid')
    pid_receipt = (output / 'owned-pid.log').read_bytes().strip()
    if not ((indexed['owned-pid.log']['exitCode'] == 1 and not pid_receipt)
            or (indexed['owned-pid.log']['exitCode'] == 0 and pid_receipt == str(pid).encode())):
        fail('owned PID differs')
    for index, name in enumerate(names, 1):
        path = target_root + '/shared_prefs/' + name + '.xml'
        for operation, script in [('remove', 'rm -f -- ' + shlex.quote(path)),
                                  ('absent', 'test ! -e ' + shlex.quote(path))]:
            log = 'scratch-' + operation + '-' + str(index) + '.log'
            item = indexed.get(log)
            expected = adb_prefix + ['shell', *remote_script_arguments(SELECTED_TARGET['package'], script)]
            if (not item or item.get('command') != expected or item.get('exitCode') != 0
                    or not (output / log).is_file() or (output / log).read_bytes().strip()):
                fail('owned preference ' + operation + ' differs')
    if sha256(output / 'frozen.apk') != SELECTED_TARGET['apkSha256']:
        fail('installed target APK differs')
    if (output / 'private-before.log').read_bytes() != before or (output / 'private-after.log').read_bytes() != after:
        fail('snapshot bytes differ')
    if (output / 'fingerprint.log').read_text(encoding='utf-8').strip() != SELECTED_TARGET['deviceFingerprint']:
        fail('fingerprint differs')
    if (output / 'sdk.log').read_text(encoding='utf-8').strip() != '37':
        fail('API differs')
    _require_selected_webview((output / 'webview.log').read_text(encoding='utf-8'))
    _require_selected_success((output / 'install.log').read_bytes(), 'install')
    _require_selected_success((output / 'remove-harness.log').read_bytes(), 'uninstall')
    removed = subprocess.CompletedProcess(indexed['harness-removed-check.log']['command'], 0,
        (output / 'harness-removed-check.log').read_bytes(), b'')
    if _package_is_present(removed, PACKAGE, 'harness-removed-check'):
        fail('harness still installed')
    if sha256(output / 'installed-harness.apk') != manifest.get('harnessApkSha256'):
        fail('installed harness APK differs')
    preflight = manifest.get('preflight')
    if (not isinstance(preflight, dict) or preflight.get('artifact') != manifest.get('artifact')
            or preflight.get('targetApkSha256') != SELECTED_TARGET['apkSha256']
            or preflight.get('referenceSources') != manifest.get('frozenSources')):
        fail('preflight artifact or reference differs')
    with zipfile.ZipFile(output / 'frozen.apk') as target_archive, zipfile.ZipFile(output / 'installed-harness.apk') as harness_archive:
        if (target_archive.namelist().count('classes19.dex') != 1
                or harness_archive.namelist().count('classes.dex') != 1
                or sha256_bytes(target_archive.read('classes19.dex')) != preflight.get('referenceDexSha256')
                or sha256_bytes(harness_archive.read('classes.dex')) != preflight.get('dexSha256')):
            fail('preflight DEX input bytes differ')
    required_preflight = {'java-version', 'javac-version', 'source-head', 'source-tree', 'source-status',
                          'source-blobs', 'manifest', 'harness-signature', 'target-signature', 'reference-dex', 'dex'}
    receipts = preflight.get('commands')
    if not isinstance(receipts, list):
        fail('preflight command output is missing')
    seen = set()
    for receipt in receipts:
        if not isinstance(receipt, dict) or receipt.get('name') not in required_preflight:
            fail('preflight command output name differs')
        name = receipt['name']
        if name in seen or type(receipt.get('exitCode')) is not int or receipt['exitCode'] != 0:
            fail('preflight command output status differs')
        seen.add(name)
        for stream in ('stdout', 'stderr'):
            path = output / ('preflight-' + name + '.' + stream + '.log')
            if not path.is_file() or sha256(path) != receipt.get(stream + 'Sha256'):
                fail('preflight command output differs: ' + name)
    if seen != required_preflight:
        fail('preflight command output inventory differs')
    _admit_retained_preflight(preflight, install[-1])
    references = preflight['referenceSources']
    if (any(not isinstance(value, dict) or not re.fullmatch(r'[0-9a-f]{40}', str(value.get('blobSha1', '')))
            or not re.fullmatch(r'[0-9a-f]{64}', str(value.get('worktreeSha256', '')))
            for value in references.values())
            or (output / 'preflight-source-blobs.stdout.log').read_text(encoding='utf-8').split()
               != [value['blobSha1'] for value in references.values()]):
        fail('preflight source blob outputs differ')
    if ((output / 'preflight-source-head.stdout.log').read_text(encoding='utf-8').strip() != SELECTED_BASELINE
            or (output / 'preflight-source-tree.stdout.log').read_text(encoding='utf-8').strip() != '0f69dc7004012a969551ce271dc4e11051637d32'
            or (output / 'preflight-source-status.stdout.log').read_bytes().strip()):
        fail('preflight source identity differs')


def _finalize_fields_02(output, fixture, manifest, report, before, after, asset=None,
                        scratch_cleanup=None, fixture_bytes=None, report_bytes=None,
                        original_apk=None):
    """Validate the FIELDS-02 native report without deleting prior artifacts."""
    golden_path = output / 'golden.json'
    disk_report_bytes = (output / 'field-oracle.json').read_bytes()
    if report_bytes is not None and report_bytes != disk_report_bytes:
        raise ValueError('the supplied report bytes differ from the exact disk report')
    report_bytes = disk_report_bytes
    report = json.loads(report_bytes.decode('utf-8'))
    if fixture_bytes is None:
        raise ValueError('the selected fixture bytes are required for FIELDS-02 finalization')
    if not isinstance(fixture_bytes, (bytes, bytearray)):
        raise ValueError('the selected fixture bytes must be bytes')
    fixture_bytes = bytes(fixture_bytes)
    selected_fixture = json.loads(fixture_bytes.decode('utf-8'))
    if selected_fixture != fixture:
        raise ValueError('the supplied fixture object differs from the selected fixture bytes')
    fixture = selected_fixture
    if fixture.get('baselineCommit') == SELECTED_BASELINE:
        report = _strict_json(report_bytes.decode('utf-8'))
    fixture_sha = sha256_bytes(fixture_bytes)
    fixture_lf_sha = sha256_bytes(lf_bytes(fixture_bytes))
    if fixture.get('fixtureId') != FIELDS_02:
        raise ValueError('the selected fixture is not FIELDS-02')
    if _require_int(fixture.get('corpusVersion'), 'fixture.corpusVersion') != 1:
        raise ValueError('the selected fixture version is not integer 1')
    if original_apk is None:
        raise ValueError('the original selected APK is required for FIELDS-02 finalization')
    original_artifact = _inspect_selected_apk(original_apk, fixture_bytes, fixture, None)
    manifest_artifact = _required_map(manifest, 'artifact', 'manifest')
    for field in ['apkSha256', 'selectedAssetSha256', 'selectedAssetSha256Lf',
                  'selectedAssetBytes', 'provenanceSha256']:
        if original_artifact.get(field) != manifest_artifact.get(field):
            raise ValueError('the original APK artifact differs from the manifest at ' + field)
    if original_artifact.get('provenance') != manifest_artifact.get('provenance'):
        raise ValueError('the original APK provenance differs from the manifest')
    manifest_sources = _required_map(manifest, 'harnessSources', 'manifest')
    embedded_sources = _required_map(
        original_artifact['provenance'], 'sources', 'original.provenance')
    if manifest_sources != embedded_sources:
        raise ValueError('the original APK sources differ from the harness manifest')
    golden_reused = golden_path.exists()
    if golden_reused and golden_path.read_bytes() != report_bytes:
        raise ValueError('an existing golden differs from this report; refusing to overwrite')

    if not isinstance(report, dict):
        raise ValueError('the frozen report must be an object')
    if _required(report, 'analysisFailure', 'report') is not None:
        raise ValueError('the frozen harness reported an analysis failure')
    if _required_map(report, 'caseFailures', 'report'):
        raise ValueError('the frozen harness recorded a failed case')
    if _required_list(report, 'unmatchedRequests', 'report'):
        raise ValueError('the frozen run issued an undeclared request')
    if _required_list(report, 'serverErrors', 'report'):
        raise ValueError('the frozen run recorded a server error')
    if fixture.get('baselineCommit') == SELECTED_BASELINE:
        _admit_selected_runtime(report, fixture)
        _admit_selected_commands(output, manifest, report_bytes, before, after)
    for field in ['fixtureId', 'corpusVersion', 'baselineCommit', 'entryPoint']:
        if _required(report, field, 'report') != fixture[field]:
            raise ValueError('the frozen report disagrees on ' + field)
    _require_int(_required(report, 'corpusVersion', 'report'), 'report.corpusVersion')
    _require_int(_required(fixture, 'corpusVersion', 'fixture'), 'fixture.corpusVersion')
    if _required_string(report, 'platform', 'report') != 'android':
        raise ValueError('the frozen report platform differs')
    if _required_string(report, 'origin', 'report') != fixture['origin']:
        raise ValueError('the frozen report origin differs')

    declared = [case['id'] for case in fixture['cases']]
    if not declared or len(set(declared)) != len(declared):
        raise ValueError('declared case ids must be nonempty and unique')
    cases = _required_list(report, 'cases', 'report')
    observed_ids = []
    for index, case in enumerate(cases):
        _admit_native_case(case, fixture['cases'][index], f'report.cases[{index}]')
        observed_ids.append(case['id'])
    if observed_ids != declared:
        raise ValueError('the frozen report cases are not the declared set/order')

    requests = _required_list(report, 'requests', 'report')
    expected_requests = fixture['expectedRequests']
    responses = fixture['responses']
    if len(expected_requests) != len(responses):
        raise ValueError('corpus expectedRequests/responses are not aligned')
    if len(requests) != len(expected_requests):
        raise ValueError('the frozen request sequence is not the declared sequence')
    for index, (actual, wanted) in enumerate(zip(requests, expected_requests)):
        label = f'report.requests[{index}]'
        _admit_native_request(actual, label)
        actual_method, actual_path, actual_query = _request_identity(actual, label)
        if actual_method != wanted['method'] or actual_path != wanted['path']:
            raise ValueError('request identity differs at ' + str(index))
        if actual_query != wanted.get('query', {}):
            raise ValueError('request query differs at ' + str(index))
        if actual.get('rawQuery') != _canonical_raw_query(wanted):
            raise ValueError('request rawQuery differs at ' + str(index))
        response = responses[index]
        receipt = _required_map(actual, 'receipt', label)
        if receipt.get('responseId') != response['id']:
            raise ValueError('response id differs at ' + str(index))
        if _require_int(receipt.get('status'), f'report.requests[{index}].receipt.status') != _require_int(response.get('status', 200), f'responses[{index}].status'):
            raise ValueError('response status differs at ' + str(index))
        location = (response.get('headers') or {}).get('Location')
        if receipt.get('redirect') != location:
            raise ValueError('response redirect differs at ' + str(index))

    trace = _required_list(report, 'stageTrace', 'report')
    if not trace:
        raise ValueError('the frozen report has an empty stage trace')
    for index, entry in enumerate(trace):
        label = f'report.stageTrace[{index}]'
        if not isinstance(entry, dict):
            raise ValueError(label + ' must be an object')
        _required_string(entry, 'stage', label)
        _required_string(entry, 'path', label)
    _admit_native_causality(cases, requests, trace, fixture)
    for index, entry in enumerate(trace):
        stage = _required_string(entry, 'stage', f'report.stageTrace[{index}]')
        if stage not in ('search', 'bookInfo', 'tableOfContents', 'content'):
            raise ValueError(f'report.stageTrace[{index}].stage is not a producer stage')
    _admit_native_operations(cases, requests, trace, fixture)

    corpus = _required_map(report, 'corpus', 'report')
    if corpus.get('asset') != 'field-fixtures.json':
        raise ValueError('the frozen report corpus asset differs')
    if corpus.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the frozen report fixture id differs')
    if _require_int(corpus.get('corpusVersion'), 'report.corpus.corpusVersion') != _require_int(fixture['corpusVersion'], 'fixture.corpusVersion'):
        raise ValueError('the frozen report corpus version differs')
    manifest_corpus = _required_map(manifest, 'corpus', 'manifest')
    for field in ['bytes', 'sha256', 'sha256Lf']:
        if field not in manifest_corpus:
            raise ValueError('manifest corpus measurement is missing ' + field)
    if _require_int(corpus.get('bytes'), 'report.corpus.bytes') != _require_int(manifest_corpus['bytes'], 'manifest.corpus.bytes'):
        raise ValueError('the frozen report corpus byte count differs')
    if corpus.get('sha256') != manifest_corpus['sha256']:
        raise ValueError('the frozen report raw corpus hash differs')
    if corpus.get('sha256Lf') != manifest_corpus['sha256Lf']:
        raise ValueError('the frozen report LF corpus hash differs')
    if _require_int(manifest_corpus['bytes'], 'manifest.corpus.bytes') < 0:
        raise ValueError('manifest corpus byte count must be nonnegative')
    if not re.fullmatch(r'[0-9a-f]{64}', manifest_corpus['sha256']):
        raise ValueError('manifest raw corpus hash is malformed')
    if not re.fullmatch(r'[0-9a-f]{64}', manifest_corpus['sha256Lf']):
        raise ValueError('manifest LF corpus hash is malformed')
    if _required_string(manifest, 'fingerprint', 'manifest') != fixture['target']['deviceFingerprint']:
        raise ValueError('the measured device fingerprint differs from the corpus target')
    if report.get('fingerprint') != manifest['fingerprint']:
        raise ValueError('the frozen report device fingerprint differs')
    if manifest.get('baselineApkSha256') != fixture['target']['apkSha256']:
        raise ValueError('the measured target APK differs from the corpus target')

    isolation = _required_map(report, 'isolation', 'report')
    for field in ['bound', 'filesRouted', 'databaseRouted']:
        if _required_bool(isolation, field, 'report.isolation') is not True:
            raise ValueError('report.isolation.' + field + ' must be true')
    if _required_bool(isolation, 'deviceProtected', 'report.isolation') is not False:
        raise ValueError('the scratch application used device-protected storage')
    if _required_bool(isolation, 'rootExistedAtStart', 'report.isolation') is not False:
        raise ValueError('the scratch root already existed')
    if isolation.get('targetPackage') != fixture['target']['package']:
        raise ValueError('the scratch target package differs')
    if isolation.get('targetApkSha256') != manifest['baselineApkSha256']:
        raise ValueError('the scratch target APK binding differs')
    if isolation.get('harnessPackage') != PACKAGE:
        raise ValueError('the scratch harness package differs')
    if isolation.get('harnessApkSha256') != manifest.get('harnessApkSha256'):
        raise ValueError('the scratch harness APK binding differs')
    if isolation.get('corpusSha256Lf') != manifest_corpus['sha256Lf']:
        raise ValueError('the scratch corpus LF binding differs')
    _required_string(isolation, 'preferencesPrefix', 'report.isolation')
    _required_string(isolation, 'scratchRoot', 'report.isolation')
    _admit_provenance(manifest, fixture_bytes, fixture, isolation)
    probe = _required_map(isolation, 'preferenceProbe', 'report.isolation')
    if probe.get('installationFile') is not False:
        raise ValueError('preference probe wrote the installation file')
    for flag in ['registered', 'committed', 'scopedFile']:
        if _required(probe, flag, 'report.isolation.preferenceProbe') is not True:
            raise ValueError('preference probe.' + flag + ' must be true')
    if probe.get('name') != OWNED_PREFERENCE_PREFIX + 'probe':
        raise ValueError('preference probe name differs from the owned namespace')

    target_root = _required_string(manifest, 'targetPrivateRoot', 'manifest')
    root_path = target_root + '/cache/liber-fields-02'
    report_path = root_path + '/field-oracle.json'
    cleanup = _required_map(report, 'cleanup', 'report')
    if cleanup.get('fixtureId') != FIELDS_02:
        raise ValueError('the report cleanup family differs')
    if _require_int(cleanup.get('corpusVersion'), 'report.cleanup.corpusVersion') != 1:
        raise ValueError('the report cleanup corpus version differs')
    for field in ['serverClosed', 'ownerComplete', 'rootRetained', 'preferencesFenced']:
        if _required(cleanup, field, 'report.cleanup') is not True:
            raise ValueError('report.cleanup.' + field + ' must be true')
    if cleanup.get('scratchRoot') != root_path:
        raise ValueError('the scratch root path differs from the measured path')
    if cleanup.get('reportPath') != report_path:
        raise ValueError('the scratch report path differs from the measured path')
    owner_run_id = _required_string(cleanup, 'ownerRunId', 'report.cleanup')
    owned = _required_list(cleanup, 'ownedPreferences', 'report.cleanup')
    if not owned or any(
            not re.fullmatch(r'liber_fields_02_[A-Za-z0-9_.:+-]+', str(name))
            for name in owned):
        raise ValueError('the scratch owned-preference list is malformed')
    if len(set(owned)) != len(owned):
        raise ValueError('the scratch owned-preference list contains duplicates')

    owner = _required_map(manifest, 'scratchOwner', 'manifest')
    if owner.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the scratch owner fixture id differs')
    if _require_int(owner.get('corpusVersion'), 'manifest.scratchOwner.corpusVersion') != _require_int(fixture['corpusVersion'], 'fixture.corpusVersion'):
        raise ValueError('the scratch owner corpus version differs')
    if owner.get('targetPackage') != fixture['target']['package']:
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
    if owner.get('seedRunId') != owner_run_id or not owner_run_id:
        raise ValueError('the scratch owner does not bind this attempt')
    if _require_int(owner.get('seedPid'), 'manifest.scratchOwner.seedPid') <= 0:
        raise ValueError('the scratch owner seed PID must be positive')
    _admit_owner_inventories(
        _required_list(owner, 'preferences', 'manifest.scratchOwner'), owned)

    if not isinstance(scratch_cleanup, dict):
        raise ValueError('the external scratch cleanup receipt is missing')
    if scratch_cleanup.get('postStop') is not True:
        raise ValueError('the owned target process was not proven stopped')
    if scratch_cleanup.get('rootAbsent') is not True:
        raise ValueError('the external scratch root cleanup is not proven')
    if scratch_cleanup.get('ownedPreferencesAbsent') is not True:
        raise ValueError('the owned preferences survived cleanup')
    if scratch_cleanup.get('root') != root_path:
        raise ValueError('the external cleanup root differs')
    if scratch_cleanup.get('ownerRunId') != cleanup.get('ownerRunId'):
        raise ValueError('the external cleanup attempt differs from the owner')
    receipt_owned = scratch_cleanup.get('reportedOwnedPreferences')
    if not isinstance(receipt_owned, list) or not receipt_owned:
        raise ValueError('the external cleanup inventory is missing')
    _admit_owner_inventories(
        _required_list(owner, 'preferences', 'manifest.scratchOwner'),
        owned, receipt_owned)

    frozen = _required_map(manifest, 'frozenSources', 'manifest')
    if fixture.get('baselineCommit') == SELECTED_BASELINE and set(frozen) != {row['path'] for row in fixture['frozenSources']}:
        raise ValueError('the manifest frozen source inventory differs')
    for source in fixture['frozenSources']:
        item = frozen.get(source['path'])
        if not isinstance(item, dict) or item.get('blobSha1') != source['sha1']:
            raise ValueError('the manifest frozen source binding differs: ' + source['path'])
    harness_sources = _required_map(manifest, 'harnessSources', 'manifest')
    if not harness_sources:
        raise ValueError('the manifest harness source binding is empty')

    before_hashes = _snapshot_records(before, 'before')
    after_hashes = _snapshot_records(after, 'after')
    for label, hashes in [('before', before_hashes), ('after', after_hashes)]:
        required_paths = set(FROZEN_APP_STORE) | {
            '.', 'cache', 'databases', 'shared_prefs', 'files',
        }
        missing = sorted(required_paths - set(hashes))
        if missing:
            raise ValueError('the ' + label + ' private inventory is incomplete: ' + ', '.join(missing))
        for path in required_paths:
            if hashes[path][0] != ('F' if path in FROZEN_APP_STORE else 'D'):
                raise ValueError(f'the {label} private node kind differs for {path}')
    changed = {path: {'before': before_hashes.get(path), 'after': after_hashes.get(path)}
               for path in sorted(set(before_hashes) | set(after_hashes))
               if before_hashes.get(path) != after_hashes.get(path)}
    if changed:
        raise ValueError('FIELDS-02 private storage changed outside the scratch boundary: '
                         + json.dumps(changed, ensure_ascii=False))
    manifest['existingDataHashesUnchanged'] = True
    manifest['privateFileChanges'] = {}
    if fixture.get('baselineCommit') == SELECTED_BASELINE:
        manifest['privateSnapshotSha256'] = {
            'before': sha256_bytes(before), 'after': sha256_bytes(after)}
    manifest['frozenAppDataUnchanged'] = all(
        path in after_hashes and after_hashes[path][0] == 'F'
        for path in FROZEN_APP_STORE)
    if not manifest['frozenAppDataUnchanged']:
        raise ValueError('the frozen application store is missing from the post-stop snapshot')

    manifest['cases'] = {'frozen': declared}
    manifest['deviceAssets'] = cleanup
    manifest['isolation'] = isolation
    manifest['scratchCleanup'] = scratch_cleanup
    manifest['corpus']['assetCopySha256'] = manifest_corpus.get('assetCopySha256')
    if asset is not None:
        asset_bytes = Path(asset).read_bytes()
        actual_asset = sha256_bytes(asset_bytes)
        if len(asset_bytes) != manifest_corpus['bytes']:
            raise ValueError('the built corpus asset byte count differs')
        if actual_asset != manifest_corpus['sha256']:
            raise ValueError('the built corpus asset raw hash differs')
        if sha256_bytes(lf_bytes(asset_bytes)) != manifest_corpus['sha256Lf']:
            raise ValueError('the built corpus asset LF hash differs')
        manifest['corpus']['assetCopySha256'] = actual_asset

    if not golden_reused:
        golden_path.write_bytes(report_bytes)
    manifest['goldenSha256'] = sha256(golden_path)
    manifest['status'] = 'observed'
    return {'goldenReused': golden_reused}

def _reconcile_selected_preflight(retained, fresh_binding):
    for key in ('artifact', 'targetApkSha256', 'referenceSources', 'dexSha256', 'referenceDexSha256'):
        if key not in fresh_binding or fresh_binding[key] != retained.get(key):
            raise ValueError('fresh preflight differs from retained binding: ' + key)
    try:
        recorded_commands = {item['name']: item['command'] for item in retained['commands']}
        fresh_commands = {item['name']: item['command'] for item in fresh_binding['commands']}
        for name in ('java-version', 'javac-version', 'manifest', 'harness-signature',
                     'target-signature', 'reference-dex', 'dex'):
            if Path(recorded_commands[name][0]).resolve() != Path(fresh_commands[name][0]).resolve():
                raise ValueError('fresh preflight tool differs: ' + name)
        for name in ('harness-signature', 'target-signature'):
            if Path(recorded_commands[name][2]).resolve() != Path(fresh_commands[name][2]).resolve():
                raise ValueError('fresh preflight signer differs: ' + name)
    except (KeyError, IndexError, TypeError) as error:
        raise ValueError('fresh preflight command binding is incomplete') from error


def verify_selected_bundle(bundle, fixture_path, apk, fresh_binding):
    """Re-admit an existing selected bundle without writing into it."""
    fixture_bytes = fixture_path.read_bytes()
    fixture = _strict_json(fixture_bytes.decode('utf-8'))
    if fixture.get('baselineCommit') != SELECTED_BASELINE:
        raise ValueError('bundle verification requires the selected reference')
    manifest_bytes = (bundle / 'manifest.json').read_bytes()
    manifest = _strict_json(manifest_bytes.decode('utf-8'))
    report_bytes = (bundle / 'field-oracle.json').read_bytes()
    golden_bytes = (bundle / 'golden.json').read_bytes()
    report = _strict_json(report_bytes.decode('utf-8'))
    if (not isinstance(manifest, dict) or manifest.get('status') != 'observed'
            or report_bytes != golden_bytes or manifest.get('goldenSha256') != sha256_bytes(golden_bytes)):
        raise ValueError('selected bundle golden or manifest differs')
    retained = _required_map(manifest, 'preflight', 'manifest')
    _reconcile_selected_preflight(retained, fresh_binding)
    if (fresh_binding['targetApkSha256'] != SELECTED_TARGET['apkSha256']
            or sha256(bundle / 'frozen.apk') != fresh_binding['targetApkSha256']
            or sha256(bundle / 'installed-harness.apk') != fresh_binding['artifact']['apkSha256']
            or sha256(apk) != fresh_binding['artifact']['apkSha256']):
        raise ValueError('fresh preflight APK binding differs')
    derived = copy.deepcopy(manifest)
    result = _finalize_fields_02(bundle, fixture, derived, report,
        (bundle / 'private-before.log').read_bytes(), (bundle / 'private-after.log').read_bytes(),
        asset=fixture_path, scratch_cleanup=manifest.get('scratchCleanup'),
        fixture_bytes=fixture_bytes, report_bytes=report_bytes, original_apk=apk)
    if not result.get('goldenReused') or derived != manifest:
        raise ValueError('selected bundle derived manifest differs')
    return {'status': 'verified-bundle', 'goldenSha256': sha256_bytes(golden_bytes),
            'manifestSha256': sha256_bytes(manifest_bytes), 'fixtureSha256': sha256_bytes(fixture_bytes),
            'harnessApkSha256': fresh_binding['artifact']['apkSha256'],
            'provenanceSha256': fresh_binding['artifact']['provenanceSha256'],
            'targetApkSha256': fresh_binding['targetApkSha256']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial')
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--verify-bundle', type=Path,
                        help='read-only verification of an existing selected bundle')
    parser.add_argument('--target-apk', type=Path)
    parser.add_argument('--java-home', type=Path)
    parser.add_argument('--android-sdk', type=Path,
                        default=Path(os.environ.get('LOCALAPPDATA', '')) / 'Android/Sdk')
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
    fixture_id = fixture.get('fixtureId')
    if fixture_id not in (FIELDS_01, FIELDS_02):
        raise SystemExit('unsupported result-field fixture family')
    fields_02 = fixture_id == FIELDS_02
    if args.verify_bundle is not None:
        if (args.preflight_only or args.finalize or not fields_02
                or fixture.get('baselineCommit') != SELECTED_BASELINE
                or not all((args.apk, args.target_apk, args.frozen_source, args.java_home))):
            raise SystemExit('bundle verification requires the selected reference and APK/source/SDK arguments')
        if args.output.resolve() == args.verify_bundle.resolve() or args.verify_bundle.resolve() in args.output.resolve().parents:
            raise SystemExit('verification output must be outside the input bundle')
        args.output.mkdir(parents=True, exist_ok=False)
        try:
            binding = selected_preflight(args.apk, args.target_apk, fixture_path,
                args.frozen_source, args.android_sdk, args.java_home, evidence=args.output)
            result = verify_selected_bundle(args.verify_bundle, fixture_path, args.apk, binding)
            (args.output / 'verification.json').write_text(
                json.dumps(result, indent=2) + '\n', encoding='utf-8')
        except Exception as error:
            (args.output / 'verification-failure.json').write_text(
                json.dumps({'status': 'failed', 'error': str(error)}, indent=2) + '\n', encoding='utf-8')
            raise SystemExit(str(error)) from error
        print(json.dumps(result))
        return 0
    if args.preflight_only:
        if not fields_02 or fixture.get('baselineCommit') != SELECTED_BASELINE:
            raise SystemExit('preflight requires the selected FIELDS-02 reference')
        if args.finalize or not all((args.apk, args.target_apk, args.frozen_source, args.java_home)):
            raise SystemExit('preflight requires --apk, --target-apk, --frozen-source and --java-home')
        if not args.target_apk.is_file() or sha256(args.target_apk) != SELECTED_TARGET['apkSha256']:
            raise SystemExit('selected target APK is missing or differs')
        args.output.mkdir(parents=True, exist_ok=False)
        try:
            binding = selected_preflight(args.apk, args.target_apk, fixture_path,
                                         args.frozen_source, args.android_sdk, args.java_home,
                                         evidence=args.output)
        except Exception as error:
            (args.output / 'preflight-failure.json').write_text(
                json.dumps({'status': 'failed', 'error': str(error)}, indent=2) + '\n', encoding='utf-8')
            raise SystemExit(str(error)) from error
        (args.output / 'preflight.json').write_text(
            json.dumps(binding, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': 'preflight-only', 'output': str(args.output)}))
        return 0
    if not args.serial:
        parser.error('--serial is required except for --preflight-only')
    selected_reference = fields_02 and fixture.get('baselineCommit') == SELECTED_BASELINE
    target_package = SELECTED_TARGET['package'] if selected_reference else TARGET_PACKAGE
    selected_binding = None
    if selected_reference:
        if args.serial != '5615f742' or not all((args.apk, args.target_apk, args.frozen_source, args.java_home)):
            raise SystemExit('selected capture requires the approved serial, --apk, --target-apk, --frozen-source and --java-home')
        if not args.finalize:
            args.output.mkdir(parents=True, exist_ok=False)
        try:
            selected_binding = selected_preflight(args.apk, args.target_apk, fixture_path,
                args.frozen_source, args.android_sdk, args.java_home,
                evidence=None if args.finalize else args.output)
        except Exception as error:
            if args.finalize:
                if ((isinstance(error, subprocess.TimeoutExpired) and hasattr(error, 'fields_preflight_timeout'))
                        or (isinstance(error, ValueError) and hasattr(error, 'fields_preflight_failure'))):
                    _retain_preflight_failure(args.output, error)
                _write_finalize_failure(args.output, str(error), preserve_existing=True)
            else:
                (args.output / 'preflight-failure.json').write_text(
                    json.dumps({'status': 'failed', 'error': str(error)}, indent=2) + '\n', encoding='utf-8')
            raise SystemExit(str(error)) from error
    if fields_02 and args.apk is None:
        raise SystemExit('FIELDS-02 requires --apk, including --finalize')
    if args.finalize:
        try:
            report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
            manifest = json.loads((args.output / 'manifest.json').read_text(encoding='utf-8'))
            report_bytes = (args.output / 'field-oracle.json').read_bytes()
        except Exception as error:
            if not selected_reference:
                raise
            _write_finalize_failure(args.output, str(error), preserve_existing=True)
            return 1
        if fields_02:
            if selected_reference:
                try:
                    _reconcile_selected_preflight(_required_map(manifest, 'preflight', 'manifest'), selected_binding)
                except Exception as error:
                    _write_finalize_failure(args.output, str(error), preserve_existing=True)
                    return 1
            golden = args.output / 'golden.json'
            report_bytes = (args.output / 'field-oracle.json').read_bytes()
            if golden.exists():
                if golden.read_bytes() != report_bytes:
                    _write_finalize_failure(args.output,
                        'existing golden bytes differ from report; refusing',
                        preserve_existing=selected_reference)
                    return 1
                if manifest.get('status') != 'observed' or manifest.get('goldenSha256') != sha256(golden):
                    _write_finalize_failure(args.output,
                        'existing golden has no accepted manifest binding',
                        preserve_existing=selected_reference)
                    return 1
            try:
                result = finalize(args.output, fixture, manifest, report,
                                  (args.output / 'private-before.log').read_bytes(),
                                  (args.output / 'private-after.log').read_bytes(),
                                  asset=args.asset,
                                  scratch_cleanup=manifest.get('scratchCleanup'),
                                  fixture_bytes=fixture_path.read_bytes(),
                                  report_bytes=report_bytes,
                                  original_apk=args.apk)
            except Exception as error:  # noqa: BLE001 - preserve accepted bytes
                _write_finalize_failure(args.output, str(error), preserve_existing=selected_reference)
                return 1
            if result and result.get('goldenReused'):
                print(json.dumps({'status': 'observed',
                                  'manifest': str(args.output / 'manifest.json'),
                                  'goldenReused': True}))
                return 0
            (args.output / 'manifest.json').write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            print(json.dumps({'status': manifest['status'],
                              'manifest': str(args.output / 'manifest.json')}))
            return 0 if manifest['status'] == 'observed' else 1
        try:
            finalize(args.output, fixture, manifest, report,
                     (args.output / 'private-before.log').read_bytes(),
                     (args.output / 'private-after.log').read_bytes(),
                     asset=args.asset,
                     scratch_cleanup=manifest.get('scratchCleanup'),
                     fixture_bytes=fixture_path.read_bytes(),
                     report_bytes=report_bytes)
        except Exception as error:  # noqa: BLE001 - legacy manifest records the blocker
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
    corpus_bytes = fixture_path.read_bytes()
    corpus_sha256 = sha256_bytes(corpus_bytes)
    corpus_sha256_lf = sha256_bytes(lf_bytes(corpus_bytes))
    asset_bytes = None
    artifact = None
    if fields_02:
        asset_bytes = Path(args.asset).read_bytes()
        if len(asset_bytes) != len(corpus_bytes):
            raise SystemExit('the built asset byte count differs from the selected corpus')
        if sha256_bytes(asset_bytes) != corpus_sha256:
            raise SystemExit('the built asset raw hash differs from the selected corpus')
        if sha256_bytes(lf_bytes(asset_bytes)) != corpus_sha256_lf:
            raise SystemExit('the built asset LF hash differs from the selected corpus')
        artifact = inspect_selected_apk(args.apk, fixture_path, fixture,
                                        harness_source_hashes(selected=selected_reference))
    if not selected_reference:
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
        'harnessSources': harness_source_hashes(selected=selected_reference),
    }
    if selected_reference:
        manifest['preflight'] = selected_binding
    if fields_02:
        manifest['corpus'].update({
            'bytes': len(corpus_bytes),
            'sha256Lf': corpus_sha256_lf,
            'assetCopySha256': sha256_bytes(asset_bytes),
        })
        manifest['artifact'] = artifact
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

    def remote_script(name, script, **kwargs):
        result = adb(name, 'shell', *remote_script_arguments(target_package, script),
                     **kwargs)
        return result

    def preflight_fields_02():
        """Refuse any preexisting state; never delete or replace it."""
        process = adb('target-process', 'shell', 'pidof', target_package, checked=False)
        if _measured_pids(process, 'preflight target pid'):
            raise ValueError('a target process already exists; refusing an unowned run')
        root_result = adb('target-private-root', 'shell', 'run-as', target_package,
                          'pwd', checked=False)
        if root_result.returncode != 0 or (selected_reference and root_result.stderr.strip()):
            raise ValueError('cannot measure the target-private root')
        target_root = root_result.stdout.decode(errors='replace').strip()
        if selected_reference:
            _selected_private_root(target_root)
        if not target_root.startswith('/data/') or '\n' in target_root:
            raise ValueError('target-private root is not a canonical absolute data path')
        root_path = target_root + '/cache/liber-fields-02'
        pref_dir = target_root + '/shared_prefs'
        installation_probe = pref_dir + '/probe.xml'
        root = remote_script('scratch-root-check',
                             'if [ -e ' + shlex.quote(root_path)
                             + ' ]; then echo PRESENT; else echo ABSENT; fi',
                             checked=False)
        if root.returncode != 0 or (selected_reference and root.stderr.strip()):
            raise ValueError('cannot determine whether the scratch root exists')
        if root.stdout.decode(errors='replace').strip() != 'ABSENT':
            raise ValueError('a preexisting scratch root exists; refusing to delete it')
        prefs = remote_script(
            'scratch-prefs-check',
            'if [ -d ' + shlex.quote(pref_dir) + ' ]; then '
            + 'find ' + shlex.quote(pref_dir)
            + ' -maxdepth 1 -name ' + shlex.quote(OWNED_PREFERENCE_PREFIX + '*.xml')
            + ' -print; fi',
            checked=False,
        )
        if prefs.returncode != 0 or (selected_reference and prefs.stderr.strip()):
            raise ValueError('cannot determine whether owned preferences exist')
        if prefs.stdout.strip():
            raise ValueError('a preexisting field preference namespace exists; refusing to delete it')
        installation = remote_script(
            'scratch-installation-probe-check',
            'if [ -e ' + shlex.quote(installation_probe) + ' ]; then echo PRESENT; fi',
            checked=False,
        )
        if installation.returncode != 0 or (selected_reference and installation.stderr.strip()):
            raise ValueError('cannot determine whether the installation probe exists')
        if installation.stdout.strip():
            raise ValueError('a preexisting installation probe exists; refusing to remove it')
        return target_root

    def stop_owned_target(owner):
        seed_pid = _require_int(_required(owner, 'seedPid', 'owner'), 'owner.seedPid')
        if seed_pid <= 0:
            raise ValueError('the owner seed PID is not a live process id')
        pids = _measured_pids(
            adb('owned-pid', 'shell', 'pidof', target_package, checked=False),
            'owned target pid')
        if pids and pids != [str(seed_pid)]:
            raise ValueError('the target process does not belong to the owner seed')
        stopped = adb('poststop', 'shell', 'am', 'force-stop', target_package, checked=False)
        if stopped.returncode != 0:
            raise ValueError('the owned target process could not be stopped')
        if selected_reference:
            _selected_silent(stopped, 'selected target stop')
        if _measured_pids(
                adb('poststop-check', 'shell', 'pidof', target_package, checked=False),
                'post-stop target pid'):
            raise ValueError('the target process is still present after the owned stop')

    def cleanup_fields_02(report, owner, manifest):
        """Remove only the exact owner inventory after proving the stop/binding."""
        if not isinstance(report, dict) or not isinstance(owner, dict):
            raise ValueError('report/owner cleanup input is malformed')
        cleanup = report.get('cleanup') or {}
        if not isinstance(cleanup, dict):
            raise ValueError('scratch cleanup record malformed')
        target_root = manifest.get('targetPrivateRoot')
        if (not isinstance(target_root, str)
                or not target_root.startswith('/data/')
                or '..' in target_root.split('/')
                or chr(10) in target_root or chr(13) in target_root):
            raise ValueError('measured target-private root is missing or non-canonical')
        root_path = target_root + '/cache/liber-fields-02'
        pref_dir = target_root + '/shared_prefs'
        isolation = report.get('isolation') or {}
        artifact = manifest.get('artifact') or {}
        for field in ['bound', 'filesRouted', 'databaseRouted']:
            if _required_bool(isolation, field, 'report.isolation') is not True:
                raise ValueError('report.isolation.' + field + ' must be true before cleanup')
        if _required_bool(isolation, 'deviceProtected', 'report.isolation') is not False:
            raise ValueError('device-protected storage differs before cleanup')
        if _required_bool(isolation, 'rootExistedAtStart', 'report.isolation') is not False:
            raise ValueError('preexisting scratch root differs before cleanup')
        if report.get('fixtureId') != FIELDS_02:
            raise ValueError('report family differs before cleanup')
        if _require_int(report.get('corpusVersion'), 'report.corpusVersion') != 1:
            raise ValueError('report corpus version differs before cleanup')
        if cleanup.get('fixtureId') != FIELDS_02:
            raise ValueError('cleanup family differs before cleanup')
        if _require_int(cleanup.get('corpusVersion'), 'cleanup.corpusVersion') != 1:
            raise ValueError('cleanup corpus version differs before cleanup')
        if isolation.get('targetPackage') != target_package:
            raise ValueError('report target package differs before cleanup')
        if isolation.get('targetApkSha256') != manifest.get('baselineApkSha256'):
            raise ValueError('report target APK differs before cleanup')
        if isolation.get('harnessPackage') != PACKAGE:
            raise ValueError('report harness package differs before cleanup')
        if isolation.get('harnessApkSha256') != manifest.get('harnessApkSha256'):
            raise ValueError('report harness APK differs before cleanup')
        if isolation.get('scratchRoot') != root_path:
            raise ValueError('report scratch root differs before cleanup')
        if isolation.get('preferencesPrefix') != OWNED_PREFERENCE_PREFIX:
            raise ValueError('report preference namespace differs before cleanup')
        if cleanup.get('scratchRoot') != root_path:
            raise ValueError('cleanup scratch root differs before cleanup')
        if cleanup.get('reportPath') != root_path + '/field-oracle.json':
            raise ValueError('cleanup report path differs before cleanup')
        artifact_apk = artifact.get('apkSha256')
        if not isinstance(artifact_apk, str) or not re.fullmatch(r'[0-9a-f]{64}', artifact_apk):
            raise ValueError('artifact APK digest is malformed before cleanup')
        if artifact_apk != isolation.get('harnessApkSha256'):
            raise ValueError('artifact APK differs before cleanup')
        if owner.get('fixtureId') != FIELDS_02:
            raise ValueError('owner family differs before cleanup')
        if _require_int(owner.get('corpusVersion'), 'owner.corpusVersion') != 1:
            raise ValueError('owner corpus version differs before cleanup')
        if owner.get('targetPackage') != target_package or owner.get('harnessPackage') != PACKAGE:
            raise ValueError('owner package binding differs before cleanup')
        if owner.get('targetApkSha256') != isolation.get('targetApkSha256'):
            raise ValueError('owner target APK differs before cleanup')
        if owner.get('harnessApkSha256') != isolation.get('harnessApkSha256'):
            raise ValueError('owner harness APK differs before cleanup')
        if owner.get('corpusSha256Lf') != isolation.get('corpusSha256Lf'):
            raise ValueError('owner corpus differs before cleanup')
        if not isinstance(artifact, dict):
            raise ValueError('artifact receipt is missing before cleanup')
        provenance = artifact.get('provenance')
        if not isinstance(provenance, dict):
            raise ValueError('artifact provenance is incomplete before cleanup')
        if _require_int(provenance.get('schemaVersion'), 'artifact.provenance.schemaVersion') != 1:
            raise ValueError('artifact provenance schema differs before cleanup')
        if provenance.get('fixtureId') != FIELDS_02:
            raise ValueError('artifact provenance family differs before cleanup')
        _admit_source_hashes(provenance.get('sources'),
                             'artifact before cleanup', current_only=True,
                             selected=selected_reference)
        pcorpus = _required_map(provenance, 'corpus', 'artifact.provenance')
        manifest_corpus = manifest.get('corpus') or {}
        if pcorpus.get('asset') != 'field-fixtures.json' or pcorpus.get('fixtureId') != FIELDS_02:
            raise ValueError('artifact corpus identity differs before cleanup')
        if _require_int(pcorpus.get('corpusVersion'), 'artifact.provenance.corpus.corpusVersion') != 1:
            raise ValueError('artifact corpus version differs before cleanup')
        if _require_int(pcorpus.get('bytes'), 'artifact.provenance.corpus.bytes') != _require_int(manifest_corpus.get('bytes'), 'manifest.corpus.bytes'):
            raise ValueError('artifact corpus differs before cleanup')
        for field in ['sha256', 'sha256Lf']:
            value = pcorpus.get(field)
            if not isinstance(value, str) or not re.fullmatch(r'[0-9a-f]{64}', value) or value != manifest_corpus.get(field):
                raise ValueError('artifact corpus digest differs before cleanup')
        if pcorpus.get('sha256Lf') != isolation.get('corpusSha256Lf'):
            raise ValueError('artifact corpus LF differs before cleanup')
        probe = isolation.get('preferenceProbe') or {}
        if probe.get('name') != OWNED_PREFERENCE_PREFIX + 'probe':
            raise ValueError('preference probe identity differs before cleanup')
        if probe.get('installationFile') is not False or any(probe.get(flag) is not True for flag in ['registered', 'committed', 'scopedFile']):
            raise ValueError('preference probe is not proven scratch-scoped before cleanup')
        if cleanup.get('ownerComplete') is not True or cleanup.get('rootRetained') is not True:
            raise ValueError('the harness did not retain a completed owner scratch root')
        if cleanup.get('preferencesFenced') is not True:
            raise ValueError('the harness did not fence owned preferences')
        owner_run_id = cleanup.get('ownerRunId')
        if not isinstance(owner_run_id, str) or not owner_run_id:
            raise ValueError('the harness did not publish an owner attempt id')
        if owner.get('seedRunId') != owner_run_id or owner.get('complete') is not True:
            raise ValueError('the scratch owner does not bind this attempt')
        if _require_int(owner.get('seedPid'), 'owner.seedPid') <= 0:
            raise ValueError('the owner seed PID must be positive')
        owner_prefs = _admit_owner_inventories(
            owner.get('preferences'), cleanup.get('ownedPreferences'))

        stop_owned_target(owner)
        for index, name in enumerate(owner_prefs, 1):
            path = pref_dir + '/' + name + '.xml'
            removed = remote_script('scratch-remove-' + str(index),
                                    'rm -f -- ' + shlex.quote(path),
                                    checked=False)
            if removed.returncode != 0:
                raise ValueError('could not remove the exact owned preference: ' + name)
            if selected_reference:
                _selected_silent(removed, 'selected preference removal')
        root_removed = remote_script('scratch-remove-root',
                                     'rm -rf -- ' + shlex.quote(root_path),
                                     checked=False)
        if root_removed.returncode != 0:
            raise ValueError('could not remove the owned scratch root')
        if selected_reference:
            _selected_silent(root_removed, 'selected scratch root removal')
        for index, name in enumerate(owner_prefs, 1):
            path = pref_dir + '/' + name + '.xml'
            absent = remote_script('scratch-absent-' + str(index),
                                   'test ! -e ' + shlex.quote(path),
                                   checked=False)
            if absent.returncode != 0:
                raise ValueError('owned preference survived cleanup: ' + name)
            if selected_reference:
                _selected_silent(absent, 'selected preference absence')
        root_absent = remote_script('scratch-absent-root',
                                    'test ! -e ' + shlex.quote(root_path),
                                    checked=False)
        if root_absent.returncode != 0:
            raise ValueError('owned scratch root survived cleanup')
        if selected_reference:
            _selected_silent(root_absent, 'selected scratch root absence')
        return {
            'reportedOwnedPreferences': list(owner_prefs),
            'ownerRunId': owner_run_id,
            'root': root_path,
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
        if selected_reference:
            if manifest['sdk'] != '37':
                raise ValueError('selected device API differs')
            webview = adb('webview', 'shell', 'dumpsys', 'webviewupdate').stdout.decode(errors='strict')
            _require_selected_webview(webview)
        baseline = adb(
            'baseline-path', 'shell', 'pm', 'path', target_package).stdout.decode().strip()
        if selected_reference and not re.fullmatch(r'package:[^\r\n]+', baseline):
            raise ValueError('installed target APK path is ambiguous')
        frozen_apk = args.output / 'frozen.apk' if selected_reference else scratch / 'frozen.apk'
        adb('pull-baseline', 'pull', baseline.removeprefix('package:'), str(frozen_apk))
        manifest['baselineApkSha256'] = sha256(frozen_apk)
        if manifest['baselineApkSha256'] != expected_apk:
            raise ValueError('installed baseline APK differs')
        existing = adb('harness-existing', 'shell', 'pm', 'list', 'packages',
                       PACKAGE, checked=False)
        if _package_is_present(existing, PACKAGE, 'harness-existing'):
            raise ValueError('harness package already exists; do not replace unowned install')
        target_private_root = None
        if fields_02:
            # A preexisting namespace is owned by someone else and is never
            # cleaned, replaced, or wildcard-deleted by this driver.
            target_private_root = preflight_fields_02()
            manifest['targetPrivateRoot'] = target_private_root
        # Only hashes/paths leave the device; no private content is copied.
        if fields_02:
            snapshot_script = _fields_snapshot_script(target_private_root)
            before = remote_script('private-before', snapshot_script)
        else:
            snapshot = "'find databases shared_prefs files -type f -exec sha256sum {} \\; 2>/dev/null'"
            before = adb('private-before', 'shell', 'run-as', 'io.legado.app.debug',
                         'sh', '-c', snapshot)
        installed_result = adb('install', 'install', '-r', str(args.apk), checked=False,
                               timeout=180)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            if fields_02:
                partial = adb('partial-harness', 'shell', 'pm', 'list', 'packages',
                              PACKAGE, checked=False)
                try:
                    partial_present = _package_is_present(
                        partial, PACKAGE, 'partial-harness')
                except ValueError as error:
                    manifest['status'] = 'failed'
                    manifest['error'] = ('install returned nonzero and package state is '
                                         'ambiguous; preserving it for inspection: '
                                         + str(error))
                else:
                    if partial_present:
                        manifest['status'] = 'failed'
                        manifest['error'] = ('install returned nonzero and package state is '
                                             'ambiguous; preserving it for inspection')
            return 2 if manifest['status'] == 'blocked' else 1
        installed = True
        if selected_reference:
            _require_selected_success(installed_result.stdout + installed_result.stderr, 'install')
            installed_path = adb('installed-harness-path', 'shell', 'pm', 'path', PACKAGE).stdout.decode().strip()
            if not re.fullmatch(r'package:[^\r\n]+', installed_path):
                raise ValueError('installed harness path is malformed')
            adb('installed-harness-pull', 'pull', installed_path.removeprefix('package:'),
                str(args.output / 'installed-harness.apk'))
            if sha256(args.output / 'installed-harness.apk') != manifest['harnessApkSha256']:
                raise ValueError('installed harness APK differs')
        if not selected_reference:
            adb('logcat-clear', 'logcat', '-c', checked=False)
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     INSTRUMENTATION, timeout=240)
        manifest['run'] = {'result': result.stdout.decode(errors='replace').strip()}
        logcat = adb('logcat-field-oracle', 'logcat', '-d', '-s', 'FieldOracle', checked=False)
        (args.output / 'logcat.log').write_bytes(logcat.stdout)
        if fields_02:
            # The harness leaves its owned scratch root and owner manifest in the
            # target cache for this external driver. Read the report/owner while
            # the owned process is alive; cleanup validates that exact owner and
            # its PID before it stops anything.
            report_path = target_private_root + '/cache/liber-fields-02/field-oracle.json'
            owner_path = target_private_root + '/cache/liber-fields-02/owner.json'
            pulled = adb('pull-report', 'exec-out', 'run-as', target_package,
                         'cat', report_path, checked=False)
            if pulled.returncode:
                raise ValueError('the device reported no oracle report')
            (args.output / 'field-oracle.json').write_bytes(pulled.stdout)
            owner_result = adb('scratch-owner', 'exec-out', 'run-as', target_package,
                               'cat', owner_path, checked=False)
            if owner_result.returncode:
                raise ValueError('the outer driver could not read the scratch owner manifest')
            manifest['scratchOwner'] = json.loads(owner_result.stdout)
            report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
            manifest['scratchCleanup'] = cleanup_fields_02(
                report, manifest['scratchOwner'], manifest)
            uninstalled = adb('remove-harness', 'uninstall', PACKAGE, checked=False)
            if uninstalled.returncode:
                raise ValueError('the owned harness could not be uninstalled')
            if selected_reference:
                _require_selected_success(uninstalled.stdout + uninstalled.stderr, 'uninstall')
                remaining = adb('harness-removed-check', 'shell', 'pm', 'list', 'packages',
                                PACKAGE, checked=False)
                if _package_is_present(remaining, PACKAGE, 'harness-removed-check'):
                    raise ValueError('the owned harness remains installed')
            installed = False
            before = (args.output / 'private-before.log').read_bytes()
            after = remote_script('private-after', snapshot_script).stdout
            finalize(args.output, fixture, manifest, report, before, after,
                     asset=args.asset, scratch_cleanup=manifest['scratchCleanup'],
                     fixture_bytes=corpus_bytes, report_bytes=pulled.stdout,
                     original_apk=args.apk)
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
            # Only our installed harness. No wildcard deletion or unowned data
            # cleanup: ambiguous remnants are preserved and reported. FIELDS-02
            # never stops or removes anything here; its cleanup path proves the
            # owner first, and a failed/ambiguous run leaves the harness in
            # place for inspection.
            if not fields_02:
                adb('stop-owned-run', 'shell', 'am', 'force-stop',
                    'io.legado.app.debug', checked=False)
                adb('remove-harness', 'uninstall', PACKAGE, checked=False)
        (args.output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'],
                          'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
