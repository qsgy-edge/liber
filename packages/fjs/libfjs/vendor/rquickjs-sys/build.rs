#![allow(clippy::uninlined_format_args)]
use std::{
    env, fs,
    path::{Path, PathBuf},
    process::{self},
};

// WASI logic lifted from https://github.com/bytecodealliance/javy/blob/61616e1507d2bf896f46dc8d72687273438b58b2/crates/quickjs-wasm-sys/build.rs#L18

const WASI_SDK_VERSION_MAJOR: usize = 24;
const WASI_SDK_VERSION_MINOR: usize = 0;

/// The interrupt poll quantum ADR 0009 settles for the whole runtime. The
/// pinned QuickJS sources poll once per 10 000 interpreter or libregexp steps;
/// the build copy polls five times as often so a deadline is noticed sooner.
const POLL_QUANTUM: &str = "1000";

/// The two definitions the build copy replaces, each of which must occur
/// exactly once. A QuickJS bump that moves or renumbers either define fails the
/// build here instead of silently restoring the pinned 10 000.
fn poll_quantum_patches() -> [(&'static str, String, String); 2] {
    [
        (
            "quickjs.c",
            "JS_INTERRUPT_COUNTER_INIT 10000".to_string(),
            format!("JS_INTERRUPT_COUNTER_INIT {POLL_QUANTUM}"),
        ),
        (
            "libregexp.c",
            "INTERRUPT_COUNTER_INIT 10000".to_string(),
            format!("INTERRUPT_COUNTER_INIT {POLL_QUANTUM}"),
        ),
    ]
}

/// Replaces both poll constants in the build copy and asserts each replacement
/// happened, so the two defines cannot drift apart from this build script.
fn patch_poll_quantum(out_dir: &Path) {
    for (file, pinned, patched) in poll_quantum_patches() {
        let path = out_dir.join(file);
        let source = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("cannot read the build copy of {file}: {error}"));
        assert_eq!(
            source.matches(&pinned).count(),
            1,
            "{file} does not carry exactly one `{pinned}`; update poll_quantum_patches() \
             for this QuickJS revision"
        );
        let patched_source = source.replace(&pinned, &patched);
        assert_eq!(
            patched_source.matches(&pinned).count(),
            0,
            "{file} still carries `{pinned}` after the poll-quantum patch"
        );
        assert_eq!(
            patched_source.matches(&patched).count(),
            1,
            "{file} does not carry exactly one `{patched}` after the poll-quantum patch"
        );
        fs::write(&path, patched_source)
            .unwrap_or_else(|error| panic!("cannot write the build copy of {file}: {error}"));
    }
}

