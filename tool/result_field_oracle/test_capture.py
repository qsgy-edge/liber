"""Small stdlib regressions for the FIELDS-02 capture boundary."""
import io
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402

ACTUAL_OWNER_PREFERENCES = [
    'liber_fields_02_FirebasePerfSharedPrefs',
    'liber_fields_02_probe',
    'liber_fields_02_FirebaseHeartBeatW0RFRkFVTFRd+MTo0NTMzOTIyNzQ3OTA6YW5kcm9pZDpjNGVhYzE0YjE0MTBlZWM1ZjYyNGE3',
    'liber_fields_02_frc_1:453392274790:android:c4eac14b1410eec5f624a7_firebase_settings',
    'liber_fields_02_com.google.android.gms.measurement.prefs',
    'liber_fields_02_io.legado.app.debug_preferences',
    'liber_fields_02_com.google.android.gms.appid',
]

def _shell_path():
    import shutil
    found = shutil.which('sh')
    if found:
        return found
    for candidate in (
            r'C:/Program Files/Git/usr/bin/sh.exe',
            r'C:/Program Files/Git/bin/sh.exe'):
        if Path(candidate).is_file():
            return candidate
    raise unittest.SkipTest('existing Git/POSIX sh is unavailable for formatter control')


def _complete_fixture_context():
    """Find a bounded installed shell/tool/runtime context for test fixtures."""
    import shutil
    candidates = [
        Path(_shell_path()).parent,
        Path(r'C:/Program Files/Git/usr/bin'),
        Path(r'C:/Program Files/Git/bin'),
    ]
    for command in ('sh', 'find', 'sha256sum', 'od', 'tr'):
        found = shutil.which(command)
        if found:
            candidates.append(Path(found).parent)
    suffix = '.exe' if os.name == 'nt' else ''
    for directory in candidates:
        if (all((directory / (name + suffix)).is_file()
                for name in ('sh', 'find', 'sha256sum', 'od', 'tr'))
                and (directory / 'msys-2.0.dll').is_file()):
            return directory
    raise unittest.SkipTest('complete installed shell/tool/runtime context unavailable')


def _child_environment(shell, env_overrides=None):
    import shutil
    environment = os.environ.copy()
    if env_overrides:
        environment.update(env_overrides)
    if os.name == 'nt':
        base = environment.get('PATH', '')
        dirs = [Path(shell).parent]
        for command in ('od', 'tr'):
            found = shutil.which(command, path=base)
            if found:
                candidate = Path(found).parent
                if candidate not in dirs:
                    dirs.append(candidate)
        environment['PATH'] = os.pathsep.join(
            [*(str(directory) for directory in dirs), base]
        )
    return environment


def _resolved_tool(command, shell, environment=None):
    import shutil
    if environment is None:
        environment = _child_environment(shell)
    found = shutil.which(command, path=environment.get('PATH', ''))
    if found:
        return Path(found)
    candidate = Path(shell).parent / (command + ('.exe' if os.name == 'nt' else ''))
    return candidate


def _run_snapshot_formatter(root, extra_path=None, env_overrides=None):
    shell = _shell_path()
    environment = _child_environment(shell, env_overrides)
    if extra_path is not None:
        environment['PATH'] = (
            str(extra_path) + os.pathsep + environment.get('PATH', '')
        )
    return subprocess.run(
        [shell, '-c', capture._fields_snapshot_script(str(root))],
        capture_output=True, env=environment)


def _snapshot_line(kind, path, digest='-'):
    return kind + chr(9) + digest + chr(9) + path.encode().hex() + chr(10)


def _snapshot_bytes(files, dirs):
    return (''.join(_snapshot_line('F', p if p == '.' else './' + p, 'a' * 64) for p in files)
            + ''.join(_snapshot_line('D', p if p == '.' else './' + p) for p in dirs)).encode()



