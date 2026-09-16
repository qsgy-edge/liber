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
