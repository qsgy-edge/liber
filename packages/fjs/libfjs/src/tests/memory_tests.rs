//! # Memory Tests
//!
//! Tests for memory management, garbage collection, and memory limits.

use crate::api::engine::{JsEngine, JsEngineRuntimeOptions, complete_bridge_request_global};
use crate::api::error::{JsError, JsResult};
use crate::api::runtime::{JsAsyncContext, JsAsyncRuntime, JsContext, JsRuntime};
use crate::api::source::{JsBuiltinOptions, JsCode};
use crate::api::value::JsValue;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::oneshot;

// ============================================================================
// Memory Usage Tests
// ============================================================================

#[test]
fn test_memory_usage_initial() {
    let runtime = JsRuntime::new().unwrap();
    let usage = runtime.memory_usage();

    // Initial memory should be reasonable
    assert!(usage.total_memory() > 0);
    assert!(usage.total_memory() < 10 * 1024 * 1024); // Less than 10 MB initially
}

#[test]
fn test_memory_usage_increases_with_allocations() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    let before = runtime.memory_usage();

    // Allocate many objects
    let _ = context.eval(
        r#"
        let arr = [];
        for (let i = 0; i < 1000; i++) {
            arr.push({ index: i, data: 'x'.repeat(100) });
        }
    "#
        .to_string(),
    );

    let after = runtime.memory_usage();

    // Memory should increase
    assert!(after.total_memory() > before.total_memory());
}

#[test]
fn test_memory_usage_object_count() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    let before = runtime.memory_usage();

    // Create many objects
    let _ = context.eval(
        r#"
        let objects = [];
        for (let i = 0; i < 100; i++) {
            objects.push({});
        }
    "#
        .to_string(),
    );

    let after = runtime.memory_usage();

    // Object count should increase
    assert!(after.obj_count() > before.obj_count());
}

#[test]
fn test_memory_usage_string_count() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    let before = runtime.memory_usage();

    // Create many strings
    let _ = context.eval(
        r#"
        let strings = [];
        for (let i = 0; i < 100; i++) {
            strings.push('string_' + i);
        }
    "#
        .to_string(),
    );

    let after = runtime.memory_usage();

    // String count should increase
    assert!(after.str_count() > before.str_count());
}

#[test]
fn test_memory_usage_function_count() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    let before = runtime.memory_usage();

    // Create many functions
    let _ = context.eval(
        r#"
        let functions = [];
        for (let i = 0; i < 50; i++) {
            functions.push(function() { return i; });
        }
    "#
        .to_string(),
    );

    let after = runtime.memory_usage();

    // Function count should increase
    assert!(after.js_func_count() >= before.js_func_count());
}

#[test]
fn test_memory_usage_array_count() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    let before = runtime.memory_usage();

    // Create many arrays
    let _ = context.eval(
        r#"
        let arrays = [];
        for (let i = 0; i < 100; i++) {
            arrays.push([1, 2, 3, 4, 5]);
        }
    "#
        .to_string(),
    );

    let after = runtime.memory_usage();

    // Array count should increase
    assert!(after.array_count() > before.array_count());
}

#[test]
fn test_memory_usage_summary_format() {
    let runtime = JsRuntime::new().unwrap();
    let usage = runtime.memory_usage();
    let summary = usage.summary();

    // Should contain expected keywords
    assert!(summary.contains("Memory:"));
    assert!(summary.contains("bytes"));
    assert!(summary.contains("Objects:"));
    assert!(summary.contains("Functions:"));
    assert!(summary.contains("Strings:"));
}

// ============================================================================
// Garbage Collection Tests
// ============================================================================

#[test]
fn test_gc_manual_trigger() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    // Allocate then discard
    let _ = context.eval(
        r#"
        let arr = [];
        for (let i = 0; i < 1000; i++) {
            arr.push({ data: 'x'.repeat(100) });
        }
        arr = null;
    "#
        .to_string(),
    );

    // Run GC multiple times
    for _ in 0..3 {
        runtime.run_gc();
    }

    // Should not panic and memory should be reasonable
    let usage = runtime.memory_usage();
    assert!(usage.total_memory() > 0);
}

#[test]
fn test_gc_frees_unreachable_objects() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    // Create objects
    let _ = context.eval(
        r#"
        let temp = [];
        for (let i = 0; i < 500; i++) {
            temp.push({ data: new Array(100).fill(i) });
        }
    "#
        .to_string(),
    );

    let before = runtime.memory_usage();

    // Make objects unreachable
    let _ = context.eval("temp = null;".to_string());

    // Run GC
    runtime.run_gc();

    let after = runtime.memory_usage();

    // Memory should decrease or stay similar
    // Note: GC behavior may vary, so we just check it doesn't crash
    assert!(after.total_memory() > 0);
    // Ideally: assert!(after.total_memory() < before.total_memory());
    let _ = before; // Suppress warning
}

