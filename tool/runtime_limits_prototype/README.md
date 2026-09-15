# THROWAWAY: JavaScript runtime limits probe (ticket #3)

**Verdict, Windows only.** The vendored in-process QuickJS enforces its heap
limit, and it installs a deadline that really does interrupt running
JavaScript; but that deadline is *sampled*, not a hard bound. Interpreter-bound
and regexp-bound work stops a fraction of a millisecond past the deadline, while
work dominated by native code between poll points runs past it without limit:
the product measured 1.77 s of wall time for a 200 ms deadline on a single
C-level call, and the pinned engine 52.8 s for a 300 ms deadline on a
catch-and-retry loop at the heap limit. A JS `try/catch` cannot swallow the
interrupt, so the residual risk is overshoot, never escape. A hard bound needs
OS-level isolation; the runtime choice itself does not change.

This directory is the prototype record for
[#3](https://github.com/qsgy-edge/liber/issues/3). It answers that ticket's two
open questions — a native execution deadline, and a native heap limit — with
executed evidence, and says which rows stay `not-run`.

## What the product already does

- `Engine::create` applies `JsEngineRuntimeOptions.memoryLimit` through
  `JS_SetMemoryLimit` once per session engine
  (`lib/source/js_source_runtime.dart`, `_ScriptSession.create`).
- `Engine::init_broker` installs the interrupt closure with
  `JS_SetInterruptHandler`; it returns "cancelled" for the scope on top of the
  active stack (`packages/fjs/libfjs/src/api/engine.rs`).
- The product's deadline is a Dart `Timer`, which cancels the execution's
  `SourceCancellation`; `cancelScopedExecutionGlobal` then sets the scope's flag,
  aborts in-flight host requests, and wakes the Windows fiber scheduler.
- Windows runs each execution on its own fiber, so a script parked inside a
  synchronous host call is suspended rather than blocking the engine.

Everything below exercises those exact mechanisms.

## Executed evidence

### 1. The pinned engine alone (`native_probe.c`, QuickJS 0.15.1)

Compiled from `packages/fjs/libfjs/vendor/rquickjs-sys/quickjs`, the pinned
vendored tree (the crate appends only its stack-accessor include to a build copy
of `quickjs.c`; the vendored C files are unchanged), with the same interrupt
closure and memory limit the product installs. Full detail in
`evidence/windows-native.json`.

| Case | Deadline | Measured | Overshoot | Interrupt polls |
|---|---|---|---|---|
| `while(true){}` | 1 ms | 1.1 ms | 0.1 ms | 25 |
| `while(true){}` | 10 ms | 10.1 ms | 0.1 ms | 276 |
| `while(true){}` | 100 ms | 100.1 ms | 0.1 ms | 2 787 |
| `while(true){}` | 500 ms | 500.0 ms | 0.0 ms | 13 495 |
| `try { while(true){} } catch {}` | 50 ms | 50.3 ms | 0.3 ms | 88 |
| `/(a+)+$/` backtracking bomb | 200 ms | 200.2 ms | 0.2 ms | 1 091 |
| allocation loop | 100 ms | 250.3 ms | 150.3 ms | 1 |
| string-building loop | 100 ms | 103.8 ms | 3.8 ms | 17 |
| loop with a 50 KB `repeat` per iteration | 100 ms | 876.6 ms | 776.6 ms | 1 |
| one `'y'.repeat(104857600)` call | 100 ms | 438.3 ms | 338.3 ms | 0 |
| catch-and-retry loop at an 8 MiB heap | 300 ms | 52 837.2 ms | 52 537.2 ms | 1 |

The try/catch case ends with `InternalError: interrupted` rather than the
script's own result: the deadline error is uncatchable. The single-poll and
zero-poll rows are the cause of the overshoot — the interrupt handler is reached
only at interpreter or libregexp poll points, and a single long C call has none.

Heap limit at 8 MiB (`JS_SetMemoryLimit`), same probe:

| Case | Result |
|---|---|
| retained-allocation loop | catchable `InternalError: out of memory` after 29.1 ms of allocating |
| 256 MB single string | same error, in 1.7 ms |
| 64 MB typed array | same error, in 0.5 ms |
| `6 * 7` after the out-of-memory error | `42` — the runtime stays usable |
| GC after the script drops its blocks | allocator returned to ~105 KB |
| same work without a limit | completes (control) |

### 2. The poll quantum (`quantum_probe.c`, patched *copies* of the same sources)

QuickJS polls once per `JS_INTERRUPT_COUNTER_INIT` interpreter polls
(`quickjs.c`) and per `INTERRUPT_COUNTER_INIT` libregexp steps
(`libregexp.c`); both ship as 10 000. The harness patches a copy, rebuilds, and
re-measures with three repeats per case; the vendored files are not modified.
Worst-sample overshoots and fastest-of-nine throughput in
`evidence/windows-quantum.json`.

| Quantum | 100 ms tight loop | heavy loop worst | allocation loop worst | 8 MiB retry worst | fixed 20 M-iteration loop, throughput-only process |
|---|---|---|---|---|---|
| 10 000 | 100.0 ms | 896.7 ms | 80.6 ms | 3 366.2 ms | 1 707 ms |
| 1 000 | 100.0 ms | 12.7 ms | 25.9 ms | 407.0 ms | 1 513 ms |
| 256 | 100.0 ms | 18.6 ms | 13.9 ms | 89.2 ms | 1 515 ms |

The benefit is real: at 1 000 or 256 the worst measured overshoot of a
native-heavy loop falls from ~0.9 s to ~13-19 ms and of the heap-limit retry
loop from ~3.4 s to ~0.09-0.4 s, while the tight loop and the regexp bomb still
stop at the deadline. The retry and allocation rows order 256 below 1 000 in
both this run (89 ms against 407 ms, 14 ms against 26 ms) and the previous one
(76 against 274 ms, 20 against 29 ms), while the heavy-loop row flips between
them (19 ms against 13 ms here), so the table supports "far smaller than
10 000" and not a general ordering from the heavy-loop row alone.

The throughput column is **not** a cost measurement. In a throughput-only
process the three builds measure within 13 % of one another and non-monotonically
(1 707 / 1 513 / 1 515 ms), so this probe resolves no cost. The in-process
column is noisier still because the earlier deadline cases run in the same
process first, and it is kept only to show that confound.

### 3. The product path (`product_probe.dart`, built DLL)

Every case drives `lib/source/js_source_runtime.dart` against a DLL built in
this lane from the pinned sources (`cargo build --locked`, sha256
`4cf50254402ec7e90adf7383f64572185a872e105df3328d1589739ef4a33ad0`). Full
detail in `evidence/windows-product.json`.

| Case | Deadline | Result | Overshoot |
|---|---|---|---|
| `while(true){}` ×3 | 100 / 200 / 500 ms | `timeout`, follow-up execution works | 15.3 / 6.9 / 14.1 ms |
| `try { while(true){} } catch {}` | 200 ms | `timeout` | — |
| backtracking regex bomb | 200 ms | `timeout` | 31.2 ms |
| parked in a synchronous host call | 200 ms | `timeout`; the host call observed cancellation | 35.2 ms |
| loop with a 50 KB `repeat` per iteration | 200 ms | `timeout` | 1 942.1 ms |
| `JSON.parse` of 8 MB (one C call) | 200 ms | `timeout` **after the call finished** | 1 566.8 ms |
| catch-and-retry loop, 8 MiB heap | 300 ms | `timeout`, follow-up execution works | 1 367.2 ms |
| isolate deliberately blocked for 400 ms | 100 ms | `timeout` at 443.1 ms — the timer waited for the isolate | 343.1 ms |
| allocation loop, 8 MiB heap, twice on one shared engine | — | `js`, follow-up works, RSS +3.0 MB total | — |
| 256 MB single string, 8 MiB heap | — | `js`, in 65.1 ms, RSS +5.9 MB | — |
| 1 000 000-deep recursion | — | `js`, follow-up works | — |

`js` is the category the product assigns to a JavaScript-level failure. The
product's `SourceScriptError` carries no message, so the out-of-memory identity
is pinned where the raw error is visible: `fiber_runtime_gate`'s
`heapLimitEnforced` check asserts `JsError_MemoryLimit` on this same DLL (it
runs in `evidence/gates.log`), and the native probe shows the error itself as
`InternalError: out of memory`. The recursion row is the stack budget, not the
heap: it also fails as a catchable JavaScript error and leaves the runtime
usable.

The two library gates that assert the same behaviour on this DLL also pass
(`runtime_gate`, `fiber_runtime_gate`, see `evidence/gates.log`).

## Where the limits do not hold

1. **A single long C-level call ignores the deadline entirely.** `JSON.parse` of
   8 MB ran 1.77 s under a 200 ms deadline; the caller only learns it timed out
   after the call returns. No poll quantum fixes this.
2. **Native-heavy loops overshoot with the cost of 10 000 iterations.** Measured
   776 ms in the engine and 1.94 s through the product for a loop that allocates
   one 50 KB string per iteration; with garbage collection inside the loop (the
   retry pattern at the heap limit) the engine measured 52.5 s. A hostile source
   can hold the shared executor thread for an unbounded time this way.
3. **The clock is Dart's.** Blocking the isolate for 400 ms delayed a 100 ms
   deadline to 443 ms. A Rust-side `Instant` compared inside the interrupt
   closure removes this dependency and shrinks the effective bound to the poll
   quantum, but does not change items 1 and 2.
4. **The heap limit is a limit on QuickJS's allocator, not on the process.**
   Measured RSS growth stays close to the budget (+3.0 MB and +5.9 MB for an
   8 MiB limit), but memory the host allocates outside QuickJS is outside the
   limit.

The quantum probe's retry loop allocates `new Array(20000)` per iteration while
the native probe uses `new Array(200000)`, which is why their overshoots differ
by an order of magnitude: the overshoot tracks the native cost of one iteration
multiplied by the poll quantum, so the two rows are not comparable directly.

## Recommended follow-ups

- Move the deadline clock into Rust and pass it per scoped execution; small and
  additive to what `install_execution_interrupt` already does.
- Decide whether the two poll constants should be lowered (the measured
  benefit is in the table above; the throughput cost is not established). It is
  a patch to the vendored sources or an upstreamable knob.
- Treat "one execution, one time budget" as best-effort in the security
  boundary (#5): either accept the measured overshoot with a session-level
  abandon policy, or add process isolation with an OS-level kill. Isolation
  means a process: `Isolate.kill(priority: beforeNextEvent)` is documented as
  "scheduled for the next time control returns to the event loop", which bounds
  nothing for an isolate busy in a synchronous computation
  (<https://api.dart.dev/dart-isolate/Isolate/kill.html>).

## Not established

- Android, iOS, macOS and Linux: `not-run`. No non-Windows executor, binding or
  compiled artefact was exercised. The interrupt handler and the memory limit
  are platform-independent C in the pinned sources, and the Windows rows are the
  only executed ones.
- The product's default 64 MiB budget: only 8 MiB was measured for the
  pathological retry pattern.
- How a deadline behaves for one execution while other scopes share the engine
  and one of them is native-heavy; the interrupt closure only consults the scope
  on top of the active stack.
- Whether polling more often costs measurable throughput: the throughput-only
  runs spread non-monotonically within 13 %, so this probe cannot answer it.
- The Windows fiber path was exercised only through the shipped gates and the
  product probe; no new fiber-level measurement was made here.
- No frozen-oracle, capability or compatibility claim follows from this record.

## Reproduce

```powershell
# from the repository root, with a built fjs.dll
python tool/runtime_limits_prototype/verify.py build/windows/x64/runner/Debug/fjs.dll
```

`verify.py` builds the native probes with the installed MinGW gcc, runs the
product probe as one process per case, runs the two library gates, and rewrites
`evidence/` plus the hashed manifest. The DLL it records was built with:

```powershell
cargo build --locked   # in packages/fjs/libfjs, crate-type cdylib
```

## Evidence

The manifest is machine-written by `verify.py` and records the tree as it was at
run time: commit `1c8aed0` (whose base is `d503d8a`), one scratch exploration script
(`explore_candidates.dart`) that has since been deleted, and the probe and
evidence files it rewrote. The source hashes in the same manifest pin the exact
probe files that produced these numbers.

- [Pinned engine, byte-level cases](evidence/windows-native.json)
- [Poll-quantum sensitivity on patched copies](evidence/windows-quantum.json)
- [Product runtime through the DLL](evidence/windows-product.json)
- [Shipped gates on the same DLL](evidence/gates.log)
- [Hashes, provenance and findings](evidence/manifest.json)