class SelectedCorpusTest(unittest.TestCase):
    def test_selected_preflight_accepts_exact_chapter_corpora_only(self):
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        here = Path(__file__).resolve().parent
        for name in ('chapter-lifecycle-fixtures-selected.json', 'chapter-relative-fixtures-selected.json',
                     'chapter-identity-fixtures-selected.json'):
            with self.subTest(corpus=name), patch.object(capture.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['probe'], 120)) as run:
                with self.assertRaises(subprocess.TimeoutExpired):
                    capture.selected_preflight(Path('unused.apk'), target, here / name, Path('source'), Path('sdk'), Path('java'))
                self.assertEqual(run.call_count, 1)
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'altered.json'
            altered.write_bytes((here / 'chapter-lifecycle-fixtures-selected.json').read_bytes() + b' ')
            with patch.object(capture.subprocess, 'run') as run, self.assertRaisesRegex(ValueError, 'corpus raw bytes'):
                capture.selected_preflight(Path('unused.apk'), target, altered, Path('source'), Path('sdk'), Path('java'))
            run.assert_not_called()

    def test_selected_preflight_accepts_reader_followthrough_corpus(self):
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        here = Path(__file__).resolve().parent
        fixture = here / 'reader-followthrough-fixtures-selected.json'
        with patch.object(capture.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['probe'], 120)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                capture.selected_preflight(Path('unused.apk'), target, fixture, Path('source'), Path('sdk'), Path('java'))
            self.assertEqual(run.call_count, 1)
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'altered.json'
            altered.write_bytes(fixture.read_bytes() + b' ')
            with patch.object(capture.subprocess, 'run') as run, self.assertRaisesRegex(ValueError, 'corpus raw bytes'):
                capture.selected_preflight(Path('unused.apk'), target, altered, Path('source'), Path('sdk'), Path('java'))
            run.assert_not_called()

    def test_selected_preflight_accepts_json_replace_corpus(self):
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        here = Path(__file__).resolve().parent
        fixture = here / 'reader-json-replace-fixtures-selected.json'
        with patch.object(capture.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['probe'], 120)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                capture.selected_preflight(Path('unused.apk'), target, fixture, Path('source'), Path('sdk'), Path('java'))
            self.assertEqual(run.call_count, 1)
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'altered.json'
            altered.write_bytes(fixture.read_bytes() + b' ')
            with patch.object(capture.subprocess, 'run') as run, self.assertRaisesRegex(ValueError, 'corpus raw bytes'):
                capture.selected_preflight(Path('unused.apk'), target, altered, Path('source'), Path('sdk'), Path('java'))
            run.assert_not_called()

    def test_selected_preflight_accepts_title_lifecycle_corpus(self):
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        here = Path(__file__).resolve().parent
        fixture = here / 'reader-title-lifecycle-fixtures-selected.json'
        with patch.object(capture.subprocess, 'run', side_effect=subprocess.TimeoutExpired(['probe'], 120)) as run:
            with self.assertRaises(subprocess.TimeoutExpired):
                capture.selected_preflight(Path('unused.apk'), target, fixture, Path('source'), Path('sdk'), Path('java'))
            self.assertEqual(run.call_count, 1)
        with tempfile.TemporaryDirectory() as directory:
            altered = Path(directory) / 'altered.json'
            altered.write_bytes(fixture.read_bytes() + b' ')
            with patch.object(capture.subprocess, 'run') as run, self.assertRaisesRegex(ValueError, 'corpus raw bytes'):
                capture.selected_preflight(Path('unused.apk'), target, altered, Path('source'), Path('sdk'), Path('java'))
            run.assert_not_called()

    def test_selected_chapter_raw_query_uses_declared_wire_bytes(self):
        self.assertEqual(capture._canonical_raw_query({'query': {'q': '��'}, 'rawQuery': 'q=%D6%D0'}), 'q=%D6%D0')
        self.assertEqual(capture._canonical_raw_query({'query': {'q': '中'}}), 'q=%E4%B8%AD')

    def test_selected_preflight_timeout_retains_attempt_and_partial_streams(self):
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            timeout = subprocess.TimeoutExpired(['injected'], 120, output=b'partial-out\n', stderr=b'partial-err\n')
            with patch.object(capture.subprocess, 'run', side_effect=timeout) as run:
                with self.assertRaises(subprocess.TimeoutExpired):
                    capture.selected_preflight(Path('unused.apk'), target, fixture, Path('source'),
                                               Path('sdk'), Path('java'), evidence=output)
            self.assertEqual(run.call_count, 1)
            records = json.loads((output / 'preflight-commands.json').read_bytes())
            self.assertEqual(records[0]['name'], 'java-version')
            self.assertEqual(records[0]['status'], 'timeout')
            self.assertTrue(records[0]['command'][0].endswith('java.exe'))
            self.assertEqual((output / 'preflight-java-version.stdout.log').read_bytes(), b'partial-out\n')
            self.assertEqual((output / 'preflight-java-version.stderr.log').read_bytes(), b'partial-err\n')

    def test_selected_finalize_nonzero_retains_each_actual_failure_without_retry(self):
        from contextlib import redirect_stderr
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            originals = {'field-oracle.json': b'original report', 'manifest.json': b'original manifest',
                         'preflight-commands.json': b'original ledger'}
            for name, data in originals.items():
                (output / name).write_bytes(data)
            argv = ['capture.py', '--finalize', '--serial', '5615f742', '--fixture', str(fixture),
                    '--apk', 'unused.apk', '--target-apk', str(target), '--frozen-source', 'source',
                    '--java-home', 'java', '--output', str(output)]
            old_files = {}
            failure_files = {}
            for index in range(2):
                stdout, stderr = b'NONZERO-STDOUT-' + bytes([index, 255]), b'NONZERO-STDERR-' + bytes([index, 254])
                result = subprocess.CompletedProcess(['in-memory'], 7, stdout, stderr)
                with patch.object(sys, 'argv', argv), patch.object(capture.subprocess, 'run', return_value=result) as run, redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as failure:
                        capture.main()
                self.assertIn('java-version command failed', str(failure.exception))
                self.assertEqual(run.call_count, 1)
                attempts = list(output.glob('preflight-nonzero-*'))
                self.assertEqual(len(attempts), index + 1)
                latest = next(path for path in attempts if path not in old_files)
                record = json.loads((latest / 'preflight-commands.json').read_bytes())
                self.assertEqual(len(record), 1)
                self.assertEqual(record[0]['command'], run.call_args.args[0])
                self.assertEqual(record[0]['exitCode'], 7)
                self.assertEqual(record[0]['stdoutSha256'], capture.sha256_bytes(stdout))
                self.assertEqual(record[0]['stderrSha256'], capture.sha256_bytes(stderr))
                self.assertEqual((latest / 'preflight-java-version.stdout.log').read_bytes(), stdout)
                self.assertEqual((latest / 'preflight-java-version.stderr.log').read_bytes(), stderr)
                for path, prior in old_files.items():
                    self.assertEqual({p.name: p.read_bytes() for p in path.iterdir()}, prior)
                old_files[latest] = {p.name: p.read_bytes() for p in latest.iterdir()}
                for path, data in failure_files.items():
                    self.assertEqual(path.read_bytes(), data)
                failure_files = {path: path.read_bytes() for path in output.glob('finalize-failure*.json')}
                self.assertEqual(len(failure_files), index + 1)
                for name, data in originals.items():
                    self.assertEqual((output / name).read_bytes(), data)
                self.assertFalse((output / 'golden.json').exists())

    def test_selected_finalize_nonzero_preserves_existing_golden(self):
        from contextlib import redirect_stderr
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            golden = output / 'golden.json'
            golden.write_bytes(b'existing golden')
            argv = ['capture.py', '--finalize', '--serial', '5615f742', '--fixture', str(fixture),
                    '--apk', 'unused.apk', '--target-apk', str(target), '--frozen-source', 'source',
                    '--java-home', 'java', '--output', str(output)]
            failure = subprocess.CompletedProcess(['in-memory'], 7, b'out', b'err')
            with patch.object(sys, 'argv', argv), patch.object(capture.subprocess, 'run', return_value=failure) as run, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    capture.main()
            self.assertEqual(run.call_count, 1)
            self.assertEqual(golden.read_bytes(), b'existing golden')
            self.assertEqual(len(list(output.glob('preflight-nonzero-*'))), 1)

    def test_selected_finalize_semantic_error_does_not_fabricate_receipt(self):
        from contextlib import redirect_stderr
        from unittest.mock import patch
        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            argv = ['capture.py', '--finalize', '--serial', '5615f742', '--fixture', str(fixture),
                    '--apk', 'unused.apk', '--target-apk', 'unused-target.apk', '--frozen-source', 'source',
                    '--java-home', 'java', '--output', str(output)]
            with patch.object(sys, 'argv', argv), patch.object(capture, 'selected_preflight', side_effect=ValueError('semantic mismatch')), redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(SystemExit, 'semantic mismatch'):
                    capture.main()
            self.assertEqual(list(output.glob('preflight-nonzero-*')), [])
            self.assertIn('semantic mismatch', (output / 'finalize-failure.json').read_text(encoding='utf-8'))

    def test_selected_finalize_timeout_retains_partial_streams_without_retry(self):
        import io
        from contextlib import redirect_stderr
        from unittest.mock import patch
        target = Path('C:/Users/17945/AppData/Local/liber-evidence/spec133/phone-resume-20261020-01a15796/controller/team-baseline-migration-01/reference-stage/artifacts/legado-3.26101819-a7d37f1-appDebug-minsdk26.apk')
        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            argv = ['capture.py', '--finalize', '--serial', '5615f742', '--fixture', str(fixture),
                    '--apk', 'unused.apk', '--target-apk', str(target), '--frozen-source', 'source',
                    '--java-home', 'java', '--output', str(output)]
            timeout = subprocess.TimeoutExpired(['injected'], 120, output=b'partial-out\n', stderr=b'partial-err\n')
            with patch.object(sys, 'argv', argv), patch.object(capture.subprocess, 'run', side_effect=timeout) as run, redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    capture.main()
            self.assertEqual(run.call_count, 1)
            attempts = list(output.glob('preflight-timeout-*'))
            self.assertEqual(len(attempts), 1)
            self.assertEqual((attempts[0] / 'preflight-java-version.stdout.log').read_bytes(), b'partial-out\n')
            self.assertEqual((attempts[0] / 'preflight-java-version.stderr.log').read_bytes(), b'partial-err\n')
            self.assertEqual(json.loads((attempts[0] / 'preflight-commands.json').read_bytes())[0]['status'], 'timeout')
            self.assertTrue((output / 'finalize-failure.json').is_file())

    def test_selected_reference_preserves_scenarios_and_changes_only_reference_metadata(self):
        directory = Path(__file__).resolve().parent
        original = json.loads((directory / 'book-url-markers-fixtures.json').read_bytes())
        selected = json.loads((directory / 'book-url-markers-fixtures-selected.json').read_bytes())
        self.assertEqual(selected['baselineCommit'], 'a7d37f1707a70a459ad708f4fe79341d1e42d716')
        self.assertEqual(selected['target']['package'], 'com.legado.app.debug')
        self.assertEqual(selected['target']['apkSha256'],
                         '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5')
        self.assertEqual(len(selected['cases']), 4)
        self.assertEqual(len(selected['expectedRequests']), 12)
        ignored = {'baselineCommit', 'target', 'frozenSources', 'hostInitialization'}
        self.assertEqual({k: v for k, v in original.items() if k not in ignored},
                         {k: v for k, v in selected.items() if k not in ignored})


    def test_selected_reference_cannot_dispatch_legacy_device_path(self):
        directory = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as output:
            result = subprocess.run([
                sys.executable, str(directory / 'capture.py'), '--serial', 'unused',
                '--fixture', str(directory / 'book-url-markers-fixtures-selected.json'),
                '--output', str(Path(output) / 'capture'), '--apk', 'unused.apk',
                '--frozen-source', 'unused-source', '--asset', 'unused-asset',
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('selected capture requires', result.stderr)
            self.assertFalse((Path(output) / 'capture').exists())

    def test_selected_preflight_rejects_missing_target_apk_without_device(self):
        directory = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as output:
            result = subprocess.run([
                sys.executable, str(directory / 'capture.py'), '--preflight-only',
                '--fixture', str(directory / 'book-url-markers-fixtures-selected.json'),
                '--output', str(Path(output) / 'receipt'), '--apk', 'unused.apk',
                '--frozen-source', 'unused-source', '--target-apk', 'missing-target.apk',
                '--java-home', 'unused-java', '--android-sdk', 'unused-sdk',
            ], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('target APK', result.stderr)
            self.assertFalse((Path(output) / 'receipt').exists())

    def test_selected_apk_requires_all_selected_build_sources(self):
        directory = Path(__file__).resolve().parent
        fixture_path = directory / 'book-url-markers-fixtures-selected.json'
        data = fixture_path.read_bytes()
        fixture = json.loads(data)
        sources = capture.harness_source_hashes(selected=True)
        provenance = {'schemaVersion': 1, 'fixtureId': 'FIELDS-02', 'corpus': {
            'asset': 'field-fixtures.json', 'bytes': len(data),
            'sha256': capture.sha256_bytes(data), 'sha256Lf': capture.sha256_bytes(capture.lf_bytes(data)),
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1}, 'sources': sources}
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'synthetic.apk'
            def inspect(provenance):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/field-fixtures.json', data)
                    archive.writestr('assets/field-provenance.json', json.dumps(provenance))
                return capture.inspect_selected_apk(apk, fixture_path, fixture, sources)
            self.assertEqual(inspect(provenance)['provenance']['sources'], sources)
            bad = dict(provenance, sources={k: v for k, v in sources.items()
                                            if k != 'GuardedReaderApplication.java'})
            with self.assertRaisesRegex(ValueError, 'source key set'):
                inspect(bad)

    def test_historical_reference_rejects_the_selected_target(self):
        directory = Path(__file__).resolve().parent
        old = json.loads((directory / 'book-url-markers-fixtures.json').read_bytes())
        old['target'] = dict(capture.SELECTED_TARGET)
        with self.assertRaisesRegex(ValueError, 'target'):
            capture._admit_selected_shape(old, 'fixture')

    def test_selected_manifest_rejects_target_on_unrelated_node(self):
        manifest = '''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    A: package="io.liber.oracle.fields" (Raw: "io.liber.oracle.fields")
    E: instrumentation (line=3)
      A: android:name(0x01010003)="io.liber.oracle.fields.FieldOracle" (Raw: "io.liber.oracle.fields.FieldOracle")
      A: android:targetPackage(0x01010021)="com.legado.app.debug" (Raw: "com.legado.app.debug")
'''
        capture._check_selected_manifest(manifest)
        with self.assertRaisesRegex(ValueError, 'manifest'):
            capture._check_selected_manifest(manifest.replace(
                '      A: android:targetPackage',
                '    E: unrelated (line=4)\n      A: android:targetPackage'))

    def test_selected_command_receipts_reject_wrong_fingerprint_command(self):
        names = ['fingerprint', 'sdk', 'webview', 'baseline-path', 'pull-baseline',
                 'harness-existing', 'target-process', 'target-private-root', 'scratch-root-check',
                 'scratch-prefs-check', 'scratch-installation-probe-check', 'private-before',
                 'install', 'installed-harness-path', 'installed-harness-pull', 'instrumentation',
                 'pull-report', 'scratch-owner', 'owned-pid', 'poststop', 'poststop-check',
                 'scratch-remove-root', 'scratch-absent-root', 'remove-harness',
                 'harness-removed-check', 'private-after']
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            commands = []
            for name in names:
                (output / (name + '.log')).write_bytes(b'')
                commands.append({'log': name + '.log', 'exitCode': 0,
                                 'command': ['adb', '-s', '5615f742', 'shell', 'getprop', 'wrong']})
            with self.assertRaisesRegex(ValueError, 'fingerprint command differs'):
                capture._admit_selected_commands(output, {'serial': '5615f742', 'commands': commands,
                                                          'targetPrivateRoot': '/data/user/0/com.legado.app.debug'},
                                                 b'', b'', b'')

    def test_selected_private_root_rejects_noncanonical_package_paths(self):
        for good in ['/data/user/0/com.legado.app.debug', '/data/data/com.legado.app.debug']:
            self.assertEqual(capture._selected_private_root(good), good)
        for bad in ['/data/other/com.legado.app.debug', '/data/user/0/../com.legado.app.debug',
                    '/data/user//com.legado.app.debug', '/data/user/0/com.legado.app.debug\n',
                    '/data/user/0/com.legado.app.debug/extra']:
            with self.subTest(path=bad), self.assertRaisesRegex(ValueError, 'canonical'):
                capture._selected_private_root(bad)

    def test_selected_webview_must_be_the_current_provider_and_version(self):
        good = 'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n'
        capture._require_selected_webview(good)
        for bad in ('Available: com.google.android.webview 158.0.8127.2\n'
                    'Current WebView package (name, version): (other, 1)\n',
                    good + good):
            with self.assertRaisesRegex(ValueError, 'WebView'):
                capture._require_selected_webview(bad)

    def test_selected_install_and_uninstall_success_must_not_conflict(self):
        capture._require_selected_success(b'Success\n', 'install')
        for receipt in (b'Success\nFailure [INSTALL_FAILED]\n',
                        b'Success\nTIMED OUT\n', b'Success\nSuccess\n', b''):
            with self.assertRaisesRegex(ValueError, 'selected command receipts'):
                capture._require_selected_success(receipt, 'install')

    def test_selected_apk_rejects_rewritten_scenario_bytes(self):
        directory = Path(__file__).resolve().parent
        fixture = json.loads((directory / 'book-url-markers-fixtures-selected.json').read_bytes())
        fixture['cases'][0]['keyword'] = 'changed'
        data = (json.dumps(fixture, ensure_ascii=False) + '\n').encode()
        sources = capture.harness_source_hashes(selected=True)
        provenance = {'schemaVersion': 1, 'fixtureId': 'FIELDS-02', 'corpus': {
            'asset': 'field-fixtures.json', 'bytes': len(data),
            'sha256': capture.sha256_bytes(data), 'sha256Lf': capture.sha256_bytes(data),
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1}, 'sources': sources}
        with tempfile.TemporaryDirectory() as temporary:
            fixture_path = Path(temporary) / 'fixture.json'
            fixture_path.write_bytes(data)
            apk = Path(temporary) / 'synthetic.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', data)
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            with self.assertRaisesRegex(ValueError, 'corpus raw'):
                capture.inspect_selected_apk(apk, fixture_path, fixture, sources)

    def test_selected_reference_rejects_a_relabelled_target(self):
        directory = Path(__file__).resolve().parent
        selected = json.loads((directory / 'book-url-markers-fixtures-selected.json').read_bytes())
        capture._admit_selected_shape(selected, 'fixture')
        selected['target']['apkSha256'] = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
        with self.assertRaisesRegex(ValueError, 'target'):
            capture._admit_selected_shape(selected, 'fixture')


def _synthetic_dex_archive(name, content):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, 'w') as archive:
        archive.writestr(name, content)
    return buffer.getvalue()


_SYNTHETIC_TARGET_APK = _synthetic_dex_archive('classes19.dex', b'synthetic-reference-dex')
_SYNTHETIC_HARNESS_APK = _synthetic_dex_archive('classes.dex', b'synthetic-harness-dex')


def _synthetic_selected_preflight(output, fixture, artifact, apk, target, source, sdk, java, references,
                                  reference_dex_sha=None, harness_dex_sha=None):
    tools = sdk / 'build-tools' / '35.0.1'
    javabin = java / 'bin' / 'java.exe'
    commands = {
        'java-version': [javabin, '-version'],
        'javac-version': [java / 'bin' / 'javac.exe', '-version'],
        'source-head': ['git', '-C', source, 'rev-parse', 'HEAD'],
        'source-tree': ['git', '-C', source, 'rev-parse', 'HEAD^{tree}'],
        'source-status': ['git', '-C', source, 'status', '--porcelain=v1'],
        'source-blobs': ['git', '-C', source, 'hash-object', *[r['path'] for r in fixture['frozenSources']]],
        'manifest': [tools / 'aapt.exe', 'dump', 'xmltree', apk, 'AndroidManifest.xml'],
        'harness-signature': [javabin, '-jar', tools / 'lib' / 'apksigner.jar', 'verify', '--print-certs', apk],
        'target-signature': [javabin, '-jar', tools / 'lib' / 'apksigner.jar', 'verify', '--print-certs', target],
        'reference-dex': [tools / 'dexdump.exe', source / 'fields-reference-dex-mechanics' / 'classes19.dex'],
        'dex': [tools / 'dexdump.exe', source / 'fields-dex-mechanics' / 'classes.dex'],
    }
    values = {'source-head': capture.SELECTED_BASELINE + '\n',
              'source-tree': '0f69dc7004012a969551ce271dc4e11051637d32\n',
              'source-blobs': '\n'.join(r['sha1'] for r in fixture['frozenSources']) + '\n'}
    receipts = []
    for name, command in commands.items():
        data = values.get(name, '').encode()
        if output is not None:
            (output / ('preflight-' + name + '.stdout.log')).write_bytes(data)
            (output / ('preflight-' + name + '.stderr.log')).write_bytes(b'')
        receipts.append({'name': name, 'exitCode': 0, 'command': [str(x) for x in command],
                         'stdoutSha256': capture.sha256_bytes(data), 'stderrSha256': capture.sha256_bytes(b'')})
    reference_dex_sha = reference_dex_sha or capture.sha256_bytes(b'synthetic-reference-dex')
    if harness_dex_sha is None:
        with zipfile.ZipFile(apk) as archive:
            harness_dex_sha = capture.sha256_bytes(archive.read('classes.dex'))
    return {'artifact': artifact, 'targetApkSha256': fixture['target']['apkSha256'],
            'dexSha256': harness_dex_sha, 'referenceDexSha256': reference_dex_sha,
            'inputs': {'harnessApk': str(apk), 'targetApk': str(target), 'source': str(source),
                       'androidSdk': str(sdk), 'javaHome': str(java),
                       'referenceDex': str(commands['reference-dex'][1]),
                       'harnessDex': str(commands['dex'][1])},
            'referenceSources': references, 'commands': receipts}


class TitleLifecycleAdmissionTest(unittest.TestCase):
    """The saved-name/refresh observation's strict admission.

    The four phase arrays are shared with the product; the setup, containment,
    preference and event-guard facts are native producer evidence. These are
    mechanism vectors over the admission functions, not native results.
    """

    ORIGIN = 'http://127.0.0.1:18734'

    def _phases(self):
        rows = [{'index': 0, 'title': 'CHAPTER ONE', 'variable': 'toc-a'},
                {'index': 1, 'title': 'CHAPTER TWO', 'variable': 'toc-b'}]
        return {phase: [dict(row) for row in rows]
                for phase in capture.TITLE_LIFECYCLE_PHASES}

    def _proof(self):
        return {
            'bookParent': {'bookUrl': self.ORIGIN + '/book/1',
                           'stored': True, 'readBack': True},
            'chapterSeed': {'rows': 2, 'inserted': True},
            'saveEvent': {'tag': 'saveContent', 'delivered': True,
                          'correlates': True,
                          'fence': {'posted': True, 'completed': True,
                                    'timeoutMillis': 5000, 'mainThread': False}},
            'contentFiles': ['00000-0123456789abcdef.nb'],
            'tocCountWords': {'previousPresent': True, 'committed': True,
                              'presentAfter': True, 'observedAfter': True,
                              'restored': True},
            'saveObserverRemoved': True,
            'guard': {
                'release': {'ownedReceivers': 1, 'removedReceivers': 1,
                            'ownedLifecycleCallbacks': 1,
                            'removedLifecycleCallbacks': 1},
                'fence': {'posted': True, 'completed': True,
                          'timeoutMillis': 5000, 'mainThread': False},
                'receipt': {'blockedDeliveries': 0, 'pendingWrappers': 0,
                            'inboundAttempts': [], 'failures': []},
            },
        }

    def _case(self):
        return {'titleLifecycle': self._phases(),
                'titleLifecycleProof': self._proof()}

    def _admit_shared(self, case, terminal=None):
        capture._admit_title_lifecycle(
            case, terminal or capture.TITLE_LIFECYCLE_TERMINAL, 'case')

    def _admit_native(self, case, terminal=None):
        capture._admit_title_lifecycle_proof(
            case, terminal or capture.TITLE_LIFECYCLE_TERMINAL, 'case')

    def _rejected(self, call, case, pattern, terminal=None):
        with self.assertRaisesRegex(ValueError, pattern):
            call(case, terminal)

    def test_a_complete_observation_is_admitted(self):
        self._admit_shared(self._case())
        self._admit_native(self._case())

    def test_a_non_observing_terminal_must_not_carry_either_field(self):
        for terminal in ('four-stage', 'search-empty'):
            self._rejected(self._admit_shared, self._case(),
                           'not declared by its terminal', terminal)
            case = {'titleLifecycleProof': self._proof()}
            self._rejected(self._admit_shared, case,
                           'not declared by its terminal', terminal)

    def test_the_shared_object_is_exactly_the_four_phases(self):
        case = self._case()
        case['titleLifecycle']['writeContainment'] = {'cachePath': 'x'}
        self._rejected(self._admit_shared, case, 'titleLifecycle fields differ')
        case = self._case()
        del case['titleLifecycle']['storedAfterRefresh']
        self._rejected(self._admit_shared, case, 'titleLifecycle fields differ')

    def test_each_phase_needs_two_ordered_rows(self):
        for phase in capture.TITLE_LIFECYCLE_PHASES:
            case = self._case()
            case['titleLifecycle'][phase] = case['titleLifecycle'][phase][:1]
            self._rejected(self._admit_shared, case, phase + ' row count differs')
            case = self._case()
            case['titleLifecycle'][phase][0]['index'] = 1
            case['titleLifecycle'][phase][1]['index'] = 0
            self._rejected(self._admit_shared, case,
                           'index is not its ordered position')

    def test_null_and_missing_variable_stay_distinct(self):
        case = self._case()
        case['titleLifecycle']['refreshedChapters'][0]['variable'] = None
        self._admit_shared(case)
        case = self._case()
        del case['titleLifecycle']['refreshedChapters'][0]['variable']
        self._rejected(self._admit_shared, case, 'variable is missing')
        case = self._case()
        case['titleLifecycle']['refreshedChapters'][0]['variable'] = 7
        self._rejected(self._admit_shared, case,
                       'variable must be a string or null')

    def test_an_extra_row_field_is_refused(self):
        case = self._case()
        case['titleLifecycle']['beforeContent'][0]['wordCount'] = '1'
        self._rejected(self._admit_shared, case, 'fields differ')

    def test_the_native_proof_is_required_and_typed(self):
        case = {'titleLifecycle': self._phases()}
        self._rejected(self._admit_native, case, 'titleLifecycleProof is missing')
        case = self._case()
        case['titleLifecycleProof']['contentFiles'] = []
        self._rejected(self._admit_native, case, 'contentFiles must not be empty')
        case = self._case()
        case['titleLifecycleProof']['bookParent']['readBack'] = False
        self._rejected(self._admit_native, case, 'readBack must be true')
        case = self._case()
        del case['titleLifecycleProof']['guard']
        self._rejected(self._admit_native, case, 'guard is missing')
        case = self._case()
        case['titleLifecycleProof']['undeclared'] = True
        self._rejected(self._admit_native, case, 'undeclared fields')

    def test_the_native_proof_rejects_an_unclosed_domain(self):
        case = self._case()
        case['titleLifecycleProof']['guard']['release']['removedReceivers'] = 0
        self._rejected(self._admit_native, case,
                       'did not remove every registration it owned')
        case = self._case()
        case['titleLifecycleProof']['guard']['receipt']['pendingWrappers'] = 1
        self._rejected(self._admit_native, case, 'left a wrapper registered')
        case = self._case()
        case['titleLifecycleProof']['guard']['receipt']['blockedDeliveries'] = 1
        self._rejected(self._admit_native, case,
                       'received an external IPC attempt')
        case = self._case()
        case['titleLifecycleProof']['guard']['receipt']['failures'] = ['x']
        self._rejected(self._admit_native, case, 'recorded a guard failure')
        case = self._case()
        case['titleLifecycleProof']['saveEvent']['fence']['completed'] = False
        self._rejected(self._admit_native, case, 'fence did not complete')

    def test_the_preference_restore_is_required_and_presence_aware(self):
        case = self._case()
        case['titleLifecycleProof']['tocCountWords']['restored'] = False
        self._rejected(self._admit_native, case, 'was not restored')
        case = self._case()
        case['titleLifecycleProof']['tocCountWords']['previousPresent'] = False
        self._rejected(self._admit_native, case, 'presence differs')

    def _operations_case(self, terminal, names):
        requests = []
        trace = []
        operations = []
        for index, name in enumerate(names):
            path = '/' + name + '/' + str(index)
            requests.append({'method': 'GET', 'path': path, 'rawQuery': '',
                             'stage': name})
            trace.append({'stage': name, 'path': self.ORIGIN + path})
            operations.append({'name': name, 'outcome': 'completed',
                               'requestStart': index, 'requestEnd': index + 1,
                               'traceStart': index, 'traceEnd': index + 1})
        case = {'id': 'c', 'terminal': terminal, 'operations': operations,
                'requests': list(requests)}
        return case, requests, trace

    def test_the_extra_refresh_span_is_admitted_only_for_its_terminal(self):
        names = ['search', 'bookInfo', 'tableOfContents', 'content',
                 'tableOfContents']
        case, requests, trace = self._operations_case(
            capture.TITLE_LIFECYCLE_TERMINAL, names)
        capture._admit_native_operations([case], requests, trace,
                                         {'origin': self.ORIGIN})
        case, requests, trace = self._operations_case('four-stage', names)
        with self.assertRaisesRegex(ValueError, 'operation set differs'):
            capture._admit_native_operations([case], requests, trace,
                                             {'origin': self.ORIGIN})

    def test_the_old_four_stage_span_stays_exactly_four(self):
        names = ['search', 'bookInfo', 'tableOfContents', 'content']
        case, requests, trace = self._operations_case('four-stage', names)
        capture._admit_native_operations([case], requests, trace,
                                         {'origin': self.ORIGIN})
        case, requests, trace = self._operations_case(
            capture.TITLE_LIFECYCLE_TERMINAL, names)
        with self.assertRaisesRegex(ValueError, 'operation set differs'):
            capture._admit_native_operations([case], requests, trace,
                                             {'origin': self.ORIGIN})

    def test_a_stale_or_extra_span_is_refused(self):
        names = ['search', 'bookInfo', 'tableOfContents', 'content',
                 'tableOfContents']
        case, requests, trace = self._operations_case(
            capture.TITLE_LIFECYCLE_TERMINAL, names)
        # A sixth request/trace pair the declared operations skip: the last
        # operation's span is internally consistent but not contiguous.
        gap_path = '/tableOfContents/5'
        requests.append({'method': 'GET', 'path': gap_path, 'rawQuery': '',
                         'stage': 'tableOfContents'})
        trace.append({'stage': 'tableOfContents', 'path': self.ORIGIN + gap_path})
        case['operations'][4]['requestStart'] = 5
        case['operations'][4]['requestEnd'] = 6
        case['operations'][4]['traceStart'] = 5
        case['operations'][4]['traceEnd'] = 6
        case['requests'] = list(requests)
        with self.assertRaisesRegex(ValueError, 'not contiguous'):
            capture._admit_native_operations([case], requests, trace,
                                             {'origin': self.ORIGIN})
        case, requests, trace = self._operations_case(
            capture.TITLE_LIFECYCLE_TERMINAL, names)
        case['operations'][4]['traceEnd'] = 99
        with self.assertRaisesRegex(ValueError, 'outside the stage trace'):
            capture._admit_native_operations([case], requests, trace,
                                             {'origin': self.ORIGIN})

    def test_the_lifecycle_corpus_declares_distinct_source_keys(self):
        here = Path(__file__).resolve().parent
        corpus = json.loads(
            (here / 'reader-title-lifecycle-fixtures-selected.json').read_text(
                encoding='utf-8'))
        keys = [case['source']['bookSourceUrl'] for case in corpus['cases']]
        self.assertEqual(len(keys), len(set(keys)))
        self.assertTrue(all(key.startswith('http://127.0.0.1:18734/source/')
                            for key in keys))
        self.assertEqual(len(corpus['expectedRequests']), 18)
        self.assertEqual(len(corpus['responses']), 18)
        self.assertEqual(len(corpus['cases']), 4)
        self.assertIn('titleLifecycle', corpus)


GUARD_FAKES = {
    'android/app/Application.java': '''package android.app;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import java.util.ArrayList;
import java.util.List;

/** Test-only Application boundary: records what the guard actually asks for. */
public class Application extends Context {
    public final List<String> registered = new ArrayList<>();
    public final List<String> unregistered = new ArrayList<>();
    public final List<String> lifecycleRegistered = new ArrayList<>();
    public final List<String> lifecycleUnregistered = new ArrayList<>();
    public BroadcastReceiver lastReceiver;
    public IntentFilter lastFilter;
    public int lastFlags = -1;
    public RuntimeException registerFailure;
    public RuntimeException unregisterFailure;

    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter) {
        return registerReceiver(receiver, filter, 0);
    }

    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter, int flags) {
        if (registerFailure != null) throw registerFailure;
        lastReceiver = receiver;
        lastFilter = filter;
        lastFlags = flags;
        registered.add(receiver.getClass().getName() + "|" + flags);
        return null;
    }

    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, android.os.Handler scheduler) {
        return registerReceiver(receiver, filter, 0);
    }

    public Intent registerReceiver(BroadcastReceiver receiver, IntentFilter filter,
            String broadcastPermission, android.os.Handler scheduler, int flags) {
        return registerReceiver(receiver, filter, flags);
    }

    public void unregisterReceiver(BroadcastReceiver receiver) {
        if (unregisterFailure != null) throw unregisterFailure;
        unregistered.add(receiver.getClass().getName());
    }

    public void registerActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        lifecycleRegistered.add(callback.getClass().getName());
    }

    public void unregisterActivityLifecycleCallbacks(ActivityLifecycleCallbacks callback) {
        lifecycleUnregistered.add(callback.getClass().getName());
    }

    public void startActivity(Intent intent) {
        throw new SecurityException("not reached in this fake");
    }

    public void startActivity(Intent intent, android.os.Bundle options) {
        throw new SecurityException("not reached in this fake");
    }

    public interface ActivityLifecycleCallbacks {
        void onActivityCreated(Object activity, android.os.Bundle state);
    }
}
''',
    'android/content/Context.java': '''package android.content;

import java.io.File;
import java.util.HashMap;
import java.util.Map;

/** Test-only Context boundary. */
public class Context {
    public static final int MODE_PRIVATE = 0;
    private final File root;
    private final Map<String, SharedPreferences> preferences = new HashMap<>();

    public Context() { this(new File(System.getProperty("java.io.tmpdir"), "r2afix-context")); }

    public Context(File root) { this.root = root; }

    public Context getApplicationContext() { return this; }

    public String getPackageName() { return "io.legado.app.debug"; }

    public File getFilesDir() { return new File(root, "files"); }

    public File getExternalFilesDir(String type) { return new File(root, "external-files"); }

    public File getDatabasePath(String name) { return new File(new File(root, "databases"), name); }

    public boolean isDeviceProtectedStorage() { return false; }

    public SharedPreferences getSharedPreferences(String name, int mode) {
        SharedPreferences existing = preferences.get(name);
        if (existing == null) {
            existing = new FakePreferences();
            preferences.put(name, existing);
        }
        return existing;
    }
}
''',
    'android/content/SharedPreferences.java': '''package android.content;

/** Test-only interface with the real Android SharedPreferences ABI. */
public interface SharedPreferences {
    java.util.Map<String, ?> getAll();
    String getString(String key, String defValue);
    java.util.Set<String> getStringSet(String key, java.util.Set<String> defValues);
    int getInt(String key, int defValue);
    long getLong(String key, long defValue);
    float getFloat(String key, float defValue);
    boolean getBoolean(String key, boolean defValue);
    boolean contains(String key);
    Editor edit();
    void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);
    void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener listener);

    interface OnSharedPreferenceChangeListener {
        void onSharedPreferenceChanged(SharedPreferences preferences, String key);
    }

    interface Editor {
        Editor putString(String key, String value);
        Editor putStringSet(String key, java.util.Set<String> values);
        Editor putInt(String key, int value);
        Editor putLong(String key, long value);
        Editor putFloat(String key, float value);
        Editor putBoolean(String key, boolean value);
        Editor remove(String key);
        Editor clear();
        boolean commit();
        void apply();
    }
}
''',
    'android/content/FakePreferences.java': '''package android.content;

import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/** Test-only implementation of the real SharedPreferences ABI. */
public class FakePreferences implements SharedPreferences {
    public final Map<String, Object> values = new HashMap<>();
    public boolean refuseCommit;
    public RuntimeException readFailure;

    @Override public boolean contains(String key) { return values.containsKey(key); }

    @Override public boolean getBoolean(String key, boolean defValue) {
        if (readFailure != null) throw readFailure;
        Object value = values.get(key);
        return value instanceof Boolean ? (Boolean) value : defValue;
    }

    @Override public Editor edit() { return new FakeEditor(this); }

    @Override public java.util.Map<String, ?> getAll() { return values; }

    @Override public String getString(String key, String defValue) { return defValue; }

    @Override public java.util.Set<String> getStringSet(String key,
            java.util.Set<String> defValues) { return defValues; }

    @Override public int getInt(String key, int defValue) { return defValue; }

    @Override public long getLong(String key, long defValue) { return defValue; }

    @Override public float getFloat(String key, float defValue) { return defValue; }

    @Override public void registerOnSharedPreferenceChangeListener(
            OnSharedPreferenceChangeListener listener) {}

    @Override public void unregisterOnSharedPreferenceChangeListener(
            OnSharedPreferenceChangeListener listener) {}

    static final class FakeEditor implements Editor {
        private final FakePreferences target;
        private final Map<String, Object> pending = new HashMap<>();
        private final Set<String> removed = new HashSet<>();

        FakeEditor(FakePreferences target) { this.target = target; }

        @Override public Editor putBoolean(String key, boolean value) {
            pending.put(key, value);
            return this;
        }

        @Override public Editor remove(String key) {
            removed.add(key);
            return this;
        }

        @Override public boolean commit() {
            if (target.refuseCommit) return false;
            for (String key : removed) target.values.remove(key);
            target.values.putAll(pending);
            return true;
        }

        @Override public void apply() { commit(); }

        @Override public android.content.SharedPreferences.Editor putString(String key,
                String value) { return this; }

        @Override public android.content.SharedPreferences.Editor putStringSet(String key,
                java.util.Set<String> values) { return this; }

        @Override public android.content.SharedPreferences.Editor putInt(String key,
                int value) { return this; }

        @Override public android.content.SharedPreferences.Editor putLong(String key,
                long value) { return this; }

        @Override public android.content.SharedPreferences.Editor putFloat(String key,
                float value) { return this; }

        @Override public android.content.SharedPreferences.Editor clear() { return this; }
    }
}
''',
    'android/content/BroadcastReceiver.java': '''package android.content;

/** Test-only receiver boundary. */
public abstract class BroadcastReceiver {
    public abstract void onReceive(Context context, Intent intent);
}
''',
    'android/content/Intent.java': '''package android.content;

/** Test-only Intent boundary: extras are never read by the guard. */
public class Intent {
    private final String action;
    public boolean extrasRead;

    public Intent(String action) { this.action = action; }

    public String getAction() { return action; }

    public String getStringExtra(String name) {
        extrasRead = true;
        return "should-not-be-read";
    }
}
''',
    'android/content/IntentFilter.java': '''package android.content;

import java.util.ArrayList;
import java.util.Iterator;
import java.util.List;

/** Test-only IntentFilter boundary. */
public class IntentFilter {
    private final List<String> actions = new ArrayList<>();
    private int dataTypes;
    private int dataSchemes;
    private int categories;

    public IntentFilter() {}

    public IntentFilter(String action) { actions.add(action); }

    public void addAction(String action) { actions.add(action); }

    public Iterator<String> actionsIterator() { return actions.iterator(); }

    public int countDataTypes() { return dataTypes; }

    public int countDataSchemes() { return dataSchemes; }

    public int countCategories() { return categories; }

    public void addCategory(String category) { categories++; }

    public void addDataType(String type) { dataTypes++; }
}
''',
    'android/os/Bundle.java': '''package android.os;

/** Test-only Bundle boundary. */
public class Bundle {
    public void putString(String key, String value) {}
}
''',
    # A REAL distinct main thread: only the controlled main thread reports MAIN.
    'android/os/Looper.java': '''package android.os;

/** Test-only Looper: exactly one controlled thread is the main thread. */
public final class Looper {
    private static final Looper MAIN = new Looper();
    private static volatile Thread mainThread;

    public static Looper getMainLooper() { return MAIN; }

    public static Looper myLooper() {
        return Thread.currentThread() == mainThread ? MAIN : null;
    }

    public static void bindMainThread() { mainThread = Thread.currentThread(); }
}
''',
    'android/os/Handler.java': '''package android.os;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;

/** Test-only Handler: a real single main thread with hold/flush controls. */
public class Handler {
    private static final ExecutorService MAIN = Executors.newSingleThreadExecutor(runnable -> {
        Thread thread = new Thread(() -> {
            Looper.bindMainThread();
            runnable.run();
        }, "controlled-main");
        thread.setDaemon(true);
        return thread;
    });
    private static boolean holding;
    private static final List<Runnable> held = new ArrayList<>();
    private static CountDownLatch queued = new CountDownLatch(1);

    public Handler(Looper looper) {}

    public boolean post(Runnable work) {
        synchronized (held) {
            if (holding) {
                held.add(work);
                queued.countDown();
                return true;
            }
        }
        MAIN.execute(work);
        return true;
    }

    public static void hold() {
        synchronized (held) {
            holding = true;
            queued = new CountDownLatch(1);
        }
    }

    public static boolean awaitQueued(long millis) throws Exception {
        return queued.await(millis, TimeUnit.MILLISECONDS);
    }

    public static void flush() {
        List<Runnable> pending;
        synchronized (held) {
            holding = false;
            pending = new ArrayList<>(held);
            held.clear();
        }
        for (Runnable work : pending) MAIN.execute(work);
    }

    public static boolean awaitIdle(long millis) throws Exception {
        CountDownLatch done = new CountDownLatch(1);
        MAIN.execute(done::countDown);
        return done.await(millis, TimeUnit.MILLISECONDS);
    }
}
''',
    'android/app/Instrumentation.java': '''package android.app;

/** Test-only placeholder so the fake tree matches the real package layout. */
public class Instrumentation {}
''',
    'com/jeremyliao/liveeventbus/core/Observable.java': '''package com.jeremyliao.liveeventbus.core;

/** Test-only public fixture interface (mirrors the inspected AAR). */
public interface Observable<T> {
    void observeForever(androidx.lifecycle.Observer<T> observer);
    void removeObserver(androidx.lifecycle.Observer<T> observer);
}
''',
    'com/jeremyliao/liveeventbus/core/LiveEventImpl.java': '''package com.jeremyliao.liveeventbus.core;

import androidx.lifecycle.Observer;
import java.util.ArrayList;
import java.util.List;

/** Test-only NON-PUBLIC implementation, as the inspected AAR's is. */
final class LiveEventImpl implements Observable<Object> {
    final List<Observer<Object>> observers = new ArrayList<>();
    public int observeCalls;
    public int removeCalls;

    @Override public void observeForever(Observer<Object> observer) {
        observeCalls++;
        observers.add(observer);
    }

    @Override public void removeObserver(Observer<Object> observer) {
        removeCalls++;
        observers.remove(observer);
    }

    public void resetCounters() {
        observeCalls = 0;
        removeCalls = 0;
    }

    void deliver(Object value) {
        for (Observer<Object> observer : new ArrayList<>(observers)) observer.onChanged(value);
    }
}
''',
    'com/jeremyliao/liveeventbus/LiveEventBus.java': '''package com.jeremyliao.liveeventbus;

import com.jeremyliao.liveeventbus.core.Observable;
import java.util.HashMap;
import java.util.Map;

/** Test-only facade: hands out the non-public implementation by interface. */
public final class LiveEventBus {
    private static final Map<String, Object> EVENTS = new HashMap<>();

    public static <T> Observable<T> get(String tag, Class<T> type) {
        Object existing = EVENTS.get(tag);
        if (existing == null) {
            existing = newImpl();
            EVENTS.put(tag, existing);
        }
        @SuppressWarnings("unchecked")
        Observable<T> observable = (Observable<T>) existing;
        return observable;
    }

    private static Object newImpl() {
        try {
            Class<?> impl = Class.forName("com.jeremyliao.liveeventbus.core.LiveEventImpl");
            java.lang.reflect.Constructor<?> constructor = impl.getDeclaredConstructor();
            constructor.setAccessible(true);
            return constructor.newInstance();
        } catch (Exception error) {
            throw new IllegalStateException(error);
        }
    }
}
''',
    'com/jeremyliao/liveeventbus/ipc/receiver/LebIpcReceiver.java': '''package com.jeremyliao.liveeventbus.ipc.receiver;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

/** Test-only receiver with the exact inspected class name the guard accepts. */
public class LebIpcReceiver extends BroadcastReceiver {
    public static int delivered;

    @Override public void onReceive(Context context, Intent intent) {
        delivered++;
        if (intent != null) intent.getStringExtra("payload");
    }
}
''',
    'com/jeremyliao/liveeventbus/utils/AppUtils.java': '''package com.jeremyliao.liveeventbus.utils;

import android.app.Application;

/** Test-only AppUtils with the exact nested callback class name. */
public final class AppUtils {
    public static final class ActivityLifecycleImpl
            implements Application.ActivityLifecycleCallbacks {
        @Override public void onActivityCreated(Object activity, android.os.Bundle state) {}
    }
}
''',
    'androidx/lifecycle/Observer.java': '''package androidx.lifecycle;

/** Test-only Observer boundary. */
public interface Observer<T> {
    void onChanged(T value);
}
''',
    'kotlin/Pair.java': '''package kotlin;

/** Test-only Pair boundary matching the reference payload shape. */
public class Pair {
    private final Object first;
    private final Object second;

    public Pair(Object first, Object second) {
        this.first = first;
        this.second = second;
    }

    public Object getFirst() { return first; }

    public Object getSecond() { return second; }
}
''',
}


LOG_STUB = '''package android.util;

/** The only OS boundary the host fixture replaces: a log call. */
public final class Log {
    public static boolean inject;

    public static int i(String tag, String message) {
        if (inject) throw new IllegalStateException("OS_LOG_ERROR");
        return 0;
    }
}
'''

REPLAY_FIXTURE = r'''
package io.liber.oracle.fields;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.net.ServerSocket;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.atomic.AtomicReference;
import org.json.JSONArray;
import org.json.JSONObject;

/**
 * Actual replay and preference-lifetime controls.
 *
 * <p>Runs the real nested replay server over loopback HTTP and the real
 * tocCountWords lifetime, both compiled from the actual SDK sources. Private
 * reflection is used only to construct/start/close the server and reach its
 * port; no match logic is copied and no Android framework call is executed.
 */
public final class StageAFixture {
    /** A bounded implementation of the real SharedPreferences ABI. */
    static final class Preferences implements android.content.SharedPreferences {
        final java.util.Map<String, Object> values = new java.util.HashMap<>();
        /** A commit that writes the value first and then reports false. */
        boolean refuseCommit;
        /** A commit that writes the value first and then throws. */
        RuntimeException commitError;
        /** A read that throws once, after a commit already mutated the store. */
        RuntimeException readError;
        /** Armed BY the commit, so the fault lands after the mutation. */
        boolean throwReadAfterWrite;
        boolean readArmed;

        @Override public boolean contains(String key) { return values.containsKey(key); }

        @Override public boolean getBoolean(String key, boolean defValue) {
            if (readArmed && readError != null) {
                readArmed = false;
                RuntimeException error = readError;
                readError = null;
                throw error;
            }
            Object value = values.get(key);
            return value instanceof Boolean ? (Boolean) value : defValue;
        }

        @Override public Editor edit() { return new Edit(this); }

        @Override public void registerOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        @Override public void unregisterOnSharedPreferenceChangeListener(
                OnSharedPreferenceChangeListener listener) {}

        @Override public java.util.Map<String, ?> getAll() { return values; }

        @Override public String getString(String key, String defValue) { return defValue; }

        @Override public java.util.Set<String> getStringSet(String key,
                java.util.Set<String> defValues) { return defValues; }

        @Override public int getInt(String key, int defValue) { return defValue; }

        @Override public long getLong(String key, long defValue) { return defValue; }

        @Override public float getFloat(String key, float defValue) { return defValue; }
    }

    static final class Edit implements android.content.SharedPreferences.Editor {
        private final Preferences target;
        private final java.util.Map<String, Object> pending = new java.util.HashMap<>();
        private final java.util.Set<String> removed = new java.util.HashSet<>();

        Edit(Preferences target) { this.target = target; }

        @Override public android.content.SharedPreferences.Editor putBoolean(String key,
                boolean value) {
            pending.put(key, value);
            return this;
        }

        @Override public android.content.SharedPreferences.Editor remove(String key) {
            removed.add(key);
            return this;
        }

        @Override public boolean commit() {
            // The mutation happens FIRST, so a false or throwing commit is a
            // partial effect the lifetime must still restore.
            for (String key : removed) target.values.remove(key);
            target.values.putAll(pending);
            if (target.throwReadAfterWrite) {
                // Q7: the readback fault is armed DURING the successful mutation,
                // not before the prior capture.
                target.readArmed = true;
                target.throwReadAfterWrite = false;
            }
            if (target.refuseCommit) {
                // One-shot: the restore's own commit must be able to succeed.
                target.refuseCommit = false;
                return false;
            }
            if (target.commitError != null) {
                RuntimeException error = target.commitError;
                target.commitError = null;
                throw error;
            }
            return true;
        }

        @Override public void apply() { commit(); }

        @Override public android.content.SharedPreferences.Editor putString(String key,
                String value) { return this; }

        @Override public android.content.SharedPreferences.Editor putStringSet(String key,
                java.util.Set<String> values) { return this; }

        @Override public android.content.SharedPreferences.Editor putInt(String key,
                int value) { return this; }

        @Override public android.content.SharedPreferences.Editor putLong(String key,
                long value) { return this; }

        @Override public android.content.SharedPreferences.Editor putFloat(String key,
                float value) { return this; }

        @Override public android.content.SharedPreferences.Editor clear() { return this; }
    }
    static Class<?> replayType;
    static Constructor<?> replayCtor;
    static Method start;
    static Method close;
    static Field serverField;

    static JSONObject response(String id, String path, String body) throws Exception {
        return new JSONObject().put("id", id).put("method", "GET").put("path", path)
            .put("body", body);
    }

    static Object create(JSONArray responses, JSONArray requests, JSONArray unmatched,
            JSONArray errors, JSONArray trace) throws Exception {
        return create(new JSONObject().put("origin", "http://127.0.0.1:0")
            .put("responses", responses), requests, unmatched, errors, trace);
    }

    static Object create(JSONObject corpus, JSONArray requests, JSONArray unmatched,
            JSONArray errors, JSONArray trace) throws Exception {
        Object server = replayCtor.newInstance(corpus, requests, unmatched, errors, trace,
            new AtomicReference<String>("stage-a-replay-control"), true);
        start.invoke(server);
        return server;
    }

    /**
     * A bounded, deterministic schedule hook around the replay corpus input.
     *
     * <p>It only controls WHEN the responses array is handed back: the first
     * real match waits, inside its own call, for a bounded opportunity for a
     * second client. The matcher, receipts and wire bytes are the real ones.
     */
    static final class ScheduledCorpus extends JSONObject {
        final java.util.concurrent.atomic.AtomicInteger matchCalls =
            new java.util.concurrent.atomic.AtomicInteger();
        final java.util.concurrent.CountDownLatch firstInMatch =
            new java.util.concurrent.CountDownLatch(1);
        final java.util.concurrent.CountDownLatch secondClientCompleted =
            new java.util.concurrent.CountDownLatch(1);
        volatile boolean firstWaiting;
        volatile boolean secondEnteredWhileFirstBlocked;

        @Override public JSONArray optJSONArray(String key) {
            if ("responses".equals(key)) {
                int call = matchCalls.incrementAndGet();
                if (call == 1) {
                    firstWaiting = true;
                    firstInMatch.countDown();
                    try {
                        secondClientCompleted.await(700, java.util.concurrent.TimeUnit.MILLISECONDS);
                    } catch (InterruptedException interrupted) {
                        Thread.currentThread().interrupt();
                        throw new AssertionError(interrupted);
                    } finally {
                        firstWaiting = false;
                    }
                } else if (call == 2) {
                    secondEnteredWhileFirstBlocked = firstWaiting;
                }
            }
            return super.optJSONArray(key);
        }
    }

    static String request(Object server, String target) throws Exception {
        int port = ((ServerSocket) serverField.get(server)).getLocalPort();
        try (Socket socket = new Socket("127.0.0.1", port)) {
            socket.setSoTimeout(2000);
            OutputStream out = socket.getOutputStream();
            out.write(("GET " + target + " HTTP/1.1\r\nHost: 127.0.0.1\r\n"
                + "Connection: close\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            out.flush();
            BufferedReader reader = new BufferedReader(
                new InputStreamReader(socket.getInputStream(), StandardCharsets.UTF_8));
            String status = reader.readLine();
            String line;
            int length = 0;
            while ((line = reader.readLine()) != null && !line.isEmpty()) {
                if (line.toLowerCase(Locale.ROOT).startsWith("content-length:")) {
                    length = Integer.parseInt(line.substring(line.indexOf(':') + 1).trim());
                }
            }
            char[] body = new char[length];
            int count = 0;
            while (count < length) {
                int got = reader.read(body, count, length - count);
                if (got < 0) throw new AssertionError("short response");
                count += got;
            }
            return status + "|" + new String(body);
        }
    }

    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    static void replayControls(JSONObject result) throws Exception {
        replayType = Class.forName("io.liber.oracle.fields.FieldOracle$FieldReplay");
        replayCtor = replayType.getDeclaredConstructors()[0];
        replayCtor.setAccessible(true);
        start = replayType.getDeclaredMethod("start");
        start.setAccessible(true);
        close = replayType.getDeclaredMethod("close");
        close.setAccessible(true);
        serverField = replayType.getDeclaredField("server");
        serverField.setAccessible(true);
        JSONArray requests = new JSONArray();
        JSONArray unmatched = new JSONArray();
        JSONArray errors = new JSONArray();
        JSONArray trace = new JSONArray();
        JSONArray responses = new JSONArray()
            .put(response("d1", "/duplicate", "FIRST"))
            .put(response("d2", "/duplicate", "SECOND"))
            .put(response("q", "/duplicate", "QUERY")
                .put("query", new JSONObject().put("special", "yes")))
            .put(response("s", "/single", "SINGLE"))
            .put(response("other", "/case-other", "OTHER"));
        Object server = create(responses, requests, unmatched, errors, trace);
        try {
            require(request(server, "/duplicate?special=yes").endsWith("|QUERY"),
                "a query-specific declaration must win");
            require(request(server, "/duplicate?client=a").endsWith("|FIRST"),
                "the first declared duplicate must be served first");
            require(request(server, "/duplicate?client=b").endsWith("|SECOND"),
                "the second declared duplicate must be served second");
            require(request(server, "/duplicate?client=c").startsWith("HTTP/1.1 404"),
                "a third duplicate must exhaust");
            require(request(server, "/single").endsWith("|SINGLE")
                && request(server, "/single").endsWith("|SINGLE"),
                "a single response must answer repeatedly");
            require(request(server, "/case-other").endsWith("|OTHER"),
                "a distinct case route must answer its own response");
        } finally {
            close.invoke(server);
        }
        require(requests.length() == 7 && trace.length() == 7 && unmatched.length() == 1
            && errors.length() == 0, "the real request/trace accounting must close");
        require(requests.getJSONObject(1).getJSONObject("receipt").getString("responseId")
            .equals("d1"), "the first duplicate receipt must name its declaration");
        require(requests.getJSONObject(2).getJSONObject("receipt").getString("responseId")
            .equals("d2"), "the second duplicate receipt must name its declaration");
        int concurrentRounds = 0;
        for (int round = 0; round < 10; round++) {
            JSONArray r = new JSONArray();
            JSONArray m = new JSONArray();
            JSONArray e = new JSONArray();
            JSONArray tr = new JSONArray();
            Object concurrent = create(new JSONArray()
                .put(response("c1", "/concurrent", "ONE"))
                .put(response("c2", "/concurrent", "TWO")), r, m, e, tr);
            final Map<String, String> bodies = new ConcurrentHashMap<>();
            final CountDownLatch go = new CountDownLatch(1);
            final List<Throwable> failures =
                Collections.synchronizedList(new ArrayList<Throwable>());
            List<Thread> workers = new ArrayList<>();
            for (final String id : new String[]{"L", "R"}) {
                Thread worker = new Thread(() -> {
                    try {
                        go.await();
                        bodies.put(id, request(concurrent, "/concurrent?client=" + id));
                    } catch (Throwable error) {
                        failures.add(error);
                    }
                });
                workers.add(worker);
                worker.start();
            }
            go.countDown();
            for (Thread worker : workers) {
                worker.join(3000);
                require(!worker.isAlive(), "a concurrent client must finish");
            }
            close.invoke(concurrent);
            require(failures.isEmpty() && r.length() == 2 && tr.length() == 2
                && m.length() == 0 && e.length() == 0,
                "the concurrent accounting must close: " + failures);
            for (int index = 0; index < 2; index++) {
                JSONObject row = r.getJSONObject(index);
                String id = row.getJSONObject("query").getString("client");
                String responseId = row.getJSONObject("receipt").getString("responseId");
                require(responseId.equals(index == 0 ? "c1" : "c2"),
                    "the recorded order must match the declaration order");
                require(bodies.get(id).endsWith(index == 0 ? "|ONE" : "|TWO"),
                    "each recorded request must carry its own wire body");
            }
            concurrentRounds++;
        }
        // The committed bounded-schedule discriminator: the first real match is
        // held while a second client gets its bounded opportunity, then the
        // recorded order and wire bytes must still pair correctly.
        JSONObject scheduled = scheduledAssociation();
        result.put("scheduledHealthy", scheduled.optBoolean("healthyAssociation"))
            .put("scheduledSecondEnteredWhileFirstBlocked",
                scheduled.optBoolean("secondEnteredWhileFirstBlocked"))
            .put("scheduledRows", scheduled.optJSONArray("recordedRequests"));
        require(scheduled.optBoolean("healthyAssociation"),
            "the controlled concurrent schedule must keep the real association: " + scheduled);
        result.put("sequentialRequests", 7).put("concurrentRounds", concurrentRounds)
            .put("queryPrecedence", true).put("duplicateOrder", true)
            .put("exhaustion", true).put("legacyRepeatedAnswer", true)
            .put("distinctRoutes", true).put("wireReceiptOrder", true);
    }

    /** One bounded controlled concurrent schedule over the real replay seam. */
    static JSONObject scheduledAssociation() throws Exception {
        JSONArray requests = new JSONArray();
        JSONArray unmatched = new JSONArray();
        JSONArray errors = new JSONArray();
        JSONArray trace = new JSONArray();
        ScheduledCorpus corpus = new ScheduledCorpus();
        corpus.put("origin", "http://127.0.0.1:0");
        corpus.put("responses", new JSONArray()
            .put(response("first", "/same", "ONE"))
            .put(response("second", "/same", "TWO")));
        Object server = create(corpus, requests, unmatched, errors, trace);
        final Map<String, String> bodies = new ConcurrentHashMap<>();
        final List<Throwable> failures =
            Collections.synchronizedList(new ArrayList<Throwable>());
        Thread first = new Thread(() -> {
            try { bodies.put("L", request(server, "/same?client=L")); }
            catch (Throwable error) { failures.add(error); }
        });
        Thread second = new Thread(() -> {
            try { bodies.put("R", request(server, "/same?client=R")); }
            catch (Throwable error) { failures.add(error); }
            finally { corpus.secondClientCompleted.countDown(); }
        });
        try {
            first.start();
            require(corpus.firstInMatch.await(3000, java.util.concurrent.TimeUnit.MILLISECONDS),
                "the first client must reach the real matcher");
            second.start();
            first.join(4000);
            second.join(4000);
            require(!first.isAlive() && !second.isAlive(), "both clients must finish");
        } finally {
            close.invoke(server);
        }
        require(failures.isEmpty() && requests.length() == 2 && trace.length() == 2
            && unmatched.length() == 0 && errors.length() == 0,
            "the scheduled transport must close: " + failures);
        boolean healthy = true;
        JSONArray rows = new JSONArray();
        for (int index = 0; index < 2; index++) {
            JSONObject row = requests.getJSONObject(index);
            String client = row.getJSONObject("query").getString("client");
            String declared = row.getJSONObject("receipt").getString("responseId");
            String expectedId = index == 0 ? "first" : "second";
            String expectedBody = index == 0 ? "ONE" : "TWO";
            boolean linked = declared.equals(expectedId)
                && bodies.get(client) != null
                && bodies.get(client).endsWith("|" + expectedBody);
            healthy &= linked;
            rows.put(new JSONObject().put("recordedClient", client)
                .put("receiptResponseId", declared)
                .put("actualWireBody", bodies.get(client))
                .put("correctlyLinked", linked));
        }
        return new JSONObject().put("recordedRequests", rows)
            .put("healthyAssociation", healthy)
            .put("secondEnteredWhileFirstBlocked", corpus.secondEnteredWhileFirstBlocked)
            .put("realMatchCalls", corpus.matchCalls.get());
    }

    static void preferenceControls(JSONObject result) throws Exception {
        Class<?> lifetime =
            Class.forName("io.liber.oracle.fields.FieldOracle$TocCountWordsLifetime");
        Method capture = lifetime.getDeclaredMethod("capture",
            android.content.SharedPreferences.class);
        Method apply = lifetime.getDeclaredMethod("apply",
            android.content.SharedPreferences.class, boolean.class);
        Method restore = lifetime.getDeclaredMethod("restore",
            android.content.SharedPreferences.class, JSONObject.class);
        capture.setAccessible(true);
        apply.setAccessible(true);
        restore.setAccessible(true);
        JSONObject outcome = new JSONObject();
        StageAFixture.Preferences preferences = new StageAFixture.Preferences();
        JSONObject priorAbsent = (JSONObject) capture.invoke(null, preferences);
        apply.invoke(null, preferences, true);
        JSONObject restoredAbsent = (JSONObject) restore.invoke(null, preferences, priorAbsent);
        outcome.put("absentRestored", restoredAbsent.optBoolean("restored"))
            .put("absentKeyRemoved", !preferences.contains("tocCountWords"));
        preferences = new StageAFixture.Preferences();
        preferences.values.put("tocCountWords", Boolean.FALSE);
        JSONObject priorFalse = (JSONObject) capture.invoke(null, preferences);
        apply.invoke(null, preferences, true);
        JSONObject restoredFalse = (JSONObject) restore.invoke(null, preferences, priorFalse);
        outcome.put("falseRestored", restoredFalse.optBoolean("restored"))
            .put("falseValueBack", Boolean.FALSE.equals(preferences.values.get("tocCountWords")));
        StageAFixture.Preferences refusing = new StageAFixture.Preferences();
        refusing.refuseCommit = true;
        boolean applyFailed = false;
        try {
            apply.invoke(null, refusing, true);
        } catch (java.lang.reflect.InvocationTargetException error) {
            applyFailed = true;
        }
        outcome.put("refusedCommitFails", applyFailed);
        StageAFixture.Preferences refusingRestore = new StageAFixture.Preferences();
        JSONObject priorPresent = (JSONObject) capture.invoke(null, refusingRestore);
        refusingRestore.refuseCommit = true;
        boolean restoreFailed = false;
        try {
            restore.invoke(null, refusingRestore, priorPresent);
        } catch (java.lang.reflect.InvocationTargetException error) {
            restoreFailed = true;
        }
        outcome.put("refusedRestoreFails", restoreFailed);
        StageAFixture.Preferences throwing = new StageAFixture.Preferences();
        JSONObject priorThrow = (JSONObject) capture.invoke(null, throwing);
        throwing.readError = new IllegalStateException("readback failed");
        throwing.throwReadAfterWrite = true;
        boolean readbackFailed = false;
        try {
            restore.invoke(null, throwing, priorThrow);
        } catch (java.lang.reflect.InvocationTargetException error) {
            readbackFailed = true;
        }
        outcome.put("readbackThrowFails", readbackFailed);
        boolean missingFailed = false;
        try {
            restore.invoke(null, new StageAFixture.Preferences(), null);
        } catch (java.lang.reflect.InvocationTargetException error) {
            missingFailed = true;
        }
        outcome.put("missingPriorFails", missingFailed);
        result.put("preference", outcome);
        require(outcome.optBoolean("absentRestored") && outcome.optBoolean("absentKeyRemoved")
            && outcome.optBoolean("falseRestored") && outcome.optBoolean("falseValueBack")
            && outcome.optBoolean("refusedCommitFails")
            && outcome.optBoolean("refusedRestoreFails")
            && outcome.optBoolean("readbackThrowFails")
            && outcome.optBoolean("missingPriorFails"),
            "every preference lifetime path must behave: " + outcome);
    }

    /**
     * C1: the actual caller composition, {@code runWithCleanup} around the real
     * {@code runOuterSequence}.
     *
     * <p>The permitted legacy replay-close failure must be accepted by the
     * caller while the resource facts stay truthful; every other failure family
     * stays fatal.
     */
    static void callerControls(JSONObject result) throws Exception {
        JSONObject outcome = new JSONObject();
        JSONObject closed = new JSONObject().put("closed", true);
        JSONObject okReplay = new JSONObject().put("serverClosed", true)
            .put("openConnectionsAfterClose", 0);
        JSONObject okTerminal = new JSONObject().put("closed", true).put("proved", true)
            .put("activityLaunchAttempts", 0);
        JSONObject notApplicable = new JSONObject().put("applicable", false);
        JSONObject ownerDone = new JSONObject().put("closed", true)
            .put("ownerComplete", true);

        // 1. A healthy non-selected legacy run succeeds through the caller.
        boolean healthy = true;
        try {
            FieldOracle.runWithCleanup(
                () -> new JSONObject().put("body", true),
                () -> FieldOracle.runOuterSequence(
                    () -> closed, () -> okReplay, () -> notApplicable, () -> notApplicable,
                    () -> notApplicable, () -> notApplicable,
                    proved -> new JSONObject().put("applicable", false),
                    () -> closed, false, false, new JSONObject()));
        } catch (Throwable error) {
            healthy = false;
        }
        outcome.put("healthyLegacySucceeds", healthy);

        // 2. The permitted non-selected replay-close failure is accepted by the
        //    actual caller, and the resource fact stays false.
        JSONObject toleratedReceipt = null;
        Throwable toleratedFailure = null;
        try {
            FieldOracle.runWithCleanup(
                () -> new JSONObject().put("body", true),
                () -> FieldOracle.runOuterSequence(
                    () -> closed,
                    () -> { throw new IllegalStateException("LEGACY_REPLAY"); },
                    () -> notApplicable, () -> notApplicable, () -> notApplicable,
                    () -> notApplicable,
                    proved -> new JSONObject().put("applicable", false),
                    () -> closed, false, false, new JSONObject()));
        } catch (Throwable error) {
            toleratedFailure = error;
        }
        // Re-run to capture the receipt the caller accepted.
        toleratedReceipt = FieldOracle.runOuterSequence(
            () -> closed,
            () -> { throw new IllegalStateException("LEGACY_REPLAY"); },
            () -> notApplicable, () -> notApplicable, () -> notApplicable,
            () -> notApplicable,
            proved -> new JSONObject().put("applicable", false),
            () -> closed, false, false, new JSONObject());
        outcome.put("toleratedReplayAccepted", toleratedFailure == null)
            .put("toleratedClosureStaysFalse",
                !toleratedReceipt.optBoolean("closureProved", true))
            .put("toleratedAcceptedFlag", toleratedReceipt.optBoolean("accepted"))
            .put("toleratedOwnerNotPublished",
                !toleratedReceipt.optJSONObject("owner").optBoolean("ownerComplete", false));

        // 3. A legacy report failure stays fatal through the caller.
        boolean reportFatal = false;
        try {
            FieldOracle.runWithCleanup(
                () -> new JSONObject().put("body", true),
                () -> FieldOracle.runOuterSequence(
                    () -> { throw new IllegalStateException("LEGACY_REPORT"); },
                    () -> okReplay, () -> notApplicable, () -> notApplicable,
                    () -> notApplicable, () -> notApplicable,
                    proved -> new JSONObject().put("applicable", false),
                    () -> closed, false, false, new JSONObject()));
        } catch (Throwable error) {
            reportFatal = true;
        }
        outcome.put("legacyReportFatal", reportFatal);

        // 4. A selected replay failure stays fatal through the caller.
        boolean selectedReplayFatal = false;
        try {
            FieldOracle.runWithCleanup(
                () -> new JSONObject().put("body", true),
                () -> FieldOracle.runOuterSequence(
                    () -> closed,
                    () -> { throw new IllegalStateException("SELECTED_REPLAY"); },
                    () -> notApplicable, () -> notApplicable, () -> okTerminal,
                    () -> notApplicable, proved -> ownerDone, () -> closed,
                    false, true, new JSONObject()));
        } catch (Throwable error) {
            selectedReplayFatal = true;
        }
        outcome.put("selectedReplayFatal", selectedReplayFatal);

        // 5. A lifecycle body failure stays fatal even when the cleanup is
        //    otherwise acceptable.
        RuntimeException bodyError = new IllegalStateException("BODY");
        Throwable bodyFailure = null;
        try {
            FieldOracle.runWithCleanup(
                () -> { throw bodyError; },
                () -> FieldOracle.runOuterSequence(
                    () -> closed, () -> okReplay, () -> notApplicable, () -> notApplicable,
                    () -> okTerminal, () -> notApplicable, proved -> ownerDone,
                    () -> closed, true, false, new JSONObject()));
        } catch (Throwable error) {
            bodyFailure = error;
        }
        outcome.put("bodyFailureStillFatal", bodyFailure == bodyError);

        // 6. A lifecycle run whose resources did not close is rejected by the
        //    caller even with no domain exception.
        boolean unprovedRejected = false;
        try {
            FieldOracle.runWithCleanup(
                () -> new JSONObject().put("body", true),
                () -> FieldOracle.runOuterSequence(
                    () -> closed,
                    () -> new JSONObject().put("serverClosed", false),
                    () -> notApplicable, () -> notApplicable, () -> okTerminal,
                    () -> notApplicable, proved -> ownerDone, () -> closed,
                    true, false, new JSONObject()));
        } catch (Throwable error) {
            unprovedRejected = true;
        }
        outcome.put("unprovedLifecycleClosureRejected", unprovedRejected);

        // 7. The generic contract still rejects a bare false or missing proof.
        boolean bareFalseRejected = false;
        try {
            FieldOracle.runWithCleanup(() -> new JSONObject(),
                () -> new JSONObject().put("closed", false));
        } catch (Throwable error) {
            bareFalseRejected = true;
        }
        boolean missingRejected = false;
        try {
            FieldOracle.runWithCleanup(() -> new JSONObject(), JSONObject::new);
        } catch (Throwable error) {
            missingRejected = true;
        }
        outcome.put("bareFalseStillRejected", bareFalseRejected)
            .put("missingProofStillRejected", missingRejected);

        result.put("caller", outcome);
        require(outcome.optBoolean("healthyLegacySucceeds")
            && outcome.optBoolean("toleratedReplayAccepted")
            && outcome.optBoolean("toleratedClosureStaysFalse")
            && outcome.optBoolean("toleratedAcceptedFlag")
            && outcome.optBoolean("toleratedOwnerNotPublished")
            && outcome.optBoolean("legacyReportFatal")
            && outcome.optBoolean("selectedReplayFatal")
            && outcome.optBoolean("bodyFailureStillFatal")
            && outcome.optBoolean("unprovedLifecycleClosureRejected")
            && outcome.optBoolean("bareFalseStillRejected")
            && outcome.optBoolean("missingProofStillRejected"),
            "every caller composition path must behave: " + outcome);
    }

    /**
     * C2: the actual final failure reporting, {@code reportFailure}.
     *
     * <p>Both steps are attempted, each failure is attached to the original as
     * suppressed, and the returned chain is the updated one.
     */
    static void reportingControls(JSONObject result) throws Exception {
        JSONObject outcome = new JSONObject();
        final java.util.List<String> order = new java.util.ArrayList<>();

        // 1. A clean report and persist adds nothing.
        RuntimeException cleanPrimary = new IllegalStateException("PRIMARY");
        String cleanChain = FieldOracle.reportFailure(cleanPrimary,
            () -> { order.add("persist"); return new JSONObject(); },
            () -> { order.add("report"); return new JSONObject(); });
        outcome.put("cleanOrder", order.equals(java.util.Arrays.asList("report", "persist")))
            .put("cleanNoExtra", cleanPrimary.getSuppressed().length == 0)
            .put("cleanChainHasPrimary", cleanChain.contains("PRIMARY"));

        // 2. A reporting (logger) failure is retained and the persist still runs.
        order.clear();
        RuntimeException reportPrimary = new IllegalStateException("PRIMARY");
        RuntimeException reportError = new IllegalStateException("REPORT_LOG");
        String reportChain = FieldOracle.reportFailure(reportPrimary,
            () -> { order.add("persist"); return new JSONObject(); },
            () -> { order.add("report"); throw reportError; });
        outcome.put("reportFailureRetained",
                containsThrowable(reportPrimary, reportError))
            .put("reportFailureStillPersists",
                order.equals(java.util.Arrays.asList("report", "persist")))
            .put("reportChainSerialized", reportChain.contains("REPORT_LOG")
                && reportChain.contains("PRIMARY"));

        // 3. A persistence failure is retained alongside a reporting failure.
        order.clear();
        RuntimeException bothPrimary = new IllegalStateException("PRIMARY");
        RuntimeException bothReport = new IllegalStateException("REPORT_LOG");
        RuntimeException bothPersist = new IllegalStateException("PERSIST");
        String bothChain = FieldOracle.reportFailure(bothPrimary,
            () -> { order.add("persist"); throw bothPersist; },
            () -> { order.add("report"); throw bothReport; });
        outcome.put("bothRetained",
                containsThrowable(bothPrimary, bothReport)
                    && containsThrowable(bothPrimary, bothPersist))
            .put("bothOrder", order.equals(java.util.Arrays.asList("report", "persist")))
            .put("bothChainSerialized", bothChain.contains("REPORT_LOG")
                && bothChain.contains("PERSIST") && bothChain.contains("PRIMARY"));

        // 4. A persistence failure alone is retained and does not replace the
        //    original.
        RuntimeException persistPrimary = new IllegalStateException("PRIMARY");
        RuntimeException persistError = new IllegalStateException("PERSIST");
        FieldOracle.reportFailure(persistPrimary,
            () -> { throw persistError; },
            () -> new JSONObject());
        outcome.put("persistAloneRetained",
                containsThrowable(persistPrimary, persistError)
                    && persistPrimary.getMessage().equals("PRIMARY"));

        result.put("reporting", outcome);
        require(outcome.optBoolean("cleanOrder")
            && outcome.optBoolean("cleanNoExtra")
            && outcome.optBoolean("cleanChainHasPrimary")
            && outcome.optBoolean("reportFailureRetained")
            && outcome.optBoolean("reportFailureStillPersists")
            && outcome.optBoolean("reportChainSerialized")
            && outcome.optBoolean("bothRetained")
            && outcome.optBoolean("bothOrder")
            && outcome.optBoolean("bothChainSerialized")
            && outcome.optBoolean("persistAloneRetained"),
            "every reporting path must behave: " + outcome);
    }

    /**
     * The actual outer cleanup sequence, driven with controlled domain inputs.
     *
     * <p>Every scenario calls the same {@code FieldOracle.runOuterSequence} the
     * collector's {@code outerCleanup()} runs; only the domain actions are
     * supplied here, so the sequencing, gating and per-domain policy are the
     * real collector's.
     */
    static void outerControls(JSONObject result) throws Exception {
        JSONObject outcome = new JSONObject();
        JSONObject closed = new JSONObject().put("closed", true);
        JSONObject okReplay = new JSONObject().put("serverClosed", true)
            .put("openConnectionsAfterClose", 0);
        JSONObject okTerminal = new JSONObject().put("closed", true).put("proved", true)
            .put("activityLaunchAttempts", 0);
        JSONObject notApplicable = new JSONObject().put("applicable", false);
        JSONObject ownerDone = new JSONObject().put("closed", true)
            .put("ownerComplete", true);

        // 1. A report failure does not skip any later domain, and it is fatal for
        //    the lifecycle corpus.
        final java.util.List<String> visited = new java.util.ArrayList<>();
        RuntimeException reportError = new IllegalStateException("REPORT_WRITE");
        Throwable aggregate = null;
        try {
            FieldOracle.runOuterSequence(
                () -> { visited.add("report"); throw reportError; },
                () -> { visited.add("replay"); return okReplay; },
                () -> { visited.add("guard"); return notApplicable; },
                () -> { visited.add("database"); return notApplicable; },
                () -> { visited.add("terminal"); return okTerminal; },
                () -> { visited.add("preferences"); return notApplicable; },
                proved -> { visited.add("owner"); return ownerDone; },
                () -> { visited.add("final-report"); return closed; },
                true, false, new JSONObject());
        } catch (Throwable error) {
            aggregate = error;
        }
        outcome.put("allDomainsAttempted", visited.equals(java.util.Arrays.asList(
                "report", "replay", "guard", "database", "terminal", "preferences",
                "owner", "final-report")))
            .put("reportFailureRetained",
                aggregate != null && containsThrowable(aggregate, reportError));

        // 2. Resource closure is independent of a report failure.
        final boolean[] ownerSawProved = {false};
        try {
            FieldOracle.runOuterSequence(
                () -> { throw new IllegalStateException("REPORT_ONLY"); },
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> okTerminal,
                () -> notApplicable,
                proved -> { ownerSawProved[0] = proved; return ownerDone; },
                () -> closed,
                true, false, new JSONObject());
        } catch (Throwable ignored) {
            // The report failure is the expected aggregate.
        }
        outcome.put("ownerSeesClosureDespiteReportFailure", ownerSawProved[0]);

        // 3. An unclosed guard blocks the owner receipt.
        final boolean[] ownerSawGuardClosed = {true};
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> okReplay,
                () -> new JSONObject().put("closed", false),
                () -> notApplicable,
                () -> okTerminal,
                () -> notApplicable,
                proved -> { ownerSawGuardClosed[0] = proved; return ownerDone; },
                () -> closed,
                true, false, new JSONObject());
        } catch (Throwable ignored) {
            // The unproved closure is the expected aggregate.
        }
        outcome.put("unclosedGuardBlocksOwner", !ownerSawGuardClosed[0]);

        // 4. A false preference fence blocks the owner receipt.
        final boolean[] ownerSawFence = {true};
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> okTerminal,
                () -> new JSONObject().put("closed", false),
                proved -> { ownerSawFence[0] = proved; return ownerDone; },
                () -> closed,
                true, false, new JSONObject());
        } catch (Throwable ignored) {
            // The unproved closure is the expected aggregate.
        }
        outcome.put("falseFenceBlocksOwner", !ownerSawFence[0]);

        // 5. An unproved terminal blocks the owner receipt.
        final boolean[] ownerSawTerminal = {true};
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> new JSONObject().put("closed", false).put("proved", false),
                () -> notApplicable,
                proved -> { ownerSawTerminal[0] = proved; return ownerDone; },
                () -> closed,
                true, false, new JSONObject());
        } catch (Throwable ignored) {
            // The unproved closure is the expected aggregate.
        }
        outcome.put("unprovedTerminalBlocksOwner", !ownerSawTerminal[0]);

        // 6. Q3: an applicable owner refusal is a lifecycle failure even when
        //    every resource closed.
        boolean ownerRefusalFatal = false;
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> okTerminal,
                () -> notApplicable,
                proved -> new JSONObject().put("closed", false).put("ownerComplete", false),
                () -> closed,
                true, false, new JSONObject());
        } catch (Throwable error) {
            ownerRefusalFatal = true;
        }
        outcome.put("ownerRefusalFatal", ownerRefusalFatal);

        // 7. Q4: a final measured activity launch is fatal for a selected run,
        //    without pretending the resources stayed open.
        boolean activityFatal = false;
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> new JSONObject().put("closed", true).put("proved", true)
                    .put("activityLaunchAttempts", 1),
                () -> notApplicable,
                proved -> ownerDone,
                () -> closed,
                true, true, new JSONObject());
        } catch (Throwable error) {
            activityFatal = true;
        }
        outcome.put("finalActivityFatal", activityFatal);

        // 8. Q2: the exact legacy disposition.
        //    (a) a healthy non-selected run passes with an inapplicable terminal.
        JSONObject healthyLegacy = FieldOracle.runOuterSequence(
            () -> closed,
            () -> okReplay,
            () -> notApplicable,
            () -> notApplicable,
            () -> notApplicable,
            () -> notApplicable,
            proved -> new JSONObject().put("applicable", false),
            () -> closed,
            false, false, new JSONObject());
        outcome.put("legacyHealthyPasses", healthyLegacy.optBoolean("closed"));
        //    (b) a non-selected replay-close failure is tolerated.
        boolean replayTolerated = true;
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> { throw new IllegalStateException("LEGACY_REPLAY"); },
                () -> notApplicable,
                () -> notApplicable,
                () -> notApplicable,
                () -> notApplicable,
                proved -> new JSONObject().put("applicable", false),
                () -> closed,
                false, false, new JSONObject());
        } catch (Throwable error) {
            replayTolerated = false;
        }
        outcome.put("legacyReplayTolerated", replayTolerated);
        //    (c) a non-selected report failure is fatal.
        boolean legacyReportFatal = false;
        try {
            FieldOracle.runOuterSequence(
                () -> { throw new IllegalStateException("LEGACY_REPORT"); },
                () -> okReplay,
                () -> notApplicable,
                () -> notApplicable,
                () -> notApplicable,
                () -> notApplicable,
                proved -> new JSONObject().put("applicable", false),
                () -> closed,
                false, false, new JSONObject());
        } catch (Throwable error) {
            legacyReportFatal = true;
        }
        outcome.put("legacyReportFatal", legacyReportFatal);
        //    (d) a selected replay-close failure is fatal.
        boolean selectedReplayFatal = false;
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> { throw new IllegalStateException("SELECTED_REPLAY"); },
                () -> notApplicable,
                () -> notApplicable,
                () -> okTerminal,
                () -> notApplicable,
                proved -> ownerDone,
                () -> closed,
                false, true, new JSONObject());
        } catch (Throwable error) {
            selectedReplayFatal = true;
        }
        outcome.put("selectedReplayFatal", selectedReplayFatal);

        // 9. Every later domain still runs after an earlier domain throws.
        final java.util.List<String> afterFailure = new java.util.ArrayList<>();
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> { afterFailure.add("replay"); throw new IllegalStateException("REPLAY"); },
                () -> { afterFailure.add("guard"); return notApplicable; },
                () -> { afterFailure.add("database"); return notApplicable; },
                () -> { afterFailure.add("terminal"); return okTerminal; },
                () -> { afterFailure.add("preferences"); return notApplicable; },
                proved -> { afterFailure.add("owner"); return ownerDone; },
                () -> { afterFailure.add("final-report"); return closed; },
                true, false, new JSONObject());
        } catch (Throwable ignored) {
            // The replay failure is the expected aggregate.
        }
        outcome.put("laterDomainsAfterFailure", afterFailure.equals(java.util.Arrays.asList(
            "replay", "guard", "database", "terminal", "preferences", "owner",
            "final-report")));

        // 10. The measured openConnectionsAfterClose stays a real fact.
        JSONObject measured = FieldOracle.runOuterSequence(
            () -> closed,
            () -> new JSONObject().put("serverClosed", true)
                .put("openConnectionsAfterClose", 0),
            () -> notApplicable,
            () -> notApplicable,
            () -> okTerminal,
            () -> notApplicable,
            proved -> ownerDone,
            () -> closed,
            true, false, new JSONObject());
        outcome.put("openConnectionsMeasured",
            measured.optJSONObject("replay").optInt("openConnectionsAfterClose", -1) == 0);

        result.put("outer", outcome);
        require(outcome.optBoolean("allDomainsAttempted")
            && outcome.optBoolean("reportFailureRetained")
            && outcome.optBoolean("ownerSeesClosureDespiteReportFailure")
            && outcome.optBoolean("unclosedGuardBlocksOwner")
            && outcome.optBoolean("falseFenceBlocksOwner")
            && outcome.optBoolean("unprovedTerminalBlocksOwner")
            && outcome.optBoolean("ownerRefusalFatal")
            && outcome.optBoolean("finalActivityFatal")
            && outcome.optBoolean("legacyHealthyPasses")
            && outcome.optBoolean("legacyReplayTolerated")
            && outcome.optBoolean("legacyReportFatal")
            && outcome.optBoolean("selectedReplayFatal")
            && outcome.optBoolean("laterDomainsAfterFailure")
            && outcome.optBoolean("openConnectionsMeasured"),
            "every outer sequence path must behave: " + outcome);
    }

    /**
     * Q1: the actual observer-close adapter, and the end -> refresh -> final
     * idempotent close sequence through the real preference lifetime.
     */
    static void adapterControls(JSONObject result) throws Throwable {
        JSONObject outcome = new JSONObject();
        JSONObject nested = new JSONObject()
            .put("events", 1)
            .put("removal", new JSONObject().put("removed", true).put("onMain", true));
        JSONObject idempotent = new JSONObject()
            .put("alreadyClosed", true).put("removed", true).put("events", 1);
        JSONObject bareRemoved = new JSONObject().put("removed", true);
        JSONObject failed = new JSONObject()
            .put("removal", new JSONObject().put("removed", true)).put("failed", true);
        JSONObject foreign = new JSONObject()
            .put("removal", new JSONObject().put("removed", true)).put("foreignEvents", 1);
        JSONObject callbackError = new JSONObject()
            .put("removal", new JSONObject().put("removed", true)).put("callbackErrors", 1);

        outcome.put("nestedAccepted",
                FieldOracle.adaptObserverClose(nested).optBoolean("closed"))
            .put("idempotentAccepted",
                FieldOracle.adaptObserverClose(idempotent).optBoolean("closed"))
            .put("bareRemovedRejected",
                !FieldOracle.adaptObserverClose(bareRemoved).optBoolean("closed"))
            .put("failedRejected",
                !FieldOracle.adaptObserverClose(failed).optBoolean("closed"))
            .put("foreignRejected",
                !FieldOracle.adaptObserverClose(foreign).optBoolean("closed"))
            .put("callbackErrorRejected",
                !FieldOracle.adaptObserverClose(callbackError).optBoolean("closed"));

        // The real saved-case lifetime: end (nested) -> refresh -> final
        // idempotent close, all through the production adapter.
        Preferences preferences = new Preferences();
        JSONObject proof = new JSONObject();
        final int[] refreshes = {0};
        final int[] closes = {0};
        FieldOracle.TocCountWordsLifetime.run(preferences,
            () -> new JSONObject().put("registered", true),
            () -> {
                // The first end acknowledgement is the nested removal shape.
                if (!FieldOracle.adaptObserverClose(nested).optBoolean("closed")) {
                    throw new IllegalStateException("the first end was not acknowledged");
                }
                refreshes[0]++;
                return new JSONObject().put("refreshed", true);
            },
            () -> {
                closes[0]++;
                // The final close is the acknowledged idempotent shape.
                return FieldOracle.adaptObserverClose(idempotent);
            },
            proof);
        outcome.put("endBeforeRefresh", refreshes[0] == 1)
            .put("finalIdempotentClose", closes[0] == 1)
            .put("lifetimeClosed", !preferences.contains("tocCountWords"));
        result.put("adapter", outcome);
        require(outcome.optBoolean("nestedAccepted")
            && outcome.optBoolean("idempotentAccepted")
            && outcome.optBoolean("bareRemovedRejected")
            && outcome.optBoolean("failedRejected")
            && outcome.optBoolean("foreignRejected")
            && outcome.optBoolean("callbackErrorRejected")
            && outcome.optBoolean("endBeforeRefresh")
            && outcome.optBoolean("finalIdempotentClose")
            && outcome.optBoolean("lifetimeClosed"),
            "every adapter/close path must behave: " + outcome);
    }

    /**
     * The actual outer/per-case lifetime algorithm, driven directly.
     *
     * <p>Every scenario calls the same production seams the collector uses:
     * {@code FieldOracle.runWithCleanup} for the outer lifetime and
     * {@code FieldOracle.TocCountWordsLifetime.run} for the saved case. Only the
     * body/operation callbacks and the SharedPreferences implementation are
     * controlled inputs.
     */
    static void lifetimeControls(JSONObject result) throws Throwable {
        JSONObject outcome = new JSONObject();
        // 1. A throwing body still runs the cleanup and the ORIGINAL error escapes.
        final boolean[] cleaned = {false};
        RuntimeException setupError = new IllegalStateException("setup failed before report");
        Throwable bodyFailure = null;
        try {
            FieldOracle.runWithCleanup(
                () -> { throw setupError; },
                () -> { cleaned[0] = true; return new JSONObject().put("closed", true); });
        } catch (Throwable error) {
            bodyFailure = error;
        }
        outcome.put("bodyFailureStillCleans", cleaned[0])
            .put("bodyFailureIsOriginal", bodyFailure == setupError);
        // 2. A cleanup failure alone escapes.
        RuntimeException closeError = new IllegalStateException("guard close failed");
        Throwable cleanupOnly = null;
        try {
            FieldOracle.runWithCleanup(() -> new JSONObject().put("ok", true),
                () -> { throw closeError; });
        } catch (Throwable error) {
            cleanupOnly = error;
        }
        outcome.put("cleanupOnlyIsOriginal", cleanupOnly == closeError);
        // 3. Both identities survive, the cleanup suppressed on the primary.
        RuntimeException bodyId = new IllegalStateException("BODY_ID");
        RuntimeException closeId = new IllegalStateException("CLOSE_ID");
        Throwable both = null;
        try {
            FieldOracle.runWithCleanup(() -> { throw bodyId; }, () -> { throw closeId; });
        } catch (Throwable error) {
            both = error;
        }
        String bothChain = FieldOracle.describeChain(both);
        outcome.put("bothPrimaryRetained", both == bodyId)
            .put("bothCleanupRetained", both != null && containsThrowable(both, closeId))
            .put("bothChainSerialized", bothChain.contains("BODY_ID")
                && bothChain.contains("CLOSE_ID") && bothChain.contains("Suppressed"));
        // 4. A clean body and a proved close succeed and return the body result.
        JSONObject bodyValue = new JSONObject().put("body", true);
        Object actual = FieldOracle.runWithCleanup(() -> bodyValue,
            () -> new JSONObject().put("closed", true));
        outcome.put("cleanReturnsBodyResult", actual == bodyValue);
        // 5. A false or missing closed proof is a failure, never a success.
        boolean falseClosureFailed = false;
        try {
            FieldOracle.runWithCleanup(() -> new JSONObject(),
                () -> new JSONObject().put("closed", false));
        } catch (Throwable error) {
            falseClosureFailed = true;
        }
        boolean missingClosureFailed = false;
        try {
            FieldOracle.runWithCleanup(() -> new JSONObject(), JSONObject::new);
        } catch (Throwable error) {
            missingClosureFailed = true;
        }
        outcome.put("falseClosureFailed", falseClosureFailed)
            .put("missingClosureFailed", missingClosureFailed);
        // 6. The production saved-case lifetime: prior absent, apply, operation,
        //    close, restore, with the applied and restored receipts in proof.
        Preferences preferences = new Preferences();
        JSONObject proof = new JSONObject();
        final int[] closes = {0};
        FieldOracle.TocCountWordsLifetime.run(preferences,
            () -> new JSONObject().put("registered", true),
            () -> {
                if (!preferences.getBoolean("tocCountWords", false)) {
                    throw new IllegalStateException("the preference was not applied first");
                }
                return new JSONObject().put("operated", true);
            },
            () -> { closes[0]++; return new JSONObject().put("closed", true); },
            proof);
        outcome.put("absentRestored", !preferences.contains("tocCountWords"))
            .put("absentAppliedProof", proof.has("tocCountWordsApplied"))
            .put("absentRestoredProof", proof.has("tocCountWords"))
            .put("absentClosedOnce", closes[0] == 1);
        // 7. Prior false present restores the value.
        Preferences priorFalse = new Preferences();
        priorFalse.values.put("tocCountWords", Boolean.FALSE);
        FieldOracle.TocCountWordsLifetime.run(priorFalse,
            () -> new JSONObject().put("registered", true), JSONObject::new,
            () -> new JSONObject().put("closed", true), new JSONObject());
        outcome.put("priorFalseRestored", priorFalse.contains("tocCountWords")
            && !priorFalse.getBoolean("tocCountWords", true));
        // 8. A throwing begin still enters the owned cleanup.
        Preferences beginPrefs = new Preferences();
        RuntimeException beginError = new IllegalStateException("BEGIN_AFTER_EFFECT");
        final int[] beginCloses = {0};
        Throwable beginFailure = null;
        try {
            FieldOracle.TocCountWordsLifetime.run(beginPrefs,
                () -> { throw beginError; }, JSONObject::new,
                () -> { beginCloses[0]++; return new JSONObject().put("closed", true); },
                new JSONObject());
        } catch (Throwable error) {
            beginFailure = error;
        }
        outcome.put("beginErrorRetained", beginFailure == beginError)
            .put("beginErrorStillCloses", beginCloses[0] == 1)
            .put("beginErrorRestored", !beginPrefs.contains("tocCountWords"));
        // 9. A false commit AFTER the mutation restores and skips the operation.
        Preferences partial = new Preferences();
        partial.refuseCommit = true;
        final int[] operated = {0};
        Throwable partialFailure = null;
        try {
            FieldOracle.TocCountWordsLifetime.run(partial,
                () -> new JSONObject().put("registered", true),
                () -> { operated[0]++; return new JSONObject(); },
                () -> new JSONObject().put("closed", true), new JSONObject());
        } catch (Throwable error) {
            partialFailure = error;
        }
        outcome.put("partialCommitFailed", partialFailure != null)
            .put("partialCommitRestored", !partial.contains("tocCountWords"))
            .put("partialCommitSkippedOperation", operated[0] == 0);
        // 10. An apply readback throw AFTER the mutation preserves the error and
        //     still restores.
        Preferences readback = new Preferences();
        RuntimeException readError = new IllegalStateException("READ_AFTER_MUTATION");
        readback.readError = readError;
        readback.throwReadAfterWrite = true;
        Throwable readbackFailure = null;
        try {
            FieldOracle.TocCountWordsLifetime.run(readback,
                () -> new JSONObject().put("registered", true), JSONObject::new,
                () -> new JSONObject().put("closed", true), new JSONObject());
        } catch (Throwable error) {
            readbackFailure = error;
        }
        outcome.put("readbackErrorRetained", readbackFailure == readError)
            .put("readbackErrorRestored", !readback.contains("tocCountWords"));
        // 11. An operation failure restores in the production lifetime.
        Preferences operation = new Preferences();
        RuntimeException operationError = new IllegalStateException("OPERATION");
        Throwable operationFailure = null;
        try {
            FieldOracle.TocCountWordsLifetime.run(operation,
                () -> new JSONObject().put("registered", true),
                () -> { throw operationError; },
                () -> new JSONObject().put("closed", true), new JSONObject());
        } catch (Throwable error) {
            operationFailure = error;
        }
        outcome.put("operationErrorRetained", operationFailure == operationError)
            .put("operationErrorRestored", !operation.contains("tocCountWords"));
        // 12. Body, observer-close and restore errors all survive the REAL
        //     shared cleanup, with the complete chain serialized.
        Preferences combined = new Preferences();
        RuntimeException combinedBody = new IllegalStateException("BODY_ID");
        RuntimeException combinedClose = new IllegalStateException("OBSERVER_ID");
        RuntimeException combinedRestore = new IllegalStateException("RESTORE_ID");
        Throwable combinedFailure = null;
        try {
            FieldOracle.TocCountWordsLifetime.run(combined,
                () -> new JSONObject().put("registered", true),
                () -> { throw combinedBody; },
                () -> { combined.commitError = combinedRestore; throw combinedClose; },
                new JSONObject());
        } catch (Throwable error) {
            combinedFailure = error;
        }
        String combinedChain = FieldOracle.describeChain(combinedFailure);
        outcome.put("combinedPrimaryRetained", combinedFailure == combinedBody)
            .put("combinedObserverRetained",
                combinedFailure != null && containsThrowable(combinedFailure, combinedClose))
            .put("combinedRestoreRetained",
                combinedFailure != null && containsThrowable(combinedFailure, combinedRestore))
            .put("combinedChainSerialized", combinedChain.contains("BODY_ID")
                && combinedChain.contains("OBSERVER_ID")
                && combinedChain.contains("RESTORE_ID"));
        result.put("lifetime", outcome);
        require(outcome.optBoolean("bodyFailureStillCleans")
            && outcome.optBoolean("bodyFailureIsOriginal")
            && outcome.optBoolean("cleanupOnlyIsOriginal")
            && outcome.optBoolean("bothPrimaryRetained")
            && outcome.optBoolean("bothCleanupRetained")
            && outcome.optBoolean("bothChainSerialized")
            && outcome.optBoolean("cleanReturnsBodyResult")
            && outcome.optBoolean("falseClosureFailed")
            && outcome.optBoolean("missingClosureFailed")
            && outcome.optBoolean("absentRestored")
            && outcome.optBoolean("absentAppliedProof")
            && outcome.optBoolean("absentRestoredProof")
            && outcome.optBoolean("absentClosedOnce")
            && outcome.optBoolean("priorFalseRestored")
            && outcome.optBoolean("beginErrorRetained")
            && outcome.optBoolean("beginErrorStillCloses")
            && outcome.optBoolean("beginErrorRestored")
            && outcome.optBoolean("partialCommitFailed")
            && outcome.optBoolean("partialCommitRestored")
            && outcome.optBoolean("partialCommitSkippedOperation")
            && outcome.optBoolean("readbackErrorRetained")
            && outcome.optBoolean("readbackErrorRestored")
            && outcome.optBoolean("operationErrorRetained")
            && outcome.optBoolean("operationErrorRestored")
            && outcome.optBoolean("combinedPrimaryRetained")
            && outcome.optBoolean("combinedObserverRetained")
            && outcome.optBoolean("combinedRestoreRetained")
            && outcome.optBoolean("combinedChainSerialized"),
            "every lifetime path must behave: " + outcome);
    }

    /** Whether a throwable identity survives anywhere in a cause/suppressed chain. */
    static boolean containsThrowable(Throwable root, Throwable wanted) {
        java.util.Set<Throwable> seen =
            java.util.Collections.newSetFromMap(new java.util.IdentityHashMap<Throwable, Boolean>());
        java.util.ArrayDeque<Throwable> queue = new java.util.ArrayDeque<>();
        if (root != null) queue.add(root);
        while (!queue.isEmpty()) {
            Throwable current = queue.remove();
            if (current == wanted) return true;
            if (!seen.add(current)) continue;
            if (current.getCause() != null) queue.add(current.getCause());
            for (Throwable suppressed : current.getSuppressed()) queue.add(suppressed);
        }
        return false;
    }

    static final class TocCountWordsCapture {
        static JSONObject capture(Preferences preferences) throws Exception {
            return FieldOracle.TocCountWordsLifetime.capture(preferences);
        }

        static JSONObject apply(Preferences preferences, boolean value) throws Exception {
            return FieldOracle.TocCountWordsLifetime.apply(preferences, value);
        }

        static JSONObject restore(Preferences preferences, JSONObject prior) throws Exception {
            return FieldOracle.TocCountWordsLifetime.restore(preferences, prior);
        }
    }

    /**
     * The tolerated legacy replay close never tolerates its own reporting
     * failure, and a selected run is never accepted without a proved closure.
     */
    static void loggerControls(JSONObject result) throws Exception {
        JSONObject closed = new JSONObject().put("closed", true);
        JSONObject notApplicable = new JSONObject().put("applicable", false);
        JSONObject outcome = new JSONObject();
        // (a) the legacy replay close alone stays tolerated and accepted, while
        // the resource facts still say the replay did not close.
        JSONObject tolerated = null;
        try {
            tolerated = FieldOracle.runOuterSequence(
                () -> closed,
                () -> { throw new IllegalStateException("LEGACY_REPLAY"); },
                () -> notApplicable, () -> notApplicable, () -> notApplicable,
                () -> notApplicable,
                proved -> new JSONObject().put("applicable", false),
                () -> closed, false, false, new JSONObject());
        } catch (Throwable error) {
            tolerated = null;
        }
        outcome.put("replayAloneAccepted", tolerated != null
            && tolerated.optBoolean("accepted") && !tolerated.optBoolean("closed")
            && !tolerated.optBoolean("closureProved"));
        // (b) the same replay close plus a logger failure is fatal, and both
        // errors stay in the chain.
        String replayLogChain = null;
        android.util.Log.inject = true;
        try {
            FieldOracle.runOuterSequence(
                () -> closed,
                () -> { throw new IllegalStateException("LEGACY_REPLAY"); },
                () -> notApplicable, () -> notApplicable, () -> notApplicable,
                () -> notApplicable,
                proved -> new JSONObject().put("applicable", false),
                () -> closed, false, false, new JSONObject());
        } catch (Throwable error) {
            replayLogChain = FieldOracle.describeChain(error);
        } finally {
            android.util.Log.inject = false;
        }
        outcome.put("replayLogFatal", replayLogChain != null);
        outcome.put("replayLogChain", replayLogChain);
        // (c) a selected run with an unproved terminal is rejected by the actual
        // caller even though no work callback threw.
        boolean unprovedRejected = false;
        try {
            FieldOracle.runWithCleanup(JSONObject::new, () -> FieldOracle.runOuterSequence(
                () -> closed,
                () -> new JSONObject().put("serverClosed", true)
                    .put("openConnectionsAfterClose", 0),
                () -> closed, () -> closed,
                () -> new JSONObject().put("closed", false).put("proved", false),
                () -> notApplicable,
                proved -> new JSONObject().put("closed", proved).put("ownerComplete", proved),
                () -> closed, false, true, new JSONObject()));
        } catch (Throwable error) {
            unprovedRejected = true;
        }
        outcome.put("unprovedSelectedRejected", unprovedRejected);
        result.put("logger", outcome);
        // Only the logger failure is fatal; the domain's own replay error stays
        // tolerated, so the aggregate names exactly one fatal failure.
        require(outcome.optBoolean("replayAloneAccepted")
            && outcome.optBoolean("replayLogFatal")
            && replayLogChain != null
            && replayLogChain.contains("1 fatal failure(s)")
            && replayLogChain.contains("OS_LOG_ERROR")
            && !replayLogChain.contains("LEGACY_REPLAY")
            && outcome.optBoolean("unprovedSelectedRejected"),
            "a tolerated replay close must not tolerate its own logger failure: " + outcome);
    }

    public static void main(String[] args) throws Exception {
        JSONObject result = new JSONObject().put("control", args[0]);
        if (args[0].equals("replay")) replayControls(result);
        else if (args[0].equals("preference")) preferenceControls(result);
        else if (args[0].equals("outer")) outerControls(result);
        else if (args[0].equals("caller")) callerControls(result);
        else if (args[0].equals("reporting")) reportingControls(result);
        else if (args[0].equals("logger")) loggerControls(result);
        else if (args[0].equals("adapter")) {
            try {
                adapterControls(result);
            } catch (Throwable error) {
                throw error instanceof Exception ? (Exception) error
                    : new IllegalStateException(error);
            }
        }
        else if (args[0].equals("lifetime")) {
            try {
                lifetimeControls(result);
            } catch (Throwable error) {
                throw error instanceof Exception ? (Exception) error
                    : new IllegalStateException(error);
            }
        }
        else throw new IllegalArgumentException("unknown control " + args[0]);
        result.put("ok", true);
        System.out.println(result.toString());
    }
}
'''


class GuardedReaderApplicationHostTest(unittest.TestCase):
    """Actual behavioural controls for the capture guard, replay and preference.

    The fakes are emitted from this committed test module, so the suite runs from
    a normal checkout with no PYTHONPATH and no private helper. The guard
    controls run in a fresh JVM each; the replay and preference controls compile
    the actual SDK sources and run over real loopback HTTP.
    """

    GUARD_CONTROLS = (
        'inactive-unchanged', 'exact-registration', 'two-arg-refused',
        'wrong-registrations', 'ipc-not-delivered', 'registration-failure',
        'foreign-unregister-refused', 'failed-release-retains',
        'double-end-idempotent', 'release-closes-observer',
        'owner-not-overwritten', 'arm-rejects', 'foreign-event-fails',
        'abandoned-registration', 'two-saved-cases',
    )

    def _java_home(self):
        candidates = []
        if os.environ.get('JAVA_HOME'):
            candidates.append(Path(os.environ['JAVA_HOME']))
        candidates.append(Path.home() / '.cache/wayfinder/temurin-17/jdk-17.0.20+8')
        candidates.append(Path('C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8'))
        for candidate in candidates:
            if (candidate / 'bin' / 'javac.exe').is_file():
                return candidate
        raise unittest.SkipTest('no pinned JDK is discoverable')

    def _android_jar(self):
        roots = [Path(os.environ.get('ANDROID_HOME', '')),
                 Path(os.environ.get('ANDROID_SDK_ROOT', '')),
                 Path(os.environ.get('LOCALAPPDATA', '')) / 'Android/Sdk',
                 Path('C:/Users/17945/AppData/Local/Android/Sdk')]
        for root in roots:
            jar = root / 'platforms/android-35/android.jar'
            if jar.is_file():
                return jar
        raise unittest.SkipTest('no android-35 SDK platform is discoverable')

    def _json_jar(self):
        for root in (Path.home() / '.gradle/caches',
                     Path('C:/Users/17945/.gradle/caches')):
            found = sorted(root.glob('**/instrumented-json-20180813.jar'))
            if found:
                return found[0]
        raise unittest.SkipTest('no installed org.json jar is discoverable')

    def _repo(self):
        return Path(__file__).resolve().parent.parent.parent

    def _run(self, argv, cwd):
        return subprocess.run(argv, cwd=str(cwd), capture_output=True, timeout=600)

    def test_the_actual_guard_controls_pass(self):
        java = self._java_home()
        jar = self._json_jar()
        repo = self._repo()
        with tempfile.TemporaryDirectory(prefix='r2afix-guard-') as directory:
            root = Path(directory)
            sources = []
            for name, text in GUARD_FAKES.items():
                path = root / 'fakes' / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(text, encoding='utf-8')
                sources.append(path)
            sources.append(
                repo / 'tool/replace_rule_oracle/GuardedReaderApplication.java')
            sources.append(repo / 'test/GuardedReaderApplicationTest.java')
            classes = root / 'classes'
            classes.mkdir()
            compiled = self._run(
                [str(java / 'bin' / 'javac.exe'), '-source', '8', '-target', '8',
                 '-nowarn', '-cp', str(jar), '-d', str(classes)]
                + [str(path) for path in sources], repo)
            self.assertEqual(compiled.returncode, 0,
                             compiled.stderr.decode(errors='replace'))
            outcomes = {}
            for control in self.GUARD_CONTROLS:
                run = self._run(
                    [str(java / 'bin' / 'java.exe'), '-cp',
                     str(classes) + os.pathsep + str(jar),
                     'io.liber.oracle.nested.GuardedReaderApplicationTest', control], repo)
                stdout = run.stdout.decode(errors='replace').strip()
                self.assertEqual(
                    run.returncode, 0,
                    control + ': ' + stdout + run.stderr.decode(errors='replace'))
                outcomes[control] = json.loads(stdout.splitlines()[-1])
            self.assertEqual(len(outcomes), len(self.GUARD_CONTROLS))

    def test_the_actual_replay_and_preference_controls_pass(self):
        java = self._java_home()
        android = self._android_jar()
        jar = self._json_jar()
        repo = self._repo()
        with tempfile.TemporaryDirectory(prefix='r2afix-sdk-') as directory:
            root = Path(directory)
            classes = root / 'actual-classes'
            classes.mkdir()
            sources = [
                repo / 'tool/nested_oracle/StateSessionOracle.java',
                repo / 'tool/nested_oracle/HostRuntimeInit.java',
                repo / 'tool/nested_oracle/ShortcutStartupGuard.java',
                repo / 'tool/result_field_oracle/FieldOracle.java',
                repo / 'tool/replace_rule_oracle/GuardedReaderApplication.java',
                repo / 'tool/result_field_oracle/SelectedFieldHostBridge.java',
            ]
            compiled = self._run(
                [str(java / 'bin' / 'javac.exe'), '-source', '8', '-target', '8',
                 '-encoding', 'UTF-8', '-cp', str(android), '-d', str(classes)]
                + [str(path) for path in sources], repo)
            self.assertEqual(compiled.returncode, 0,
                             compiled.stderr.decode(errors='replace'))
            fixture = root / 'StageAFixture.java'
            fixture.write_text(REPLAY_FIXTURE, encoding='utf-8')
            log = root / 'fakes' / 'android' / 'util' / 'Log.java'
            log.parent.mkdir(parents=True, exist_ok=True)
            log.write_text(LOG_STUB, encoding='utf-8')
            classpath = os.pathsep.join([str(classes), str(jar), str(android)])
            fixture_compiled = self._run(
                [str(java / 'bin' / 'javac.exe'), '-source', '8', '-target', '8',
                 '-cp', classpath, '-d', str(classes), str(fixture), str(log)], repo)
            self.assertEqual(fixture_compiled.returncode, 0,
                             fixture_compiled.stderr.decode(errors='replace'))
            for control in ('replay', 'preference', 'lifetime', 'outer', 'adapter',
                            'caller', 'reporting', 'logger'):
                run = self._run(
                    [str(java / 'bin' / 'java.exe'), '-cp', classpath,
                     'io.liber.oracle.fields.StageAFixture', control], repo)
                stdout = run.stdout.decode(errors='replace').strip()
                self.assertEqual(
                    run.returncode, 0,
                    control + ': ' + stdout + run.stderr.decode(errors='replace'))
                self.assertTrue(json.loads(stdout.splitlines()[-1])['ok'], control)


class SelectedReceiptTest(unittest.TestCase):
    def test_complete_selected_receipts_and_raw_report_tamper(self):
        from unittest.mock import patch
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            selected_apk = os.environ.get('FIELDS_SELECTED_HARNESS_APK')
            selected_target = os.environ.get('FIELDS_SELECTED_TARGET_APK')
            if bool(selected_apk) != bool(selected_target):
                self.fail('supply both selected actual APK paths or neither')
            target = Path(selected_target).read_bytes() if selected_target else _SYNTHETIC_TARGET_APK
            harness = Path(selected_apk).read_bytes() if selected_apk else _SYNTHETIC_HARNESS_APK
            (output / 'frozen.apk').write_bytes(target)
            (output / 'installed-harness.apk').write_bytes(harness)
            target_sha = capture.sha256_bytes(target)
            artifact = {'synthetic': True}
            if selected_apk:
                fixture_path = Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json')
                fixture = json.loads(fixture_path.read_bytes())
                self.assertEqual(target_sha, capture.SELECTED_TARGET['apkSha256'])
                artifact = capture.inspect_selected_apk(selected_apk, fixture_path, fixture,
                                                        capture.harness_source_hashes(selected=True))
            prefix = ['adb', '-s', '5615f742']
            target_package = capture.SELECTED_TARGET['package']
            root = '/data/user/0/' + target_package
            scratch = root + '/cache/liber-fields-02'
            prefs = root + '/shared_prefs'
            owner = {'seedPid': 4242, 'preferences': ['liber_fields_02_probe']}
            report = b'{"mechanics-only":true}'
            before = b'synthetic-before'
            after = b'synthetic-after'
            manifest = {'serial': '5615f742', 'targetPrivateRoot': root,
                        'scratchOwner': owner, 'harnessApkSha256': capture.sha256_bytes(harness),
                        'artifact': artifact, 'frozenSources': {'synthetic': True},
                        'preflight': {'targetApkSha256': target_sha, 'artifact': artifact,
                                      'referenceSources': {'synthetic': True}}, 'commands': []}
            def add(name, args, data=b'', code=0):
                log = name + '.log'
                (output / log).write_bytes(data)
                manifest['commands'].append({'command': prefix + args, 'exitCode': code, 'log': log})
            def shell(script):
                return ['shell', *capture.remote_script_arguments(target_package, script)]
            add('fingerprint', ['shell', 'getprop', 'ro.build.fingerprint'],
                (capture.SELECTED_TARGET['deviceFingerprint'] + '\n').encode())
            add('sdk', ['shell', 'getprop', 'ro.build.version.sdk'], b'37\n')
            add('webview', ['shell', 'dumpsys', 'webviewupdate'],
                b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n')
            add('baseline-path', ['shell', 'pm', 'path', target_package], b'package:/target.apk\n')
            add('pull-baseline', ['pull', '/target.apk', str(output / 'frozen.apk')])
            add('harness-existing', ['shell', 'pm', 'list', 'packages', capture.PACKAGE])
            add('target-process', ['shell', 'pidof', target_package], code=1)
            add('target-private-root', ['shell', 'run-as', target_package, 'pwd'], (root + '\n').encode())
            add('scratch-root-check', shell('if [ -e ' + shlex.quote(scratch) + ' ]; then echo PRESENT; else echo ABSENT; fi'), b'ABSENT\n')
            add('scratch-prefs-check', shell('if [ -d ' + shlex.quote(prefs) + ' ]; then find ' + shlex.quote(prefs) + ' -maxdepth 1 -name ' + shlex.quote(capture.OWNED_PREFERENCE_PREFIX + '*.xml') + ' -print; fi'))
            add('scratch-installation-probe-check', shell('if [ -e ' + shlex.quote(prefs + '/probe.xml') + ' ]; then echo PRESENT; fi'))
            add('private-before', shell(capture._fields_snapshot_script(root)), before)
            add('install', ['install', '-r', '/synthetic/harness.apk'], b'Success\n')
            add('installed-harness-path', ['shell', 'pm', 'path', capture.PACKAGE], b'package:/installed.apk\n')
            add('installed-harness-pull', ['pull', '/installed.apk', str(output / 'installed-harness.apk')])
            add('instrumentation', ['shell', 'am', 'instrument', '-w', '-r', capture.INSTRUMENTATION], b'INSTRUMENTATION_CODE: -1\n')
            add('pull-report', ['exec-out', 'run-as', target_package, 'cat', scratch + '/field-oracle.json'], report)
            add('scratch-owner', ['exec-out', 'run-as', target_package, 'cat', scratch + '/owner.json'], json.dumps(owner).encode())
            add('owned-pid', ['shell', 'pidof', target_package], b'4242\n')
            add('poststop', ['shell', 'am', 'force-stop', target_package])
            add('poststop-check', ['shell', 'pidof', target_package], code=1)
            preference = prefs + '/liber_fields_02_probe.xml'
            add('scratch-remove-1', shell('rm -f -- ' + shlex.quote(preference)))
            add('scratch-remove-root', shell('rm -rf -- ' + shlex.quote(scratch)))
            add('scratch-absent-1', shell('test ! -e ' + shlex.quote(preference)))
            add('scratch-absent-root', shell('test ! -e ' + shlex.quote(scratch)))
            add('remove-harness', ['uninstall', capture.PACKAGE], b'Success\n')
            add('harness-removed-check', ['shell', 'pm', 'list', 'packages', capture.PACKAGE])
            add('private-after', shell(capture._fields_snapshot_script(root)), after)
            fixture = json.loads(Path(__file__).resolve().with_name('book-url-markers-fixtures-selected.json').read_bytes())
            references = {r['path']: {'blobSha1': r['sha1'], 'worktreeSha256': 'a' * 64} for r in fixture['frozenSources']}
            manifest['frozenSources'] = references
            with zipfile.ZipFile(io.BytesIO(target)) as archive:
                reference_dex_sha = capture.sha256_bytes(archive.read('classes19.dex'))
            with zipfile.ZipFile(io.BytesIO(harness)) as archive:
                harness_dex_sha = capture.sha256_bytes(archive.read('classes.dex'))
            manifest['preflight'] = _synthetic_selected_preflight(
                output, fixture, artifact, '/synthetic/harness.apk', '/synthetic/reference.apk',
                output / 'source', output / 'sdk', output / 'java', references,
                reference_dex_sha=reference_dex_sha, harness_dex_sha=harness_dex_sha)
            manifest['preflight']['targetApkSha256'] = target_sha
            with patch.dict(capture.SELECTED_TARGET, {'apkSha256': target_sha}):
                capture._admit_selected_commands(output, manifest, report, before, after)
                dex = next(item for item in manifest['preflight']['commands'] if item['name'] == 'dex')
                original_dex_command = dex['command']
                dex['command'] = ['not-the-SDK', 'wrong.dex']
                with self.assertRaisesRegex(ValueError, 'preflight command'):
                    capture._admit_selected_commands(output, manifest, report, before, after)
                dex['command'] = original_dex_command
                signer = next(item for item in manifest['preflight']['commands'] if item['name'] == 'target-signature')
                original_target_apk = signer['command'][-1]
                signer['command'][-1] = '/synthetic/wrong-reference.apk'
                with self.assertRaisesRegex(ValueError, 'preflight command signer binding'):
                    capture._admit_selected_commands(output, manifest, report, before, after)
                signer['command'][-1] = original_target_apk
                for operation in ('java-version', 'javac-version', 'source-head', 'source-tree',
                                  'source-status', 'source-blobs', 'manifest', 'harness-signature',
                                  'target-signature', 'reference-dex', 'dex'):
                    receipt = next(item for item in manifest['preflight']['commands'] if item['name'] == operation)
                    original_command = receipt['command']
                    receipt['command'] = [*original_command, 'unexpected-argument']
                    with self.subTest(preflight=operation), self.assertRaisesRegex(ValueError, 'preflight command'):
                        capture._admit_selected_commands(output, manifest, report, before, after)
                    receipt['command'] = original_command
                for name, bad in [('poststop', b'Error: force-stop failed\n'),
                                  ('scratch-remove-root', b'rm: Permission denied\n')]:
                    log = output / (name + '.log')
                    log.write_bytes(bad)
                    with self.assertRaisesRegex(ValueError, 'contradictory'):
                        capture._admit_selected_commands(output, manifest, report, before, after)
                    log.write_bytes(b'')
                instrumentation = output / 'instrumentation.log'
                for bad in (b'INSTRUMENTATION_CODE: -1\nINSTRUMENTATION_CODE: 1\n',
                            b'INSTRUMENTATION_CODE: -1\nINSTRUMENTATION_CODE: malformed\n'):
                    instrumentation.write_bytes(bad)
                    with self.assertRaisesRegex(ValueError, 'instrumentation'):
                        capture._admit_selected_commands(output, manifest, report, before, after)
                instrumentation.write_bytes(b'INSTRUMENTATION_CODE: -1\n')
                import shutil
                with tempfile.TemporaryDirectory() as copied_parent:
                    copied = Path(copied_parent) / 'copied-evidence'
                    shutil.copytree(output, copied)
                    capture._admit_selected_commands(copied, manifest, report, before, after)
                target_pull = next(item for item in manifest['commands'] if item['log'] == 'pull-baseline.log')
                original_destination = target_pull['command'][-1]
                target_pull['command'][-1] = str(Path(original_destination).with_name('wrong.apk'))
                with self.assertRaisesRegex(ValueError, 'target pull command differs'):
                    capture._admit_selected_commands(output, manifest, report, before, after)
                target_pull['command'][-1] = original_destination
                harness_pull = next(item for item in manifest['commands'] if item['log'] == 'installed-harness-pull.log')
                original_destination = harness_pull['command'][-1]
                harness_pull['command'][-1] = str(Path(original_destination).parent / 'other' / 'installed-harness.apk')
                with self.assertRaisesRegex(ValueError, 'installed harness pull command differs'):
                    capture._admit_selected_commands(output, manifest, report, before, after)
                harness_pull['command'][-1] = original_destination
                (output / 'pull-report.log').write_bytes(report + b' ')
                with self.assertRaisesRegex(ValueError, 'raw report differs'):
                    capture._admit_selected_commands(output, manifest, report, before, after)
                (output / 'pull-report.log').write_bytes(report)
                (output / 'preflight-dex.stdout.log').write_bytes(b'tampered')
                with self.assertRaisesRegex(ValueError, 'preflight command output'):
                    capture._admit_selected_commands(output, manifest, report, before, after)


class CaptureBoundaryTest(unittest.TestCase):
    def test_remote_script_is_one_quoted_argument(self):
        args = capture.remote_script_arguments(
            'io.legado.app.debug',
            "rm -f '/data/data/x/a.xml'; test ! -e '/data/data/x'",
        )
        self.assertEqual(args[:4], ['run-as', 'io.legado.app.debug', 'sh', '-c'])
        self.assertEqual(len(args), 5)
        self.assertTrue(args[4].startswith("'") and args[4].endswith("'"))
        self.assertIn(';', args[4])

    def test_conflicting_existing_golden_is_never_deleted(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            sentinel = b'{"accepted":"do-not-touch"}\n'
            (output / 'golden.json').write_bytes(sentinel)
            (output / 'field-oracle.json').write_bytes(b'{"different":true}\n')
            with self.assertRaises(ValueError):
                capture._finalize_fields_02(output, {}, {}, {},
                                            b'', b'', scratch_cleanup=None)
            self.assertEqual((output / 'golden.json').read_bytes(), sentinel)

    def test_selected_failure_receipts_preserve_each_failure_and_evidence(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            originals = {'field-oracle.json': b'{"report":"unchanged"}\n',
                         'manifest.json': b'{"manifest":"unchanged"}\n',
                         'golden.json': b'{"golden":"unchanged"}\n'}
            for name, data in originals.items():
                (output / name).write_bytes(data)
            first = capture._write_finalize_failure(output, 'first', preserve_existing=True)
            first_bytes = first.read_bytes()
            second = capture._write_finalize_failure(output, 'second', preserve_existing=True)
            self.assertEqual(first.name, 'finalize-failure.json')
            self.assertNotEqual(first, second)
            self.assertRegex(second.name, r'^finalize-failure-[0-9a-f-]+\.json$')
            self.assertEqual(first.read_bytes(), first_bytes)
            self.assertEqual(json.loads(first_bytes)['error'], 'first')
            self.assertEqual(json.loads(second.read_bytes())['error'], 'second')
            for name, data in originals.items():
                self.assertEqual((output / name).read_bytes(), data)

    def test_selected_cli_preflight_failures_preserve_existing_receipts(self):
        directory = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            originals = {'field-oracle.json': b'{"report":"synthetic"}\n',
                         'manifest.json': b'{"status":"synthetic"}\n',
                         'golden.json': b'{"golden":"synthetic"}\n'}
            for name, data in originals.items():
                (output / name).write_bytes(data)
            command = [sys.executable, str(directory / 'capture.py'), '--finalize',
                       '--serial', '5615f742', '--fixture', str(directory / 'book-url-markers-fixtures-selected.json'),
                       '--apk', 'unused.apk', '--target-apk', 'missing-target.apk',
                       '--frozen-source', 'unused-source', '--java-home', 'unused-java',
                       '--output', str(output)]
            first = subprocess.run(command, capture_output=True, text=True)
            first_path = output / 'finalize-failure.json'
            first_bytes = first_path.read_bytes()
            second = subprocess.run(command, capture_output=True, text=True)
            self.assertNotEqual(first.returncode, 0)
            self.assertNotEqual(second.returncode, 0)
            self.assertIn('selected target APK', first.stderr)
            self.assertEqual(first_path.read_bytes(), first_bytes)
            receipts = list(output.glob('finalize-failure*.json'))
            self.assertEqual(len(receipts), 2)
            self.assertTrue(all('selected target APK' in json.loads(path.read_bytes())['error'] for path in receipts))
            for name, data in originals.items():
                self.assertEqual((output / name).read_bytes(), data)

    def test_selected_finalize_missing_report_records_immutable_failure(self):
        import io
        from contextlib import redirect_stderr
        from unittest.mock import patch
        directory = Path(__file__).resolve().parent
        with tempfile.TemporaryDirectory() as temporary:
            output = Path(temporary)
            manifest = b'{"status":"synthetic"}\n'
            (output / 'manifest.json').write_bytes(manifest)
            argv = ['capture.py', '--finalize', '--serial', '5615f742',
                    '--fixture', str(directory / 'book-url-markers-fixtures-selected.json'),
                    '--apk', 'synthetic.apk', '--target-apk', 'synthetic-target.apk',
                    '--frozen-source', 'synthetic-source', '--java-home', 'synthetic-java',
                    '--output', str(output)]
            with patch.object(sys, 'argv', argv), patch.object(capture, 'selected_preflight', return_value={}), redirect_stderr(io.StringIO()):
                self.assertEqual(capture.main(), 1)
            receipt = json.loads((output / 'finalize-failure.json').read_bytes())
            self.assertIn('field-oracle.json', receipt['error'])
            self.assertEqual((output / 'manifest.json').read_bytes(), manifest)
            self.assertFalse((output / 'golden.json').exists())

    def test_historical_failure_receipt_keeps_default_replacement_behavior(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            capture._write_finalize_failure(output, 'first')
            capture._write_finalize_failure(output, 'second')
            self.assertEqual(json.loads((output / 'finalize-failure.json').read_bytes())['error'], 'second')
            self.assertEqual(len(list(output.glob('finalize-failure*.json'))), 1)

    def test_failure_receipt_does_not_touch_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            manifest = output / 'manifest.json'
            manifest.write_bytes(b'{"status":"observed"}\n')
            capture._write_finalize_failure(output, 'synthetic failure')
            self.assertEqual(manifest.read_bytes(), b'{"status":"observed"}\n')
            receipt = json.loads((output / 'finalize-failure.json').read_text())
            self.assertEqual(receipt['status'], 'failed')
            self.assertEqual(receipt['error'], 'synthetic failure')

    def test_lf_normalisation_is_byte_stable(self):
        self.assertEqual(capture.lf_bytes(b'a\r\nb\nc\r\n'), b'a\nb\nc\n')
        self.assertEqual(shlex.split(capture.remote_script_arguments('p', 'x')[4]), ['x'])


class ProbeCallerConsistencyTest(unittest.TestCase):
    def test_caller_passes_the_unscoped_suffix_helper_contract(self):
        import re
        source = (Path(__file__).resolve().with_name('FieldOracle.java')
                  .read_text(encoding='utf-8'))
        match = re.search(
            r'scratch\.seedProbePreferences\(\s*\(android\.content\.Context\) app, '
            r'dataDir, "([^"]+)"\)', source)
        self.assertIsNotNone(match)
        helper = (Path(__file__).resolve().parent.parent / 'nested_oracle'
                  / 'StateSessionOracle.java').read_text(encoding='utf-8')
        self.assertIn('String scoped = preferencesPrefix + probe;', helper)
        self.assertEqual(capture.OWNED_PREFERENCE_PREFIX + match.group(1),
                         'liber_fields_02_probe')


class ProvenanceAssetTest(unittest.TestCase):
    def test_five_and_seven_input_apk_provenance(self):
        fixture_path = Path(__file__).resolve().with_name('book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        helpers = ('HostRuntimeInit.java', 'ShortcutStartupGuard.java')
        legacy = {k: v for k, v in capture.harness_source_hashes().items() if k not in helpers}
        current = dict(legacy)
        for name in helpers:
            current[name] = capture.sha256(fixture_path.parent.parent / 'nested_oracle' / name)
        provenance = {'schemaVersion': 1, 'fixtureId': 'FIELDS-02', 'corpus': {
            'asset': 'field-fixtures.json', 'bytes': len(fixture_bytes),
            'sha256': capture.sha256_bytes(fixture_bytes),
            'sha256Lf': capture.sha256_bytes(capture.lf_bytes(fixture_bytes)),
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1}}
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'selected.apk'
            def inspect(sources, expected):
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/field-fixtures.json', fixture_bytes)
                    archive.writestr('assets/field-provenance.json',
                                     json.dumps({**provenance, 'sources': sources}))
                return capture.inspect_selected_apk(apk, fixture_path, fixture, expected)
            self.assertEqual(inspect(current, current)['provenance']['sources'], current)
            self.assertEqual(inspect(legacy, None)['provenance']['sources'], legacy)
            with self.assertRaises(ValueError):
                inspect(legacy, current)  # new capture must not accept old inventory
            for bad in [
                {k: v for k, v in current.items() if k != 'HostRuntimeInit.java'},
                {**current, 'HostRuntimeInit.java': '0' * 64},
                {**current, 'ShortcutStartupGuard.java': '0' * 64},
                {**current, 'ShortcutStartupGuard.java': 'bad'},
                {**current, 'unrelated.java': '0' * 64},
            ]:
                with self.assertRaises(ValueError):
                    inspect(bad, current)

    def test_embedded_asset_and_complete_provenance_are_measured(self):
        fixture_path = Path(__file__).resolve().with_name('book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        provenance = {
            'schemaVersion': 1,
            'fixtureId': 'FIELDS-02',
            'corpus': {
                'asset': 'field-fixtures.json',
                'bytes': len(fixture_bytes),
                'sha256': capture.sha256_bytes(fixture_bytes),
                'sha256Lf': capture.sha256_bytes(capture.lf_bytes(fixture_bytes)),
                'fixtureId': 'FIELDS-02',
                'corpusVersion': 1,
            },
            'sources': capture.harness_source_hashes(),
        }
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'selected.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture_bytes)
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            artifact = capture.inspect_selected_apk(
                apk, fixture_path, fixture, capture.harness_source_hashes())
            self.assertEqual(artifact['apkSha256'], capture.sha256(apk))
            self.assertEqual(artifact['selectedAssetSha256'], provenance['corpus']['sha256'])
            self.assertEqual(set(artifact['provenance']['sources']), set(capture.HARNESS_SOURCE_KEYS))
            provenance['sources']['capture.py'] = '0' * 64
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture_bytes)
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            with self.assertRaises(ValueError):
                capture.inspect_selected_apk(
                    apk, fixture_path, fixture, capture.harness_source_hashes())


class DuplicateAssetTest(unittest.TestCase):
    def test_duplicate_required_zip_asset_is_refused(self):
        import warnings
        fixture_path = Path(__file__).resolve().with_name(
            'book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        provenance = {
            'schemaVersion': 1, 'fixtureId': 'FIELDS-02',
            'corpus': {
                'asset': 'field-fixtures.json', 'bytes': len(fixture_bytes),
                'sha256': capture.sha256_bytes(fixture_bytes),
                'sha256Lf': capture.sha256_bytes(capture.lf_bytes(fixture_bytes)),
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            },
            'sources': capture.harness_source_hashes(),
        }
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'duplicate.apk'
            with warnings.catch_warnings():
                warnings.simplefilter('ignore')
                with zipfile.ZipFile(apk, 'w') as archive:
                    archive.writestr('assets/field-fixtures.json', fixture_bytes)
                    archive.writestr('assets/field-fixtures.json', fixture_bytes)
                    archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            with zipfile.ZipFile(apk) as archive:
                self.assertEqual(
                    archive.namelist().count('assets/field-fixtures.json'), 2)
            with self.assertRaises(ValueError):
                capture.inspect_selected_apk(
                    apk, fixture_path, fixture, capture.harness_source_hashes())


class ProvenanceSelectionTest(unittest.TestCase):
    def test_selected_fixture_family_and_integer_version_are_strict(self):
        fixture_path = Path(__file__).resolve().with_name(
            'book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        provenance = {
            'schemaVersion': 1, 'fixtureId': 'FIELDS-02',
            'corpus': {
                'asset': 'field-fixtures.json', 'bytes': len(fixture_bytes),
                'sha256': capture.sha256_bytes(fixture_bytes),
                'sha256Lf': capture.sha256_bytes(capture.lf_bytes(fixture_bytes)),
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            },
            'sources': capture.harness_source_hashes(),
        }
        with tempfile.TemporaryDirectory() as directory:
            apk = Path(directory) / 'selected.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture_bytes)
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            for changed in [
                {**fixture, 'corpusVersion': 1.0},
                {**fixture, 'fixtureId': 'UNSUPPORTED-FAMILY'},
            ]:
                raw = json.dumps(changed).encode()
                selected = Path(directory) / 'changed.json'
                selected.write_bytes(raw)
                with self.assertRaises(ValueError):
                    capture.inspect_selected_apk(
                        apk, selected, changed, capture.harness_source_hashes())


class DriverBoundaryTest(unittest.TestCase):
    def _run(self, root_state='ABSENT', install_code=0, stop_code=0,
             uninstall_code=0, partial=False, owner_mutator=None,
             snapshot_code=0, process_pid=None, installation_probe=False,
             instrument_code=0, process_pid_preflight=None, process_pid_owned=None,
             process_pid_post=None, pid_stderr=False, snapshot_fail_on=None,
             existing_harness=False, package_query_code=0,
             package_query_stderr=b'', package_query_stdout=None,
             owner_preferences=None, selected=False, selected_install_receipt=None,
             selected_pref_stderr=b'', selected_stop_stderr=b'', inspect_bundle=None):
        import io
        from contextlib import redirect_stdout
        from unittest.mock import patch

        fixture = Path(__file__).resolve().with_name(
            'book-url-markers-fixtures-selected.json' if selected else 'book-url-markers-fixtures.json')
        fixture_data = json.loads(fixture.read_text(encoding='utf-8'))
        target_package = fixture_data['target']['package']
        commands = []
        calls = {'finalize': 0, 'install_attempted': False}
        target_root = '/data/user/0/' + target_package
        scratch_root = target_root + '/cache/liber-fields-02'
        before_lines = b''
        report_bytes = b''
        owner_bytes = b''
        actual_sha = capture.sha256
        pid_calls = {'count': 0}

        def fake_sha(path):
            if Path(path).name == 'frozen.apk':
                return fixture_data['target']['apkSha256']
            return actual_sha(path)

        def fake_run(args, **kwargs):
            commands.append(list(map(str, args)))
            text = ' '.join(map(str, args))
            stdout, code, stderr = b'', 0, b''
            if args[0] == 'git':
                if 'rev-parse' in args:
                    stdout = (fixture_data['baselineCommit'] + '\n').encode()
                elif 'hash-object' in args:
                    stdout = ('\n'.join(
                        item['sha1'] for item in fixture_data['frozenSources']) + '\n').encode()
            elif args[0] == 'adb':
                if 'ro.build.fingerprint' in args:
                    stdout = (fixture_data['target']['deviceFingerprint'] + '\n').encode()
                elif 'ro.build.version.release' in args:
                    stdout = b'17\n'
                elif 'ro.build.version.sdk' in args:
                    stdout = b'37\n'
                elif 'ro.product.model' in args:
                    stdout = b'synthetic-test-only\n'
                elif selected and 'webviewupdate' in args:
                    stdout = b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n'
                elif args[-3:] == ['pm', 'path', target_package]:
                    stdout = b'package:/synthetic/frozen.apk\n'
                elif args[-3:] == ['pm', 'path', capture.PACKAGE]:
                    if selected and calls['install_attempted']:
                        stdout = b'package:/synthetic/installed-harness.apk\n'
                    elif existing_harness and not calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    elif partial and calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    else:
                        code = 1
                elif args[-4:] == ['pm', 'list', 'packages', capture.PACKAGE]:
                    code = package_query_code
                    stderr = package_query_stderr
                    if package_query_stdout is not None:
                        stdout = package_query_stdout
                    elif not package_query_code and existing_harness and not calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    elif not package_query_code and partial and calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                elif 'pidof' in args:
                    pid_calls['count'] += 1
                    if pid_calls['count'] == 1:
                        chosen = process_pid_preflight if process_pid_preflight is not None else process_pid
                    elif pid_calls['count'] == 2:
                        chosen = process_pid_owned if process_pid_owned is not None else process_pid
                    else:
                        chosen = process_pid_post if process_pid_post is not None else process_pid
                    if chosen is None:
                        code = 1
                        if pid_stderr:
                            stderr = b'query failed'
                    else:
                        stdout = (str(chosen) + chr(10)).encode()
                elif args[-1:] == ['pwd']:
                    stdout = (target_root + '\n').encode()
                elif selected and 'pull' in args:
                    destination = Path(args[-1])
                    destination.write_bytes(apk.read_bytes() if destination.name == 'installed-harness.apk' else _SYNTHETIC_TARGET_APK)
                elif 'install' in args:
                    calls['install_attempted'] = True
                    code = install_code
                    if selected and code == 0:
                        stdout = selected_install_receipt if selected_install_receipt is not None else b'Success\n'
                elif 'uninstall' in args:
                    code = uninstall_code
                    if selected and code == 0:
                        stdout = b'Success\n'
                elif 'am' in args and 'instrument' in args:
                    code = instrument_code
                    if selected and code == 0:
                        stdout = b'INSTRUMENTATION_CODE: -1\n'
                    calls['instrument_failed'] = instrument_code != 0
                elif 'am' in args and 'force-stop' in args:
                    code = stop_code
                    if selected:
                        stderr = selected_stop_stderr
                elif 'exec-out' in args and scratch_root + '/field-oracle.json' in text:
                    if calls.get('instrument_failed'):
                        code = 1
                    else:
                        stdout = report_bytes
                elif 'exec-out' in args and scratch_root + '/owner.json' in text:
                    if calls.get('instrument_failed'):
                        code = 1
                    else:
                        stdout = owner_bytes
                elif 'run-as' in args:
                    script = args[-1]
                    if 'find . -type f' in script:
                        calls['snapshot_calls'] = calls.get('snapshot_calls', 0) + 1
                        fail = snapshot_code != 0 or snapshot_fail_on == calls['snapshot_calls']
                        code = 1 if fail else 0
                        stdout = b'' if fail else before_lines
                    elif 'probe.xml' in script:
                        stdout = (b'PRESENT' + chr(10)) if installation_probe else b''
                    elif 'scratch-root-check' in text or 'if [ -e ' in script:
                        stdout = (root_state + '\n').encode()
                    elif 'find ' in script:
                        stdout = b'' if ' -name ' in script else before_lines
                        if selected and ' -name ' in script:
                            stderr = selected_pref_stderr
            return subprocess.CompletedProcess(args, code, stdout, stderr)

        with tempfile.TemporaryDirectory() as directory:
            # Build the actual original APK and compose the same evidence the
            # finalizer consumes; only adb/git transport is mocked.
            evidence = FinalizeContractTest()._evidence(selected=selected)
            report = json.loads(json.dumps(evidence[3]))
            if selected:
                report['startupContainment'] = {'service': 'shortcut', 'provider': 'io.legado.app.api.ReaderProvider',
                    'intercepted': 1, 'handled': 1, 'beforeBinding': True}
                report['isolation']['appClass'] = 'io.liber.oracle.nested.GuardedReaderApplication'
                report['hostInitialization'] = {'verified': True, 'applicationAttached': False,
                    'invokedOn': 'unattached-instance', 'notRun': ['io.legado.app.App.onCreate'],
                    'registeredWrappers': {r['type']: r['factory'] for r in fixture_data['hostInitialization']['registrations']},
                    'method': fixture_data['hostInitialization']['method']}
                report['terminalOwner'] = {'scope': 'Coroutine.DEFAULT', 'rootActive': True, 'rootCompleted': False,
                    'baselineChildren': 0, 'childrenMethod': 'kotlinx.coroutines.Job.getChildren()',
                    'completionMethod': 'kotlinx.coroutines.Job.isCompleted()'}
                prefix = 'public final java.lang.Object io.legado.app.model.webBook.WebBook.'
                report['entryPoints'] = {
                    'searchBookAwait': prefix + 'searchBookAwait(io.legado.app.data.entities.BookSource,java.lang.String,java.lang.Integer,kotlin.jvm.functions.Function3,kotlin.jvm.functions.Function1,kotlin.coroutines.Continuation)',
                    'getBookInfoAwait': prefix + 'getBookInfoAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,kotlin.coroutines.Continuation)',
                    'getChapterListAwait': prefix + 'getChapterListAwait-yxL6bBk(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,boolean,kotlin.coroutines.Continuation)',
                    'getContentAwait': prefix + 'getContentAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,kotlin.coroutines.Continuation)',
                }
                for case in report['cases']:
                    case['terminalOwner'] = {'owner': 'Coroutine.DEFAULT Job', 'observedChildren': 0,
                        'allCompleted': True, 'rootEmpty': True, 'launchAttempts': 0}
                report['cleanup'].update({'openConnectionsAfterClose': 0, 'databaseClosed': True, 'activityLaunchAttempts': 0})
            owner = json.loads(json.dumps(evidence[4]['scratchOwner']))
            provenance = evidence[4]['artifact']['provenance']
            apk = Path(directory) / 'field-oracle.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture.read_bytes())
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
                if selected:
                    archive.writestr('classes.dex', b'synthetic-harness-dex')
            artifact = capture.inspect_selected_apk(
                apk, fixture, fixture_data, capture.harness_source_hashes(selected=selected))
            report['isolation'].update({
                'targetPackage': target_package,
                'targetApkSha256': fixture_data['target']['apkSha256'],
                'harnessPackage': capture.PACKAGE,
                'harnessApkSha256': artifact['apkSha256'],
                'corpusSha256Lf': artifact['selectedAssetSha256Lf'],
                'scratchRoot': scratch_root,
                'preferencesPrefix': 'liber_fields_02_',
                'preferenceProbe': {
                    'name': 'liber_fields_02_probe', 'registered': True,
                    'committed': True, 'scopedFile': True,
                    'installationFile': False,
                },
            })
            report['cleanup'].update({
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
                'serverClosed': True, 'ownerComplete': True,
                'rootRetained': True, 'preferencesFenced': True,
                'ownerRunId': 'run', 'scratchRoot': scratch_root,
                'reportPath': scratch_root + '/field-oracle.json',
                'ownedPreferences': ['liber_fields_02_probe'],
            })
            report['corpus'].update({
                'bytes': len(fixture.read_bytes()),
                'sha256': artifact['selectedAssetSha256'],
                'sha256Lf': artifact['selectedAssetSha256Lf'],
            })
            owner.update({
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
                'targetPackage': target_package,
                'harnessPackage': capture.PACKAGE,
                'targetApkSha256': fixture_data['target']['apkSha256'],
                'harnessApkSha256': artifact['apkSha256'],
                'corpusSha256Lf': artifact['selectedAssetSha256Lf'],
                'complete': True, 'seedRunId': 'run', 'seedPid': 4242,
                'preferences': ['liber_fields_02_probe'],
            })
            if owner_preferences is not None:
                report['cleanup']['ownedPreferences'] = list(owner_preferences)
                owner['preferences'] = list(owner_preferences)
            if owner_mutator is not None:
                owner_mutator(owner)
            report_bytes = json.dumps(report).encode()
            owner_bytes = json.dumps(owner).encode()
            before_lines = evidence[6]
            real_finalize = capture.finalize

            def counting_finalize(*args, **kwargs):
                calls['finalize'] += 1
                return real_finalize(*args, **kwargs)

            cache = Path(directory) / 'baseline'
            cache.mkdir()
            frozen = Path(directory) / 'frozen'
            for source in fixture_data['frozenSources']:
                target = frozen / source['path']
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(b'frozen-source-context')
            output = Path(directory) / 'out'
            argv = ['capture.py', '--serial', '5615f742', '--apk', str(apk),
                    '--frozen-source', str(frozen),
                    '--output', str(output), '--asset', str(fixture),
                    '--fixture', str(fixture)]
            if selected:
                argv += ['--target-apk', str(cache / 'target.apk'), '--java-home', str(cache)]
            def synthetic_preflight(*args, **kwargs):
                references = {item['path']: {'blobSha1': item['sha1'],
                              'worktreeSha256': actual_sha(frozen / item['path'])}
                              for item in fixture_data['frozenSources']}
                return _synthetic_selected_preflight(kwargs.get('evidence'), fixture_data, artifact,
                    apk, cache / 'target.apk', frozen, Path('C:/Users/17945/AppData/Local/Android/Sdk'),
                    Path('C:/Users/17945/.cache/wayfinder/temurin-17/jdk-17.0.20+8'), references)
            with patch.object(sys, 'argv', argv), \
                    patch.object(capture, 'selected_preflight', synthetic_preflight), \
                    patch.object(capture, 'sha256', fake_sha), \
                    patch.object(capture.subprocess, 'run', fake_run), \
                    patch.object(capture.tempfile, 'mkdtemp', lambda **kwargs: str(cache)), \
                    patch.object(capture, 'finalize', counting_finalize), \
                    redirect_stdout(io.StringIO()):
                exit_code = capture.main()
            calls['golden'] = (output / 'golden.json').exists()
            if inspect_bundle is not None and calls['golden']:
                inspect_bundle(output, fixture, apk)
            if (output / 'manifest.json').exists():
                manifest = json.loads(
                    (output / 'manifest.json').read_text(encoding='utf-8'))
                calls['manifest_status'] = manifest['status']
                calls['manifest_commands'] = manifest.get('commands', [])
                calls['manifest_error'] = manifest.get('error')
        return exit_code, commands, calls

    def test_selected_verified_bundle_is_read_only_and_reconciles_inputs(self):
        def verify(bundle, fixture, apk):
            from unittest.mock import patch
            manifest = json.loads((bundle / 'manifest.json').read_bytes())
            before = {p.name: p.read_bytes() for p in bundle.iterdir() if p.is_file()}
            real_sha = capture.sha256
            def synthetic_target(path):
                return capture.SELECTED_TARGET['apkSha256'] if Path(path).name == 'frozen.apk' else real_sha(path)
            with patch.object(capture, 'sha256', side_effect=synthetic_target):
                result = capture.verify_selected_bundle(bundle, fixture, apk, manifest['preflight'])
                self.assertEqual(result['status'], 'verified-bundle')
                self.assertEqual(result['goldenSha256'], capture.sha256(bundle / 'golden.json'))
                self.assertEqual(before, {p.name: p.read_bytes() for p in bundle.iterdir() if p.is_file()})
                from contextlib import redirect_stdout
                import io
                destination = bundle.parent / 'verification'
                argv = ['capture.py', '--verify-bundle', str(bundle), '--fixture', str(fixture),
                        '--apk', str(apk), '--target-apk', str(bundle / 'frozen.apk'),
                        '--frozen-source', 'synthetic-source', '--java-home', 'synthetic-java',
                        '--output', str(destination)]
                with patch.object(sys, 'argv', argv), patch.object(capture, 'selected_preflight', return_value=manifest['preflight']), redirect_stdout(io.StringIO()):
                    self.assertEqual(capture.main(), 0)
                self.assertEqual(json.loads((destination / 'verification.json').read_bytes())['status'], 'verified-bundle')
                bad = json.loads(json.dumps(manifest['preflight']))
                bad['targetApkSha256'] = '0' * 64
                with self.assertRaisesRegex(ValueError, 'fresh preflight'):
                    capture.verify_selected_bundle(bundle, fixture, apk, bad)
            self.assertEqual(before, {p.name: p.read_bytes() for p in bundle.iterdir() if p.is_file()})
        exit_code, _, calls = self._run(selected=True, process_pid_owned=4242, inspect_bundle=verify)
        self.assertEqual(exit_code, 0, calls)

    def test_selected_finalize_reconciles_fresh_preflight_before_reuse(self):
        import io
        from contextlib import redirect_stderr
        from unittest.mock import patch
        def verify(bundle, fixture, apk):
            manifest_bytes = (bundle / 'manifest.json').read_bytes()
            golden_bytes = (bundle / 'golden.json').read_bytes()
            binding = json.loads(manifest_bytes)['preflight']
            binding['targetApkSha256'] = '0' * 64
            argv = ['capture.py', '--finalize', '--serial', '5615f742', '--fixture', str(fixture),
                    '--apk', str(apk), '--target-apk', str(bundle / 'frozen.apk'),
                    '--frozen-source', 'source', '--java-home', 'java', '--output', str(bundle)]
            real_sha = capture.sha256
            def synthetic_target(path):
                return capture.SELECTED_TARGET['apkSha256'] if Path(path).name == 'frozen.apk' else real_sha(path)
            with patch.object(sys, 'argv', argv), patch.object(capture, 'selected_preflight', return_value=binding), patch.object(capture, 'sha256', side_effect=synthetic_target), redirect_stderr(io.StringIO()):
                self.assertEqual(capture.main(), 1)
            self.assertIn('fresh preflight', json.loads((bundle / 'finalize-failure.json').read_bytes())['error'])
            self.assertEqual((bundle / 'manifest.json').read_bytes(), manifest_bytes)
            self.assertEqual((bundle / 'golden.json').read_bytes(), golden_bytes)
        exit_code, _, calls = self._run(selected=True, process_pid_owned=4242, inspect_bundle=verify)
        self.assertEqual(exit_code, 0, calls)

    def test_selected_bundle_refuses_each_physical_receipt_mutation(self):
        from unittest.mock import patch
        def verify(bundle, fixture, apk):
            original_manifest = (bundle / 'manifest.json').read_bytes()
            original_logs = {p.name: p.read_bytes() for p in bundle.glob('*.log')}
            binding = json.loads(original_manifest)['preflight']
            real_sha = capture.sha256
            def synthetic_target(path):
                return capture.SELECTED_TARGET['apkSha256'] if Path(path).name == 'frozen.apk' else real_sha(path)
            with patch.object(capture, 'sha256', side_effect=synthetic_target):
                self.assertEqual(capture.verify_selected_bundle(bundle, fixture, apk, binding)['status'], 'verified-bundle')
                for name in ['missing_preferences', 'unknown_pid', 'mixed_terminal', 'wrong_dex', 'stop_error', 'root_error']:
                    manifest = json.loads(original_manifest)
                    for filename, data in original_logs.items():
                        (bundle / filename).write_bytes(data)
                    if name == 'missing_preferences':
                        removed = [r['log'] for r in manifest['commands'] if r['log'].startswith(('scratch-remove-1.', 'scratch-absent-1.'))]
                        manifest['commands'] = [r for r in manifest['commands'] if r['log'] not in removed]
                        for filename in removed:
                            (bundle / filename).unlink()
                    elif name == 'unknown_pid':
                        next(r for r in manifest['commands'] if r['log'] == 'poststop-check.log')['exitCode'] = 127
                        (bundle / 'poststop-check.log').write_bytes(b'Permission denied\n')
                    elif name == 'mixed_terminal':
                        (bundle / 'instrumentation.log').write_bytes(b'INSTRUMENTATION_CODE: -1\nINSTRUMENTATION_CODE: 1\n')
                    elif name == 'wrong_dex':
                        next(r for r in manifest['preflight']['commands'] if r['name'] == 'dex')['command'] = ['not-the-SDK', 'wrong.dex']
                    elif name == 'stop_error':
                        (bundle / 'poststop.log').write_bytes(b'Error: force-stop failed\n')
                    else:
                        (bundle / 'scratch-remove-root.log').write_bytes(b'rm: Permission denied\n')
                    (bundle / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
                    with self.subTest(name=name), self.assertRaises(ValueError):
                        capture.verify_selected_bundle(bundle, fixture, apk, binding)
                (bundle / 'manifest.json').write_bytes(original_manifest)
                for filename, data in original_logs.items():
                    (bundle / filename).write_bytes(data)
        exit_code, _, calls = self._run(selected=True, process_pid_owned=4242, inspect_bundle=verify)
        self.assertEqual(exit_code, 0, calls)

    def test_selected_driver_refuses_preinstall_preference_access_error(self):
        exit_code, commands, calls = self._run(selected=True, selected_pref_stderr=b'find: Permission denied\n')
        self.assertEqual(exit_code, 1)
        self.assertIn('preference', calls['manifest_error'])
        self.assertFalse(calls['install_attempted'])
        self.assertFalse(any('force-stop' in cmd or 'uninstall' in cmd for cmd in commands))

    def test_selected_driver_refuses_contradictory_stop_receipt(self):
        exit_code, commands, calls = self._run(selected=True, process_pid_owned=4242,
                                                selected_stop_stderr=b'Error: force-stop failed\n')
        self.assertEqual(exit_code, 1)
        self.assertIn('stop', calls['manifest_error'])
        self.assertFalse(calls['golden'])
        self.assertFalse(any('rm -f --' in ' '.join(cmd) or 'uninstall' in cmd for cmd in commands))

    def test_selected_driver_preserves_mixed_install_without_instrumentation(self):
        exit_code, commands, calls = self._run(
            selected=True, selected_install_receipt=b'Success\nFailure [INSTALL_FAILED]\n')
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['golden'])
        self.assertFalse(any('instrument' in cmd for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))
        self.assertIn('success is missing or contradicted', calls['manifest_error'])

    def test_selected_driver_rejects_wrong_owner_before_cleanup(self):
        exit_code, commands, calls = self._run(
            selected=True, owner_mutator=lambda owner: owner.update(harnessApkSha256='0' * 64))
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['golden'])
        self.assertIn('owner harness APK differs before cleanup', calls['manifest_error'])
        self.assertFalse(any('force-stop' in cmd or 'uninstall' in cmd for cmd in commands))

    def test_selected_driver_preserves_failed_stop_without_cleanup(self):
        exit_code, commands, calls = self._run(selected=True, stop_code=1)
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['golden'])
        self.assertIn('owned target process could not be stopped', calls['manifest_error'])
        self.assertFalse(any('uninstall' in cmd for cmd in commands))
        self.assertFalse(any('rm -f --' in ' '.join(cmd) for cmd in commands))

    def test_selected_driver_rejects_failed_post_cleanup_snapshot(self):
        exit_code, commands, calls = self._run(selected=True, snapshot_fail_on=2)
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['golden'])
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('private-after exited 1', calls['manifest_error'])

    def test_selected_driver_preserves_instrumentation_failure(self):
        exit_code, commands, calls = self._run(selected=True, instrument_code=1)
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['golden'])
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('instrumentation exited 1', calls['manifest_error'])
        self.assertFalse(any('force-stop' in cmd or 'uninstall' in cmd for cmd in commands))

    def test_selected_driver_uses_selected_target_and_preserves_raw_receipts(self):
        exit_code, commands, calls = self._run(selected=True, process_pid_owned=4242)
        self.assertEqual(exit_code, 0, calls)
        self.assertEqual(calls['finalize'], 1)
        self.assertTrue(calls['golden'])  # TemporaryDirectory synthetic mechanics only.
        self.assertTrue(any('com.legado.app.debug' in cmd for cmd in commands))
        self.assertFalse(any('io.legado.app.debug' in cmd for cmd in commands))
        self.assertFalse(any(cmd[-2:] == ['logcat', '-c'] for cmd in commands))

    def test_successful_driver_uses_exact_quoted_cleanup_and_uninstall(self):
        exit_code, commands, calls = self._run()
        self.assertEqual(exit_code, 0)
        self.assertEqual(calls['finalize'], 1)
        self.assertTrue(calls['golden'])
        self.assertEqual(calls['manifest_status'], 'observed')
        self.assertFalse(any('*' in cmd for cmd in commands))
        self.assertTrue(any('rm -f --' in ' '.join(cmd) for cmd in commands))
        remote = [cmd for cmd in commands
                  if 'run-as' in cmd and len(cmd) > 8 and cmd[6] == 'sh']
        self.assertTrue(remote)
        for cmd in remote:
            self.assertEqual(cmd[7], '-c')
            self.assertTrue(cmd[8].startswith("'") and cmd[8].endswith("'"))
        self.assertTrue(any('uninstall' in cmd and capture.PACKAGE in cmd for cmd in commands))
        snapshots = [' '.join(cmd) for cmd in commands if 'find . -type f' in ' '.join(cmd)]
        self.assertTrue(snapshots)
        self.assertIn('find . -type d', snapshots[0])

    def test_preexisting_root_is_preserved_without_deletion(self):
        exit_code, commands, calls = self._run(root_state='PRESENT')
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))
        self.assertFalse(calls['install_attempted'])

    def test_failed_stop_blocks_promotion_without_deletion(self):
        exit_code, commands, calls = self._run(stop_code=1)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))

    def test_failed_uninstall_blocks_promotion(self):
        exit_code, commands, calls = self._run(uninstall_code=1)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(any('uninstall' in cmd and capture.PACKAGE in cmd for cmd in commands))

    def test_wrong_owner_hashes_do_not_delete_scratch(self):
        exit_code, commands, calls = self._run(
            owner_mutator=lambda owner: owner.update(harnessApkSha256='0' * 64))
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('force-stop' in cmd for cmd in commands))

    def test_actual_android_owner_names_are_admitted_and_logged_by_index(self):
        exit_code, commands, calls = self._run(
            owner_preferences=ACTUAL_OWNER_PREFERENCES)
        self.assertEqual(exit_code, 0)
        self.assertEqual(calls['finalize'], 1)
        self.assertTrue(calls['golden'])
        self.assertEqual(calls['manifest_status'], 'observed')
        labels = [' '.join(cmd) for cmd in commands]
        logs = [item.get('log') for item in calls.get('manifest_commands', [])]
        for index in range(1, len(ACTUAL_OWNER_PREFERENCES) + 1):
            self.assertIn('scratch-remove-' + str(index) + '.log', logs)
            self.assertIn('scratch-absent-' + str(index) + '.log', logs)
        for name in ACTUAL_OWNER_PREFERENCES:
            path = '/data/user/0/io.legado.app.debug/shared_prefs/' + name + '.xml'
            self.assertTrue(any(shlex.quote(path) in label for label in labels), name)
        for name in ACTUAL_OWNER_PREFERENCES:
            self.assertFalse(any('scratch-remove-' + name in label for label in labels))

    def test_owner_name_admission_accepts_actual_and_rejects_separators(self):
        self.assertEqual(
            capture._safe_owner_names(ACTUAL_OWNER_PREFERENCES, 'owner.preferences'),
            ACTUAL_OWNER_PREFERENCES,
        )
        for bad in (
            'liber_fields_02_evil/name',
            r'liber_fields_02_evil\name',
            'liber_fields_02_..',
            'liber_other_probe',
            'liber_fields_02_probe/',
            'liber_fields_02_probe' + chr(10),
        ):
            with self.assertRaisesRegex(ValueError, 'unsafe preference name'):
                capture._safe_owner_names(
                    ['liber_fields_02_probe', bad], 'owner.preferences')
        with self.assertRaisesRegex(ValueError, 'omits the registered probe'):
            capture._safe_owner_names(['liber_fields_02_evil/name'], 'owner.preferences')
        with self.assertRaisesRegex(ValueError, 'inventories differ'):
            capture._admit_owner_inventories(
                ACTUAL_OWNER_PREFERENCES, ACTUAL_OWNER_PREFERENCES[:-1])

    def test_wrong_post_owner_pid_preserves_before_stop(self):
        exit_code, commands, calls = self._run(process_pid_owned=999999)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))

    def test_failed_post_stop_pid_blocks_removal_and_promotion(self):
        exit_code, commands, calls = self._run(process_pid_post=999999)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))

    def test_second_snapshot_failure_does_not_promote(self):
        exit_code, commands, calls = self._run(snapshot_fail_on=2)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse((calls.get('golden', False)))

    def test_preexisting_installation_probe_is_preserved_without_install(self):
        exit_code, commands, calls = self._run(installation_probe=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(calls['install_attempted'])
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))

    def test_instrumentation_failure_preserves_ambiguous_harness_state(self):
        exit_code, commands, calls = self._run(instrument_code=1)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))

    def test_snapshot_failure_is_not_used_for_promotion(self):
        exit_code, commands, calls = self._run(snapshot_code=1)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('force-stop' in cmd for cmd in commands))

    def test_unresolved_process_is_preserved_without_stop_or_removal(self):
        exit_code, commands, calls = self._run(process_pid=999999)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))

    def test_absent_harness_inventory_allows_install(self):
        exit_code, commands, calls = self._run()
        self.assertEqual(exit_code, 0)
        inventory = [cmd for cmd in commands
                     if cmd[-4:] == ['pm', 'list', 'packages', capture.PACKAGE]]
        self.assertEqual(len(inventory), 1)
        self.assertTrue(calls['install_attempted'])

    def test_existing_harness_inventory_refuses_without_install(self):
        exit_code, commands, calls = self._run(existing_harness=True)
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(any(cmd[-4:] == ['pm', 'list', 'packages', capture.PACKAGE]
                            for cmd in commands))

    def test_package_inventory_access_error_is_not_absence(self):
        exit_code, commands, calls = self._run(
            package_query_code=1, package_query_stderr=b'permission denied')
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertFalse(any('install' in cmd for cmd in commands
                             if 'field-oracle.apk' in ' '.join(cmd)))
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('query failed (exit 1)', calls['manifest_error'])
        self.assertIn('permission denied', calls['manifest_error'])

    def test_malformed_package_inventory_is_refused(self):
        exit_code, commands, calls = self._run(
            package_query_stdout=b'package:' + bytes([10]))
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('malformed package record', calls['manifest_error'])

    def test_contradictory_package_inventory_is_refused(self):
        exit_code, commands, calls = self._run(
            package_query_code=1,
            package_query_stdout=b'package:' + capture.PACKAGE.encode() + bytes([10]))
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('query failed (exit 1)', calls['manifest_error'])

    def test_successful_inventory_with_stderr_is_not_absence(self):
        exit_code, commands, calls = self._run(
            package_query_stderr=b'permission denied')
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)
        self.assertIn('query reported an error', calls['manifest_error'])
        self.assertIn('permission denied', calls['manifest_error'])

    def test_rejected_install_with_verified_absence_is_blocked(self):
        exit_code, commands, calls = self._run(install_code=1)
        self.assertEqual(exit_code, 2)
        self.assertTrue(calls['install_attempted'])
        self.assertEqual(calls['manifest_status'], 'blocked')
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))

    def test_partial_install_is_preserved_or_refused(self):
        exit_code, commands, calls = self._run(install_code=1, partial=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(calls['install_attempted'])
        self.assertEqual(calls['manifest_status'], 'failed')
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))