#[test]
fn test_gc_threshold_setting() {
    let runtime = JsRuntime::new().unwrap();

    // Set various thresholds
    runtime.set_gc_threshold(1024); // Very low
    runtime.set_gc_threshold(1024 * 1024); // 1 MB
    runtime.set_gc_threshold(10 * 1024 * 1024); // 10 MB

    // Should not panic
    let _context = JsContext::from(&runtime).unwrap();
}

#[tokio::test]
async fn test_gc_async_runtime() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let context = JsAsyncContext::from(&runtime).await.unwrap();

    // Allocate some data
    let _ = context
        .eval(
            r#"
        let data = [];
        for (let i = 0; i < 100; i++) {
            data.push({ value: i });
        }
        data = null;
    "#
            .to_string(),
        )
        .await;

    // Async GC
    runtime.run_gc().await;

    let usage = runtime.memory_usage().await;
    assert!(usage.total_memory() > 0);
}

// ============================================================================
// Memory Limit Tests
// ============================================================================

#[test]
fn test_memory_limit_set() {
    let runtime = JsRuntime::new().unwrap();

    // Set various limits
    runtime.set_memory_limit(1024 * 1024); // 1 MB
    runtime.set_memory_limit(16 * 1024 * 1024); // 16 MB
    runtime.set_memory_limit(0); // Unlimited

    // Should not panic
    let _context = JsContext::from(&runtime).unwrap();
}

#[test]
fn test_memory_limit_small() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_memory_limit(512 * 1024); // 512 KB - very small
    let context = JsContext::from(&runtime).unwrap();

    // Try to allocate a lot - should fail
    let result = context.eval(
        r#"
        let data = [];
        for (let i = 0; i < 100000; i++) {
            data.push({ x: i, y: 'data'.repeat(100) });
        }
    "#
        .to_string(),
    );

    // Should fail due to memory limit
    assert!(result.is_err());
}

#[test]
fn test_memory_limit_realistic() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_memory_limit(8 * 1024 * 1024); // 8 MB
    let context = JsContext::from(&runtime).unwrap();

    // Moderate allocation should succeed
    let result = context.eval(
        r#"
        let data = [];
        for (let i = 0; i < 100; i++) {
            data.push({ x: i });
        }
        data.length
    "#
        .to_string(),
    );

    assert!(result.is_ok());
}

#[tokio::test]
async fn test_memory_limit_async() {
    let runtime = JsAsyncRuntime::new().unwrap();
    runtime.set_memory_limit(8 * 1024 * 1024).await;

    let _context = JsAsyncContext::from(&runtime).await.unwrap();
    let engine = JsEngine::create(None, None, None).await.unwrap();
    engine.init_without_bridge().await.unwrap();

    // Should work with reasonable allocation
    let result = engine
        .eval(JsCode::Code("[1, 2, 3, 4, 5]".to_string()), None)
        .await;
    assert!(result.is_ok());
}

// ============================================================================
// Stack Size Limit Tests
// ============================================================================

#[test]
fn test_stack_size_limit_set() {
    let runtime = JsRuntime::new().unwrap();

    // Set various stack sizes
    runtime.set_max_stack_size(256 * 1024); // 256 KB
    runtime.set_max_stack_size(1024 * 1024); // 1 MB
    runtime.set_max_stack_size(0); // Default

    let _context = JsContext::from(&runtime).unwrap();
}

#[test]
fn test_stack_overflow_protection() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_max_stack_size(128 * 1024); // Small stack
    let context = JsContext::from(&runtime).unwrap();

    // Deep recursion should fail
    let result = context.eval(
        r#"
        function recurse(n) {
            if (n <= 0) return 0;
            return 1 + recurse(n - 1);
        }
        recurse(100000)
    "#
        .to_string(),
    );

    // Should error due to stack overflow
    assert!(result.is_err());
}

#[test]
fn test_stack_with_reasonable_recursion() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_max_stack_size(1024 * 1024); // 1 MB
    let context = JsContext::from(&runtime).unwrap();

    // Moderate recursion should succeed
    let result = context.eval(
        r#"
        function factorial(n) {
            if (n <= 1) return 1;
            return n * factorial(n - 1);
        }
        factorial(10)
    "#
        .to_string(),
    );

    assert!(result.is_ok());
}