/// The bytes reserved by a running script's allocation checks for building the
/// out-of-memory error object. `JS_ThrowError2` throws `JS_NULL` when
/// `JS_MakeError` cannot allocate (tickets #77/#79); this headroom preserves the
/// report in the measured budget-limited shapes, not under system allocation
/// failure. `JS_ThrowOutOfMemory` marks the throw path with `in_out_of_memory`,
/// and only that path's checks see the whole `malloc_limit`. Checks precede
/// allocator rounding and accounting; they are not a process RSS cap. A limit
/// at or below the headroom keeps the previous behaviour without a reserve.
///
/// The runtime also selects rquickjs's `rust-alloc` feature (#111): its usable
/// sizes are aligned requests, not the libc allocator's potentially much larger
/// slack. Without that, an accepted allocation can consume this reserve and even
/// exceed the cap before the next limit check. Heap usage after eval unwinds is
/// not the usage at refusal. Keep this reserve at 16 KiB.
///
/// `js_malloc_limit_exceeded()` replaces the pinned limit arithmetic, which a
/// 32-bit target can wrap: with `malloc_size` of a few kilobytes,
/// `new ArrayBuffer(8).transfer(4294967295)` made
/// `malloc_size + SIZE_MAX - 8` wrap to `malloc_size - 9`, so the pinned check
/// accepted a request of `SIZE_MAX` bytes, `RustAllocator::round_size` rounded
/// it up to 2^32 (back to zero), the allocator handed back a header-only block,
/// and the transfer then cleared ~4 GB outside it (#111). The helper also
/// refuses the requests the selected allocator cannot lay out at all; see
/// `JS_ALLOC_LAYOUT_PADDING`.
const OOM_HEADROOM_HELPER: &str = r#"/* Bytes reserved by script allocation checks for the out-of-memory
   error object and its message string, not a system-allocation guarantee.
   JS_ThrowError2 throws JS_NULL when JS_MakeError cannot allocate,
   and the report is lost (#79); JS_ThrowOutOfMemory marks
   the throw path with in_out_of_memory, which is the only path that sees the
   whole malloc_limit. A limit at or below the headroom keeps the old
   behaviour. */
#define JS_OOM_HEADROOM (16 * 1024)

/* The allocator this build selects (rquickjs's rust-alloc) rounds every request
   up to the alignment of u64 (8 bytes) and keeps an 8-byte size header in front
   of the block it returns, so laying a request out needs this much padding on
   top of it. A request in the last JS_ALLOC_LAYOUT_PADDING bytes of the address
   space cannot be laid out: the rounding wraps and the allocator returns a
   block it never sized for that request. Refuse those requests at the limit
   check instead (#111). */
#define JS_ALLOC_LAYOUT_PADDING ((8 - 1) + 8)

static size_t js_malloc_limit(JSRuntime *rt)
{
    size_t limit = rt->malloc_state.malloc_limit;

    if (limit != 0 && !rt->in_out_of_memory && limit > JS_OOM_HEADROOM)
        limit -= JS_OOM_HEADROOM;
    return limit;
}

/* True when a request of `size` bytes on top of `tracked` already tracked bytes
   must be refused. This is the pinned test `tracked + size > js_malloc_limit(rt)
   - 1` computed so that neither the sum nor the subtraction can wrap, so the
   16 KiB reserve applies to it exactly as it does to the pinned checks;
   `tracked` is `malloc_size` for js_malloc_rt/js_calloc_rt and
   `malloc_size - old_size` for js_realloc_rt. Two deliberate differences from
   the pinned form, and only where the pinned form wrapped or could not be
   satisfied: a request the allocator cannot lay out is refused above, and with
   `malloc_limit == 0` (unlimited) a request that would take the tracked total
   to SIZE_MAX is refused too, where the pinned form accepted it (`limit - 1`
   is SIZE_MAX there) although no allocator can satisfy that total. */
static bool js_malloc_limit_exceeded(JSRuntime *rt, size_t tracked, size_t size)
{
    size_t limit = js_malloc_limit(rt);

    if (unlikely(size > SIZE_MAX - JS_ALLOC_LAYOUT_PADDING))
        return true;
    if (limit == 0)
        limit = SIZE_MAX; /* unlimited: the pinned `limit - 1` is SIZE_MAX */
    if (unlikely(tracked >= limit))
        return true;
    return size > limit - 1 - tracked;
}"#;

/// The three allocator limit checks the build copy reroutes through
/// `js_malloc_limit_exceeded()`. Each pinned string must occur exactly once.
/// The pinned `count != (count * size) / size` test above the calloc check
/// stays as it is: with `size > 0` it rejects every wrapping product, so the
/// size the helper is handed cannot itself wrap. Nothing is allocated, freed or
/// cleared between these checks and the requests they decide.
const OOM_HEADROOM_LIMIT_CHECKS: [(&str, &str); 3] = [
    (
        "s->malloc_size + (count * size) > s->malloc_limit - 1",
        "js_malloc_limit_exceeded(rt, s->malloc_size, count * size)",
    ),
    (
        "s->malloc_size + size > s->malloc_limit - 1",
        "js_malloc_limit_exceeded(rt, s->malloc_size, size)",
    ),
    (
        "s->malloc_size + size - old_size > s->malloc_limit - 1",
        "js_malloc_limit_exceeded(rt, s->malloc_size - old_size, size)",
    ),
];

/// Reserves capacity for the budget-limit report in the build copy of
/// `quickjs.c` and keeps every limit decision free of wrapping arithmetic:
/// inserts the headroom helper before the first allocator helper and routes the
/// three limit checks through it, asserting each edit lands exactly once. This
/// does not guarantee allocation under system exhaustion. The anchor is a
/// single line, so a CRLF or LF checkout patches identically. The frozen
/// `quickjs/` sources stay unchanged, as `LIBER.md` records.
fn patch_oom_headroom(out_dir: &Path) {
    let path = out_dir.join("quickjs.c");
    let source = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read the build copy of quickjs.c: {error}"));

    let anchor = "static size_t js_malloc_usable_size_unknown(const void *ptr)";
    assert_eq!(
        source.matches(anchor).count(),
        1,
        "quickjs.c does not carry exactly one `{anchor}`; update patch_oom_headroom() for this \
         QuickJS revision"
    );
    let mut patched_source = source.replace(anchor, &format!("{OOM_HEADROOM_HELPER}\n{anchor}"));
    assert_eq!(
        patched_source.matches(OOM_HEADROOM_HELPER).count(),
        1,
        "quickjs.c does not carry exactly one OOM-headroom helper after the patch"
    );

    for (pinned, patched) in OOM_HEADROOM_LIMIT_CHECKS {
        assert_eq!(
            patched_source.matches(pinned).count(),
            1,
            "quickjs.c does not carry exactly one `{pinned}`; update OOM_HEADROOM_LIMIT_CHECKS \
             for this QuickJS revision"
        );
        patched_source = patched_source.replace(pinned, patched);
        assert_eq!(
            patched_source.matches(pinned).count(),
            0,
            "quickjs.c still carries `{pinned}` after the OOM-headroom patch"
        );
        assert_eq!(
            patched_source.matches(patched).count(),
            1,
            "quickjs.c does not carry exactly one `{patched}` after the OOM-headroom patch"
        );
    }

    fs::write(&path, patched_source)
        .unwrap_or_else(|error| panic!("cannot write the build copy of quickjs.c: {error}"));
}

/// The `ArrayBuffer.prototype.transfer` request the build copy bounds. That
/// function takes a `uint64_t` length and hands it to `js_realloc`, whose size
/// is a `size_t`, so on a 32-bit target the pinned code truncates the length
/// first: `transfer(2**32)` reaches `js_realloc_rt` as a zero-byte realloc,
/// which frees the backing store the ArrayBuffer still points at, and a length
/// that truncates to a small non-zero size keeps the buffer but `memset`s far
/// past it (#111). A length a `size_t` cannot hold is refused before that
/// conversion. The `INT32_MAX` bound the ArrayBuffer constructor applies is not
/// mirrored here: that bound is upstream behaviour, not a pointer-width
/// truncation.
const TRANSFER_LENGTH_GUARD: (&str, [&str; 2]) = (
    "        new_bs = js_realloc(ctx, bs, new_len);",
    [
        "if (unlikely(new_len > (uint64_t)SIZE_MAX))",
        "    return JS_ThrowRangeError(ctx, \"invalid array buffer length\");",
    ],
);

/// What `patch_transfer_length_guard()` asserts it inserted: one line of the
/// guard, which is unique in the build copy because only this patch writes it.
const TRANSFER_LENGTH_GUARD_NEEDLE: &str = "if (unlikely(new_len > (uint64_t)SIZE_MAX))";

/// Refuses a transfer length wider than the target's `size_t` in the build copy
/// of `quickjs.c`, before the pinned `js_realloc` call converts it. The pinned
/// anchor is a single line and the inserted text is written with the file's own
/// line ending, so a CRLF or LF checkout patches identically. On a 64-bit
/// target `UINTPTR_MAX == UINT64_MAX` and the guard is not compiled, leaving
/// the pinned path byte-identical there.
fn patch_transfer_length_guard(out_dir: &Path) {
    let path = out_dir.join("quickjs.c");
    let source = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read the build copy of quickjs.c: {error}"));

    let newline = if source.contains("\r\n") {
        "\r\n"
    } else {
        "\n"
    };
    let (pinned, lines) = TRANSFER_LENGTH_GUARD;
    assert_eq!(
        source.matches(pinned).count(),
        1,
        "quickjs.c does not carry exactly one `{pinned}`; update TRANSFER_LENGTH_GUARD for this \
         QuickJS revision"
    );
    let guarded: Vec<String> = lines
        .iter()
        .map(|line| format!("            {line}"))
        .collect();
    let guard = format!(
        "        #if UINTPTR_MAX < UINT64_MAX{newline}{}{newline}        #endif",
        guarded.join(newline)
    );
    let patched_source = source.replace(pinned, &format!("{guard}{newline}{pinned}"));
    assert_eq!(
        patched_source.matches(pinned).count(),
        1,
        "the transfer length guard must leave exactly one pinned `{pinned}` in place"
    );
    for needle in ["#if UINTPTR_MAX < UINT64_MAX", TRANSFER_LENGTH_GUARD_NEEDLE] {
        assert_eq!(
            patched_source.matches(needle).count(),
            1,
            "quickjs.c does not carry exactly one `{needle}` after the transfer length guard patch"
        );
    }
    fs::write(&path, patched_source)
        .unwrap_or_else(|error| panic!("cannot write the build copy of quickjs.c: {error}"));
}

fn download_wasi_sdk() -> PathBuf {
    let mut wasi_sdk_dir: PathBuf = env::var("OUT_DIR").unwrap().into();
    wasi_sdk_dir.push("wasi-sdk");

    fs::create_dir_all(&wasi_sdk_dir).unwrap();

    let major_version = WASI_SDK_VERSION_MAJOR;
    let minor_version = WASI_SDK_VERSION_MINOR;

    let mut archive_path = wasi_sdk_dir.clone();
    archive_path.push(format!("wasi-sdk-{major_version}-{minor_version}.tar.gz"));

    println!("SDK tar: {archive_path:?}");

    // Download archive if necessary
    if !archive_path.try_exists().unwrap() {
        let file_suffix = match (env::consts::OS, env::consts::ARCH) {
            ("linux", "x86") | ("linux", "x86_64") => "x86_64-linux",
            ("linux", "aarch64") => "arm64-linux",
            ("macos", "x86") | ("macos", "x86_64") => "x86_64-macos",
            ("macos", "aarch64") => "arm64-macos",
            ("windows", "x86") | ("windows", "x86_64") => "x86_64-windows",
            ("windows", "aarch64") => "arm64-windows",
            other => panic!("Unsupported platform tuple {:?}", other),
        };

        let uri = format!("https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-{major_version}/wasi-sdk-{major_version}.{minor_version}-{file_suffix}.tar.gz");

        println!("Downloading WASI SDK archive from {uri} to {archive_path:?}");

        let output = process::Command::new("curl")
            .args([
                "--location",
                "-o",
                archive_path.to_string_lossy().as_ref(),
                uri.as_ref(),
            ])
            .output()
            .expect("failed to download the WASI SDK with curl");
        println!("curl output: {}", String::from_utf8_lossy(&output.stdout));
        println!("curl err: {}", String::from_utf8_lossy(&output.stderr));
        if !output.status.success() {
            panic!(
                "curl WASI SDK failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    let mut test_binary = wasi_sdk_dir.clone();
    test_binary.extend(["bin", "wasm-ld"]);
    // Extract archive if necessary
    if !test_binary.try_exists().unwrap() {
        println!("Extracting WASI SDK archive {archive_path:?}");
        let output = process::Command::new("tar")
            .args([
                "-zxf",
                archive_path.to_string_lossy().as_ref(),
                "--strip-components",
                "1",
            ])
            .current_dir(&wasi_sdk_dir)
            .output()
            .unwrap();
        if !output.status.success() {
            panic!(
                "Unpacking WASI SDK failed: {}",
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }

    wasi_sdk_dir
}

fn get_wasi_sdk_path() -> PathBuf {
    std::env::var_os("WASI_SDK")
        .map(PathBuf::from)
        .unwrap_or_else(download_wasi_sdk)
}

fn main() {
    #[cfg(feature = "logging")]
    pretty_env_logger::init();

    let features = [
        "bindgen",
        "update-bindings",
        "dump-bytecode",
        "dump-gc",
        "dump-gc-free",
        "dump-free",
        "dump-leaks",
        "dump-mem",
        "dump-objects",
        "dump-atoms",
        "dump-shapes",
        "dump-module-resolve",
        "dump-promise",
        "dump-read-object",
        "disable-assertions",
    ];

    for feature in &features {
        println!("cargo:rerun-if-env-changed={}", feature_to_cargo(feature));
    }
    println!("cargo:rerun-if-env-changed=CARGO_CFG_SANITIZE");

    let src_dir = Path::new("quickjs");

    let out_dir = env::var("OUT_DIR").expect("No OUT_DIR env var is set by cargo");
    let out_dir = Path::new(&out_dir);

    let header_files = [
        "builtin-array-fromasync.h",
        "builtin-iterator-zip-keyed.h",
        "builtin-iterator-zip.h",
        "cutils.h",
        "dtoa.h",
        "libregexp-opcode.h",
        "libregexp.h",
        "libunicode-table.h",
        "libunicode.h",
        "list.h",
        "quickjs-atom.h",
        "quickjs-opcode.h",
        "quickjs-c-atomics.h",
        "quickjs.h",
    ];

    let source_files = ["libregexp.c", "libunicode.c", "quickjs.c", "dtoa.c"];

    let mut defines: Vec<(String, Option<&str>)> = vec![("_GNU_SOURCE".into(), None)];

    #[cfg(feature = "disable-assertions")]
    defines.push(("NDEBUG".into(), None));

    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap();
    let target_env = env::var("CARGO_CFG_TARGET_ENV").unwrap();

    let mut builder = cc::Build::new();
    builder
        .extra_warnings(false)
        .flag_if_supported("-Wno-implicit-const-int-float-conversion")
        //.flag("-Wno-array-bounds")
        //.flag("-Wno-format-truncation")
        ;

    match env::var("CARGO_CFG_SANITIZE").as_deref() {
        Ok("address") => {
            builder
                .flag("-fsanitize=address")
                .flag("-fno-sanitize-recover=all")
                .flag("-fno-omit-frame-pointer");
        }
        Ok("memory") => {
            builder
                .flag("-fsanitize=memory")
                .flag("-fno-sanitize-recover=all")
                .flag("-fno-omit-frame-pointer");
        }
        Ok("thread") => {
            builder
                .flag("-fsanitize=thread")
                .flag("-fno-sanitize-recover=all")
                .flag("-fno-omit-frame-pointer");
        }
        Ok(x) => println!("cargo:warning=Unsupported sanitize_option: '{x}'"),
        _ => {}
    }

    let mut bindgen_cflags = vec![];

    if target_os == "windows" {
        if target_env == "msvc" {
            env::set_var(
                "CFLAGS",
                "/DWIN32_LEAN_AND_MEAN /std:c11 /experimental:c11atomics",
            );
        } else {
            env::set_var("CFLAGS", "-DWIN32_LEAN_AND_MEAN -std=c11");
        }
    }

    if target_os == "wasi" {
        // pretend we're emscripten - there are already ifdefs that match
        // also, wasi doesn't ahve FE_DOWNWARD or FE_UPWARD
        defines.push(("EMSCRIPTEN".into(), Some("1")));
        defines.push(("FE_DOWNWARD".into(), Some("0")));
        defines.push(("FE_UPWARD".into(), Some("0")));
    }

    for file in source_files.iter().chain(header_files.iter()) {
        println!("cargo:rerun-if-changed={}", src_dir.join(file).display());
        fs::copy(src_dir.join(file), out_dir.join(file))
            .expect("Unable to copy source; try 'git submodule update --init'");
    }
    // Keep the frozen QuickJS sources untouched; only the build copy is patched.
    patch_poll_quantum(out_dir);
    patch_oom_headroom(out_dir);
    patch_transfer_length_guard(out_dir);
    println!("cargo:rerun-if-changed=quickjs.bind.h");
    fs::copy("quickjs.bind.h", out_dir.join("quickjs.bind.h")).expect("Unable to copy source");

    if target_os == "wasi" && !matches!(env::var("RQUICKJS_SYS_NO_WASI_SDK").as_deref(), Ok("1")) {
        let wasi_sdk_path = get_wasi_sdk_path();
        if !wasi_sdk_path.try_exists().unwrap() {
            panic!(
                "wasi-sdk not installed in specified path of {}",
                wasi_sdk_path.display()
            );
        }
        env::set_var("CC", wasi_sdk_path.join("bin/clang").to_str().unwrap());
        env::set_var("AR", wasi_sdk_path.join("bin/ar").to_str().unwrap());
        let sysroot = format!(
            "--sysroot={}",
            wasi_sdk_path.join("share/wasi-sysroot").display()
        );
        env::set_var("CFLAGS", &sysroot);
        bindgen_cflags.push(sysroot);
    }

    // generating bindings
    bindgen(
        out_dir,
        out_dir.join("quickjs.bind.h"),
        &defines,
        bindgen_cflags,
    );

    for (name, value) in &defines {
        builder.define(name, *value);
    }

    for src in &source_files {
        builder.file(out_dir.join(src));
    }

    builder.compile("libquickjs.a");
}

fn feature_to_cargo(name: impl AsRef<str>) -> String {
    format!("CARGO_FEATURE_{}", feature_to_define(name))
}

fn feature_to_define(name: impl AsRef<str>) -> String {
    name.as_ref().to_uppercase().replace('-', "_")
}

#[cfg(not(feature = "bindgen"))]
fn bindgen<'a, D, H, X, K, V>(out_dir: D, _header_file: H, _defines: X, _add_cflags: Vec<String>)
where
    D: AsRef<Path>,
    H: AsRef<Path>,
    X: IntoIterator<Item = &'a (K, Option<V>)>,
    K: AsRef<str> + 'a,
    V: AsRef<str> + 'a,
{
    let target = env::var("TARGET").unwrap();

    if !Path::new("./")
        .join("src")
        .join("bindings")
        .join(format!("{}.rs", target))
        .canonicalize()
        .map(|x| x.exists())
        .unwrap_or(false)
    {
        println!(
            "cargo:warning=rquickjs probably doesn't ship bindings for platform `{}({})`. try the `bindgen` feature instead.",
            target,
            env::var("BUILD_TARGET").unwrap_or("n/a".into())
        );
    }

    let bindings_file = out_dir.as_ref().join("bindings.rs");

    fs::write(
        bindings_file,
        format!(
            r#"macro_rules! bindings_env {{
                ("TARGET") => {{ "{target}" }};
            }}"#
        ),
    )
    .unwrap();
}

#[cfg(feature = "bindgen")]
fn bindgen<'a, D, H, X, K, V>(out_dir: D, header_file: H, defines: X, add_cflags: Vec<String>)
where
    D: AsRef<Path>,
    H: AsRef<Path>,
    X: IntoIterator<Item = &'a (K, Option<V>)>,
    K: AsRef<str> + 'a,
    V: AsRef<str> + 'a,
{
    let out_dir = out_dir.as_ref();
    let header_file = header_file.as_ref();

    let mut cflags = add_cflags;

    //format!("-I{}", out_dir.parent().display()),

    for (name, value) in defines {
        cflags.push(if let Some(value) = value {
            format!("-D{}={}", name.as_ref(), value.as_ref())
        } else {
            format!("-D{}", name.as_ref())
        });
    }

    let mut builder = bindgen_rs::Builder::default()
        .use_core()
        .detect_include_paths(true)
        .clang_arg("-xc")
        .clang_arg("-v")
        .clang_args(cflags)
        .size_t_is_usize(false)
        .header(header_file.display().to_string())
        .allowlist_type("JS.*")
        .allowlist_function("js.*")
        .allowlist_function("JS.*")
        .allowlist_function("__JS.*")
        .allowlist_var("JS.*")
        .opaque_type("FILE")
        .blocklist_type("FILE")
        .blocklist_function("JS_DumpMemoryUsage");

    if env::var("CARGO_CFG_TARGET_OS").unwrap() == "wasi" {
        builder = builder.clang_arg("-fvisibility=default");
    }

    let bindings = builder.generate().expect("Unable to generate bindings");

    let bindings_file = out_dir.join("bindings.rs");

    bindings
        .write_to_file(&bindings_file)
        .expect("Couldn't write bindings");

    // Special case to support bundled bindings
    if env::var("CARGO_FEATURE_UPDATE_BINDINGS").is_ok() {
        let dest_dir = Path::new("src").join("bindings");
        fs::create_dir_all(&dest_dir).unwrap();

        let dest_file = format!("{}.rs", env::var("TARGET").unwrap());
        fs::copy(&bindings_file, dest_dir.join(dest_file)).unwrap();
    }
}
