"""Run the runtime-limit probes and record the executed evidence.

Usage: python tool/runtime_limits_prototype/verify.py [fjs-library.dll]

Writes evidence/windows-native.json, evidence/windows-quantum.json,
evidence/windows-product.json, evidence/gates.log and evidence/manifest.json
under this directory. Every probe writes its raw JSON; the manifest adds hashes
and provenance. A non-zero exit means an observation did not reproduce, not
that a limit is missing: the verdicts live in manifest.json's `findings`.
"""
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EVIDENCE = HERE / 'evidence'
QUICKJS = ROOT / 'packages/fjs/libfjs/vendor/rquickjs-sys/quickjs'
SCRATCH = pathlib.Path(tempfile.gettempdir()) / 'liber-runtime-limits-prototype'
COMPILER = shutil.which('gcc') or 'D:/Tool/mingw64/bin/gcc.exe'
GATES = ('runtime_gate', 'fiber_runtime_gate')
QUANTUMS = (10000, 1000, 256)
# The catch-and-retry allocation loop deliberately runs far past its deadline.
CASE_TIMEOUTS = {'deadline-oom-retry-loop': 300}
PRODUCT_CASES = (
    'deadline-basic',
    'deadline-heavy-loop-body',
    'deadline-single-native-call',
    'deadline-uncatchable',
    'deadline-regex-bomb',
    'deadline-host-call',
    'deadline-isolate-blocked',
    'deadline-oom-retry-loop',
    'memory-limit-alloc-loop',
    'memory-limit-huge-allocation',
    'stack-depth',
)
QUANTUM_PATCHES = {
    'quickjs.c': (r'#define JS_INTERRUPT_COUNTER_INIT \d+',
                  '#define JS_INTERRUPT_COUNTER_INIT {quantum}'),
    'libregexp.c': (r'#define INTERRUPT_COUNTER_INIT \d+',
                    '#define INTERRUPT_COUNTER_INIT {quantum}'),
}


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def run(command, timeout, cwd=ROOT):
    started = time.monotonic()
    try:
        completed = subprocess.run([str(part) for part in command], cwd=cwd, text=True,
                                   capture_output=True, timeout=timeout, check=False)
        return {'command': [str(part) for part in command], 'exitCode': completed.returncode,
                'timedOut': False, 'seconds': round(time.monotonic() - started, 3),
                'stdout': completed.stdout, 'stderr': completed.stderr[-4000:]}
    except subprocess.TimeoutExpired as expired:
        decode = lambda value: value.decode('utf-8', 'replace') if isinstance(value, bytes) \
            else (value or '')
        return {'command': [str(part) for part in command], 'exitCode': None, 'timedOut': True,
                'seconds': round(time.monotonic() - started, 3),
                'stdout': decode(expired.stdout), 'stderr': decode(expired.stderr)}


def compile_probe(name, compiler_arguments, output, timeout=900):
    sources = [QUICKJS / 'quickjs.c', QUICKJS / 'libregexp.c', QUICKJS / 'libunicode.c',
               QUICKJS / 'dtoa.c']
    command = [COMPILER, '-std=gnu11', '-D_GNU_SOURCE', '-DWIN32_LEAN_AND_MEAN', '-O1', '-g',
               '-I', QUICKJS, *compiler_arguments, HERE / name, *sources, '-lws2_32', '-lm',
               '-o', output]
    return run(command, timeout=timeout)