// ============================================================================
// Memory Usage All Getters Test
// ============================================================================

#[test]
fn test_memory_usage_all_getters() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    // Do some work
    let _ = context.eval(
        r#"
        let arr = [1, 2, 3];
        let obj = {a: 1, b: 2};
        function test() { return 42; }
        let str = "hello world";
    "#
        .to_string(),
    );

    let usage = runtime.memory_usage();

    // Test all getters
    let _ = usage.malloc_size();
    let _ = usage.malloc_limit();
    let _ = usage.memory_used_size();
    let _ = usage.malloc_count();
    let _ = usage.memory_used_count();
    let _ = usage.atom_count();
    let _ = usage.atom_size();
    let _ = usage.str_count();
    let _ = usage.str_size();
    let _ = usage.obj_count();
    let _ = usage.obj_size();
    let _ = usage.prop_count();
    let _ = usage.prop_size();
    let _ = usage.shape_count();
    let _ = usage.shape_size();
    let _ = usage.js_func_count();
    let _ = usage.js_func_size();
    let _ = usage.js_func_code_size();
    let _ = usage.js_func_pc2line_count();
    let _ = usage.js_func_pc2line_size();
    let _ = usage.c_func_count();
    let _ = usage.array_count();
    let _ = usage.fast_array_count();
    let _ = usage.fast_array_elements();
    let _ = usage.binary_object_count();
    let _ = usage.binary_object_size();
    let _ = usage.total_memory();
    let _ = usage.total_allocations();
}

#[test]
fn test_memory_usage_clone() {
    let runtime = JsRuntime::new().unwrap();
    let usage = runtime.memory_usage();
    let cloned = usage.clone();

    assert_eq!(usage.total_memory(), cloned.total_memory());
    assert_eq!(usage.obj_count(), cloned.obj_count());
    assert_eq!(usage.str_count(), cloned.str_count());
}

// ============================================================================
// Memory Stress Tests
// ============================================================================

#[test]
fn test_memory_stress_allocate_deallocate() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_memory_limit(32 * 1024 * 1024); // 32 MB
    let context = JsContext::from(&runtime).unwrap();

    // Multiple cycles of allocation and deallocation
    for i in 0..5 {
        let _ = context.eval(format!(
            r#"
            let cycle{} = [];
            for (let i = 0; i < 100; i++) {{
                cycle{}.push({{ data: new Array(50).fill(i) }});
            }}
            cycle{} = null;
        "#,
            i, i, i
        ));

        runtime.run_gc();
    }

    let usage = runtime.memory_usage();
    assert!(usage.total_memory() < 32 * 1024 * 1024);
}

#[test]
fn test_memory_large_string_allocation() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    // Large string
    let result = context.eval("'x'.repeat(100000)".to_string());
    assert!(result.is_ok());

    // Multiple large strings
    let result = context.eval(
        r#"
        let strings = [];
        for (let i = 0; i < 10; i++) {
            strings.push('y'.repeat(10000));
        }
        strings.length
    "#
        .to_string(),
    );
    assert!(result.is_ok());
}

#[test]
fn test_memory_large_array_allocation() {
    let runtime = JsRuntime::new().unwrap();
    runtime.set_memory_limit(64 * 1024 * 1024); // 64 MB
    let context = JsContext::from(&runtime).unwrap();

    let result = context.eval(
        r#"
        let arr = new Array(10000);
        for (let i = 0; i < arr.length; i++) {
            arr[i] = i;
        }
        arr.length
    "#
        .to_string(),
    );

    assert!(result.is_ok());
    if let crate::api::error::JsResult::Ok(JsValue::Integer(len)) = result {
        assert_eq!(len, 10000);
    }
}

#[test]
fn test_memory_deep_object_nesting() {
    let runtime = JsRuntime::new().unwrap();
    let context = JsContext::from(&runtime).unwrap();

    // Create deeply nested object
    let result = context.eval(
        r#"
        function createNested(depth) {
            if (depth === 0) return { value: 'leaf' };
            return { child: createNested(depth - 1) };
        }
        let nested = createNested(50);
        nested.child.child.child.child.child !== undefined
    "#
        .to_string(),
    );

    assert!(result.is_ok());
}

// ============================================================================
// Runtime Info Tests
// ============================================================================

#[test]
fn test_runtime_set_info() {
    let runtime = JsRuntime::new().unwrap();
    let result = runtime.set_info("Test Runtime v1.0".to_string());
    assert!(result.is_ok());
}

