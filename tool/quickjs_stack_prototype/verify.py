"""Throwaway native-fiber verifier; real loopback HTTP, no product bindings."""
import argparse
import hashlib
import http.server
import json
import pathlib
import queue
import subprocess
import threading

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
parser = argparse.ArgumentParser()
parser.add_argument("executable")
parser.add_argument("--output", default=str(HERE / "evidence" / "windows.json"))
parser.add_argument("--without-frame-restore", action="store_true")
args = parser.parse_args()
fixture = json.loads((ROOT / "tool/nested_oracle/state-fixtures.json").read_text())
golden_path = ROOT / "tool/nested_oracle/evidence/android-17-os4.0.0.25/state-expanded-golden.json"
golden = json.loads(golden_path.read_text())
requests = []
arrivals, releases = {}, {}
lock = threading.Lock()

class Replay(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            requests.append("GET " + self.path)
            arrivals.setdefault(self.path, threading.Event()).set()
            release = releases.setdefault(self.path, threading.Event())
        if not release.wait(8):
            return
        body = b"__trace__" if self.path.startswith("/trace-") else b"ok"
        try:
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
            pass
    def log_message(self, *unused):
        pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Replay)
server.daemon_threads = False
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
origin = f"http://127.0.0.1:{server.server_port}"
command = [args.executable, str(server.server_port)]
if args.without_frame_restore:
    command.append("without-frame-restore")
process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                           stderr=subprocess.PIPE, text=True, encoding="utf-8")
events, errors, transcript = queue.Queue(), [], []
def drain_stdout():
    for line in process.stdout:
        transcript.append(line.rstrip())
        try:
            events.put(json.loads(line))
        except json.JSONDecodeError:
            events.put({"type": "invalid-json", "line": line})
    events.put({"type": "eof", "exit": process.poll()})
def drain_stderr():
    errors.extend(process.stderr)
stdout_thread = threading.Thread(target=drain_stdout, daemon=True)
stderr_thread = threading.Thread(target=drain_stderr, daemon=True)
stdout_thread.start()
stderr_thread.start()
checks, values = {}, {}
def event(kind):
    found = events.get(timeout=6)
    if found["type"] != kind:
        raise AssertionError((kind, found, errors[-3:]))
    return found
def send(text):
    process.stdin.write(text + "\n")
    process.stdin.flush()
def start(identifier, code, waiting=False, duration=0):
    send(f"start\t{identifier}\t{duration}\t{json.dumps(code.replace('$ORIGIN', origin))}")
    return event("waiting" if waiting else "done")
def drop(identifier):
    send(f"drop\t{identifier}"); event("dropped")
def run(code):
    result = start(0, code)
    drop(0)
    if result["error"] or result["cancelled"]:
        raise AssertionError(result)
    return result["value"]
def hold(identifier, code, path, duration=0):
    with lock:
        arrivals[path], releases[path] = threading.Event(), threading.Event()
    start(identifier, code, waiting=True, duration=duration)
    if not arrivals[path].wait(5):
        raise AssertionError("Request not observed: " + path)
def release(path):
    releases[path].set()
def resume(identifier, cancelled=False):
    send(f"{'cancel' if cancelled else 'resume'}\t{identifier}")
    result = event("done")
    drop(identifier)
    return result

def gc():
    send("gc"); event("gc")

