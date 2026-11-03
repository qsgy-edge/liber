"""Selected reader capture admission mechanics; all reports here are synthetic."""
import copy
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import capture

# Executes the selected shell script on Git Bash only; never Android evidence.
GIT_BASH = Path('C:/Program Files/Git/bin/bash.exe')


def host_selected_inventory(directory, failure=None):
    with tempfile.TemporaryDirectory(prefix='reader-hash-bin-', dir='C:/Temp') as temporary:
        tools = Path(temporary)
        marker = tools / 'hash-called'
        if failure == 'hash':
            wrapper = ('#!/bin/sh\nif [ -e "$READER_HASH_MARKER" ]; then '
                       'echo "synthetic sha256sum failure" >&2; exit 42; fi\n'
                       ': > "$READER_HASH_MARKER"\nexec /usr/bin/sha256sum -t "$@"\n')
        else:
            # Git-for-Windows adds a binary '*' marker; these synthetic text
            # inputs use -t to preserve Android-style two-space records.
            wrapper = '#!/bin/sh\nexec /usr/bin/sha256sum -t "$@"\n'
        (tools / 'sha256sum').write_text(wrapper, encoding='utf-8', newline='\n')
        if failure == 'find':
            (tools / 'find').write_text('#!/bin/sh\necho "synthetic find failure" >&2\nexit 43\n',
                                        encoding='utf-8', newline='\n')
        def posix(path):
            value = path.as_posix()
            return '/' + value[0].lower() + value[2:]
        env = os.environ.copy()
        env['READER_HASH_MARKER'] = posix(marker)
        return subprocess.run([str(GIT_BASH), '--noprofile', '--norc', '-c',
                               'PATH="$1:$PATH"; export PATH; shift; exec sh -c "$1"',
                               'sh', posix(tools), capture.SELECTED_INVENTORY_SCRIPT],
                              cwd=directory, env=env, capture_output=True, timeout=30)


