"""Selected reader capture admission mechanics; all reports here are synthetic."""
import copy
import json
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

import capture


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
                       'fixtureSha256': self.binding['corpusSha256Lf'], 'fingerprint': capture.FINGERPRINT,
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
                                   'preferencesRemoved': [{'name': 'liber_replace_selected_probe', 'ok': True}]},
                       'rows': []}
        for case in self.fixture['cases']:
            terminal = {'allCompleted': True, 'rootEmpty': True, 'launchAttempts': 0}
            self.report['rows'].append({'id': case['id'], 'status': 'observed', 'title': 'synthetic',
                'content': 'synthetic', 'selection': {'title': [], 'content': []}, 'textList': ['synthetic'],
                'sameTitleRemoved': False, 'effectiveRules': [], 'disabledRules': [], 'terminal': terminal,
                **({'timeoutObserved': False, 'restartObservation': 'notCompared: synthetic'} if case['id'] == 'timeout' else {}),
                'readerCalls': [dict(terminal, method='getDisplayTitle'), dict(terminal, method='getContent')]})

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

    def test_selected_report_refuses_damaged_admission(self):
        capture.check_selected_report(self.fixture, self.report, self.binding)
        corruptions = [
            lambda r: r['identity'].__setitem__('corpusAssetSha256', 'wrong'),
            lambda r: r['identity'].__setitem__('targetApkSha256', 'wrong'),
            lambda r: r['provenance']['sourceHashes'].__setitem__('reader', 'wrong'),
            lambda r: r['hostInitialization'].__setitem__('verified', False),
            lambda r: r['startupContainment'].__setitem__('handled', 0),
            lambda r: r.__setitem__('fingerprint', 'other'),
            lambda r: r.__setitem__('paragraphIndent', ' '),
            lambda r: r['terminalOwner'].__setitem__('baselineChildren', 1),
            lambda r: r['cleanup'].__setitem__('activityLaunchAttempts', 1),
            lambda r: r['rows'][0]['terminal'].__setitem__('rootEmpty', False),
            lambda r: r['rows'][0].pop('textList'),
            lambda r: r['rows'][0].__setitem__('textList', ['different']),
            lambda r: r['rows'].reverse(),
        ]
        for corrupt in corruptions:
            bad = copy.deepcopy(self.report)
            corrupt(bad)
            with self.subTest(corrupt=corrupt):
                with self.assertRaises(ValueError):
                    capture.check_selected_report(self.fixture, bad, self.binding)


if __name__ == '__main__':
    unittest.main()
