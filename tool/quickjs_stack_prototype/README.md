# THROWAWAY: independent QuickJS execution stacks

**Historical probe verdict: Windows native feasibility passed.** The subsequent Windows fjs integration is recorded separately in [the product evidence manifest](../nested_oracle/evidence/windows-fibers-manifest.json); it must not be inferred from this standalone probe.

This probe answers whether two synchronous JS executions can share a QuickJS runtime while resuming in either order after real HTTP waits. It compiles the pinned QuickJS C sources used by the current rquickjs dependency, without editing that dependency or product files. Each execution gets a Windows fiber. A trusted test controller chooses which completed request to resume; this is not a production scheduler.

Run from this repository in PowerShell 7:

```powershell
./tool/quickjs_stack_prototype/run.ps1
```

`run.ps1` accepts `-QuickJsDirectory`, `-OutputDirectory`, `-Compiler`, and `-EvidenceDirectory` for a different installation. It uses the already installed MinGW compiler and Python. The executable goes to the Windows temporary directory; observations and hashes go to `evidence/`. No dependencies are installed or downloaded.

## Observed

- The seven execution observations selected from the expanded frozen Legado golden match, including the previously failing `firstCompletesWhileSecondHeld`. The same fixture script strings are executed against a real local HTTP replay server; all four request targets and their order match. The three LRU observations are **not run** here: this standalone native probe has no source-library cache.
- Cancelling either the older or newer suspended execution leaves the other usable and preserves shared state. A CPU loop is interrupted through the engine interrupt handler; the probe records that handler being invoked.
- Exceptions pending across `finally` and suspended host calls retain their originating value. Native exceptions created immediately after resumption retain the correct JS backtrace.
- 100 rounds keep cyclic, locally referenced objects alive through GC while both execution stacks are suspended. Both resume orders are exercised, with GC between resumptions and after disposal.
- The executable exits naturally with engine assertions enabled and no native diagnostics. Output-reader threads are joined before classifying diagnostics.

The positive run passes 19 checks. The negative control deliberately omits restoration of `current_stack_frame`: normal values still match, but both native backtrace checks fail and their stacks are empty. `run.ps1` requires exactly those two negative-control failures. This demonstrates why successful return values alone would miss an execution-state bug.

## Mechanism and costs

`prototype.c` includes the pinned `quickjs.c` in the same translation unit so it can inspect private runtime state. At suspension it saves and detaches the current frame, stack bounds, exception value, exception/backtrace recursion flags, and parent-promise pointer. It restores them before entering a suspended fiber. The fibers execute on one OS thread; the runtime is never concurrently entered by separate threads. Suspended stacks are resumed to unwind before being deleted.

This is evidence for a small explicit native suspension boundary, **not proof that every saved field is necessary or sufficient for arbitrary QuickJS execution**. Direct private-state access is suitable for this disposable probe. Product integration would need a maintained accessor boundary, paired Rust bindings, a scheduler that keeps the engine on its owning thread, and verified cancellation/teardown across suspended Rust frames.

## Not established

- fjs, rquickjs Rust frames, FRB callbacks, Tokio scheduling, or the Flutter application have not been switched to fibers or validated by this probe.
- The compiler here is MinGW C; this is not evidence for the product's MSVC/Rust build.
- Android, iOS, macOS, and Linux remain `not-run`.
- Promise-job ownership, module loading, arbitrary JS reentrancy, stack exhaustion, active LRU eviction, and a complete private-state audit are not covered.
- Controller-selected resumption proves the native stack capability, not fairness or correctness of a production I/O scheduler.
- The frozen golden remains unchanged. This result does not promote any ticket or complete source-compatibility gate.

## Evidence

- [Positive run](evidence/windows.json)
- [Negative control](evidence/windows-no-frame-restore.json)
- [Source, engine, compiler and binary identities](evidence/manifest.json)
- Both runs also retain native JSON-line event transcripts.

The subsequent Windows fjs/Rust/FRB integration has passed the ten-observation state differential, cancellation/lifecycle gates and Windows application validation; see the separate product evidence above. Other platforms and wider compatibility remain unproven. This directory preserves the original disposable probe.
