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

The same build script patches `quickjs.c`'s memory-limit checks so the
out-of-memory error object can always be allocated (ticket #79). It inserts a
`js_malloc_limit()` helper before the first allocator helper and routes the
three limit checks -- `js_malloc_rt`, `js_calloc_rt`, `js_realloc_rt` --
through it. While `in_out_of_memory` is false those checks stop a running
script 16 KiB short of the configured limit; `JS_ThrowOutOfMemory` sets that
flag around the throw, so the `InternalError: out of memory` report always has
room. Without it `JS_ThrowError2` throws `JS_NULL` when `JS_MakeError` cannot
allocate and the script sees `Runtime error: null` instead. The script asserts the helper and
each of the three replacements happened exactly once and fails the build
otherwise; the frozen `quickjs/quickjs.c` is not touched.

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
The frozen sources and C patch logic remain unchanged by #111.

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
only. When updating rquickjs/QuickJS, re-check the poll-quantum defines this
build script patches and rerun the state, nested, cancellation, GC-pressure and
lifecycle gates. Do not modify the Cargo cache or silently move the dependency
revision.
