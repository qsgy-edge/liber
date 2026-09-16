"""Run the ticket-#19 text-engine benchmark and record its evidence.

Usage:
  python tool/text_engine_prototype/verify.py [--library <fjs library>] [--inputs <dir>]

Writes, under this directory:

- `evidence/windows-text-engine.json` — every phase's own record, exactly as the
  harness and the Rust bench printed it.
- `evidence/manifest.json` — what the run was: commit, the native library's
  hash, each input's hash and size, each binary's hash, the host, and the
  findings the rows support.
- `evidence/gates.log` — the commands, in order, with their exit codes.

Inputs come from `make_inputs.py` (the 20 MB GBK and UTF-8 files) and from the
measurement session's `500mb.txt`; both live in the probe directory, not in the
repository. The Dart phases run one per process, because peak RSS is a process
number, and the Rust bench exists because a `dart run` process reports a
quarter of a gigabyte of Dart VM before the engine does anything.
"""
import argparse
import hashlib
import os
import json
import pathlib
import platform
import shutil
import subprocess
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parents[1]
EVIDENCE = HERE / 'evidence'
BENCH = HERE / 'text_engine_bench.dart'
RUST_BENCH = HERE / 'rust_bench'
DEFAULT_INPUTS = pathlib.Path('D:/liber-probe/text-engine')
DEFAULT_BIG = pathlib.Path('D:/liber-probe/500mb.txt')


def sha256(path):
    return hashlib.sha256(pathlib.Path(path).read_bytes()).hexdigest()


def run(command, log):
    started = time.time()
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    elapsed = time.time() - started
    log.write(f'$ {" ".join(str(part) for part in command)}\n')
    log.write(f'exit={result.returncode} wall={elapsed:.2f}s\n')
    if result.stdout:
        log.write(result.stdout if result.stdout.endswith('\n') else result.stdout + '\n')
    if result.stderr:
        log.write('stderr: ' + result.stderr)
    log.write('\n')
    log.flush()
    return result


def dart_phase(dart, library, phase, key, parameters, out, log):
    parameters_path = out.with_suffix('.params.json')
    parameters_path.write_text(json.dumps(parameters), encoding='utf-8')
    result = run(
        [dart, 'run', str(BENCH), library, phase, str(parameters_path), str(out)], log)
    if result.returncode != 0:
        raise SystemExit(f'phase {phase} failed (exit {result.returncode})')
    record = json.loads(out.read_text(encoding='utf-8'))
    record['key'] = key
    return record


