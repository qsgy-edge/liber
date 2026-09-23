"""Record the app a platform's build step produced as a row in `.ci-results/`.

Usage: python tool/ci_build_row.py <windows|linux|macos|android|ios>

The row names what the build produced, so the uploaded `evidence-<platform>`
artifact records the artifact itself (path, sha256, bytes) instead of leaving it
in a log. `tool/ci_runtime.py` keeps running the shared gate rows and gains no
build rows: a build in that list would build the app a second time.

CI runs this after the runtime gates, because `tool/ci_runtime.py` recreates
`.ci-results/` when it starts — a row written by the build step itself would be
deleted before the artifact upload.

The module is written for the five GitHub runner hosts: paths are recorded with
forward slashes and the row is plain JSON.
"""
import hashlib
import json
import pathlib
import subprocess
import sys

# platform -> (the build command, the file whose hash identifies the build, the
# app package directory around it or None when the artifact is the package).
BUILDS = {
    'windows': ('flutter build windows --debug --no-pub',
                'build/windows/x64/runner/Debug/liber.exe',
                'build/windows/x64/runner/Debug'),
    'linux': ('flutter build linux --debug --no-pub',
              'build/linux/x64/debug/bundle/liber',
              'build/linux/x64/debug/bundle'),
    'macos': ('flutter build macos --debug --no-pub',
              'build/macos/Build/Products/Debug/liber.app/Contents/MacOS/liber',
              'build/macos/Build/Products/Debug/liber.app'),
    'android': ('flutter build apk --debug --no-pub',
                'build/app/outputs/flutter-apk/app-debug.apk',
                None),
    'ios': ('flutter build ios --simulator --no-codesign --no-pub',
            'build/ios/iphonesimulator/Runner.app/Runner',
            'build/ios/iphonesimulator/Runner.app'),
}

OUTPUT = pathlib.Path('.ci-results')


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in BUILDS:
        raise SystemExit('Usage: python tool/ci_build_row.py <'
                         + '|'.join(BUILDS) + '>')
    platform = sys.argv[1]
    command, artifact_name, package_name = BUILDS[platform]
    artifact = pathlib.Path(artifact_name)
    if not artifact.is_file():
        raise SystemExit(f'{platform}: no built app at {artifact_name}')
    if package_name is not None and not pathlib.Path(package_name).is_dir():
        raise SystemExit(f'{platform}: no app package at {package_name}')
    OUTPUT.mkdir(exist_ok=True)
    row = {
        'platform': platform,
        'command': command,
        'buildMode': 'debug',
        'commit': subprocess.check_output(['git', 'rev-parse', 'HEAD'],
                                          text=True).strip(),
        'artifact': {
            'path': artifact.as_posix(),
            'sha256': hashlib.sha256(artifact.read_bytes()).hexdigest(),
            'bytes': artifact.stat().st_size,
        },
        'package': package_name,
    }
    path = OUTPUT / f'{platform}-app-build.json'
    path.write_text(json.dumps(row, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(row, indent=2), flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
