# Liber fjs candidate

This directory vendors the MIT-licensed fjs package from upstream commit
`8195d78bc0335045fd62bcf4835c3e889b54c77b`, retaining `LICENSE` and the upstream
platform/cargokit build integration. It is a candidate until the Liber runtime
checks and Windows build pass. The product dependency must not point at Temp.

The initial synchronous broker and FRB bindings were copied as a matched pair
from the previously executed Windows experiment. FRB is 2.12.0; the generated
Dart/Rust content-hash check remains enabled. The nested host evaluation API was
regenerated with FRB 2.12.0 as a matched Dart/Rust pair; use the newly built DLL,
not the previous broker DLL.

Local changes in `libfjs/src/api/engine.rs` implement the synchronous two-stage
host broker, owner-scoped request termination, shutdown before host cleanup,
init/close cleanup, and observation of failed starter/cancellation callbacks.
`libfjs/src/api/runtime.rs` removes implicit filesystem/native module fallback;
modules must be explicitly registered. Builtins remain opt-in and Liber must
construct its engine with `JsBuiltinOptions.none()`.

This is not a hostile-code OS isolation boundary. An execution must own a real
cancellation token and await host cleanup; a callback that has already reached
Dart cannot be revoked by aborting its Rust waiter. Do not launch new I/O after
that token is cancelled. The source session owns cookies separately. Explicit
engine close is required, followed by process-level `LibFjs.dispose()` only when
all engines have stopped.

Same-runtime host-to-JS nesting uses `evalBridgeRequestGlobal(requestId, source)`.
The suspended bridge processes these commands on its current QuickJS context;
ordinary `engine.eval` stays queued. Stale request IDs are refused, shutdown
interrupts nested execution, and nested results must be synchronous. The native
channel currently caps each nested script at 64 KiB, the queue at eight entries,
and host nesting at 16. These limits are explicit candidate policy, not a proven
match for Legado's recursive-eval counter.

The product retains inline jsLib closures in a 16-entry cache keyed by library
text and memory limit, with fresh bindings for each evaluation. Same-library
executions are serialized; references are strong until eviction/disposal rather
than Legado's weak-reference cache. Cancellation evicts the affected engine.
Remote-library JSON maps, full Rhino globals/Java APIs, dynamic headers and the
remaining AnalyzeUrl options are not implemented. No full shared-scope or
frozen-oracle compatibility claim follows from the Windows regression tests.
Android/iOS/macOS/Linux remain not-run for this revision.

`liber_html/` is a Liber crate inside the same native build: the frozen HTML rule
adapter (a port of jsoup 1.16.2's selector engine over `html5ever`, plus Legado's
rule layer, ADR 0008). `libfjs` depends on it by path and exposes `html_analyze`
through `libfjs/src/api/html.rs`; the Dart API is
`lib/src/frb/api/html.dart`, re-exported from `lib/fjs.dart`. Its own tests are
independent of the JavaScript runtime:
`cargo test --manifest-path packages/fjs/liber_html/Cargo.toml`.
Re-running the pinned `flutter_rust_bridge_codegen generate` to add that API also
re-emitted the vendored generated files in the tool's current layout; apart from
the new html API the exposed surface is unchanged. The `tool/check_frb_*` scripts
that `libfjs/cargokit.yaml` lists as hash inputs are not vendored in this
repository, so regeneration is the only consistency check here.

Build through the package's existing cargokit integration when building Flutter.
For a native diagnostic build, use `cargo build --release --locked` from
`libfjs/`, keeping the tested target directory and loaded DLL provenance explicit.
Generated bindings can be reproduced with `flutter_rust_bridge_codegen` 2.12.0
and this directory's `flutter_rust_bridge.yaml`; never hand-edit generated code
or disable the content-hash check to accommodate a mismatched DLL.
