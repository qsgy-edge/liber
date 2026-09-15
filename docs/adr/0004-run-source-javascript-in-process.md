# Book Source JavaScript runs in-process on a vendored QuickJS with a cancellable synchronous host bridge

**Status:** accepted for Windows; the five-platform adapter boundary is still
open (#4)

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

## Consequences

The native package is vendored and pinned together with the QuickJS sources and
an explicit rebuild input list, so `cargo` reuses the built library and a source
edit rebuilds it. The runtime's enforceable execution deadline and per-platform
heap limits are still unproven, and every non-Windows runtime row is `not-run`;
both stay open in #3 and #4. Closing an engine cancels its in-flight host calls
by design, and a global `dispose` is deliberately not used per engine close.

See `packages/fjs/LIBER.md` and
`docs/compatibility/five-platform-runtime-components.md`. Provenance:
`liber-archive`, issues 11 and 14 with the ticket 11 prototype record.