def rust_phase(binary, phase, key, parameters, out, log):
    parameters_path = out.with_suffix('.params.json')
    parameters_path.write_text(json.dumps(parameters), encoding='utf-8')
    result = run([binary, phase, str(parameters_path), str(out)], log)
    if result.returncode != 0:
        raise SystemExit(f'rust phase {phase} failed (exit {result.returncode})')
    record = json.loads(out.read_text(encoding='utf-8'))
    record['key'] = key
    return record


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--library')
    parser.add_argument('--debug-library')
    parser.add_argument('--inputs', type=pathlib.Path, default=DEFAULT_INPUTS)
    parser.add_argument('--big', type=pathlib.Path, default=DEFAULT_BIG)
    arguments = parser.parse_args()

    library = pathlib.Path(arguments.library) if arguments.library else (
        ROOT / 'build/windows/x64/runner/Debug/fjs.dll')
    library = library.resolve(strict=True)
    debug_library = None
    if arguments.debug_library:
        debug_library = pathlib.Path(arguments.debug_library).resolve(strict=True)
    inputs = arguments.inputs.resolve(strict=True)
    big = arguments.big.resolve(strict=True)
    dart = shutil.which('dart')
    if dart is None:
        raise SystemExit('dart is not on PATH')
    # Windows reports the case it launched with, and the build-hooks runner
    # doubles an upper-case suffix; tool/ci_runtime.py normalizes the same way.
    if dart[-4:].lower() == '.exe':
        dart = dart[:-4] + '.exe'

    EVIDENCE.mkdir(exist_ok=True)
    scratch = inputs / 'bench'
    scratch.mkdir(exist_ok=True)
    rust_binary = RUST_BENCH / 'target/release' / (
        'rust_bench.exe' if platform.system() == 'Windows' else 'rust_bench')
    with (EVIDENCE / 'gates.log').open('w', encoding='utf-8') as log:
        run([
            'cargo', 'build', '--release', '--manifest-path', str(RUST_BENCH / 'Cargo.toml'),
        ], log)
    rust_binary = rust_binary.resolve(strict=True)
    gbk = inputs / 'engine-20mb-gbk.txt'
    utf8 = inputs / 'engine-20mb-utf8.txt'
    modern_tw = inputs / 'modern-tw.txt'
    modern_cn = inputs / 'modern-cn.txt'
    for required in (gbk, utf8, big, modern_tw, modern_cn):
        if not required.exists():
            raise SystemExit(f'{required} 不存在：先运行 make_inputs.py 和 fetch_corpus.py')

    records = []
    log_path = EVIDENCE / 'gates.log'

    def phase(key, record):
        record['key'] = key
        records.append(record)
        print(f"{key:<34} {record['elapsed_micros'] / 1000:>9.1f} ms  "
              f"peak {record['peak_rss_bytes']} B  baseline {record['baseline_rss_bytes']} B")
        return record

    # The engine alone: no Dart VM in the process, so the contract's
    # "peak RSS under ~50 MB for 500 MB" can be read off the row. Three runs per
    # row, because a 500 MB pass on a cold page cache is a different number from
    # a warm one, and the record says which is which by keeping all three.
    def engine(phase_name, key, parameters, repeats=3):
        for attempt in range(1, repeats + 1):
            phase(f'{key}#{attempt}', rust_phase(
                rust_binary, phase_name, key,
                parameters, scratch / f'rust-{key}-{attempt}.json', log))

    with log_path.open('w', encoding='utf-8') as log:
        run([
            'cargo', 'build', '--release', '--manifest-path', str(RUST_BENCH / 'Cargo.toml'),
        ], log)
        engine('index', 'rust-bench-index-500mb-utf8',
               {'path': str(big), 'stride': 32768,
                'anchors_out': str(scratch / 'rust-big-anchors.json')})
        engine('index', 'rust-bench-index-20mb-gbk',
               {'path': str(gbk), 'stride': 32768,
                'anchors_out': str(scratch / 'rust-20-anchors.json')})
        engine('index', 'rust-bench-index-20mb-utf8', {'path': str(utf8), 'stride': 32768})
        engine('window', 'rust-bench-window-500mb',
               {'path': str(big), 'encoding': 'UTF-8',
                'anchors_in': str(scratch / 'rust-big-anchors.json'),
                'offset': 100_000_000, 'max_code_units': 20000,
                'max_scan_bytes': 4 * 1024 * 1024})
        engine('window', 'rust-bench-window-20mb-gbk',
               {'path': str(gbk), 'encoding': 'GBK',
                'anchors_in': str(scratch / 'rust-20-anchors.json'),
                'offset': 5_000_000, 'max_code_units': 20000,
                'max_scan_bytes': 4 * 1024 * 1024})
        engine('convert', 'rust-bench-convert',
               {'traditional': str(modern_tw), 'simplified': str(modern_cn)})

        # The pure-Dart comparison the contract asks for. One run each: these are
        # tens of seconds, and the rows they replace were measured the same way.
        phase('dart-index-500mb-utf8', dart_phase(
            dart, str(library), 'dart-index', 'dart-index-500mb-utf8',
            {'path': str(big), 'stride': 32768}, scratch / 'dart-index-big.json', log))
        phase('dart-index-20mb-utf8', dart_phase(
            dart, str(library), 'dart-index', 'dart-index-20mb-utf8',
            {'path': str(utf8), 'stride': 32768}, scratch / 'dart-index-20utf8.json', log))
        phase('dart-byte-pass-20mb-gbk', dart_phase(
            dart, str(library), 'dart-bytes', 'dart-byte-pass-20mb-gbk',
            {'path': str(gbk), 'stride': 32768}, scratch / 'dart-bytes-20gbk.json', log))
        phase('dart-decode-20mb-gbk', dart_phase(
            dart, str(library), 'dart-decode', 'dart-decode-20mb-gbk',
            {'path': str(gbk)}, scratch / 'dart-decode-20gbk.json', log))
        phase('dart-read-string-20mb-gbk', dart_phase(
            dart, str(library), 'dart-read-string', 'dart-read-string-20mb-gbk',
            {'path': str(gbk)}, scratch / 'dart-read-string-20gbk.json', log))
        phase('dart-read-string-500mb-utf8', dart_phase(
            dart, str(library), 'dart-read-string', 'dart-read-string-500mb-utf8',
            {'path': str(big)}, scratch / 'dart-read-string-big.json', log))

        # The engine where the product calls it: through the bridge, in a Dart
        # process. The floor is the Dart VM, so these rows carry the delta. A
        # debug native library is what a `flutter run` debug build loads and it
        # is several times slower than a release one, so both are recorded.
        for label, candidate in (('release', library), ('debug', debug_library)):
            if candidate is None:
                continue
            path = str(candidate)
            phase(f'{label}-index-500mb-utf8', dart_phase(
                dart, path, 'rust-index', f'{label}-index-500mb-utf8',
                {'path': str(big), 'stride': 32768,
                 'anchors_out': str(scratch / f'{label}-big-anchors.json')},
                scratch / f'{label}-index-big.json', log))
            phase(f'{label}-index-20mb-gbk', dart_phase(
                dart, path, 'rust-index', f'{label}-index-20mb-gbk',
                {'path': str(gbk), 'stride': 32768,
                 'anchors_out': str(scratch / f'{label}-20-anchors.json')},
                scratch / f'{label}-index-20gbk.json', log))
            phase(f'{label}-window-500mb', dart_phase(
                dart, path, 'rust-window', f'{label}-window-500mb',
                {'path': str(big), 'encoding': 'UTF-8',
                 'anchors_in': str(scratch / f'{label}-big-anchors.json'),
                 'offset': 100_000_000, 'max_code_units': 20000,
                 'max_scan_bytes': 4 * 1024 * 1024},
                scratch / f'{label}-window-big.json', log))
            phase(f'{label}-window-20mb-gbk', dart_phase(
                dart, path, 'rust-window', f'{label}-window-20mb-gbk',
                {'path': str(gbk), 'encoding': 'GBK',
                 'anchors_in': str(scratch / f'{label}-20-anchors.json'),
                 'offset': 5_000_000, 'max_code_units': 20000,
                 'max_scan_bytes': 4 * 1024 * 1024},
                scratch / f'{label}-window-20gbk.json', log))
            phase(f'{label}-convert', dart_phase(
                dart, path, 'rust-convert', f'{label}-convert',
                {'traditional': str(modern_tw), 'simplified': str(modern_cn)},
                scratch / f'{label}-convert.json', log))

    payload = {
        'note': 'Ticket #19 benchmark: the Rust text engine against a pure-Dart '
                'streaming index over the same files. Read README.md next to this '
                'file for what each row means and how to re-run it.',
        'host': {
            'platform': platform.platform(),
            'machine': platform.machine(),
            'processor': platform.processor(),
            "cpus": os.cpu_count(),
            'python': platform.python_version(),
            'dart': subprocess.run([dart, '--version'], capture_output=True, text=True).stdout.strip(),
        },
        'records': records,
    }
    (EVIDENCE / 'windows-text-engine.json').write_text(
        json.dumps(payload, ensure_ascii=False, indent=1) + '\n',
        encoding='utf-8', newline='\n')

    inputs_manifest = json.loads((inputs / 'engine-20mb-manifest.json').read_text(encoding='utf-8'))
    corpus_manifest = json.loads((inputs / 'corpus-manifest.json').read_text(encoding='utf-8'))
    manifest = {
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'], text=True).strip(),
        'platform': platform.platform(),
        'library': str(library),
        'librarySha256': sha256(library),
        'debugLibrary': str(debug_library) if debug_library else None,
        'debugLibrarySha256': sha256(debug_library) if debug_library else None,
        'rustBench': {
            'path': str(rust_binary),
            'sha256': sha256(rust_binary),
        },
        'inputs': {
            **inputs_manifest['inputs'],
            '500mb.txt': {
                'bytes': big.stat().st_size,
                'encoding': 'UTF-8',
                'sha256': sha256(big),
            },
            'modern-tw.txt': {
                'bytes': modern_tw.stat().st_size,
                'sha256': sha256(modern_tw),
                'corpusManifestSha256': corpus_manifest['sources'][1]['sha256'],
            },
            'modern-cn.txt': {
                'bytes': modern_cn.stat().st_size,
                'sha256': sha256(modern_cn),
                'corpusManifestSha256': corpus_manifest['sources'][2]['sha256'],
            },
        },
        'findings': findings(records),
    }
    (EVIDENCE / 'manifest.json').write_text(
        json.dumps(manifest, ensure_ascii=False, indent=1) + '\n', encoding='utf-8', newline='\n')
    print(json.dumps(manifest['findings'], ensure_ascii=False, indent=1))


