import base64
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
import zipfile
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('html_capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureReceiptsTest(unittest.TestCase):
    def test_success_must_not_mask_android_failure_or_timeout(self):
        capture.require_success(b'Performing Streamed Install\nSuccess\n')
        for output in (b'Success\nFailure [INSTALL_FAILED]\n', b'Success\nnotice: Failure [bad]\n',
                       b'Success\nTIMED OUT\n', b'progress\n'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                capture.require_success(output)

    def test_instrumentation_requires_unique_success_payload(self):
        payload = b'HTML_ORACLE_BASE64=e30=\nINSTRUMENTATION_CODE: -1\n'
        self.assertEqual(capture.instrumentation_payload(payload), {})
        duplicate = b'HTML_ORACLE_BASE64=' + base64.b64encode(b'{"failure":"bad","failure":null}') + b'\nINSTRUMENTATION_CODE: -1\n'
        for output in (payload + payload, duplicate, payload + b'TIMED OUT\n', payload + b'Failure [bad]\n',
                       payload + b'INSTRUMENTATION_FAILED: bad\n', payload + b'INSTRUMENTATION_STATUS_CODE: -2\n',
                       payload + b'INSTRUMENTATION_RESULT: shortMsg=Process crashed\n',
                       b'HTML_ORACLE_BASE64=e30=\nINSTRUMENTATION_CODE: 1\n'):
            with self.subTest(output=output), self.assertRaises(ValueError):
                capture.instrumentation_payload(output)

    def test_synthetic_complete_bundle_and_mixed_receipt_rejections(self):
        # This is a synthetic mechanics control, not a native observation or golden.
        fixture = json.loads(Path(__file__).with_name('list-fixtures-selected.json').read_bytes())
        real_apk = os.environ.get('LIBER_HTML_SYNTHETIC_APK')
        if real_apk:
            fake_target = Path(os.environ['LIBER_HTML_SYNTHETIC_TARGET']).read_bytes()
            fake_harness = Path(real_apk).read_bytes()
            binding = capture.preflight(
                Path(real_apk), Path(__file__).with_name('list-fixtures-selected.json'),
                Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/source'),
                Path('C:/Users/17945/AppData/Local/Android/Sdk'),
                Path('C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8'))
        else:
            fake_target, fake_harness = b'synthetic target', b'synthetic harness'
            binding = {'corpusSha256': 'a' * 64, 'corpusBytes': 101, 'harnessApkSha256': capture.digest(fake_harness),
                       'provenanceSha256': 'b' * 64, 'provenance': {'synthetic': True}}
        target_sha = capture.digest(fake_target)
        terminal = {'owner': 'Coroutine.DEFAULT Job', 'observedChildren': 0, 'allCompleted': True,
                    'rootEmpty': True, 'launchAttempts': 0}
        registered = ['liber_html_selected_html_probe']
        target_path, harness_path = '/data/app/target/base.apk', '/data/app/harness/base.apk'
        report = {
            'baselineCommit': capture.BASELINE, 'entryPoint': fixture['entryPoint'], 'fingerprint': capture.FINGERPRINT,
            'corpus': {'asset': 'html-fixtures.json', 'bytes': binding['corpusBytes'], 'sha256': binding['corpusSha256'],
                       'fixtureId': fixture['fixtureId'], 'corpusVersion': 1, 'schemaVersion': 1},
            'identity': {'fixtureId': fixture['fixtureId'], 'corpusVersion': 1, 'targetPackage': capture.TARGET,
                         'targetApkSha256': target_sha, 'targetApkPath': target_path,
                         'harnessPackage': capture.PACKAGE, 'harnessApkPath': harness_path,
                         'harnessApkSha256': binding['harnessApkSha256'], 'corpusAssetSha256': binding['corpusSha256'],
                         'corpusSha256Lf': binding['corpusSha256'], 'provenanceAssetSha256': binding['provenanceSha256']},
            'provenance': binding['provenance'],
            'startupContainment': {'service': 'shortcut', 'provider': 'io.legado.app.api.ReaderProvider',
                                   'intercepted': 1, 'handled': 1, 'beforeBinding': True},
            'isolation': {'verified': True, 'application': 'io.liber.oracle.nested.GuardedReaderApplication',
                          'scratchRoot': '/data/user/0/com.legado.app.debug/cache/liber-html-selected',
                          'preferenceProbe': {'name': 'liber_html_selected_html_probe', 'registered': True,
                                              'committed': True, 'scopedFile': True, 'installationFile': False}},
            'hostInitialization': {'verified': True, 'applicationAttached': False, 'invokedOn': 'unattached-instance',
                                   'notRun': ['io.legado.app.App.onCreate'], 'method': fixture['hostInitialization']['method'],
                                   'registeredWrappers': {r['type']: r['factory'] for r in fixture['hostInitialization']['registrations']}},
            'entryPoints': {'constructor': 'AnalyzeRule(io.legado.app.model.analyzeRule.RuleDataInterface,io.legado.app.data.entities.BaseSource,boolean,boolean)',
                            'setContent': 'setContent(java.lang.Object,java.lang.String)',
                            'getString': 'getString(java.lang.String,java.lang.Object,boolean)',
                            'getStringList': 'getStringList(java.lang.String,java.lang.Object,boolean)'},
            'terminalOwner': {'scope': 'Coroutine.DEFAULT', 'rootActive': True, 'rootCompleted': False,
                              'baselineChildren': 0, 'childrenMethod': 'kotlinx.coroutines.Job.getChildren()',
                              'completionMethod': 'kotlinx.coroutines.Job.isCompleted()'},
            'observations': [{'id': c['id'], 'value': c['expected'], 'terminal': terminal} for c in fixture['cases']],
            'cleanup': {'databaseClosed': True, 'terminalProved': True, 'activityLaunchAttempts': 0,
                        'scratchRemoved': True, 'scratchRetained': False, 'registeredPreferences': registered,
                        'preferencesRemoved': [{'name': registered[0], 'ok': True}]},
        }
        snapshot = "'find . -type f -exec sha256sum {} \\; 2>/dev/null'"
        snapshot_bytes = (('f' * 64) + '  files/original\n').encode()
        instrumentation = b'HTML_ORACLE_BASE64=' + base64.b64encode(json.dumps(report).encode()) + b'\nINSTRUMENTATION_CODE: -1\n'
        entries = [
            ('fingerprint', ['shell', 'getprop', 'ro.build.fingerprint'], (capture.FINGERPRINT + '\n').encode()),
            ('api', ['shell', 'getprop', 'ro.build.version.sdk'], b'37\n'),
            ('webview', ['shell', 'dumpsys', 'webviewupdate'], b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n'),
            ('target-path', ['shell', 'pm', 'path', capture.TARGET], ('package:' + target_path + '\n').encode()),
            ('target-pull', ['pull', target_path, 'C:/synthetic/frozen.apk'], b'1 file pulled\n'),
            ('harness-before', ['shell', 'pm', 'list', 'packages', capture.PACKAGE], b''),
            ('private-before', ['shell', 'run-as', capture.TARGET, 'sh', '-c', snapshot], snapshot_bytes),
            ('install', ['install', '-r', 'C:/synthetic/html-oracle.apk'], b'Performing Streamed Install\nSuccess\n'),
            ('installed-path', ['shell', 'pm', 'path', capture.PACKAGE], ('package:' + harness_path + '\n').encode()),
            ('installed-pull', ['pull', harness_path, 'C:/synthetic/installed-harness.apk'], b'1 file pulled\n'),
            ('instrumentation', ['shell', 'am', 'instrument', '-w', '-r', capture.PACKAGE + '/' + capture.ENTRY], instrumentation),
            ('private-after', ['shell', 'run-as', capture.TARGET, 'sh', '-c', snapshot], snapshot_bytes),
            ('stop-owned-run', ['shell', 'am', 'force-stop', capture.TARGET], b''),
            ('target-stopped-check', ['shell', 'sh', '-c', "'if ! command -v pidof >/dev/null; then echo ERROR; elif pidof com.legado.app.debug >/dev/null; then echo PRESENT; else echo ABSENT; fi'"], b'ABSENT\n'),
            ('scratch-removed-check', ['shell', 'run-as', capture.TARGET, 'sh', '-c', "'if test -e cache/liber-html-selected; then echo PRESENT; else echo ABSENT; fi'"], b'ABSENT\n'),
            ('remove-harness', ['uninstall', capture.PACKAGE], b'Success\n'),
            ('harness-removed-check', ['shell', 'pm', 'list', 'packages', capture.PACKAGE], b''),
            ('private-final', ['shell', 'run-as', capture.TARGET, 'sh', '-c', snapshot], snapshot_bytes),
        ]
        with tempfile.TemporaryDirectory(prefix='html-synthetic-') as temporary, patch.object(capture, 'TARGET_SHA', target_sha):
            root = Path(temporary)
            (root / 'frozen.apk').write_bytes(fake_target)
            (root / 'installed-harness.apk').write_bytes(fake_harness)
            (root / 'observation.json').write_text(json.dumps(report), encoding='utf-8')
            commands = []
            for name, args, output in entries:
                (root / (name + '.log')).write_bytes(output)
                commands.append({'name': name, 'command': ['adb', '-s', '5615f742'] + args,
                                 'exitCode': 0, 'log': name + '.log', 'sha256': capture.digest(output)})
            manifest = {'status': 'observed', 'serial': '5615f742',
                        'preflight': json.loads(json.dumps(binding)), 'commands': commands}
            def save():
                (root / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
            save()
            self.assertEqual(capture.verify_bundle(root, fixture, binding), report)
            if real_apk:
                # Full gate control is synthetic. Its temporary pass proves mechanics only.
                dart = os.environ.get('LIBER_DART', 'C:/Users/17945/fvm/default/bin/cache/dart-sdk/bin/dart.exe')
                args = [dart, 'run', 'tool/html_adapter_gate.dart', os.environ['LIBER_FJS_LIBRARY'],
                        str(root / 'observation.json'), str(root / 'gate-report.json'),
                        'tool/html_oracle/list-fixtures-selected.json']
                result = subprocess.run(args, capture_output=True, timeout=180)
                self.assertEqual(result.returncode, 0, result.stderr.decode(errors='replace'))
                self.assertEqual(json.loads((root / 'gate-report.json').read_text(encoding='utf-8'))['status'], 'pass')
                (root / 'gate-report.json').unlink()
                report['observations'][0]['value'] = ['/synthetic-mismatch']
                (root / 'observation.json').write_text(json.dumps(report), encoding='utf-8')
                altered = b'HTML_ORACLE_BASE64=' + base64.b64encode(json.dumps(report).encode()) + b'\nINSTRUMENTATION_CODE: -1\n'
                (root / 'instrumentation.log').write_bytes(altered)
                row = next(r for r in commands if r['name'] == 'instrumentation')
                row['sha256'] = capture.digest(altered); save()
                result = subprocess.run(args, capture_output=True, timeout=180)
                self.assertEqual(result.returncode, 1, result.stderr.decode(errors='replace'))
                self.assertEqual(json.loads((root / 'gate-report.json').read_text(encoding='utf-8'))['status'], 'fail')
                report['observations'][0]['value'] = fixture['cases'][0]['expected']
                (root / 'observation.json').write_text(json.dumps(report), encoding='utf-8')
                (root / 'instrumentation.log').write_bytes(instrumentation)
                row['sha256'] = capture.digest(instrumentation); save()
            for name, suffix in [('install', b'Failure [INSTALL_FAILED]\n'), ('remove-harness', b'TIMED OUT\n'),
                                 ('instrumentation', instrumentation), ('private-after', b'not-a-hash\n'),
                                 ('private-final', b'not-a-hash\n')]:
                with self.subTest(name=name):
                    file = root / (name + '.log')
                    original = file.read_bytes()
                    file.write_bytes(original + suffix)
                    row = next(r for r in commands if r['name'] == name)
                    old_hash = row['sha256']; row['sha256'] = capture.digest(file.read_bytes()); save()
                    with self.assertRaises(ValueError):
                        capture.verify_bundle(root, fixture, binding)
                    file.write_bytes(original); row['sha256'] = old_hash; save()
            for damage in ('failed-status', 'missing-command', 'failed-command', 'wrong-command', 'wrong-binding'):
                with self.subTest(damage=damage):
                    original = json.loads(json.dumps(manifest))
                    if damage == 'failed-status':
                        manifest['status'] = 'failed'
                    elif damage == 'missing-command':
                        manifest['commands'].pop()
                    elif damage == 'failed-command':
                        manifest['commands'][0]['exitCode'] = 1
                    elif damage == 'wrong-command':
                        manifest['commands'][0]['command'][-1] = 'different.property'
                    else:
                        manifest['preflight']['harnessApkSha256'] = '0' * 64
                    save()
                    with self.assertRaises(ValueError):
                        capture.verify_bundle(root, fixture, binding)
                    manifest.clear(); manifest.update(original)
                    # Restore shared command/binding objects used by other controls.
                    commands = manifest['commands']
                    manifest['preflight'] = json.loads(json.dumps(binding))
                    save()
            for damage in ('missing-row', 'duplicate-id', 'ambiguous-outcome', 'wrong-value-type',
                           'unfinished-child', 'database-open', 'wrong-environment', 'wrong-provenance',
                           'boolean-version', 'boolean-launch-count'):
                with self.subTest(damage=damage):
                    broken = json.loads(json.dumps(report))
                    if damage == 'missing-row':
                        broken['observations'].pop()
                    elif damage == 'duplicate-id':
                        broken['observations'][1]['id'] = broken['observations'][0]['id']
                    elif damage == 'ambiguous-outcome':
                        broken['observations'][0]['error'] = 'synthetic error'
                    elif damage == 'wrong-value-type':
                        broken['observations'][0]['value'] = 'scalar, not list'
                    elif damage == 'unfinished-child':
                        broken['observations'][0]['terminal']['allCompleted'] = False
                    elif damage == 'database-open':
                        broken['cleanup']['databaseClosed'] = False
                    elif damage == 'wrong-environment':
                        broken['fingerprint'] = 'another fingerprint'
                    elif damage == 'boolean-version':
                        broken['corpus']['corpusVersion'] = True
                    elif damage == 'boolean-launch-count':
                        broken['cleanup']['activityLaunchAttempts'] = False
                    else:
                        broken['provenance'] = {}
                    with self.assertRaises(ValueError):
                        capture.validate_observation(fixture, broken, binding)

    def test_real_preflight_rejects_wrong_corpus_target_and_missing_provenance(self):
        selected_apk = os.environ.get('LIBER_HTML_SYNTHETIC_APK')
        if not selected_apk:
            self.skipTest('requires the locally built selected APK')
        source = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/source')
        sdk = Path('C:/Users/17945/AppData/Local/Android/Sdk')
        java = Path('C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8')
        tools = sdk / 'build-tools/35.0.1'
        corpus = Path(__file__).with_name('list-fixtures-selected.json')
        with self.assertRaisesRegex(ValueError, 'packaged selected corpus differs'):
            capture.preflight(Path(selected_apk), Path(__file__).with_name('fixtures-selected.json'), source, sdk, java)
        with tempfile.TemporaryDirectory(prefix='html-negative-apk-') as temporary:
            root = Path(temporary)
            with zipfile.ZipFile(selected_apk) as apk:
                assets = {'html-fixtures.json': apk.read('assets/html-fixtures.json'),
                          'provenance.json': apk.read('assets/provenance.json')}
                dex = apk.read('classes.dex')
            (root / 'dex').mkdir(); (root / 'dex/classes.dex').write_bytes(dex)
            manifest = Path(__file__).with_name('AndroidManifest-selected.xml').read_text(encoding='utf-8')
            key = Path(os.environ['USERPROFILE']) / '.android/debug.keystore'
            for name, bad_target, missing in [('wrong-target', True, False), ('missing-provenance', False, True)]:
                with self.subTest(name=name):
                    work = root / name; work.mkdir(); (work / 'assets').mkdir()
                    for filename, data in assets.items():
                        if not (missing and filename == 'provenance.json'):
                            (work / 'assets' / filename).write_bytes(data)
                    xml = manifest.replace('com.legado.app.debug', 'com.legado.app.wrong') if bad_target else manifest
                    (work / 'AndroidManifest.xml').write_text(xml, encoding='utf-8')
                    capture.run_checked([tools / 'aapt.exe', 'package', '-f', '-M', work / 'AndroidManifest.xml',
                                         '-I', sdk / 'platforms/android-35/android.jar', '-A', work / 'assets',
                                         '-F', work / 'unsigned.apk'])
                    capture.run_checked([java / 'bin/jar.exe', 'uf', work / 'unsigned.apk', '-C', root / 'dex', 'classes.dex'])
                    capture.run_checked([tools / 'zipalign.exe', '-p', '4', work / 'unsigned.apk', work / 'aligned.apk'])
                    capture.run_checked([java / 'bin/java.exe', '-jar', tools / 'lib/apksigner.jar', 'sign',
                                         '--ks', key, '--ks-key-alias', 'androiddebugkey', '--ks-pass', 'pass:android',
                                         '--key-pass', 'pass:android', '--out', work / 'negative.apk', work / 'aligned.apk'])
                    message = 'manifest package, entry or target differs' if bad_target else 'missing or duplicated selected APK member'
                    with self.assertRaisesRegex(ValueError, message):
                        capture.preflight(work / 'negative.apk', corpus, source, sdk, java)


if __name__ == '__main__':
    unittest.main()
