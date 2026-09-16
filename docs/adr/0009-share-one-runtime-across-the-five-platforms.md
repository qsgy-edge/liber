# One shared runtime and one execution model; only the WebView adapter differs by platform

**Status:** accepted (2026-09-16). Settles the five-platform adapter boundary ADR 0004 left
open, and amends that ADR's fiber clause: the runtime has one execution model, not one per
platform.

**One runtime on all five platforms.** Android, iOS, Windows, macOS and Linux run the same
source-execution stack: the vendored `fjs`/QuickJS native library with the `liber_html` crate,
plus one Dart pipeline (`lib/source/`) that owns the four stages, the rule dispatch, the session
cookie jar, the frozen request semantics, and the cancellation tokens. A platform may not
substitute another JavaScript engine, fork the pipeline, or move execution to a remote service.

**Per-platform code is three things and nothing else.** The native build glue (`cargokit` and
each platform's toolchain), the engine binding for that platform, and the WebView transport
behind the existing `BookSourceTransport` interface (`lib/source/book_source_service.dart:12`) —
one thin adapter per system engine: WebView2, Android WebView, WKWebView, WebKitGTK. Nothing
source-visible is platform-specific; the WebView adapter contract is #2's, and its rows are
evidenced per adapter identity, never inferred across platforms.

**One execution model, with no per-execution stacks.** Executions on one engine run on one OS
thread. A script parked in a synchronous host bridge call is served by a nested wait loop on
that thread; the loop also takes queued executions in submission order (a `VecDeque` with
`push_back`/`pop_front`: `libfjs/src/api/engine.rs:208, 978, 2086`) and nested evaluations in the
order they arrive on its channel, and an execution started this way runs *nested inside* the
parked one, which cannot resume until the nested one returns or parks deeper. Cancellation ends
the parked call with an error the script cannot swallow, and the interrupt then stops the script
at its next poll. Per-execution stacks (Windows fibers) are not part of the runtime on any
platform: what they add — several executions parked at once, resuming in any order — is not
compared by the differential contract and is not asserted by any gate, so no source can depend
on it. **Amendment (2026-09-16, ticket #25's executed evidence): the "not compared by the
differential contract" clause is wrong — one row does compare it.** The state differential's
`firstCompletesWhileSecondHeld` releases a scope parked in HTTP and asks whether it completes
while a second scope is still parked; the frozen baseline does that by resuming independently
parked scopes, and the one execution model cannot, because the nested wait owns the OS thread.
Measured after the fiber removal: expected `true`, observed `false`, with every other
observation of that scenario unchanged (`secondCompletedWhileFirstHeld`, both results, the
cancel result, the state after cancel, the LRU trio and the request order all match the
golden). That row is therefore recorded as a known divergence, not a pass — `notCompared` in
`tool/state_oracle_compare.dart` plus the divergence table in
`docs/compatibility/book-source-differential-contract.md` — and a platform running that
harness has its compatibility claim narrowed by exactly this capability (two independently
parked scopes, resuming in any order) and by nothing else. The rest of the sentence stands: no
gate asserts the capability.
Concurrent analyses *are* reachable from the product today — a second tap on a search
result or on the directory-refresh button while the first analysis runs starts another one on
the same pipeline and, for a source with a `jsLib`, on the same engine
(`lib/source/html_source_browser.dart:217, 256`; `lib/source/js_source_runtime.dart:79-93`) — and
removing the fiber makes that case deterministic, one at a time and nested, instead of
interleaved. A future need for genuinely parallel analyses re-opens that decision with its own
evidence.

**The limits stay in process, and the deadline clock moves into Rust.** The heap limit is
enforced today, per session engine, through `JS_SetMemoryLimit`. The deadline is a Dart `Timer`
today and becomes a per-scope deadline held in Rust, compared inside the interrupt closure the
broker already installs, plus a timeout on the parked host wait, so enforcement stops depending
on a punctual Dart `Timer` (ticket #3 measured a blocked isolate delaying a 100 ms deadline to
443 ms). The interrupt poll quantum comes down from QuickJS's pinned 10 000/10 000
(`packages/fjs/libfjs/vendor/rquickjs-sys/quickjs/quickjs.c:479`,
`.../libregexp.c:62`) to 1 000/1 000. Both moves are #25's and are not in the tree yet: the
product still drives the deadline from a `Timer` (`lib/source/js_source_runtime.dart:152-155`).
A *hard* bound stays out of reach in process, so OS-level
process isolation is the mechanism for it — an option *per source*, owned by the security
boundary (#5), not the default: ADR 0004 rejected default isolation because the contract
compares source-visible state, including process-global request and rate-limiter state, that a
per-source process cannot share.

## Measured limits this decision rests on

Ticket #3's executed evidence, in `tool/runtime_limits_prototype/`, Windows only:

- The heap limit is enforced (`InternalError: out of memory` is catchable, the engine stays
  usable, RSS grows by megabytes rather than by the requested size).
- The interrupt is polled, so overshoot is bounded by the poll quantum and by the length of a
  single native call: with the quantum at 1 000/256 the worst measured overshoots fell from
  897 ms to 13/19 ms for a native-heavy loop and from 3 366 ms to 407/89 ms for a catch-and-retry
  loop at the heap limit, with no measurable throughput cost in the single process that
  measured it (13 %, non-monotonic, three builds).
- A single C-level call has no poll inside it: an 8 MB `JSON.parse` ran 1.77 s under a 200 ms
  deadline. The byte caps on script and host I/O bound it; isolation is what removes it.
- The product's clock was Dart's, and a deliberately blocked isolate delayed a 100 ms deadline
  to 443 ms — the failure mode the Rust clock removes.

## Considered options

- **A per-platform JavaScript engine (system JavaScriptCore on Apple, another engine
  elsewhere).** Rejected: the differential contract compares source-visible behavior, so every
  additional engine adds a conformance surface and a second set of rule-dialect divergences,
  while iOS's JIT restriction costs an interpreter engine nothing. One library already
  cross-builds for all five targets (CI run 35053007809).
- **Portable per-execution stacks on all five platforms.** Rejected: upstream `fjs` ships no
  such implementation (its `libfjs/src/runtime` has no fiber module; the Win32 one is this
  repository's own, and Win32 provides the stack switch), so this would be four new
  stack-switching implementations in Rust for a capability nothing observes.
- **Keep the Windows fiber as a platform implementation detail.** Rejected: it exists only by
  patching the pinned QuickJS sources — `liber_stack.inc` is there solely to make a non-LIFO
  stack layout safe — and by carrying a platform-specific scheduler beside the shared one.
- **Move the HTTP transport into Rust so the execution core is one language.** Rejected: the
  request semantics are the strictly compared surface of the contract and are already
  implemented and wire-tested in Dart (`lib/source/http_source_transport.dart`, #9's rows); the
  cookie jar and the byte caps live there too, the WebView cookie synchronization stays on the
  plugin side, and user state is Dart's (the space store), so a second network path in Rust
  would duplicate the audited surface without removing a layer.
- **One worker process or isolate per source as the default.** Rejected as the default by ADR
  0004, for the shared-state reason above; it remains an isolation option owned by #5.
- **Keep the Dart `Timer` as the deadline clock and change nothing else.** Rejected: it is the
  443 ms failure mode, and the clock is not what bounds the engine's poll quantum.

## Consequences

- The runtime loses its platform branch. Deleted: `libfjs/src/runtime/fibers.rs`, the three
  `#[cfg(windows)]` sites in `libfjs/src/api/engine.rs`, the `liber_stack.inc` accessor and its
  build-script append, and the three Windows-only runtime gates, which join the shared gate list
  that runs on Windows, Linux and macOS. Which assertion of those gates survives, which is
  re-derived on the one execution path and which is deleted with its reason is listed assertion
  by assertion in ticket #25, because several of them exist only to hold two suspended stacks at
  once. Owned by ticket #25.
- Documentation that describes the runtime's shape moves with the same slice, or it starts
  contradicting this decision: `README.md`'s layout line, `packages/fjs/LIBER.md` (including its
  "same-library executions are serialized" claim, which the Dart cache does not implement —
  `lib/source/js_source_runtime.dart:164-166` only delays eviction), the vendored
  `rquickjs-sys/LIBER.md`, `.github/workflows/ci.yml`'s coverage note, `book_sources/README.md`'s
  gate list, the limits harness (`README.md` and `verify.py`'s `GATES`), and the generated FRB
  comment that names `run_fiber_scheduler`.
- The vendored `rquickjs-sys` stays vendored, but its patch changes shape: from the stack
  accessor to the poll-quantum replacement, which the build script must assert happened, so a
  QuickJS bump that moves those two defines fails the build instead of silently restoring
  10 000. Its `LIBER.md` — including the "other platforms need their own independent-resumption
  implementation" line — is rewritten with it.
- Every platform's rows are its own. No platform may claim compatibility without, on that
  platform: the shared runtime gates, the heap and deadline rows of the limits harness, and
  #2's WebView rows for its adapter. Android and iOS need device or simulator rows — the CI jobs
  cross-build the native library only — and the Linux rendered-document path stays `not-run`
  until #2 proves WebKitGTK.
- The two differential rows that compare against the Android golden
  (`tool/state_oracle_compare.dart`, `tool/nested_oracle_compare.dart`) extend to the three
  desktop platforms; `tool/state_oracle_compare.dart:176` hard-codes its platform label today
  and must report the platform it ran on.
- The limits harness is Windows-shaped (`tool/runtime_limits_prototype/verify.py` writes
  `windows-*.json`, drives `pwsh build.ps1`, loads `build/windows/.../fjs.dll`), so it becomes
  platform-neutral before the other four rows can be executed; until then they stay `not-run`.
- Residual risk the decision accepts: in-process enforcement bounds overshoot but does not
  eliminate it, a single native call is bounded only by the input caps, and the tighter quantum
  has been measured in one process on one platform — the change re-runs the harness per platform
  together with that platform's binding row.

Provenance: ticket #4; ticket #3's measurements and harness in
`tool/runtime_limits_prototype/`; CI run 35053007809 (commit `2aac2d7`) for the executed
Linux/macOS gate rows; `packages/fjs/LIBER.md`,
`packages/fjs/libfjs/vendor/rquickjs-sys/LIBER.md`,
`docs/compatibility/five-platform-runtime-components.md`.