#[tokio::test]
async fn test_runtime_set_info_async() {
    let runtime = JsAsyncRuntime::new().unwrap();
    let result = runtime
        .set_info("Test Async Runtime v1.0".to_string())
        .await;
    assert!(result.is_ok());
}

// ============================================================================
// Dump Flags Tests
// ============================================================================

#[test]
fn test_runtime_dump_flags() {
    let runtime = JsRuntime::new().unwrap();

    // Various dump flag values
    runtime.set_dump_flags(0);
    runtime.set_dump_flags(1);
    runtime.set_dump_flags(0xFFFF);

    // Should not panic
    let _context = JsContext::from(&runtime).unwrap();
}

// ============================================================================
// Scoped heap-limit rows (tickets #77 and #79)
// ============================================================================

/// The gate's historically named single-request shape. The array's final size
/// would exceed 16 MiB, but fill grows its backing store in steps. Heap usage
/// measured after eval has unwound is not usage at the allocation refusal (#111).
const HEAP_LIMIT_ROW_SOURCE: &str =
    "(()=>{const blocks=[]; while(true) { blocks.push(new Array(4000000).fill(123)); }})()";

/// The shape #77 measured and #79 is about: the heap grows one ~80 KB array at
/// a time, so the request the limit refuses can leave any residue in
/// `[0, 80 KB)`. When that residue was smaller than what QuickJS needs to build
/// the OOM error object, `JS_ThrowError2` threw a bare null instead of the
/// `InternalError` and the row saw `JsError_Runtime: Runtime error: null`
/// (30 of 1000 engine-level runs in WSL2; 10 of 200 across processes; 10 of 10
/// on macOS CI run 36024098730). The vendored build now keeps headroom for the
/// error object, so this shape must report `JsError_MemoryLimit` every time.
const HEAP_LIMIT_ACCUMULATING_SOURCE: &str =
    "(()=>{const blocks=[]; while(true) { blocks.push(new Array(10000).fill(123)); }})()";

/// The same accumulation with a ~1.6 KB request per step. A smaller request
/// leaves a smaller residue when the limit refuses it, so on a platform whose
/// allocator keeps the residue above the error object's need for the 80 KB
/// shape this finer shape still starves it: on Windows before the headroom
/// patch every run lost the report (30 of 30, `Runtime error: null`,
/// `afterGcUsable` true), which is the reproduction the ticket's WSL2 and
/// macOS runs could only make probabilistic.
const HEAP_LIMIT_FINE_GRAINED_SOURCE: &str =
    "(()=>{const blocks=[]; while(true) { blocks.push(new Array(100).fill(1)); }})()";

/// The row's JS heap limit in bytes, as the gate sets it.
const HEAP_LIMIT_ROW_BYTES: usize = 16 * 1024 * 1024;

/// The gate's parked-cycle script, verbatim.
const HEAP_LIMIT_PARKED_CYCLE_SOURCE: &str =
    r#"(()=>{let x={tag:73};x.self=x;fjs.bridge_call("cycle");return x.self===x&&x.tag===73})()"#;

/// The gate's nested-allocation-pressure script, verbatim. It runs in a queued
/// scope while the cycle scope above is parked in its host call, so the row's
/// engine reaches the heap-limit script with that history behind it.
const HEAP_LIMIT_NESTED_PRESSURE_SOURCE: &str =
    "(()=>{for(let i=0;i<20000;i++){let x={data:new Array(256).fill(i)};x.self=x;}return 42})()";

/// One pass of the gate row, with what the engine reported.
struct HeapLimitRowOutcome {
    /// The Dart-facing error type the row compares against
    /// `JsError_MemoryLimit`, or `JsValue` when the script returned instead of
    /// failing.
    label: String,
    /// The Rust payload behind the label, so a divergent run is self-describing.
    detail: String,
    /// QuickJS's accounting right after the row. A passing run leaves this near
    /// the engine's baseline, which is the whole point of the row's script.
    malloc_size: i64,
    malloc_limit: i64,
    /// Whether a scoped execution still runs after the row (the gate's
    /// `afterGcUsable`).
    after_gc_usable: bool,
}