failure = None
try:
    event("ready")
    run(fixture["library"] + "\nstate.n")
    hold(1, fixture["first"], "/hold")
    second = start(2, fixture["second"])
    values["secondCompletedWhileFirstHeld"] = not second["error"]
    values["secondResult"] = second["value"]
    drop(2)
    release("/hold")
    values["firstResult"] = resume(1)["value"]
    values["concurrentFinalState"] = run(fixture["read"])
    hold(1, fixture["early"], "/early")
    hold(2, fixture["late"], "/late")
    release("/early")
    first = resume(1)
    values["firstCompletesWhileSecondHeld"] = not first["error"] and not releases["/late"].is_set()
    release("/late"); resume(2)
    hold(1, fixture["cancel"], "/entered", duration=100)
    release("/entered")
    cancelled = resume(1)
    checks["frozenCancellationInterruptObserved"] = cancelled["interruptCalls"] > 0 and cancelled["error"]
    values["cancelResult"] = "error:cancelled" if cancelled["cancelled"] else cancelled["value"]
    values["afterCancelState"] = run(fixture["read"])
    frozen_requests = requests[:]
    differences = []
    for name, actual in values.items():
        expected = golden["values"][name]
        if name in ("firstResult", "secondResult", "concurrentFinalState", "afterCancelState"):
            expected, actual = float(expected), float(actual)
        if expected != actual:
            differences.append({"field": name, "expected": expected, "actual": actual})
    checks["frozenExecutionObservations"] = not differences
    checks["frozenRequestSequence"] = frozen_requests == golden["requests"]

    # Exceptions pending across finally must belong to the originating fiber.
    code = "(()=>{try{try{throw new Error('A-marker')}finally{java.ajax('$ORIGIN/exception-A')}}catch(e){return e.message}})()"
    hold(1, code, "/exception-A")
    code_b = "(()=>{try{try{throw new Error('B-marker')}finally{java.ajax('$ORIGIN/exception-B')}}catch(e){return e.message}})()"
    hold(2, code_b, "/exception-B")
    gc()
    release("/exception-A")
    checks["firstExceptionIsolated"] = resume(1)["value"] == "A-marker"
    release("/exception-B")
    checks["secondExceptionIsolated"] = resume(2)["value"] == "B-marker"

    # Build the error in the native callback immediately after restoring a stack,
    # before QuickJS's usual callback epilogue can restore a parent frame itself.
    hold(1, "(function alpha(){return java.ajax('$ORIGIN/trace-A').stack})()", "/trace-A")
    hold(2, "(function beta(){return java.ajax('$ORIGIN/trace-B').stack})()", "/trace-B")
    release("/trace-A")
    trace_a = resume(1)["value"]
    checks["resumedNativeBacktraceA"] = "alpha" in trace_a and "beta" not in trace_a
    release("/trace-B")
    trace_b = resume(2)["value"]
    checks["resumedNativeBacktraceB"] = "beta" in trace_b and "alpha" not in trace_b

    # Cancel the older suspended stack while the newer stack remains live.
    hold(1, "state.n=50;java.ajax('$ORIGIN/cancel-A');state.n=999", "/cancel-A")
    hold(2, "state.n=60;java.ajax('$ORIGIN/live-B');state.n", "/live-B")
    checks["olderCancelIndependent"] = resume(1, cancelled=True)["cancelled"]
    release("/cancel-A"); release("/live-B")
    checks["newerSurvivesOlderCancel"] = resume(2)["value"] == 60
    checks["cancelDoesNotResetOrFinishCancelledCode"] = run("state.n") == 60
    # Invert cancellation order.
    hold(1, "java.ajax('$ORIGIN/live-A');state.n", "/live-A")
    hold(2, "java.ajax('$ORIGIN/cancel-B');state.n=999", "/cancel-B")
    checks["newerCancelIndependent"] = resume(2, cancelled=True)["cancelled"]
    release("/cancel-B"); release("/live-A")
    checks["olderSurvivesNewerCancel"] = resume(1)["value"] == 60
    cpu = start(1, "state.n=71;while(true);", duration=100)
    checks["cpuLoopInterrupts"] = cpu["cancelled"] and cpu["error"]
    drop(1)
    checks["cpuCancelRetainsState"] = run("state.n") == 71
    checks["subsequentExecutionWorks"] = run("++state.n") == 72

    gc_cycles = 100
    gc_ok = True
    for i in range(gc_cycles):
        a, b = f"/gc-{i}-A", f"/gc-{i}-B"
        def script(path, number):
            return f"(()=>{{let x={{n:{number},data:new Array(256).fill({number})}};x.self=x;java.ajax('$ORIGIN{path}');return x.self===x&&x.data[255]===x.n}})()"
        hold(1, script(a, i), a); hold(2, script(b, i + 1), b)
        gc()
        order = [(1, a), (2, b)] if i % 2 else [(2, b), (1, a)]
        for identifier, path in order:
            release(path)
            observed = resume(identifier)
            gc_ok = gc_ok and observed["value"] is True and not observed["error"]
            gc()
    checks["cyclesLiveAcrossGcAndBothResumeOrders"] = gc_ok
except Exception as error:
    failure = repr(error)
finally:
    with lock:
        for released in releases.values():
            released.set()
    try:
        send("quit")
        process.wait(timeout=6)
    except Exception:
        process.kill(); process.wait()
    stdout_thread.join(timeout=2)
    stderr_thread.join(timeout=2)
    server.shutdown(); server.server_close(); thread.join(timeout=2)
    checks["outputDrained"] = not stdout_thread.is_alive() and not stderr_thread.is_alive()
    checks["nativeNaturalExit"] = process.returncode == 0
    checks["noNativeDiagnostics"] = not errors
    report = {
        "status": "pass" if failure is None and all(checks.values()) else "fail",
        "scope": "Windows standalone C QuickJS fiber feasibility; not fjs/FRB product integration",
        "frameRestore": not args.without_frame_restore,
        "checks": checks, "failure": failure, "values": values,
        "differences": locals().get("differences"), "frozenRequests": locals().get("frozen_requests"),
        "notRun": ["LRU cache: unchanged product layer absent in this native probe", "FRB and Rust suspended frames", "other platforms"],
        "resumeBacktraces": {"A": locals().get("trace_a"), "B": locals().get("trace_b")},
        "gcCycles": locals().get("gc_cycles", 0), "stderr": errors,
        "exitCode": process.returncode,
        "goldenSha256": hashlib.sha256(golden_path.read_bytes()).hexdigest(),
        "executableSha256": hashlib.sha256(pathlib.Path(args.executable).read_bytes()).hexdigest(),
    }
    output = pathlib.Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    output.with_suffix(".events.jsonl").write_text("\n".join(transcript) + "\n", encoding="utf-8")
    print(json.dumps(report))
raise SystemExit(0 if report["status"] == "pass" else 1)
