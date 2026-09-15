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
process RSS grew by 3.0 MB and 5.9 MB rather than by the requested size. The
limit is allocator-level C reached through `JS_SetMemoryLimit` in the pinned
sources — an inference from that source, not a measured cross-platform row —
and only the Windows row is executed.

**The deadline is sampled, not a hard bound.** `JS_SetInterruptHandler` is
polled every 10 000 interpreter polls and every 10 000 libregexp steps, so a
deadline is enforced at poll points only. The pinned engine stops tight loops
within 0.1 ms of deadlines of 1, 10, 100 and 500 ms and a backtracking-regex bomb
within 0.2 ms of a 200 ms one (a `try/catch` around the loop cannot swallow the
error: 0.3 ms past a 50 ms deadline); through the product the same shape lands
15.3, 6.9 and 14.1 ms past 100, 200 and 500 ms deadlines, and a script parked in
a synchronous host call 35.2 ms past a 200 ms one. Work dominated by native
code between polls is where it breaks: a loop that allocates 50 KB per iteration
overshoots by 0.78 s in the
engine and 1.94 s through the product, a single `JSON.parse` of 8 MB takes 1.77 s
under a 200 ms deadline (1.57 s of overshoot) because one C call contains no
poll, and a catch-and-retry loop at the heap limit measured a 52.5 s overshoot
(52.8 s total) for a 300 ms deadline. The interrupt error is uncatchable, so a
script cannot swallow the deadline: the gap is overshoot, never escape.

**The clock is Dart's.** The product drives the deadline from a Dart `Timer`,
and a deliberately blocked isolate delayed a 100 ms deadline to 443 ms. Moving
the clock into Rust — a per-scope deadline compared inside the interrupt closure
the broker already installs — is additive and removes that dependency, while
leaving the poll-quantum gap.

**The poll quantum is the in-process lever.** Rebuilding patched copies of the
pinned sources with both constants at 1 000 and 256 cut the worst measured
overshoot of a native-heavy loop from 897 ms to 13 ms and 19 ms, and of the
heap-limit retry loop from 3 366 ms to 407 ms and 89 ms, without changing the
tight-loop or regexp rows; the retry and allocation rows order 256 below 1 000
in both runs, while the heavy-loop row flips between them. A throughput-only
process measured a fixed 20 M-iteration loop within 13 % across the three builds
and non-monotonically (1 707 / 1 513 / 1 515 ms),
so polling more often costs nothing measurable and nothing proved here.

## Consequences

The native package is vendored and pinned together with the QuickJS sources and
an explicit rebuild input list, so `cargo` reuses the built library and a source
edit rebuilds it. The runtime choice stands: the heap limit is enforced in
process, and the deadline does interrupt evaluation. The alternatives rejected
for this decision were rejected for other reasons and none of them bounds a
single C-level call in process either. What the deadline
cannot do is bound a single C-level call or a loop dominated by native work
between polls, so a *hard* execution bound needs process isolation with an
OS-level kill — the "one worker process or isolate per source" option stays
available for exactly that, and the choice belongs to the security boundary
(#5). Every non-Windows runtime row is still `not-run`, and each platform's
binding must re-verify the interrupt behaviour when it exists. Closing an engine
cancels its in-flight host calls by design, and a global `dispose` is
deliberately not used per engine close.

See `packages/fjs/LIBER.md`,
`docs/compatibility/five-platform-runtime-components.md`, and
`tool/runtime_limits_prototype/`. Provenance: `liber-archive`, issues 11 and 14
with the ticket 11 prototype record.