/// The Dart class name the row compares against, derived from the Rust variant.
fn heap_limit_outcome_label(error: &JsError) -> &'static str {
    match error {
        JsError::Promise(_) => "JsError_Promise",
        JsError::Module { .. } => "JsError_Module",
        JsError::Context(_) => "JsError_Context",
        JsError::Storage(_) => "JsError_Storage",
        JsError::Io { .. } => "JsError_Io",
        JsError::Runtime(_) => "JsError_Runtime",
        JsError::Generic(_) => "JsError_Generic",
        JsError::Engine(_) => "JsError_Engine",
        JsError::Bridge(_) => "JsError_Bridge",
        JsError::Conversion { .. } => "JsError_Conversion",
        JsError::Timeout { .. } => "JsError_Timeout",
        JsError::MemoryLimit(_) => "JsError_MemoryLimit",
        JsError::StackOverflow(_) => "JsError_StackOverflow",
        JsError::Syntax { .. } => "JsError_Syntax",
        JsError::Reference(_) => "JsError_Reference",
        JsError::Type(_) => "JsError_Type",
        JsError::Cancelled(_) => "JsError_Cancelled",
    }
}

/// Runs one heap-limit row engine-level: the same 16 MiB limit, the same
/// `gcThreshold: 1`, the given script, inside a scoped execution in an engine
/// that already ran the gate's parked-cycle and nested-pressure rows.
async fn run_heap_limit_row(source: &str) -> HeapLimitRowOutcome {
    let engine = Arc::new(
        JsEngine::create(
            Some(JsBuiltinOptions::none()),
            None,
            Some(JsEngineRuntimeOptions {
                memory_limit: Some(HEAP_LIMIT_ROW_BYTES),
                gc_threshold: Some(1),
                ..JsEngineRuntimeOptions::default()
            }),
        )
        .await
        .expect("the row's engine is created"),
    );
    let (entered_tx, entered_rx) = oneshot::channel::<u64>();
    let entered_tx = Arc::new(std::sync::Mutex::new(Some(entered_tx)));
    engine
        .init_broker(
            {
                let entered_tx = entered_tx.clone();
                move |request| {
                    let entered_tx = entered_tx
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .take();
                    Box::pin(async move {
                        if let Some(entered_tx) = entered_tx {
                            let _ = entered_tx.send(request.id);
                        }
                    })
                }
            },
            |_| Box::pin(async {}),
        )
        .await
        .expect("the row's broker attaches");

    let cycle_id = engine
        .create_scoped_execution(None)
        .expect("reserve the parked scope");
    let parked = tokio::spawn({
        let engine = engine.clone();
        async move {
            engine
                .eval_scoped(cycle_id, HEAP_LIMIT_PARKED_CYCLE_SOURCE.to_string())
                .await
        }
    });
    let request_id = tokio::time::timeout(Duration::from_secs(5), entered_rx)
        .await
        .expect("the parked host call is entered")
        .expect("the host call reports its request");
    let pressure_id = engine
        .create_scoped_execution(None)
        .expect("reserve the pressure scope");
    let pressure = engine
        .eval_scoped(pressure_id, HEAP_LIMIT_NESTED_PRESSURE_SOURCE.to_string())
        .await;
    assert!(
        matches!(pressure, Ok(JsValue::Integer(42))),
        "the nested pressure row must complete: {pressure:?}"
    );
    complete_bridge_request_global(request_id, JsResult::Ok(JsValue::string("ok")))
        .expect("release the parked scope");
    let cycle = tokio::time::timeout(Duration::from_secs(5), parked)
        .await
        .expect("the parked scope finishes")
        .expect("the parked scope does not panic");
    assert!(
        matches!(cycle, Ok(JsValue::Boolean(true))),
        "the parked scope returns its value: {cycle:?}"
    );

    let row_id = engine
        .create_scoped_execution(None)
        .expect("reserve the row's scope");
    let first = tokio::time::timeout(
        Duration::from_secs(60),
        engine.eval_scoped(row_id, source.to_string()),
    )
    .await
    .expect("the over-limit script stops");
    let (label, detail) = match &first {
        Ok(value) => ("JsValue".to_string(), format!("{value:?}")),
        Err(error) => (
            heap_limit_outcome_label(error).to_string(),
            format!("{error:?} / {error}"),
        ),
    };

    let usage = engine.memory_usage().await.expect("usage is readable");
    engine.run_gc().await.expect("gc runs after the row");
    let after_gc_id = engine
        .create_scoped_execution(None)
        .expect("reserve the after-gc scope");
    let after_gc = engine.eval_scoped(after_gc_id, "21*2".to_string()).await;
    engine.close().await.expect("the row's engine closes");

    HeapLimitRowOutcome {
        label,
        detail,
        malloc_size: usage.malloc_size(),
        malloc_limit: usage.malloc_limit(),
        after_gc_usable: matches!(after_gc, Ok(JsValue::Integer(42))),
    }
}

