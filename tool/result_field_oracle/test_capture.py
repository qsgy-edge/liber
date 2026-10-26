"""Small stdlib regressions for the FIELDS-02 capture boundary."""
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
             package_query_stderr=b'', package_query_stdout=None):
        import io
        from contextlib import redirect_stdout
        from unittest.mock import patch

        fixture = Path(__file__).resolve().with_name('book-url-markers-fixtures.json')
        fixture_data = json.loads(fixture.read_text(encoding='utf-8'))
        commands = []
        calls = {'finalize': 0, 'install_attempted': False}
        target_root = '/data/user/0/io.legado.app.debug'
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
                elif args[-3:] == ['pm', 'path', capture.TARGET_PACKAGE]:
                    stdout = b'package:/synthetic/frozen.apk\n'
                elif args[-3:] == ['pm', 'path', capture.PACKAGE]:
                    if existing_harness and not calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    elif partial and calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    else:
                        code = 1
                elif args[-4:] == ['pm', 'list', 'packages', capture.PACKAGE]:
                    if package_query_stdout is not None:
                        stdout = package_query_stdout
                    elif package_query_code:
                        code = package_query_code
                        stderr = package_query_stderr
                    elif existing_harness and not calls['install_attempted']:
                        stdout = b'package:' + capture.PACKAGE.encode() + bytes([10])
                    elif partial and calls['install_attempted']:
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
                elif 'install' in args:
                    calls['install_attempted'] = True
                    code = install_code
                elif 'uninstall' in args:
                    code = uninstall_code
                elif 'am' in args and 'instrument' in args:
                    code = instrument_code
                    calls['instrument_failed'] = instrument_code != 0
                elif 'am' in args and 'force-stop' in args:
                    code = stop_code
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
            return subprocess.CompletedProcess(args, code, stdout, stderr)

        with tempfile.TemporaryDirectory() as directory:
            # Build the actual original APK and compose the same evidence the
            # finalizer consumes; only adb/git transport is mocked.
            evidence = FinalizeContractTest()._evidence()
            report = json.loads(json.dumps(evidence[3]))
            owner = json.loads(json.dumps(evidence[4]['scratchOwner']))
            provenance = evidence[4]['artifact']['provenance']
            apk = Path(directory) / 'field-oracle.apk'
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/field-fixtures.json', fixture.read_bytes())
                archive.writestr('assets/field-provenance.json', json.dumps(provenance))
            artifact = capture.inspect_selected_apk(
                apk, fixture, fixture_data, capture.harness_source_hashes())
            report['isolation'].update({
                'targetPackage': capture.TARGET_PACKAGE,
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
                'targetPackage': capture.TARGET_PACKAGE,
                'harnessPackage': capture.PACKAGE,
                'targetApkSha256': fixture_data['target']['apkSha256'],
                'harnessApkSha256': artifact['apkSha256'],
                'corpusSha256Lf': artifact['selectedAssetSha256Lf'],
                'complete': True, 'seedRunId': 'run', 'seedPid': 4242,
                'preferences': ['liber_fields_02_probe'],
            })
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
            with patch.object(sys, 'argv', argv), \
                    patch.object(capture, 'sha256', fake_sha), \
                    patch.object(capture.subprocess, 'run', fake_run), \
                    patch.object(capture.tempfile, 'mkdtemp', lambda **kwargs: str(cache)), \
                    patch.object(capture, 'finalize', counting_finalize), \
                    redirect_stdout(io.StringIO()):
                exit_code = capture.main()
            calls['golden'] = (output / 'golden.json').exists()
            if (output / 'manifest.json').exists():
                calls['manifest_status'] = json.loads(
                    (output / 'manifest.json').read_text(encoding='utf-8'))['status']
        return exit_code, commands, calls

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

    def test_malformed_package_inventory_is_refused(self):
        exit_code, commands, calls = self._run(
            package_query_stdout=b'package:' + bytes([10]))
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)

    def test_contradictory_package_inventory_is_refused(self):
        exit_code, commands, calls = self._run(
            package_query_code=1,
            package_query_stdout=b'package:' + capture.PACKAGE.encode() + bytes([10]))
        self.assertEqual(exit_code, 1)
        self.assertFalse(calls['install_attempted'])
        self.assertEqual(calls['finalize'], 0)

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
    def _evidence(self):
        fixture_path = Path(__file__).resolve().with_name(
            'book-url-markers-fixtures.json')
        fixture_bytes = fixture_path.read_bytes()
        fixture = json.loads(fixture_bytes)
        raw = capture.sha256_bytes(fixture_bytes)
        lf = capture.sha256_bytes(capture.lf_bytes(fixture_bytes))
        target_root = '/data/data/io.legado.app.debug'
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
            'sources': capture.harness_source_hashes(),
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
                'targetPackage': capture.TARGET_PACKAGE,
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
            'harnessSources': capture.harness_source_hashes(),
            'scratchOwner': {
                'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
                'targetPackage': capture.TARGET_PACKAGE,
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
            apk, fixture_path, fixture, capture.harness_source_hashes())
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