class SnapshotParserTest(unittest.TestCase):
    def test_typed_parser_refuses_ambiguous_or_unsupported_nodes(self):
        for payload in [
            _snapshot_line('F', 'file', 'not-a-digest').encode(),
            (_snapshot_line('F', 'file') + _snapshot_line('F', 'file')).encode(),
            _snapshot_line('U', 'link').encode(),
            _snapshot_line('F', './../escape').encode(),
            _snapshot_line('D', './one' + chr(10) + 'D' + chr(9) + '-' + chr(9) + 'two').encode(),
            _snapshot_line('F', './a/./b').encode(),
            ('F' + chr(9) + 'a' * 64 + chr(9) + 'not-hex' + chr(10)).encode(),
        ]:
            with self.assertRaises(ValueError):
                capture._snapshot_records(payload, 'test')

    def test_snapshot_script_and_parser_round_trip_ordinary_names(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['cache', 'files', 'databases', 'shared_prefs']:
                (root / name).mkdir()
            (root / 'databases' / 'legado.db').write_bytes(b'x')
            completed = _run_snapshot_formatter(root)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            records = capture._snapshot_records(completed.stdout, 'test')
            self.assertIn('databases/legado.db', records)
            self.assertIn('.', records)

    @unittest.skipIf(__import__('os').name == 'nt', 'Windows cannot create LF fixture names')
    def test_snapshot_script_and_parser_round_trip_record_breaking_names(self):
        import subprocess
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in ['.', 'cache', 'files', 'databases', 'shared_prefs']:
                (root if name == '.' else root / name).mkdir(exist_ok=True)
            (root / 'databases' / 'legado.db').write_bytes(b'x')
            weird = root / 'files' / ('one' + chr(10) + 'D' + chr(9) + '-' + chr(9) + 'two')
            weird.write_bytes(b'y')
            completed = _run_snapshot_formatter(root)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            with self.assertRaises(ValueError):
                capture._snapshot_records(completed.stdout, 'test')


class FormatterFailureTest(unittest.TestCase):
    def _make_root(self, base):
        root = base / 'private'
        for name in ['.', 'cache', 'databases', 'files', 'shared_prefs']:
            (root if name == '.' else root / name).mkdir(exist_ok=True)
        (root / 'databases' / 'legado.db').write_bytes(b'x')
        (root / 'files' / 'one').write_bytes(b'y')
        return root

    def _wrapper(self, path, body):
        path.write_text('#!/bin/sh' + chr(10) + body + chr(10), encoding='utf-8')
        path.chmod(0o755)
        return path

    def test_actual_formatter_commands_fail_closed(self):
        shell = _shell_path()
        real_od = _resolved_tool('od', shell)
        real_tr = _resolved_tool('tr', shell)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self._make_root(base)
            good = _run_snapshot_formatter(root)
            self.assertEqual(good.returncode, 0, good.stderr)
            canonical = capture._snapshot_records(good.stdout, 'positive')
            self.assertIn('files/one', canonical)
            for command, real in [('od', real_od), ('tr', real_tr)]:
                bin_dir = base / (command + '-bin')
                bin_dir.mkdir()
                marker = base / (command + '.marker')
                wrapper = self._wrapper(
                    bin_dir / command,
                    shlex.quote(str(real)) + ' "$@"' + chr(10) +
                    'rc=$?' + chr(10) + '[ "$rc" -eq 0 ] || exit "$rc"' + chr(10) +
                    'printf fault >> ' + shlex.quote(str(marker)) + chr(10) +
                    'exit 17')
                completed = _run_snapshot_formatter(root, extra_path=bin_dir)
                self.assertNotEqual(completed.returncode, 0, command)
                self.assertTrue(marker.exists() and marker.read_text(), command)
            # Encoder-output printf and record-emission printf have distinct
            # actual call sites; make each fired branch visible via a marker.
            for phase, condition in [
                ('encoder', 'case "$1" in %s) printf fault >> ' + shlex.quote(str(base / 'encoder.marker')) + '; return 17;; esac;'),
                ('record', 'case "$1" in F*) printf fault >> ' + shlex.quote(str(base / 'record.marker')) + '; return 19;; esac;'),
            ]:
                bin_dir = base / (phase + '-bin')
                bin_dir.mkdir()
                prefix = ('printf() { command printf "$@"; rc=$?; [ "$rc" -eq 0 ] || return "$rc"; '
                          + condition + ' return 0; }; ')
                self._wrapper(
                    bin_dir / 'sh',
                    'if [ "$1" = "-c" ]; then' + chr(10) +
                    ' code=$2' + chr(10) + ' shift 2' + chr(10) +
                    ' exec ' + shlex.quote(str(Path(shell).as_posix())) +
                    ' -c ' + shlex.quote(prefix) + '"$code" "$@"' + chr(10) +
                    'fi' + chr(10) +
                    'exec ' + shlex.quote(str(Path(shell).as_posix())) + ' "$@"')
                completed = _run_snapshot_formatter(root, extra_path=bin_dir)
                self.assertNotEqual(completed.returncode, 0, phase)
                marker = base / (phase + '.marker')
                self.assertTrue(marker.exists() and marker.read_text(), phase)

    def test_repeated_byte_filename_is_not_abbreviated_by_od(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self._make_root(Path(directory))
            name = 'a' * 100
            (root / 'files' / name).write_bytes(b'r')
            completed = _run_snapshot_formatter(root)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            records = capture._snapshot_records(completed.stdout, 'repeated-name')
            self.assertIn('files/' + name, records)

    def test_formatter_does_not_require_a_writable_tmp(self):
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self._make_root(base)
            env = os.environ.copy()
            env['TMPDIR'] = str(base / 'unwritable-tmp')
            self.assertFalse(Path(env['TMPDIR']).exists())
            completed = _run_snapshot_formatter(root, env_overrides=env)
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn('files/one', capture._snapshot_records(completed.stdout, 'no-temp'))

    @unittest.skipUnless(os.name == 'nt', 'Windows PATH precedence control')
    def test_windows_posix_tools_keep_precedence_and_complete_fallback(self):
        import shutil
        from unittest import mock
        shell = Path(_shell_path())
        tool_root = _complete_fixture_context()
        dll = tool_root / 'msys-2.0.dll'
        complete_shell = tool_root / ('sh.exe' if os.name == 'nt' else 'sh')
        real_od = _resolved_tool('od', str(complete_shell))
        real_tr = _resolved_tool('tr', str(complete_shell))
        windows = Path(os.environ['SystemRoot'])
        system32 = windows / 'System32'
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self._make_root(base)
            for phase, tools in [('both', [real_od, real_tr]), ('od', [real_od]), ('tr', [real_tr])]:
                bin_dir = base / ('bin-' + phase)
                bin_dir.mkdir()
                for tool in [*tools, dll]:
                    shutil.copy2(tool, bin_dir / tool.name)
                if phase == 'both':
                    paths = [
                        str(bin_dir), str(system32), str(tool_root), str(windows)
                    ]
                else:
                    paths = [str(bin_dir), str(system32), str(windows)]
                env = os.environ.copy()
                env['PATH'] = os.pathsep.join(paths)
                # Premises must be visible in the parent PATH before the
                # unchanged helper adds its complete POSIX tool-root prefix.
                if phase == 'od':
                    self.assertIsNone(
                        __import__('shutil').which('tr', path=env['PATH'])
                    )
                elif phase == 'tr':
                    self.assertIsNone(
                        __import__('shutil').which('od', path=env['PATH'])
                    )
                else:
                    visible_find = __import__('shutil').which(
                        'find', path=env['PATH']
                    )
                    self.assertIsNotNone(visible_find)
                    self.assertEqual(
                        Path(visible_find).parent.name.lower(), 'system32'
                    )
                complete_shell = tool_root / (
                    'sh.exe' if os.name == 'nt' else 'sh'
                )
                with mock.patch.dict(os.environ, env, clear=True),                         mock.patch.object(
                            sys.modules[__name__], '_shell_path',
                            lambda: str(complete_shell),
                        ):
                    completed = _run_snapshot_formatter(root)
                self.assertEqual(completed.returncode, 0, (phase, completed.stderr))
                records = capture._snapshot_records(completed.stdout, phase)
                self.assertIn('files/one', records, phase)

    @unittest.skipUnless(os.name == 'nt', 'Windows host non-Windows branch control')
    def test_non_windows_branch_uses_preferred_child_path_tool(self):
        import shutil
        import types
        from unittest import mock
        shell = Path(_shell_path())
        complete = _complete_fixture_context()
        complete_shell = complete / ('sh.exe' if os.name == 'nt' else 'sh')
        real_od = _resolved_tool('od', str(complete_shell))
        dll = complete / 'msys-2.0.dll'
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            root = self._make_root(base)
            preferred = base / 'preferred'
            preferred.mkdir()
            shutil.copy2(real_od, preferred / real_od.name)
            shutil.copy2(dll, preferred / dll.name)
            env = os.environ.copy()
            env['PATH'] = (
                str(preferred)
                + os.pathsep
                + str(complete)
                + os.pathsep
                + env.get('PATH', '')
            )
            proxy = types.SimpleNamespace(
                name='posix', environ=os.environ, pathsep=os.pathsep
            )
            with mock.patch.dict(os.environ, env, clear=True),                     mock.patch.object(
                        sys.modules[__name__], 'os', proxy, create=True
                    ):
                selected = _resolved_tool('od', str(shell))
                completed = _run_snapshot_formatter(root)
            self.assertEqual(selected.resolve(), (preferred / real_od.name).resolve())
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertIn('files/one', capture._snapshot_records(completed.stdout, 'preferred'))

    @unittest.skipUnless(os.name == 'nt', 'split-shell permanent method control')
    def test_split_shell_executes_both_permanent_methods(self):
        import shutil
        from unittest import mock
        complete = _complete_fixture_context()
        shell = complete / 'sh.exe'
        with tempfile.TemporaryDirectory() as directory:
            alias_dir = Path(directory) / 'shell-only'
            alias_dir.mkdir()
            shutil.copy2(shell, alias_dir / shell.name)
            with mock.patch.object(
                    sys.modules[__name__], '_shell_path',
                    lambda: str(alias_dir / shell.name)):
                for name in [
                    'test_windows_posix_tools_keep_precedence_and_complete_fallback',
                    'test_non_windows_branch_uses_preferred_child_path_tool',
                ]:
                    result = unittest.TestResult()
                    FormatterFailureTest(name).run(result)
                    self.assertEqual(result.testsRun, 1, name)
                    self.assertEqual(result.errors, [], name)
                    self.assertEqual(result.skipped, [], name)
                    self.assertEqual(result.failures, [], name)

    @unittest.skipUnless(os.name == 'nt', 'Windows incomplete-first context control')
    def test_incomplete_first_context_uses_complete_fallback(self):
        import shutil
        from unittest import mock
        complete = _complete_fixture_context()
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for missing in ('find', 'sha256sum'):
                incomplete = base / ('incomplete-' + missing)
                incomplete.mkdir()
                for name in ('sh', 'od', 'tr'):
                    shutil.copy2(complete / (name + '.exe'), incomplete / (name + '.exe'))
                shutil.copy2(complete / 'msys-2.0.dll', incomplete / 'msys-2.0.dll')
                if missing != 'find':
                    shutil.copy2(complete / 'find.exe', incomplete / 'find.exe')
                if missing != 'sha256sum':
                    shutil.copy2(complete / 'sha256sum.exe', incomplete / 'sha256sum.exe')
                env = os.environ.copy()
                env['PATH'] = os.pathsep.join([
                    str(incomplete), str(complete), str(Path(os.environ['SystemRoot']) / 'System32'),
                    os.environ['SystemRoot'],
                ])
                incomplete_shell = incomplete / 'sh.exe'
                root_base = base / ('root-' + missing)
                root_base.mkdir()
                root = self._make_root(root_base)
                with mock.patch.dict(os.environ, env, clear=True),                         mock.patch.object(
                            sys.modules[__name__], '_shell_path',
                            lambda: str(incomplete_shell),
                        ):
                    positive = _run_snapshot_formatter(root)
                    self.assertEqual(positive.returncode, 0, (missing, positive.stderr))
                    self.assertIn(
                        'files/one',
                        capture._snapshot_records(positive.stdout, missing),
                    )
                    selected = _complete_fixture_context()
                    self.assertNotEqual(selected.resolve(), incomplete.resolve(), missing)
                    selected_shell = selected / 'sh.exe'
                    with mock.patch.object(
                            sys.modules[__name__], '_shell_path',
                            lambda: str(selected_shell),
                        ):
                        fallback = _run_snapshot_formatter(root)
                    self.assertEqual(fallback.returncode, 0, (missing, fallback.stderr))
                    self.assertIn(
                        'files/one',
                        capture._snapshot_records(fallback.stdout, missing + '-fallback'),
                    )
                    result = unittest.TestResult()
                    FormatterFailureTest(
                        'test_windows_posix_tools_keep_precedence_and_complete_fallback'
                    ).run(result)
                self.assertEqual(result.testsRun, 1, missing)
                self.assertEqual(result.errors, [], missing)
                self.assertEqual(result.skipped, [], missing)
                self.assertEqual(result.failures, [], missing)

    def test_alternative_complete_contexts_remain_usable(self):
        import hashlib
        import shutil
        from unittest import mock
        installed = _complete_fixture_context()
        names = ('sh', 'find', 'sha256sum', 'od', 'tr')
        runtime = [installed / (name + '.exe') for name in names]
        runtime.append(installed / 'bash.exe')
        runtime.extend(sorted(installed.glob('*.dll')))
        self.assertIn(installed / 'msys-2.0.dll', runtime)
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            alternative = base / 'nondefault-installation' / 'usr' / 'bin'
            alternative.mkdir(parents=True)
            (alternative.parent.parent / 'tmp').mkdir()
            originals = {
                original: hashlib.sha256(original.read_bytes()).hexdigest()
                for original in runtime
            }
            for original, digest in originals.items():
                shutil.copy2(original, alternative / original.name)
                self.assertEqual(
                    (alternative / original.name).read_bytes(), original.read_bytes())
                self.assertEqual(
                    hashlib.sha256((alternative / original.name).read_bytes()).hexdigest(),
                    digest)
            windows = Path(os.environ['SystemRoot'])
            installed_root = base / 'installed-positive'
            installed_root.mkdir()
            root = self._make_root(installed_root)
            installed_positive = _run_snapshot_formatter(root)
            self.assertEqual(installed_positive.returncode, 0, installed_positive.stderr)
            self.assertIn(
                'files/one',
                capture._snapshot_records(installed_positive.stdout, 'installed-positive'),
            )
            alternative_env = os.environ.copy()
            alternative_env['PATH'] = os.pathsep.join([
                str(alternative), str(windows / 'System32'), str(windows)])
            alternative_root = base / 'alternative-positive'
            alternative_root.mkdir()
            alternative_root = self._make_root(alternative_root)
            with mock.patch.dict(os.environ, alternative_env, clear=True), \
                    mock.patch.object(
                        sys.modules[__name__], '_shell_path',
                        lambda: str(alternative / 'sh.exe'),
                    ):
                alternative_positive = _run_snapshot_formatter(alternative_root)
                self.assertEqual(
                    alternative_positive.returncode, 0, alternative_positive.stderr)
                self.assertIn(
                    'files/one',
                    capture._snapshot_records(
                        alternative_positive.stdout, 'alternative-positive'),
                )
                canonical = {
                    'c:/program files/git/usr/bin': base / 'absent-canonical-usr-bin',
                    'c:/program files/git/bin': base / 'absent-canonical-bin',
                }
                real_path = Path
                aliases = []
                def bounded_path(value):
                    if isinstance(value, str):
                        name = value.replace(chr(92), '/').lower().rstrip('/')
                        if name in canonical:
                            aliases.append(name)
                            return canonical[name]
                    return real_path(value)
                with mock.patch.object(sys.modules[__name__], 'Path', bounded_path):
                    selected = _complete_fixture_context()
                    self.assertEqual(selected.resolve(), alternative.resolve())
                    result = unittest.TestResult()
                    FormatterFailureTest(
                        'test_incomplete_first_context_uses_complete_fallback'
                    ).run(result)
                self.assertEqual(result.testsRun, 1)
                self.assertEqual(result.errors, [])
                self.assertEqual(result.skipped, [])
                self.assertEqual(result.failures, [])
                self.assertEqual(
                    sorted(set(aliases)), sorted(canonical.keys()))
                result = unittest.TestResult()
                FormatterFailureTest(
                    'test_incomplete_first_context_uses_complete_fallback'
                ).run(result)
                self.assertEqual(result.testsRun, 1)
                self.assertEqual(result.errors, [])
                self.assertEqual(result.skipped, [])
                self.assertEqual(result.failures, [])
            for original, digest in originals.items():
                self.assertEqual(
                    hashlib.sha256(original.read_bytes()).hexdigest(), digest)

    def test_utf8_filename_is_not_transliterated_and_rename_is_visible(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self._make_root(Path(directory))
            chinese = root / 'files' / '汉'
            chinese.write_bytes(b'z')
            env = os.environ.copy()
            env.pop('LC_ALL', None)
            env.update({'LANG': 'en_US.UTF-8', 'LC_CTYPE': 'en_US.UTF-8'})
            before = _run_snapshot_formatter(root, env_overrides=env)
            self.assertEqual(before.returncode, 0, before.stderr)
            before_records = capture._snapshot_records(before.stdout, 'utf8-before')
            self.assertIn('files/汉', before_records)
            self.assertNotIn('files/lI', before_records)
            chinese.rename(root / 'files' / 'lI')
            after = _run_snapshot_formatter(root, env_overrides=env)
            self.assertEqual(after.returncode, 0, after.stderr)
            after_records = capture._snapshot_records(after.stdout, 'utf8-after')
            self.assertIn('files/lI', after_records)
            self.assertNotEqual(before_records, after_records)


class FinalizeContractTest(unittest.TestCase):
    def _evidence(self, selected=False):
        fixture_path = Path(__file__).resolve().with_name(
            'book-url-markers-fixtures-selected.json' if selected else 'book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        raw = capture.sha256_bytes(fixture_bytes)
        lf = capture.sha256_bytes(capture.lf_bytes(fixture_bytes))
        target_root = '/data/data/' + fixture['target']['package']
        scratch_root = target_root + '/cache/liber-fields-02'
        provenance = {
            'schemaVersion': 1,
            'fixtureId': 'FIELDS-02',
            'corpus': {
                'asset': 'field-fixtures.json',
                'bytes': len(fixture_bytes),
                'sha256': raw,
                'sha256Lf': lf,
                'fixtureId': 'FIELDS-02',
                'corpusVersion': 1,
            },
            'sources': capture.harness_source_hashes(selected=selected),
        }
        artifact = {
            'apkSha256': 'a' * 64,
            'selectedAssetSha256': raw,
            'selectedAssetSha256Lf': lf,
            'selectedAssetBytes': len(fixture_bytes),
            'provenanceSha256': 'b' * 64,
            'provenance': provenance,
        }

        def request(index):
            wanted = fixture['expectedRequests'][index]
            response = fixture['responses'][index]
            return {
                'method': wanted['method'],
                'path': wanted['path'],
                'query': wanted.get('query', {}),
                'rawQuery': capture._canonical_raw_query(wanted),
                'stage': 'search',
                'headers': {},
                'body': '',
                'receipt': {
                    'terminal': 'responded',
                    'status': response.get('status', 200),
                    'responseId': response['id'],
                    'redirect': (response.get('headers') or {}).get('Location'),
                    'send': 'completed',
                },
            }

        counts = {
            'html-pattern-redirect-markers': 4,
            'json-pattern-nonmatch-list': 4,
            'json-no-pattern-empty-fallback': 3,
            'json-pattern-empty-terminal': 1,
        }
        cursor = 0
        cases = []
        for entry in fixture['cases']:
            count = counts[entry['id']]
            indexes = list(range(cursor, cursor + count))
            cursor += count
            positive = entry.get('terminal', 'four-stage') != 'search-empty'
            if positive:
                operation_counts = {
                    'html-pattern-redirect-markers': [
                        ('search', 2), ('bookInfo', 0),
                        ('tableOfContents', 1), ('content', 1)],
                    'json-pattern-nonmatch-list': [
                        ('search', 1), ('bookInfo', 1),
                        ('tableOfContents', 1), ('content', 1)],
                }.get(entry['id'], [
                    ('search', 1), ('bookInfo', 0),
                    ('tableOfContents', 1), ('content', 1)])
            else:
                operation_counts = [('search', 1)]
            operation_cursor = indexes[0]
            operations = []
            for name, length in operation_counts:
                operations.append({
                    'name': name, 'outcome': 'completed',
                    'requestStart': operation_cursor,
                    'requestEnd': operation_cursor + length,
                    'traceStart': operation_cursor,
                    'traceEnd': operation_cursor + length,
                })
                operation_cursor += length
            record = {
                'id': entry['id'],
                'terminal': entry.get('terminal', 'four-stage'),
                'search': {'results': []},
                'bookInfo': None,
                'tableOfContents': None,
                'chapter': None,
                'sourceProbes': {'vipProbe': None, 'payProbe': None},
                'operations': operations,
                'requests': [request(index) for index in indexes],
            }
            if positive:
                record.update({
                    'search': {'results': [{
                        'name': 'synthetic', 'author': 'synthetic',
                        'bookUrl': 'http://127.0.0.1:18733/book',
                        'infoHtml': True,
                    }]},
                    'bookInfo': {
                        'name': 'synthetic', 'author': 'synthetic',
                        'bookUrl': 'http://127.0.0.1:18733/book',
                        'tocUrl': '/toc',
                    },
                    'tableOfContents': {
                        'tocUrl': '/toc',
                        'chapters': [{
                            'title': 'chapter', 'url': '/c',
                            'absoluteUrl': 'http://127.0.0.1:18733/c',
                            'tag': None, 'isVolume': False,
                            'isVip': False, 'isPay': False,
                            'bookUrl': 'http://127.0.0.1:18733/book',
                        }],
                    },
                    'chapter': {'title': 'chapter', 'text': 'body'},
                })
            cases.append(record)
        requests = [request(index) for index in range(len(fixture['expectedRequests']))]
        trace = []
        for case in cases:
            for operation in case['operations']:
                for index in range(operation['requestStart'], operation['requestEnd']):
                    item = requests[index]
                    trace.append({
                        'stage': operation['name'],
                        'path': fixture['origin'] + item['path']
                        + ('' if not item['rawQuery'] else '?' + item['rawQuery']),
                    })
                    requests[index]['stage'] = operation['name']
                    local = index - case['operations'][0]['requestStart']
                    case['requests'][local]['stage'] = operation['name']
        report = {
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            'baselineCommit': fixture['baselineCommit'],
            'entryPoint': fixture['entryPoint'], 'origin': fixture['origin'],
            'platform': 'android',
            'fingerprint': fixture['target']['deviceFingerprint'],
            'corpus': {
                'asset': 'field-fixtures.json', 'bytes': len(fixture_bytes),
                'sha256': raw, 'sha256Lf': lf,
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            },
            'isolation': {
                'bound': True, 'filesRouted': True, 'databaseRouted': True,
                'deviceProtected': False, 'rootExistedAtStart': False,
                'targetPackage': fixture['target']['package'],
                'targetApkSha256': fixture['target']['apkSha256'],
                'harnessPackage': capture.PACKAGE,
                'harnessApkSha256': artifact['apkSha256'],
                'corpusSha256Lf': lf,
                'preferencesPrefix': 'liber_fields_02_',
                'scratchRoot': scratch_root,
                'preferenceProbe': {
                    'name': 'liber_fields_02_probe', 'registered': True,
                    'committed': True, 'scopedFile': True,
                    'installationFile': False,
                },
            },
            'cleanup': {
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
                'serverClosed': True, 'ownerComplete': True,
                'rootRetained': True, 'preferencesFenced': True,
                'ownerRunId': 'run', 'scratchRoot': scratch_root,
                'reportPath': scratch_root + '/field-oracle.json',
                'ownedPreferences': ['liber_fields_02_probe'],
            },
            'analysisFailure': None, 'caseFailures': {},
            'cases': cases, 'requests': requests, 'stageTrace': trace,
            'unmatchedRequests': [], 'serverErrors': [],
        }
        manifest = {
            'status': 'not-run',
            'corpus': {
                'path': str(fixture_path), 'sha256': raw,
                'bytes': len(fixture_bytes), 'sha256Lf': lf,
                'assetCopySha256': raw, 'fixtureId': 'FIELDS-02',
                'corpusVersion': 1,
            },
            'fingerprint': fixture['target']['deviceFingerprint'],
            'baselineApkSha256': fixture['target']['apkSha256'],
            'harnessApkSha256': artifact['apkSha256'],
            'artifact': artifact,
            'targetPrivateRoot': target_root,
            'frozenSources': {
                entry['path']: {'blobSha1': entry['sha1']}
                for entry in fixture['frozenSources']
            },
            'harnessSources': capture.harness_source_hashes(selected=selected),
            'scratchOwner': {
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
                'targetPackage': fixture['target']['package'],
                'harnessPackage': capture.PACKAGE,
                'targetApkSha256': fixture['target']['apkSha256'],
                'harnessApkSha256': artifact['apkSha256'],
                'corpusSha256Lf': lf, 'complete': True,
                'seedRunId': 'run', 'seedPid': 4242,
                'preferences': ['liber_fields_02_probe'],
            },
        }
        cleanup = {
            'rootAbsent': True, 'ownedPreferencesAbsent': True,
            'postStop': True, 'root': scratch_root,
            'ownerRunId': 'run',
            'reportedOwnedPreferences': ['liber_fields_02_probe'],
        }
        before = _snapshot_bytes(capture.FROZEN_APP_STORE, ['.', 'cache', 'databases', 'shared_prefs', 'files'])
        return fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before

    def test_selected_finalize_refuses_duplicate_raw_report_keys(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence(selected=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = b'{"fixtureId":"FIELDS-02","fixtureId":"FIELDS-02"}'
            (output / 'field-oracle.json').write_bytes(payload)
            with self.assertRaisesRegex(ValueError, 'duplicate JSON key'):
                capture.finalize(output, fixture, manifest, json.loads(payload), before, before,
                                 asset=fixture_path, scratch_cleanup=cleanup,
                                 fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())

    def test_selected_finalize_refuses_missing_runtime_terminal_proof(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence(selected=True)
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            with self.assertRaisesRegex(ValueError, 'selected runtime'):
                capture.finalize(output, fixture, manifest, report, before, before,
                                 asset=fixture_path, scratch_cleanup=cleanup,
                                 fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())

    def test_selected_finalize_mechanics_requires_each_terminal(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence(selected=True)
        report['startupContainment'] = {'service': 'shortcut', 'provider': 'io.legado.app.api.ReaderProvider',
                                        'intercepted': 1, 'handled': 1, 'beforeBinding': True}
        report['isolation']['appClass'] = 'io.liber.oracle.nested.GuardedReaderApplication'
        report['hostInitialization'] = {'verified': True, 'applicationAttached': False,
                                        'invokedOn': 'unattached-instance',
                                        'notRun': ['io.legado.app.App.onCreate'],
                                        'registeredWrappers': {r['type']: r['factory'] for r in fixture['hostInitialization']['registrations']},
                                        'method': fixture['hostInitialization']['method']}
        report['terminalOwner'] = {'scope': 'Coroutine.DEFAULT', 'rootActive': True, 'rootCompleted': False,
                                   'baselineChildren': 0, 'childrenMethod': 'kotlinx.coroutines.Job.getChildren()',
                                   'completionMethod': 'kotlinx.coroutines.Job.isCompleted()'}
        report['entryPoints'] = {
            'searchBookAwait': 'searchBookAwait(io.legado.app.data.entities.BookSource,java.lang.String,java.lang.Integer,kotlin.jvm.functions.Function3,kotlin.jvm.functions.Function1,kotlin.coroutines.Continuation)',
            'getBookInfoAwait': 'getBookInfoAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,kotlin.coroutines.Continuation)',
            'getChapterListAwait': 'getChapterListAwait-yxL6bBk(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,boolean,boolean,kotlin.coroutines.Continuation)',
            'getContentAwait': 'getContentAwait(io.legado.app.data.entities.BookSource,io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,kotlin.coroutines.Continuation)',
        }
        report['entryPoints'] = {key: 'public final java.lang.Object io.legado.app.model.webBook.WebBook.' + value
                                 for key, value in report['entryPoints'].items()}
        for case in report['cases']:
            case['terminalOwner'] = {'owner': 'Coroutine.DEFAULT Job', 'observedChildren': 0,
                                     'allCompleted': True, 'rootEmpty': True, 'launchAttempts': 0}
        report['cleanup'].update({'openConnectionsAfterClose': 0, 'databaseClosed': True,
                                  'activityLaunchAttempts': 0})
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            path = output / 'field-oracle.json'
            bad = json.loads(json.dumps(report))
            bad['cases'][2]['terminalOwner']['rootEmpty'] = False
            path.write_text(json.dumps(bad), encoding='utf-8')
            with self.assertRaisesRegex(ValueError, 'case terminal'):
                capture.finalize(output, fixture, manifest, bad, before, before,
                                 asset=fixture_path, scratch_cleanup=cleanup,
                                 fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())
            payload = json.dumps(report).encode()
            path.write_bytes(payload)
            capture._admit_selected_runtime(report, fixture)  # synthetic mechanics, not a native golden
            with self.assertRaisesRegex(ValueError, 'selected command receipts'):
                capture.finalize(output, fixture, manifest, report, before, before,
                                 asset=fixture_path, scratch_cleanup=cleanup,
                                 fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())

    def test_historical_five_source_finalize_joins_original_apk(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        sources = {name: digest for name, digest in manifest['harnessSources'].items()
                   if name not in ('HostRuntimeInit.java', 'ShortcutStartupGuard.java')}
        manifest['harnessSources'] = sources
        manifest['artifact']['provenance']['sources'] = sources
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = output / 'historical.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture_bytes)
                archive.writestr('assets/field-provenance.json',
                                 json.dumps(manifest['artifact']['provenance']))
            artifact = capture.inspect_selected_apk(apk, fixture_path, fixture, None)
            manifest['artifact'] = artifact
            manifest['harnessApkSha256'] = artifact['apkSha256']
            manifest['scratchOwner']['harnessApkSha256'] = artifact['apkSha256']
            report['isolation']['harnessApkSha256'] = artifact['apkSha256']
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            altered = json.loads(json.dumps(manifest))
            altered['harnessSources']['FieldOracle.java'] = '0' * 64
            with self.assertRaises(ValueError):
                capture.finalize(output, fixture, altered, report, before, before,
                                 asset=fixture_path, scratch_cleanup=cleanup,
                                 fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())
            capture.finalize(output, fixture, manifest, report, before, before,
                             asset=fixture_path, scratch_cleanup=cleanup,
                             fixture_bytes=fixture_bytes, original_apk=apk)
            self.assertEqual((output / 'golden.json').read_bytes(), payload)

    def test_offline_finalize_requires_external_inventory(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            cleanup['reportedOwnedPreferences'] = None
            with self.assertRaises(ValueError):
                capture.finalize(
                    output, fixture, manifest, report, before, before,
                    asset=fixture_path, scratch_cleanup=cleanup,
                    fixture_bytes=fixture_bytes, report_bytes=payload,
                    original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())

    def test_offline_finalize_without_original_apk_refuses(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            with self.assertRaises(ValueError):
                capture.finalize(
                    output, fixture, manifest, report, before, before,
                    asset=fixture_path, scratch_cleanup=cleanup,
                    fixture_bytes=fixture_bytes, report_bytes=payload)
            self.assertFalse((output / 'golden.json').exists())

    def test_offline_finalize_consumes_copied_evidence_and_original_apk(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'evidence'
            output.mkdir()
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            (output / 'private-before.log').write_bytes(before)
            (output / 'private-after.log').write_bytes(before)
            manifest['status'] = 'not-run'
            manifest['scratchCleanup'] = cleanup
            (output / 'manifest.json').write_text(
                json.dumps(manifest, ensure_ascii=False, indent=2) + chr(10),
                encoding='utf-8')
            argv = ['capture.py', '--serial', '5615f742', '--apk', str(apk),
                    '--fixture', str(fixture_path), '--output', str(output),
                    '--finalize']
            from unittest.mock import patch
            with patch.object(sys, 'argv', argv):
                self.assertEqual(capture.main(), 0)
            self.assertEqual((output / 'golden.json').read_bytes(), payload)
            self.assertEqual(
                json.loads((output / 'manifest.json').read_text(encoding='utf-8'))['status'],
                'observed')

    def _selected_apk(self, directory, fixture_path, fixture, manifest, report):
        apk = Path(directory) / 'selected.apk'
        provenance = manifest['artifact']['provenance']
        with zipfile.ZipFile(apk, 'w') as archive:
            archive.writestr('assets/field-fixtures.json', fixture_path.read_bytes())
            archive.writestr('assets/field-provenance.json',
                             json.dumps(provenance))
        artifact = capture.inspect_selected_apk(
            apk, fixture_path, fixture, capture.harness_source_hashes(
                selected=fixture.get('baselineCommit') == capture.SELECTED_BASELINE))
        manifest['artifact'] = artifact
        manifest['harnessApkSha256'] = artifact['apkSha256']
        report['isolation']['harnessApkSha256'] = artifact['apkSha256']
        manifest['scratchOwner']['harnessApkSha256'] = artifact['apkSha256']
        return apk

    def test_positive_report_is_validated_and_promoted_exactly(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            result = capture.finalize(
                output, fixture, manifest, report, before, before,
                asset=fixture_path, scratch_cleanup=cleanup,
                fixture_bytes=fixture_bytes, report_bytes=payload,
                original_apk=apk)
            self.assertFalse(result['goldenReused'])
            self.assertEqual((output / 'golden.json').read_bytes(), payload)
            self.assertEqual(manifest['status'], 'observed')

    def test_public_finalize_refuses_unknown_family(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        unknown = dict(fixture)
        unknown['fixtureId'] = 'UNKNOWN-FAMILY'
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            with self.assertRaises(ValueError):
                capture.finalize(
                    output, unknown, manifest, report, before, before,
                    asset=fixture_path, scratch_cleanup=cleanup,
                    fixture_bytes=fixture_bytes, report_bytes=payload,
                    original_apk=fixture_path)

    def test_incomplete_private_snapshot_refuses_promotion(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        incomplete = ''.join(
            'a' * 64 + '  ' + path + chr(10)
            for path in capture.FROZEN_APP_STORE).encode()
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory)
            apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
            payload = json.dumps(report).encode()
            (output / 'field-oracle.json').write_bytes(payload)
            with self.assertRaises(ValueError):
                capture.finalize(
                    output, fixture, manifest, report, incomplete, incomplete,
                    asset=fixture_path, scratch_cleanup=cleanup,
                    fixture_bytes=fixture_bytes, report_bytes=payload,
                    original_apk=apk)
            self.assertFalse((output / 'golden.json').exists())

    def test_strict_types_and_changed_fixture_refuse_promotion(self):
        fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before = self._evidence()
        for mutate in [
            lambda r: r.update(corpusVersion=True),
            lambda r: r['corpus'].update(bytes=float(len(fixture_bytes))),
            lambda r: r['stageTrace'][0].update(stage='bookInfo'),
            lambda r: r['requests'][0].update(stage='bookInfo'),
            lambda r: r['stageTrace'][0].update(path='http://127.0.0.1:18733/wrong'),
            lambda r: r['stageTrace'][1].update(path=r['stageTrace'][0]['path']),
            lambda r: r['stageTrace'][2].update(path=r['stageTrace'][3]['path']),
            lambda r: r['stageTrace'][0].update(path=r['requests'][0]['path']),
            lambda r: r['cases'][0]['operations'][0].update(outcome='error'),
            lambda r: r['cases'][0]['operations'][0].update(requestEnd=999),
            lambda r: r['cases'][0].pop('operations'),
        ]:
            changed = json.loads(json.dumps(report))
            mutate(changed)
            with tempfile.TemporaryDirectory() as directory:
                output = Path(directory)
                apk = self._selected_apk(directory, fixture_path, fixture, manifest, report)
                payload = json.dumps(changed).encode()
                (output / 'field-oracle.json').write_bytes(payload)
                with self.assertRaises(ValueError):
                    capture.finalize(
                        output, fixture, manifest, changed, before, before,
                        asset=fixture_path, scratch_cleanup=cleanup,
                        fixture_bytes=fixture_bytes, report_bytes=payload,
                        original_apk=apk)
                self.assertFalse((output / 'golden.json').exists())


if __name__ == '__main__':
    unittest.main()
