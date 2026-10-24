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
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile

BASELINE_APK = 'cc99040cc55e9a8b37134430c3ba38ff6ec2940b787e0235a19fa95692552cc6'
FINGERPRINT = 'Redmi/myron/myron:17/CP2A.260605.016/OS4.0.0.31.XPMCNXM:user/release-keys'
PACKAGE = 'io.liber.oracle.fields'
INSTRUMENTATION = PACKAGE + '/.FieldOracle'
TARGET_PACKAGE = 'io.legado.app.debug'
REPORT_REMOTE = '/sdcard/Android/data/io.legado.app.debug/files/field-oracle.json'
FIELDS_02 = 'FIELDS-02'
SCRATCH_ROOT = '/data/data/io.legado.app.debug/cache/liber-fields-02'
REPORT_REMOTE_FIELDS_02 = SCRATCH_ROOT + '/field-oracle.json'
OWNER_REMOTE_FIELDS_02 = SCRATCH_ROOT + '/owner.json'
PREFERENCE_DIR = '/data/data/io.legado.app.debug/shared_prefs'
OWNED_PREFERENCE_PREFIX = 'liber_fields_02_'
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


def _write_finalize_failure(output, error):
    receipt = {
        'status': 'failed',
        'kind': 'fields-02-finalize-failure',
        'error': error,
    }
    (output / 'finalize-failure.json').write_text(
        json.dumps(receipt, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def _hash_lines(output):
    """`sha256sum` output as {relative path: digest}."""
    hashes = {}
    for line in output.decode(errors='replace').splitlines():
        parts = line.split(None, 1)
        if len(parts) == 2:
            hashes[parts[1].strip()] = parts[0]
    return hashes


def finalize(output, fixture, manifest, report, before, after, asset=None,
             scratch_cleanup=None):
    """Validate one pulled report and its privacy snapshot; write the golden.

    Re-runnable over an evidence directory that already holds
    `field-oracle.json`, `private-before.log` and `private-after.log`, so a
    capture whose device step was interrupted can be finalized from the raw
    report the device actually produced instead of re-running the instrument.
    """
    if fixture.get('fixtureId') == FIELDS_02:
        return _finalize_fields_02(output, fixture, manifest, report, before, after,
                                   asset=asset, scratch_cleanup=scratch_cleanup)
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
    manifest['harnessSources'] = {
        p.name: sha256(p) for p in [
            Path(__file__), Path(__file__).with_name('FieldOracle.java'),
            Path(__file__).with_name('AndroidManifest.xml'),
            Path(__file__).with_name('build.ps1'),
            Path(__file__).with_name('..') / 'nested_oracle' / 'StateSessionOracle.java']
    }
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
    if not isinstance(_required(receipt, 'status', label + '.receipt'), int):
        raise ValueError(label + '.receipt.status must be integer')
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


def _finalize_fields_02(output, fixture, manifest, report, before, after, asset=None,
                        scratch_cleanup=None):
    """Validate the FIELDS-02 native report without deleting prior artifacts."""
    golden_path = output / 'golden.json'
    report_bytes = (output / 'field-oracle.json').read_bytes()
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
    for field in ['fixtureId', 'corpusVersion', 'baselineCommit', 'entryPoint']:
        if _required(report, field, 'report') != fixture[field]:
            raise ValueError('the frozen report disagrees on ' + field)
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
        response = responses[index]
        receipt = _required_map(actual, 'receipt', label)
        if receipt.get('responseId') != response['id']:
            raise ValueError('response id differs at ' + str(index))
        if receipt.get('status') != response.get('status', 200):
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

    corpus = _required_map(report, 'corpus', 'report')
    if corpus.get('asset') != 'field-fixtures.json':
        raise ValueError('the frozen report corpus asset differs')
    if corpus.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the frozen report fixture id differs')
    if corpus.get('corpusVersion') != fixture['corpusVersion']:
        raise ValueError('the frozen report corpus version differs')
    manifest_corpus = _required_map(manifest, 'corpus', 'manifest')
    for field in ['bytes', 'sha256', 'sha256Lf']:
        if field not in manifest_corpus:
            raise ValueError('manifest corpus measurement is missing ' + field)
    if corpus.get('bytes') != manifest_corpus['bytes']:
        raise ValueError('the frozen report corpus byte count differs')
    if corpus.get('sha256') != manifest_corpus['sha256']:
        raise ValueError('the frozen report raw corpus hash differs')
    if corpus.get('sha256Lf') != manifest_corpus['sha256Lf']:
        raise ValueError('the frozen report LF corpus hash differs')
    if not isinstance(manifest_corpus['bytes'], int) or manifest_corpus['bytes'] < 0:
        raise ValueError('manifest corpus byte count must be a nonnegative integer')
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
    if isolation.get('targetPackage') != TARGET_PACKAGE:
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

    cleanup = _required_map(report, 'cleanup', 'report')
    for field in ['serverClosed', 'ownerComplete', 'rootRetained', 'preferencesFenced']:
        if _required(cleanup, field, 'report.cleanup') is not True:
            raise ValueError('report.cleanup.' + field + ' must be true')
    if cleanup.get('scratchRoot') != SCRATCH_ROOT:
        raise ValueError('the scratch root path differs from the measured path')
    if cleanup.get('reportPath') != REPORT_REMOTE_FIELDS_02:
        raise ValueError('the scratch report path differs from the measured path')
    owner_run_id = _required_string(cleanup, 'ownerRunId', 'report.cleanup')
    owned = _required_list(cleanup, 'ownedPreferences', 'report.cleanup')
    if not owned or any(
            not re.fullmatch(r'liber_fields_02_[A-Za-z0-9_.-]+', str(name))
            for name in owned):
        raise ValueError('the scratch owned-preference list is malformed')
    if len(set(owned)) != len(owned):
        raise ValueError('the scratch owned-preference list contains duplicates')

    owner = _required_map(manifest, 'scratchOwner', 'manifest')
    if owner.get('fixtureId') != fixture['fixtureId']:
        raise ValueError('the scratch owner fixture id differs')
    if owner.get('corpusVersion') != fixture['corpusVersion']:
        raise ValueError('the scratch owner corpus version differs')
    if owner.get('targetPackage') != TARGET_PACKAGE:
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
    if owner.get('seedRunId') != owner_run_id:
        raise ValueError('the scratch owner does not bind this attempt')
    owner_prefs = _required_list(owner, 'preferences', 'manifest.scratchOwner')
    if sorted(owner_prefs) != sorted(owned):
        raise ValueError('the owner and report preference inventory differ')

    if not isinstance(scratch_cleanup, dict):
        raise ValueError('the external scratch cleanup receipt is missing')
    if scratch_cleanup.get('postStop') is not True:
        raise ValueError('the owned target process was not proven stopped')
    if scratch_cleanup.get('rootAbsent') is not True:
        raise ValueError('the external scratch root cleanup is not proven')
    if scratch_cleanup.get('ownedPreferencesAbsent') is not True:
        raise ValueError('the owned preferences survived cleanup')
    if scratch_cleanup.get('root') != SCRATCH_ROOT:
        raise ValueError('the external cleanup root differs')
    receipt_owned = scratch_cleanup.get('reportedOwnedPreferences')
    if not isinstance(receipt_owned, list) or sorted(receipt_owned) != sorted(owned):
        raise ValueError('the external cleanup inventory differs from the owner')

    frozen = _required_map(manifest, 'frozenSources', 'manifest')
    for source in fixture['frozenSources']:
        item = frozen.get(source['path'])
        if not isinstance(item, dict) or item.get('blobSha1') != source['sha1']:
            raise ValueError('the manifest frozen source binding differs: ' + source['path'])
    harness_sources = _required_map(manifest, 'harnessSources', 'manifest')
    if not harness_sources:
        raise ValueError('the manifest harness source binding is empty')

    before_hashes = _hash_lines(before)
    after_hashes = _hash_lines(after)
    changed = {path: {'before': before_hashes.get(path), 'after': after_hashes.get(path)}
               for path in sorted(set(before_hashes) | set(after_hashes))
               if before_hashes.get(path) != after_hashes.get(path)}
    if changed:
        raise ValueError('FIELDS-02 private storage changed outside the scratch boundary: '
                         + json.dumps(changed, ensure_ascii=False))
    manifest['existingDataHashesUnchanged'] = True
    manifest['privateFileChanges'] = {}
    manifest['frozenAppDataUnchanged'] = all(path in after_hashes for path in FROZEN_APP_STORE)
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

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--serial', required=True)
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
    fields_02 = fixture.get('fixtureId') == FIELDS_02
    if args.finalize:
        report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
        manifest = json.loads((args.output / 'manifest.json').read_text(encoding='utf-8'))
        if fields_02:
            golden = args.output / 'golden.json'
            report_bytes = (args.output / 'field-oracle.json').read_bytes()
            if golden.exists():
                if golden.read_bytes() != report_bytes:
                    _write_finalize_failure(args.output,
                                            'existing golden bytes differ from report; refusing')
                    return 1
                if manifest.get('status') != 'observed' or manifest.get('goldenSha256') != sha256(golden):
                    _write_finalize_failure(args.output,
                                            'existing golden has no accepted manifest binding')
                    return 1
            try:
                result = finalize(args.output, fixture, manifest, report,
                                  (args.output / 'private-before.log').read_bytes(),
                                  (args.output / 'private-after.log').read_bytes(),
                                  asset=args.asset,
                                  scratch_cleanup=manifest.get('scratchCleanup'))
            except Exception as error:  # noqa: BLE001 - preserve accepted bytes
                _write_finalize_failure(args.output, str(error))
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
                     scratch_cleanup=manifest.get('scratchCleanup'))
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
    if fields_02:
        asset_bytes = Path(args.asset).read_bytes()
        if len(asset_bytes) != len(corpus_bytes):
            raise SystemExit('the built asset byte count differs from the selected corpus')
        if sha256_bytes(asset_bytes) != corpus_sha256:
            raise SystemExit('the built asset raw hash differs from the selected corpus')
        if sha256_bytes(lf_bytes(asset_bytes)) != corpus_sha256_lf:
            raise SystemExit('the built asset LF hash differs from the selected corpus')
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
        'harnessSources': {
            p.name: sha256(p) for p in [
                Path(__file__), Path(__file__).with_name('FieldOracle.java'),
                Path(__file__).with_name('AndroidManifest.xml'),
                Path(__file__).with_name('build.ps1'),
                Path(__file__).with_name('..') / 'nested_oracle' / 'StateSessionOracle.java']
        },
    }
    if fields_02:
        manifest['corpus'].update({
            'bytes': len(corpus_bytes),
            'sha256Lf': corpus_sha256_lf,
            'assetCopySha256': sha256_bytes(asset_bytes),
        })
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
        result = adb(name, 'shell', *remote_script_arguments(TARGET_PACKAGE, script),
                     **kwargs)
        return result

    def preflight_fields_02():
        """Refuse any preexisting state; never delete or replace it."""
        process = adb('target-process', 'shell', 'pidof', TARGET_PACKAGE, checked=False)
        if process.returncode not in (0, 1) or process.stdout.strip():
            raise ValueError('a target process already exists; refusing an unowned run')
        root = remote_script('scratch-root-check',
                             'if [ -e ' + shlex.quote(SCRATCH_ROOT)
                             + ' ]; then echo PRESENT; else echo ABSENT; fi',
                             checked=False)
        if root.returncode != 0:
            raise ValueError('cannot determine whether the scratch root exists')
        if root.stdout.decode(errors='replace').strip() != 'ABSENT':
            raise ValueError('a preexisting scratch root exists; refusing to delete it')
        prefs = remote_script(
            'scratch-prefs-check',
            'if [ -d ' + shlex.quote(PREFERENCE_DIR) + ' ]; then '
            + 'find ' + shlex.quote(PREFERENCE_DIR)
            + ' -maxdepth 1 -name ' + shlex.quote(OWNED_PREFERENCE_PREFIX + '*.xml')
            + ' -print; fi',
            checked=False,
        )
        if prefs.returncode != 0:
            raise ValueError('cannot determine whether owned preferences exist')
        if prefs.stdout.strip():
            raise ValueError('a preexisting field preference namespace exists; refusing to delete it')

    def stop_owned_target():
        stopped = adb('poststop', 'shell', 'am', 'force-stop', TARGET_PACKAGE, checked=False)
        if stopped.returncode != 0:
            raise ValueError('the owned target process could not be stopped')
        check = adb('poststop-check', 'shell', 'pidof', TARGET_PACKAGE, checked=False)
        if check.returncode not in (0, 1) or check.stdout.strip():
            raise ValueError('the target process is still present after the owned stop')

    def cleanup_fields_02(report, owner):
        """Remove only the exact owner inventory after proving the stop/binding."""
        if not isinstance(report, dict) or not isinstance(owner, dict):
            raise ValueError('report/owner cleanup input is malformed')
        cleanup = report.get('cleanup') or {}
        if not isinstance(cleanup, dict):
            raise ValueError('scratch cleanup record malformed')
        if cleanup.get('ownerComplete') is not True or cleanup.get('rootRetained') is not True:
            raise ValueError('the harness did not retain a completed owner scratch root')
        if cleanup.get('preferencesFenced') is not True:
            raise ValueError('the harness did not fence owned preferences')
        owner_run_id = cleanup.get('ownerRunId')
        if not isinstance(owner_run_id, str) or not owner_run_id:
            raise ValueError('the harness did not publish an owner attempt id')
        if owner.get('seedRunId') != owner_run_id or owner.get('complete') is not True:
            raise ValueError('the scratch owner does not bind this attempt')
        owner_prefs = owner.get('preferences')
        reported = cleanup.get('ownedPreferences')
        if not isinstance(owner_prefs, list) or not isinstance(reported, list):
            raise ValueError('the scratch preference inventory is missing')
        if sorted(owner_prefs) != sorted(reported):
            raise ValueError('the owner and report preference inventories differ')
        if not owner_prefs:
            raise ValueError('the scratch owner has no owned preference namespace')
        for name in owner_prefs:
            if not isinstance(name, str) or not re.fullmatch(
                    r'liber_fields_02_[A-Za-z0-9_.-]+', name):
                raise ValueError('unexpected owned preference name: ' + str(name))
        if len(set(owner_prefs)) != len(owner_prefs):
            raise ValueError('the scratch owner repeats a preference name')

        stop_owned_target()
        for name in owner_prefs:
            path = PREFERENCE_DIR + '/' + name + '.xml'
            removed = remote_script('scratch-remove-' + name,
                                    'rm -f -- ' + shlex.quote(path),
                                    checked=False)
            if removed.returncode != 0:
                raise ValueError('could not remove the exact owned preference: ' + name)
        root_removed = remote_script('scratch-remove-root',
                                     'rm -rf -- ' + shlex.quote(SCRATCH_ROOT),
                                     checked=False)
        if root_removed.returncode != 0:
            raise ValueError('could not remove the owned scratch root')
        for name in owner_prefs:
            path = PREFERENCE_DIR + '/' + name + '.xml'
            absent = remote_script('scratch-absent-' + name,
                                   'test ! -e ' + shlex.quote(path),
                                   checked=False)
            if absent.returncode != 0:
                raise ValueError('owned preference survived cleanup: ' + name)
        root_absent = remote_script('scratch-absent-root',
                                    'test ! -e ' + shlex.quote(SCRATCH_ROOT),
                                    checked=False)
        if root_absent.returncode != 0:
            raise ValueError('owned scratch root survived cleanup')
        return {
            'reportedOwnedPreferences': list(owner_prefs),
            'ownerRunId': owner_run_id,
            'root': SCRATCH_ROOT,
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
        baseline = adb(
            'baseline-path', 'shell', 'pm', 'path', 'io.legado.app.debug').stdout.decode().strip()
        adb('pull-baseline', 'pull', baseline.removeprefix('package:'),
            str(scratch / 'frozen.apk'))
        manifest['baselineApkSha256'] = sha256(scratch / 'frozen.apk')
        if manifest['baselineApkSha256'] != expected_apk:
            raise ValueError('installed baseline APK differs')
        existing = adb('harness-existing', 'shell', 'pm', 'path', PACKAGE, checked=False)
        if b'package:' in existing.stdout:
            raise ValueError('harness package already exists; do not replace unowned install')
        if fields_02:
            # A preexisting namespace is owned by someone else and is never
            # cleaned, replaced, or wildcard-deleted by this driver.
            preflight_fields_02()
        # Only hash lists leave the device; no user content is copied.
        snapshot_script = ("find databases shared_prefs files -type f "
                           "-exec sha256sum {} \\; 2>/dev/null")
        if fields_02:
            before = remote_script('private-before', snapshot_script)
        else:
            snapshot = "'" + snapshot_script + "'"
            before = adb('private-before', 'shell', 'run-as', 'io.legado.app.debug',
                         'sh', '-c', snapshot)
        installed_result = adb('install', 'install', '-r', str(args.apk), checked=False,
                               timeout=180)
        if installed_result.returncode:
            manifest['status'] = 'blocked'
            manifest['blocker'] = installed_result.stderr.decode(errors='replace')
            partial = adb('partial-harness', 'shell', 'pm', 'path', PACKAGE,
                          checked=False)
            if b'package:' in partial.stdout:
                manifest['status'] = 'failed'
                manifest['error'] = ('install returned nonzero but a partial harness '
                                     'package is present; preserving it for inspection')
                removed = adb('remove-partial-harness', 'uninstall', PACKAGE,
                               checked=False)
                if removed.returncode:
                    manifest['error'] += '; partial harness uninstall also failed'
            return 2 if manifest['status'] == 'blocked' else 1
        installed = True
        adb('logcat-clear', 'logcat', '-c', checked=False)
        result = adb('instrumentation', 'shell', 'am', 'instrument', '-w', '-r',
                     INSTRUMENTATION, timeout=240)
        manifest['run'] = {'result': result.stdout.decode(errors='replace').strip()}
        logcat = adb('logcat-field-oracle', 'logcat', '-d', '-s', 'FieldOracle', checked=False)
        (args.output / 'logcat.log').write_bytes(logcat.stdout)
        if fields_02:
            # The harness leaves its owned scratch root and owner manifest in the
            # target cache for this external driver. Stop the owned target first,
            # then read the report/owner and remove only the verified inventory.
            stop_owned_target()
            pulled = adb('pull-report', 'exec-out', 'run-as', TARGET_PACKAGE,
                         'cat', REPORT_REMOTE_FIELDS_02, checked=False)
            if pulled.returncode:
                raise ValueError('the device reported no oracle report')
            (args.output / 'field-oracle.json').write_bytes(pulled.stdout)
            owner_result = adb('scratch-owner', 'exec-out', 'run-as', TARGET_PACKAGE,
                               'cat', OWNER_REMOTE_FIELDS_02, checked=False)
            if owner_result.returncode:
                raise ValueError('the outer driver could not read the scratch owner manifest')
            manifest['scratchOwner'] = json.loads(owner_result.stdout)
            report = json.loads((args.output / 'field-oracle.json').read_text(encoding='utf-8'))
            manifest['scratchCleanup'] = cleanup_fields_02(
                report, manifest['scratchOwner'])
            uninstalled = adb('remove-harness', 'uninstall', PACKAGE, checked=False)
            if uninstalled.returncode:
                raise ValueError('the owned harness could not be uninstalled')
            installed = False
            before = (args.output / 'private-before.log').read_bytes()
            after = remote_script('private-after', snapshot_script).stdout
            finalize(args.output, fixture, manifest, report, before, after,
                     asset=args.asset, scratch_cleanup=manifest['scratchCleanup'])
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
            # cleanup: ambiguous remnants are preserved and reported.
            if fields_02:
                stop = adb('stop-owned-run', 'shell', 'am', 'force-stop',
                           TARGET_PACKAGE, checked=False)
                if stop.returncode:
                    manifest['status'] = 'failed'
                    manifest['error'] = 'owned target stop failed in cleanup'
            else:
                adb('stop-owned-run', 'shell', 'am', 'force-stop',
                    'io.legado.app.debug', checked=False)
            removed = adb('remove-harness', 'uninstall', PACKAGE, checked=False)
            if removed.returncode and fields_02:
                manifest['status'] = 'failed'
                manifest['error'] = 'owned harness uninstall failed in cleanup'
        (args.output / 'manifest.json').write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'status': manifest['status'],
                          'manifest': str(args.output / 'manifest.json')}))


if __name__ == '__main__':
    sys.exit(main())
