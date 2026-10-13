"""Bounded host-JVM classification oracle; all frozen inputs come from Git objects.

No downloads. Reuses the existing content oracle's compile-only stubs and pinned
jars. Outputs/compile scratch must be outside the repository. Not a device run.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess

BASELINE = "14dd24945b2914ce2708b8abaa4ee67ceef892af"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SHARED = ROOT / "tool/html_content_oracle"


def run(args):
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    if result.returncode:
        print(result.stdout.decode("utf-8", errors="replace"))
        raise RuntimeError(f"Command failed ({result.returncode}): {args[0]}")
    return result.stdout


def digest(path, algorithm="sha256"):
    return hashlib.new(algorithm, path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--legado", type=Path, default=Path("D:/GithubRepositories/Android/legado"))
    parser.add_argument("--jars", type=Path, required=True)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.is_relative_to(ROOT):
        raise ValueError("Evidence and compile scratch must be outside the repo")
    out.mkdir(parents=True, exist_ok=True)
    frozen = out / "frozen"
    sources = []
    hashes = {}
    for line in (SHARED / "replace-frozen.sha1").read_text(encoding="utf-8").splitlines():
        _, name = line.split(None, 1)
        # The older pins describe CRLF worktree bytes. Our authority is the
        # immutable object, so materialize LF object bytes and hash those.
        data = run(["git", "-C", args.legado, "show", f"{BASELINE}:{name}"])
        target = frozen / name
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data)
        hashes[name] = hashlib.sha256(data).hexdigest()
        if name.startswith("modules/rhino/") or name.endswith(("AnalyzeRule.kt", "RuleDataInterface.kt", "AnalyzeByRegex.kt", "AppPattern.kt")):
            sources.append(target)
    # This source is cited for navigation; AnalyzeRule is the actual decider.
    name = "app/src/main/java/io/legado/app/model/analyzeRule/RuleAnalyzer.kt"
    data = run(["git", "-C", args.legado, "show", f"{BASELINE}:{name}"])
    (frozen / name).write_bytes(data)
    hashes[name] = hashlib.sha256(data).hexdigest()
    # Check the reached helper transcriptions against the frozen bytes.
    utils = (SHARED / "stubs/utils.kt").read_text(encoding="utf-8")
    normalize = lambda s: " ".join(s.split())
    for start, end, name in [
        ("inline fun <K, V>", "/** `StringExtensions", "MapExtensions.kt"),
        ("fun String?.isJson()", "/** `StringExtensions.kt:81", "StringExtensions.kt"),
    ]:
        snippet = utils[utils.index(start):utils.index(end, utils.index(start))].strip()
        path = next(p for p in hashes if p.endswith(name))
        if normalize(snippet) not in normalize((frozen / path).read_text(encoding="utf-8")):
            raise ValueError(f"Helper transcription mismatch: {name}")
    cache = Path.home() / ".gradle/caches/modules-2/files-2.1"

    def jar(module, pattern):
        matches = sorted((cache / module).glob(f"*/*/{pattern}"))
        if not matches:
            raise FileNotFoundError(f"No {pattern} in {cache / module}")
        return matches[-1]

    kc = jar("org.jetbrains.kotlin/kotlin-compiler-embeddable", "kotlin-compiler-embeddable-2*.jar")
    stdlib = jar("org.jetbrains.kotlin/kotlin-stdlib", "kotlin-stdlib-2*.jar")
    reflect = jar("org.jetbrains.kotlin/kotlin-reflect", "kotlin-reflect-2*.jar")
    coroutines = jar("org.jetbrains.kotlinx/kotlinx-coroutines-core-jvm", "*.jar")
    trove = jar("org.jetbrains.intellij.deps/trove4j", "*.jar")
    annotations = jar("org.jetbrains/annotations", "*.jar")
    gson = jar("com.google.code.gson/gson", "*.jar")
    okio = jar("com.squareup.okio/okio-jvm", "*.jar")
    androidx = jar("androidx.annotation/annotation-jvm", "*.jar")
    pinned = []
    for line in (SHARED / "jars.sha256").read_text(encoding="utf-8").splitlines():
        expected, name = line.split(None, 1)
        path = args.jars / name.strip().lstrip("*")
        if digest(path) != expected:
            raise ValueError(f"Jar pin mismatch: {path}")
        pinned.append(path)
    java = Path(os.environ["LOCALAPPDATA"]) / "Programs/Android Studio/jbr/bin/java.exe"
    sdk = os.environ.get("ANDROID_HOME") or os.environ.get("ANDROID_SDK_ROOT")
    if not sdk:
        for line in (ROOT / "android/local.properties").read_text(encoding="utf-8").splitlines():
            if line.startswith("sdk.dir="):
                sdk = line[8:].replace("\\\\", "/").replace("\\:", ":")
    android = Path(sdk) / "platforms/android-35/android.jar"
    cp = [stdlib, gson, android, coroutines, okio, androidx, *pinned]
    compiler_cp = [kc, stdlib, reflect, coroutines, trove, annotations]
    sources.extend(sorted((SHARED / "stubs").glob("*.kt")))
    sources.append(SHARED / "FrozenContentStubs.kt")
    sources.append(HERE / "RuleFieldOracle.kt")
    classes = out / "classes"
    classes.mkdir(exist_ok=True)
    command = [java, "-Dfile.encoding=UTF-8", "-cp", ";".join(map(str, compiler_cp)),
               "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-reflect", "-no-stdlib",
               "-jvm-target", "1.8", "-cp", ";".join(map(str, cp)), "-d", classes, *sources]
    (out / "compile.log").write_bytes(run(command))
    command = [java, "-Dfile.encoding=UTF-8", "-cp", ";".join(map(str, [classes, *cp])),
               "tool.rulefield.RuleFieldOracleKt", HERE / "fixtures.json", out / "golden.json"]
    result = run(command)
    (out / "run.log").write_bytes(result)
    manifest = {
        "baseline": BASELINE, "provenance": "host JVM; NOT Android/device extraction evidence",
        "frozenSourceSha256": hashes,
        "compiledInputSha256": {str(p): digest(p) for p in sources},
        "toolchainSha256": {str(p): digest(p) for p in [*compiler_cp, *cp, java]},
        "jvm": run([java, "-version"]).decode(),
        "fixturesSha256": digest(HERE / "fixtures.json"),
        "harnessSha256": digest(HERE / "RuleFieldOracle.kt"),
        "runnerSha256": digest(Path(__file__)), "goldenSha256": digest(out / "golden.json"),
        "command": command and "python tool/rule_field_oracle/run.py --output <external-dir> --jars <pinned-dir>",
        "limitation": "ExtractionAnswer has no declared answer; any extraction is a named failure. Only mode/value classification is proven.",
        "deviceRows": "not-run",
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(result.decode().strip())


if __name__ == "__main__":
    main()
