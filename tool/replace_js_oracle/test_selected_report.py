import copy
import json
from pathlib import Path
import unittest

import selected_capture


class SelectedReportTest(unittest.TestCase):
    def setUp(self):
        self.fixture = json.loads(Path(__file__).with_name('fixtures-selected.json').read_text(encoding='utf-8'))
        self.binding = {'corpusAssetSha256': 'fixture', 'corpusSha256Lf': 'fixture',
                        'harnessApkSha256': 'harness', 'harnessIdsigSha256': 'idsig', 'provenanceAssetSha256': 'provenance',
                        'targetApkSha256': self.fixture['target']['apkSha256']}
        self.identity = {'fixtureId': 'REPLACE-JS-01', 'corpusVersion': 1,
                         **{key: value for key, value in self.binding.items() if key != 'harnessIdsigSha256'},
                         'targetPackage': 'com.legado.app.debug',
                         'harnessPackage': 'io.liber.oracle.replacejs.selected',
                         'role': 'main12', 'runId': 'f6645947-6b5e-4fac-b704-c63a43d77002',
                         'pid': 42, 'processStartTicks': '123456'}
        terminal = {'owner': 'Coroutine.DEFAULT Job', 'allCompleted': True,
                    'rootEmpty': True, 'launchAttempts': 0, 'observedChildren': 1}
        self.row = {'status': 'observed', 'elapsedMillis': 1, 'title': 'title', 'content': 'text',
                    'textList': ['text'], 'sameTitleRemoved': False, 'effectiveRules': [],
                    'useReplaceRule': True, 'reSegment': False, 'converterType': 0,
                    'selection': {'title': [], 'content': []}, 'rulesDisabledByRun': [],
                    'terminal': terminal, 'readerCalls': [dict(terminal, method='getDisplayTitle'),
                                                          dict(terminal, method='getContent')]}
        self.rows = [dict(copy.deepcopy(self.row), id=c['id']) for c in self.fixture['cases'][:-1]]
        self.report = {'fixtureId': 'REPLACE-JS-01', 'corpusVersion': 1,
                       'baselineCommit': self.fixture['baselineCommit'], 'fixtureSha256': 'fixture',
                       'boundary': self.fixture['comparisonBoundary'], 'role': 'main12', 'pid': 42,
                       'fingerprint': selected_capture.FINGERPRINT, 'identity': self.identity,
                       'provenance': {'baselineCommit': self.fixture['baselineCommit'],
                                      'corpusAssetSha256': 'fixture'},
                       'startupContainment': {'service': 'shortcut', 'provider': 'io.legado.app.api.ReaderProvider',
                                              'intercepted': 1, 'handled': 1, 'beforeBinding': True},
                       'isolation': {'verified': True, 'application': 'io.liber.oracle.nested.GuardedReaderApplication',
                                     'scratchRoot': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected',
                                     'externalCache': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/external-cache',
                                     'files': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/files',
                                     'database': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/databases/legado.db',
                                     'preferencesPrefix': 'liber_replace_js_selected_',
                                     'preferenceProbe': {'name': 'liber_replace_js_selected_liber_replace_js_probe',
                                                         'mode': 'written-once-and-retained-in-the-owned-set', 'registered': True, 'committed': True,
                                                         'scopedFile': True, 'installationFile': False}},
                       'webViewContainment': {
                           'scratchCanonicalRoot': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected',
                           'suffix': 'liber-replace-js-selected', 'suffixStatus': 'set-in-Instrumentation.newApplication',
                           'applicationClass': 'io.liber.oracle.nested.GuardedReaderApplication',
                           'resolvedApplicationContextIsApplication': True, 'deviceProtected': False,
                           'androidxProcessGlobalConfig': {'classPresent': False, 'configSet': False, 'dataDirectoryBasePath': None, 'cacheDirectoryBasePath': None, 'dataDirectorySuffixKey': False},
                           'provider': {'package': 'com.google.android.webview', 'versionName': '158.0.8127.2', 'versionCode': 812700213},
                           'candidate': {'package': 'com.google.android.webview', 'versionName': '158.0.8127.2', 'versionCode': 812700213},
                           'computed': {'data': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/dir-webview_liber-replace-js-selected',
                                        'cache': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/cache/webview_liber-replace-js-selected',
                                        'textures': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/dir-textures'},
                           'actual': {'data': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/dir-webview_liber-replace-js-selected',
                                      'cache': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/cache/webview_liber-replace-js-selected',
                                      'textures': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/dir-textures',
                                      'loadedFrom': 'provider-classloader-0'},
                           'realProfileBefore': {'app_webview': {'path': '/data/data/com.legado.app.debug/app_webview', 'exists': False, 'directory': False, 'length': 0, 'lastModified': 0},
                                                 'app_webview_suffixed': {'path': '/data/data/com.legado.app.debug/app_webview_liber-replace-js-selected', 'exists': False, 'directory': False, 'length': 0, 'lastModified': 0}},
                           'realProfileAfter': {'app_webview': {'path': '/data/data/com.legado.app.debug/app_webview', 'exists': False, 'directory': False, 'length': 0, 'lastModified': 0},
                                                'app_webview_suffixed': {'path': '/data/data/com.legado.app.debug/app_webview_liber-replace-js-selected', 'exists': False, 'directory': False, 'length': 0, 'lastModified': 0}},
                           'pathSource': 'org.chromium.base.PathUtils via provider classloader'},
                       'settingsBefore': {'backupPath': None, 'paragraphIndent': '', 'adaptSpecialStyle': False,
                                          'replaceEnableDefault': True, 'chineseConverterType': 0},
                       'entryPoints': {'getDisplayTitle': 'public java.lang.String io.legado.app.data.entities.BookChapter.getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)',
                           'getContent': 'public io.legado.app.help.book.BookContent io.legado.app.help.book.ContentProcessor.getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)',
                           'toReplaceBook': 'public io.legado.app.data.entities.ReplaceBook io.legado.app.data.entities.Book.toReplaceBook()',
                           'bookConstructor': 'public io.legado.app.data.entities.Book()', 'chapterConstructor': 'public io.legado.app.data.entities.BookChapter()',
                           'ruleConstructor': 'public io.legado.app.data.entities.ReplaceRule()',
                           'textList': 'public final java.util.List io.legado.app.help.book.BookContent.getTextList()',
                           'sameTitleRemoved': 'public final boolean io.legado.app.help.book.BookContent.getSameTitleRemoved()',
                           'effectiveRules': 'public final java.util.List io.legado.app.help.book.BookContent.getEffectiveReplaceRules()'},
                       'roleOwner': '/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected/role-owner.json',
                       'roleOwnerIdentity': self.identity,
                       'hostInitialization': {'verified': True, 'applicationAttached': False,
                           'method': self.fixture['hostInitialization']['method'],
                           'registeredWrappers': {r['type']: r['factory'] for r in self.fixture['hostInitialization']['registrations']}},
                       'terminalOwner': {'scope': 'Coroutine.DEFAULT', 'rootActive': True, 'rootCompleted': False,
                                         'baselineChildren': 0, 'childrenMethod': 'kotlinx.coroutines.Job.getChildren()',
                                         'completionMethod': 'kotlinx.coroutines.Job.isCompleted()'},
                       'cleanup': {'databaseClosed': True, 'terminalProved': True, 'activityLaunchAttempts': 0,
                                   'scratchRemoved': False, 'scratchRetained': True,
                                   'hostCleanup': 'required-after-owned-process-termination',
                                   'registeredPreferences': ['liber_replace_js_selected_liber_replace_js_probe',
                                                             'liber_replace_js_selected_com.legado.app.debug_preferences',
                                                             'liber_replace_js_selected_com.google.firebase:abc+def']},
                       'partition': {'role': 'main12', 'caseIds': [r['id'] for r in self.rows]}, 'rows': self.rows}

    def test_raw_receipt_rejects_contradictions_before_next_command(self):
        for name in ('instrumentation', 'owned-pid', 'owner-after'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                selected_capture.validate_command_receipt(name, b'', b'error: simulated', 0, False)
        for name in ('scratch-after', 'owned-cleanup'):
            with self.subTest(name=name), self.assertRaises(ValueError):
                selected_capture.validate_command_receipt(name, b'Error: refused\n', b'', 0, False)
        with self.assertRaises(ValueError):
            selected_capture.validate_command_receipt('target-after', b'', b'pidof error', 1, False)
        with self.assertRaises(ValueError):
            selected_capture.validate_command_receipt('pull-harness', b'adb: error: injected\n', b'', 0, False)
        selected_capture.validate_command_receipt('pull-harness', b'', b'/device/base.apk: 1 file pulled, 0 skipped. 18 MB/s\n', 0, False)
        with self.assertRaises(ValueError):
            selected_capture.validate_command_receipt('pull-harness', b'', b'[ 20%] error: denied\n', 0, False)

    def test_real_safe_preference_names_and_rejections(self):
        names = ['liber_replace_js_selected_com.legado.app.debug_preferences',
                 'liber_replace_js_selected_com.google.firebase:abc+def']
        script = selected_capture.cleanup_script(names)
        for name in names:
            self.assertIn(name + '.xml', script)
        for name in ['liber_replace_js_selected_../escape', 'liber_replace_js_selected_a/b',
                     'liber_replace_js_selected_a\\b', 'liber_replace_js_selected_..']:
            with self.subTest(name=name), self.assertRaises(ValueError):
                selected_capture.cleanup_script([name])

    def test_raw_malformed_duplicate_and_duplicate_json(self):
        import base64
        payload = base64.b64encode(json.dumps(self.report).encode())
        raw = b'INSTRUMENTATION_RESULT: stream=REPLACE_JS_ORACLE_BASE64=' + payload + b'\nINSTRUMENTATION_CODE: -1\n'
        for bad in (raw + b'REPLACE_JS_ORACLE_BASE64=%%\n', raw + b'INSTRUMENTATION_CODE: nope\n',
                    b'INSTRUMENTATION_RESULT: stream=REPLACE_JS_ORACLE_BASE64=' + base64.b64encode(b'{"timedOut":true,"timedOut":false}') + b'\nINSTRUMENTATION_CODE: -1\n'):
            with self.subTest(bad=bad[-60:]), self.assertRaises(ValueError):
                selected_capture.decode_instrumentation(bad)

    def test_host_provider_contradiction_rejected(self):
        good = (b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n'
                b'WebView package dirty: false\nAny WebView package installed: true\n')
        for bad in (good + b'WebView package dirty: true\n', good + b'Any WebView package installed: false\n'):
            with self.assertRaises(ValueError): selected_capture.check_provider_preflight(bad)

    def test_main12_complete(self):
        selected_capture.check_selected_report(self.fixture, self.report, self.binding, 'main12')

    def test_timeout_role_is_exactly_one_separate_lifetime(self):
        report = copy.deepcopy(self.report)
        report['role'] = 'timeout'
        report['identity']['role'] = 'timeout'
        report['roleOwnerIdentity']['role'] = 'timeout'
        report['partition'] = {'role': 'timeout', 'caseIds': ['js-timeout']}
        report['rows'] = [dict(copy.deepcopy(self.row), id='js-timeout', restartObservation='not-observed')]
        selected_capture.check_selected_report(self.fixture, report, self.binding, 'timeout')
        report['partition']['caseIds'].append('js-error')
        with self.assertRaises(ValueError):
            selected_capture.check_selected_report(self.fixture, report, self.binding, 'timeout')

    def test_incomplete_wrong_role_guard_or_failure_is_rejected(self):
        for mutation in ('missing', 'role', 'launch', 'failure', 'timedout', 'cleanup', 'cache', 'webview', 'provider', 'androidx', 'probe', 'entry', 'shortcut', 'row-error'):
            report = copy.deepcopy(self.report)
            if mutation == 'missing': report['rows'].pop()
            if mutation == 'role': report['partition']['role'] = 'timeout'
            if mutation == 'launch': report['rows'][0]['terminal']['launchAttempts'] = 1
            if mutation == 'failure': report['failure'] = 'native failure'
            if mutation == 'timedout': report['timedOut'] = True
            if mutation == 'cleanup': report['cleanup']['scratchRemoved'] = True
            if mutation == 'cache': report['isolation']['externalCache'] = '/unowned/cache'
            if mutation == 'webview': report['webViewContainment']['actual']['data'] = '/unowned'
            if mutation == 'provider': report['webViewContainment']['provider']['versionName'] = 'wrong'
            if mutation == 'androidx': report['webViewContainment']['androidxProcessGlobalConfig']['dataDirectorySuffixKey'] = True
            if mutation == 'probe': report['isolation']['preferenceProbe'].pop('name')
            if mutation == 'entry': report['entryPoints'].pop('bookConstructor')
            if mutation == 'shortcut': report['startupContainment'].pop('provider')
            if mutation == 'row-error': report['rows'][0].update(error='contradiction', timedOut=True)
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                selected_capture.check_selected_report(self.fixture, report, self.binding, 'main12')

    def test_malformed_typed_row_does_not_become_success(self):
        self.report['rows'][0]['textList'] = ['other']
        with self.assertRaises(ValueError):
            selected_capture.check_selected_report(self.fixture, self.report, self.binding, 'main12')

    def test_owned_cleanup_requires_durable_owner_and_unchanged_originals(self):
        import hashlib
        identity = self.identity
        owner = {k: identity[k] for k in ('fixtureId', 'corpusVersion', 'corpusSha256Lf', 'targetPackage',
                                         'targetApkSha256', 'harnessPackage', 'harnessApkSha256')}
        owner.update({'createdAt': 1, 'preferences': self.report['cleanup']['registeredPreferences']})
        a, b = json.dumps(owner).encode(), json.dumps(identity).encode()
        marker = b'__LIBER_REPLACE_JS_INVENTORY_COMPLETE__\n'
        before = b'a' * 64 + b'  files/original\n' + marker
        retained = (b'a' * 64 + b'  files/original\n' + hashlib.sha256(a).hexdigest().encode() +
                    b'  cache/liber-replace-js-selected/owner.json\n' + hashlib.sha256(b).hexdigest().encode() +
                    b'  cache/liber-replace-js-selected/role-owner.json\n' + b'b' * 64 +
                    b'  shared_prefs/liber_replace_js_selected_liber_replace_js_probe.xml\n' + marker)
        names = selected_capture.validate_owned_state(self.report, a, b, before, retained)
        self.assertIn('liber_replace_js_selected_liber_replace_js_probe.xml', selected_capture.cleanup_script(names))
        for wrong in (retained.replace(b'a' * 64, b'b' * 64, 1), retained.replace(b'role-owner.json', b'other.json'),
                      retained.replace(b'liber_replace_js_selected_liber_replace_js_probe.xml', b'other.xml')):
            with self.assertRaises(ValueError):
                selected_capture.validate_owned_state(self.report, a, b, before, wrong)
        with self.assertRaises(ValueError): selected_capture.cleanup_script(['liber_replace_js_selected_../escape'])
        duplicate_owner = b'{"fixtureId":"REPLACE-JS-01",' + a[1:]
        with self.assertRaises(ValueError):
            selected_capture.validate_owned_state(self.report, duplicate_owner, b, before, retained)

    def test_owned_process_liveness_requires_exact_pid_start_and_package(self):
        self.assertEqual(selected_capture.classify_process(b'', 1, self.identity), 'absent')
        self.assertEqual(selected_capture.classify_process(b'42\n', 0, self.identity), 'live')
        for output, code in ((b'43\n', 0), (b'42 43\n', 0), (b'', 0), (b'42\n', 1)):
            with self.subTest(output=output, code=code), self.assertRaises(ValueError):
                selected_capture.classify_process(output, code, self.identity)
        stat = b'42 (com.legado.app.debug) S ' + b'0 ' * 18 + b'123456 0\n'
        selected_capture.check_live_process(stat, b'com.legado.app.debug\x00', self.identity)
        for badstat, cmdline in ((stat.replace(b'123456', b'7'), b'com.legado.app.debug\x00'),
                                 (stat, b'other.package\x00')):
            with self.assertRaises(ValueError):
                selected_capture.check_live_process(badstat, cmdline, self.identity)

    def test_candidate_query_precedes_provider_initialization(self):
        source = Path(__file__).with_name('SelectedWebViewContainment.java').read_text(encoding='utf-8')
        self.assertLess(source.index('PackageInfo candidate = WebView.getCurrentWebViewPackage()'),
                        source.index('CookieManager manager = CookieManager.getInstance()'))
        self.assertLess(source.index('CookieManager manager = CookieManager.getInstance()'),
                        source.index('PackageInfo provider = WebView.getCurrentWebViewPackage()'))

    def test_webview_provider_preflight_is_current_and_unambiguous(self):
        line = (b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\n'
                b'WebView package dirty: false\nAny WebView package installed: true\n')
        selected_capture.check_provider_preflight(line)
        for bad in (b'', line + line, line.replace(b'158.0.8127.2', b'1.0')):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                selected_capture.check_provider_preflight(bad)

    def test_manifest_identity_must_be_root_instrumentation_not_decoy(self):
        xml = ('E: manifest (line=1)\n'
               '  A: package="io.liber.oracle.replacejs.selected" (Raw: "io.liber.oracle.replacejs.selected")\n'
               '  E: instrumentation (line=4)\n'
               '    A: android:name(0x01010003)="io.liber.oracle.nested.SelectedReplaceJsOracle"\n'
               '    A: android:targetPackage(0x01010021)="com.legado.app.debug"\n')
        selected_capture.check_manifest(xml)
        for bad in (xml.replace('E: instrumentation', 'E: decoy'),
                    xml.replace('com.legado.app.debug', 'io.legado.app.debug'), xml + xml):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                selected_capture.check_manifest(bad)

    def test_raw_instrumentation_requires_one_payload_and_success_terminal(self):
        import base64
        payload = base64.b64encode(json.dumps(self.report).encode())
        raw = b'INSTRUMENTATION_RESULT: stream=REPLACE_JS_ORACLE_BASE64=' + payload + b'\nINSTRUMENTATION_CODE: -1\n'
        self.assertEqual(selected_capture.decode_instrumentation(raw)['role'], 'main12')
        for bad in (raw + raw, raw.replace(b'CODE: -1', b'CODE: 1'), raw + b'INSTRUMENTATION_FAILED: crashed\n',
                    raw.replace(b'INSTRUMENTATION_RESULT: stream=', b'')):
            with self.assertRaises(ValueError):
                selected_capture.decode_instrumentation(bad)

    def test_physical_bundle_mechanics_refuses_missing_logs_and_commands(self):
        import base64
        import hashlib
        import os
        import shlex
        import tempfile
        from contextlib import nullcontext
        destination = os.environ.get('REPLACE_JS_TEST_BUNDLE_OUTPUT')
        if destination:
            Path(destination).mkdir(parents=True, exist_ok=False)
        context = nullcontext(destination) if destination else tempfile.TemporaryDirectory()
        with context as tmp:
            root = Path(tmp)
            actual = os.environ.get('REPLACE_JS_TEST_PREFLIGHT')
            if actual:
                preflight = json.loads(Path(actual).read_text(encoding='utf-8'))
                self.binding.update({key: preflight[key] for key in self.binding})
                self.binding['provenance'] = preflight['provenance']
                self.identity.update({key: self.binding[key] for key in self.identity.keys() & self.binding.keys()})
                self.report['fixtureSha256'] = self.binding['corpusSha256Lf']
                self.report['provenance'] = preflight['provenance']
                target_bytes = Path(os.environ['REPLACE_JS_TEST_REFERENCE']).read_bytes()
                harness_bytes = Path(os.environ['REPLACE_JS_TEST_HARNESS']).read_bytes()
                idsig_bytes = Path(os.environ['REPLACE_JS_TEST_HARNESS'] + '.idsig').read_bytes()
            else:
                target_bytes, harness_bytes, idsig_bytes = b'test-only-target', b'test-only-harness', b'test-only-idsig'
            (root / 'reference.apk').write_bytes(target_bytes)
            (root / 'harness.apk').write_bytes(harness_bytes)
            (root / 'harness.apk.idsig').write_bytes(idsig_bytes)
            (root / 'installed-harness.apk').write_bytes(harness_bytes)
            self.binding['harnessIdsigSha256'] = hashlib.sha256(idsig_bytes).hexdigest()
            self.binding['targetApkSha256'] = hashlib.sha256(target_bytes).hexdigest()
            self.binding['harnessApkSha256'] = hashlib.sha256(harness_bytes).hexdigest()
            self.identity.update({key: self.binding[key] for key in ('targetApkSha256', 'harnessApkSha256')})
            product_path = os.environ.get('REPLACE_JS_TEST_PRODUCT')
            if product_path:
                product = json.loads(Path(product_path).read_text(encoding='utf-8'))['product']
                for row, actual in zip(self.rows, product):
                    for field in ('title', 'content', 'selection', 'rulesDisabledByRun'):
                        row[field] = actual[field]
                    row['textList'] = row['content'].split('\n')
            raw = b'INSTRUMENTATION_RESULT: stream=REPLACE_JS_ORACLE_BASE64=' + base64.b64encode(json.dumps(self.report).encode()) + b'\nINSTRUMENTATION_CODE: -1\n'
            (root / 'observation.json').write_text(json.dumps(self.report), encoding='utf-8')
            package = selected_capture.PACKAGE
            target = selected_capture.TARGET
            marker = b'__LIBER_REPLACE_JS_INVENTORY_COMPLETE__\n'
            inv = b'a' * 64 + b'  cache/kept\n' + marker
            owner = {key: self.identity[key] for key in ('fixtureId', 'corpusVersion', 'corpusSha256Lf',
                     'targetPackage', 'targetApkSha256', 'harnessPackage', 'harnessApkSha256')}
            owner.update({'createdAt': 1, 'preferences': self.report['cleanup']['registeredPreferences']})
            owner_data, role_data = json.dumps(owner).encode(), json.dumps(self.identity).encode()
            retained = (inv[:-len(marker)] + hashlib.sha256(owner_data).hexdigest().encode() +
                        b'  cache/liber-replace-js-selected/owner.json\n' + hashlib.sha256(role_data).hexdigest().encode() +
                        b'  cache/liber-replace-js-selected/role-owner.json\n' + b'b' * 64 +
                        b'  shared_prefs/liber_replace_js_selected_liber_replace_js_probe.xml\n' + marker)
            values = [
                ('fingerprint', ['shell', 'getprop', 'ro.build.fingerprint'], (selected_capture.FINGERPRINT + '\n').encode()),
                ('webview-provider', ['shell', 'dumpsys', 'webviewupdate'],
                 b'Current WebView package (name, version): (com.google.android.webview, 158.0.8127.2)\nWebView package dirty: false\nAny WebView package installed: true\n'),
                ('target-before', ['shell', 'pidof', target], b''),
                ('reference-path', ['shell', 'pm', 'path', target], b'package:/device/reference.apk\n'),
                ('pull-reference', ['pull', '/device/reference.apk', str(root / 'reference.apk')], b''),
                ('harness-existing', ['shell', 'pm', 'list', 'packages', package], b''),
                ('private-before', ['shell', 'run-as', target, 'sh', '-c', shlex.quote(selected_capture.INVENTORY_SCRIPT)], inv),
                ('scratch-before', ['shell', 'run-as', target, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')], b''),
                ('install', ['install', '-r', str(root / 'harness.apk')], b'Success\n'),
                ('harness-path', ['shell', 'pm', 'path', package], b'package:/device/harness.apk\n'),
                ('pull-harness', ['pull', '/device/harness.apk', str(root / 'installed-harness.apk')], b''),
                ('target-preinstrument', ['shell', 'pidof', target], b''),
                ('instrumentation', ['shell', 'am', 'instrument', '-w', '-r', '-e', 'role', 'main12', package + '/io.liber.oracle.nested.SelectedReplaceJsOracle'], raw),
                ('owner-before', ['shell', 'run-as', target, 'cat', 'cache/liber-replace-js-selected/owner.json'], owner_data),
                ('role-owner-before', ['shell', 'run-as', target, 'cat', 'cache/liber-replace-js-selected/role-owner.json'], role_data),
                ('private-retained-before', ['shell', 'run-as', target, 'sh', '-c', shlex.quote(selected_capture.INVENTORY_SCRIPT)], retained),
                ('owned-pid', ['shell', 'pidof', target], b''),
                ('target-after', ['shell', 'pidof', target], b''),
                ('owner-after', ['shell', 'run-as', target, 'cat', 'cache/liber-replace-js-selected/owner.json'], owner_data),
                ('role-owner-after', ['shell', 'run-as', target, 'cat', 'cache/liber-replace-js-selected/role-owner.json'], role_data),
                ('private-retained', ['shell', 'run-as', target, 'sh', '-c', shlex.quote(selected_capture.INVENTORY_SCRIPT)], retained),
                ('owned-cleanup', ['shell', 'run-as', target, 'sh', '-c', shlex.quote(selected_capture.cleanup_script(owner['preferences']))], b''),
                ('target-final', ['shell', 'pidof', target], b''),
                ('private-after', ['shell', 'run-as', target, 'sh', '-c', shlex.quote(selected_capture.INVENTORY_SCRIPT)], inv),
                ('scratch-after', ['shell', 'run-as', target, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')], b''),
                ('remove-harness', ['uninstall', package], b'Success\n'),
                ('harness-removed', ['shell', 'pm', 'list', 'packages', package], b''),
            ]
            commands = []
            for name, argv, stdout in values:
                (root / (name + '.stdout')).write_bytes(stdout)
                (root / (name + '.stderr')).write_bytes(b'')
                commands.append({'name': name, 'argv': ['adb', '-s', '5615f742'] + argv,
                                 'exitCode': 1 if name in ('target-before', 'target-preinstrument', 'owned-pid', 'target-after', 'target-final') else 0, 'timeout': False,
                                 'stdoutSha256': hashlib.sha256(stdout).hexdigest(),
                                 'stderrSha256': hashlib.sha256(b'').hexdigest()})
            manifest = {'status': 'observed', 'role': 'main12', 'serial': '5615f742', 'commands': commands}
            (root / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')
            selected_capture.verify_bundle(root, self.fixture, self.binding, 'main12')
            # The actual capture function runs only against this intercepted transport.
            import subprocess
            import types
            from unittest.mock import patch
            for bad_name in ('instrumentation', 'owned-pid', 'owner-after'):
                with tempfile.TemporaryDirectory() as transport_tmp:
                    destination = Path(transport_tmp) / 'attempt'
                    seen = []
                    def fake_run(argv, **kwargs):
                        item = manifest['commands'][len(seen)]
                        name = item['name']
                        seen.append(name)
                        if name in ('pull-reference', 'pull-harness'):
                            import shutil
                            shutil.copyfile(root / Path(argv[-1]).name, argv[-1])
                        return subprocess.CompletedProcess(argv, item['exitCode'],
                            (root / (name + '.stdout')).read_bytes(),
                            b'error: injected\n' if name == bad_name else b'')
                    args = types.SimpleNamespace(output=destination, role='main12', serial='5615f742',
                        apk=root / 'harness.apk', backup='not-used', reference_apk='not-used',
                        frozen_source='not-used', android_sdk='not-used', java_home='not-used')
                    with patch.object(selected_capture, 'check_backup'), patch.object(selected_capture, 'preflight', return_value=self.binding), \
                         patch.object(selected_capture.subprocess, 'run', side_effect=fake_run):
                        self.assertEqual(selected_capture.capture(args), 1)
                    self.assertIn(bad_name, seen)
                    self.assertEqual((destination / 'harness.apk').read_bytes(), harness_bytes)
                    self.assertEqual((destination / 'harness.apk.idsig').read_bytes(), idsig_bytes)
                    failure = json.loads((destination / 'manifest.json').read_text(encoding='utf-8'))
                    self.assertEqual(failure['status'], 'failed')
                    self.assertIn('stderr is contradictory', failure['error'])
                    self.assertNotIn('owned-cleanup', seen)
                    self.assertNotIn('remove-harness', seen)
                    if bad_name in ('instrumentation', 'owned-pid'):
                        self.assertNotIn('stop-owned', seen)
            # A live process is stoppable only when its PID, start ticks and cmdline match.
            live = copy.deepcopy(manifest)
            owned = next(c for c in live['commands'] if c['name'] == 'owned-pid')
            owned['exitCode'] = 0
            owned['stdoutSha256'] = hashlib.sha256(b'42\n').hexdigest()
            (root / 'owned-pid.stdout').write_bytes(b'42\n')
            stat = b'42 (com.legado.app.debug) S ' + b'0 ' * 18 + b'123456 0\n'
            live_rows = [('process-stat', ['shell', 'cat', '/proc/42/stat'], stat),
                         ('process-cmdline', ['shell', 'cat', '/proc/42/cmdline'], b'com.legado.app.debug\x00'),
                         ('stop-owned', ['shell', 'am', 'force-stop', target], b'')]
            index = next(i for i, c in enumerate(live['commands']) if c['name'] == 'owned-pid') + 1
            for name, argv, stdout in live_rows:
                (root / (name + '.stdout')).write_bytes(stdout)
                (root / (name + '.stderr')).write_bytes(b'')
                live['commands'].insert(index, {'name': name, 'argv': ['adb', '-s', '5615f742'] + argv,
                    'exitCode': 0, 'timeout': False, 'stdoutSha256': hashlib.sha256(stdout).hexdigest(),
                    'stderrSha256': hashlib.sha256(b'').hexdigest()})
                index += 1
            (root / 'manifest.json').write_text(json.dumps(live), encoding='utf-8')
            selected_capture.verify_bundle(root, self.fixture, self.binding, 'main12')
            changed = stat.replace(b'123456', b'7')
            (root / 'process-stat.stdout').write_bytes(changed)
            next(c for c in live['commands'] if c['name'] == 'process-stat')['stdoutSha256'] = hashlib.sha256(changed).hexdigest()
            (root / 'manifest.json').write_text(json.dumps(live), encoding='utf-8')
            with self.assertRaises(ValueError): selected_capture.verify_bundle(root, self.fixture, self.binding, 'main12')
            (root / 'owned-pid.stdout').write_bytes(b'')
            for change in ('missing-command', 'preinstrument-live', 'failure-code', 'truncated-inventory', 'duplicate-payload', 'contradictory-install'):
                bad = copy.deepcopy(manifest)
                if change == 'missing-command': bad['commands'].pop(2)
                if change == 'preinstrument-live':
                    (root / 'target-preinstrument.stdout').write_bytes(b'42\n')
                    item = next(c for c in bad['commands'] if c['name'] == 'target-preinstrument')
                    item['exitCode'] = 0
                    item['stdoutSha256'] = hashlib.sha256(b'42\n').hexdigest()
                if change == 'failure-code': next(c for c in bad['commands'] if c['name'] == 'instrumentation')['exitCode'] = 1
                if change == 'truncated-inventory':
                    (root / 'private-after.stdout').write_bytes(inv[:-1])
                    next(c for c in bad['commands'] if c['name'] == 'private-after')['stdoutSha256'] = hashlib.sha256(inv[:-1]).hexdigest()
                if change == 'duplicate-payload':
                    (root / 'instrumentation.stdout').write_bytes(raw + raw)
                    next(c for c in bad['commands'] if c['name'] == 'instrumentation')['stdoutSha256'] = hashlib.sha256(raw + raw).hexdigest()
                if change == 'contradictory-install':
                    (root / 'install.stdout').write_bytes(b'Success\nFailure: install failed\n')
                    next(c for c in bad['commands'] if c['name'] == 'install')['stdoutSha256'] = hashlib.sha256(b'Success\nFailure: install failed\n').hexdigest()
                (root / 'manifest.json').write_text(json.dumps(bad), encoding='utf-8')
                with self.subTest(change=change), self.assertRaises(ValueError):
                    selected_capture.verify_bundle(root, self.fixture, self.binding, 'main12')
                (root / 'private-after.stdout').write_bytes(inv)
                (root / 'instrumentation.stdout').write_bytes(raw)
                (root / 'install.stdout').write_bytes(b'Success\n')
                (root / 'target-preinstrument.stdout').write_bytes(b'')
            (root / 'manifest.json').write_text(json.dumps(manifest), encoding='utf-8')

    def test_inventory_requires_completion_and_cache_scope(self):
        good = b'a' * 64 + b'  cache/kept\n__LIBER_REPLACE_JS_INVENTORY_COMPLETE__\n'
        self.assertEqual(len(selected_capture.parse_inventory(good)), 1)
        for bad in (good[:-1], good.replace(b'__LIBER_REPLACE_JS_INVENTORY_COMPLETE__', b''),
                    good.replace(b'cache/kept', b'other/kept'), good + good):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                selected_capture.parse_inventory(bad)


if __name__ == '__main__':
    unittest.main()