def findings(records):
    """What the rows support, in the words the ticket asks its question in."""
    import statistics

    def runs(prefix):
        return [record for record in records if record['key'].startswith(prefix)]

    def one(key):
        return next(record for record in records if record['key'] == key)

    def median_ms(prefix):
        return round(statistics.median(record['elapsed_micros'] for record in runs(prefix)) / 1000, 1)

    def best_ms(prefix):
        return round(min(record['elapsed_micros'] for record in runs(prefix)) / 1000, 1)

    def footprint_mb(prefix):
        record = runs(prefix)[-1]
        return round((record['peak_rss_bytes'] - record['baseline_rss_bytes']) / (1024 * 1024), 1)

    def peak_mb(prefix):
        return round(runs(prefix)[-1]['peak_rss_bytes'] / (1024 * 1024), 1)

    engine_index_500mb = median_ms('rust-bench-index-500mb-utf8#')
    engine_peak = peak_mb('rust-bench-index-500mb-utf8#')
    findings = {
        'engineAlone': {
            'index500mbUtf8MedianMs': engine_index_500mb,
            'index500mbUtf8BestMs': best_ms('rust-bench-index-500mb-utf8#'),
            'index500mbUtf8PeakRssMb': engine_peak,
            'index500mbUtf8FootprintMb': footprint_mb('rust-bench-index-500mb-utf8#'),
            'index20mbGbkMedianMs': median_ms('rust-bench-index-20mb-gbk#'),
            'index20mbGbkPeakRssMb': peak_mb('rust-bench-index-20mb-gbk#'),
            'index20mbUtf8MedianMs': median_ms('rust-bench-index-20mb-utf8#'),
            'window500mbMedianMs': median_ms('rust-bench-window-500mb#'),
            'window500mbFootprintMb': footprint_mb('rust-bench-window-500mb#'),
            'window20mbGbkMedianMs': median_ms('rust-bench-window-20mb-gbk#'),
            'convertMs': median_ms('rust-bench-convert#'),
            'capture': one('rust-bench-index-500mb-utf8#1'),
        },
        'pureDartStreamingIndex': {
            'index500mbUtf8Ms': one('dart-index-500mb-utf8')['elapsed_micros'] / 1000,
            'index500mbUtf8FootprintMb': (
                one('dart-index-500mb-utf8')['peak_rss_bytes']
                - one('dart-index-500mb-utf8')['baseline_rss_bytes']) / (1024 * 1024),
            'index20mbUtf8Ms': one('dart-index-20mb-utf8')['elapsed_micros'] / 1000,
            'bytePass20mbGbkMs': one('dart-byte-pass-20mb-gbk')['elapsed_micros'] / 1000,
            'decode20mbGbkReplacementCharacters': one('dart-decode-20mb-gbk')
            .get('replacement_characters'),
            'readString20mbGbkError': one('dart-read-string-20mb-gbk').get('error', ''),
            'readString500mbUtf8Ms': one('dart-read-string-500mb-utf8')['elapsed_micros'] / 1000,
            'readString500mbUtf8FootprintMb': (
                one('dart-read-string-500mb-utf8')['peak_rss_bytes']
                - one('dart-read-string-500mb-utf8')['baseline_rss_bytes']) / (1024 * 1024),
        },
        'throughTheBridge': {
            'releaseIndex500mbUtf8Ms': one('release-index-500mb-utf8')['elapsed_micros'] / 1000,
            'releaseIndex500mbUtf8FootprintMb': (
                one('release-index-500mb-utf8')['peak_rss_bytes']
                - one('release-index-500mb-utf8')['baseline_rss_bytes']) / (1024 * 1024),
            'releaseWindow500mbMs': one('release-window-500mb')['elapsed_micros'] / 1000,
            'releaseConvertMs': one('release-convert')['elapsed_micros'] / 1000,
        },
        'contractTargets': {
            'passUnderOneSecond500mb': engine_index_500mb < 1000,
            'peakUnderFiftyMegabytes500mb': engine_peak < 50,
        },
    }
    if runs('debug-index-500mb-utf8'):
        findings['throughTheBridge']['debugIndex500mbUtf8Ms'] = (
            one('debug-index-500mb-utf8')['elapsed_micros'] / 1000)
        findings['throughTheBridge']['dartDebugVsReleaseFactor'] = round(
            findings['throughTheBridge']['debugIndex500mbUtf8Ms']
            / findings['throughTheBridge']['releaseIndex500mbUtf8Ms'], 1)
    findings['pureDartVsEngine'] = {
        'index500mbFactor': round(
            findings['pureDartStreamingIndex']['index500mbUtf8Ms'] / engine_index_500mb, 1),
        'index500mbFootprintFactor': round(
            findings['pureDartStreamingIndex']['index500mbUtf8FootprintMb']
            / max(findings['engineAlone']['index500mbUtf8FootprintMb'], 0.1), 1),
        'readAsStringVsEngineFactor': round(
            findings['pureDartStreamingIndex']['readString500mbUtf8Ms'] / engine_index_500mb, 1),
    }
    return findings


if __name__ == '__main__':
    sys.exit(main())
