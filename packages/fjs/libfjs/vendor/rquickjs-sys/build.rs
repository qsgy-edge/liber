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

/// The bytes of tracked heap kept out of a running script's reach so the
/// out-of-memory error object can always be built. `JS_ThrowError2` throws
/// `JS_NULL` when `JS_MakeError` cannot allocate, and the report is lost
/// (tickets #77/#79); this headroom is what makes that allocation succeed.
/// `JS_ThrowOutOfMemory` marks the throw path with `in_out_of_memory`, and
/// that is the only path that sees the whole `malloc_limit`, so a script still
/// cannot push the tracked heap past the configured limit. A limit at or below
/// the headroom keeps the previous behaviour.
///
/// 16 KiB kept the report on Windows and Linux and did not on macOS (CI run
/// `36227056236`: the gate's own over-limit request still came back as
/// `Runtime error: null` there while the fine-grained shape reported the limit,
/// so the space left at the refusal is what macOS needs more of). The tracked
/// total is adjusted by the allocator's *usable* sizes, so a platform whose
/// rounding overshoots the reduced limit eats into the reserve; 64 KiB is that
/// margin times a wide factor, at 0.1 % of the product's 64 MiB cap.
const OOM_HEADROOM_HELPER: &str = r#"/* Bytes of the tracked heap kept out of a running script's reach so the
   out-of-memory error object (and its message string) can always be
   allocated. JS_ThrowError2 otherwise throws JS_NULL when JS_MakeError
   cannot allocate, and the report is lost (#79); JS_ThrowOutOfMemory marks
   the throw path with in_out_of_memory, which is the only path that sees the
   whole malloc_limit. The tracked total moves by the allocator's usable
   sizes, so the reserve has to exceed that platform's rounding; a limit at or
   below the headroom keeps the old behaviour. */
#define JS_OOM_HEADROOM (64 * 1024)

static size_t js_malloc_limit(JSRuntime *rt)
{
    size_t limit = rt->malloc_state.malloc_limit;

    if (limit != 0 && !rt->in_out_of_memory && limit > JS_OOM_HEADROOM)
        limit -= JS_OOM_HEADROOM;
    return limit;
}"#;

/// The three allocator limit checks the build copy reroutes through
/// `js_malloc_limit()`. Each pinned string must occur exactly once.
const OOM_HEADROOM_LIMIT_CHECKS: [(&str, &str); 3] = [
    (
        "s->malloc_size + (count * size) > s->malloc_limit - 1",
        "s->malloc_size + (count * size) > js_malloc_limit(rt) - 1",
    ),
    (
        "s->malloc_size + size > s->malloc_limit - 1",
        "s->malloc_size + size > js_malloc_limit(rt) - 1",
    ),
    (
        "s->malloc_size + size - old_size > s->malloc_limit - 1",
        "s->malloc_size + size - old_size > js_malloc_limit(rt) - 1",
    ),
];

/// Patches the build copy of `quickjs.c` so an out-of-memory error object can
/// always be allocated, however little of the heap the failing request left:
/// inserts the headroom helper before the first allocator helper and routes
/// the three limit checks through it, asserting each edit lands exactly once.
/// The anchor is a single line, so a CRLF or LF checkout patches identically.
/// The frozen `quickjs/` sources stay unchanged, as `LIBER.md` records.
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
    let mut patched_source =
        source.replace(anchor, &format!("{OOM_HEADROOM_HELPER}\n{anchor}"));
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
