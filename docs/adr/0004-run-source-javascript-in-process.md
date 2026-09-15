# Book Source JavaScript runs in-process on a vendored QuickJS with a cancellable synchronous host bridge

**Status:** accepted for Windows (2026-09-15); its execution deadline and heap
limit are measured on Windows by ticket #3 (2026-09-16); the five-platform
adapter boundary is still open (#4)

Source JavaScript executes in-process in the vendored `fjs`/QuickJS runtime whose
Windows scheduler runs each execution on its own stack (a fiber), so a script
blocked in a synchronous host call can be suspended and cancelled from another
Dart isolate, and cancellation unblocks the suspended script instead of only
rejecting a future result. Host access is an allowlisted surface with byte caps
on script and host I/O. An asynchronous Promise wrapper cannot reproduce the
baseline's synchronous host contract, and `flutter_js 0.8.7` was rejected as the
shared candidate after its Windows self-checks showed no enforceable native
execution timeout, a failing Dart memory binding, and ambient
`sendMessage`/`console`/`setTimeout` globals.

## Considered options

- **`flutter_js` on all five platforms.** Rejected on the probe results above;
  the remaining platforms stay `not-run`.
- **Wrap host calls in Promises or `async`.** Rejected: the baseline's rule
  JavaScript receives host values synchronously, and a wrapper changes every
  rule's control flow.
- **One worker process or isolate per source as the default.** Rejected as the
  default: it cannot share the process-wide, source-visible state the
  differential contract compares. It remains available as an isolation option.

## Measured limits (ticket #3, Windows only)

Executed evidence, not inference: `tool/runtime_limits_prototype/` holds the
three probes, their raw JSON, and a manifest of the source, DLL and engine
hashes. The native probe compiles the pinned QuickJS sources directly; the
product probe drives the same mechanisms through a DLL built from them.

**The heap limit is enforced.** With an 8 MiB budget, a retained-allocation
loop, a 256 MB single string and a 64 MB typed array all fail with the catchable
`InternalError: out of memory`, the runtime keeps working afterwards, the
allocator returns to ~105 KB once the script drops the blocks, and the product's
process RSS grew by 5.7 MB rather than by the requested size. The limit is
allocator-level C reached through `JS_SetMemoryLimit`, so it is not
platform-specific, but only the Windows row is executed.

**The deadline is sampled, not a hard bound.** `JS_SetInterruptHandler` is
polled every 10 000 interpreter polls and every 10 000 libregexp steps, so a
deadline is enforced at poll points only. Measured: tight loops and a
backtracking-regex bomb stop within 0.2 ms of deadlines of 1, 10, 100 and
500 ms; a script parked in a synchronous host call is released 22.5 ms after a
200 ms deadline; a loop with a 50 KB allocation per iteration overshoots by
~0.9 s; and a single `JSON.parse` of 8 MB runs its full 1.19 s past a 200 ms
deadline because one C call contains no poll. At the heap limit, the engine
measured a 27.5 s overshoot for a 300 ms deadline on a catch-and-retry loop. The
interrupt error is uncatchable, so a script cannot swallow the deadline: the gap
is overshoot, never escape.

**The clock is Dart's.** The product drives the deadline from a Dart `Timer`,
and a deliberately blocked isolate delayed a 100 ms deadline to 448 ms. Moving
the clock into Rust — a per-scope deadline compared inside the interrupt closure
the broker already installs — is additive and removes that dependency, while
leaving the poll-quantum gap.

**The poll quantum is the in-process lever.** Rebuilding patched copies of the
pinned sources with both constants at 1 000 and 256 cut the worst measured
overshoot of a native-heavy loop from 508 ms to 91 ms and 13 ms, and of the
heap-limit retry loop from 1 865 ms to 274 ms and 76 ms, without changing the
tight-loop or regexp rows. The probe could not establish the cost: the fixed
throughput loop measured ~1.0 s, ~2.4 s and ~1.0 s for 10 000, 1 000 and 256, a
non-monotone spread that polling frequency cannot explain.

## Consequences

The native package is vendored and pinned together with the QuickJS sources and
an explicit rebuild input list, so `cargo` reuses the built library and a source
edit rebuilds it. The runtime choice stands: the heap limit is enforced in
process, the deadline does interrupt evaluation, and no considered in-process
alternative promised more. What the deadline cannot do is bound a single
C-level call or a loop dominated by native work between polls, so a *hard*
execution bound needs process isolation with an OS-level kill — the
"one worker process or isolate per source" option stays available for exactly
that, and the choice belongs to the security boundary (#5). Every non-Windows
runtime row is still `not-run`, and each platform's binding must re-verify the
interrupt behaviour when it exists. Closing an engine cancels its in-flight host
calls by design, and a global `dispose` is deliberately not used per engine
close.

See `packages/fjs/LIBER.md`,
`docs/compatibility/five-platform-runtime-components.md`, and
`tool/runtime_limits_prototype/`. Provenance: `liber-archive`, issues 11 and 14
with the ticket 11 prototype record.