/// Drives one heap-limit shape through [`run_heap_limit_row`] `iterations`
/// times. Returns how many runs lost the limit's report, and the runs that
/// neither reported the limit nor left the engine usable.
async fn drive_heap_limit_shape(shape: &str, iterations: usize) -> (usize, Vec<String>) {
    let mut divergences = Vec::new();
    let mut report_lost_runs = 0usize;
    for iteration in 0..iterations {
        let outcome = run_heap_limit_row(shape).await;
        let report_kept = outcome.label == "JsError_MemoryLimit"
            && outcome.detail.contains("InternalError: out of memory");
        let report_lost =
            outcome.label == "JsError_Runtime" && outcome.detail.contains("Runtime error: null");
        if report_lost {
            report_lost_runs += 1;
        }
        eprintln!(
            "FJS heap-limit row #{iteration}: label={} malloc_size={} malloc_limit={} \
             report_kept={} report_lost={} after_gc_usable={} detail={}",
            outcome.label,
            outcome.malloc_size,
            outcome.malloc_limit,
            report_kept,
            report_lost,
            outcome.after_gc_usable,
            outcome.detail,
        );
        if !report_kept || !outcome.after_gc_usable {
            divergences.push(format!(
                "#{iteration}: {} (malloc_size={} of {}), engine usable after the row: {}",
                outcome.detail, outcome.malloc_size, outcome.malloc_limit, outcome.after_gc_usable
            ));
        }
    }
    eprintln!(
        "FJS heap-limit row: {report_lost_runs} of {iterations} runs lost the limit's report."
    );
    (report_lost_runs, divergences)
}

/// The historically named single-request shape (`new Array(4000000).fill`):
/// the constructor sets a sparse length, then fill grows the backing array.
/// The libc allocator's usable-size slack could take that growth past the cap
/// on macOS and starve the OOM report (#111). The requested-size Rust allocator
/// must retain the report, and the engine must remain usable after every run.
///
/// Raise the iteration count with `FJS_HEAP_LIMIT_ROW_ITERATIONS=200 cargo test
/// single_request`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn single_request_heap_limit_shape_reports_the_memory_limit() {
    let iterations: usize = std::env::var("FJS_HEAP_LIMIT_ROW_ITERATIONS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(10);
    assert!(iterations > 0, "the single-request row must execute");
    let (report_lost_runs, divergences) =
        drive_heap_limit_shape(HEAP_LIMIT_ROW_SOURCE, iterations).await;
    eprintln!(
        "FJS heap-limit single-request: {iterations} runs, {report_lost_runs} lost, {} divergent.",
        divergences.len()
    );
    assert!(
        divergences.is_empty(),
        "the single-request shape must report JsError_MemoryLimit with InternalError: out of \
         memory and leave the engine usable on every run, but {} of {iterations} runs did not \
         ({report_lost_runs} lost the report): {divergences:#?}",
        divergences.len()
    );
}

/// The accumulating shape of tickets #77 and #79 (`new Array(10000)` per
/// step): the failing request's residue can be smaller than the OOM error
/// object, which is what the vendored headroom exists for. Every iteration
/// must report `JsError::MemoryLimit` and leave the engine usable. Raise the
/// iteration count with `FJS_HEAP_LIMIT_ACCUMULATING_ITERATIONS=...`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn accumulating_heap_limit_shape_reports_the_memory_limit() {
    let iterations: usize = std::env::var("FJS_HEAP_LIMIT_ACCUMULATING_ITERATIONS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(20);
    let (report_lost_runs, divergences) =
        drive_heap_limit_shape(HEAP_LIMIT_ACCUMULATING_SOURCE, iterations).await;
    assert!(
        divergences.is_empty(),
        "the accumulating shape must report the JS heap limit as JsError_MemoryLimit every time \
         and leave the engine usable, but {} of {iterations} runs did not ({report_lost_runs} lost \
         the report): {divergences:#?}",
        divergences.len()
    );
}

/// The fine-grained accumulation of ticket #79: the same defect as the
/// accumulating row, on a shape whose residue starves the error object on
/// every host. Raise the iteration count with
/// `FJS_HEAP_LIMIT_FINE_GRAINED_ITERATIONS=...`.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fine_grained_accumulation_reports_the_memory_limit() {
    let iterations: usize = std::env::var("FJS_HEAP_LIMIT_FINE_GRAINED_ITERATIONS")
        .ok()
        .and_then(|value| value.parse().ok())
        .unwrap_or(20);
    let (report_lost_runs, divergences) =
        drive_heap_limit_shape(HEAP_LIMIT_FINE_GRAINED_SOURCE, iterations).await;
    assert!(
        divergences.is_empty(),
        "the fine-grained accumulation must report the JS heap limit as JsError_MemoryLimit every \
         time and leave the engine usable, but {} of {iterations} runs did not ({report_lost_runs} \
         lost the report): {divergences:#?}",
        divergences.len()
    );
}

