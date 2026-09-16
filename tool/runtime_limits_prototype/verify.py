"""Run the runtime-limit probes and record the executed evidence for this platform.

Usage: python tool/runtime_limits_prototype/verify.py [release-library] [gate-library]

The rows are the same on every platform; only the native library differs.
`release-library` is what the product cases and the limit rows load — a release
build measures what a release build does. `gate-library` is what the shared gate
list loads, which on Windows is the app bundle's debug DLL.

Writes evidence/<platform>-native.json, evidence/<platform>-quantum.json,
evidence/<platform>-product.json, evidence/gates.log and evidence/manifest.json
under this directory. Every probe writes its raw JSON; the manifest adds hashes
and provenance. A non-zero exit means an observation did not reproduce, not that
a limit is missing: the verdicts live in manifest.json's `findings`.

Rows for a platform other than the one running this file stay `not-run`; the
manifest records which platform each file belongs to instead of implying a
five-platform result.
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
# Importing the shared gate list must not leave a __pycache__ tree in the
# repository; the harness only needs the module's constants and helpers.
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tool'))
import ci_runtime  # noqa: E402  (one shared gate list, not a second copy)

EVIDENCE = HERE / 'evidence'
QUICKJS = ROOT / 'packages/fjs/libfjs/vendor/rquickjs-sys/quickjs'
SCRATCH = pathlib.Path(tempfile.gettempdir()) / 'liber-runtime-limits-prototype'
COMPILER = shutil.which('gcc') or shutil.which('cc') or 'D:/Tool/mingw64/bin/gcc.exe'
PLATFORM = {'win32': 'windows', 'darwin': 'macos', 'linux': 'linux'}.get(sys.platform)
if PLATFORM is None:
    raise SystemExit(f'unsupported platform: {sys.platform}')
EXE = '.exe' if PLATFORM == 'windows' else ''
QUICKJS_SOURCES = ('quickjs.c', 'libregexp.c', 'libunicode.c', 'dtoa.c')
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
VENDOR_NOTES = ROOT / 'packages/fjs/libfjs/vendor/rquickjs-sys/LIBER.md'
# The build copy the product links carries the poll quantum ADR 0009 settles;
# the vendored files stay pinned at 10 000.
PRODUCT_QUANTUM = 1000


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def vendored_revision(label):
    """Read a pinned revision out of the vendor record instead of restating it."""
    notes = VENDOR_NOTES.read_text(encoding='utf-8')
    match = re.search(rf'{label}\s+commit\s*`?\s*([0-9a-f]{{40}})', notes) or         re.search(rf'{label}\s+submodule\s*`?\s*([0-9a-f]{{40}})', notes)
    if match is None:
        raise SystemExit(f'no {label} revision in {VENDOR_NOTES}')
    return match.group(1)


def default_library(kind):
    """The native library this platform's probes load, when no path is given."""
    if PLATFORM == 'windows':
        release = ROOT / 'packages/fjs/libfjs/target/release/fjs.dll'
        if kind == 'release':
            return release
        # The gates load the app bundle's debug DLL: test/native_library.dart and
        # the package's own gates resolve that copy before the crate target dir.
        return ROOT / 'build/windows/x64/runner/Debug/fjs.dll'
    suffix = 'libfjs.dylib' if PLATFORM == 'macos' else 'libfjs.so'
    profile = 'release' if kind == 'release' else 'debug'
    return ROOT / 'packages/fjs/libfjs/target' / profile / suffix


def run(command, timeout, cwd=ROOT):
    started = time.monotonic()
    try:
        # Decode as UTF-8 rather than the console's code page: a probe or a gate
        # that prints a non-ASCII result must not turn its whole record into None
        # on a GBK console.
        completed = subprocess.run([str(part) for part in command], cwd=cwd, text=True,
                                   encoding='utf-8', errors='replace', capture_output=True,
                                   timeout=timeout, check=False)
        return {'command': [str(part) for part in command], 'exitCode': completed.returncode,
                'timedOut': False, 'seconds': round(time.monotonic() - started, 3),
                'stdout': completed.stdout, 'stderr': completed.stderr[-4000:]}
    except subprocess.TimeoutExpired as expired:
        decode = lambda value: value.decode('utf-8', 'replace') if isinstance(value, bytes) \
            else (value or '')
        return {'command': [str(part) for part in command], 'exitCode': None, 'timedOut': True,
                'seconds': round(time.monotonic() - started, 3),
                'stdout': decode(expired.stdout), 'stderr': decode(expired.stderr)}


