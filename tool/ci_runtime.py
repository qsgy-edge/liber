"""Run existing desktop gates with per-command logs and actual input hashes."""
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


def main():
    if len(sys.argv) != 3 or sys.argv[1] not in ('windows', 'linux', 'macos'):
        raise SystemExit('Usage: python tool/ci_runtime.py <windows|linux|macos> <rust-target>')
    platform, target = sys.argv[1:]
    library = (pathlib.Path('build/windows/x64/runner/Debug/fjs.dll') if platform == 'windows'
               else pathlib.Path('packages/fjs/libfjs/target') / target / 'debug' /
               ('libfjs.dylib' if platform == 'macos' else 'libfjs.so'))
    library = library.resolve(strict=True)
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
    output = pathlib.Path('.ci-results')
    shutil.rmtree(output, ignore_errors=True)
    output.mkdir(exist_ok=True)
    gates = ['runtime_gate', 'runtime_host_integration', 'host_surface_gate',
             'broker_lifecycle_regression', 'broker_loader_regression']
    commands = [(name, [dart, 'run', f'tool/{name}.dart', str(library)]) for name in gates]
    # The HTML adapter corpus is platform-independent: the same rows run wherever
    # the native library builds, so each destination platform records its own row.
    commands += [('html-adapter', [dart, 'run', 'tool/html_adapter_gate.dart', str(library), '-',
                                   str(output / 'html-adapter.json')])]
    broker_modes = ['queued-close', 'throw-start', 'throw-cancel', 'same-runtime-nested',
                    'same-runtime-queued-release', 'same-runtime-cancel']
    commands += [(f'broker_gate_regression-{mode}',
                  [dart, 'run', 'tool/broker_gate_regression.dart', str(library), mode])
                 for mode in broker_modes]
    if platform == 'windows':
        windows_gates = ['fiber_runtime_gate', 'scoped_runtime_gate', 'nested_runtime_gate']
        commands += [(name, [dart, 'run', f'tool/{name}.dart', str(library)])
                     for name in windows_gates]
        golden = 'tool/nested_oracle/evidence/android-17-os4.0.0.25/'
        commands += [
            ('state-differential', [dart, 'run', 'tool/state_oracle_compare.dart', str(library),
                                    golden + 'state-expanded-golden.json', str(output / 'state.json')]),
            ('nested-differential', [dart, 'run', 'tool/nested_oracle_compare.dart', str(library),
                                     golden + 'golden.json', str(output / 'nested.json')]),
        ]
    manifest = {'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
                'platform': platform, 'target': target,
                'librarySha256': hashlib.sha256(library.read_bytes()).hexdigest(),
                'results': []}
    failed = False
    for name, command in commands:
        log_path = output / (name + '.log')
        with log_path.open('w', encoding='utf-8') as log:
            try:
                result = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                        timeout=120, check=False)
                code = result.returncode
            except subprocess.TimeoutExpired:
                code = 124
                log.write('\nCI command timed out after 120 seconds.\n')
        crash = CRASH_MARKER in log_path.read_text(encoding='utf-8', errors='replace')
        if crash:
            code = 1
        manifest['results'].append({'name': name, 'command': command, 'exitCode': code,
                                   'dartVmCrashInLog': crash,
                                   'scriptSha256': hashlib.sha256(pathlib.Path(command[2]).read_bytes()).hexdigest()})
        failed |= code != 0
        if crash:
            print(f'{name}: Dart VM crash marker in log', flush=True)
        print(f'{name}: exit {code}', flush=True)
        if code:
            print(log_path.read_text(encoding='utf-8', errors='replace')[-8000:])
        (output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    return int(failed)


if __name__ == '__main__':
    sys.exit(main())