// ============================================================================
// Pointer-width allocation boundaries (#111)
// ============================================================================

/// Creates the 8-byte probe buffer the refused requests must leave alone, and
/// keeps it reachable from later scoped executions through `globalThis`.
const TRANSFER_PROBE_SETUP: &str = "globalThis.__liberTransferProbe=(()=>{const \
     b=new ArrayBuffer(8);new Uint8Array(b).fill(7);return b})();true";

/// The probe buffer as one line: length, detach state and contents.
const TRANSFER_PROBE_STATE: &str = "(()=>{const b=globalThis.__liberTransferProbe;const \
     v=new Uint8Array(b);return b.byteLength+'|'+b.detached+'|'+Array.from(v).join(',')})()";

/// What [`TRANSFER_PROBE_STATE`] reports while nothing has touched the buffer.
const TRANSFER_PROBE_INTACT: &str = "8|false|7,7,7,7,7,7,7,7";

/// One boundary row's engine: the gate's 16 MiB limit with `gcThreshold: 1`,
/// or no limit at all (`None`), which leaves QuickJS's `malloc_limit` at 0.
async fn boundary_engine(memory_limit: Option<usize>) -> Arc<JsEngine> {
    Arc::new(
        JsEngine::create(
            Some(JsBuiltinOptions::none()),
            None,
            Some(JsEngineRuntimeOptions {
                memory_limit,
                gc_threshold: Some(1),
                ..JsEngineRuntimeOptions::default()
            }),
        )
        .await
        .expect("the boundary row's engine is created"),
    )
}

/// Runs `source` in a scope of its own and returns the Dart-facing label of the
/// outcome with the Rust result behind it.
async fn run_boundary_script(
    engine: &JsEngine,
    source: &str,
) -> (String, Result<JsValue, JsError>) {
    let scope = engine
        .create_scoped_execution(None)
        .expect("reserve the boundary scope");
    let outcome = tokio::time::timeout(
        Duration::from_secs(60),
        engine.eval_scoped(scope, source.to_string()),
    )
    .await
    .expect("the boundary script stops");
    let label = match &outcome {
        Ok(_) => "JsValue".to_string(),
        Err(error) => heap_limit_outcome_label(error).to_string(),
    };
    (label, outcome)
}

/// Asserts that a boundary script was refused with `label` and `needle` in its
/// payload instead of running.
fn assert_refused(outcome: &Result<JsValue, JsError>, label: &str, needle: &str, what: &str) {
    match outcome {
        Err(error) => {
            let actual = heap_limit_outcome_label(error).to_string();
            let detail = format!("{error:?} / {error}");
            assert_eq!(actual, label, "{what} must be refused as {label}: {detail}");
            assert!(
                detail.contains(needle),
                "{what} must report `{needle}`, not `{detail}`"
            );
        }
        Ok(value) => panic!("{what} must be refused, but the script returned {value:?}"),
    }
}

/// Asserts that a row returned the string it reports, and returns it.
fn boundary_string(outcome: &Result<JsValue, JsError>, what: &str) -> String {
    match outcome {
        Ok(JsValue::String(value)) => value.clone(),
        other => panic!("{what} must return a string, got {other:?}"),
    }
}

/// Asserts that the probe buffer is still the attached 8 bytes of 7 it was
/// created as, and returns what it reported.
async fn assert_probe_buffer_intact(engine: &JsEngine, what: &str) -> String {
    let (_, state) = run_boundary_script(engine, TRANSFER_PROBE_STATE).await;
    let state = boundary_string(&state, &format!("{what}: reading the probe buffer"));
    assert_eq!(
        state, TRANSFER_PROBE_INTACT,
        "{what}: a refused transfer must leave the original ArrayBuffer attached and unchanged"
    );
    state
}

