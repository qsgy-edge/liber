"""Small stdlib regressions for the FIELDS-02 capture boundary."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parent))
import capture  # noqa: E402


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


class DriverBoundaryTest(unittest.TestCase):
    def _run(self, root_state='ABSENT', install_code=0, stop_code=0,
             uninstall_code=0, partial=False):
        import io
        from contextlib import redirect_stdout
        from unittest.mock import patch

        repo = Path('D:/GithubRepositories/Flutter/liber-138-evidence')
        fixture = repo / 'tool/result_field_oracle/book-url-markers-fixtures.json'
        fixture_data = json.loads(fixture.read_text(encoding='utf-8'))
        commands = []
        calls = {'finalize': 0, 'install_attempted': False}
        actual_sha = capture.sha256

        def fake_sha(path):
            if Path(path).name == 'frozen.apk':
                return fixture_data['target']['apkSha256']
            return actual_sha(path)

        report = {
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            'baselineCommit': fixture_data['baselineCommit'],
            'entryPoint': fixture_data['entryPoint'],
            'origin': fixture_data['origin'], 'platform': 'android',
            'fingerprint': fixture_data['target']['deviceFingerprint'],
            'cleanup': {
                'serverClosed': True, 'ownerComplete': True, 'rootRetained': True,
                'preferencesFenced': True, 'ownerRunId': 'run',
                'scratchRoot': capture.SCRATCH_ROOT,
                'reportPath': capture.REPORT_REMOTE_FIELDS_02,
                'ownedPreferences': ['liber_fields_02_probe'],
            },
        }
        owner = {
            'fixtureId': 'FIELDS-02', 'corpusVersion': 1,
            'targetPackage': capture.TARGET_PACKAGE, 'harnessPackage': capture.PACKAGE,
            'targetApkSha256': fixture_data['target']['apkSha256'],
            'harnessApkSha256': 'synthetic-harness',
            'corpusSha256Lf': 'synthetic-corpus', 'complete': True,
            'seedRunId': 'run', 'preferences': ['liber_fields_02_probe'],
        }
        report_bytes = json.dumps(report).encode()
        owner_bytes = json.dumps(owner).encode()
        before_lines = ''.join(
            'a' * 64 + '  ' + path + '\n' for path in capture.FROZEN_APP_STORE).encode()

        def fake_run(args, **kwargs):
            commands.append(list(map(str, args)))
            text = ' '.join(map(str, args))
            stdout, code = b'', 0
            if args[0] == 'git':
                if 'rev-parse' in args:
                    stdout = (fixture_data['baselineCommit'] + '\n').encode()
                elif 'hash-object' in args:
                    stdout = ('\n'.join(item['sha1'] for item in fixture_data['frozenSources']) + '\n').encode()
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
                    if partial and calls['install_attempted']:
                        stdout = b'package:/synthetic/partial.apk\n'
                elif 'pidof' in args:
                    code = 1
                elif 'install' in args:
                    calls['install_attempted'] = True
                    code = install_code
                elif 'uninstall' in args:
                    code = uninstall_code
                elif 'am' in args and 'instrument' in args:
                    code = 0
                elif 'am' in args and 'force-stop' in args:
                    code = stop_code
                elif 'exec-out' in args and capture.REPORT_REMOTE_FIELDS_02 in text:
                    stdout = report_bytes
                elif 'exec-out' in args and capture.OWNER_REMOTE_FIELDS_02 in text:
                    stdout = owner_bytes
                elif 'run-as' in args:
                    script = args[-1]
                    if 'scratch-root-check' in text or 'if [ -e ' in script:
                        stdout = (root_state + '\n').encode()
                    elif 'find ' in script:
                        stdout = b''
                    elif 'private-before' in text or 'private-after' in text:
                        stdout = before_lines
            return subprocess.CompletedProcess(args, code, stdout, b'')

        def fake_finalize(output, fixture_arg, manifest, report_arg, before, after,
                          asset=None, scratch_cleanup=None):
            calls['finalize'] += 1
            manifest['status'] = 'observed'
            manifest['goldenSha256'] = 'synthetic-golden'
            return {'goldenReused': False}

        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'out'
            apk = Path(directory) / 'field-oracle.apk'
            apk.write_bytes(b'synthetic apk')
            cache = Path(directory) / 'baseline'
            cache.mkdir()
            argv = ['capture.py', '--serial', '5615f742', '--apk', str(apk),
                    '--frozen-source', 'D:/GithubRepositories/Android/legado',
                    '--output', str(output), '--asset', str(fixture),
                    '--fixture', str(fixture)]
            with patch.object(sys, 'argv', argv), patch.object(capture, 'sha256', fake_sha), \
                    patch.object(capture.subprocess, 'run', fake_run), \
                    patch.object(capture.tempfile, 'mkdtemp', lambda **kwargs: str(cache)), \
                    patch.object(capture, 'finalize', fake_finalize), \
                    redirect_stdout(io.StringIO()):
                exit_code = capture.main()
        return exit_code, commands, calls

    def test_successful_driver_uses_exact_quoted_cleanup_and_uninstall(self):
        exit_code, commands, calls = self._run()
        self.assertEqual(exit_code, 0)
        self.assertEqual(calls['finalize'], 1)
        self.assertFalse(any('*' in cmd for cmd in commands))
        self.assertTrue(any('rm -f --' in ' '.join(cmd) for cmd in commands))
        remote = [cmd for cmd in commands
                  if 'run-as' in cmd and len(cmd) > 8 and cmd[6] == 'sh']
        self.assertTrue(remote)
        for cmd in remote:
            self.assertEqual(cmd[7], '-c')
            self.assertTrue(cmd[8].startswith("'") and cmd[8].endswith("'"))
        self.assertTrue(any('uninstall' in cmd and capture.PACKAGE in cmd for cmd in commands))

    def test_preexisting_root_is_preserved_without_deletion(self):
        exit_code, commands, calls = self._run(root_state='PRESENT')
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
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

    def test_partial_install_is_preserved_or_refused(self):
        exit_code, commands, calls = self._run(install_code=1, partial=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(calls['install_attempted'])


if __name__ == '__main__':
    unittest.main()
