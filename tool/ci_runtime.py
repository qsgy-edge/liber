"""Run the shared desktop gates with per-command logs and actual input hashes.

One list runs on Windows, Linux and macOS; only the native library differs.
`tool/runtime_limits_prototype/verify.py` imports `gate_commands` so the limits
harness and CI cannot drift apart.
"""
import hashlib
import json
import pathlib
import shutil
import subprocess
import sys

# The Dart VM prints this header when it reports a native fault. A crashed
# process can still exit 0 when the fault happens on a non-isolate thread
# during teardown, so the marker itself fails the gate.
CRASH_MARKER = '===== CRASH ====='

# Rows that assert the shared runtime, host surface, broker and the HTML
# adapter. Every desktop platform runs all of them through the same
# platform-neutral execution model (ADR 0009).
SHARED_GATES = [
    'runtime_gate',
    'runtime_host_integration',
    'host_surface_gate',
    'broker_lifecycle_regression',
    'broker_loader_regression',
    'scoped_runtime_gate',
    'nested_runtime_gate',
]
BROKER_MODES = ['queued-close', 'throw-start', 'throw-cancel', 'same-runtime-nested',
                'same-runtime-queued-release', 'same-runtime-cancel']
# The frozen APK's executed golden; the two differential rows compare the
# destination against it on every desktop platform.
ORACLE_GOLDEN = 'tool/nested_oracle/evidence/android-17-os4.0.0.25/'


def dart_binary():
    """The `dart` interpreter, with the spelling trap below repaired."""
    dart = shutil.which('dart')
    if dart is None:
        raise SystemExit('dart is not on PATH')
    # Windows reports the case it launched with in Platform.resolvedExecutable,
    # and the Dart build-hooks runner appends '.exe' unless that path already
    # ends with those exact three characters. shutil.which builds its result
    # from PATHEXT, whose suffix is upper case, so the runner asks for
    # 'dart.EXE.exe' and every gate dies inside the sqlite3 hook. Restore the
    # suffix's spelling before the gates see it.
    if dart[-4:].lower() == '.exe':
        dart = dart[:-4] + '.exe'
    return dart


def library_path(platform, target):
    """The native library the gates load on this platform."""
    if platform == 'windows':
        candidates = [pathlib.Path('build/windows/x64/runner/Debug/fjs.dll')]
    else:
        name = 'libfjs.dylib' if platform == 'macos' else 'libfjs.so'
        candidates = [pathlib.Path('packages/fjs/libfjs/target') / target / 'debug' / name,
                      pathlib.Path('packages/fjs/libfjs/target') / 'debug' / name]
    for candidate in candidates:
        if candidate.exists():
            return candidate.resolve()
    raise SystemExit(f'no native library for {platform}/{target}: tried '
                     + ', '.join(str(candidate) for candidate in candidates))


def gate_commands(dart, library, output):
    """The one row list every desktop platform runs, with its own library."""
    commands = [(name, [dart, 'run', f'tool/{name}.dart', str(library)])
                for name in SHARED_GATES]
    # The HTML adapter corpus is platform-independent: the same rows run wherever
    # the native library builds, so each destination platform records its own row.
    commands += [('html-adapter', [dart, 'run', 'tool/html_adapter_gate.dart', str(library), '-',
                                   str(output / 'html-adapter.json')])]
    commands += [(f'broker_gate_regression-{mode}',
                  [dart, 'run', 'tool/broker_gate_regression.dart', str(library), mode])
                 for mode in BROKER_MODES]
    commands += [
        ('state-differential', [dart, 'run', 'tool/state_oracle_compare.dart', str(library),
                                ORACLE_GOLDEN + 'state-expanded-golden.json',
                                str(output / 'state.json')]),
        ('nested-differential', [dart, 'run', 'tool/nested_oracle_compare.dart', str(library),
                                 ORACLE_GOLDEN + 'golden.json', str(output / 'nested.json')]),
    ]
    return commands


def run_commands(commands, output, manifest, timeout=120):
    """Runs one row at a time, logging each and appending to the manifest."""
    failed = False
    for name, command in commands:
        log_path = output / (name + '.log')
        with log_path.open('w', encoding='utf-8') as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=timeout, check=False)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
                log.write(f'\nCI command timed out after {timeout} seconds.\n')
        crash = CRASH_MARKER in log_path.read_text(encoding='utf-8', errors='replace')
        if crash:
            code = 1
        manifest['results'].append({'name': name, 'command': command, 'exitCode': code,
                                   'dartVmCrashInLog': crash,
                                   'scriptSha256': hashlib.sha256(
                                       pathlib.Path(command[2]).read_bytes()).hexdigest()})
        failed |= code != 0
        if crash:
            print(f'{name}: Dart VM crash marker in log', flush=True)
        print(f'{name}: exit {code}', flush=True)
        if code:
            print(log_path.read_text(encoding='utf-8', errors='replace')[-8000:])
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return failed


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('windows', 'linux', 'macos'):
        raise SystemExit('Usage: python tool/ci_runtime.py <windows|linux|macos> <rust-target>')
    platform, target = sys.argv[1:]
    library = library_path(platform, target)
    dart = dart_binary()
    output = pathlib.Path('.ci-results')
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(exist_ok=True)
    manifest = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                'platform': platform, 'target': target,
                'librarySha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                'rows': [name for name, _ in gate_commands(dart, library, output)],
                'results': []}
    return int(run_commands(gate_commands(dart, library, output), output, manifest))


if __name__ == '__main__':
    sys.exit(main())
