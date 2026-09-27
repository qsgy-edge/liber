# Liber vendored rquickjs-sys

This directory vendors `rquickjs-sys 0.12.1` from rquickjs commit
`04e27345bd12e1d9b1eb68d76865805126313998`, with QuickJS submodule
`fd0a0210b7be00957751871e7e01b8291268fc29`.
Only the crate sources, generated bindings, required QuickJS C/header inputs,
and MIT licenses are retained. Upstream test programs and Git metadata are not copied.

The frozen `quickjs/` files are unchanged. The local build-script extension
patches only the build copy of `quickjs.c` and `libregexp.c`: the interrupt poll
quantum falls from the pinned 10 000 to 1 000 in both, the value ADR 0009 settles
for the one execution model all five platforms run. QuickJS polls its interrupt
handler once per parser step (`JS_INTERRUPT_COUNTER_INIT`) and once per backtracking
step (`INTERRUPT_COUNTER_INIT`), so the quantum bounds how late a deadline is
noticed by work that stays inside the interpreter. The build script asserts that
each of the two replacements happened exactly once and fails the build otherwise,
so a QuickJS bump that moves or renumbers either define cannot silently restore
10 000.

The same build script patches `quickjs.c`'s memory-limit checks to reserve
capacity for the out-of-memory error object (ticket #79) and to keep every limit
decision free of wrapping arithmetic (#111). It inserts a `js_malloc_limit()`
helper before the first allocator helper and routes
the three limit checks -- `js_malloc_rt`, `js_calloc_rt`, `js_realloc_rt` --
through it. While `in_out_of_memory` is false those checks use a limit 16 KiB
below the configured cap; `JS_ThrowOutOfMemory` sets that flag around the throw,
so report construction can use the reserved capacity. This preserves the report
in the measured budget-limited shapes, not under every allocation failure.
Without it `JS_ThrowError2` throws `JS_NULL` when `JS_MakeError` cannot
allocate and the script sees `Runtime error: null` instead. The script asserts the helper and
each of the three replacements happened exactly once and fails the build
otherwise; the frozen `quickjs/quickjs.c` is not touched.

The three checks go through `js_malloc_limit_exceeded(rt, tracked, size)`, which
reaches the same decision as the pinned test `tracked + size > js_malloc_limit(rt)
- 1` -- the same reserved limit, so the 16 KiB reserve still holds the running
script short of the cap -- wherever that test did not wrap, and refuses the
requests it could not decide. (`tracked` is `malloc_size` for malloc/calloc and
`malloc_size - old_size` for realloc.) On a 32-bit target the pinned form
misjudged a request near `SIZE_MAX`: with a few kilobytes tracked,
`new ArrayBuffer(8).transfer(4294967295)` made `malloc_size + SIZE_MAX - 8` wrap
to `malloc_size - 9`, so the request was accepted, `RustAllocator::round_size`
rounded it up to 2^32 -- back to zero -- the allocator returned a header-only
block, and the transfer then cleared ~4 GB outside it. The helper also refuses
any request the selected allocator cannot lay out: `rust-alloc` rounds a request
up to `align_of::<u64>()` and keeps an 8-byte header in front of the block, so
a request in the last `JS_ALLOC_LAYOUT_PADDING` (15) bytes of the address space
would wrap that arithmetic. That bound is reachable without a limit:
`JsEngineRuntimeOptions { memory_limit: None, .. }` leaves `malloc_limit` at 0,
where only the layout bound can refuse such a request. Where nothing wraps the
helper decides exactly what the pinned test decided; the two deliberate
differences are that wrapping requests are refused and that with an unlimited
limit a request that would take the tracked total to `SIZE_MAX` is refused (the
pinned form accepted that total, which no allocator can satisfy). `count * size`
stays covered by the pinned `count != (count * size) / size` test above the
calloc check, which rejects every wrapping product for `size > 0`.

The build script also bounds one 32-bit truncation in
`ArrayBuffer.prototype.transfer`, which takes a `uint64_t` length and passes it
to `js_realloc`, whose size parameter is a `size_t`: a length wider than the
target's `size_t` is refused with a `RangeError` before the conversion. Without
it the pinned code truncates first: `transfer(2**32)` reaches `js_realloc_rt` as
a zero-byte realloc and frees the backing store the ArrayBuffer still points at,
while a length that truncates to a small non-zero size keeps the buffer and
`memset`s far past it. The guard is compiled only where `UINTPTR_MAX` is
narrower than `UINT64_MAX`; on a 64-bit target the pinned path is unchanged.

The rows for the three limit checks and the transfer length guard are
`pointer_width_transfer_boundaries_report_and_keep_the_buffer` and the three
heap-limit rows in `libfjs/src/tests/memory_tests.rs`; the first runs only on a
32-bit target and says so elsewhere. The i686 job of the probe branch
(`probe/111-b20-r6`) is what executes them, once against this build script and
once against the one the review audited. That is arithmetic and engine
evidence, not an Android run: the Android `armeabi-v7a` build (an APK carries
`libfjs.so` for arm64-v8a, armeabi-v7a and x86_64) compiles this code at 32-bit
width but has never executed it on a device, so the Android pointer-width row
stays `not-run`.

Libfjs also selects rquickjs's existing `rust-alloc` feature (#111), on every
platform. Without that feature `RawRuntime::new` calls `JS_NewRuntime`, using
libc, not rquickjs's header-based Rust allocator. QuickJS checks requested bytes
before allocating but charges the allocator's usable size afterwards, including
OS slack. The macOS Dart probe reached 16 932 864 tracked bytes with a 16 777 216
limit; even the 96-byte error object was then refused, so `JS_MakeError` failed
and `JS_ThrowError2` threw null. The same Rust test executable did not reproduce
that failure. The row's small *post-eval* heap was measured after array cleanup,
not at refusal; `new Array(4000000).fill` grows its backing array during fill,
rather than making one allocation against an empty budget.

`RustAllocator` uses Rust's global allocator and reports requests rounded to
`align_of::<u64>()`, stored in a header, rather than exposing the system
allocator's extra slack. This changes array growth, GC accounting and allocation
callbacks across all five platforms; it does not change the configured heap
limit, the 16 KiB reserve, the recursion guard, or error mapping. The budget is
QuickJS's tracked allocation accounting, not a process RSS cap: OS slack and
allocator metadata are not all counted (the Rust header is not included in its
reported usable size; QuickJS's fixed overhead is 0 on Apple and 8 elsewhere).
#111 adds the wrapping-safe limit helper and the transfer length guard above and
changes no other C patch logic; the frozen `quickjs/` sources stay unchanged.
Limits at or
below 16 KiB retain the existing no-reserve behaviour. System allocator failure
can still prevent an error object from being built; arbitrary small limits and
alignment/overhead boundary values other than the ones the pointer-width row
executes have not been proven.

There is no stack accessor any more. The Windows fiber scheduler that needed one
— to detach and restore QuickJS's stack-frame state before every resumption — is
removed (ticket #25, ADR 0009), so the runtime never switches stacks and the
runtime's stack fields are never saved. Nothing in this directory reads or writes
QuickJS private layout.

The Cargo Git-source patch in libfjs selects this local sys crate for all
rquickjs users, including llrt. Verify with:

```text
cargo tree --manifest-path packages/fjs/libfjs/Cargo.toml -i rquickjs-sys --offline --depth 1
```

`libfjs/cargokit.yaml` lists `libfjs/vendor` among its `hash_inputs`, so a
patched vendored tree rebuilds the prebuilt binary instead of reusing one built
from the unpatched sources.

The runtime is exercised on Windows, Linux and macOS through the shared gate list
in `tool/ci_runtime.py` and the limits harness in
`tool/runtime_limits_prototype/`; Android and iOS cross-build the native library
only, and the 32-bit rows above were executed on an i686 Linux runner rather
than a device. When updating rquickjs/QuickJS, re-check the poll-quantum defines
this build script patches, the allocator layout `JS_ALLOC_LAYOUT_PADDING` is
derived from, and the `js_realloc` call `TRANSFER_LENGTH_GUARD` bounds, then
rerun the state, nested, cancellation, GC-pressure, lifecycle and
pointer-width gates. Do not modify the Cargo cache or silently move the
dependency revision.
