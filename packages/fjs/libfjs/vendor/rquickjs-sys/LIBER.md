# Liber native stack accessors

This directory vendors `rquickjs-sys 0.12.1` from rquickjs commit
`04e27345bd12e1d9b1eb68d76865805126313998`, with QuickJS submodule
`fd0a0210b7be00957751871e7e01b8291268fc29`.
Only the crate sources, generated bindings, required QuickJS C/header inputs,
and MIT licenses are retained. Upstream test programs and Git metadata are not copied.

The frozen `quickjs/` files are unchanged. The local build-script extension
appends `liber_stack.inc` to the build copy of `quickjs.c`. This makes the
private-state layout compiler-checked without duplicating that layout in Rust.
The accessor saves/detaches/restores stack-frame state, bounds, the pending
exception, exception recursion flags and parent-promise linkage.

`src/runtime/fibers.rs` in libfjs owns Windows fibers and restores this state
before every resumption. All fibers belonging to one engine stay on one OS
thread and share one QuickJS runtime. Fibers must unwind before deletion.
The scheduler holds the existing async-context lock for its lifetime; host
completion/cancellation notifications wake it without acquiring that lock.

The Cargo Git-source patch in libfjs selects this local sys crate for all
rquickjs users, including llrt. Verify with:

```text
cargo tree --manifest-path packages/fjs/libfjs/Cargo.toml -i rquickjs-sys --offline --depth 1
```

The Windows executor is the only platform integrated and exercised here.
Other platforms retain the earlier execution path and need their own
independent-resumption implementation and validation. A passing Windows
result is not a five-platform compatibility claim.

When updating rquickjs/QuickJS, re-check the private runtime fields and rerun
the state, nested, cancellation, GC-pressure and lifecycle gates. Do not
modify the Cargo cache or silently move the dependency revision.
