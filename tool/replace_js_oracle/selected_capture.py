"""Selected REPLACE-JS physical evidence checks and fixed-role capture support.

No selected observation is supplied by this module: the raw instrumentation stream
and complete independent host receipts are required for admission.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import uuid
import zipfile

FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.6.0.XPMCNXM:user/release-keys'
TARGET = 'com.legado.app.debug'
PACKAGE = 'io.liber.oracle.replacejs.selected'
PREFIX = 'liber_replace_js_selected_'
WEBVIEW_PACKAGE = 'com.google.android.webview'
WEBVIEW_VERSION = '158.0.8127.2'
WEBVIEW_SUFFIX = 'liber-replace-js-selected'
INVENTORY_END = b'__LIBER_REPLACE_JS_INVENTORY_COMPLETE__'
INVENTORY_SCRIPT = ("set -e; find databases shared_prefs files cache -type f -exec sh -c "
                    "'for f do sha256sum \"$f\" || exit 20; done' sh {} +; "
                    "printf '%s\\n' '__LIBER_REPLACE_JS_INVENTORY_COMPLETE__'")


def parse_inventory(data):
    """A complete, error-propagating hash walk including the existing cache scope."""
    _require(isinstance(data, bytes) and data.endswith(b'\n'), 'truncated inventory')
    lines = [line.removesuffix(b'\r') for line in data[:-1].split(b'\n')]
    _require(lines[-1] == INVENTORY_END and INVENTORY_END not in lines[:-1], 'inventory completion absent')
    paths = set()
    for line in lines[:-1]:
        _require(re.fullmatch(rb'[0-9a-f]{64}  (?:databases|shared_prefs|files|cache)/[^\r\n]+', line) is not None,
                 'invalid inventory record')
        path = line[66:]
        _require(path not in paths and b'/../' not in path and not path.endswith(b'/..'), 'inventory path invalid or repeated')
        paths.add(path)
    return sorted(lines[:-1])


def validate_command_receipt(name, stdout, stderr, code, timedout, argv=None):
    """The same raw-command gate runs immediately live and on later admission."""
    expected = (0, 1) if name == 'owned-pid' else (1,) if name in (
        'target-before', 'target-preinstrument', 'target-after', 'target-final') else (0,)
    _require(type(code) is int and code in expected and timedout is False, name + ': exit or timeout differs')
    _require(isinstance(stdout, bytes) and isinstance(stderr, bytes), name + ': raw output absent')
    if name in ('pull-reference', 'pull-harness'):
        _require(isinstance(argv, list) and len(argv) == 3 and argv[0] == 'pull' and
                 all(isinstance(x, str) and x and not any(ord(c) < 32 or ord(c) == 127 for c in x) for x in argv[1:]) and
                 re.fullmatch(r'/[^\s:]+\.apk', argv[1]) is not None, name + ': pull arguments invalid')
        remote, destination = (x.encode('utf-8') for x in argv[1:])
        _require(all(not any(c < 32 and c not in (10, 13) or c == 127 for c in stream)
                     for stream in (stdout, stderr)), name + ': control byte in transfer output')
        lines = [line for stream in (stdout, stderr) for line in re.split(rb'[\r\n]+', stream) if line]
        _require(b'error' not in stderr.lower() and b'failed' not in stderr.lower(), name + ': stderr is contradictory')
        integer = rb'(?:0|[1-9][0-9]*)'
        summary = (re.escape(remote) + rb': 1 file pulled, 0 skipped\. ' + integer + rb'\.[0-9] MB/s \(' +
                   integer + rb' bytes in ' + integer + rb'\.[0-9]{3}s\)')
        summaries = 0
        for line in lines:
            if re.fullmatch(summary, line):
                summaries += 1
            else:
                progress = re.fullmatch(rb'\[( {0,2}[0-9]{1,3})%\] (.+)', line)
                _require(progress is not None and int(progress.group(1)) <= 100 and
                         progress.group(1) == ('%3d' % int(progress.group(1))).encode('ascii') and
                         progress.group(2) in (remote, destination), name + ': transfer output is contradictory')
        _require(summaries == 1, name + ': transfer summary differs')
    elif name == 'install':
        notification = b'All files should be loaded. Notifying the device.'
        _require(stderr in (b'', notification + b'\n', notification + b'\r\n'), name + ': stderr is contradictory')
        _require(notification not in stdout, name + ': notification on stdout')
    else:
        _require(not stderr, name + ': stderr is contradictory')
    _require(not any(line.strip().lower().startswith((b'error:', b'failure', b'failed',
                     b'adb: error:', b'adb: failed', b'permission denied'))
                     for line in stdout.splitlines()), name + ': stdout is contradictory')
    if name in ('target-before', 'target-preinstrument', 'target-after', 'target-final'):
        _require(not stdout.strip(), name + ': target process not absent')
    if name in ('scratch-before', 'scratch-after', 'owned-cleanup', 'stop-owned'):
        _require(not stdout.strip(), name + ': unexpected output')
    if name in ('install', 'remove-harness'):
        lines = stdout.decode('utf-8').splitlines()
        _require(lines.count('Success') == 1, name + ': success missing')
        if name == 'install':
            modes = [line.strip() for line in lines if line.strip().startswith('Performing ')]
            _require(modes == ['Performing Incremental Install'] and lines.index('Performing Incremental Install') < lines.index('Success'),
                     'install: incremental mode not confirmed')
    if name == 'instrumentation':
        decode_instrumentation(stdout)


def classify_process(output, exit_code, identity):
    """Only a proven absent process or the one reported owned PID is usable."""
    _require(type(identity.get('pid')) is int and identity['pid'] > 0, 'invalid owned PID')
    if exit_code == 1 and not output.strip():
        return 'absent'
    _require(exit_code == 0 and output.strip() == str(identity['pid']).encode('ascii'),
             'target process ownership ambiguous')
    return 'live'


def check_live_process(stat, cmdline, identity):
    match = re.fullmatch(rb'(\d+) \((.*)\) (.*)\s*', stat.strip())
    _require(match is not None and int(match.group(1)) == identity['pid'], 'process stat identity differs')
    fields = match.group(3).split()
    _require(len(fields) > 19 and fields[19].decode('ascii') == identity.get('processStartTicks'),
             'process start ticks differ')
    _require(cmdline.split(b'\x00', 1)[0] == TARGET.encode('ascii'), 'process package differs')


def decode_instrumentation(data):
    """Decode exactly one successful raw terminal; failure and ambiguity are fatal."""
    _require(isinstance(data, bytes), 'instrumentation is not bytes')
    _require(all(marker not in data for marker in (b'INSTRUMENTATION_FAILED', b'INSTRUMENTATION_ABORTED',
             b'INSTRUMENTATION_RESULT: shortMsg=', b'INSTRUMENTATION_RESULT: longMsg=', b'FAILURES!!!')),
             'instrumentation explicitly failed')
    lines = [line for line in data.splitlines() if line.strip()]
    _require(len(lines) == 2 and re.fullmatch(rb'INSTRUMENTATION_CODE:[ \t]*-1[ \t]*', lines[1]) is not None,
             'instrumentation frame must be one ordered result followed by success terminal')
    payload = re.fullmatch(rb'INSTRUMENTATION_RESULT: stream=REPLACE_JS_ORACLE_BASE64=([A-Za-z0-9+/=]+)', lines[0])
    _require(payload is not None, 'instrumentation result malformed')
    payloads = [payload.group(1)]
    try:
        report = strict_json(base64.b64decode(payloads[0], validate=True).decode('utf-8'))
    except (ValueError, UnicodeError) as error:
        raise ValueError('instrumentation payload invalid') from error
    _require(isinstance(report, dict), 'instrumentation payload is not an object')
    return report


def check_provider_preflight(data):
    text = data.decode('utf-8', errors='strict')
    headings = re.findall(r'^[ \t]*Current WebView package[^\r\n]*', text, re.M)
    matches = re.findall(r'^[ \t]*Current WebView package \(name, version\): \(([^,]+), ([^)]+)\)[ \t]*\r?$', text, re.M)
    pinned = [line.strip() for line in text.splitlines() if re.match(
        r'^[ \t]*(?:\S+ package )?' + re.escape(WEBVIEW_PACKAGE) + r'(?:[ \t(]|$)', line)]
    pinned_valid = (r'Valid package ' + re.escape(WEBVIEW_PACKAGE) + r' \(versionName: ' +
                    re.escape(WEBVIEW_VERSION) + r', versionCode: [0-9]+, targetSdkVersion: [0-9]+\) is +installed/enabled for all users')
    dirty = re.findall(r'^[ \t]*WebView package dirty:[ \t]*([^\r\n]*)\r?$', text, re.M)
    installed = re.findall(r'^[ \t]*Any WebView package installed:[ \t]*([^\r\n]*)\r?$', text, re.M)
    _require(len(headings) == 1 and matches == [(WEBVIEW_PACKAGE, WEBVIEW_VERSION)] and
             len(pinned) == 1 and re.fullmatch(pinned_valid, pinned[0]) is not None and
             len(re.findall(r'^[ \t]*WebView package dirty[^\r\n]*', text, re.M)) == 1 and
             len(re.findall(r'^[ \t]*Any WebView package installed[^\r\n]*', text, re.M)) == 1 and
             dirty == ['false'] and installed == ['true'],
             'current WebView provider differs, is dirty, or is ambiguous')


def _sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def typed_equal(left, right):
    if type(left) is not type(right):
        return False
    if isinstance(left, dict):
        return left.keys() == right.keys() and all(typed_equal(left[k], right[k]) for k in left)
    if isinstance(left, list):
        return len(left) == len(right) and all(typed_equal(a, b) for a, b in zip(left, right))
    return left == right


def _strings(value):
    return isinstance(value, list) and all(isinstance(x, str) for x in value)


def _strict_object(pairs):
    result = {}
    for key, value in pairs:
        _require(key not in result, 'duplicate JSON key: ' + key)
        result[key] = value
    return result


def strict_json(data):
    def reject_constant(value):
        raise ValueError('invalid JSON constant: ' + value)
    return json.loads(data, object_pairs_hook=_strict_object, parse_constant=reject_constant)


def validate_owned_state(report, owner_data, role_owner_data, before_data, retained_data):
    """Check both durable owners and every original file before permitting removal."""
    identity = report['identity']
    owner = strict_json(owner_data)
    role_owner = strict_json(role_owner_data)
    _require(isinstance(owner, dict) and isinstance(role_owner, dict) and typed_equal(role_owner, identity),
             'durable role owner differs')
    for key in ('fixtureId', 'corpusVersion', 'corpusSha256Lf', 'targetPackage',
                'targetApkSha256', 'harnessPackage', 'harnessApkSha256'):
        _require(typed_equal(owner.get(key), identity.get(key)), 'durable scratch owner differs: ' + key)
    registered = report['cleanup']['registeredPreferences']
    _require(_strings(registered) and registered and len(registered) == len(set(registered)) and
             all(safe_preference_name(name) for name in registered), 'unsafe owner preference names')
    _require(type(owner.get('createdAt')) is int and owner['createdAt'] > 0 and
             isinstance(owner.get('preferences'), list) and
             sorted(owner['preferences']) == sorted(registered), 'durable preference owner differs')
    before = {line[66:]: line[:64] for line in parse_inventory(before_data)}
    retained = {line[66:]: line[:64] for line in parse_inventory(retained_data)}
    scratch_prefix = b'cache/liber-replace-js-selected/'
    owned_prefs = {(f'shared_prefs/{name}{suffix}').encode('ascii')
                   for name in registered for suffix in ('.xml', '.xml.bak')}
    _require(not any(path.startswith(scratch_prefix) or path in owned_prefs for path in before),
             'owned state existed before run')
    _require(all(retained.get(path) == digest for path, digest in before.items()), 'original file changed')
    additions = set(retained) - set(before)
    _require(all(path.startswith(scratch_prefix) or path in owned_prefs for path in additions),
             'unowned file was added')
    _require(retained.get(scratch_prefix + b'owner.json') == hashlib.sha256(owner_data).hexdigest().encode('ascii') and
             retained.get(scratch_prefix + b'role-owner.json') == hashlib.sha256(role_owner_data).hexdigest().encode('ascii'),
             'owned manifests absent from or differ from retained inventory')
    probe = report['isolation']['preferenceProbe']['name']
    _require(probe in registered and ('shared_prefs/' + probe + '.xml').encode('ascii') in retained,
             'scoped preference probe missing from owner or retained inventory')
    return registered


def safe_preference_name(name):
    return (isinstance(name, str) and name.startswith(PREFIX) and len(name) > len(PREFIX) and
            re.fullmatch(r'[A-Za-z0-9_.:+-]+', name) is not None and '..' not in name)


def cleanup_script(registered):
    _require(_strings(registered) and registered and len(set(registered)) == len(registered) and
             all(safe_preference_name(x) for x in registered), 'unsafe cleanup preference names')
    files = ' '.join("'shared_prefs/" + name + suffix + "'" for name in sorted(registered) for suffix in ('.xml', '.xml.bak'))
    return ('set -e; set +e; p=$(pidof com.legado.app.debug 2>&1); code=$?; set -e; '
            '[ "$code" -eq 1 ] && [ -z "$p" ] || exit 30; '
            'test -d cache/liber-replace-js-selected; test ! -L cache; '
            'test ! -L cache/liber-replace-js-selected; test -d shared_prefs; test ! -L shared_prefs; '
            'rm -rf cache/liber-replace-js-selected; rm -f ' + files)


def _terminal(value):
    return (isinstance(value, dict) and value.get('owner') == 'Coroutine.DEFAULT Job' and
            value.get('allCompleted') is True and value.get('rootEmpty') is True and
            type(value.get('launchAttempts')) is int and value['launchAttempts'] == 0 and type(value.get('observedChildren')) is int and
            value['observedChildren'] >= 0)


def check_selected_report(fixture, report, binding, role):
    """Validate an already decoded report; this alone never admits native evidence."""
    _require(role in ('main12', 'timeout'), 'unknown fixed role')
    _require(isinstance(report, dict) and report.get('failure') is None and
             report.get('cleanupFailure') is None and report.get('error') is None and
             (report.get('timedOut') is None or report.get('timedOut') is False), 'selected instrumentation failed or timed out')
    for key in ('fixtureId', 'corpusVersion', 'baselineCommit'):
        _require(typed_equal(report.get(key), fixture.get(key)), 'selected report identity differs: ' + key)
    _require(report.get('fixtureSha256') == binding['corpusSha256Lf'] and
             report.get('boundary') == fixture['comparisonBoundary'] and
             report.get('role') == role and report.get('fingerprint') == FINGERPRINT and
             type(report.get('pid')) is int and report['pid'] > 0, 'selected runtime identity differs')
    identity = report.get('identity') or {}
    for key in ('corpusAssetSha256', 'corpusSha256Lf', 'harnessApkSha256',
                'provenanceAssetSha256', 'targetApkSha256'):
        _require(identity.get(key) == binding[key], 'selected measured identity differs: ' + key)
    _require(identity.get('fixtureId') == fixture['fixtureId'] and
             typed_equal(identity.get('corpusVersion'), fixture['corpusVersion']) and
             identity.get('targetPackage') == TARGET and identity.get('harnessPackage') == PACKAGE and
             identity.get('role') == role and type(identity.get('pid')) is int and typed_equal(identity.get('pid'), report.get('pid')) and
             isinstance(identity.get('processStartTicks'), str) and
             re.fullmatch(r'[0-9]+', identity['processStartTicks']) is not None,
             'selected identity role, process or packages differ')
    try:
        _require(str(uuid.UUID(identity.get('runId', ''))) == identity.get('runId'), 'invalid run id')
    except (ValueError, TypeError, AttributeError):
        raise ValueError('invalid run id') from None
    provenance = report.get('provenance') or {}
    _require(provenance.get('baselineCommit') == fixture['baselineCommit'] and
             provenance.get('corpusAssetSha256') == binding['corpusAssetSha256'] and
             ('provenance' not in binding or typed_equal(provenance, binding['provenance'])), 'provenance differs')
    host = report.get('hostInitialization') or {}
    wrappers = {r['type']: r['factory'] for r in fixture['hostInitialization']['registrations']}
    _require(host.get('verified') is True and host.get('applicationAttached') is False and
             host.get('method') == fixture['hostInitialization']['method'] and
             host.get('registeredWrappers') == wrappers, 'host initialization unverified')
    startup = report.get('startupContainment') or {}
    _require(startup.get('service') == 'shortcut' and startup.get('provider') == 'io.legado.app.api.ReaderProvider' and
             type(startup.get('intercepted')) is int and startup['intercepted'] == 1 and
             type(startup.get('handled')) is int and startup['handled'] == 1 and
             startup.get('beforeBinding') is True, 'startup containment unverified')
    isolation = report.get('isolation') or {}
    probe = isolation.get('preferenceProbe') or {}
    root = isolation.get('scratchRoot')
    _require(isolation.get('verified') is True and
             isolation.get('application') == 'io.liber.oracle.nested.GuardedReaderApplication' and
             root in ('/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected',
                      '/data/data/com.legado.app.debug/cache/liber-replace-js-selected') and
             isolation.get('externalCache') == root + '/external-cache' and
             isolation.get('files') == root + '/files' and isolation.get('database') == root + '/databases/legado.db' and
             isolation.get('preferencesPrefix') == PREFIX and
             report.get('roleOwner') == root + '/role-owner.json' and typed_equal(report.get('roleOwnerIdentity'), identity) and
             probe.get('name') == PREFIX + 'liber_replace_js_probe' and
             probe.get('mode') == 'written-once-and-retained-in-the-owned-set' and
             probe.get('registered') is True and probe.get('committed') is True and
             probe.get('scopedFile') is True and probe.get('installationFile') is False,
             'scratch routing unverified')
    webview = report.get('webViewContainment') or {}
    config = webview.get('androidxProcessGlobalConfig') or {}
    computed = webview.get('computed') or {}
    actual = webview.get('actual') or {}
    provider = webview.get('provider') or {}
    candidate = webview.get('candidate') or {}
    canonical_root = webview.get('scratchCanonicalRoot')
    _require(canonical_root in ('/data/user/0/com.legado.app.debug/cache/liber-replace-js-selected',
                                '/data/data/com.legado.app.debug/cache/liber-replace-js-selected'), 'WebView scratch root differs')
    _require(webview.get('suffix') == WEBVIEW_SUFFIX and
             webview.get('suffixStatus') == 'set-in-Instrumentation.newApplication' and
             webview.get('applicationClass') == 'io.liber.oracle.nested.GuardedReaderApplication' and
             webview.get('resolvedApplicationContextIsApplication') is True and webview.get('deviceProtected') is False and
             type(config.get('classPresent')) is bool and type(config.get('configSet')) is bool and
             (config['classPresent'] or not config['configSet']) and
             'dataDirectoryBasePath' in config and config['dataDirectoryBasePath'] is None and
             'cacheDirectoryBasePath' in config and config['cacheDirectoryBasePath'] is None and
             config.get('dataDirectorySuffixKey') is False and
             provider.get('package') == WEBVIEW_PACKAGE and provider.get('versionName') == WEBVIEW_VERSION and
             type(provider.get('versionCode')) is int and provider['versionCode'] > 0 and typed_equal(candidate, provider) and
             computed == {'data': canonical_root + '/dir-webview_' + WEBVIEW_SUFFIX,
                          'cache': canonical_root + '/cache/webview_' + WEBVIEW_SUFFIX, 'textures': canonical_root + '/dir-textures'} and
             all(actual.get(key) == computed[key] for key in ('data', 'cache', 'textures')) and
             isinstance(actual.get('loadedFrom'), str) and actual['loadedFrom'].startswith('provider-classloader-') and
             webview.get('pathSource') == 'org.chromium.base.PathUtils via provider classloader',
             'WebView containment unverified')
    before, after = webview.get('realProfileBefore'), webview.get('realProfileAfter')
    _require(isinstance(before, dict) and typed_equal(before, after) and
             set(before) == {'app_webview', 'app_webview_suffixed'} and
             all(isinstance(value, dict) and type(value.get('exists')) is bool and
                 type(value.get('directory')) is bool and type(value.get('length')) is int and value['length'] >= 0 and
                 type(value.get('lastModified')) is int and value['lastModified'] >= 0 for value in before.values()) and
             before['app_webview'].get('path') in ('/data/user/0/com.legado.app.debug/app_webview', '/data/data/com.legado.app.debug/app_webview') and
             before['app_webview_suffixed'].get('path') in ('/data/user/0/com.legado.app.debug/app_webview_' + WEBVIEW_SUFFIX,
                                                            '/data/data/com.legado.app.debug/app_webview_' + WEBVIEW_SUFFIX),
             'WebView installation metadata changed or malformed')
    settings = report.get('settingsBefore') or {}
    _require('backupPath' in settings and settings['backupPath'] is None and
             isinstance(settings.get('paragraphIndent'), str) and
             type(settings.get('adaptSpecialStyle')) is bool and
             type(settings.get('replaceEnableDefault')) is bool and
             type(settings.get('chineseConverterType')) is int, 'scratch settings unverified')
    entry = report.get('entryPoints') or {}
    signatures = {
        'getDisplayTitle': 'java.lang.String io.legado.app.data.entities.BookChapter.getDisplayTitle(java.util.List,boolean,boolean,io.legado.app.data.entities.ReplaceBook)',
        'getContent': 'io.legado.app.help.book.BookContent io.legado.app.help.book.ContentProcessor.getContent(io.legado.app.data.entities.Book,io.legado.app.data.entities.BookChapter,java.lang.String,boolean,boolean,boolean,boolean,java.lang.Boolean,java.util.List,java.util.List)',
        'toReplaceBook': 'io.legado.app.data.entities.ReplaceBook io.legado.app.data.entities.Book.toReplaceBook()',
        'textList': 'java.util.List io.legado.app.help.book.BookContent.getTextList()',
        'sameTitleRemoved': 'boolean io.legado.app.help.book.BookContent.getSameTitleRemoved()',
        'effectiveRules': 'java.util.List io.legado.app.help.book.BookContent.getEffectiveReplaceRules()',
    }
    _require(isinstance(entry, dict) and all(type(entry.get(k)) is str and entry[k] == 'public final ' + signature
             for k, signature in signatures.items()) and
             all(entry.get(key) == 'public io.legado.app.data.entities.' + cls + '()' for key, cls in
                 (('bookConstructor', 'Book'), ('chapterConstructor', 'BookChapter'), ('ruleConstructor', 'ReplaceRule'))),
             'selected entry ABI differs')
    owner = report.get('terminalOwner') or {}
    _require(owner.get('scope') == 'Coroutine.DEFAULT' and owner.get('rootActive') is True and
             owner.get('rootCompleted') is False and type(owner.get('baselineChildren')) is int and owner['baselineChildren'] == 0 and
             owner.get('childrenMethod') == 'public abstract kotlin.sequences.Sequence kotlinx.coroutines.Job.getChildren()' and
             owner.get('completionMethod') == 'public abstract boolean kotlinx.coroutines.Job.isCompleted()',
             'coroutine owner not verified')
    cleanup = report.get('cleanup') or {}
    registered = cleanup.get('registeredPreferences')
    _require(cleanup.get('databaseClosed') is True and cleanup.get('terminalProved') is True and
             type(cleanup.get('activityLaunchAttempts')) is int and cleanup['activityLaunchAttempts'] == 0 and
             cleanup.get('scratchRemoved') is False and cleanup.get('scratchRetained') is True and
             cleanup.get('hostCleanup') == 'required-after-owned-process-termination' and
             'preferencesRemoved' not in cleanup and
             _strings(registered) and bool(registered) and len(registered) == len(set(registered)) and
             all(safe_preference_name(x) for x in registered),
             'native closure or retained ownership not verified')
    ids = [c['id'] for c in fixture['cases']]
    _require(len(ids) == 13 and len(set(ids)) == 13 and ids[-1] == 'js-timeout', 'full corpus differs')
    expected = ids[:-1] if role == 'main12' else ids[-1:]
    rows = report.get('rows')
    _require(typed_equal(report.get('partition'), {'role': role, 'caseIds': expected}) and
             isinstance(rows, list) and all(isinstance(r, dict) for r in rows) and
             [r.get('id') for r in rows] == expected, 'fixed role row order differs')
    for row in rows:
        selection, calls = row.get('selection'), row.get('readerCalls')
        _require(row.get('status') == 'observed' and row.get('error') is None and
                 (row.get('timedOut') is None or row.get('timedOut') is False) and
                 type(row.get('elapsedMillis')) is int and row['elapsedMillis'] >= 0 and isinstance(row.get('title'), str) and
                 isinstance(row.get('content'), str) and _strings(row.get('textList')) and
                 '\n'.join(row['textList']) == row['content'] and
                 type(row.get('sameTitleRemoved')) is bool and type(row.get('useReplaceRule')) is bool and
                 type(row.get('reSegment')) is bool and type(row.get('converterType')) is int and 'effectiveRules' in row and
                 (row['effectiveRules'] is None or _strings(row['effectiveRules'])) and
                 isinstance(selection, dict) and _strings(selection.get('title')) and
                 _strings(selection.get('content')) and _strings(row.get('rulesDisabledByRun')) and
                 _terminal(row.get('terminal')) and isinstance(calls, list) and len(calls) == 2 and
                 all(_terminal(c) for c in calls) and
                 [c.get('method') for c in calls] == ['getDisplayTitle', 'getContent'],
                 'selected row incomplete: ' + str(row.get('id')))
        if row['id'] == 'js-timeout':
            _require(row.get('restartObservation') == 'not-observed' and 'timeoutObserved' not in row,
                     'timeout/restart observation is missing or fabricated')
    return rows


def check_manifest(text):
    stack, roots, entries = [], [], []
    for line in text.splitlines():
        element = re.fullmatch(r'( *)E: ([\w.-]+) \(line=\d+\)', line)
        if element:
            indent, name = len(element.group(1)), element.group(2)
            while stack and stack[-1]['indent'] >= indent:
                stack.pop()
            node = {'indent': indent, 'name': name, 'parent': stack[-1] if stack else None, 'attributes': {}}
            if node['parent'] is None:
                roots.append(node)
            if name == 'instrumentation':
                entries.append(node)
            stack.append(node)
            continue
        _require(not re.match(r'^ *E:', line), 'malformed manifest element')
        attr = re.match(r'^( *)A: ([^\s=(]+)', line)
        if not attr:
            continue
        _require(stack and len(attr.group(1)) > stack[-1]['indent'], 'malformed manifest attribute')
        node, key = stack[-1], attr.group(2)
        relevant = ((node['parent'] is None and node['name'] == 'manifest' and key == 'package') or
                    (node['name'] == 'instrumentation' and key in ('android:name', 'android:targetPackage')))
        if not relevant:
            continue
        match = re.fullmatch(r' *A: [^\s=(]+(?:\((0x[0-9a-fA-F]+)\))?="([^"]*)"(?: \(Raw: "([^"]*)"\))?', line)
        expected = {'package': None, 'android:name': '0x01010003', 'android:targetPackage': '0x01010021'}[key]
        _require(match is not None and match.group(1) == expected and
                 (match.group(3) is None or match.group(2) == match.group(3)), 'manifest identity attribute malformed')
        node['attributes'].setdefault(key, []).append(match.group(2))
    _require(len(roots) == 1 and roots[0]['name'] == 'manifest' and len(entries) == 1, 'manifest root or entry ambiguous')
    _require(entries[0]['parent'] is roots[0] and roots[0]['attributes'].get('package') == [PACKAGE] and
             entries[0]['attributes'].get('android:name') == ['io.liber.oracle.nested.SelectedReplaceJsOracle'] and
             entries[0]['attributes'].get('android:targetPackage') == [TARGET], 'manifest identity differs')


def preflight(apk, reference_apk, source, sdk, java_home, output):
    """Inspect current physical source, signed artifacts, assets and SDK commands."""
    root = Path(__file__).resolve().parents[2]
    tool = Path(__file__).parent
    fixture_bytes = (tool / 'fixtures-selected.json').read_bytes()
    fixture = strict_json(fixture_bytes)
    original = strict_json((tool / 'fixtures.json').read_bytes())
    _require(fixture['cases'] == original['cases'], 'selected inputs differ from original')
    _require(fixture.get('baselineCommit') == 'a7d37f1707a70a459ad708f4fe79341d1e42d716' and
             fixture.get('target', {}).get('package') == TARGET and
             fixture['target'].get('apkSha256') == '593cc00c7d588e78cc32775d85aeb4d05957c6fd56f4ba942096753e8a5283b5',
             'selected fixture target differs')
    _require(_sha(reference_apk) == fixture['target']['apkSha256'], 'reference APK differs')
    output = Path(output)
    output.mkdir(parents=True, exist_ok=False)
    commands = []

    def run(name, command):
        try:
            result = subprocess.run([str(x) for x in command], capture_output=True, timeout=120)
        except subprocess.TimeoutExpired as error:
            (output / (name + '.stdout')).write_bytes(error.stdout or b'')
            (output / (name + '.stderr')).write_bytes(error.stderr or b'')
            commands.append({'name': name, 'argv': [str(x) for x in command], 'exitCode': None, 'timeout': True})
            raise ValueError(name + ' timed out') from error
        (output / (name + '.stdout')).write_bytes(result.stdout)
        (output / (name + '.stderr')).write_bytes(result.stderr)
        commands.append({'name': name, 'argv': [str(x) for x in command], 'exitCode': result.returncode, 'timeout': False})
        _require(result.returncode == 0, name + ' failed')
        return result.stdout.decode('utf-8', errors='strict')

    try:
        _require(run('source-head', ['git', '-C', source, 'rev-parse', 'HEAD']).strip() == fixture['baselineCommit'], 'source HEAD differs')
        _require(run('source-tree', ['git', '-C', source, 'rev-parse', 'HEAD^{tree}']).strip() == '0f69dc7004012a969551ce271dc4e11051637d32', 'source tree differs')
        _require(not run('source-status', ['git', '-C', source, 'status', '--porcelain=v1']).strip(), 'source checkout dirty')
        reference = {}
        for row in fixture['frozenSources']:
            data = (Path(source) / row['path']).read_bytes()
            _require(hashlib.sha1(data).hexdigest() == row['sha1'] and hashlib.sha256(data).hexdigest() == row['sha256'],
                     'reference source differs: ' + row['path'])
            reference[row['path']] = row['sha256']
        with zipfile.ZipFile(apk) as archive:
            for name in ('assets/fixtures-selected.json', 'assets/provenance.json', 'classes.dex'):
                _require(archive.namelist().count(name) == 1, 'missing or duplicate APK member: ' + name)
            _require(archive.read('assets/fixtures-selected.json') == fixture_bytes, 'packaged fixture differs')
            provenance_bytes = archive.read('assets/provenance.json')
            provenance = strict_json(provenance_bytes.decode('utf-8-sig'))
            dex = archive.read('classes.dex')
        fixture_hash = hashlib.sha256(fixture_bytes).hexdigest()
        _require(provenance.get('baselineCommit') == fixture['baselineCommit'] and
                 provenance.get('corpusAssetSha256') == fixture_hash and provenance.get('corpusSha256Lf') == fixture_hash and
                 provenance.get('dexSha256') == hashlib.sha256(dex).hexdigest() and
                 provenance.get('referenceHashes') == reference, 'packaged provenance differs')
        sources = ['tool/replace_js_oracle/ReplaceJsOracle.java', 'tool/replace_js_oracle/SelectedReplaceJsOracle.java',
                   'tool/replace_js_oracle/SelectedWebViewContainment.java', 'tool/replace_js_oracle/AndroidManifest-selected.xml', 'tool/replace_js_oracle/build.ps1',
                   'tool/replace_js_oracle/capture.py', 'tool/replace_js_oracle/selected_capture.py',
                   'tool/replace_js_oracle/compare.dart', 'tool/replace_rule_oracle/GuardedReaderApplication.java',
                   'tool/nested_oracle/StateSessionOracle.java', 'tool/nested_oracle/HostRuntimeInit.java',
                   'tool/nested_oracle/ShortcutStartupGuard.java']
        _require(provenance.get('sourceHashes') == {name: _sha(root / name) for name in sources}, 'current producer/consumer source differs')
        dex_path = output / 'harness.classes.dex'
        dex_path.write_bytes(dex)
        dex_output = run('harness-dex', [Path(sdk) / 'build-tools/35.0.1/dexdump.exe', '-f', dex_path])
        for name in ('Lio/liber/oracle/nested/SelectedReplaceJsOracle;',
                     'Lio/liber/oracle/nested/GuardedReaderApplication;',
                     'Lio/liber/oracle/nested/StateSessionOracle$ScratchContext;',
                     'Lio/liber/oracle/nested/HostRuntimeInit;', 'Lio/liber/oracle/nested/SelectedWebViewContainment;',
                     'runSelected', 'onCreate'):
            _require(name in dex_output, 'compiled entry missing: ' + name)
        aapt = Path(sdk) / 'build-tools/35.0.1/aapt.exe'
        java = Path(java_home) / 'bin/java.exe'
        signer = Path(sdk) / 'build-tools/35.0.1/lib/apksigner.jar'
        idsig = Path(str(apk) + '.idsig')
        _require(idsig.is_file(), 'signed APK sidecar missing')
        verifier = output / 'VerifyV4.java'
        verifier.write_text('''import java.io.File;\nimport com.android.apksig.ApkVerifier;\nclass VerifyV4 { public static void main(String[] a) throws Exception {\n  ApkVerifier.Result r = new ApkVerifier.Builder(new File(a[0])).setV4SignatureFile(new File(a[1])).build().verify();\n  System.out.println("verified=" + r.isVerified() + " v4=" + r.isVerifiedUsingV4Scheme());\n  if (!r.isVerified() || !r.isVerifiedUsingV4Scheme()) { System.err.println(r.getErrors()); System.exit(1); }\n} }\n''', encoding='utf-8')
        _require('verified=true v4=true' in run('harness-v4', [java, '--class-path', signer, verifier, apk, idsig]),
                 'APK v4 sidecar verification failed')
        manifest = run('harness-manifest', [aapt, 'dump', 'xmltree', apk, 'AndroidManifest.xml'])
        check_manifest(manifest)
        signer_text = run('harness-signature', [java, '-jar', signer, 'verify', '--verbose', '--print-certs', apk])
        digests = re.findall(r'Signer #(\d+) certificate SHA-256 digest: ([0-9a-f]{64})', signer_text, re.I)
        _require([(n, x.lower()) for n, x in digests] == [('1', '954abf2c4e9528b2226457d598e2ff9d1b608f83ac00c52ad66e023d61b2f2ad')], 'harness signer differs')
        target_manifest = run('reference-badging', [aapt, 'dump', 'badging', reference_apk])
        _require("package: name='" + TARGET + "'" in target_manifest and 'application-debuggable' in target_manifest,
                 'reference package or debug flag differs')
        target_sign = run('reference-signature', [java, '-jar', signer, 'verify', '--verbose', '--print-certs', reference_apk])
        digests = re.findall(r'Signer #(\d+) certificate SHA-256 digest: ([0-9a-f]{64})', target_sign, re.I)
        _require([(n, x.lower()) for n, x in digests] == [('1', '954abf2c4e9528b2226457d598e2ff9d1b608f83ac00c52ad66e023d61b2f2ad')], 'reference signer differs')
        result = {'status': 'preflight-only', 'fixtureSha256': fixture_hash, 'targetApkSha256': _sha(reference_apk),
                  'harnessApkSha256': _sha(apk), 'harnessIdsigSha256': _sha(idsig), 'provenanceAssetSha256': hashlib.sha256(provenance_bytes).hexdigest(),
                  'corpusAssetSha256': fixture_hash, 'corpusSha256Lf': fixture_hash, 'provenance': provenance}
        return result
    finally:
        (output / 'commands.json').write_text(json.dumps(commands, indent=2) + '\n', encoding='utf-8')


def verify_bundle(directory, fixture, binding, role):
    """Admit only complete physical logs for one fixed selected lifetime."""
    directory = Path(directory)
    manifest = strict_json((directory / 'manifest.json').read_text(encoding='utf-8'))
    _require(manifest.get('status') == 'observed' and manifest.get('role') == role and
             manifest.get('serial') == '5615f742' and manifest.get('error') is None and
             manifest.get('failure') is None and (manifest.get('timedOut') is None or manifest.get('timedOut') is False),
             'bundle status, failure or role differs')
    commands = manifest.get('commands')
    prefix = ['fingerprint', 'webview-provider', 'target-before', 'reference-path', 'pull-reference', 'harness-existing',
              'private-before', 'scratch-before', 'install', 'harness-path', 'pull-harness', 'target-preinstrument', 'instrumentation',
              'owner-before', 'role-owner-before', 'private-retained-before', 'owned-pid']
    suffix = ['target-after', 'owner-after', 'role-owner-after', 'private-retained', 'owned-cleanup',
              'target-final', 'private-after', 'scratch-after', 'remove-harness', 'harness-removed']
    _require(isinstance(commands, list) and all(isinstance(x, dict) for x in commands), 'physical command set malformed')
    names = [x.get('name') for x in commands]
    live_names = prefix + ['process-stat', 'process-cmdline', 'stop-owned'] + suffix
    _require(names in (prefix + suffix, live_names), 'physical command set differs')
    logs = {}
    serial = manifest['serial']
    for item in commands:
        name = item['name']
        _require(isinstance(item.get('argv'), list) and item['argv'][:3] == ['adb', '-s', serial],
                 'physical command is not owned: ' + name)
        stdout = (directory / (name + '.stdout')).read_bytes()
        stderr = (directory / (name + '.stderr')).read_bytes()
        _require(item.get('stdoutSha256') == hashlib.sha256(stdout).hexdigest() and
                 item.get('stderrSha256') == hashlib.sha256(stderr).hexdigest(), 'command log differs: ' + name)
        validate_command_receipt(name, stdout, stderr, item.get('exitCode'), item.get('timeout'), item['argv'][3:])
        logs[name] = stdout
    def argv(name):
        return commands[names.index(name)]['argv'][3:]
    expected = {
        'fingerprint': ['shell', 'getprop', 'ro.build.fingerprint'],
        'webview-provider': ['shell', 'dumpsys', 'webviewupdate'],
        'target-before': ['shell', 'pidof', TARGET],
        'reference-path': ['shell', 'pm', 'path', TARGET],
        'harness-existing': ['shell', 'pm', 'list', 'packages', PACKAGE],
        'private-before': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)],
        'scratch-before': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')],
        'harness-path': ['shell', 'pm', 'path', PACKAGE],
        'target-preinstrument': ['shell', 'pidof', TARGET],
        'instrumentation': ['shell', 'am', 'instrument', '-w', '-r', '-e', 'role', role,
                            PACKAGE + '/io.liber.oracle.nested.SelectedReplaceJsOracle'],
        'owner-before': ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/owner.json'],
        'role-owner-before': ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/role-owner.json'],
        'private-retained-before': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)],
        'owned-pid': ['shell', 'pidof', TARGET],
        'owner-after': ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/owner.json'],
        'role-owner-after': ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/role-owner.json'],
        'private-retained': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)],
        'target-final': ['shell', 'pidof', TARGET],
        'private-after': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)],
        'scratch-after': ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')],
        'target-after': ['shell', 'pidof', TARGET],
        'remove-harness': ['uninstall', PACKAGE],
        'harness-removed': ['shell', 'pm', 'list', 'packages', PACKAGE],
    }
    for name, value in expected.items():
        _require(argv(name) == value, 'physical command differs: ' + name)
    _require(logs['fingerprint'].decode('utf-8').strip() == FINGERPRINT, 'physical fingerprint differs')
    check_provider_preflight(logs['webview-provider'])
    _require(not logs['target-before'].strip() and not logs['target-preinstrument'].strip() and
             not logs['target-after'].strip() and not logs['target-final'].strip(), 'target process is not absent')
    def package_path(name):
        value = logs[name].decode('utf-8').strip()
        _require(value.startswith('package:') and '\n' not in value and '\r' not in value, 'package path invalid')
        return value.removeprefix('package:')
    _require(argv('pull-reference') == ['pull', package_path('reference-path'), str(directory / 'reference.apk')] and
             argv('pull-harness') == ['pull', package_path('harness-path'), str(directory / 'installed-harness.apk')],
             'pulled APK command differs')
    _require(argv('install') == ['install', '-r', str(directory / 'harness.apk')], 'install command differs')
    _require(_sha(directory / 'reference.apk') == binding['targetApkSha256'] and
             _sha(directory / 'harness.apk.idsig') == binding['harnessIdsigSha256'] and
             _sha(directory / 'harness.apk') == binding['harnessApkSha256'] and
             _sha(directory / 'installed-harness.apk') == binding['harnessApkSha256'], 'physical APK differs')
    for name in ('harness-existing', 'harness-removed'):
        lines = logs[name].decode('utf-8').splitlines()
        _require(all(x.startswith('package:') for x in lines) and
                 'package:' + PACKAGE not in lines, 'harness is not absent: ' + name)
    for name in ('install', 'remove-harness'):
        lines = logs[name].decode('utf-8').splitlines()
        _require(lines.count('Success') == 1 and not any(
            line.lower().startswith(('failure', 'error', 'failed')) for line in lines),
            'install/remove not confirmed: ' + name)
    report = decode_instrumentation(logs['instrumentation'])
    _require(typed_equal(report, strict_json((directory / 'observation.json').read_text(encoding='utf-8'))), 'raw payload differs from observation')
    check_selected_report(fixture, report, binding, role)
    _require(logs['owner-before'] == logs['owner-after'] and logs['role-owner-before'] == logs['role-owner-after'],
             'durable owner changed during termination')
    validate_owned_state(report, logs['owner-before'], logs['role-owner-before'], logs['private-before'], logs['private-retained-before'])
    registered = validate_owned_state(report, logs['owner-after'], logs['role-owner-after'], logs['private-before'], logs['private-retained'])
    owned_item = commands[names.index('owned-pid')]
    state = classify_process(logs['owned-pid'], owned_item['exitCode'], report['identity'])
    _require((state == 'live') == (names == live_names), 'process evidence and stop sequence differ')
    if state == 'live':
        pid = str(report['identity']['pid'])
        _require(argv('process-stat') == ['shell', 'cat', '/proc/' + pid + '/stat'] and
                 argv('process-cmdline') == ['shell', 'cat', '/proc/' + pid + '/cmdline'] and
                 argv('stop-owned') == ['shell', 'am', 'force-stop', TARGET], 'owned process commands differ')
        check_live_process(logs['process-stat'], logs['process-cmdline'], report['identity'])
    _require(argv('owned-cleanup') == ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(cleanup_script(registered))],
             'owned cleanup command differs')
    _require(parse_inventory(logs['private-before']) == parse_inventory(logs['private-after']), 'private inventory differs')
    return report


def check_backup(fixture, backup):
    source = fixture['backupSource']
    _require(_sha(backup) == source['sha256'], 'backup zip differs')
    with zipfile.ZipFile(backup) as archive:
        _require(archive.namelist().count(source['entry']) == 1, 'backup entry missing or duplicated')
        entry = archive.read(source['entry'])
    _require(hashlib.sha256(entry).hexdigest() == source['entrySha256'], 'backup entry differs')
    rules = strict_json(entry.decode('utf-8'))
    _require(len(rules) == source['ruleCount'], 'backup rule count differs')
    indexed = {r['id']: r for r in rules}
    for row in fixture['cases']:
        if 'backupRule' in row:
            original = row['backupRule']
            _require(original.get('isEnabled') is False and indexed.get(original['id']) == original,
                     'backup rule differs: ' + row['id'])
    _require([r['id'] for r in rules if str(r.get('replacement', '')).startswith('@js:')] == source['jsRuleIds'],
             'backup JS rule identity differs')


def capture(args):
    """Attempt exactly one approved fixed-role lifetime; failures remain untouched."""
    import shutil
    _require(args.role in ('main12', 'timeout') and args.serial == '5615f742', 'unapproved role or handset')
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    fixture = strict_json(Path(__file__).with_name('fixtures-selected.json').read_bytes())
    manifest = {'status': 'not-run', 'role': args.role, 'serial': args.serial, 'commands': []}
    installed = False
    def run(name, argv, timeout=60, expected_code=0):
        command = ['adb', '-s', args.serial] + [str(x) for x in argv]
        try:
            result = subprocess.run(command, capture_output=True, timeout=timeout)
            stdout, stderr, code, timedout = result.stdout, result.stderr, result.returncode, False
        except subprocess.TimeoutExpired as error:
            stdout, stderr, code, timedout = error.stdout or b'', error.stderr or b'', None, True
        (output / (name + '.stdout')).write_bytes(stdout)
        (output / (name + '.stderr')).write_bytes(stderr)
        manifest['commands'].append({'name': name, 'argv': command, 'exitCode': code, 'timeout': timedout,
                                     'stdoutSha256': hashlib.sha256(stdout).hexdigest(),
                                     'stderrSha256': hashlib.sha256(stderr).hexdigest()})
        allowed = expected_code if isinstance(expected_code, tuple) else (expected_code,)
        _require(code in allowed, name + ' failed')
        validate_command_receipt(name, stdout, stderr, code, timedout, command[3:])
        return stdout
    try:
        check_backup(fixture, args.backup)
        binding = preflight(args.apk, args.reference_apk, args.frozen_source, args.android_sdk, args.java_home,
                            output / 'preflight')
        shutil.copyfile(args.apk, output / 'harness.apk')
        shutil.copyfile(str(args.apk) + '.idsig', output / 'harness.apk.idsig')
        _require(_sha(output / 'harness.apk') == binding['harnessApkSha256'] and
                 _sha(output / 'harness.apk.idsig') == binding['harnessIdsigSha256'], 'copied harness pair differs')
        _require(run('fingerprint', ['shell', 'getprop', 'ro.build.fingerprint']).decode().strip() == FINGERPRINT,
                 'device fingerprint differs')
        check_provider_preflight(run('webview-provider', ['shell', 'dumpsys', 'webviewupdate']))
        _require(not run('target-before', ['shell', 'pidof', TARGET], expected_code=1).strip(), 'target process already exists')
        target = run('reference-path', ['shell', 'pm', 'path', TARGET]).decode().strip()
        _require(target.startswith('package:') and '\n' not in target, 'reference package path ambiguous')
        run('pull-reference', ['pull', target.removeprefix('package:'), output / 'reference.apk'])
        _require(_sha(output / 'reference.apk') == binding['targetApkSha256'], 'installed target differs')
        existing = run('harness-existing', ['shell', 'pm', 'list', 'packages', PACKAGE]).decode().splitlines()
        _require(all(x.startswith('package:') for x in existing) and 'package:' + PACKAGE not in existing,
                 'harness already installed or package inventory malformed')
        before = run('private-before', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)])
        parse_inventory(before)
        run('scratch-before', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')])
        installed_result = run('install', ['install', '-r', output / 'harness.apk'])
        installed = True  # An exit-zero attempt may have installed even if its text is contradictory.
        install_lines = installed_result.decode('utf-8').splitlines()
        _require(install_lines.count('Success') == 1 and not any(
            line.lower().startswith(('failure', 'error', 'failed')) for line in install_lines), 'install success not confirmed')
        target = run('harness-path', ['shell', 'pm', 'path', PACKAGE]).decode().strip()
        _require(target.startswith('package:') and '\n' not in target, 'harness package path ambiguous')
        run('pull-harness', ['pull', target.removeprefix('package:'), output / 'installed-harness.apk'])
        _require(_sha(output / 'installed-harness.apk') == binding['harnessApkSha256'], 'installed harness differs')
        _require(not run('target-preinstrument', ['shell', 'pidof', TARGET], expected_code=1).strip(),
                 'target process appeared before instrumentation')
        raw = run('instrumentation', ['shell', 'am', 'instrument', '-w', '-r', '-e', 'role', args.role,
                                      PACKAGE + '/io.liber.oracle.nested.SelectedReplaceJsOracle'], timeout=180)
        report = decode_instrumentation(raw)
        (output / 'observation.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        check_selected_report(fixture, report, binding, args.role)
        owner_before = run('owner-before', ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/owner.json'])
        role_owner_before = run('role-owner-before', ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/role-owner.json'])
        retained_before = run('private-retained-before', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)])
        validate_owned_state(report, owner_before, role_owner_before, before, retained_before)
        process = run('owned-pid', ['shell', 'pidof', TARGET], expected_code=(0, 1))
        state = classify_process(process, manifest['commands'][-1]['exitCode'], report['identity'])
        if state == 'live':
            pid = str(report['identity']['pid'])
            stat = run('process-stat', ['shell', 'cat', '/proc/' + pid + '/stat'])
            cmdline = run('process-cmdline', ['shell', 'cat', '/proc/' + pid + '/cmdline'])
            check_live_process(stat, cmdline, report['identity'])
            run('stop-owned', ['shell', 'am', 'force-stop', TARGET])
        _require(not run('target-after', ['shell', 'pidof', TARGET], expected_code=1).strip(), 'owned target process survived')
        owner_after = run('owner-after', ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/owner.json'])
        role_owner_after = run('role-owner-after', ['shell', 'run-as', TARGET, 'cat', 'cache/liber-replace-js-selected/role-owner.json'])
        _require(owner_before == owner_after and role_owner_before == role_owner_after, 'durable owner changed during termination')
        retained = run('private-retained', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)])
        registered = validate_owned_state(report, owner_after, role_owner_after, before, retained)
        run('owned-cleanup', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(cleanup_script(registered))])
        _require(not run('target-final', ['shell', 'pidof', TARGET], expected_code=1).strip(), 'target restarted during cleanup')
        after = run('private-after', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote(INVENTORY_SCRIPT)])
        _require(parse_inventory(before) == parse_inventory(after), 'private inventory differs')
        run('scratch-after', ['shell', 'run-as', TARGET, 'sh', '-c', shlex.quote('test ! -e cache/liber-replace-js-selected')])
        remove_lines = run('remove-harness', ['uninstall', PACKAGE]).decode('utf-8').splitlines()
        _require(remove_lines.count('Success') == 1 and not any(
            line.lower().startswith(('failure', 'error', 'failed')) for line in remove_lines), 'harness removal not confirmed')
        installed = False
        remaining = run('harness-removed', ['shell', 'pm', 'list', 'packages', PACKAGE]).decode().splitlines()
        _require(all(x.startswith('package:') for x in remaining) and 'package:' + PACKAGE not in remaining,
                 'harness removal inventory malformed')
        manifest['status'] = 'observed'
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
        verify_bundle(output, fixture, binding, args.role)
        return 0
    except Exception as error:
        manifest['status'] = 'failed'
        manifest['error'] = str(error)
        raw_path = output / 'instrumentation.stdout'
        if raw_path.is_file():
            payloads = re.findall(rb'REPLACE_JS_ORACLE_BASE64=([A-Za-z0-9+/=]+)', raw_path.read_bytes())
            if len(payloads) == 1:
                try:
                    partial = strict_json(base64.b64decode(payloads[0], validate=True).decode('utf-8'))
                    (output / 'failure-observation.json').write_text(
                        json.dumps(partial, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
                    manifest['failureObservation'] = 'unadmitted; see raw instrumentation and failure-observation.json'
                except (ValueError, UnicodeError):
                    manifest['failureObservation'] = 'unreadable; raw instrumentation retained'
        manifest['recovery'] = ('not-run: inspect and independently recover owned process and residue' if installed
                                else 'not-run: no successful owned install recorded; inspect any partial install')
        return 1
    finally:
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', default='5615f742')
    parser.add_argument('--role', choices=('main12', 'timeout'))
    parser.add_argument('--apk', required=True, type=Path)
    parser.add_argument('--reference-apk', required=True, type=Path)
    parser.add_argument('--frozen-source', required=True, type=Path)
    parser.add_argument('--android-sdk', required=True, type=Path)
    parser.add_argument('--java-home', required=True, type=Path)
    parser.add_argument('--backup', type=Path, default=Path('D:/GithubRepositories/Android/legado-backups/legado-backup-2026-09-17.zip'))
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--preflight-only', action='store_true')
    parser.add_argument('--verify-only', action='store_true')
    parser.add_argument('--main12-bundle', type=Path)
    parser.add_argument('--timeout-bundle', type=Path)
    args = parser.parse_args(argv)
    try:
        _require(not (args.preflight_only and args.verify_only), 'incompatible modes')
        if args.verify_only:
            fixture = strict_json(Path(__file__).with_name('fixtures-selected.json').read_bytes())
            check_backup(fixture, args.backup)
            binding = preflight(args.apk, args.reference_apk, args.frozen_source, args.android_sdk, args.java_home, args.output)
            result = {'main12': None, 'timeout': None, 'states': {'main12': 'not-run', 'timeout': 'not-run'},
                      'recovery': {'main12': 'not-run', 'timeout': 'not-run'}}
            identities = []
            for role, directory in (('main12', args.main12_bundle), ('timeout', args.timeout_bundle)):
                if directory is None:
                    continue
                path = directory.resolve()
                metadata = strict_json((path / 'manifest.json').read_text(encoding='utf-8'))
                if metadata.get('status') == 'failed':
                    result['states'][role] = 'unadmitted-failure-claim'
                    result['recovery'][role] = 'not-run: independent recovery is not verified by this verifier'
                    continue
                report = verify_bundle(path, fixture, binding, role)
                result[role] = report
                result['states'][role] = 'observed'
                identities.append((report['identity']['runId'], report['pid']))
            _require(len(identities) < 2 or (identities[0][0] != identities[1][0] and identities[0][1] != identities[1][1]),
                     'roles do not have distinct owned lifetimes')
            (args.output / 'admitted.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
            print(json.dumps({'status': 'verified', 'states': result['states']}))
            return 0
        if args.preflight_only:
            result = preflight(args.apk, args.reference_apk, args.frozen_source, args.android_sdk, args.java_home, args.output)
            (args.output / 'preflight.json').write_text(json.dumps(result, indent=2) + '\n', encoding='utf-8')
            print(json.dumps({'status': result['status'], 'harnessApkSha256': result['harnessApkSha256']}))
            return 0
        _require(args.role is not None, 'a fixed role is required')
        return capture(args)
    except Exception as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
