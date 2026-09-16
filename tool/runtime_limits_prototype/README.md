# THROWAWAY: JavaScript runtime limits probe (ticket #3, re-run by ticket #25)

**Verdict, Windows row executed 2026-09-16 with the shipped poll quantum (1 000/1 000)
against a release build; every other platform row is `not-run`.** The vendored in-process
QuickJS enforces its heap limit, and the execution deadline — now held in Rust, not by a Dart
`Timer` — really does interrupt running JavaScript. The deadline is *sampled*, not a hard
bound: interpreter-bound and regexp-bound work stops a fraction of a millisecond past the
deadline, and with the shipped 1 000 poll quantum native-heavy loops that used to overshoot by
seconds now land within tens of milliseconds. A single long C-level call still contains no
poll at all, so nothing in process bounds it. A JS `try/catch` cannot swallow the interrupt,
so the residual risk is overshoot, never escape. A hard bound needs OS-level isolation; the
runtime choice itself does not change.

This directory is the prototype record for
[#3](https://github.com/qsgy-edge/liber/issues/3) and the limits half of
[#25](https://github.com/qsgy-edge/liber/issues/25). It answers that ticket's two open
questions — a native execution deadline, and a native heap limit — with executed evidence,
and says which rows stay `not-run`.

## What the product already does

- `Engine::create` applies `JsEngineRuntimeOptions.memoryLimit` through
  `JS_SetMemoryLimit` once per session engine
  (`lib/source/js_source_runtime.dart`, `_ScriptSession.create`).
- `Engine::init_broker` installs the interrupt closure with `JS_SetInterruptHandler`; it
  returns "cancelled" for the scope on top of the active stack, and it returns for that scope
  once its deadline has passed (`packages/fjs/libfjs/src/api/engine.rs`).
- The deadline is a per-scope budget **in Rust**: the host passes `deadlineMs` to
  `createScopedExecution`, Rust compares it with a monotonic clock inside the interrupt
  closure, and the parked host wait carries a timeout arm that ends the wait and tears the
  execution's host requests down (`lib/source/js_source_runtime.dart`,
  `packages/fjs/libfjs/src/api/engine.rs`). No Dart `Timer` holds a deadline any more.
- The build script replaces both poll quanta in the build copy of the vendored QuickJS
  (`JS_INTERRUPT_COUNTER_INIT` in `quickjs.c`, `INTERRUPT_COUNTER_INIT` in `libregexp.c`)
  from the pinned 10 000 to 1 000, and fails the build unless each replacement happened
  (`packages/fjs/libfjs/vendor/rquickjs-sys/build.rs`). The vendored files stay pinned.
- All five platforms run the same execution model: one OS thread per engine, a script parked
  in a synchronous host call served by a nested wait loop (ADR 0009). There is no fiber path
  and no per-execution stack.

Everything below exercises those exact mechanisms.

## Executed evidence

### 1. The pinned engine alone (`native_probe.c`, QuickJS 0.15.1)

Compiled from `packages/fjs/libfjs/vendor/rquickjs-sys/quickjs` — the frozen pinned tree, at
the pinned 10 000 quantum, so this section is the baseline the product rows are read against.
Full detail in `evidence/windows-native.json`.

| Case | Deadline | Measured | Overshoot | Interrupt polls |
|---|---|---|---|---|
| `while(true){}` | 1 ms | 1.0 ms | 0.0 ms | 44 |
| `while(true){}` | 10 ms | 10.0 ms | 0.0 ms | 467 |
| `while(true){}` | 100 ms | 100.0 ms | 0.0 ms | 4 721 |
| `while(true){}` | 500 ms | 500.0 ms | 0.0 ms | 23 362 |
| `try { while(true){} } catch {}` | 50 ms | 50.1 ms | 0.1 ms | 167 |
| `/(a+)+$/` backtracking bomb | 200 ms | 200.2 ms | 0.2 ms | 1 138 |
| allocation loop | 100 ms | 236.2 ms | 136.2 ms | 1 |
| string-building loop | 100 ms | 105.4 ms | 5.4 ms | 19 |
| loop with a 50 KB `repeat` per iteration | 100 ms | 550.3 ms | 450.3 ms | 1 |
| one `'y'.repeat(104857600)` call | 100 ms | 241.0 ms | 141.0 ms | 0 |
| catch-and-retry loop at an 8 MiB heap | 300 ms | 24 217.4 ms | 23 917.4 ms | 1 |

The try/catch case ends with `InternalError: interrupted` rather than the
script's own result: the deadline error is uncatchable. The single-poll and
zero-poll rows are the cause of the overshoot — the interrupt handler is reached
only at interpreter or libregexp poll points, and a single long C call has none.

Heap limit at 8 MiB (`JS_SetMemoryLimit`), same probe:

| Case | Result |
|---|---|
| retained-allocation loop | catchable `InternalError: out of memory` after 17.5 ms of allocating |
| 256 MB single string | same error, in 0.0 ms |
| 64 MB typed array | same error, in 0.0 ms |
| `6 * 7` after the out-of-memory error | `42` — the runtime stays usable |
| GC after the script drops its blocks | allocator returned to ~96 KB |
| same work without a limit | completes (control) |

### 2. The poll quantum (`quantum_probe.c`, patched *copies* of the same sources)

QuickJS polls once per `JS_INTERRUPT_COUNTER_INIT` interpreter polls (`quickjs.c`) and per
`INTERRUPT_COUNTER_INIT` libregexp steps (`libregexp.c`); both ship as 10 000 and the build
copy now carries 1 000. The harness patches a copy, rebuilds, and re-measures with three
repeats per case; the vendored files are not modified. Worst-sample overshoots and
fastest-of-nine throughput in `evidence/windows-quantum.json`.

| Quantum | 100 ms tight loop | heavy loop worst | allocation loop worst | 8 MiB retry worst | fixed 20 M-iteration loop, throughput-only process |
|---|---|---|---|---|---|
| 10 000 (pinned) | 100.0 ms | 563.3 ms | 132.8 ms | 2 616.3 ms | 1 024.0 ms |
| 1 000 (shipped) | 100.0 ms | 11.5 ms | 25.2 ms | 278.1 ms | 1 031.2 ms |
| 256 | 100.0 ms | 4.8 ms | 17.4 ms | 50.4 ms | 984.6 ms |

The benefit is real: at 1 000 the worst measured overshoot of a native-heavy loop falls from
~0.6 s to ~11 ms and of the heap-limit retry loop from ~2.6 s to ~0.28 s, while the tight loop
and the regexp bomb still stop at the deadline. 256 is better again on the retry row, but
ADR 0009 settles 1 000: it is already within tens of milliseconds of the deadline, and the
measured spread between 1 000 and 256 is not monotonic across runs.

The throughput column is **not** a cost measurement. The three builds measure within ~5 % of
one another here and non-monotonically across runs (the previous record: 1 707 / 1 513 /
1 515 ms), so this probe resolves no cost.

### 3. The product path (`product_probe.dart`, release DLL)

Every case drives `lib/source/js_source_runtime.dart` against a **release** build — the profile
a distributed application loads — through the Rust-held deadline and the shipped 1 000
quantum. The earlier record in this directory measured a *debug* DLL at the pinned 10 000
quantum; the numbers below are not comparable to those one-for-one, and every row whose
assertion changed says so. Full detail in `evidence/windows-product.json`.

| Case | Deadline | Result | Overshoot | Carried over from the pinned record |
|---|---|---|---|---|
| `while(true){}` ×3 | 100 / 200 / 500 ms | `timeout`, follow-up execution works | 4.8 / 0.2 / 0.0 ms | 15.3 / 6.9 / 14.1 ms |
| `try { while(true){} } catch {}` | 200 ms | `timeout` | — | `timeout` |
| backtracking regex bomb | 200 ms | `timeout` | 35.4 ms | 31.2 ms |
| parked in a synchronous host call | 200 ms | `timeout`; the host call observed cancellation | 38.6 ms | 35.2 ms |
| loop with a 50 KB `repeat` per iteration | 200 ms | `timeout` | 26.1 ms | 1 942.1 ms |
| `JSON.parse` of a 16 MB array (one C call) | 100 ms | `timeout` **after the call finished** | 674.3 ms | 1 566.8 ms |
| catch-and-retry loop, 8 MiB heap | 300 ms | `timeout`, follow-up execution works | 34.4 ms | 1 367.2 ms |
| isolate deliberately blocked for 400 ms | 100 ms | `timeout`; the execution had already ended when the isolate returned (3.3 ms after unblocking) | — | `timeout` at 443.1 ms — the old Dart timer waited for the isolate |
| allocation loop, 8 MiB heap, twice on one shared engine | — | `js`, follow-up works | — | RSS +3.0 MB |
| 256 MB single string, 8 MiB heap | — | `js`, in 34.1 ms | — | 65.1 ms |
| 1 000 000-deep recursion | — | `js`, follow-up works | — | same |

`js` is the category the product assigns to a JavaScript-level failure. The product's
`SourceScriptError` carries no message, so the out-of-memory identity is pinned where the raw
error is visible: `scoped_runtime_gate`'s `heapLimitEnforced` check asserts
`JsError_MemoryLimit` on this same DLL (`evidence/gates.log`), and the native probe shows the
error itself as `InternalError: out of memory`. The recursion row is the stack budget, not the
heap: it also fails as a catchable JavaScript error and leaves the runtime usable.

Three product cases had to be re-derived for the shipped quantum and the release profile, and
their assertions changed with them:

- `deadline-heavy-loop-body` asserted an overshoot **above** 50 ms. At the pinned 10 000
  quantum it measured 1 942.1 ms; at 1 000 it measures 26.1 ms, so the assertion is now "under
  100 ms". The gap itself is still recorded — by the pinned engine rows above and by the
  10 000 column of the quantum table.
- `deadline-single-native-call` asserted that the execution ran more than a second past its
  deadline. A release build parses the same payload about nine times faster, so the row now
  uses a 16 MB payload with a 512 MiB heap (the parsed array alone costs ~128 MB, which the
  product's default 64 MiB budget would turn into the memory row), a 100 ms deadline, and a
  short loop after the call so the interpreter polls as soon as the call returns. Without that
  loop the execution can end without polling again and the deadline is never reported at all —
  the same gap, one step further. Both checks now hold: `timeout`, 674 ms past the deadline.
- `deadline-oom-retry-loop` asserted that it ran more than a second past its deadline; at the
  shipped quantum it overshoots by 34 ms, and its assertion is now "under 500 ms".
- `deadline-isolate-blocked` used to assert that the deadline waited for the isolate (the old
  failure mode). It now records how long the already-finished execution took to be observed
  after the isolate returned (3.3 ms), which is what a deadline held outside the isolate looks
  like.

The gates that exercise the same engine through the same shared list also pass on the debug
DLL this harness is given for them (see `evidence/gates.log`).

## Where the limits do not hold

1. **A single long C-level call ignores the deadline entirely.** `JSON.parse` of 16 MB ran
   774 ms under a 100 ms deadline; the caller only learns it timed out after the call returns,
   and if the script polls no further the deadline is never reported at all. No poll quantum
   fixes this.
2. **Native-heavy loops still overshoot by the poll quantum's worth of native work.**
   Measured at 11 ms (heavy loop) and 278 ms (the heap-limit retry pattern) at the shipped
   quantum, against 563 ms and 2 616 ms at the pinned one. A hostile source can hold the shared
   executor thread for the length of one native burst.
3. **The process, not the engine, is the real boundary.** The heap limit bounds QuickJS's
   allocator only; memory the host allocates outside QuickJS is outside it. Measured RSS change
   through the product stayed inside the budget (the last run measured no growth after two
   out-of-memory runs; earlier runs measured +3.0 and +5.9 MB for an 8 MiB limit) — RSS is a
   process quantity and a noisy one.
4. **The Rust clock is authoritative but not instantaneous.** A deadline that lands while a
   script is parked in a host wait now ends that wait and tears its host request down
   (`deadline-host-call`), and the interrupt is compared on the JavaScript thread rather than
   in the host's event loop (`deadline-isolate-blocked`). What it cannot do is interrupt a
   single native call, as above.

## Recommended follow-ups

- The remaining four platform rows: run `verify.py` on Linux and macOS (the harness is
  platform-neutral now; the probes' POSIX clock branch has not been compiled from this host),
  and on Android/iOS through their own binding, where these rows need devices.
- Treat "one execution, one time budget" as best-effort in the security boundary (#5): either
  accept the measured overshoot with a session-level abandon policy, or add process isolation
  with an OS-level kill. Isolation means a process: `Isolate.kill(priority: beforeNextEvent)`
  is documented as "scheduled for the next time control returns to the event loop", which
  bounds nothing for an isolate busy in a synchronous computation
  (<https://api.dart.dev/dart-isolate/Isolate/kill.html>).
- Whether the quantum should come down further: 256 measured better again on the retry row
  (50.4 ms against 278.1 ms) with no resolvable cost. ADR 0009 settled 1 000; a later change
  re-runs this harness and says so.

## Not established

- Android, iOS, macOS and Linux: `not-run`. The harness is platform-neutral (it writes
  `<platform>-*.json`, selects the library and the probe build flags by platform, and runs the
  same shared gate list), but only the Windows row was executed for this record. The interrupt
  handler, the memory limit and the poll quantum are platform-independent C in the pinned
  sources.
- The product's default 64 MiB budget: only 8 MiB was measured for the pathological retry
  pattern, and the single-native-call row deliberately raises it to 512 MiB.
- How a deadline behaves for one execution while other scopes share the engine and one of them
  is native-heavy; the interrupt closure only consults the scope on top of the active stack.
- Whether polling more often costs measurable throughput: see section 2.
- No frozen-oracle, capability or compatibility claim follows from this record. The state
  differential's known divergence is recorded separately, in
  `docs/compatibility/book-source-differential-contract.md`.

## Reproduce

```bash
# from the repository root, with a built release DLL and the app bundle's debug DLL
python tool/runtime_limits_prototype/verify.py \
  packages/fjs/libfjs/target/release/fjs.dll \
  build/windows/x64/runner/Debug/fjs.dll
```

The first argument is the library the product cases and the limit rows load; the second is the
library the shared gate list loads (on Windows, the app bundle's debug DLL, which is what
`test/native_library.dart` and the package's own gates resolve). Defaults are the same paths,
computed per platform.

`verify.py` builds the native probes with the installed C compiler, runs the product probe as
one process per case, runs the shared gate list from `tool/ci_runtime.py`, and rewrites
`evidence/<platform>-*.json`, `evidence/gates.log` and `evidence/manifest.json`. The libraries
it recorded were built with:

```bash
cargo build --release --locked   # in packages/fjs/libfjs, crate-type cdylib
flutter build windows --debug    # the app bundle copy the gates load
```

## Evidence

The manifest is machine-written by `verify.py` and records the tree as it was at run time,
the platform the row belongs to, both libraries with their hashes, and the source hashes of
every probe file that produced these numbers. Every file in this directory except
`gates.log` is a rewritten artefact of the last run.

- [Pinned engine, byte-level cases](evidence/windows-native.json)
- [Poll-quantum sensitivity on patched copies](evidence/windows-quantum.json)
- [Product runtime through the release DLL](evidence/windows-product.json)
- [Shared gate list on the debug DLL](evidence/gates.log)
- [Hashes, provenance and findings](evidence/manifest.json)
