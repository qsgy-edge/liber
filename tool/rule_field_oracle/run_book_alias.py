"""Run only the precise bookName alias and source fallback against hash-checked existing frozen classes.

No downloads or recompilation of the frozen oracle. Only BookAliasOracle.kt is
compiled, serially with a 256 MB heap; all build outputs remain external.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
BASELINE = "14dd24945b2914ce2708b8abaa4ee67ceef892af"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--compiled", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--legado", type=Path, default=Path("D:/GithubRepositories/Android/legado"))
    args = parser.parse_args()
    compiled = args.compiled.resolve()
    out = args.output.resolve()
    assert not out.is_relative_to(ROOT), "Scratch must be external"
    out.mkdir(parents=True, exist_ok=True)
    original = compiled / "manifest.json"
    receipt = json.loads(original.read_text(encoding="utf-8"))
    versioned = json.loads((HERE / "evidence/review-host/manifest.json").read_text(encoding="utf-8"))
    assert Path(versioned.pop("receiptSource")).resolve() == original
    assert {k: v for k, v in receipt.items() if k not in {"compileCommand", "runCommand"}} == versioned, "Existing compiled oracle receipt must match its versioned binding"
    assert receipt["baseline"] == BASELINE
    for name, pin in receipt["frozenSourceSha256"].items():
        data = subprocess.check_output(["git", "-C", str(args.legado), "show", f"{BASELINE}:{name}"])
        assert hashlib.sha256(data).hexdigest() == pin, name
    for name, pin in receipt["compiledInputSha256"].items():
        path = (compiled if name.startswith("frozen") else ROOT) / name
        assert sha(path) == pin, name
    for name, pin in receipt["toolchainSha256"].items():
        assert sha(Path(name)) == pin, name
    classes = compiled / "classes"
    class_hashes = {str(p.relative_to(classes)): sha(p) for p in sorted(classes.rglob("*")) if p.is_file()}
    assert class_hashes, "Compiled frozen classes must exist"
    old = receipt["compileCommand"]
    compiler_cp = old[old.index("-cp") + 1]
    cp = old[old.index("-cp", old.index("-cp") + 1) + 1]
    target = out / "classes"
    target.mkdir(exist_ok=True)
    prefix = [old[0], "-Xms16m", "-Xmx256m", "-Dfile.encoding=UTF-8", "-cp"]
    compile_cmd = [*prefix, compiler_cp, "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler",
                   "-no-reflect", "-no-stdlib", "-jvm-target", "1.8", "-Xfriend-paths=" + str(classes), "-cp", str(classes) + ";" + cp,
                   "-d", str(target), str(HERE / "BookAliasOracle.kt")]
    run_cmd = [*prefix, str(target) + ";" + str(classes) + ";" + cp,
               "tool.rulefield.bookalias.BookAliasOracleKt", str(HERE / "book-alias-fixtures.json"), str(out / "golden.json")]
    exits = {}
    for name, command in [("compile", compile_cmd), ("run", run_cmd)]:
        result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        (out / f"{name}.log").write_bytes(result.stdout)
        exits[name] = result.returncode
        if result.returncode:
            print(result.stdout.decode("utf-8", errors="replace").encode("ascii", errors="backslashreplace").decode())
            raise RuntimeError(f"{name} exit {result.returncode}")
    manifest = {
        "baseline": BASELINE, "execution": "host-JVM; not device evidence",
        "compiledOracleManifestSha256": sha(original),
        "compiledClassSha256": class_hashes,
        "compiledInputSha256": receipt["compiledInputSha256"],
        "frozenSourceSha256": receipt["frozenSourceSha256"],
        "toolchainSha256": receipt["toolchainSha256"],
        "fixturesSha256": sha(HERE / "book-alias-fixtures.json"),
        "harnessSha256": sha(HERE / "BookAliasOracle.kt"),
        "runnerSha256": sha(Path(__file__)), "goldenSha256": sha(out / "golden.json"),
        "compileCommand": compile_cmd, "runCommand": run_cmd,
        "compileExit": exits["compile"], "runExit": exits["run"],
        "harnessClassSha256": {str(p.relative_to(target)): sha(p) for p in sorted(target.rglob("*")) if p.is_file()},
        "logSha256": {name: sha(out / name) for name in ["compile.log", "run.log"]},
        "observations": 2, "productComparableRows": 2,
        "frozenOnly": [], "deviceRows": "not-run",
        "limitations": "Actual compiled AnalyzeRule.get/BaseSource.get with preserved mutable Book name; no whole caller class, no new entity stub or storage protocol.",
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print((out / "run.log").read_text(encoding="utf-8").strip())


if __name__ == "__main__":
    main()