class SelectedReaderAdmissionTest(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(Path(__file__).with_name('fixtures-selected.json').read_text(encoding='utf-8'))
        self.binding = {'corpusAssetSha256': 'b' * 64, 'corpusSha256Lf': 'c' * 64,
                        'harnessApkSha256': 'a' * 64, 'provenanceAssetSha256': 'd' * 64,
                        'dexSha256': '1' * 64, 'sourceHashes': {'reader': 'e' * 64},
                        'sourceHashesLf': {'reader': 'e' * 64}, 'referenceHashes': {s['path']: s['sha256'] for s in self.fixture['frozenSources']}}
        self.report = {'fixtureId': 'REPLACE-17', 'corpusVersion': 2,
                       'baselineCommit': self.fixture['baselineCommit'],
                       'boundary': self.fixture['comparisonBoundary'],
                       'fixtureSha256': self.binding['corpusSha256Lf'],
                       'fingerprint': 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.5.0.XPMCNXM:user/release-keys',
                       'paragraphIndent': '　　',
                       'identity': {'fixtureId': 'REPLACE-17', 'corpusVersion': 2,
                                    'targetPackage': 'com.legado.app.debug',
                                    'targetApkSha256': self.fixture['target']['apkSha256'],
                                    'harnessPackage': 'io.liber.oracle.replace.selected',
                                    **{k: self.binding[k] for k in ('corpusAssetSha256', 'corpusSha256Lf',
                                        'harnessApkSha256', 'provenanceAssetSha256')}},
                       'provenance': {'baselineCommit': self.fixture['baselineCommit'],
                                      **{k: self.binding[k] for k in ('corpusAssetSha256', 'corpusSha256Lf',
                                          'sourceHashes', 'sourceHashesLf', 'referenceHashes', 'dexSha256')}},
                       'hostInitialization': {'verified': True, 'applicationAttached': False,
                           'method': self.fixture['hostInitialization']['method'],
                           'registeredWrappers': {r['type']: r['factory'] for r in self.fixture['hostInitialization']['registrations']}},
                       'startupContainment': {'intercepted': 1, 'handled': 1, 'beforeBinding': True},
                       'isolation': {'verified': True, 'application': 'io.liber.oracle.nested.GuardedReaderApplication',
                                     'preferenceProbe': {'registered': True, 'committed': True, 'scopedFile': True, 'installationFile': False}},
                       'entryPoints': {'getDisplayTitleArity': 4, 'getContentArity': 10,
                           'getDisplayTitle': 'synthetic getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)',
                           'getContent': 'synthetic getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)'},
                       'settingsBefore': {'backupPath': None, 'paragraphIndent': '　　',
                                          'adaptSpecialStyle': True, 'chineseConverterType': 0,
                                          'replaceEnableDefault': True},
                       'terminalOwner': {'scope': 'Coroutine.DEFAULT', 'rootActive': True,
                                         'rootCompleted': False, 'baselineChildren': 0,
                                         'childrenMethod': 'kotlin.sequences.Sequence kotlinx.coroutines.Job.getChildren()',
                                         'completionMethod': 'boolean kotlinx.coroutines.Job.isCompleted()'},
                       'cleanup': {'databaseClosed': True, 'scratchRemoved': True, 'terminalProved': True,
                                   'activityLaunchAttempts': 0, 'scratchRetained': False,
                                   'registeredPreferences': ['liber_replace_selected_probe'],
                                   'preferencesRemoved': [{'name': 'liber_replace_selected_probe', 'ok': True}]},
                       'rows': []}
        self.report['partition'] = {'role': 'reader-non-timeout',
                                    'caseIds': [case['id'] for case in self.fixture['cases'] if case['id'] != 'timeout']}
        for case in self.fixture['cases']:
            if case['id'] == 'timeout':
                continue
            terminal = {'allCompleted': True, 'rootEmpty': True, 'launchAttempts': 0}
            self.report['rows'].append({'id': case['id'], 'status': 'observed', 'title': 'synthetic',
                'content': 'synthetic', 'selection': {'title': [], 'content': []}, 'textList': ['synthetic'],
                'sameTitleRemoved': False, 'effectiveRules': [], 'disabledRules': [], 'terminal': terminal,
                **({'timeoutObserved': False, 'restartObservation': 'notCompared: synthetic'} if case['id'] == 'timeout' else {}),
                'readerCalls': [dict(terminal, method='getDisplayTitle'), dict(terminal, method='getContent')]})

    def test_selected_private_inventory_actual_host_walks(self):
        # Host analogues only. The selected three-root scope is unchanged.
        with tempfile.TemporaryDirectory(prefix='reader-inventory-', dir='C:/Temp') as temporary:
            root = Path(temporary)
            for name in ('databases', 'shared_prefs', 'files'):
                (root / name).mkdir()
            empty = host_selected_inventory(root)
            self.assertEqual(empty.returncode, 0, empty.stderr)
            self.assertEqual(empty.stderr, b'')
            self.assertEqual(empty.stdout, capture.SELECTED_INVENTORY_COMPLETE + b'\n')
            self.assertEqual(capture.parse_selected_private_inventory(empty.stdout), [])
            (root / 'databases' / 'a').write_bytes(b'first')
            (root / 'files' / 'b').write_bytes(b'second')
            complete = host_selected_inventory(root)
            self.assertEqual(complete.returncode, 0, complete.stderr)
            self.assertEqual(complete.stderr, b'')
            self.assertEqual(capture.parse_selected_private_inventory(complete.stdout), sorted([
                (hashlib.sha256(b'first').hexdigest() + '  databases/a').encode(),
                (hashlib.sha256(b'second').hexdigest() + '  files/b').encode(),
            ]))
            failed = host_selected_inventory(root, failure='hash')
            self.assertNotEqual(failed.returncode, 0)
            self.assertTrue(failed.stdout, 'must retain a real partial hash')
            self.assertIn(b'synthetic sha256sum failure', failed.stderr)
            self.assertNotIn(capture.SELECTED_INVENTORY_COMPLETE, failed.stdout)
            with self.assertRaisesRegex(ValueError, 'private inventory.*completion'):
                capture.parse_selected_private_inventory(failed.stdout + failed.stderr)
            failed_find = host_selected_inventory(root, failure='find')
            self.assertNotEqual(failed_find.returncode, 0)
            self.assertIn(b'synthetic find failure', failed_find.stderr)
            self.assertNotIn(capture.SELECTED_INVENTORY_COMPLETE, failed_find.stdout)
            with self.assertRaisesRegex(ValueError, 'private inventory.*completion'):
                capture.parse_selected_private_inventory(failed_find.stdout + failed_find.stderr)
            for invalid in (b'', complete.stdout[:-1], complete.stdout.splitlines()[0] + b'\n',
                            capture.SELECTED_INVENTORY_COMPLETE + b'\n' + complete.stdout,
                            complete.stdout + capture.SELECTED_INVENTORY_COMPLETE + b'\n',
                            b'truncated\n' + capture.SELECTED_INVENTORY_COMPLETE + b'\n',
                            (b'a' * 64 + b'  files/a\n') * 2 + capture.SELECTED_INVENTORY_COMPLETE + b'\n'):
                with self.subTest(invalid=invalid), self.assertRaises(ValueError):
                    capture.parse_selected_private_inventory(invalid)
            quoted = subprocess.run([str(GIT_BASH), '--noprofile', '--norc', '-c',
                                     'set -- ' + capture.SELECTED_INVENTORY_COMMAND + '; printf "%s" "$1"'],
                                    cwd=root, capture_output=True, timeout=30)
            self.assertEqual(quoted.returncode, 0, quoted.stderr)
            self.assertEqual(quoted.stdout.decode('utf-8'), capture.SELECTED_INVENTORY_SCRIPT)

    def test_manifest_attributes_belong_to_their_actual_nodes(self):
        # Synthetic aapt xmltree metadata only; no APK or device is involved.
        text = '''N: android=http://schemas.android.com/apk/res/android
  E: manifest (line=1)
    A: package="io.liber.oracle.replace.selected" (Raw: "io.liber.oracle.replace.selected")
    E: application (line=3)
      A: android:label(0x01010001)="normal" (Raw: "normal")
    E: instrumentation (line=4)
      A: android:name(0x01010003)="io.liber.oracle.nested.SelectedReaderOracle" (Raw: "io.liber.oracle.nested.SelectedReaderOracle")
      A: android:targetPackage(0x01010021)="com.legado.app.debug" (Raw: "com.legado.app.debug")
'''
        capture.check_selected_manifest(text)
        entry = 'io.liber.oracle.nested.SelectedReaderOracle'
        target = 'com.legado.app.debug'
        package = 'io.liber.oracle.replace.selected'
        cases = [
            text.replace('android:targetPackage(0x01010021)="' + target + '" (Raw: "' + target + '")',
                         'android:targetPackage(0x01010021)="wrong" (Raw: "wrong")').replace('"normal"', '"' + target + '"'),
            text.replace('android:name(0x01010003)="' + entry + '" (Raw: "' + entry + '")',
                         'android:name(0x01010003)="wrong" (Raw: "wrong")').replace('"normal"', '"' + entry + '"'),
            text.replace('package="' + package + '"', 'package="wrong"').replace('"normal"', '"' + package + '"'),
            text.replace('      A: android:targetPackage', '      A: android:otherTarget'),
            text + '      A: android:name(0x01010003)="' + entry + '" (Raw: "' + entry + '")\n',
            text + '      A: android:targetPackage(0x01010021)="' + target + '" (Raw: "' + target + '")\n',
            text.replace('    E: application', '    A: package="' + package + '" (Raw: "' + package + '")\n    E: application'),
            text + '    E: instrumentation (line=5)\n',
            text.replace('android:name(0x01010003)', 'android:name(0x01010001)'),
            text.replace('android:targetPackage(0x01010021)', 'android:targetPackage'),
            text.replace('(Raw: "' + target + '")', '(Raw: "wrong")'),
            text.replace('    E: instrumentation', '      E: instrumentation'),
            text.replace('android:targetPackage(0x01010021)="' + target + '"',
                         'android:targetPackage(0x01010021)=(type 0x10)0x0'),
        ]
        for index, invalid in enumerate(cases):
            with self.subTest(index=index):
                with self.assertRaises(ValueError):
                    capture.check_selected_manifest(invalid)

    def test_selector_refuses_arbitrary_corpus_before_device(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / 'receipt'
            command = [sys.executable, str(Path(capture.__file__)), '--serial', 'not-used',
                       '--apk', str(Path(tmp) / 'missing.apk'), '--frozen-source', tmp,
                       '--output', str(output), '--corpus', str(Path(tmp) / 'other.json'),
                       '--preflight-only']
            result = subprocess.run(command, capture_output=True, timeout=20)
            self.assertEqual(result.returncode, 1)
            receipt = json.loads((output / 'manifest.json').read_text(encoding='utf-8'))
            self.assertEqual(receipt['error'], 'unsupported corpus path')
            self.assertEqual(receipt['commands'], [])

    def test_packaged_selected_asset_binding_refuses_changed_assets(self):
        corpus = b'{"synthetic":true}\n'
        provenance = b'{"fixture":"synthetic"}\n'
        with tempfile.TemporaryDirectory() as tmp:
            apk = Path(tmp) / 'synthetic.apk'
            with zipfile.ZipFile(apk, 'w') as z:
                z.writestr('assets/fixtures-selected.json', corpus)
                z.writestr('assets/provenance.json', provenance)
            capture.check_selected_assets(apk, corpus, provenance)
            with self.assertRaises(ValueError):
                capture.check_selected_assets(apk, corpus + b'changed', provenance)
            with self.assertRaises(ValueError):
                capture.check_selected_assets(apk, corpus, provenance + b'changed')

    def test_device_fingerprint_selection_preserves_legacy_identity(self):
        old = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
        new = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.5.0.XPMCNXM:user/release-keys'
        for selected, allowed, refused in [(False, old, new), (True, new, old)]:
            with self.subTest(selected=selected):
                capture.check_device_fingerprint(selected, allowed)
                for fingerprint in (refused, 'wrong'):
                    with self.assertRaises(ValueError):
                        capture.check_device_fingerprint(selected, fingerprint)

    def test_failure_preservation_requires_exact_registered_owner(self):
        # Synthetic snapshots and owner exercise classification only, not a capture.
        unframed = f"{'a' * 64}  files/original\n".encode()
        before = unframed + capture.SELECTED_INVENTORY_COMPLETE + b'\n'
        after = unframed + f"{'b' * 64}  shared_prefs/liber_replace_selected_owned.xml\n".encode() + capture.SELECTED_INVENTORY_COMPLETE + b'\n'
        owner = {'fixtureId': 'REPLACE-17', 'corpusVersion': 2,
                 'corpusSha256Lf': 'c' * 64, 'targetPackage': 'com.legado.app.debug',
                 'targetApkSha256': self.fixture['target']['apkSha256'],
                 'harnessPackage': 'io.liber.oracle.replace.selected', 'harnessApkSha256': 'a' * 64,
                 'createdAt': 123, 'preferences': ['liber_replace_selected_owned']}
        result = capture.classify_selected_preservation(before, after, owner, self.report['identity'])
        self.assertTrue(result['originalsUnchanged'])
        self.assertEqual(result['registeredAdditions'], ['shared_prefs/liber_replace_selected_owned.xml'])
        self.assertFalse(result['equal'])
        # Empty or partial unframed inventories must not prove preservation.
        for incomplete in (b'', unframed):
            with self.subTest(incomplete=incomplete), self.assertRaisesRegex(ValueError, 'private inventory.*completion'):
                capture.classify_selected_preservation(incomplete, incomplete, owner, self.report['identity'])
        for bad_before, bad_after, bad_owner in [
            (before, after.replace(b'files/original', b'files/renamed'), owner),
            (before, after.replace(b'a' * 64, b'c' * 64), owner),
            (before, unframed + f"{'b' * 64}  shared_prefs/liber_replace_selected_owned.xml\n{'d' * 64}  shared_prefs/liber_replace_selected_unowned.xml\n".encode() + capture.SELECTED_INVENTORY_COMPLETE + b'\n', owner),
            (before, after, dict(owner, harnessApkSha256='wrong')),
        ]:
            with self.assertRaises(ValueError):
                capture.classify_selected_preservation(bad_before, bad_after, bad_owner, self.report['identity'])

    def test_selected_report_refuses_damaged_admission(self):
        capture.check_selected_report(self.fixture, self.report, self.binding)
        corruptions = [
            lambda r: r['identity'].__setitem__('corpusAssetSha256', 'wrong'),
            lambda r: r['identity'].__setitem__('targetApkSha256', 'wrong'),
            lambda r: r['provenance']['sourceHashes'].__setitem__('reader', 'wrong'),
            lambda r: r['hostInitialization'].__setitem__('verified', False),
            lambda r: r['startupContainment'].__setitem__('handled', 0),
            lambda r: r.__setitem__('fingerprint', 'other'),
            lambda r: r.__setitem__('fingerprint', 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'),
            lambda r: r.__setitem__('paragraphIndent', ' '),
            lambda r: r['terminalOwner'].__setitem__('baselineChildren', 1),
            lambda r: r['cleanup'].__setitem__('activityLaunchAttempts', 1),
            lambda r: r['cleanup'].__setitem__('registeredPreferences', ['liber_replace_selected_other']),
            lambda r: r['cleanup'].__setitem__('terminalProved', False),
            lambda r: r['rows'][0]['terminal'].__setitem__('rootEmpty', False),
            lambda r: r['rows'][0].pop('textList'),
            lambda r: r['rows'][0].__setitem__('textList', ['different']),
            lambda r: r['rows'].reverse(),
            lambda r: r['rows'].pop(),
            lambda r: r['rows'].append(copy.deepcopy(r['rows'][0])),
            lambda r: r['partition'].__setitem__('role', 'timeout'),
            lambda r: r['partition']['caseIds'].remove('refusal'),
        ]
        for corrupt in corruptions:
            bad = copy.deepcopy(self.report)
            corrupt(bad)
            with self.subTest(corrupt=corrupt):
                with self.assertRaises(ValueError):
                    capture.check_selected_report(self.fixture, bad, self.binding)


if __name__ == '__main__':
    unittest.main()
