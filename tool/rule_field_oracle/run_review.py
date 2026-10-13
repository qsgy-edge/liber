"""Execute frozen typed rule-field callers and export the pinned HTML4 table.

No downloads. Inputs are verified read-only #105 preparation artifacts and pinned
JSONPath jars; all compile/run scratch and receipts are external to the repo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

BASELINE = "14dd24945b2914ce2708b8abaa4ee67ceef892af"
ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
SHARED = ROOT / "tool/html_content_oracle"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def command(args, log):
    result = subprocess.run([str(a) for a in args], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_bytes(result.stdout)
    if result.returncode:
        print(result.stdout.decode("utf-8", errors="replace").encode("ascii", errors="backslashreplace").decode())
        raise RuntimeError(f"exit {result.returncode}; see {log}")
    return result.stdout


def main():
    parser = argparse.ArgumentParser(__doc__)
    parser.add_argument("--inputs", required=True, type=Path)
    parser.add_argument("--jars", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--legado", type=Path, default=Path("D:/GithubRepositories/Android/legado"))
    parser.add_argument("--export-dart", type=Path)
    args = parser.parse_args()
    out = args.output.resolve()
    if out.is_relative_to(ROOT):
        raise ValueError("Compile scratch/receipts must be external")
    out.mkdir(parents=True, exist_ok=True)
    receipt = json.loads((args.inputs / "manifest.json").read_text(encoding="utf-8"))
    assert receipt["frozenCommit"] == BASELINE
    for kind, folder in [("sourceFiles", "sources"), ("stubFiles", "stubs")]:
        for name, pin in receipt[kind].items():
            assert sha(args.inputs / folder / name) == pin, name
    for name, pin in receipt["toolchain"].items():
        assert sha(Path(name)) == pin, name
    sources = []
    hashes = {}
    names = list(receipt["sourceFiles"]) + [
        "app/src/main/java/io/legado/app/model/analyzeRule/AnalyzeByJSonPath.kt",
        "app/src/main/java/io/legado/app/utils/NetworkUtils.kt",
        "app/src/main/java/io/legado/app/utils/StringExtensions.kt",
        "app/src/main/java/io/legado/app/utils/MapExtensions.kt",
        "app/src/main/java/io/legado/app/utils/GsonExtensions.kt",
        "app/src/main/java/io/legado/app/model/webBook/BookInfo.kt",
        "app/src/main/java/io/legado/app/model/webBook/BookList.kt",
    ]
    for name in names:
        data = subprocess.check_output(["git", "-C", str(args.legado), "show", f"{BASELINE}:{name}"])
        if name in receipt["sourceFiles"]:
            assert hashlib.sha256(data).hexdigest() == receipt["sourceFiles"][name], name
        p = out / "frozen" / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        hashes[name] = sha(p)
        if name.endswith(".kt") and "/utils/" not in name and "/webBook/" not in name:
            sources.append(p)
    # Helpers used for mode and URL decisions must match the object-derived bodies.
    normalize = lambda s: " ".join(s.split())
    utils = (SHARED / "stubs/utils.kt").read_text(encoding="utf-8")
    for start, end, name in [
        ("inline fun <K, V>", "/** `StringExtensions", "MapExtensions.kt"),
        ("fun String?.isJson()", "/** `StringExtensions.kt:81", "StringExtensions.kt"),
    ]:
        snippet = utils[utils.index(start):utils.index(end, utils.index(start))].strip()
        frozen = next((out / "frozen").rglob(name)).read_text(encoding="utf-8")
        assert normalize(snippet) in normalize(frozen), name
    # The URL helper is the existing frozen transcription, not a canned answer.
    url_helpers = (SHARED / "FrozenContentStubs.kt").read_text(encoding="utf-8")
    network = next((out / "frozen").rglob("NetworkUtils.kt")).read_text(encoding="utf-8")
    body = url_helpers[url_helpers.index("fun getAbsoluteURL"):url_helpers.index("\n}\n")]
    body = body.replace("// AppLog.put(\"网址拼接出错\\n${e.localizedMessage}\", e) — Android's log.", 'AppLog.put("网址拼接出错\\n${e.localizedMessage}", e)')
    assert normalize(body) in normalize(network), "NetworkUtils helper mismatch"
    sources += sorted(p for p in (SHARED / "stubs").glob("*.kt") if p.name not in {"analysis.kt", "jsoup_node.kt", "utils.kt"})
    sources += [SHARED / "FrozenContentStubs.kt", HERE / "FrozenValueUtils.kt", HERE / "UnreachedXPath.kt", HERE / "ReviewOracle.kt"]
    value_utils = (HERE / "FrozenValueUtils.kt").read_text(encoding="utf-8")
    generic = value_utils[value_utils.index('inline fun <reified T> genericType()'):value_utils.index('/** `MapExtensions.kt:21-33`')].strip()
    assert normalize(generic) in normalize(next((out / "frozen").rglob('GsonExtensions.kt')).read_text(encoding="utf-8"))
    jars = []
    for pins in [SHARED / "jars.sha256", ROOT / "tool/jsonpath_probe/jars.sha256"]:
        for line in pins.read_text(encoding="utf-8").splitlines():
            pin, name = line.split()
            p = args.jars / name.lstrip("*")
            assert sha(p) == pin, p
            jars.append(p)
    for download in receipt["downloads"]:
        p = args.jars / download["url"].rsplit("/", 1)[1]
        assert sha(p) == download["sha256"], p
        jars.append(p)
    old = receipt["compileCommand"]
    java = Path(old[0])
    compiler_cp = old[old.index("-cp") + 1]
    cp_paths = [Path(p) for p in old[old.index("-cp", old.index("-cp") + 1) + 1].split(";") if "/jars/" not in p.replace("\\", "/")]
    cp_paths += jars
    cp = ";".join(map(str, cp_paths))
    classes = out / "classes"
    classes.mkdir(exist_ok=True)
    compile_cmd = [java, "-Xms16m", "-Xmx256m", "-Dfile.encoding=UTF-8", "-cp", compiler_cp,
                   "org.jetbrains.kotlin.cli.jvm.K2JVMCompiler", "-no-reflect", "-no-stdlib",
                   "-jvm-target", "1.8", "-cp", cp, "-d", classes, *sources]
    command(compile_cmd, out / "compile.log")
    run_cmd = [java, "-Xms16m", "-Xmx256m", "-Dfile.encoding=UTF-8", "-cp", str(classes) + ";" + cp,
               "tool.rulefield.ReviewOracleKt", HERE / "review-fixtures.json", out / "golden.json", out / "entities.json"]
    result = command(run_cmd, out / "run.log")
    exported = json.loads((out / "entities.json").read_text(encoding="utf-8"))
    assert len(exported) == 252 and all(len(v) == 1 for v in exported.values())
    dart = "// Generated by tool/rule_field_oracle/run_review.py from commons-text 1.13.0.\n// Do not edit: HTML4 lookup data, pinned to the frozen dependency.\nconst html4Entities = <String, String>{\n"
    dart += "".join(f"  '{name}': '\\u{units[0]:04x}',\n" for name, units in exported.items())
    dart += "};\n"
    (out / "html4_entities.dart").write_text(dart, encoding="utf-8", newline="\n")
    if args.export_dart:
        args.export_dart.write_text(dart, encoding="utf-8", newline="\n")
    manifest = {
        "baseline": BASELINE, "execution": "host-JVM; not device evidence",
        "frozenSourceSha256": hashes,
        "compiledInputSha256": {str(p.relative_to(out) if p.is_relative_to(out) else p.relative_to(ROOT)): sha(p) for p in sources},
        "toolchainSha256": {str(p): sha(p) for p in [java, *map(Path, compiler_cp.split(";")), *cp_paths]},
        "fixturesSha256": sha(HERE / "review-fixtures.json"), "harnessSha256": sha(HERE / "ReviewOracle.kt"),
        "runnerSha256": sha(Path(__file__)), "goldenSha256": sha(out / "golden.json"),
        "entityExportSha256": sha(out / "entities.json"), "entityDartSha256": sha(out / "html4_entities.dart"),
        "compileCommand": list(map(str, compile_cmd)), "runCommand": list(map(str, run_cmd)),
        "compileExit": 0, "runExit": 0, "deviceRows": "not-run",
        "notCompared": [{"name": "native-array-scalar", "reason": "NativeArray Java toString includes JVM object identity; both actual observations retained, not normalized."}],
        "limitations": "Actual JSoup/JSONPath paths and typed content execute. XPath/network/device paths remain fail-closed or outside corpus. Entity/variable stubs supply bounded unused services; no platform parity claimed.",
    }
    (out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(result.decode().strip())


if __name__ == "__main__":
    main()