def probe_build(probe, output, optimisation, sources, include, defines=()):
    """The one probe build recipe; only the platform flags differ.

    Windows needs `WIN32_LEAN_AND_MEAN` and `ws2_32`; both platforms take
    `_GNU_SOURCE`, the C11 dialect, `-lm` and the pinned source list.
    """
    flags = ['-std=gnu11', '-D_GNU_SOURCE', optimisation, '-g']
    libraries = ['-lm']
    if PLATFORM == 'windows':
        flags.append('-DWIN32_LEAN_AND_MEAN')
        libraries.append('-lws2_32')
    return [COMPILER, *flags, *defines, '-I', include, HERE / probe,
            *sources, *libraries, '-o', output]


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
        sources = [work / 'quickjs' / name for name in QUICKJS_SOURCES]
        source_hashes = [{'path': path.name, 'sha256': sha256(path)} for path in sources]
        executable = work / f'quantum_probe{EXE}'
        build = run(probe_build('quantum_probe.c', executable, '-O2', sources,
                                work / 'quickjs', [f'-DQUANTUM_LABEL={quantum}']),
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


def resolve(argument, kind):
    library = pathlib.Path(argument).resolve() if argument else default_library(kind)
    return library.resolve(strict=True)


def main():
    release = resolve(sys.argv[1] if len(sys.argv) > 1 else None, 'release')
    gates_library = resolve(sys.argv[2] if len(sys.argv) > 2 else None, 'gates')
    EVIDENCE.mkdir(exist_ok=True)
    SCRATCH.mkdir(exist_ok=True)
    dart = ci_runtime.dart_binary()

    failures = []

    # 1. The native probe: the pinned QuickJS sources, no Dart in the way. Its
    # quantum is the pinned 10 000, so this file stays the baseline the product
    # rows are read against.
    native_executable = SCRATCH / f'native_probe{EXE}'
    build = run(probe_build('native_probe.c', native_executable, '-O1',
                            [QUICKJS / name for name in QUICKJS_SOURCES], QUICKJS), timeout=900)
    if build['exitCode'] != 0:
        raise SystemExit('native probe build failed:\n' + build['stderr'] + build['stdout'])
    probe = run([native_executable], timeout=900)
    (EVIDENCE / f'{PLATFORM}-native.json').write_text(probe['stdout'], encoding='utf-8')
    native = json.loads(probe['stdout'])
    failures += [f'native check failed: {name}' for name, ok in native['checks'].items() if not ok]

    # 2. The poll-quantum sensitivity table on patched copies of those sources.
    quantums = quantum_table()
    (EVIDENCE / f'{PLATFORM}-quantum.json').write_text(
        json.dumps({'note': 'Patched copies of the frozen vendored sources; the vendored '
                            'files themselves are unchanged, and the product build copy '
                            f'carries quantum {PRODUCT_QUANTUM}.',
                    'rows': quantums}, indent=2) + '\n', encoding='utf-8')

    # 3. The product probe: one process per case, so an uninterruptible execution is
    # recorded as a kill instead of hanging the run.
    product = {'library': str(release), 'cases': {}}
    for case in PRODUCT_CASES:
        result = run([dart, 'run', 'tool/runtime_limits_prototype/product_probe.dart',
                      release, case], timeout=CASE_TIMEOUTS.get(case, 120))
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
    (EVIDENCE / f'{PLATFORM}-product.json').write_text(json.dumps(product, indent=2) + '\n',
                                                       encoding='utf-8')

    # 4. The shared gate list on the same native build the app loads. The list
    # itself lives in tool/ci_runtime.py so the harness and CI cannot drift.
    gates = {}
    gate_log = []
    gate_output = SCRATCH / 'gates'
    shutil.rmtree(gate_output, ignore_errors=True)
    gate_output.mkdir(parents=True, exist_ok=True)
    for name, command in ci_runtime.gate_commands(dart, gates_library, gate_output):
        result = run(command, timeout=300)
        gates[name] = {'exitCode': result['exitCode'], 'timedOut': result['timedOut'],
                       'seconds': result['seconds']}
        gate_log.append(f'===== {name} (exit {result["exitCode"]}) =====\n'
                        f'{result["stdout"]}\n{result["stderr"]}\n')
        if result['exitCode'] != 0:
            failures.append(f'gate failed on this library: {name}')
    (EVIDENCE / 'gates.log').write_text(''.join(gate_log), encoding='utf-8')

    # 5. Provenance and the verdict.
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=ROOT, text=True).strip()

    def library_record(path):
        return {'path': str(path), 'sha256': sha256(path), 'bytes': path.stat().st_size,
                'mtime': time.strftime('%Y-%m-%dT%H:%M:%S',
                                       time.localtime(path.stat().st_mtime))}

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
        'productIsolateBlockedElapsedAfterUnblockMs':
            product['cases']['deadline-isolate-blocked']['measurements']['run']
            ['elapsedAfterUnblockMs'],
        'productRssGrowthOverHeapLimitBytes':
            product['cases']['memory-limit-alloc-loop']['measurements']['runs']['rssGrowthBytes'],
    }
    manifest = {
        'status': 'pass' if not failures else 'fail',
        'platform': PLATFORM,
        'scope': f'{PLATFORM} only; every other platform stays not-run until this file runs there',
        'recordedAt': time.strftime('%Y-%m-%dT%H:%M:%S%z'),
        'repositoryHead': git('rev-parse', 'HEAD'),
        'repositoryBranch': git('branch', '--show-current'),
        'uncommittedChanges': git('status', '--short').splitlines(),
        'libraries': {
            'release': library_record(release),
            'gates': library_record(gates_library),
        },
        'nativeProbe': {'path': str(native_executable), 'sha256': sha256(native_executable)},
        'engines': {'quickjs': native['engine'],
                    'rquickjsRevision': vendored_revision('rquickjs'),
                    'quickjsRevision': vendored_revision('QuickJS'),
                    'revisionSource': str(VENDOR_NOTES.relative_to(ROOT)).replace(os.sep, '/'),
                    'productPollQuantum': PRODUCT_QUANTUM,
                    'compiler': compiler_version()},
        'sourceHashes': [
            {'path': str(path.relative_to(ROOT)).replace('\\', '/'), 'sha256': sha256(path)}
            for path in [HERE / 'native_probe.c', HERE / 'quantum_probe.c',
                         HERE / 'product_probe.dart', HERE / 'verify.py',
                         ROOT / 'tool/ci_runtime.py']
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