def quantum_table():
    """Rebuild the pinned sources with a smaller poll quanta and re-measure."""
    rows = []
    for quantum in QUANTUMS:
        work = SCRATCH / f'quantum-{quantum}'
        shutil.rmtree(work, ignore_errors=True)
        shutil.copytree(QUICKJS, work / 'quickjs')
        patches = []
        for name, (pattern, template) in QUANTUM_PATCHES.items():
            path = work / 'quickjs' / name
            text = path.read_text(encoding='utf-8')
            patched, count = re.subn(pattern, template.format(quantum=quantum), text, count=1)
            if count != 1:
                raise SystemExit(f'quantum patch did not match in {name}')
            path.write_text(patched, encoding='utf-8', newline='\n')
            patches.append({'file': name, 'pattern': pattern,
                            'replacement': template.format(quantum=quantum)})
        sources = [work / 'quickjs' / 'quickjs.c', work / 'quickjs' / 'libregexp.c',
                   work / 'quickjs' / 'libunicode.c', work / 'quickjs' / 'dtoa.c']
        source_hashes = [{'path': path.name, 'sha256': sha256(path)} for path in sources]
        executable = work / 'quantum_probe.exe'
        build = run([COMPILER, '-std=gnu11', '-D_GNU_SOURCE', '-DWIN32_LEAN_AND_MEAN', '-O2',
                     f'-DQUANTUM_LABEL={quantum}', '-I', work / 'quickjs',
                     HERE / 'quantum_probe.c', *sources, '-lws2_32', '-lm', '-o', executable],
                    timeout=900)
        if build['exitCode'] != 0:
            raise SystemExit(f'quantum probe build failed for {quantum}:\n{build["stderr"]}')
        probe = run([executable], timeout=300)
        row = json.loads(probe['stdout'])
        throughput_only = run([executable, 'throughput'], timeout=300)
        row['throughputOnly'] = json.loads(throughput_only['stdout'])['cases']['throughputLoop']
        row['patches'] = patches
        row['patchedSourceHashes'] = source_hashes
        rows.append(row)
        if row['quantum'] != quantum:
            raise SystemExit(f'quantum probe reported {row["quantum"]} for {quantum}')
        print(f'quantum {quantum}: ' + json.dumps(
            {name: {'medianMs': case['medianMs'], 'worstOvershootMs': case['worstOvershootMs'],
                    'interruptedInEverySample': case['interruptedInEverySample']}
             for name, case in row['cases'].items()}), flush=True)
    return rows


