"""Small stdlib regressions for the FIELDS-02 capture boundary."""
import json
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile
import unittest
import zipfile

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
             instrument_code=0):
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

        def fake_sha(path):
            if Path(path).name == 'frozen.apk':
                return fixture_data['target']['apkSha256']
            return actual_sha(path)

        def fake_run(args, **kwargs):
            commands.append(list(map(str, args)))
            text = ' '.join(map(str, args))
            stdout, code = b'', 0
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
                    if partial and calls['install_attempted']:
                        stdout = b'package:/synthetic/partial.apk\n'
                elif 'pidof' in args:
                    if process_pid is None:
                        code = 1
                    else:
                        stdout = (str(process_pid) + '\n').encode()
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
                        code = snapshot_code
                        stdout = before_lines if snapshot_code == 0 else b''
                    elif 'probe.xml' in script:
                        stdout = (b'PRESENT' + chr(10)) if installation_probe else b''
                    elif 'scratch-root-check' in text or 'if [ -e ' in script:
                        stdout = (root_state + '\n').encode()
                    elif 'find ' in script:
                        stdout = b'' if ' -name ' in script else before_lines
            return subprocess.CompletedProcess(args, code, stdout, b'')

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

    def test_partial_install_is_preserved_or_refused(self):
        exit_code, commands, calls = self._run(install_code=1, partial=True)
        self.assertEqual(exit_code, 1)
        self.assertEqual(calls['finalize'], 0)
        self.assertTrue(calls['install_attempted'])
        self.assertFalse(any('force-stop' in cmd for cmd in commands))
        self.assertFalse(any('rm -f ' in ' '.join(cmd) or 'rm -rf ' in ' '.join(cmd)
                             for cmd in commands))
        self.assertFalse(any('uninstall' in cmd for cmd in commands))


class SnapshotParserTest(unittest.TestCase):
    def test_typed_parser_refuses_ambiguous_or_unsupported_nodes(self):
        tab, newline = chr(9), chr(10)
        for payload in [
            ('F' + tab + 'not-a-digest' + tab + 'file' + newline).encode(),
            ('F' + tab + 'a' * 64 + tab + 'file' + newline +
             'F' + tab + 'a' * 64 + tab + 'file' + newline).encode(),
            ('U' + tab + '-' + tab + 'link' + newline).encode(),
            ('F' + tab + 'a' * 64 + tab + '../escape' + newline).encode(),
            ('plain sha output' + newline).encode(),
        ]:
            with self.assertRaises(ValueError):
                capture._snapshot_records(payload, 'test')


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
        trace = [
            {'stage': 'search', 'path': fixture['origin'] + item['path']
             + ('' if not item['rawQuery'] else '?' + item['rawQuery'])}
            for item in requests
        ]
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
        before = (''.join(
            'F\t' + 'a' * 64 + '\t' + path + '\n'
            for path in capture.FROZEN_APP_STORE)
            + ''.join('D\t-\t' + path + '\n'
                      for path in ['.', 'cache', 'databases', 'shared_prefs', 'files'])).encode()
        return fixture_path, fixture_bytes, fixture, report, manifest, cleanup, before

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