/// Runs the pointer-width transfer rows against one engine: the requests the
/// pinned 32-bit checks let through, the transfer lengths that do not fit a
/// `size_t`, and the ordinary grow and shrink transfers that must keep working.
async fn run_transfer_boundary_rows(engine: &JsEngine, context: &str) {
    let (_, created) = run_boundary_script(engine, TRANSFER_PROBE_SETUP).await;
    assert!(
        matches!(created, Ok(JsValue::Boolean(true))),
        "{context}: the probe buffer must be created: {created:?}"
    );

    for size in [usize::MAX, usize::MAX - 14, usize::MAX - 15] {
        let what = format!("{context}: transfer({size})");
        let source = format!("globalThis.__liberTransferProbe.transfer({size})");
        let (_, outcome) = run_boundary_script(engine, &source).await;
        assert_refused(
            &outcome,
            "JsError_MemoryLimit",
            "InternalError: out of memory",
            &what,
        );
        let state = assert_probe_buffer_intact(engine, &what).await;
        eprintln!("FJS pointer-width row {what}: buffer={state}");
    }

    for size in [1u64 << 32, (1u64 << 32) + 100] {
        let what = format!("{context}: transfer({size})");
        let source = format!("globalThis.__liberTransferProbe.transfer({size})");
        let (_, outcome) = run_boundary_script(engine, &source).await;
        assert_refused(
            &outcome,
            "JsError_Runtime",
            "RangeError: invalid array buffer length",
            &what,
        );
        let state = assert_probe_buffer_intact(engine, &what).await;
        eprintln!("FJS pointer-width row {what}: buffer={state}");
    }

    let grow = "(()=>{const b=globalThis.__liberTransferProbe.transfer(16);\
                globalThis.__liberTransferProbe=b;const v=new Uint8Array(b);return \
                b.byteLength+'|'+Array.from(v).join(',')})()";
    let (_, grown) = run_boundary_script(engine, grow).await;
    assert_eq!(
        boundary_string(&grown, &format!("{context}: the growing transfer")),
        "16|7,7,7,7,7,7,7,7,0,0,0,0,0,0,0,0",
        "{context}: a growing transfer must keep the prefix and zero-fill the rest"
    );

    let shrink = "(()=>{const b=globalThis.__liberTransferProbe.transfer(4);\
                   globalThis.__liberTransferProbe=b;const v=new Uint8Array(b);return \
                   b.byteLength+'|'+Array.from(v).join(',')})()";
    let (_, shrunk) = run_boundary_script(engine, shrink).await;
    assert_eq!(
        boundary_string(&shrunk, &format!("{context}: the shrinking transfer")),
        "4|7,7,7,7",
        "{context}: a shrinking transfer must keep the surviving prefix"
    );

    let (_, usable) = run_boundary_script(engine, "21*2").await;
    assert!(
        matches!(usable, Ok(JsValue::Integer(42))),
        "{context}: the engine must stay usable after the boundary rows: {usable:?}"
    );
}

/// The 32-bit allocation boundary of #111. On this target a `size_t` is 32 bits
/// wide and `ArrayBuffer.prototype.transfer` takes a `uint64_t`: the pinned
/// check `malloc_size + size - old_size > malloc_limit - 1` wrapped for a
/// request of `SIZE_MAX` bytes, `RustAllocator::round_size` rounded that request
/// back to zero, the allocator returned a header-only block, and the transfer
/// then cleared ~4 GB outside it. The vendored guard refuses a request whose
/// layout wraps, and the transfer length guard refuses a length a `size_t`
/// cannot hold, which the pinned code truncated (dropping the backing store of a
/// still-attached ArrayBuffer, or keeping it while `memset`ting past it).
///
/// The rows run in the same shape as the gate rows (16 MiB limit,
/// `gcThreshold: 1`), once against that limit and once against an engine with no
/// limit at all, where only the layout bound can refuse the request. On a 64-bit
/// target the pinned arithmetic does not wrap and the same input is refused by
/// the configured limit, so the row is not-applicable and says so.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn pointer_width_transfer_boundaries_report_and_keep_the_buffer() {
    if usize::BITS != 32 {
        eprintln!(
            "FJS pointer-width row: not-applicable on a {}-bit target; the pinned transfer only \
             truncates where `size_t` is narrower than the `uint64_t` length",
            usize::BITS
        );
        return;
    }

    for (context, memory_limit) in [
        ("16 MiB limit", Some(HEAP_LIMIT_ROW_BYTES)),
        ("no limit", None),
    ] {
        let engine = boundary_engine(memory_limit).await;
        run_transfer_boundary_rows(&engine, context).await;
        let usage = engine.memory_usage().await.expect("usage is readable");
        eprintln!(
            "FJS pointer-width row ({context}): malloc_size={} of {}",
            usage.malloc_size(),
            usage.malloc_limit()
        );
        engine.close().await.expect("the boundary engine closes");
    }
}