def main():
    library = pathlib.Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else \
        (ROOT / 'build/windows/x64/runner/Debug/fjs.dll').resolve()
    library = library.resolve(strict=True)
    EVIDENCE.mkdir(exist_ok=True)
    SCRATCH.mkdir(exist_ok=True)
    dart = shutil.which('dart')
    pwsh = shutil.which('pwsh') or shutil.which('powershell')
    if dart is None or pwsh is None:
        raise SystemExit('dart and pwsh must be on PATH')

    failures = []

    # 1. The native probe: the pinned QuickJS sources, no Dart in the way.
    build = run([pwsh, '-NoProfile', '-File', HERE / 'build.ps1', '-OutputDirectory', SCRATCH],
                timeout=900)
    if build['exitCode'] != 0:
        raise SystemExit('native probe build failed:\n' + build['stderr'] + build['stdout'])
    probe = run([SCRATCH / 'native_probe.exe'], timeout=900)
    (EVIDENCE / 'windows-native.json').write_text(probe['stdout'], encoding='utf-8')
    native = json.loads(probe['stdout'])
    failures += [f'native check failed: {name}' for name, ok in native['checks'].items() if not ok]

    # 2. The poll-quantum sensitivity table on patched copies of those sources.
    quantums = quantum_table()
    (EVIDENCE / 'windows-quantum.json').write_text(
        json.dumps({'note': 'Patched copies of the frozen vendored sources; the vendored '
                            'files themselves are unchanged.',
                    'rows': quantums}, indent=2) + '\n', encoding='utf-8')

    # 3. The product probe: one process per case, so an uninterruptible execution is
    # recorded as a kill instead of hanging the run.
    product = {'library': str(library), 'cases': {}}
    for case in PRODUCT_CASES:
        result = run([dart, 'run', 'tool/runtime_limits_prototype/product_probe.dart',
                      library, case], timeout=CASE_TIMEOUTS.get(case, 120))
        entry = {'case': case, 'timedOut': result['timedOut'], 'exitCode': result['exitCode'],
                 'seconds': result['seconds']}
        try:
            entry.update(json.loads(result['stdout']))
        except json.JSONDecodeError:
            entry['stdout'] = result['stdout'][-2000:]
            entry['stderr'] = result['stderr']
            failures.append(f'product case produced no JSON: {case}')
        product['cases'][case] = entry
        if result['timedOut']:
            failures.append(f'product case exceeded its harness timeout: {case}')
        failures += [f'product check failed: {case}/{name}'
                     for name, ok in entry.get('checks', {}).items() if not ok]
        print(f'product {case}: {entry.get("status", "no-status")} '
              f'({entry["seconds"]}s)', flush=True)
    (EVIDENCE / 'windows-product.json').write_text(json.dumps(product, indent=2) + '\n',
                                                   encoding='utf-8')

    # 4. The shipped gates that exercise the same engine through this DLL.
    gates = {}
    gate_log = []
    for gate in GATES:
        result = run([dart, 'run', f'tool/{gate}.dart', library], timeout=300)
        gates[gate] = {'exitCode': result['exitCode'], 'timedOut': result['timedOut'],
                       'seconds': result['seconds']}
        gate_log.append(f'===== {gate} (exit {result["exitCode"]}) =====\n'
                        f'{result["stdout"]}\n{result["stderr"]}\n')
        if result['exitCode'] != 0:
            failures.append(f'gate failed on this library: {gate}')
    (EVIDENCE / 'gates.log').write_text(''.join(gate_log), encoding='utf-8')

    # 5. Provenance and the verdict.
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=ROOT, text=True).strip()

    findings = dict(native['findings'])
    findings['quantumSensitivity'] = {
        str(row['quantum']): {
            'heavyLoopWorstOvershootMs': row['cases']['heavyLoopBody']['worstOvershootMs'],
            'allocationLoopWorstOvershootMs': row['cases']['allocationLoop']['worstOvershootMs'],
            'oomRetryWorstOvershootMs': row['cases']['oomRetryLoop']['worstOvershootMs'],
            'throughputLoopFastestMs': row['cases']['throughputLoop']['fastestMs'],
            'throughputOnlyFastestMs': row['throughputOnly']['fastestMs'],
        } for row in quantums}
    for row in quantums:
        for name, case in row['cases'].items():
            if case['deadlineMs'] > 0 and not case['interruptedInEverySample']:
                failures.append(
                    f'quantum {row["quantum"]} case {name} did not interrupt every sample')
    measured = {
        'productDeadlineBasicOvershootMs': [
            run_entry['overshootMs']
            for run_entry in product['cases']['deadline-basic']['measurements']['runs']],
        'productHeavyLoopOvershootMs':
            product['cases']['deadline-heavy-loop-body']['measurements']['run']['overshootMs'],
        'productSingleNativeCallMeasuredMs':
            product['cases']['deadline-single-native-call']['measurements']['run']['measuredMs'],
        'productOomRetryOvershootMs':
            product['cases']['deadline-oom-retry-loop']['measurements']['run']['overshootMs'],
        'productHostCallOvershootMs':
            product['cases']['deadline-host-call']['measurements']['run']['overshootMs'],
        'productIsolateBlockedMeasuredMs':
            product['cases']['deadline-isolate-blocked']['measurements']['run']['measuredMs'],
        'productRssGrowthOverHeapLimitBytes':
            product['cases']['memory-limit-alloc-loop']['measurements']['runs']['rssGrowthBytes'],
    }
    manifest = {
        'status': 'pass' if not failures else 'fail',
        'scope': 'Windows only; Android, iOS, macOS and Linux remain not-run',
        'recordedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'repositoryHead': git('rev-parse', 'HEAD'),
        'repositoryBranch': git('branch', '--show-current'),
        'uncommittedChanges': git('status', '--short').splitlines(),
        'library': {'path': str(library), 'sha256': sha256(library),
                    'bytes': library.stat().st_size,
                    'mtime': time.strftime('%Y-%m-%dT%H:%M:%S',
                                           time.localtime(library.stat().st_mtime))},
        'nativeProbe': {'path': str(SCRATCH / 'native_probe.exe'),
                        'sha256': sha256(SCRATCH / 'native_probe.exe')},
        'engines': {'quickjs': native['engine'],
                    'rquickjsRevision': '04e27345bd12e1d9b1eb68d76865805126313998',
                    'quickjsRevision': 'fd0a0210b7be00957751871e7e01b8291268fc29',
                    'compiler': compiler_version()},
        'sourceHashes': [
            {'path': str(path.relative_to(ROOT)).replace('\\', '/'), 'sha256': sha256(path)}
            for path in [HERE / 'native_probe.c', HERE / 'quantum_probe.c', HERE / 'build.ps1',
                         HERE / 'product_probe.dart', HERE / 'verify.py']
            + sorted(QUICKJS.glob('*.c')) + sorted(QUICKJS.glob('*.h'))],
        'evidenceHashes': [
            {'path': str(path.relative_to(ROOT)).replace('\\', '/'), 'sha256': sha256(path)}
            for path in sorted(EVIDENCE.glob('*.json')) + [EVIDENCE / 'gates.log']],
        'gates': gates,
        'findings': findings,
        'measured': measured,
        'failures': failures,
    }
    (EVIDENCE / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n',
                                            encoding='utf-8')
    print(json.dumps({'status': manifest['status'], 'failures': failures,
                      'findings': findings}, indent=2), flush=True)
    return 1 if failures else 0


def compiler_version():
    version = run([COMPILER, '--version'], timeout=60)
    return version['stdout'].splitlines()[0] if version['stdout'] else COMPILER


if __name__ == '__main__':
    sys.exit(main())
